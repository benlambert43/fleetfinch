#import "FFCleanupController.h"

#import <notify.h>

#import "FFCleanup.h"
#import "FFCleanupGroupController.h"

static const NSTimeInterval FFHelperPatience = 30;

static NSString *FFThings(NSUInteger count) {
  return [NSString stringWithFormat:@"%lu %@", (unsigned long)count,
                                    count == 1 ? @"thing" : @"things"];
}

static FFCleanupCount *FFCountEverything(BOOL measure,
                                         NSMutableDictionary<NSString *, FFCleanupCount *> *each) {
  FFCleanupCount *total = [FFCleanupCount new];
  for (FFCleanupGroup *group in FFCleanupGroups()) {
    FFCleanupCount *count = FFCountGroup(group, measure);
    each[group.identifier] = count;
    [total add:count];
  }
  return total;
}

NSString *FFCleanupSummary(void) {
  FFCleanupCount *total = FFCountEverything(NO, [NSMutableDictionary new]);
  NSUInteger listed = total.present + total.removed;
  if (listed == 0) {
    return @"Nothing listed";
  }
  if (total.removed == 0) {
    return @"Not removed";
  }
  return [NSString stringWithFormat:@"%lu of %lu removed", (unsigned long)total.removed,
                                    (unsigned long)listed];
}

@implementation FFCleanupController {
  NSDictionary<NSString *, FFCleanupCount *> *_counts;
  FFCleanupCount *_total;
  BOOL _measured;
  NSDate *_asked;
  int _token;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    self.title = @"Stock Apps and Services";
    _token = NOTIFY_TOKEN_INVALID;
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
  __weak FFCleanupController *weak = self;
  notify_register_dispatch(FFCleanupChanged.UTF8String, &_token, dispatch_get_main_queue(),
                           ^(int token) {
                             [weak changed];
                           });
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self count];
}

- (BOOL)working {
  NSDictionary *progress = FFReadProgress();
  if ([progress[@"running"] boolValue]) {
    return YES;
  }
  NSDate *finished = progress[@"finished"];
  BOOL answered = [finished isKindOfClass:[NSDate class]] && _asked != nil &&
                  [finished compare:_asked] != NSOrderedAscending;
  return _asked != nil && !answered && -_asked.timeIntervalSinceNow < FFHelperPatience;
}

- (void)changed {
  if (![FFReadProgress()[@"running"] boolValue]) {
    [self count];
  }
  [self reload];
}

- (void)count {
  NSMutableDictionary<NSString *, FFCleanupCount *> *quick = [NSMutableDictionary new];
  _total = FFCountEverything(NO, quick);
  _counts = quick;
  _measured = NO;
  [self reload];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSMutableDictionary<NSString *, FFCleanupCount *> *full = [NSMutableDictionary new];
    FFCleanupCount *total = FFCountEverything(YES, full);
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_total = total;
      self->_counts = full;
      self->_measured = YES;
      [self reload];
    });
  });
}

- (NSString *)amount:(NSUInteger)count bytes:(uint64_t)bytes {
  if (count == 0) {
    return @"Nothing";
  }
  return _measured ? [NSString stringWithFormat:@"%@, %@", FFThings(count), FFFormatBytes(bytes)]
                   : FFThings(count);
}

- (void)ask:(NSString *)verb title:(NSString *)title message:(NSString *)message {
  UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:title
                                        message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
  __weak FFCleanupController *weak = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:title
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            [weak send:verb];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)send:(NSString *)verb {
  _asked = FFSendRequest(verb, @[]) != nil ? [NSDate date] : nil;
  [self reload];
  __weak FFCleanupController *weak = self;
  dispatch_time_t later =
    dispatch_time(DISPATCH_TIME_NOW, (int64_t)((FFHelperPatience + 1) * NSEC_PER_SEC));
  dispatch_after(later, dispatch_get_main_queue(), ^{
    [weak reload];
  });
}

- (NSString *)caution {
  if (FFDeviceIsTested()) {
    return @"";
  }
  return [NSString stringWithFormat:@" This list was tested on other devices, not on %@ with "
                                    @"iOS %@.",
                                    FFDeviceModel(), FFSystemVersion()];
}

