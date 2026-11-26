#import <mach-o/dyld_images.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

#import "FLLoaded.h"
#import "FLMachO.h"
#import "FLMonitors.h"
#import "FLSystemInfo.h"

static const uint32_t FLImagesMost = 4096;
static const size_t FLPathMost = 1024;
static const NSUInteger FLProgramsMost = 0xffff;
static const NSUInteger FLUnreadMost = 64;
static const NSTimeInterval FLLoadedSaveEvery = 600;
static const NSTimeInterval FLLoadedSaveAnyway = 3600;
static const uint32_t FLSlideSince = 12;
static const size_t FLInfoLeast = 12;

@interface FLLoadedEntry : NSObject

@property(nonatomic) NSTimeInterval first;
@property(nonatomic) NSTimeInterval last;
@property(nonatomic) BOOL cached;
@property(nonatomic, strong) NSMutableIndexSet *programs;

@end

@implementation FLLoadedEntry
@end

static BOOL FLReadTask(mach_port_t task, vm_address_t address, void *into, size_t size) {
  vm_size_t got = 0;
  return vm_read_overwrite(task, address, size, (vm_address_t)into, &got) == KERN_SUCCESS &&
         got == size;
}

static NSString *FLReadPath(mach_port_t task, vm_address_t address) {
  char text[FLPathMost];
  size_t have = 0;
  while (address != 0 && have < sizeof(text)) {
    size_t room = vm_page_size - ((address + have) & (vm_page_size - 1));
    size_t want = MIN(room, sizeof(text) - have);
    if (!FLReadTask(task, address + have, text + have, want)) {
      return nil;
    }
    char *end = memchr(text + have, 0, want);
    if (end != NULL) {
      return [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:text
                                    length:(NSUInteger)(end - text)];
    }
    have += want;
  }
  return nil;
}

@implementation FLLoadedMonitor {
  dispatch_queue_t _queue;
  NSDictionary<NSNumber *, NSString *> *_cached;
  NSMutableDictionary<NSString *, FLLoadedEntry *> *_libraries;
  NSMutableArray<NSString *> *_programs;
  NSMutableDictionary<NSString *, NSNumber *> *_indices;
  NSMutableDictionary<NSString *, NSNumber *> *_unread;
  NSDate *_began;
  NSDate *_saved;
  unsigned long long _looks;
  BOOL _changed;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _libraries = [NSMutableDictionary new];
    _programs = [NSMutableArray new];
    _indices = [NSMutableDictionary new];
    _unread = [NSMutableDictionary new];
    _began = [NSDate date];
    _saved = [NSDate date];
    [self restore:FLReadState(FLLoadedState)];
  }
  return self;
}

- (void)restore:(NSDictionary *)saved {
  NSArray<NSString *> *programs = saved[@"programs"];
  NSDictionary<NSString *, NSDictionary *> *libraries = saved[@"libraries"];
  if (![programs isKindOfClass:[NSArray class]] ||
      ![libraries isKindOfClass:[NSDictionary class]]) {
    return;
  }
  for (NSString *path in libraries) {
    NSDate *first = libraries[path][@"first"];
    NSDate *last = libraries[path][@"last"];
    if (![first isKindOfClass:[NSDate class]] || ![last isKindOfClass:[NSDate class]]) {
      continue;
    }
    FLLoadedEntry *entry = [FLLoadedEntry new];
    entry.first = first.timeIntervalSinceReferenceDate;
    entry.last = last.timeIntervalSinceReferenceDate;
    entry.cached = [libraries[path][@"cached"] boolValue];
    entry.programs = [NSMutableIndexSet new];
    for (NSString *program in FLLoadedBy(saved, path)) {
      [entry.programs addIndex:[self indexOfProgram:program]];
    }
    _libraries[path] = entry;
  }
  if ([saved[@"began"] isKindOfClass:[NSDate class]]) {
    _began = saved[@"began"];
  }
  _looks = [saved[@"looks"] unsignedLongLongValue];
}

- (NSUInteger)indexOfProgram:(NSString *)program {
  NSNumber *known = _indices[program];
  if (known != nil) {
    return known.unsignedIntegerValue;
  }
  if (_programs.count >= FLProgramsMost) {
    return FLProgramsMost;
  }
  [_programs addObject:program];
  _indices[program] = @(_programs.count - 1);
  return _programs.count - 1;
}

- (void)note:(NSString *)path
          by:(NSUInteger)program
          at:(NSTimeInterval)now
      cached:(BOOL)cached {
  FLLoadedEntry *entry = _libraries[path];
  if (entry == nil) {
    entry = [FLLoadedEntry new];
    entry.first = now;
    entry.cached = cached;
    entry.programs = [NSMutableIndexSet new];
    _libraries[path] = entry;
    _changed = YES;
  }
  if (program < FLProgramsMost && ![entry.programs containsIndex:program]) {
    [entry.programs addIndex:program];
    _changed = YES;
  }
  entry.last = now;
}

