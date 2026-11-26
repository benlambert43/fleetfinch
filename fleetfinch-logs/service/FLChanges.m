#import "FLChanges.h"

#import <copyfile.h>
#import <netinet/in.h>
#import <spawn.h>
#import <sys/mount.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/wait.h>
#import <unistd.h>

#import "FLCollect.h"
#import "FLCommon.h"
#import "FLDependencyIndex.h"
#import "FLInventory.h"
#import "FLLoaded.h"
#import "FLReport.h"
#import "FLStatus.h"
#import "FLStore.h"
#import "FLSystemInfo.h"
#import "FLTouched.h"

extern char **environ;

NSString *const FLHeldFolder = @"/Library/FinchLogs/Held";
static NSString *const FLChangesFolder = @"/Library/FinchLogs";
static NSString *const FLChangesFile = @"/Library/FinchLogs/changes.plist";
static NSString *const FLStoredFolder = @"/private/var/FinchLogsHeld";
static NSString *const FLLaunchControl = @"/bin/launchctl";
static NSString *const FLHomeScreen = @"/System/Library/CoreServices/SpringBoard.app";
static NSString *const FLStateHeld = @"held";
static NSString *const FLStateStored = @"stored";
static NSString *const FLStateRestored = @"restored";
static NSString *const FLStateDiscarded = @"discarded";
static NSString *const FLReachHome = @"springboard";
static NSString *const FLReachShell = @"ssh";
static NSString *const FLReachNetwork = @"network";
static const uint16_t FLShellPort = 22;
static const double FLExpectedRuns = 3;
static const unsigned long long FLErrorsNoticed = 5;
static const double FLErrorsTimes = 3;
static const uint64_t FLSpareBytes = 8 * 1024 * 1024;
static const size_t FLCompareBytes = 64 * 1024;
static const int64_t FLTrialFirst = 120;
static const int64_t FLTrialEvery = 30;
static const NSUInteger FLTrialTries = 9;
static const NSUInteger FLPlainFolderItems = 1;

static NSArray<NSString *> *FLCountedFields(void) {
  return @[ @"runs", @"errors", @"faults", @"reported", @"bad" ];
}

static NSArray<NSString *> *FLWayBack(void) {
  return @[
    @"/sbin/launchd", @"/usr/bin/finchlog", FLLaunchControl, @"/usr/sbin/racoon",
    @"/usr/libexec/dhcpd", @"/usr/libexec/wifiFirmwareLoader",
    @"/usr/libexec/wifiFirmwareLoader_orig", @"/usr/sbin/sshd", @"/bin/sh", @"/bin/bash",
    @"/usr/sbin/wifid", @"/usr/libexec/configd"
  ];
}

static NSArray<NSString *> *FLStartupPaths(void) {
  return [FLWayBack() arrayByAddingObjectsFromArray:@[
    @"/usr/lib/dyld", @"/usr/lib/system", @"/System/Library/Caches", @"/private/etc",
    @"/private/var", FLHomeScreen, @"/taig", @"/usr/share/icu",
    @"/System/Library/CoreServices/SystemVersion.plist", @"/System/Library/SystemConfiguration",
    FLChangesFolder
  ]];
}

static NSMutableDictionary *FLReadJournal(void) {
  NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:FLChangesFile];
  NSMutableDictionary *journal = [NSMutableDictionary new];
  NSMutableArray *changes = [NSMutableArray new];
  NSArray *kept = [saved[@"changes"] isKindOfClass:[NSArray class]] ? saved[@"changes"] : @[];
  for (NSDictionary *each in kept) {
    [changes addObject:[each mutableCopy]];
  }
  journal[@"next"] = saved[@"next"] ?: @1;
  journal[@"changes"] = changes;
  return journal;
}

static BOOL FLWriteJournal(NSDictionary *journal) {
  [[NSFileManager defaultManager] createDirectoryAtPath:FLChangesFolder
                            withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0755}
                                                  error:NULL];
  return [journal writeToFile:FLChangesFile atomically:YES];
}

static BOOL FLIsInside(NSString *path, NSString *folder) {
  return [path isEqualToString:folder] || [path hasPrefix:[folder stringByAppendingString:@"/"]];
}

static NSString *FLCleanPath(NSString *word) {
  NSString *path = word;
  while (path.length > 1 && [path hasSuffix:@"/"]) {
    path = [path substringToIndex:path.length - 1];
  }
  NSString *name = path.lastPathComponent;
  char resolved[PATH_MAX];
  if ([name isEqualToString:@"."] || [name isEqualToString:@".."] ||
      realpath(path.stringByDeletingLastPathComponent.fileSystemRepresentation, resolved) == NULL) {
    return nil;
  }
  NSString *folder =
    [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolved
                                                                length:strlen(resolved)];
  return [folder stringByAppendingPathComponent:name];
}

static NSDictionary *FLServiceDefinedAt(NSString *path) {
  __block NSDictionary *found = nil;
  FLEachLaunchDefinition(^(NSDictionary *service, NSDictionary *plist) {
    if ([service[@"file"] isEqualToString:path]) {
      found = service;
    }
  });
  return found;
}

