#import "FLReportController.h"

#import <notify.h>

#import "FLDependencyIndex.h"
#import "FLInventoryController.h"
#import "FLInventoryItemController.h"
#import "FLReport.h"
#import "FLStatus.h"
#import "FLTheme.h"

static const NSTimeInterval FLReportAskEvery = 30;
static const NSTimeInterval FLReportRefresh = 5;
static const CGFloat FLReportBarHeight = 44;
static const NSUInteger FLReportLongFact = 36;

static NSDictionary *FLReportRead(NSString *kind) {
  static NSMutableDictionary<NSString *, NSDictionary *> *cached;
  static NSMutableDictionary<NSString *, NSDate *> *written;
  if (cached == nil) {
    cached = [NSMutableDictionary new];
    written = [NSMutableDictionary new];
  }
  NSDate *now = FLStateWritten(FLReportState(kind));
  if (now == nil) {
    return nil;
  }
  if (cached[kind] == nil || ![now isEqualToDate:written[kind]]) {
    cached[kind] = FLReadState(FLReportState(kind)) ?: @{};
    written[kind] = now;
  }
  return cached[kind].count > 0 ? cached[kind] : nil;
}

static void FLReportAsk(NSString *kind) {
  static NSMutableDictionary<NSString *, NSDate *> *asked;
  if (asked == nil) {
    asked = [NSMutableDictionary new];
  }
  if (asked[kind] != nil && -asked[kind].timeIntervalSinceNow < FLReportAskEvery) {
    return;
  }
  if (FLServiceRunning(FLServiceStatus())) {
    asked[kind] = [NSDate date];
    FLPostCommand(FLReportCommand(kind));
  }
}

static NSArray<NSDictionary *> *FLReportSections(NSDictionary *report) {
  NSArray<NSDictionary *> *sections = report[@"sections"];
  return [sections isKindOfClass:[NSArray class]] ? sections : @[];
}

@interface FLReportWatch : NSObject

- (instancetype)initWithKind:(NSString *)kind changed:(void (^)(void))changed;
- (void)stop;

@end

@implementation FLReportWatch {
  int _token;
  BOOL _listening;
}

- (instancetype)initWithKind:(NSString *)kind changed:(void (^)(void))changed {
  self = [super init];
  if (self) {
    _listening = notify_register_dispatch(FLReportNotice(kind).UTF8String, &_token,
                                          dispatch_get_main_queue(), ^(int fired) {
                                            changed();
                                          }) == NOTIFY_STATUS_OK;
  }
  return self;
}

- (void)stop {
  if (_listening) {
    notify_cancel(_token);
    _listening = NO;
  }
}

- (void)dealloc {
  [self stop];
}

@end

@interface FLReportRowController : FLListController

- (instancetype)initWithRow:(NSDictionary *)row;

@end

@implementation FLReportRowController {
  NSDictionary *_row;
}

- (instancetype)initWithRow:(NSDictionary *)row {
  self = [super initGrouped:YES];
  if (self) {
    _row = row;
    self.title = row[@"title"];
  }
  return self;
}

- (void)act {
  NSDictionary *action = _row[@"action"];
  const char *name = [action[@"command"] UTF8String];
  int token = 0;
  if (name == NULL || notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
    return;
  }
  notify_set_state(token, [action[@"value"] unsignedLongLongValue]);
  notify_post(name);
  notify_cancel(token);
  [self.navigationController popViewControllerAnimated:YES];
}

