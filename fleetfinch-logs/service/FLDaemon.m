#import "FLDaemon.h"

#import <notify.h>
#import <signal.h>
#import <spawn.h>
#import <sys/utsname.h>
#import <sys/wait.h>

#import "FLChanges.h"
#import "FLCollect.h"
#import "FLCommon.h"
#import "FLInventory.h"
#import "FLMonitors.h"
#import "FLReport.h"
#import "FLReports.h"
#import "FLSettings.h"
#import "FLStore.h"
#import "FLSystemInfo.h"
#import "FLTrace.h"

extern char **environ;
extern void xpc_transaction_begin(void);
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer,
                                size_t size);

static const uint32_t FLSetHighWaterMark = 5;
static const uint32_t FLMemoryLimitMegabytes = 16;
static const NSTimeInterval FLLookSoon = 2;
static const NSTimeInterval FLLookLater = 20;
static const NSTimeInterval FLLookEvery = 300;
static const NSTimeInterval FLTraceFirst = 180;
static const NSTimeInterval FLTracedFresh = 600;
static NSString *const FLTraceSeconds = @"20";
static NSString *const FLTraceKept = @"traceSnapshot";

static NSString *const FLDaemonState = @"daemon";
static NSString *const FLStatusState = @"status";
static NSString *const FLLiveState = @"live";
static NSString *const FLServicesState = @"services";
static const NSTimeInterval FLUsageInterval = 60;
static const NSTimeInterval FLWatchWindow = 30;
static const NSTimeInterval FLFrequentSnapshots = 6 * 60 * 60;
static const NSTimeInterval FLSlowLaunch = 2;
static const NSTimeInterval FLAppsInterval = 600;
static const NSTimeInterval FLAppsFirst = 120;
static const NSTimeInterval FLReportEvery = 30;
static const NSTimeInterval FLInventoryFirst = 60;
static const NSTimeInterval FLInventoryCheck = 600;
static const NSTimeInterval FLInventoryRetry = 3600;
static const NSTimeInterval FLTrafficInterval = 60;
static NSString *const FLInventoryKept = @"inventory";
static NSString *const FLInstalledProgram = @"/usr/bin/finchlog";

static dispatch_queue_t FLWork;
static NSMutableDictionary<NSString *, dispatch_source_t> *FLTimers;
static NSMutableArray *FLSources;
static NSMutableDictionary *FLState;
static NSDate *FLStarted;
static NSDate *FLLaunched;
static NSDate *FLLastWrite;
static NSMutableArray<NSString *> *FLSnapshotsDue;
static NSMutableDictionary<NSString *, NSString *> *FLSnapshotReasons;
static NSDate *FLWatchedUntil;
static NSDictionary *FLLastMaintenance;
static NSDictionary *FLLastImport;
static NSDictionary *FLUsage;
static NSDate *FLUsageAt;
static NSDate *FLSampledAt;
static NSDate *FLReportedAt;
static NSUInteger FLServicesWritten;
static pid_t FLLister;
static NSDate *FLListerStarted;
static double FLListerAwake;
static NSDate *FLListerFailed;
static NSString *FLListerMarks;
static dispatch_source_t FLListerExit;
static NSMutableDictionary<NSString *, NSDate *> *FLReportsWritten;

static FLSyslogMonitor *FLSyslog;
static FLKernelMonitor *FLKernel;
static FLProcessMonitor *FLProcesses;
static FLResourceMonitor *FLResources;
static FLPowerMonitor *FLPower;
static FLNetworkMonitor *FLNetwork;
static FLEventMonitor *FLEvents;
static FLImportMonitor *FLImports;
static FLTrafficMonitor *FLTraffic;
static FLLoadedMonitor *FLLoaded;
static pid_t FLTracer;
static BOOL FLTracerTraces;
static dispatch_source_t FLTracerExit;
static FLUsageLedger *FLRunLedger;

static NSArray<NSString *> *FLFrequentKinds(void) {
  NSArray<NSString *> *kinds = @[
    @"processes", @"services", @"volumes", @"network", @"power", @"kernel", @"usage"
  ];
  return [kinds arrayByAddingObjectsFromArray:FLLiveReportKinds()];
}

static void FLStartTracer(BOOL tracing);

static void FLWriteReport(NSString *kind) {
  NSDate *last = FLReportsWritten[kind];
  if ([FLTracedReportKinds() containsObject:kind]) {
    NSDate *written = FLStateWritten(FLReportState(kind));
    if (written == nil || -written.timeIntervalSinceNow >= FLTracedFresh) {
      FLStartTracer(NO);
    }
    notify_post(FLReportNotice(kind).UTF8String);
    return;
  }
  if (last == nil || -last.timeIntervalSinceNow >= FLReportEvery) {
    NSDictionary *report = FLBuildReport(kind, FLCurrentReportSource());
    if (report != nil) {
      FLWriteCompactState(FLReportState(kind), report);
    }
    FLReportsWritten[kind] = [NSDate date];
  }
  notify_post(FLReportNotice(kind).UTF8String);
}