static int FLRun(NSArray<NSString *> *arguments) {
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

static BOOL FLIsLoaded(NSString *label) {
  return label != nil && FLLaunchJobs()[label] != nil;
}

static void FLControlService(NSString *verb, NSString *file) {
  if (access(FLLaunchControl.fileSystemRepresentation, X_OK) == 0) {
    FLRun(@[ FLLaunchControl, verb, file ]);
  }
}

static BOOL FLHomeScreenRuns(void) {
  NSString *program = [FLHomeScreen stringByAppendingPathComponent:@"SpringBoard"];
  for (FLProcess *process in FLProcessList(YES)) {
    if ([process.path isEqualToString:program]) {
      return YES;
    }
  }
  return NO;
}

static BOOL FLAnswersHere(uint16_t port) {
  int handle = socket(AF_INET, SOCK_STREAM, 0);
  if (handle < 0) {
    return NO;
  }
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_len = sizeof(address);
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  BOOL answered = connect(handle, (struct sockaddr *)&address, sizeof(address)) == 0;
  close(handle);
  return answered;
}

static BOOL FLHasAddress(void) {
  for (FLInterface *interface in FLInterfaces()) {
    if ([interface isLoopback] || ![interface isUp]) {
      continue;
    }
    for (NSString *address in interface.addresses) {
      if ([address rangeOfString:@"."].location != NSNotFound &&
          ![address hasPrefix:@"169.254."]) {
        return YES;
      }
    }
  }
  return NO;
}

static void FLMeasure(NSString *path, NSUInteger *entries, uint64_t *bytes) {
  struct stat info;
  if (lstat(path.fileSystemRepresentation, &info) != 0) {
    return;
  }
  *entries += 1;
  if (S_ISREG(info.st_mode)) {
    *bytes += (uint64_t)info.st_size;
  }
  if (!S_ISDIR(info.st_mode)) {
    return;
  }
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *name in [manager contentsOfDirectoryAtPath:path error:NULL]) {
    @autoreleasepool {
      FLMeasure([path stringByAppendingPathComponent:name], entries, bytes);
    }
  }
}

static uint64_t FLRoomAt(NSString *path) {
  struct statfs volume;
  if (statfs(path.fileSystemRepresentation, &volume) != 0) {
    return 0;
  }
  return (uint64_t)volume.f_bavail * (uint64_t)volume.f_bsize;
}

static BOOL FLCopyEntry(NSString *from, NSString *to) {
  const char *source = from.fileSystemRepresentation;
  const char *target = to.fileSystemRepresentation;
  struct stat info;
  if (lstat(source, &info) != 0) {
    return NO;
  }
  if (S_ISDIR(info.st_mode)) {
    if (mkdir(target, S_IRWXU) != 0) {
      return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in [manager contentsOfDirectoryAtPath:from error:NULL]) {
      @autoreleasepool {
        if (!FLCopyEntry([from stringByAppendingPathComponent:name],
                         [to stringByAppendingPathComponent:name])) {
          return NO;
        }
      }
    }
  } else if (S_ISLNK(info.st_mode)) {
    char link[PATH_MAX];
    ssize_t length = readlink(source, link, sizeof(link) - 1);
    if (length < 0) {
      return NO;
    }
    link[length] = '\0';
    if (symlink(link, target) != 0) {
      return NO;
    }
  } else if (S_ISREG(info.st_mode)) {
    copyfile_flags_t how = COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_NOFOLLOW | COPYFILE_EXCL;
    if (copyfile(source, target, NULL, how) != 0) {
      return NO;
    }
  } else {
    return NO;
  }
  if (lchown(target, info.st_uid, info.st_gid) != 0) {
    return NO;
  }
  if (S_ISLNK(info.st_mode)) {
    return YES;
  }
  struct timeval times[2];
  times[0].tv_sec = info.st_atimespec.tv_sec;
  times[0].tv_usec = 0;
  times[1].tv_sec = info.st_mtimespec.tv_sec;
  times[1].tv_usec = (suseconds_t)(info.st_mtimespec.tv_nsec / 1000);
  return chmod(target, info.st_mode & 07777) == 0 && utimes(target, times) == 0;
}

static BOOL FLSameContents(const char *first, const char *second) {
  int one = open(first, O_RDONLY | O_NOFOLLOW);
  int other = open(second, O_RDONLY | O_NOFOLLOW);
  char *block = malloc(2 * FLCompareBytes);
  BOOL same = one >= 0 && other >= 0 && block != NULL;
  while (same) {
    ssize_t got = read(one, block, FLCompareBytes);
    ssize_t matched = got <= 0 ? got : read(other, block + FLCompareBytes, (size_t)got);
    if (got < 0 || matched != got) {
      same = NO;
    } else if (got == 0) {
      same = read(other, block + FLCompareBytes, 1) == 0;
      break;
    } else {
      same = memcmp(block, block + FLCompareBytes, (size_t)got) == 0;
    }
  }
  free(block);
  if (one >= 0) {
    close(one);
  }
  if (other >= 0) {
    close(other);
  }
  return same;
}

static BOOL FLSameEntry(NSString *from, NSString *to) {
  const char *source = from.fileSystemRepresentation;
  const char *target = to.fileSystemRepresentation;
  struct stat first, second;
  if (lstat(source, &first) != 0 || lstat(target, &second) != 0 ||
      first.st_mode != second.st_mode || first.st_uid != second.st_uid ||
      first.st_gid != second.st_gid) {
    return NO;
  }
  if (S_ISREG(first.st_mode)) {
    return first.st_size == second.st_size && FLSameContents(source, target);
  }
  if (S_ISLNK(first.st_mode)) {
    char one[PATH_MAX], other[PATH_MAX];
    ssize_t length = readlink(source, one, sizeof(one));
    return length >= 0 && length == readlink(target, other, sizeof(other)) &&
           memcmp(one, other, (size_t)length) == 0;
  }
  if (!S_ISDIR(first.st_mode)) {
    return NO;
  }
  NSFileManager *manager = [NSFileManager defaultManager];
  NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:from error:NULL];
  NSArray<NSString *> *copied = [manager contentsOfDirectoryAtPath:to error:NULL];
  if (names == nil || copied == nil ||
      ![[NSSet setWithArray:names] isEqualToSet:[NSSet setWithArray:copied]]) {
    return NO;
  }
  for (NSString *name in names) {
    @autoreleasepool {
      if (!FLSameEntry([from stringByAppendingPathComponent:name],
                       [to stringByAppendingPathComponent:name])) {
        return NO;
      }
    }
  }
  return YES;
}

static NSString *FLCopyTree(NSString *from, NSString *to) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *folder = to.stringByDeletingLastPathComponent;
  [manager createDirectoryAtPath:folder
     withIntermediateDirectories:YES
                      attributes:@{NSFilePosixPermissions : @0755}
                           error:NULL];
  [manager removeItemAtPath:to error:NULL];
  NSUInteger entries = 0;
  uint64_t bytes = 0;
  FLMeasure(from, &entries, &bytes);
  if (FLRoomAt(folder) < bytes + FLSpareBytes) {
    return [NSString stringWithFormat:@"there is not room for %@ where %@ is", FLFormatBytes(bytes),
                                      folder];
  }
  if (!FLCopyEntry(from, to) || !FLSameEntry(from, to)) {
    [manager removeItemAtPath:to error:NULL];
    return [NSString stringWithFormat:@"the copy at %@ did not come out the same", to];
  }
  return nil;
}

