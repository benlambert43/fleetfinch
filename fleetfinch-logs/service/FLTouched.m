#import "FLTouched.h"

#import <fts.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/stat.h>

#import "FLCommon.h"
#import "FLReport.h"
#import "FLStatus.h"
#import "FLSystemInfo.h"

static const uint64_t FLBlock = 512;
static const NSUInteger FLFilesNamed = 40;
static const NSUInteger FLGroupDepth = 4;
static const NSUInteger FLFilesListed = 20000;

static NSDate *FLDay(id value) {
  return [value isKindOfClass:[NSDate class]] ? value : nil;
}

NSString *FLLastReadText(NSDate *last, NSDictionary *reading) {
  NSDate *made = FLDay(reading[@"made"]);
  if (last == nil) {
    return @"";
  }
  if (made != nil && [last compare:made] == NSOrderedAscending) {
    return @"not read since iOS was installed";
  }
  return [@"last read " stringByAppendingString:FLFormatDay(last)];
}

NSString *FLLastReadSentence(long long last, NSDictionary *reading) {
  if (last <= 0) {
    return @"";
  }
  NSString *text = FLLastReadText([NSDate dateWithTimeIntervalSince1970:(double)last], reading);
  return [NSString stringWithFormat:@"%@%@.", [text substringToIndex:1].uppercaseString,
                                    [text substringFromIndex:1]];
}

static NSDictionary *FLWeighed(NSDictionary *row, id weight) {
  NSMutableDictionary *weighed = [row mutableCopy];
  weighed[@"weight"] = weight ?: @0;
  return weighed;
}

static void FLSortHeaviest(NSMutableArray<NSDictionary *> *rows) {
  [rows sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult order = [second[@"weight"] compare:first[@"weight"]];
    return order != NSOrderedSame ? order : [first[@"title"] compare:second[@"title"]];
  }];
}

static uint64_t FLWeightOf(NSArray<NSDictionary *> *rows) {
  uint64_t total = 0;
  for (NSDictionary *row in rows) {
    total += [row[@"bytes"] unsignedLongLongValue];
  }
  return total;
}

static NSString *FLFilesSaid(NSDictionary *thing, NSDictionary *reading) {
  NSUInteger read = [thing[@"read"] unsignedIntegerValue];
  NSUInteger listed = [thing[@"listed"] unsignedIntegerValue];
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  uint64_t bytes = [thing[@"bytes"] unsignedLongLongValue];
  if (bytes > 0) {
    [parts addObject:FLFormatBytes(bytes)];
  }
  if (read == 0) {
    [parts addObject:[NSString stringWithFormat:@"%@, none read",
                                                FLReportCount([thing[@"files"]
                                                                unsignedLongLongValue],
                                                              @"file", @"files")]];
  } else {
    [parts addObject:[NSString stringWithFormat:@"%lu of %@ read, %@ of it",
                                                (unsigned long)read,
                                                FLReportCount([thing[@"files"]
                                                                unsignedLongLongValue],
                                                              @"file", @"files"),
                                                FLFormatBytes([thing[@"readBytes"]
                                                  unsignedLongLongValue])]];
  }
  if (listed > 0 && read == 0) {
    [parts addObject:[NSString stringWithFormat:@"only the %@ read",
                                                listed == 1
                                                  ? @"file that describes it was"
                                                  : @"files that describe it were"]];
  }
  NSString *last = FLLastReadText(FLDay(thing[@"lastRead"]), reading);
  if (last.length > 0) {
    [parts addObject:last];
  }
  return [parts componentsJoinedByString:@" · "];
}

static NSDictionary *FLThingRow(NSString *title, NSString *kind, NSDictionary *thing,
                                NSDictionary *reading) {
  NSMutableDictionary *row = [FLReportRow(title, FLFilesSaid(thing, reading), @[
    @[ @"Kind", kind ?: @"" ],
    @[ @"Path", thing[@"path"] ?: @"" ],
    @[ @"Files", [thing[@"files"] description] ?: @"" ],
    @[ @"Files read", [thing[@"read"] description] ?: @"0" ],
    @[ @"Files read that only describe it", [thing[@"listed"] description] ?: @"" ],
    @[ @"Last read", FLLastReadText(FLDay(thing[@"lastRead"]), reading) ],
  ]) mutableCopy];
  row[@"bytes"] = thing[@"bytes"] ?: @0;
  return row;
}

