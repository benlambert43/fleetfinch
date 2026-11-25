#import "FLServicesController.h"

#import "FLDetailController.h"
#import "FLStatus.h"
#import "FLTheme.h"

@interface FLServicesController () <UISearchBarDelegate>
@end

@implementation FLServicesController {
  UISegmentedControl *_scope;
  UISearchBar *_searchBar;
  NSString *_search;
}

- (instancetype)init {
  self = [super initGrouped:NO];
  if (self) {
    self.title = @"Services";
    self.refreshInterval = 5;
    self.watchesService = YES;
    _scope = [[UISegmentedControl alloc] initWithItems:@[ @"Running", @"Loaded", @"All" ]];
    _scope.selectedSegmentIndex = 0;
    [_scope addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _scope;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
  _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar.placeholder = @"Find a service by name";
  _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
  _searchBar.searchBarStyle = UISearchBarStyleMinimal;
  _searchBar.delegate = self;
  self.tableView.tableHeaderView = _searchBar;
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  _search = [searchText copy];
  [self reload];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [searchBar resignFirstResponder];
}

- (NSString *)stateOf:(NSDictionary *)service {
  int pid = [service[@"pid"] intValue];
  if (pid > 0) {
    return [NSString stringWithFormat:@"Running as pid %d", pid];
  }
  if (![service[@"loaded"] boolValue]) {
    return @"Not loaded";
  }
  NSString *last = service[@"lastExit"];
  return last.length > 0 && [service[@"status"] integerValue] != 0
    ? [NSString stringWithFormat:@"Not running, last ended with %@", last]
    : @"Not running";
}

- (void)show:(NSDictionary *)service {
  NSArray *pairs = @[
    @[ @"Label", service[@"label"] ?: @"" ],
    @[ @"State", [self stateOf:service] ],
    @[ @"Last ended with", service[@"lastExit"] ?: @"" ],
    @[ @"Starts", service[@"starts"] ?: @"" ],
    @[ @"Runs as", service[@"user"] ?: @"" ],
    @[ @"Defined in", service[@"file"] ?: @"" ],
    @[ @"Command", service[@"command"] ?: @"" ],
  ];
  FLDetailController *detail = [[FLDetailController alloc] initWithTitle:@"Service"
                                                                   pairs:pairs
                                                               monospace:@"Command"];
  detail.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:detail animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  NSArray<NSDictionary *> *services = FLReadState(@"services")[@"services"];
  if (![services isKindOfClass:[NSArray class]] || services.count == 0) {
    section.footer = FLServiceRunning(FLServiceStatus())
      ? @"Asking the service what launchd has loaded…"
      : @"The Finch Logs service is not running, so there is nothing to show.";
    return @[ section ];
  }
  NSInteger scope = _scope.selectedSegmentIndex;
  NSUInteger running = 0;
  __weak FLServicesController *weak = self;
  for (NSDictionary *service in services) {
    BOOL active = [service[@"pid"] intValue] > 0;
    if (active) {
      running++;
    }
    if ((scope == 0 && !active) || (scope == 1 && ![service[@"loaded"] boolValue])) {
      continue;
    }
    NSString *label = service[@"label"] ?: @"";
    if (_search.length > 0 &&
        [label rangeOfString:_search options:NSCaseInsensitiveSearch].location == NSNotFound) {
      continue;
    }
    FLRow *row = [FLRow linkWithTitle:label
                               detail:[self stateOf:service]
                               action:^{
                                 [weak show:service];
                               }];
    row.stacked = YES;
    row.dimmed = !active;
    [section addRow:row];
  }
  section.footer = [NSString
    stringWithFormat:@"Services launchd knows: %lu. Running: %lu.",
                     (unsigned long)services.count, (unsigned long)running];
  return @[ section ];
}

@end
