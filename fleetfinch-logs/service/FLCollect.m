#import "FLCollect.h"

#import <dlfcn.h>
#import <grp.h>
#import <pwd.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import <IOKit/IOKitLib.h>
#import <launch.h>

#import "FLCommon.h"
#import "FLSystemInfo.h"
#import "FLUsage.h"

static const NSUInteger FLValueDepth = 6;
static const NSUInteger FLDataPreview = 48;
static const NSUInteger FLListPreview = 64;
static const size_t FLSysctlValueLimit = 64 * 1024;
static const NSUInteger FLRegistryLimit = 6 * 1024 * 1024;
static const NSUInteger FLRegistryPiece = 64 * 1024;

extern int proc_kmsgbuf(void *buffer, uint32_t size);
extern kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry,
                                                      uint64_t *identifier);

void *FLSymbol(const char *library, const char *name) {
  void *handle = library == NULL ? RTLD_DEFAULT : dlopen(library, RTLD_LAZY);
  if (handle == NULL) {
    return NULL;
  }
  return dlsym(handle, name);
}

static NSString *FLDescribeData(NSData *data) {
  const uint8_t *bytes = data.bytes;
  NSUInteger length = data.length;
  BOOL printable = length > 0;
  NSUInteger text = length;
  while (text > 0 && bytes[text - 1] == 0) {
    text--;
  }
  for (NSUInteger index = 0; index < text && printable; index++) {
    printable = bytes[index] >= 32 && bytes[index] < 127;
  }
  if (printable && text > 0) {
    NSString *string = [[NSString alloc] initWithBytes:bytes
                                                length:text
                                              encoding:NSASCIIStringEncoding];
    return [NSString stringWithFormat:@"<\"%@\">", string];
  }
  NSMutableString *hex = [NSMutableString stringWithString:@"<"];
  for (NSUInteger index = 0; index < MIN(length, FLDataPreview); index++) {
    [hex appendFormat:@"%02x", bytes[index]];
  }
  if (length > FLDataPreview) {
    [hex appendFormat:@"… %lu bytes", (unsigned long)length];
  }
  [hex appendString:@">"];
  return hex;
}

static NSString *FLDescribe(id value, NSUInteger depth) {
  if (value == nil || value == [NSNull null]) {
    return @"";
  }
  if ([value isKindOfClass:[NSString class]]) {
    return FLEscape(value);
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
      return [value boolValue] ? @"Yes" : @"No";
    }
    return [value stringValue];
  }
  if ([value isKindOfClass:[NSData class]]) {
    return FLDescribeData(value);
  }
  if ([value isKindOfClass:[NSDate class]]) {
    return FLTimestamp(value);
  }
  if (depth >= FLValueDepth) {
    return @"…";
  }
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *parts = [NSMutableArray new];
    for (id item in (NSArray *)value) {
      if (parts.count >= FLListPreview) {
        [parts addObject:[NSString stringWithFormat:@"… %lu items",
                                                    (unsigned long)[value count]]];
        break;
      }
      [parts addObject:FLDescribe(item, depth + 1)];
    }
    return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@", "]];
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSMutableArray *parts = [NSMutableArray new];
    NSArray *keys = [[(NSDictionary *)value allKeys]
      sortedArrayUsingComparator:^(id first, id second) {
        return [[first description] compare:[second description]];
      }];
    for (id key in keys) {
      if (parts.count >= FLListPreview) {
        [parts addObject:@"…"];
        break;
      }
      [parts addObject:[NSString stringWithFormat:@"%@ = %@", key,
                                                  FLDescribe(value[key], depth + 1)]];
    }
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@"; "]];
  }
  return FLEscape([value description]);
}

NSString *FLDescribeValue(id value) {
  return FLDescribe(value, 0);
}

static NSString *FLSysctlName(const int *identifier, size_t length) {
  int query[CTL_MAXNAME + 2] = {0, 1};
  memcpy(query + 2, identifier, length * sizeof(int));
  char name[512] = {0};
  size_t size = sizeof(name) - 1;
  if (sysctl(query, (u_int)length + 2, name, &size, NULL, 0) != 0) {
    return nil;
  }
  return [NSString stringWithUTF8String:name];
}

static NSString *FLSysctlStructure(NSString *format, const uint8_t *bytes, size_t size) {
  if ([format isEqualToString:@"S,timeval"] && size >= sizeof(struct timeval)) {
    struct timeval moment;
    memcpy(&moment, bytes, sizeof(moment));
    if (moment.tv_sec == 0) {
      return @"never";
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)moment.tv_sec +
                                                         moment.tv_usec / 1e6];
    return FLTimestamp(date);
  }
  if ([format isEqualToString:@"S,loadavg"] && size >= sizeof(struct loadavg)) {
    struct loadavg load;
    memcpy(&load, bytes, sizeof(load));
    double scale = load.fscale == 0 ? 1.0 : (double)load.fscale;
    return [NSString stringWithFormat:@"%.2f %.2f %.2f", load.ldavg[0] / scale,
                                      load.ldavg[1] / scale, load.ldavg[2] / scale];
  }
  if ([format isEqualToString:@"S,clockinfo"] && size >= sizeof(struct clockinfo)) {
    struct clockinfo clock;
    memcpy(&clock, bytes, sizeof(clock));
    return [NSString stringWithFormat:@"hz = %d, tick = %d, profhz = %d, stathz = %d",
                                      clock.hz, clock.tick, clock.profhz, clock.stathz];
  }
  if ([format isEqualToString:@"S,xsw_usage"] && size >= sizeof(struct xsw_usage)) {
    struct xsw_usage swap;
    memcpy(&swap, bytes, sizeof(swap));
    return [NSString stringWithFormat:@"total = %llu, used = %llu, free = %llu",
                                      swap.xsu_total, swap.xsu_used, swap.xsu_avail];
  }
  return FLDescribeData([NSData dataWithBytes:bytes length:size]);
}

