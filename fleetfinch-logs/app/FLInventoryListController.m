#import "FLInventoryListController.h"

#import "FLDependencyIndex.h"
#import "FLInventoryController.h"
#import "FLInventoryItemController.h"
#import "FLTheme.h"

NSString *const FLInventoryOtherFiles = @"storage";

static const CGFloat FLInventoryBarHeight = 44;
static const CGFloat FLInventoryOrderHeight = 30;
static const CGFloat FLInventoryMargin = 12;

typedef NS_ENUM(NSInteger, FLInventoryOrder) {
  FLInventoryLargest = 0,
  FLInventoryByName,
  FLInventoryLeastNeeded,
};

static uint64_t FLInventoryBytes(NSDictionary *item) {
  return [(item[@"bytes"] ?: item[@"cached"] ?: item[@"programBytes"]) unsignedLongLongValue];
}

static NSUInteger FLInventoryNeed(NSDictionary *item) {
  NSArray<NSString *> *order = FLNeedOrder();
  NSUInteger rank = [order indexOfObject:item[@"need"] ?: @""];
  return rank == NSNotFound ? order.count : order.count - 1 - rank;
}

static NSUInteger FLInventoryUsers(NSDictionary *item) {
  return [item[@"users"] unsignedIntegerValue] + [item[@"openers"] unsignedIntegerValue];
}

@interface FLInventoryListController () <UISearchBarDelegate>
@end

@implementation FLInventoryListController {
  NSString *_kind;
  UISegmentedControl *_order;
  UISearchBar *_searchBar;
  NSString *_search;
}

- (instancetype)initWithKind:(NSString *)kind title:(NSString *)title {
  self = [super initGrouped:NO];
  if (self) {
    self.title = title;
    self.refreshInterval = 10;
    _kind = [kind copy];
    BOOL loaded = [@[ @"framework", @"library", @"bundle" ] containsObject:kind];
    NSArray<NSString *> *orders = loaded ? @[ @"Largest First", @"By Name", @"Least Needed" ]
                                         : @[ @"Largest First", @"By Name" ];
    _order = [[UISegmentedControl alloc] initWithItems:orders];
    _order.selectedSegmentIndex =
      [kind isEqualToString:@"service"] ? FLInventoryByName : FLInventoryLargest;
    [_order addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  CGFloat width = 320;
  UIView *header = [[UIView alloc]
    initWithFrame:CGRectMake(0, 0, width,
                             FLInventoryBarHeight + FLInventoryOrderHeight + FLInventoryMargin)];
  header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, width, FLInventoryBarHeight)];
  _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar.placeholder = @"Find by name or path";
  _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
  _searchBar.searchBarStyle = UISearchBarStyleMinimal;
  _searchBar.delegate = self;
  [header addSubview:_searchBar];
  _order.frame = CGRectMake(FLInventoryMargin, FLInventoryBarHeight,
                            width - 2 * FLInventoryMargin, FLInventoryOrderHeight);
  _order.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [header addSubview:_order];
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

- (NSString *)hostOf:(NSDictionary *)item {
  NSString *inside = item[@"inside"];
  return inside.length > 0 ? [@"in " stringByAppendingString:inside.lastPathComponent] : nil;
}

- (NSString *)neededOf:(NSDictionary *)item {
  if (item[@"users"] == nil) {
    return nil;
  }
  if ([item[@"shadowed"] boolValue]) {
    return @"never loaded, the shared cache's copy is used";
  }
  NSString *need = item[@"need"];
  if (need != nil && ![need isEqualToString:@"loaded"]) {
    return FLNeedText(need);
  }
  NSUInteger openers = [item[@"openers"] unsignedIntegerValue];
  NSString *linked = [NSString stringWithFormat:@"linked by %@", item[@"users"]];
  return openers == 0 ? linked
                      : [NSString stringWithFormat:@"%@, opened by name by %lu", linked,
                                                   (unsigned long)openers];
}

- (NSString *)detailOf:(NSDictionary *)item {
  NSString *kind = item[@"kind"];
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  NSString *size = [FLInventoryItemController sizeOf:item];
  NSString *origin = [item[@"from"] length] > 0 ? [@"from " stringByAppendingString:item[@"from"]]
                                                : nil;
  NSString *named = item[@"clients"] == nil
    ? @""
    : [NSString stringWithFormat:@"named by %@", item[@"clients"]];
  if ([kind isEqualToString:@"service"]) {
    NSUInteger offered = [item[@"machServices"] count];
    [parts addObject:[item[@"program"] lastPathComponent] ?: @""];
    if (offered > 0) {
      [parts addObject:FLCount(offered, @"Mach service")];
    }
    [parts addObject:named];
    if ([item[@"elsewhere"] boolValue]) {
      [parts addObject:@"not loaded on this model"];
    }
    if ([item[@"disabled"] boolValue]) {
      [parts addObject:@"disabled"];
    }
  } else if ([kind isEqualToString:@"app"]) {
    [parts addObject:item[@"id"] ?: @""];
    if ([item[@"hidden"] boolValue]) {
      [parts addObject:@"hidden"];
    }
  } else if ([kind isEqualToString:@"extension"]) {
    [parts addObject:item[@"point"] ?: @""];
    [parts addObject:[self hostOf:item] ?: @""];
  } else if ([kind isEqualToString:@"xpc"]) {
    [parts addObject:[self hostOf:item] ?: @""];
    [parts addObject:named];
  } else if ([kind isEqualToString:@"framework"]) {
    [parts addObject:[item[@"inCache"] boolValue] ? @"library in the shared cache"
                                                  : (item[@"binary"] != nil ? @"library on disk"
                                                                            : @"no library")];
  } else if ([kind isEqualToString:@"bundle"]) {
    [parts addObject:[@"in " stringByAppendingString:item[@"group"] ?: @"/"]];
  } else {
    [parts addObject:[item[@"path"] stringByDeletingLastPathComponent] ?: @""];
    if ([item[@"type"] isEqualToString:@"script"]) {
      [parts addObject:@"script"];
    }
  }
  [parts addObject:size ?: @""];
  [parts addObject:[self neededOf:item] ?: @""];
  if (origin != nil && ![kind isEqualToString:@"service"]) {
    [parts addObject:origin];
  }
  NSMutableArray<NSString *> *shown = [NSMutableArray new];
  for (NSString *part in parts) {
    if (part.length > 0) {
      [shown addObject:part];
    }
  }
  return [shown componentsJoinedByString:@" · "];
}

- (void)show:(NSDictionary *)item {
  FLInventoryItemController *page = [[FLInventoryItemController alloc] initWithItem:item];
  page.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:page animated:YES];
}

