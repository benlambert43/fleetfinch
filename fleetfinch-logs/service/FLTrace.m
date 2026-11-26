#import "FLTrace.h"

#import <signal.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "FLCallNames.h"
#import "FLCollect.h"
#import "FLCommon.h"
#import "FLPorts.h"
#import "FLReport.h"
#import "FLStatus.h"
#import "FLStore.h"
#import "FLSystemInfo.h"

enum {
  FLTraceEnable = 3,
  FLTraceSetBuffer = 4,
  FLTraceGetBuffer = 5,
  FLTraceSetUp = 6,
  FLTraceRemove = 7,
  FLTraceRead = 10,
  FLTraceThreads = 21,
  FLTraceFilter = 22,
};

typedef struct {
  uint64_t stamp;
  uint32_t arguments[4];
  uint32_t thread;
  uint32_t code;
} FLTraceRecord;

typedef struct {
  uint32_t thread;
  int32_t pid;
  char name[20];
} FLTraceMapped;

typedef struct {
  int records;
  int quiet;
  int flags;
  int threads;
  int buffer;
} FLTraceBuffer;

#define FL_TRACE_PATH 96
#define FL_TRACE_CALLS 512
#define FL_TRACE_TRAPS 128

typedef struct {
  int32_t pid;
  int32_t program;
  uint16_t call;
  uint16_t length;
  uint16_t held;
  uint8_t gathering;
  char path[FL_TRACE_PATH];
  char kept[FL_TRACE_PATH];
  char name[20];
} FLTraceThread;

typedef struct {
  uint32_t calls[FL_TRACE_CALLS];
  uint32_t failed[FL_TRACE_CALLS];
  uint16_t error[FL_TRACE_CALLS];
  uint32_t traps[FL_TRACE_TRAPS];
  uint32_t opened;
  uint32_t looked;
} FLTraceCounts;

static const int FLTraceControl = 24;
static const int FLTraceRecords = 32768;
static const size_t FLTraceFilterBytes = 8192;
static const size_t FLThreadsMost = 8192;
static const useconds_t FLTracePause = 200000;
static const uint32_t FLCodeCalls = 0x040c;
static const uint32_t FLCodeTraps = 0x010c;
static const uint32_t FLCodeLookup = 0x03010090;
static const uint32_t FLCodeThread = 0x07000004;
static const uint32_t FLCodeExec = 0x07000008;
static const uint32_t FLCodeThreadEnd = 0x0700000c;
static const uint32_t FLCodeThreadName = 0x07010004;
static const uint32_t FLCodeLost = 0x07020008;
static const uint32_t FLCodeStart = 1;
static const uint32_t FLCodeEnd = 2;
static const size_t FLPathMost = 92;
static const int32_t FLProgramUnknown = -1;
static const int32_t FLProgramIgnored = -2;
static const NSTimeInterval FLTraceDefault = 20;
static const NSTimeInterval FLTraceLongest = 6 * 3600;
static const NSUInteger FLAreaCacheMost = 20000;
static const NSUInteger FLDetailMost = 5000;
static const NSUInteger FLProgramsListed = 6;
static const NSUInteger FLFactsMost = 80;
static const size_t FLSystemDepth = 4;
static const size_t FLOtherDepth = 3;
static const int FLNotSupported[] = {45, 78, 102};
static NSString *const FLOwnProgram = @"/usr/bin/finchlog";
static NSString *const FLKernelProgram = @"(the kernel)";
static NSString *const FLUnplacedLong = @"(paths too long to place)";
static NSString *const FLUnplacedRelative = @"(paths given without their folder)";

static volatile sig_atomic_t FLTraceStopped;

static void FLTraceStop(int number) {
  FLTraceStopped = 1;
}

static int FLTraceAsk(int operation, int value, void *data, size_t *size) {
  int name[4] = {CTL_KERN, FLTraceControl, operation, value};
  size_t none = 0;
  return sysctl(name, value >= 0 ? 4 : 3, data, size ?: &none, NULL, 0);
}

static BOOL FLTraceInUse(void) {
  FLTraceBuffer buffer;
  size_t size = sizeof(buffer);
  memset(&buffer, 0, sizeof(buffer));
  return FLTraceAsk(FLTraceGetBuffer, -1, &buffer, &size) == 0 && buffer.records > 0;
}

static BOOL FLAnotherTraceRuns(void) {
  for (FLProcess *process in FLProcessList(YES)) {
    if (process.pid != getpid() && [process.path isEqualToString:FLOwnProgram] &&
        process.arguments.count > 1 && [process.arguments[1] isEqualToString:@"trace"]) {
      return YES;
    }
  }
  return NO;
}

BOOL FLTraceRelease(void) {
  if (!FLTraceInUse() || FLAnotherTraceRuns()) {
    return NO;
  }
  FLTraceAsk(FLTraceEnable, 0, NULL, NULL);
  return FLTraceAsk(FLTraceRemove, -1, NULL, NULL) == 0;
}

static BOOL FLIsOpen(uint32_t call) {
  static const uint32_t opens[] = {5, 59, 216, 244, 277, 398, 441, 463, 464};
  for (size_t index = 0; index < sizeof(opens) / sizeof(opens[0]); index++) {
    if (opens[index] == call) {
      return YES;
    }
  }
  return NO;
}

@interface FLTraceUse : NSObject

@property(nonatomic) uint32_t opened;
@property(nonatomic) uint32_t looked;

@end

@implementation FLTraceUse
@end

@interface FLTraceSession : NSObject

@property(nonatomic, readonly) unsigned long long records;
@property(nonatomic, readonly) unsigned long long lost;
@property(nonatomic, readonly) NSTimeInterval seconds;
@property(nonatomic, copy) NSString *detail;

- (NSString *)run:(NSTimeInterval)seconds;
- (void)mergeInto:(NSMutableDictionary *)ledger;
- (NSString *)summary;

@end