static NSDictionary *FLItemAt(NSDictionary *inventory, NSString *path) {
  for (NSDictionary *item in inventory[@"items"]) {
    if ([item[@"path"] isEqualToString:path]) {
      return item;
    }
  }
  return nil;
}

static NSString *FLPackageOf(NSString *path) {
  NSDictionary<NSString *, NSString *> *owners = FLPackageOwners();
  NSString *prefix = [path stringByAppendingString:@"/"];
  for (NSString *owned in owners) {
    struct stat info;
    if (([owned isEqualToString:path] || [owned hasPrefix:prefix]) &&
        lstat(owned.fileSystemRepresentation, &info) == 0 && !S_ISDIR(info.st_mode)) {
      return owners[owned];
    }
  }
  return nil;
}

static NSString *FLStartupNeed(NSString *path, NSString *program) {
  for (NSString *needed in FLStartupPaths()) {
    if (FLIsInside(path, needed) || FLIsInside(needed, path) ||
        (program != nil && FLIsInside(program, needed))) {
      return needed;
    }
  }
  return nil;
}

NSSet<NSString *> *FLPathsKept(FLReportSource source) {
  NSDictionary *inventory = source(FLInventoryState);
  NSDictionary *dependencies = source(FLDependenciesState);
  FLDependencyIndex *index = [[FLDependencyIndex alloc] initWithDependencies:dependencies
                                                                   inventory:inventory];
  NSMutableSet<NSString *> *kept = [[index pathsLinkedFrom:FLWayBack()] mutableCopy];
  NSDictionary *loaded = source(FLLoadedState);
  NSDictionary *libraries = loaded[@"libraries"];
  for (NSString *library in [libraries isKindOfClass:[NSDictionary class]] ? libraries : @{}) {
    for (NSString *program in FLLoadedBy(loaded, library)) {
      if ([FLWayBack() containsObject:program]) {
        [kept addObject:library];
        break;
      }
    }
  }
  return kept;
}

BOOL FLPathIsKept(NSString *path, NSString *program, NSSet<NSString *> *kept) {
  if (FLStartupNeed(path, program) != nil) {
    return YES;
  }
  for (NSString *each in kept) {
    if (FLIsInside(each, path) || FLIsInside(path, each)) {
      return YES;
    }
  }
  return NO;
}

static NSUInteger FLProgramsAmong(NSArray<NSString *> *files, NSDictionary *inventory) {
  NSMutableSet<NSString *> *programs = [NSMutableSet new];
  for (NSDictionary *item in inventory[@"items"]) {
    BOOL single = [@[ @"program", @"library" ] containsObject:item[@"kind"] ?: @""];
    for (NSString *file in @[ single ? item[@"path"] ?: @"" : @"", item[@"program"] ?: @"",
                              item[@"binary"] ?: @"" ]) {
      if (file.length > 0) {
        [programs addObject:file];
      }
    }
  }
  NSUInteger count = 0;
  for (NSString *file in files) {
    count += [programs containsObject:file] ? 1 : 0;
  }
  return count;
}

static NSString *FLRefusal(NSString *path, NSDictionary *service, BOOL force,
                           NSDictionary *inventory, FLDependencyIndex *index,
                           NSDictionary *found) {
  struct stat info;
  struct statfs volume;
  if (lstat(path.fileSystemRepresentation, &info) != 0) {
    return [NSString stringWithFormat:@"there is nothing at %@", path];
  }
  NSString *needed = FLStartupNeed(path, service[@"program"]);
  if (needed != nil) {
    return [NSString stringWithFormat:@"%@ stays where it is: the device needs %@ to start, to "
                                      @"be reached, or to undo a change",
                                      path, needed];
  }
  if ([path componentsSeparatedByString:@"/"].count < 3 ||
      statfs(path.stringByDeletingLastPathComponent.fileSystemRepresentation, &volume) != 0 ||
      strcmp(volume.f_mntonname, "/") != 0) {
    return [NSString stringWithFormat:@"%@ is not a part of iOS inside one of the system "
                                      @"volume's folders",
                                      path];
  }
  NSString *package = FLPackageOf(path);
  if (package != nil) {
    return [NSString stringWithFormat:@"%@ holds files of the package %@. Remove that package "
                                      @"instead",
                                      path, package];
  }
  if (inventory.count == 0 || index == nil) {
    return @"what is installed and what depends on what have not been worked out yet. Run "
           @"finchlog depends --fresh first";
  }
  for (NSString *used in [index pathsLinkedFrom:FLWayBack()]) {
    if (FLIsInside(used, path) || FLIsInside(path, used)) {
      return [NSString stringWithFormat:@"%@ stays where it is: Finch Logs, launchd, the "
                                        @"jailbreak or the way in over SSH links %@",
                                        path, used];
    }
  }
  NSDictionary *loaded = index.loaded;
  NSDictionary *libraries = loaded[@"libraries"];
  for (NSString *library in [libraries isKindOfClass:[NSDictionary class]] ? libraries : @{}) {
    if (!FLIsInside(library, path)) {
      continue;
    }
    for (NSString *program in FLLoadedBy(loaded, library)) {
      if ([FLWayBack() containsObject:program]) {
        return [NSString stringWithFormat:@"%@ stays where it is: %@ had %@ loaded, and the "
                                          @"device needs that program to start, to be reached "
                                          @"or to undo a change",
                                          path, program, library];
      }
    }
  }
  NSDictionary *item = FLItemAt(inventory, path);
  NSUInteger within = 0;
  NSString *prefix = [path stringByAppendingString:@"/"];
  for (NSDictionary *each in item == nil ? inventory[@"items"] : @[]) {
    within += [each[@"path"] hasPrefix:prefix] ? 1 : 0;
  }
  if (within > FLPlainFolderItems) {
    return [NSString stringWithFormat:@"%@ is a folder that holds %lu installed things. Set "
                                      @"them aside one at a time",
                                      path, (unsigned long)within];
  }
  if (force || service != nil) {
    return nil;
  }
  for (FLProcess *process in FLProcessList(YES)) {
    if (process.path.length > 0 && FLIsInside(process.path, path)) {
      return [NSString stringWithFormat:@"%@ is running now as pid %d. Set aside the launch "
                                        @"service that starts it first, or add --force",
                                        process.path, process.pid];
    }
  }
  NSArray<NSString *> *early = found[@"starting"];
  NSUInteger run = FLProgramsAmong(early, inventory);
  if (early.count > 0 && (![item[@"kind"] isEqualToString:@"app"] || run > 0)) {
    NSString *programs = run == 0
      ? @""
      : [NSString stringWithFormat:@", %@ of them a program or a library", @(run)];
    return [NSString stringWithFormat:@"%@ stays where it is: the device read %@ in it while "
                                      @"starting%@. Add --force to set it aside anyway",
                                      path, FLReportCount(early.count, @"file", @"files"),
                                      programs];
  }
  if ([item[@"need"] isEqualToString:@"loaded"]) {
    return [NSString stringWithFormat:@"%@ is linked by %@ programs and libraries, and at least "
                                      @"one of them has run. Add --force to set it aside anyway",
                                      path, item[@"users"] ?: @"some"];
  }
  for (NSString *library in [libraries isKindOfClass:[NSDictionary class]] ? libraries : @{}) {
    NSArray<NSString *> *programs = FLIsInside(library, path) ? FLLoadedBy(loaded, library) : @[];
    if (programs.count > 0) {
      NSString *others = programs.count == 1
        ? @""
        : [@" and " stringByAppendingString:FLReportCount(programs.count - 1, @"other program",
                                                          @"other programs")];
      return [NSString stringWithFormat:@"%@ has been seen loaded by %@%@. Add --force to set "
                                        @"it aside anyway",
                                        library, programs.firstObject.lastPathComponent, others];
    }
  }
  return nil;
}

