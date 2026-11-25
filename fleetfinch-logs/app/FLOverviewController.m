#import "FLOverviewController.h"

#import "FLInventoryController.h"
#import "FLReader.h"
#import "FLSettings.h"
#import "FLStatus.h"
#import "FLTheme.h"
#import "FLUsageController.h"

static const NSTimeInterval FLFreshFor = 20;

@implementation FLOverviewController

- (instancetype)init {
  self = [super initGrouped:YES];
  if (self) {
    self.title = @"Overview";
    self.refreshInterval = 5;
    self.watchesService = YES;
  }
  return self;
}

- (NSDictionary *)resourcesFrom:(NSDictionary *)status {
  NSDictionary *live = FLServiceLive();
  NSDate *written = live[@"written"];
  if ([written isKindOfClass:[NSDate class]] && -written.timeIntervalSinceNow < FLFreshFor &&
      [live[@"resources"] isKindOfClass:[NSDictionary class]]) {
    return live[@"resources"];
  }
  return [status[@"resources"] isKindOfClass:[NSDictionary class]] ? status[@"resources"] : @{};
}

- (NSString *)volumeTitle:(NSString *)mount {
  if ([mount isEqualToString:@"/"]) {
    return @"System storage";
  }
  if ([mount isEqualToString:@"/private/var"]) {
    return @"Data storage";
  }
  return mount;
}

- (void)send:(NSString *)command saying:(NSString *)message {
  if (!FLServiceRunning(FLServiceStatus())) {
    [self showMessage:@"The Finch Logs service is not running, so there is nothing to ask."
                title:@"Service Not Running"];
    return;
  }
  FLPostCommand(command);
  [self showMessage:message title:nil];
}