@implementation FLTraceSession {
  CFMutableDictionaryRef _threads;
  CFMutableDictionaryRef _pids;
  NSMutableArray<NSString *> *_programs;
  NSMutableDictionary<NSString *, NSNumber *> *_indices;
  NSPointerArray *_counts;
  NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, FLTraceUse *> *> *_files;
  NSMutableDictionary<NSString *, NSString *> *_areas;
  NSSet<NSString *> *_items;
  NSDictionary<NSString *, id> *_folders;
  NSDictionary<NSString *, id> *_named;
  NSSet<NSString *> *_roots;
  NSCountedSet<NSString *> *_opened;
  NSCountedSet<NSString *> *_looked;
  NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *_links;
  NSUInteger _linked;
  NSUInteger _closed;
  int32_t _detailed;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _threads = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    _pids = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    _programs = [NSMutableArray new];
    _indices = [NSMutableDictionary new];
    _counts = [NSPointerArray pointerArrayWithOptions:NSPointerFunctionsOpaqueMemory];
    _files = [NSMutableDictionary new];
    _areas = [NSMutableDictionary new];
    _opened = [NSCountedSet new];
    _looked = [NSCountedSet new];
    _detailed = FLProgramUnknown;
    _roots = [NSSet setWithArray:@[
      @"System", @"Library", @"Applications", @"usr", @"bin", @"sbin", @"private", @"var", @"tmp",
      @"etc", @"dev", @"Developer", @"cores", @"User", @"taig", @"boot", @"lib", @"mnt"
    ]];
    [self readInventory];
  }
  return self;
}

- (void)dealloc {
  for (NSUInteger index = 0; index < _counts.count; index++) {
    free([_counts pointerAtIndex:index]);
  }
  NSUInteger count = (NSUInteger)CFDictionaryGetCount(_threads);
  const void **values = calloc(MAX(count, 1), sizeof(void *));
  CFDictionaryGetKeysAndValues(_threads, NULL, values);
  for (NSUInteger index = 0; index < count; index++) {
    free((void *)values[index]);
  }
  free(values);
  CFRelease(_threads);
  CFRelease(_pids);
}

- (void)readInventory {
  NSMutableSet<NSString *> *items = [NSMutableSet new];
  NSMutableDictionary<NSString *, id> *folders = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, id> *named = [NSMutableDictionary new];
  @autoreleasepool {
    for (NSDictionary *item in FLReadState(FLInventoryState)[@"items"]) {
      NSString *path = item[@"path"];
      if (![path hasPrefix:@"/"] || [item[@"kind"] isEqualToString:@"service"]) {
        continue;
      }
      [items addObject:path];
      NSString *last = path.lastPathComponent;
      folders[last] = folders[last] == nil ? path : [NSNull null];
      if ([item[@"kind"] isEqualToString:@"program"]) {
        NSString *brief = last.length > 16 ? [last substringToIndex:16] : last;
        named[brief] = named[brief] == nil ? path : [NSNull null];
      }
    }
  }
  _items = items;
  _folders = folders;
  _named = named;
}

- (int32_t)indexOfProgram:(NSString *)program {
  NSNumber *known = _indices[program];
  if (known != nil) {
    return known.intValue;
  }
  if ([program isEqualToString:FLOwnProgram]) {
    return FLProgramIgnored;
  }
  [_programs addObject:program];
  [_counts addPointer:calloc(1, sizeof(FLTraceCounts))];
  _indices[program] = @(_programs.count - 1);
  if (self.detail != nil && _detailed == FLProgramUnknown &&
      ([program isEqualToString:self.detail] ||
       [program.lastPathComponent caseInsensitiveCompare:self.detail] == NSOrderedSame)) {
    _detailed = (int32_t)(_programs.count - 1);
  }
  return (int32_t)(_programs.count - 1);
}

- (int32_t)programOfProcess:(int32_t)pid name:(const char *)name {
  const void *cached = NULL;
  if (CFDictionaryGetValueIfPresent(_pids, (const void *)(intptr_t)pid, &cached)) {
    return (int32_t)(intptr_t)cached - 3;
  }
  NSString *program = pid == 0 ? FLKernelProgram : FLProcessSketch(pid, NO).path;
  if (program.length == 0 && name != NULL && name[0] != '\0') {
    NSString *brief = [[NSString alloc] initWithBytes:name
                                               length:strnlen(name, 20)
                                             encoding:NSUTF8StringEncoding];
    id found = brief == nil ? nil : _named[brief];
    program = [found isKindOfClass:[NSString class]]
      ? found
      : (brief.length > 0 ? [brief stringByAppendingString:@" (gone before it was looked at)"]
                          : nil);
  }
  int32_t index = program.length == 0 ? FLProgramUnknown : [self indexOfProgram:program];
  if (index != FLProgramUnknown) {
    CFDictionarySetValue(_pids, (const void *)(intptr_t)pid, (const void *)(intptr_t)(index + 3));
  }
  return index;
}

- (FLTraceThread *)thread:(uint32_t)identifier make:(BOOL)make {
  FLTraceThread *thread =
    (FLTraceThread *)CFDictionaryGetValue(_threads, (const void *)(uintptr_t)identifier);
  if (thread == NULL && make) {
    thread = calloc(1, sizeof(FLTraceThread));
    thread->pid = -1;
    thread->program = FLProgramUnknown;
    CFDictionarySetValue(_threads, (const void *)(uintptr_t)identifier, thread);
  }
  return thread;
}

- (void)readThreads {
  size_t size = FLThreadsMost * sizeof(FLTraceMapped);
  FLTraceMapped *mapped = calloc(1, size);
  if (mapped != NULL && FLTraceAsk(FLTraceThreads, -1, mapped, &size) == 0) {
    for (size_t index = 0; index < size / sizeof(FLTraceMapped); index++) {
      if (mapped[index].thread == 0) {
        continue;
      }
      FLTraceThread *thread = [self thread:mapped[index].thread make:YES];
      if (thread->pid < 0) {
        thread->pid = mapped[index].pid;
        memcpy(thread->name, mapped[index].name, sizeof(thread->name));
      }
    }
  }
  free(mapped);
}

- (NSString *)areaOfFolder:(NSString *)folder {
  NSString *known = _areas[folder];
  if (known != nil) {
    return known;
  }
  NSString *area = nil;
  NSString *walked = folder;
  while (walked.length > 1) {
    if ([_items containsObject:walked]) {
      area = walked;
      break;
    }
    walked = walked.stringByDeletingLastPathComponent;
  }
  if (area == nil) {
    NSArray<NSString *> *parts = [folder componentsSeparatedByString:@"/"];
    BOOL system = [folder hasPrefix:@"/System/Library/"] || [folder hasPrefix:@"/private/var/"];
    NSUInteger depth = (system ? FLSystemDepth : FLOtherDepth) + 1;
    area = parts.count <= depth
      ? folder
      : [[parts subarrayWithRange:NSMakeRange(0, depth)] componentsJoinedByString:@"/"];
  }
  if (_areas.count >= FLAreaCacheMost) {
    [_areas removeAllObjects];
  }
  _areas[folder] = area;
  return area;
}

