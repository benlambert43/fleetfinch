#import "FLDepends.h"

#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <unistd.h>

#import "FLCollect.h"
#import "FLCommon.h"
#import "FLDependencyIndex.h"
#import "FLMachO.h"
#import "FLStatus.h"

static const NSUInteger FLNamesShown = 25;
static NSString *const FLLoaderPrefix = @"@loader_path/";
static NSString *const FLProgramPrefix = @"@executable_path/";
static NSString *const FLSearchPrefix = @"@rpath/";

static NSArray<NSString *> *FLLookupKeys(void) {
  return @[
    @"com.apple.security.exception.mach-lookup.global-name",
    @"com.apple.security.temporary-exception.mach-lookup.global-name"
  ];
}

static NSSet<NSString *> *FLSharedFolders(void) {
  return [NSSet setWithArray:@[
    @"/System/Library", @"/System/Library/CoreServices", @"/System/Library/Frameworks",
    @"/System/Library/PrivateFrameworks", @"/usr/lib", @"/usr/libexec", @"/Applications",
    @"/Library"
  ]];
}

static NSArray *FLList(id value) {
  return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSString *FLCleanPath(NSString *path) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  for (NSString *part in [path componentsSeparatedByString:@"/"]) {
    if (part.length == 0 || [part isEqualToString:@"."]) {
      continue;
    }
    if ([part isEqualToString:@".."]) {
      [parts removeLastObject];
      continue;
    }
    [parts addObject:part];
  }
  return [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
}

@interface FLNode : NSObject

@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSMutableDictionary *item;
@property(nonatomic, strong) FLImage *image;
@property(nonatomic, strong) FLSharedCache *cache;
@property(nonatomic) uint64_t offset;
@property(nonatomic) NSUInteger index;
@property(nonatomic, strong) NSMutableArray<FLNode *> *links;
@property(nonatomic, strong) NSMutableArray<FLNode *> *weak;
@property(nonatomic, strong) NSMutableArray<FLNode *> *opens;
@property(nonatomic, strong) NSMutableArray<NSString *> *missing;
@property(nonatomic, strong) NSMutableArray<NSString *> *absent;
@property(nonatomic, strong) NSMutableArray<NSString *> *talks;
@property(nonatomic, strong) NSDictionary *entitlements;
@property(nonatomic, copy) NSString *need;
@property(nonatomic) BOOL shadowed;

@end

@implementation FLNode

- (instancetype)init {
  self = [super init];
  if (self) {
    _links = [NSMutableArray new];
    _weak = [NSMutableArray new];
    _opens = [NSMutableArray new];
    _missing = [NSMutableArray new];
    _absent = [NSMutableArray new];
    _talks = [NSMutableArray new];
  }
  return self;
}

- (NSString *)type {
  if ([self.image isProgram]) {
    return @"program";
  }
  return [self.image isPlugIn] ? @"plug-in" : @"library";
}

@end

static NSArray<NSString *> *FLPathsOf(NSArray<FLNode *> *nodes) {
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  for (FLNode *node in nodes) {
    [paths addObject:node.path];
  }
  return paths;
}

@interface FLGatherer : NSObject

- (instancetype)initWithInventory:(NSDictionary *)inventory usage:(NSDictionary *)usage;
- (NSDictionary *)gather;

@end

@implementation FLGatherer {
  NSDictionary *_inventory;
  NSDictionary *_usage;
  NSMutableArray<FLNode *> *_nodes;
  NSMutableDictionary<NSString *, FLNode *> *_byPath;
  NSMutableDictionary<NSString *, FLNode *> *_cachedAt;
  NSMutableOrderedSet<NSString *> *_searchRoots;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_items;
  NSMutableDictionary<NSString *, FLNode *> *_ofItem;
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_offers;
  NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *_own;
  NSArray<FLSharedCache *> *_caches;
  NSUInteger _unread;
}

- (instancetype)initWithInventory:(NSDictionary *)inventory usage:(NSDictionary *)usage {
  self = [super init];
  if (self) {
    _inventory = inventory;
    _usage = usage;
    _nodes = [NSMutableArray new];
    _byPath = [NSMutableDictionary new];
    _cachedAt = [NSMutableDictionary new];
    _searchRoots = [NSMutableOrderedSet new];
    _items = [NSMutableDictionary new];
    _ofItem = [NSMutableDictionary new];
    _offers = [NSMutableDictionary new];
    _own = [NSMutableDictionary new];
  }
  return self;
}

- (FLNode *)addNode:(NSString *)path item:(NSMutableDictionary *)item {
  FLNode *node = [FLNode new];
  node.path = path;
  node.item = [item isKindOfClass:[NSMutableDictionary class]] ? item : nil;
  node.index = _nodes.count;
  [_nodes addObject:node];
  _byPath[path] = node;
  if (item[@"path"] != nil) {
    _ofItem[item[@"path"]] = node;
  }
  return node;
}

- (FLNode *)nodeNamed:(NSString *)path {
  return path == nil ? nil : (_cachedAt[path] ?: _byPath[path]);
}

- (void)listNodes {
  NSMutableDictionary<NSString *, NSMutableDictionary *> *cached = [NSMutableDictionary new];
  NSMutableArray<NSArray *> *files = [NSMutableArray new];
  NSArray<NSString *> *run = @[ @"app", @"extension", @"xpc" ];
  NSArray<NSString *> *held = @[ @"framework", @"bundle" ];
  for (NSMutableDictionary *item in FLList(_inventory[@"items"])) {
    NSString *kind = item[@"kind"];
    NSString *path = item[@"path"];
    if (path == nil) {
      continue;
    }
    _items[path] = item;
    BOOL inCache = [item[@"inCache"] boolValue];
    NSString *binary = nil;
    if ([kind isEqualToString:@"program"]) {
      binary = [item[@"type"] isEqualToString:@"script"] ? nil : path;
    } else if ([kind isEqualToString:@"library"]) {
      binary = inCache ? nil : path;
      if (inCache) {
        cached[path] = item;
      }
    } else if ([run containsObject:kind]) {
      binary = item[@"program"];
    } else if ([held containsObject:kind]) {
      binary = inCache ? nil : item[@"binary"];
      if (inCache && item[@"binary"] != nil) {
        cached[item[@"binary"]] = item;
      }
    }
    if (binary != nil) {
      [files addObject:@[ binary, item ]];
    }
  }
  _caches = [FLSharedCache caches];
  for (FLSharedCache *cache in _caches) {
    for (NSDictionary *image in cache.images) {
      NSString *path = image[@"path"];
      if (_cachedAt[path] != nil) {
        continue;
      }
      FLNode *node = [self addNode:path item:cached[path]];
      node.cache = cache;
      node.offset = [image[@"offset"] unsignedLongLongValue];
      _cachedAt[path] = node;
      for (NSString *alias in FLList(image[@"aliases"])) {
        if (_cachedAt[alias] == nil) {
          _cachedAt[alias] = node;
        }
      }
    }
  }
  for (NSArray *file in files) {
    NSString *path = file[0];
    FLNode *taken = _byPath[path];
    if (taken == nil) {
      [self addNode:path item:file[1]].shadowed = _cachedAt[path] != nil;
    } else if (taken.cache != nil) {
      file[1][@"shadowed"] = @YES;
    }
  }
}

- (void)readImages {
  for (FLNode *node in _nodes) {
    @autoreleasepool {
      if (node.cache != nil) {
        node.image = FLReadImage(node.cache.handle, node.offset);
      } else {
        int handle = open(node.path.fileSystemRepresentation, O_RDONLY);
        if (handle >= 0) {
          node.image = FLReadImageFile(handle);
          if ([node.image isProgram]) {
            node.entitlements = FLReadEntitlements(handle, node.image);
          }
          close(handle);
        }
      }
      _unread += node.image == nil ? 1 : 0;
    }
  }
}

- (FLNode *)programFor:(FLNode *)node {
  NSArray<NSString *> *run = @[ @"app", @"extension", @"xpc" ];
  NSDictionary *item = node.item;
  while (item != nil) {
    if ([run containsObject:item[@"kind"]]) {
      return _ofItem[item[@"path"]];
    }
    item = item[@"inside"] == nil ? nil : _items[item[@"inside"]];
  }
  return nil;
}

- (NSString *)expand:(NSString *)name from:(FLNode *)node {
  if ([name hasPrefix:FLLoaderPrefix]) {
    NSString *folder = node.path.stringByDeletingLastPathComponent;
    NSString *rest = [name substringFromIndex:FLLoaderPrefix.length];
    return FLCleanPath([folder stringByAppendingPathComponent:rest]);
  }
  if ([name hasPrefix:FLProgramPrefix]) {
    FLNode *program = [node.image isProgram] ? node : [self programFor:node] ?: node;
    NSString *folder = program.path.stringByDeletingLastPathComponent;
    NSString *rest = [name substringFromIndex:FLProgramPrefix.length];
    return FLCleanPath([folder stringByAppendingPathComponent:rest]);
  }
  return [name hasPrefix:@"/"] ? FLCleanPath(name) : nil;
}

- (FLNode *)resolve:(NSString *)name from:(FLNode *)node {
  if ([name hasPrefix:FLSearchPrefix]) {
    NSString *rest = [name substringFromIndex:FLSearchPrefix.length];
    FLNode *program = [self programFor:node];
    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    for (FLNode *each in program == nil || program == node ? @[ node ] : @[ node, program ]) {
      for (NSString *path in each.image.searchPaths) {
        NSString *root = [self expand:path from:each];
        if (root != nil) {
          [roots addObject:root];
        }
      }
      [roots addObject:[each.path.stringByDeletingLastPathComponent
                         stringByAppendingPathComponent:@"Frameworks"]];
    }
    [roots addObjectsFromArray:_searchRoots.array];
    for (NSString *root in roots) {
      FLNode *found = [self nodeNamed:FLCleanPath([root stringByAppendingPathComponent:rest])];
      if (found != nil) {
        return found;
      }
    }
    return nil;
  }
  NSString *path = [self expand:name from:node];
  FLNode *found = [self nodeNamed:path];
  char real[PATH_MAX];
  if (found == nil && path != nil && realpath(path.fileSystemRepresentation, real) != NULL) {
    found = [self nodeNamed:[NSString stringWithUTF8String:real]];
  }
  return found;
}

- (void)link {
  for (FLNode *node in _nodes) {
    for (NSString *path in node.image.searchPaths) {
      NSString *root = [self expand:path from:node];
      if (root != nil) {
        [_searchRoots addObject:root];
      }
    }
  }
  for (FLNode *node in _nodes) {
    @autoreleasepool {
      NSSet<NSString *> *weak = [NSSet setWithArray:node.image.weakLinks ?: @[]];
      for (NSString *name in node.image.links) {
        FLNode *target = [self resolve:name from:node];
        BOOL optional = [weak containsObject:name];
        if (target == nil) {
          [optional ? node.absent : node.missing addObject:name];
        } else if (target != node && ![node.links containsObject:target]) {
          [node.links addObject:target];
          if (optional) {
            [node.weak addObject:target];
          }
        }
      }
    }
  }
}

- (void)noteOffers {
  for (NSMutableDictionary *item in FLList(_inventory[@"items"])) {
    NSString *kind = item[@"kind"];
    NSString *path = item[@"path"];
    NSArray<NSString *> *names = nil;
    FLNode *runner = path == nil ? nil : _ofItem[path];
    if ([kind isEqualToString:@"xpc"]) {
      names = item[@"id"] == nil ? nil : @[ item[@"id"] ];
    } else if ([kind isEqualToString:@"app"]) {
      names = FLList(item[@"machServices"]);
    } else if ([kind isEqualToString:@"service"]) {
      names = FLList(item[@"machServices"]);
      runner = [self nodeNamed:item[@"program"]];
    }
    for (NSString *name in names) {
      NSMutableArray<NSString *> *givers = _offers[name] ?: [NSMutableArray new];
      if (path != nil && ![givers containsObject:path]) {
        [givers addObject:path];
      }
      _offers[name] = givers;
    }
    if (runner != nil && names.count > 0) {
      NSMutableSet<NSString *> *own = _own[runner.path] ?: [NSMutableSet new];
      [own addObjectsFromArray:names];
      _own[runner.path] = own;
    }
  }
}

- (void)note:(NSIndexSet *)found meanings:(NSArray *)meanings for:(FLNode *)node {
  NSSet<NSString *> *own = _own[node.path];
  [found enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
    id meaning = meanings[index];
    if ([meaning isKindOfClass:[NSString class]]) {
      if (![own containsObject:meaning] && ![node.talks containsObject:meaning]) {
        [node.talks addObject:meaning];
      }
      return;
    }
    NSArray<FLNode *> *targets = [meaning isKindOfClass:[FLNode class]] ? @[ meaning ] : meaning;
    for (FLNode *target in targets) {
      if (target != node && ![node.links containsObject:target] &&
          ![node.opens containsObject:target]) {
        [node.opens addObject:target];
      }
    }
  }];
  for (NSString *key in FLLookupKeys()) {
    for (NSString *name in FLList(node.entitlements[key])) {
      if (_offers[name] != nil && ![own containsObject:name] &&
          ![node.talks containsObject:name]) {
        [node.talks addObject:name];
      }
    }
  }
  [node.talks sortUsingSelector:@selector(compare:)];
}

