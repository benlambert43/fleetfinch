#import "FLUsage.h"

#import <fcntl.h>
#import <limits.h>
#import <mach/mach_time.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FLCollect.h"
#import "FLCommon.h"
#import "FLInventory.h"
#import "FLStatus.h"

static const NSTimeInterval FLUsageSaveEvery = 300;
static const NSUInteger FLUsageCommandLength = 300;
static const NSUInteger FLUsageNamesKept = 8;
static const NSUInteger FLUsageNameLimit = 16;
static const size_t FLUsageScriptLine = 255;
static const NSTimeInterval FLUsageInventoryFor = 600;
static NSString *const FLUsageOthers = @"others";
static NSString *const FLUsageUnnamed = @"(too short to name)";
static NSString *const FLCleanEnding = @"exit code 0";

static FLUsageLedger *FLLedger;

static double FLAwakeSeconds(void) {
  static mach_timebase_info_data_t base;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_timebase_info(&base);
  });
  return (double)mach_absolute_time() * base.numer / base.denom / NSEC_PER_SEC;
}

NSString *FLServiceFamily(NSString *label) {
  static NSArray<NSArray *> *rules;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *unique = @"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                       @"[0-9a-fA-F]{12}";
    NSMutableArray *made = [NSMutableArray new];
    for (NSArray<NSString *> *rule in @[
           @[ @"\\[0x[0-9a-fA-F]+\\]", @"" ], @[ unique, @"*" ], @[ @"0x[0-9a-fA-F]+", @"*" ]
         ]) {
      NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:rule[0]
                                                                               options:0
                                                                                 error:NULL];
      if (pattern != nil) {
        [made addObject:@[ pattern, rule[1] ]];
      }
    }
    rules = made;
  });
  NSString *family = label ?: @"";
  for (NSArray *rule in rules) {
    family = [rule[0] stringByReplacingMatchesInString:family
                                               options:0
                                                 range:NSMakeRange(0, family.length)
                                          withTemplate:rule[1]];
  }
  return family;
}

NSString *FLBundledServiceIdentifier(NSString *path) {
  NSRange bundle = [path ?: @"" rangeOfString:@".xpc/"];
  if (bundle.location == NSNotFound) {
    return nil;
  }
  NSString *identifier = FLBundleInfo([path substringToIndex:bundle.location + 4])[@"identifier"];
  return identifier.length > 0 ? identifier : nil;
}

NSString *FLBundledServiceLabel(NSString *path) {
  return [FLBundledServiceIdentifier(path) stringByAppendingString:@" (XPC service)"];
}

static NSString *FLScriptInterpreter(NSString *path) {
  struct stat info;
  if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) {
    return nil;
  }
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return nil;
  }
  char line[FLUsageScriptLine + 1] = {0};
  ssize_t count = read(handle, line, FLUsageScriptLine);
  close(handle);
  if (count < 3 || line[0] != '#' || line[1] != '!') {
    return nil;
  }
  char *start = line + 2;
  while (*start == ' ' || *start == '\t') {
    start++;
  }
  char *end = start;
  while (*end != '\0' && *end != ' ' && *end != '\t' && *end != '\n' && *end != '\r') {
    end++;
  }
  *end = '\0';
  char resolved[PATH_MAX];
  if (*start == '\0' || realpath(start, resolved) == NULL) {
    return nil;
  }
  return @(resolved);
}

NSString *FLScriptOf(FLProcess *process) {
  NSString *script = process.arguments.count > 1 ? process.arguments[1] : @"";
  if (![script hasPrefix:@"/"] || process.path.length == 0 ||
      [script isEqualToString:process.path]) {
    return nil;
  }
  return [FLScriptInterpreter(script) isEqualToString:process.path] ? script : nil;
}

static void FLTally(NSMutableDictionary *entry, NSString *field, NSString *name) {
  if (name.length == 0) {
    return;
  }
  NSMutableDictionary *counts = entry[field];
  if (counts == nil) {
    counts = [NSMutableDictionary new];
    entry[field] = counts;
  }
  NSString *slot = counts[name] != nil || counts.count < FLUsageNamesKept ? name : FLUsageOthers;
  counts[slot] = @([counts[slot] unsignedLongLongValue] + 1);
}

static NSMutableDictionary *FLMutableCounts(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? [value mutableCopy] : nil;
}

@implementation FLUsageLedger {
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_entries;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_active;
  NSDate *_began;
  NSDate *_saved;
  NSString *_boot;
  NSUInteger _boots;
  double _watched;
  double _awake;
  BOOL _changed;
  BOOL _drifted;
}

