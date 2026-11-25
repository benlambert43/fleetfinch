#import "FLMonitors.h"

#import <stdarg.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <time.h>
#import <unistd.h>

#import "FLStore.h"

static NSString *const FLSyslogSocket = @"/var/run/lockdown/syslog.sock";
static NSString *const FLSyslogState = @"syslog";
static const NSUInteger FLRecentLimit = 300;
static const NSTimeInterval FLSaveEvery = 20;
static const NSUInteger FLBufferLimit = 1024 * 1024;
static const NSTimeInterval FLReplayLimit = 300;

void FLNote(NSString *stream, FLLevel level, NSString *source, NSString *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  [[FLStore shared] log:stream level:level source:source message:message];
}

static FLLevel FLLevelFromSyslog(NSString *name) {
  static NSDictionary *levels;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    levels = @{
      @"Emergency" : @(FLLevelFault),
      @"Alert" : @(FLLevelFault),
      @"Critical" : @(FLLevelFault),
      @"Error" : @(FLLevelError),
      @"Warning" : @(FLLevelWarning),
      @"Notice" : @(FLLevelNotice),
      @"Info" : @(FLLevelInfo),
      @"Debug" : @(FLLevelDebug),
    };
  });
  NSNumber *level = levels[name];
  return level == nil ? FLLevelNotice : (FLLevel)level.integerValue;
}

static NSDate *FLDateFromSyslog(NSString *stamp, NSDate *now) {
  static NSArray *months;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    months = @[
      @"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun", @"Jul", @"Aug", @"Sep", @"Oct",
      @"Nov", @"Dec"
    ];
  });
  if (stamp.length < 15) {
    return nil;
  }
  NSUInteger month = [months indexOfObject:[stamp substringToIndex:3]];
  int day = 0, hour = 0, minute = 0, second = 0;
  if (month == NSNotFound ||
      sscanf([stamp substringFromIndex:4].UTF8String, "%d %d:%d:%d", &day, &hour,
             &minute, &second) != 4) {
    return nil;
  }
  time_t current = (time_t)now.timeIntervalSince1970;
  struct tm parts;
  localtime_r(&current, &parts);
  parts.tm_mon = (int)month;
  parts.tm_mday = day;
  parts.tm_hour = hour;
  parts.tm_min = minute;
  parts.tm_sec = second;
  parts.tm_isdst = -1;
  time_t moment = mktime(&parts);
  if (moment > current + 24 * 60 * 60) {
    parts.tm_year -= 1;
    parts.tm_isdst = -1;
    moment = mktime(&parts);
  }
  return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)moment];
}

@implementation FLSyslogMonitor {
  dispatch_queue_t _queue;
  NSMutableOrderedSet<NSNumber *> *_recent;
  BOOL _stopped;
  BOOL _dirty;
  NSDate *_saved;
  time_t _newest;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.fleetfinch.logs.syslog", DISPATCH_QUEUE_SERIAL);
    _recent = [NSMutableOrderedSet new];
    NSDictionary *state = FLReadState(FLSyslogState);
    NSArray *saved = state[@"recent"];
    if ([saved isKindOfClass:[NSArray class]]) {
      [_recent addObjectsFromArray:saved];
    }
    _newest = (time_t)[state[@"newest"] longLongValue];
    _saved = [NSDate date];
  }
  return self;
}

- (void)start {
  dispatch_async(_queue, ^{
    [self run];
  });
}

- (void)stop {
  _stopped = YES;
  [self save];
}

- (void)save {
  @synchronized(self) {
    if (_dirty) {
      FLWriteState(FLSyslogState,
                   @{@"recent" : _recent.array, @"newest" : @((long long)_newest)});
      _dirty = NO;
    }
    _saved = [NSDate date];
  }
}

