#import "FLListController.h"

#import "FLStatus.h"
#import "FLTheme.h"

static const NSUInteger FLStackAbove = 26;
static const NSTimeInterval FLWatchEvery = 10;
static const CGFloat FLRowMargin = 15;
static const CGFloat FLRowGap = 10;
static const CGFloat FLRowPadding = 7;
static const CGFloat FLRowSpacing = 1;
static const CGFloat FLRowMinimum = 44;
static const CGFloat FLRowNarrowest = 40;
static const NSUInteger FLHeightsKept = 1000;
static const CGFloat FLFooterPadding = 8;
static const CGFloat FLFooterSize = 13;
static NSString *const FLRowCellName = @"row";

typedef struct {
  CGRect title;
  CGRect detail;
  CGFloat height;
  BOOL stacked;
} FLRowLayout;

@implementation FLRow

+ (instancetype)rowWithTitle:(NSString *)title detail:(NSString *)detail {
  FLRow *row = [FLRow new];
  row.title = title ?: @"";
  row.detail = detail;
  row.stacked = detail.length > FLStackAbove;
  return row;
}

+ (instancetype)linkWithTitle:(NSString *)title
                       detail:(NSString *)detail
                       action:(void (^)(void))action {
  FLRow *row = [self rowWithTitle:title detail:detail];
  row.disclosure = YES;
  row.action = action;
  return row;
}

+ (instancetype)buttonWithTitle:(NSString *)title action:(void (^)(void))action {
  FLRow *row = [self rowWithTitle:title detail:nil];
  row.button = YES;
  row.action = action;
  return row;
}

@end

@implementation FLSection

+ (instancetype)sectionWithTitle:(NSString *)title {
  FLSection *section = [FLSection new];
  section.title = title;
  section.rows = [NSMutableArray new];
  return section;
}

- (FLRow *)add:(NSString *)title detail:(NSString *)detail {
  FLRow *row = [FLRow rowWithTitle:title detail:detail];
  [self.rows addObject:row];
  return row;
}

- (void)addRow:(FLRow *)row {
  [self.rows addObject:row];
}

@end

static UIFont *FLTitleFont(FLRow *row, BOOL stacked) {
  return [UIFont systemFontOfSize:row.button || !stacked ? 17 : 16];
}

static UIFont *FLDetailFont(FLRow *row, BOOL stacked) {
  return row.monospace ? FLMonoFont(12) : [UIFont systemFontOfSize:stacked ? 13 : 16];
}

static CGSize FLTextSize(NSString *text, UIFont *font, CGFloat width) {
  if (text.length == 0) {
    return CGSizeZero;
  }
  CGRect box = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName : font}
                                  context:nil];
  return CGSizeMake(ceil(box.size.width), ceil(box.size.height));
}

static FLRowLayout FLLayoutRow(FLRow *row, CGFloat width, BOOL accessory) {
  FLRowLayout layout;
  CGFloat room = MAX(FLRowNarrowest, width - FLRowMargin - (accessory ? 0 : FLRowMargin));
  BOOL detailed = row.detail.length > 0 && !row.button;
  CGSize title = FLTextSize(row.title, FLTitleFont(row, NO), CGFLOAT_MAX);
  CGSize detail = detailed ? FLTextSize(row.detail, FLDetailFont(row, NO), CGFLOAT_MAX)
                           : CGSizeZero;
  layout.stacked = row.stacked || row.button ||
                   title.width + (detailed ? FLRowGap + detail.width : 0) > room;
  if (!layout.stacked) {
    layout.height = FLRowMinimum;
    layout.title = CGRectMake(FLRowMargin, floor((layout.height - title.height) / 2),
                              title.width, title.height);
    layout.detail = CGRectMake(FLRowMargin + room - detail.width,
                               floor((layout.height - detail.height) / 2), detail.width,
                               detail.height);
    return layout;
  }
  title = FLTextSize(row.title, FLTitleFont(row, YES), room);
  detail = detailed ? FLTextSize(row.detail, FLDetailFont(row, YES), room) : CGSizeZero;
  CGFloat content = title.height + (detailed ? FLRowSpacing + detail.height : 0);
  layout.height = MAX(FLRowMinimum, content + 2 * FLRowPadding);
  CGFloat top = floor((layout.height - content) / 2);
  layout.title = CGRectMake(FLRowMargin, top, room, title.height);
  layout.detail = CGRectMake(FLRowMargin, top + title.height + FLRowSpacing, room, detail.height);
  return layout;
}

