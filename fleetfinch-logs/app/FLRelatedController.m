#import "FLRelatedController.h"

#import "FLDependencyIndex.h"
#import "FLInventoryController.h"
#import "FLInventoryItemController.h"
#import "FLTheme.h"

static const CGFloat FLRelatedBarHeight = 44;

@interface FLRelatedController () <UISearchBarDelegate>
@end

@implementation FLRelatedController {
  NSArray<NSDictionary *> *_rows;
  UISearchBar *_searchBar;
  NSString *_search;
}

- (instancetype)initWithTitle:(NSString *)title rows:(NSArray<NSDictionary *> *)rows {
  self = [super initGrouped:NO];
  if (self) {
    self.title = title;
    _rows = [rows copy];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, FLRelatedBarHeight)];
  _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar.placeholder = @"Find by name or path";
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

- (void)open:(NSDictionary *)item {
  FLInventoryItemController *page = [[FLInventoryItemController alloc] initWithItem:item];
  page.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:page animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  FLDependencyIndex *index = [FLInventoryController index];
  __weak FLRelatedController *weak = self;
  for (NSDictionary *each in _rows) {
    NSString *title = each[@"title"] ?: @"";
    NSString *detail = each[@"detail"] ?: @"";
    if (_search.length > 0) {
      NSString *text = [NSString stringWithFormat:@"%@ %@", title, detail];
      if ([text rangeOfString:_search options:NSCaseInsensitiveSearch].location == NSNotFound) {
        continue;
      }
    }
    NSDictionary *item = [index itemAtPath:each[@"item"]];
    FLRow *row = item == nil ? [FLRow rowWithTitle:title detail:detail]
                             : [FLRow linkWithTitle:title
                                             detail:detail
                                             action:^{
                                               [weak open:item];
                                             }];
    row.stacked = YES;
    [section addRow:row];
  }
  section.footer = [FLCount(section.rows.count, @"row") stringByAppendingString:@" shown."];
  return @[ section ];
}

@end
