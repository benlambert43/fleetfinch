#import "FLInventory.h"

#import <fcntl.h>
#import <fts.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <notify.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FLCollect.h"
#import "FLCommon.h"
#import "FLDependencyIndex.h"
#import "FLMachO.h"
#import "FLStatus.h"
#import "FLSystemInfo.h"

static const uint64_t FLBlockBytes = 512;
static const size_t FLHeadBytes = 512;
static const size_t FLAreaDepth = 3;
static const size_t FLSystemAreaDepth = 4;
static const char *const FLSystemLibrary = "/System/Library/";
static NSString *const FLOverridesFile = @"/var/db/com.apple.xpc.launchd/disabled.plist";
static NSString *const FLStockOrigin = @"iOS";
static NSString *const FLAddedOrigin = @"added later";
static NSString *const FLStorageKind = @"storage";

typedef NS_ENUM(NSInteger, FLBinaryKind) {
  FLBinaryNone = 0,
  FLBinaryProgram,
  FLBinaryScript,
  FLBinaryLibrary,
};

NSArray<NSString *> *FLInventoryKinds(void) {
  return @[
    @"app", @"extension", @"service", @"xpc", @"framework", @"bundle", @"program", @"library"
  ];
}

static NSDictionary<NSString *, NSArray<NSString *> *> *FLKindWords(void) {
  return @{
    @"app" : @[ @"Apps", @"app", @"apps" ],
    @"extension" : @[ @"App Extensions", @"app extension", @"app extensions" ],
    @"service" : @[ @"Launch Services", @"launch service", @"launch services" ],
    @"xpc" : @[ @"XPC Services", @"XPC service", @"XPC services" ],
    @"framework" : @[ @"Frameworks", @"framework", @"frameworks" ],
    @"bundle" : @[ @"Plug-ins and Bundles", @"bundle", @"bundles" ],
    @"program" : @[ @"Programs", @"program", @"programs" ],
    @"library" : @[ @"Libraries", @"library", @"libraries" ],
  };
}

NSString *FLInventoryKindTitle(NSString *kind) {
  return FLKindWords()[kind].firstObject ?: kind;
}

NSString *FLInventoryKindNamed(NSString *word) {
  NSDictionary<NSString *, NSString *> *words = @{
    @"apps" : @"app",
    @"extensions" : @"extension",
    @"services" : @"service",
    @"xpc" : @"xpc",
    @"frameworks" : @"framework",
    @"bundles" : @"bundle",
    @"programs" : @"program",
    @"libraries" : @"library",
    @"storage" : FLStorageKind,
  };
  return words[word.lowercaseString];
}

static NSString *FLKindCount(NSString *kind, NSUInteger count) {
  NSArray<NSString *> *words = FLKindWords()[kind];
  NSString *noun = words == nil ? kind : words[count == 1 ? 1 : 2];
  return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, noun];
}

static NSString *FLText(id value) {
  return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

static NSArray<NSString *> *FLTexts(id value) {
  NSMutableArray<NSString *> *texts = [NSMutableArray new];
  if ([value isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray *)value) {
      NSString *text = FLText(item);
      if (text != nil) {
        [texts addObject:text];
      }
    }
  }
  return texts;
}

static void FLPut(NSMutableDictionary *record, NSString *key, id value) {
  if (value != nil) {
    record[key] = value;
  }
}

static void FLPutList(NSMutableDictionary *record, NSString *key, NSArray *values) {
  if (values.count > 0) {
    record[key] = values;
  }
}

static BOOL FLEndsWith(const char *name, const char *ending) {
  size_t length = strlen(name);
  size_t tail = strlen(ending);
  return length >= tail && strcmp(name + length - tail, ending) == 0;
}

static FLBinaryKind FLProbeBinary(const char *path, NSString **interpreter) {
  int handle = open(path, O_RDONLY);
  if (handle < 0) {
    return FLBinaryNone;
  }
  uint8_t head[FLHeadBytes + 1] = {0};
  ssize_t count = pread(handle, head, FLHeadBytes, 0);
  FLBinaryKind kind = FLBinaryNone;
  if (count > 2 && head[0] == '#' && head[1] == '!') {
    char *start = (char *)head + 2;
    while (*start == ' ' || *start == '\t') {
      start++;
    }
    start[strcspn(start, " \t\r\n")] = '\0';
    *interpreter = [NSString stringWithUTF8String:start];
    kind = FLBinaryScript;
  } else if (count >= (ssize_t)sizeof(struct mach_header)) {
    struct mach_header header;
    memcpy(&header, head, sizeof(header));
    if (header.magic == FAT_CIGAM &&
        count >= (ssize_t)(sizeof(struct fat_header) + sizeof(struct fat_arch))) {
      struct fat_arch first;
      memcpy(&first, head + sizeof(struct fat_header), sizeof(first));
      off_t inner = (off_t)OSSwapBigToHostInt32(first.offset);
      if (pread(handle, &header, sizeof(header), inner) != (ssize_t)sizeof(header)) {
        header.magic = 0;
      }
    }
    if (header.magic == MH_MAGIC || header.magic == MH_MAGIC_64) {
      if (header.filetype == MH_EXECUTE) {
        kind = FLBinaryProgram;
      } else if (header.filetype == MH_DYLIB || header.filetype == MH_BUNDLE ||
                 header.filetype == MH_DYLINKER) {
        kind = FLBinaryLibrary;
      }
    }
  }
  close(handle);
  return kind;
}

static NSString *FLFolderKind(const char *name, const char *path) {
  const char *dot = strrchr(name, '.');
  if (dot == NULL || dot == name || dot[1] == '\0') {
    return nil;
  }
  const char *extension = dot + 1;
  static const char *const skipped[] = {"lproj", "storyboardc", "momd", "nib"};
  for (size_t index = 0; index < sizeof(skipped) / sizeof(skipped[0]); index++) {
    if (strcmp(extension, skipped[index]) == 0) {
      return nil;
    }
  }
  if (strcmp(extension, "app") == 0) {
    return @"app";
  }
  if (strcmp(extension, "appex") == 0) {
    return @"extension";
  }
  if (strcmp(extension, "xpc") == 0) {
    return @"xpc";
  }
  if (strcmp(extension, "framework") == 0) {
    return @"framework";
  }
  if (strcmp(extension, "bundle") == 0 || strcmp(extension, "plugin") == 0 ||
      strcmp(extension, "kext") == 0) {
    return @"bundle";
  }
  char file[PATH_MAX];
  struct stat info;
  if (snprintf(file, sizeof(file), "%s/Info.plist", path) < (int)sizeof(file) &&
      lstat(file, &info) == 0 && S_ISREG(info.st_mode)) {
    return @"bundle";
  }
  return nil;
}

