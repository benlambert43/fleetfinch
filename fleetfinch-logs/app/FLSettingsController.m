#import "FLSettingsController.h"

#import "FLReader.h"
#import "FLSettings.h"
#import "FLStatus.h"
#import "FLTheme.h"

static NSString *const FLSnapshotSwitch = @"snapshot";

@interface FLChoiceController : FLListController

- (instancetype)initWithTitle:(NSString *)title
                      choices:(NSArray<NSArray *> *)choices
                      current:(NSNumber *)current
                       footer:(NSString *)footer
                       choose:(void (^)(NSNumber *value))choose;

@end

@implementation FLChoiceController {
  NSArray<NSArray *> *_choices;
  NSNumber *_current;
  NSString *_footer;
  void (^_choose)(NSNumber *value);
}

- (instancetype)initWithTitle:(NSString *)title
                      choices:(NSArray<NSArray *> *)choices
                      current:(NSNumber *)current
                       footer:(NSString *)footer
                       choose:(void (^)(NSNumber *value))choose {
  self = [super initGrouped:YES];
  if (self) {
    self.title = title;
    self.hidesBottomBarWhenPushed = YES;
    _choices = [choices copy];
    _current = current;
    _footer = [footer copy];
    _choose = [choose copy];
  }
  return self;
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  __weak FLChoiceController *weak = self;
  for (NSArray *choice in _choices) {
    NSNumber *value = choice[1];
    FLRow *row = [FLRow rowWithTitle:choice[0] detail:nil];
    row.checked = [value isEqualToNumber:_current];
    row.action = ^{
      [weak pick:value];
    };
    [section addRow:row];
  }
  section.footer = _footer;
  return @[ section ];
}

- (void)pick:(NSNumber *)value {
  _current = value;
  if (_choose != nil) {
    _choose(value);
  }
  [self.navigationController popViewControllerAnimated:YES];
}

@end

@implementation FLSettingsController {
  NSArray<NSString *> *_switches;
}

- (instancetype)init {
  self = [super initGrouped:YES];
  if (self) {
    self.title = @"Settings";
    NSMutableArray *names = [[FLReader knownStreams] mutableCopy];
    [names removeObject:@"finchlogs"];
    [names addObject:FLSnapshotSwitch];
    _switches = names;
  }
  return self;
}

- (void)save:(NSDictionary *)changes {
  if (![FLSettings save:changes]) {
    [self showMessage:@"The setting could not be saved. Finch Logs may need to be installed "
                      @"again."
                title:@"Not Saved"];
    return;
  }
  FLPostCommand(FLCommandSettings);
  [self reload];
}

- (NSString *)labelFor:(NSNumber *)value among:(NSArray<NSArray *> *)choices {
  for (NSArray *choice in choices) {
    if ([choice[1] isEqualToNumber:value]) {
      return choice[0];
    }
  }
  return [value description];
}

- (FLRow *)choiceRow:(NSString *)title
                 key:(NSString *)key
             choices:(NSArray<NSArray *> *)choices
              footer:(NSString *)footer {
  NSNumber *current = [FLSettings current][key];
  __weak FLSettingsController *weak = self;
  return [FLRow linkWithTitle:title
                       detail:[self labelFor:current among:choices]
                       action:^{
                         FLChoiceController *picker =
                           [[FLChoiceController alloc] initWithTitle:title
                                                             choices:choices
                                                             current:current
                                                              footer:footer
                                                              choose:^(NSNumber *value) {
                                                                [weak save:@{key : value}];
                                                              }];
                         [weak.navigationController pushViewController:picker animated:YES];
                       }];
}

- (void)switched:(UISwitch *)sender {
  NSString *name = _switches[(NSUInteger)sender.tag];
  NSMutableArray *disabled = [[FLSettings current][FLSettingDisabledCollectors] mutableCopy]
                               ?: [NSMutableArray new];
  [disabled removeObject:name];
  if (!sender.isOn) {
    [disabled addObject:name];
  }
  [self save:@{FLSettingDisabledCollectors : disabled}];
}

