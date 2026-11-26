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

NSDictionary *FLCandidatesReport(FLReportSource source) {
  NSDictionary *usage = source(FLUsageState);
  NSDictionary *trace = source(FLTracedState);
  NSDictionary *loaded = source(FLLoadedState);
  NSDictionary *inventory = source(FLInventoryState);
  NSSet<NSString *> *kept = FLPathsKept(source);
  NSMutableDictionary<NSString *, NSNumber *> *opened = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *looked = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *taken = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *ran = [NSMutableDictionary new];
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
  NSString * (^inUse)(NSString *) = ^NSString *(NSString *path) {
    if (ran[path] != nil) {
      return @"something inside it has run";
    }
    if (taken[path] != nil) {
      return @"something inside it was loaded";
    }
    return opened[path] != nil ? @"a file inside it was opened" : nil;
  };
  NSString * (^glanced)(NSString *) = ^NSString *(NSString *path) {
    return looked[path] == nil ? nil : @"a program has looked at it without opening anything";
  };

  NSMutableDictionary<NSString *, NSDictionary *> *services = [NSMutableDictionary new];
  NSMutableArray<NSDictionary *> *spare = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *data = [NSMutableArray new];
  NSSet<NSString *> *unneeded = [NSSet setWithArray:@[ @"idle", @"plugin", @"unseen", @"orphan" ]];
  NSSet<NSString *> *holding = [NSSet setWithArray:@[ @"framework", @"bundle", @"library" ]];
  @autoreleasepool {
    for (NSDictionary *item in inventory[@"items"]) {
      NSString *kind = item[@"kind"];
      NSString *path = item[@"path"];
      if ([kind isEqualToString:@"service"] && item[@"id"] != nil) {
        services[item[@"id"]] = item;
      }
      uint64_t bytes = [item[@"bytes"] unsignedLongLongValue];
      if (![holding containsObject:kind ?: @""] || [item[@"data"] boolValue] || path == nil ||
          [item[@"inside"] length] > 0 || ![item[@"from"] isEqualToString:FLStock] ||
          bytes == 0 || inUse(path) != nil || FLPathIsKept(path, nil, kept)) {
        continue;
      }
      NSString *need = item[@"need"];
      BOOL coded = item[@"binary"] != nil || [kind isEqualToString:@"library"] ||
                   [item[@"inCache"] boolValue];
      if (need != nil && [unneeded containsObject:need]) {
        NSString *why = [@"nothing that has run needs it: "
          stringByAppendingString:[@{
            @"idle" : @"only programs that never ran link it",
            @"plugin" : @"only plug-ins that nothing names need it",
            @"unseen" : @"it is a plug-in that nothing names",
            @"orphan" : @"nothing was found that needs it",
          }[need] description]];
        [spare addObject:FLCandidate(item[@"name"] ?: path.lastPathComponent, kind, path, bytes,
                                     why, glanced(path))];
      } else if (need == nil && !coded) {
        [data addObject:FLCandidate(item[@"name"] ?: path.lastPathComponent, kind, path, bytes,
                                    @"it holds no program, and no traced program opened a "
                                    @"file in it",
                                    glanced(path))];
      }
    }
  }

  NSMutableArray<NSDictionary *> *apps = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *idle = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *tools = [NSMutableArray new];
  NSDictionary *report = FLUsageReport(usage);
  for (NSDictionary *row in report[@"rows"]) {
    NSString *kind = row[@"kind"];
    NSString *path = row[@"where"];
    if ([row[@"ran"] boolValue] || ![row[@"origin"] isEqualToString:FLStock] ||
        ![path hasPrefix:@"/"]) {
      continue;
    }
    uint64_t bytes = [row[@"bytes"] unsignedLongLongValue];
    if ([kind isEqualToString:@"app"]) {
      if (inUse(path) == nil && !FLPathIsKept(path, nil, kept)) {
        [apps addObject:FLCandidate(row[@"name"], @"app", path, bytes, @"never opened",
                                    glanced(path))];
      }
    } else if ([kind isEqualToString:@"service"]) {
      NSString *file = [row[@"file"] length] > 0 ? row[@"file"] : path;
      NSUInteger clients = [services[row[@"key"]][@"clients"] unsignedIntegerValue];
      NSString *caution = clients == 0
        ? nil
        : [@"a service it offers is named by "
            stringByAppendingString:FLReportCount(clients, @"program", @"programs")];
      if (ran[path] == nil && !FLPathIsKept(file, path, kept)) {
        [idle addObject:FLCandidate(row[@"name"], @"launch service", file, bytes,
                                    @"never started", caution)];
      }
    } else if ([kind isEqualToString:@"program"]) {
      if (opened[path] == nil && !FLPathIsKept(path, nil, kept)) {
        [tools addObject:FLCandidate(row[@"name"], @"program", path, bytes, @"never run", nil)];
      }
    }
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
  NSString *early =
    @"The service starts about a minute after the device does. A program that runs only in "
    @"that first minute and then ends is never seen, so it is listed here although the start "
    @"may need it.";
  return @{
    @"title" : FLReportTitle(@"candidates"),
    @"made" : [NSDate date],
    @"notes" : @[ counted, meaning, left, early ],
    @"sections" : @[
      FLCandidateSection(@"Apps never opened", @"With nothing inside them run, loaded or opened.",
                         apps),
      FLCandidateSection(@"Launch services never started",
                         @"The size is the program's, which other services may share.", idle),
      FLCandidateSection(@"Programs never run", @"Programs that no launch service starts.",
                         tools),
      FLCandidateSection(@"Frameworks, bundles and libraries nothing that has run needs",
                         @"Going by what each program links and names, and never seen loaded.",
                         spare),
      FLCandidateSection(@"Bundles of data no traced program opened",
                         @"These hold no program, so only tracing can show their use, and "
                         @"tracing runs part of the time.",
                         data),
    ],
  };
}
