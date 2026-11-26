#import <Foundation/Foundation.h>
#import <notify.h>
#import <sys/resource.h>
#import <sys/utsname.h>

#import "FLChanges.h"
#import "FLCollect.h"
#import "FLCommon.h"
#import "FLDaemon.h"
#import "FLDepends.h"
#import "FLDump.h"
#import "FLInventory.h"
#import "FLReader.h"
#import "FLReport.h"
#import "FLReports.h"
#import "FLSettings.h"
#import "FLStatus.h"
#import "FLStore.h"
#import "FLSystemInfo.h"
#import "FLTrace.h"
#import "FLUsage.h"

static NSString *const FLTrailer = @"@@finchlog";
static const NSTimeInterval FLFollowReport = 10;
static const int64_t FLUsageWait = 5;
static const int FLHelperNiceness = 10;
static NSString *const FLInventorySnapshot = @"inventory";
static NSString *const FLDependenciesSnapshot = @"dependencies";

static void FLPrint(NSString *text) {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  fwrite(data.bytes, 1, data.length, stdout);
}

static NSString *FLOption(NSArray<NSString *> *arguments, NSString *name) {
  NSUInteger index = [arguments indexOfObject:name];
  if (index == NSNotFound || index + 1 >= arguments.count) {
    return nil;
  }
  return arguments[index + 1];
}

static NSArray<NSString *> *FLOptions(NSArray<NSString *> *arguments, NSString *name) {
  NSMutableArray *values = [NSMutableArray new];
  for (NSUInteger index = 0; index + 1 < arguments.count; index++) {
    if ([arguments[index] isEqualToString:name]) {
      [values addObject:arguments[index + 1]];
    }
  }
  return values;
}

static int FLShowUsage(void) {
  FLPrint(@"Finch Logs keeps a record of what this device is doing.\n\n"
          @"  finchlog status                  how the service is doing\n"
          @"  finchlog streams                 the logs it keeps\n"
          @"  finchlog tail [-n N] [-f] [--stream NAME]\n"
          @"                                   the newest lines, and new ones as they come\n"
          @"  finchlog read [--cursor C] [--lines N] [--stream NAME] [--follow [--for S]]\n"
          @"                                   lines after a cursor, for another program\n"
          @"  finchlog files GROUP             the files of one log or snapshot\n"
          @"  finchlog show FILE               one file, unpacked if it is archived\n"
          @"  finchlog dump [--hours H] [--gzip]\n"
          @"                                   every log as a tar archive on standard output\n"
          @"  finchlog collect [KIND]          gather one kind of information right now\n"
          @"  finchlog usage [--never]         what has run since Finch Logs began counting,\n"
          @"                                   and what never has\n"
          @"  finchlog inventory [KIND] [--fresh]\n"
          @"                                   everything installed, with its size and what it\n"
          @"                                   offers; KIND is apps, extensions, services, xpc,\n"
          @"                                   frameworks, bundles, programs, libraries or\n"
          @"                                   storage, and --fresh lists it all again first\n"
          @"  finchlog depends [NAME] [--fresh]\n"
          @"                                   what NAME links, opens by name and names, and what\n"
          @"                                   does the same to it; with no NAME, all of it\n"
          @"  finchlog health                  the reports, bad endings, faults and errors of\n"
          @"                                   each component\n"
          @"  finchlog connections             which programs talk to which servers\n"
          @"  finchlog loaded                  the libraries and plug-ins running programs have\n"
          @"                                   really loaded\n"
          @"  finchlog trace [--for S] [--name PROGRAM]\n"
          @"                                   record every system call, kernel trap and file\n"
          @"                                   lookup for S seconds (20 unless told), and with\n"
          @"                                   --name, everything one program did\n"
          @"  finchlog candidates              what nothing recorded so far has used, by size\n"
          @"  finchlog calls | opened | talks  what the traces have gathered: the calls each\n"
          @"                                   program makes, which parts of the system had\n"
          @"                                   files opened, and who holds connections to whom\n"
          @"  finchlog hold NAME [--note TEXT] [--force] [--check]\n"
          @"                                   set a part of iOS aside where iOS no longer finds\n"
          @"                                   it; NAME is a path, a launch service or a name,\n"
          @"                                   and --check only says whether it would be done\n"
          @"  finchlog restore NUMBER          put what a change set aside back where it was\n"
          @"  finchlog store NUMBER            move it off the system volume to free the space\n"
          @"  finchlog discard NUMBER --yes    delete it for good\n"
          @"  finchlog changes                 each change, and what differs since it was made\n"
          @"  finchlog snapshot | import | maintain | reload\n"
          @"                                   ask the service to do that now\n"
          @"  finchlog daemon                  run the service (launchd does this)\n"
          @"  finchlog version\n");
  return 64;
}