static NSDictionary *FLBundlePlist(NSString *bundle) {
  NSArray<NSString *> *places = @[
    @"Info.plist", @"Resources/Info.plist", @"Contents/Info.plist",
    @"Versions/A/Resources/Info.plist"
  ];
  for (NSString *place in places) {
    NSString *file = [bundle stringByAppendingPathComponent:place];
    if (access(file.fileSystemRepresentation, R_OK) != 0) {
      continue;
    }
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:file];
    if ([plist isKindOfClass:[NSDictionary class]]) {
      return plist;
    }
  }
  return @{};
}

static NSString *FLBinaryKey(NSString *kind) {
  return [@[ @"app", @"extension", @"xpc" ] containsObject:kind] ? @"program" : @"binary";
}

static NSMutableDictionary *FLDescribeBundle(NSString *path, NSString *kind,
                                             NSString **executable) {
  NSDictionary *info = FLBundlePlist(path);
  NSString *folder = path.lastPathComponent;
  NSString *plain = folder.stringByDeletingPathExtension;
  NSMutableDictionary *record = [NSMutableDictionary new];
  record[@"kind"] = kind;
  record[@"path"] = path;
  record[@"name"] = plain;
  FLPut(record, @"id", FLText(info[@"CFBundleIdentifier"]));
  FLPut(record, @"version",
        FLText(info[@"CFBundleShortVersionString"]) ?: FLText(info[@"CFBundleVersion"]));
  *executable = FLText(info[@"CFBundleExecutable"]);
  if ([kind isEqualToString:@"app"]) {
    NSDictionary *shown = FLBundleInfo(path);
    FLPut(record, @"name", FLText(shown[@"name"]));
    BOOL user = [path hasPrefix:@"/private/var/"] || [path hasPrefix:@"/var/"];
    record[@"type"] = user ? @"user" : @"system";
    if ([shown[@"hidden"] boolValue]) {
      record[@"hidden"] = @YES;
    }
    NSMutableArray<NSString *> *schemes = [NSMutableArray new];
    if ([info[@"CFBundleURLTypes"] isKindOfClass:[NSArray class]]) {
      for (id type in (NSArray *)info[@"CFBundleURLTypes"]) {
        if ([type isKindOfClass:[NSDictionary class]]) {
          [schemes addObjectsFromArray:FLTexts(type[@"CFBundleURLSchemes"])];
        }
      }
    }
    FLPutList(record, @"schemes", schemes);
    FLPutList(record, @"background", FLTexts(info[@"UIBackgroundModes"]));
    FLPutList(record, @"machServices", FLTexts(info[@"SBMachServices"]));
  } else if ([kind isEqualToString:@"extension"]) {
    FLPut(record, @"name", FLText(FLBundleInfo(path)[@"name"]));
    NSDictionary *extension = info[@"NSExtension"];
    if ([extension isKindOfClass:[NSDictionary class]]) {
      FLPut(record, @"point", FLText(extension[@"NSExtensionPointIdentifier"]));
    }
  } else if ([kind isEqualToString:@"xpc"]) {
    NSDictionary *service = info[@"XPCService"];
    if ([service isKindOfClass:[NSDictionary class]]) {
      FLPut(record, @"type", FLText(service[@"ServiceType"]));
    }
  } else if ([kind isEqualToString:@"framework"]) {
    if (*executable == nil) {
      *executable = plain;
    }
  } else {
    record[@"type"] = folder.pathExtension;
    record[@"group"] = path.stringByDeletingLastPathComponent;
  }
  return record;
}

static NSString *FLDescribeHeld(NSCountedSet<NSString *> *held) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  for (NSString *kind in FLInventoryKinds()) {
    NSUInteger count = [held countForObject:kind];
    if (count > 0) {
      [parts addObject:FLKindCount(kind, count)];
    }
  }
  return [parts componentsJoinedByString:@", "];
}

@interface FLOpenItem : NSObject

@property(nonatomic, strong) NSMutableDictionary *record;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSCountedSet<NSString *> *holds;
@property(nonatomic) char *executable;
@property(nonatomic) int level;
@property(nonatomic) uint64_t own;
@property(nonatomic) uint64_t nested;
@property(nonatomic) NSUInteger files;

@end

@implementation FLOpenItem

- (void)dealloc {
  free(_executable);
}

@end

@interface FLTally : NSObject

@property(nonatomic) uint64_t bytes;
@property(nonatomic) NSUInteger files;

@end

@implementation FLTally
@end

@interface FLInventoryWalk : NSObject

@property(nonatomic, strong, readonly) NSMutableArray<NSMutableDictionary *> *items;
@property(nonatomic, strong, readonly) NSMutableDictionary<NSString *, FLTally *> *areas;
@property(nonatomic, strong, readonly)
  NSMutableDictionary<NSString *, NSMutableDictionary *> *awaited;
@property(nonatomic, readonly) uint64_t bytes;
@property(nonatomic, readonly) NSUInteger files;
@property(nonatomic, readonly) NSUInteger folders;
@property(nonatomic, readonly) NSUInteger unread;

- (void)walk:(NSString *)root system:(BOOL)system;

@end

@implementation FLInventoryWalk {
  NSMutableArray<FLOpenItem *> *_open;
  NSMutableSet<NSNumber *> *_linked;
  char _area[PATH_MAX];
  FLTally *_tally;
  BOOL _system;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _items = [NSMutableArray new];
    _areas = [NSMutableDictionary new];
    _awaited = [NSMutableDictionary new];
    _open = [NSMutableArray new];
    _linked = [NSMutableSet new];
  }
  return self;
}

- (NSString *)pathOf:(FTSENT *)entry {
  return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:entry->fts_path
                                                                     length:entry->fts_pathlen];
}

- (void)enter:(FTSENT *)entry {
  _folders += _system ? 1 : 0;
  NSString *kind = FLFolderKind(entry->fts_name, entry->fts_path);
  NSString *path = kind == nil ? nil : [self pathOf:entry];
  if (path == nil) {
    return;
  }
  NSString *executable = nil;
  FLOpenItem *item = [FLOpenItem new];
  item.path = path;
  item.level = entry->fts_level;
  item.holds = [NSCountedSet new];
  item.record = FLDescribeBundle(path, kind, &executable);
  if (executable != nil) {
    item.executable = strdup(executable.fileSystemRepresentation);
  }
  FLPut(item.record, @"inside", _open.lastObject.path);
  if (!_system) {
    item.record[@"data"] = @YES;
  }
  [_open addObject:item];
  entry->fts_number = 1;
}

