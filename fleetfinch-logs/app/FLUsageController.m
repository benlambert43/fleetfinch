#import "FLUsageController.h"

#import "FLDetailController.h"
#import "FLStatus.h"
#import "FLTheme.h"

static const NSTimeInterval FLUsageAskEvery = 60;
static const CGFloat FLUsageBarHeight = 44;
static const CGFloat FLUsageFilterHeight = 30;
static const CGFloat FLUsageMargin = 12;

typedef NS_ENUM(NSInteger, FLUsageFilter) {
  FLUsageFilterAll = 0,
  FLUsageFilterRan,
  FLUsageFilterNever,
};

static NSArray<NSString *> *FLUsageKinds(void) {
  return @[ @"app", @"service", @"program" ];
}

@interface FLUsageController () <UISearchBarDelegate>
@end

@implementation FLUsageController {
  UISegmentedControl *_kind;
  UISegmentedControl *_filter;
  UISearchBar *_searchBar;
  NSString *_search;
}

+ (NSDictionary *)report {
  static NSDictionary *cached;
  static NSDate *written;
  NSDate *now = FLStateWritten(FLUsageReportState);
  if (now == nil) {
    return nil;
  }
  if (cached == nil || ![now isEqualToDate:written]) {
    cached = FLReadState(FLUsageReportState);
    written = now;
  }
  return cached.count > 0 ? cached : nil;
}

+ (void)ask {
  static NSDate *asked;
  if (asked != nil && -asked.timeIntervalSinceNow < FLUsageAskEvery) {
    return;
  }
  if (FLServiceRunning(FLServiceStatus())) {
    asked = [NSDate date];
    FLPostCommand(FLCommandUsage);
  }
}

