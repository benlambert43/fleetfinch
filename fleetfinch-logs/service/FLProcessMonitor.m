#import "FLMonitors.h"

#import <notify.h>
#import <sys/stat.h>

#import "FLCollect.h"
#import "FLLaunchd.h"
#import "FLProcessWatcher.h"
#import "FLStatus.h"
#import "FLStore.h"
#import "FLSystemInfo.h"

static NSString *const FLSpringBoardServices =
  @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices";
static const NSTimeInterval FLServiceReload = 600;
static const NSTimeInterval FLJobReload = 60;
static const NSUInteger FLTopCount = 5;
static const NSUInteger FLKernelTail = 160;
static const NSUInteger FLKernelAnchor = 64;
static NSString *const FLAppsState = @"apps";
static const NSTimeInterval FLForkGrace = 1.0;
static const NSTimeInterval FLExecQuiet = 0.25;
static const NSTimeInterval FLJobsFresh = 1.0;
static const NSTimeInterval FLEndedKept = 120;
static const NSTimeInterval FLSettleSoonest = 0.05;
static NSString *const FLLaunchProxy = @"xpcproxy";
static const char *const FLLockState = "com.apple.springboard.lockstate";
static const NSTimeInterval FLLaunchdSettle = 1.0;
static const NSTimeInterval FLLaunchdReview = 20;

static void FLNoteAt(NSDate *date, NSString *stream, FLLevel level, NSString *source,
                     NSString *format, ...) NS_FORMAT_FUNCTION(5, 6);

static void FLNoteAt(NSDate *date, NSString *stream, FLLevel level, NSString *source,
                     NSString *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  [[FLStore shared] log:stream
                  level:level
                 source:source
                message:message
                   date:date ?: [NSDate date]];
}

@interface FLPendingProcess : NSObject

@property(nonatomic, strong) FLProcess *process;
@property(nonatomic, strong) NSMutableArray<FLProcess *> *earlier;
@property(nonatomic, strong) NSMutableArray<NSDate *> *changes;
@property(nonatomic, strong) NSDate *deadline;
@property(nonatomic) BOOL clone;
@property(nonatomic) BOOL lost;

@end

@implementation FLPendingProcess
@end

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
  NSString *_counted;
  NSDate *_sampled;
  BOOL _primed;
  NSMutableDictionary<NSString *, FLPendingProcess *> *_pending;
  NSMutableDictionary<NSNumber *, NSDictionary *> *_ended;
  FLProcessWatcher *_watcher;
  dispatch_queue_t _queue;
  NSMutableSet<NSString *> *_asking;
  BOOL _settling;
  BOOL _jobsStale;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _known = [NSMutableDictionary new];
    _processor = [NSMutableDictionary new];
    _memory = [NSMutableDictionary new];
    _jobLabels = @{};
    _live = @[];
    _pending = [NSMutableDictionary new];
    _ended = [NSMutableDictionary new];
    _asking = [NSMutableSet new];
  }
  return self;
}

- (void)askLaunchdAbout:(NSString *)label {
  NSDictionary<NSString *, NSString *> *facts = FLLaunchdFacts(label);
  if (facts == nil) {
    return;
  }
  [self.ledger service:label
              launched:(NSUInteger)MAX(0, facts[@"runs"].integerValue)
                reason:facts[@"pid"] == nil ? nil : facts[@"immediate reason"]
               program:facts[@"program"]];
}

- (void)reviewLaunchd {
  for (NSString *label in _jobs.allKeys) {
    @autoreleasepool {
      [self askLaunchdAbout:label];
    }
  }
}

- (void)askSoonAbout:(NSString *)label {
  if (_queue == nil || label == nil || [_asking containsObject:label] ||
      [FLServiceFamily(label) containsString:@"*"]) {
    return;
  }
  [_asking addObject:label];
  __weak FLProcessMonitor *weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FLLaunchdSettle * NSEC_PER_SEC)),
                 _queue, ^{
                   [weak asked:label];
                 });
}

