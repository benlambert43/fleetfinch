#import "FLCandidates.h"

#import "FLChanges.h"
#import "FLCommon.h"
#import "FLReport.h"
#import "FLUsage.h"

static NSString *const FLStock = @"iOS";

static void FLAddUnder(NSMutableDictionary<NSString *, NSNumber *> *sums, NSString *path,
                       unsigned long long amount) {
  NSString *walked = path;
  while (amount > 0 && walked.length > 1) {
    sums[walked] = @(sums[walked].unsignedLongLongValue + amount);
    walked = walked.stringByDeletingLastPathComponent;
  }
}

static NSDictionary *FLCandidate(NSString *name, NSString *kind, NSString *path, uint64_t bytes,
                                 NSString *why, NSString *caution) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  if (bytes > 0) {
    [parts addObject:FLFormatBytes(bytes)];
  }
  [parts addObject:why];
  if (caution.length > 0) {
    [parts addObject:caution];
  }
  NSMutableDictionary *row = [FLReportRow(name, [parts componentsJoinedByString:@" · "], @[
    @[ @"Kind", kind ],
    @[ @"Path", path ?: @"" ],
    @[ @"Size", bytes > 0 ? FLFormatBytes(bytes) : @"" ],
    @[ @"Why it is listed", why ],
    @[ @"But", caution ?: @"" ],
  ]) mutableCopy];
  row[@"weight"] = @(bytes);
  return row;
}

static NSDictionary *FLCandidateSection(NSString *title, NSString *note,
                                        NSMutableArray<NSDictionary *> *rows) {
  [rows sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult order = [second[@"weight"] compare:first[@"weight"]];
    return order != NSOrderedSame ? order : [first[@"title"] compare:second[@"title"]];
  }];
  uint64_t total = 0;
  for (NSDictionary *row in rows) {
    total += [row[@"weight"] unsignedLongLongValue];
  }
  NSString *sized = [NSString stringWithFormat:@"%@ in all. %@", FLFormatBytes(total), note];
  return FLReportSection(title, sized, rows);
}

static NSString *FLJoinedCautions(NSArray<NSString *> *cautions) {
  NSMutableArray<NSString *> *said = [NSMutableArray new];
  for (NSString *caution in cautions) {
    if (caution.length > 0) {
      [said addObject:caution];
    }
  }
  return said.count == 0 ? nil : [said componentsJoinedByString:@"; "];
}

