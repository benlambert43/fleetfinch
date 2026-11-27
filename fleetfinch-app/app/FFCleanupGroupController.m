#import "FFCleanupGroupController.h"

#import <notify.h>

#import "FFCleanup.h"

static NSString *const FFServiceExtension = @"plist";
static NSString *const FFVendorPrefix = @"com.apple.";

static NSString *FFShownName(NSString *path) {
  NSString *name = path.lastPathComponent;
  if ([name.pathExtension isEqualToString:FFServiceExtension]) {
    name = name.stringByDeletingPathExtension;
  }
  return [name hasPrefix:FFVendorPrefix] ? [name substringFromIndex:FFVendorPrefix.length] : name;
}

@implementation FFCleanupGroupController {
  FFCleanupGroup *_group;
  NSDictionary<NSString *, NSNumber *> *_sizes;
  int _token;
}

- (instancetype)initWithGroup:(FFCleanupGroup *)group {
  self = [super init];
  if (self) {
    _group = group;
    _token = NOTIFY_TOKEN_INVALID;
    self.title = group.title;
  }
  return self;
}

- (void)dealloc {
  if (_token != NOTIFY_TOKEN_INVALID) {
    notify_cancel(_token);
  }
}

- (void)viewDidLoad {
  [super viewDidLoad];
  __weak FFCleanupGroupController *weak = self;
  notify_register_dispatch(FFCleanupChanged.UTF8String, &_token, dispatch_get_main_queue(),
                           ^(int token) {
                             [weak reload];
                             if (![FFReadProgress()[@"running"] boolValue]) {
                               [weak measure];
                             }
                           });
}

- (void)ask:(NSString *)verb title:(NSString *)title message:(NSString *)message {
  UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:title
                                        message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
  NSString *identifier = _group.identifier;
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:title
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            FFSendRequest(verb, @[ identifier ]);
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reload];
  [self measure];
}

- (void)measure {
  FFCleanupGroup *group = _group;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary new];
    for (NSString *path in group.paths) {
      FFItemState state = FFStateOfPath(path);
      if (state != FFItemAbsent) {
        NSString *where = state == FFItemRemoved ? FFKeptPath(path) : path;
        sizes[path] = @(FFSpaceTaken(where, NULL, NULL));
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_sizes = sizes;
      [self reload];
    });
  });
}

- (NSArray<FFSection *> *)buildSections {
  NSMutableArray<FFRow *> *rows = [NSMutableArray new];
  NSUInteger present = 0;
  NSUInteger removed = 0;
  for (NSString *path in _group.paths) {
    FFItemState state = FFStateOfPath(path);
    NSString *said = state == FFItemPresent ? @"Installed"
                                            : (state == FFItemRemoved ? @"Removed" : @"Not here");
    NSNumber *size = _sizes[path];
    if (size != nil && state != FFItemAbsent) {
      said = [NSString stringWithFormat:@"%@, %@", said, FFFormatBytes(size.unsignedLongLongValue)];
    }
    [rows addObject:[FFRow rowWithTitle:FFShownName(path) detail:said]];
    present += state == FFItemPresent ? 1 : 0;
    removed += state == FFItemRemoved ? 1 : 0;
  }
  NSMutableArray<FFRow *> *actions = [NSMutableArray new];
  __weak FFCleanupGroupController *weak = self;
  NSDictionary *progress = FFReadProgress();
  if ([progress[@"running"] boolValue]) {
    NSString *step = [NSString stringWithFormat:@"%@ of %@", progress[@"done"], progress[@"total"]];
    [actions addObject:[FFRow rowWithTitle:@"Working" detail:step]];
  } else {
    if (present > 0) {
      [actions addObject:[FFRow buttonWithTitle:@"Remove This Group"
                                    destructive:YES
                                         action:^{
                                           [weak ask:FFVerbRemove
                                               title:@"Remove"
                                             message:@"It is copied to the data volume first, so "
                                                     @"it can be put back."];
                                         }]];
    }
    if (removed > 0) {
      [actions addObject:[FFRow buttonWithTitle:@"Put This Group Back"
                                    destructive:NO
                                         action:^{
                                           [weak ask:FFVerbRestore
                                               title:@"Put Back"
                                             message:@"It is copied back to where it was."];
                                         }]];
    }
  }
  NSMutableArray<FFSection *> *sections = [NSMutableArray new];
  if (actions.count > 0) {
    [sections addObject:[FFSection sectionWithTitle:nil rows:actions footer:_group.about]];
  }
  [sections addObject:[FFSection sectionWithTitle:@"What Is in It" rows:rows footer:nil]];
  return sections;
}

@end