static BOOL FLRecords(NSString *stream) {
  return ![[FLStore shared].disabledStreams containsObject:stream];
}

static void FLGuard(NSString *name, dispatch_block_t work) {
  @try {
    @autoreleasepool {
      work();
    }
  } @catch (NSException *exception) {
    FLNote(@"finchlogs", FLLevelError, name, @"failed: %@ (%@)", exception.reason,
           exception.name);
  }
}

static void FLEvery(NSString *name, NSTimeInterval interval, NSTimeInterval first,
                    dispatch_block_t work) {
  dispatch_source_t existing = FLTimers[name];
  if (existing != nil) {
    dispatch_source_cancel(existing);
  }
  if (interval <= 0) {
    [FLTimers removeObjectForKey:name];
    return;
  }
  dispatch_source_t timer =
    dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, FLWork);
  dispatch_source_set_timer(timer,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(first * NSEC_PER_SEC)),
                            (uint64_t)(interval * NSEC_PER_SEC),
                            (uint64_t)(interval * NSEC_PER_SEC / 10));
  dispatch_source_set_event_handler(timer, ^{
    FLGuard(name, work);
  });
  dispatch_resume(timer);
  FLTimers[name] = timer;
}

static void FLSaveState(void) {
  FLState[@"lastSeen"] = [NSDate date];
  NSData *seen = [FLKernel.seen dataUsingEncoding:NSUTF8StringEncoding];
  if (seen.length > 0) {
    FLState[@"kernelSeen"] = seen;
  } else {
    [FLState removeObjectForKey:@"kernelSeen"];
  }
  FLWriteState(FLDaemonState, FLState);
}

static NSString *FLBootIdentifier(void) {
  NSString *session = FLSysctlString(@"kern.bootsessionuuid");
  if (session.length > 0) {
    return session;
  }
  NSDate *boot = FLBootTime();
  return boot == nil ? @"unknown" : FLTimestamp(boot);
}

static void FLTakeSnapshot(NSString *kind, NSString *why) {
  if (![FLCollectKinds() containsObject:kind]) {
    return;
  }
  NSDate *began = [NSDate date];
  NSString *heading = FLSnapshotHeading(kind, why, began);
  NSString *path = [[FLStore shared] saveSnapshot:kind
                                           pieces:^BOOL(void (^write)(NSString *piece)) {
                                             write(heading);
                                             return FLCollectPieces(kind, write);
                                           }];
  if (path == nil) {
    FLNote(@"finchlogs", FLLevelWarning, @"snapshot", @"%@ could not be saved", kind);
    return;
  }
  NSMutableDictionary *taken =
    [FLState[@"snapshots"] isKindOfClass:[NSDictionary class]]
      ? [FLState[@"snapshots"] mutableCopy]
      : [NSMutableDictionary new];
  taken[kind] = began;
  FLState[@"snapshots"] = taken;
  FLNote(@"finchlogs", FLLevelInfo, @"snapshot", @"saved %@ (%@) in %.1fs", kind,
         FLFormatBytes(FLFileSize(path)), -began.timeIntervalSinceNow);
}

static void FLTakeNextSnapshot(void) {
  NSString *kind = FLSnapshotsDue.firstObject;
  if (kind == nil) {
    return;
  }
  NSString *why = FLSnapshotReasons[kind] ?: @"";
  [FLSnapshotsDue removeObjectAtIndex:0];
  [FLSnapshotReasons removeObjectForKey:kind];
  FLGuard(kind, ^{
    FLTakeSnapshot(kind, why);
  });
  if (FLSnapshotsDue.count > 0) {
    dispatch_async(FLWork, ^{
      FLTakeNextSnapshot();
    });
  } else {
    FLSaveState();
  }
}

static void FLTakeSnapshots(NSArray<NSString *> *kinds, NSString *why) {
  BOOL idle = FLSnapshotsDue.count == 0;
  for (NSString *kind in kinds) {
    if (FLSnapshotReasons[kind] == nil) {
      [FLSnapshotsDue addObject:kind];
      FLSnapshotReasons[kind] = why;
    }
  }
  if (idle && FLSnapshotsDue.count > 0) {
    dispatch_async(FLWork, ^{
      FLTakeNextSnapshot();
    });
  }
}

