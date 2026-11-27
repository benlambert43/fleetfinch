#import "FFHealth.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <mach/mach.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/resource.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <unistd.h>

extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int size);
extern int proc_pidpath(int pid, void *buffer, uint32_t size);
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer,
                                size_t size);

NSString *const FFReachHome = @"springboard";
NSString *const FFReachShell = @"ssh";
NSString *const FFReachNetwork = @"network";
NSString *const FFReachCalm = @"calm";
NSString *const FFReachSteady = @"steady";

static NSString *const FFHomeScreen = @"/System/Library/CoreServices/SpringBoard.app";
static const uint32_t FFAllProcesses = 1;
static const size_t FFPathLimit = 4096;
static const uint16_t FFShellPort = 22;
static const long FFShellSeconds = 10;
static const size_t FFBannerBytes = 4;
static const unsigned FFCalmSeconds = 5;
static const NSTimeInterval FFSteadySeconds = 150;
static NSString *const FFReportFolder = @"/private/var/mobile/Library/Logs/CrashReporter";
static NSString *const FFWatchdogReport = @"stacks+backboardd";
static const double FFCalmBelow = 0.9;
static const int FFTopNiceness = -20;
static const integer_t FFTopImportance = 32;
static const int32_t FFMemoryPriority = 18;
static const uint32_t FFSetMemoryPriority = 2;
static const uint32_t FFSetHighWaterMark = 5;

NSArray<NSNumber *> *FFProcessesUnder(NSString *path) {
  NSMutableArray<NSNumber *> *found = [NSMutableArray new];
  int wanted = proc_listpids(FFAllProcesses, 0, NULL, 0);
  if (wanted <= 0) {
    return found;
  }
  int size = wanted + (int)(64 * sizeof(pid_t));
  pid_t *pids = malloc((size_t)size);
  int filled = proc_listpids(FFAllProcesses, 0, pids, size);
  NSString *prefix = [path stringByAppendingString:@"/"];
  char *buffer = malloc(FFPathLimit);
  for (int index = 0; index < filled / (int)sizeof(pid_t); index++) {
    if (pids[index] <= 0 || proc_pidpath(pids[index], buffer, (uint32_t)FFPathLimit) <= 0) {
      continue;
    }
    NSString *program = @(buffer);
    if ([program isEqualToString:path] || [program hasPrefix:prefix]) {
      [found addObject:@(pids[index])];
    }
  }
  free(buffer);
  free(pids);
  return found;
}

static BOOL FFShellAnswers(void) {
  int handle = socket(AF_INET, SOCK_STREAM, 0);
  if (handle < 0) {
    return NO;
  }
  struct timeval limit = {FFShellSeconds, 0};
  setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
  setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_len = sizeof(address);
  address.sin_family = AF_INET;
  address.sin_port = htons(FFShellPort);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  char banner[FFBannerBytes];
  BOOL answered = connect(handle, (struct sockaddr *)&address, sizeof(address)) == 0 &&
                  recv(handle, banner, FFBannerBytes, MSG_WAITALL) == (ssize_t)FFBannerBytes &&
                  memcmp(banner, "SSH-", FFBannerBytes) == 0;
  close(handle);
  return answered;
}

static BOOL FFHasAddress(void) {
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) != 0) {
    return NO;
  }
  BOOL found = NO;
  for (struct ifaddrs *each = list; each != NULL && !found; each = each->ifa_next) {
    if (each->ifa_addr == NULL || each->ifa_addr->sa_family != AF_INET ||
        (each->ifa_flags & IFF_LOOPBACK) != 0 || (each->ifa_flags & IFF_UP) == 0) {
      continue;
    }
    uint32_t address = ntohl(((struct sockaddr_in *)each->ifa_addr)->sin_addr.s_addr);
    found = address != 0 && (address >> 16) != 0xA9FE;
  }
  freeifaddrs(list);
  return found;
}

static BOOL FFProcessorTicks(uint64_t *busy, uint64_t *all) {
  host_cpu_load_info_data_t load;
  mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) !=
      KERN_SUCCESS) {
    return NO;
  }
  *busy = (uint64_t)load.cpu_ticks[CPU_STATE_USER] + load.cpu_ticks[CPU_STATE_SYSTEM] +
          load.cpu_ticks[CPU_STATE_NICE];
  *all = *busy + load.cpu_ticks[CPU_STATE_IDLE];
  return YES;
}

double FFBusyShare(unsigned seconds) {
  uint64_t busyBefore = 0, allBefore = 0, busyAfter = 0, allAfter = 0;
  if (!FFProcessorTicks(&busyBefore, &allBefore)) {
    return 0;
  }
  sleep(seconds);
  if (!FFProcessorTicks(&busyAfter, &allAfter) || allAfter <= allBefore) {
    return 0;
  }
  return (double)(busyAfter - busyBefore) / (double)(allAfter - allBefore);
}

