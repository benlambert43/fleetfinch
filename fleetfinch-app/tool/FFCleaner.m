#import "FFCleaner.h"

#import <fcntl.h>
#import <notify.h>
#import <objc/message.h>
#import <signal.h>
#import <spawn.h>
#import <sys/file.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "FFArrangement.h"
#import "FFCleanup.h"
#import "FFCopy.h"
#import "FFHealth.h"
#import "FFStayJoined.h"

extern char **environ;
extern int reboot(int how);
extern void xpc_transaction_begin(void);

typedef uint32_t IOPMAssertionID;
extern int IOPMAssertionCreateWithName(CFStringRef type, uint32_t level, CFStringRef name,
                                       IOPMAssertionID *identifier);
extern int IOPMAssertionRelease(IOPMAssertionID identifier);

static NSString *const FFLaunchControl = @"/bin/launchctl";
static NSString *const FFIconTool = @"/usr/bin/uicache";
static NSString *const FFMountTool = @"/sbin/mount";
static NSString *const FFLockPath = @"/private/var/FleetFinch/lock";
static NSString *const FFLogPath = @"/private/var/FleetFinch/cleanup.log";
static NSString *const FFSystemServices = @"/System/Library/LaunchDaemons";
static NSString *const FFAddedServices = @"/Library/LaunchDaemons";
static NSString *const FFAppsFolder = @"/Applications";
static NSString *const FFGuardedPrefix = @"com.apple.jetsamproperties.";
static NSString *const FFAppsNotice = @"com.apple.mobile.application_installed";
static const int FFRestartNow = 0;
static const uint32_t FFMemoryLimitMegabytes = 48;
static const uint32_t FFAssertionOn = 255;
static const NSTimeInterval FFProgressEvery = 1;
static const unsigned FFTrialFirst = 120;
static const unsigned FFTrialEvery = 20;
static const unsigned FFTrialTries = 7;
static const unsigned FFSettle = 60;
static const unsigned FFQueueEvery = 5;
static const unsigned FFCalmLook = 2;
static const unsigned FFCalmTries = 12;
static const double FFCalmEnough = 0.6;
static const unsigned FFWatchLook = 3;
static const unsigned FFWatchRounds = 3;
static const double FFStormShare = 0.9;
static const unsigned FFHelperWait = 30;

static BOOL FFQuiet = NO;