static void FLKeepBaseline(NSNumber *identifier) {
  NSDictionary *usage = FLReadState(FLUsageState);
  NSMutableDictionary *counts = [NSMutableDictionary new];
  NSDictionary<NSString *, NSDictionary *> *entries = usage[@"entries"];
  for (NSString *key in [entries isKindOfClass:[NSDictionary class]] ? entries : @{}) {
    NSMutableArray *values = [NSMutableArray new];
    for (NSString *field in FLCountedFields()) {
      [values addObject:entries[key][field] ?: @0];
    }
    counts[key] = values;
  }
  FLWriteCompactState([NSString stringWithFormat:@"change-%@", identifier], @{
    @"at" : [NSDate date],
    @"watched" : usage[@"watched"] ?: @0,
    @"counts" : counts,
  });
}

static void FLMark(FLLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

static void FLMark(FLLevel level, NSString *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  [[FLStore shared] log:@"change" level:level source:@"finchlog" message:message];
  [[FLStore shared] sync];
  printf("%s\n", message.UTF8String);
}

static int FLFail(NSString *message) {
  fprintf(stderr, "finchlog: %s\n", message.UTF8String);
  return 1;
}

static NSArray<NSString *> *FLStartersOf(NSString *path) {
  NSMutableArray<NSString *> *labels = [NSMutableArray new];
  FLEachLaunchDefinition(^(NSDictionary *service, NSDictionary *plist) {
    if (FLIsInside(service[@"program"], path) && ![labels containsObject:service[@"label"]]) {
      [labels addObject:service[@"label"]];
    }
  });
  return labels;
}

static void FLSayReading(NSDictionary *found, NSDictionary *inventory) {
  NSDictionary *reading = inventory[@"reading"];
  NSDate *counting = reading[@"began"];
  long long last = [found[@"last"] longLongValue];
  if (found == nil || ![counting isKindOfClass:[NSDate class]]) {
    return;
  }
  printf("%s of its %s files have been read since %s, and %s since the device last started. %s\n",
         [found[@"read"] description].UTF8String, [found[@"files"] description].UTF8String,
         FLFormatDay(counting).UTF8String, [found[@"sinceStart"] description].UTF8String,
         FLLastReadSentence(last, reading).UTF8String);
  NSUInteger early = [found[@"starting"] count];
  if (early > 0) {
    printf("The device read %lu of them while starting.\n", (unsigned long)early);
  }
}

static void FLSayOnly(FLDependencyIndex *index, NSDictionary *item) {
  NSArray<NSDictionary *> *only = item == nil ? @[] : [index itemsOnlyNeededBy:item];
  uint64_t total = 0;
  for (NSDictionary *each in only) {
    total += [each[@"bytes"] unsignedLongLongValue];
  }
  if (only.count == 0) {
    return;
  }
  printf("With it gone, nothing else that was found would need %s, %s in all:\n",
         FLReportCount(only.count, @"more thing", @"more things").UTF8String,
         FLFormatBytes(total).UTF8String);
  for (NSDictionary *each in only) {
    printf("  %s\t%s\n", FLFormatBytes([each[@"bytes"] unsignedLongLongValue]).UTF8String,
           [each[@"path"] UTF8String]);
  }
}

static int FLHold(NSString *path, NSString *note, BOOL force, BOOL check,
                  dispatch_block_t save) {
  NSDictionary *service = FLServiceDefinedAt(path);
  NSString *label = service[@"label"];
  save();
  NSDictionary *inventory = FLReadState(FLInventoryState);
  NSDictionary *dependencies = FLReadState(FLDependenciesState);
  FLDependencyIndex *index = nil;
  if (inventory.count > 0 && dependencies.count > 0) {
    index = [[FLDependencyIndex alloc] initWithDependencies:dependencies inventory:inventory];
    index.loaded = FLReadState(FLLoadedState);
  }
  NSDictionary *found = service == nil ? FLReadingUnder(path, inventory) : nil;
  NSString *reason = FLRefusal(path, service, force, inventory, index, found);
  if (reason != nil) {
    return FLFail(reason);
  }
  NSArray<NSString *> *starters = label == nil ? FLStartersOf(path) : @[];
  if (check) {
    NSUInteger entries = 0;
    uint64_t length = 0;
    FLMeasure(path, &entries, &length);
    printf("Nothing stands in the way of setting %s aside: %s, %s.\n", path.UTF8String,
           FLReportCount(entries, @"file", @"files and folders").UTF8String,
           FLFormatBytes(length).UTF8String);
    if (label != nil) {
      printf("It defines the launch service %s, which %s.\n", label.UTF8String,
             FLIsLoaded(label) ? "is loaded and would be unloaded" : "is not loaded");
    }
    for (NSString *starter in starters) {
      printf("launchd has %s, which starts a program in it.\n", starter.UTF8String);
    }
    FLSayReading(found, inventory);
    FLSayOnly(index, FLItemAt(inventory, path));
    return 0;
  }
  NSMutableDictionary *journal = FLReadJournal();
  NSNumber *identifier = journal[@"next"];
  NSString *folder = [FLHeldFolder stringByAppendingPathComponent:identifier.description];
  NSString *held = [folder stringByAppendingPathComponent:path.lastPathComponent];
  if (![[NSFileManager defaultManager] createDirectoryAtPath:folder
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions : @0755}
                                                       error:NULL]) {
    return FLFail([NSString stringWithFormat:@"%@ could not be made", folder]);
  }
  FLKeepBaseline(identifier);
  NSUInteger entries = 0;
  uint64_t bytes = 0;
  FLMeasure(path, &entries, &bytes);
  NSDictionary *reach = @{
    FLReachHome : @(FLHomeScreenRuns()),
    FLReachShell : @(FLAnswersHere(FLShellPort)),
    FLReachNetwork : @(FLHasAddress()),
  };
  BOOL loaded = FLIsLoaded(label);
  NSMutableDictionary *record = [NSMutableDictionary new];
  record[@"id"] = identifier;
  record[@"path"] = path;
  record[@"held"] = held;
  record[@"state"] = FLStateHeld;
  record[@"at"] = [NSDate date];
  record[@"entries"] = @(entries);
  record[@"length"] = @(bytes);
  record[@"reach"] = reach;
  if (note.length > 0) {
    record[@"note"] = note;
  }
  if (label != nil) {
    record[@"label"] = label;
    record[@"loaded"] = @(loaded);
  }
  NSDictionary *item = FLItemAt(inventory, path);
  if (item[@"bytes"] != nil) {
    record[@"bytes"] = item[@"bytes"];
  }
  [journal[@"changes"] addObject:record];
  journal[@"next"] = @(identifier.integerValue + 1);
  if (!FLWriteJournal(journal)) {
    rmdir(folder.fileSystemRepresentation);
    return FLFail([NSString stringWithFormat:@"the record of changes could not be written, so "
                                             @"%@ was left where it is",
                                             path]);
  }
  if (loaded) {
    FLControlService(@"unload", path);
  }
  BOOL stopped = loaded && !FLIsLoaded(label);
  if (rename(path.fileSystemRepresentation, held.fileSystemRepresentation) != 0) {
    int problem = errno;
    if (stopped) {
      FLControlService(@"load", path);
    }
    [journal[@"changes"] removeObject:record];
    FLWriteJournal(journal);
    rmdir(folder.fileSystemRepresentation);
    return FLFail([NSString stringWithFormat:@"%@ could not be moved: %s", path,
                                             strerror(problem)]);
  }
  NSString *defined = @"";
  if (label != nil) {
    NSString *now = !loaded ? @"which was not loaded"
                            : (stopped ? @"which was unloaded, so it is stopped"
                                       : @"which stays loaded until the device restarts");
    defined = [NSString stringWithFormat:@", the definition of %@, %@", label, now];
  }
  FLMark(FLLevelNotice, @"Change %@: set %@ aside%@%@", identifier, path, defined,
         note.length > 0 ? [@". Note: " stringByAppendingString:note] : @"");
  printf("Put it back with: finchlog restore %s\n", identifier.description.UTF8String);
  if ([path.pathExtension isEqualToString:@"app"]) {
    printf("The Home screen shows its icon until uicache is run or the device restarts.\n");
  }
  for (NSString *starter in starters) {
    printf("launchd still has %s, which starts a program in it. Set that aside as well.\n",
           starter.UTF8String);
  }
  FLSayOnly(index, item);
  return 0;
}