- (void)scan {
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  NSMutableArray *meanings = [NSMutableArray new];
  NSMutableSet<NSString *> *taken = [NSMutableSet new];
  void (^add)(NSString *, id) = ^(NSString *name, id meaning) {
    if (name.length > 0 && ![taken containsObject:name]) {
      [taken addObject:name];
      [names addObject:name];
      [meanings addObject:meaning];
    }
  };
  for (NSDictionary<NSString *, FLNode *> *known in @[ _cachedAt, _byPath ]) {
    for (NSString *path in known) {
      FLNode *node = known[path];
      if (node.image != nil && ![node.image isProgram]) {
        add(path, node);
      }
    }
  }
  NSMutableDictionary<NSString *, NSMutableArray<FLNode *> *> *folders =
    [NSMutableDictionary new];
  for (FLNode *node in _nodes) {
    NSString *kind = node.item[@"kind"];
    NSString *folder = node.item[@"path"];
    BOOL plugged = [kind isEqualToString:@"bundle"];
    if (node.image == nil || folder == nil ||
        !(plugged || [kind isEqualToString:@"framework"])) {
      continue;
    }
    add(folder, node);
    add([folder stringByAppendingString:@"/"], node);
    NSString *group = node.item[@"group"];
    if (plugged && group != nil) {
      NSMutableArray<FLNode *> *inside = folders[group] ?: [NSMutableArray new];
      [inside addObject:node];
      folders[group] = inside;
    }
  }
  NSSet<NSString *> *shared = FLSharedFolders();
  for (NSString *folder in folders) {
    if (_items[folder] == nil && ![shared containsObject:folder]) {
      add(folder, folders[folder]);
      add([folder stringByAppendingString:@"/"], folders[folder]);
    }
  }
  for (NSString *name in _offers) {
    add(name, name);
  }
  FLNameSet *set = [[FLNameSet alloc] initWithNames:names];
  for (FLNode *node in _nodes) {
    @autoreleasepool {
      FLImage *image = node.image;
      NSMutableIndexSet *found = [NSMutableIndexSet new];
      uint64_t offset = 0;
      if (image == nil || image.encrypted) {
        continue;
      }
      if (node.cache != nil) {
        if ([node.cache offset:&offset ofAddress:image.stringsAddress]) {
          [set scan:node.cache.handle offset:offset size:image.stringsSize into:found];
        }
      } else if (image.stringsSize > 0) {
        int handle = open(node.path.fileSystemRepresentation, O_RDONLY);
        if (handle >= 0) {
          [set scan:handle offset:image.stringsOffset size:image.stringsSize into:found];
          close(handle);
        }
      }
      [self note:found meanings:meanings for:node];
    }
  }
}