- (NSString *)areaOfPath:(NSString *)path whole:(BOOL)whole {
  if (!whole) {
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
      id found = part.pathExtension.length > 0 ? _folders[part] : nil;
      if ([found isKindOfClass:[NSString class]]) {
        return found;
      }
    }
    return [path hasPrefix:@"/"] || path.length >= FLPathMost ? FLUnplacedLong : FLUnplacedRelative;
  }
  if ([_items containsObject:path]) {
    return path;
  }
  return [self areaOfFolder:path.stringByDeletingLastPathComponent];
}

- (void)use:(const char *)raw length:(size_t)length by:(int32_t)program opened:(BOOL)opened {
  while (length > 0 && (raw[length - 1] == '\0' || raw[length - 1] == '/')) {
    length--;
  }
  if (length == 0 || program < 0) {
    return;
  }
  NSString *given = [[NSString alloc] initWithBytes:raw
                                             length:length
                                           encoding:NSUTF8StringEncoding];
  if (given == nil) {
    return;
  }
  NSString *path = given;
  while ([path rangeOfString:@"//"].location != NSNotFound) {
    path = [path stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
  }
  given = [path hasPrefix:@"private/"] ? [@"/" stringByAppendingString:path] : path;
  path = given;
  for (NSArray<NSString *> *pair in
       @[ @[ @"/var/", @"/private/var/" ], @[ @"/tmp/", @"/private/var/tmp/" ],
          @[ @"/etc/", @"/private/etc/" ] ]) {
    if ([given hasPrefix:pair[0]]) {
      path = [pair[1] stringByAppendingString:[given substringFromIndex:[pair[0] length]]];
    }
  }
  NSRange second = [path rangeOfString:@"/" options:0 range:NSMakeRange(1, path.length - 1)];
  NSString *first = [path hasPrefix:@"/"]
    ? [path substringWithRange:NSMakeRange(1, (second.location == NSNotFound ? path.length
                                                                             : second.location) -
                                                1)]
    : nil;
  BOOL whole = first != nil && (length < FLPathMost || [_roots containsObject:first]);
  NSString *area = [self areaOfPath:path whole:whole];
  NSMutableDictionary<NSNumber *, FLTraceUse *> *users = _files[area];
  if (users == nil) {
    users = [NSMutableDictionary new];
    _files[area] = users;
  }
  FLTraceUse *use = users[@(program)];
  if (use == nil) {
    use = [FLTraceUse new];
    users[@(program)] = use;
  }
  FLTraceCounts *counts = [_counts pointerAtIndex:(NSUInteger)program];
  if (opened) {
    use.opened += 1;
    counts->opened += 1;
  } else {
    use.looked += 1;
    counts->looked += 1;
  }
  if (program == _detailed) {
    NSCountedSet<NSString *> *kept = opened ? _opened : _looked;
    if (kept.count < FLDetailMost || [kept containsObject:path]) {
      [kept addObject:whole ? path : [@"…" stringByAppendingString:path]];
    }
  }
}

- (void)handle:(const FLTraceRecord *)record {
  uint32_t code = record->code;
  uint32_t kind = code & ~3u;
  uint32_t phase = code & 3u;
  if (kind == FLCodeLost) {
    _lost += 1;
    return;
  }
  if (kind == FLCodeThread) {
    FLTraceThread *made = [self thread:record->arguments[0] make:YES];
    made->pid = (int32_t)record->arguments[1];
    made->program = FLProgramUnknown;
    FLTraceThread *maker = [self thread:record->thread make:NO];
    if (maker != NULL && maker->pid == made->pid) {
      memcpy(made->name, maker->name, sizeof(made->name));
    }
    return;
  }
  if (kind == FLCodeThreadEnd) {
    FLTraceThread *ended = [self thread:record->arguments[0] make:NO];
    if (ended != NULL) {
      CFDictionaryRemoveValue(_threads, (const void *)(uintptr_t)record->arguments[0]);
      free(ended);
    }
    return;
  }
  FLTraceThread *thread = [self thread:record->thread make:YES];
  if (kind == FLCodeThreadName) {
    return;
  }
  if (kind == FLCodeExec) {
    thread->pid = (int32_t)record->arguments[0];
    thread->program = FLProgramUnknown;
    CFDictionaryRemoveValue(_pids, (const void *)(intptr_t)thread->pid);
    return;
  }
  uint32_t group = code >> 16;
  if (thread->pid < 0 && group == FLCodeCalls && phase == FLCodeEnd && record->arguments[3] > 0) {
    thread->pid = (int32_t)record->arguments[3];
  }
  if (thread->program == FLProgramUnknown && thread->pid >= 0) {
    thread->program = [self programOfProcess:thread->pid name:thread->name];
  }
  int32_t program = thread->program;
  if (program < 0) {
    return;
  }
  FLTraceCounts *counts = [_counts pointerAtIndex:(NSUInteger)program];
  uint32_t number = (code >> 2) & 0x3fff;
  if (group == FLCodeCalls) {
    if (phase == FLCodeStart) {
      if (thread->held > 0) {
        [self use:thread->kept length:thread->held by:program opened:NO];
      }
      thread->call = (uint16_t)(number + 1);
      thread->held = 0;
      if (number < FL_TRACE_CALLS) {
        counts->calls[number] += 1;
      }
    } else if (phase == FLCodeEnd) {
      uint32_t failed = record->arguments[0];
      if (failed != 0 && number < FL_TRACE_CALLS) {
        counts->failed[number] += 1;
        counts->error[number] = (uint16_t)failed;
      }
      if (thread->held > 0 && failed == 0) {
        [self use:thread->kept length:thread->held by:program opened:FLIsOpen(number)];
      }
      thread->held = 0;
      thread->call = 0;
    }
    return;
  }
  if (group == FLCodeTraps) {
    if (phase == FLCodeStart && number < FL_TRACE_TRAPS) {
      counts->traps[number] += 1;
    }
    return;
  }
  if (kind != FLCodeLookup) {
    return;
  }
  const char *bytes = (const char *)record->arguments;
  size_t offered = sizeof(record->arguments);
  if ((phase & FLCodeStart) != 0) {
    thread->length = 0;
    thread->gathering = 1;
    bytes += sizeof(uint32_t);
    offered -= sizeof(uint32_t);
  }
  if (!thread->gathering) {
    return;
  }
  size_t room = FLPathMost - thread->length;
  size_t taken = MIN(room, offered);
  memcpy(thread->path + thread->length, bytes, taken);
  thread->length = (uint16_t)(thread->length + taken);
  if ((phase & FLCodeEnd) == 0) {
    return;
  }
  thread->gathering = 0;
  size_t length = strnlen(thread->path, thread->length);
  if (thread->call == 0) {
    [self use:thread->path length:length by:program opened:NO];
    return;
  }
  if (thread->held > 0) {
    [self use:thread->kept length:thread->held by:program opened:NO];
  }
  memcpy(thread->kept, thread->path, length);
  thread->held = (uint16_t)length;
}

- (NSString *)run:(NSTimeInterval)seconds {
  if (FLTraceInUse()) {
    if (FLAnotherTraceRuns()) {
      return @"another finchlog trace is running";
    }
    FLTraceAsk(FLTraceEnable, 0, NULL, NULL);
    FLTraceAsk(FLTraceRemove, -1, NULL, NULL);
  }
  uint8_t *filter = calloc(1, FLTraceFilterBytes);
  FLTraceRecord *records = malloc((size_t)FLTraceRecords * sizeof(FLTraceRecord));
  static const uint32_t wanted[] = {0x040c, 0x010c, 0x0301, 0x0700, 0x0701, 0x0702};
  for (size_t index = 0; index < sizeof(wanted) / sizeof(wanted[0]); index++) {
    filter[wanted[index] / 8] |= (uint8_t)(1u << (wanted[index] % 8));
  }
  size_t filtered = FLTraceFilterBytes;
  NSString *problem = nil;
  if (filter == NULL || records == NULL) {
    problem = @"there is no memory for the trace";
  } else if (FLTraceAsk(FLTraceSetBuffer, FLTraceRecords, NULL, NULL) != 0 ||
             FLTraceAsk(FLTraceSetUp, -1, NULL, NULL) != 0) {
    problem = [NSString stringWithFormat:@"the kernel would not set up a trace: %s",
                                         strerror(errno)];
  } else if (FLTraceAsk(FLTraceFilter, -1, filter, &filtered) != 0) {
    problem = [NSString stringWithFormat:@"the kernel would not take the trace's filter: %s",
                                         strerror(errno)];
  }
  if (problem == nil) {
    [self readThreads];
    if (FLTraceAsk(FLTraceEnable, 1, NULL, NULL) != 0) {
      problem = [NSString stringWithFormat:@"the kernel would not start the trace: %s",
                                           strerror(errno)];
    }
  }
  NSTimeInterval begun = FLAwakeSeconds();
  BOOL last = NO;
  while (problem == nil && !last) {
    usleep(FLTracePause);
    last = FLTraceStopped || FLAwakeSeconds() - begun >= seconds;
    if (last) {
      FLTraceAsk(FLTraceEnable, 0, NULL, NULL);
    }
    size_t got = (size_t)FLTraceRecords * sizeof(FLTraceRecord);
    if (FLTraceAsk(FLTraceRead, -1, records, &got) != 0) {
      problem = [NSString stringWithFormat:@"the trace could not be read: %s", strerror(errno)];
      break;
    }
    got = MIN(got, (size_t)FLTraceRecords);
    @autoreleasepool {
      for (size_t index = 0; index < got; index++) {
        [self handle:&records[index]];
      }
    }
    _records += got;
  }
  _seconds = FLAwakeSeconds() - begun;
  FLTraceAsk(FLTraceEnable, 0, NULL, NULL);
  FLTraceAsk(FLTraceRemove, -1, NULL, NULL);
  free(filter);
  free(records);
  if (problem == nil) {
    _links = FLPortLinks(&_linked, &_closed);
  }
  return problem;
}

static NSMutableDictionary *FLBranch(NSMutableDictionary *tree, NSString *key) {
  NSMutableDictionary *branch = tree[key];
  if (![branch isKindOfClass:[NSDictionary class]]) {
    branch = [NSMutableDictionary new];
    tree[key] = branch;
  }
  return branch;
}

static NSMutableDictionary *FLLedgerToAddTo(void) {
  NSDictionary *saved = FLReadState(FLTracedState);
  if (saved.count == 0) {
    return [NSMutableDictionary new];
  }
  CFPropertyListRef copy = CFPropertyListCreateDeepCopy(kCFAllocatorDefault,
                                                        (__bridge CFDictionaryRef)saved,
                                                        kCFPropertyListMutableContainers);
  return CFBridgingRelease(copy) ?: [NSMutableDictionary new];
}

static NSArray<NSNumber *> *FLSummed(NSArray<NSNumber *> *before, NSArray<NSNumber *> *added) {
  NSMutableArray<NSNumber *> *sums = [NSMutableArray new];
  for (NSUInteger index = 0; index < added.count; index++) {
    unsigned long long old = index < before.count ? before[index].unsignedLongLongValue : 0;
    [sums addObject:@(old + added[index].unsignedLongLongValue)];
  }
  return sums;
}

- (void)mergeInto:(NSMutableDictionary *)ledger {
  NSDate *now = [NSDate date];
  NSMutableArray<NSString *> *known = [ledger[@"programs"] isKindOfClass:[NSArray class]]
    ? [ledger[@"programs"] mutableCopy]
    : [NSMutableArray new];
  NSMutableDictionary<NSString *, NSNumber *> *places = [NSMutableDictionary new];
  for (NSUInteger index = 0; index < known.count; index++) {
    places[known[index]] = @(index);
  }
  NSString * (^placed)(NSString *) = ^NSString *(NSString *program) {
    NSNumber *place = places[program];
    if (place == nil) {
      [known addObject:program];
      place = @(known.count - 1);
      places[program] = place;
    }
    return place.stringValue;
  };
  NSMutableDictionary *calls = FLBranch(ledger, @"calls");
  NSMutableDictionary *traps = FLBranch(ledger, @"traps");
  for (NSUInteger index = 0; index < _programs.count; index++) {
    FLTraceCounts *counts = [_counts pointerAtIndex:index];
    NSString *place = nil;
    for (uint32_t number = 0; number < FL_TRACE_CALLS; number++) {
      if (counts->calls[number] == 0 && counts->failed[number] == 0) {
        continue;
      }
      place = place ?: placed(_programs[index]);
      NSMutableDictionary *made = FLBranch(calls, place);
      NSString *name = FLSystemCallName(number);
      NSArray<NSNumber *> *before = made[name];
      NSArray<NSNumber *> *sums =
        FLSummed(before, @[ @(counts->calls[number]), @(counts->failed[number]) ]);
      NSNumber *error = counts->failed[number] > 0
        ? @(counts->error[number])
        : (before.count > 2 ? before[2] : @0);
      made[name] = @[ sums[0], sums[1], error ];
    }
    for (uint32_t number = 0; number < FL_TRACE_TRAPS; number++) {
      if (counts->traps[number] == 0) {
        continue;
      }
      place = place ?: placed(_programs[index]);
      NSMutableDictionary *made = FLBranch(traps, place);
      NSString *name = FLKernelTrapName(number);
      made[name] = @([made[name] unsignedLongLongValue] + counts->traps[number]);
    }
  }
  NSMutableDictionary *files = FLBranch(ledger, @"files");
  for (NSString *area in _files) {
    NSMutableDictionary *entry = FLBranch(files, area);
    NSMutableDictionary *by = FLBranch(entry, @"by");
    NSDictionary<NSNumber *, FLTraceUse *> *users = _files[area];
    for (NSNumber *program in users) {
      NSString *place = placed(_programs[program.unsignedIntegerValue]);
      by[place] = FLSummed(by[place], @[ @(users[program].opened), @(users[program].looked) ]);
    }
    entry[@"first"] = entry[@"first"] ?: now;
    entry[@"last"] = now;
  }
  NSMutableDictionary *links = FLBranch(ledger, @"links");
  for (NSString *holder in _links) {
    NSMutableDictionary *reached = FLBranch(links, placed(holder));
    for (NSString *owner in _links[holder]) {
      NSString *place = placed(owner);
      NSArray *before = reached[place];
      NSNumber *ports = _links[holder][owner];
      NSNumber *most = before.count > 3 && [before[3] compare:ports] == NSOrderedDescending
        ? before[3]
        : ports;
      reached[place] = @[
        before.count > 0 ? before[0] : now, now,
        @((before.count > 2 ? [before[2] unsignedLongLongValue] : 0) + 1), most
      ];
    }
  }
  ledger[@"programs"] = known;
  ledger[@"version"] = @1;
  ledger[@"began"] = ledger[@"began"] ?: now;
  ledger[@"saved"] = now;
  ledger[@"seconds"] = @([ledger[@"seconds"] doubleValue] + _seconds);
  ledger[@"windows"] = @([ledger[@"windows"] unsignedLongLongValue] + 1);
  ledger[@"records"] = @([ledger[@"records"] unsignedLongLongValue] + _records);
  ledger[@"lost"] = @([ledger[@"lost"] unsignedLongLongValue] + _lost);
  ledger[@"looks"] = @([ledger[@"looks"] unsignedLongLongValue] + (_links != nil ? 1 : 0));
  ledger[@"closed"] = @(_closed);
}

- (NSString *)describe:(int32_t)program {
  FLTraceCounts *counts = [_counts pointerAtIndex:(NSUInteger)program];
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"\n%@\n\nSystem calls\ncall\ttimes\tfailed\tlast error\n",
                     _programs[(NSUInteger)program]];
  NSMutableArray<NSNumber *> *numbers = [NSMutableArray new];
  for (uint32_t number = 0; number < FL_TRACE_CALLS; number++) {
    if (counts->calls[number] > 0 || counts->failed[number] > 0) {
      [numbers addObject:@(number)];
    }
  }
  [numbers sortUsingComparator:^NSComparisonResult(NSNumber *first, NSNumber *second) {
    uint32_t one = counts->calls[first.unsignedIntValue];
    uint32_t other = counts->calls[second.unsignedIntValue];
    return one == other ? [first compare:second]
                        : (one > other ? NSOrderedAscending : NSOrderedDescending);
  }];
  for (NSNumber *number in numbers) {
    uint32_t each = number.unsignedIntValue;
    NSString *error = counts->failed[each] == 0
      ? @""
      : [NSString stringWithFormat:@"%s (%u)", strerror(counts->error[each]),
                                   counts->error[each]];
    [text appendFormat:@"%@\t%u\t%u\t%@\n", FLSystemCallName(each), counts->calls[each],
                       counts->failed[each], error];
  }
  [text appendString:@"\nKernel traps\ntrap\ttimes\n"];
  for (uint32_t number = 0; number < FL_TRACE_TRAPS; number++) {
    if (counts->traps[number] > 0) {
      [text appendFormat:@"%@\t%u\n", FLKernelTrapName(number), counts->traps[number]];
    }
  }
  for (NSArray *pair in @[ @[ @"Files opened", _opened ], @[ @"Paths only looked at", _looked ] ]) {
    NSCountedSet<NSString *> *paths = pair[1];
    [text appendFormat:@"\n%@: %lu\n", pair[0], (unsigned long)paths.count];
    for (NSString *path in [paths.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
      [text appendFormat:@"%@\t%lu\n", path, (unsigned long)[paths countForObject:path]];
    }
  }
  return text;
}

- (NSString *)summary {
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"Traced for %@: %llu records from %lu programs, %llu stretches lost.\n",
                     FLFormatDuration(_seconds), _records, (unsigned long)_programs.count, _lost];
  [text appendFormat:@"Looked at the port tables of %lu programs; %lu could not be read.\n",
                     (unsigned long)_linked, (unsigned long)_closed];
  [text appendString:@"\nprogram\tsystem calls\tfailed\tkernel traps\tfiles opened\t"
                     @"paths looked at\n"];
  NSMutableArray<NSArray *> *rows = [NSMutableArray new];
  for (NSUInteger index = 0; index < _programs.count; index++) {
    FLTraceCounts *counts = [_counts pointerAtIndex:index];
    unsigned long long calls = 0, failed = 0, traps = 0;
    for (uint32_t number = 0; number < FL_TRACE_CALLS; number++) {
      calls += counts->calls[number];
      failed += counts->failed[number];
    }
    for (uint32_t number = 0; number < FL_TRACE_TRAPS; number++) {
      traps += counts->traps[number];
    }
    [rows addObject:@[
      @(calls), [NSString stringWithFormat:@"%@\t%llu\t%llu\t%llu\t%u\t%u\n", _programs[index],
                                           calls, failed, traps, counts->opened, counts->looked]
    ]];
  }
  [rows sortUsingComparator:^NSComparisonResult(NSArray *first, NSArray *second) {
    return [second[0] compare:first[0]];
  }];
  for (NSArray *row in rows) {
    [text appendString:row[1]];
  }
  if (self.detail != nil) {
    [text appendString:_detailed >= 0
                         ? [self describe:_detailed]
                         : [NSString stringWithFormat:@"\nNo program called %@ did anything "
                                                      @"while the trace ran.\n",
                                                      self.detail]];
  }
  return text;
}

