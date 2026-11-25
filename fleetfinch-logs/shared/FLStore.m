#import "FLStore.h"

#import <fcntl.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>
#import <zlib.h>

#import "FLSettings.h"

NSString *const FLSnapshotFolder = @"snapshots";
NSString *const FLImportFolder = @"imports";

static const NSUInteger FLMessageLimit = 16 * 1024;
static const size_t FLCopyChunk = 64 * 1024;
static const size_t FLTextChunk = 16 * 1024;
static const double FLPartialAfter = 60 * 60;
static const uid_t FLMobileUser = 501;

static BOOL FLWriteAll(int handle, const uint8_t *bytes, size_t length) {
  while (length > 0) {
    ssize_t written = write(handle, bytes, length);
    if (written <= 0) {
      return NO;
    }
    bytes += written;
    length -= (size_t)written;
  }
  return YES;
}

static BOOL FLWriteText(int handle, NSString *text) {
  uint8_t *buffer = malloc(FLTextChunk);
  NSRange left = NSMakeRange(0, text.length);
  BOOL written = YES;
  while (written && left.length > 0) {
    NSUInteger used = 0;
    NSRange rest = left;
    [text getBytes:buffer
             maxLength:FLTextChunk
            usedLength:&used
              encoding:NSUTF8StringEncoding
               options:NSStringEncodingConversionAllowLossy
                 range:left
        remainingRange:&rest];
    if (rest.length == left.length) {
      rest = NSMakeRange(left.location + 1, left.length - 1);
    }
    written = FLWriteAll(handle, buffer, used);
    left = rest;
  }
  free(buffer);
  return written;
}

static BOOL FLCopyAll(int input, int output) {
  uint8_t *buffer = malloc(FLCopyChunk);
  ssize_t count = 0;
  BOOL copied = YES;
  while (copied && (count = read(input, buffer, FLCopyChunk)) > 0) {
    copied = FLWriteAll(output, buffer, (size_t)count);
  }
  free(buffer);
  return copied && count == 0;
}

BOOL FLGzipFile(NSString *source, NSString *target, BOOL merge) {
  int input = open(source.fileSystemRepresentation, O_RDONLY);
  if (input < 0) {
    return NO;
  }
  struct stat info;
  fstat(input, &info);
  NSString *partial = [target stringByAppendingString:@".part"];
  FLMakeDirectory(target.stringByDeletingLastPathComponent);
  unlink(partial.fileSystemRepresentation);
  BOOL ready = YES;
  int earlier = merge ? open(target.fileSystemRepresentation, O_RDONLY) : -1;
  if (earlier >= 0) {
    int kept = open(partial.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    ready = kept >= 0 && FLCopyAll(earlier, kept);
    if (kept >= 0) {
      close(kept);
    }
    close(earlier);
  }
  gzFile output = ready ? gzopen(partial.fileSystemRepresentation, "ab6") : NULL;
  if (output == NULL) {
    close(input);
    unlink(partial.fileSystemRepresentation);
    return NO;
  }
  BOOL written = YES;
  void *buffer = malloc(FLCopyChunk);
  ssize_t count = 0;
  while ((count = read(input, buffer, FLCopyChunk)) > 0) {
    if (gzwrite(output, buffer, (unsigned)count) != (int)count) {
      written = NO;
      break;
    }
  }
  free(buffer);
  close(input);
  if (gzclose(output) != Z_OK || count < 0 || !written) {
    unlink(partial.fileSystemRepresentation);
    return NO;
  }
  if (rename(partial.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
    unlink(partial.fileSystemRepresentation);
    return NO;
  }
  struct timeval times[2];
  times[0].tv_sec = info.st_mtime;
  times[0].tv_usec = 0;
  times[1] = times[0];
  utimes(target.fileSystemRepresentation, times);
  chmod(target.fileSystemRepresentation, 0644);
  return YES;
}

static NSArray<NSDictionary *> *FLFilesUnder(NSString *root) {
  NSMutableArray *files = [NSMutableArray new];
  NSFileManager *manager = [NSFileManager defaultManager];
  NSDirectoryEnumerator *walker = [manager enumeratorAtPath:root];
  for (;;) {
    @autoreleasepool {
      NSString *relative = [walker nextObject];
      if (relative == nil) {
        break;
      }
      NSString *path = [root stringByAppendingPathComponent:relative];
      struct stat info;
      if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) {
        continue;
      }
      [files addObject:@{
        @"path" : path,
        @"relative" : relative,
        @"size" : @((uint64_t)info.st_size),
        @"modified" : @((double)info.st_mtime),
      }];
    }
  }
  return files;
}

static void FLRemoveEmptyFolders(NSString *root) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSArray *relatives = [[manager enumeratorAtPath:root] allObjects];
  for (NSString *relative in relatives.reverseObjectEnumerator) {
    NSString *path = [root stringByAppendingPathComponent:relative];
    BOOL folder = NO;
    if ([manager fileExistsAtPath:path isDirectory:&folder] && folder &&
        [manager contentsOfDirectoryAtPath:path error:NULL].count == 0) {
      rmdir(path.fileSystemRepresentation);
    }
  }
}