NSDictionary *FLCandidatesReport(FLReportSource source) {
  NSDictionary *usage = source(FLUsageState);
  NSDictionary *trace = source(FLTracedState);
  NSDictionary *loaded = source(FLLoadedState);
  NSDictionary *inventory = source(FLInventoryState);
  NSDictionary *reading = inventory[@"reading"];
  NSDate *counting = [reading[@"began"] isKindOfClass:[NSDate class]] ? reading[@"began"] : nil;
  NSSet<NSString *> *kept = FLPathsKept(source);
  NSMutableDictionary<NSString *, NSNumber *> *opened = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *looked = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *taken = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *ran = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *starting = [NSMutableDictionary new];
  NSDictionary<NSString *, NSDictionary *> *files = trace[@"files"];
  for (NSString *area in [files isKindOfClass:[NSDictionary class]] ? files : @{}) {
    unsigned long long opens = 0, looks = 0;
    NSDictionary<NSString *, NSArray<NSNumber *> *> *by = files[area][@"by"];
    for (NSString *place in by) {
      opens += by[place].firstObject.unsignedLongLongValue;
      looks += by[place].count > 1 ? by[place][1].unsignedLongLongValue : 0;
    }
    FLAddUnder(opened, area, opens);
    FLAddUnder(looked, area, looks);
  }
  NSDictionary<NSString *, NSDictionary *> *libraries = loaded[@"libraries"];
  for (NSString *library in [libraries isKindOfClass:[NSDictionary class]] ? libraries : @{}) {
    FLAddUnder(taken, library, 1);
  }
  NSDictionary<NSString *, NSDictionary *> *entries = usage[@"entries"];
  for (NSString *key in [entries isKindOfClass:[NSDictionary class]] ? entries : @{}) {
    NSString *path = entries[key][@"path"];
    if ([path hasPrefix:@"/"] && [entries[key][@"runs"] unsignedLongLongValue] > 0) {
      FLAddUnder(ran, path, 1);
    }
  }
  NSDictionary<NSString *, NSNumber *> *early = source(FLStartupState)[@"files"];
  for (NSString *file in [early isKindOfClass:[NSDictionary class]] ? early : @{}) {
    FLAddUnder(starting, file, 1);
  }
  NSString * (^inUse)(NSString *) = ^NSString *(NSString *path) {
    if (ran[path] != nil) {
      return @"something inside it has run";
    }
    return taken[path] != nil ? @"something inside it was loaded" : nil;
  };
  NSString * (^glanced)(NSString *) = ^NSString *(NSString *path) {
    if (opened[path] != nil) {
      return @"a traced program opened a file in it";
    }
    return looked[path] == nil ? nil : @"a program has looked at it without opening anything";
  };
  NSString * (^described)(NSDictionary *) = ^NSString *(NSDictionary *thing) {
    return [thing[@"listed"] unsignedIntegerValue] == 0
      ? nil
      : @"only the files that describe it were read";
  };
  NSString * (^readFrom)(NSDictionary *) = ^NSString *(NSDictionary *thing) {
    NSUInteger read = [thing[@"read"] unsignedIntegerValue];
    if (read == 0) {
      return described(thing);
    }
    NSDate *last = thing[@"lastRead"];
    return [NSString stringWithFormat:@"%@ of its %@ files %@ read, the last %@",
                                      @(read), thing[@"files"] ?: @"", read == 1 ? @"was" : @"were",
                                      [last isKindOfClass:[NSDate class]] ? FLFormatDay(last)
                                                                          : @""];
  };
  NSString * (^whileStarting)(NSString *) = ^NSString *(NSString *path) {
    NSNumber *count = starting[path];
    return count == nil
      ? nil
      : [NSString stringWithFormat:@"the device read %@ in it while starting",
                                   FLReportCount(count.unsignedLongLongValue, @"file", @"files")];
  };

  NSMutableDictionary<NSString *, NSDictionary *> *services = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSDictionary *> *things = [NSMutableDictionary new];
  NSMutableArray<NSDictionary *> *spare = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *data = [NSMutableArray new];
  NSSet<NSString *> *unneeded = [NSSet setWithArray:@[ @"idle", @"plugin", @"unseen", @"orphan" ]];
  NSSet<NSString *> *holding = [NSSet setWithArray:@[ @"framework", @"bundle", @"library" ]];
  NSString *unread = counting == nil
    ? @"it holds no program, and no traced program opened a file in it"
    : [NSString stringWithFormat:@"it holds no program, and nothing has read a file in it since "
                                 @"%@",
                                 FLFormatDay(counting)];
  @autoreleasepool {
    for (NSDictionary *item in inventory[@"items"]) {
      NSString *kind = item[@"kind"];
      NSString *path = item[@"path"];
      if ([kind isEqualToString:@"service"] && item[@"id"] != nil) {
        services[item[@"id"]] = item;
      } else if (path != nil) {
        things[path] = item;
      }
      uint64_t bytes = [item[@"bytes"] unsignedLongLongValue];
      if (![holding containsObject:kind ?: @""] || [item[@"data"] boolValue] || path == nil ||
          [item[@"inside"] length] > 0 || ![item[@"from"] isEqualToString:FLStock] ||
          bytes == 0 || inUse(path) != nil || [item[@"read"] unsignedIntegerValue] > 0 ||
          starting[path] != nil || FLPathIsKept(path, nil, kept)) {
        continue;
      }
      NSString *need = item[@"need"];
      BOOL coded = item[@"binary"] != nil || [kind isEqualToString:@"library"] ||
                   [item[@"inCache"] boolValue];
      NSString *caution = FLJoinedCautions(@[ glanced(path) ?: @"", described(item) ?: @"" ]);
      if (need != nil && [unneeded containsObject:need]) {
        NSString *why = [@"nothing that has run needs it: "
          stringByAppendingString:[@{
            @"idle" : @"only programs that never ran link it",
            @"plugin" : @"only plug-ins that nothing names need it",
            @"unseen" : @"it is a plug-in that nothing names",
            @"orphan" : @"nothing was found that needs it",
          }[need] description]];
        [spare addObject:FLCandidate(item[@"name"] ?: path.lastPathComponent, kind, path, bytes,
                                     why, caution)];
      } else if (need == nil && !coded && (counting != nil || opened[path] == nil)) {
        [data addObject:FLCandidate(item[@"name"] ?: path.lastPathComponent, kind, path, bytes,
                                    unread, caution)];
      }
    }
  }

  NSMutableArray<NSDictionary *> *apps = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *unseen = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *idle = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *tools = [NSMutableArray new];
  NSDictionary *report = FLUsageReport(usage);
  for (NSDictionary *row in report[@"rows"]) {
    NSString *kind = row[@"kind"];
    NSString *path = row[@"where"];
    if (![row[@"origin"] isEqualToString:FLStock] || ![path hasPrefix:@"/"]) {
      continue;
    }
    uint64_t bytes = [row[@"bytes"] unsignedLongLongValue];
    BOOL app = [kind isEqualToString:@"app"];
    if (app && [row[@"ran"] boolValue] && [row[@"fronts"] unsignedLongLongValue] == 0 &&
        !FLPathIsKept(path, nil, kept)) {
      NSString *why = [NSString
        stringWithFormat:@"never in front; iOS started it %@ by itself",
                         FLReportCount([row[@"runs"] unsignedLongLongValue], @"time", @"times")];
      NSString *caution = [row[@"running"] unsignedIntegerValue] > 0 ? @"it is running now" : nil;
      [unseen addObject:FLCandidate(row[@"name"], @"app", path, bytes, why, caution)];
    }
    if ([row[@"ran"] boolValue]) {
      continue;
    }
    if (app) {
      if (inUse(path) == nil && !FLPathIsKept(path, nil, kept)) {
        NSString *caution = FLJoinedCautions(@[
          glanced(path) ?: @"", readFrom(things[path]) ?: @"", whileStarting(path) ?: @""
        ]);
        [apps addObject:FLCandidate(row[@"name"], @"app", path, bytes, @"never run", caution)];
      }
    } else if ([kind isEqualToString:@"service"]) {
      NSString *file = [row[@"file"] length] > 0 ? row[@"file"] : path;
      NSUInteger clients = [services[row[@"key"]][@"clients"] unsignedIntegerValue];
      NSString *caution = clients == 0
        ? nil
        : [@"a service it offers is named by "
            stringByAppendingString:FLReportCount(clients, @"program", @"programs")];
      if (ran[path] == nil && row[@"read"] == nil && !FLPathIsKept(file, path, kept)) {
        [idle addObject:FLCandidate(row[@"name"], @"launch service", file, bytes,
                                    @"never started", caution)];
      }
    } else if ([kind isEqualToString:@"program"]) {
      if (opened[path] == nil && row[@"read"] == nil && !FLPathIsKept(path, nil, kept)) {
        [tools addObject:FLCandidate(row[@"name"], @"program", path, bytes, @"never run", nil)];
      }
    }
  }

  NSMutableArray<NSDictionary *> *folders = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *languages = [NSMutableArray new];
  for (NSDictionary *area in counting == nil ? @[] : inventory[@"areas"]) {
    NSString *path = area[@"path"];
    uint64_t bytes = [area[@"bytes"] unsignedLongLongValue];
    if (path == nil || bytes == 0 || [area[@"read"] unsignedIntegerValue] > 0 ||
        opened[path] != nil || starting[path] != nil || FLPathIsKept(path, nil, kept)) {
      continue;
    }
    NSString *why = [NSString
      stringWithFormat:@"nothing has read any of its %@",
                       FLReportCount([area[@"files"] unsignedLongLongValue], @"file", @"files")];
    [folders addObject:FLCandidate(path, @"folder of other files", path, bytes, why,
                                   FLJoinedCautions(@[ glanced(path) ?: @"",
                                                       described(area) ?: @"" ]))];
  }
  for (NSDictionary *language in counting == nil ? @[] : reading[@"languages"]) {
    uint64_t bytes = [language[@"bytes"] unsignedLongLongValue];
    if (bytes == 0 || [language[@"read"] unsignedIntegerValue] > 0) {
      continue;
    }
    NSString *why = [NSString
      stringWithFormat:@"nothing has read any of its %@",
                       FLReportCount([language[@"files"] unsignedLongLongValue], @"file",
                                     @"files")];
    NSString *name = [NSString stringWithFormat:@"%@.lproj", language[@"name"]];
    [languages addObject:FLCandidate(name, @"translation", nil, bytes, why,
                                     @"it is spread over many folders, one in each thing that "
                                     @"is translated")];
  }

  NSDate *began = [usage[@"began"] isKindOfClass:[NSDate class]] ? usage[@"began"] : nil;
  NSString *counted = began == nil
    ? @"Nothing has been counted yet."
    : [NSString stringWithFormat:@"Going by what has run since %@, with the device awake for "
                                 @"%@ of that time, by what running programs had loaded, and "
                                 @"by %@ of tracing.",
                                 FLFormatDay(began),
                                 FLFormatDuration([usage[@"watched"] doubleValue]),
                                 FLFormatDuration([trace[@"seconds"] doubleValue])];
  NSString *meaning =
    @"A thing is listed when nothing recorded so far has used it. That is evidence, not proof: "
    @"the lists mean more the longer the device has been in ordinary use, and a thing used "
    @"once a month looks the same as one never used until that month has passed.";
  NSString *left =
    @"Left out: everything a package installed, everything the device needs to start, to be "
    @"reached and to undo a change, and everything inside another listed thing.";
  NSUInteger starts = [source(FLStartupState)[@"starts"] unsignedIntegerValue];
  NSString *read = counting == nil
    ? @"When files were last read is not known yet, so a program that runs only in the first "
      @"minute after the device starts, before Finch Logs is running, is listed here although "
      @"the start may need it."
    : [NSString stringWithFormat:@"Also going by which files have been read since %@, which "
                                 @"covers every file on the system volume, and by what the "
                                 @"device read while starting, recorded for %@. A program, "
                                 @"library, bundle or folder with a file read is left out, so "
                                 @"what runs before Finch Logs is running is not listed.",
                                 FLFormatDay(counting),
                                 FLReportCount(starts, @"start", @"starts")];
  return @{
    @"title" : FLReportTitle(@"candidates"),
    @"made" : [NSDate date],
    @"notes" : @[ counted, read, meaning, left ],
    @"sections" : @[
      FLCandidateSection(@"Apps never run", @"With nothing inside them run or loaded.", apps),
      FLCandidateSection(@"Apps that ran but were never in front",
                         @"iOS starts some apps by itself where nobody sees them.", unseen),
      FLCandidateSection(@"Launch services never started",
                         @"The size is the program's, which other services may share.", idle),
      FLCandidateSection(@"Programs never run", @"Programs that no launch service starts.",
                         tools),
      FLCandidateSection(@"Frameworks, bundles and libraries nothing that has run needs",
                         @"Going by what each program links and names, never seen loaded, and "
                         @"with no file read.",
                         spare),
      FLCandidateSection(@"Bundles of data nothing has read",
                         @"These hold no program, so only the reading of their files shows "
                         @"their use.",
                         data),
      FLCandidateSection(@"Folders of other files nothing has read",
                         @"Fonts, sounds, language data and the like, outside any installed "
                         @"thing.",
                         folders),
      FLCandidateSection(@"Translations nothing has read",
                         @"Every folder of one language, added up over the whole system "
                         @"volume.",
                         languages),
    ],
  };
}
