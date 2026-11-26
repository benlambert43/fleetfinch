#import "FLReports.h"

#import "FLCandidates.h"
#import "FLChanges.h"
#import "FLCommon.h"
#import "FLLoaded.h"
#import "FLReport.h"
#import "FLStatus.h"
#import "FLTrace.h"
#import "FLUsage.h"

static FLReportSource FLDaemonSource;
static const NSUInteger FLNamesShown = 4;
static const NSUInteger FLNamesListed = 60;

NSArray<NSString *> *FLLiveReportKinds(void) {
  return @[ @"health", @"connections", @"loaded", @"changes" ];
}

NSArray<NSString *> *FLTracedReportKinds(void) {
  return @[ @"calls", @"opened", @"talks", @"candidates" ];
}

NSArray<NSString *> *FLReportKinds(void) {
  return [FLLiveReportKinds() arrayByAddingObjectsFromArray:FLTracedReportKinds()];
}

NSString *FLReportTitle(NSString *kind) {
  NSDictionary<NSString *, NSString *> *titles = @{
    @"health" : @"How each component is doing",
    @"connections" : @"Which programs talk to which servers",
    @"loaded" : @"Which libraries and plug-ins have really been loaded",
    @"changes" : @"What has been set aside, and what changed since",
    @"calls" : @"Which system calls each program makes",
    @"opened" : @"Which parts of the system had files opened",
    @"talks" : @"Which programs hold connections to which",
    @"candidates" : @"What nothing recorded so far has used",
  };
  return titles[kind] ?: kind;
}

NSString *FLReportKindNamed(NSString *word) {
  NSString *kind = word.lowercaseString;
  return [FLReportKinds() containsObject:kind] ? kind : nil;
}

void FLSetReportSource(FLReportSource source) {
  FLDaemonSource = [source copy];
}

FLReportSource FLCurrentReportSource(void) {
  return FLDaemonSource ?: ^NSDictionary *(NSString *name) {
    return FLReadState(name);
  };
}

static NSString *FLWatched(NSDictionary *usage) {
  NSDate *began = [usage[@"began"] isKindOfClass:[NSDate class]] ? usage[@"began"] : [NSDate date];
  return [NSString stringWithFormat:@"Counted since %@, with the device awake for %@ of that "
                                    @"time.",
                                    FLFormatDay(began),
                                    FLFormatDuration([usage[@"watched"] doubleValue])];
}

static NSString *FLCounts(NSDictionary<NSString *, NSNumber *> *counts) {
  if (![counts isKindOfClass:[NSDictionary class]]) {
    return @"";
  }
  NSArray<NSString *> *names =
    [counts.allKeys sortedArrayUsingComparator:^(NSString *first, NSString *second) {
      NSComparisonResult order = [counts[second] compare:counts[first]];
      return order != NSOrderedSame ? order : [first compare:second];
    }];
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  for (NSString *name in names) {
    [parts addObject:[NSString stringWithFormat:@"%@ ×%@", name, counts[name]]];
  }
  return [parts componentsJoinedByString:@", "];
}

static NSString *FLEntryTitle(NSString *key, NSDictionary *entry) {
  NSRange colon = [key rangeOfString:@":"];
  NSString *rest = colon.location == NSNotFound ? key : [key substringFromIndex:NSMaxRange(colon)];
  return [key hasPrefix:@"app:"] ? (entry[@"name"] ?: rest) : rest;
}

static NSString *FLEntryKind(NSString *key) {
  NSDictionary<NSString *, NSString *> *kinds = @{
    @"app" : @"App",
    @"service" : @"Service",
    @"program" : @"Program",
    @"sender" : @"Named in the system log only",
  };
  NSRange colon = [key rangeOfString:@":"];
  return colon.location == NSNotFound ? @"" : (kinds[[key substringToIndex:colon.location]] ?: @"");
}

