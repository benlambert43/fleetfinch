#import "FLMonitors.h"

#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FLSettings.h"
#import "FLStore.h"

static NSString *const FLImportState = @"imports";
static const off_t FLCopyLimit = 8 * 1024 * 1024;
static const off_t FLFirstTail = 512 * 1024;
static const size_t FLTailStep = 128 * 1024;
static const NSUInteger FLTailSteps = 16;
static const NSUInteger FLSummaryLength = 300;
static const NSTimeInterval FLRecopyAfter = 60 * 60;
static const size_t FLHeaderLength = 2048;
static NSString *const FLLaunchReport = @".launchd.report";
static NSString *const FLWholeDevice = @"(the device)";

static NSArray<NSDictionary *> *FLImportSources(void) {
  return @[
    @{@"path" : @"/var/mobile/Library/Logs", @"name" : @"Mobile"},
    @{@"path" : @"/Library/Logs", @"name" : @"Library"},
    @{@"path" : @"/var/logs", @"name" : @"Logs"},
    @{@"path" : @"/var/log", @"name" : @"Log"},
    @{@"path" : @"/var/root/Library/Logs", @"name" : @"Root"},
    @{@"path" : @"/var/wireless/Library/Logs", @"name" : @"Wireless"},
    @{@"path" : @"/var/installd/Library/Logs", @"name" : @"Installer"},
    @{@"path" : @"/var/networkd/Library/Logs", @"name" : @"Network"},
    @{@"path" : @"/var/db/diagnostics", @"name" : @"Diagnostics"},
  ];
}

static BOOL FLIsTextLog(NSString *name) {
  NSString *lower = name.lowercaseString;
  return [lower hasSuffix:@".log"] || [lower containsString:@".log."];
}

static NSString *FLFirstLine(NSString *path) {
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return @"";
  }
  char buffer[512] = {0};
  ssize_t count = read(handle, buffer, sizeof(buffer) - 1);
  close(handle);
  if (count <= 0) {
    return @"";
  }
  NSString *text = FLStringFromData([NSData dataWithBytes:buffer length:(NSUInteger)count]);
  NSString *line = [text componentsSeparatedByString:@"\n"].firstObject ?: @"";
  for (NSUInteger index = 0; index < MIN(line.length, (NSUInteger)64); index++) {
    unichar character = [line characterAtIndex:index];
    if (character < 9 || (character > 13 && character < 32)) {
      return @"";
    }
  }
  return line.length > FLSummaryLength ? [line substringToIndex:FLSummaryLength] : line;
}

static NSArray<NSString *> *FLReportSubject(NSString *path) {
  NSString *file = path.lastPathComponent;
  if ([file hasSuffix:FLLaunchReport]) {
    NSString *plain = [file substringToIndex:file.length - FLLaunchReport.length];
    NSRange dated = [plain rangeOfString:@"_" options:NSBackwardsSearch];
    return dated.location == NSNotFound ? nil
                                        : @[ [plain substringToIndex:dated.location],
                                             @"launchd report", @"" ];
  }
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return nil;
  }
  char buffer[FLHeaderLength + 1] = {0};
  ssize_t count = read(handle, buffer, FLHeaderLength);
  close(handle);
  char *end = count > 1 && buffer[0] == '{' ? strchr(buffer, '\n') : NULL;
  if (end == NULL) {
    return nil;
  }
  NSData *line = [NSData dataWithBytes:buffer length:(NSUInteger)(end - buffer)];
  NSDictionary *header = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
  NSString *type = [header isKindOfClass:[NSDictionary class]] ? [header[@"bug_type"] description]
                                                               : nil;
  if (type.length == 0) {
    return nil;
  }
  NSDictionary<NSString *, NSString *> *kinds = @{
    @"109" : @"crash report",
    @"110" : @"kernel panic report",
    @"198" : @"low memory report",
    @"288" : @"stackshot",
  };
  NSString *name = [header[@"app_name"] description] ?: [header[@"name"] description];
  NSString *program = @"";
  char *marked = strstr(end, "\nPath:");
  if (marked != NULL) {
    char *start = marked + strlen("\nPath:");
    start += strspn(start, " \t");
    size_t length = strcspn(start, "\r\n");
    program = [[NSString alloc] initWithBytes:start length:length encoding:NSUTF8StringEncoding]
      ?: @"";
  }
  return @[
    name.length > 0 ? name : FLWholeDevice,
    kinds[type] ?: [@"report of type " stringByAppendingString:type],
    [program hasPrefix:@"/"] ? program : @""
  ];
}