static NSString *FLSysctlValue(const int *identifier, size_t length) {
  int query[CTL_MAXNAME + 2] = {0, 4};
  memcpy(query + 2, identifier, length * sizeof(int));
  uint8_t description[256] = {0};
  size_t descriptionSize = sizeof(description) - 1;
  if (sysctl(query, (u_int)length + 2, description, &descriptionSize, NULL, 0) != 0 ||
      descriptionSize < sizeof(u_int)) {
    return nil;
  }
  u_int kind = 0;
  memcpy(&kind, description, sizeof(kind));
  NSString *format = @((const char *)description + sizeof(u_int));
  int type = (int)(kind & CTLTYPE);
  if (type == CTLTYPE_NODE) {
    return nil;
  }
  size_t size = 0;
  if (sysctl((int *)identifier, (u_int)length, NULL, &size, NULL, 0) != 0) {
    return nil;
  }
  if (size == 0) {
    return @"";
  }
  if (size > FLSysctlValueLimit) {
    return [NSString stringWithFormat:@"(%lu bytes)", (unsigned long)size];
  }
  uint8_t *bytes = calloc(1, size + 16);
  size_t filled = size + 8;
  if (sysctl((int *)identifier, (u_int)length, bytes, &filled, NULL, 0) != 0) {
    free(bytes);
    return nil;
  }
  NSString *value = nil;
  if (type == CTLTYPE_STRING) {
    value = FLEscape(FLStringFromData(
      [NSData dataWithBytes:bytes length:strnlen((const char *)bytes, filled)]));
  } else if (type == CTLTYPE_INT) {
    NSMutableArray *numbers = [NSMutableArray new];
    BOOL isUnsigned = [format hasPrefix:@"IU"] || [format hasPrefix:@"LU"];
    for (size_t offset = 0; offset + sizeof(int) <= filled && numbers.count < 32;
         offset += sizeof(int)) {
      int number = 0;
      memcpy(&number, bytes + offset, sizeof(number));
      [numbers addObject:isUnsigned ? [NSString stringWithFormat:@"%u", (unsigned)number]
                                    : [NSString stringWithFormat:@"%d", number]];
    }
    value = [numbers componentsJoinedByString:@" "];
  } else if (type == CTLTYPE_QUAD && filled >= sizeof(int64_t)) {
    int64_t number = 0;
    memcpy(&number, bytes, sizeof(number));
    value = [format hasPrefix:@"QU"]
      ? [NSString stringWithFormat:@"%llu", (unsigned long long)number]
      : [NSString stringWithFormat:@"%lld", (long long)number];
  } else {
    value = FLSysctlStructure(format, bytes, filled);
  }
  free(bytes);
  return value;
}

static NSString *FLCollectSysctl(void) {
  NSMutableString *text = [NSMutableString new];
  int query[CTL_MAXNAME + 2] = {0, 2, 1};
  size_t queryLength = 3;
  NSUInteger count = 0;
  for (;;) {
    int next[CTL_MAXNAME] = {0};
    size_t nextSize = sizeof(next);
    if (sysctl(query, (u_int)queryLength, next, &nextSize, NULL, 0) != 0) {
      break;
    }
    size_t nextLength = nextSize / sizeof(int);
    if (nextLength == 0 || nextLength > CTL_MAXNAME) {
      break;
    }
    NSString *name = FLSysctlName(next, nextLength);
    BOOL bulky = [name hasPrefix:@"kern.proc"] || [name hasPrefix:@"kern.file"] ||
                 [name hasPrefix:@"kern.vnode"] || [name hasPrefix:@"kern.kdebug"] ||
                 [name containsString:@"pcblist"];
    if (name != nil && !bulky) {
      NSString *value = FLSysctlValue(next, nextLength);
      if (value != nil) {
        [text appendFormat:@"%@ = %@\n", name, value];
        count++;
      }
    }
    memcpy(query + 2, next, nextLength * sizeof(int));
    queryLength = nextLength + 2;
    if (count > 20000) {
      break;
    }
  }
  return text;
}

static void FLAppendRegistryEntry(io_registry_entry_t entry, NSUInteger depth,
                                  NSMutableString *text, NSUInteger *written,
                                  void (^write)(NSString *piece)) {
  if (*written + text.length > FLRegistryLimit) {
    return;
  }
  @autoreleasepool {
    io_name_t name = {0};
    io_name_t className = {0};
    IORegistryEntryGetNameInPlane(entry, kIOServicePlane, name);
    IOObjectGetClass(entry, className);
    uint64_t identifier = 0;
    IORegistryEntryGetRegistryEntryID(entry, &identifier);
    NSString *indent = [@"" stringByPaddingToLength:depth * 2
                                         withString:@" "
                                    startingAtIndex:0];
    [text appendFormat:@"%@+ %s <%s, id 0x%llx>\n", indent, name, className, identifier];
    CFMutableDictionaryRef properties = NULL;
    if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) ==
          KERN_SUCCESS &&
        properties != NULL) {
      NSDictionary *values = CFBridgingRelease(properties);
      NSArray *keys = [values.allKeys sortedArrayUsingSelector:@selector(compare:)];
      for (NSString *key in keys) {
        [text appendFormat:@"%@    %@ = %@\n", indent, key, FLDescribeValue(values[key])];
      }
    }
    if (text.length >= FLRegistryPiece) {
      write([text copy]);
      *written += text.length;
      [text setString:@""];
    }
  }
  io_iterator_t children = IO_OBJECT_NULL;
  if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) !=
      KERN_SUCCESS) {
    return;
  }
  io_registry_entry_t child = IO_OBJECT_NULL;
  while ((child = IOIteratorNext(children)) != IO_OBJECT_NULL) {
    FLAppendRegistryEntry(child, depth + 1, text, written, write);
    IOObjectRelease(child);
  }
  IOObjectRelease(children);
}

static void FLWriteRegistry(void (^write)(NSString *piece)) {
  io_registry_entry_t root = IORegistryGetRootEntry(kIOMasterPortDefault);
  if (root == IO_OBJECT_NULL) {
    write(@"The I/O Registry could not be opened.\n");
    return;
  }
  NSMutableString *text = [NSMutableString new];
  NSUInteger written = 0;
  FLAppendRegistryEntry(root, 0, text, &written, write);
  IOObjectRelease(root);
  if (written + text.length > FLRegistryLimit) {
    [text appendString:@"… the rest was left out to keep this snapshot small\n"];
  }
  write(text);
}