static NSString *FLGroupOf(NSString *path, NSSet<NSString *> *items) {
  NSString *walked = path.stringByDeletingLastPathComponent;
  NSString *outermost = nil;
  while (walked.length > 1) {
    if ([items containsObject:walked]) {
      outermost = walked;
    }
    walked = walked.stringByDeletingLastPathComponent;
  }
  if (outermost != nil) {
    return outermost;
  }
  NSArray<NSString *> *parts = [path.stringByDeletingLastPathComponent
    componentsSeparatedByString:@"/"];
  NSUInteger depth = FLGroupDepth + 1;
  return parts.count <= depth
    ? path.stringByDeletingLastPathComponent
    : [[parts subarrayWithRange:NSMakeRange(0, depth)] componentsJoinedByString:@"/"];
}

static NSArray<NSDictionary *> *FLStartingRows(NSDictionary *startup, NSSet<NSString *> *items) {
  NSDictionary<NSString *, NSNumber *> *files = startup[@"files"];
  NSUInteger starts = [startup[@"starts"] unsignedIntegerValue];
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups =
    [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *most = [NSMutableDictionary new];
  for (NSString *path in [files isKindOfClass:[NSDictionary class]] ? files : @{}) {
    NSString *group = FLGroupOf(path, items);
    NSMutableArray<NSString *> *inside = groups[group] ?: [NSMutableArray new];
    [inside addObject:path];
    groups[group] = inside;
    most[group] = @(MAX(most[group].unsignedIntegerValue, files[path].unsignedIntegerValue));
  }
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSString *group in groups) {
    NSArray<NSString *> *inside = [groups[group] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *path in inside) {
      if (names.count == FLFilesNamed) {
        [names addObject:[NSString stringWithFormat:@"and %lu more",
                                                    (unsigned long)(inside.count - FLFilesNamed)]];
        break;
      }
      [names addObject:[path substringFromIndex:MIN(path.length, group.length + 1)]];
    }
    NSString *detail = [NSString
      stringWithFormat:@"%@ read, in up to %@ of %@ · %@",
                       FLReportCount(inside.count, @"file", @"files"), most[group],
                       FLReportCount(starts, @"start", @"starts"), group];
    [rows addObject:FLWeighed(FLReportRow(group.lastPathComponent, detail, @[
                                @[ @"Path", group ],
                                @[ @"Files", [names componentsJoinedByString:@", "] ],
                              ]),
                              @(inside.count))];
  }
  NSMutableArray<NSDictionary *> *sorted = [rows mutableCopy];
  FLSortHeaviest(sorted);
  return sorted;
}

