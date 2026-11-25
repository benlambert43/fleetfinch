#import "FLTextController.h"

#import "FLReader.h"
#import "FLTheme.h"

static const NSUInteger FLTextLimit = 600 * 1024;

@implementation FLTextController {
  NSString *_path;
  UITextView *_text;
  UIActivityIndicatorView *_spinner;
  NSString *_loaded;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title {
  self = [super init];
  if (self) {
    _path = [path copy];
    self.title = title;
    self.hidesBottomBarWhenPushed = YES;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  _text = [[UITextView alloc] initWithFrame:self.view.bounds];
  _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _text.editable = NO;
  _text.font = FLMonoFont(11);
  _text.textColor = FLInkColor();
  _text.alwaysBounceVertical = YES;
  _text.layoutManager.allowsNonContiguousLayout = YES;
  _text.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
  [self.view addSubview:_text];
  _spinner = [[UIActivityIndicatorView alloc]
    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  _spinner.center = CGPointMake(CGRectGetMidX(self.view.bounds), 120);
  _spinner.autoresizingMask =
    UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
  [self.view addSubview:_spinner];
  [_spinner startAnimating];
  self.navigationItem.rightBarButtonItem =
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                  target:self
                                                  action:@selector(share:)];
  self.navigationItem.rightBarButtonItem.enabled = NO;
  NSString *path = _path;
  __weak FLTextController *weak = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *text = [FLTextController textOfFile:path];
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak show:text];
    });
  });
}

+ (NSString *)textOfFile:(NSString *)path {
  uint64_t size = FLFileSize(path);
  NSData *data = [FLReader startOfFile:path limit:FLTextLimit + 1];
  if (data == nil) {
    return @"This file could not be read. It may have been archived or deleted a moment ago.";
  }
  if (data.length == 0) {
    return @"This file is empty.";
  }
  const uint8_t *bytes = data.bytes;
  NSUInteger sample = MIN(data.length, (NSUInteger)4096);
  NSUInteger odd = 0;
  for (NSUInteger index = 0; index < sample; index++) {
    uint8_t byte = bytes[index];
    if (byte == 0 || (byte < 0x20 && byte != '\n' && byte != '\r' && byte != '\t')) {
      odd++;
    }
  }
  if (odd * 20 > sample) {
    return [NSString
      stringWithFormat:@"This dump is not text, so it cannot be shown here (%@).\n\nIt is "
                       @"kept as it was written and is included when the logs are exported "
                       @"with “finchlog dump” or imported by FleetFinch on a computer.",
                       FLFormatBytes(size)];
  }
  BOOL cut = data.length > FLTextLimit;
  NSString *text = FLStringFromData(cut ? [data subdataWithRange:NSMakeRange(0, FLTextLimit)]
                                        : data);
  if (cut) {
    text = [text stringByAppendingFormat:@"\n\n… Only the first %@ is shown here.",
                                         FLFormatBytes(FLTextLimit)];
  }
  return text;
}

- (void)show:(NSString *)text {
  [_spinner stopAnimating];
  _loaded = text;
  _text.text = text;
  self.navigationItem.rightBarButtonItem.enabled = text.length > 0;
}

- (void)share:(UIBarButtonItem *)sender {
  if (_loaded.length == 0) {
    return;
  }
  UIActivityViewController *share =
    [[UIActivityViewController alloc] initWithActivityItems:@[ _loaded ]
                                      applicationActivities:nil];
  share.popoverPresentationController.barButtonItem = sender;
  [self presentViewController:share animated:YES completion:nil];
}

@end
