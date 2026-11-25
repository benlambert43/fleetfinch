#import "FLMonitors.h"

#import <sys/stat.h>

#import "FLCollect.h"
#import "FLStatus.h"
#import "FLSystemInfo.h"

static NSString *const FLSpringBoardServices =
  @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices";
static const NSTimeInterval FLServiceReload = 600;
static const NSTimeInterval FLJobReload = 60;
static const NSUInteger FLTopCount = 5;
static const NSUInteger FLKernelTail = 160;
static const NSUInteger FLKernelAnchor = 64;
static NSString *const FLAppsState = @"apps";

@implementation FLKernelMonitor {
  NSString *_previous;
}

- (NSString *)linesAddedTo:(NSString *)current {
  if (_previous.length > 0) {
    NSString *head = [current substringToIndex:MIN(FLKernelAnchor, current.length)];
    NSRange search = NSMakeRange(0, _previous.length);
    for (;;) {
      NSRange found = [_previous rangeOfString:head options:0 range:search];
      if (found.location == NSNotFound) {
        return nil;
      }
      NSString *kept = [_previous substringFromIndex:found.location];
      if ([current hasPrefix:kept]) {
        return [current substringFromIndex:kept.length];
      }
      search = NSMakeRange(found.location + 1, _previous.length - found.location - 1);
    }
  }
  if (_seen.length > 0) {
    NSRange found = [current rangeOfString:_seen options:NSBackwardsSearch];
    if (found.location != NSNotFound) {
      return [current substringFromIndex:NSMaxRange(found)];
    }
  }
  return nil;
}

- (void)poll {
  NSString *current = FLKernelMessages();
  if (current.length == 0) {
    return;
  }
  NSRange lastLine = [current rangeOfString:@"\n" options:NSBackwardsSearch];
  if (lastLine.location == NSNotFound) {
    return;
  }
  NSUInteger end = lastLine.location;
  while (end > 0 && [current characterAtIndex:end - 1] == '\n') {
    end--;
  }
  current = [[current substringToIndex:end] stringByAppendingString:@"\n"];
  if ([current isEqualToString:_previous]) {
    return;
  }
  NSString *fresh = [self linesAddedTo:current];
  BOOL whole = fresh == nil;
  if (whole) {
    if (_previous.length > 0 || _seen.length > 0) {
      FLNote(@"kernel", FLLevelInfo, @"finchlog",
             @"Some kernel messages were overwritten before they could be read");
    }
    fresh = current;
  }
  _previous = current;
  _seen = [current substringFromIndex:current.length - MIN(FLKernelTail, current.length)];
  NSUInteger index = 0;
  for (NSString *line in [fresh componentsSeparatedByString:@"\n"]) {
    NSString *text = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL partial = whole && index == 0;
    index++;
    if (text.length == 0 || partial) {
      continue;
    }
    FLNote(@"kernel", FLLevelNotice, @"kernel", @"%@", text);
  }
}

@end

@implementation FLProcessMonitor {
  NSMutableDictionary<NSString *, FLProcess *> *_known;
  NSMutableDictionary<NSString *, NSNumber *> *_processor;
  NSMutableDictionary<NSString *, NSNumber *> *_memory;
  NSArray<NSDictionary *> *_definitions;
  NSDate *_definitionsLoaded;
  NSDictionary<NSString *, NSDictionary *> *_jobs;
  NSDictionary<NSNumber *, NSString *> *_jobLabels;
  NSDate *_jobsLoaded;
  NSUInteger _jobsVersion;
  NSArray<NSDictionary *> *_live;
  NSDictionary<NSString *, NSDictionary *> *_apps;
  NSString *_front;
  NSDate *_sampled;
  BOOL _primed;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _known = [NSMutableDictionary new];
    _processor = [NSMutableDictionary new];
    _memory = [NSMutableDictionary new];
    _jobLabels = @{};
    _live = @[];
  }
  return self;
}

- (NSArray<NSDictionary *> *)definitions {
  if (_definitions == nil || -_definitionsLoaded.timeIntervalSinceNow > FLServiceReload) {
    _definitions = FLLaunchServices();
    _definitionsLoaded = [NSDate date];
  }
  return _definitions;
}

