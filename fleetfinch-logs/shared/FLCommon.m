#import "FLCommon.h"

#import <mach/mach_time.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>

NSString *const FLVersion = @"1.0.0";
NSString *const FLRootPath = @"/var/mobile/Library/FinchLogs";
NSString *const FLDaemonLabel = @"com.fleetfinch.logs.daemon";
NSString *const FLAppIdentifier = @"com.fleetfinch.logs";

NSString *const FLCommandSnapshot = @"com.fleetfinch.logs.snapshot";
NSString *const FLCommandImport = @"com.fleetfinch.logs.import";
NSString *const FLCommandMaintain = @"com.fleetfinch.logs.maintain";
NSString *const FLCommandSettings = @"com.fleetfinch.logs.settings";
NSString *const FLCommandWatch = @"com.fleetfinch.logs.watch";
NSString *const FLCommandUsage = @"com.fleetfinch.logs.usage";
NSString *const FLCommandInventory = @"com.fleetfinch.logs.inventory";
NSString *const FLCommandRestore = @"com.fleetfinch.logs.changes.restore";
NSString *const FLNoticeChanged = @"com.fleetfinch.logs.changed";
NSString *const FLNoticeUsage = @"com.fleetfinch.logs.usage.ready";
NSString *const FLNoticeInventory = @"com.fleetfinch.logs.inventory.ready";
NSString *const FLUsageState = @"usage";
NSString *const FLUsageReportState = @"usagereport";
NSString *const FLInventoryState = @"inventory";
NSString *const FLInstalledState = @"installed";
NSString *const FLDependenciesState = @"dependencies";
NSString *const FLTrafficState = @"traffic";
NSString *const FLLoadedState = @"loaded";
NSString *const FLTracedState = @"trace";
NSString *const FLTouchedState = @"touched";
NSString *const FLStartupState = @"startup";
NSString *const FLNoticeSleeping = @"com.fleetfinch.logs.sleeping";

NSString *FLLivePath(void) {
  return [FLRootPath stringByAppendingPathComponent:@"live"];
}

NSString *FLArchivePath(void) {
  return [FLRootPath stringByAppendingPathComponent:@"archive"];
}

NSString *FLStatePath(void) {
  return [FLRootPath stringByAppendingPathComponent:@"state"];
}

NSString *FLSettingsPath(void) {
  return [FLRootPath stringByAppendingPathComponent:@"settings.plist"];
}

static NSString *const FLLevelLetters = @"DINWEF";
static const NSUInteger FLCharacterBytes = 4;

NSString *FLLevelLetter(FLLevel level) {
  NSInteger index = MAX(0, MIN((NSInteger)FLLevelLetters.length - 1, level));
  return [FLLevelLetters substringWithRange:NSMakeRange((NSUInteger)index, 1)];
}

NSString *FLLevelName(FLLevel level) {
  switch (level) {
    case FLLevelDebug:
      return @"Debug";
    case FLLevelInfo:
      return @"Info";
    case FLLevelNotice:
      return @"Notice";
    case FLLevelWarning:
      return @"Warning";
    case FLLevelError:
      return @"Error";
    case FLLevelFault:
      return @"Fault";
  }
  return @"Notice";
}

FLLevel FLLevelFromLetter(NSString *letter) {
  NSRange range = letter.length == 1
    ? [FLLevelLetters rangeOfString:letter]
    : NSMakeRange(NSNotFound, 0);
  return range.location == NSNotFound ? FLLevelNotice : (FLLevel)range.location;
}

static void FLLocalTime(NSDate *date, struct tm *parts, int *millis) {
  NSTimeInterval interval = date.timeIntervalSince1970;
  time_t seconds = (time_t)floor(interval);
  *millis = (int)((interval - (NSTimeInterval)seconds) * 1000.0);
  if (*millis < 0) {
    *millis = 0;
  }
  if (*millis > 999) {
    *millis = 999;
  }
  localtime_r(&seconds, parts);
}

NSString *FLTimestamp(NSDate *date) {
  struct tm parts;
  int millis = 0;
  FLLocalTime(date, &parts, &millis);
  long offset = parts.tm_gmtoff;
  char sign = offset < 0 ? '-' : '+';
  long minutes = labs(offset) / 60;
  char text[40];
  snprintf(text, sizeof(text), "%04d-%02d-%02dT%02d:%02d:%02d.%03d%c%02ld:%02ld",
           parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour,
           parts.tm_min, parts.tm_sec, millis, sign, minutes / 60, minutes % 60);
  return @(text);
}