- (void)look:(int)pid {
  if (pid <= 0 || pid == getpid() || _cached == nil) {
    return;
  }
  NSString *program = FLProcessSketch(pid, NO).path;
  if (program.length == 0) {
    return;
  }
  mach_port_t task = MACH_PORT_NULL;
  struct task_dyld_info where;
  mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
  struct dyld_all_image_infos all;
  memset(&all, 0, sizeof(all));
  struct dyld_image_info *list = NULL;
  BOOL read = NO;
  if (task_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS &&
      task_info(task, TASK_DYLD_INFO, (task_info_t)&where, &count) == KERN_SUCCESS &&
      where.all_image_info_addr != 0 && where.all_image_info_size >= FLInfoLeast &&
      FLReadTask(task, (vm_address_t)where.all_image_info_addr, &all,
                 MIN(sizeof(all), (size_t)where.all_image_info_size)) &&
      all.infoArrayCount > 0 && all.infoArrayCount <= FLImagesMost && all.infoArray != NULL) {
    size_t size = all.infoArrayCount * sizeof(struct dyld_image_info);
    list = malloc(size);
    read = list != NULL && FLReadTask(task, (vm_address_t)all.infoArray, list, size);
  }
  if (read) {
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    NSUInteger index = [self indexOfProgram:program];
    uint64_t slide = all.version >= FLSlideSince ? (uint64_t)all.sharedCacheSlide : 0;
    for (uint32_t each = 1; each < all.infoArrayCount; each++) {
      @autoreleasepool {
        uint64_t address = (uint64_t)(uintptr_t)list[each].imageLoadAddress;
        NSString *shared = address >= slide ? _cached[@(address - slide)] : nil;
        NSString *path = shared ?: FLReadPath(task, (vm_address_t)list[each].imageFilePath);
        if (path.length > 0 && ![path isEqualToString:program]) {
          [self note:path by:index at:now cached:shared != nil];
        }
      }
    }
    _looks++;
  } else if (_unread.count < FLUnreadMost || _unread[program] != nil) {
    _unread[program] = @(_unread[program].unsignedLongLongValue + 1);
  }
  free(list);
  if (task != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), task);
  }
}

- (void)startOnQueue:(dispatch_queue_t)queue {
  _queue = queue;
  NSMutableDictionary<NSNumber *, NSString *> *cached = [NSMutableDictionary new];
  @autoreleasepool {
    for (FLSharedCache *cache in [FLSharedCache caches]) {
      for (NSDictionary *image in cache.images) {
        if (image[@"address"] != nil && image[@"path"] != nil) {
          cached[image[@"address"]] = image[@"path"];
        }
      }
    }
  }
  _cached = cached;
  [self sweep];
}

- (void)sweep {
  for (FLProcess *process in FLProcessList(NO)) {
    @autoreleasepool {
      [self look:process.pid];
    }
  }
}

- (void)noticed:(FLProcess *)process after:(NSTimeInterval)delay {
  int pid = process.pid;
  if (_queue == nil) {
    return;
  }
  __weak FLLoadedMonitor *weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
    [weak look:pid];
  });
}

- (NSDictionary *)contents {
  NSMutableDictionary *libraries = [NSMutableDictionary new];
  for (NSString *path in _libraries) {
    FLLoadedEntry *entry = _libraries[path];
    libraries[path] = @{
      @"first" : [NSDate dateWithTimeIntervalSinceReferenceDate:entry.first],
      @"last" : [NSDate dateWithTimeIntervalSinceReferenceDate:entry.last],
      @"cached" : @(entry.cached),
      @"by" : FLLoadedIndices(entry.programs),
    };
  }
  return @{
    @"version" : @1,
    @"began" : _began,
    @"saved" : [NSDate date],
    @"looks" : @(_looks),
    @"watching" : @(_cached.count > 0),
    @"programs" : [_programs copy],
    @"libraries" : libraries,
    @"unread" : [_unread copy],
  };
}

- (BOOL)save {
  BOOL saved = FLWriteCompactState(FLLoadedState, [self contents]);
  if (saved) {
    _saved = [NSDate date];
    _changed = NO;
  }
  return saved;
}

- (BOOL)saveIfDue {
  NSTimeInterval since = -_saved.timeIntervalSinceNow;
  if (since < FLLoadedSaveEvery || (!_changed && since < FLLoadedSaveAnyway)) {
    return NO;
  }
  return [self save];
}

@end