static void FLTakeDueSnapshots(void) {
  NSDictionary *taken = FLState[@"snapshots"];
  NSTimeInterval daily = [FLSettings number:FLSettingSnapshotInterval];
  NSArray *frequent = FLFrequentKinds();
  NSMutableArray *due = [NSMutableArray new];
  for (NSString *kind in FLCollectKinds()) {
    NSDate *last = [taken[kind] isKindOfClass:[NSDate class]] ? taken[kind] : nil;
    NSTimeInterval interval = [frequent containsObject:kind] ? MIN(daily, FLFrequentSnapshots)
                                                             : daily;
    if (interval > 0 && (last == nil || -last.timeIntervalSinceNow >= interval)) {
      [due addObject:kind];
    }
  }
  if (due.count > 0) {
    FLTakeSnapshots(due, @"it was time for a new one");
  }
}

static void FLRecordBoot(void) {
  NSString *identifier = FLBootIdentifier();
  NSDate *boot = FLBootTime();
  struct utsname name;
  uname(&name);
  if ([FLState[@"boot"] isEqualToString:identifier]) {
    FLNote(@"boot", FLLevelNotice, @"finchlog",
           @"Finch Logs %@ started again; the device has been up %@", FLVersion,
           FLFormatDuration(FLUptime()));
    return;
  }
  NSDate *lastSeen = [FLState[@"lastSeen"] isKindOfClass:[NSDate class]]
    ? FLState[@"lastSeen"]
    : nil;
  if (FLLastWrite != nil &&
      (lastSeen == nil || [FLLastWrite compare:lastSeen] == NSOrderedDescending)) {
    lastSeen = FLLastWrite;
  }
  NSString *started = boot == nil ? @"an unknown time" : FLFormatDay(boot);
  NSTimeInterval waited = FLLaunched == nil ? 0 : [FLStarted timeIntervalSinceDate:FLLaunched];
  if (boot != nil && waited >= FLSlowLaunch) {
    FLNote(@"boot", FLLevelNotice, @"system",
           @"%s started at %@; launchd started Finch Logs %@ %@ later, and it began recording "
           @"%@ after that",
           name.nodename, started, FLVersion,
           FLFormatDuration([FLLaunched timeIntervalSinceDate:boot]), FLFormatDuration(waited));
  } else {
    FLNote(@"boot", FLLevelNotice, @"system",
           @"%s started at %@; Finch Logs %@ began recording %@ later", name.nodename, started,
           FLVersion,
           FLFormatDuration(boot == nil ? 0 : [FLStarted timeIntervalSinceDate:boot]));
  }
  NSTimeInterval away = lastSeen == nil || boot == nil ? -1
                                                       : [boot timeIntervalSinceDate:lastSeen];
  if (away >= 0) {
    FLNote(@"boot", FLLevelNotice, @"system",
           @"It was last seen running at %@, so it was off or restarting for about %@",
           FLFormatDay(lastSeen), FLFormatDuration(away));
  } else if (lastSeen != nil) {
    FLNote(@"boot", FLLevelNotice, @"system", @"It was last seen running at %@",
           FLFormatDay(lastSeen));
  } else {
    FLNote(@"boot", FLLevelNotice, @"system", @"This is the first start Finch Logs has seen");
  }
  FLNote(@"boot", FLLevelNotice, @"system", @"%s %s, build %@, boot arguments: %@",
         name.sysname, name.release, FLSysctlString(@"kern.osversion") ?: @"unknown",
         FLSysctlString(@"kern.bootargs") ?: @"");
  FLNote(@"boot", FLLevelNotice, @"system", @"%s", name.version);
  NSArray<FLProcess *> *processes =
    [FLProcessList(YES) sortedArrayUsingComparator:^(FLProcess *first, FLProcess *second) {
      return [first.started compare:second.started];
    }];
  FLNote(@"boot", FLLevelNotice, @"system",
         @"%lu processes were already running, listed here at the moment each began",
         (unsigned long)processes.count);
  for (FLProcess *process in processes) {
    NSTimeInterval offset = boot == nil ? 0 : [process.started timeIntervalSinceDate:boot];
    NSString *label = [FLProcesses serviceLabelForProcess:process.pid];
    NSString *service = label == nil ? @"" : [NSString stringWithFormat:@", service %@", label];
    NSString *message = [NSString
      stringWithFormat:@"began %.1fs after start as pid %d (parent %d, %@%@): %@", offset,
                       process.pid, process.parent, FLUserName(process.user), service,
                       [process commandLine]];
    [[FLStore shared] log:@"boot"
                    level:FLLevelInfo
                   source:process.name
                  message:message
                     date:process.started];
  }
  FLNote(@"boot", FLLevelNotice, @"system",
         @"launchd has %lu services loaded and %lu of them running",
         (unsigned long)[FLProcesses serviceCount],
         (unsigned long)[FLProcesses runningServiceCount]);
  FLState[@"boot"] = identifier;
  FLState[@"snapshots"] = @{};
  FLSaveState();
  if (FLRecords(@"snapshot")) {
    FLTakeSnapshots(FLCollectKinds(), @"the device started");
  }
}