static NSDictionary *FLHealthRow(NSString *key, NSDictionary *entry, NSString *detail) {
  NSDate *last = entry[@"last"];
  NSDate *troubled = entry[@"troubled"];
  return FLReportRow(FLEntryTitle(key, entry), detail, @[
    @[ @"Kind", FLEntryKind(key) ],
    @[ @"Reports written about it", FLCounts(entry[@"reports"]) ],
    @[ @"How it ended", FLCounts(entry[@"endings"]) ],
    @[ @"Faults logged", [entry[@"faults"] description] ?: @"" ],
    @[ @"Errors logged", [entry[@"errors"] description] ?: @"" ],
    @[ @"Runs seen", [entry[@"runs"] description] ?: @"" ],
    @[ @"Last seen running", [last isKindOfClass:[NSDate class]] ? FLFormatDay(last) : @"" ],
    @[ @"Last trouble", [troubled isKindOfClass:[NSDate class]] ? FLFormatDay(troubled) : @"" ],
    @[ @"Path", entry[@"path"] ?: @"" ],
  ]);
}

static NSArray<NSDictionary *> *FLHealthRows(NSDictionary<NSString *, NSDictionary *> *entries,
                                             NSString *field,
                                             NSString * (^detail)(NSDictionary *entry)) {
  NSMutableArray<NSString *> *keys = [NSMutableArray new];
  for (NSString *key in entries) {
    NSDictionary *entry = entries[key];
    BOOL covered = [key hasPrefix:@"program:"] && [entry[@"runs"] unsignedLongLongValue] > 0 &&
                   [entry[@"covered"] unsignedLongLongValue] >=
                     [entry[@"runs"] unsignedLongLongValue];
    if ([entry[field] unsignedLongLongValue] > 0 && !covered) {
      [keys addObject:key];
    }
  }
  [keys sortUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
    NSComparisonResult order = [entries[second][field] compare:entries[first][field]];
    return order != NSOrderedSame ? order : [first compare:second];
  }];
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSString *key in keys) {
    [rows addObject:FLHealthRow(key, entries[key], detail(entries[key]))];
  }
  return rows;
}

static NSDictionary *FLHealthReport(FLReportSource source) {
  NSDictionary *usage = source(FLUsageState);
  NSDictionary<NSString *, NSDictionary *> *entries =
    [usage[@"entries"] isKindOfClass:[NSDictionary class]] ? usage[@"entries"] : @{};
  NSArray<NSDictionary *> *reported = FLHealthRows(entries, @"reported", ^(NSDictionary *entry) {
    return FLCounts(entry[@"reports"]);
  });
  NSArray<NSDictionary *> *ended = FLHealthRows(entries, @"bad", ^(NSDictionary *entry) {
    return [NSString
      stringWithFormat:@"ended badly %@ in %@: %@",
                       FLReportCount([entry[@"bad"] unsignedLongLongValue], @"time", @"times"),
                       FLReportCount([entry[@"runs"] unsignedLongLongValue], @"run", @"runs"),
                       FLCounts(entry[@"endings"])];
  });
  NSArray<NSDictionary *> *faulted = FLHealthRows(entries, @"faults", ^(NSDictionary *entry) {
    return [NSString
      stringWithFormat:@"%@ and %@ logged",
                       FLReportCount([entry[@"faults"] unsignedLongLongValue], @"fault", @"faults"),
                       FLReportCount([entry[@"errors"] unsignedLongLongValue], @"error",
                                     @"errors")];
  });
  NSMutableDictionary *quieter = [NSMutableDictionary new];
  for (NSString *key in entries) {
    if ([entries[key][@"faults"] unsignedLongLongValue] == 0) {
      quieter[key] = entries[key];
    }
  }
  NSArray<NSDictionary *> *erred = FLHealthRows(quieter, @"errors", ^(NSDictionary *entry) {
    return [FLReportCount([entry[@"errors"] unsignedLongLongValue], @"error", @"errors")
      stringByAppendingString:@" logged"];
  });
  NSString *meaning =
    @"A report is a file iOS wrote about the component, such as a crash report. An ending is "
    @"bad when a service stopped with a signal or an exit code other than 0. Faults and "
    @"errors are the messages it wrote to the system log at those levels. A program that "
    @"only ever runs as a service or an app is counted there.";
  return @{
    @"title" : FLReportTitle(@"health"),
    @"made" : [NSDate date],
    @"notes" : @[ FLWatched(usage), meaning ],
    @"sections" : @[
      FLReportSection(@"Had reports written about them", nil, reported),
      FLReportSection(@"Ended badly", nil, ended),
      FLReportSection(@"Logged faults", nil, faulted),
      FLReportSection(@"Logged errors but no faults", nil, erred),
    ],
  };
}