- (instancetype)initForBoot:(NSString *)boot {
  self = [super init];
  if (self) {
    NSDictionary *saved = FLReadState(FLUsageState);
    _entries = [NSMutableDictionary new];
    _active = [NSMutableDictionary new];
    NSDictionary *entries = saved[@"entries"];
    if ([entries isKindOfClass:[NSDictionary class]]) {
      for (NSString *key in entries) {
        NSDictionary *entry = entries[key];
        if (![entry isKindOfClass:[NSDictionary class]]) {
          continue;
        }
        NSMutableDictionary *copy = [entry mutableCopy];
        for (NSString *field in @[ @"starters", @"endings", @"reports" ]) {
          NSMutableDictionary *counts = FLMutableCounts(copy[field]);
          if (counts != nil) {
            copy[field] = counts;
          } else {
            [copy removeObjectForKey:field];
          }
        }
        _entries[key] = copy;
      }
    }
    BOOL sameBoot = boot.length > 0 && [saved[@"boot"] isEqual:boot];
    NSDictionary *active = saved[@"active"];
    if (sameBoot && [active isKindOfClass:[NSDictionary class]]) {
      for (NSString *identity in active) {
        NSDictionary *state = active[identity];
        if ([state isKindOfClass:[NSDictionary class]] &&
            [state[@"keys"] isKindOfClass:[NSArray class]] &&
            [state[@"started"] isKindOfClass:[NSDate class]]) {
          _active[identity] = [state mutableCopy];
        }
      }
    }
    _began = [saved[@"began"] isKindOfClass:[NSDate class]] ? saved[@"began"] : [NSDate date];
    _boots = [saved[@"boots"] unsignedIntegerValue] + (sameBoot ? 0 : 1);
    _watched = [saved[@"watched"] doubleValue];
    _awake = FLAwakeSeconds();
    _boot = [boot copy] ?: @"";
    _saved = [NSDate date];
    _changed = !sameBoot;
  }
  return self;
}

- (NSMutableDictionary *)entry:(NSString *)key name:(NSString *)name path:(NSString *)path {
  NSMutableDictionary *entry = _entries[key];
  if (entry == nil) {
    entry = [NSMutableDictionary new];
    _entries[key] = entry;
  }
  if (name.length > 0) {
    entry[@"name"] = name;
  }
  if (path.length > 0) {
    entry[@"path"] = path;
  }
  return entry;
}

- (void)account:(NSMutableDictionary *)state
      processor:(double)processor
         memory:(uint64_t)memory
             at:(NSDate *)now {
  double lived = MAX(0, [now timeIntervalSinceDate:state[@"started"]]);
  double longer = MAX(0, lived - [state[@"seconds"] doubleValue]);
  double work = MAX(0, processor - [state[@"processor"] doubleValue]);
  for (NSString *key in state[@"keys"]) {
    NSMutableDictionary *entry = _entries[key];
    if (entry == nil) {
      continue;
    }
    entry[@"seconds"] = @([entry[@"seconds"] doubleValue] + longer);
    entry[@"processor"] = @([entry[@"processor"] doubleValue] + work);
    if (memory > [entry[@"memory"] unsignedLongLongValue]) {
      entry[@"memory"] = @(memory);
    }
    NSDate *last = entry[@"last"];
    if (last == nil || [now compare:last] == NSOrderedDescending) {
      entry[@"last"] = now;
    }
  }
  state[@"seconds"] = @(lived);
  state[@"processor"] = @(MAX(processor, [state[@"processor"] doubleValue]));
}

- (NSString *)programNamed:(NSString *)name {
  NSString *found = nil;
  for (NSString *key in _entries) {
    if (![key hasPrefix:@"program:/"]) {
      continue;
    }
    NSString *last = key.lastPathComponent;
    BOOL same = name.length >= FLUsageNameLimit ? [last hasPrefix:name]
                                                : [last isEqualToString:name];
    if (!same) {
      continue;
    }
    if (found != nil) {
      return name;
    }
    found = [key substringFromIndex:@"program:".length];
  }
  return found ?: name;
}