NSDictionary *FLStoreUsage(void) {
  uint64_t liveBytes = 0, archiveBytes = 0;
  NSArray *live = FLFilesUnder(FLLivePath());
  NSArray *archive = FLFilesUnder(FLArchivePath());
  double oldest = 0;
  for (NSDictionary *file in live) {
    liveBytes += [file[@"size"] unsignedLongLongValue];
  }
  for (NSDictionary *file in archive) {
    archiveBytes += [file[@"size"] unsignedLongLongValue];
    double modified = [file[@"modified"] doubleValue];
    if (oldest == 0 || modified < oldest) {
      oldest = modified;
    }
  }
  return @{
    @"liveBytes" : @(liveBytes),
    @"liveFiles" : @(live.count),
    @"archiveBytes" : @(archiveBytes),
    @"archiveFiles" : @(archive.count),
    @"oldestArchive" : @(oldest),
  };
}

NSDate *FLNewestLogWrite(void) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *live = FLLivePath();
  time_t newest = 0;
  for (NSString *stream in [manager contentsOfDirectoryAtPath:live error:NULL]) {
    if ([stream isEqualToString:FLSnapshotFolder] || [stream isEqualToString:FLImportFolder]) {
      continue;
    }
    NSString *folder = [live stringByAppendingPathComponent:stream];
    for (NSString *name in [manager contentsOfDirectoryAtPath:folder error:NULL]) {
      NSString *path = [folder stringByAppendingPathComponent:name];
      struct stat info;
      if ([name hasSuffix:@".log"] && lstat(path.fileSystemRepresentation, &info) == 0 &&
          S_ISREG(info.st_mode) && info.st_mtime > newest) {
        newest = info.st_mtime;
      }
    }
  }
  return newest == 0 ? nil : [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)newest];
}

@implementation FLStore {
  dispatch_queue_t _queue;
  NSMutableDictionary<NSString *, NSNumber *> *_handles;
  NSMutableDictionary<NSString *, NSString *> *_hours;
  NSMutableDictionary<NSString *, NSNumber *> *_counts;
}

+ (instancetype)shared {
  static FLStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [FLStore new];
  });
  return store;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.fleetfinch.logs.store", DISPATCH_QUEUE_SERIAL);
    _handles = [NSMutableDictionary new];
    _hours = [NSMutableDictionary new];
    _counts = [NSMutableDictionary new];
  }
  return self;
}

- (BOOL)prepare {
  NSArray *folders = @[ FLRootPath, FLLivePath(), FLArchivePath(), FLStatePath() ];
  BOOL made = YES;
  for (NSString *folder in folders) {
    made = FLMakeDirectory(folder) && made;
    [[NSFileManager defaultManager]
      setAttributes:@{NSFileProtectionKey : NSFileProtectionNone}
       ofItemAtPath:folder
              error:NULL];
  }
  if (made && getuid() == 0) {
    chown(FLRootPath.fileSystemRepresentation, FLMobileUser, FLMobileUser);
    chmod(FLRootPath.fileSystemRepresentation, 0755);
  }
  return made;
}

- (NSString *)pathForStream:(NSString *)stream hour:(NSString *)hour {
  NSString *folder = [FLLivePath() stringByAppendingPathComponent:stream];
  return [folder stringByAppendingPathComponent:[hour stringByAppendingString:@".log"]];
}