@implementation FLImportMonitor {
  NSMutableDictionary<NSString *, NSString *> *_copied;
  NSMutableDictionary<NSString *, NSNumber *> *_copiedAt;
  NSMutableDictionary<NSString *, NSString *> *_files;
  NSMutableDictionary<NSString *, NSNumber *> *_offsets;
  NSString *_volume;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    NSDictionary *state = FLReadState(FLImportState);
    _copied = [state[@"copied"] isKindOfClass:[NSDictionary class]]
      ? [state[@"copied"] mutableCopy]
      : [NSMutableDictionary new];
    _copiedAt = [state[@"copiedAt"] isKindOfClass:[NSDictionary class]]
      ? [state[@"copiedAt"] mutableCopy]
      : [NSMutableDictionary new];
    _files = [state[@"files"] isKindOfClass:[NSDictionary class]]
      ? [state[@"files"] mutableCopy]
      : [NSMutableDictionary new];
    _offsets = [state[@"offsets"] isKindOfClass:[NSDictionary class]]
      ? [state[@"offsets"] mutableCopy]
      : [NSMutableDictionary new];
  }
  return self;
}

- (NSString *)identityOf:(const struct stat *)info {
  return [NSString stringWithFormat:@"%@:%llu", _volume, (unsigned long long)info->st_ino];
}

- (NSUInteger)tail:(NSString *)path info:(const struct stat *)info {
  NSString *key = [self identityOf:info];
  NSNumber *saved = _offsets[key];
  off_t offset = saved == nil ? MAX(0, info->st_size - FLFirstTail) : saved.longLongValue;
  if (offset > info->st_size) {
    offset = 0;
  }
  if (offset == info->st_size) {
    _offsets[key] = @(offset);
    return 0;
  }
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return 0;
  }
  NSData *newline = [NSData dataWithBytes:"\n" length:1];
  NSString *source = path.lastPathComponent;
  NSUInteger written = 0;
  BOOL partial = saved == nil && offset > 0;
  BOOL advanced = NO;
  for (NSUInteger step = 0; step < FLTailSteps && offset < info->st_size; step++) {
    @autoreleasepool {
      size_t wanted = (size_t)MIN((off_t)FLTailStep, info->st_size - offset);
      NSMutableData *data = [NSMutableData dataWithLength:wanted];
      ssize_t count = pread(handle, data.mutableBytes, wanted, offset);
      if (count <= 0) {
        break;
      }
      data.length = (NSUInteger)count;
      NSRange last = [data rangeOfData:newline
                               options:NSDataSearchBackwards
                                 range:NSMakeRange(0, data.length)];
      BOOL unbroken = last.location == NSNotFound;
      if (unbroken && (size_t)count < FLTailStep) {
        break;
      }
      NSUInteger taken = unbroken ? data.length : last.location;
      NSData *whole = [data subdataWithRange:NSMakeRange(0, taken)];
      for (NSString *line in [FLStringFromData(whole) componentsSeparatedByString:@"\n"]) {
        if (partial) {
          partial = NO;
          continue;
        }
        if (line.length == 0) {
          continue;
        }
        [[FLStore shared] log:@"file" level:FLLevelNotice source:source message:line];
        written++;
      }
      offset += (off_t)taken + (unbroken ? 0 : 1);
      advanced = YES;
    }
  }
  close(handle);
  if (advanced || saved != nil) {
    _offsets[key] = @(offset);
  }
  return written;
}

