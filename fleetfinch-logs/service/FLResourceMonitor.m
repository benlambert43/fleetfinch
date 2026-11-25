#import "FLMonitors.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <sys/sysctl.h>

#import "FLStore.h"
#import "FLSystemInfo.h"

static double FLShare(NSDictionary *now, NSDictionary *before, NSArray *keys) {
  double part = 0, whole = 0;
  for (NSString *key in @[ @"user", @"system", @"idle", @"nice" ]) {
    double change = [now[key] doubleValue] - [before[key] doubleValue];
    if (change < 0) {
      change = 0;
    }
    whole += change;
    if ([keys containsObject:key]) {
      part += change;
    }
  }
  return whole <= 0 ? 0 : part / whole * 100.0;
}

static NSDictionary<NSString *, NSNumber *> *FLDiskCounters(void) {
  uint64_t bytesRead = 0, bytesWritten = 0, reads = 0, writes = 0;
  io_iterator_t drivers = IO_OBJECT_NULL;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                   IOServiceMatching("IOBlockStorageDriver"),
                                   &drivers) != KERN_SUCCESS) {
    return @{};
  }
  io_service_t driver = IO_OBJECT_NULL;
  while ((driver = IOIteratorNext(drivers)) != IO_OBJECT_NULL) {
    NSDictionary *statistics = CFBridgingRelease(IORegistryEntryCreateCFProperty(
      driver, CFSTR("Statistics"), kCFAllocatorDefault, 0));
    bytesRead += [statistics[@"Bytes (Read)"] unsignedLongLongValue];
    bytesWritten += [statistics[@"Bytes (Write)"] unsignedLongLongValue];
    reads += [statistics[@"Operations (Read)"] unsignedLongLongValue];
    writes += [statistics[@"Operations (Write)"] unsignedLongLongValue];
    IOObjectRelease(driver);
  }
  IOObjectRelease(drivers);
  return @{
    @"bytesRead" : @(bytesRead),
    @"bytesWritten" : @(bytesWritten),
    @"reads" : @(reads),
    @"writes" : @(writes),
  };
}

static uint64_t FLGrowth(NSNumber *now, NSNumber *before) {
  uint64_t current = now.unsignedLongLongValue;
  uint64_t previous = before.unsignedLongLongValue;
  return before == nil || current < previous ? 0 : current - previous;
}

@implementation FLResourceMonitor {
  NSDictionary *_ticks;
  NSArray<NSDictionary *> *_cores;
  NSDictionary *_memory;
  NSDictionary *_disk;
  NSDictionary<NSString *, NSArray<NSNumber *> *> *_traffic;
  NSDate *_sampled;
  NSDictionary *_latest;
}