NSDate *FLDateFromTimestamp(NSString *text) {
  int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;
  int millis = 0, offsetHours = 0, offsetMinutes = 0;
  char sign = '+';
  int found = sscanf(text.UTF8String, "%4d-%2d-%2dT%2d:%2d:%2d.%3d%c%2d:%2d",
                     &year, &month, &day, &hour, &minute, &second, &millis,
                     &sign, &offsetHours, &offsetMinutes);
  if (found < 7) {
    return nil;
  }
  struct tm parts;
  memset(&parts, 0, sizeof(parts));
  parts.tm_year = year - 1900;
  parts.tm_mon = month - 1;
  parts.tm_mday = day;
  parts.tm_hour = hour;
  parts.tm_min = minute;
  parts.tm_sec = second;
  time_t seconds = timegm(&parts);
  long offset = (offsetHours * 60 + offsetMinutes) * 60;
  if (found >= 10) {
    seconds -= sign == '-' ? -offset : offset;
  }
  return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)seconds + millis / 1000.0];
}

NSString *FLHourKey(NSDate *date) {
  struct tm parts;
  int millis = 0;
  FLLocalTime(date, &parts, &millis);
  char text[24];
  snprintf(text, sizeof(text), "%04d-%02d-%02d_%02d", parts.tm_year + 1900,
           parts.tm_mon + 1, parts.tm_mday, parts.tm_hour);
  return @(text);
}

NSString *FLMomentKey(NSDate *date) {
  struct tm parts;
  int millis = 0;
  FLLocalTime(date, &parts, &millis);
  char text[32];
  snprintf(text, sizeof(text), "%04d-%02d-%02d_%02d%02d%02d", parts.tm_year + 1900,
           parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min,
           parts.tm_sec);
  return @(text);
}

static NSCharacterSet *FLSpecialCharacters(void) {
  static NSCharacterSet *set;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet *special = [NSMutableCharacterSet new];
    [special addCharactersInRange:NSMakeRange(0, 32)];
    [special addCharactersInRange:NSMakeRange(127, 1)];
    [special addCharactersInString:@"\\"];
    set = [special copy];
  });
  return set;
}

NSString *FLEscape(NSString *text) {
  if (text == nil) {
    return @"";
  }
  if ([text rangeOfCharacterFromSet:FLSpecialCharacters()].location == NSNotFound) {
    return text;
  }
  NSMutableString *escaped = [NSMutableString stringWithCapacity:text.length + 8];
  NSUInteger length = text.length;
  for (NSUInteger index = 0; index < length; index++) {
    unichar character = [text characterAtIndex:index];
    switch (character) {
      case '\\':
        [escaped appendString:@"\\\\"];
        break;
      case '\n':
        [escaped appendString:@"\\n"];
        break;
      case '\t':
        [escaped appendString:@"\\t"];
        break;
      case '\r':
        [escaped appendString:@"\\r"];
        break;
      default:
        if (character < 32 || character == 127) {
          [escaped appendFormat:@"\\x%02x", character];
        } else {
          [escaped appendFormat:@"%C", character];
        }
    }
  }
  return escaped;
}

NSString *FLUnescape(NSString *text) {
  if ([text rangeOfString:@"\\"].location == NSNotFound) {
    return text;
  }
  NSMutableString *plain = [NSMutableString stringWithCapacity:text.length];
  NSUInteger length = text.length;
  for (NSUInteger index = 0; index < length; index++) {
    unichar character = [text characterAtIndex:index];
    if (character != '\\' || index + 1 >= length) {
      [plain appendFormat:@"%C", character];
      continue;
    }
    unichar next = [text characterAtIndex:++index];
    if (next == 'n') {
      [plain appendString:@"\n"];
    } else if (next == 't') {
      [plain appendString:@"\t"];
    } else if (next == 'r') {
      [plain appendString:@"\r"];
    } else if (next == 'x' && index + 2 < length) {
      NSString *hex = [text substringWithRange:NSMakeRange(index + 1, 2)];
      unsigned value = 0;
      [[NSScanner scannerWithString:hex] scanHexInt:&value];
      [plain appendFormat:@"%C", (unichar)value];
      index += 2;
    } else {
      [plain appendFormat:@"%C", next];
    }
  }
  return plain;
}

