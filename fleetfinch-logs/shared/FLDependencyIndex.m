#import "FLDependencyIndex.h"

#import "FLLoaded.h"

NSArray<NSString *> *FLNeedOrder(void) {
  return @[ @"loaded", @"seen", @"opened", @"idle", @"plugin", @"unseen", @"orphan" ];
}

NSString *FLNeedText(NSString *need) {
  NSDictionary<NSString *, NSString *> *texts = @{
    @"loaded" : @"loaded by a program that has run",
    @"seen" : @"seen loaded in a running program",
    @"opened" : @"may be opened by a program that has run",
    @"idle" : @"needed only by programs that have never run",
    @"plugin" : @"needed only by plug-ins that nothing names",
    @"unseen" : @"a plug-in that nothing names",
    @"orphan" : @"nothing found that needs it",
  };
  return texts[need] ?: @"";
}

static NSArray<NSString *> *FLListed(id value) {
  return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static void FLGather(NSMutableDictionary<NSString *, NSMutableArray *> *table, NSString *key,
                     NSDictionary *node) {
  NSMutableArray *nodes = table[key];
  if (nodes == nil) {
    nodes = [NSMutableArray new];
    table[key] = nodes;
  }
  [nodes addObject:node];
}

@implementation FLDependencyIndex {
  NSMutableDictionary<NSString *, NSDictionary *> *_items;
  NSMutableDictionary<NSString *, NSDictionary *> *_nodes;
  NSMutableDictionary<NSString *, NSDictionary *> *_owned;
  NSMutableDictionary<NSString *, NSMutableArray *> *_users;
  NSMutableDictionary<NSString *, NSMutableArray *> *_openers;
  NSMutableDictionary<NSString *, NSMutableArray *> *_talkers;
}

- (instancetype)initWithDependencies:(NSDictionary *)dependencies
                           inventory:(NSDictionary *)inventory {
  self = [super init];
  if (self) {
    _dependencies = dependencies;
    _inventory = inventory;
    _items = [NSMutableDictionary new];
    _nodes = [NSMutableDictionary new];
    _owned = [NSMutableDictionary new];
    _users = [NSMutableDictionary new];
    _openers = [NSMutableDictionary new];
    _talkers = [NSMutableDictionary new];
    for (NSDictionary *item in FLListed(inventory[@"items"])) {
      NSString *path = item[@"path"];
      if (path != nil && _items[path] == nil) {
        _items[path] = item;
      }
    }
    for (NSDictionary *node in FLListed(dependencies[@"nodes"])) {
      NSString *path = node[@"path"];
      if (path == nil) {
        continue;
      }
      _nodes[path] = node;
      _owned[node[@"item"] ?: path] = node;
      for (NSString *target in FLListed(node[@"links"])) {
        FLGather(_users, target, node);
      }
      for (NSString *target in FLListed(node[@"opens"])) {
        FLGather(_openers, target, node);
      }
      for (NSString *name in FLListed(node[@"talks"])) {
        FLGather(_talkers, name, node);
      }
    }
  }
  return self;
}

- (NSDictionary *)itemAtPath:(NSString *)path {
  return path == nil ? nil : _items[path];
}

- (NSDictionary *)nodeAtPath:(NSString *)path {
  return path == nil ? nil : _nodes[path];
}

- (NSDictionary *)nodeOfItem:(NSDictionary *)item {
  NSString *path = item[@"path"];
  NSDictionary *node = path == nil ? nil : _owned[path];
  return node ?: [self nodeAtPath:item[@"program"]];
}

- (NSDictionary *)itemOfNode:(NSDictionary *)node {
  return [self itemAtPath:node[@"item"] ?: node[@"path"]];
}

- (NSString *)nameOfNode:(NSDictionary *)node {
  NSDictionary *item = [self itemOfNode:node];
  NSString *path = node[@"path"] ?: @"";
  if (item != nil && ![@[ @"program", @"library" ] containsObject:item[@"kind"]]) {
    return item[@"name"] ?: path.lastPathComponent;
  }
  return path.lastPathComponent;
}

- (NSSet<NSString *> *)pathsLinkedFrom:(NSArray<NSString *> *)programs {
  NSMutableSet<NSString *> *linked = [NSMutableSet new];
  NSMutableArray<NSString *> *waiting = [programs mutableCopy];
  while (waiting.count > 0) {
    NSString *path = waiting.lastObject;
    [waiting removeLastObject];
    if ([linked containsObject:path]) {
      continue;
    }
    [linked addObject:path];
    NSDictionary *node = _nodes[path];
    if (node[@"item"] != nil) {
      [linked addObject:node[@"item"]];
    }
    [waiting addObjectsFromArray:FLListed(node[@"links"])];
  }
  return linked;
}

- (NSArray<NSDictionary *> *)usersOfNode:(NSDictionary *)node {
  return _users[node[@"path"] ?: @""] ?: @[];
}

- (NSArray<NSDictionary *> *)openersOfNode:(NSDictionary *)node {
  return _openers[node[@"path"] ?: @""] ?: @[];
}

- (NSArray<NSString *> *)namesOfferedBy:(NSDictionary *)item {
  if ([item[@"kind"] isEqualToString:@"xpc"]) {
    return item[@"id"] == nil ? @[] : @[ item[@"id"] ];
  }
  return FLListed(item[@"machServices"]);
}

- (NSArray<NSDictionary *> *)clientsOfItem:(NSDictionary *)item {
  NSDictionary *own = [self nodeOfItem:item];
  NSMutableArray<NSDictionary *> *clients = [NSMutableArray new];
  NSMutableSet<NSString *> *seen = [NSMutableSet new];
  for (NSString *name in [self namesOfferedBy:item]) {
    for (NSDictionary *node in _talkers[name]) {
      NSString *path = node[@"path"];
      if (node == own || [seen containsObject:path]) {
        continue;
      }
      [seen addObject:path];
      [clients addObject:node];
    }
  }
  return clients;
}

- (NSDictionary *)rowForNode:(NSDictionary *)node note:(NSString *)note {
  NSString *path = node[@"path"] ?: @"";
  NSMutableDictionary *row = [NSMutableDictionary new];
  row[@"title"] = [self nameOfNode:node];
  row[@"detail"] = note.length > 0 ? [NSString stringWithFormat:@"%@ · %@", path, note] : path;
  NSString *item = [self itemOfNode:node][@"path"];
  if (item != nil) {
    row[@"item"] = item;
  }
  return row;
}

- (NSArray<NSDictionary *> *)rowsForNodes:(NSArray<NSDictionary *> *)nodes {
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSDictionary *node in nodes) {
    [rows addObject:[self rowForNode:node note:nil]];
  }
  [rows sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSComparisonResult names = [first[@"title"] caseInsensitiveCompare:second[@"title"]];
    return names != NSOrderedSame ? names : [first[@"detail"] compare:second[@"detail"]];
  }];
  return rows;
}