static int FLShowStatus(void) {
  NSDictionary *status = FLServiceStatus();
  BOOL running = FLServiceRunning(status);
  FLPrint([NSString stringWithFormat:@"Finch Logs %@\n", FLVersion]);
  if (!running) {
    FLPrint(@"Service: not running\n");
  } else {
    NSDate *started = status[@"started"];
    FLPrint([NSString stringWithFormat:@"Service: running as pid %@ for %@\n", status[@"pid"],
                                       FLFormatDuration(-started.timeIntervalSinceNow)]);
  }
  NSDate *boot = FLBootTime();
  if (boot != nil) {
    FLPrint([NSString stringWithFormat:@"Device started: %@ (%@ ago)\n", FLFormatDay(boot),
                                       FLFormatDuration(FLUptime())]);
  }
  if (status.count == 0) {
    return running ? 0 : 1;
  }
  FLPrint([NSString stringWithFormat:@"System log: %@, %@ messages read\n",
                                     [status[@"systemLogConnected"] boolValue]
                                       ? @"connected"
                                       : @"not connected",
                                     status[@"systemLogMessages"] ?: @0]);
  NSDictionary *usage = status[@"usage"];
  FLPrint([NSString
    stringWithFormat:@"Store: %@ in %@ live files, %@ in %@ archived files\n",
                     FLFormatBytes([usage[@"liveBytes"] unsignedLongLongValue]),
                     usage[@"liveFiles"] ?: @0,
                     FLFormatBytes([usage[@"archiveBytes"] unsignedLongLongValue]),
                     usage[@"archiveFiles"] ?: @0]);
  NSDictionary *counts = status[@"counts"];
  NSArray *names = [counts.allKeys sortedArrayUsingSelector:@selector(compare:)];
  NSMutableArray *written = [NSMutableArray new];
  for (NSString *name in names) {
    [written addObject:[NSString stringWithFormat:@"%@ %@", name, counts[name]]];
  }
  FLPrint([NSString stringWithFormat:@"Lines written since it started: %@\n",
                                     [written componentsJoinedByString:@", "]]);
  NSDictionary *maintenance = status[@"maintenance"];
  if (maintenance != nil) {
    NSDictionary *result = maintenance[@"result"];
    FLPrint([NSString
      stringWithFormat:@"Last tidied: %@ (archived %@, deleted %@)\n",
                       FLFormatDay(maintenance[@"at"]), result[@"archived"] ?: @0,
                       result[@"deleted"] ?: @0]);
  }
  NSDictionary *settings = status[@"settings"];
  FLPrint([NSString
    stringWithFormat:@"Keeps: logs for %@ before archiving, archives for %@, up to %@\n",
                     FLFormatDuration([settings[FLSettingArchiveAfter] doubleValue]),
                     FLFormatDuration([settings[FLSettingDeleteAfter] doubleValue]),
                     FLFormatBytes([settings[FLSettingStoreLimit] unsignedLongLongValue])]);
  return running ? 0 : 1;
}