NSDictionary *FLTouchedReport(FLReportSource source) {
  NSDictionary *inventory = source(FLInventoryState);
  NSDictionary *reading = inventory[@"reading"];
  NSDictionary *startup = source(FLStartupState);
  NSDictionary<NSString *, NSString *> *kinds = @{
    @"app" : @"app",
    @"extension" : @"app extension",
    @"xpc" : @"XPC service",
    @"framework" : @"framework",
    @"bundle" : @"plug-in or bundle",
  };
  NSMutableArray<NSDictionary *> *unread = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *used = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *idle = [NSMutableArray new];
  NSMutableSet<NSString *> *folders = [NSMutableSet new];
  @autoreleasepool {
    for (NSDictionary *item in inventory[@"items"]) {
      NSString *kind = item[@"kind"];
      NSString *path = item[@"path"];
      if (path == nil || [item[@"data"] boolValue]) {
        continue;
      }
      if (kinds[kind] != nil) {
        [folders addObject:path];
      }
      if ([item[@"inside"] length] > 0) {
        continue;
      }
      BOOL file = [kind isEqualToString:@"program"] || [kind isEqualToString:@"library"];
      if (file && ![item[@"inCache"] boolValue] && item[@"lastRead"] != nil &&
          [item[@"read"] unsignedIntegerValue] == 0) {
        NSString *detail = [NSString
          stringWithFormat:@"%@ · %@ · %@",
                           FLFormatBytes([item[@"bytes"] unsignedLongLongValue]),
                           FLLastReadText(FLDay(item[@"lastRead"]), reading), path];
        NSMutableDictionary *row =
          [FLReportRow(path.lastPathComponent, detail, @[ @[ @"Kind", kind ], @[ @"Path", path ] ])
            mutableCopy];
        row[@"bytes"] = item[@"bytes"] ?: @0;
        [idle addObject:FLWeighed(row, item[@"bytes"])];
      }
      if (kinds[kind] == nil || [item[@"files"] unsignedIntegerValue] == 0) {
        continue;
      }
      NSDictionary *row = FLThingRow(item[@"name"] ?: path.lastPathComponent, kinds[kind], item,
                                     reading);
      if ([item[@"read"] unsignedIntegerValue] == 0) {
        [unread addObject:FLWeighed(row, item[@"bytes"])];
      } else {
        [used addObject:FLWeighed(row, item[@"lastRead"] ?: [NSDate distantPast])];
      }
    }
  }
  NSMutableArray<NSDictionary *> *quiet = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *busy = [NSMutableArray new];
  for (NSDictionary *area in inventory[@"areas"]) {
    NSDictionary *row = FLThingRow(area[@"path"], @"folder of other files", area, reading);
    if ([area[@"read"] unsignedIntegerValue] == 0) {
      [quiet addObject:FLWeighed(row, area[@"bytes"])];
    } else {
      [busy addObject:FLWeighed(row, area[@"lastRead"] ?: [NSDate distantPast])];
    }
  }
  NSMutableArray<NSDictionary *> *languages = [NSMutableArray new];
  for (NSDictionary *language in reading[@"languages"]) {
    NSMutableDictionary *row =
      [FLReportRow(language[@"name"], FLFilesSaid(language, reading), nil) mutableCopy];
    row[@"bytes"] = language[@"bytes"] ?: @0;
    [languages addObject:row];
  }
  NSMutableArray<NSDictionary *> *largest = [NSMutableArray new];
  for (NSDictionary *file in reading[@"largest"]) {
    NSString *path = file[@"path"] ?: @"";
    NSString *detail = [NSString
      stringWithFormat:@"%@ · %@ · %@", FLFormatBytes([file[@"bytes"] unsignedLongLongValue]),
                       FLLastReadText(FLDay(file[@"lastRead"]), reading), path];
    NSMutableDictionary *row =
      [FLReportRow(path.lastPathComponent, detail, @[ @[ @"Path", path ] ]) mutableCopy];
    row[@"bytes"] = file[@"bytes"] ?: @0;
    [largest addObject:row];
  }
  for (NSMutableArray<NSDictionary *> *each in @[ unread, used, idle, quiet, busy ]) {
    FLSortHeaviest(each);
  }
  NSArray<NSDictionary *> *starting = FLStartingRows(startup, folders);

  NSDate *counting = FLDay(reading[@"began"]);
  NSDate *swept = FLDay(reading[@"swept"]);
  NSDate *boot = FLDay(reading[@"boot"]);
  NSMutableArray<NSString *> *notes = [NSMutableArray new];
  if (counting == nil) {
    [notes addObject:@"What is installed has not been listed since Finch Logs began to look at "
                     @"when files were last read. The service lists it within a few minutes of "
                     @"starting."];
  } else {
    [notes addObject:[NSString
                       stringWithFormat:@"Counting since %@, as of the listing made %@. Of the "
                                        @"%@ files on the system volume, %@ have been read "
                                        @"since then, taking %@ of %@, and %@ since the device "
                                        @"last started%@.",
                                        FLFormatDay(counting),
                                        swept == nil ? @"" : FLFormatDay(swept),
                                        reading[@"files"] ?: @0, reading[@"read"] ?: @0,
                                        FLFormatBytes([reading[@"readBytes"]
                                          unsignedLongLongValue]),
                                        FLFormatBytes([reading[@"bytes"] unsignedLongLongValue]),
                                        reading[@"sinceStart"] ?: @0,
                                        boot == nil
                                          ? @""
                                          : [@" on " stringByAppendingString:FLFormatDay(boot)]]];
    [notes addObject:[NSString
                       stringWithFormat:@"%@ files, taking %@, have not been read since iOS was "
                                        @"installed on this device: they still carry a time of "
                                        @"last reading from before the system volume was made. "
                                        @"iOS keeps no such times until a jailbreak makes that "
                                        @"volume writable, so this covers the time since "
                                        @"then.",
                                        reading[@"untouched"] ?: @0,
                                        FLFormatBytes([reading[@"untouchedBytes"]
                                          unsignedLongLongValue])]];
  }
  [notes addObject:@"The file system notes when each file on the system volume was last read. "
                   @"Reading a file, mapping it into memory and running it all move that time, "
                   @"so this covers every file, all of the time, and costs nothing while the "
                   @"device runs. Finch Logs puts the time back after its own reading. A size "
                   @"is the space on the volume."];
  [notes addObject:@"A program that already holds a file in memory does not read it again, so "
                   @"what long-running services use shows once the device has restarted since "
                   @"the count began. Another tool that reads everything, such as a search of "
                   @"the whole volume, makes everything look read."];
  [notes addObject:@"A time from before the count began is shown as it stands. For a program or "
                   @"a library it may be an older Finch Logs' own doing, which read each of "
                   @"them whenever it listed what is installed."];
  NSUInteger starts = [startup[@"starts"] unsignedIntegerValue];
  NSString *started = starts == 0
    ? @"Nothing has been recorded about a start yet. The service lists what the device read "
      @"while starting when it lists what is installed within fifteen minutes of a start."
    : [NSString stringWithFormat:@"What the device read while starting has been recorded for "
                                 @"%@, the last on %@: every file read from the start "
                                 @"until the listing a few minutes after it. iOS keeps the "
                                 @"system volume read-only for the first part of a start, "
                                 @"about 20 seconds on this kind of jailbreak, and nothing "
                                 @"read then leaves a trace.",
                                 FLReportCount(starts, @"start", @"starts"),
                                 FLDay(startup[@"at"]) == nil ? @"" : FLFormatDay(startup[@"at"])];
  NSString * (^sized)(NSArray<NSDictionary *> *, NSString *) =
    ^NSString *(NSArray<NSDictionary *> *rows, NSString *note) {
      return [NSString stringWithFormat:@"%@ in all. %@", FLFormatBytes(FLWeightOf(rows)), note];
    };
  return @{
    @"title" : FLReportTitle(@"touched"),
    @"made" : [NSDate date],
    @"notes" : notes,
    @"sections" : @[
      FLReportSection(@"Installed things nothing has read",
                      sized(unread, @"Apps, extensions, XPC services, frameworks and bundles "
                                    @"with no file read since the count began, largest first."),
                      unread),
      FLReportSection(@"Folders of other files nothing has read",
                      sized(quiet, @"Fonts, sounds, language data and the like, outside any "
                                   @"installed thing."),
                      quiet),
      FLReportSection(@"Programs and libraries nothing has read",
                      sized(idle, @"Single files outside any app or bundle. Running a program "
                                  @"or loading a library reads its file."),
                      idle),
      FLReportSection(@"Translations, by language",
                      sized(languages, @"Every folder of translated text and pictures on the "
                                       @"system volume, added up by language."),
                      languages),
      FLReportSection(@"Largest files nothing has read",
                      sized(largest, @"Single files of 128 KB or more, wherever they are."),
                      largest),
      FLReportSection(@"Read while the device was starting", started, starting),
      FLReportSection(@"Installed things that were read from", @"The latest first.", used),
      FLReportSection(@"Folders of other files that were read from", @"The latest first.", busy),
    ],
  };
}