- (NSArray<NSString *> *)keysFor:(FLProcess *)process label:(NSString *)label {
  NSString *program = process.path;
  if (program.length == 0 && process.name.length > 0) {
    program = [self programNamed:process.name];
  }
  if (program.length == 0) {
    return @[];
  }
  NSMutableArray<NSString *> *keys = [NSMutableArray new];
  NSMutableArray<NSMutableDictionary *> *tools = [NSMutableArray new];
  NSString *key = [@"program:" stringByAppendingString:program];
  [tools addObject:[self entry:key name:program.lastPathComponent path:program]];
  [keys addObject:key];
  NSString *script = FLScriptOf(process);
  if (script.length > 0) {
    key = [@"program:" stringByAppendingString:script];
    [tools addObject:[self entry:key name:script.lastPathComponent path:script]];
    [keys addObject:key];
  }
  NSString *family = label.length > 0 ? FLServiceFamily(label) : @"";
  if (family.length > 0 && ![family hasPrefix:@"UIKitApplication:"]) {
    key = [@"service:" stringByAppendingString:family];
    [self entry:key name:family path:program];
    [keys addObject:key];
  }
  NSString *bundle = [process appBundlePath];
  NSDictionary *app = bundle == nil ? nil : FLBundleInfo(bundle);
  NSString *identifier = app[@"identifier"];
  if (identifier.length > 0) {
    key = [@"app:" stringByAppendingString:identifier];
    [self entry:key name:app[@"name"] path:bundle];
    [keys addObject:key];
  }
  if (keys.count > tools.count) {
    for (NSMutableDictionary *tool in tools) {
      tool[@"covered"] = @([tool[@"covered"] unsignedLongLongValue] + 1);
    }
  }
  return keys;
}

- (void)count:(NSArray<NSString *> *)keys
      process:(FLProcess *)process
      starter:(NSString *)starter
         from:(NSDate *)from {
  NSString *command = [process commandLine];
  if (command.length > FLUsageCommandLength) {
    command = [command substringToIndex:FLUsageCommandLength];
  }
  for (NSString *key in keys) {
    NSMutableDictionary *entry = _entries[key];
    entry[@"runs"] = @([entry[@"runs"] unsignedLongLongValue] + 1);
    NSDate *first = entry[@"first"];
    if (first == nil || [from compare:first] == NSOrderedAscending) {
      entry[@"first"] = from;
    }
    entry[@"command"] = command;
    entry[@"user"] = FLUserName(process.user);
    FLTally(entry, @"starters", starter);
  }
}

- (void)began:(FLProcess *)process
        label:(NSString *)label
      starter:(NSString *)starter
         from:(NSDate *)from
           at:(NSDate *)now {
  NSString *identity = [process identity];
  if (_active[identity] != nil) {
    return;
  }
  NSArray<NSString *> *keys = [self keysFor:process label:label];
  if (keys.count == 0) {
    return;
  }
  NSDate *since = from ?: process.started ?: now;
  [self count:keys process:process starter:starter from:since];
  NSMutableDictionary *state = [NSMutableDictionary new];
  state[@"keys"] = keys;
  state[@"started"] = since;
  state[@"seconds"] = @0;
  state[@"processor"] = @0;
  _active[identity] = state;
  [self account:state
      processor:process.detailed ? process.processorSeconds : 0
         memory:process.footprintBytes ?: process.residentBytes
             at:now];
  _changed = YES;
  if (self.started != nil) {
    self.started(process);
  }
}

- (void)began:(FLProcess *)process label:(NSString *)label starter:(NSString *)starter {
  [self began:process label:label starter:starter from:nil at:[NSDate date]];
}

- (void)passed:(FLProcess *)process
       starter:(NSString *)starter
          from:(NSDate *)from
            to:(NSDate *)to {
  NSArray<NSString *> *keys = [self keysFor:process label:nil];
  if (keys.count == 0) {
    return;
  }
  [self count:keys process:process starter:starter from:from];
  NSMutableDictionary *state = [NSMutableDictionary new];
  state[@"keys"] = keys;
  state[@"started"] = from;
  state[@"seconds"] = @0;
  state[@"processor"] = @0;
  [self account:state processor:0 memory:0 at:to];
  _changed = YES;
}

- (void)missed:(NSString *)starter at:(NSDate *)when {
  NSString *key = [@"program:" stringByAppendingString:FLUsageUnnamed];
  NSMutableDictionary *entry = [self entry:key name:FLUsageUnnamed path:nil];
  entry[@"runs"] = @([entry[@"runs"] unsignedLongLongValue] + 1);
  if (entry[@"first"] == nil) {
    entry[@"first"] = when;
  }
  entry[@"last"] = when;
  FLTally(entry, @"starters", starter);
  _changed = YES;
}

- (void)seen:(FLProcess *)process {
  NSMutableDictionary *state = _active[[process identity]];
  if (state == nil) {
    return;
  }
  [self account:state
      processor:process.processorSeconds
         memory:process.footprintBytes ?: process.residentBytes
             at:[NSDate date]];
  _drifted = YES;
}