static void FFSay(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void FFSay(NSString *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  NSString *line = [NSString stringWithFormat:@"%@ %@\n", FFFormatDay([NSDate date]), message];
  int handle = open(FFLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (handle >= 0) {
    const char *text = line.UTF8String;
    write(handle, text, strlen(text));
    close(handle);
  }
  if (!FFQuiet) {
    printf("%s\n", message.UTF8String);
    fflush(stdout);
  }
}

static BOOL FFSystemVolumeWritable(void) {
  struct statfs volume;
  return statfs("/", &volume) == 0 && (volume.f_flags & MNT_RDONLY) == 0;
}

static NSString *const FFReadOnlyProblem =
  @"The system volume is read-only on this start and could not be made writable, so nothing on "
  @"it can be removed or put back. Restart the device and try again.";

static NSString *FFThings(NSUInteger count) {
  return [NSString stringWithFormat:@"%lu %@", (unsigned long)count,
                                    count == 1 ? @"thing" : @"things"];
}

static int FFFail(NSString *message) {
  fprintf(stderr, "fleetfinch: %s\n", message.UTF8String);
  return 1;
}

static NSArray<NSString *> *FFKeptTrees(void) {
  return @[
    @"/Applications/MobileSafari.app", @"/Applications/Preferences.app",
    @"/Applications/FleetFinch.app", @"/System/Library/CoreServices/SpringBoard.app",
    @"/System/Library/Caches", @"/System/Library/SystemConfiguration", FFAddedServices,
    @"/Library/MobileSubstrate", @"/private/etc", @"/private/var", @"/dev", @"/bin", @"/sbin",
    @"/usr/lib/system", @"/usr/share/firmware", @"/usr/share/icu", @"/usr/share/zoneinfo",
    @"/usr/share/zoneinfo.default", @"/usr/libexec/cydia", @"/taig"
  ];
}

static NSArray<NSString *> *FFKeptFiles(void) {
  NSMutableArray<NSString *> *files = [@[
    @"/usr/lib/dyld", @"/usr/sbin/racoon", @"/usr/libexec/dhcpd",
    @"/usr/libexec/wifiFirmwareLoader", @"/usr/libexec/wifiFirmwareLoader_orig",
    @"/usr/sbin/sshd", @"/usr/libexec/sshd-keygen-wrapper", @"/usr/bin/fleetfinch",
    @"/usr/bin/finchlog", @"/usr/sbin/wifid", @"/usr/libexec/configd", @"/usr/sbin/mDNSResponder",
    @"/usr/sbin/mDNSResponderHelper", @"/usr/libexec/securityd", @"/usr/libexec/keybagd",
    @"/usr/libexec/backboardd", @"/usr/libexec/lockdownd", @"/usr/sbin/notifyd",
    @"/usr/sbin/cfprefsd", @"/usr/sbin/distnoted", @"/usr/sbin/syslogd",
    @"/usr/libexec/UserEventAgent", @"/usr/libexec/lsd", @"/usr/libexec/installd",
    @"/usr/libexec/fseventsd", @"/usr/libexec/amfid", @"/usr/libexec/MobileGestaltHelper",
    @"/usr/libexec/assertiond", @"/usr/libexec/pkd", @"/System/Library/CoreServices/powerd.bundle",
    @"/System/Library/CoreServices/SystemVersion.plist",
    @"/System/Library/Frameworks/SystemConfiguration.framework",
    @"/System/Library/PrivateFrameworks/MobileContainerManager.framework"
  ] mutableCopy];
  for (NSString *label in @[
         @"com.apple.wifiFirmwareLoader", @"com.apple.racoon", @"com.apple.configd",
         @"com.apple.wifid", @"com.apple.mDNSResponder", @"com.apple.mDNSResponderHelper",
         @"com.apple.securityd", @"com.apple.mobile.keybagd", @"com.apple.backboardd",
         @"com.apple.mobile.lockdown", @"com.apple.notifyd", @"com.apple.cfprefsd.xpc.daemon",
         @"com.apple.distnoted.xpc.daemon", @"com.apple.syslogd",
         @"com.apple.UserEventAgent-System", @"com.apple.lsd", @"com.apple.mobile.installd",
         @"com.apple.fseventsd", @"com.apple.MobileFileIntegrity", @"com.apple.mobilegestalt.xpc",
         @"com.apple.assertiond", @"com.apple.powerd", @"com.apple.SCHelper-embedded",
         @"com.apple.containermanagerd", @"com.apple.pluginkit.pkd"
       ]) {
    [files addObject:[NSString stringWithFormat:@"%@/%@.plist", FFSystemServices, label]];
  }
  return files;
}

static NSString *FFRefusal(NSString *path, NSSet<NSString *> *listed) {
  struct stat info;
  if (![listed containsObject:path]) {
    return [NSString stringWithFormat:@"%@ is not on the cleanup list", path];
  }
  if (![FFCleanPath(path) isEqualToString:path] ||
      [path componentsSeparatedByString:@"/"].count < 3 || !FFOnSystemVolume(path)) {
    return [NSString stringWithFormat:@"%@ is not the plain path of a thing inside one of the "
                                      @"system volume's folders",
                                      path];
  }
  for (NSString *tree in FFKeptTrees()) {
    if (FFIsInside(path, tree) || FFIsInside(tree, path)) {
      return [NSString stringWithFormat:@"%@ stays: the device needs %@ to start, to be "
                                        @"reached or to keep Safari and Settings",
                                        path, tree];
    }
  }
  for (NSString *file in FFKeptFiles()) {
    if (FFIsInside(file, path)) {
      return [NSString stringWithFormat:@"%@ stays: the device needs %@ to start or to be "
                                        @"reached",
                                        path, file];
    }
  }
  if ([path.lastPathComponent hasPrefix:FFGuardedPrefix]) {
    return [NSString stringWithFormat:@"%@ stays: it sets the memory limits of what runs", path];
  }
  if (lstat(path.fileSystemRepresentation, &info) != 0) {
    return [NSString stringWithFormat:@"there is nothing at %@", path];
  }
  return nil;
}

static int FFRun(NSArray<NSString *> *arguments) {
  char **argv = calloc(arguments.count + 1, sizeof(char *));
  for (NSUInteger index = 0; index < arguments.count; index++) {
    argv[index] = (char *)arguments[index].UTF8String;
  }
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  pid_t pid = 0;
  int status = -1;
  if (posix_spawn(&pid, arguments[0].fileSystemRepresentation, &actions, NULL, argv, environ) ==
      0) {
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
  }
  posix_spawn_file_actions_destroy(&actions);
  free(argv);
  return status;
}

static BOOL FFIsService(NSString *path) {
  NSString *folder = path.stringByDeletingLastPathComponent;
  return [path.pathExtension isEqualToString:@"plist"] &&
         ([folder isEqualToString:FFSystemServices] || [folder isEqualToString:FFAddedServices]);
}

static void FFControlService(NSString *verb, NSString *file) {
  if (access(FFLaunchControl.fileSystemRepresentation, X_OK) == 0) {
    FFRun(@[ FFLaunchControl, verb, file ]);
  }
}

static BOOL FFLoadsHere(NSString *path) {
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
  NSDictionary *only = plist[@"LimitLoadToHardware"];
  NSDictionary *never = plist[@"LimitLoadFromHardware"];
  for (NSString *key in [only isKindOfClass:[NSDictionary class]] ? only : @{}) {
    NSArray *values = only[key];
    if ([values isKindOfClass:[NSArray class]] && ![values containsObject:FFHardwareValue(key)]) {
      return NO;
    }
  }
  for (NSString *key in [never isKindOfClass:[NSDictionary class]] ? never : @{}) {
    NSArray *values = never[key];
    if ([values isKindOfClass:[NSArray class]] && [values containsObject:FFHardwareValue(key)]) {
      return NO;
    }
  }
  return YES;
}

static NSString *FFUnloadAndWatch(NSString *path) {
  if (access(FFLaunchControl.fileSystemRepresentation, X_OK) != 0) {
    return nil;
  }
  unsigned tries = 0;
  while (FFBusyShare(FFCalmLook) > FFCalmEnough) {
    if (++tries >= FFCalmTries) {
      return [NSString stringWithFormat:@"%@ was left where it is: the device stayed too busy "
                                        @"to tell what unloading it would do",
                                        path];
    }
  }
  FFControlService(@"unload", path);
  for (unsigned round = 0; round < FFWatchRounds; round++) {
    if (FFBusyShare(FFWatchLook) < FFStormShare) {
      return nil;
    }
  }
  FFControlService(@"load", path);
  return [NSString stringWithFormat:@"%@ was left where it is: without it the device's "
                                    @"processors stayed full for %u seconds, because other "
                                    @"parts of iOS keep asking for it, so it was loaded again",
                                    path, FFWatchLook * FFWatchRounds];
}

static BOOL FFTouchesApps(NSString *path) {
  for (NSString *part in path.pathComponents) {
    if ([@[ @"app", @"appex" ] containsObject:part.pathExtension]) {
      return YES;
    }
  }
  return NO;
}

static void FFRebuildApps(void) {
  Class workspace = NSClassFromString(@"LSApplicationWorkspace");
  SEL shared = NSSelectorFromString(@"defaultWorkspace");
  SEL rebuild =
    NSSelectorFromString(@"_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");
  BOOL rebuilt = NO;
  if ([workspace respondsToSelector:shared]) {
    id instance = ((id (*)(id, SEL))objc_msgSend)(workspace, shared);
    if ([instance respondsToSelector:rebuild]) {
      rebuilt =
        ((BOOL (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(instance, rebuild, YES, YES, NO);
    }
  }
  if (!rebuilt && access(FFIconTool.fileSystemRepresentation, X_OK) == 0) {
    rebuilt = FFRun(@[ FFIconTool ]) == 0;
  }
  notify_post(FFAppsNotice.UTF8String);
  FFSay(@"%@", rebuilt ? @"The Home screen's list of apps was made again."
                       : @"The Home screen's list of apps could not be made again; it will be "
                         @"when the device restarts.");
}

static NSMutableDictionary *FFJournal(void) {
  NSMutableDictionary *journal = [NSMutableDictionary new];
  NSDictionary *saved = FFReadJournal();
  NSMutableArray *batches = [NSMutableArray new];
  NSArray *kept = [saved[@"batches"] isKindOfClass:[NSArray class]] ? saved[@"batches"] : @[];
  for (NSDictionary *each in kept) {
    [batches addObject:[each mutableCopy]];
  }
  journal[@"next"] = saved[@"next"] ?: @1;
  journal[@"batches"] = batches;
  return journal;
}

static BOOL FFWriteJournal(NSDictionary *journal) {
  return [journal writeToFile:FFJournalPath atomically:YES] &&
         chmod(FFJournalPath.fileSystemRepresentation, 0644) == 0;
}

static NSString *FFBatchList(NSNumber *identifier) {
  return [FFBatchFolder
    stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.txt", identifier]];
}

static NSArray<NSString *> *FFBatchPaths(NSNumber *identifier) {
  NSString *text = [NSString stringWithContentsOfFile:FFBatchList(identifier)
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"/"]) {
      [paths addObject:line];
    }
  }
  return paths;
}

static BOOL FFAppendToBatch(NSNumber *identifier, NSString *path) {
  int handle = open(FFBatchList(identifier).fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (handle < 0) {
    return NO;
  }
  const char *line = [path stringByAppendingString:@"\n"].UTF8String;
  size_t length = strlen(line);
  BOOL written = write(handle, line, length) == (ssize_t)length && fsync(handle) == 0;
  close(handle);
  return written;
}

static BOOL FFPrepare(void) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSDictionary *open = @{NSFilePosixPermissions : @0755};
  for (NSString *folder in @[ FFStateFolder, FFRemovedFolder, FFBatchFolder ]) {
    if (![manager createDirectoryAtPath:folder
            withIntermediateDirectories:YES
                             attributes:open
                                  error:NULL]) {
      return NO;
    }
  }
  return YES;
}

static int FFLock(void) {
  int handle = open(FFLockPath.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
  if (handle >= 0 && flock(handle, LOCK_EX | LOCK_NB) != 0) {
    close(handle);
    return -1;
  }
  return handle;
}

static void FFProgress(NSDictionary *progress) {
  [progress writeToFile:FFProgressPath atomically:YES];
  chmod(FFProgressPath.fileSystemRepresentation, 0644);
  notify_post(FFCleanupChanged.UTF8String);
}

static void FFTick(NSString *verb, NSUInteger done, NSUInteger total, NSString *path,
                   NSDate *started, NSDate **last) {
  NSDate *now = [NSDate date];
  if (*last != nil && [now timeIntervalSinceDate:*last] < FFProgressEvery && done < total) {
    return;
  }
  *last = now;
  FFProgress(@{
    @"running" : @YES,
    @"verb" : verb,
    @"done" : @(done),
    @"total" : @(total),
    @"current" : path.lastPathComponent ?: @"",
    @"started" : started,
  });
}

static void FFFinish(NSString *verb, NSString *result, NSArray<NSString *> *problems) {
  FFProgress(@{
    @"running" : @NO,
    @"verb" : verb,
    @"finished" : [NSDate date],
    @"result" : result,
    @"problems" : problems,
  });
}

static NSArray<NSString *> *FFSelect(NSArray<NSString *> *words, NSString **unknown) {
  NSArray<FFCleanupGroup *> *groups = FFCleanupGroups();
  NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet new];
  NSMutableSet<NSString *> *listed = [NSMutableSet new];
  for (FFCleanupGroup *group in groups) {
    [listed addObjectsFromArray:group.paths];
  }
  for (NSString *word in words.count > 0 ? words : [groups valueForKey:@"identifier"]) {
    NSArray<NSString *> *found = nil;
    for (FFCleanupGroup *group in groups) {
      if ([group.identifier isEqualToString:word]) {
        found = group.paths;
      }
    }
    if (found == nil && [listed containsObject:word]) {
      found = @[ word ];
    }
    if (found == nil) {
      *unknown = word;
      return nil;
    }
    [paths addObjectsFromArray:found];
  }
  return paths.array;
}

static int FFFailUnknown(NSString *word) {
  return FFFail([NSString stringWithFormat:@"%@ is neither a group nor a path on the cleanup "
                                           @"list",
                                           word]);
}

static NSString *FFRemoveOne(NSString *path, NSNumber *batch, uint64_t *freed) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *kept = FFKeptPath(path);
  BOOL service = FFIsService(path) && FFLoadsHere(path);
  struct stat info;
  BOOL copied = lstat(kept.fileSystemRepresentation, &info) == 0;
  if (copied && !FFSameTree(path, kept)) {
    return [NSString stringWithFormat:@"%@ was left where it is: a copy that differs from it "
                                      @"is already kept at %@",
                                      path, kept];
  }
  NSString *unsettled = service ? FFUnloadAndWatch(path) : nil;
  if (unsettled != nil) {
    return unsettled;
  }
  uint64_t space = FFSpaceTaken(path, NULL, NULL);
  NSArray<NSNumber *> *running = FFProcessesUnder(path);
  NSString *problem = copied ? nil : FFCopyTree(path, kept);
  if (problem == nil && !FFAppendToBatch(batch, path)) {
    problem = @"the record of what was removed could not be written";
  }
  if (problem != nil) {
    if (service) {
      FFControlService(@"load", path);
    }
    return [NSString stringWithFormat:@"%@ was left where it is: %@", path, problem];
  }
  if (![manager removeItemAtPath:path error:NULL]) {
    return [NSString stringWithFormat:@"%@ was copied to %@ but could not be deleted", path,
                                      kept];
  }
  for (NSNumber *pid in running) {
    kill(pid.intValue, SIGKILL);
  }
  *freed += space;
  return nil;
}

static NSString *FFRestoreOne(NSString *path) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *kept = FFKeptPath(path);
  struct stat info;
  if (lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation, &info) != 0) {
    return [NSString stringWithFormat:@"%@ was not put back: the folder it was in is not there",
                                      path];
  }
  NSString *problem = FFCopyTree(kept, path);
  if (problem != nil) {
    return [NSString stringWithFormat:@"%@ was not put back: %@", path, problem];
  }
  [manager removeItemAtPath:kept error:NULL];
  FFPruneEmptyFolders(kept.stringByDeletingLastPathComponent, FFRemovedFolder);
  if (FFIsService(path) && FFLoadsHere(path)) {
    FFControlService(@"load", path);
  }
  return nil;
}

static NSArray<NSString *> *FFOrphanServices(void) {
  NSMutableArray<NSString *> *orphans = [NSMutableArray new];
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *folder in @[ FFSystemServices, FFAddedServices ]) {
    for (NSString *name in [manager contentsOfDirectoryAtPath:folder error:NULL]) {
      NSString *file = [folder stringByAppendingPathComponent:name];
      NSDictionary *plist =
        FFIsService(file) ? [NSDictionary dictionaryWithContentsOfFile:file] : nil;
      NSArray *arguments = plist[@"ProgramArguments"];
      NSString *program = plist[@"Program"];
      if (![program isKindOfClass:[NSString class]] && [arguments isKindOfClass:[NSArray class]] &&
          arguments.count > 0) {
        program = arguments[0];
      }
      struct stat info;
      if ([program isKindOfClass:[NSString class]] && [program hasPrefix:@"/"] &&
          access(program.fileSystemRepresentation, F_OK) != 0 &&
          lstat(FFKeptPath(program).fileSystemRepresentation, &info) == 0) {
        [orphans addObject:[NSString stringWithFormat:@"%@ (%@)", file, program]];
      }
    }
  }
  return orphans;
}