@end

static NSDictionary<NSString *, NSDictionary *> *FLTable(NSDictionary *ledger, NSString *key) {
  NSDictionary *table = ledger[key];
  return [table isKindOfClass:[NSDictionary class]] ? table : @{};
}

static NSString *FLProgramAt(NSArray<NSString *> *programs, NSString *place) {
  NSUInteger index = (NSUInteger)place.integerValue;
  return index < programs.count ? programs[index] : @"";
}

static NSString *FLTraced(NSDictionary *ledger) {
  NSDate *began = [ledger[@"began"] isKindOfClass:[NSDate class]] ? ledger[@"began"] : nil;
  if (began == nil) {
    return @"Nothing has been traced yet. finchlog trace records for 20 seconds, and the "
           @"service does the same at regular times unless that is switched off.";
  }
  unsigned long long lost = [ledger[@"lost"] unsignedLongLongValue];
  NSString *missed = lost == 0
    ? @"none were lost"
    : [NSString stringWithFormat:@"some were lost in %@, because they came too fast",
                                 FLReportCount(lost, @"stretch", @"stretches")];
  return [NSString
    stringWithFormat:@"Gathered since %@ in %@ that ran for %@ in all, reading %@ records; %@.",
                     FLFormatDay(began),
                     FLReportCount([ledger[@"windows"] unsignedLongLongValue], @"trace",
                                   @"traces"),
                     FLFormatDuration([ledger[@"seconds"] doubleValue]), ledger[@"records"] ?: @0,
                     missed];
}

