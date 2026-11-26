#import "FLReader.h"

#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

#import "FLStore.h"

static const NSUInteger FLTailBytes = 2 * 1024 * 1024;
static const NSUInteger FLArchiveBytes = 48 * 1024 * 1024;
static const NSUInteger FLReadChunk = 256 * 1024;
static const NSUInteger FLStampWidth = 29;

@implementation FLLogFile
@end

@implementation FLRecord

+ (instancetype)recordFromLine:(NSString *)line stream:(NSString *)stream {
  NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
  FLRecord *record = [FLRecord new];
  record.stream = stream;
  if (parts.count < 4) {
    record.level = FLLevelNotice;
    record.source = @"";
    record.message = line;
    return record;
  }
  record.date = FLDateFromTimestamp(parts[0]);
  record.level = FLLevelFromLetter(parts[1]);
  record.source = FLUnescape(parts[2]);
  NSArray *rest = [parts subarrayWithRange:NSMakeRange(3, parts.count - 3)];
  record.message = FLUnescape([rest componentsJoinedByString:@"\t"]);
  return record;
}

@end

static NSArray<NSString *> *FLStreamOrder(void) {
  return @[
    @"system", @"kernel", @"boot", @"process", @"app", @"service", @"resource",
    @"power", @"network", @"connection", @"event", @"file", @"import", @"change",
    @"finchlogs"
  ];
}

static NSArray<NSString *> *FLFolderNames(NSString *path) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSMutableArray *names = [NSMutableArray new];
  for (NSString *name in [manager contentsOfDirectoryAtPath:path error:NULL]) {
    BOOL folder = NO;
    NSString *full = [path stringByAppendingPathComponent:name];
    if ([manager fileExistsAtPath:full isDirectory:&folder] && folder) {
      [names addObject:name];
    }
  }
  return names;
}

static NSArray<NSString *> *FLSplitLines(NSData *data) {
  if (data.length == 0) {
    return @[];
  }
  NSString *text = FLStringFromData(data);
  NSMutableArray *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
  if ([lines.lastObject length] == 0) {
    [lines removeLastObject];
  }
  return lines;
}

@implementation FLReader

+ (NSArray<NSString *> *)streams {
  NSMutableSet *found = [NSMutableSet new];
  [found addObjectsFromArray:FLFolderNames(FLLivePath())];
  [found addObjectsFromArray:FLFolderNames(FLArchivePath())];
  [found removeObject:FLSnapshotFolder];
  [found removeObject:FLImportFolder];
  NSArray *order = FLStreamOrder();
  return [found.allObjects sortedArrayUsingComparator:^(NSString *first, NSString *second) {
    NSUInteger left = [order indexOfObject:first];
    NSUInteger right = [order indexOfObject:second];
    if (left != right) {
      return left < right ? NSOrderedAscending : NSOrderedDescending;
    }
    return [first compare:second];
  }];
}

+ (NSArray<NSString *> *)knownStreams {
  return FLStreamOrder();
}

+ (NSString *)streamTitle:(NSString *)stream {
  NSDictionary *titles = @{
    @"system" : @"System Log",
    @"kernel" : @"Kernel",
    @"boot" : @"Boot",
    @"process" : @"Processes",
    @"app" : @"Apps",
    @"service" : @"Services",
    @"resource" : @"Resources",
    @"power" : @"Power",
    @"network" : @"Network",
    @"connection" : @"Connections",
    @"event" : @"Events",
    @"file" : @"Log Files",
    @"import" : @"Dumps",
    @"change" : @"Changes",
    @"finchlogs" : @"Finch Logs",
  };
  return titles[stream] ?: stream;
}

+ (NSString *)streamDescription:(NSString *)stream {
  NSDictionary *descriptions = @{
    @"system" : @"Every message the system log receives, from the kernel, services and apps",
    @"kernel" : @"What the kernel prints while Finch Logs is running",
    @"boot" : @"Each start of the device: when, what was running first, and in what order",
    @"process" : @"Every process that starts or exits, with what started it",
    @"app" : @"Apps opening, closing, coming to the front, being installed, updated or removed",
    @"service" : @"Background services that launchd starts and stops",
    @"resource" : @"Processor, memory, storage, network and battery use, sampled regularly",
    @"power" : @"Sleep and wake, charging, battery level, lock and display state",
    @"network" : @"Interfaces, addresses and Wi-Fi networks as they change",
    @"connection" : @"Each connection a process made, with the server and the bytes each way",
    @"event" : @"Notifications the system posts about its own state",
    @"file" : @"Lines other parts of the system wrote to log files of their own",
    @"import" : @"Crash reports and other dumps the system wrote, as they are copied in",
    @"change" : @"Each part of iOS that was set aside, put back or deleted with finchlog",
    @"finchlogs" : @"What Finch Logs itself is doing",
  };
  return descriptions[stream] ?: @"";
}