static NSString *FLPeerFacts(NSDictionary *peer) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  unsigned long long count = [peer[@"count"] unsignedLongLongValue];
  NSDate *last = peer[@"last"];
  [parts addObject:[NSString stringWithFormat:@"%llu %@", count,
                                              count == 1 ? @"connection" : @"connections"]];
  if ([peer[@"failed"] unsignedLongLongValue] > 0) {
    [parts addObject:[NSString stringWithFormat:@"%@ could not connect", peer[@"failed"]]];
  }
  [parts addObject:[NSString stringWithFormat:@"received %@, sent %@",
                                              FLFormatBytes([peer[@"in"] unsignedLongLongValue]),
                                              FLFormatBytes([peer[@"out"] unsignedLongLongValue])]];
  if ([last isKindOfClass:[NSDate class]]) {
    [parts addObject:[@"last " stringByAppendingString:FLFormatDay(last)]];
  }
  if ([peer[@"behalf"] length] > 0) {
    [parts addObject:[@"for " stringByAppendingString:peer[@"behalf"]]];
  }
  if ([peer[@"addresses"] count] > 0) {
    [parts addObject:[@"at " stringByAppendingString:[peer[@"addresses"]
                                                       componentsJoinedByString:@" "]]];
  }
  return [parts componentsJoinedByString:@", "];
}

static uint64_t FLPeerBytes(NSDictionary *peer) {
  return [peer[@"in"] unsignedLongLongValue] + [peer[@"out"] unsignedLongLongValue];
}