- (void)ended:(FLProcess *)process
    processor:(NSNumber *)processor
       memory:(NSNumber *)memory
           at:(NSDate *)when {
  NSString *identity = [process identity];
  NSMutableDictionary *state = _active[identity];
  if (state == nil) {
    return;
  }
  [self account:state
      processor:processor.doubleValue
         memory:memory.unsignedLongLongValue
             at:when ?: [NSDate date]];
  [_active removeObjectForKey:identity];
  _changed = YES;
}

- (void)ended:(FLProcess *)process processor:(NSNumber *)processor memory:(NSNumber *)memory {
  [self ended:process processor:processor memory:memory at:nil];
}

- (void)rebase:(FLProcess *)process processor:(double)processor {
  _active[[process identity]][@"processor"] = @(processor);
}

- (void)keepOnly:(NSSet<NSString *> *)identities {
  for (NSString *identity in _active.allKeys) {
    if (![identities containsObject:identity]) {
      [_active removeObjectForKey:identity];
      _changed = YES;
    }
  }
}

- (void)service:(NSString *)label endedWith:(NSString *)ending {
  NSString *key = [@"service:" stringByAppendingString:FLServiceFamily(label)];
  NSMutableDictionary *entry = _entries[key];
  if (entry != nil) {
    FLTally(entry, @"endings", ending);
    if (![ending isEqualToString:FLCleanEnding]) {
      entry[@"bad"] = @([entry[@"bad"] unsignedLongLongValue] + 1);
    }
    _changed = YES;
  }
}

- (NSArray<NSString *> *)keysOfProgram:(NSString *)program {
  NSMutableArray<NSString *> *keys =
    [NSMutableArray arrayWithObject:[@"program:" stringByAppendingString:program]];
  for (NSString *key in _entries) {
    NSString *path = _entries[key][@"path"];
    if (path.length == 0) {
      continue;
    }
    if (([key hasPrefix:@"service:"] && [path isEqualToString:program]) ||
        ([key hasPrefix:@"app:"] && [program hasPrefix:[path stringByAppendingString:@"/"]])) {
      [keys addObject:key];
    }
  }
  return keys;
}

- (NSArray<NSString *> *)keysOfSender:(NSString *)sender pid:(int)pid {
  NSString *prefix = [NSString stringWithFormat:@"%d:", pid];
  for (NSString *identity in pid > 0 ? _active.allKeys : @[]) {
    if ([identity hasPrefix:prefix]) {
      return _active[identity][@"keys"];
    }
  }
  if (sender.length == 0) {
    return @[];
  }
  NSString *program = [self programNamed:sender];
  if ([program hasPrefix:@"/"]) {
    return [self keysOfProgram:program];
  }
  NSString *key = [@"sender:" stringByAppendingString:sender];
  [self entry:key name:sender path:nil];
  return @[ key ];
}

- (void)logged:(FLLevel)level by:(NSString *)sender pid:(int)pid {
  NSString *field = level >= FLLevelFault ? @"faults" : @"errors";
  for (NSString *key in [self keysOfSender:sender pid:pid]) {
    NSMutableDictionary *entry = _entries[key];
    entry[field] = @([entry[field] unsignedLongLongValue] + 1);
    entry[@"troubled"] = [NSDate date];
  }
  _drifted = YES;
}

- (void)reported:(NSString *)name kind:(NSString *)kind path:(NSString *)path {
  if (name.length == 0 || kind.length == 0) {
    return;
  }
  NSString *family = [@"service:" stringByAppendingString:FLServiceFamily(name)];
  NSArray<NSString *> *keys = nil;
  if (path.length > 0) {
    keys = [self keysOfProgram:path];
  } else if (_entries[family] != nil || [name containsString:@"."]) {
    keys = @[ family ];
  } else {
    keys = [self keysOfSender:name pid:0];
  }
  for (NSString *key in keys) {
    NSMutableDictionary *entry = _entries[key];
    if (entry == nil) {
      entry = [self entry:key name:name.lastPathComponent path:path.length > 0 ? path : nil];
    }
    FLTally(entry, @"reports", kind);
    entry[@"reported"] = @([entry[@"reported"] unsignedLongLongValue] + 1);
    entry[@"troubled"] = [NSDate date];
  }
  _changed = YES;
}

- (NSDictionary *)contents {
  double awake = FLAwakeSeconds();
  if (awake > _awake) {
    _watched += awake - _awake;
  }
  _awake = awake;
  return @{
    @"version" : @1,
    @"began" : _began,
    @"boot" : _boot,
    @"boots" : @(_boots),
    @"watched" : @(_watched),
    @"saved" : [NSDate date],
    @"entries" : _entries,
    @"active" : _active,
  };
}

- (BOOL)save {
  if (!FLWriteCompactState(FLUsageState, [self contents])) {
    return NO;
  }
  _saved = [NSDate date];
  _changed = NO;
  _drifted = NO;
  return YES;
}