- (void)add:(NSString *)key
      title:(NSString *)title
       rows:(NSArray<NSDictionary *> *)rows
         to:(NSMutableArray<NSDictionary *> *)sections {
  if (rows.count > 0) {
    [sections addObject:@{@"key" : key, @"title" : title, @"rows" : rows}];
  }
}

- (NSArray<NSDictionary *> *)relationsOfItem:(NSDictionary *)item {
  NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
  NSDictionary *node = [self nodeOfItem:item];
  NSSet<NSString *> *weak = [NSSet setWithArray:FLListed(node[@"weak"])];
  NSMutableArray<NSDictionary *> *needs = [NSMutableArray new];
  for (NSString *path in FLListed(node[@"links"])) {
    NSDictionary *target = [self nodeAtPath:path];
    if (target != nil) {
      [needs addObject:[self rowForNode:target
                                   note:[weak containsObject:path] ? @"only if it is there"
                                                                   : nil]];
    }
  }
  [self add:@"needs" title:@"Links" rows:needs to:sections];

  NSMutableArray<NSDictionary *> *missing = [NSMutableArray new];
  for (NSString *name in FLListed(node[@"missing"])) {
    [missing addObject:@{@"title" : name, @"detail" : @"not on this device, so this cannot load"}];
  }
  for (NSString *name in FLListed(node[@"absent"])) {
    [missing addObject:@{@"title" : name, @"detail" : @"not on this device, and done without"}];
  }
  [self add:@"missing" title:@"Links but Missing" rows:missing to:sections];

  NSMutableArray<NSDictionary *> *opened = [NSMutableArray new];
  for (NSString *path in FLListed(node[@"opens"])) {
    NSDictionary *target = [self nodeAtPath:path];
    if (target != nil) {
      [opened addObject:target];
    }
  }
  [self add:@"opens" title:@"Opens by Name" rows:[self rowsForNodes:opened] to:sections];

  NSDictionary<NSString *, NSArray<NSString *> *> *offers = _dependencies[@"offers"];
  NSMutableArray<NSDictionary *> *talks = [NSMutableArray new];
  for (NSString *name in FLListed(node[@"talks"])) {
    NSMutableArray<NSString *> *givers = [NSMutableArray new];
    NSString *first = nil;
    for (NSString *path in FLListed(offers[name])) {
      NSDictionary *giver = [self itemAtPath:path];
      NSString *shown = giver[@"name"] ?: path.lastPathComponent;
      if (![givers containsObject:shown]) {
        [givers addObject:shown];
      }
      first = first ?: path;
    }
    NSMutableDictionary *row = [NSMutableDictionary new];
    row[@"title"] = name;
    row[@"detail"] =
      [@"offered by " stringByAppendingString:[givers componentsJoinedByString:@", "]];
    if (first != nil) {
      row[@"item"] = first;
    }
    [talks addObject:row];
  }
  [self add:@"talks" title:@"Names the Services" rows:talks to:sections];

  if (node != nil && ![node[@"type"] isEqualToString:@"program"]) {
    [self add:@"users"
        title:@"Linked By"
         rows:[self rowsForNodes:[self usersOfNode:node]]
           to:sections];
    [self add:@"openers"
        title:@"Opened by Name By"
         rows:[self rowsForNodes:[self openersOfNode:node]]
           to:sections];
  }
  [self add:@"clients"
      title:@"Named By"
       rows:[self rowsForNodes:[self clientsOfItem:item]]
         to:sections];
  NSString *own = node[@"path"];
  if (own != nil && [node[@"type"] isEqualToString:@"program"]) {
    [self add:@"loads"
        title:@"Seen Loading From Files of Their Own"
         rows:[self rowsForPaths:[self pathsLoadedBy:own]]
           to:sections];
  } else if (own != nil) {
    [self add:@"loaders"
        title:@"Seen Loaded By"
         rows:[self rowsForPaths:FLLoadedBy(self.loaded, own)]
           to:sections];
  }
  [self addTracedFor:item[@"path"] program:own to:sections];
  return sections;
}