- (void)asked:(NSString *)label {
  [_asking removeObject:label];
  [self askLaunchdAbout:label];
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
  return FLBundledServiceLabel(process.path);
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
  for (FLPendingProcess *pending in _pending.allValues) {
    if (pending.process.pid == pid) {
      return pending.process;
    }
  }
  return nil;
}

- (NSString *)starterOf:(FLProcess *)process {
  if (process.parent == 1) {
    return @"launchd";
  }
  if (process.parent == 0) {
    return @"the kernel";
  }
  return [[self known:process.parent] displayName] ?: @"a process";
}

- (NSString *)nameOf:(FLProcess *)process {
  NSString *script = FLScriptOf(process);
  return script.length > 0 ? script.lastPathComponent : [process displayName];
}

- (NSString *)sourceOf:(FLProcess *)process {
  return process.name.length > 0 ? process.name : [process displayName];
}

- (void)started:(FLProcess *)process
          label:(NSString *)label
          chain:(NSArray<FLProcess *> *)chain
             at:(NSDate *)when {
  NSString *service = label == nil ? @"" : [NSString stringWithFormat:@" for %@", label];
  NSMutableArray<NSString *> *through = [NSMutableArray new];
  for (FLProcess *earlier in chain) {
    [through addObject:[self nameOf:earlier]];
  }
  NSString *way = through.count == 0
    ? @""
    : [NSString stringWithFormat:@" by way of %@", [through componentsJoinedByString:@" and "]];
  FLNoteAt(when, @"process", FLLevelNotice, [self sourceOf:process],
           @"started pid %d by %@ (pid %d)%@%@ as %@: %@", process.pid, [self starterOf:process],
           process.parent, service, way, FLUserName(process.user), [process commandLine]);
  [self askSoonAbout:label];
  if (process.parent == 1 && label == nil) {
    FLNoteAt(when, @"service", FLLevelNotice,
             [self bundledServiceLabel:process] ?: [self sourceOf:process],
             @"started as pid %d running %@", process.pid, [process commandLine]);
  }
  NSString *bundle = [process appBundlePath];
  if (bundle != nil) {
    NSDictionary *info = FLBundleInfo(bundle);
    FLNoteAt(when, @"app", FLLevelNotice, info[@"name"] ?: [self sourceOf:process],
             @"opened as pid %d (%@ %@) from %@", process.pid, info[@"identifier"] ?: @"",
             info[@"version"] ?: @"", bundle);
  }
}

- (void)exited:(FLProcess *)process
        labels:(NSDictionary<NSNumber *, NSString *> *)labels
            at:(NSDate *)when {
  NSString *identity = [process identity];
  NSTimeInterval lived = MAX(0, [when timeIntervalSinceDate:process.started]);
  NSNumber *processor = _processor[identity];
  NSNumber *memory = _memory[identity];
  NSString *usage = @"";
  if (processor != nil && memory != nil) {
    usage = [NSString stringWithFormat:@", having used %.2fs of processor and %@ of memory when "
                                       @"last seen",
                                       processor.doubleValue,
                                       FLFormatBytes(memory.unsignedLongLongValue)];
  } else if (processor != nil) {
    usage = [NSString stringWithFormat:@", having used %.2fs of processor",
                                       processor.doubleValue];
  }
  FLNoteAt(when, @"process", FLLevelNotice, [self sourceOf:process], @"exited pid %d after %@%@",
           process.pid, FLFormatDuration(lived), usage);
  if (process.parent == 1 && labels[@(process.pid)] == nil) {
    FLNoteAt(when, @"service", FLLevelNotice,
             [self bundledServiceLabel:process] ?: [self sourceOf:process],
             @"stopped (pid %d) after %@", process.pid, FLFormatDuration(lived));
  }
  NSString *bundle = [process appBundlePath];
  if (bundle != nil) {
    NSDictionary *info = FLBundleInfo(bundle);
    FLNoteAt(when, @"app", FLLevelNotice, info[@"name"] ?: [self sourceOf:process],
             @"closed (pid %d) after %@", process.pid, FLFormatDuration(lived));
  }
  [_processor removeObjectForKey:identity];
  [_memory removeObjectForKey:identity];
  for (NSNumber *pid in _ended.allKeys) {
    NSDate *at = _ended[pid][@"at"];
    if ([when timeIntervalSinceDate:at] > FLEndedKept) {
      [_ended removeObjectForKey:pid];
    }
  }
  _ended[@(process.pid)] = @{@"process" : process, @"at" : when};
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
  NSDictionary *record = _ended[@(pid)];
  NSDate *ended = record[@"at"] ?: [NSDate date];
  if (process == nil) {
    process = record[@"process"];
  }
  NSString *lived = process == nil
    ? @""
    : [NSString stringWithFormat:@" after %@",
                                 FLFormatDuration(MAX(0, [ended timeIntervalSinceDate:process
                                                                                    .started]))];
  NSString *ending = @"";
  FLLevel level = FLLevelNotice;
  if (removed) {
    ending = @" and launchd let go of it";
  } else if (status != nil) {
    ending = [@" with " stringByAppendingString:FLDescribeExit(status.integerValue)];
    if (status.integerValue != 0) {
      level = FLLevelWarning;
    }
    [self.ledger service:label endedWith:FLDescribeExit(status.integerValue)];
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

- (BOOL)isLocked {
  static int token = NOTIFY_TOKEN_INVALID;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (notify_register_check(FLLockState, &token) != NOTIFY_STATUS_OK) {
      token = NOTIFY_TOKEN_INVALID;
    }
  });
  uint64_t state = 0;
  return token != NOTIFY_TOKEN_INVALID && notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
         state != 0;
}