static void FLMaintain(void) {
  NSDictionary *result = [[FLStore shared] maintain];
  FLLastMaintenance = @{@"at" : [NSDate date], @"result" : result ?: @{}};
  FLUsage = FLStoreUsage();
  FLUsageAt = [NSDate date];
  if ([result[@"archived"] integerValue] > 0 || [result[@"deleted"] integerValue] > 0 ||
      [result[@"trimmed"] integerValue] > 0 || [result[@"failed"] integerValue] > 0) {
    FLNote(@"finchlogs", FLLevelInfo, @"store",
           @"archived %@ files older than %@, deleted %@ older than %@, removed %@ to stay "
           @"under the size limit, %@ could not be archived; the store holds %@",
           result[@"archived"], FLFormatDuration([FLSettings number:FLSettingArchiveAfter]),
           result[@"deleted"], FLFormatDuration([FLSettings number:FLSettingDeleteAfter]),
           result[@"trimmed"], result[@"failed"],
           FLFormatBytes([result[@"bytes"] unsignedLongLongValue]));
  }
}

static void FLImport(void) {
  NSDictionary *result = [FLImports scan];
  FLLastImport = @{@"at" : [NSDate date], @"result" : result ?: @{}};
  if ([result[@"copied"] integerValue] > 0 || [result[@"lines"] integerValue] > 0) {
    FLNote(@"finchlogs", FLLevelInfo, @"import",
           @"copied %@ new dumps and read %@ new lines from %@ log files", result[@"copied"],
           result[@"lines"], result[@"seen"]);
  }
}

static void FLListerEnded(int status) {
  NSTimeInterval took = FLAwakeSeconds() - FLListerAwake;
  NSDate *written = FLStateWritten(FLInventoryState);
  BOOL clean = WIFEXITED(status) && WEXITSTATUS(status) == 0;
  BOOL listed = clean || (written != nil && [written timeIntervalSinceDate:FLListerStarted] > 0);
  if (FLListerExit != nil) {
    dispatch_source_cancel(FLListerExit);
    FLListerExit = nil;
  }
  FLLister = 0;
  FLListerFailed = clean ? nil : [NSDate date];
  if (listed) {
    FLState[FLInventoryKept] = @{
      @"at" : [NSDate date],
      @"marks" : FLListerMarks ?: @"",
      @"took" : @(took),
      @"boot" : FLBootIdentifier(),
    };
    FLSaveState();
  }
  if (clean) {
    FLNote(@"finchlogs", FLLevelInfo, @"inventory",
           @"listed what is installed and what depends on what in %@", FLFormatDuration(took));
  } else if (listed) {
    FLNote(@"finchlogs", FLLevelWarning, @"inventory",
           @"listed what is installed in %@, but the helper ended with %@ before it had worked "
           @"out what depends on what",
           FLFormatDuration(took), FLDescribeExit(status));
  } else {
    FLNote(@"finchlogs", FLLevelWarning, @"inventory",
           @"what is installed could not be listed: the helper ended with %@ after %@",
           FLDescribeExit(status), FLFormatDuration(took));
  }
}

static BOOL FLReapLister(void) {
  int status = 0;
  if (FLLister <= 0 || waitpid(FLLister, &status, WNOHANG) != FLLister) {
    return NO;
  }
  FLListerEnded(status);
  return YES;
}

static void FLStartLister(NSString *why) {
  if (FLLister > 0 && !FLReapLister()) {
    return;
  }
  NSString *program = [NSBundle mainBundle].executablePath ?: FLInstalledProgram;
  NSMutableArray<NSString *> *arguments =
    [@[ program.lastPathComponent, @"inventory", @"--save" ] mutableCopy];
  if (FLRecords(@"snapshot")) {
    [arguments addObjectsFromArray:@[ @"--snapshot", @"--reason", why ]];
  }
  char **argv = calloc(arguments.count + 1, sizeof(char *));
  for (NSUInteger index = 0; index < arguments.count; index++) {
    argv[index] = (char *)arguments[index].UTF8String;
  }
  pid_t pid = 0;
  [FLRunLedger save];
  [FLLoaded save];
  FLListerMarks = FLInventoryMarks();
  int failed = posix_spawn(&pid, program.fileSystemRepresentation, NULL, NULL, argv, environ);
  free(argv);
  if (failed != 0) {
    FLListerFailed = [NSDate date];
    FLNote(@"finchlogs", FLLevelWarning, @"inventory",
           @"the helper that lists what is installed could not be started: %s",
           strerror(failed));
    return;
  }
  FLLister = pid;
  FLListerStarted = [NSDate date];
  FLListerAwake = FLAwakeSeconds();
  FLNote(@"finchlogs", FLLevelInfo, @"inventory",
         @"listing what is installed in pid %d, because %@", (int)pid, why);
  FLListerExit = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                        DISPATCH_PROC_EXIT, FLWork);
  dispatch_source_set_event_handler(FLListerExit, ^{
    if (FLLister == pid) {
      FLReapLister();
    }
  });
  dispatch_resume(FLListerExit);
  FLReapLister();
}