- (NSArray<NSDictionary *> *)rowsForUses:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)uses
                                   named:(NSString * (^)(NSString *key))named {
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSString *key in uses) {
    NSArray<NSNumber *> *counted = uses[key];
    NSString *path = named(key);
    if (path.length == 0 || counted.count < 2) {
      continue;
    }
    NSDictionary *node = [self nodeAtPath:path];
    NSMutableDictionary *row = [NSMutableDictionary new];
    row[@"title"] = node != nil ? [self nameOfNode:node] : path.lastPathComponent;
    row[@"detail"] = [NSString stringWithFormat:@"opened %@, looked at %@ · %@", counted[0],
                                                counted[1], path];
    NSString *item = [self itemOfNode:node][@"path"] ?: [self itemAtPath:path][@"path"];
    if (item != nil) {
      row[@"item"] = item;
    }
    [rows addObject:row];
  }
  [rows sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    return [first[@"title"] caseInsensitiveCompare:second[@"title"]];
  }];
  return rows;
}

- (void)addTracedFor:(NSString *)path
             program:(NSString *)program
                  to:(NSMutableArray<NSDictionary *> *)sections {
  NSArray<NSString *> *programs = self.traced[@"programs"];
  NSDictionary<NSString *, NSDictionary *> *files = self.traced[@"files"];
  NSDictionary<NSString *, NSDictionary *> *links = self.traced[@"links"];
  if (![programs isKindOfClass:[NSArray class]]) {
    return;
  }
  NSString * (^programAt)(NSString *) = ^NSString *(NSString *place) {
    NSUInteger index = (NSUInteger)place.integerValue;
    return index < programs.count ? programs[index] : nil;
  };
  if ([files isKindOfClass:[NSDictionary class]] && path != nil) {
    [self add:@"readers"
        title:@"Had Files Reached By"
         rows:[self rowsForUses:files[path][@"by"] named:programAt]
           to:sections];
  }
  NSUInteger place = program == nil ? NSNotFound : [programs indexOfObject:program];
  if (place == NSNotFound) {
    return;
  }
  NSString *own = @(place).stringValue;
  if ([files isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *reached = [NSMutableDictionary new];
    for (NSString *area in files) {
      NSArray<NSNumber *> *counted = files[area][@"by"][own];
      if (counted != nil && [area hasPrefix:@"/"]) {
        reached[area] = counted;
      }
    }
    [self add:@"reads"
        title:@"Reached Files In"
         rows:[self rowsForUses:reached
                          named:^NSString *(NSString *area) {
                            return area;
                          }]
           to:sections];
  }
  if (![links isKindOfClass:[NSDictionary class]]) {
    return;
  }
  NSMutableArray<NSString *> *held = [NSMutableArray new];
  for (NSString *other in links[own]) {
    [held addObject:programAt(other) ?: @""];
  }
  NSMutableArray<NSString *> *holders = [NSMutableArray new];
  for (NSString *other in links) {
    if (links[other][own] != nil) {
      [holders addObject:programAt(other) ?: @""];
    }
  }
  [self add:@"talksTo" title:@"Holds Connections To" rows:[self rowsForPaths:held] to:sections];
  [self add:@"talkedTo"
      title:@"Programs Holding Connections to It"
       rows:[self rowsForPaths:holders]
         to:sections];
}

- (NSArray<NSString *> *)pathsLoadedBy:(NSString *)program {
  NSDictionary<NSString *, NSDictionary *> *libraries = self.loaded[@"libraries"];
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  if (![libraries isKindOfClass:[NSDictionary class]]) {
    return paths;
  }
  for (NSString *path in libraries) {
    if (![libraries[path][@"cached"] boolValue] &&
        [FLLoadedBy(self.loaded, path) containsObject:program]) {
      [paths addObject:path];
    }
  }
  return paths;
}

- (NSArray<NSDictionary *> *)rowsForPaths:(NSArray<NSString *> *)paths {
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  for (NSString *path in [paths sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *node = [self nodeAtPath:path];
    [rows addObject:node != nil ? [self rowForNode:node note:nil]
                                : @{@"title" : path.lastPathComponent, @"detail" : path}];
  }
  return rows;
}

- (NSArray<NSArray<NSString *> *> *)entitlementsOfItem:(NSDictionary *)item {
  NSDictionary<NSString *, NSString *> *granted = [self nodeOfItem:item][@"entitlements"];
  NSMutableArray<NSArray<NSString *> *> *pairs = [NSMutableArray new];
  if (![granted isKindOfClass:[NSDictionary class]]) {
    return pairs;
  }
  for (NSString *key in [granted.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [pairs addObject:@[ key, [granted[key] description] ]];
  }
  return pairs;
}

- (NSArray<NSDictionary *> *)itemsNamed:(NSString *)name {
  NSDictionary *exact = [self itemAtPath:name] ?: [self itemOfNode:[self nodeAtPath:name]];
  if (exact != nil) {
    return @[ exact ];
  }
  NSMutableArray<NSDictionary *> *found = [NSMutableArray new];
  for (NSDictionary *item in FLListed(_inventory[@"items"])) {
    NSString *path = item[@"path"] ?: @"";
    NSArray<NSString *> *known = @[
      item[@"id"] ?: @"", item[@"name"] ?: @"", path.lastPathComponent,
      path.lastPathComponent.stringByDeletingPathExtension
    ];
    for (NSString *each in known) {
      if ([each caseInsensitiveCompare:name] == NSOrderedSame) {
        [found addObject:item];
        break;
      }
    }
  }
  return found;
}

@end
