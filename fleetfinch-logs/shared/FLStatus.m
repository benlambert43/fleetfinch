#import "FLStatus.h"

#import <notify.h>

#import "FLCommon.h"
#import "FLSystemInfo.h"

static const NSTimeInterval FLSameLaunch = 2;
static const uint64_t FLSleepHold = 10;

static NSString *FLStateFile(NSString *name) {
  return [[FLStatePath() stringByAppendingPathComponent:name]
    stringByAppendingPathExtension:@"plist"];
}

NSDictionary *FLReadState(NSString *name) {
  return [NSDictionary dictionaryWithContentsOfFile:FLStateFile(name)] ?: @{};
}

void FLWriteState(NSString *name, NSDictionary *state) {
  [state writeToFile:FLStateFile(name) atomically:YES];
}

BOOL FLWriteCompactState(NSString *name, NSDictionary *state) {
  NSData *data =
    [NSPropertyListSerialization dataWithPropertyList:state
                                               format:NSPropertyListBinaryFormat_v1_0
                                              options:0
                                                error:NULL];
  return data != nil && [data writeToFile:FLStateFile(name) atomically:YES];
}

NSDate *FLStateWritten(NSString *name) {
  return FLFileModified(FLStateFile(name));
}

NSDictionary *FLServiceStatus(void) {
  return FLReadState(@"status");
}

NSDictionary *FLServiceLive(void) {
  return FLReadState(@"live");
}

BOOL FLServiceRunning(NSDictionary *status) {
  NSNumber *pid = status[@"pid"];
  NSDate *launched = status[@"launched"];
  if (pid == nil || ![launched isKindOfClass:[NSDate class]]) {
    return NO;
  }
  FLProcess *process = FLProcessWithIdentifier(pid.intValue);
  return process != nil && [process.name isEqualToString:@"finchlog"] &&
         fabs([process.started timeIntervalSinceDate:launched]) < FLSameLaunch;
}

void FLPostCommand(NSString *name) {
  notify_post(name.UTF8String);
}

static int FLSleepingToken(void) {
  static int token = NOTIFY_TOKEN_INVALID;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (notify_register_check(FLNoticeSleeping.UTF8String, &token) != NOTIFY_STATUS_OK) {
      token = NOTIFY_TOKEN_INVALID;
    }
  });
  return token;
}

void FLMarkGoingToSleep(BOOL sleeping) {
  int token = FLSleepingToken();
  if (token != NOTIFY_TOKEN_INVALID) {
    notify_set_state(token, sleeping ? (uint64_t)time(NULL) : 0);
  }
}

BOOL FLGoingToSleep(void) {
  int token = FLSleepingToken();
  uint64_t since = 0;
  if (token == NOTIFY_TOKEN_INVALID || notify_get_state(token, &since) != NOTIFY_STATUS_OK ||
      since == 0) {
    return NO;
  }
  uint64_t now = (uint64_t)time(NULL);
  return now >= since && now - since < FLSleepHold;
}