- (BOOL)loadJobs {
  NSDictionary<NSString *, NSDictionary *> *jobs = FLLaunchJobs();
  _jobsLoaded = [NSDate date];
  if (jobs == nil || [jobs isEqualToDictionary:_jobs]) {
    return NO;
  }
  NSMutableDictionary *labels = [NSMutableDictionary new];
  for (NSString *label in jobs) {
    NSNumber *pid = jobs[label][@"pid"];
    if (pid.intValue > 0) {
      labels[pid] = label;
    }
  }
  _jobs = jobs;
  _jobLabels = labels;
  _jobsVersion++;
  return YES;
}

- (NSString *)bundledServiceLabel:(FLProcess *)process {
  NSRange bundle = [process.path rangeOfString:@".xpc/"];
  if (bundle.location == NSNotFound) {
    return nil;
  }
  NSString *folder = [process.path substringToIndex:bundle.location + 4];
  NSString *identifier = FLBundleInfo(folder)[@"identifier"];
  return identifier.length > 0 ? [identifier stringByAppendingString:@" (XPC service)"] : nil;
}

- (NSString *)serviceLabelForProcess:(int)pid {
  return _jobLabels[@(pid)];
}

- (FLProcess *)known:(int)pid {
  for (FLProcess *process in _known.allValues) {
    if (process.pid == pid) {
      return process;
    }
  }
  return nil;
}

- (void)started:(FLProcess *)process {
  FLProcess *parent = [self known:process.parent];
  NSString *parentName = process.parent == 1 ? @"launchd"
                                             : ([parent displayName] ?: @"a process");
  NSString *label = _jobLabels[@(process.pid)];
  NSString *service = label == nil ? @"" : [NSString stringWithFormat:@" for %@", label];
  FLNote(@"process", FLLevelNotice, process.name,
         @"started pid %d by %@ (pid %d)%@ as %@: %@", process.pid, parentName,
         process.parent, service, FLUserName(process.user), [process commandLine]);
  if (process.parent == 1 && label == nil) {
    FLNote(@"service", FLLevelNotice, [self bundledServiceLabel:process] ?: process.name,
           @"started as pid %d running %@", process.pid, [process commandLine]);
  }
  NSString *bundle = [process appBundlePath];
  if (bundle != nil) {
    NSDictionary *info = FLBundleInfo(bundle);
    FLNote(@"app", FLLevelNotice, info[@"name"] ?: process.name,
           @"opened as pid %d (%@ %@) from %@", process.pid, info[@"identifier"] ?: @"",
           info[@"version"] ?: @"", bundle);
  }
}

- (void)exited:(FLProcess *)process labels:(NSDictionary<NSNumber *, NSString *> *)labels {
  NSString *identity = [process identity];
  NSTimeInterval lived = -process.started.timeIntervalSinceNow;
  NSNumber *processor = _processor[identity];
  NSNumber *memory = _memory[identity];
  NSString *usage = processor == nil
    ? @""
    : [NSString stringWithFormat:@", having used %.2fs of processor and %@ of memory when "
                                 @"last seen",
                                 processor.doubleValue,
                                 FLFormatBytes(memory.unsignedLongLongValue)];
  FLNote(@"process", FLLevelNotice, process.name, @"exited pid %d after %@%@", process.pid,
         FLFormatDuration(lived), usage);
  if (process.parent == 1 && labels[@(process.pid)] == nil) {
    FLNote(@"service", FLLevelNotice, [self bundledServiceLabel:process] ?: process.name,
           @"stopped (pid %d) after %@", process.pid, FLFormatDuration(lived));
  }
  NSString *bundle = [process appBundlePath];
  if (bundle != nil) {
    NSDictionary *info = FLBundleInfo(bundle);
    FLNote(@"app", FLLevelNotice, info[@"name"] ?: process.name, @"closed (pid %d) after %@",
           process.pid, FLFormatDuration(lived));
  }
  [_processor removeObjectForKey:identity];
  [_memory removeObjectForKey:identity];
}

- (NSString *)commandOfJob:(NSDictionary *)job process:(FLProcess *)process {
  if (process != nil) {
    return [process commandLine];
  }
  NSArray *arguments = job[@"arguments"];
  return arguments.count > 0 ? [arguments componentsJoinedByString:@" "]
                             : (job[@"program"] ?: @"an unknown program");
}

