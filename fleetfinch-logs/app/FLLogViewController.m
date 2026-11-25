#import "FLLogViewController.h"

#import "FLDetailController.h"
#import "FLFilesController.h"
#import "FLTheme.h"

static const NSUInteger FLInitialLines = 400;
static const NSUInteger FLStepLines = 400;
static const NSUInteger FLKeepLines = 3000;
static const NSUInteger FLFileBytes = 2 * 1024 * 1024;
static const NSTimeInterval FLTailEvery = 1.0;
static NSString *const FLLogCellName = @"line";

static NSString *FLLineTime(NSDate *date) {
  if (date == nil) {
    return @"";
  }
  static NSDateFormatter *today;
  static NSDateFormatter *earlier;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    today = [NSDateFormatter new];
    today.locale = locale;
    today.dateFormat = @"HH:mm:ss.SSS";
    earlier = [NSDateFormatter new];
    earlier.locale = locale;
    earlier.dateFormat = @"MM-dd HH:mm:ss";
  });
  BOOL recent = [[NSCalendar currentCalendar] isDateInToday:date];
  return [recent ? today : earlier stringFromDate:date];
}

static const CGFloat FLLineMargin = 10;
static const CGFloat FLLinePadding = 6;
static const CGFloat FLLineGap = 2;
static const NSUInteger FLLineLimit = 8;

@interface FLLine : NSObject

@property(nonatomic, strong) FLRecord *record;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) NSUInteger rows;
@property(nonatomic) NSUInteger columns;

@end

@implementation FLLine

- (void)wrapTo:(NSUInteger)columns {
  if (self.columns == columns && self.text != nil) {
    return;
  }
  self.columns = columns;
  NSString *message = [self.record.message stringByReplacingOccurrencesOfString:@"\t"
                                                                     withString:@"  "];
  NSMutableArray<NSString *> *rows = [NSMutableArray new];
  BOOL cut = NO;
  for (NSString *part in [message componentsSeparatedByString:@"\n"]) {
    NSUInteger start = 0;
    do {
      if (rows.count == FLLineLimit) {
        cut = YES;
        break;
      }
      NSUInteger length = MIN(columns, part.length - start);
      NSRange range = NSMakeRange(start, length);
      if (length > 0) {
        range = [part rangeOfComposedCharacterSequencesForRange:range];
      }
      [rows addObject:[part substringWithRange:range]];
      start = NSMaxRange(range);
    } while (start < part.length);
    if (cut) {
      break;
    }
  }
  if (cut) {
    NSString *last = rows.lastObject;
    NSUInteger keep = MIN(last.length, columns > 2 ? columns - 2 : 0);
    NSRange kept = [last rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, keep)];
    rows[rows.count - 1] = [[last substringWithRange:kept] stringByAppendingString:@" …"];
  }
  while (rows.count > 1 && [rows.lastObject length] == 0) {
    [rows removeLastObject];
  }
  self.rows = MAX((NSUInteger)1, rows.count);
  self.text = [rows componentsJoinedByString:@"\n"];
}

@end

@interface FLLogCell : UITableViewCell

@property(nonatomic, strong) UILabel *meta;
@property(nonatomic, strong) UILabel *message;

@end

@implementation FLLogCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
  if (self) {
    _meta = [UILabel new];
    _meta.font = FLMonoFont(11);
    _meta.lineBreakMode = NSLineBreakByTruncatingTail;
    _message = [UILabel new];
    _message.font = FLMonoFont(12);
    _message.numberOfLines = 0;
    _message.lineBreakMode = NSLineBreakByCharWrapping;
    [self.contentView addSubview:_meta];
    [self.contentView addSubview:_message];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.contentView.bounds;
  CGFloat width = CGRectGetWidth(bounds) - 2 * FLLineMargin;
  CGFloat metaHeight = ceil(self.meta.font.lineHeight);
  self.meta.frame = CGRectMake(FLLineMargin, FLLinePadding, width, metaHeight);
  CGFloat top = FLLinePadding + metaHeight + FLLineGap;
  self.message.frame =
    CGRectMake(FLLineMargin, top, width, CGRectGetHeight(bounds) - top - FLLinePadding);
}

@end

@interface FLLogViewController () <UITableViewDataSource, UITableViewDelegate,
                                   UISearchBarDelegate>
@end

@implementation FLLogViewController {
  NSString *_stream;
  FLLogFile *_file;
  NSMutableArray<FLLine *> *_records;
  NSMutableArray<FLLine *> *_shown;
  NSUInteger _columns;
  CGFloat _width;
  CGFloat _metaHeight;
  CGFloat _firstRow;
  CGFloat _nextRow;
  NSString *_cursor;
  NSString *_search;
  FLLevel _minimum;
  BOOL _tailing;
  BOOL _reading;
  BOOL _loaded;
  BOOL _partial;
  NSTimer *_timer;
  dispatch_queue_t _queue;
  UITableView *_table;
  UISearchBar *_searchBar;
  UILabel *_status;
  UILabel *_empty;
  UIBarButtonItem *_tailButton;
}

