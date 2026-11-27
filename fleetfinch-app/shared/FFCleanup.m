#import "FFCleanup.h"

#import <notify.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <time.h>

NSString *const FFManifestPath = @"/Applications/FleetFinch.app/Cleanup.plist";
NSString *const FFStateFolder = @"/private/var/FleetFinch";
NSString *const FFRemovedFolder = @"/private/var/FleetFinch/Removed";
NSString *const FFBatchFolder = @"/private/var/FleetFinch/Batches";
NSString *const FFJournalPath = @"/private/var/FleetFinch/cleanup.plist";
NSString *const FFProgressPath = @"/private/var/FleetFinch/progress.plist";
NSString *const FFRequestFolder = @"/private/var/mobile/Library/FleetFinch/Requests";
NSString *const FFCleanupChanged = @"com.fleetfinch.app.cleanup.changed";
NSString *const FFVerbRemove = @"remove";
NSString *const FFVerbRestore = @"restore";

static const uint64_t FFBlockBytes = 512;

@implementation FFCleanupGroup

@end

@implementation FFCleanupCount

- (void)add:(FFCleanupCount *)other {
  self.present += other.present;
  self.removed += other.removed;
  self.absent += other.absent;
  self.presentBytes += other.presentBytes;
  self.removedBytes += other.removedBytes;
}

@end

static NSDictionary *FFManifest(void) {
  NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:FFManifestPath];
  return [manifest isKindOfClass:[NSDictionary class]] ? manifest : @{};
}

static NSArray<FFCleanupGroup *> *FFReadGroups(void) {
  NSMutableArray<FFCleanupGroup *> *groups = [NSMutableArray new];
  NSArray *listed = FFManifest()[@"groups"];
  for (NSDictionary *each in [listed isKindOfClass:[NSArray class]] ? listed : @[]) {
    NSArray *paths = each[@"paths"];
    if (![each isKindOfClass:[NSDictionary class]] || ![paths isKindOfClass:[NSArray class]] ||
        ![each[@"id"] isKindOfClass:[NSString class]]) {
      continue;
    }
    NSArray *models = each[@"models"];
    if ([models isKindOfClass:[NSArray class]] && ![models containsObject:FFDeviceModel()]) {
      continue;
    }
    NSMutableArray<NSString *> *kept = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSString *path in paths) {
      if ([path isKindOfClass:[NSString class]] && [path hasPrefix:@"/"] &&
          ![seen containsObject:path]) {
        [kept addObject:path];
        [seen addObject:path];
      }
    }
    FFCleanupGroup *group = [FFCleanupGroup new];
    group.identifier = each[@"id"];
    group.title = [each[@"title"] isKindOfClass:[NSString class]] ? each[@"title"] : each[@"id"];
    group.about = [each[@"about"] isKindOfClass:[NSString class]] ? each[@"about"] : @"";
    group.paths = kept;
    [groups addObject:group];
  }
  return groups;
}

NSArray<FFCleanupGroup *> *FFCleanupGroups(void) {
  static NSArray<FFCleanupGroup *> *groups;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    groups = FFReadGroups();
  });
  return groups;
}

NSArray<NSDictionary *> *FFCleanupTested(void) {
  NSArray *tested = FFManifest()[@"tested"];
  return [tested isKindOfClass:[NSArray class]] ? tested : @[];
}

NSString *FFKeptPath(NSString *path) {
  return [FFRemovedFolder stringByAppendingString:path];
}

FFItemState FFStateOfPath(NSString *path) {
  struct stat info;
  if (lstat(path.fileSystemRepresentation, &info) == 0) {
    return FFItemPresent;
  }
  return lstat(FFKeptPath(path).fileSystemRepresentation, &info) == 0 ? FFItemRemoved
                                                                       : FFItemAbsent;
}

uint64_t FFSpaceTaken(NSString *path, NSUInteger *entries, uint64_t *length) {
  struct stat info;
  if (lstat(path.fileSystemRepresentation, &info) != 0) {
    return 0;
  }
  uint64_t space = (uint64_t)info.st_blocks * FFBlockBytes;
  if (entries != NULL) {
    *entries += 1;
  }
  if (length != NULL && S_ISREG(info.st_mode)) {
    *length += (uint64_t)info.st_size;
  }
  if (!S_ISDIR(info.st_mode)) {
    return space;
  }
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *name in [manager contentsOfDirectoryAtPath:path error:NULL]) {
    @autoreleasepool {
      space += FFSpaceTaken([path stringByAppendingPathComponent:name], entries, length);
    }
  }
  return space;
}

