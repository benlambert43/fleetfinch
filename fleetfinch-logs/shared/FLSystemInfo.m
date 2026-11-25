#import "FLSystemInfo.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <netinet/in.h>
#import <pwd.h>
#import <sys/mount.h>
#import <sys/resource.h>
#import <sys/socket.h>
#import <sys/sysctl.h>

#import <IOKit/IOKitLib.h>
#import <SystemConfiguration/CaptiveNetwork.h>

#import "FLCommon.h"

#define FL_PROC_PIDTASKINFO 4
#define FL_PATH_LIMIT 4096
#define FL_RTM_IFINFO2 0x12

struct fl_proc_taskinfo {
  uint64_t pti_virtual_size;
  uint64_t pti_resident_size;
  uint64_t pti_total_user;
  uint64_t pti_total_system;
  uint64_t pti_threads_user;
  uint64_t pti_threads_system;
  int32_t pti_policy;
  int32_t pti_faults;
  int32_t pti_pageins;
  int32_t pti_cow_faults;
  int32_t pti_messages_sent;
  int32_t pti_messages_received;
  int32_t pti_syscalls_mach;
  int32_t pti_syscalls_unix;
  int32_t pti_csw;
  int32_t pti_threadnum;
  int32_t pti_numrunning;
  int32_t pti_priority;
};

extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int size);
extern int proc_pidpath(int pid, void *buffer, uint32_t size);
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

static double FLSecondsFromAbsolute(uint64_t absolute) {
  static mach_timebase_info_data_t timebase;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_timebase_info(&timebase);
  });
  if (timebase.denom == 0) {
    return 0;
  }
  return (double)absolute * (double)timebase.numer / (double)timebase.denom / 1e9;
}

@implementation FLProcess

- (NSString *)identity {
  return [NSString stringWithFormat:@"%d:%.0f", self.pid,
                                    self.started.timeIntervalSince1970];
}

- (NSString *)appBundlePath {
  if (self.path.length == 0) {
    return nil;
  }
  NSRange marker = [self.path rangeOfString:@".app/"];
  if (marker.location == NSNotFound) {
    return nil;
  }
  if (![self.path containsString:@"/Applications/"] &&
      ![self.path containsString:@"/Bundle/Application/"]) {
    return nil;
  }
  NSString *rest = [self.path substringFromIndex:NSMaxRange(marker)];
  if ([rest containsString:@"/"]) {
    return nil;
  }
  return [self.path substringToIndex:marker.location + 4];
}

- (NSString *)displayName {
  NSString *bundle = [self appBundlePath];
  if (bundle != nil) {
    NSString *name = FLBundleInfo(bundle)[@"name"];
    if (name.length > 0) {
      return name;
    }
  }
  if (self.path.length > 0) {
    return self.path.lastPathComponent;
  }
  return self.name ?: @"";
}

- (NSString *)commandLine {
  if (self.arguments.count > 0) {
    return [self.arguments componentsJoinedByString:@" "];
  }
  return self.path.length > 0 ? self.path : (self.name ?: @"");
}

@end

@implementation FLVolume
@end

@implementation FLInterface

- (instancetype)init {
  self = [super init];
  if (self) {
    _addresses = [NSMutableArray new];
  }
  return self;
}

- (BOOL)isUp {
  return (self.flags & IFF_UP) != 0 && (self.flags & IFF_RUNNING) != 0;
}

- (BOOL)isLoopback {
  return (self.flags & IFF_LOOPBACK) != 0;
}

@end

NSString *FLSysctlString(NSString *name) {
  size_t size = 0;
  if (sysctlbyname(name.UTF8String, NULL, &size, NULL, 0) != 0 || size == 0) {
    return nil;
  }
  char *buffer = calloc(1, size + 1);
  NSString *text = nil;
  if (sysctlbyname(name.UTF8String, buffer, &size, NULL, 0) == 0) {
    text = [NSString stringWithUTF8String:buffer];
  }
  free(buffer);
  return text;
}

BOOL FLSysctlNumber(NSString *name, int64_t *value) {
  uint8_t buffer[8] = {0};
  size_t size = sizeof(buffer);
  if (sysctlbyname(name.UTF8String, buffer, &size, NULL, 0) != 0) {
    return NO;
  }
  if (size == sizeof(int32_t)) {
    int32_t small = 0;
    memcpy(&small, buffer, sizeof(small));
    *value = small;
    return YES;
  }
  if (size == sizeof(int64_t)) {
    memcpy(value, buffer, sizeof(int64_t));
    return YES;
  }
  return NO;
}