- (NSIndexSet *)reachFrom:(NSArray<FLNode *> *)starts soft:(BOOL)soft {
  NSMutableIndexSet *reached = [NSMutableIndexSet new];
  NSMutableArray<FLNode *> *waiting = [starts mutableCopy];
  while (waiting.count > 0) {
    FLNode *node = waiting.lastObject;
    [waiting removeLastObject];
    for (NSArray<FLNode *> *next in soft ? @[ node.links, node.opens ] : @[ node.links ]) {
      for (FLNode *target in next) {
        if (![reached containsIndex:target.index]) {
          [reached addIndex:target.index];
          [waiting addObject:target];
        }
      }
    }
  }
  return reached;
}

- (void)classify {
  NSDictionary *entries = _usage[@"entries"];
  if (![entries isKindOfClass:[NSDictionary class]] || entries.count == 0) {
    return;
  }
  NSMutableArray<FLNode *> *programs = [NSMutableArray new];
  NSMutableArray<FLNode *> *ran = [NSMutableArray new];
  for (FLNode *node in _nodes) {
    if ([node.image isProgram]) {
      [programs addObject:node];
      if (entries[[@"program:" stringByAppendingString:node.path]] != nil) {
        [ran addObject:node];
      }
    }
  }
  NSIndexSet *loaded = [self reachFrom:ran soft:NO];
  NSIndexSet *opened = [self reachFrom:ran soft:YES];
  NSIndexSet *named = [self reachFrom:programs soft:YES];
  NSMutableArray<FLNode *> *unseen = [NSMutableArray new];
  for (FLNode *node in _nodes) {
    if ([node.image isPlugIn] && ![named containsIndex:node.index]) {
      [unseen addObject:node];
    }
  }
  NSIndexSet *plugged = [self reachFrom:unseen soft:YES];
  NSDictionary *seen = FLReadState(FLLoadedState)[@"libraries"];
  for (FLNode *node in _nodes) {
    if (node.image == nil || [node.image isProgram]) {
      continue;
    }
    if ([loaded containsIndex:node.index]) {
      node.need = @"loaded";
    } else if ([seen isKindOfClass:[NSDictionary class]] && seen[node.path] != nil) {
      node.need = @"seen";
    } else if ([opened containsIndex:node.index]) {
      node.need = @"opened";
    } else if ([named containsIndex:node.index]) {
      node.need = @"idle";
    } else if ([node.image isPlugIn]) {
      node.need = @"unseen";
    } else {
      node.need = [plugged containsIndex:node.index] ? @"plugin" : @"orphan";
    }
  }
}