static NSString *FLNamed(NSArray<NSString *> *paths, NSUInteger most) {
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  for (NSString *path in paths) {
    if (names.count == most) {
      [names addObject:[NSString stringWithFormat:@"and %lu more",
                                                  (unsigned long)(paths.count - most)]];
      break;
    }
    [names addObject:path.lastPathComponent];
  }
  return [names componentsJoinedByString:@", "];
}

static NSComparator FLHeaviest(void) {
  return ^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult order = [second[@"weight"] compare:first[@"weight"]];
    return order != NSOrderedSame ? order : [first[@"title"] compare:second[@"title"]];
  };
}

static NSDictionary *FLWeighed(NSDictionary *row, unsigned long long weight) {
  NSMutableDictionary *weighed = [row mutableCopy];
  weighed[@"weight"] = @(weight);
  return weighed;
}

NSDictionary *FLCallsReport(FLReportSource source) {
  NSDictionary *ledger = source(FLTracedState);
  NSArray<NSString *> *programs = ledger[@"programs"] ?: @[];
  NSDictionary<NSString *, NSDictionary *> *calls = FLTable(ledger, @"calls");
  NSDictionary<NSString *, NSDictionary *> *traps = FLTable(ledger, @"traps");
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *callers =
    [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *failures = [NSMutableDictionary new];
  NSMutableArray<NSDictionary *> *perProgram = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *refused = [NSMutableArray new];
  NSMutableSet<NSString *> *places = [NSMutableSet setWithArray:calls.allKeys];
  [places addObjectsFromArray:traps.allKeys];
  for (NSString *place in places) {
    @autoreleasepool {
      NSString *program = FLProgramAt(programs, place);
      NSDictionary<NSString *, NSArray<NSNumber *> *> *made = calls[place] ?: @{};
      NSDictionary<NSString *, NSNumber *> *trapped = traps[place] ?: @{};
      unsigned long long all = 0;
      NSArray<NSString *> *names =
        [made.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *first,
                                                                     NSString *second) {
          NSComparisonResult order = [made[second][0] compare:made[first][0]];
          return order != NSOrderedSame ? order : [first compare:second];
        }];
      NSMutableArray<NSArray<NSString *> *> *facts = [NSMutableArray new];
      [facts addObject:@[ @"Program", program ]];
      for (NSString *name in names) {
        NSArray<NSNumber *> *counted = made[name];
        unsigned long long times = counted[0].unsignedLongLongValue;
        unsigned long long failed = counted.count > 1 ? counted[1].unsignedLongLongValue : 0;
        int error = counted.count > 2 ? counted[2].intValue : 0;
        all += times;
        NSMutableArray<NSString *> *users = callers[name] ?: [NSMutableArray new];
        [users addObject:program];
        callers[name] = users;
        totals[name] = @(totals[name].unsignedLongLongValue + times);
        failures[name] = @(failures[name].unsignedLongLongValue + failed);
        NSString *made = FLReportCount(times, @"time", @"times");
        NSString *said = failed == 0
          ? made
          : [NSString stringWithFormat:@"%@, %llu failed, last with %s", made, failed,
                                       strerror(error)];
        if (facts.count < FLFactsMost) {
          [facts addObject:@[ name, said ]];
        }
        for (size_t index = 0; index < sizeof(FLNotSupported) / sizeof(FLNotSupported[0]);
             index++) {
          if (failed > 0 && error == FLNotSupported[index]) {
            NSString *detail = [NSString stringWithFormat:@"%@ failed %llu of %@, last with %s",
                                                          name, failed, made, strerror(error)];
            [refused addObject:FLWeighed(FLReportRow(program.lastPathComponent, detail,
                                                     @[ @[ @"Program", program ] ]),
                                         failed)];
          }
        }
      }
      unsigned long long trappedAll = 0;
      NSMutableArray<NSString *> *trapsSaid = [NSMutableArray new];
      for (NSString *name in [trapped.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        trappedAll += trapped[name].unsignedLongLongValue;
        [trapsSaid addObject:[NSString stringWithFormat:@"%@ ×%@", name, trapped[name]]];
      }
      [facts addObject:@[ @"Kernel traps", [trapsSaid componentsJoinedByString:@", "] ]];
      NSString *detail = [NSString
        stringWithFormat:@"%@, %@ in all; %@",
                         FLReportCount(names.count, @"system call", @"different system calls"),
                         FLReportCount(all, @"call", @"calls"),
                         FLReportCount(trappedAll, @"kernel trap", @"kernel traps")];
      [perProgram addObject:FLWeighed(FLReportRow(program.lastPathComponent, detail, facts),
                                      all + trappedAll)];
    }
  }
  NSMutableArray<NSDictionary *> *perCall = [NSMutableArray new];
  for (NSString *name in callers) {
    NSArray<NSString *> *users = [callers[name] sortedArrayUsingSelector:@selector(compare:)];
    NSString *detail = [NSString
      stringWithFormat:@"made by %@, %@, %@ failed: %@",
                       FLReportCount(users.count, @"program", @"programs"),
                       FLReportCount(totals[name].unsignedLongLongValue, @"time", @"times"),
                       failures[name], FLNamed(users, FLProgramsListed)];
    [perCall addObject:FLWeighed(FLReportRow(name, detail,
                                             @[ @[ @"Made by", FLNamed(users, FLFactsMost) ] ]),
                                 users.count)];
  }
  NSMutableArray<NSDictionary *> *unused = [NSMutableArray new];
  for (NSString *name in FLSystemCallNames()) {
    if (callers[name] == nil) {
      [unused addObject:FLReportRow(name, @"", nil)];
    }
  }
  [perProgram sortUsingComparator:FLHeaviest()];
  [perCall sortUsingComparator:FLHeaviest()];
  [refused sortUsingComparator:FLHeaviest()];
  NSString *meaning =
    @"A system call is a request a program makes of the kernel, and a kernel trap is the older "
    @"Mach kind of the same. What a program calls inside its own libraries cannot be seen from "
    @"outside it; these are the calls that cross into the kernel.";
  return @{
    @"title" : FLReportTitle(@"calls"),
    @"made" : [NSDate date],
    @"notes" : @[ FLTraced(ledger), meaning ],
    @"sections" : @[
      FLReportSection(@"Calls the kernel refused as not supported",
                      @"A program that still asks for something this kernel does not do.",
                      refused),
      FLReportSection(@"Programs, and the calls each made", nil, perProgram),
      FLReportSection(@"System calls, and how many programs made them", nil, perCall),
      FLReportSection(@"System calls nothing made while tracing",
                      callers.count == 0 ? @"Nothing has been traced yet." : nil, unused),
    ],
  };
}

static NSString *FLUsesSaid(NSArray<NSString *> *programs, NSDictionary *by,
                            NSUInteger most, unsigned long long *opened,
                            unsigned long long *looked, NSMutableArray<NSString *> *users) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  NSArray<NSString *> *places = [by.allKeys sortedArrayUsingComparator:^(NSString *first,
                                                                         NSString *second) {
    NSComparisonResult order = [by[second][0] compare:by[first][0]];
    return order != NSOrderedSame ? order : [by[second][1] compare:by[first][1]];
  }];
  for (NSString *place in places) {
    NSArray<NSNumber *> *counted = by[place];
    NSString *program = FLProgramAt(programs, place);
    *opened += counted[0].unsignedLongLongValue;
    *looked += counted.count > 1 ? counted[1].unsignedLongLongValue : 0;
    [users addObject:program];
    if (parts.count < most) {
      [parts addObject:[NSString stringWithFormat:@"%@ (opened %@, looked at %@)",
                                                  program.lastPathComponent, counted[0],
                                                  counted.count > 1 ? counted[1] : @0]];
    }
  }
  if (places.count > most) {
    [parts addObject:[NSString stringWithFormat:@"and %lu more",
                                                (unsigned long)(places.count - most)]];
  }
  return [parts componentsJoinedByString:@", "];
}