static void FFFinish(NSString *verb, NSString *result, NSArray<NSString *> *problems);

static BOOL FFMakeSystemVolumeWritable(void) {
  if (FFSystemVolumeWritable()) {
    return YES;
  }
  FFRun(@[ FFMountTool, @"-u", @"-w", @"/" ]);
  BOOL writable = FFSystemVolumeWritable();
  FFSay(@"The system volume was read-only on this start; %@.",
        writable ? @"it was remounted writable" : @"remounting it writable did not work");
  return writable;
}

static int FFRefuseReadOnly(NSString *verb) {
  FFSay(@"%@", FFReadOnlyProblem);
  FFFinish(verb, FFReadOnlyProblem, @[ FFReadOnlyProblem ]);
  return 1;
}

static BOOL FFHasIcon(NSString *path) {
  return [path.pathExtension isEqualToString:@"app"] &&
         [path.stringByDeletingLastPathComponent isEqualToString:FFAppsFolder];
}

static BOOL FFAppsAreWhole(void) {
  NSString *unknown = nil;
  for (NSString *path in FFSelect(@[], &unknown)) {
    if (FFHasIcon(path) && FFStateOfPath(path) == FFItemRemoved) {
      return NO;
    }
  }
  return YES;
}

static NSArray<NSString *> *FFAppIdentifiers(NSArray<NSString *> *paths) {
  NSMutableArray<NSString *> *identifiers = [NSMutableArray new];
  for (NSString *path in paths) {
    NSString *file = [path stringByAppendingPathComponent:@"Info.plist"];
    NSString *identifier = [NSDictionary dictionaryWithContentsOfFile:file][@"CFBundleIdentifier"];
    if ([identifier isKindOfClass:[NSString class]]) {
      [identifiers addObject:identifier];
    }
  }
  return identifiers;
}