static int FLShowStreams(void) {
  NSMutableArray *groups = [[FLReader streams] mutableCopy];
  [groups addObjectsFromArray:[FLReader groupsUnder:FLSnapshotFolder]];
  [groups addObjectsFromArray:[FLReader groupsUnder:FLImportFolder]];
  for (NSString *group in groups) {
    uint64_t live = 0, archived = 0;
    NSUInteger liveFiles = 0, archivedFiles = 0;
    for (FLLogFile *file in [FLReader filesInGroup:group]) {
      if (file.archived) {
        archived += file.size;
        archivedFiles++;
      } else {
        live += file.size;
        liveFiles++;
      }
    }
    FLPrint([NSString stringWithFormat:@"%@\t%lu live (%@)\t%lu archived (%@)\t%@\n", group,
                                       (unsigned long)liveFiles, FLFormatBytes(live),
                                       (unsigned long)archivedFiles, FLFormatBytes(archived),
                                       [FLReader streamDescription:group]]);
  }
  return 0;
}

static int FLShowFiles(NSArray<NSString *> *arguments) {
  if (arguments.count == 0) {
    return FLShowUsage();
  }
  for (FLLogFile *file in [FLReader filesInGroup:arguments[0]]) {
    FLPrint([NSString stringWithFormat:@"%@\t%@\t%@\t%@\n", file.path,
                                       FLFormatBytes(file.size), FLFormatDay(file.modified),
                                       file.archived ? @"archived" : @"live"]);
  }
  return 0;
}

static int FLShowFile(NSArray<NSString *> *arguments) {
  if (arguments.count == 0) {
    return FLShowUsage();
  }
  NSString *path = arguments[0];
  if (![path hasPrefix:@"/"]) {
    path = [FLRootPath stringByAppendingPathComponent:path];
  }
  NSData *data = [FLReader dataOfFile:path tail:64 * 1024 * 1024];
  if (data == nil) {
    fprintf(stderr, "finchlog: %s could not be read\n", path.UTF8String);
    return 1;
  }
  fwrite(data.bytes, 1, data.length, stdout);
  return 0;
}

static int FLRead(NSArray<NSString *> *arguments) {
  NSString *cursor = FLOption(arguments, @"--cursor") ?: @"";
  NSUInteger limit = (NSUInteger)MAX(1, [FLOption(arguments, @"--lines") integerValue]);
  if (FLOption(arguments, @"--lines") == nil) {
    limit = 500;
  }
  BOOL follow = [arguments containsObject:@"--follow"];
  NSTimeInterval lifetime = MAX(0, [FLOption(arguments, @"--for") doubleValue]);
  NSArray<NSString *> *streams = FLOptions(arguments, @"--stream");
  NSDate *began = [NSDate date];
  NSDate *reported = nil;
  for (;;) {
    if (follow && FLGoingToSleep()) {
      sleep(1);
      continue;
    }
    BOOL more = NO;
    @autoreleasepool {
      NSDictionary *result = [FLReader readAfterCursor:cursor streams:streams limit:limit];
      NSArray<NSString *> *lines = result[@"lines"];
      for (NSString *line in lines) {
        FLPrint([line stringByAppendingString:@"\n"]);
      }
      NSString *next = result[@"cursor"];
      cursor = next.length > 0 ? next : @"none:none:0";
      more = [result[@"more"] boolValue];
      if (lines.count > 0 || reported == nil ||
          -reported.timeIntervalSinceNow >= FLFollowReport) {
        FLPrint([NSString stringWithFormat:@"%@ cursor=%@ more=%d lines=%lu\n", FLTrailer,
                                           cursor, more ? 1 : 0,
                                           (unsigned long)lines.count]);
        reported = [NSDate date];
      }
      if (fflush(stdout) != 0 || !follow) {
        return 0;
      }
      if (lifetime > 0 && -began.timeIntervalSinceNow >= lifetime) {
        return 0;
      }
    }
    if (!more) {
      sleep(1);
    }
  }
}

static void FLPrintPlain(NSString *line) {
  NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
  if (parts.count < 5) {
    FLPrint([line stringByAppendingString:@"\n"]);
    return;
  }
  NSString *stamp = parts[1];
  NSString *clock = stamp.length >= 23 ? [stamp substringWithRange:NSMakeRange(11, 12)] : stamp;
  NSArray *rest = [parts subarrayWithRange:NSMakeRange(4, parts.count - 4)];
  FLPrint([NSString stringWithFormat:@"%@ %@ %-9@ %@: %@\n", clock, parts[2], parts[0],
                                     parts[3], [rest componentsJoinedByString:@"\t"]]);
}