- (void)leave:(FTSENT *)entry {
  if (entry->fts_number != 1 || _open.count == 0) {
    return;
  }
  FLOpenItem *item = _open.lastObject;
  [_open removeLastObject];
  NSMutableDictionary *record = item.record;
  uint64_t total = item.own + item.nested;
  record[@"bytes"] = @(total);
  if (item.nested > 0) {
    record[@"own"] = @(item.own);
  }
  record[@"files"] = @(item.files);
  if (item.holds.count > 0) {
    record[@"holds"] = FLDescribeHeld(item.holds);
  }
  if (item.executable != NULL && record[FLBinaryKey(record[@"kind"])] == nil) {
    NSString *name = [NSString stringWithUTF8String:item.executable];
    if (name != nil) {
      _awaited[[item.path stringByAppendingPathComponent:name]] = record;
      NSString *versioned = [@"Versions/A" stringByAppendingPathComponent:name];
      _awaited[[item.path stringByAppendingPathComponent:versioned]] = record;
    }
  }
  FLOpenItem *parent = _open.lastObject;
  parent.nested += total;
  parent.files += item.files;
  [parent.holds addObject:record[@"kind"]];
  [_items addObject:record];
}

- (BOOL)isMainBinary:(FTSENT *)entry of:(FLOpenItem *)item {
  if (item.executable == NULL || strcmp(entry->fts_name, item.executable) != 0) {
    return NO;
  }
  if (entry->fts_level == item.level + 1) {
    return YES;
  }
  return entry->fts_level == item.level + 3 && entry->fts_parent != NULL &&
         strcmp(entry->fts_parent->fts_name, "MacOS") == 0;
}

- (void)count:(uint64_t)bytes inAreaOf:(const char *)path {
  size_t depth = strncmp(path, FLSystemLibrary, strlen(FLSystemLibrary)) == 0
    ? FLSystemAreaDepth
    : FLAreaDepth;
  size_t length = 0;
  size_t parts = 0;
  for (size_t index = 1; path[index] != '\0' && parts < depth; index++) {
    if (path[index] == '/') {
      parts++;
      length = index;
    }
  }
  if (length == 0) {
    length = 1;
  }
  if (_tally == nil || strlen(_area) != length || strncmp(_area, path, length) != 0) {
    memcpy(_area, path, length);
    _area[length] = '\0';
    NSString *area = [NSString stringWithUTF8String:_area] ?: @"/";
    _tally = _areas[area];
    if (_tally == nil) {
      _tally = [FLTally new];
      _areas[area] = _tally;
    }
  }
  _tally.bytes += bytes;
  _tally.files++;
}

- (BOOL)record:(FTSENT *)entry bytes:(uint64_t)bytes inside:(FLOpenItem *)item {
  NSString *interpreter = nil;
  FLBinaryKind binary = FLProbeBinary(entry->fts_path, &interpreter);
  NSString *path = binary == FLBinaryNone ? nil : [self pathOf:entry];
  if (path == nil) {
    return NO;
  }
  NSMutableDictionary *record = [NSMutableDictionary new];
  record[@"kind"] = binary == FLBinaryLibrary ? @"library" : @"program";
  record[@"path"] = path;
  record[@"name"] = path.lastPathComponent;
  record[@"bytes"] = @(bytes);
  if (binary == FLBinaryScript) {
    record[@"type"] = @"script";
    FLPut(record, @"interpreter", interpreter);
  }
  FLPut(record, @"inside", item.path);
  if (!_system) {
    record[@"data"] = @YES;
  }
  [_items addObject:record];
  item.nested += bytes;
  [item.holds addObject:record[@"kind"]];
  return YES;
}

- (void)file:(FTSENT *)entry {
  struct stat *info = entry->fts_statp;
  uint64_t bytes = (uint64_t)info->st_blocks * FLBlockBytes;
  if (info->st_nlink > 1) {
    NSNumber *node = @((unsigned long long)info->st_ino);
    if ([_linked containsObject:node]) {
      bytes = 0;
    } else {
      [_linked addObject:node];
    }
  }
  if (_system) {
    _files++;
    _bytes += bytes;
  }
  FLOpenItem *item = _open.lastObject;
  item.files++;
  BOOL regular = entry->fts_info == FTS_F;
  if (regular && item != nil && [self isMainBinary:entry of:item]) {
    FLPut(item.record, FLBinaryKey(item.record[@"kind"]), [self pathOf:entry]);
    item.own += bytes;
    return;
  }
  BOOL runs = (info->st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
  if (regular && (runs || FLEndsWith(entry->fts_name, ".dylib")) &&
      [self record:entry bytes:bytes inside:item]) {
    return;
  }
  if (item != nil) {
    item.own += bytes;
  } else if (_system) {
    [self count:bytes inAreaOf:entry->fts_path];
  }
}

- (void)walk:(NSString *)root system:(BOOL)system {
  _system = system;
  [_linked removeAllObjects];
  [_open removeAllObjects];
  _tally = nil;
  char *paths[] = {(char *)root.fileSystemRepresentation, NULL};
  FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
  if (tree == NULL) {
    return;
  }
  FTSENT *entry = NULL;
  while ((entry = fts_read(tree)) != NULL) {
    @autoreleasepool {
      switch (entry->fts_info) {
        case FTS_D:
          [self enter:entry];
          break;
        case FTS_DP:
          [self leave:entry];
          break;
        case FTS_DNR:
          _unread++;
          [self leave:entry];
          break;
        case FTS_ERR:
        case FTS_NS:
          _unread++;
          break;
        case FTS_F:
        case FTS_SL:
        case FTS_SLNONE:
        case FTS_DEFAULT:
          [self file:entry];
          break;
        default:
          break;
      }
    }
  }
  fts_close(tree);
}

@end

static NSArray<NSMutableDictionary *> *FLSharedCacheImages(uint64_t *bytes) {
  NSMutableArray<NSMutableDictionary *> *images = [NSMutableArray new];
  for (FLSharedCache *cache in [FLSharedCache caches]) {
    *bytes += cache.bytes;
    for (NSDictionary *found in cache.images) {
      @autoreleasepool {
        FLImage *read = FLReadImage(cache.handle, [found[@"offset"] unsignedLongLongValue]);
        NSMutableDictionary *image = [NSMutableDictionary new];
        image[@"path"] = found[@"path"];
        image[@"cached"] = @(read.segmentBytes);
        FLPut(image, @"aliases", found[@"aliases"]);
        [images addObject:image];
      }
    }
  }
  return images;
}

static NSDictionary<NSString *, NSString *> *FLPackageOwners(void) {
  NSMutableDictionary *owners = [NSMutableDictionary new];
  NSString *folder = @"/var/lib/dpkg/info";
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL];
  for (NSString *name in names) {
    if (![name.pathExtension isEqualToString:@"list"]) {
      continue;
    }
    @autoreleasepool {
      NSString *package = name.stringByDeletingPathExtension;
      NSRange colon = [package rangeOfString:@":"];
      if (colon.location != NSNotFound) {
        package = [package substringToIndex:colon.location];
      }
      NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
      for (NSString *line in [FLStringFromData(data) componentsSeparatedByString:@"\n"]) {
        if (line.length > 1) {
          owners[line] = package;
        }
      }
    }
  }
  return owners;
}