- (void)countFront:(NSString *)front {
  NSString *shown = [self isLocked] ? @"" : front;
  NSString *name = nil;
  NSString *path = nil;
  if (shown.length > 0 && ![shown isEqualToString:_counted ?: @""]) {
    for (FLProcess *process in _known.allValues) {
      NSString *bundle = [process appBundlePath];
      NSDictionary *info = bundle == nil ? nil : FLBundleInfo(bundle);
      if ([info[@"identifier"] isEqualToString:shown]) {
        name = info[@"name"];
        path = bundle;
        break;
      }
    }
  }
  _counted = shown;
  [self.ledger inFront:shown name:name path:path];
}

- (void)checkFront {
  NSString *front = [self lookUpFrontApp] ?: @"";
  [self countFront:front];
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
    if (_pending[identity] != nil) {
      continue;
    }
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
  for (FLProcess *process in started) {
    [self.ledger began:process
                 label:_jobLabels[@(process.pid)] ?: FLBundledServiceIdentifier(process.path)
               starter:[self starterOf:process]];
  }
  for (FLProcess *process in exited) {
    NSString *identity = [process identity];
    [self.ledger ended:process processor:_processor[identity] memory:_memory[identity]];
  }
  if (!_primed) {
    [self.ledger keepOnly:[NSSet setWithArray:current.allKeys]];
  }
  if (_primed) {
    NSSortDescriptor *byStart = [NSSortDescriptor sortDescriptorWithKey:@"started"
                                                              ascending:YES];
    for (FLProcess *process in [started sortedArrayUsingDescriptors:@[ byStart ]]) {
      [self started:process label:_jobLabels[@(process.pid)] chain:nil at:process.started];
    }
    _known = previous;
    for (FLProcess *process in exited) {
      [self exited:process labels:labelsBefore at:[NSDate date]];
    }
    _known = current;
    if (jobsChanged && jobsBefore != nil) {
      [self compareJobs:jobsBefore exited:exited];
    }
  }
  _primed = YES;
  [self checkFront];
}

- (void)refreshJobs {
  NSDictionary<NSString *, NSDictionary *> *before = _jobs;
  if ([self loadJobs] && before != nil && _primed) {
    [self compareJobs:before exited:@[]];
  }
  _jobsStale = NO;
}

- (NSString *)labelByProgram:(FLProcess *)process chain:(NSArray<FLProcess *> *)chain {
  NSMutableSet<NSString *> *paths = [NSMutableSet new];
  for (FLProcess *image in [chain ?: @[] arrayByAddingObject:process]) {
    if (image.path.length > 0) {
      [paths addObject:image.path];
    }
    NSString *script = FLScriptOf(image);
    if (script.length > 0) {
      [paths addObject:script];
    }
  }
  NSString *found = nil;
  for (NSString *label in _jobs) {
    NSString *program = _jobs[label][@"program"];
    if (program.length == 0 || ![paths containsObject:program]) {
      continue;
    }
    if (found != nil) {
      return nil;
    }
    found = label;
  }
  return found;
}