static NSString *FLCollectRegistry(void) {
  NSMutableString *whole = [NSMutableString new];
  FLWriteRegistry(^(NSString *piece) {
    [whole appendString:piece];
  });
  return whole;
}

static NSArray<NSString *> *FLGestaltKeys(void) {
  return @[
    @"UserAssignedDeviceName", @"DeviceName", @"ProductType", @"ProductName",
    @"ProductVersion", @"BuildVersion", @"ReleaseType", @"HWModelStr",
    @"ModelNumber", @"RegionCode", @"RegionInfo",
    @"RegulatoryModelNumber", @"DeviceClass", @"DeviceClassNumber", @"DeviceColor",
    @"DeviceEnclosureColor", @"DeviceVariant", @"CPUArchitecture",
    @"ChipID", @"BoardId", @"UniqueChipID", @"DieId", @"UniqueDeviceID",
    @"SerialNumber", @"MLBSerialNumber", @"FirmwareVersion",
    @"BluetoothAddress", @"WifiAddress",
    @"EthernetMacAddress", @"SoftwareBundleVersion", @"SoftwareBehavior",
    @"SupportedDeviceFamilies", @"DiskUsage", @"BatteryCurrentCapacity",
    @"BatteryIsCharging", @"BatteryIsFullyCharged", @"ExternalPowerSourceConnected",
    @"ExternalChargeCapability", @"HasBaseband", @"HasBattery", @"main-screen-width",
    @"main-screen-height", @"main-screen-scale", @"main-screen-pitch",
    @"main-screen-class", @"main-screen-orientation",
    @"ArtworkTraits", @"DeviceSupportsNavigation", @"DeviceSupports1080p",
    @"DeviceSupports720p", @"DeviceSupports3DMaps", @"DeviceSupports3DImagery",
    @"DeviceSupports4G", @"wifi", @"bluetooth", @"bluetooth-le", @"gps",
    @"accelerometer", @"gyroscope", @"magnetometer", @"front-facing-camera",
    @"rear-facing-camera", @"still-camera", @"video-camera", @"camera-flash",
    @"multitasking", @"multitasking-gestures", @"telephony", @"cellular-data",
    @"sms", @"armv6", @"armv7", @"armv7s", @"arm64", @"opengles-1", @"opengles-2",
    @"opengles-3", @"metal", @"hd-video-capture", @"encrypted-data-partition",
    @"hardware-keyboard", @"microphone", @"ambient-light-sensor", @"proximity-sensor",
    @"hall-effect-sensor", @"gas-gauge-battery", @"displayport", @"display-mirroring",
    @"airplay-mirroring", @"hidpi", @"international-settings", @"location-services",
    @"peer-peer", @"photo-stream", @"ringer-switch", @"volume-buttons",
    @"PartitionType", @"SigningFuse", @"EffectiveSecurityMode",
    @"EffectiveProductionStatus", @"CertificateSecurityMode", @"CertificateProductionStatus",
    @"IsSimulator", @"IsUIBuild", @"InternalBuild", @"ComputerName",
    @"CPUType", @"CPUSubType",
    @"MinimumSupportediTunesVersion",
    @"PasswordConfigured", @"PasswordProtected",
    @"SysCfg", @"FrontFacingCameraHFRCapability", @"RearCameraCapability",
    @"WirelessBoardSnum", @"SecureElement"
  ];
}

static NSArray<NSString *> *FLBasebandKeys(void) {
  return @[
    @"BasebandFirmwareVersion", @"InternationalMobileEquipmentIdentity",
    @"MobileEquipmentIdentifier"
  ];
}

static NSString *FLCollectGestalt(void) {
  CFTypeRef (*copyAnswer)(CFStringRef) =
    FLSymbol("/usr/lib/libMobileGestalt.dylib", "MGCopyAnswer");
  if (copyAnswer == NULL) {
    return @"MobileGestalt is not available on this system.\n";
  }
  NSMutableString *text = [NSMutableString new];
  NSMutableArray<NSString *> *keys = [FLGestaltKeys() mutableCopy];
  id baseband = CFBridgingRelease(copyAnswer(CFSTR("HasBaseband")));
  if ([baseband respondsToSelector:@selector(boolValue)] && [baseband boolValue]) {
    [keys addObjectsFromArray:FLBasebandKeys()];
  }
  for (NSString *key in keys) {
    id answer = CFBridgingRelease(copyAnswer((__bridge CFStringRef)key));
    if (answer != nil) {
      [text appendFormat:@"%@ = %@\n", key, FLDescribeValue(answer)];
    }
  }
  return text;
}

static NSString *FLCollectKexts(void) {
  CFDictionaryRef (*copyInfo)(CFArrayRef, CFArrayRef) =
    FLSymbol(NULL, "OSKextCopyLoadedKextInfo");
  if (copyInfo == NULL) {
    return @"Kernel extension information is not available on this system.\n";
  }
  NSDictionary *loaded = CFBridgingRelease(copyInfo(NULL, NULL));
  if (loaded.count == 0) {
    return @"The kernel gave no list of loaded extensions.\n";
  }
  NSMutableArray *rows = [NSMutableArray new];
  for (NSString *identifier in loaded) {
    NSDictionary *info = loaded[identifier];
    [rows addObject:@[
      info[@"OSBundleLoadTag"] ?: @0, identifier, info[@"CFBundleVersion"] ?: @"",
      info[@"OSBundleLoadAddress"] ?: @0, info[@"OSBundleLoadSize"] ?: @0
    ]];
  }
  [rows sortUsingComparator:^(NSArray *first, NSArray *second) {
    return [first[0] compare:second[0]];
  }];
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"%lu kernel extensions loaded\n", (unsigned long)rows.count];
  for (NSArray *row in rows) {
    [text appendFormat:@"%4d  %@  %@  at 0x%llx  %@\n", [row[0] intValue], row[1],
                       row[2], [row[3] unsignedLongLongValue],
                       FLFormatBytes([row[4] unsignedLongLongValue])];
  }
  return text;
}