static UITableViewCellAccessoryType FLAccessoryType(FLRow *row) {
  if (row.accessory != nil) {
    return UITableViewCellAccessoryNone;
  }
  if (row.checked) {
    return UITableViewCellAccessoryCheckmark;
  }
  return row.disclosure ? UITableViewCellAccessoryDisclosureIndicator
                        : UITableViewCellAccessoryNone;
}

@interface FLRowCell : UITableViewCell

@property(nonatomic, strong) FLRow *row;

@end

@implementation FLRowCell {
  UILabel *_title;
  UILabel *_detail;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
  if (self) {
    _title = [UILabel new];
    _title.numberOfLines = 0;
    _detail = [UILabel new];
    _detail.numberOfLines = 0;
    _detail.textColor = FLMutedColor();
    [self.contentView addSubview:_title];
    [self.contentView addSubview:_detail];
  }
  return self;
}

- (void)setRow:(FLRow *)row {
  _row = row;
  _title.text = row.title;
  _detail.text = row.button ? nil : row.detail;
  self.accessoryView = row.accessory;
  self.accessoryType = FLAccessoryType(row);
  self.selectionStyle = row.action == nil ? UITableViewCellSelectionStyleNone
                                          : UITableViewCellSelectionStyleDefault;
  if (row.button) {
    _title.textColor = row.destructive ? FLDangerColor() : FLTintColor();
  } else {
    _title.textColor = row.titleColor ?: (row.dimmed ? FLMutedColor() : FLInkColor());
  }
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  BOOL accessory = self.accessoryView != nil ||
                   self.accessoryType != UITableViewCellAccessoryNone;
  CGRect bounds = self.contentView.bounds;
  FLRowLayout layout = FLLayoutRow(_row, CGRectGetWidth(bounds), accessory);
  CGFloat shift = floor((CGRectGetHeight(bounds) - layout.height) / 2);
  _title.font = FLTitleFont(_row, layout.stacked);
  _detail.font = FLDetailFont(_row, layout.stacked);
  _detail.textAlignment = layout.stacked ? NSTextAlignmentLeft : NSTextAlignmentRight;
  _title.frame = CGRectOffset(layout.title, 0, shift);
  _detail.frame = CGRectOffset(layout.detail, 0, shift);
}

@end

@implementation FLListController {
  NSTimer *_timer;
  NSDate *_watched;
  BOOL _visible;
  CGFloat _width;
  NSMutableDictionary<NSString *, NSNumber *> *_widths;
  NSCache<NSString *, NSNumber *> *_heights;
}

- (instancetype)initGrouped:(BOOL)grouped {
  return [super initWithStyle:grouped ? UITableViewStyleGrouped : UITableViewStylePlain];
}

- (instancetype)init {
  return [self initGrouped:YES];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  _widths = [NSMutableDictionary new];
  _heights = [NSCache new];
  _heights.countLimit = FLHeightsKept;
  self.tableView.estimatedRowHeight = 0;
  self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
  [self.tableView registerClass:[FLRowCell class] forCellReuseIdentifier:FLRowCellName];
  if (self.tableView.style == UITableViewStylePlain) {
    self.tableView.tableFooterView = [UIView new];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat width = CGRectGetWidth(self.tableView.bounds);
  if (width != _width) {
    _width = width;
    [self.tableView reloadData];
  }
}

- (CGFloat)contentWidthFor:(FLRow *)row {
  CGFloat table = CGRectGetWidth(self.tableView.bounds);
  UITableViewCellAccessoryType type = FLAccessoryType(row);
  NSString *key = [NSString stringWithFormat:@"%ld|%.0f|%.0f", (long)type,
                                             CGRectGetWidth(row.accessory.bounds), table];
  NSNumber *known = _widths[key];
  if (known != nil) {
    return known.doubleValue;
  }
  UITableViewCell *probe = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:nil];
  probe.accessoryType = type;
  if (row.accessory != nil) {
    probe.accessoryView = [[UIView alloc] initWithFrame:row.accessory.bounds];
  }
  probe.frame = CGRectMake(0, 0, table, FLRowMinimum);
  [probe layoutIfNeeded];
  CGFloat width = CGRectGetWidth(probe.contentView.bounds);
  _widths[key] = @(width);
  return width;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  FLRow *row = [self rowAt:indexPath];
  if (row == nil) {
    return FLRowMinimum;
  }
  CGFloat width = [self contentWidthFor:row];
  BOOL accessory = row.accessory != nil || FLAccessoryType(row) != UITableViewCellAccessoryNone;
  NSString *key = [NSString stringWithFormat:@"%d%d%d%d|%.0f|%@|%@", row.stacked, row.button,
                                             row.monospace, accessory, width, row.title,
                                             row.detail ?: @""];
  NSNumber *known = [_heights objectForKey:key];
  if (known != nil) {
    return known.doubleValue;
  }
  CGFloat height = FLLayoutRow(row, width, accessory).height;
  [_heights setObject:@(height) forKey:key];
  return height;
}