NSDictionary *FLReadingUnder(NSString *path, NSDictionary *inventory) {
  NSDictionary *reading = inventory[@"reading"];
  NSDictionary<NSString *, NSNumber *> *starting = FLReadState(FLStartupState)[@"files"];
  if (![starting isKindOfClass:[NSDictionary class]]) {
    starting = @{};
  }
  long long counting = (long long)[FLDay(reading[@"began"]) timeIntervalSince1970];
  NSDate *boot = FLBootTime();
  long long started = boot == nil ? 0 : (long long)boot.timeIntervalSince1970;
  NSMutableArray<NSArray *> *files = [NSMutableArray new];
  NSMutableArray<NSString *> *early = [NSMutableArray new];
  NSUInteger count = 0, read = 0, since = 0;
  long long last = 0;
  char *paths[] = {(char *)path.fileSystemRepresentation, NULL};
  FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
  FTSENT *entry = NULL;
  while (tree != NULL && (entry = fts_read(tree)) != NULL) {
    if (entry->fts_info != FTS_F) {
      continue;
    }
    @autoreleasepool {
      long long when = (long long)entry->fts_statp->st_atimespec.tv_sec;
      NSString *file =
        [[NSFileManager defaultManager] stringWithFileSystemRepresentation:entry->fts_path
                                                                    length:entry->fts_pathlen];
      count += 1;
      read += counting > 0 && when >= counting ? 1 : 0;
      since += started > 0 && when >= started ? 1 : 0;
      last = MAX(last, when);
      if (file != nil && starting[file] != nil) {
        [early addObject:file];
      }
      if (file != nil && files.count < FLFilesListed) {
        [files addObject:@[
          @(when), @((uint64_t)entry->fts_statp->st_blocks * FLBlock), file,
          starting[file] ?: @0
        ]];
      }
    }
  }
  if (tree != NULL) {
    fts_close(tree);
  }
  return @{
    @"files" : @(count),
    @"read" : @(read),
    @"sinceStart" : @(since),
    @"last" : @(last),
    @"starting" : early,
    @"listed" : files,
  };
}