static NSString *FLCollectVolumes(void) {
  NSMutableString *text = [NSMutableString new];
  for (FLVolume *volume in FLVolumes()) {
    NSMutableArray *flags = [NSMutableArray new];
    if (volume.flags & MNT_RDONLY) {
      [flags addObject:@"read-only"];
    }
    if (volume.flags & MNT_NOSUID) {
      [flags addObject:@"nosuid"];
    }
    if (volume.flags & MNT_NODEV) {
      [flags addObject:@"nodev"];
    }
    if (volume.flags & MNT_JOURNALED) {
      [flags addObject:@"journaled"];
    }
    if (volume.flags & MNT_ROOTFS) {
      [flags addObject:@"root"];
    }
    [text appendFormat:@"%@ on %@ (%@%@%@): %@ in all, %@ free, %@ available\n",
                       volume.device, volume.mount, volume.type,
                       flags.count > 0 ? @", " : @"",
                       [flags componentsJoinedByString:@", "],
                       FLFormatBytes(volume.totalBytes), FLFormatBytes(volume.freeBytes),
                       FLFormatBytes(volume.availableBytes)];
  }
  return text;
}

static NSString *FLCollectProcesses(void) {
  NSArray<FLProcess *> *processes =
    [FLProcessList(YES) sortedArrayUsingComparator:^(FLProcess *first, FLProcess *second) {
      return [first.started compare:second.started];
    }];
  NSDate *boot = FLBootTime();
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"%lu processes, in the order they started\n",
                     (unsigned long)processes.count];
  [text appendString:@"pid\tparent\tuser\tstarted\tsince boot\tprocessor\tmemory\t"
                     @"threads\tcommand\n"];
  for (FLProcess *process in processes) {
    NSTimeInterval offset = boot == nil ? 0 : [process.started timeIntervalSinceDate:boot];
    [text appendFormat:@"%d\t%d\t%@\t%@\t%.1fs\t%.2fs\t%@\t%d\t%@\n", process.pid,
                       process.parent, FLUserName(process.user),
                       FLFormatDay(process.started), offset, process.processorSeconds,
                       FLFormatBytes(process.footprintBytes ?: process.residentBytes),
                       process.threads, FLEscape([process commandLine])];
  }
  return text;
}

static BOOL FLLoadsHere(NSDictionary *plist) {
  NSArray<NSArray *> *rules = @[
    @[ @"LimitLoadToHardware", @YES ], @[ @"LimitLoadFromHardware", @NO ]
  ];
  for (NSArray *rule in rules) {
    NSDictionary *limits = plist[rule[0]];
    if (![limits isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    for (NSString *key in limits) {
      NSString *value = FLSysctlString([@"hw." stringByAppendingString:[key description]]);
      NSArray *listed = [limits[key] isKindOfClass:[NSArray class]] ? limits[key] : @[];
      if (value != nil && [listed containsObject:value] != [rule[1] boolValue]) {
        return NO;
      }
    }
  }
  return YES;
}

void FLEachLaunchDefinition(void (^visit)(NSDictionary *service, NSDictionary *plist)) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSArray *folders = @[
    @"/System/Library/LaunchDaemons", @"/Library/LaunchDaemons",
    @"/System/Library/NanoLaunchDaemons", @"/Library/LaunchAgents",
    @"/System/Library/LaunchAgents"
  ];
  for (NSString *folder in folders) {
    NSArray *names = [[manager contentsOfDirectoryAtPath:folder error:NULL]
      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
      if (![name.pathExtension isEqualToString:@"plist"]) {
        continue;
      }
      @autoreleasepool {
        NSString *file = [folder stringByAppendingPathComponent:name];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:file];
        if (![plist isKindOfClass:[NSDictionary class]]) {
          continue;
        }
        NSArray *arguments = [plist[@"ProgramArguments"] isKindOfClass:[NSArray class]]
          ? plist[@"ProgramArguments"]
          : @[];
        NSString *program = [plist[@"Program"] isKindOfClass:[NSString class]]
          ? plist[@"Program"]
          : (arguments.count > 0 ? [arguments[0] description] : @"");
        if (program.length == 0) {
          continue;
        }
        NSMutableDictionary *service = [NSMutableDictionary new];
        service[@"label"] = [plist[@"Label"] description] ?: name.stringByDeletingPathExtension;
        service[@"file"] = file;
        service[@"program"] = program;
        service[@"arguments"] = arguments;
        service[@"runAtLoad"] = @([plist[@"RunAtLoad"] boolValue]);
        service[@"keepAlive"] = @(plist[@"KeepAlive"] != nil &&
                                  ![plist[@"KeepAlive"] isEqual:@NO]);
        service[@"disabled"] = @([plist[@"Disabled"] boolValue]);
        service[@"onDemand"] = @(plist[@"MachServices"] != nil ||
                                 plist[@"Sockets"] != nil);
        if (!FLLoadsHere(plist)) {
          service[@"elsewhere"] = @YES;
        }
        if (plist[@"LaunchEvents"] != nil) {
          service[@"onEvent"] = @YES;
        }
        if (plist[@"WatchPaths"] != nil || plist[@"QueueDirectories"] != nil) {
          service[@"onPath"] = @YES;
        }
        if (plist[@"StartInterval"] != nil || plist[@"StartCalendarInterval"] != nil) {
          service[@"onTimer"] = @YES;
        }
        if ([plist[@"UserName"] isKindOfClass:[NSString class]]) {
          service[@"user"] = plist[@"UserName"];
        }
        if ([plist[@"MachServices"] isKindOfClass:[NSDictionary class]]) {
          service[@"machServices"] = [[plist[@"MachServices"] allKeys]
            sortedArrayUsingSelector:@selector(compare:)];
        }
        visit(service, plist);
      }
    }
  }
}

NSArray<NSDictionary *> *FLLaunchServices(void) {
  NSMutableArray *services = [NSMutableArray new];
  FLEachLaunchDefinition(^(NSDictionary *service, NSDictionary *plist) {
    [services addObject:service];
  });
  return services;
}