static void FLReapTracer(void) {
  int status = 0;
  if (FLTracer <= 0 || waitpid(FLTracer, &status, WNOHANG) != FLTracer) {
    return;
  }
  if (FLTracerExit != nil) {
    dispatch_source_cancel(FLTracerExit);
    FLTracerExit = nil;
  }
  FLTracer = 0;
  BOOL tracing = FLTracerTraces;
  FLTracerTraces = NO;
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    for (NSString *kind in FLTracedReportKinds()) {
      notify_post(FLReportNotice(kind).UTF8String);
    }
    return;
  }
  FLNote(@"finchlogs", FLLevelWarning, @"trace", @"the helper that %@ ended with %@%@",
         tracing ? @"traces" : @"writes the lists made from traces", FLDescribeExit(status),
         tracing && FLTraceRelease() ? @", so the kernel's trace was switched off for it" : @"");
}

static void FLStartTracer(BOOL tracing) {
  FLReapTracer();
  if (FLTracer > 0 || (tracing && FLLister > 0 && !FLReapLister())) {
    return;
  }
  NSString *program = [NSBundle mainBundle].executablePath ?: FLInstalledProgram;
  NSMutableArray<NSString *> *arguments = [@[ program.lastPathComponent ] mutableCopy];
  [arguments addObjectsFromArray:tracing ? @[ @"trace", @"--quiet", @"--for", FLTraceSeconds ]
                                         : @[ @"reports", @"--save" ]];
  NSDate *kept = [FLState[FLTraceKept] isKindOfClass:[NSDate class]] ? FLState[FLTraceKept] : nil;
  NSTimeInterval daily = [FLSettings number:FLSettingSnapshotInterval];
  if (tracing && FLRecords(@"snapshot") && daily > 0 &&
      (kept == nil || -kept.timeIntervalSinceNow >= daily)) {
    [arguments addObjectsFromArray:@[ @"--snapshot", @"--reason", @"it was time for a new one" ]];
    FLState[FLTraceKept] = [NSDate date];
  }
  char **argv = calloc(arguments.count + 1, sizeof(char *));
  for (NSUInteger index = 0; index < arguments.count; index++) {
    argv[index] = (char *)arguments[index].UTF8String;
  }
  pid_t pid = 0;
  [FLRunLedger save];
  [FLLoaded save];
  int failed = posix_spawn(&pid, program.fileSystemRepresentation, NULL, NULL, argv, environ);
  free(argv);
  if (failed != 0) {
    FLNote(@"finchlogs", FLLevelWarning, @"trace", @"the helper that traces could not be "
                                                   @"started: %s",
           strerror(failed));
    return;
  }
  FLTracer = pid;
  FLTracerTraces = tracing;
  FLTracerExit = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                        DISPATCH_PROC_EXIT, FLWork);
  dispatch_source_set_event_handler(FLTracerExit, ^{
    FLReapTracer();
  });
  dispatch_resume(FLTracerExit);
  FLReapTracer();
}

static void FLCheckInventory(void) {
  if (FLLister > 0 && !FLReapLister()) {
    return;
  }
  if (FLListerFailed != nil && -FLListerFailed.timeIntervalSinceNow < FLInventoryRetry) {
    return;
  }
  NSDictionary *last = FLState[FLInventoryKept];
  NSDate *written = FLStateWritten(FLInventoryState);
  NSTimeInterval daily = [FLSettings number:FLSettingSnapshotInterval];
  if (written == nil || ![last isKindOfClass:[NSDictionary class]]) {
    FLStartLister(@"nothing was listed yet");
  } else if (![last[@"boot"] isEqual:FLBootIdentifier()]) {
    FLStartLister(@"the device started");
  } else if (![last[@"marks"] isEqual:FLInventoryMarks()]) {
    FLStartLister(@"something was installed or removed");
  } else if (daily > 0 && -written.timeIntervalSinceNow >= daily) {
    FLStartLister(@"it was time for a new one");
  }
}

static BOOL FLWatched(void) {
  return FLWatchedUntil != nil && FLWatchedUntil.timeIntervalSinceNow > 0;
}

