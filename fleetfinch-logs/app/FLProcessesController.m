#import "FLProcessesController.h"

#import "FLDetailController.h"
#import "FLStatus.h"
#import "FLTheme.h"

static const NSTimeInterval FLLiveFor = 20;

typedef NS_ENUM(NSInteger, FLProcessOrder) {
  FLProcessOrderProcessor = 0,
  FLProcessOrderMemory,
  FLProcessOrderName,
  FLProcessOrderNewest,
};

@implementation FLProcessesController {
  UISegmentedControl *_scope;
  FLProcessOrder _order;
}

- (instancetype)init {
  self = [super initGrouped:NO];
  if (self) {
    self.title = @"Processes";
    self.refreshInterval = 5;
    self.watchesService = YES;
    _scope = [[UISegmentedControl alloc] initWithItems:@[ @"Everything", @"Apps" ]];
    _scope.selectedSegmentIndex = 0;
    [_scope addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _scope;
    self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Sort"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(chooseOrder:)];
  }
  return self;
}

- (void)chooseOrder:(UIBarButtonItem *)sender {
  UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:@"Put first"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
  NSArray *titles = @[
    @"The busiest", @"The largest in memory", @"Names from A to Z", @"The most recently started"
  ];
  __weak FLProcessesController *weak = self;
  for (NSUInteger index = 0; index < titles.count; index++) {
    NSString *title = (FLProcessOrder)index == _order
      ? [titles[index] stringByAppendingString:@" ✓"]
      : titles[index];
    [sheet addAction:[UIAlertAction actionWithTitle:title
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [weak setOrder:(FLProcessOrder)index];
                                            }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  sheet.popoverPresentationController.barButtonItem = sender;
  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setOrder:(FLProcessOrder)order {
  _order = order;
  [self reload];
}

- (NSArray<NSDictionary *> *)sorted:(NSArray<NSDictionary *> *)rows {
  NSSortDescriptor *name =
    [NSSortDescriptor sortDescriptorWithKey:@"name"
                                  ascending:YES
                                   selector:@selector(caseInsensitiveCompare:)];
  NSSortDescriptor *first = nil;
  switch (_order) {
    case FLProcessOrderProcessor:
      first = [NSSortDescriptor sortDescriptorWithKey:@"processor" ascending:NO];
      break;
    case FLProcessOrderMemory:
      first = [NSSortDescriptor sortDescriptorWithKey:@"memory" ascending:NO];
      break;
    case FLProcessOrderNewest:
      first = [NSSortDescriptor sortDescriptorWithKey:@"started" ascending:NO];
      break;
    case FLProcessOrderName:
      break;
  }
  return [rows sortedArrayUsingDescriptors:first == nil ? @[ name ] : @[ first, name ]];
}

- (void)show:(NSDictionary *)process {
  NSDate *started = process[@"started"];
  NSArray *pairs = @[
    @[ @"Name", process[@"name"] ?: @"" ],
    @[ @"Process ID", [process[@"pid"] description] ?: @"" ],
    @[
      @"Started by",
      [process[@"parent"] intValue] == 1
        ? @"launchd (pid 1)"
        : [NSString stringWithFormat:@"pid %@", process[@"parent"] ?: @0]
    ],
    @[ @"Runs as", process[@"user"] ?: @"" ],
    @[
      @"Started",
      [started isKindOfClass:[NSDate class]]
        ? [NSString stringWithFormat:@"%@ (%@)", FLFormatDay(started), FLAgo(started)]
        : @""
    ],
    @[ @"Processor now", FLPercent([process[@"processor"] doubleValue]) ],
    @[
      @"Processor in all",
      [NSString stringWithFormat:@"%.2f seconds", [process[@"processorSeconds"] doubleValue]]
    ],
    @[ @"Memory", FLFormatBytes([process[@"memory"] unsignedLongLongValue]) ],
    @[ @"Threads", [process[@"threads"] description] ?: @"" ],
    @[ @"App", process[@"identifier"] ?: @"" ],
    @[ @"Program", process[@"path"] ?: @"" ],
    @[ @"Command", process[@"command"] ?: @"" ],
  ];
  FLDetailController *detail = [[FLDetailController alloc] initWithTitle:process[@"name"]
                                                                   pairs:pairs
                                                               monospace:@"Command"];
  detail.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:detail animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  NSDictionary *live = FLServiceLive();
  NSDate *written = live[@"written"];
  BOOL fresh = [written isKindOfClass:[NSDate class]] &&
               -written.timeIntervalSinceNow < FLLiveFor;
  if (!fresh) {
    section.footer = FLServiceRunning(FLServiceStatus())
      ? @"Asking the service what is running…"
      : @"The Finch Logs service is not running, so there is nothing to show.";
    return @[ section ];
  }
  NSString *front = live[@"frontApp"];
  BOOL appsOnly = _scope.selectedSegmentIndex == 1;
  __weak FLProcessesController *weak = self;
  NSUInteger total = 0;
  for (NSDictionary *process in [self sorted:live[@"processes"]]) {
    total++;
    if (appsOnly && ![process[@"app"] boolValue]) {
      continue;
    }
    NSString *identifier = process[@"identifier"];
    BOOL inFront = front.length > 0 && [identifier isEqualToString:front];
    NSString *detail = [NSString
      stringWithFormat:@"%@ processor · %@ · pid %@ · %@%@",
                       FLPercent([process[@"processor"] doubleValue]),
                       FLFormatBytes([process[@"memory"] unsignedLongLongValue]), process[@"pid"],
                       process[@"user"], inFront ? @" · in front" : @""];
    FLRow *row = [FLRow linkWithTitle:process[@"name"]
                               detail:detail
                               action:^{
                                 [weak show:process];
                               }];
    row.stacked = YES;
    if (inFront) {
      row.titleColor = FLTintColor();
    }
    [section addRow:row];
  }
  section.footer = appsOnly
    ? [NSString stringWithFormat:@"Apps running: %lu, among %lu processes.",
                                 (unsigned long)section.rows.count, (unsigned long)total]
    : [NSString stringWithFormat:@"Processes running: %lu.", (unsigned long)total];
  return @[ section ];
}

@end