- (int)openStream:(NSString *)stream hour:(NSString *)hour {
  NSString *path = [self pathForStream:stream hour:hour];
  FLMakeDirectory(path.stringByDeletingLastPathComponent);
  return open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
}

- (void)writeLine:(NSData *)line stream:(NSString *)stream hour:(NSString *)hour {
  NSString *current = _hours[stream];
  int handle = -1;
  BOOL temporary = NO;
  if ([current isEqualToString:hour]) {
    handle = _handles[stream].intValue;
  } else if (current == nil || [hour compare:current] == NSOrderedDescending) {
    if (current != nil) {
      close(_handles[stream].intValue);
    }
    handle = [self openStream:stream hour:hour];
    if (handle < 0) {
      [_handles removeObjectForKey:stream];
      [_hours removeObjectForKey:stream];
      return;
    }
    _handles[stream] = @(handle);
    _hours[stream] = hour;
  } else {
    handle = [self openStream:stream hour:hour];
    temporary = YES;
  }
  if (handle < 0) {
    return;
  }
  FLWriteAll(handle, line.bytes, line.length);
  if (temporary) {
    close(handle);
  }
  _counts[stream] = @(_counts[stream].unsignedLongLongValue + 1);
}

- (void)log:(NSString *)stream
      level:(FLLevel)level
     source:(NSString *)source
    message:(NSString *)message {
  [self log:stream level:level source:source message:message date:[NSDate date]];
}

- (void)log:(NSString *)stream
      level:(FLLevel)level
     source:(NSString *)source
    message:(NSString *)message
       date:(NSDate *)date {
  if (stream.length == 0 || [self.disabledStreams containsObject:stream]) {
    return;
  }
  NSString *text = message ?: @"";
  if (text.length > FLMessageLimit) {
    text = [NSString stringWithFormat:@"%@… (%lu more characters)",
                                      [text substringToIndex:FLMessageLimit],
                                      (unsigned long)(text.length - FLMessageLimit)];
  }
  NSDate *moment = date ?: [NSDate date];
  NSString *line = [NSString stringWithFormat:@"%@\t%@\t%@\t%@\n", FLTimestamp(moment),
                                              FLLevelLetter(level),
                                              FLEscape(source ?: @""), FLEscape(text)];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  NSString *hour = FLHourKey([NSDate date]);
  dispatch_async(_queue, ^{
    [self writeLine:data stream:stream hour:hour];
  });
}