- (BOOL)saveIfDue {
  if ((!_changed && !_drifted) || -_saved.timeIntervalSinceNow < FLUsageSaveEvery) {
    return NO;
  }
  return [self save];
}

@end

void FLSetUsageLedger(FLUsageLedger *ledger) {
  FLLedger = ledger;
}

NSDictionary *FLCurrentUsage(void) {
  return FLLedger != nil ? [FLLedger contents] : FLReadState(FLUsageState);
}

static NSString *FLDescribeCounts(NSDictionary<NSString *, NSNumber *> *counts) {
  if (![counts isKindOfClass:[NSDictionary class]] || counts.count == 0) {
    return @"";
  }
  NSArray<NSString *> *names =
    [counts.allKeys sortedArrayUsingComparator:^(NSString *first, NSString *second) {
      NSComparisonResult order = [counts[second] compare:counts[first]];
      return order != NSOrderedSame ? order : [first compare:second];
    }];
  NSMutableArray *parts = [NSMutableArray new];
  for (NSString *name in names) {
    [parts addObject:[NSString stringWithFormat:@"%@ ×%@", name, counts[name]]];
  }
  return [parts componentsJoinedByString:@", "];
}

NSString *FLUsageTrouble(NSDictionary *entry) {
  NSMutableArray<NSString *> *parts = [NSMutableArray new];
  NSArray<NSArray<NSString *> *> *counted = @[
    @[ @"reported", @"report", @"reports" ], @[ @"bad", @"bad ending", @"bad endings" ],
    @[ @"faults", @"fault", @"faults" ], @[ @"errors", @"error", @"errors" ]
  ];
  for (NSArray<NSString *> *each in counted) {
    unsigned long long count = [entry[each[0]] unsignedLongLongValue];
    if (count > 0) {
      [parts addObject:[NSString stringWithFormat:@"%llu %@", count, each[count == 1 ? 1 : 2]]];
    }
  }
  return [parts componentsJoinedByString:@", "];
}

static NSDictionary *FLUsageRow(NSString *kind, NSString *key, NSString *name,
                                NSDictionary *details, NSDictionary *entry,
                                NSUInteger running) {
  NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
  row[@"kind"] = kind;
  row[@"key"] = key;
  row[@"name"] = name.length > 0 ? name : key;
  row[@"ran"] = @(entry != nil);
  row[@"running"] = @(running);
  if (entry == nil) {
    return row;
  }
  for (NSString *field in @[
         @"runs", @"first", @"last", @"seconds", @"processor", @"memory", @"command", @"user"
       ]) {
    if (entry[field] != nil) {
      row[field] = entry[field];
    }
  }
  row[@"starters"] = FLDescribeCounts(entry[@"starters"]);
  row[@"endings"] = FLDescribeCounts(entry[@"endings"]);
  row[@"reports"] = FLDescribeCounts(entry[@"reports"]);
  for (NSString *field in @[ @"errors", @"faults", @"bad", @"reported" ]) {
    if ([entry[field] unsignedLongLongValue] > 0) {
      row[field] = entry[field];
    }
  }
  row[@"trouble"] = FLUsageTrouble(entry);
  if ([row[@"where"] length] == 0 && [entry[@"path"] length] > 0) {
    row[@"where"] = entry[@"path"];
  }
  return row;
}

static NSDictionary *FLUsageInventory(void) {
  static NSDictionary *kept;
  static NSDate *built;
  static NSDate *listed;
  NSDate *written = FLStateWritten(FLInstalledState);
  BOOL same = written == listed || [written isEqual:listed];
  if (kept != nil && same && -built.timeIntervalSinceNow < FLUsageInventoryFor) {
    return kept;
  }
  NSDictionary *installed = written == nil ? @{} : FLReadState(FLInstalledState);
  NSMutableDictionary *found = [NSMutableDictionary new];
  for (NSString *key in @[ @"apps", @"bundles", @"tools" ]) {
    found[key] = [installed[key] isKindOfClass:[NSArray class]] ? installed[key] : @[];
  }
  found[@"origins"] =
    [installed[@"origins"] isKindOfClass:[NSDictionary class]] ? installed[@"origins"] : @{};
  found[@"listed"] = @(installed.count > 0);
  found[@"definitions"] = FLLaunchServices() ?: @[];
  kept = found;
  built = [NSDate date];
  listed = written;
  return kept;
}