- (NSString *)labelFor:(FLProcess *)process
                 chain:(NSArray<FLProcess *> *)chain
                 since:(NSDate *)began {
  NSString *label = _jobLabels[@(process.pid)];
  if (label != nil || process.parent != 1) {
    return label;
  }
  for (FLProcess *image in chain) {
    if (image.arguments.count > 1 &&
        [image.path.lastPathComponent isEqualToString:FLLaunchProxy]) {
      _jobsStale = YES;
      return image.arguments[1];
    }
  }
  if (_jobsLoaded == nil || [_jobsLoaded compare:began] != NSOrderedDescending) {
    [self refreshJobs];
    label = _jobLabels[@(process.pid)];
  }
  return label ?: [self labelByProgram:process chain:chain];
}

- (void)missed:(FLProcess *)process at:(NSDate *)when {
  NSString *starter = [self starterOf:process];
  FLNoteAt(when, @"process", FLLevelInfo, starter,
           @"started pid %d, which ran a program and exited before it could be named",
           process.pid);
  [self.ledger missed:starter at:when];
}

- (void)settled:(FLPendingProcess *)pending at:(NSDate *)now {
  FLProcess *process = pending.process;
  NSString *starter = [self starterOf:process];
  NSDate *began = process.started ?: now;
  for (NSUInteger index = 0; index < pending.earlier.count; index++) {
    [self.ledger passed:pending.earlier[index]
                starter:starter
                   from:began
                     to:pending.changes[index]];
    began = pending.changes[index];
  }
  NSString *label = [self labelFor:process chain:pending.earlier since:began];
  _known[[process identity]] = process;
  [self.ledger began:process
               label:label ?: FLBundledServiceIdentifier(process.path)
             starter:starter
                from:began
                  at:now];
  [self started:process label:label chain:pending.earlier at:began];
}

- (void)changed:(FLProcess *)before into:(FLProcess *)process at:(NSDate *)when {
  NSString *identity = [before identity];
  _known[identity] = process;
  if ([before.path isEqualToString:process.path] &&
      [[before commandLine] isEqualToString:[process commandLine]]) {
    return;
  }
  double spent = [_processor[identity] doubleValue];
  [self.ledger ended:before processor:_processor[identity] memory:_memory[identity] at:when];
  [self.ledger began:process
               label:_jobLabels[@(process.pid)] ?: FLBundledServiceIdentifier(process.path)
             starter:[self starterOf:process]
                from:when
                  at:when];
  [self.ledger rebase:process processor:spent];
  FLNoteAt(when, @"process", FLLevelNotice, [self sourceOf:process],
           @"pid %d now runs %@, having started as %@", process.pid, [process commandLine],
           [self nameOf:before]);
}

- (void)await:(FLProcess *)process copy:(BOOL)copy until:(NSDate *)deadline {
  FLPendingProcess *pending = [FLPendingProcess new];
  pending.process = process;
  pending.clone = copy;
  pending.earlier = [NSMutableArray new];
  pending.changes = [NSMutableArray new];
  pending.deadline = deadline;
  _pending[[process identity]] = pending;
}

- (void)appeared:(FLProcessEvent *)event {
  FLProcess *process = event.process;
  NSString *identity = [process identity];
  if (_known[identity] != nil || _pending[identity] != nil) {
    return;
  }
  BOOL copy = event.clone;
  if (!event.named) {
    if (process.name.length == 0) {
      [self missed:process at:event.at];
      return;
    }
    copy = [process.name isEqualToString:[self known:process.parent].name];
  }
  [self await:process
         copy:copy
        until:[event.at dateByAddingTimeInterval:copy ? FLForkGrace : FLExecQuiet]];
}