NSDate *FLBootTime(void) {
  struct timeval boot;
  size_t size = sizeof(boot);
  int mib[2] = {CTL_KERN, KERN_BOOTTIME};
  if (sysctl(mib, 2, &boot, &size, NULL, 0) != 0 || boot.tv_sec == 0) {
    return nil;
  }
  return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)boot.tv_sec +
                                               boot.tv_usec / 1e6];
}

NSTimeInterval FLUptime(void) {
  NSDate *boot = FLBootTime();
  return boot == nil ? 0 : -boot.timeIntervalSinceNow;
}

NSString *FLUserName(unsigned user) {
  static NSMutableDictionary *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = [NSMutableDictionary new];
  });
  @synchronized(names) {
    NSString *known = names[@(user)];
    if (known != nil) {
      return known;
    }
    struct passwd *entry = getpwuid((uid_t)user);
    NSString *name = entry != NULL && entry->pw_name != NULL
      ? @(entry->pw_name)
      : [NSString stringWithFormat:@"%u", user];
    names[@(user)] = name;
    return name;
  }
}

static NSArray<NSString *> *FLProcessArguments(int pid) {
  int limit = 0;
  size_t limitSize = sizeof(limit);
  int limitName[2] = {CTL_KERN, KERN_ARGMAX};
  if (sysctl(limitName, 2, &limit, &limitSize, NULL, 0) != 0 || limit <= 0) {
    return nil;
  }
  char *buffer = malloc((size_t)limit);
  size_t size = (size_t)limit;
  int name[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  if (sysctl(name, 3, buffer, &size, NULL, 0) != 0 || size < sizeof(int)) {
    free(buffer);
    return nil;
  }
  int count = 0;
  memcpy(&count, buffer, sizeof(count));
  char *cursor = buffer + sizeof(int);
  char *end = buffer + size;
  while (cursor < end && *cursor != '\0') {
    cursor++;
  }
  while (cursor < end && *cursor == '\0') {
    cursor++;
  }
  NSMutableArray *arguments = [NSMutableArray new];
  while (cursor < end && (int)arguments.count < count) {
    size_t length = strnlen(cursor, (size_t)(end - cursor));
    NSData *data = [NSData dataWithBytes:cursor length:length];
    [arguments addObject:FLStringFromData(data)];
    cursor += length + 1;
  }
  free(buffer);
  return arguments;
}

static void FLFillProcess(FLProcess *process) {
  char path[FL_PATH_LIMIT];
  int length = proc_pidpath(process.pid, path, sizeof(path));
  if (length > 0) {
    process.path = [[NSString alloc] initWithBytes:path
                                            length:(NSUInteger)length
                                          encoding:NSUTF8StringEncoding];
  }
  struct fl_proc_taskinfo task;
  int filled = proc_pidinfo(process.pid, FL_PROC_PIDTASKINFO, 0, &task, sizeof(task));
  if (filled == (int)sizeof(task)) {
    process.detailed = YES;
    process.residentBytes = task.pti_resident_size;
    process.virtualBytes = task.pti_virtual_size;
    process.processorSeconds =
      FLSecondsFromAbsolute(task.pti_total_user + task.pti_total_system);
    process.threads = task.pti_threadnum;
    process.faults = task.pti_faults;
    process.pageIns = task.pti_pageins;
  }
  struct rusage_info_v2 usage;
  if (proc_pid_rusage(process.pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) {
    process.footprintBytes = usage.ri_phys_footprint;
    process.readBytes = usage.ri_diskio_bytesread;
    process.writtenBytes = usage.ri_diskio_byteswritten;
    process.wakeups = usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups;
  }
  process.arguments = FLProcessArguments(process.pid);
}

static FLProcess *FLProcessFromEntry(const struct kinfo_proc *entry, BOOL detailed) {
  FLProcess *process = [FLProcess new];
  process.pid = entry->kp_proc.p_pid;
  process.parent = entry->kp_eproc.e_ppid;
  process.user = entry->kp_eproc.e_ucred.cr_uid;
  process.name = [NSString stringWithUTF8String:entry->kp_proc.p_comm] ?: @"";
  struct timeval started = entry->kp_proc.p_starttime;
  process.started = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)started.tv_sec +
                                                          started.tv_usec / 1e6];
  if (detailed) {
    FLFillProcess(process);
  }
  return process;
}