static int FFRemove(NSArray<NSString *> *words) {
  if (!FFMakeSystemVolumeWritable()) {
    return FFRefuseReadOnly(FFVerbRemove);
  }
  NSString *unknown = nil;
  NSArray<NSString *> *chosen = FFSelect(words, &unknown);
  if (chosen == nil) {
    return FFFailUnknown(unknown);
  }
  NSSet<NSString *> *listed = [NSSet setWithArray:FFSelect(@[], &unknown) ?: @[]];
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  NSMutableArray<NSString *> *problems = [NSMutableArray new];
  for (NSString *path in chosen) {
    if (FFStateOfPath(path) != FFItemPresent) {
      continue;
    }
    NSString *refusal = FFRefusal(path, listed);
    if (refusal != nil) {
      [problems addObject:refusal];
    } else {
      [paths addObject:path];
    }
  }
  NSMutableDictionary *journal = FFJournal();
  NSNumber *identifier = journal[@"next"];
  NSDictionary *reach = FFReach();
  NSDate *started = [NSDate date];
  NSDate *last = nil;
  uint64_t freed = 0;
  NSUInteger removed = 0;
  BOOL apps = NO;
  BOOL leaving = NO;
  for (NSString *path in paths) {
    leaving = leaving || FFHasIcon(path);
  }
  FFSay(@"Removing %@ as batch %@. Before: %@.", FFThings(paths.count), identifier,
        FFReachSentence(reach));
  if (leaving && FFAppsAreWhole()) {
    FFSay(@"%@", FFSaveArrangement()
                   ? @"The Home screen's arrangement was saved, to be put back with the apps."
                   : @"The Home screen's arrangement could not be read, so it will not be put "
                     @"back with the apps.");
  }
  NSMutableDictionary *batch = [@{
    @"id" : identifier,
    @"at" : started,
    @"groups" : words,
    @"items" : @0,
    @"bytes" : @0,
    @"reach" : reach,
    @"open" : @YES,
  } mutableCopy];
  journal[@"next"] = @(identifier.integerValue + 1);
  if (paths.count > 0) {
    [journal[@"batches"] addObject:batch];
  }
  if (paths.count > 0 && !FFWriteJournal(journal)) {
    return FFFail(@"the record of batches could not be written, so nothing was removed");
  }
  for (NSUInteger index = 0; index < paths.count; index++) {
    @autoreleasepool {
      NSString *path = paths[index];
      FFTick(FFVerbRemove, index, paths.count, path, started, &last);
      NSString *problem = FFRemoveOne(path, identifier, &freed);
      if (problem != nil) {
        [problems addObject:problem];
        FFSay(@"%@", problem);
      } else {
        removed += 1;
        apps = apps || FFTouchesApps(path);
        FFSay(@"Removed %@", path);
      }
    }
  }
  batch[@"items"] = @(removed);
  batch[@"bytes"] = @(freed);
  [batch removeObjectForKey:@"open"];
  if (removed == 0) {
    [journal[@"batches"] removeObject:batch];
  }
  FFWriteJournal(journal);
  if (apps) {
    FFRebuildApps();
  }
  NSDictionary *after = FFReach();
  NSString *missing = FFReachMissing(reach, after);
  NSString *result =
    [NSString stringWithFormat:@"Removed %@ and freed %@ on the system volume.",
                               FFThings(removed), FFFormatBytes(freed)];
  if (missing != nil) {
    [problems addObject:[NSString stringWithFormat:@"Afterwards %@.", missing]];
  }
  FFSay(@"%@ After: %@.", result, FFReachSentence(after));
  for (NSString *orphan in FFOrphanServices()) {
    FFSay(@"A launch service is left whose program is gone: %@", orphan);
  }
  FFFinish(FFVerbRemove, result, problems);
  return problems.count > 0 ? 1 : 0;
}