- (void)sample:(BOOL)record {
  NSDate *now = [NSDate date];
  NSTimeInterval elapsed = _sampled == nil ? 0 : [now timeIntervalSinceDate:_sampled];
  NSDictionary *ticks = FLProcessorTicks();
  NSArray<NSDictionary *> *cores = FLProcessorCoreTicks();
  NSDictionary *memory = FLMemoryStatistics();
  NSDictionary *disk = FLDiskCounters();
  NSArray<NSNumber *> *loads = FLLoadAverages();
  NSDictionary *battery = FLBatteryProperties();
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  NSMutableDictionary *latest = [NSMutableDictionary new];
  latest[@"at"] = now;

  if (_ticks != nil) {
    double user = FLShare(ticks, _ticks, @[ @"user", @"nice" ]);
    double system = FLShare(ticks, _ticks, @[ @"system" ]);
    NSMutableArray *perCore = [NSMutableArray new];
    for (NSUInteger index = 0; index < MIN(cores.count, _cores.count); index++) {
      double busy = FLShare(cores[index], _cores[index], @[ @"user", @"nice", @"system" ]);
      [perCore addObject:[NSString stringWithFormat:@"%.0f%%", busy]];
    }
    [parts addObject:[NSString
                       stringWithFormat:@"processor %.1f%% (user %.1f%%, system %.1f%%), "
                                        @"cores %@",
                                        user + system, user, system,
                                        [perCore componentsJoinedByString:@" "]]];
    latest[@"processor"] = @(user + system);
    latest[@"processorUser"] = @(user);
    latest[@"processorSystem"] = @(system);
  }
  if (loads.count == 3) {
    [parts addObject:[NSString stringWithFormat:@"load %.2f %.2f %.2f",
                                                loads[0].doubleValue, loads[1].doubleValue,
                                                loads[2].doubleValue]];
    latest[@"load"] = loads;
  }

  uint64_t total = [memory[@"total"] unsignedLongLongValue];
  uint64_t free = [memory[@"free"] unsignedLongLongValue];
  uint64_t inactive = [memory[@"inactive"] unsignedLongLongValue];
  uint64_t used = total > free + inactive ? total - free - inactive : 0;
  NSMutableString *memoryText = [NSMutableString
    stringWithFormat:@"memory %@ used of %@ (free %@, active %@, inactive %@, wired %@, "
                     @"compressed %@)",
                     FLFormatBytes(used), FLFormatBytes(total), FLFormatBytes(free),
                     FLFormatBytes([memory[@"active"] unsignedLongLongValue]),
                     FLFormatBytes(inactive),
                     FLFormatBytes([memory[@"wired"] unsignedLongLongValue]),
                     FLFormatBytes([memory[@"compressed"] unsignedLongLongValue])];
  if (memory[@"level"] != nil) {
    [memoryText appendFormat:@", %@%% available by the kernel's count", memory[@"level"]];
  }
  if (_memory != nil) {
    [memoryText appendFormat:@", %llu pages in and %llu out since the last sample",
                             FLGrowth(memory[@"pageIns"], _memory[@"pageIns"]),
                             FLGrowth(memory[@"pageOuts"], _memory[@"pageOuts"])];
  }
  [parts addObject:memoryText];
  latest[@"memoryUsed"] = @(used);
  latest[@"memoryTotal"] = @(total);
  latest[@"memoryFree"] = @(free);
  if (memory[@"level"] != nil) {
    latest[@"memoryLevel"] = memory[@"level"];
  }

  NSMutableArray *volumeTexts = [NSMutableArray new];
  NSMutableArray *volumeRows = [NSMutableArray new];
  for (FLVolume *volume in FLVolumes()) {
    if (volume.totalBytes < 1024 * 1024) {
      continue;
    }
    [volumeTexts addObject:[NSString stringWithFormat:@"%@ %@ free of %@", volume.mount,
                                                      FLFormatBytes(volume.availableBytes),
                                                      FLFormatBytes(volume.totalBytes)]];
    [volumeRows addObject:@{
      @"mount" : volume.mount,
      @"total" : @(volume.totalBytes),
      @"free" : @(volume.availableBytes),
    }];
  }
  NSMutableString *storage = [NSMutableString
    stringWithFormat:@"storage %@", [volumeTexts componentsJoinedByString:@", "]];
  if (_disk != nil) {
    [storage appendFormat:@", %@ read and %@ written since the last sample",
                          FLFormatBytes(FLGrowth(disk[@"bytesRead"], _disk[@"bytesRead"])),
                          FLFormatBytes(
                            FLGrowth(disk[@"bytesWritten"], _disk[@"bytesWritten"]))];
  }
  [parts addObject:storage];
  latest[@"volumes"] = volumeRows;

  NSMutableDictionary *traffic = [NSMutableDictionary new];
  NSMutableArray *networkTexts = [NSMutableArray new];
  NSMutableArray *networkRows = [NSMutableArray new];
  for (FLInterface *interface in FLInterfaces()) {
    traffic[interface.name] = @[ @(interface.receivedBytes), @(interface.sentBytes) ];
    if ([interface isLoopback] || ![interface isUp]) {
      continue;
    }
    NSArray<NSNumber *> *before = _traffic[interface.name];
    uint64_t received = before == nil ? 0 : FLGrowth(@(interface.receivedBytes), before[0]);
    uint64_t sent = before == nil ? 0 : FLGrowth(@(interface.sentBytes), before[1]);
    NSString *address = interface.addresses.count > 0 ? interface.addresses.lastObject : @"";
    for (NSString *candidate in interface.addresses) {
      if ([candidate containsString:@"."]) {
        address = candidate;
      }
    }
    [networkTexts addObject:[NSString stringWithFormat:@"%@ %@ received %@ sent %@",
                                                       interface.name, address,
                                                       FLFormatBytes(received),
                                                       FLFormatBytes(sent)]];
    [networkRows addObject:@{
      @"name" : interface.name,
      @"address" : address,
      @"received" : @(elapsed > 0 ? (double)received / elapsed : 0),
      @"sent" : @(elapsed > 0 ? (double)sent / elapsed : 0),
    }];
  }
  [parts addObject:[NSString
                     stringWithFormat:@"network %@",
                                      networkTexts.count > 0
                                        ? [networkTexts componentsJoinedByString:@", "]
                                        : @"no interface is up"]];
  latest[@"interfaces"] = networkRows;

  [parts addObject:[NSString stringWithFormat:@"battery %@", FLBatterySummary(battery)]];
  latest[@"battery"] = FLBatterySummary(battery);
  NSNumber *capacity = battery[@"CurrentCapacity"];
  NSNumber *maximum = battery[@"MaxCapacity"];
  if (capacity != nil && maximum.doubleValue > 0) {
    latest[@"batteryLevel"] = @(capacity.doubleValue * 100.0 / maximum.doubleValue);
  }
  latest[@"uptime"] = @(FLUptime());

  _ticks = ticks;
  _cores = cores;
  _memory = memory;
  _disk = disk;
  _traffic = traffic;
  _sampled = now;
  _latest = latest;
  if (record) {
    FLNote(@"resource", FLLevelInfo, @"system", @"%@",
           [parts componentsJoinedByString:@"; "]);
  }
}

- (NSDictionary *)latest {
  return _latest ?: @{};
}