- (NSDictionary *)describe:(FLNode *)node {
  NSMutableDictionary *record = [NSMutableDictionary new];
  record[@"path"] = node.path;
  record[@"type"] = [node type];
  NSString *owner = node.item[@"path"];
  if (owner != nil && ![owner isEqualToString:node.path]) {
    record[@"item"] = owner;
  }
  if (node.cache != nil) {
    record[@"cached"] = @YES;
  }
  if (node.shadowed) {
    record[@"shadowed"] = @YES;
  }
  NSDictionary<NSString *, NSArray *> *lists = @{
    @"links" : FLPathsOf(node.links),
    @"weak" : FLPathsOf(node.weak),
    @"opens" : [FLPathsOf(node.opens) sortedArrayUsingSelector:@selector(compare:)],
    @"missing" : node.missing,
    @"absent" : node.absent,
    @"talks" : node.talks,
  };
  for (NSString *key in lists) {
    if (lists[key].count > 0) {
      record[key] = lists[key];
    }
  }
  if (node.entitlements.count > 0) {
    NSMutableDictionary *granted = [NSMutableDictionary new];
    for (id key in node.entitlements) {
      granted[[key description]] = FLDescribeValue(node.entitlements[key]);
    }
    record[@"entitlements"] = granted;
  }
  if (node.need != nil) {
    record[@"need"] = node.need;
  }
  return record;
}

