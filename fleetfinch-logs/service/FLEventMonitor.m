#import "FLMonitors.h"

#import <notify.h>

#import "FLSystemInfo.h"

static const NSTimeInterval FLRepeatWindow = 600;
static const int64_t FLNormalPressure = 1;

static NSArray<NSString *> *FLWatchedNotifications(void) {
  return @[
    @"com.apple.springboard.lockstate",
    @"com.apple.springboard.lockcomplete",
    @"com.apple.springboard.hasBlankedScreen",
    @"com.apple.springboard.finishedstartup",
    @"com.apple.springboard.pluggedin",
    @"com.apple.springboard.fullycharged",
    @"com.apple.springboard.ringerstate",
    @"com.apple.springboard.homescreenunlocked",
    @"com.apple.springboard.passcodeLockedOrBlocked",
    @"com.apple.springboard.lowPowerAlertPresented",
    @"SBSpringBoardDidLaunchNotification",
    @"com.apple.iokit.hid.displayStatus",
    @"com.apple.backboardd.backlight.changed",
    @"com.apple.backboardd.orientation",
    @"com.apple.system.lowdiskspace",
    @"com.apple.system.verylowdiskspace",
    @"com.apple.system.lowdiskspace.system",
    @"com.apple.system.lowdiskspace.user",
    @"com.apple.system.timezone",
    @"com.apple.system.clock_set",
    @"com.apple.system.hostname",
    @"com.apple.system.config.network_change",
    @"com.apple.system.config.network_change.dns",
    @"com.apple.system.config.network_change.nwi",
    @"com.apple.system.powersources.source",
    @"com.apple.system.powersources.timeremaining",
    @"com.apple.system.powersources.criticallevel",
    @"com.apple.system.powermanagement.poweradapter",
    @"com.apple.system.powermanagement.useractivity",
    @"com.apple.system.powermanagement.SystemLoadAdvisory",
    @"com.apple.system.lowpowermode",
    @"com.apple.system.thermalstatus",
    @"com.apple.system.thermalpressurelevel",
    @"com.apple.system.memorystatus",
    @"com.apple.system.loginwindow.shutdownInitiated",
    @"com.apple.mobile.application_installed",
    @"com.apple.mobile.application_uninstalled",
    @"com.apple.LaunchServices.ApplicationsChanged",
    @"com.apple.mobile.keybagd.lock_status",
    @"com.apple.mobile.keybagd.first_unlock",
    @"com.apple.mobile.lockdown.device_name_changed",
    @"com.apple.mobile.lockdown.host_attached",
    @"com.apple.mobile.lockdown.host_detached",
    @"com.apple.mobile.lockdown.trusted_host_attached",
    @"com.apple.mobile.lockdown.activation_state",
    @"com.apple.mobile.lockdown.developer_status_changed",
    @"com.apple.mobile.lockdown.timezone_changed",
    @"com.apple.mobile.developer_image_mounted",
    @"com.apple.mobile.data_sync.domain_changed",
    @"com.apple.itunes-mobdev.syncWillStart",
    @"com.apple.itunes-mobdev.syncDidStart",
    @"com.apple.itunes-mobdev.syncDidFinish",
    @"com.apple.itunes-client.syncCancelRequest",
    @"com.apple.mobile.backup.domain_changed",
    @"com.apple.language.changed",
    @"com.apple.locale.changed",
    @"AppleLanguagePreferencesChangedNotification",
    @"AppleDatePreferencesChangedNotification",
    @"AppleTimePreferencesChangedNotification",
    @"com.apple.bluetooth.state",
    @"com.apple.bluetooth.pairing",
    @"com.apple.wifi.manager.available",
    @"com.apple.airplay.active",
    @"com.apple.coreaudio.audiodevice.connected",
    @"com.apple.MobileSoftwareUpdate.availableUpdate",
    @"com.apple.softwareupdate.autoinstall.startInstall",
    @"com.apple.ManagedConfiguration.profileListChanged",
    @"com.apple.ManagedConfiguration.passcodeChanged",
    @"com.apple.Preferences.ResetPrivacyWarningsNotification",
    @"com.apple.mobile.keybagd.user_changed",
    @"com.apple.datamigrator.migrationDidFinish",
    @"com.apple.accessories.connection.changed",
    @"com.apple.iapd.accessoryDidConnect",
    @"com.apple.iapd.accessoryDidDisconnect",
    @"com.apple.mobile.usb.attached",
    @"com.apple.stackshot",
    @"com.apple.ReportCrash.Jetsam",
    @"com.apple.crashreporter.crash_complete",
    @"com.apple.OSAnalytics.logWritten",
    @"com.apple.mobileinstallation.install_completed",
    @"com.saurik.Cydia.Startup"
  ];
}

static NSString *FLPlainEvent(NSString *name, uint64_t state) {
  if ([name isEqualToString:@"com.apple.springboard.lockstate"]) {
    return state != 0 ? @"the device locked" : @"the device unlocked";
  }
  if ([name isEqualToString:@"com.apple.springboard.hasBlankedScreen"]) {
    return state != 0 ? @"the screen turned off" : @"the screen turned on";
  }
  if ([name isEqualToString:@"com.apple.iokit.hid.displayStatus"]) {
    return state != 0 ? @"the display is on" : @"the display is off";
  }
  if ([name isEqualToString:@"com.apple.springboard.pluggedin"]) {
    return state != 0 ? @"external power was connected" : @"external power was removed";
  }
  if ([name isEqualToString:@"com.apple.springboard.fullycharged"]) {
    return state != 0 ? @"the battery is fully charged" : nil;
  }
  if ([name isEqualToString:@"com.apple.system.lowpowermode"]) {
    return state != 0 ? @"Low Power Mode turned on" : @"Low Power Mode turned off";
  }
  return nil;
}