static void FFMarkRestored(NSMutableDictionary *journal, NSString *why) {
  for (NSMutableDictionary *batch in journal[@"batches"]) {
    if (batch[@"restored"] != nil) {
      continue;
    }
    BOOL left = NO;
    for (NSString *path in FFBatchPaths(batch[@"id"])) {
      left = left || FFStateOfPath(path) == FFItemRemoved;
    }
    if (!left) {
      batch[@"restored"] = [NSDate date];
      batch[@"why"] = why;
    }
  }
  FFWriteJournal(journal);
}

static NSUInteger FFRestorePaths(NSArray<NSString *> *wanted, NSString *why,
                                 NSMutableArray<NSString *> *problems) {
  FFMakeSystemVolumeWritable();
  NSMutableOrderedSet<NSString *> *listed = [NSMutableOrderedSet new];
  for (NSString *path in wanted) {
    if (FFStateOfPath(path) == FFItemRemoved) {
      [listed addObject:path];
    }
  }
  NSMutableArray<NSString *> *paths = [listed.array mutableCopy];
  NSDate *started = [NSDate date];
  NSDate *last = nil;
  NSUInteger restored = 0;
  BOOL apps = NO;
  NSMutableArray<NSString *> *returned = [NSMutableArray new];
  FFSay(@"Putting %@ back, %@.", FFThings(paths.count), why);
  NSMutableArray<NSString *> *waiting = paths;
  NSUInteger before = NSNotFound;
  while (waiting.count > 0 && waiting.count != before) {
    before = waiting.count;
    NSMutableArray<NSString *> *again = [NSMutableArray new];
    [problems removeAllObjects];
    for (NSString *path in waiting) {
      @autoreleasepool {
        FFTick(FFVerbRestore, restored, paths.count, path, started, &last);
        NSString *problem = FFRestoreOne(path);
        if (problem != nil) {
          [again addObject:path];
          [problems addObject:problem];
        } else {
          restored += 1;
          apps = apps || FFTouchesApps(path);
          if (FFHasIcon(path)) {
            [returned addObject:path];
          }
          FFSay(@"Put back %@", path);
        }
      }
    }
    waiting = again;
  }
  for (NSString *problem in problems) {
    FFSay(@"%@", problem);
  }
  if (apps) {
    FFRebuildApps();
  }
  if (returned.count > 0 && FFAppsAreWhole()) {
    if (!FFHasSavedArrangement()) {
      FFSay(@"No arrangement of the Home screen had been saved, so the apps are where iOS put "
            @"them.");
    } else if (FFRestoreArrangement(FFAppIdentifiers(returned))) {
      FFSay(@"The Home screen's arrangement was put back.");
    } else {
      FFSay(@"The Home screen's arrangement could not be put back; the apps are where iOS put "
            @"them.");
    }
  }
  FFMarkRestored(FFJournal(), why);
  return restored;
}