NSString *FLOriginOf(NSDictionary<NSString *, NSString *> *owners, NSArray<NSString *> *paths) {
  for (NSString *path in paths) {
    NSString *owner = path.length > 0 ? owners[path] : nil;
    if (owner != nil) {
      return owner;
    }
  }
  BOOL placed = NO;
  for (NSString *path in paths) {
    if ([path hasPrefix:@"/var/"] || [path hasPrefix:@"/private/var/"]) {
      return FLAddedOrigin;
    }
    placed = placed || [path hasPrefix:@"/"];
  }
  return placed ? FLStockOrigin : @"";
}

static NSArray<NSString *> *FLSocketNames(id sockets) {
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  if (![sockets isKindOfClass:[NSDictionary class]]) {
    return names;
  }
  NSArray *keys = [[(NSDictionary *)sockets allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *key in keys) {
    id value = sockets[key];
    NSArray *listeners = [value isKindOfClass:[NSArray class]] ? value : @[ value ];
    for (id listener in listeners) {
      if (![listener isKindOfClass:[NSDictionary class]]) {
        continue;
      }
      NSString *path = FLText(listener[@"SockPathName"]);
      id service = listener[@"SockServiceName"];
      NSString *name = path;
      if (name == nil) {
        name = service == nil ? [key description]
                              : [NSString stringWithFormat:@"port %@", service];
      }
      if (![names containsObject:name]) {
        [names addObject:name];
      }
    }
  }
  return names;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *FLEventNames(id events) {
  NSMutableDictionary *names = [NSMutableDictionary new];
  if (![events isKindOfClass:[NSDictionary class]]) {
    return names;
  }
  for (NSString *stream in (NSDictionary *)events) {
    NSDictionary *wanted = events[stream];
    if (![wanted isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    NSMutableArray<NSString *> *found = [NSMutableArray new];
    for (NSString *key in wanted) {
      NSDictionary *event = [wanted[key] isKindOfClass:[NSDictionary class]] ? wanted[key] : @{};
      NSString *name = FLText(event[@"Notification"]) ?: FLText(event[@"Name"]);
      [found addObject:name ?: [key description]];
    }
    names[[stream description]] = [found sortedArrayUsingSelector:@selector(compare:)];
  }
  return names;
}

static NSString *FLEventCount(NSString *stream, NSUInteger count) {
  NSDictionary<NSString *, NSArray<NSString *> *> *words = @{
    @"com.apple.notifyd.matching" : @[ @"notification", @"notifications" ],
    @"com.apple.distnoted.matching" : @[ @"app notification", @"app notifications" ],
    @"com.apple.xpc.activity" : @[ @"scheduled activity", @"scheduled activities" ],
    @"com.apple.iokit.matching" : @[ @"hardware event", @"hardware events" ],
    @"com.apple.fsevents.matching" : @[ @"file change", @"file changes" ],
  };
  NSArray<NSString *> *pair = words[stream];
  if (pair == nil) {
    return [NSString stringWithFormat:@"%lu from %@", (unsigned long)count, stream];
  }
  return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, pair[count == 1 ? 0 : 1]];
}

static NSString *FLDescribeTriggers(NSDictionary *plist, NSDictionary *record) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  if ([record[@"elsewhere"] boolValue]) {
    [parts addObject:@"not loaded on this model"];
  }
  if ([record[@"disabled"] boolValue]) {
    [parts addObject:@"disabled"];
  }
  if ([plist[@"RunAtLoad"] boolValue]) {
    [parts addObject:[plist[@"LaunchOnlyOnce"] boolValue] ? @"once at boot" : @"at boot"];
  }
  id keep = plist[@"KeepAlive"];
  if ([keep isKindOfClass:[NSDictionary class]]) {
    NSDictionary *paths = keep[@"PathState"];
    if ([paths isKindOfClass:[NSDictionary class]]) {
      NSArray *watched = [paths.allKeys sortedArrayUsingSelector:@selector(compare:)];
      for (NSString *path in watched) {
        [parts addObject:[NSString stringWithFormat:@"kept running while %@ %@", path,
                                                    [paths[path] boolValue] ? @"exists"
                                                                            : @"is missing"]];
      }
    }
    if (keep[@"SuccessfulExit"] != nil) {
      [parts addObject:[keep[@"SuccessfulExit"] boolValue] ? @"started again after a clean exit"
                                                           : @"started again after a failed exit"];
    }
    if ([keep[@"Crashed"] boolValue]) {
      [parts addObject:@"started again after a crash"];
    }
  } else if (keep != nil && ![keep isEqual:@NO]) {
    [parts addObject:@"kept running"];
  }
  NSUInteger offered = [record[@"machServices"] count];
  if (offered > 0) {
    [parts addObject:offered == 1
                       ? @"when a program asks for its Mach service"
                       : [NSString stringWithFormat:@"when a program asks for one of its %lu "
                                                    @"Mach services",
                                                    (unsigned long)offered]];
  }
  if ([record[@"sockets"] count] > 0) {
    [parts addObject:[NSString
                       stringWithFormat:@"on a connection to %@",
                                        [record[@"sockets"] componentsJoinedByString:@" or "]]];
  }
  NSDictionary<NSString *, NSArray *> *events = record[@"events"];
  for (NSString *stream in [events.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [parts addObject:[@"on " stringByAppendingString:FLEventCount(stream, events[stream].count)]];
  }
  for (NSArray<NSString *> *rule in @[
         @[ @"WatchPaths", @"when %@ changes" ],
         @[ @"QueueDirectories", @"when files arrive in %@" ]
       ]) {
    NSArray<NSString *> *paths = FLTexts(plist[rule[0]]);
    if (paths.count > 0) {
      NSString *listed = [paths componentsJoinedByString:@" or "];
      [parts addObject:[rule[1] stringByReplacingOccurrencesOfString:@"%@" withString:listed]];
    }
  }
  if ([plist[@"StartInterval"] doubleValue] > 0) {
    [parts addObject:[@"every " stringByAppendingString:FLFormatDuration(
                                                          [plist[@"StartInterval"] doubleValue])]];
  }
  if (plist[@"StartCalendarInterval"] != nil) {
    [parts addObject:@"at set times"];
  }
  return parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"when launchd decides";
}

static NSArray<NSMutableDictionary *> *FLServiceRecords(void) {
  NSDictionary *overrides = [NSDictionary dictionaryWithContentsOfFile:FLOverridesFile] ?: @{};
  NSMutableArray<NSMutableDictionary *> *records = [NSMutableArray new];
  FLEachLaunchDefinition(^(NSDictionary *service, NSDictionary *plist) {
    NSString *label = service[@"label"];
    NSMutableDictionary *record = [NSMutableDictionary new];
    record[@"kind"] = @"service";
    record[@"name"] = label;
    record[@"id"] = label;
    record[@"path"] = service[@"file"];
    record[@"program"] = service[@"program"];
    NSArray<NSString *> *arguments = FLTexts(service[@"arguments"]);
    NSString *command = [arguments componentsJoinedByString:@" "];
    if (arguments.count > 0 && ![arguments[0] isEqualToString:service[@"program"]]) {
      record[@"command"] = [NSString stringWithFormat:@"%@ as %@", service[@"program"], command];
    } else if (arguments.count > 1) {
      record[@"command"] = command;
    }
    record[@"user"] = FLText(plist[@"UserName"]) ?: @"root";
    id overridden = overrides[label];
    if ([overridden respondsToSelector:@selector(boolValue)] ? [overridden boolValue]
                                                             : [plist[@"Disabled"] boolValue]) {
      record[@"disabled"] = @YES;
    }
    if ([service[@"elsewhere"] boolValue]) {
      record[@"elsewhere"] = @YES;
    }
    FLPutList(record, @"machServices", service[@"machServices"]);
    FLPutList(record, @"sockets", FLSocketNames(plist[@"Sockets"]));
    NSDictionary *events = FLEventNames(plist[@"LaunchEvents"]);
    if (events.count > 0) {
      record[@"events"] = events;
    }
    record[@"starts"] = FLDescribeTriggers(plist, record);
    [records addObject:record];
  });
  return records;
}

static NSString *FLEnclosing(NSString *path,
                             NSDictionary<NSString *, NSMutableDictionary *> *folders) {
  NSString *folder = path.stringByDeletingLastPathComponent;
  while (folder.length > 1) {
    if (folders[folder] != nil) {
      return folder;
    }
    folder = folder.stringByDeletingLastPathComponent;
  }
  return nil;
}

static uint64_t FLSizeOf(NSDictionary *item) {
  return [(item[@"bytes"] ?: item[@"cached"]) unsignedLongLongValue];
}

static void FLSortItems(NSMutableArray<NSMutableDictionary *> *items) {
  NSArray<NSString *> *order = FLInventoryKinds();
  [items sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSUInteger kind = [order indexOfObject:first[@"kind"]];
    NSUInteger other = [order indexOfObject:second[@"kind"]];
    if (kind != other) {
      return kind < other ? NSOrderedAscending : NSOrderedDescending;
    }
    BOOL cached = first[@"bytes"] == nil;
    BOOL otherCached = second[@"bytes"] == nil;
    if (cached != otherCached) {
      return cached ? NSOrderedDescending : NSOrderedAscending;
    }
    uint64_t size = FLSizeOf(first);
    uint64_t otherSize = FLSizeOf(second);
    if (size != otherSize) {
      return size > otherSize ? NSOrderedAscending : NSOrderedDescending;
    }
    NSComparisonResult names = [first[@"name"] caseInsensitiveCompare:second[@"name"]];
    return names != NSOrderedSame ? names : [first[@"path"] compare:second[@"path"]];
  }];
}

NSDictionary *FLGatherInventory(void) {
  NSDate *began = [NSDate date];
  FLInventoryWalk *walk = [FLInventoryWalk new];
  [walk walk:@"/" system:YES];
  for (NSString *root in @[
         @"/private/var/containers/Bundle/Application",
         @"/private/var/mobile/Containers/Bundle/Application"
       ]) {
    if (access(root.fileSystemRepresentation, R_OK) == 0) {
      [walk walk:root system:NO];
    }
  }
  NSMutableArray<NSMutableDictionary *> *items = walk.items;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *folders = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSMutableDictionary *> *programs = [NSMutableDictionary new];
  for (NSMutableDictionary *item in items) {
    NSString *kind = item[@"kind"];
    if ([kind isEqualToString:@"program"]) {
      programs[item[@"path"]] = item;
    } else if (![kind isEqualToString:@"library"]) {
      folders[item[@"path"]] = item;
      if (item[@"program"] != nil) {
        programs[item[@"program"]] = item;
      }
    }
  }

  uint64_t cacheBytes = 0;
  uint64_t cachedBytes = 0;
  NSArray<NSMutableDictionary *> *images = FLSharedCacheImages(&cacheBytes);
  for (NSMutableDictionary *image in images) {
    NSString *path = image[@"path"];
    cachedBytes += [image[@"cached"] unsignedLongLongValue];
    NSMutableDictionary *bundle = walk.awaited[path];
    if (bundle != nil && bundle[@"cached"] == nil) {
      bundle[@"cached"] = image[@"cached"];
      bundle[@"binary"] = path;
      bundle[@"inCache"] = @YES;
      continue;
    }
    image[@"kind"] = @"library";
    image[@"name"] = path.lastPathComponent;
    image[@"inCache"] = @YES;
    FLPut(image, @"inside", FLEnclosing(path, folders));
    [items addObject:image];
  }

  for (NSMutableDictionary *service in FLServiceRecords()) {
    NSMutableDictionary *program = programs[service[@"program"]];
    if (program != nil) {
      NSMutableArray *labels = program[@"runBy"] ?: [NSMutableArray new];
      NSString *label = service[@"id"];
      if ([service[@"elsewhere"] boolValue]) {
        label = [label stringByAppendingString:@" (not loaded on this model)"];
      } else if ([service[@"disabled"] boolValue]) {
        label = [label stringByAppendingString:@" (disabled)"];
      }
      if (![labels containsObject:label]) {
        [labels addObject:label];
      }
      program[@"runBy"] = labels;
      if ([program[@"kind"] isEqualToString:@"program"]) {
        service[@"programBytes"] = program[@"bytes"];
      }
    }
    [items addObject:service];
  }

  NSDictionary<NSString *, NSString *> *owners = FLPackageOwners();
  for (NSMutableDictionary *item in items) {
    item[@"from"] = FLOriginOf(owners, @[ item[@"path"] ?: @"" ]);
  }
  FLSortItems(items);

  NSMutableArray<NSDictionary *> *kinds = [NSMutableArray new];
  uint64_t held = 0;
  for (NSString *kind in FLInventoryKinds()) {
    NSUInteger count = 0;
    uint64_t bytes = 0, system = 0, cached = 0;
    for (NSDictionary *item in items) {
      if (![item[@"kind"] isEqualToString:kind]) {
        continue;
      }
      count++;
      uint64_t own = [(item[@"own"] ?: item[@"bytes"]) unsignedLongLongValue];
      bytes += own;
      system += [item[@"data"] boolValue] ? 0 : own;
      cached += [item[@"cached"] unsignedLongLongValue];
    }
    held += system;
    [kinds addObject:@{
      @"kind" : kind,
      @"title" : FLInventoryKindTitle(kind),
      @"count" : @(count),
      @"bytes" : @(bytes),
      @"system" : @(system),
      @"cached" : @(cached),
    }];
  }
  NSMutableArray<NSDictionary *> *areas = [NSMutableArray new];
  for (NSString *area in walk.areas) {
    FLTally *tally = walk.areas[area];
    [areas addObject:@{@"path" : area, @"bytes" : @(tally.bytes), @"files" : @(tally.files)}];
  }
  [areas sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult sizes = [second[@"bytes"] compare:first[@"bytes"]];
    return sizes != NSOrderedSame ? sizes : [first[@"path"] compare:second[@"path"]];
  }];

  NSMutableDictionary *inventory = [NSMutableDictionary new];
  inventory[@"version"] = @1;
  inventory[@"gathered"] = [NSDate date];
  inventory[@"took"] = @(-began.timeIntervalSinceNow);
  inventory[@"items"] = items;
  inventory[@"kinds"] = kinds;
  inventory[@"areas"] = areas;
  inventory[@"counted"] = @{
    @"files" : @(walk.files),
    @"folders" : @(walk.folders),
    @"bytes" : @(walk.bytes),
    @"held" : @(held),
    @"unread" : @(walk.unread),
  };
  inventory[@"cache"] = @{
    @"libraries" : @(images.count),
    @"bytes" : @(cacheBytes),
    @"cached" : @(cachedBytes),
  };
  struct statfs volume;
  if (statfs("/", &volume) == 0) {
    inventory[@"volume"] = @{
      @"total" : @((uint64_t)volume.f_blocks * volume.f_bsize),
      @"free" : @((uint64_t)volume.f_bavail * volume.f_bsize),
    };
  }
  return inventory;
}

static NSDictionary *FLInstalledList(NSDictionary *inventory) {
  NSMutableArray *apps = [NSMutableArray new];
  NSMutableArray *bundles = [NSMutableArray new];
  NSMutableArray *tools = [NSMutableArray new];
  NSMutableDictionary *origins = [NSMutableDictionary new];
  for (NSDictionary *item in inventory[@"items"]) {
    NSString *kind = item[@"kind"];
    NSString *path = item[@"path"] ?: @"";
    NSString *origin = item[@"from"] ?: @"";
    if (origin.length > 0 && ![origin isEqualToString:FLStockOrigin] &&
        ![origin isEqualToString:FLAddedOrigin]) {
      origins[path] = origin;
    }
    NSMutableDictionary *row = [NSMutableDictionary new];
    row[@"path"] = path;
    row[@"origin"] = origin;
    row[@"bytes"] = item[@"bytes"] ?: @0;
    if ([kind isEqualToString:@"app"]) {
      if (item[@"inside"] != nil || !([path hasPrefix:@"/Applications/"] ||
                                      [path containsString:@"/Bundle/Application/"])) {
        continue;
      }
      FLPut(row, @"identifier", item[@"id"]);
      row[@"name"] = item[@"name"] ?: path.lastPathComponent;
      row[@"kind"] = item[@"type"] ?: @"system";
      row[@"hidden"] = @([item[@"hidden"] boolValue]);
      [apps addObject:row];
    } else if ([kind isEqualToString:@"extension"] || [kind isEqualToString:@"xpc"]) {
      if (item[@"id"] == nil) {
        continue;
      }
      row[@"identifier"] = item[@"id"];
      FLPut(row, @"program", item[@"program"]);
      NSString *host = [item[@"inside"] lastPathComponent].stringByDeletingPathExtension;
      if ([kind isEqualToString:@"xpc"]) {
        row[@"note"] = @"an XPC service, started when a program that uses it asks";
      } else {
        row[@"note"] = [NSString stringWithFormat:@"an app extension of %@ for %@",
                                                  host ?: @"the system",
                                                  item[@"point"] ?: @"an unnamed purpose"];
      }
      [bundles addObject:row];
    } else if ([kind isEqualToString:@"program"]) {
      [tools addObject:row];
    }
  }
  return @{
    @"gathered" : inventory[@"gathered"] ?: [NSDate date],
    @"apps" : apps,
    @"bundles" : bundles,
    @"tools" : tools,
    @"origins" : origins,
  };
}

BOOL FLSaveInventory(NSDictionary *inventory) {
  if (!FLWriteCompactState(FLInventoryState, inventory) ||
      !FLWriteCompactState(FLInstalledState, FLInstalledList(inventory))) {
    return NO;
  }
  notify_post(FLNoticeInventory.UTF8String);
  return YES;
}

NSString *FLInventoryMarks(void) {
  NSArray<NSString *> *places = @[
    @"/var/lib/dpkg/status", @"/Applications", @"/System/Library/LaunchDaemons",
    @"/Library/LaunchDaemons", @"/System/Library/Frameworks",
    @"/System/Library/PrivateFrameworks", @"/System/Library/CoreServices", @"/usr/libexec",
    @"/usr/bin", @"/usr/sbin", @"/usr/lib", @"/bin", @"/sbin",
    @"/Library/MobileSubstrate/DynamicLibraries", @"/var/containers/Bundle/Application",
    @"/var/mobile/Containers/Bundle/Application", FLOverridesFile
  ];
  NSMutableArray<NSString *> *marks = [NSMutableArray new];
  for (NSString *place in places) {
    struct stat info;
    if (stat(place.fileSystemRepresentation, &info) != 0) {
      [marks addObject:@"-"];
      continue;
    }
    [marks addObject:[NSString stringWithFormat:@"%lld.%ld", (long long)info.st_mtimespec.tv_sec,
                                                (long)info.st_mtimespec.tv_nsec]];
  }
  return [marks componentsJoinedByString:@" "];
}

static NSString *FLOffers(NSDictionary *item) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  for (NSArray<NSString *> *offer in @[
         @[ @"schemes", @"URL schemes " ], @[ @"background", @"background modes " ],
         @[ @"machServices", @"Mach services " ]
       ]) {
    NSArray<NSString *> *names = item[offer[0]];
    if (names.count > 0) {
      [parts addObject:[offer[1] stringByAppendingString:[names componentsJoinedByString:@", "]]];
    }
  }
  return [parts componentsJoinedByString:@"; "];
}