@implementation FLEventMonitor {
  NSMutableArray<NSNumber *> *_tokens;
  dispatch_source_t _pressure;
  NSMutableArray *_observers;
  NSMutableDictionary<NSString *, NSNumber *> *_states;
  NSMutableDictionary<NSString *, NSDate *> *_noted;
  NSMutableDictionary<NSString *, NSNumber *> *_repeats;
}

- (BOOL)shouldNote:(NSString *)name state:(uint64_t)state repeats:(NSUInteger *)repeats {
  NSNumber *previous = _states[name];
  NSDate *noted = _noted[name];
  BOOL same = previous != nil && previous.unsignedLongLongValue == state;
  if (same && noted != nil && -noted.timeIntervalSinceNow < FLRepeatWindow) {
    _repeats[name] = @(_repeats[name].unsignedIntegerValue + 1);
    return NO;
  }
  *repeats = _repeats[name].unsignedIntegerValue;
  _states[name] = @(state);
  _noted[name] = [NSDate date];
  [_repeats removeObjectForKey:name];
  return YES;
}

- (void)startOnQueue:(dispatch_queue_t)queue
            network:(void (^)(void))network
              power:(void (^)(void))power
               apps:(void (^)(void))apps {
  _tokens = [NSMutableArray new];
  _observers = [NSMutableArray new];
  _states = [NSMutableDictionary new];
  _noted = [NSMutableDictionary new];
  _repeats = [NSMutableDictionary new];
  __weak FLEventMonitor *weak = self;
  for (NSString *name in FLWatchedNotifications()) {
    int token = 0;
    uint32_t status =
      notify_register_dispatch(name.UTF8String, &token, queue, ^(int fired) {
        uint64_t state = 0;
        notify_get_state(fired, &state);
        NSUInteger repeats = 0;
        if ([weak shouldNote:name state:state repeats:&repeats]) {
          NSString *again = repeats == 0
            ? @""
            : [NSString stringWithFormat:@", after posting the same %lu more times",
                                         (unsigned long)repeats];
          FLNote(@"event", FLLevelInfo, @"notification", @"%@ (state %llu)%@", name, state,
                 again);
          NSString *plain = FLPlainEvent(name, state);
          if (plain != nil) {
            FLNote(@"power", FLLevelNotice, @"system", @"%@", plain);
          }
        }
        if ([name hasPrefix:@"com.apple.system.config.network_change"] && network != nil) {
          network();
        }
        if (([name containsString:@"powersources"] || [name containsString:@"pluggedin"] ||
             [name containsString:@"fullycharged"]) &&
            power != nil) {
          power();
        }
        if (([name containsString:@"application_"] || [name containsString:@"install_completed"] ||
             [name containsString:@"ApplicationsChanged"]) &&
            apps != nil) {
          apps();
        }
      });
    if (status == NOTIFY_STATUS_OK) {
      [_tokens addObject:@(token)];
    }
  }

  _pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                     DISPATCH_MEMORYPRESSURE_NORMAL |
                                       DISPATCH_MEMORYPRESSURE_WARN |
                                       DISPATCH_MEMORYPRESSURE_CRITICAL,
                                     queue);
  if (_pressure != nil) {
    dispatch_source_t source = _pressure;
    dispatch_source_set_event_handler(source, ^{
      unsigned long level = dispatch_source_get_data(source);
      NSString *text = @"back to normal";
      FLLevel severity = FLLevelNotice;
      if (level & DISPATCH_MEMORYPRESSURE_CRITICAL) {
        text = @"critical";
        severity = FLLevelError;
      } else if (level & DISPATCH_MEMORYPRESSURE_WARN) {
        text = @"warning";
        severity = FLLevelWarning;
      }
      int64_t whole = 0;
      int64_t available = 0;
      BOOL measured = FLSysctlNumber(@"kern.memorystatus_vm_pressure_level", &whole);
      NSString *room = FLSysctlNumber(@"kern.memorystatus_level", &available)
        ? [NSString stringWithFormat:@"; %lld%% of memory is available", available]
        : @"";
      if (measured && whole <= FLNormalPressure && severity != FLLevelNotice) {
        FLNote(@"event", FLLevelWarning, @"memory",
               @"iOS warned Finch Logs that it is close to the memory it may use, while the "
               @"device as a whole is not short%@",
               room);
        return;
      }
      FLNote(@"event", severity, @"memory", @"memory pressure is %@%@", text, room);
    });
    dispatch_resume(source);
  }

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  NSOperationQueue *operations = [NSOperationQueue new];
  operations.underlyingQueue = queue;
  [_observers addObject:[center addObserverForName:NSSystemClockDidChangeNotification
                                            object:nil
                                             queue:operations
                                        usingBlock:^(NSNotification *note) {
                                          FLNote(@"event", FLLevelNotice, @"clock",
                                                 @"the system clock was set");
                                        }]];
  [_observers addObject:[center addObserverForName:NSSystemTimeZoneDidChangeNotification
                                            object:nil
                                             queue:operations
                                        usingBlock:^(NSNotification *note) {
                                          FLNote(@"event", FLLevelNotice, @"clock",
                                                 @"the time zone changed to %@",
                                                 [NSTimeZone localTimeZone].name);
                                        }]];
  FLNote(@"finchlogs", FLLevelInfo, @"events", @"Watching %lu system notifications",
         (unsigned long)_tokens.count);
}

@end