static NSArray<NSString *> *FFEverythingRemoved(void) {
  NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet new];
  NSArray *batches = FFReadJournal()[@"batches"];
  for (NSDictionary *batch in [batches reverseObjectEnumerator]) {
    [paths addObjectsFromArray:[FFBatchPaths(batch[@"id"]) reverseObjectEnumerator].allObjects];
  }
  NSString *unknown = nil;
  [paths addObjectsFromArray:[FFSelect(@[], &unknown) reverseObjectEnumerator].allObjects];
  return paths.array;
}

static int FFRestore(NSArray<NSString *> *words) {
  if (!FFMakeSystemVolumeWritable()) {
    return FFRefuseReadOnly(FFVerbRestore);
  }
  NSString *unknown = nil;
  NSArray<NSString *> *chosen = words.count > 0 ? FFSelect(words, &unknown) : nil;
  if (words.count > 0 && chosen == nil) {
    return FFFailUnknown(unknown);
  }
  NSSet<NSString *> *asked = chosen == nil ? nil : [NSSet setWithArray:chosen];
  NSMutableArray<NSString *> *wanted = [NSMutableArray new];
  for (NSString *path in FFEverythingRemoved()) {
    if (asked == nil || [asked containsObject:path]) {
      [wanted addObject:path];
    }
  }
  NSMutableArray<NSString *> *problems = [NSMutableArray new];
  NSUInteger restored = FFRestorePaths(wanted, @"as asked", problems);
  NSString *result = [NSString stringWithFormat:@"Put %@ back.", FFThings(restored)];
  FFSay(@"%@ Now: %@.", result, FFReachSentence(FFReach()));
  FFFinish(FFVerbRestore, result, problems);
  return problems.count > 0 ? 1 : 0;
}