static int FLTail(NSArray<NSString *> *arguments) {
  NSUInteger count = (NSUInteger)MAX(1, [FLOption(arguments, @"-n") integerValue]);
  if (FLOption(arguments, @"-n") == nil) {
    count = 40;
  }
  BOOL follow = [arguments containsObject:@"-f"];
  NSArray *streams = FLOptions(arguments, @"--stream");
  NSString *cursor = @"";
  for (;;) {
    if (follow && FLGoingToSleep()) {
      sleep(1);
      continue;
    }
    @autoreleasepool {
      NSDictionary *result = [FLReader readAfterCursor:cursor streams:streams limit:count];
      for (NSString *line in result[@"lines"]) {
        FLPrintPlain(line);
      }
      fflush(stdout);
      cursor = result[@"cursor"];
      if (!follow) {
        return 0;
      }
      if (cursor.length == 0) {
        cursor = @"none:none:0";
      }
      count = 2000;
    }
    sleep(1);
  }
}

static int FLDumpStore(NSArray<NSString *> *arguments) {
  NSString *hours = FLOption(arguments, @"--hours");
  NSTimeInterval newerThan = hours == nil ? 0 : MAX(0, hours.doubleValue * 3600.0);
  [[FLStore shared] sync];
  return FLWriteDump(STDOUT_FILENO, newerThan, [arguments containsObject:@"--gzip"]) ? 0 : 1;
}

static NSString *FLFirstWord(NSArray<NSString *> *arguments) {
  return arguments.count > 0 && ![arguments[0] hasPrefix:@"--"] ? arguments[0] : nil;
}

static NSDictionary *FLListAgain(NSDictionary **dependencies, BOOL *saved) {
  NSDictionary *inventory = FLGatherInventory();
  BOOL root = getuid() == 0;
  *saved = !root || FLSaveInventory(inventory);
  *dependencies = FLGatherDependencies(inventory, FLReadState(FLUsageState));
  if (root && *saved) {
    *saved = FLSaveDependencies(*dependencies) && FLSaveInventory(inventory);
  }
  return inventory;
}

static BOOL FLSaveText(NSString *kind, NSString *why, NSString *text) {
  NSString *heading = FLSnapshotHeading(kind, why, [NSDate date]);
  return [[FLStore shared] saveSnapshot:kind
                                 pieces:^BOOL(void (^write)(NSString *piece)) {
                                   write(heading);
                                   write(text);
                                   return YES;
                                 }] != nil;
}

static int FLShowInventory(NSArray<NSString *> *arguments) {
  BOOL save = [arguments containsObject:@"--save"];
  BOOL fresh = save || [arguments containsObject:@"--fresh"];
  NSString *word = FLFirstWord(arguments);
  NSString *kind = word == nil ? nil : FLInventoryKindNamed(word);
  if (word != nil && kind == nil) {
    fprintf(stderr, "finchlog: there is no kind of installed thing called %s\n",
            word.UTF8String);
    return 64;
  }
  if (save) {
    setpriority(PRIO_PROCESS, 0, FLHelperNiceness);
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY);
  }
  NSDictionary *inventory = fresh ? nil : FLReadState(FLInventoryState);
  NSDictionary *dependencies = nil;
  if (inventory.count == 0) {
    BOOL saved = NO;
    inventory = FLListAgain(&dependencies, &saved);
    if (!saved) {
      fprintf(stderr, "finchlog: the list of what is installed could not be saved\n");
      return 1;
    }
  }
  if (!save) {
    FLPrint(FLInventoryText(inventory, kind));
    return 0;
  }
  if ([arguments containsObject:@"--snapshot"]) {
    NSString *why = FLOption(arguments, @"--reason") ?: @"it was asked for";
    if (!FLSaveText(FLInventorySnapshot, why, FLInventoryText(inventory, nil)) ||
        !FLSaveText(FLDependenciesSnapshot, why,
                    FLDependenciesText(dependencies, inventory))) {
      fprintf(stderr, "finchlog: the snapshots of what is installed could not be saved\n");
      return 1;
    }
  }
  FLPrint([NSString stringWithFormat:@"%@\n%@\n", FLInventorySummary(inventory),
                                     FLDependenciesSummary(dependencies)]);
  return 0;
}