- (void)became:(FLProcessEvent *)event {
  FLProcess *process = event.process;
  NSString *identity = [process identity];
  FLPendingProcess *pending = _pending[identity];
  FLProcess *known = _known[identity];
  if (!event.named) {
    pending.lost = YES;
    if (pending == nil && known != nil) {
      [self missed:known at:event.at];
    }
    return;
  }
  NSDate *deadline = [event.at dateByAddingTimeInterval:FLExecQuiet];
  if (pending != nil) {
    if (!pending.clone) {
      [pending.earlier addObject:pending.process];
      [pending.changes addObject:event.at];
    }
    pending.process = process;
    pending.clone = NO;
    pending.deadline = deadline;
  } else if (known != nil) {
    [self changed:known into:process at:event.at];
  } else {
    [self await:process copy:NO until:deadline];
  }
}

- (void)gone:(FLProcessEvent *)event {
  NSString *identity = [event.process identity];
  FLPendingProcess *pending = _pending[identity];
  if (pending != nil) {
    [_pending removeObjectForKey:identity];
    if (pending.lost) {
      [self missed:pending.process at:event.at];
    }
    if (pending.clone) {
      return;
    }
    [self settled:pending at:event.at];
  }
  FLProcess *known = _known[identity];
  if (known == nil) {
    return;
  }
  if (event.processor != nil) {
    _processor[identity] = event.processor;
  }
  [self.ledger ended:known processor:_processor[identity] memory:_memory[identity] at:event.at];
  if (_jobLabels[@(known.pid)] != nil) {
    _jobsStale = YES;
  }
  [self exited:known labels:_jobLabels at:event.at];
  [_known removeObjectForKey:identity];
}

- (void)settle {
  NSDate *now = [NSDate date];
  NSDate *next = nil;
  for (NSString *identity in _pending.allKeys) {
    FLPendingProcess *pending = _pending[identity];
    if ([pending.deadline compare:now] != NSOrderedDescending) {
      [_pending removeObjectForKey:identity];
      [self settled:pending at:now];
    } else if (next == nil || [pending.deadline compare:next] == NSOrderedAscending) {
      next = pending.deadline;
    }
  }
  if (_jobsStale) {
    NSDate *due = [_jobsLoaded ?: now dateByAddingTimeInterval:FLJobsFresh];
    if (next == nil || [due compare:next] == NSOrderedAscending) {
      next = due;
    }
  }
  if (next == nil || _settling || _queue == nil) {
    return;
  }
  _settling = YES;
  __weak FLProcessMonitor *weak = self;
  NSTimeInterval wait = MAX(FLSettleSoonest, next.timeIntervalSinceNow);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), _queue, ^{
    [weak settleLater];
  });
}

- (void)settleLater {
  _settling = NO;
  [self handle:@[]];
}

- (void)handle:(NSArray<FLProcessEvent *> *)events {
  @try {
    @autoreleasepool {
      for (FLProcessEvent *event in events) {
        if (event.change == FLProcessAppeared) {
          [self appeared:event];
        } else if (event.change == FLProcessBecame) {
          [self became:event];
        } else {
          [self gone:event];
        }
      }
      if (_jobsStale && -_jobsLoaded.timeIntervalSinceNow >= FLJobsFresh) {
        [self refreshJobs];
      }
      [self settle];
    }
  } @catch (NSException *exception) {
    FLNote(@"finchlogs", FLLevelError, @"processes", @"failed: %@ (%@)", exception.reason,
           exception.name);
  }
}

- (void)watchOnQueue:(dispatch_queue_t)queue {
  if (_watcher != nil) {
    return;
  }
  _queue = queue;
  __weak FLProcessMonitor *weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FLLaunchdReview * NSEC_PER_SEC)),
                 queue, ^{
                   [weak reviewLaunchd];
                 });
  FLProcessWatcher *watcher =
    [[FLProcessWatcher alloc] initWithQueue:queue
                                    handler:^(NSArray<FLProcessEvent *> *events) {
                                      [weak handle:events];
                                    }];
  if ([watcher start]) {
    _watcher = watcher;
  } else {
    FLNote(@"finchlogs", FLLevelWarning, @"processes",
           @"Process events could not be watched, so runs shorter than the time between two "
           @"looks at the process table will be missed");
  }
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
    [self.ledger seen:fresh];
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