static void FFPrintStatus(BOOL each, NSArray<NSString *> *words) {
  FFCleanupCount *total = [FFCleanupCount new];
  for (FFCleanupGroup *group in FFCleanupGroups()) {
    if (words.count > 0 && ![words containsObject:group.identifier]) {
      continue;
    }
    FFCleanupCount *count = FFCountGroup(group, YES);
    [total add:count];
    printf("%s\t%s\tinstalled %lu (%s)\tremoved %lu (%s)\tnot on this device %lu\n",
           group.identifier.UTF8String, group.title.UTF8String, (unsigned long)count.present,
           FFFormatBytes(count.presentBytes).UTF8String, (unsigned long)count.removed,
           FFFormatBytes(count.removedBytes).UTF8String, (unsigned long)count.absent);
    for (NSString *path in each ? group.paths : @[]) {
      FFItemState state = FFStateOfPath(path);
      NSString *where = state == FFItemRemoved ? FFKeptPath(path) : path;
      printf("  %s\t%s\t%s\n",
             state == FFItemPresent ? "installed" : (state == FFItemRemoved ? "removed" : "absent"),
             state == FFItemAbsent ? "" : FFFormatBytes(FFSpaceTaken(where, NULL, NULL)).UTF8String,
             path.UTF8String);
    }
  }
  printf("In all: installed %lu (%s), removed %lu (%s), not on this device %lu\n",
         (unsigned long)total.present, FFFormatBytes(total.presentBytes).UTF8String,
         (unsigned long)total.removed, FFFormatBytes(total.removedBytes).UTF8String,
         (unsigned long)total.absent);
  printf("Free on the system volume: %s. Free where the copies are kept: %s.\n",
         FFFormatBytes(FFRoomAt(@"/")).UTF8String, FFFormatBytes(FFRoomAt(FFStateFolder)).UTF8String);
  for (NSDictionary *batch in FFReadJournal()[@"batches"]) {
    NSString *state = batch[@"restored"] != nil
      ? [NSString stringWithFormat:@"put back %@ %@", FFFormatDay(batch[@"restored"]),
                                   batch[@"why"] ?: @""]
      : (batch[@"survived"] != nil ? @"through a restart" : @"not yet through a restart");
    printf("Batch %s: %s, %s, %s, %s\n", [batch[@"id"] description].UTF8String,
           FFFormatDay(batch[@"at"]).UTF8String,
           FFThings([batch[@"items"] unsignedIntegerValue]).UTF8String,
           FFFormatBytes([batch[@"bytes"] unsignedLongLongValue]).UTF8String, state.UTF8String);
  }
}

static int FFCheck(void) {
  NSDictionary *reach = FFReach();
  printf("%s.\n", FFReachSentence(reach).UTF8String);
  NSArray<NSString *> *orphans = FFOrphanServices();
  for (NSString *orphan in orphans) {
    printf("A launch service is left whose program is gone: %s\n", orphan.UTF8String);
  }
  printf("Free on the system volume: %s. It is %s on this start.\n",
         FFFormatBytes(FFRoomAt(@"/")).UTF8String,
         FFSystemVolumeWritable() ? "writable" : "read-only");
  printf("While the device sleeps, Wi-Fi %s.\n",
         FFWiFiStaysJoinedAsleep()
           ? "stays joined, so it can still be reached"
           : "is switched off, so on battery it cannot be reached until it wakes");
  BOOL reached = [reach[FFReachHome] boolValue] && [reach[FFReachSteady] boolValue] &&
                 [reach[FFReachNetwork] boolValue] && [reach[FFReachShell] boolValue];
  return reached && orphans.count == 0 && FFSystemVolumeWritable() ? 0 : 1;
}

static NSArray<NSMutableDictionary *> *FFOnTrial(NSDictionary *journal) {
  NSDate *boot = FFBootTime();
  NSMutableArray<NSMutableDictionary *> *waiting = [NSMutableArray new];
  for (NSMutableDictionary *batch in journal[@"batches"]) {
    NSDate *made = batch[@"at"];
    if (batch[@"restored"] == nil && batch[@"survived"] == nil && boot != nil &&
        [made isKindOfClass:[NSDate class]] && [made compare:boot] == NSOrderedAscending) {
      [waiting addObject:batch];
    }
  }
  return waiting;
}

static void FFHandleRequests(void) {
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *name in [manager contentsOfDirectoryAtPath:FFRequestFolder error:NULL]) {
    @autoreleasepool {
      NSString *file = [FFRequestFolder stringByAppendingPathComponent:name];
      NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:file];
      [manager removeItemAtPath:file error:NULL];
      NSString *verb = request[@"verb"];
      NSArray *groups = request[@"groups"];
      NSMutableArray<NSString *> *words = [NSMutableArray new];
      for (id word in [groups isKindOfClass:[NSArray class]] ? groups : @[]) {
        if ([word isKindOfClass:[NSString class]]) {
          [words addObject:word];
        }
      }
      if ([verb isEqual:FFVerbRemove]) {
        FFRemove(words);
      } else if ([verb isEqual:FFVerbRestore]) {
        FFRestore(words);
      }
    }
  }
}

static void FFWait(unsigned seconds) {
  for (unsigned waited = 0; waited < seconds; waited += FFQueueEvery) {
    sleep(FFQueueEvery);
    FFHandleRequests();
  }
}

