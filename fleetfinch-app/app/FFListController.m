#import "FFListController.h"

#import "FFPlaceholderController.h"
#import "FFTheme.h"

static NSString *const FFCellIdentifier = @"row";

@implementation FFRow

+ (instancetype)rowWithTitle:(NSString *)title detail:(NSString *)detail {
  return [self rowWithTitle:title detail:detail about:nil];
}

+ (instancetype)rowWithTitle:(NSString *)title
                      detail:(NSString *)detail
                       about:(NSString *)about {
  FFRow *row = [self new];
  row.title = title;
  row.detail = detail;
  row.about = about;
  return row;
}

@end

@implementation FFSection

+ (instancetype)sectionWithTitle:(NSString *)title
                            rows:(NSArray<FFRow *> *)rows
                          footer:(NSString *)footer {
  FFSection *section = [self new];
  section.title = title;
  section.rows = rows;
  section.footer = footer;
  return section;
}

@end

@implementation FFListController {
  NSArray<FFSection *> *_sections;
}

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self reload];
}

- (NSArray<FFSection *> *)buildSections {
  return @[];
}

- (void)reload {
  _sections = [self buildSections];
  [self.tableView reloadData];
}

- (FFRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
  return _sections[indexPath.section].rows[indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)_sections[section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return _sections[section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return _sections[section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:FFCellIdentifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                  reuseIdentifier:FFCellIdentifier];
    cell.detailTextLabel.textColor = FFMutedColor();
  }
  FFRow *row = [self rowAtIndexPath:indexPath];
  cell.textLabel.text = row.title;
  cell.detailTextLabel.text = row.detail;
  BOOL opens = row.about != nil;
  cell.accessoryType = opens ? UITableViewCellAccessoryDisclosureIndicator
                             : UITableViewCellAccessoryNone;
  cell.selectionStyle = opens ? UITableViewCellSelectionStyleDefault
                              : UITableViewCellSelectionStyleNone;
  return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView
  willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self rowAtIndexPath:indexPath].about != nil ? indexPath : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  FFRow *row = [self rowAtIndexPath:indexPath];
  FFPlaceholderController *placeholder =
    [[FFPlaceholderController alloc] initWithTitle:row.title about:row.about];
  [self.navigationController pushViewController:placeholder animated:YES];
}

@end