NSDictionary *FLUsageReport(NSDictionary *usage) {
  NSDictionary<NSString *, NSDictionary *> *entries =
    [usage[@"entries"] isKindOfClass:[NSDictionary class]] ? usage[@"entries"] : @{};
  NSDictionary<NSString *, NSDictionary *> *active =
    [usage[@"active"] isKindOfClass:[NSDictionary class]] ? usage[@"active"] : @{};
  NSCountedSet *running = [NSCountedSet new];
  for (NSDictionary *state in active.allValues) {
    for (NSString *key in state[@"keys"]) {
      [running addObject:key];
    }
  }
  NSDictionary *inventory = FLUsageInventory();
  NSDictionary<NSString *, NSString *> *owners = inventory[@"origins"];
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
  NSMutableSet<NSString *> *listed = [NSMutableSet new];
  NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary new];
  for (NSDictionary *tool in inventory[@"tools"]) {
    sizes[tool[@"path"]] = tool[@"bytes"];
  }
  NSMutableSet<NSString *> *bundled = [NSMutableSet new];
  for (NSDictionary *bundle in inventory[@"bundles"]) {
    if (bundle[@"program"] != nil) {
      [bundled addObject:bundle[@"program"]];
    }
  }
  NSMutableDictionary<NSString *, NSString *> *labelled = [NSMutableDictionary new];
  for (NSString *key in entries) {
    NSString *path = entries[key][@"path"];
    if ([key hasPrefix:@"service:"] && path != nil && [bundled containsObject:path]) {
      labelled[path] = key;
    }
  }

  for (NSDictionary *app in inventory[@"apps"]) {
    NSString *path = app[@"path"] ?: @"";
    NSString *identifier = app[@"identifier"] ?: path;
    NSString *key = [@"app:" stringByAppendingString:identifier];
    if ([listed containsObject:key]) {
      continue;
    }
    [listed addObject:key];
    NSString *note = [app[@"hidden"] boolValue]
      ? [NSString stringWithFormat:@"%@, hidden", app[@"kind"]]
      : app[@"kind"];
    NSDictionary *details = @{
      @"where" : path,
      @"origin" : app[@"origin"] ?: @"",
      @"note" : note ?: @"",
      @"bytes" : app[@"bytes"] ?: @0,
    };
    [rows addObject:FLUsageRow(@"app", identifier, app[@"name"], details, entries[key],
                               [running countForObject:key])];
  }

  NSMutableSet<NSString *> *servicePrograms = [NSMutableSet new];
  for (NSDictionary *service in FLServiceTable(FLLaunchJobs(), inventory[@"definitions"])) {
    NSString *program = service[@"program"] ?: @"";
    NSString *file = service[@"file"] ?: @"";
    if (program.length > 0 && file.length > 0) {
      [servicePrograms addObject:program];
    }
    NSString *family = FLServiceFamily(service[@"label"]);
    NSString *key = [@"service:" stringByAppendingString:family];
    if (family.length == 0 || [family hasPrefix:@"UIKitApplication:"] ||
        [listed containsObject:key]) {
      continue;
    }
    if (file.length == 0 && entries[key] == nil && [family containsString:@"*"]) {
      continue;
    }
    if (file.length == 0 && [bundled containsObject:program]) {
      continue;
    }
    [listed addObject:key];
    NSDictionary *details = @{
      @"where" : program,
      @"file" : file,
      @"origin" : FLOriginOf(owners, @[ file, program ]),
      @"note" : FLServiceStarts(service) ?: @"",
      @"bytes" : sizes[program] ?: @0,
    };
    [rows addObject:FLUsageRow(@"service", family, family, details, entries[key],
                               [running countForObject:key])];
  }
  for (NSDictionary *bundle in inventory[@"bundles"]) {
    NSString *identifier = bundle[@"identifier"];
    NSString *program = bundle[@"program"] ?: @"";
    NSString *key = [@"service:" stringByAppendingString:identifier];
    if ([listed containsObject:key]) {
      continue;
    }
    NSString *used = key;
    NSString *other = labelled[program] ?: [@"program:" stringByAppendingString:program];
    if (entries[key] == nil && entries[other] != nil) {
      used = other;
    }
    [listed addObject:key];
    [listed addObject:used];
    NSDictionary *details = @{
      @"where" : bundle[@"path"],
      @"origin" : bundle[@"origin"] ?: @"",
      @"note" : bundle[@"note"] ?: @"",
      @"bytes" : bundle[@"bytes"] ?: @0,
    };
    [rows addObject:FLUsageRow(@"service", identifier, identifier, details, entries[used],
                               [running countForObject:used])];
  }

  for (NSDictionary *tool in inventory[@"tools"]) {
    NSString *path = tool[@"path"];
    NSString *key = [@"program:" stringByAppendingString:path];
    NSDictionary *entry = entries[key];
    [listed addObject:key];
    unsigned long long runs = [entry[@"runs"] unsignedLongLongValue];
    BOOL covered = runs > 0 && [entry[@"covered"] unsignedLongLongValue] >= runs;
    if (covered || (entry == nil && [servicePrograms containsObject:path])) {
      continue;
    }
    NSDictionary *details =
      @{@"where" : path, @"origin" : tool[@"origin"] ?: @"", @"bytes" : tool[@"bytes"] ?: @0};
    [rows addObject:FLUsageRow(@"program", path, path.lastPathComponent, details, entry,
                               [running countForObject:key])];
  }

  for (NSString *key in entries) {
    if ([listed containsObject:key]) {
      continue;
    }
    NSDictionary *entry = entries[key];
    NSRange colon = [key rangeOfString:@":"];
    if (colon.location == NSNotFound) {
      continue;
    }
    NSString *kind = [key substringToIndex:colon.location];
    NSString *name = [key substringFromIndex:NSMaxRange(colon)];
    NSString *path = entry[@"path"] ?: @"";
    NSString *note = @"";
    if ([kind isEqualToString:@"program"]) {
      unsigned long long runs = [entry[@"runs"] unsignedLongLongValue];
      if (runs > 0 && [entry[@"covered"] unsignedLongLongValue] >= runs) {
        continue;
      }
    } else if ([kind isEqualToString:@"app"]) {
      note = @"no longer installed";
    } else {
      note = @"not defined on disk";
    }
    NSDictionary *details =
      @{@"where" : path, @"origin" : FLOriginOf(owners, @[ path ]), @"note" : note};
    [rows addObject:FLUsageRow(kind, name, entry[@"name"], details, entry,
                               [running countForObject:key])];
  }

  NSMutableDictionary *summary = [NSMutableDictionary new];
  for (NSString *kind in @[ @"app", @"service", @"program" ]) {
    NSUInteger total = 0, never = 0, now = 0;
    for (NSDictionary *row in rows) {
      if (![row[@"kind"] isEqualToString:kind]) {
        continue;
      }
      total++;
      never += [row[@"ran"] boolValue] ? 0 : 1;
      now += [row[@"running"] unsignedIntegerValue] > 0 ? 1 : 0;
    }
    summary[kind] = @{@"total" : @(total), @"never" : @(never), @"running" : @(now)};
  }
  [rows sortUsingComparator:^(NSDictionary *first, NSDictionary *second) {
    return [first[@"name"] caseInsensitiveCompare:second[@"name"]];
  }];
  NSMutableDictionary *report = [NSMutableDictionary new];
  report[@"generated"] = [NSDate date];
  report[@"began"] = usage[@"began"] ?: [NSDate date];
  report[@"watched"] = usage[@"watched"] ?: @0;
  report[@"boots"] = usage[@"boots"] ?: @0;
  report[@"rows"] = rows;
  report[@"summary"] = summary;
  report[@"listed"] = inventory[@"listed"] ?: @NO;
  return report;
}