NSDictionary *FLFilesReport(FLReportSource source) {
  NSDictionary *ledger = source(FLTracedState);
  NSArray<NSString *> *programs = ledger[@"programs"] ?: @[];
  NSDictionary<NSString *, NSDictionary *> *files = FLTable(ledger, @"files");
  NSMutableArray<NSDictionary *> *opened = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *looked = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *unplaced = [NSMutableArray new];
  for (NSString *area in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    @autoreleasepool {
      NSDictionary *entry = files[area];
      unsigned long long opens = 0, looks = 0;
      NSMutableArray<NSString *> *users = [NSMutableArray new];
      NSString *said = FLUsesSaid(programs, entry[@"by"], FLFactsMost, &opens, &looks, users);
      NSDate *last = entry[@"last"];
      NSString *detail = [NSString
        stringWithFormat:@"opened %@, looked at %@ by %@: %@",
                         FLReportCount(opens, @"time", @"times"),
                         FLReportCount(looks, @"time", @"times"),
                         FLReportCount(users.count, @"program", @"programs"),
                         FLNamed(users, FLProgramsListed)];
      NSDictionary *row = FLReportRow(area, detail, @[
        @[ @"By", said ],
        @[ @"Last seen", [last isKindOfClass:[NSDate class]] ? FLFormatDay(last) : @"" ],
      ]);
      [![area hasPrefix:@"/"] ? unplaced : (opens > 0 ? opened : looked) addObject:row];
    }
  }
  NSMutableArray<NSDictionary *> *untouched = [NSMutableArray new];
  NSSet<NSString *> *kinds = [NSSet setWithArray:@[ @"app", @"framework", @"bundle", @"program" ]];
  @autoreleasepool {
    for (NSDictionary *item in files.count == 0 ? @[] : source(FLInventoryState)[@"items"]) {
      NSString *path = item[@"path"];
      uint64_t bytes = [item[@"bytes"] unsignedLongLongValue];
      if (![kinds containsObject:item[@"kind"] ?: @""] || [item[@"data"] boolValue] ||
          [item[@"inside"] length] > 0 || path == nil || files[path] != nil || bytes == 0) {
        continue;
      }
      NSString *detail = [NSString stringWithFormat:@"%@ · %@", FLFormatBytes(bytes), path];
      [untouched addObject:FLWeighed(FLReportRow(item[@"name"] ?: path.lastPathComponent, detail,
                                                 @[
                                                   @[ @"Kind", item[@"kind"] ?: @"" ],
                                                   @[ @"Path", path ],
                                                 ]),
                                     bytes)];
    }
  }
  [untouched sortUsingComparator:FLHeaviest()];
  NSString *meaning =
    @"Each file a program reaches is counted under the installed thing it is inside, or under "
    @"its folder when it is inside none. Opened means an open or a start that worked; looked at "
    @"means the path was only checked. Finch Logs' own reading is left out.";
  NSString *limits =
    @"The kernel's record keeps the last 92 characters of a path, so longer ones can only be "
    @"placed when a folder in them has a name no other installed thing has.";
  return @{
    @"title" : FLReportTitle(@"opened"),
    @"made" : [NSDate date],
    @"notes" : @[ FLTraced(ledger), meaning, limits ],
    @"sections" : @[
      FLReportSection(@"Had files opened", nil, opened),
      FLReportSection(@"Only looked at", nil, looked),
      FLReportSection(@"Could not be placed", nil, unplaced),
      FLReportSection(@"Installed and not touched while tracing",
                      @"Apps, frameworks, bundles and programs on the system volume in which no "
                      @"traced program reached a file, largest first. Tracing only runs part of "
                      @"the time, so this shows what is not in everyday use, not what is never "
                      @"used.",
                      untouched),
    ],
  };
}