- (FFSection *)summarySection {
  NSDictionary *progress = FFReadProgress();
  NSMutableArray<FFRow *> *rows = [NSMutableArray new];
  [rows addObject:[FFRow rowWithTitle:@"Removed"
                               detail:[self amount:_total.removed bytes:_total.removedBytes]]];
  [rows addObject:[FFRow rowWithTitle:@"Still installed"
                               detail:[self amount:_total.present bytes:_total.presentBytes]]];
  [rows addObject:[FFRow rowWithTitle:@"Free on the system volume"
                               detail:FFFormatBytes(FFRoomAt(@"/"))]];
  if ([progress[@"running"] boolValue]) {
    BOOL removing = [progress[@"verb"] isEqual:FFVerbRemove];
    NSString *step = [NSString stringWithFormat:@"%@ of %@: %@", progress[@"done"],
                                                progress[@"total"], progress[@"current"]];
    [rows addObject:[FFRow rowWithTitle:removing ? @"Removing" : @"Putting back" detail:step]];
  } else if ([self working]) {
    [rows addObject:[FFRow rowWithTitle:@"Working" detail:@"Waiting for the helper"]];
  }
  NSString *about = @"Removes the stock apps and services this device has been tested without. "
                    @"Safari and Settings stay. Each thing is copied to the data volume first, "
                    @"so it can be put back.";
  return [FFSection sectionWithTitle:nil
                                rows:rows
                              footer:[about stringByAppendingString:[self caution]]];
}

- (FFSection *)groupSection {
  NSMutableArray<FFRow *> *rows = [NSMutableArray new];
  __weak FFCleanupController *weak = self;
  for (FFCleanupGroup *group in FFCleanupGroups()) {
    FFCleanupCount *count = _counts[group.identifier];
    NSUInteger listed = count.present + count.removed;
    NSString *said = count.removed == 0
      ? [self amount:count.present bytes:count.presentBytes]
      : [NSString stringWithFormat:@"%lu of %lu removed", (unsigned long)count.removed,
                                   (unsigned long)listed];
    [rows addObject:[FFRow rowWithTitle:group.title
                                 detail:said
                                 action:^{
                                   FFCleanupGroupController *page =
                                     [[FFCleanupGroupController alloc] initWithGroup:group];
                                   [weak.navigationController pushViewController:page animated:YES];
                                 }]];
  }
  return [FFSection sectionWithTitle:@"What It Removes" rows:rows footer:nil];
}

- (NSString *)lastRun {
  NSDictionary *progress = FFReadProgress();
  NSDate *finished = progress[@"finished"];
  NSMutableArray<NSString *> *said = [NSMutableArray new];
  if (_asked != nil && ![self working] &&
      (![finished isKindOfClass:[NSDate class]] ||
       [finished compare:_asked] == NSOrderedAscending)) {
    [said addObject:@"The helper did not answer. Restart the device and try again."];
  }
  if ([finished isKindOfClass:[NSDate class]] && [progress[@"result"] isKindOfClass:[NSString class]]) {
    [said addObject:[NSString stringWithFormat:@"Last run, %@: %@", FFFormatDay(finished),
                                               progress[@"result"]]];
    NSArray *problems = progress[@"problems"];
    if ([problems isKindOfClass:[NSArray class]] && problems.count > 0) {
      [said addObject:[NSString stringWithFormat:@"%@ left as they were. The first: %@",
                                                 FFThings(problems.count), problems.firstObject]];
    }
  }
  for (NSDictionary *batch in FFReadJournal()[@"batches"]) {
    if (batch[@"restored"] == nil && batch[@"survived"] == nil) {
      [said addObject:@"The newest removals have not been through a restart. If the device "
                      @"cannot be reached after its next restart, they are put back by "
                      @"themselves."];
      break;
    }
  }
  return said.count > 0 ? [said componentsJoinedByString:@"\n\n"] : nil;
}

- (FFSection *)actionSection {
  NSMutableArray<FFRow *> *rows = [NSMutableArray new];
  __weak FFCleanupController *weak = self;
  BOOL idle = ![self working];
  if (idle && _total.present > 0) {
    NSString *message = [NSString stringWithFormat:@"%@ will be copied to the data volume and "
                                                   @"deleted from the system volume.%@",
                                                   FFThings(_total.present), [self caution]];
    [rows addObject:[FFRow buttonWithTitle:@"Remove Stock Apps and Services"
                               destructive:YES
                                    action:^{
                                      [weak ask:FFVerbRemove title:@"Remove" message:message];
                                    }]];
  }
  if (idle && _total.removed > 0) {
    NSString *message = [NSString stringWithFormat:@"%@ will be copied back to where they were.",
                                                   FFThings(_total.removed)];
    [rows addObject:[FFRow buttonWithTitle:@"Put Everything Back"
                               destructive:NO
                                    action:^{
                                      [weak ask:FFVerbRestore title:@"Put Back" message:message];
                                    }]];
  }
  if (rows.count == 0) {
    [rows addObject:[FFRow rowWithTitle:idle ? @"Nothing to do" : @"Working" detail:nil]];
  }
  return [FFSection sectionWithTitle:nil rows:rows footer:[self lastRun]];
}

- (NSArray<FFSection *> *)buildSections {
  if (_total == nil) {
    return @[];
  }
  return @[ [self summarySection], [self groupSection], [self actionSection] ];
}

@end