- (NSString *)saveSnapshot:(NSString *)kind
                    pieces:(BOOL (^)(void (^write)(NSString *piece)))pieces {
  NSString *folder = [[FLLivePath() stringByAppendingPathComponent:FLSnapshotFolder]
    stringByAppendingPathComponent:kind];
  FLMakeDirectory(folder);
  NSString *name = [FLMomentKey([NSDate date]) stringByAppendingString:@".txt"];
  NSString *path = [folder stringByAppendingPathComponent:name];
  NSString *partial = [path stringByAppendingString:@".part"];
  int handle = open(partial.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (handle < 0) {
    return nil;
  }
  __block BOOL written = YES;
  BOOL collected = pieces(^(NSString *piece) {
    written = written && FLWriteText(handle, piece);
  });
  close(handle);
  if (!collected || !written ||
      rename(partial.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
    unlink(partial.fileSystemRepresentation);
    return nil;
  }
  chmod(path.fileSystemRepresentation, 0644);
  return path;
}

- (NSString *)importFile:(NSString *)path folder:(NSString *)folder {
  NSString *base = [[FLLivePath() stringByAppendingPathComponent:FLImportFolder]
    stringByAppendingPathComponent:folder];
  FLMakeDirectory(base);
  NSString *target = [base stringByAppendingPathComponent:path.lastPathComponent];
  int input = open(path.fileSystemRepresentation, O_RDONLY);
  if (input < 0) {
    return nil;
  }
  struct stat info;
  fstat(input, &info);
  NSString *partial = [target stringByAppendingString:@".part"];
  int output = open(partial.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (output < 0) {
    close(input);
    return nil;
  }
  BOOL copied = FLCopyAll(input, output);
  close(input);
  close(output);
  if (!copied ||
      rename(partial.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
    unlink(partial.fileSystemRepresentation);
    return nil;
  }
  struct timeval times[2];
  times[0].tv_sec = info.st_mtime;
  times[0].tv_usec = 0;
  times[1] = times[0];
  utimes(target.fileSystemRepresentation, times);
  return target;
}

- (NSSet<NSString *> *)openPaths {
  NSMutableSet *paths = [NSMutableSet new];
  [_hours enumerateKeysAndObjectsUsingBlock:^(NSString *stream, NSString *hour, BOOL *stop) {
    [paths addObject:[self pathForStream:stream hour:hour]];
  }];
  return paths;
}

- (NSDictionary *)maintainNow {
  NSDictionary *settings = [FLSettings current];
  double archiveAfter = [settings[FLSettingArchiveAfter] doubleValue];
  double deleteAfter = [settings[FLSettingDeleteAfter] doubleValue];
  uint64_t limit = [settings[FLSettingStoreLimit] unsignedLongLongValue];
  double now = [NSDate date].timeIntervalSince1970;
  NSSet *open = [self openPaths];
  NSUInteger archived = 0, deleted = 0, trimmed = 0, failed = 0;

  for (NSDictionary *file in FLFilesUnder(FLLivePath())) {
    NSString *path = file[@"path"];
    if ([path hasSuffix:@".part"]) {
      if (now - [file[@"modified"] doubleValue] >= FLPartialAfter) {
        unlink(path.fileSystemRepresentation);
      }
      continue;
    }
    if ([open containsObject:path]) {
      continue;
    }
    if (now - [file[@"modified"] doubleValue] < archiveAfter) {
      continue;
    }
    NSString *relative = file[@"relative"];
    NSString *target = [[FLArchivePath() stringByAppendingPathComponent:relative]
      stringByAppendingString:@".gz"];
    BOOL copies = [relative hasPrefix:[FLImportFolder stringByAppendingString:@"/"]];
    if (FLGzipFile(path, target, !copies)) {
      unlink(path.fileSystemRepresentation);
      archived++;
    } else {
      failed++;
    }
  }

  NSMutableArray *kept = [NSMutableArray new];
  uint64_t total = 0;
  for (NSDictionary *file in FLFilesUnder(FLArchivePath())) {
    NSString *path = file[@"path"];
    if (now - [file[@"modified"] doubleValue] >= deleteAfter ||
        [path hasSuffix:@".part"]) {
      unlink(path.fileSystemRepresentation);
      deleted++;
    } else {
      [kept addObject:file];
      total += [file[@"size"] unsignedLongLongValue];
    }
  }

  NSArray *live = FLFilesUnder(FLLivePath());
  for (NSDictionary *file in live) {
    total += [file[@"size"] unsignedLongLongValue];
  }
  NSSortDescriptor *oldestFirst = [NSSortDescriptor sortDescriptorWithKey:@"modified"
                                                               ascending:YES];
  NSMutableArray *candidates =
    [[kept sortedArrayUsingDescriptors:@[ oldestFirst ]] mutableCopy];
  for (NSDictionary *file in [live sortedArrayUsingDescriptors:@[ oldestFirst ]]) {
    if (![open containsObject:file[@"path"]]) {
      [candidates addObject:file];
    }
  }
  for (NSDictionary *file in candidates) {
    if (limit == 0 || total <= limit) {
      break;
    }
    if (unlink([file[@"path"] fileSystemRepresentation]) == 0) {
      total -= MIN(total, [file[@"size"] unsignedLongLongValue]);
      trimmed++;
    }
  }

  FLRemoveEmptyFolders(FLArchivePath());
  FLRemoveEmptyFolders(FLLivePath());
  return @{
    @"archived" : @(archived),
    @"deleted" : @(deleted),
    @"trimmed" : @(trimmed),
    @"failed" : @(failed),
    @"bytes" : @(total),
  };
}

- (NSDictionary *)maintain {
  __block NSDictionary *result = nil;
  dispatch_sync(_queue, ^{
    result = [self maintainNow];
  });
  return result;
}

- (NSDictionary *)counts {
  __block NSDictionary *counts = nil;
  dispatch_sync(_queue, ^{
    counts = [self->_counts copy];
  });
  return counts;
}

- (void)sync {
  dispatch_sync(_queue, ^{
  });
}

@end