+ (NSArray<NSString *> *)groupsUnder:(NSString *)folder {
  NSMutableSet *groups = [NSMutableSet new];
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *root in @[ FLLivePath(), FLArchivePath() ]) {
    NSString *base = [root stringByAppendingPathComponent:folder];
    for (NSString *relative in [manager enumeratorAtPath:base]) {
      BOOL directory = NO;
      NSString *full = [base stringByAppendingPathComponent:relative];
      if ([manager fileExistsAtPath:full isDirectory:&directory] && !directory) {
        NSString *parent = relative.stringByDeletingLastPathComponent;
        [groups addObject:parent.length == 0
                            ? folder
                            : [folder stringByAppendingPathComponent:parent]];
      }
    }
  }
  return [groups.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<FLLogFile *> *)filesInGroup:(NSString *)group archived:(BOOL)archived {
  NSString *root = archived ? FLArchivePath() : FLLivePath();
  NSString *folder = [root stringByAppendingPathComponent:group];
  NSMutableArray *files = [NSMutableArray new];
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder
                                                                         error:NULL];
  for (NSString *name in names) {
    NSString *path = [folder stringByAppendingPathComponent:name];
    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        [name hasSuffix:@".part"]) {
      continue;
    }
    FLLogFile *file = [FLLogFile new];
    file.path = path;
    file.group = group;
    file.name = archived && [name hasSuffix:@".gz"] ? name.stringByDeletingPathExtension
                                                    : name;
    file.archived = archived;
    file.size = (uint64_t)info.st_size;
    file.modified = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.st_mtime];
    [files addObject:file];
  }
  return files;
}

+ (NSArray<FLLogFile *> *)sorted:(NSArray<FLLogFile *> *)files {
  return [files sortedArrayUsingComparator:^(FLLogFile *first, FLLogFile *second) {
    NSComparisonResult order = [first.name compare:second.name];
    if (order != NSOrderedSame) {
      return order;
    }
    return first.archived == second.archived
      ? NSOrderedSame
      : (first.archived ? NSOrderedAscending : NSOrderedDescending);
  }];
}

+ (NSArray<FLLogFile *> *)liveFilesInGroup:(NSString *)group {
  return [self sorted:[self filesInGroup:group archived:NO]];
}

+ (NSArray<FLLogFile *> *)filesInGroup:(NSString *)group {
  NSArray *archived = [self filesInGroup:group archived:YES];
  NSArray *live = [self filesInGroup:group archived:NO];
  return [self sorted:[archived arrayByAddingObjectsFromArray:live]];
}

+ (NSData *)plainDataOfFile:(NSString *)path tail:(NSUInteger)maximum {
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return nil;
  }
  off_t size = lseek(handle, 0, SEEK_END);
  NSUInteger wanted = maximum == 0 ? FLTailBytes : maximum;
  off_t start = size > (off_t)wanted ? size - (off_t)wanted : 0;
  lseek(handle, start, SEEK_SET);
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(size - start)];
  NSUInteger filled = 0;
  while (filled < data.length) {
    ssize_t count = read(handle, (uint8_t *)data.mutableBytes + filled,
                         data.length - filled);
    if (count <= 0) {
      break;
    }
    filled += (NSUInteger)count;
  }
  close(handle);
  data.length = filled;
  if (start > 0) {
    NSRange newline = [data rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                options:0
                                  range:NSMakeRange(0, data.length)];
    if (newline.location != NSNotFound) {
      return [data subdataWithRange:NSMakeRange(newline.location + 1,
                                                data.length - newline.location - 1)];
    }
  }
  return data;
}

+ (NSData *)archivedDataOfFile:(NSString *)path tail:(NSUInteger)maximum {
  gzFile input = gzopen(path.fileSystemRepresentation, "rb");
  if (input == NULL) {
    return nil;
  }
  NSMutableData *data = [NSMutableData new];
  void *buffer = malloc(FLReadChunk);
  int count = 0;
  while ((count = gzread(input, buffer, (unsigned)FLReadChunk)) > 0) {
    [data appendBytes:buffer length:(NSUInteger)count];
    if (data.length > FLArchiveBytes) {
      [data replaceBytesInRange:NSMakeRange(0, data.length - FLArchiveBytes / 2)
                      withBytes:NULL
                         length:0];
    }
  }
  free(buffer);
  gzclose(input);
  NSUInteger wanted = maximum == 0 ? FLTailBytes : maximum;
  if (data.length <= wanted) {
    return data;
  }
  NSRange tail = NSMakeRange(data.length - wanted, wanted);
  NSRange newline = [data rangeOfData:[NSData dataWithBytes:"\n" length:1]
                              options:0
                                range:tail];
  NSUInteger start = newline.location == NSNotFound ? tail.location
                                                    : newline.location + 1;
  return [data subdataWithRange:NSMakeRange(start, data.length - start)];
}