- (void)countInto:(NSMutableDictionary *)counted {
  NSCountedSet<NSString *> *users = [NSCountedSet new];
  NSCountedSet<NSString *> *openers = [NSCountedSet new];
  NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *talkers =
    [NSMutableDictionary new];
  NSUInteger links = 0, opens = 0, talks = 0, missing = 0, programs = 0, plugged = 0, held = 0;
  for (FLNode *node in _nodes) {
    if (node.image == nil) {
      continue;
    }
    programs += [node.image isProgram] ? 1 : 0;
    plugged += [node.image isPlugIn] ? 1 : 0;
    held += node.cache != nil ? 1 : 0;
    links += node.links.count;
    opens += node.opens.count;
    talks += node.talks.count;
    missing += node.missing.count > 0 ? 1 : 0;
    for (FLNode *target in node.links) {
      [users addObject:target.path];
    }
    for (FLNode *target in node.opens) {
      [openers addObject:target.path];
    }
    for (NSString *name in node.talks) {
      for (NSString *giver in _offers[name]) {
        NSMutableSet<NSString *> *callers = talkers[giver] ?: [NSMutableSet new];
        [callers addObject:node.path];
        talkers[giver] = callers;
      }
    }
  }
  for (FLNode *node in _nodes) {
    if (node.image == nil || node.item == nil) {
      continue;
    }
    node.item[@"needs"] = @(node.links.count);
    if (![node.image isProgram]) {
      node.item[@"users"] = @([users countForObject:node.path]);
      node.item[@"openers"] = @([openers countForObject:node.path]);
    }
    if (node.need != nil) {
      node.item[@"need"] = node.need;
    }
    if (node.shadowed) {
      node.item[@"shadowed"] = @YES;
    }
  }
  for (NSString *giver in talkers) {
    _items[giver][@"clients"] = @(talkers[giver].count);
  }
  NSUInteger read = _nodes.count - _unread;
  counted[@"programs"] = @(programs);
  counted[@"plugins"] = @(plugged);
  counted[@"libraries"] = @(read - programs - plugged);
  counted[@"cached"] = @(held);
  counted[@"onDisk"] = @(read - held);
  counted[@"links"] = @(links);
  counted[@"opens"] = @(opens);
  counted[@"talks"] = @(talks);
  counted[@"missing"] = @(missing);
  counted[@"unread"] = @(_unread);
}

- (NSDictionary *)gather {
  [self listNodes];
  [self readImages];
  [self link];
  [self noteOffers];
  [self scan];
  [self classify];
  NSMutableDictionary *counted = [NSMutableDictionary new];
  [self countInto:counted];
  NSMutableArray<NSDictionary *> *nodes = [NSMutableArray new];
  for (FLNode *node in _nodes) {
    if (node.image != nil) {
      [nodes addObject:[self describe:node]];
    }
  }
  [nodes sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    return [first[@"path"] compare:second[@"path"]];
  }];
  NSMutableDictionary *dependencies = [NSMutableDictionary new];
  dependencies[@"version"] = @1;
  dependencies[@"gathered"] = [NSDate date];
  dependencies[@"counted"] = counted;
  dependencies[@"nodes"] = nodes;
  dependencies[@"offers"] = _offers;
  NSDate *began = _usage[@"began"];
  if ([began isKindOfClass:[NSDate class]]) {
    dependencies[@"began"] = began;
  }
  return dependencies;
}