BOOL FLWriteUsageReport(NSDictionary *report) {
  return FLWriteCompactState(FLUsageReportState, report);
}

static NSString *FLUsageNumbers(NSDictionary *row) {
  NSUInteger running = [row[@"running"] unsignedIntegerValue];
  return [NSString
    stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%.1fs\t%@\t%@", row[@"runs"] ?: @0,
                     running > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)running]
                                 : @"no",
                     row[@"first"] == nil ? @"" : FLFormatDay(row[@"first"]),
                     row[@"last"] == nil ? @"" : FLFormatDay(row[@"last"]),
                     FLFormatDuration([row[@"seconds"] doubleValue]),
                     [row[@"processor"] doubleValue],
                     FLFormatBytes([row[@"memory"] unsignedLongLongValue]),
                     [NSString stringWithFormat:@"%@\t%@", row[@"starters"] ?: @"",
                                                row[@"trouble"] ?: @""]];
}

static NSString *const FLUsageHeadings =
  @"runs\trunning now\tfirst seen\tlast seen\trun time\tprocessor\tmost memory\tstarted by\t"
  @"trouble";

static NSString *FLUsageLine(NSDictionary *row, BOOL ran) {
  NSString *kind = row[@"kind"];
  NSString *origin = row[@"origin"] ?: @"";
  NSString *note = row[@"note"] ?: @"";
  NSString *where = FLEscape([row[@"where"] length] > 0 ? row[@"where"] : row[@"key"]);
  uint64_t bytes = [row[@"bytes"] unsignedLongLongValue];
  NSString *size = bytes > 0 ? FLFormatBytes(bytes) : @"";
  if ([kind isEqualToString:@"app"]) {
    return ran ? [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@", row[@"name"],
                                            row[@"key"], FLUsageNumbers(row), note, size, origin,
                                            where]
               : [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@", row[@"name"], row[@"key"],
                                            note, size, origin, where];
  }
  if ([kind isEqualToString:@"service"]) {
    return ran ? [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", row[@"key"],
                                            FLUsageNumbers(row), row[@"endings"] ?: @"", note,
                                            size, origin, where, row[@"file"] ?: @""]
               : [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@", row[@"key"], note, size,
                                            origin, where, row[@"file"] ?: @""];
  }
  return ran ? [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@", where, FLUsageNumbers(row),
                                          size, origin, FLEscape(row[@"command"] ?: @"")]
             : [NSString stringWithFormat:@"%@\t%@\t%@", where, size, origin];
}