- (NSArray<FLSection *> *)buildSections {
  NSMutableArray *sections = [NSMutableArray new];
  double hour = 60 * 60;
  double day = 24 * hour;
  double megabyte = 1024.0 * 1024.0;

  FLSection *keeping = [FLSection sectionWithTitle:@"Keeping Logs"];
  [keeping addRow:[self choiceRow:@"Archive logs after"
                              key:FLSettingArchiveAfter
                          choices:@[
                            @[ @"6 hours", @(6 * hour) ], @[ @"12 hours", @(12 * hour) ],
                            @[ @"1 day", @(day) ], @[ @"2 days", @(2 * day) ]
                          ]
                           footer:@"Older logs are compressed into the archive, where they "
                                  @"take about a tenth of the room."]];
  [keeping addRow:[self choiceRow:@"Delete archives after"
                              key:FLSettingDeleteAfter
                          choices:@[
                            @[ @"3 days", @(3 * day) ], @[ @"1 week", @(7 * day) ],
                            @[ @"2 weeks", @(14 * day) ], @[ @"30 days", @(30 * day) ]
                          ]
                           footer:@"Archived logs older than this are deleted for good."]];
  [keeping addRow:[self choiceRow:@"Largest the store may grow"
                              key:FLSettingStoreLimit
                          choices:@[
                            @[ @"250 MB", @(250 * megabyte) ], @[ @"500 MB", @(500 * megabyte) ],
                            @[ @"1 GB", @(1024 * megabyte) ], @[ @"2 GB", @(2048 * megabyte) ],
                            @[ @"4 GB", @(4096 * megabyte) ]
                          ]
                           footer:@"If the logs and archives together pass this size, the "
                                  @"oldest files are deleted first."]];
  keeping.footer = @"Logs older than a day are archived and archives older than a week are "
                   @"deleted, unless you choose otherwise here.";
  [sections addObject:keeping];

  FLSection *pace = [FLSection sectionWithTitle:@"How Often to Look"];
  [pace addRow:[self choiceRow:@"Processor, memory and battery"
                           key:FLSettingResourceInterval
                       choices:@[
                         @[ @"Every 10 seconds", @10 ], @[ @"Every 30 seconds", @30 ],
                         @[ @"Every minute", @60 ], @[ @"Every 5 minutes", @300 ]
                       ]
                        footer:@"How often one line of resource use is written."]];
  [pace addRow:[self choiceRow:@"Processes and services"
                           key:FLSettingProcessInterval
                       choices:@[
                         @[ @"Every 2 seconds", @2 ], @[ @"Every 5 seconds", @5 ],
                         @[ @"Every 15 seconds", @15 ], @[ @"Every minute", @60 ]
                       ]
                        footer:@"Processes are followed as the kernel reports them. This is "
                               @"how often that record is checked against the process table "
                               @"and launchd's services are compared."]];
  [pace addRow:[self choiceRow:@"Dumps and log files"
                           key:FLSettingImportInterval
                       choices:@[
                         @[ @"Every minute", @60 ], @[ @"Every 5 minutes", @300 ],
                         @[ @"Every 15 minutes", @900 ], @[ @"Every hour", @(hour) ]
                       ]
                        footer:@"How often new crash reports and dumps are copied in."]];
  [pace addRow:[self choiceRow:@"Full snapshots"
                           key:FLSettingSnapshotInterval
                       choices:@[
                         @[ @"Every 6 hours", @(6 * hour) ], @[ @"Every 12 hours", @(12 * hour) ],
                         @[ @"Every day", @(day) ], @[ @"Every week", @(7 * day) ]
                       ]
                        footer:@"A snapshot is always taken when the device starts."]];
  [sections addObject:pace];

  FLSection *record = [FLSection sectionWithTitle:@"What to Record"];
  NSArray *disabled = [FLSettings current][FLSettingDisabledCollectors];
  for (NSUInteger index = 0; index < _switches.count; index++) {
    NSString *name = _switches[index];
    BOOL snapshot = [name isEqualToString:FLSnapshotSwitch];
    FLRow *row = [FLRow rowWithTitle:snapshot ? @"Snapshots" : [FLReader streamTitle:name]
                              detail:nil];
    UISwitch *toggle = [UISwitch new];
    toggle.on = ![disabled containsObject:name];
    toggle.tag = (NSInteger)index;
    toggle.onTintColor = FLTintColor();
    [toggle addTarget:self
               action:@selector(switched:)
     forControlEvents:UIControlEventValueChanged];
    row.accessory = toggle;
    [record addRow:row];
  }
  record.footer = @"Everything is recorded unless you turn it off. Changes take effect at once.";
  [sections addObject:record];

  FLSection *about = [FLSection sectionWithTitle:@"About"];
  [about add:@"Finch Logs" detail:FLVersion];
  [about add:@"Logs are kept in" detail:FLRootPath];
  [about add:@"From a shell" detail:@"Run “finchlog help” as root"];
  [sections addObject:about];
  return sections;
}

@end