+ (NSData *)startOfFile:(NSString *)path limit:(NSUInteger)limit {
  BOOL archived = [path hasSuffix:@".gz"];
  gzFile packed = archived ? gzopen(path.fileSystemRepresentation, "rb") : NULL;
  int handle = archived ? -1 : open(path.fileSystemRepresentation, O_RDONLY);
  if (packed == NULL && handle < 0) {
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:limit];
  NSUInteger filled = 0;
  while (filled < limit) {
    void *room = (uint8_t *)data.mutableBytes + filled;
    NSUInteger wanted = MIN(limit - filled, FLReadChunk);
    long count = archived ? gzread(packed, room, (unsigned)wanted) : read(handle, room, wanted);
    if (count <= 0) {
      break;
    }
    filled += (NSUInteger)count;
  }
  if (archived) {
    gzclose(packed);
  } else {
    close(handle);
  }
  data.length = filled;
  return data;
}

+ (NSData *)dataOfFile:(NSString *)path tail:(NSUInteger)maximum {
  return [path hasSuffix:@".gz"] ? [self archivedDataOfFile:path tail:maximum]
                                 : [self plainDataOfFile:path tail:maximum];
}

+ (NSArray<NSString *> *)linesOfFile:(NSString *)path tail:(NSUInteger)maximum {
  return FLSplitLines([self dataOfFile:path tail:maximum]);
}

+ (NSArray<FLRecord *> *)recordsOfFile:(NSString *)path
                               stream:(NSString *)stream
                                 tail:(NSUInteger)maximum {
  NSMutableArray *records = [NSMutableArray new];
  for (NSString *line in [self linesOfFile:path tail:maximum]) {
    if (line.length > 0) {
      [records addObject:[FLRecord recordFromLine:line stream:stream]];
    }
  }
  return records;
}

+ (NSArray<FLRecord *> *)tailOfStream:(NSString *)stream count:(NSUInteger)count {
  NSMutableArray *records = [NSMutableArray new];
  for (FLLogFile *file in [self liveFilesInGroup:stream].reverseObjectEnumerator) {
    NSArray *found = [self recordsOfFile:file.path stream:stream tail:0];
    [records replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:found];
    if (records.count >= count) {
      break;
    }
  }
  if (records.count > count) {
    [records removeObjectsInRange:NSMakeRange(0, records.count - count)];
  }
  return records;
}

+ (NSDictionary<NSString *, NSArray *> *)positionsFromCursor:(NSString *)cursor {
  NSMutableDictionary *positions = [NSMutableDictionary new];
  for (NSString *entry in [cursor componentsSeparatedByString:@","]) {
    NSArray<NSString *> *parts = [entry componentsSeparatedByString:@":"];
    if (parts.count == 3) {
      positions[parts[0]] = @[ parts[1], @(parts[2].longLongValue) ];
    }
  }
  return positions;
}

+ (NSArray<NSString *> *)linesOfFile:(NSString *)path
                              from:(off_t)offset
                             limit:(NSUInteger)limit
                               end:(off_t *)end {
  NSMutableArray *lines = [NSMutableArray new];
  *end = offset;
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return lines;
  }
  off_t size = lseek(handle, 0, SEEK_END);
  off_t position = offset > size ? 0 : offset;
  *end = position;
  NSMutableData *pending = [NSMutableData new];
  void *buffer = malloc(FLReadChunk);
  while (lines.count < limit && position + (off_t)pending.length < size) {
    ssize_t count = pread(handle, buffer, FLReadChunk, position + (off_t)pending.length);
    if (count <= 0) {
      break;
    }
    [pending appendBytes:buffer length:(NSUInteger)count];
    const uint8_t *bytes = pending.bytes;
    NSUInteger start = 0;
    for (NSUInteger index = 0; index < pending.length && lines.count < limit; index++) {
      if (bytes[index] != '\n') {
        continue;
      }
      NSData *line = [NSData dataWithBytes:bytes + start length:index - start];
      [lines addObject:FLStringFromData(line)];
      start = index + 1;
    }
    position += (off_t)start;
    [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
  }
  free(buffer);
  close(handle);
  *end = position;
  return lines;
}