static void FLWriteStatus(void) {
  if (FLUsage == nil || -FLUsageAt.timeIntervalSinceNow > 300) {
    FLUsage = FLStoreUsage();
    FLUsageAt = [NSDate date];
  }
  NSMutableDictionary *status = [NSMutableDictionary new];
  status[@"version"] = FLVersion;
  status[@"pid"] = @(getpid());
  status[@"started"] = FLStarted;
  if (FLLaunched != nil) {
    status[@"launched"] = FLLaunched;
  }
  status[@"written"] = [NSDate date];
  status[@"boot"] = FLState[@"boot"] ?: @"";
  NSDate *boot = FLBootTime();
  if (boot != nil) {
    status[@"bootTime"] = boot;
  }
  status[@"counts"] = [[FLStore shared] counts] ?: @{};
  status[@"systemLogConnected"] = @(FLSyslog.connected);
  status[@"systemLogMessages"] = @(FLSyslog.received);
  status[@"processes"] = @([FLProcesses processCount]);
  status[@"services"] = @([FLProcesses serviceCount]);
  status[@"runningServices"] = @([FLProcesses runningServiceCount]);
  status[@"frontApp"] = [FLProcesses frontApp];
  status[@"usage"] = FLUsage ?: @{};
  status[@"snapshots"] = FLState[@"snapshots"] ?: @{};
  status[@"resources"] = [FLResources latest];
  if (FLLastMaintenance != nil) {
    status[@"maintenance"] = FLLastMaintenance;
  }
  if (FLLastImport != nil) {
    status[@"import"] = FLLastImport;
  }
  status[@"settings"] = [FLSettings current];
  FLWriteState(FLStatusState, status);
}

static void FLWriteLive(BOOL fresh) {
  if (!FLWatched()) {
    return;
  }
  [FLProcesses sampleUsage:NO];
  [FLResources sample:NO];
  FLWriteState(FLLiveState, @{
    @"written" : [NSDate date],
    @"processes" : [FLProcesses liveProcesses] ?: @[],
    @"resources" : [FLResources latest],
    @"frontApp" : [FLProcesses frontApp],
  });
  NSUInteger version = [FLProcesses servicesVersion];
  if (fresh || version != FLServicesWritten) {
    FLServicesWritten = version;
    FLWriteState(FLServicesState, @{
      @"written" : [NSDate date],
      @"services" : [FLProcesses services] ?: @[],
    });
  }
}

static void FLApplySettings(void) {
  NSArray *disabled = [FLSettings current][FLSettingDisabledCollectors];
  NSMutableSet *streams = [NSMutableSet new];
  for (id name in disabled) {
    if ([name isKindOfClass:[NSString class]] && ![name isEqualToString:@"finchlogs"]) {
      [streams addObject:name];
    }
  }
  [FLStore shared].disabledStreams = streams;
}

static NSTimeInterval FLResourceInterval(void) {
  return MAX(5, [FLSettings number:FLSettingResourceInterval]);
}

static void FLSampleResources(void) {
  [FLResources sample:YES];
  [FLPower checkBattery];
  FLSampledAt = [NSDate date];
}

static void FLEveryResources(NSTimeInterval first) {
  FLEvery(@"resource", FLResourceInterval(), first, ^{
    FLSampleResources();
  });
}

static void FLCatchUp(void) {
  if (FLRecords(@"kernel")) {
    [FLKernel poll];
  }
  [FLProcesses poll];
  NSTimeInterval interval = FLResourceInterval();
  if (FLSampledAt == nil || -FLSampledAt.timeIntervalSinceNow >= interval) {
    FLSampleResources();
    FLEveryResources(interval);
  }
  FLWriteStatus();
  [FLRunLedger saveIfDue];
}

static void FLSchedule(void) {
  FLApplySettings();
  NSTimeInterval processes = MAX(1, [FLSettings number:FLSettingProcessInterval]);
  NSTimeInterval imports = MAX(60, [FLSettings number:FLSettingImportInterval]);
  FLEvery(@"kernel", FLRecords(@"kernel") ? 5 : 0, 1, ^{
    [FLKernel poll];
  });
  FLEvery(@"process", processes, 2, ^{
    [FLProcesses poll];
  });
  FLEvery(@"usage", FLRecords(@"resource") ? FLUsageInterval : 0, 10, ^{
    [FLProcesses sampleUsage:YES];
  });
  FLEveryResources(3);
  FLEvery(@"network", FLRecords(@"network") ? 600 : 0, 4, ^{
    [FLNetwork check];
  });
  FLEvery(@"import", FLRecords(@"file") || FLRecords(@"import") ? imports : 0, 20, ^{
    FLImport();
  });
  FLEvery(@"apps", FLRecords(@"app") ? FLAppsInterval : 0, FLAppsFirst, ^{
    [FLProcesses checkApps];
  });
  FLEvery(@"maintain", 60 * 60, 90, ^{
    FLMaintain();
  });
  FLEvery(@"snapshot", FLRecords(@"snapshot") ? 600 : 0, 600, ^{
    FLTakeDueSnapshots();
  });
  FLEvery(@"inventory", FLInventoryCheck, FLInventoryFirst, ^{
    FLCheckInventory();
  });
  FLEvery(@"status", 15, 5, ^{
    FLWriteStatus();
  });
  FLEvery(@"heartbeat", 60, 60, ^{
    FLSaveState();
    [FLRunLedger saveIfDue];
    [FLTraffic saveIfDue];
    [FLLoaded saveIfDue];
  });
  FLEvery(@"loaded", FLLookEvery, FLLookEvery, ^{
    [FLLoaded sweep];
  });
  FLEvery(@"trace", [FLSettings number:FLSettingTraceInterval], FLTraceFirst, ^{
    FLStartTracer(YES);
  });
  FLEvery(@"traffic", FLRecords(@"connection") ? FLTrafficInterval : 0, 30, ^{
    [FLTraffic refresh];
  });
  FLEvery(@"live", 5, 5, ^{
    FLWriteLive(NO);
  });
}