- (BOOL)copy:(NSString *)path
        info:(const struct stat *)info
      folder:(NSString *)folder {
  NSString *print = [NSString stringWithFormat:@"%lld:%ld", (long long)info->st_size,
                                               (long)info->st_mtime];
  NSString *file = [self identityOf:info];
  if ([_copied[path] isEqualToString:print]) {
    _files[file] = print;
    return NO;
  }
  double now = [NSDate date].timeIntervalSince1970;
  if ([_files[file] isEqualToString:print]) {
    _copied[path] = print;
    _copiedAt[path] = @(now);
    FLNote(@"import", FLLevelInfo, path.lastPathComponent,
           @"was copied before under another name or folder and is now in %@",
           path.stringByDeletingLastPathComponent);
    return NO;
  }
  if (_copied[path] != nil && now - _copiedAt[path].doubleValue < FLRecopyAfter) {
    return NO;
  }
  _copied[path] = print;
  _copiedAt[path] = @(now);
  NSString *saved = [[FLStore shared] importFile:path folder:folder];
  if (saved == nil) {
    FLNote(@"import", FLLevelWarning, path.lastPathComponent, @"could not be copied from %@",
           path.stringByDeletingLastPathComponent);
    return NO;
  }
  _files[file] = print;
  NSString *summary = FLFirstLine(path);
  FLNote(@"import", FLLevelNotice, path.lastPathComponent, @"copied %@ from %@%@%@",
         FLFormatBytes((uint64_t)info->st_size), path.stringByDeletingLastPathComponent,
         summary.length > 0 ? @": " : @"", summary);
  NSArray<NSString *> *subject = FLReportSubject(path);
  if (subject != nil && self.reported != nil) {
    self.reported(subject[0], subject[1], subject[2]);
  }
  return YES;
}

- (NSDictionary *)scan {
  NSFileManager *manager = [NSFileManager defaultManager];
  double keep = [FLSettings number:FLSettingDeleteAfter];
  time_t now = time(NULL);
  NSUInteger copied = 0, lines = 0, seen = 0;
  NSSet *disabled = [FLStore shared].disabledStreams;
  BOOL tails = ![disabled containsObject:@"file"];
  BOOL copies = ![disabled containsObject:@"import"];
  NSMutableSet *present = [NSMutableSet new];
  NSMutableSet *files = [NSMutableSet new];
  NSMutableSet *logs = [NSMutableSet new];
  NSMutableSet *folders = [NSMutableSet new];
  for (NSDictionary *source in FLImportSources()) {
    NSString *root = source[@"path"];
    char resolved[PATH_MAX];
    if (realpath(root.fileSystemRepresentation, resolved) == NULL ||
        [folders containsObject:@(resolved)]) {
      continue;
    }
    [folders addObject:@(resolved)];
    struct statfs volume;
    _volume = statfs(resolved, &volume) == 0 ? @(volume.f_mntonname) : @(resolved);
    NSDirectoryEnumerator *walker = [manager enumeratorAtPath:root];
    for (NSString *relative in walker) {
      @autoreleasepool {
        NSString *path = [root stringByAppendingPathComponent:relative];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) {
          continue;
        }
        seen++;
        [present addObject:path];
        if (FLIsTextLog(relative.lastPathComponent)) {
          [logs addObject:[self identityOf:&info]];
          if (tails) {
            lines += [self tail:path info:&info];
          }
          continue;
        }
        if (!copies || info.st_size == 0 || info.st_size > FLCopyLimit ||
            (keep > 0 && now - info.st_mtime > (time_t)keep)) {
          continue;
        }
        [files addObject:[self identityOf:&info]];
        NSString *parent = relative.stringByDeletingLastPathComponent;
        NSString *folder = parent.length == 0
          ? source[@"name"]
          : [source[@"name"] stringByAppendingPathComponent:parent];
        if ([self copy:path info:&info folder:folder]) {
          copied++;
        }
      }
    }
  }
  for (NSString *path in _copied.allKeys) {
    if (![present containsObject:path]) {
      [_copied removeObjectForKey:path];
      [_copiedAt removeObjectForKey:path];
    }
  }
  for (NSString *file in _files.allKeys) {
    if (![files containsObject:file]) {
      [_files removeObjectForKey:file];
    }
  }
  for (NSString *log in _offsets.allKeys) {
    if (![logs containsObject:log]) {
      [_offsets removeObjectForKey:log];
    }
  }
  FLWriteState(FLImportState, @{
    @"copied" : _copied,
    @"copiedAt" : _copiedAt,
    @"files" : _files,
    @"offsets" : _offsets,
  });
  return @{@"copied" : @(copied), @"lines" : @(lines), @"seen" : @(seen)};
}

@end