+ (NSArray<NSString *> *)lastLines:(NSUInteger)wanted
                            ofFile:(NSString *)path
                             whole:(BOOL *)whole
                               end:(off_t *)end {
  off_t size = (off_t)FLFileSize(path);
  off_t window = (off_t)FLReadChunk;
  for (;;) {
    off_t start = size > window ? size - window : 0;
    NSMutableArray<NSString *> *lines = [[self linesOfFile:path
                                                      from:start
                                                     limit:NSUIntegerMax
                                                       end:end] mutableCopy];
    if (start > 0 && lines.count > 0) {
      [lines removeObjectAtIndex:0];
    }
    *whole = start == 0;
    if (start == 0 || lines.count >= wanted || window >= (off_t)FLTailBytes) {
      return lines;
    }
    window *= 2;
  }
}

+ (NSDictionary *)readAfterCursor:(NSString *)cursor
                          streams:(NSArray<NSString *> *)streams
                            limit:(NSUInteger)limit {
  BOOL initial = cursor.length == 0;
  NSDictionary *positions = [self positionsFromCursor:cursor ?: @""];
  NSMutableArray<NSArray *> *entries = [NSMutableArray new];
  NSMutableArray<NSString *> *next = [NSMutableArray new];
  NSString *floor = nil;
  BOOL more = NO;
  NSArray *wanted = streams.count > 0 ? streams : [self streams];
  for (NSString *stream in wanted) {
    NSArray<FLLogFile *> *files = [self liveFilesInGroup:stream];
    if (files.count == 0) {
      continue;
    }
    if (initial) {
      FLLogFile *newest = files.lastObject;
      off_t end = 0;
      BOOL whole = YES;
      NSMutableArray<NSString *> *found = [NSMutableArray new];
      NSUInteger index = files.count;
      while (whole && (index == files.count || found.count < limit) && index > 0) {
        index--;
        off_t reached = 0;
        NSArray *lines = [self lastLines:limit - found.count
                                  ofFile:files[index].path
                                   whole:&whole
                                     end:&reached];
        if (index == files.count - 1) {
          end = reached;
        }
        [found replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:lines];
      }
      NSString *first = found.firstObject;
      if ((!whole || index > 0) && first.length >= FLStampWidth) {
        NSString *stamp = [first substringToIndex:FLStampWidth];
        if (floor == nil || [stamp compare:floor] == NSOrderedDescending) {
          floor = stamp;
        }
      }
      for (NSString *line in found) {
        [entries addObject:@[ line, stream ]];
      }
      [next addObject:[NSString stringWithFormat:@"%@:%@:%lld", stream, newest.name,
                                                 (long long)end]];
      continue;
    }
    NSArray *position = positions[stream];
    NSString *fileName = position[0];
    off_t offset = [position[1] longLongValue];
    NSString *lastName = fileName ?: files.firstObject.name;
    off_t lastOffset = fileName == nil ? 0 : offset;
    NSUInteger taken = 0;
    for (FLLogFile *file in files) {
      if (fileName != nil && [file.name compare:fileName] == NSOrderedAscending) {
        continue;
      }
      off_t start = [file.name isEqualToString:fileName] ? offset : 0;
      off_t end = start;
      NSArray *lines = [self linesOfFile:file.path
                                    from:start
                                   limit:limit - taken
                                     end:&end];
      for (NSString *line in lines) {
        [entries addObject:@[ line, stream ]];
      }
      taken += lines.count;
      lastName = file.name;
      lastOffset = end;
      if (taken >= limit) {
        more = YES;
        break;
      }
    }
    [next addObject:[NSString stringWithFormat:@"%@:%@:%lld", stream, lastName,
                                               (long long)lastOffset]];
  }
  [entries sortWithOptions:NSSortStable
           usingComparator:^(NSArray *first, NSArray *second) {
             NSString *left = first[0];
             NSString *right = second[0];
             if (left.length < FLStampWidth || right.length < FLStampWidth) {
               return NSOrderedSame;
             }
             return [[left substringToIndex:FLStampWidth]
               compare:[right substringToIndex:FLStampWidth]];
           }];
  if (floor != nil) {
    NSUInteger kept = 0;
    while (kept < entries.count) {
      NSString *line = entries[kept][0];
      if (line.length >= FLStampWidth &&
          [[line substringToIndex:FLStampWidth] compare:floor] != NSOrderedAscending) {
        break;
      }
      kept++;
    }
    [entries removeObjectsInRange:NSMakeRange(0, kept)];
  }
  if (initial && entries.count > limit) {
    [entries removeObjectsInRange:NSMakeRange(0, entries.count - limit)];
  }
  NSMutableArray *lines = [NSMutableArray arrayWithCapacity:entries.count];
  for (NSArray *entry in entries) {
    [lines addObject:[NSString stringWithFormat:@"%@\t%@", entry[1], entry[0]]];
  }
  return @{
    @"lines" : lines,
    @"cursor" : [next componentsJoinedByString:@","],
    @"more" : @(more),
  };
}

@end