- (void)confirm {
  NSDictionary *action = _row[@"action"];
  if (!FLServiceRunning(FLServiceStatus())) {
    [self showMessage:@"The Finch Logs service is not running, so it cannot do this."
                title:nil];
    return;
  }
  UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:action[@"title"]
                                        message:action[@"confirm"]
                                 preferredStyle:UIAlertControllerStyleAlert];
  __weak FLReportRowController *weak = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:action[@"title"] ?: @"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *chosen) {
                                            [weak act];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (NSDictionary *)installed {
  FLDependencyIndex *index = [FLInventoryController index];
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  for (NSArray<NSString *> *fact in _row[@"facts"]) {
    if (fact.count == 2 && [@[ @"Path", @"Program" ] containsObject:fact[0]]) {
      [paths addObject:fact[1]];
    }
  }
  [paths addObject:_row[@"title"] ?: @""];
  for (NSString *path in paths) {
    NSDictionary *item = [path hasPrefix:@"/"]
      ? ([index itemAtPath:path] ?: [index itemOfNode:[index nodeAtPath:path]])
      : nil;
    if (item != nil) {
      return item;
    }
  }
  return nil;
}

- (NSArray<FLSection *> *)buildSections {
  NSMutableArray<FLSection *> *sections = [NSMutableArray new];
  FLSection *facts = [FLSection sectionWithTitle:nil];
  if ([_row[@"detail"] length] > 0) {
    FLRow *summary = [facts add:_row[@"title"] detail:_row[@"detail"]];
    summary.stacked = YES;
  }
  for (NSArray<NSString *> *fact in _row[@"facts"]) {
    if (fact.count < 2 || fact[1].length == 0) {
      continue;
    }
    FLRow *row = [facts add:fact[0] detail:fact[1]];
    row.stacked = fact[1].length > FLReportLongFact;
  }
  facts.footer = @"Touch and hold a row to copy it.";
  [sections addObject:facts];
  NSDictionary *item = [self installed];
  if (item != nil) {
    FLSection *more = [FLSection sectionWithTitle:nil];
    __weak FLReportRowController *owner = self;
    [more addRow:[FLRow linkWithTitle:@"Its Page in What Is Installed"
                               detail:nil
                               action:^{
                                 [owner.navigationController
                                   pushViewController:[[FLInventoryItemController alloc]
                                                        initWithItem:item]
                                             animated:YES];
                               }]];
    more.footer = @"Its size, what it needs, what needs it, and what has been seen using it.";
    [sections addObject:more];
  }
  NSDictionary *action = _row[@"action"];
  if ([action[@"title"] length] > 0) {
    FLSection *doing = [FLSection sectionWithTitle:nil];
    __weak FLReportRowController *weak = self;
    [doing addRow:[FLRow buttonWithTitle:action[@"title"]
                                  action:^{
                                    [weak confirm];
                                  }]];
    [sections addObject:doing];
  }
  return sections;
}

@end

@interface FLReportSectionController : FLListController <UISearchBarDelegate>

- (instancetype)initWithKind:(NSString *)kind section:(NSUInteger)index title:(NSString *)title;

@end

@implementation FLReportSectionController {
  NSString *_kind;
  NSUInteger _index;
  UISearchBar *_searchBar;
  NSString *_search;
  FLReportWatch *_watch;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  __weak FLReportSectionController *weak = self;
  _watch = [[FLReportWatch alloc] initWithKind:_kind
                                       changed:^{
                                         [weak reload];
                                       }];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [_watch stop];
  _watch = nil;
}

- (instancetype)initWithKind:(NSString *)kind section:(NSUInteger)index title:(NSString *)title {
  self = [super initGrouped:NO];
  if (self) {
    _kind = [kind copy];
    _index = index;
    self.title = title;
    self.refreshInterval = 2 * FLReportRefresh;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, FLReportBarHeight)];
  _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar.placeholder = @"Find";
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