static NSString *FLEvents(NSDictionary *item) {
  NSDictionary<NSString *, NSArray<NSString *> *> *events = item[@"events"];
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  for (NSString *stream in [events.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [parts addObject:[NSString stringWithFormat:@"%@: %@", stream,
                                                [events[stream] componentsJoinedByString:@", "]]];
  }
  return [parts componentsJoinedByString:@"; "];
}

static NSString *FLLibraryPlace(NSDictionary *item) {
  if ([item[@"inCache"] boolValue]) {
    return [NSString stringWithFormat:@"in the shared cache, %@",
                                      FLFormatBytes([item[@"cached"] unsignedLongLongValue])];
  }
  return item[@"binary"] != nil ? @"on disk" : @"none";
}

static NSString *FLNeeded(NSDictionary *item) {
  if (item[@"users"] == nil) {
    return @"";
  }
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  [parts addObject:[NSString stringWithFormat:@"linked by %@, opened by name by %@",
                                              item[@"users"], item[@"openers"] ?: @0]];
  NSString *need = FLNeedText(item[@"need"]);
  if (need.length > 0) {
    [parts addObject:need];
  }
  if ([item[@"shadowed"] boolValue]) {
    [parts addObject:@"the shared cache's copy is loaded instead"];
  }
  return [parts componentsJoinedByString:@"; "];
}

static NSString *FLCountOf(NSDictionary *item, NSString *key) {
  return item[key] == nil ? @"" : [item[key] description];
}

static NSString *FLItemSize(NSDictionary *item) {
  return item[@"bytes"] == nil ? @"" : FLFormatBytes([item[@"bytes"] unsignedLongLongValue]);
}

static NSString *FLItemLine(NSDictionary *item) {
  NSString *kind = item[@"kind"];
  NSString *name = item[@"name"] ?: @"";
  NSString *identifier = item[@"id"] ?: @"";
  NSString *origin = item[@"from"] ?: @"";
  NSString *path = FLEscape(item[@"path"] ?: @"");
  NSString *inside = item[@"inside"] ?: @"";
  NSString *held = item[@"holds"] ?: @"";
  if ([kind isEqualToString:@"app"]) {
    NSString *type = [item[@"hidden"] boolValue]
      ? [NSString stringWithFormat:@"%@, hidden", item[@"type"]]
      : item[@"type"];
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", name, identifier,
                                      item[@"version"] ?: @"", FLItemSize(item), origin,
                                      type ?: @"", held, FLOffers(item), path];
  }
  if ([kind isEqualToString:@"extension"]) {
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@", name, identifier,
                                      item[@"point"] ?: @"", inside, FLItemSize(item), origin,
                                      path];
  }
  if ([kind isEqualToString:@"service"]) {
    NSString *size = item[@"programBytes"] == nil
      ? @""
      : FLFormatBytes([item[@"programBytes"] unsignedLongLongValue]);
    return [NSString
      stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", name,
                       item[@"starts"] ?: @"",
                       [item[@"machServices"] componentsJoinedByString:@", "] ?: @"",
                       FLCountOf(item, @"clients"), FLEvents(item), item[@"user"] ?: @"",
                       FLEscape(item[@"command"] ?: item[@"program"] ?: @""), size, origin, path];
  }
  if ([kind isEqualToString:@"xpc"]) {
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", name, identifier,
                                      item[@"type"] ?: @"", inside, FLItemSize(item),
                                      FLCountOf(item, @"clients"), origin, path];
  }
  if ([kind isEqualToString:@"framework"]) {
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", name,
                                      identifier, item[@"version"] ?: @"", FLLibraryPlace(item),
                                      FLItemSize(item), held, FLNeeded(item), origin, path];
  }
  if ([kind isEqualToString:@"bundle"]) {
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", name, identifier,
                                      item[@"type"] ?: @"", FLItemSize(item), held,
                                      FLNeeded(item), origin, path];
  }
  if ([kind isEqualToString:@"program"]) {
    NSString *type = [item[@"type"] isEqualToString:@"script"]
      ? [NSString stringWithFormat:@"script for %@", item[@"interpreter"] ?: @"an interpreter"]
      : @"program";
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@", path, type, FLItemSize(item),
                                      FLCountOf(item, @"needs"), origin,
                                      [item[@"runBy"] componentsJoinedByString:@", "] ?: @""];
  }
  if ([item[@"inCache"] boolValue]) {
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@", path, @"in the shared cache",
                                      FLFormatBytes([item[@"cached"] unsignedLongLongValue]),
                                      FLNeeded(item), origin];
  }
  return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@", path, @"on disk",
                                    FLItemSize(item), FLNeeded(item), origin];
}