NSDictionary *FLTalksReport(FLReportSource source) {
  NSDictionary *ledger = source(FLTracedState);
  NSArray<NSString *> *programs = ledger[@"programs"] ?: @[];
  NSDictionary<NSString *, NSDictionary *> *links = FLTable(ledger, @"links");
  unsigned long long looks = [ledger[@"looks"] unsignedLongLongValue];
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *holders =
    [NSMutableDictionary new];
  NSMutableArray<NSDictionary *> *reaching = [NSMutableArray new];
  for (NSString *place in links) {
    @autoreleasepool {
      NSString *holder = FLProgramAt(programs, place);
      NSDictionary<NSString *, NSArray *> *reached = links[place];
      NSMutableArray<NSString *> *owners = [NSMutableArray new];
      NSMutableArray<NSArray<NSString *> *> *facts = [NSMutableArray new];
      [facts addObject:@[ @"Program", holder ]];
      for (NSString *other in reached) {
        NSString *owner = FLProgramAt(programs, other);
        NSArray *seen = reached[other];
        [owners addObject:owner];
        NSMutableArray<NSString *> *known = holders[owner] ?: [NSMutableArray new];
        [known addObject:holder];
        holders[owner] = known;
        if (facts.count < FLFactsMost) {
          [facts addObject:@[
            owner.lastPathComponent,
            [NSString stringWithFormat:@"up to %@, in %@ of %@, last %@",
                                       FLReportCount(seen.count > 3
                                                       ? [seen[3] unsignedLongLongValue]
                                                       : 0,
                                                     @"port", @"ports"),
                                       seen.count > 2 ? seen[2] : @0,
                                       FLReportCount(looks, @"look", @"looks"),
                                       seen.count > 1 && [seen[1] isKindOfClass:[NSDate class]]
                                         ? FLFormatDay(seen[1])
                                         : @""]
          ]];
        }
      }
      [owners sortUsingSelector:@selector(compare:)];
      NSString *detail = [NSString
        stringWithFormat:@"holds connections to %@: %@",
                         FLReportCount(owners.count, @"program", @"programs"),
                         FLNamed(owners, FLProgramsListed)];
      [reaching addObject:FLWeighed(FLReportRow(holder.lastPathComponent, detail, facts),
                                    owners.count)];
    }
  }
  NSMutableArray<NSDictionary *> *reachedBy = [NSMutableArray new];
  for (NSString *owner in holders) {
    NSArray<NSString *> *known = [holders[owner] sortedArrayUsingSelector:@selector(compare:)];
    NSString *detail = [NSString
      stringWithFormat:@"%@ to it: %@",
                       known.count == 1
                         ? @"1 program holds a connection"
                         : [NSString stringWithFormat:@"%lu programs hold connections",
                                                      (unsigned long)known.count],
                       FLNamed(known, FLProgramsListed)];
    [reachedBy addObject:FLWeighed(FLReportRow(owner.lastPathComponent, detail, @[
                                     @[ @"Program", owner ],
                                     @[ @"Held by", FLNamed(known, FLFactsMost) ],
                                   ]),
                                   known.count)];
  }
  [reaching sortUsingComparator:FLHeaviest()];
  [reachedBy sortUsingComparator:FLHeaviest()];
  NSString *meaning =
    @"A program holds a connection to another when it has the right to send messages to a "
    @"port the other receives on. That is how apps and services talk to each other, so the "
    @"second list shows who would notice if a service were gone. launchd receives for every "
    @"service that has not started yet.";
  NSString *limits =
    @"This is read from each program's table of ports at the end of every trace, so it shows "
    @"who was connected at those moments, not each message that was sent.";
  return @{
    @"title" : FLReportTitle(@"talks"),
    @"made" : [NSDate date],
    @"notes" : @[ FLTraced(ledger), meaning, limits ],
    @"sections" : @[
      FLReportSection(@"Programs others hold connections to", nil, reachedBy),
      FLReportSection(@"Programs, and what each holds connections to", nil, reaching),
    ],
  };
}