@end

NSDictionary *FLGatherDependencies(NSDictionary *inventory, NSDictionary *usage) {
  return [[[FLGatherer alloc] initWithInventory:inventory usage:usage] gather];
}

BOOL FLSaveDependencies(NSDictionary *dependencies) {
  return FLWriteCompactState(FLDependenciesState, dependencies);
}

NSString *FLDependenciesSummary(NSDictionary *dependencies) {
  NSDictionary *counted = dependencies[@"counted"];
  return [NSString
    stringWithFormat:@"Read %@ programs, %@ libraries and %@ plug-ins: %@ files on disk and %@ "
                     @"libraries in the shared cache. They link one another %@ times, open one "
                     @"another by name %@ times and name services %@ times",
                     counted[@"programs"] ?: @0, counted[@"libraries"] ?: @0,
                     counted[@"plugins"] ?: @0, counted[@"onDisk"] ?: @0,
                     counted[@"cached"] ?: @0, counted[@"links"] ?: @0, counted[@"opens"] ?: @0,
                     counted[@"talks"] ?: @0];
}

static NSString *FLCapitalized(NSString *text) {
  return text.length == 0 ? text
                          : [[text substringToIndex:1].uppercaseString
                              stringByAppendingString:[text substringFromIndex:1]];
}

static NSString *FLSizeOfItem(NSDictionary *item) {
  return item[@"bytes"] == nil ? @"" : FLFormatBytes([item[@"bytes"] unsignedLongLongValue]);
}

static NSString *FLNamesOf(FLDependencyIndex *index, NSArray<NSDictionary *> *nodes,
                           NSUInteger most) {
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  for (NSDictionary *node in nodes) {
    [names addObject:[index nameOfNode:node]];
  }
  [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
  if (names.count <= most) {
    return [names componentsJoinedByString:@", "];
  }
  NSArray *first = [names subarrayWithRange:NSMakeRange(0, most)];
  return [NSString stringWithFormat:@"%@ and %lu more", [first componentsJoinedByString:@", "],
                                    (unsigned long)(names.count - most)];
}

static NSString *FLNamesAt(FLDependencyIndex *index, NSArray<NSString *> *paths) {
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  for (NSString *path in paths) {
    NSDictionary *node = [index nodeAtPath:path];
    [names addObject:node == nil ? path.lastPathComponent : [index nameOfNode:node]];
  }
  return [names componentsJoinedByString:@", "];
}

static void FLAppendNeeds(NSMutableString *text, FLDependencyIndex *index) {
  NSArray<NSDictionary *> *nodes = FLList(index.dependencies[@"nodes"]);
  NSCountedSet<NSString *> *counts = [NSCountedSet new];
  for (NSDictionary *node in nodes) {
    if (node[@"need"] != nil) {
      [counts addObject:node[@"need"]];
    }
  }
  if (counts.count == 0) {
    [text appendString:@"\nNothing has been counted as running yet, so the libraries are not "
                       @"sorted by whether anything that has run needs them.\n"];
    return;
  }
  NSDate *began = index.dependencies[@"began"];
  [text appendFormat:@"\nHow the libraries and plug-ins are needed, going by what has run since "
                     @"%@\nneeded\tfound\n",
                     [began isKindOfClass:[NSDate class]] ? FLFormatDay(began) : @"the start"];
  for (NSString *need in FLNeedOrder()) {
    [text appendFormat:@"%@\t%lu\n", FLCapitalized(FLNeedText(need)),
                       (unsigned long)[counts countForObject:need]];
  }
  NSArray<NSString *> *spare = @[ @"idle", @"plugin", @"unseen", @"orphan" ];
  NSMutableArray<NSDictionary *> *chosen = [NSMutableArray new];
  for (NSDictionary *node in nodes) {
    if ([spare containsObject:node[@"need"] ?: @""]) {
      [chosen addObject:node];
    }
  }
  [chosen sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSUInteger rank = [spare indexOfObject:first[@"need"]];
    NSUInteger other = [spare indexOfObject:second[@"need"]];
    if (rank != other) {
      return rank < other ? NSOrderedAscending : NSOrderedDescending;
    }
    NSNumber *size = [index itemOfNode:first][@"bytes"] ?: @0;
    NSNumber *otherSize = [index itemOfNode:second][@"bytes"] ?: @0;
    NSComparisonResult sizes = [otherSize compare:size];
    return sizes != NSOrderedSame ? sizes : [first[@"path"] compare:second[@"path"]];
  }];
  [text appendFormat:@"\nLibraries and plug-ins that nothing which has run needs: %lu\n"
                     @"name\tneeded\tsize\tlinked by\topened by\tpath\n",
                     (unsigned long)chosen.count];
  for (NSDictionary *node in chosen) {
    NSDictionary *item = [index itemOfNode:node];
    [text appendFormat:@"%@\t%@%@\t%@\t%lu\t%lu\t%@\n", [index nameOfNode:node],
                       FLNeedText(node[@"need"]),
                       [node[@"shadowed"] boolValue]
                         ? @"; the shared cache's copy is loaded instead"
                         : @"",
                       [node[@"cached"] boolValue] && item[@"bytes"] == nil
                         ? @"in the shared cache"
                         : FLSizeOfItem(item),
                       (unsigned long)[index usersOfNode:node].count,
                       (unsigned long)[index openersOfNode:node].count,
                       FLEscape(item[@"path"] ?: node[@"path"])];
  }
}