static NSMutableDictionary *FLChangeNumbered(NSDictionary *journal, NSString *word) {
  for (NSMutableDictionary *record in journal[@"changes"]) {
    if ([[record[@"id"] description] isEqualToString:word ?: @""]) {
      return record;
    }
  }
  return nil;
}

static BOOL FLIsActive(NSDictionary *record) {
  NSString *state = record[@"state"];
  return [state isEqualToString:FLStateHeld] || [state isEqualToString:FLStateStored];
}

static NSString *FLPutBack(NSMutableDictionary *journal, NSMutableDictionary *record,
                           NSString *why) {
  NSString *path = record[@"path"];
  NSString *held = record[@"held"];
  struct stat info;
  if (!FLIsActive(record)) {
    return [NSString stringWithFormat:@"change %@ was already %@", record[@"id"],
                                      record[@"state"]];
  }
  BOOL there = lstat(path.fileSystemRepresentation, &info) == 0;
  BOOL kept = lstat(held.fileSystemRepresentation, &info) == 0;
  if (there && kept) {
    return [NSString stringWithFormat:@"there is something at %@ again, so the copy set aside "
                                      @"was left where it is",
                                      path];
  }
  if (!there && !kept) {
    return [NSString stringWithFormat:@"the copy that was set aside at %@ is gone", held];
  }
  NSString *folder = path.stringByDeletingLastPathComponent;
  if (!there && lstat(folder.fileSystemRepresentation, &info) != 0) {
    return [NSString stringWithFormat:@"the folder it was in, %@, is not there. Put that back "
                                      @"first",
                                      folder];
  }
  if (there) {
    why = [why stringByAppendingString:@", and it was found already in place"];
  } else if (rename(held.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
    NSString *problem = errno == EXDEV ? FLCopyTree(held, path) : @(strerror(errno));
    if (problem != nil) {
      return [NSString stringWithFormat:@"%@ could not be put back at %@: %@", held, path,
                                        problem];
    }
    [[NSFileManager defaultManager] removeItemAtPath:held error:NULL];
  }
  rmdir(held.stringByDeletingLastPathComponent.fileSystemRepresentation);
  NSString *label = record[@"label"];
  BOOL wanted = label != nil && [record[@"loaded"] boolValue];
  if (wanted) {
    FLControlService(@"load", path);
  }
  record[@"state"] = FLStateRestored;
  record[@"restored"] = [NSDate date];
  record[@"why"] = why ?: @"";
  FLWriteJournal(journal);
  NSString *defined = !wanted ? @""
                              : (FLIsLoaded(label)
                                   ? @", and loaded it into launchd again"
                                   : @"; launchd loads it when the device restarts");
  FLMark(FLLevelNotice, @"Change %@ undone, %@: put %@ back%@", record[@"id"], why, path,
         defined);
  return nil;
}

static int FLRestore(NSMutableDictionary *journal, NSMutableDictionary *record) {
  NSString *problem = FLPutBack(journal, record, @"as asked");
  if (problem != nil) {
    return FLFail(problem);
  }
  if ([[record[@"path"] pathExtension] isEqualToString:@"app"]) {
    printf("The Home screen shows its icon again once uicache is run or the device restarts.\n");
  }
  return 0;
}

static int FLKeepElsewhere(NSMutableDictionary *journal, NSMutableDictionary *record) {
  NSString *held = record[@"held"];
  if (![record[@"state"] isEqualToString:FLStateHeld]) {
    return FLFail([NSString stringWithFormat:@"change %@ is not waiting on the system volume",
                                             record[@"id"]]);
  }
  NSString *folder = [FLStoredFolder stringByAppendingPathComponent:[record[@"id"] description]];
  NSString *kept = [folder stringByAppendingPathComponent:held.lastPathComponent];
  NSString *problem = FLCopyTree(held, kept);
  if (problem != nil) {
    return FLFail([NSString stringWithFormat:@"%@, so %@ was left where it is", problem, held]);
  }
  record[@"held"] = kept;
  record[@"state"] = FLStateStored;
  record[@"stored"] = [NSDate date];
  if (!FLWriteJournal(journal)) {
    [[NSFileManager defaultManager] removeItemAtPath:kept error:NULL];
    return FLFail(@"the record of changes could not be written, so nothing was moved");
  }
  [[NSFileManager defaultManager] removeItemAtPath:held error:NULL];
  rmdir(held.stringByDeletingLastPathComponent.fileSystemRepresentation);
  FLMark(FLLevelNotice,
         @"Change %@: moved %@ off the system volume to %@, where it can still be put back from",
         record[@"id"], record[@"path"], kept);
  return 0;
}

static int FLDiscard(NSMutableDictionary *journal, NSMutableDictionary *record, BOOL sure) {
  NSString *held = record[@"held"];
  if (!FLIsActive(record)) {
    return FLFail([NSString stringWithFormat:@"change %@ was already %@", record[@"id"],
                                             record[@"state"]]);
  }
  if (!sure) {
    return FLFail([NSString stringWithFormat:@"this deletes %@ for good, and nothing can put it "
                                             @"back. Add --yes to do it",
                                             held]);
  }
  if (![[NSFileManager defaultManager] removeItemAtPath:held error:NULL]) {
    return FLFail([NSString stringWithFormat:@"%@ could not be deleted", held]);
  }
  rmdir(held.stringByDeletingLastPathComponent.fileSystemRepresentation);
  record[@"state"] = FLStateDiscarded;
  record[@"discarded"] = [NSDate date];
  FLWriteJournal(journal);
  FLMark(FLLevelNotice, @"Change %@ made final: deleted the copy of %@ that was set aside",
         record[@"id"], record[@"path"]);
  return 0;
}

static NSArray<NSString *> *FLTargets(NSString *word) {
  if ([word hasPrefix:@"/"]) {
    NSString *path = FLCleanPath(word);
    if (path == nil) {
      FLFail([NSString stringWithFormat:@"%@ is not the full path of a thing", word]);
    }
    return path == nil ? nil : @[ path ];
  }
  NSMutableArray<NSString *> *files = [NSMutableArray new];
  FLEachLaunchDefinition(^(NSDictionary *service, NSDictionary *plist) {
    if ([service[@"label"] isEqualToString:word]) {
      [files addObject:service[@"file"]];
    }
  });
  if (files.count > 0) {
    return files;
  }
  FLDependencyIndex *index =
    [[FLDependencyIndex alloc] initWithDependencies:FLReadState(FLDependenciesState)
                                          inventory:FLReadState(FLInventoryState)];
  NSArray<NSDictionary *> *found = [index itemsNamed:word];
  if (found.count == 1 && [found.firstObject[@"path"] hasPrefix:@"/"]) {
    return @[ found.firstObject[@"path"] ];
  }
  if (found.count > 1) {
    fprintf(stderr, "finchlog: %lu things are called %s. Say which by its path:\n",
            (unsigned long)found.count, word.UTF8String);
    for (NSDictionary *item in found) {
      fprintf(stderr, "  %s\n", [item[@"path"] UTF8String]);
    }
    return nil;
  }
  FLFail([NSString stringWithFormat:@"nothing installed is called %@", word]);
  return nil;
}

static NSString *FLChangeState(NSDictionary *record) {
  NSString *state = record[@"state"] ?: @"";
  NSDictionary<NSString *, NSArray<NSString *> *> *words = @{
    FLStateHeld : @[ @"set aside", @"at" ],
    FLStateStored : @[ @"moved off the system volume", @"stored" ],
    FLStateRestored : @[ @"put back", @"restored" ],
    FLStateDiscarded : @[ @"deleted for good", @"discarded" ],
  };
  NSArray<NSString *> *pair = words[state];
  NSDate *when = pair == nil ? nil : record[pair[1]];
  NSString *said = [NSString stringWithFormat:@"%@ %@", pair.firstObject ?: state,
                                              [when isKindOfClass:[NSDate class]]
                                                ? FLFormatDay(when)
                                                : @""];
  if (FLIsActive(record) && record[@"survived"] == nil) {
    said = [said stringByAppendingString:@", not yet through a restart"];
  }
  return said;
}

static NSArray<NSDictionary *> *FLCompare(NSDictionary *baseline, NSDictionary *usage) {
  NSDictionary<NSString *, NSArray<NSNumber *> *> *before = baseline[@"counts"];
  NSDictionary<NSString *, NSDictionary *> *entries =
    [usage[@"entries"] isKindOfClass:[NSDictionary class]] ? usage[@"entries"] : @{};
  double awakeBefore = [baseline[@"watched"] doubleValue];
  double awakeAfter = MAX(0, [usage[@"watched"] doubleValue] - awakeBefore);
  double share = awakeBefore > 0 ? awakeAfter / awakeBefore : 0;
  NSArray<NSString *> *fields = FLCountedFields();
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSString *key in [entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *entry = entries[key];
    unsigned long long runs = [entry[@"runs"] unsignedLongLongValue];
    if ([key hasPrefix:@"program:"] && runs > 0 &&
        [entry[@"covered"] unsignedLongLongValue] >= runs) {
      continue;
    }
    NSArray<NSNumber *> *old = before[key];
    unsigned long long was[5] = {0};
    unsigned long long since[5] = {0};
    for (NSUInteger index = 0; index < fields.count; index++) {
      was[index] = index < old.count ? old[index].unsignedLongLongValue : 0;
      unsigned long long now = [entry[fields[index]] unsignedLongLongValue];
      since[index] = now > was[index] ? now - was[index] : 0;
    }
    NSRange colon = [key rangeOfString:@":"];
    NSString *title = [key substringFromIndex:NSMaxRange(colon)];
    NSMutableArray<NSString *> *found = [NSMutableArray new];
    if (was[0] > 0 && since[0] == 0 && was[0] * share >= FLExpectedRuns) {
      [found addObject:[NSString stringWithFormat:@"has not run since; it ran %@ before, so "
                                                  @"about %.0f runs were to be expected",
                                                  FLReportCount(was[0], @"time", @"times"),
                                                  was[0] * share]];
    }
    if (was[0] == 0 && since[0] > 0) {
      [found addObject:[@"began to run: "
                         stringByAppendingString:FLReportCount(since[0], @"run", @"runs")]];
    }
    if (since[3] > 0) {
      [found addObject:[NSString stringWithFormat:@"%@ written about it (%llu before)",
                                                  FLReportCount(since[3], @"report",
                                                                @"reports"),
                                                  was[3]]];
    }
    if (since[4] > 0 && since[4] > was[4] * share * FLErrorsTimes) {
      [found addObject:[NSString stringWithFormat:@"ended badly %@ (%llu before)",
                                                  FLReportCount(since[4], @"time", @"times"),
                                                  was[4]]];
    }
    if (since[2] > 0 && since[2] > was[2] * share * FLErrorsTimes) {
      [found addObject:[NSString stringWithFormat:@"logged %@ (%llu before)",
                                                  FLReportCount(since[2], @"fault", @"faults"),
                                                  was[2]]];
    }
    if (since[1] >= FLErrorsNoticed && since[1] > was[1] * share * FLErrorsTimes) {
      [found addObject:[NSString stringWithFormat:@"logged %@ (%llu before)",
                                                  FLReportCount(since[1], @"error", @"errors"),
                                                  was[1]]];
    }
    if (found.count > 0) {
      [rows addObject:FLReportRow(title, [found componentsJoinedByString:@"; "], nil)];
    }
  }
  return rows;
}

static NSDictionary *FLChangeRow(NSDictionary *record) {
  NSDate *made = record[@"at"];
  NSString *title = [NSString stringWithFormat:@"%@. %@", record[@"id"], record[@"path"]];
  uint64_t taken = [record[@"bytes"] unsignedLongLongValue];
  NSDictionary *row = FLReportRow(title, FLChangeState(record), @[
    @[ @"Set aside", [made isKindOfClass:[NSDate class]] ? FLFormatDay(made) : @"" ],
    @[ @"Launch service", record[@"label"] ?: @"" ],
    @[ @"Note", record[@"note"] ?: @"" ],
    @[ @"Kept at", FLIsActive(record) ? record[@"held"] ?: @"" : @"" ],
    @[ @"Put back", record[@"why"] ?: @"" ],
    @[ @"Space it took", taken > 0 ? FLFormatBytes(taken) : @"" ],
    @[ @"Length", FLFormatBytes([record[@"length"] unsignedLongLongValue]) ],
    @[ @"Files and folders", [record[@"entries"] description] ?: @"" ],
  ]);
  if (!FLIsActive(record)) {
    return row;
  }
  NSMutableDictionary *acting = [row mutableCopy];
  acting[@"action"] = @{
    @"title" : @"Put It Back",
    @"command" : FLCommandRestore,
    @"value" : record[@"id"] ?: @0,
    @"confirm" : [NSString stringWithFormat:@"Put %@ back where it was?", record[@"path"]],
  };
  return acting;
}

NSDictionary *FLChangesReport(FLReportSource source) {
  NSDictionary *journal = FLReadJournal();
  NSDictionary *usage = source(FLUsageState);
  NSMutableArray<NSDictionary *> *listed = [NSMutableArray new];
  NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
  for (NSDictionary *record in [journal[@"changes"] reverseObjectEnumerator]) {
    [listed addObject:FLChangeRow(record)];
    if (!FLIsActive(record)) {
      continue;
    }
    NSDictionary *baseline = FLReadState([NSString stringWithFormat:@"change-%@", record[@"id"]]);
    double awake = MAX(0, [usage[@"watched"] doubleValue] - [baseline[@"watched"] doubleValue]);
    NSString *note = baseline.count == 0
      ? @"What was counted before this change was not kept, so nothing can be compared."
      : [NSString stringWithFormat:@"The device has been awake for %@ since. Each line is "
                                   @"something that differs from before the change, which "
                                   @"does not prove the change caused it.",
                                   FLFormatDuration(awake)];
    NSString *title = [NSString stringWithFormat:@"Since change %@, %@", record[@"id"],
                                                 [record[@"path"] lastPathComponent]];
    [sections addObject:FLReportSection(title, note, FLCompare(baseline, usage))];
  }
  [sections insertObject:FLReportSection(@"Changes", nil, listed) atIndex:0];
  NSString *how =
    @"finchlog hold NAME sets a part of iOS aside, where iOS no longer finds it, and unloads "
    @"it first if it is a launch service. finchlog restore NUMBER puts it back, finchlog store "
    @"NUMBER moves it off the system volume to free the space, and finchlog discard NUMBER "
    @"deletes it for good.";
  NSString *trial =
    @"A change that has not been through a restart is put back by itself if, some minutes "
    @"after the next restart, the Home screen is not running, the device does not answer on "
    @"its SSH port or it has no network address, when it did before the change.";
  return @{
    @"title" : FLReportTitle(@"changes"),
    @"made" : [NSDate date],
    @"notes" : @[ how, trial ],
    @"sections" : sections,
  };
}

BOOL FLRestoreChange(NSNumber *identifier, NSString *why) {
  NSMutableDictionary *journal = FLReadJournal();
  NSMutableDictionary *record = FLChangeNumbered(journal, identifier.description);
  return record != nil && FLPutBack(journal, record, why) == nil;
}

static void FLTryChanges(dispatch_queue_t queue, NSUInteger attempt) {
  NSMutableDictionary *journal = FLReadJournal();
  NSDate *boot = FLBootTime();
  NSMutableArray<NSMutableDictionary *> *waiting = [NSMutableArray new];
  for (NSMutableDictionary *record in journal[@"changes"]) {
    NSDate *made = record[@"at"];
    if (FLIsActive(record) && record[@"survived"] == nil && boot != nil &&
        [made isKindOfClass:[NSDate class]] && [made compare:boot] == NSOrderedAscending) {
      [waiting addObject:record];
    }
  }
  if (waiting.count == 0) {
    return;
  }
  BOOL home = FLHomeScreenRuns();
  BOOL shell = FLAnswersHere(FLShellPort);
  BOOL network = FLHasAddress();
  NSMutableArray<NSMutableDictionary *> *passed = [NSMutableArray new];
  NSMutableArray<NSMutableDictionary *> *failed = [NSMutableArray new];
  for (NSMutableDictionary *record in waiting) {
    NSDictionary *reach = record[@"reach"];
    BOOL reached = (home || ![reach[FLReachHome] boolValue]) &&
                   (shell || ![reach[FLReachShell] boolValue]) &&
                   (network || ![reach[FLReachNetwork] boolValue]);
    [reached ? passed : failed addObject:record];
  }
  if (failed.count > 0 && attempt + 1 < FLTrialTries) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, FLTrialEvery * NSEC_PER_SEC), queue, ^{
      FLTryChanges(queue, attempt + 1);
    });
    return;
  }
  if (passed.count > 0) {
    for (NSMutableDictionary *record in passed) {
      record[@"survived"] = [NSDate date];
    }
    FLWriteJournal(journal);
    FLMark(FLLevelNotice,
           @"The device restarted with change %@ in place and can still be reached",
           [[passed valueForKey:@"id"] componentsJoinedByString:@", "]);
  }
  NSString *missing = !home ? @"the Home screen was not running"
                            : (!shell ? @"the device did not answer on its SSH port"
                                      : @"the device had no network address");
  NSString *why = [@"by itself, because after a restart " stringByAppendingString:missing];
  for (NSMutableDictionary *record in failed.reverseObjectEnumerator) {
    NSString *problem = FLPutBack(journal, record, why);
    if (problem != nil) {
      FLMark(FLLevelFault, @"Change %@ could not be undone after a restart: %@", record[@"id"],
             problem);
    }
  }
}