static int FLShowDepends(NSArray<NSString *> *arguments) {
  NSString *name = FLFirstWord(arguments);
  NSDictionary *inventory = FLReadState(FLInventoryState);
  NSDictionary *dependencies = FLReadState(FLDependenciesState);
  if ([arguments containsObject:@"--fresh"] || inventory.count == 0 ||
      dependencies.count == 0) {
    BOOL saved = NO;
    inventory = FLListAgain(&dependencies, &saved);
    if (!saved) {
      fprintf(stderr, "finchlog: what depends on what could not be saved\n");
      return 1;
    }
  }
  if (name == nil) {
    FLPrint(FLDependenciesText(dependencies, inventory));
    return 0;
  }
  NSString *text = FLDependsText(dependencies, inventory, name, FLCurrentUsage());
  if (text == nil) {
    fprintf(stderr, "finchlog: nothing installed is called %s\n", name.UTF8String);
    return 1;
  }
  FLPrint(text);
  return 0;
}

static int FLRunCollect(NSArray<NSString *> *arguments) {
  NSString *kind = arguments.count > 0 ? arguments[0] : nil;
  if (kind == nil || [kind isEqualToString:@"list"]) {
    NSArray<NSString *> *listed = [@[ FLInventorySnapshot, FLDependenciesSnapshot ]
      arrayByAddingObjectsFromArray:FLTracedReportKinds()];
    for (NSString *name in [FLCollectKinds() arrayByAddingObjectsFromArray:listed]) {
      FLPrint([NSString stringWithFormat:@"%@\t%@\n", name, FLCollectTitle(name)]);
    }
    return 0;
  }
  if ([kind isEqualToString:FLInventorySnapshot]) {
    return FLShowInventory(@[ @"--fresh" ]);
  }
  if ([kind isEqualToString:FLDependenciesSnapshot]) {
    return FLShowDepends(@[ @"--fresh" ]);
  }
  if ([FLTracedReportKinds() containsObject:kind]) {
    FLPrint(FLReportText(FLBuildReport(kind, FLCurrentReportSource())));
    return 0;
  }
  NSString *text = FLCollect(kind);
  if (text == nil) {
    fprintf(stderr, "finchlog: there is nothing called %s to collect\n", kind.UTF8String);
    return 64;
  }
  FLPrint(text);
  return 0;
}

static void FLAskToSave(void) {
  if (!FLServiceRunning(FLServiceStatus())) {
    return;
  }
  dispatch_semaphore_t saved = dispatch_semaphore_create(0);
  int token = 0;
  notify_register_dispatch(FLNoticeUsage.UTF8String, &token,
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int fired) {
                             dispatch_semaphore_signal(saved);
                           });
  FLPostCommand(FLCommandUsage);
  dispatch_semaphore_wait(saved, dispatch_time(DISPATCH_TIME_NOW, FLUsageWait * NSEC_PER_SEC));
  notify_cancel(token);
}

static int FLShowReport(NSArray<NSString *> *arguments) {
  NSString *word = arguments.count > 0 ? arguments[0] : nil;
  NSString *kind = word == nil ? nil : FLReportKindNamed(word);
  if (kind == nil) {
    for (NSString *each in FLReportKinds()) {
      FLPrint([NSString stringWithFormat:@"%@\t%@\n", each, FLReportTitle(each)]);
    }
    return word == nil ? 0 : 64;
  }
  FLAskToSave();
  FLPrint(FLReportText(FLBuildReport(kind, FLCurrentReportSource())));
  return 0;
}