- (instancetype)initWithStream:(NSString *)stream {
  self = [super init];
  if (self) {
    _stream = [stream copy];
    _tailing = YES;
    [self prepare];
    self.title = stream == nil ? @"Every Log" : [FLReader streamTitle:stream];
  }
  return self;
}

- (instancetype)initWithFile:(FLLogFile *)file stream:(NSString *)stream {
  self = [super init];
  if (self) {
    _stream = [stream copy];
    _file = file;
    [self prepare];
    self.title = file.name;
  }
  return self;
}

- (void)prepare {
  _records = [NSMutableArray new];
  _shown = [NSMutableArray new];
  _minimum = FLLevelDebug;
  _queue = dispatch_queue_create("com.fleetfinch.logs.reader", DISPATCH_QUEUE_SERIAL);
  self.hidesBottomBarWhenPushed = YES;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
  _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _table.dataSource = self;
  _table.delegate = self;
  _table.estimatedRowHeight = 0;
  _metaHeight = ceil(FLMonoFont(11).lineHeight);
  [self measure];
  _table.separatorInset = UIEdgeInsetsMake(0, 10, 0, 0);
  _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
  [_table registerClass:[FLLogCell class] forCellReuseIdentifier:FLLogCellName];
  [self.view addSubview:_table];

  _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
  _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _searchBar.placeholder = @"Show only lines containing…";
  _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
  _searchBar.searchBarStyle = UISearchBarStyleMinimal;
  _searchBar.delegate = self;
  _table.tableHeaderView = _searchBar;

  _empty = [UILabel new];
  _empty.textAlignment = NSTextAlignmentCenter;
  _empty.textColor = FLMutedColor();
  _empty.numberOfLines = 0;
  _empty.font = [UIFont systemFontOfSize:15];
  _empty.text = @"Reading…";
  _table.backgroundView = _empty;

  _status = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
  _status.font = [UIFont systemFontOfSize:12];
  _status.textColor = FLMutedColor();
  _status.textAlignment = NSTextAlignmentCenter;
  _status.adjustsFontSizeToFitWidth = YES;
  _status.minimumScaleFactor = 0.8;

  UIBarButtonItem *flexible =
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                  target:nil
                                                  action:nil];
  NSMutableArray *items = [NSMutableArray new];
  if (_file == nil) {
    _tailButton = [[UIBarButtonItem alloc] initWithTitle:@"Tail"
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(toggleTail)];
    [items addObject:_tailButton];
  }
  [items addObject:flexible];
  [items addObject:[[UIBarButtonItem alloc] initWithCustomView:_status]];
  [items addObject:flexible];
  [items addObject:[[UIBarButtonItem alloc] initWithTitle:@"Level"
                                                    style:UIBarButtonItemStylePlain
                                                   target:self
                                                   action:@selector(chooseLevel:)]];
  self.toolbarItems = items;
  if (_file == nil && _stream != nil) {
    self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Files"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(showFiles)];
  }
  [self updateControls];
  [self loadInitial];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.navigationController setToolbarHidden:NO animated:animated];
  [self startTimer];
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(startTimer)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];
  [center addObserver:self
             selector:@selector(stopTimer)
                 name:UIApplicationWillResignActiveNotification
               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [self.navigationController setToolbarHidden:YES animated:animated];
  [self stopTimer];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dealloc {
  [_timer invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startTimer {
  [self stopTimer];
  if (_file != nil) {
    return;
  }
  _timer = [NSTimer scheduledTimerWithTimeInterval:FLTailEvery
                                            target:self
                                          selector:@selector(readMore)
                                          userInfo:nil
                                           repeats:YES];
}

- (void)stopTimer {
  [_timer invalidate];
  _timer = nil;
}

- (void)measure {
  CGFloat width = CGRectGetWidth(self.view.bounds);
  if (width == _width && _columns > 0) {
    return;
  }
  _width = width;
  UIFont *font = FLMonoFont(12);
  NSDictionary *attributes = @{NSFontAttributeName : font};
  CGSize open = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
  CGFloat one = [@"M" boundingRectWithSize:open
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:attributes
                                   context:nil]
                  .size.height;
  CGFloat two = [@"M\nM" boundingRectWithSize:open
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:attributes
                                      context:nil]
                  .size.height;
  _firstRow = ceil(one) + 1;
  _nextRow = ceil(two - one);
  CGFloat advance = [@"MMMMMMMMMMMMMMMMMMMM" sizeWithAttributes:attributes].width / 20.0;
  CGFloat room = width - 2 * FLLineMargin - 1;
  NSUInteger columns = advance > 0 ? (NSUInteger)floor(room / advance) : 40;
  _columns = MAX((NSUInteger)20, columns);
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  NSUInteger before = _columns;
  [self measure];
  if (before != _columns) {
    [_table reloadData];
  }
}

- (NSArray<FLLine *> *)linesFromRecords:(NSArray<FLRecord *> *)records {
  NSMutableArray *lines = [NSMutableArray arrayWithCapacity:records.count];
  for (FLRecord *record in records) {
    FLLine *line = [FLLine new];
    line.record = record;
    [lines addObject:line];
  }
  return lines;
}

- (NSArray<FLLine *> *)linesFromText:(NSArray<NSString *> *)texts {
  NSMutableArray *records = [NSMutableArray arrayWithCapacity:texts.count];
  for (NSString *text in texts) {
    NSRange tab = [text rangeOfString:@"\t"];
    if (tab.location == NSNotFound) {
      continue;
    }
    NSString *stream = [text substringToIndex:tab.location];
    NSString *rest = [text substringFromIndex:NSMaxRange(tab)];
    [records addObject:[FLRecord recordFromLine:rest stream:stream]];
  }
  return [self linesFromRecords:records];
}

- (void)loadInitial {
  FLLogFile *file = _file;
  NSString *stream = _stream;
  __weak FLLogViewController *weak = self;
  _reading = YES;
  _partial = file != nil && !file.archived && file.size > FLFileBytes;
  dispatch_async(_queue, ^{
    NSArray<FLLine *> *records = nil;
    NSString *cursor = nil;
    if (file != nil) {
      records = [weak linesFromRecords:[FLReader recordsOfFile:file.path
                                                        stream:stream
                                                          tail:FLFileBytes]];
    } else {
      NSDictionary *result = [FLReader readAfterCursor:@""
                                               streams:stream == nil ? nil : @[ stream ]
                                                 limit:FLInitialLines];
      records = [weak linesFromText:result[@"lines"]];
      cursor = result[@"cursor"];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak finishInitial:records cursor:cursor];
    });
  });
}

- (void)finishInitial:(NSArray<FLLine *> *)records cursor:(NSString *)cursor {
  _reading = NO;
  _loaded = YES;
  _cursor = cursor;
  [_records setArray:records ?: @[]];
  [self applyFilter];
  [self scrollToEnd];
}

- (void)readMore {
  if (!_tailing || _reading || !_loaded || _file != nil) {
    return;
  }
  NSString *cursor = _cursor ?: @"";
  NSString *stream = _stream;
  __weak FLLogViewController *weak = self;
  _reading = YES;
  dispatch_async(_queue, ^{
    NSDictionary *result = [FLReader readAfterCursor:cursor
                                             streams:stream == nil ? nil : @[ stream ]
                                               limit:cursor.length == 0 ? FLInitialLines
                                                                        : FLStepLines];
    NSArray<FLLine *> *records = [weak linesFromText:result[@"lines"]];
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak finishMore:records
                cursor:result[@"cursor"]
                  more:[result[@"more"] boolValue]];
    });
  });
}