- (instancetype)initWithKind:(NSString *)kind neverOnly:(BOOL)neverOnly {
  self = [super initGrouped:NO];
  if (self) {
    self.title = @"What Has Run";
    self.refreshInterval = 2;
    _kind = [[UISegmentedControl alloc] initWithItems:@[ @"Apps", @"Services", @"Programs" ]];
    NSUInteger chosen = [FLUsageKinds() indexOfObject:kind ?: @""];
    _kind.selectedSegmentIndex = chosen == NSNotFound ? 0 : (NSInteger)chosen;
    [_kind addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _kind;
    _filter = [[UISegmentedControl alloc] initWithItems:@[ @"All", @"Has Run", @"Never Ran" ]];
    _filter.selectedSegmentIndex = neverOnly ? FLUsageFilterNever : FLUsageFilterAll;
    [_filter addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  CGFloat width = 320;
  UIView *header = [[UIView alloc]
    initWithFrame:CGRectMake(0, 0, width,
                             FLUsageBarHeight + FLUsageFilterHeight + FLUsageMargin)];
  header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, width, FLUsageBarHeight)];
  _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar.placeholder = @"Find by name or path";
  _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
  _searchBar.searchBarStyle = UISearchBarStyleMinimal;
  _searchBar.delegate = self;
  [header addSubview:_searchBar];
  _filter.frame = CGRectMake(FLUsageMargin, FLUsageBarHeight, width - 2 * FLUsageMargin,
                             FLUsageFilterHeight);
  _filter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [header addSubview:_filter];
  self.tableView.tableHeaderView = header;
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  _search = [searchText copy];
  [self reload];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [searchBar resignFirstResponder];
}

- (NSString *)titleOf:(NSDictionary *)row {
  return [row[@"kind"] isEqualToString:@"app"] ? row[@"name"] : row[@"key"];
}

- (NSString *)stateOf:(NSDictionary *)row {
  NSUInteger running = [row[@"running"] unsignedIntegerValue];
  NSString *origin = [row[@"origin"] length] > 0 ? row[@"origin"] : @"an unknown place";
  uint64_t bytes = [row[@"bytes"] unsignedLongLongValue];
  if (bytes > 0) {
    origin = [NSString stringWithFormat:@"%@ · %@", origin, FLFormatBytes(bytes)];
  }
  if (![row[@"ran"] boolValue]) {
    return [NSString stringWithFormat:@"Never ran · from %@", origin];
  }
  NSString *runs = FLCount([row[@"runs"] unsignedIntegerValue], @"run");
  NSString *work =
    [NSString stringWithFormat:@"%.1fs of processor", [row[@"processor"] doubleValue]];
  NSDate *last = row[@"last"];
  NSString *when = running > 0 ? @"running now"
                               : [NSString stringWithFormat:@"last seen %@", FLAgo(last)];
  return [NSString stringWithFormat:@"%@ · %@ · %@ · from %@", runs, when, work, origin];
}

- (void)show:(NSDictionary *)row {
  NSString *kind = row[@"kind"];
  BOOL ran = [row[@"ran"] boolValue];
  NSUInteger running = [row[@"running"] unsignedIntegerValue];
  NSMutableArray<NSArray<NSString *> *> *pairs = [NSMutableArray new];
  [pairs addObject:@[ @"Name", row[@"name"] ?: @"" ]];
  if ([kind isEqualToString:@"app"]) {
    [pairs addObject:@[ @"Identifier", row[@"key"] ?: @"" ]];
    [pairs addObject:@[ @"Kind", row[@"note"] ?: @"" ]];
  } else if ([kind isEqualToString:@"service"]) {
    [pairs addObject:@[ @"Starts", row[@"note"] ?: @"" ]];
    [pairs addObject:@[ @"Defined in", row[@"file"] ?: @"" ]];
  }
  [pairs addObject:@[ @"From", row[@"origin"] ?: @"" ]];
  uint64_t bytes = [row[@"bytes"] unsignedLongLongValue];
  [pairs addObject:@[ @"Size", bytes > 0 ? FLFormatBytes(bytes) : @"" ]];
  NSString *state = @"Never seen running";
  if (running > 0) {
    state = running == 1 ? @"Running now"
                         : [NSString stringWithFormat:@"Running now, %lu times over",
                                                      (unsigned long)running];
  } else if (ran) {
    state = @"Not running";
  }
  [pairs addObject:@[ @"State", state ]];
  if (ran) {
    NSDate *first = row[@"first"];
    NSDate *last = row[@"last"];
    [pairs addObject:@[ @"Runs seen", [row[@"runs"] description] ?: @"0" ]];
    [pairs addObject:@[ @"First seen", FLFormatDay(first) ?: @"" ]];
    [pairs addObject:@[ @"Last seen", FLFormatDay(last) ?: @"" ]];
    [pairs addObject:@[ @"Time running", FLFormatDuration([row[@"seconds"] doubleValue]) ]];
    [pairs addObject:@[
      @"Processor", [NSString stringWithFormat:@"%.1fs", [row[@"processor"] doubleValue]]
    ]];
    [pairs addObject:@[
      @"Most memory", FLFormatBytes([row[@"memory"] unsignedLongLongValue])
    ]];
    [pairs addObject:@[ @"Started by", row[@"starters"] ?: @"" ]];
    if ([row[@"endings"] length] > 0) {
      [pairs addObject:@[ @"Ended with", row[@"endings"] ]];
    }
    [pairs addObject:@[ @"Ran as", row[@"user"] ?: @"" ]];
  }
  [pairs addObject:@[ [kind isEqualToString:@"service"] ? @"Program" : @"Path",
                      row[@"where"] ?: @"" ]];
  if ([row[@"command"] length] > 0) {
    [pairs addObject:@[ @"Last command", row[@"command"] ]];
  }
  NSMutableArray *shown = [NSMutableArray new];
  for (NSArray<NSString *> *pair in pairs) {
    if (pair[1].length > 0) {
      [shown addObject:pair];
    }
  }
  FLDetailController *detail = [[FLDetailController alloc] initWithTitle:[self titleOf:row]
                                                                   pairs:shown
                                                               monospace:@"Last command"];
  detail.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:detail animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  [FLUsageController ask];
  FLSection *section = [FLSection sectionWithTitle:nil];
  NSDictionary *report = [FLUsageController report];
  NSArray<NSDictionary *> *rows = report[@"rows"];
  if (![rows isKindOfClass:[NSArray class]]) {
    section.footer = FLServiceRunning(FLServiceStatus())
      ? @"Asking the service what it has seen run…"
      : @"The Finch Logs service is not running, so there is nothing to show.";
    return @[ section ];
  }
  NSString *kind = FLUsageKinds()[(NSUInteger)MAX(0, _kind.selectedSegmentIndex)];
  FLUsageFilter filter = (FLUsageFilter)_filter.selectedSegmentIndex;
  NSMutableArray<NSDictionary *> *chosen = [NSMutableArray new];
  for (NSDictionary *row in rows) {
    BOOL ran = [row[@"ran"] boolValue];
    if (![row[@"kind"] isEqualToString:kind] || (filter == FLUsageFilterRan && !ran) ||
        (filter == FLUsageFilterNever && ran)) {
      continue;
    }
    if (_search.length > 0) {
      NSString *text = [NSString stringWithFormat:@"%@ %@ %@", row[@"name"] ?: @"",
                                                  row[@"key"] ?: @"", row[@"where"] ?: @""];
      if ([text rangeOfString:_search options:NSCaseInsensitiveSearch].location == NSNotFound) {
        continue;
      }
    }
    [chosen addObject:row];
  }
  if (filter == FLUsageFilterRan) {
    [chosen sortWithOptions:NSSortStable
            usingComparator:^(NSDictionary *first, NSDictionary *second) {
              BOOL active = [first[@"running"] unsignedIntegerValue] > 0;
              BOOL other = [second[@"running"] unsignedIntegerValue] > 0;
              if (active != other) {
                return active ? NSOrderedAscending : NSOrderedDescending;
              }
              if (active) {
                return NSOrderedSame;
              }
              NSDate *earlier = first[@"last"] ?: [NSDate distantPast];
              NSDate *later = second[@"last"] ?: [NSDate distantPast];
              return [later compare:earlier];
            }];
  }
  __weak FLUsageController *weak = self;
  for (NSDictionary *row in chosen) {
    FLRow *line = [FLRow linkWithTitle:[self titleOf:row]
                                detail:[self stateOf:row]
                                action:^{
                                  [weak show:row];
                                }];
    line.stacked = YES;
    line.dimmed = ![row[@"ran"] boolValue];
    [section addRow:line];
  }
  NSDictionary *counts = report[@"summary"][kind];
  NSDate *began = report[@"began"];
  NSString *unlisted = [report[@"listed"] boolValue]
    ? @""
    : @" What is installed has not been listed yet, so apps, extensions and programs that "
      @"have never run are missing.";
  section.footer = [NSString
    stringWithFormat:@"%@ found, %@ never seen running. Counted since %@, with the device awake "
                     @"for %@ of that time. A run of only a few milliseconds can go unnamed.%@",
                     counts[@"total"] ?: @0, counts[@"never"] ?: @0,
                     [began isKindOfClass:[NSDate class]] ? FLFormatDay(began) : @"the start",
                     FLFormatDuration([report[@"watched"] doubleValue]), unlisted];
  return @[ section ];
}

@end