- (void)show:(NSDictionary *)row {
  FLReportRowController *page = [[FLReportRowController alloc] initWithRow:row];
  page.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:page animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  NSArray<NSDictionary *> *sections = FLReportSections(FLReportRead(_kind));
  NSDictionary *source = _index < sections.count ? sections[_index] : nil;
  NSUInteger shown = 0;
  __weak FLReportSectionController *weak = self;
  for (NSDictionary *each in source[@"rows"]) {
    NSString *title = each[@"title"] ?: @"";
    NSString *detail = each[@"detail"] ?: @"";
    if (_search.length > 0 &&
        [title rangeOfString:_search options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [detail rangeOfString:_search options:NSCaseInsensitiveSearch].location == NSNotFound) {
      continue;
    }
    BOOL more = [each[@"facts"] count] > 0 || each[@"action"] != nil;
    FLRow *row = more ? [FLRow linkWithTitle:title
                                      detail:detail
                                      action:^{
                                        [weak show:each];
                                      }]
                      : [FLRow rowWithTitle:title detail:detail];
    row.stacked = YES;
    [section addRow:row];
    shown++;
  }
  NSString *count = [NSString stringWithFormat:@"%lu shown.", (unsigned long)shown];
  NSString *note = source[@"note"];
  section.footer = note.length > 0 ? [NSString stringWithFormat:@"%@ %@", count, note] : count;
  return @[ section ];
}

@end

@implementation FLReportController {
  NSString *_kind;
  FLReportWatch *_watch;
}

+ (NSArray<NSArray<NSString *> *> *)kinds {
  return @[
    @[ @"candidates", @"What Looks Unused", @"Installed things nothing recorded has used" ],
    @[ @"touched", @"Files Read", @"What has been read, what never has, and what a start reads" ],
    @[ @"health", @"Problems", @"Reports, bad endings, faults and errors, per component" ],
    @[ @"connections", @"Servers", @"Which programs talk to which servers" ],
    @[ @"loaded", @"Loaded Libraries", @"What running programs have really loaded" ],
    @[ @"opened", @"Files Reached", @"Which parts of the system had files opened" ],
    @[ @"talks", @"Connections Between Programs", @"Who holds a connection to whom" ],
    @[ @"calls", @"System Calls", @"The calls each program makes of the kernel" ],
    @[ @"changes", @"Changes", @"What has been set aside, and what differs since" ],
  ];
}

- (instancetype)initWithKind:(NSString *)kind title:(NSString *)title {
  self = [super initGrouped:YES];
  if (self) {
    _kind = [kind copy];
    self.title = title;
    self.refreshInterval = FLReportRefresh;
  }
  return self;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  __weak FLReportController *weak = self;
  _watch = [[FLReportWatch alloc] initWithKind:_kind
                                       changed:^{
                                         [weak reload];
                                       }];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [_watch stop];
  _watch = nil;
}

- (void)show:(NSUInteger)index title:(NSString *)title {
  FLReportSectionController *list = [[FLReportSectionController alloc] initWithKind:_kind
                                                                           section:index
                                                                             title:title];
  list.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:list animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  FLReportAsk(_kind);
  NSDictionary *report = FLReportRead(_kind);
  FLSection *lists = [FLSection sectionWithTitle:report[@"title"]];
  if (report == nil) {
    lists.footer = FLServiceRunning(FLServiceStatus())
      ? @"The service has not written this yet. It appears here when it has."
      : @"The Finch Logs service is not running, so there is nothing to show.";
    return @[ lists ];
  }
  NSArray<NSDictionary *> *sections = FLReportSections(report);
  __weak FLReportController *weak = self;
  for (NSUInteger index = 0; index < sections.count; index++) {
    NSString *title = sections[index][@"title"] ?: @"";
    NSUInteger count = [sections[index][@"rows"] count];
    FLRow *row = count == 0 ? [FLRow rowWithTitle:title detail:@"None"]
                            : [FLRow linkWithTitle:title
                                            detail:[NSString stringWithFormat:@"%lu",
                                                                              (unsigned long)count]
                                            action:^{
                                              [weak show:index title:title];
                                            }];
    row.dimmed = count == 0;
    [lists addRow:row];
  }
  NSDate *made = report[@"made"];
  NSMutableArray<NSString *> *notes = [NSMutableArray new];
  for (NSString *note in report[@"notes"]) {
    [notes addObject:note];
  }
  if ([made isKindOfClass:[NSDate class]]) {
    [notes addObject:[@"Written " stringByAppendingString:FLAgo(made)]];
  }
  lists.footer = [notes componentsJoinedByString:@"\n\n"];
  return @[ lists ];
}

@end