NSArray<FLProcess *> *FLProcessList(BOOL detailed) {
  int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  if (sysctl(name, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
    return @[];
  }
  size += size / 4 + sizeof(struct kinfo_proc) * 16;
  struct kinfo_proc *entries = malloc(size);
  if (sysctl(name, 4, entries, &size, NULL, 0) != 0) {
    free(entries);
    return @[];
  }
  NSUInteger count = size / sizeof(struct kinfo_proc);
  NSMutableArray *processes = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    if (entries[index].kp_proc.p_pid == 0) {
      continue;
    }
    @autoreleasepool {
      [processes addObject:FLProcessFromEntry(&entries[index], detailed)];
    }
  }
  free(entries);
  return processes;
}

FLProcess *FLProcessWithIdentifier(int pid) {
  int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc entry;
  size_t size = sizeof(entry);
  if (sysctl(name, 4, &entry, &size, NULL, 0) != 0 || size < sizeof(entry)) {
    return nil;
  }
  return FLProcessFromEntry(&entry, YES);
}

NSDictionary<NSString *, NSNumber *> *FLProcessorTicks(void) {
  host_cpu_load_info_data_t load;
  mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load,
                      &count) != KERN_SUCCESS) {
    return @{};
  }
  return @{
    @"user" : @(load.cpu_ticks[CPU_STATE_USER]),
    @"system" : @(load.cpu_ticks[CPU_STATE_SYSTEM]),
    @"idle" : @(load.cpu_ticks[CPU_STATE_IDLE]),
    @"nice" : @(load.cpu_ticks[CPU_STATE_NICE]),
  };
}

NSArray<NSDictionary<NSString *, NSNumber *> *> *FLProcessorCoreTicks(void) {
  natural_t cores = 0;
  processor_info_array_t info = NULL;
  mach_msg_type_number_t count = 0;
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info,
                          &count) != KERN_SUCCESS) {
    return @[];
  }
  processor_cpu_load_info_t loads = (processor_cpu_load_info_t)info;
  NSMutableArray *result = [NSMutableArray new];
  for (natural_t core = 0; core < cores; core++) {
    [result addObject:@{
      @"user" : @(loads[core].cpu_ticks[CPU_STATE_USER]),
      @"system" : @(loads[core].cpu_ticks[CPU_STATE_SYSTEM]),
      @"idle" : @(loads[core].cpu_ticks[CPU_STATE_IDLE]),
      @"nice" : @(loads[core].cpu_ticks[CPU_STATE_NICE]),
    }];
  }
  vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));
  return result;
}

NSDictionary<NSString *, NSNumber *> *FLMemoryStatistics(void) {
  vm_size_t page = 0;
  host_page_size(mach_host_self(), &page);
  vm_statistics64_data_t memory;
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  NSMutableDictionary *result = [NSMutableDictionary new];
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&memory,
                        &count) == KERN_SUCCESS) {
    result[@"free"] = @((uint64_t)memory.free_count * page);
    result[@"active"] = @((uint64_t)memory.active_count * page);
    result[@"inactive"] = @((uint64_t)memory.inactive_count * page);
    result[@"wired"] = @((uint64_t)memory.wire_count * page);
    result[@"speculative"] = @((uint64_t)memory.speculative_count * page);
    result[@"purgeable"] = @((uint64_t)memory.purgeable_count * page);
    result[@"compressed"] = @((uint64_t)memory.compressor_page_count * page);
    result[@"pageIns"] = @(memory.pageins);
    result[@"pageOuts"] = @(memory.pageouts);
    result[@"faults"] = @(memory.faults);
  }
  int64_t total = 0;
  if (FLSysctlNumber(@"hw.memsize", &total) || FLSysctlNumber(@"hw.physmem", &total)) {
    result[@"total"] = @((uint64_t)total);
  }
  int64_t level = 0;
  if (FLSysctlNumber(@"kern.memorystatus_level", &level)) {
    result[@"level"] = @(level);
  }
  return result;
}

NSArray<NSNumber *> *FLLoadAverages(void) {
  double loads[3] = {0, 0, 0};
  if (getloadavg(loads, 3) != 3) {
    return @[];
  }
  return @[ @(loads[0]), @(loads[1]), @(loads[2]) ];
}