- (int)open {
  int handle = socket(AF_UNIX, SOCK_STREAM, 0);
  if (handle < 0) {
    return -1;
  }
  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  strlcpy(address.sun_path, FLSyslogSocket.fileSystemRepresentation,
          sizeof(address.sun_path));
  if (connect(handle, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(handle);
    return -1;
  }
  return handle;
}

- (void)run {
  NSUInteger failures = 0;
  while (!_stopped) {
    int handle = [self open];
    if (handle < 0) {
      if (failures == 0) {
        FLNote(@"finchlogs", FLLevelWarning, @"syslog",
               @"The system log at %@ could not be opened; trying again", FLSyslogSocket);
      }
      failures++;
      sleep((unsigned)MIN(60, 5 * failures));
      continue;
    }
    BOOL streamed = [self pump:handle];
    close(handle);
    _connected = NO;
    if (_stopped) {
      break;
    }
    failures = streamed ? 0 : failures + 1;
    FLNote(@"finchlogs", FLLevelWarning, @"syslog",
           @"The system log closed its connection; reconnecting");
    sleep((unsigned)MIN(60, 2 + 5 * failures));
  }
  [self save];
}

- (BOOL)pump:(int)handle {
  usleep(300 * 1000);
  const char *command = "watch\n";
  if (write(handle, command, strlen(command)) < 0) {
    return NO;
  }
  NSMutableData *pending = [NSMutableData new];
  BOOL started = NO;
  BOOL replaying = YES;
  NSDate *opened = [NSDate date];
  time_t openedAt = (time_t)opened.timeIntervalSince1970;
  uint8_t buffer[16 * 1024];
  while (!_stopped) {
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(handle, &readable);
    struct timeval wait = {2, 0};
    int ready = select(handle + 1, &readable, NULL, NULL, &wait);
    if (-_saved.timeIntervalSinceNow > FLSaveEvery) {
      [self save];
    }
    if (ready < 0) {
      return started;
    }
    if (ready == 0) {
      continue;
    }
    ssize_t count = read(handle, buffer, sizeof(buffer));
    if (count <= 0) {
      return started;
    }
    [pending appendBytes:buffer length:(NSUInteger)count];
    if (!started) {
      NSData *marker = [NSData dataWithBytes:"OK\n" length:3];
      NSRange found = [pending rangeOfData:marker
                                   options:0
                                     range:NSMakeRange(0, pending.length)];
      if (found.location == NSNotFound) {
        if (pending.length > 8 * 1024) {
          return NO;
        }
        continue;
      }
      [pending replaceBytesInRange:NSMakeRange(0, NSMaxRange(found))
                         withBytes:NULL
                            length:0];
      started = YES;
      _connected = YES;
      FLNote(@"finchlogs", FLLevelInfo, @"syslog", @"Reading the system log");
    }
    replaying = replaying && -opened.timeIntervalSinceNow < FLReplayLimit;
    for (;;) {
      const uint8_t *bytes = pending.bytes;
      const uint8_t *end = memchr(bytes, 0, pending.length);
      if (end == NULL) {
        break;
      }
      NSUInteger length = (NSUInteger)(end - bytes);
      NSData *record = [NSData dataWithBytes:bytes length:length];
      [pending replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
      replaying = [self take:record replaying:replaying openedAt:openedAt];
    }
    if (pending.length > FLBufferLimit) {
      replaying = [self take:[pending copy] replaying:replaying openedAt:openedAt];
      pending.length = 0;
    }
  }
  return started;
}

- (BOOL)take:(NSData *)data replaying:(BOOL)replaying openedAt:(time_t)openedAt {
  NSString *text = FLStringFromData(data);
  text = [text stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  if (text.length == 0) {
    return replaying;
  }
  NSNumber *print = @(text.hash);
  NSDate *now = [NSDate date];
  NSDate *stamped = FLDateFromSyslog(text, now);
  time_t moment = stamped == nil ? 0 : (time_t)stamped.timeIntervalSince1970;
  BOOL backlog = replaying && moment <= openedAt;
  @synchronized(self) {
    if (backlog) {
      if (moment != 0 && moment < _newest) {
        return YES;
      }
      if ([_recent containsObject:print]) {
        return YES;
      }
    }
    [_recent addObject:print];
    if (_recent.count > FLRecentLimit) {
      [_recent removeObjectsInRange:NSMakeRange(0, _recent.count - FLRecentLimit)];
    }
    if (moment > _newest) {
      _newest = moment;
    }
    _dirty = YES;
    _received++;
  }

  NSRange close = text.length > 16
    ? [text rangeOfString:@">: " options:0 range:NSMakeRange(16, text.length - 16)]
    : NSMakeRange(NSNotFound, 0);
  NSRange open = close.location == NSNotFound
    ? close
    : [text rangeOfString:@" <"
                  options:NSBackwardsSearch
                    range:NSMakeRange(16, close.location - 16)];
  if (stamped == nil || open.location == NSNotFound) {
    [[FLStore shared] log:@"system" level:FLLevelNotice source:@"syslog" message:text];
    return backlog;
  }
  NSString *level = [text substringWithRange:NSMakeRange(NSMaxRange(open),
                                                         close.location - NSMaxRange(open))];
  NSString *prefix = [text substringWithRange:NSMakeRange(16, open.location - 16)];
  NSString *message = [text substringFromIndex:NSMaxRange(close)];
  NSRange space = [prefix rangeOfString:@" "];
  NSString *sender = space.location == NSNotFound
    ? prefix
    : [prefix substringFromIndex:NSMaxRange(space)];
  NSRange extra = [sender rangeOfString:@" ("];
  if (extra.location != NSNotFound) {
    message = [NSString stringWithFormat:@"%@ %@",
                                         [sender substringFromIndex:extra.location + 1],
                                         message];
    sender = [sender substringToIndex:extra.location];
  }
  BOOL old = fabs([stamped timeIntervalSinceDate:now]) > 2.0;
  [[FLStore shared] log:@"system"
                  level:FLLevelFromSyslog(level)
                 source:sender
                message:message
                   date:old ? stamped : now];
  return backlog;
}

@end