- (void)noteStopped:(NSString *)label
                pid:(int)pid
             status:(NSNumber *)status
             exited:(NSArray<FLProcess *> *)exited
            removed:(BOOL)removed {
  FLProcess *process = nil;
  for (FLProcess *candidate in exited) {
    if (candidate.pid == pid) {
      process = candidate;
    }
  }
  NSString *lived = process == nil
    ? @""
    : [NSString stringWithFormat:@" after %@", FLFormatDuration(-process.started
                                                                    .timeIntervalSinceNow)];
  NSString *ending = @"";
  FLLevel level = FLLevelNotice;
  if (removed) {
    ending = @" and launchd let go of it";
  } else if (status != nil) {
    ending = [@" with " stringByAppendingString:FLDescribeExit(status.integerValue)];
    if (status.integerValue != 0) {
      level = FLLevelWarning;
    }
  }
  FLNote(@"service", level, label, @"stopped (pid %d)%@%@", pid, lived, ending);
}

- (void)compareJobs:(NSDictionary<NSString *, NSDictionary *> *)before
             exited:(NSArray<FLProcess *> *)exited {
  NSArray<NSString *> *labels =
    [_jobs.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *label in labels) {
    NSDictionary *job = _jobs[label];
    NSDictionary *old = before[label];
    int pid = [job[@"pid"] intValue];
    int oldPid = [old[@"pid"] intValue];
    if (old != nil && pid == oldPid) {
      continue;
    }
    if (oldPid > 0) {
      [self noteStopped:label pid:oldPid status:job[@"status"] exited:exited removed:NO];
    }
    NSString *command = [self commandOfJob:job process:pid > 0 ? [self known:pid] : nil];
    if (pid > 0) {
      FLNote(@"service", FLLevelNotice, label, @"%@ as pid %d running %@",
             old == nil ? @"added to launchd and started" : @"started", pid, command);
    } else if (old == nil) {
      FLNote(@"service", FLLevelInfo, label, @"added to launchd, to run %@ when needed",
             command);
    }
  }
  for (NSString *label in [before.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (_jobs[label] != nil) {
      continue;
    }
    int oldPid = [before[label][@"pid"] intValue];
    if (oldPid > 0) {
      [self noteStopped:label pid:oldPid status:nil exited:exited removed:YES];
    } else {
      FLNote(@"service", FLLevelInfo, label, @"removed from launchd");
    }
  }
}

- (NSArray<NSDictionary *> *)services {
  NSMutableArray *rows = [NSMutableArray new];
  for (NSDictionary *service in FLServiceTable(_jobs, [self definitions])) {
    NSMutableDictionary *row = [NSMutableDictionary new];
    row[@"label"] = service[@"label"];
    row[@"pid"] = service[@"pid"] ?: @0;
    row[@"loaded"] = service[@"loaded"] ?: @NO;
    row[@"starts"] = FLServiceStarts(service);
    row[@"program"] = service[@"program"] ?: @"";
    NSArray *arguments = service[@"arguments"];
    row[@"command"] = arguments.count > 0 ? [arguments componentsJoinedByString:@" "]
                                          : (service[@"program"] ?: @"");
    row[@"file"] = service[@"file"] ?: @"";
    row[@"user"] = service[@"user"] ?: @"";
    if (service[@"status"] != nil) {
      row[@"status"] = service[@"status"];
      row[@"lastExit"] = FLDescribeExit([service[@"status"] integerValue]);
    }
    [rows addObject:row];
  }
  return rows;
}

- (NSUInteger)servicesVersion {
  return _jobsVersion;
}

- (NSUInteger)serviceCount {
  return _jobs.count;
}

- (NSUInteger)runningServiceCount {
  return _jobLabels.count;
}

- (NSString *)lookUpFrontApp {
  static CFStringRef (*copyFront)(void);
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    copyFront = FLSymbol(FLSpringBoardServices.fileSystemRepresentation,
                         "SBSCopyFrontmostApplicationDisplayIdentifier");
  });
  if (copyFront == NULL) {
    return nil;
  }
  return CFBridgingRelease(copyFront());
}

