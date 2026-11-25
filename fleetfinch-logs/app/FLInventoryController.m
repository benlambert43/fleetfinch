#import "FLInventoryController.h"

#import "FLDependencyIndex.h"
#import "FLInventoryListController.h"
#import "FLStatus.h"
#import "FLTheme.h"

@implementation FLInventoryController

+ (NSDate *)listed {
  return FLStateWritten(FLInventoryState);
}

+ (NSDictionary *)inventory {
  static NSDictionary *cached;
  static NSDate *written;
  NSDate *now = [self listed];
  if (now == nil) {
    return nil;
  }
  if (cached == nil || ![now isEqualToDate:written]) {
    cached = FLReadState(FLInventoryState);
    written = now;
  }
  return cached.count > 0 ? cached : nil;
}

+ (FLDependencyIndex *)index {
  static FLDependencyIndex *cached;
  static NSDate *written;
  static NSDate *listed;
  NSDate *now = FLStateWritten(FLDependenciesState);
  NSDate *list = [self listed];
  NSDictionary *inventory = [self inventory];
  if (now == nil || list == nil || inventory == nil) {
    return nil;
  }
  if (cached == nil || ![now isEqualToDate:written] || ![list isEqualToDate:listed]) {
    cached = [[FLDependencyIndex alloc] initWithDependencies:FLReadState(FLDependenciesState)
                                                   inventory:inventory];
    written = now;
    listed = list;
  }
  return cached;
}

- (instancetype)init {
  self = [super initGrouped:YES];
  if (self) {
    self.title = @"What Is Installed";
    self.refreshInterval = 5;
  }
  return self;
}

- (void)listAgain {
  if (!FLServiceRunning(FLServiceStatus())) {
    [self showMessage:@"The Finch Logs service is not running, so nothing can be listed."
                title:@"Service Not Running"];
    return;
  }
  FLPostCommand(FLCommandInventory);
  [self showMessage:@"The service is listing everything that is installed. That takes about a "
                    @"minute and a half, and this screen shows the new list when it is done."
              title:nil];
}

- (void)open:(NSString *)kind title:(NSString *)title {
  FLInventoryListController *list = [[FLInventoryListController alloc] initWithKind:kind
                                                                              title:title];
  [self.navigationController pushViewController:list animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  NSDictionary *inventory = [FLInventoryController inventory];
  __weak FLInventoryController *weak = self;
  FLSection *actions = [FLSection sectionWithTitle:nil];
  [actions addRow:[FLRow buttonWithTitle:inventory == nil ? @"List Now" : @"List Again"
                                  action:^{
                                    [weak listAgain];
                                  }]];
  if (inventory == nil) {
    actions.footer = @"The service has not listed what is installed yet. It does so within a "
                     @"few minutes of starting, and needs about a minute and a half with the "
                     @"device awake.";
    return @[ actions ];
  }

  FLSection *kinds = [FLSection sectionWithTitle:@"Installed"];
  for (NSDictionary *kind in inventory[@"kinds"]) {
    uint64_t bytes = [kind[@"bytes"] unsignedLongLongValue];
    NSString *key = kind[@"kind"];
    NSString *title = kind[@"title"];
    NSString *detail = bytes > 0
      ? [NSString stringWithFormat:@"%@ · %@", kind[@"count"], FLFormatBytes(bytes)]
      : [kind[@"count"] description];
    [kinds addRow:[FLRow linkWithTitle:title
                                detail:detail
                                action:^{
                                  [weak open:key title:title];
                                }]];
  }
  kinds.footer = @"A size is the space on the volume that removing the thing would free. Each "
                 @"kind's size leaves out what is nested inside its folders and counted under "
                 @"another kind.";

  FLSection *storage = [FLSection sectionWithTitle:@"System Volume"];
  NSDictionary *volume = inventory[@"volume"];
  NSDictionary *counted = inventory[@"counted"];
  NSDictionary *cache = inventory[@"cache"];
  uint64_t taken = [counted[@"bytes"] unsignedLongLongValue];
  uint64_t held = [counted[@"held"] unsignedLongLongValue];
  if (volume != nil) {
    [storage add:@"Capacity" detail:FLFormatBytes([volume[@"total"] unsignedLongLongValue])];
    [storage add:@"Free" detail:FLFormatBytes([volume[@"free"] unsignedLongLongValue])];
  }
  [storage add:@"Taken by Files"
        detail:[NSString stringWithFormat:@"%@ in %@ files", FLFormatBytes(taken),
                                          counted[@"files"] ?: @0]];
  NSString *others = [NSString stringWithFormat:@"%@ in %lu folders",
                                                FLFormatBytes(taken > held ? taken - held : 0),
                                                (unsigned long)[inventory[@"areas"] count]];
  [storage addRow:[FLRow linkWithTitle:@"Other Files"
                                detail:others
                                action:^{
                                  [weak open:FLInventoryOtherFiles title:@"Other Files"];
                                }]];
  if ([cache[@"libraries"] unsignedIntegerValue] > 0) {
    uint64_t whole = [cache[@"bytes"] unsignedLongLongValue];
    [storage add:@"Shared Library Cache"
          detail:[NSString stringWithFormat:@"%@ libraries in %@", cache[@"libraries"],
                                            FLFormatBytes(whole)]];
  }
  storage.footer = @"Other files belong to none of the kinds above: fonts, sounds, language "
                   @"data and the shared library cache, one file that holds most of the "
                   @"system's libraries. The rest of the volume is the file system's own "
                   @"records.";

  NSDate *gathered = inventory[@"gathered"];
  if ([gathered isKindOfClass:[NSDate class]]) {
    actions.footer = [NSString
      stringWithFormat:@"Listed %@ (%@) in %@. The service lists everything again once a day, "
                       @"and when something is installed or removed.",
                       FLFormatDay(gathered), FLAgo(gathered),
                       FLFormatDuration([inventory[@"took"] doubleValue])];
  }
  return @[ kinds, storage, actions ];
}

@end