- (NSString *)noteFor:(NSUInteger)found {
  NSDictionary<NSString *, NSString *> *notes = @{
    @"app" : @"An app's size includes the extensions and services inside it.",
    @"service" : @"Each is a definition launchd starts a program from. One that is disabled, or "
                 @"not loaded on this model, never starts.",
    @"framework" : @"Most frameworks keep their code in the shared library cache, so removing "
                   @"a framework's folder frees only the size shown.",
    @"library" : @"A library in the shared cache takes no space of its own and cannot be "
                 @"removed by itself.",
    @"program" : @"Run By names the launch services that start a program.",
    FLInventoryOtherFiles : @"Files that belong to no app, service, framework, bundle, program "
                            @"or library, by the folder they are in.",
  };
  NSString *note = notes[_kind];
  NSString *count = [NSString stringWithFormat:@"%lu shown.", (unsigned long)found];
  return note == nil ? count : [NSString stringWithFormat:@"%@ %@", count, note];
}

- (BOOL)matches:(NSDictionary *)item {
  if (_search.length == 0) {
    return YES;
  }
  NSString *text = [NSString stringWithFormat:@"%@ %@ %@", item[@"name"] ?: @"",
                                              item[@"id"] ?: @"", item[@"path"] ?: @""];
  return [text rangeOfString:_search options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (NSComparisonResult)compare:(NSDictionary *)first with:(NSDictionary *)second {
  FLInventoryOrder order = (FLInventoryOrder)_order.selectedSegmentIndex;
  if (order == FLInventoryByName) {
    NSString *name = first[@"name"] ?: first[@"path"] ?: @"";
    NSString *other = second[@"name"] ?: second[@"path"] ?: @"";
    return [name caseInsensitiveCompare:other];
  }
  if (order == FLInventoryLeastNeeded) {
    NSUInteger need = FLInventoryNeed(first);
    NSUInteger otherNeed = FLInventoryNeed(second);
    if (need != otherNeed) {
      return need < otherNeed ? NSOrderedAscending : NSOrderedDescending;
    }
    NSUInteger users = FLInventoryUsers(first);
    NSUInteger otherUsers = FLInventoryUsers(second);
    if (users != otherUsers) {
      return users < otherUsers ? NSOrderedAscending : NSOrderedDescending;
    }
  }
  uint64_t size = FLInventoryBytes(first);
  uint64_t other = FLInventoryBytes(second);
  return size == other ? NSOrderedSame
                       : (size > other ? NSOrderedAscending : NSOrderedDescending);
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  NSDictionary *inventory = [FLInventoryController inventory];
  if (inventory == nil) {
    section.footer = @"What is installed has not been listed yet.";
    return @[ section ];
  }
  BOOL files = [_kind isEqualToString:FLInventoryOtherFiles];
  NSMutableArray<NSDictionary *> *chosen = [NSMutableArray new];
  for (NSDictionary *item in inventory[files ? @"areas" : @"items"]) {
    if ((files || [item[@"kind"] isEqualToString:_kind]) && [self matches:item]) {
      [chosen addObject:item];
    }
  }
  __weak FLInventoryListController *weak = self;
  [chosen sortWithOptions:NSSortStable
          usingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
            return [weak compare:first with:second];
          }];
  for (NSDictionary *item in chosen) {
    FLRow *row = nil;
    if (files) {
      NSString *detail =
        [NSString stringWithFormat:@"%@ · %@",
                                   FLCount([item[@"files"] unsignedIntegerValue], @"file"),
                                   FLFormatBytes([item[@"bytes"] unsignedLongLongValue])];
      row = [FLRow rowWithTitle:item[@"path"] detail:detail];
    } else {
      row = [FLRow linkWithTitle:[FLInventoryItemController titleOf:item]
                          detail:[self detailOf:item]
                          action:^{
                            [weak show:item];
                          }];
    }
    row.stacked = YES;
    [section addRow:row];
  }
  section.footer = [self noteFor:chosen.count];
  return @[ section ];
}

@end