static NSString *FLItemHeadings(NSString *kind) {
  NSDictionary<NSString *, NSString *> *headings = @{
    @"app" : @"name\tidentifier\tversion\tsize\tfrom\tkind\tholds\toffers\tpath",
    @"extension" : @"name\tidentifier\textension point\tinside\tsize\tfrom\tpath",
    @"service" : @"label\tstarts\tMach services\tnamed by\tevents\tuser\tcommand\tprogram size\t"
                 @"from\tdefined in",
    @"xpc" : @"name\tidentifier\ttype\tinside\tsize\tnamed by\tfrom\tpath",
    @"framework" : @"name\tidentifier\tversion\tlibrary\tsize\tholds\tneeded\tfrom\tpath",
    @"bundle" : @"name\tidentifier\ttype\tsize\tholds\tneeded\tfrom\tpath",
    @"program" : @"path\tkind\tsize\tlibraries linked\tfrom\trun by",
    @"library" : @"path\twhere\tsize\tneeded\tfrom",
  };
  return headings[kind] ?: @"";
}

static void FLAppendBundles(NSMutableString *text, NSArray<NSDictionary *> *bundles) {
  NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary new];
  for (NSDictionary *bundle in bundles) {
    NSString *group = bundle[@"group"] ?: @"";
    if (groups[group] == nil) {
      groups[group] = [NSMutableArray new];
    }
    [groups[group] addObject:bundle];
    uint64_t own = [(bundle[@"own"] ?: bundle[@"bytes"]) unsignedLongLongValue];
    sizes[group] = @([sizes[group] unsignedLongLongValue] + own);
  }
  NSArray<NSString *> *order =
    [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *first,
                                                                   NSString *second) {
      NSComparisonResult bigger = [sizes[second] compare:sizes[first]];
      return bigger != NSOrderedSame ? bigger : [first compare:second];
    }];
  [text appendFormat:@"%@\n", FLItemHeadings(@"bundle")];
  for (NSString *group in order) {
    [text appendFormat:@"\nIn %@: %lu, %@\n", group, (unsigned long)groups[group].count,
                       FLFormatBytes(sizes[group].unsignedLongLongValue)];
    for (NSDictionary *bundle in groups[group]) {
      [text appendFormat:@"%@\n", FLItemLine(bundle)];
    }
  }
}