- (void)finishMore:(NSArray<FLLine *> *)records cursor:(NSString *)cursor more:(BOOL)more {
  _reading = NO;
  if (cursor.length > 0) {
    _cursor = cursor;
  }
  if (records.count > 0) {
    BOOL atEnd = [self isAtEnd];
    [_records addObjectsFromArray:records];
    if (_records.count > FLKeepLines) {
      [_records removeObjectsInRange:NSMakeRange(0, _records.count - FLKeepLines)];
    }
    [self applyFilter];
    if (atEnd) {
      [self scrollToEnd];
    }
  }
  if (more) {
    [self readMore];
  }
}

- (BOOL)matches:(FLRecord *)record {
  if (record.level < _minimum) {
    return NO;
  }
  if (_search.length == 0) {
    return YES;
  }
  NSStringCompareOptions options = NSCaseInsensitiveSearch;
  return [record.message rangeOfString:_search options:options].location != NSNotFound ||
         [record.source rangeOfString:_search options:options].location != NSNotFound;
}

- (void)applyFilter {
  [_shown removeAllObjects];
  for (FLLine *line in _records) {
    if ([self matches:line.record]) {
      [_shown addObject:line];
    }
  }
  [_table reloadData];
  [self updateControls];
}

- (void)updateControls {
  _tailButton.title = _tailing ? @"Stop Tailing" : @"Tail";
  _tailButton.style = _tailing ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain;
  BOOL filtered = _shown.count != _records.count;
  NSString *count = filtered
    ? [NSString stringWithFormat:@"%lu of %lu lines", (unsigned long)_shown.count,
                                 (unsigned long)_records.count]
    : [NSString stringWithFormat:_partial ? @"Last %lu lines of the file" : @"%lu lines",
                                 (unsigned long)_records.count];
  _status.text = _file == nil && _tailing ? [@"Tailing · " stringByAppendingString:count] : count;
  if (!_loaded) {
    _empty.text = @"Reading…";
  } else if (_records.count == 0) {
    _empty.text = @"Nothing has been written here yet.";
  } else {
    _empty.text = @"No line matches what you asked to see.";
  }
  _empty.hidden = _shown.count > 0;
}