int FLTraceCommand(NSArray<NSString *> *arguments) {
  if (getuid() != 0) {
    fprintf(stderr, "finchlog: only root may trace\n");
    return 1;
  }
  NSUInteger timed = [arguments indexOfObject:@"--for"];
  NSUInteger named = [arguments indexOfObject:@"--name"];
  NSTimeInterval seconds = timed != NSNotFound && timed + 1 < arguments.count
    ? arguments[timed + 1].doubleValue
    : FLTraceDefault;
  seconds = MIN(MAX(seconds, 1), FLTraceLongest);
  BOOL quiet = [arguments containsObject:@"--quiet"];
  FLTraceSession *session = [FLTraceSession new];
  if (named != NSNotFound && named + 1 < arguments.count) {
    session.detail = arguments[named + 1];
  }
  signal(SIGINT, FLTraceStop);
  signal(SIGTERM, FLTraceStop);
  signal(SIGHUP, FLTraceStop);
  if (!quiet) {
    fprintf(stderr, "Tracing for %s. Interrupt to stop sooner.\n",
            FLFormatDuration(seconds).UTF8String);
  }
  NSString *problem = [session run:seconds];
  if (problem != nil) {
    fprintf(stderr, "finchlog: %s\n", problem.UTF8String);
    return 1;
  }
  NSMutableDictionary *ledger = FLLedgerToAddTo();
  [session mergeInto:ledger];
  BOOL saved = FLWriteCompactState(FLTracedState, ledger);
  NSMutableDictionary<NSString *, NSDictionary *> *read = [NSMutableDictionary new];
  read[FLTracedState] = ledger;
  FLReportSource source = ^NSDictionary *(NSString *name) {
    if (read[name] == nil) {
      read[name] = FLReadState(name) ?: @{};
    }
    return read[name];
  };
  for (NSString *kind in FLTracedReportKinds()) {
    @autoreleasepool {
      NSDictionary *report = FLBuildReport(kind, source);
      saved = FLWriteCompactState(FLReportState(kind), report) && saved;
      if ([arguments containsObject:@"--snapshot"]) {
        NSUInteger reasoned = [arguments indexOfObject:@"--reason"];
        NSString *why = reasoned != NSNotFound && reasoned + 1 < arguments.count
          ? arguments[reasoned + 1]
          : @"it was asked for";
        NSString *text = [FLSnapshotHeading(kind, why, [NSDate date])
          stringByAppendingString:FLReportText(report)];
        [[FLStore shared] saveSnapshot:kind
                                pieces:^BOOL(void (^write)(NSString *piece)) {
                                  write(text);
                                  return YES;
                                }];
      }
    }
  }
  if (!quiet) {
    NSData *text = [[session summary] dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(text.bytes, 1, text.length, stdout);
  }
  if (!saved) {
    fprintf(stderr, "finchlog: what the trace found could not be saved\n");
    return 1;
  }
  return 0;
}
