#import "FLInventoryItemController.h"

#import "FLDependencyIndex.h"
#import "FLDetailController.h"
#import "FLInventoryController.h"
#import "FLRelatedController.h"
#import "FLTheme.h"
#import "FLUsageController.h"

static NSString *FLJoined(id names) {
  return [names isKindOfClass:[NSArray class]] ? [names componentsJoinedByString:@", "] : @"";
}

static NSString *FLSentence(NSString *text) {
  return text.length == 0 ? @""
                          : [[text substringToIndex:1].uppercaseString
                              stringByAppendingString:[text substringFromIndex:1]];
}

@implementation FLInventoryItemController {
  NSDictionary *_item;
}

+ (NSString *)titleOf:(NSDictionary *)item {
  NSString *kind = item[@"kind"];
  NSString *path = item[@"path"] ?: @"";
  if ([kind isEqualToString:@"xpc"]) {
    return item[@"id"] ?: item[@"name"] ?: path;
  }
  if ([kind isEqualToString:@"bundle"]) {
    return path.lastPathComponent;
  }
  return item[@"name"] ?: path.lastPathComponent;
}

+ (NSString *)sizeOf:(NSDictionary *)item {
  if (item[@"bytes"] != nil) {
    return FLFormatBytes([item[@"bytes"] unsignedLongLongValue]);
  }
  if ([item[@"inCache"] boolValue]) {
    return [NSString stringWithFormat:@"%@ in the shared cache",
                                      FLFormatBytes([item[@"cached"] unsignedLongLongValue])];
  }
  return nil;
}

- (instancetype)initWithItem:(NSDictionary *)item {
  self = [super initGrouped:YES];
  if (self) {
    _item = item;
    self.title = [FLInventoryItemController titleOf:item];
    self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Copy"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(copyAll)];
  }
  return self;
}

- (NSString *)libraryOf:(NSDictionary *)item {
  if ([item[@"inCache"] boolValue]) {
    return [NSString stringWithFormat:@"In the shared cache, %@",
                                      FLFormatBytes([item[@"cached"] unsignedLongLongValue])];
  }
  return item[@"binary"] != nil ? @"On disk" : @"None";
}

- (NSDictionary *)usageOf:(NSDictionary *)item {
  NSString *kind = item[@"kind"];
  NSString *wanted = @"service";
  NSString *key = item[@"id"];
  if ([kind isEqualToString:@"app"]) {
    wanted = @"app";
  } else if ([kind isEqualToString:@"program"]) {
    wanted = @"program";
    key = item[@"path"];
  } else if (![@[ @"extension", @"xpc", @"service" ] containsObject:kind]) {
    return nil;
  }
  for (NSDictionary *row in [FLUsageController report][@"rows"]) {
    if ([row[@"kind"] isEqualToString:wanted] && [row[@"key"] isEqualToString:key ?: @""]) {
      return row;
    }
  }
  return nil;
}

- (NSString *)runsOf:(NSDictionary *)item {
  NSDictionary *usage = [self usageOf:item];
  if (usage == nil) {
    return nil;
  }
  NSDate *began = [FLUsageController report][@"began"];
  NSString *since = [began isKindOfClass:[NSDate class]] ? FLFormatDay(began) : @"the start";
  if (![usage[@"ran"] boolValue]) {
    return [NSString stringWithFormat:@"Never, counted since %@", since];
  }
  NSString *runs = FLCount([usage[@"runs"] unsignedIntegerValue], @"run");
  if ([usage[@"running"] unsignedIntegerValue] > 0) {
    return [NSString stringWithFormat:@"%@ since %@, running now", runs, since];
  }
  return [NSString stringWithFormat:@"%@ since %@, last seen %@", runs, since,
                                    FLAgo(usage[@"last"])];
}

- (NSString *)readingOf:(NSDictionary *)item {
  NSDate *counting = [FLInventoryController inventory][@"reading"][@"began"];
  NSString *kind = item[@"kind"];
  if (![counting isKindOfClass:[NSDate class]] || [item[@"data"] boolValue] ||
      [kind isEqualToString:@"service"]) {
    return nil;
  }
  NSString *since = FLFormatDay(counting);
  NSUInteger read = [item[@"read"] unsignedIntegerValue];
  if ([kind isEqualToString:@"program"] || [kind isEqualToString:@"library"]) {
    if (item[@"lastRead"] == nil) {
      return nil;
    }
    return [NSString stringWithFormat:@"%@ since %@", read > 0 ? @"Read" : @"Not read", since];
  }
  if (item[@"files"] == nil) {
    return nil;
  }
  NSString *described = read == 0 && [item[@"listed"] unsignedIntegerValue] > 0
    ? @", only the files that describe it"
    : @"";
  NSString *found = read == 0 ? @"None" : [@(read) description];
  return [NSString stringWithFormat:@"%@ of its %@ files since %@%@", found, item[@"files"], since,
                                    described];
}