NSArray<FLVolume *> *FLVolumes(void) {
  struct statfs *mounts = NULL;
  int count = getmntinfo(&mounts, MNT_NOWAIT);
  NSMutableArray *volumes = [NSMutableArray new];
  for (int index = 0; index < count; index++) {
    FLVolume *volume = [FLVolume new];
    volume.mount = @(mounts[index].f_mntonname);
    volume.device = @(mounts[index].f_mntfromname);
    volume.type = @(mounts[index].f_fstypename);
    volume.totalBytes = (uint64_t)mounts[index].f_blocks * mounts[index].f_bsize;
    volume.freeBytes = (uint64_t)mounts[index].f_bfree * mounts[index].f_bsize;
    volume.availableBytes = (uint64_t)mounts[index].f_bavail * mounts[index].f_bsize;
    volume.flags = mounts[index].f_flags;
    [volumes addObject:volume];
  }
  return volumes;
}

static NSString *FLAddressText(const struct sockaddr *address, const struct sockaddr *mask) {
  char text[INET6_ADDRSTRLEN] = {0};
  if (address->sa_family == AF_INET) {
    const struct sockaddr_in *inet = (const struct sockaddr_in *)address;
    inet_ntop(AF_INET, &inet->sin_addr, text, sizeof(text));
    int bits = 0;
    if (mask != NULL) {
      uint32_t value = ntohl(((const struct sockaddr_in *)mask)->sin_addr.s_addr);
      while (value & 0x80000000u) {
        bits++;
        value <<= 1;
      }
      return [NSString stringWithFormat:@"%s/%d", text, bits];
    }
    return @(text);
  }
  if (address->sa_family == AF_INET6) {
    const struct sockaddr_in6 *inet = (const struct sockaddr_in6 *)address;
    inet_ntop(AF_INET6, &inet->sin6_addr, text, sizeof(text));
    return @(text);
  }
  return nil;
}

NSArray<FLInterface *> *FLInterfaces(void) {
  NSMutableDictionary<NSString *, FLInterface *> *byName = [NSMutableDictionary new];
  NSMutableArray<FLInterface *> *ordered = [NSMutableArray new];
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) == 0) {
    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
      if (entry->ifa_name == NULL) {
        continue;
      }
      NSString *name = @(entry->ifa_name);
      FLInterface *interface = byName[name];
      if (interface == nil) {
        interface = [FLInterface new];
        interface.name = name;
        byName[name] = interface;
        [ordered addObject:interface];
      }
      interface.flags = entry->ifa_flags;
      if (entry->ifa_addr == NULL) {
        continue;
      }
      if (entry->ifa_addr->sa_family == AF_LINK) {
        const struct sockaddr_dl *link = (const struct sockaddr_dl *)entry->ifa_addr;
        if (link->sdl_alen == 6) {
          const uint8_t *bytes = (const uint8_t *)LLADDR(link);
          interface.hardwareAddress =
            [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x", bytes[0],
                                       bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
        }
        continue;
      }
      NSString *address = FLAddressText(entry->ifa_addr, entry->ifa_netmask);
      if (address != nil) {
        [interface.addresses addObject:address];
      }
    }
    freeifaddrs(list);
  }

  int name[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
  size_t size = 0;
  if (sysctl(name, 6, NULL, &size, NULL, 0) == 0 && size > 0) {
    char *buffer = malloc(size);
    if (sysctl(name, 6, buffer, &size, NULL, 0) == 0) {
      char *cursor = buffer;
      char *end = buffer + size;
      while (cursor + sizeof(struct if_msghdr) <= end) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (header->ifm_msglen == 0) {
          break;
        }
        if (header->ifm_type == FL_RTM_IFINFO2 &&
            cursor + sizeof(struct if_msghdr2) <= end) {
          struct if_msghdr2 *detail = (struct if_msghdr2 *)cursor;
          char label[IF_NAMESIZE] = {0};
          if (if_indextoname(detail->ifm_index, label) != NULL) {
            FLInterface *interface = byName[@(label)];
            interface.receivedBytes = detail->ifm_data.ifi_ibytes;
            interface.sentBytes = detail->ifm_data.ifi_obytes;
            interface.receivedPackets = detail->ifm_data.ifi_ipackets;
            interface.sentPackets = detail->ifm_data.ifi_opackets;
            interface.receiveErrors = detail->ifm_data.ifi_ierrors;
            interface.sendErrors = detail->ifm_data.ifi_oerrors;
          }
        }
        cursor += header->ifm_msglen;
      }
    }
    free(buffer);
  }
  return ordered;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSDictionary *FLWirelessNetwork(void) {
  NSArray *names = CFBridgingRelease(CNCopySupportedInterfaces());
  for (NSString *name in names) {
    NSDictionary *info =
      CFBridgingRelease(CNCopyCurrentNetworkInfo((__bridge CFStringRef)name));
    if (info.count > 0) {
      NSMutableDictionary *network = [NSMutableDictionary new];
      network[@"interface"] = name;
      if (info[@"SSID"] != nil) {
        network[@"ssid"] = info[@"SSID"];
      }
      if (info[@"BSSID"] != nil) {
        network[@"bssid"] = info[@"BSSID"];
      }
      return network;
    }
  }
  return @{};
}
#pragma clang diagnostic pop