static void FLAppendMissing(NSMutableString *text, FLDependencyIndex *index) {
  NSMutableArray<NSDictionary *> *broken = [NSMutableArray new];
  for (NSDictionary *node in FLList(index.dependencies[@"nodes"])) {
    if ([node[@"missing"] count] > 0) {
      [broken addObject:node];
    }
  }
  [text appendFormat:@"\nPrograms and libraries that cannot load here, because one they link is "
                     @"missing: %lu\npath\tmissing\n",
                     (unsigned long)broken.count];
  for (NSDictionary *node in broken) {
    [text appendFormat:@"%@\t%@\n", FLEscape(node[@"path"]),
                       [node[@"missing"] componentsJoinedByString:@", "]];
  }
}

static void FLAppendServices(NSMutableString *text, FLDependencyIndex *index) {
  NSArray<NSArray<NSString *> *> *kinds = @[
    @[ @"service", @"Launch services" ], @[ @"xpc", @"XPC services" ],
    @[ @"app", @"Apps that offer Mach services" ]
  ];
  for (NSArray<NSString *> *kind in kinds) {
    NSMutableArray<NSDictionary *> *chosen = [NSMutableArray new];
    for (NSDictionary *item in FLList(index.inventory[@"items"])) {
      if ([item[@"kind"] isEqualToString:kind[0]] && [index namesOfferedBy:item].count > 0) {
        [chosen addObject:item];
      }
    }
    [chosen sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
      NSString *name = first[@"id"] ?: first[@"name"] ?: @"";
      NSString *other = second[@"id"] ?: second[@"name"] ?: @"";
      return [name caseInsensitiveCompare:other];
    }];
    [text appendFormat:@"\n%@ and the programs and libraries that name them: %lu\n"
                       @"name\tnames offered\tnamed by\twho\n",
                       kind[1], (unsigned long)chosen.count];
    for (NSDictionary *item in chosen) {
      NSArray<NSDictionary *> *clients = [index clientsOfItem:item];
      [text appendFormat:@"%@\t%lu\t%lu\t%@\n", item[@"id"] ?: item[@"name"],
                         (unsigned long)[index namesOfferedBy:item].count,
                         (unsigned long)clients.count, FLNamesOf(index, clients, FLNamesShown)];
    }
  }
}

NSString *FLDependenciesText(NSDictionary *dependencies, NSDictionary *inventory) {
  FLDependencyIndex *index = [[FLDependencyIndex alloc] initWithDependencies:dependencies
                                                                   inventory:inventory];
  NSMutableString *text = [NSMutableString new];
  NSDate *gathered = dependencies[@"gathered"];
  [text appendFormat:@"%@, on %@.\n", FLDependenciesSummary(dependencies),
                     [gathered isKindOfClass:[NSDate class]] ? FLFormatDay(gathered) : @""];
  [text appendString:@"A program links the libraries it cannot start without. While it runs it "
                     @"may also open a library or a plug-in by name, and it reaches a service by "
                     @"the name the service offers. Those names are found here by looking for "
                     @"them, whole, among the program's own strings, so a name the program puts "
                     @"together while it runs is not seen, and a name that is there may never be "
                     @"used.\n"];
  NSUInteger unread = [dependencies[@"counted"][@"unread"] unsignedIntegerValue];
  if (unread > 0) {
    [text appendFormat:@"%lu files could not be read as programs and are left out.\n",
                       (unsigned long)unread];
  }
  FLAppendNeeds(text, index);
  FLAppendMissing(text, index);
  FLAppendServices(text, index);
  NSArray<NSDictionary *> *nodes = FLList(dependencies[@"nodes"]);
  [text appendFormat:@"\nEvery program, library and plug-in: %lu\n"
                     @"path\tkind\tneeded\tlinks\topens by name\tnames the services\tlinked by\t"
                     @"opened by\n",
                     (unsigned long)nodes.count];
  for (NSDictionary *node in nodes) {
    NSString *kind = [node[@"cached"] boolValue]
      ? [node[@"type"] stringByAppendingString:@", in the shared cache"]
      : node[@"type"];
    [text appendFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%lu\t%lu\n", FLEscape(node[@"path"]), kind,
                       FLNeedText(node[@"need"]), FLNamesAt(index, FLList(node[@"links"])),
                       FLNamesAt(index, FLList(node[@"opens"])),
                       [FLList(node[@"talks"]) componentsJoinedByString:@", "],
                       (unsigned long)[index usersOfNode:node].count,
                       (unsigned long)[index openersOfNode:node].count];
  }
  return text;
}