static void FLAddLaunchJob(const launch_data_t value, const char *key, void *context) {
  if (key == NULL || value == NULL || launch_data_get_type(value) != LAUNCH_DATA_DICTIONARY) {
    return;
  }
  NSString *label = [NSString stringWithUTF8String:key];
  if (label.length == 0) {
    return;
  }
  NSMutableDictionary *jobs = (__bridge NSMutableDictionary *)context;
  NSMutableDictionary *job = [NSMutableDictionary new];
  launch_data_t pid = launch_data_dict_lookup(value, LAUNCH_JOBKEY_PID);
  if (pid != NULL && launch_data_get_type(pid) == LAUNCH_DATA_INTEGER) {
    job[@"pid"] = @(launch_data_get_integer(pid));
  }
  launch_data_t status = launch_data_dict_lookup(value, LAUNCH_JOBKEY_LASTEXITSTATUS);
  if (status != NULL && launch_data_get_type(status) == LAUNCH_DATA_INTEGER) {
    job[@"status"] = @(launch_data_get_integer(status));
  }
  launch_data_t demand = launch_data_dict_lookup(value, LAUNCH_JOBKEY_ONDEMAND);
  if (demand != NULL && launch_data_get_type(demand) == LAUNCH_DATA_BOOL) {
    job[@"keptRunning"] = @(!launch_data_get_bool(demand));
  }
  launch_data_t program = launch_data_dict_lookup(value, LAUNCH_JOBKEY_PROGRAM);
  if (program != NULL && launch_data_get_type(program) == LAUNCH_DATA_STRING) {
    NSString *path = [NSString stringWithUTF8String:launch_data_get_string(program)];
    if (path != nil) {
      job[@"program"] = path;
    }
  }
  launch_data_t arguments = launch_data_dict_lookup(value, LAUNCH_JOBKEY_PROGRAMARGUMENTS);
  if (arguments != NULL && launch_data_get_type(arguments) == LAUNCH_DATA_ARRAY) {
    NSMutableArray *list = [NSMutableArray new];
    size_t count = launch_data_array_get_count(arguments);
    for (size_t index = 0; index < count; index++) {
      launch_data_t item = launch_data_array_get_index(arguments, index);
      if (item == NULL || launch_data_get_type(item) != LAUNCH_DATA_STRING) {
        continue;
      }
      NSString *argument = [NSString stringWithUTF8String:launch_data_get_string(item)];
      if (argument != nil) {
        [list addObject:argument];
      }
    }
    job[@"arguments"] = list;
    if (job[@"program"] == nil && list.count > 0) {
      job[@"program"] = list[0];
    }
  }
  jobs[label] = job;
}

NSDictionary<NSString *, NSDictionary *> *FLLaunchJobs(void) {
  launch_data_t message = launch_data_new_string(LAUNCH_KEY_GETJOBS);
  if (message == NULL) {
    return nil;
  }
  launch_data_t reply = launch_msg(message);
  launch_data_free(message);
  if (reply == NULL) {
    return nil;
  }
  NSMutableDictionary *jobs = nil;
  if (launch_data_get_type(reply) == LAUNCH_DATA_DICTIONARY) {
    jobs = [NSMutableDictionary new];
    launch_data_dict_iterate(reply, FLAddLaunchJob, (__bridge void *)jobs);
  }
  launch_data_free(reply);
  return jobs;
}

NSString *FLDescribeExit(NSInteger status) {
  if ((status & 0x7f) == 0) {
    return [NSString stringWithFormat:@"exit code %ld", (long)((status >> 8) & 0xff)];
  }
  return [NSString stringWithFormat:@"signal %ld", (long)(status & 0x7f)];
}

NSArray<NSDictionary *> *FLServiceTable(NSDictionary<NSString *, NSDictionary *> *jobs,
                                        NSArray<NSDictionary *> *definitions) {
  NSMutableDictionary<NSString *, NSMutableDictionary *> *rows = [NSMutableDictionary new];
  for (NSDictionary *definition in definitions) {
    if (rows[definition[@"label"]] != nil && [definition[@"elsewhere"] boolValue]) {
      continue;
    }
    NSMutableDictionary *row = [definition mutableCopy];
    row[@"loaded"] = @NO;
    row[@"pid"] = @0;
    rows[definition[@"label"]] = row;
  }
  for (NSString *label in jobs) {
    NSDictionary *job = jobs[label];
    NSMutableDictionary *row = rows[label];
    if (row == nil) {
      row = [NSMutableDictionary new];
      row[@"label"] = label;
      rows[label] = row;
    }
    row[@"loaded"] = @YES;
    row[@"pid"] = job[@"pid"] ?: @0;
    if (job[@"status"] != nil) {
      row[@"status"] = job[@"status"];
    }
    if (job[@"keptRunning"] != nil) {
      row[@"keptRunning"] = job[@"keptRunning"];
    }
    if ([job[@"program"] length] > 0) {
      row[@"program"] = job[@"program"];
    }
    if ([job[@"arguments"] count] > 0) {
      row[@"arguments"] = job[@"arguments"];
    }
  }
  return [rows.allValues sortedArrayUsingComparator:^(NSDictionary *first,
                                                      NSDictionary *second) {
    return [first[@"label"] caseInsensitiveCompare:second[@"label"]];
  }];
}

NSString *FLServiceStarts(NSDictionary *service) {
  NSMutableArray *flags = [NSMutableArray new];
  if ([service[@"elsewhere"] boolValue]) {
    [flags addObject:@"not loaded on this model"];
  }
  if ([service[@"runAtLoad"] boolValue]) {
    [flags addObject:@"at boot"];
  }
  if ([service[@"keepAlive"] boolValue] || [service[@"keptRunning"] boolValue]) {
    [flags addObject:@"kept running"];
  }
  if ([service[@"onDemand"] boolValue]) {
    [flags addObject:@"when something asks for it"];
  }
  if ([service[@"onEvent"] boolValue]) {
    [flags addObject:@"on a system event"];
  }
  if ([service[@"onPath"] boolValue]) {
    [flags addObject:@"when a watched path changes"];
  }
  if ([service[@"onTimer"] boolValue]) {
    [flags addObject:@"on a timer"];
  }
  if ([service[@"disabled"] boolValue]) {
    [flags addObject:@"disabled"];
  }
  if (service[@"file"] == nil) {
    [flags addObject:@"when another program asks launchd for it"];
  }
  return flags.count > 0 ? [flags componentsJoinedByString:@", "] : @"when launchd decides";
}