- (NSString *)lastReadOf:(NSDictionary *)item {
  NSDate *last = item[@"lastRead"];
  NSDate *made = [FLInventoryController inventory][@"reading"][@"made"];
  if (![last isKindOfClass:[NSDate class]]) {
    return nil;
  }
  if ([made isKindOfClass:[NSDate class]] && [last compare:made] == NSOrderedAscending) {
    return @"Not since iOS was installed";
  }
  return [NSString stringWithFormat:@"%@ (%@)", FLFormatDay(last), FLAgo(last)];
}

- (NSString *)startingOf:(NSDictionary *)item {
  NSDictionary *startup = [FLInventoryController startup];
  NSDictionary<NSString *, NSNumber *> *files = startup[@"files"];
  NSUInteger starts = [startup[@"starts"] unsignedIntegerValue];
  NSString *path = item[@"path"];
  if (starts == 0 || path == nil || ![files isKindOfClass:[NSDictionary class]] ||
      [item[@"kind"] isEqualToString:@"service"] || [item[@"inCache"] boolValue]) {
    return nil;
  }
  NSString *prefix = [path stringByAppendingString:@"/"];
  NSUInteger found = 0;
  for (NSString *file in files) {
    found += [file isEqualToString:path] || [file hasPrefix:prefix] ? 1 : 0;
  }
  return [NSString stringWithFormat:@"%@, over %@",
                                    found == 0 ? @"Nothing" : FLCount(found, @"file"),
                                    FLCount(starts, @"recorded start")];
}