void FLWatchChanges(dispatch_queue_t queue) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, FLTrialFirst * NSEC_PER_SEC), queue, ^{
    FLTryChanges(queue, 0);
  });
}

int FLChangeCommand(NSString *verb, NSArray<NSString *> *arguments, dispatch_block_t save) {
  NSString *word = arguments.count > 0 && ![arguments[0] hasPrefix:@"--"] ? arguments[0] : nil;
  if (word == nil) {
    return FLFail([NSString stringWithFormat:@"say what to %@", verb]);
  }
  if (getuid() != 0) {
    return FLFail([NSString stringWithFormat:@"only root may %@ a part of iOS", verb]);
  }
  if ([verb isEqualToString:@"hold"]) {
    NSUInteger noted = [arguments indexOfObject:@"--note"];
    NSString *note = noted != NSNotFound && noted + 1 < arguments.count ? arguments[noted + 1]
                                                                        : nil;
    NSArray<NSString *> *targets = FLTargets(word);
    int result = targets == nil ? 1 : 0;
    for (NSString *path in targets) {
      result = MAX(result, FLHold(path, note, [arguments containsObject:@"--force"],
                                  [arguments containsObject:@"--check"], save));
    }
    return result;
  }
  NSMutableDictionary *journal = FLReadJournal();
  NSMutableDictionary *record = FLChangeNumbered(journal, word);
  if (record == nil) {
    return FLFail([NSString stringWithFormat:@"there is no change numbered %@; finchlog changes "
                                             @"lists them",
                                             word]);
  }
  if ([verb isEqualToString:@"restore"]) {
    return FLRestore(journal, record);
  }
  if ([verb isEqualToString:@"store"]) {
    return FLKeepElsewhere(journal, record);
  }
  return FLDiscard(journal, record, [arguments containsObject:@"--yes"]);
}