static NSString *FLCollectServices(void) {
  NSDictionary *jobs = FLLaunchJobs();
  NSArray *services = FLServiceTable(jobs, FLLaunchServices());
  NSMutableString *text = [NSMutableString new];
  NSUInteger loaded = 0;
  NSUInteger active = 0;
  NSMutableString *rows = [NSMutableString new];
  for (NSDictionary *service in services) {
    int pid = [service[@"pid"] intValue];
    NSString *state = @"not loaded";
    if (jobs == nil) {
      state = @"unknown";
    } else if ([service[@"loaded"] boolValue]) {
      loaded++;
      state = @"not running";
      if (pid > 0) {
        active++;
        state = [NSString stringWithFormat:@"running as pid %d", pid];
      }
    }
    NSString *last = service[@"status"] == nil
      ? @""
      : FLDescribeExit([service[@"status"] integerValue]);
    NSArray *arguments = service[@"arguments"];
    NSString *command = arguments.count > 0 ? [arguments componentsJoinedByString:@" "]
                                            : (service[@"program"] ?: @"");
    [rows appendFormat:@"%@\t%@\t%@\t%@\t%@\t%@\n", service[@"label"], state, last,
                       FLServiceStarts(service), FLEscape(command), service[@"file"] ?: @""];
  }
  if (jobs == nil) {
    [text appendFormat:@"launchd did not answer, so only the %lu services defined on disk "
                       @"are listed\n",
                       (unsigned long)services.count];
  } else {
    [text appendFormat:@"%lu services known, %lu loaded by launchd, %lu with a running "
                       @"process\n",
                       (unsigned long)services.count, (unsigned long)loaded,
                       (unsigned long)active];
  }
  [text appendString:@"label\tstate\tlast exit\tstarts\tcommand\tdefined in\n"];
  [text appendString:rows];
  return text;
}

NSArray<NSDictionary *> *FLInstalledApps(void) {
  NSMutableArray *apps = [NSMutableArray new];
  NSFileManager *manager = [NSFileManager defaultManager];
  NSMutableArray *bundles = [NSMutableArray new];
  for (NSString *name in [manager contentsOfDirectoryAtPath:@"/Applications" error:NULL]) {
    if ([name.pathExtension isEqualToString:@"app"]) {
      [bundles addObject:@[ [@"/Applications" stringByAppendingPathComponent:name],
                            @"system" ]];
    }
  }
  for (NSString *root in @[
         @"/var/containers/Bundle/Application", @"/var/mobile/Containers/Bundle/Application"
       ]) {
    for (NSString *container in [manager contentsOfDirectoryAtPath:root error:NULL]) {
      NSString *folder = [root stringByAppendingPathComponent:container];
      for (NSString *name in [manager contentsOfDirectoryAtPath:folder error:NULL]) {
        if ([name.pathExtension isEqualToString:@"app"]) {
          [bundles addObject:@[ [folder stringByAppendingPathComponent:name], @"user" ]];
        }
      }
    }
  }
  NSMutableSet *seen = [NSMutableSet new];
  for (NSArray *bundle in bundles) {
    NSDictionary *info = FLBundleInfo(bundle[0]);
    NSString *key = [NSString stringWithFormat:@"%@|%@", info[@"identifier"] ?: bundle[0],
                                               [bundle[0] lastPathComponent]];
    if ([seen containsObject:key]) {
      continue;
    }
    [seen addObject:key];
    NSMutableDictionary *app = [info mutableCopy];
    app[@"path"] = bundle[0];
    app[@"kind"] = bundle[1];
    [apps addObject:app];
  }
  [apps sortUsingComparator:^(NSDictionary *first, NSDictionary *second) {
    return [first[@"name"] caseInsensitiveCompare:second[@"name"]];
  }];
  return apps;
}

static NSString *FLCollectApps(void) {
  NSArray *apps = FLInstalledApps();
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"%lu apps installed\n", (unsigned long)apps.count];
  [text appendString:@"name\tidentifier\tversion\tkind\tpath\n"];
  for (NSDictionary *app in apps) {
    NSString *kind = [app[@"hidden"] boolValue]
      ? [app[@"kind"] stringByAppendingString:@", hidden"]
      : app[@"kind"];
    [text appendFormat:@"%@\t%@\t%@\t%@\t%@\n", app[@"name"], app[@"identifier"] ?: @"",
                       app[@"version"] ?: @"", kind, app[@"path"]];
  }
  return text;
}

NSArray<NSDictionary *> *FLInstalledPackages(void) {
  NSData *data = [NSData dataWithContentsOfFile:@"/var/lib/dpkg/status"];
  NSMutableArray *packages = [NSMutableArray new];
  if (data == nil) {
    return packages;
  }
  NSString *status = FLStringFromData(data);
  for (NSString *paragraph in [status componentsSeparatedByString:@"\n\n"]) {
    NSMutableDictionary *fields = [NSMutableDictionary new];
    for (NSString *line in [paragraph componentsSeparatedByString:@"\n"]) {
      NSRange colon = [line rangeOfString:@": "];
      if (colon.location == NSNotFound || [line hasPrefix:@" "]) {
        continue;
      }
      NSString *key = [line substringToIndex:colon.location];
      if (fields[key] == nil) {
        fields[key] = [line substringFromIndex:NSMaxRange(colon)];
      }
    }
    NSString *state = fields[@"Status"];
    BOOL placeholder = [fields[@"Tag"] containsString:@"role::cydia"];
    if (fields[@"Package"] == nil || placeholder || ![state hasSuffix:@" installed"]) {
      continue;
    }
    [packages addObject:fields];
  }
  [packages sortUsingComparator:^(NSDictionary *first, NSDictionary *second) {
    return [first[@"Package"] compare:second[@"Package"]];
  }];
  return packages;
}