- (void)checkFront {
  NSString *front = [self lookUpFrontApp] ?: @"";
  if (_front != nil && [front isEqualToString:_front]) {
    return;
  }
  BOOL first = _front == nil;
  _front = front;
  if (first && front.length == 0) {
    return;
  }
  NSString *name = nil;
  for (FLProcess *process in _known.allValues) {
    NSString *bundle = [process appBundlePath];
    if (bundle != nil && [FLBundleInfo(bundle)[@"identifier"] isEqualToString:front]) {
      name = FLBundleInfo(bundle)[@"name"];
      break;
    }
  }
  if (front.length == 0) {
    FLNote(@"app", FLLevelInfo, @"SpringBoard", @"no app is in front");
  } else {
    FLNote(@"app", FLLevelInfo, name ?: front, @"came to the front (%@)", front);
  }
}

- (void)poll {
  NSArray<FLProcess *> *listed = FLProcessList(NO);
  if (listed.count == 0) {
    return;
  }
  NSMutableDictionary<NSString *, FLProcess *> *current = [NSMutableDictionary new];
  NSMutableArray<FLProcess *> *started = [NSMutableArray new];
  for (FLProcess *process in listed) {
    NSString *identity = [process identity];
    FLProcess *known = _known[identity];
    if (known != nil) {
      current[identity] = known;
      continue;
    }
    FLProcess *detailed = FLProcessWithIdentifier(process.pid);
    if (detailed == nil || ![[detailed identity] isEqualToString:identity]) {
      detailed = process;
    }
    current[identity] = detailed;
    [started addObject:detailed];
  }
  NSMutableArray<FLProcess *> *exited = [NSMutableArray new];
  for (NSString *identity in _known) {
    if (current[identity] == nil) {
      [exited addObject:_known[identity]];
    }
  }
  NSMutableDictionary *previous = _known;
  NSDictionary<NSString *, NSDictionary *> *jobsBefore = _jobs;
  NSDictionary<NSNumber *, NSString *> *labelsBefore = _jobLabels;
  BOOL jobsChanged = NO;
  if (started.count > 0 || exited.count > 0 || _jobs == nil ||
      -_jobsLoaded.timeIntervalSinceNow >= FLJobReload) {
    jobsChanged = [self loadJobs];
  }
  _known = current;
  if (_primed) {
    NSSortDescriptor *byStart = [NSSortDescriptor sortDescriptorWithKey:@"started"
                                                              ascending:YES];
    for (FLProcess *process in [started sortedArrayUsingDescriptors:@[ byStart ]]) {
      [self started:process];
    }
    _known = previous;
    for (FLProcess *process in exited) {
      [self exited:process labels:labelsBefore];
    }
    _known = current;
    if (jobsChanged && jobsBefore != nil) {
      [self compareJobs:jobsBefore exited:exited];
    }
  }
  _primed = YES;
  [self checkFront];
}

- (NSString *)versionOf:(NSDictionary *)app {
  NSString *version = app[@"version"];
  NSString *build = app[@"build"];
  if (build.length == 0 || [build isEqualToString:version]) {
    return version;
  }
  return [NSString stringWithFormat:@"%@ (%@)", version, build];
}