void FFRunAboveOthers(void) {
  setpriority(PRIO_PROCESS, 0, FFTopNiceness);
  thread_extended_policy_data_t steady = {.timeshare = FALSE};
  thread_policy_set(mach_thread_self(), THREAD_EXTENDED_POLICY, (thread_policy_t)&steady,
                    THREAD_EXTENDED_POLICY_COUNT);
  thread_precedence_policy_data_t above = {.importance = FFTopImportance};
  thread_policy_set(mach_thread_self(), THREAD_PRECEDENCE_POLICY, (thread_policy_t)&above,
                    THREAD_PRECEDENCE_POLICY_COUNT);
}

void FFKeepInMemory(uint32_t megabytes) {
  struct {
    int32_t priority;
    uint64_t data;
  } properties = {FFMemoryPriority, 0};
  memorystatus_control(FFSetMemoryPriority, getpid(), 0, &properties, sizeof(properties));
  memorystatus_control(FFSetHighWaterMark, getpid(), megabytes, NULL, 0);
}

static NSTimeInterval FFAgeOfProcess(int pid) {
  int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc entry;
  size_t size = sizeof(entry);
  if (sysctl(name, 4, &entry, &size, NULL, 0) != 0 || size < sizeof(entry)) {
    return 0;
  }
  struct timeval started = entry.kp_proc.p_starttime;
  return [NSDate date].timeIntervalSince1970 - ((NSTimeInterval)started.tv_sec + started.tv_usec / 1e6);
}

static BOOL FFWatchdogFired(void) {
  NSDate *boot = FFBootTime();
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *name in [manager contentsOfDirectoryAtPath:FFReportFolder error:NULL]) {
    NSString *file = [FFReportFolder stringByAppendingPathComponent:name];
    NSDate *written = [manager attributesOfItemAtPath:file error:NULL].fileModificationDate;
    if ([name hasPrefix:FFWatchdogReport] && boot != nil && written != nil &&
        [written compare:boot] == NSOrderedDescending) {
      return YES;
    }
  }
  return NO;
}

NSDictionary<NSString *, NSNumber *> *FFReach(void) {
  NSString *program = [FFHomeScreen stringByAppendingPathComponent:@"SpringBoard"];
  NSArray<NSNumber *> *home = FFProcessesUnder(program);
  BOOL steady = home.count > 0 && FFAgeOfProcess(home.firstObject.intValue) >= FFSteadySeconds &&
                !FFWatchdogFired();
  return @{
    FFReachHome : @(home.count > 0),
    FFReachSteady : @(steady),
    FFReachShell : @(FFShellAnswers()),
    FFReachNetwork : @(FFHasAddress()),
    FFReachCalm : @(FFBusyShare(FFCalmSeconds) < FFCalmBelow),
  };
}

NSString *FFReachMissing(NSDictionary *before, NSDictionary *now) {
  if ([before[FFReachHome] boolValue] && ![now[FFReachHome] boolValue]) {
    return @"the Home screen was not running";
  }
  if ([before[FFReachSteady] boolValue] && ![now[FFReachSteady] boolValue]) {
    return @"the Home screen had not stayed up (the watchdog of iOS restarts it when a service "
           @"it waits for does not answer)";
  }
  if ([before[FFReachNetwork] boolValue] && ![now[FFReachNetwork] boolValue]) {
    return @"the device had no network address";
  }
  if ([before[FFReachShell] boolValue] && ![now[FFReachShell] boolValue]) {
    return @"the device did not answer on its SSH port";
  }
  if ([before[FFReachCalm] boolValue] && ![now[FFReachCalm] boolValue]) {
    return @"the device's processors were still full";
  }
  return nil;
}

NSString *FFReachSentence(NSDictionary *reach) {
  NSString *home = ![reach[FFReachHome] boolValue]
    ? @"not running"
    : ([reach[FFReachSteady] boolValue] ? @"running and steady" : @"running, started lately");
  return [NSString stringWithFormat:@"Home screen %@, network address %@, SSH %@, processors %@",
                                    home,
                                    [reach[FFReachNetwork] boolValue] ? @"present" : @"missing",
                                    [reach[FFReachShell] boolValue] ? @"answering"
                                                                    : @"not answering",
                                    [reach[FFReachCalm] boolValue] ? @"calm" : @"full"];
}

NSDate *FFBootTime(void) {
  struct timeval boot;
  size_t size = sizeof(boot);
  int name[2] = {CTL_KERN, KERN_BOOTTIME};
  if (sysctl(name, 2, &boot, &size, NULL, 0) != 0 || boot.tv_sec == 0) {
    return nil;
  }
  return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)boot.tv_sec + boot.tv_usec / 1e6];
}
