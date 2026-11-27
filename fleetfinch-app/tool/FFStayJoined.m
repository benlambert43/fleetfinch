#import "FFStayJoined.h"

#import <CoreFoundation/CoreFoundation.h>
#import <unistd.h>

#import "FFHealth.h"

typedef struct __WiFiManagerClient *WiFiManagerClientRef;
typedef void (*FFWiFiRestarted)(WiFiManagerClientRef client, void *info);

extern WiFiManagerClientRef WiFiManagerClientCreate(CFAllocatorRef allocator, int type);
extern void WiFiManagerClientScheduleWithRunLoop(WiFiManagerClientRef client, CFRunLoopRef loop,
                                                 CFStringRef mode);
extern void WiFiManagerClientRegisterServerRestartCallback(WiFiManagerClientRef client,
                                                           FFWiFiRestarted callback, void *info);
extern int WiFiManagerClientSetWoWState(WiFiManagerClientRef client, Boolean state);
extern Boolean WiFiManagerClientGetWoWState(WiFiManagerClientRef client);
extern void xpc_transaction_begin(void);

NSString *const FFStayJoinedService = @"com.fleetfinch.app.reach";

static const CFTimeInterval FFLookFirst = 20;
static const CFTimeInterval FFLookEvery = 300;
static const uint32_t FFJoinedMemoryMegabytes = 8;

static WiFiManagerClientRef FFJoinedClient;

static void FFAskToStayJoined(void) {
  WiFiManagerClientSetWoWState(FFJoinedClient, true);
}

static void FFWiFiCameBack(WiFiManagerClientRef client, void *info) {
  FFAskToStayJoined();
}

static void FFLookAgain(CFRunLoopTimerRef timer, void *info) {
  if (!WiFiManagerClientGetWoWState(FFJoinedClient)) {
    FFAskToStayJoined();
  }
}

BOOL FFWiFiStaysJoinedAsleep(void) {
  WiFiManagerClientRef client = WiFiManagerClientCreate(kCFAllocatorDefault, 0);
  if (client == NULL) {
    return NO;
  }
  BOOL stays = WiFiManagerClientGetWoWState(client);
  CFRelease(client);
  return stays;
}

int FFKeepReachable(void) {
  if (getuid() != 0) {
    fprintf(stderr, "fleetfinch: only root may ask Wi-Fi to stay joined\n");
    return 1;
  }
  xpc_transaction_begin();
  FFKeepInMemory(FFJoinedMemoryMegabytes);
  FFJoinedClient = WiFiManagerClientCreate(kCFAllocatorDefault, 0);
  if (FFJoinedClient == NULL) {
    fprintf(stderr, "fleetfinch: the Wi-Fi service did not answer\n");
    return 1;
  }
  WiFiManagerClientScheduleWithRunLoop(FFJoinedClient, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
  WiFiManagerClientRegisterServerRestartCallback(FFJoinedClient, FFWiFiCameBack, NULL);
  FFAskToStayJoined();
  CFRunLoopTimerRef timer =
    CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + FFLookFirst,
                         FFLookEvery, 0, 0, FFLookAgain, NULL);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
  CFRunLoopRun();
  return 0;
}