static void FLOnCommand(NSString *name, dispatch_block_t work) {
  int token = 0;
  notify_register_dispatch(name.UTF8String, &token, FLWork, ^(int fired) {
    FLGuard(name, work);
  });
}

static void FLStop(int signal) {
  FLNote(@"finchlogs", FLLevelNotice, @"finchlog", @"Stopping on signal %d after %@", signal,
         FLFormatDuration(-FLStarted.timeIntervalSinceNow));
  [FLSyslog stop];
  FLSaveState();
  [FLRunLedger save];
  [FLTraffic save];
  [FLLoaded save];
  [[FLStore shared] sync];
  exit(0);
}

static void FLOnSignal(int number) {
  signal(number, SIG_IGN);
  dispatch_source_t source =
    dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)number, 0, FLWork);
  dispatch_source_set_event_handler(source, ^{
    FLStop(number);
  });
  dispatch_resume(source);
  [FLSources addObject:source];
}

int FLRunDaemon(void) {
  if (![[FLStore shared] prepare]) {
    fprintf(stderr, "finchlog: %s could not be created\n", FLRootPath.UTF8String);
    return 1;
  }
  FLApplySettings();
  FLStarted = [NSDate date];
  xpc_transaction_begin();
  int limited = memorystatus_control(FLSetHighWaterMark, getpid(), FLMemoryLimitMegabytes, NULL, 0);
  int limitError = errno;
  FLLaunched = FLProcessWithIdentifier(getpid()).started;
  FLTimers = [NSMutableDictionary new];
  FLSources = [NSMutableArray new];
  FLSnapshotsDue = [NSMutableArray new];
  FLSnapshotReasons = [NSMutableDictionary new];
  FLState = [FLReadState(FLDaemonState) mutableCopy];
  if (![FLState[@"boot"] isEqualToString:FLBootIdentifier()]) {
    FLLastWrite = FLNewestLogWrite();
  }
  dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
    DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
  FLWork = dispatch_queue_create("com.fleetfinch.logs.work", attributes);

  FLNote(@"finchlogs", FLLevelNotice, @"finchlog",
         @"Finch Logs %@ started as pid %d (uid %d)", FLVersion, (int)getpid(),
         (int)getuid());
  if (getuid() != 0) {
    FLNote(@"finchlogs", FLLevelWarning, @"finchlog",
           @"Not running as root, so other users' processes and some logs cannot be read");
  }
  if (limited != 0) {
    FLNote(@"finchlogs", FLLevelWarning, @"finchlog",
           @"The memory iOS allows this service could not be raised to %u MB (%s), so iOS may "
           @"stop it while it takes a large snapshot",
           FLMemoryLimitMegabytes, strerror(limitError));
  }

  FLSyslog = [FLSyslogMonitor new];
  FLKernel = [FLKernelMonitor new];
  FLProcesses = [FLProcessMonitor new];
  FLResources = [FLResourceMonitor new];
  FLPower = [FLPowerMonitor new];
  FLNetwork = [FLNetworkMonitor new];
  FLEvents = [FLEventMonitor new];
  FLImports = [FLImportMonitor new];
  FLTraffic = [FLTrafficMonitor new];
  FLLoaded = [FLLoadedMonitor new];
  FLRunLedger = [[FLUsageLedger alloc] initForBoot:FLBootIdentifier()];
  FLSetUsageLedger(FLRunLedger);
  FLProcesses.ledger = FLRunLedger;
  FLReportsWritten = [NSMutableDictionary new];
  FLSetReportSource(^NSDictionary *(NSString *name) {
    if ([name isEqualToString:FLUsageState]) {
      return [FLRunLedger contents];
    }
    if ([name isEqualToString:FLLoadedState]) {
      return [FLLoaded contents];
    }
    return [name isEqualToString:FLTrafficState] ? [FLTraffic contents] : FLReadState(name);
  });
  FLRunLedger.started = ^(FLProcess *process) {
    [FLLoaded noticed:process after:FLLookSoon];
    [FLLoaded noticed:process after:FLLookLater];
  };
  FLSyslog.troubled = ^(NSString *sender, int pid, FLLevel level) {
    dispatch_async(FLWork, ^{
      [FLRunLedger logged:level by:sender pid:pid];
    });
  };
  FLImports.reported = ^(NSString *name, NSString *kind, NSString *path) {
    [FLRunLedger reported:name kind:kind path:path];
  };
  if ([FLState[@"boot"] isEqualToString:FLBootIdentifier()] &&
      [FLState[@"kernelSeen"] isKindOfClass:[NSData class]]) {
    FLKernel.seen = [[NSString alloc] initWithData:FLState[@"kernelSeen"]
                                          encoding:NSUTF8StringEncoding];
  }

  FLOnSignal(SIGTERM);
  FLOnSignal(SIGINT);
  FLOnSignal(SIGHUP);

  FLPower.woke = ^{
    dispatch_async(FLWork, ^{
      FLGuard(@"wake", ^{
        FLCatchUp();
      });
    });
  };
  [FLSyslog start];
  [FLPower start];
  dispatch_async(FLWork, ^{
    FLGuard(@"start", ^{
      if (FLRecords(@"kernel")) {
        [FLKernel poll];
      }
      FLWriteStatus();
      [FLProcesses poll];
      [FLProcesses watchOnQueue:FLWork];
      if (FLRecords(@"connection")) {
        [FLTraffic startOnQueue:FLWork];
      }
      [FLLoaded startOnQueue:FLWork];
      [FLResources sample:NO];
      FLWriteStatus();
      [FLEvents startOnQueue:FLWork
                     network:^{
                       FLGuard(@"network", ^{
                         [FLNetwork check];
                       });
                     }
                       power:^{
                         FLGuard(@"power", ^{
                           [FLPower checkBattery];
                         });
                       }
                        apps:^{
                          FLGuard(@"apps", ^{
                            [FLProcesses checkApps];
                          });
                        }];
      FLSchedule();
      FLRecordBoot();
    });
  });

  FLOnCommand(FLCommandSnapshot, ^{
    FLNote(@"finchlogs", FLLevelInfo, @"command", @"Asked to take every snapshot now");
    FLTakeSnapshots(FLCollectKinds(), @"it was asked for");
    [FLState removeObjectForKey:FLTraceKept];
    FLStartLister(@"it was asked for");
  });
  FLOnCommand(FLCommandInventory, ^{
    FLStartLister(@"it was asked for");
  });
  FLOnCommand(FLCommandImport, ^{
    FLNote(@"finchlogs", FLLevelInfo, @"command", @"Asked to look for new dumps now");
    FLImport();
    FLWriteStatus();
  });
  FLOnCommand(FLCommandMaintain, ^{
    FLNote(@"finchlogs", FLLevelInfo, @"command", @"Asked to tidy the store now");
    FLMaintain();
    FLWriteStatus();
  });
  FLOnCommand(FLCommandSettings, ^{
    FLNote(@"finchlogs", FLLevelInfo, @"command", @"Settings changed; rescheduling");
    FLSchedule();
    FLWriteStatus();
  });
  FLOnCommand(FLCommandUsage, ^{
    [FLRunLedger save];
    [FLTraffic save];
    [FLLoaded save];
    if (FLReportedAt == nil || -FLReportedAt.timeIntervalSinceNow >= FLReportEvery) {
      FLWriteUsageReport(FLUsageReport([FLRunLedger contents]));
      FLReportedAt = [NSDate date];
    }
    notify_post(FLNoticeUsage.UTF8String);
  });
  for (NSString *kind in FLReportKinds()) {
    FLOnCommand(FLReportCommand(kind), ^{
      FLWriteReport(kind);
    });
  }
  int restoring = 0;
  notify_register_dispatch(FLCommandRestore.UTF8String, &restoring, FLWork, ^(int fired) {
    FLGuard(FLCommandRestore, ^{
      uint64_t number = 0;
      if (notify_get_state(fired, &number) == NOTIFY_STATUS_OK && number > 0) {
        FLRestoreChange(@(number), @"as asked in the app");
        [FLReportsWritten removeObjectForKey:@"changes"];
        FLWriteReport(@"changes");
      }
    });
  });
  FLWatchChanges(FLWork);
  FLOnCommand(FLCommandWatch, ^{
    BOOL already = FLWatched();
    FLWatchedUntil = [NSDate dateWithTimeIntervalSinceNow:FLWatchWindow];
    if (!already) {
      FLWriteLive(YES);
    }
  });

  CFRunLoopRun();
  return 0;
}