NSString *FLFormatBytes(uint64_t bytes) {
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
  return [NSString stringWithFormat:(amount >= 100.0 ? @"%.0f %@" : @"%.1f %@"),
                                    amount, units[unit]];
}

NSString *FLFormatDuration(NSTimeInterval seconds) {
  if (seconds > 0 && seconds < 1) {
    return [NSString stringWithFormat:@"%ld ms", MAX(1L, lround(seconds * 1000.0))];
  }
  long total = (long)MAX(0.0, seconds);
  long days = total / 86400;
  long hours = (total % 86400) / 3600;
  long minutes = (total % 3600) / 60;
  if (days > 0) {
    return [NSString stringWithFormat:@"%ldd %ldh", days, hours];
  }
  if (hours > 0) {
    return [NSString stringWithFormat:@"%ldh %ldm", hours, minutes];
  }
  if (minutes > 0) {
    return [NSString stringWithFormat:@"%ldm %lds", minutes, total % 60];
  }
  return [NSString stringWithFormat:@"%lds", total];
}

NSString *FLFormatClock(NSDate *date) {
  struct tm parts;
  int millis = 0;
  FLLocalTime(date, &parts, &millis);
  char text[16];
  snprintf(text, sizeof(text), "%02d:%02d:%02d", parts.tm_hour, parts.tm_min,
           parts.tm_sec);
  return @(text);
}

NSString *FLFormatDay(NSDate *date) {
  struct tm parts;
  int millis = 0;
  FLLocalTime(date, &parts, &millis);
  char text[32];
  snprintf(text, sizeof(text), "%04d-%02d-%02d %02d:%02d:%02d", parts.tm_year + 1900,
           parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min,
           parts.tm_sec);
  return @(text);
}

NSString *FLStringFromData(NSData *data) {
  for (NSUInteger cut = 0; cut < FLCharacterBytes && cut < data.length; cut++) {
    NSString *text = [[NSString alloc] initWithBytes:data.bytes
                                              length:data.length - cut
                                            encoding:NSUTF8StringEncoding];
    if (text != nil) {
      return text;
    }
  }
  return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

BOOL FLMakeDirectory(NSString *path) {
  return [[NSFileManager defaultManager]
           createDirectoryAtPath:path
     withIntermediateDirectories:YES
                      attributes:@{
                        NSFilePosixPermissions : @0755,
                        NSFileProtectionKey : NSFileProtectionNone
                      }
                           error:NULL];
}

uint64_t FLFileSize(NSString *path) {
  struct stat info;
  if (stat(path.fileSystemRepresentation, &info) != 0) {
    return 0;
  }
  return (uint64_t)info.st_size;
}

NSDate *FLFileModified(NSString *path) {
  struct stat info;
  if (stat(path.fileSystemRepresentation, &info) != 0) {
    return nil;
  }
  return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.st_mtime];
}

FLFileTimes FLFileTimesAt(const char *path) {
  FLFileTimes times = {0, 0, 0, NO};
  struct stat info;
  if (path != NULL && stat(path, &info) == 0 && S_ISREG(info.st_mode)) {
    times.read = (long long)info.st_atimespec.tv_sec;
    times.written = (long long)info.st_mtimespec.tv_sec;
    times.node = (unsigned long long)info.st_ino;
    times.known = YES;
  }
  return times;
}

void FLPutBackAccessTime(const char *path, FLFileTimes before) {
  FLFileTimes now = FLFileTimesAt(path);
  if (!before.known || !now.known || now.node != before.node || now.written != before.written ||
      now.read == before.read) {
    return;
  }
  struct timeval times[2];
  times[0].tv_sec = (time_t)before.read;
  times[0].tv_usec = 0;
  times[1].tv_sec = (time_t)before.written;
  times[1].tv_usec = 0;
  utimes(path, times);
}

void FLKeepingAccessTime(NSString *path, void (^read)(void)) {
  const char *file = path.fileSystemRepresentation;
  FLFileTimes before = FLFileTimesAt(file);
  read();
  FLPutBackAccessTime(file, before);
}

double FLAwakeSeconds(void) {
  static mach_timebase_info_data_t base;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_timebase_info(&base);
  });
  return (double)mach_absolute_time() * base.numer / base.denom / NSEC_PER_SEC;
}
