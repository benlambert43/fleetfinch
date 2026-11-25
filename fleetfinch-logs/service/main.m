#import <Foundation/Foundation.h>
#import <sys/utsname.h>

#import "FLCollect.h"
#import "FLCommon.h"
#import "FLDaemon.h"
#import "FLDump.h"
#import "FLReader.h"
#import "FLSettings.h"
#import "FLStatus.h"
#import "FLStore.h"
#import "FLSystemInfo.h"

static NSString *const FLTrailer = @"@@finchlog";
static const NSTimeInterval FLFollowReport = 10;

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

static int FLRunCollect(NSArray<NSString *> *arguments) {
  NSString *kind = arguments.count > 0 ? arguments[0] : nil;
  if (kind == nil || [kind isEqualToString:@"list"]) {
    for (NSString *name in FLCollectKinds()) {
      FLPrint([NSString stringWithFormat:@"%@\t%@\n", name, FLCollectTitle(name)]);
    }
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