static void FFAfterRestart(void) {
  if (FFOnTrial(FFJournal()).count == 0) {
    return;
  }
  FFSay(@"The device restarted with removals that had not been through a restart. Checking "
        @"that it can still be reached.");
  FFWait(FFTrialFirst);
  NSString *missing = nil;
  for (unsigned attempt = 0; attempt < FFTrialTries; attempt++) {
    NSMutableDictionary *journal = FFJournal();
    NSArray<NSMutableDictionary *> *waiting = FFOnTrial(journal);
    NSDictionary *now = FFReach();
    missing = nil;
    for (NSMutableDictionary *batch in waiting) {
      missing = missing ?: FFReachMissing(batch[@"reach"], now);
    }
    if (missing == nil) {
      for (NSMutableDictionary *batch in waiting) {
        batch[@"survived"] = [NSDate date];
      }
      FFWriteJournal(journal);
      FFSay(@"The device restarted with batch %@ removed and can still be reached: %@.",
            [[waiting valueForKey:@"id"] componentsJoinedByString:@", "], FFReachSentence(now));
      notify_post(FFCleanupChanged.UTF8String);
      return;
    }
    FFWait(FFTrialEvery);
  }
  NSMutableDictionary *journal = FFJournal();
  NSArray<NSMutableDictionary *> *failed = FFOnTrial(journal);
  NSDictionary *before = failed.firstObject[@"reach"];
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  BOOL restarted = NO;
  for (NSMutableDictionary *batch in failed.reverseObjectEnumerator) {
    restarted = restarted || batch[@"restarted"] != nil;
    batch[@"restarted"] = [NSDate date];
    [paths addObjectsFromArray:[FFBatchPaths(batch[@"id"]) reverseObjectEnumerator].allObjects];
  }
  FFWriteJournal(journal);
  NSString *why = [@"by itself, because after a restart " stringByAppendingString:missing];
  NSMutableArray<NSString *> *problems = [NSMutableArray new];
  NSUInteger restored = FFRestorePaths(paths, why, problems);
  FFFinish(FFVerbRestore,
           [NSString stringWithFormat:@"Put %@ back %@.", FFThings(restored), why],
           problems);
  FFWait(FFSettle);
  if (FFReachMissing(before, FFReach()) != nil && !restarted) {
    FFSay(@"The device still cannot be reached, so it is restarting once.");
    sync();
    reboot(FFRestartNow);
  }
}

static void FFStandFirm(void) {
  FFRunAboveOthers();
  FFKeepInMemory(FFMemoryLimitMegabytes);
}

static int FFAskHelper(NSString *verb, NSArray<NSString *> *words) {
  NSDate *asked = [NSDate date];
  unsigned long long shown = [[NSFileManager defaultManager] attributesOfItemAtPath:FFLogPath
                                                                              error:NULL].fileSize;
  NSString *request = FFSendRequest(verb, words);
  if (request == nil) {
    return -1;
  }
  BOOL begun = NO;
  for (unsigned waited = 0;; waited++) {
    sleep(1);
    NSFileHandle *log = [NSFileHandle fileHandleForReadingAtPath:FFLogPath];
    [log seekToFileOffset:shown];
    NSData *fresh = [log readDataToEndOfFile];
    [log closeFile];
    if (fresh.length > 0) {
      shown += fresh.length;
      fwrite(fresh.bytes, 1, fresh.length, stdout);
      fflush(stdout);
      begun = YES;
    }
    NSDictionary *progress = FFReadProgress();
    NSDate *finished = progress[@"finished"];
    if (![progress[@"running"] boolValue] && [finished isKindOfClass:[NSDate class]] &&
        [finished compare:asked] != NSOrderedAscending) {
      return [progress[@"problems"] count] > 0 ? 1 : 0;
    }
    if (!begun && waited >= FFHelperWait) {
      [[NSFileManager defaultManager] removeItemAtPath:request error:NULL];
      return -1;
    }
  }
}

int FFServe(void) {
  if (getuid() != 0) {
    return FFFail(@"only root may run the helper");
  }
  FFQuiet = YES;
  xpc_transaction_begin();
  FFStandFirm();
  int lock = FFPrepare() ? FFLock() : -1;
  if (lock < 0) {
    return 1;
  }
  IOPMAssertionID awake = 0;
  IOPMAssertionCreateWithName(CFSTR("NoIdleSleepAssertion"), FFAssertionOn,
                              CFSTR("com.fleetfinch.app.cleanup"), &awake);
  FFHandleRequests();
  FFAfterRestart();
  FFHandleRequests();
  IOPMAssertionRelease(awake);
  close(lock);
  return 0;
}

int FFCleanupCommand(NSArray<NSString *> *arguments) {
  NSString *verb = arguments.firstObject ?: @"status";
  NSArray<NSString *> *words =
    arguments.count > 1 ? [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)] : @[];
  if ([verb isEqualToString:@"status"] || [verb isEqualToString:@"list"]) {
    FFPrintStatus([verb isEqualToString:@"list"], words);
    return 0;
  }
  if ([verb isEqualToString:@"check"]) {
    return FFCheck();
  }
  BOOL removing = [verb isEqualToString:FFVerbRemove];
  if (!removing && ![verb isEqualToString:FFVerbRestore]) {
    return FFFail([NSString stringWithFormat:@"cleanup does not know how to %@", verb]);
  }
  if (getuid() != 0) {
    return FFFail([NSString stringWithFormat:@"only root may %@ a part of iOS", verb]);
  }
  NSString *unknown = nil;
  if (words.count > 0 && FFSelect(words, &unknown) == nil) {
    return FFFailUnknown(unknown);
  }
  int asked = FFAskHelper(verb, words);
  if (asked >= 0) {
    return asked;
  }
  fprintf(stderr, "fleetfinch: the helper that launchd runs did not answer, so this is being "
                  "done in this session, which iOS may starve if the device gets busy\n");
  FFStandFirm();
  int lock = FFPrepare() ? FFLock() : -1;
  if (lock < 0) {
    return FFFail(@"another cleanup is running, or its folder could not be made");
  }
  IOPMAssertionID awake = 0;
  IOPMAssertionCreateWithName(CFSTR("NoIdleSleepAssertion"), FFAssertionOn,
                              CFSTR("com.fleetfinch.app.cleanup"), &awake);
  int result = removing ? FFRemove(words) : FFRestore(words);
  IOPMAssertionRelease(awake);
  close(lock);
  return result;
}