@end

static io_connect_t FLRootPort = IO_OBJECT_NULL;
static NSDate *FLSleptAt = nil;

static NSString *FLWakeReason(void) {
  NSString *reason = FLSysctlString(@"kern.wakereason");
  return reason.length > 0 ? reason : @"unknown";
}

static void FLPowerChanged(void *context, io_service_t service, natural_t message,
                           void *argument) {
  switch (message) {
    case kIOMessageCanSystemSleep:
      IOAllowPowerChange(FLRootPort, (long)argument);
      break;
    case kIOMessageSystemWillSleep:
      FLMarkGoingToSleep(YES);
      FLSleptAt = [NSDate date];
      FLNote(@"power", FLLevelNotice, @"system", @"going to sleep");
      [[FLStore shared] sync];
      IOAllowPowerChange(FLRootPort, (long)argument);
      break;
    case kIOMessageSystemWillNotSleep:
      FLMarkGoingToSleep(NO);
      FLNote(@"power", FLLevelInfo, @"system", @"sleep was called off");
      break;
    case kIOMessageSystemHasPoweredOn: {
      FLMarkGoingToSleep(NO);
      NSTimeInterval asleep = FLSleptAt == nil ? 0 : -FLSleptAt.timeIntervalSinceNow;
      FLNote(@"power", FLLevelNotice, @"system", @"woke after %@ asleep, because of: %@",
             FLFormatDuration(asleep), FLWakeReason());
      FLSleptAt = nil;
      FLPowerMonitor *monitor = (__bridge FLPowerMonitor *)context;
      if (monitor.woke != nil) {
        monitor.woke();
      }
      break;
    }
    default:
      break;
  }
}

@implementation FLPowerMonitor {
  NSString *_battery;
  NSInteger _level;
}

- (void)start {
  IONotificationPortRef port = NULL;
  io_object_t notifier = IO_OBJECT_NULL;
  FLMarkGoingToSleep(NO);
  FLRootPort =
    IORegisterForSystemPower((__bridge void *)self, &port, FLPowerChanged, &notifier);
  if (FLRootPort == IO_OBJECT_NULL || port == NULL) {
    FLNote(@"finchlogs", FLLevelWarning, @"power",
           @"Sleep and wake could not be watched on this system");
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port),
                     kCFRunLoopCommonModes);
  _level = -1;
}

- (void)checkBattery {
  NSDictionary *battery = FLBatteryProperties();
  if (battery.count == 0) {
    return;
  }
  NSString *state = @"on battery";
  if ([battery[@"IsCharging"] boolValue]) {
    state = @"charging";
  } else if ([battery[@"ExternalConnected"] boolValue]) {
    state = [battery[@"FullyCharged"] boolValue] ? @"fully charged, on power" : @"on power";
  }
  NSNumber *capacity = battery[@"CurrentCapacity"];
  NSNumber *maximum = battery[@"MaxCapacity"];
  NSInteger level = maximum.doubleValue > 0
    ? (NSInteger)lround(capacity.doubleValue * 100.0 / maximum.doubleValue)
    : -1;
  if (![state isEqualToString:_battery ?: @""]) {
    NSDictionary *adapter = battery[@"AdapterDetails"];
    NSString *supply = [adapter[@"Watts"] doubleValue] > 0
      ? [NSString stringWithFormat:@" from a %@ W supply", adapter[@"Watts"]]
      : @"";
    FLNote(@"power", FLLevelNotice, @"battery", @"now %@%@ at %ld%%: %@", state, supply,
           (long)level, FLBatterySummary(battery));
    _battery = state;
    _level = level;
    return;
  }
  if (level != _level && level >= 0) {
    FLNote(@"power", FLLevelInfo, @"battery", @"%ld%% (%@)", (long)level,
           FLBatterySummary(battery));
    _level = level;
  }
}

@end

@implementation FLNetworkMonitor {
  NSString *_summary;
}

- (void)check {
  NSMutableArray *parts = [NSMutableArray new];
  NSDictionary *wireless = FLWirelessNetwork();
  if (wireless[@"ssid"] != nil) {
    [parts addObject:[NSString stringWithFormat:@"Wi-Fi network %@ (%@)", wireless[@"ssid"],
                                                wireless[@"bssid"] ?: @""]];
  } else {
    [parts addObject:@"no Wi-Fi network"];
  }
  for (FLInterface *interface in FLInterfaces()) {
    if ([interface isLoopback] || ![interface isUp] || interface.addresses.count == 0) {
      continue;
    }
    [parts addObject:[NSString
                       stringWithFormat:@"%@ %@", interface.name,
                                        [interface.addresses componentsJoinedByString:@" "]]];
  }
  NSString *summary = [parts componentsJoinedByString:@"; "];
  if ([summary isEqualToString:_summary ?: @""]) {
    return;
  }
  FLNote(@"network", FLLevelNotice, @"network", @"%@%@",
         _summary == nil ? @"" : @"changed to: ", summary);
  _summary = summary;
}

@end