- (NSArray<NSArray<NSString *> *> *)pairsFor:(NSDictionary *)item {
  NSString *kind = item[@"kind"];
  NSMutableArray<NSArray<NSString *> *> *pairs = [NSMutableArray new];
  NSString *own = item[@"own"] == nil
    ? @""
    : [NSString stringWithFormat:@"%@, the rest is nested inside",
                                 FLFormatBytes([item[@"own"] unsignedLongLongValue])];
  NSDictionary<NSString *, NSArray<NSString *> *> *events = item[@"events"];
  NSMutableArray<NSString *> *wanted = [NSMutableArray new];
  for (NSString *stream in [events.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [wanted addObject:[NSString stringWithFormat:@"%@: %@", stream, FLJoined(events[stream])]];
  }
  BOOL service = [kind isEqualToString:@"service"];
  BOOL library = [kind isEqualToString:@"framework"] || [kind isEqualToString:@"bundle"];
  NSString *type = item[@"type"] ?: @"";
  if ([kind isEqualToString:@"app"]) {
    type = [item[@"hidden"] boolValue] ? [type stringByAppendingString:@", hidden"] : type;
  } else if ([type isEqualToString:@"script"]) {
    type = [NSString stringWithFormat:@"Script for %@", item[@"interpreter"] ?: @"an interpreter"];
  }
  NSString *needed = FLSentence(FLNeedText(item[@"need"]));
  if ([item[@"shadowed"] boolValue]) {
    needed = @"Never loaded: the shared cache holds a library of the same name, and that one "
             @"is used";
  }
  [pairs addObject:@[ @"Name", service ? @"" : (item[@"name"] ?: @"") ]];
  [pairs addObject:@[ service ? @"Label" : @"Identifier", item[@"id"] ?: @"" ]];
  [pairs addObject:@[ @"Version", item[@"version"] ?: @"" ]];
  [pairs addObject:@[ @"Kind", type ]];
  [pairs addObject:@[ @"Extension Point", item[@"point"] ?: @"" ]];
  [pairs addObject:@[ @"Starts", item[@"starts"] ?: @"" ]];
  [pairs addObject:@[ @"Runs As", item[@"user"] ?: @"" ]];
  [pairs addObject:@[ @"Size", [FLInventoryItemController sizeOf:item] ?: @"" ]];
  [pairs addObject:@[ @"Its Own Files", own ]];
  [pairs addObject:@[ @"Files", [item[@"files"] description] ?: @"" ]];
  [pairs addObject:@[ @"Holds", item[@"holds"] ?: @"" ]];
  [pairs addObject:@[ @"Library", library ? [self libraryOf:item] : @"" ]];
  [pairs addObject:@[ @"Needed", needed ]];
  [pairs addObject:@[ @"From", item[@"from"] ?: @"" ]];
  [pairs addObject:@[ @"Inside", item[@"inside"] ?: @"" ]];
  [pairs addObject:@[ @"Seen Running", [self runsOf:item] ?: @"" ]];
  [pairs addObject:@[ @"Files Read", [self readingOf:item] ?: @"" ]];
  [pairs addObject:@[ @"Last Read", [self lastReadOf:item] ?: @"" ]];
  [pairs addObject:@[ @"Read While Starting", [self startingOf:item] ?: @"" ]];
  [pairs addObject:@[ @"Run By", FLJoined(item[@"runBy"]) ]];
  [pairs addObject:@[ @"URL Schemes", FLJoined(item[@"schemes"]) ]];
  [pairs addObject:@[ @"Background Modes", FLJoined(item[@"background"]) ]];
  [pairs addObject:@[ @"Mach Services", FLJoined(item[@"machServices"]) ]];
  [pairs addObject:@[ @"Sockets", FLJoined(item[@"sockets"]) ]];
  [pairs addObject:@[ @"Events", [wanted componentsJoinedByString:@"\n"] ]];
  if (service) {
    uint64_t bytes = [item[@"programBytes"] unsignedLongLongValue];
    [pairs addObject:@[ @"Program", item[@"command"] ?: item[@"program"] ?: @"" ]];
    [pairs addObject:@[ @"Program Size", bytes > 0 ? FLFormatBytes(bytes) : @"" ]];
    [pairs addObject:@[ @"Defined In", item[@"path"] ?: @"" ]];
  } else {
    [pairs addObject:@[ @"Program", item[@"program"] ?: @"" ]];
    [pairs addObject:@[ @"Path", item[@"path"] ?: @"" ]];
  }
  NSMutableArray<NSArray<NSString *> *> *shown = [NSMutableArray new];
  for (NSArray<NSString *> *pair in pairs) {
    if (pair[1].length > 0) {
      [shown addObject:pair];
    }
  }
  return shown;
}

- (NSDictionary *)current {
  return [[FLInventoryController index] itemAtPath:_item[@"path"]] ?: _item;
}

- (void)copyAll {
  NSMutableArray<NSString *> *lines = [NSMutableArray new];
  for (NSArray<NSString *> *pair in [self pairsFor:[self current]]) {
    [lines addObject:[NSString stringWithFormat:@"%@: %@", pair[0], pair[1]]];
  }
  [UIPasteboard generalPasteboard].string = [lines componentsJoinedByString:@"\n"];
  [self showMessage:@"What this screen says about it was copied." title:nil];
}

- (void)open:(UIViewController *)controller {
  controller.hidesBottomBarWhenPushed = YES;
  [self.navigationController pushViewController:controller animated:YES];
}

- (NSArray<FLSection *> *)buildSections {
  NSDictionary *item = [self current];
  FLSection *about = [FLSection sectionWithTitle:nil];
  for (NSArray<NSString *> *pair in [self pairsFor:item]) {
    FLRow *row = [about add:pair[0] detail:pair[1]];
    if ([pair[0] isEqualToString:@"Program"]) {
      row.stacked = YES;
      row.monospace = YES;
    }
  }
  about.footer = @"Touch and hold a row to copy it.";

  FLSection *depends = [FLSection sectionWithTitle:@"What It Needs and What Needs It"];
  FLDependencyIndex *index = [FLInventoryController index];
  if (index == nil) {
    depends.footer = @"What depends on what has not been worked out yet. The service does "
                     @"that each time it lists what is installed.";
    return @[ about, depends ];
  }
  __weak FLInventoryItemController *weak = self;
  for (NSDictionary *relation in [index relationsOfItem:item]) {
    NSArray<NSDictionary *> *rows = relation[@"rows"];
    NSString *title = relation[@"title"];
    [depends addRow:[FLRow linkWithTitle:title
                                  detail:[@(rows.count) description]
                                  action:^{
                                    [weak open:[[FLRelatedController alloc] initWithTitle:title
                                                                                     rows:rows]];
                                  }]];
  }
  NSArray<NSArray<NSString *> *> *granted = [index entitlementsOfItem:item];
  if (granted.count > 0) {
    [depends addRow:[FLRow linkWithTitle:@"Entitlements"
                                  detail:[@(granted.count) description]
                                  action:^{
                                    [weak open:[[FLDetailController alloc]
                                                 initWithTitle:@"Entitlements"
                                                         pairs:granted
                                                     monospace:nil]];
                                  }]];
  }
  depends.footer = depends.rows.count == 0
    ? @"Nothing was found that this needs, or that needs it."
    : @"It cannot load without what it links. What it opens by name, and the services it "
      @"names, are found among its own strings, so a name it puts together while running "
      @"is not seen. Needed by Nothing Else lists what no other program, plug-in or library "
      @"that was found would need if this were gone.";
  return @[ about, depends ];
}

@end