FFCleanupCount *FFCountGroup(FFCleanupGroup *group, BOOL measure) {
  FFCleanupCount *count = [FFCleanupCount new];
  for (NSString *path in group.paths) {
    switch (FFStateOfPath(path)) {
      case FFItemPresent:
        count.present += 1;
        count.presentBytes += measure ? FFSpaceTaken(path, NULL, NULL) : 0;
        break;
      case FFItemRemoved:
        count.removed += 1;
        count.removedBytes += measure ? FFSpaceTaken(FFKeptPath(path), NULL, NULL) : 0;
        break;
      case FFItemAbsent:
        count.absent += 1;
        break;
    }
  }
  return count;
}

NSDictionary *FFReadJournal(void) {
  NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:FFJournalPath];
  return [journal isKindOfClass:[NSDictionary class]] ? journal : @{};
}

NSDictionary *FFReadProgress(void) {
  NSDictionary *progress = [NSDictionary dictionaryWithContentsOfFile:FFProgressPath];
  return [progress isKindOfClass:[NSDictionary class]] ? progress : @{};
}

NSString *FFSendRequest(NSString *verb, NSArray<NSString *> *groups) {
  NSFileManager *manager = [NSFileManager defaultManager];
  [manager createDirectoryAtPath:FFRequestFolder
     withIntermediateDirectories:YES
                      attributes:nil
                           error:NULL];
  NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"plist"];
  NSString *file = [FFRequestFolder stringByAppendingPathComponent:name];
  NSDictionary *request = @{@"verb" : verb, @"groups" : groups ?: @[], @"at" : [NSDate date]};
  return [request writeToFile:file atomically:YES] ? file : nil;
}

uint64_t FFRoomAt(NSString *path) {
  struct statfs volume;
  if (statfs(path.fileSystemRepresentation, &volume) != 0) {
    return 0;
  }
  return (uint64_t)volume.f_bavail * (uint64_t)volume.f_bsize;
}

NSString *FFFormatBytes(uint64_t bytes) {
  static NSString *const units[] = {@"bytes", @"KB", @"MB", @"GB", @"TB"};
  double amount = (double)bytes;
  int unit = 0;
  while (amount >= 1024.0 && unit < 4) {
    amount /= 1024.0;
    unit++;
  }
  if (unit == 0) {
    return [NSString stringWithFormat:@"%llu bytes", bytes];
  }
  return [NSString stringWithFormat:(amount >= 100.0 ? @"%.0f %@" : @"%.1f %@"), amount,
                                    units[unit]];
}

NSString *FFFormatDay(NSDate *date) {
  time_t seconds = (time_t)date.timeIntervalSince1970;
  struct tm parts;
  localtime_r(&seconds, &parts);
  char text[32];
  snprintf(text, sizeof(text), "%04d-%02d-%02d %02d:%02d", parts.tm_year + 1900,
           parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min);
  return @(text);
}

static NSString *FFSystemString(const char *name) {
  char value[128];
  size_t size = sizeof(value);
  if (sysctlbyname(name, value, &size, NULL, 0) != 0 || size == 0) {
    return @"";
  }
  value[sizeof(value) - 1] = '\0';
  return @(value);
}

NSString *FFDeviceModel(void) {
  return FFSystemString("hw.machine");
}

NSString *FFHardwareValue(NSString *key) {
  return FFSystemString([@"hw." stringByAppendingString:key].UTF8String);
}

NSString *FFSystemVersion(void) {
  NSDictionary *version = [NSDictionary
    dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
  NSString *product = version[@"ProductVersion"];
  return [product isKindOfClass:[NSString class]] ? product : @"";
}

BOOL FFDeviceIsTested(void) {
  NSString *model = FFDeviceModel();
  NSString *system = FFSystemVersion();
  for (NSDictionary *each in FFCleanupTested()) {
    if ([each isKindOfClass:[NSDictionary class]] && [each[@"model"] isEqual:model] &&
        [each[@"system"] isEqual:system]) {
      return YES;
    }
  }
  return NO;
}