- (NSArray<FLSection *> *)buildSections {
  return @[];
}

- (void)watch {
  if (!self.watchesService) {
    return;
  }
  if (_watched == nil || -_watched.timeIntervalSinceNow >= FLWatchEvery) {
    _watched = [NSDate date];
    FLPostCommand(FLCommandWatch);
  }
}

- (void)reload {
  [self watch];
  _sections = [[self buildSections] copy] ?: @[];
  if (self.isViewLoaded) {
    [self.tableView reloadData];
  }
}

- (void)tick {
  if (self.tableView.isDragging || self.tableView.isDecelerating || self.tableView.isEditing) {
    [self watch];
    return;
  }
  [self reload];
}

- (void)startTimer {
  [_timer invalidate];
  _timer = nil;
  if (self.refreshInterval > 0 && _visible) {
    _timer = [NSTimer scheduledTimerWithTimeInterval:self.refreshInterval
                                              target:self
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
  }
}

- (void)becameActive {
  if (_visible) {
    _watched = nil;
    [self reload];
    [self startTimer];
  }
}

- (void)becameInactive {
  [_timer invalidate];
  _timer = nil;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  _visible = YES;
  _watched = nil;
  [self reload];
  [self startTimer];
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(becameActive)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];
  [center addObserver:self
             selector:@selector(becameInactive)
                 name:UIApplicationWillResignActiveNotification
               object:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  _visible = NO;
  [_timer invalidate];
  _timer = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dealloc {
  [_timer invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
  UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:title
                                        message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (FLRow *)rowAt:(NSIndexPath *)path {
  if (path.section >= (NSInteger)self.sections.count) {
    return nil;
  }
  NSArray<FLRow *> *rows = self.sections[(NSUInteger)path.section].rows;
  return path.row < (NSInteger)rows.count ? rows[(NSUInteger)path.row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)self.sections[(NSUInteger)section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return self.sections[(NSUInteger)section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return self.sections[(NSUInteger)section].footer;
}

- (NSString *)plainFooterIn:(UITableView *)tableView section:(NSInteger)section {
  NSString *footer = self.sections[(NSUInteger)section].footer;
  return tableView.style == UITableViewStylePlain && footer.length > 0 ? footer : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  NSString *footer = [self plainFooterIn:tableView section:section];
  if (footer == nil) {
    return UITableViewAutomaticDimension;
  }
  CGFloat room = CGRectGetWidth(tableView.bounds) - 2 * FLRowMargin;
  return FLTextSize(footer, [UIFont systemFontOfSize:FLFooterSize], room).height +
         2 * FLFooterPadding;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  NSString *footer = [self plainFooterIn:tableView section:section];
  if (footer == nil) {
    return nil;
  }
  CGFloat width = CGRectGetWidth(tableView.bounds);
  CGFloat height = [self tableView:tableView heightForFooterInSection:section];
  UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
  view.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.96];
  UILabel *label = [[UILabel alloc]
    initWithFrame:CGRectMake(FLRowMargin, FLFooterPadding, width - 2 * FLRowMargin,
                             height - 2 * FLFooterPadding)];
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  label.numberOfLines = 0;
  label.font = [UIFont systemFontOfSize:FLFooterSize];
  label.textColor = FLMutedColor();
  label.text = footer;
  [view addSubview:label];
  return view;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  FLRowCell *cell = [tableView dequeueReusableCellWithIdentifier:FLRowCellName
                                                    forIndexPath:indexPath];
  cell.row = [self rowAt:indexPath];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  FLRow *row = [self rowAt:indexPath];
  if (row.action != nil) {
    row.action();
  }
}

- (BOOL)tableView:(UITableView *)tableView
  shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self rowAt:indexPath].detail.length > 0;
}

- (BOOL)tableView:(UITableView *)tableView
  canPerformAction:(SEL)action
 forRowAtIndexPath:(NSIndexPath *)indexPath
        withSender:(id)sender {
  return action == @selector(copy:);
}

- (void)tableView:(UITableView *)tableView
    performAction:(SEL)action
forRowAtIndexPath:(NSIndexPath *)indexPath
       withSender:(id)sender {
  FLRow *row = [self rowAt:indexPath];
  if (action == @selector(copy:) && row.detail.length > 0) {
    [UIPasteboard generalPasteboard].string = row.detail;
  }
}

@end