static NSDictionary *FLConnectionsReport(FLReportSource source) {
  NSDictionary *traffic = source(FLTrafficState);
  NSDictionary<NSString *, NSDictionary *> *programs =
    [traffic[@"programs"] isKindOfClass:[NSDictionary class]] ? traffic[@"programs"] : @{};
  NSMutableArray<NSDictionary *> *talkers = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *listeners = [NSMutableArray new];
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *servers =
    [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSNumber *> *volumes = [NSMutableDictionary new];
  for (NSString *program in programs) {
    NSDictionary<NSString *, NSDictionary *> *peers = programs[program][@"peers"];
    NSDictionary<NSString *, NSDictionary *> *listens = programs[program][@"listens"];
    NSString *name = programs[program][@"name"] ?: program.lastPathComponent;
    uint64_t received = 0, sent = 0;
    NSArray<NSString *> *order =
      [peers.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *first,
                                                                    NSString *second) {
        uint64_t one = FLPeerBytes(peers[first]);
        uint64_t other = FLPeerBytes(peers[second]);
        return one == other ? [first compare:second]
                            : (one > other ? NSOrderedAscending : NSOrderedDescending);
      }];
    NSMutableArray<NSArray<NSString *> *> *facts = [NSMutableArray new];
    [facts addObject:@[ @"Program", program ]];
    for (NSString *peer in order) {
      received += [peers[peer][@"in"] unsignedLongLongValue];
      sent += [peers[peer][@"out"] unsignedLongLongValue];
      [facts addObject:@[ peer, FLPeerFacts(peers[peer]) ]];
      if (![peer hasPrefix:@"this device"] && ![peer hasPrefix:@"no fixed peer"] &&
          ![peer hasPrefix:@"from "] && ![peer hasPrefix:@"("]) {
        NSMutableArray<NSString *> *users = servers[peer] ?: [NSMutableArray new];
        [users addObject:name];
        servers[peer] = users;
        volumes[peer] = @([volumes[peer] unsignedLongLongValue] + FLPeerBytes(peers[peer]));
      }
    }
    if (order.count > 0) {
      NSString *detail = [NSString stringWithFormat:@"%lu %@, received %@, sent %@",
                                                    (unsigned long)order.count,
                                                    order.count == 1 ? @"peer" : @"peers",
                                                    FLFormatBytes(received), FLFormatBytes(sent)];
      NSMutableDictionary *row = [FLReportRow(name, detail, facts) mutableCopy];
      row[@"weight"] = @(received + sent);
      [talkers addObject:row];
    }
    if (listens.count > 0) {
      NSArray<NSString *> *ports = [listens.allKeys sortedArrayUsingSelector:@selector(compare:)];
      [listeners addObject:FLReportRow(name, [ports componentsJoinedByString:@", "],
                                       @[ @[ @"Program", program ] ])];
    }
  }
  [talkers sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult order = [second[@"weight"] compare:first[@"weight"]];
    return order != NSOrderedSame ? order : [first[@"title"] compare:second[@"title"]];
  }];
  NSMutableArray<NSDictionary *> *reached = [NSMutableArray new];
  NSArray<NSString *> *known =
    [servers.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *first,
                                                                    NSString *second) {
      NSComparisonResult order = [volumes[second] compare:volumes[first]];
      return order != NSOrderedSame ? order : [first compare:second];
    }];
  for (NSString *server in known) {
    NSString *detail = [NSString
      stringWithFormat:@"%@ in all, used by %@",
                       FLFormatBytes(volumes[server].unsignedLongLongValue),
                       [servers[server] componentsJoinedByString:@", "]];
    [reached addObject:FLReportRow(server, detail, nil)];
  }
  NSMutableArray<NSDictionary *> *open = [NSMutableArray new];
  for (NSDictionary *each in traffic[@"open"]) {
    NSDate *since = each[@"since"];
    NSString *detail = [NSString
      stringWithFormat:@"%@, since %@, received %@, sent %@", each[@"peer"],
                       [since isKindOfClass:[NSDate class]] ? FLFormatDay(since) : @"",
                       FLFormatBytes([each[@"in"] unsignedLongLongValue]),
                       FLFormatBytes([each[@"out"] unsignedLongLongValue])];
    [open addObject:FLReportRow([each[@"program"] lastPathComponent], detail,
                                @[ @[ @"Program", each[@"program"] ?: @"" ] ])];
  }
  NSMutableArray<NSDictionary *> *missing = [NSMutableArray new];
  NSDictionary<NSString *, NSDictionary *> *failures = traffic[@"failures"];
  for (NSString *name in [failures.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSDate *last = failures[name][@"last"];
    NSString *detail = [NSString
      stringWithFormat:@"looked up %@, last %@",
                       FLReportCount([failures[name][@"count"] unsignedLongLongValue], @"time",
                                     @"times"),
                       [last isKindOfClass:[NSDate class]] ? FLFormatDay(last) : @""];
    [missing addObject:FLReportRow(name, detail, nil)];
  }
  NSDate *began = [traffic[@"began"] isKindOfClass:[NSDate class]] ? traffic[@"began"]
                                                                  : [NSDate date];
  NSString *counted = [NSString
    stringWithFormat:@"Counted since %@. A connection is counted when it closes, with the bytes "
                     @"it carried each way.",
                     FLFormatDay(began)];
  NSString *naming = [traffic[@"naming"] boolValue]
    ? @"A server is shown by name when its name was looked up over Wi-Fi while Finch Logs was "
      @"watching, and by address otherwise."
    : @"Name lookups are not being watched, so servers are shown by address.";
  NSString *watching = [traffic[@"watching"] boolValue]
    ? @""
    : @"The kernel's record of connections is not open, so nothing new is being counted.";
  NSMutableArray<NSString *> *notes = [NSMutableArray arrayWithObjects:counted, naming, nil];
  if (watching.length > 0) {
    [notes addObject:watching];
  }
  return @{
    @"title" : FLReportTitle(@"connections"),
    @"made" : [NSDate date],
    @"notes" : notes,
    @"sections" : @[
      FLReportSection(@"Programs that have talked over the network", nil, talkers),
      FLReportSection(@"Servers, and the programs that talk to them", nil, reached),
      FLReportSection(@"Programs that wait for connections", nil, listeners),
      FLReportSection(@"Connections open now", nil, open),
      FLReportSection(@"Names that were looked up and do not exist",
                      @"The answer does not say which program asked.", missing),
    ],
  };
}

static NSString *FLNamesOfPrograms(NSArray<NSString *> *programs, NSUInteger most) {
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  for (NSString *program in programs) {
    if (names.count == most) {
      [names addObject:[NSString stringWithFormat:@"and %lu more",
                                                  (unsigned long)(programs.count - most)]];
      break;
    }
    [names addObject:program.lastPathComponent];
  }
  return [names componentsJoinedByString:@", "];
}