static NSString *FLCollectPackages(void) {
  NSArray *packages = FLInstalledPackages();
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"%lu packages installed by dpkg\n", (unsigned long)packages.count];
  [text appendString:@"package\tversion\tname\tsection\tsize\n"];
  for (NSDictionary *fields in packages) {
    NSString *size = fields[@"Installed-Size"] == nil
      ? @""
      : FLFormatBytes([fields[@"Installed-Size"] longLongValue] * 1024);
    [text appendFormat:@"%@\t%@\t%@\t%@\t%@\n", fields[@"Package"],
                       fields[@"Version"] ?: @"", fields[@"Name"] ?: @"",
                       fields[@"Section"] ?: @"", size];
  }
  return text;
}

static NSString *FLCollectNetwork(void) {
  NSMutableString *text = [NSMutableString new];
  NSDictionary *wireless = FLWirelessNetwork();
  if (wireless.count > 0) {
    [text appendFormat:@"Wi-Fi network %@ (%@) on %@\n", wireless[@"ssid"] ?: @"",
                       wireless[@"bssid"] ?: @"", wireless[@"interface"] ?: @""];
  } else {
    [text appendString:@"Not joined to a Wi-Fi network\n"];
  }
  for (FLInterface *interface in FLInterfaces()) {
    [text appendFormat:@"%@: %@%@, flags 0x%x\n", interface.name,
                       [interface isUp] ? @"up" : @"down",
                       [interface isLoopback] ? @", loopback" : @"", interface.flags];
    if (interface.hardwareAddress != nil) {
      [text appendFormat:@"    hardware address %@\n", interface.hardwareAddress];
    }
    for (NSString *address in interface.addresses) {
      [text appendFormat:@"    address %@\n", address];
    }
    [text appendFormat:@"    received %@ in %llu packets (%llu errors), sent %@ in %llu "
                       @"packets (%llu errors)\n",
                       FLFormatBytes(interface.receivedBytes), interface.receivedPackets,
                       interface.receiveErrors, FLFormatBytes(interface.sentBytes),
                       interface.sentPackets, interface.sendErrors];
  }
  CFTypeRef (*create)(CFAllocatorRef, CFStringRef, void *, void *) =
    FLSymbol(NULL, "SCDynamicStoreCreate");
  CFArrayRef (*copyKeys)(CFTypeRef, CFStringRef) =
    FLSymbol(NULL, "SCDynamicStoreCopyKeyList");
  CFTypeRef (*copyValue)(CFTypeRef, CFStringRef) =
    FLSymbol(NULL, "SCDynamicStoreCopyValue");
  if (create != NULL && copyKeys != NULL && copyValue != NULL) {
    CFTypeRef store = create(kCFAllocatorDefault, CFSTR("finchlog"), NULL, NULL);
    if (store != NULL) {
      NSArray *keys = CFBridgingRelease(copyKeys(store, CFSTR(".*")));
      keys = [keys sortedArrayUsingSelector:@selector(compare:)];
      [text appendFormat:@"\n%lu entries in the system's network configuration\n",
                         (unsigned long)keys.count];
      for (NSString *key in keys) {
        id value = CFBridgingRelease(copyValue(store, (__bridge CFStringRef)key));
        [text appendFormat:@"%@ = %@\n", key, FLDescribeValue(value)];
      }
      CFRelease(store);
    }
  }
  return text;
}

static NSString *FLCollectPower(void) {
  NSMutableString *text = [NSMutableString new];
  NSDictionary *battery = FLBatteryProperties();
  [text appendFormat:@"Battery: %@\n", FLBatterySummary(battery)];
  struct timeval moment;
  size_t size = sizeof(moment);
  if (sysctlbyname("kern.sleeptime", &moment, &size, NULL, 0) == 0 && moment.tv_sec > 0) {
    [text appendFormat:@"Last went to sleep at %@\n",
                       FLFormatDay([NSDate dateWithTimeIntervalSince1970:moment.tv_sec])];
  }
  size = sizeof(moment);
  if (sysctlbyname("kern.waketime", &moment, &size, NULL, 0) == 0 && moment.tv_sec > 0) {
    [text appendFormat:@"Last woke at %@\n",
                       FLFormatDay([NSDate dateWithTimeIntervalSince1970:moment.tv_sec])];
  }
  int (*copyAssertions)(CFDictionaryRef *) =
    FLSymbol(NULL, "IOPMCopyAssertionsByProcess");
  if (copyAssertions != NULL) {
    CFDictionaryRef assertions = NULL;
    if (copyAssertions(&assertions) == 0 && assertions != NULL) {
      NSDictionary *byProcess = CFBridgingRelease(assertions);
      [text appendFormat:@"\n%lu processes hold power assertions\n",
                         (unsigned long)byProcess.count];
      for (NSNumber *pid in byProcess) {
        FLProcess *process = FLProcessWithIdentifier(pid.intValue);
        [text appendFormat:@"%@ (pid %@): %@\n", [process displayName] ?: @"unknown", pid,
                           FLDescribeValue(byProcess[pid])];
      }
    }
  }
  [text appendString:@"\nEverything the battery reports\n"];
  NSArray *keys = [battery.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *key in keys) {
    [text appendFormat:@"%@ = %@\n", key, FLDescribeValue(battery[key])];
  }
  return text;
}