NSDictionary *FLBatteryProperties(void) {
  io_service_t service = IOServiceGetMatchingService(
    kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
  if (service == IO_OBJECT_NULL) {
    return @{};
  }
  CFMutableDictionaryRef properties = NULL;
  kern_return_t status =
    IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
  IOObjectRelease(service);
  if (status != KERN_SUCCESS || properties == NULL) {
    return @{};
  }
  return CFBridgingRelease(properties);
}

NSString *FLBatterySummary(NSDictionary *battery) {
  if (battery.count == 0) {
    return @"unknown";
  }
  NSMutableArray *parts = [NSMutableArray new];
  NSNumber *current = battery[@"CurrentCapacity"];
  NSNumber *maximum = battery[@"MaxCapacity"];
  if (current != nil && maximum.doubleValue > 0) {
    [parts addObject:[NSString stringWithFormat:@"%.0f%%", current.doubleValue * 100.0 /
                                                             maximum.doubleValue]];
  }
  if ([battery[@"IsCharging"] boolValue]) {
    [parts addObject:@"charging"];
  } else if ([battery[@"ExternalConnected"] boolValue]) {
    [parts addObject:[battery[@"FullyCharged"] boolValue] ? @"full, on power"
                                                           : @"on power"];
  } else {
    [parts addObject:@"on battery"];
  }
  if (battery[@"Voltage"] != nil) {
    [parts addObject:[NSString stringWithFormat:@"%.2f V",
                                                [battery[@"Voltage"] doubleValue] /
                                                  1000.0]];
  }
  NSNumber *amperage = battery[@"InstantAmperage"] ?: battery[@"Amperage"];
  if (amperage != nil) {
    [parts addObject:[NSString stringWithFormat:@"%d mA", amperage.intValue]];
  }
  if (battery[@"Temperature"] != nil) {
    [parts addObject:[NSString stringWithFormat:@"%.1f °C",
                                                [battery[@"Temperature"] doubleValue] /
                                                  100.0]];
  }
  if (battery[@"CycleCount"] != nil) {
    [parts addObject:[NSString stringWithFormat:@"%@ cycles", battery[@"CycleCount"]]];
  }
  return [parts componentsJoinedByString:@", "];
}

NSDictionary *FLBundleInfo(NSString *bundlePath) {
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
    cache.countLimit = 256;
  });
  if (bundlePath.length == 0) {
    return @{};
  }
  NSString *file = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
  NSDate *modified = FLFileModified(file);
  NSDictionary *known = [cache objectForKey:bundlePath];
  if (known != nil && (known[@"modified"] == modified || [known[@"modified"] isEqual:modified])) {
    return known;
  }
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:file];
  NSMutableDictionary *info = [NSMutableDictionary new];
  if (modified != nil) {
    info[@"modified"] = modified;
  }
  NSString *folder = bundlePath.lastPathComponent.stringByDeletingPathExtension;
  NSString *strings = [bundlePath
    stringByAppendingPathComponent:@"en.lproj/InfoPlist.strings"];
  NSDictionary *localized = [NSDictionary dictionaryWithContentsOfFile:strings];
  info[@"name"] = localized[@"CFBundleDisplayName"] ?: localized[@"CFBundleName"]
    ?: plist[@"CFBundleDisplayName"] ?: plist[@"CFBundleName"] ?: folder;
  if (plist[@"CFBundleIdentifier"] != nil) {
    info[@"identifier"] = plist[@"CFBundleIdentifier"];
  }
  NSString *version = plist[@"CFBundleShortVersionString"] ?: plist[@"CFBundleVersion"];
  if (version != nil) {
    info[@"version"] = version;
  }
  if (plist[@"CFBundleVersion"] != nil) {
    info[@"build"] = plist[@"CFBundleVersion"];
  }
  info[@"hidden"] = @([plist[@"SBAppTags"] isKindOfClass:[NSArray class]] &&
                      [plist[@"SBAppTags"] containsObject:@"hidden"]);
  [cache setObject:info forKey:bundlePath];
  return info;
}