- (void)checkApps {
  NSMutableDictionary<NSString *, NSDictionary *> *found = [NSMutableDictionary new];
  for (NSDictionary *app in FLInstalledApps()) {
    NSString *path = app[@"path"] ?: @"";
    NSString *identifier = app[@"identifier"] ?: path;
    found[identifier] = @{
      @"name" : app[@"name"] ?: identifier,
      @"version" : app[@"version"] ?: @"",
      @"build" : app[@"build"] ?: @"",
      @"path" : path,
    };
  }
  if (found.count == 0) {
    return;
  }
  NSDictionary<NSString *, NSDictionary *> *before = _apps;
  if (before == nil) {
    NSDictionary *saved = FLReadState(FLAppsState)[@"apps"];
    before = [saved isKindOfClass:[NSDictionary class]] ? saved : nil;
  }
  _apps = found;
  if ([found isEqualToDictionary:before]) {
    return;
  }
  FLWriteState(FLAppsState, @{@"apps" : found});
  if (before == nil) {
    return;
  }
  for (NSString *identifier in [found.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *app = found[identifier];
    NSDictionary *old = before[identifier];
    NSString *version = [self versionOf:app];
    if (old == nil) {
      FLNote(@"app", FLLevelNotice, app[@"name"], @"installed (%@ %@) in %@", identifier, version,
             [app[@"path"] stringByDeletingLastPathComponent]);
    } else if (![[self versionOf:old] isEqualToString:version]) {
      FLNote(@"app", FLLevelNotice, app[@"name"], @"updated from %@ to %@ (%@)",
             [self versionOf:old], version, identifier);
    }
  }
  for (NSString *identifier in [before.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (found[identifier] == nil) {
      NSDictionary *old = before[identifier];
      FLNote(@"app", FLLevelNotice, old[@"name"] ?: identifier, @"removed (%@ %@)", identifier,
             [self versionOf:old]);
    }
  }
}

- (void)sampleUsage:(BOOL)record {
  NSDate *now = [NSDate date];
  NSTimeInterval elapsed = _sampled == nil ? 0 : [now timeIntervalSinceDate:_sampled];
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSString *identity in _known.allKeys) {
    FLProcess *known = _known[identity];
    FLProcess *fresh = FLProcessWithIdentifier(known.pid);
    if (fresh == nil || ![[fresh identity] isEqualToString:identity]) {
      continue;
    }
    NSNumber *before = _processor[identity];
    double share = before == nil || elapsed <= 0
      ? 0
      : MAX(0, fresh.processorSeconds - before.doubleValue) / elapsed * 100.0;
    uint64_t memory = fresh.footprintBytes ?: fresh.residentBytes;
    _processor[identity] = @(fresh.processorSeconds);
    _memory[identity] = @(memory);
    NSString *bundle = [known appBundlePath];
    [rows addObject:@{
      @"pid" : @(known.pid),
      @"parent" : @(known.parent),
      @"user" : FLUserName(known.user),
      @"name" : [known displayName],
      @"path" : known.path ?: @"",
      @"command" : [known commandLine],
      @"started" : known.started ?: now,
      @"processor" : @(share),
      @"processorSeconds" : @(fresh.processorSeconds),
      @"memory" : @(memory),
      @"threads" : @(fresh.threads),
      @"app" : @(bundle != nil),
      @"identifier" : bundle == nil ? @"" : (FLBundleInfo(bundle)[@"identifier"] ?: @""),
    }];
  }
  _sampled = now;
  _live = rows;
  if (!record || elapsed <= 0 || rows.count == 0) {
    return;
  }
  NSArray *busiest = [rows sortedArrayUsingDescriptors:@[
    [NSSortDescriptor sortDescriptorWithKey:@"processor" ascending:NO]
  ]];
  NSArray *largest = [rows sortedArrayUsingDescriptors:@[
    [NSSortDescriptor sortDescriptorWithKey:@"memory" ascending:NO]
  ]];
  NSMutableArray *busy = [NSMutableArray new];
  NSMutableArray *large = [NSMutableArray new];
  for (NSUInteger index = 0; index < MIN(FLTopCount, rows.count); index++) {
    NSDictionary *row = busiest[index];
    if ([row[@"processor"] doubleValue] >= 0.1) {
      [busy addObject:[NSString stringWithFormat:@"%@ %.1f%%", row[@"name"],
                                                 [row[@"processor"] doubleValue]]];
    }
    row = largest[index];
    [large addObject:[NSString stringWithFormat:@"%@ %@", row[@"name"],
                                                FLFormatBytes([row[@"memory"]
                                                  unsignedLongLongValue])]];
  }
  FLNote(@"resource", FLLevelInfo, @"processes",
         @"%lu running; busiest over %.0fs: %@; largest: %@", (unsigned long)rows.count,
         elapsed, busy.count > 0 ? [busy componentsJoinedByString:@", "] : @"none above 0.1%",
         [large componentsJoinedByString:@", "]);
}

- (NSArray<NSDictionary *> *)liveProcesses {
  return _live;
}

- (NSString *)frontApp {
  return _front ?: @"";
}

- (NSUInteger)processCount {
  return _known.count;
}

@end