- (NSArray<FLSection *> *)buildSections {
  NSDictionary *status = FLServiceStatus();
  BOOL running = FLServiceRunning(status);
  NSMutableArray *sections = [NSMutableArray new];

  FLSection *service = [FLSection sectionWithTitle:@"Service"];
  NSDate *started = status[@"started"];
  FLRow *state = [service
       add:@"Finch Logs service"
    detail:running ? [NSString stringWithFormat:@"Running for %@",
                                                FLFormatDuration(-started.timeIntervalSinceNow)]
                   : @"Not running"];
  if (!running) {
    state.titleColor = FLDangerColor();
    service.footer = @"The service starts with the device and restarts itself if it stops. If it "
                     @"stays stopped, restart the device or install Finch Logs again.";
  }
  [service add:@"Version" detail:status[@"version"] ?: FLVersion];
  if (running) {
    [service add:@"System log"
          detail:[status[@"systemLogConnected"] boolValue]
                   ? [NSString stringWithFormat:@"Connected, %@ messages",
                                                status[@"systemLogMessages"] ?: @0]
                   : @"Not connected"];
  }
  [sections addObject:service];

  FLSection *device = [FLSection sectionWithTitle:@"Device"];
  NSDate *boot = status[@"bootTime"];
  if ([boot isKindOfClass:[NSDate class]]) {
    [device add:@"Started"
         detail:[NSString stringWithFormat:@"%@ (%@)", FLFormatDay(boot), FLAgo(boot)]];
  }
  if (running) {
    [device add:@"Processes" detail:[status[@"processes"] description] ?: @"0"];
    [device add:@"Services"
         detail:[NSString stringWithFormat:@"%@ running of %@", status[@"runningServices"] ?: @0,
                                           status[@"services"] ?: @0]];
    NSString *front = status[@"frontApp"];
    [device add:@"In front" detail:front.length > 0 ? front : @"Home screen"];
  }
  if (device.rows.count > 0) {
    [sections addObject:device];
  }

  [FLUsageController ask];
  NSDictionary *report = [FLUsageController report];
  NSDictionary *counted = report[@"summary"];
  if ([counted isKindOfClass:[NSDictionary class]]) {
    FLSection *usage = [FLSection sectionWithTitle:@"What Has Run"];
    __weak FLOverviewController *weak = self;
    for (NSArray<NSString *> *kind in @[
           @[ @"app", @"Apps", @"never opened" ], @[ @"service", @"Services", @"never run" ],
           @[ @"program", @"Programs", @"never run" ]
         ]) {
      NSDictionary *counts = counted[kind[0]];
      NSString *detail = [NSString stringWithFormat:@"%@ of %@ %@", counts[@"never"] ?: @0,
                                                    counts[@"total"] ?: @0, kind[2]];
      [usage addRow:[FLRow linkWithTitle:kind[1]
                                  detail:detail
                                  action:^{
                                    [weak.navigationController
                                      pushViewController:[[FLUsageController alloc]
                                                           initWithKind:kind[0]
                                                              neverOnly:YES]
                                                animated:YES];
                                  }]];
    }
    NSDate *began = report[@"began"];
    usage.footer = [NSString
      stringWithFormat:@"Counted since %@, with the device awake for %@ of that time.",
                       [began isKindOfClass:[NSDate class]] ? FLFormatDay(began) : @"the start",
                       FLFormatDuration([report[@"watched"] doubleValue])];
    [sections addObject:usage];
  }

  FLSection *installed = [FLSection sectionWithTitle:@"What Is Installed"];
  NSDate *listed = [FLInventoryController listed];
  __weak FLOverviewController *owner = self;
  [installed
    addRow:[FLRow linkWithTitle:@"Everything Installed"
                         detail:listed == nil ? @"Not listed yet"
                                              : [@"Listed " stringByAppendingString:FLAgo(listed)]
                         action:^{
                           [owner.navigationController
                             pushViewController:[FLInventoryController new]
                                       animated:YES];
                         }]];
  installed.footer = @"Every app, service, framework, plug-in, program and library on the "
                     @"device, with its size and what it offers, and where the system volume's "
                     @"space goes.";
  [sections addObject:installed];

  NSDictionary *resources = [self resourcesFrom:status];
  if (running && resources.count > 0) {
    FLSection *now = [FLSection sectionWithTitle:@"Right Now"];
    if (resources[@"processor"] != nil) {
      [now add:@"Processor" detail:FLPercent([resources[@"processor"] doubleValue])];
    }
    NSArray *load = resources[@"load"];
    if ([load isKindOfClass:[NSArray class]] && load.count == 3) {
      [now add:@"Load"
        detail:[NSString stringWithFormat:@"%.2f  %.2f  %.2f", [load[0] doubleValue],
                                          [load[1] doubleValue], [load[2] doubleValue]]];
    }
    [now add:@"Memory"
      detail:[NSString
               stringWithFormat:@"%@ of %@",
                                FLFormatBytes([resources[@"memoryUsed"] unsignedLongLongValue]),
                                FLFormatBytes([resources[@"memoryTotal"] unsignedLongLongValue])]];
    for (NSDictionary *volume in resources[@"volumes"]) {
      [now add:[self volumeTitle:volume[@"mount"]]
        detail:[NSString
                 stringWithFormat:@"%@ free of %@",
                                  FLFormatBytes([volume[@"free"] unsignedLongLongValue]),
                                  FLFormatBytes([volume[@"total"] unsignedLongLongValue])]];
    }
    for (NSDictionary *interface in resources[@"interfaces"]) {
      NSString *address = interface[@"address"];
      [now add:[NSString stringWithFormat:@"Network %@", interface[@"name"]]
        detail:[NSString
                 stringWithFormat:@"%@%@%@/s in, %@/s out", address,
                                  address.length > 0 ? @" · " : @"",
                                  FLFormatBytes((uint64_t)[interface[@"received"] doubleValue]),
                                  FLFormatBytes((uint64_t)[interface[@"sent"] doubleValue])]];
    }
    if ([resources[@"battery"] length] > 0) {
      [now add:@"Battery" detail:resources[@"battery"]];
    }
    [sections addObject:now];
  }

  FLSection *store = [FLSection sectionWithTitle:@"Store"];
  NSDictionary *usage = status[@"usage"];
  if ([usage isKindOfClass:[NSDictionary class]] && usage.count > 0) {
    [store add:@"Logs"
        detail:[NSString
                 stringWithFormat:@"%@ in %@ files",
                                  FLFormatBytes([usage[@"liveBytes"] unsignedLongLongValue]),
                                  usage[@"liveFiles"] ?: @0]];
    [store add:@"Archive"
        detail:[NSString
                 stringWithFormat:@"%@ in %@ files",
                                  FLFormatBytes([usage[@"archiveBytes"] unsignedLongLongValue]),
                                  usage[@"archiveFiles"] ?: @0]];
  }
  NSDictionary *maintenance = status[@"maintenance"];
  if ([maintenance[@"at"] isKindOfClass:[NSDate class]]) {
    NSDictionary *result = maintenance[@"result"];
    [store add:@"Last tidied"
        detail:[NSString stringWithFormat:@"%@: %@ archived, %@ deleted",
                                          FLAgo(maintenance[@"at"]), result[@"archived"] ?: @0,
                                          @([result[@"deleted"] integerValue] +
                                            [result[@"trimmed"] integerValue])]];
  }
  NSDictionary *settings = [FLSettings current];
  store.footer = [NSString
    stringWithFormat:@"Logs older than %@ are compressed into the archive, and archives older "
                     @"than %@ are deleted. The store may grow to %@.",
                     FLFormatDuration([settings[FLSettingArchiveAfter] doubleValue]),
                     FLFormatDuration([settings[FLSettingDeleteAfter] doubleValue]),
                     FLFormatBytes((uint64_t)[settings[FLSettingStoreLimit] doubleValue])];
  [sections addObject:store];

  NSDictionary *counts = status[@"counts"];
  if (running && [counts isKindOfClass:[NSDictionary class]] && counts.count > 0) {
    FLSection *written = [FLSection sectionWithTitle:@"Lines Written Since the Service Started"];
    for (NSString *stream in [FLReader knownStreams]) {
      if (counts[stream] != nil) {
        [written add:[FLReader streamTitle:stream] detail:[counts[stream] description]];
      }
    }
    [sections addObject:written];
  }

  FLSection *actions = [FLSection sectionWithTitle:nil];
  __weak FLOverviewController *weak = self;
  [actions addRow:[FLRow buttonWithTitle:@"Take Snapshots Now"
                                  action:^{
                                    [weak send:FLCommandSnapshot
                                        saying:@"The service is taking a fresh snapshot of "
                                               @"everything. They appear under Logs in a few "
                                               @"seconds."];
                                  }]];
  [actions addRow:[FLRow buttonWithTitle:@"Tidy the Store Now"
                                  action:^{
                                    [weak send:FLCommandMaintain
                                        saying:@"The service is archiving old logs and deleting "
                                               @"old archives now."];
                                  }]];
  actions.footer = @"Snapshots are taken when the device starts and once a day. The store is "
                   @"tidied every hour.";
  [sections addObject:actions];
  return sections;
}

@end