static int FLSaveReports(void) {
  NSMutableDictionary<NSString *, NSDictionary *> *read = [NSMutableDictionary new];
  FLReportSource source = ^NSDictionary *(NSString *name) {
    if (read[name] == nil) {
      read[name] = FLReadState(name) ?: @{};
    }
    return read[name];
  };
  BOOL saved = YES;
  setpriority(PRIO_PROCESS, 0, FLHelperNiceness);
  for (NSString *kind in FLTracedReportKinds()) {
    @autoreleasepool {
      saved = FLWriteCompactState(FLReportState(kind), FLBuildReport(kind, source)) && saved;
    }
  }
  return saved ? 0 : 1;
}

static int FLPrintUsage(NSArray<NSString *> *arguments) {
  FLAskToSave();
  NSDictionary *usage = FLCurrentUsage();
  if (usage.count == 0) {
    fprintf(stderr, "finchlog: nothing has been counted yet; the service has not run\n");
    return 1;
  }
  FLPrint(FLUsageText(FLUsageReport(usage), [arguments containsObject:@"--never"]));
  return 0;
}

static int FLAsk(NSString *command, NSString *said) {
  NSDictionary *status = FLServiceStatus();
  if (!FLServiceRunning(status)) {
    fprintf(stderr, "finchlog: the service is not running\n");
    return 1;
  }
  FLPostCommand(command);
  FLPrint([said stringByAppendingString:@"\n"]);
  return 0;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSMutableArray<NSString *> *arguments = [NSMutableArray new];
    for (int index = 2; index < argc; index++) {
      [arguments addObject:@(argv[index])];
    }
    NSString *command = argc > 1 ? @(argv[1]) : @"help";
    if ([command isEqualToString:@"daemon"]) {
      return FLRunDaemon();
    }
    if ([command isEqualToString:@"version"]) {
      struct utsname name;
      uname(&name);
      printf("finchlog %s on %s %s (%s)\n", FLVersion.UTF8String, name.sysname,
             name.release, name.machine);
      return 0;
    }
    if ([command isEqualToString:@"status"]) {
      return FLShowStatus();
    }
    if ([command isEqualToString:@"streams"]) {
      return FLShowStreams();
    }
    if ([command isEqualToString:@"files"]) {
      return FLShowFiles(arguments);
    }
    if ([command isEqualToString:@"show"]) {
      return FLShowFile(arguments);
    }
    if ([command isEqualToString:@"read"]) {
      return FLRead(arguments);
    }
    if ([command isEqualToString:@"tail"]) {
      return FLTail(arguments);
    }
    if ([command isEqualToString:@"dump"]) {
      return FLDumpStore(arguments);
    }
    if ([command isEqualToString:@"collect"]) {
      return FLRunCollect(arguments);
    }
    if ([command isEqualToString:@"usage"]) {
      return FLPrintUsage(arguments);
    }
    if ([command isEqualToString:@"inventory"]) {
      return FLShowInventory(arguments);
    }
    if ([command isEqualToString:@"depends"]) {
      return FLShowDepends(arguments);
    }
    if ([command isEqualToString:@"report"]) {
      return FLShowReport(arguments);
    }
    if ([command isEqualToString:@"reports"] && [arguments containsObject:@"--save"]) {
      return FLSaveReports();
    }
    if ([command isEqualToString:@"trace"]) {
      return FLTraceCommand(arguments);
    }
    if ([@[ @"hold", @"restore", @"store", @"discard" ] containsObject:command]) {
      return FLChangeCommand(command, arguments, ^{
        FLAskToSave();
      });
    }
    if (FLReportKindNamed(command) != nil) {
      return FLShowReport(@[ command ]);
    }
    if ([command isEqualToString:@"snapshot"]) {
      return FLAsk(FLCommandSnapshot, @"Asked the service to take every snapshot now.");
    }
    if ([command isEqualToString:@"import"]) {
      return FLAsk(FLCommandImport, @"Asked the service to look for new dumps now.");
    }
    if ([command isEqualToString:@"maintain"]) {
      return FLAsk(FLCommandMaintain, @"Asked the service to tidy its store now.");
    }
    if ([command isEqualToString:@"reload"]) {
      return FLAsk(FLCommandSettings, @"Asked the service to read its settings again.");
    }
    return FLShowUsage();
  }
}