static void FLSay(NSString *text) {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  fwrite(data.bytes, 1, data.length, stdout);
}

static int FLShowStarting(void) {
  NSDictionary *startup = FLReadState(FLStartupState);
  NSDictionary<NSString *, NSNumber *> *files = startup[@"files"];
  NSUInteger starts = [startup[@"starts"] unsignedIntegerValue];
  if (starts == 0 || ![files isKindOfClass:[NSDictionary class]]) {
    fprintf(stderr, "finchlog: nothing has been recorded about a start yet\n");
    return 1;
  }
  FLSay([NSString stringWithFormat:@"What the device read while starting, over %@, the last on "
                                   @"%@: %lu files\nstarts\tpath\n",
                                   FLReportCount(starts, @"start", @"starts"),
                                   FLDay(startup[@"at"]) == nil ? @"" : FLFormatDay(startup[@"at"]),
                                   (unsigned long)files.count]);
  for (NSString *path in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    FLSay([NSString stringWithFormat:@"%@\t%@\n", files[path], FLEscape(path)]);
  }
  return 0;
}

int FLTouchedCommand(NSArray<NSString *> *arguments) {
  if ([arguments containsObject:@"--starting"]) {
    return FLShowStarting();
  }
  NSString *word = arguments.count > 0 && ![arguments[0] hasPrefix:@"--"] ? arguments[0] : nil;
  if (word == nil) {
    return -1;
  }
  char resolved[PATH_MAX];
  if (![word hasPrefix:@"/"] || realpath(word.fileSystemRepresentation, resolved) == NULL) {
    fprintf(stderr, "finchlog: give the full path of a file or folder that is there\n");
    return 64;
  }
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *path = [manager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
  NSDictionary *inventory = FLReadState(FLInventoryState);
  NSDictionary *reading = inventory[@"reading"];
  NSDictionary *found = FLReadingUnder(path, inventory);
  NSDate *counting = FLDay(reading[@"began"]);
  long long began = (long long)counting.timeIntervalSince1970;
  NSArray<NSArray *> *files =
    [found[@"listed"] sortedArrayUsingComparator:^NSComparisonResult(NSArray *first,
                                                                     NSArray *second) {
      NSComparisonResult order = [second[0] compare:first[0]];
      return order != NSOrderedSame ? order : [first[2] compare:second[2]];
    }];
  long long last = [found[@"last"] longLongValue];
  FLSay([NSString
    stringWithFormat:@"%@: %@ files, %@ read since %@, %@ since the device last started, %@ "
                     @"while it was starting. %@\n",
                     path, found[@"files"], found[@"read"],
                     counting == nil ? @"the count began" : FLFormatDay(counting),
                     found[@"sinceStart"], @([found[@"starting"] count]),
                     FLLastReadSentence(last, reading)]);
  FLSay(@"last read\tsince the count began\tstarts it was read in\tsize\tpath\n");
  for (NSArray *file in files) {
    long long when = [file[0] longLongValue];
    FLSay([NSString
      stringWithFormat:@"%@\t%@\t%@\t%@\t%@\n",
                       FLFormatDay([NSDate dateWithTimeIntervalSince1970:(double)when]),
                       began > 0 && when >= began ? @"yes" : @"no", file[3],
                       FLFormatBytes([file[1] unsignedLongLongValue]), FLEscape(file[2])]);
  }
  return 0;
}