- (BOOL)isAtEnd {
  CGFloat visible = CGRectGetHeight(_table.bounds) - _table.contentInset.bottom;
  return _table.contentOffset.y + visible >= _table.contentSize.height - 120;
}

- (void)scrollToEnd {
  if (_shown.count == 0) {
    return;
  }
  NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)_shown.count - 1 inSection:0];
  [_table scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}

- (void)toggleTail {
  _tailing = !_tailing;
  [self updateControls];
  if (_tailing) {
    [self scrollToEnd];
    [self readMore];
  }
}

- (void)chooseLevel:(UIBarButtonItem *)sender {
  UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:@"Which lines to show"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
  NSArray *choices = @[
    @[ @"Everything", @(FLLevelDebug) ], @[ @"Notices and above", @(FLLevelNotice) ],
    @[ @"Warnings and above", @(FLLevelWarning) ], @[ @"Errors only", @(FLLevelError) ]
  ];
  __weak FLLogViewController *weak = self;
  for (NSArray *choice in choices) {
    FLLevel level = (FLLevel)[choice[1] integerValue];
    NSString *title = level == _minimum ? [choice[0] stringByAppendingString:@" ✓"] : choice[0];
    [sheet addAction:[UIAlertAction actionWithTitle:title
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [weak setMinimum:level];
                                            }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  sheet.popoverPresentationController.barButtonItem = sender;
  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setMinimum:(FLLevel)level {
  _minimum = level;
  [self applyFilter];
  [self scrollToEnd];
}

- (void)showFiles {
  FLFilesController *files =
    [[FLFilesController alloc] initWithGroup:_stream
                                       title:[FLReader streamTitle:_stream]
                                      stream:_stream];
  [self.navigationController pushViewController:files animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  _search = [searchText copy];
  [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [searchBar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)_shown.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  FLLine *line = _shown[(NSUInteger)indexPath.row];
  [line wrapTo:_columns];
  return 2 * FLLinePadding + _metaHeight + FLLineGap + _firstRow +
         (CGFloat)(line.rows - 1) * _nextRow;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  FLLogCell *cell = [tableView dequeueReusableCellWithIdentifier:FLLogCellName
                                                    forIndexPath:indexPath];
  FLLine *line = _shown[(NSUInteger)indexPath.row];
  [line wrapTo:_columns];
  FLRecord *record = line.record;
  UIColor *color = FLLevelColor(record.level);
  NSMutableAttributedString *meta = [[NSMutableAttributedString alloc]
    initWithString:FLLineTime(record.date)
        attributes:@{NSForegroundColorAttributeName : FLMutedColor()}];
  NSString *level = [NSString stringWithFormat:@"  %@", FLLevelName(record.level)];
  [meta appendAttributedString:[[NSAttributedString alloc]
                                 initWithString:level
                                     attributes:@{NSForegroundColorAttributeName : color}]];
  NSString *origin = _stream == nil
    ? [NSString stringWithFormat:@"  %@ · %@", [FLReader streamTitle:record.stream],
                                 record.source]
    : [@"  " stringByAppendingString:record.source ?: @""];
  [meta appendAttributedString:[[NSAttributedString alloc]
                                 initWithString:origin
                                     attributes:@{
                                       NSForegroundColorAttributeName : FLInkColor()
                                     }]];
  cell.meta.attributedText = meta;
  cell.message.text = line.text;
  cell.message.textColor = record.level >= FLLevelWarning ? color : FLInkColor();
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  FLRecord *record = _shown[(NSUInteger)indexPath.row].record;
  NSArray *pairs = @[
    @[ @"Time", record.date == nil ? @"" : FLTimestamp(record.date) ],
    @[ @"Level", FLLevelName(record.level) ],
    @[ @"Log", [FLReader streamTitle:record.stream] ],
    @[ @"From", record.source ?: @"" ],
    @[ @"Message", record.message ?: @"" ],
  ];
  FLDetailController *detail = [[FLDetailController alloc] initWithTitle:@"Line"
                                                                   pairs:pairs
                                                               monospace:@"Message"];
  [self.navigationController pushViewController:detail animated:YES];
}

@end