NSString *FLInventorySummary(NSDictionary *inventory) {
  NSDictionary *counted = inventory[@"counted"];
  NSDate *gathered = [inventory[@"gathered"] isKindOfClass:[NSDate class]] ? inventory[@"gathered"]
                                                                          : [NSDate date];
  return [NSString stringWithFormat:@"Listed %@ in %@: %lu things installed, among %@ files in %@ "
                                    @"folders on the system volume",
                                    FLFormatDay(gathered),
                                    FLFormatDuration([inventory[@"took"] doubleValue]),
                                    (unsigned long)[inventory[@"items"] count],
                                    counted[@"files"] ?: @0, counted[@"folders"] ?: @0];
}

NSString *FLInventoryText(NSDictionary *inventory, NSString *kind) {
  NSMutableString *text = [NSMutableString new];
  NSDictionary *counted = inventory[@"counted"];
  NSDictionary *volume = inventory[@"volume"];
  NSDictionary *cache = inventory[@"cache"];
  uint64_t bytes = [counted[@"bytes"] unsignedLongLongValue];
  [text appendFormat:@"%@\n", FLInventorySummary(inventory)];
  if (volume != nil) {
    [text appendFormat:@"The system volume holds %@ and has %@ free. Its files take %@, and the "
                       @"file system's own records the rest.\n",
                       FLFormatBytes([volume[@"total"] unsignedLongLongValue]),
                       FLFormatBytes([volume[@"free"] unsignedLongLongValue]),
                       FLFormatBytes(bytes)];
  }
  [text appendString:@"A size is the space a thing takes on the volume, which is what removing it "
                     @"would free. iOS keeps many files compressed, so this is often less than "
                     @"their length, and a file that compresses to under 4 KB is kept inside the "
                     @"file system's own records and takes no space of its own: a thing made "
                     @"only of such files shows as 0 bytes. The size of a folder includes what "
                     @"is nested inside it.\n"];
  if ([cache[@"libraries"] unsignedIntegerValue] > 0) {
    [text appendFormat:@"The shared library cache is one file of %@ that holds %@ libraries "
                       @"(%@ of code and data). A library kept there takes no space of its own "
                       @"and cannot be removed by itself.\n",
                       FLFormatBytes([cache[@"bytes"] unsignedLongLongValue]),
                       cache[@"libraries"],
                       FLFormatBytes([cache[@"cached"] unsignedLongLongValue])];
  }
  if ([counted[@"unread"] unsignedIntegerValue] > 0) {
    [text appendFormat:@"%@ files or folders could not be read and are not counted.\n",
                       counted[@"unread"]];
  }
  NSArray<NSDictionary *> *kinds = inventory[@"kinds"];
  NSArray<NSDictionary *> *areas = inventory[@"areas"];
  NSArray<NSDictionary *> *items = inventory[@"items"];
  BOOL everything = kind == nil;
  if (everything || [kind isEqualToString:FLStorageKind]) {
    uint64_t held = [counted[@"held"] unsignedLongLongValue];
    [text appendString:@"\nWhere the space on the system volume goes\nkind\tfound\tsize\n"];
    for (NSDictionary *row in kinds) {
      uint64_t taken = [row[@"system"] unsignedLongLongValue];
      [text appendFormat:@"%@\t%@\t%@\n", row[@"title"], row[@"count"],
                         taken > 0 ? FLFormatBytes(taken) : @""];
    }
    [text appendFormat:@"Other files\t%lu folders\t%@\n", (unsigned long)areas.count,
                       FLFormatBytes(bytes > held ? bytes - held : 0)];
    [text appendString:@"Each kind's size leaves out what is nested inside its folders and "
                       @"counted under another kind, so the sizes add up to the space the files "
                       @"take.\n"];
  }
  for (NSDictionary *row in kinds) {
    NSString *each = row[@"kind"];
    if (!everything && ![kind isEqualToString:each]) {
      continue;
    }
    NSMutableArray<NSDictionary *> *chosen = [NSMutableArray new];
    for (NSDictionary *item in items) {
      if ([item[@"kind"] isEqualToString:each]) {
        [chosen addObject:item];
      }
    }
    if ([each isEqualToString:@"service"]) {
      [chosen sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        return [first[@"name"] caseInsensitiveCompare:second[@"name"]];
      }];
    }
    [text appendFormat:@"\n%@: %lu", row[@"title"], (unsigned long)chosen.count];
    if ([each isEqualToString:@"bundle"]) {
      [text appendString:@", by the folder they are in\n"];
      FLAppendBundles(text, chosen);
      continue;
    }
    [text appendFormat:@"\n%@\n", FLItemHeadings(each)];
    for (NSDictionary *item in chosen) {
      [text appendFormat:@"%@\n", FLItemLine(item)];
    }
  }
  if (everything || [kind isEqualToString:FLStorageKind]) {
    [text appendFormat:@"\nOther files, by folder: %lu\nfolder\tfiles\tsize\n",
                       (unsigned long)areas.count];
    for (NSDictionary *area in areas) {
      [text appendFormat:@"%@\t%@\t%@\n", FLEscape(area[@"path"]), area[@"files"],
                         FLFormatBytes([area[@"bytes"] unsignedLongLongValue])];
    }
  }
  return text;
}