static NSString *FLRunsOf(NSDictionary *node, NSDictionary *usage) {
  NSDictionary *entries = usage[@"entries"];
  if (![node[@"type"] isEqualToString:@"program"] ||
      ![entries isKindOfClass:[NSDictionary class]]) {
    return nil;
  }
  NSDate *began = usage[@"began"];
  NSString *since = [began isKindOfClass:[NSDate class]] ? FLFormatDay(began) : @"the start";
  NSDictionary *entry = entries[[@"program:" stringByAppendingString:node[@"path"] ?: @""]];
  if (entry == nil) {
    return [NSString stringWithFormat:@"never, counted since %@", since];
  }
  NSDate *last = entry[@"last"];
  NSUInteger runs = [entry[@"runs"] unsignedIntegerValue];
  return [NSString stringWithFormat:@"%lu %@ since %@, last seen %@", (unsigned long)runs,
                                    runs == 1 ? @"run" : @"runs", since,
                                    [last isKindOfClass:[NSDate class]] ? FLFormatDay(last) : @""];
}

NSString *FLDependsText(NSDictionary *dependencies, NSDictionary *inventory, NSString *name,
                        NSDictionary *usage) {
  FLDependencyIndex *index = [[FLDependencyIndex alloc] initWithDependencies:dependencies
                                                                   inventory:inventory];
  index.loaded = FLReadState(FLLoadedState);
  index.traced = FLReadState(FLTracedState);
  NSArray<NSDictionary *> *found = [index itemsNamed:name];
  NSMutableString *text = [NSMutableString new];
  if (found.count == 0) {
    return nil;
  }
  if (found.count > 1) {
    [text appendFormat:@"%lu things are called %@. Say which by its path:\n",
                       (unsigned long)found.count, name];
    for (NSDictionary *item in found) {
      [text appendFormat:@"%@\t%@\n", item[@"kind"], item[@"path"]];
    }
    return text;
  }
  NSDictionary *item = found.firstObject;
  NSDictionary *node = [index nodeOfItem:item];
  [text appendFormat:@"%@\nKind: %@\nPath: %@\n", item[@"name"] ?: name, item[@"kind"],
                     item[@"path"]];
  if (node != nil && ![node[@"path"] isEqualToString:item[@"path"]]) {
    [text appendFormat:@"Program or library: %@%@\n", node[@"path"],
                       [node[@"cached"] boolValue] ? @" (in the shared cache)" : @""];
  }
  NSString *runs = node == nil ? nil : FLRunsOf(node, usage);
  if (runs != nil) {
    [text appendFormat:@"Seen running: %@\n", runs];
  }
  if (node[@"need"] != nil) {
    [text appendFormat:@"Needed: %@\n", FLNeedText(node[@"need"])];
  }
  if ([node[@"shadowed"] boolValue]) {
    [text appendString:@"A library of the same name in the shared cache is loaded instead of "
                       @"this file.\n"];
  }
  if (node == nil && [index clientsOfItem:item].count == 0) {
    [text appendString:@"Nothing is known about what this depends on: it has no program or "
                       @"library of its own that could be read.\n"];
  }
  for (NSDictionary *section in [index relationsOfItem:item]) {
    NSArray<NSDictionary *> *rows = section[@"rows"];
    [text appendFormat:@"\n%@: %lu\n", section[@"title"], (unsigned long)rows.count];
    for (NSDictionary *row in rows) {
      [text appendFormat:@"%@\t%@\n", row[@"title"], row[@"detail"] ?: @""];
    }
  }
  NSArray<NSArray<NSString *> *> *granted = [index entitlementsOfItem:item];
  if (granted.count > 0) {
    [text appendFormat:@"\nEntitlements: %lu\n", (unsigned long)granted.count];
    for (NSArray<NSString *> *pair in granted) {
      [text appendFormat:@"%@ = %@\n", pair[0], pair[1]];
    }
  }
  return text;
}