NSString *FLUsageText(NSDictionary *report, BOOL neverOnly) {
  NSMutableString *text = [NSMutableString new];
  NSDate *began = [report[@"began"] isKindOfClass:[NSDate class]] ? report[@"began"]
                                                                 : [NSDate date];
  NSUInteger boots = [report[@"boots"] unsignedIntegerValue];
  [text appendFormat:@"Watching since %@ (%@), with the device awake for %@ of it, over %lu %@\n",
                     FLFormatDay(began), FLFormatDuration(-began.timeIntervalSinceNow),
                     FLFormatDuration([report[@"watched"] doubleValue]), (unsigned long)boots,
                     boots == 1 ? @"start" : @"starts"];
  [text appendString:@"Runs are counted as the kernel reports them. One that lasts only a few "
                     @"milliseconds while the processor is busy can end before it is named, "
                     @"and is counted as too short to name.\n"];
  if (![report[@"listed"] boolValue]) {
    [text appendString:@"What is installed has not been listed yet, so apps, extensions and "
                       @"programs that have never run are missing. The service lists it within "
                       @"a few minutes of starting, and finchlog inventory lists it now.\n"];
  }
  [text appendString:@"\n"];
  NSArray<NSArray<NSString *> *> *kinds = @[
    @[
      @"app", @"Apps", @"been opened",
      @"name\tidentifier\t{numbers}\tkind\tsize\tfrom\tpath",
      @"name\tidentifier\tkind\tsize\tfrom\tpath"
    ],
    @[
      @"service", @"Services", @"run",
      @"label\t{numbers}\tended with\tstarts\tsize\tfrom\tprogram\tdefined in",
      @"label\tstarts\tsize\tfrom\tprogram\tdefined in"
    ],
    @[
      @"program", @"Programs", @"run", @"path\t{numbers}\tsize\tfrom\tlast command",
      @"path\tsize\tfrom"
    ],
  ];
  NSDictionary *summary = report[@"summary"];
  for (NSArray<NSString *> *kind in kinds) {
    NSDictionary *counts = summary[kind[0]];
    [text appendFormat:@"%@: %@ found, %@ have never %@, %@ running now\n", kind[1],
                       counts[@"total"] ?: @0, counts[@"never"] ?: @0, kind[2],
                       counts[@"running"] ?: @0];
  }
  NSArray<NSDictionary *> *rows = report[@"rows"];
  for (NSArray<NSString *> *kind in kinds) {
    NSMutableArray<NSDictionary *> *ran = [NSMutableArray new];
    NSMutableArray<NSDictionary *> *never = [NSMutableArray new];
    for (NSDictionary *row in rows) {
      if ([row[@"kind"] isEqualToString:kind[0]]) {
        [[row[@"ran"] boolValue] ? ran : never addObject:row];
      }
    }
    [ran sortWithOptions:NSSortStable
         usingComparator:^(NSDictionary *first, NSDictionary *second) {
           NSDate *earlier = first[@"last"] ?: [NSDate distantPast];
           NSDate *later = second[@"last"] ?: [NSDate distantPast];
           return [later compare:earlier];
         }];
    if (!neverOnly) {
      [text appendFormat:@"\n%@ that have %@: %lu, the latest first\n", kind[1], kind[2],
                         (unsigned long)ran.count];
      [text appendString:[kind[3] stringByReplacingOccurrencesOfString:@"{numbers}"
                                                            withString:FLUsageHeadings]];
      [text appendString:@"\n"];
      for (NSDictionary *row in ran) {
        [text appendFormat:@"%@\n", FLUsageLine(row, YES)];
      }
    }
    [text appendFormat:@"\n%@ that have never %@: %lu\n%@\n", kind[1], kind[2],
                       (unsigned long)never.count, kind[4]];
    for (NSDictionary *row in never) {
      [text appendFormat:@"%@\n", FLUsageLine(row, NO)];
    }
  }
  return text;
}