static NSDictionary *FLLoadedReport(FLReportSource source) {
  NSDictionary *loaded = source(FLLoadedState);
  NSDictionary<NSString *, NSDictionary *> *libraries =
    [loaded[@"libraries"] isKindOfClass:[NSDictionary class]] ? loaded[@"libraries"] : @{};
  NSMutableArray<NSDictionary *> *apart = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *shared = [NSMutableArray new];
  for (NSString *path in [libraries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    @autoreleasepool {
      NSArray<NSString *> *programs = FLLoadedBy(loaded, path);
      NSDate *first = libraries[path][@"first"];
      NSDate *last = libraries[path][@"last"];
      BOOL inCache = [libraries[path][@"cached"] boolValue];
      NSString *detail = [NSString
        stringWithFormat:@"loaded by %lu %@: %@", (unsigned long)programs.count,
                         programs.count == 1 ? @"program" : @"programs",
                         FLNamesOfPrograms(programs, FLNamesShown)];
      NSMutableDictionary *row = [FLReportRow(path.lastPathComponent, detail, @[
        @[ @"Path", path ],
        @[ @"First seen loaded", [first isKindOfClass:[NSDate class]] ? FLFormatDay(first) : @"" ],
        @[ @"Last seen loaded", [last isKindOfClass:[NSDate class]] ? FLFormatDay(last) : @"" ],
        @[ @"Loaded by", FLNamesOfPrograms(programs, FLNamesListed) ],
      ]) mutableCopy];
      row[@"weight"] = @(programs.count);
      [inCache ? shared : apart addObject:row];
    }
  }
  NSComparator most = ^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult order = [second[@"weight"] compare:first[@"weight"]];
    return order != NSOrderedSame ? order : [first[@"title"] compare:second[@"title"]];
  };
  [apart sortUsingComparator:most];
  [shared sortUsingComparator:most];
  NSMutableArray<NSDictionary *> *closed = [NSMutableArray new];
  NSDictionary<NSString *, NSNumber *> *unread = loaded[@"unread"];
  for (NSString *program in [unread.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *detail = [@"could not be looked into "
      stringByAppendingString:FLReportCount(unread[program].unsignedLongLongValue, @"time",
                                            @"times")];
    [closed addObject:FLReportRow(program.lastPathComponent, detail, @[ @[ @"Path", program ] ])];
  }
  NSDate *began = [loaded[@"began"] isKindOfClass:[NSDate class]] ? loaded[@"began"]
                                                                 : [NSDate date];
  NSString *counted = [NSString
    stringWithFormat:@"Counted since %@, in %@ looks at running programs. Every running program "
                     @"is looked at every five minutes while the device is awake, and each new "
                     @"one 2 and 20 seconds after it starts.",
                     FLFormatDay(began), loaded[@"looks"] ?: @0];
  NSString *limits =
    @"What a program loads and lets go of between two looks is missed, and so is everything "
    @"loaded by a program that runs for less than two seconds.";
  return @{
    @"title" : FLReportTitle(@"loaded"),
    @"made" : [NSDate date],
    @"notes" : @[ counted, limits ],
    @"sections" : @[
      FLReportSection(@"Loaded from files of their own",
                      @"These are outside the shared library cache, so each is a file that "
                      @"could be removed, and each was in use.",
                      apart),
      FLReportSection(@"Loaded from the shared library cache", nil, shared),
      FLReportSection(@"Programs that could not be looked into", nil, closed),
    ],
  };
}

NSDictionary *FLBuildReport(NSString *kind, FLReportSource source) {
  if ([kind isEqualToString:@"health"]) {
    return FLHealthReport(source);
  }
  if ([kind isEqualToString:@"connections"]) {
    return FLConnectionsReport(source);
  }
  if ([kind isEqualToString:@"loaded"]) {
    return FLLoadedReport(source);
  }
  if ([kind isEqualToString:@"changes"]) {
    return FLChangesReport(source);
  }
  if ([kind isEqualToString:@"calls"]) {
    return FLCallsReport(source);
  }
  if ([kind isEqualToString:@"opened"]) {
    return FLFilesReport(source);
  }
  if ([kind isEqualToString:@"talks"]) {
    return FLTalksReport(source);
  }
  if ([kind isEqualToString:@"candidates"]) {
    return FLCandidatesReport(source);
  }
  return nil;
}