static NSString *FLCollectEnvironment(void) {
  NSMutableString *text = [NSMutableString new];
  struct utsname name;
  uname(&name);
  NSDate *boot = FLBootTime();
  [text appendFormat:@"Finch Logs %@\n", FLVersion];
  [text appendFormat:@"Host name: %s\n", name.nodename];
  [text appendFormat:@"Machine: %s\n", name.machine];
  [text appendFormat:@"Kernel: %s %s\n", name.sysname, name.release];
  [text appendFormat:@"Kernel version: %s\n", name.version];
  [text appendFormat:@"System build: %@\n", FLSysctlString(@"kern.osversion") ?: @""];
  [text appendFormat:@"Boot arguments: %@\n", FLSysctlString(@"kern.bootargs") ?: @""];
  if (boot != nil) {
    [text appendFormat:@"Started: %@ (%@ ago)\n", FLFormatDay(boot),
                       FLFormatDuration(FLUptime())];
  }
  NSTimeZone *zone = [NSTimeZone localTimeZone];
  [text appendFormat:@"Time zone: %@ (%@)\n", zone.name, zone.abbreviation ?: @""];
  [text appendFormat:@"Locale: %@\n", [NSLocale currentLocale].localeIdentifier];
  [text appendFormat:@"Processors: %lu, %lu active\n",
                     (unsigned long)[NSProcessInfo processInfo].processorCount,
                     (unsigned long)[NSProcessInfo processInfo].activeProcessorCount];
  [text appendFormat:@"Memory: %@\n",
                     FLFormatBytes([NSProcessInfo processInfo].physicalMemory)];
  [text appendFormat:@"Running as: %@ (uid %d), pid %d\n", FLUserName(getuid()),
                     (int)getuid(), (int)getpid()];
  [text appendString:@"\nUsers\n"];
  setpwent();
  struct passwd *user = NULL;
  while ((user = getpwent()) != NULL) {
    [text appendFormat:@"%s\tuid %d\tgid %d\t%s\t%s\n", user->pw_name, (int)user->pw_uid,
                       (int)user->pw_gid, user->pw_dir, user->pw_shell];
  }
  endpwent();
  [text appendString:@"\nGroups\n"];
  setgrent();
  struct group *group = NULL;
  while ((group = getgrent()) != NULL) {
    NSMutableArray *members = [NSMutableArray new];
    for (char **member = group->gr_mem; member != NULL && *member != NULL; member++) {
      [members addObject:@(*member)];
    }
    [text appendFormat:@"%s\tgid %d\t%@\n", group->gr_name, (int)group->gr_gid,
                       [members componentsJoinedByString:@", "]];
  }
  endgrent();
  return text;
}

NSString *FLKernelMessages(void) {
  int64_t size = 0;
  if (!FLSysctlNumber(@"kern.msgbuf", &size) || size <= 0 || size > 4 * 1024 * 1024) {
    size = 256 * 1024;
  }
  char *buffer = calloc(1, (size_t)size + 1);
  int filled = proc_kmsgbuf(buffer, (uint32_t)size);
  while (filled > 0 && buffer[filled - 1] == '\0') {
    filled--;
  }
  NSString *text = @"";
  if (filled > 0) {
    NSMutableData *data = [NSMutableData dataWithBytes:buffer length:(NSUInteger)filled];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < data.length; index++) {
      if (bytes[index] == 0) {
        bytes[index] = '\n';
      }
    }
    text = FLStringFromData(data);
  }
  free(buffer);
  return text;
}

static NSString *FLCollectKernelLog(void) {
  NSString *messages = FLKernelMessages();
  return messages.length > 0 ? messages : @"The kernel's message buffer could not be read.\n";
}

NSString *FLSnapshotHeading(NSString *kind, NSString *why, NSDate *taken) {
  struct utsname name;
  uname(&name);
  return [NSString stringWithFormat:@"%@\nTaken: %@\nDevice: %s (%s)\nReason: %@\n\n",
                                    FLCollectTitle(kind), FLTimestamp(taken), name.nodename,
                                    name.machine, why];
}

NSArray<NSString *> *FLCollectKinds(void) {
  return @[
    @"environment", @"device", @"processes", @"services", @"apps", @"packages",
    @"volumes", @"network", @"power", @"kernel", @"extensions", @"sysctl", @"registry",
    @"usage"
  ];
}

NSString *FLCollectTitle(NSString *kind) {
  NSDictionary *titles = @{
    @"environment" : @"System, users and groups",
    @"device" : @"What the device says about itself",
    @"processes" : @"Every running process",
    @"services" : @"Services launchd knows",
    @"apps" : @"Installed apps",
    @"packages" : @"Installed packages",
    @"volumes" : @"Mounted volumes",
    @"network" : @"Network interfaces and configuration",
    @"power" : @"Battery and power",
    @"kernel" : @"Kernel message buffer",
    @"extensions" : @"Loaded kernel extensions",
    @"sysctl" : @"Kernel settings and counters",
    @"registry" : @"Hardware in the I/O Registry",
    @"usage" : @"What has run and what never has",
    @"inventory" : @"What is installed",
    @"dependencies" : @"What depends on what",
  };
  return titles[kind] ?: kind;
}

NSString *FLCollect(NSString *kind) {
  @autoreleasepool {
    if ([kind isEqualToString:@"environment"]) {
      return FLCollectEnvironment();
    }
    if ([kind isEqualToString:@"device"]) {
      return FLCollectGestalt();
    }
    if ([kind isEqualToString:@"processes"]) {
      return FLCollectProcesses();
    }
    if ([kind isEqualToString:@"services"]) {
      return FLCollectServices();
    }
    if ([kind isEqualToString:@"apps"]) {
      return FLCollectApps();
    }
    if ([kind isEqualToString:@"packages"]) {
      return FLCollectPackages();
    }
    if ([kind isEqualToString:@"volumes"]) {
      return FLCollectVolumes();
    }
    if ([kind isEqualToString:@"network"]) {
      return FLCollectNetwork();
    }
    if ([kind isEqualToString:@"power"]) {
      return FLCollectPower();
    }
    if ([kind isEqualToString:@"kernel"]) {
      return FLCollectKernelLog();
    }
    if ([kind isEqualToString:@"extensions"]) {
      return FLCollectKexts();
    }
    if ([kind isEqualToString:@"sysctl"]) {
      return FLCollectSysctl();
    }
    if ([kind isEqualToString:@"registry"]) {
      return FLCollectRegistry();
    }
    if ([kind isEqualToString:@"usage"]) {
      return FLUsageText(FLUsageReport(FLCurrentUsage()), NO);
    }
    return nil;
  }
}

BOOL FLCollectPieces(NSString *kind, void (^write)(NSString *piece)) {
  if ([kind isEqualToString:@"registry"]) {
    FLWriteRegistry(write);
    return YES;
  }
  NSString *text = FLCollect(kind);
  if (text == nil) {
    return NO;
  }
  write(text);
  return YES;
}
