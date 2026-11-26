#import "FLUsage.h"

#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FLCollect.h"
#import "FLCommon.h"
#import "FLInventory.h"
#import "FLLaunchd.h"
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
  FLFileTimes before = FLFileTimesAt(path.fileSystemRepresentation);
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return nil;
  }
  char line[FLUsageScriptLine + 1] = {0};
  ssize_t count = read(handle, line, FLUsageScriptLine);
  close(handle);
  FLPutBackAccessTime(path.fileSystemRepresentation, before);
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
  NSMutableDictionary<NSString *, NSNumber *> *_launched;
  NSDate *_began;
  NSDate *_saved;
  NSString *_boot;
  NSString *_born;
  NSString *_front;
  NSUInteger _boots;
  double _watched;
  double _awake;
  double _frontSince;
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
        for (NSString *field in @[ @"starters", @"endings", @"reports", @"reasons" ]) {
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
    _born = saved[@"began"] == nil ? _boot : saved[@"born"];
    _saved = [NSDate date];
    _changed = !sameBoot;
    _front = sameBoot && [saved[@"front"] isKindOfClass:[NSString class]] ? saved[@"front"] : @"";
    _frontSince = _awake;
    _launched = sameBoot && [saved[@"launched"] isKindOfClass:[NSDictionary class]]
      ? [saved[@"launched"] mutableCopy]
      : [NSMutableDictionary new];
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
  if ([since compare:_began] == NSOrderedAscending) {
    since = _began;
  }
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

- (void)inFront:(NSString *)identifier name:(NSString *)name path:(NSString *)path {
  NSString *shown = identifier ?: @"";
  double awake = FLAwakeSeconds();
  NSDate *now = [NSDate date];
  NSMutableDictionary *held =
    _front.length > 0 ? _entries[[@"app:" stringByAppendingString:_front]] : nil;
  if (held != nil) {
    held[@"frontSeconds"] = @([held[@"frontSeconds"] doubleValue] + MAX(0, awake - _frontSince));
    held[@"lastFront"] = now;
    _drifted = YES;
  }
  _frontSince = awake;
  if ([shown isEqualToString:_front]) {
    return;
  }
  _front = [shown copy];
  _changed = YES;
  if (shown.length == 0) {
    return;
  }
  NSMutableDictionary *entry = [self entry:[@"app:" stringByAppendingString:shown]
                                      name:name
                                      path:path];
  entry[@"fronts"] = @([entry[@"fronts"] unsignedLongLongValue] + 1);
  entry[@"lastFront"] = now;
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

- (void)service:(NSString *)label
       launched:(NSUInteger)runs
         reason:(NSString *)reason
        program:(NSString *)program {
  NSString *family = FLServiceFamily(label);
  if (family.length == 0 || [family containsString:@"*"] ||
      [family hasPrefix:@"UIKitApplication:"]) {
    return;
  }
  NSString *key = [@"service:" stringByAppendingString:family];
  NSNumber *known = _launched[label];
  NSUInteger before = known.unsignedIntegerValue;
  if (known == nil && [_born isEqual:_boot]) {
    before = reason.length > 0 && runs > 0 ? runs - 1 : runs;
  }
  if (known == nil || runs > before) {
    _launched[label] = @(runs);
    _changed = YES;
  }
  if (runs > before) {
    NSMutableDictionary *entry = [self entry:key name:family path:program];
    entry[@"launches"] = @([entry[@"launches"] unsignedLongLongValue] + (runs - before));
    FLTally(entry, @"reasons", reason);
  } else if (reason.length > 0 && _entries[key] != nil && _entries[key][@"reasons"] == nil) {
    FLTally(_entries[key], @"reasons", reason);
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
    @"front" : _front ?: @"",
    @"launched" : _launched,
    @"born" : _born ?: @"",
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

static NSString *FLDescribeReasons(NSDictionary<NSString *, NSNumber *> *counts) {
  if (![counts isKindOfClass:[NSDictionary class]] || counts.count == 0) {
    return @"";
  }
  NSMutableDictionary<NSString *, NSNumber *> *said = [NSMutableDictionary new];
  for (NSString *reason in counts) {
    said[FLLaunchReasonText(reason)] = counts[reason];
  }
  return FLDescribeCounts(said);
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
  row[@"ran"] = @([entry[@"runs"] unsignedLongLongValue] > 0 ||
                  [entry[@"fronts"] unsignedLongLongValue] > 0 ||
                  [entry[@"launches"] unsignedLongLongValue] > 0);
  row[@"running"] = @(running);
  if (entry == nil) {
    return row;
  }
  for (NSString *field in @[
         @"runs", @"first", @"last", @"seconds", @"processor", @"memory", @"command", @"user",
         @"fronts", @"frontSeconds", @"lastFront", @"launches"
       ]) {
    if (entry[field] != nil) {
      row[field] = entry[field];
    }
  }
  row[@"starters"] = FLDescribeCounts(entry[@"starters"]);
  row[@"endings"] = FLDescribeCounts(entry[@"endings"]);
  row[@"reports"] = FLDescribeCounts(entry[@"reports"]);
  row[@"why"] = FLDescribeReasons(entry[@"reasons"]);
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
  for (NSString *key in @[ @"origins", @"reads" ]) {
    found[key] = [installed[key] isKindOfClass:[NSDictionary class]] ? installed[key] : @{};
  }
  if ([installed[@"counting"] isKindOfClass:[NSDate class]]) {
    found[@"counting"] = installed[@"counting"];
  }
  found[@"listed"] = @(installed.count > 0);
  found[@"definitions"] = FLLaunchServices() ?: @[];
  kept = found;
  built = [NSDate date];
  listed = written;
  return kept;
}

static NSDictionary *FLUsageDetails(NSDictionary *details, NSDate *read) {
  if (read == nil) {
    return details;
  }
  NSMutableDictionary *more = [details mutableCopy];
  more[@"read"] = read;
  return more;
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
  NSDictionary<NSString *, NSDate *> *reads = inventory[@"reads"];
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
    [rows addObject:FLUsageRow(@"app", identifier, app[@"name"],
                               FLUsageDetails(details, reads[app[@"program"] ?: @""]),
                               entries[key], [running countForObject:key])];
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
    [rows addObject:FLUsageRow(@"service", family, family, FLUsageDetails(details, reads[program]),
                               entries[key], [running countForObject:key])];
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
    [rows addObject:FLUsageRow(@"service", identifier, identifier,
                               FLUsageDetails(details, reads[program]), entries[used],
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
    [rows addObject:FLUsageRow(@"program", path, path.lastPathComponent,
                               FLUsageDetails(details, reads[path]), entry,
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
    NSUInteger total = 0, never = 0, now = 0, read = 0, front = 0;
    for (NSDictionary *row in rows) {
      if (![row[@"kind"] isEqualToString:kind]) {
        continue;
      }
      BOOL ran = [row[@"ran"] boolValue];
      total++;
      never += ran ? 0 : 1;
      read += !ran && row[@"read"] != nil ? 1 : 0;
      front += [row[@"fronts"] unsignedLongLongValue] > 0 ? 1 : 0;
      now += [row[@"running"] unsignedIntegerValue] > 0 ? 1 : 0;
    }
    summary[kind] = @{
      @"total" : @(total),
      @"never" : @(never),
      @"running" : @(now),
      @"read" : @(read),
      @"front" : @(front),
    };
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
  if (inventory[@"counting"] != nil) {
    report[@"counting"] = inventory[@"counting"];
  }
  return report;
}

BOOL FLWriteUsageReport(NSDictionary *report) {
  return FLWriteCompactState(FLUsageReportState, report);
}

static NSString *FLUsageDay(id date) {
  return [date isKindOfClass:[NSDate class]] ? FLFormatDay(date) : @"";
}

static NSString *FLUsageNumbers(NSDictionary *row) {
  NSUInteger running = [row[@"running"] unsignedIntegerValue];
  return [NSString
    stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%.1fs\t%@\t%@", row[@"runs"] ?: @0,
                     running > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)running]
                                 : @"no",
                     FLUsageDay(row[@"first"]), FLUsageDay(row[@"last"]),
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
  NSString *read = FLUsageDay(row[@"read"]);
  uint64_t bytes = [row[@"bytes"] unsignedLongLongValue];
  NSString *size = bytes > 0 ? FLFormatBytes(bytes) : @"";
  if ([kind isEqualToString:@"app"]) {
    NSString *front = [NSString
      stringWithFormat:@"%@\t%@\t%@", row[@"fronts"] ?: @0,
                       FLFormatDuration([row[@"frontSeconds"] doubleValue]),
                       FLUsageDay(row[@"lastFront"])];
    return ran ? [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", row[@"name"],
                                            row[@"key"], front, FLUsageNumbers(row), note, size,
                                            origin, where]
               : [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", row[@"name"],
                                            row[@"key"], note, size, origin, read,
                                            row[@"trouble"] ?: @"", where];
  }
  if ([kind isEqualToString:@"service"]) {
    return ran ? [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@",
                                            row[@"key"], FLUsageNumbers(row),
                                            row[@"launches"] ?: @"", row[@"why"] ?: @"",
                                            row[@"endings"] ?: @"", note, size, origin, where,
                                            row[@"file"] ?: @""]
               : [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@", row[@"key"],
                                            note, size, origin, read, row[@"trouble"] ?: @"",
                                            where, row[@"file"] ?: @""];
  }
  return ran ? [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@", where, FLUsageNumbers(row),
                                          size, origin, FLEscape(row[@"command"] ?: @"")]
             : [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@", where, size, origin, read,
                                          row[@"trouble"] ?: @""];
}

static NSComparator FLLatest(NSString *field) {
  return ^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
    NSDate *earlier = [first[field] isKindOfClass:[NSDate class]] ? first[field]
                                                                 : [NSDate distantPast];
    NSDate *later = [second[field] isKindOfClass:[NSDate class]] ? second[field]
                                                                : [NSDate distantPast];
    return [later compare:earlier];
  };
}

static void FLAppendRows(NSMutableString *text, NSString *title, NSString *headings,
                         NSArray<NSDictionary *> *rows, BOOL ran) {
  [text appendFormat:@"\n%@: %lu\n%@\n", title, (unsigned long)rows.count,
                     [headings stringByReplacingOccurrencesOfString:@"{numbers}"
                                                         withString:FLUsageHeadings]];
  for (NSDictionary *row in rows) {
    [text appendFormat:@"%@\n", FLUsageLine(row, ran)];
  }
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
  [text appendString:@"An app is in front when it is the one on the screen and the device is "
                     @"not locked. iOS also starts apps by itself where nobody sees them, so "
                     @"an app can have run without ever being in front.\n"];
  [text appendString:@"Started by launchd is launchd's own count of how often it has run a "
                     @"service, which covers the time before Finch Logs was running, and why "
                     @"is the reason it gave for the start.\n"];
  if ([report[@"counting"] isKindOfClass:[NSDate class]]) {
    [text appendFormat:@"File read is when the file of a thing that was never seen running was "
                       @"last read, if that was since %@. Running a program reads its file, so "
                       @"this shows what ran before Finch Logs was running, which it is not for "
                       @"the first minute after the device starts.\n",
                       FLFormatDay(report[@"counting"])];
  }
  if (![report[@"listed"] boolValue]) {
    [text appendString:@"What is installed has not been listed yet, so apps, extensions and "
                       @"programs that have never run are missing. The service lists it within "
                       @"a few minutes of starting, and finchlog inventory lists it now.\n"];
  }
  [text appendString:@"\n"];
  NSDictionary *summary = report[@"summary"];
  NSDictionary *apps = summary[@"app"];
  [text appendFormat:@"Apps: %@ found, %@ have been in front, %@ have never run, %@ running now\n",
                     apps[@"total"] ?: @0, apps[@"front"] ?: @0, apps[@"never"] ?: @0,
                     apps[@"running"] ?: @0];
  NSArray<NSArray<NSString *> *> *others =
    @[ @[ @"service", @"Services" ], @[ @"program", @"Programs" ] ];
  for (NSArray<NSString *> *kind in others) {
    NSDictionary *counts = summary[kind[0]];
    [text appendFormat:@"%@: %@ found, %@ have never run, %@ of those had their file read, %@ "
                       @"running now\n",
                       kind[1], counts[@"total"] ?: @0, counts[@"never"] ?: @0,
                       counts[@"read"] ?: @0, counts[@"running"] ?: @0];
  }
  NSArray<NSDictionary *> *rows = report[@"rows"];
  NSString *fronted = @"name\tidentifier\ttimes in front\ttime in front\tlast in front\t"
                      @"{numbers}\tkind\tsize\tfrom\tpath";
  NSString *served = @"label\t{numbers}\tstarted by launchd\twhy\tended with\tstarts\tsize\t"
                     @"from\tprogram\tdefined in";
  NSArray<NSArray<NSString *> *> *kinds = @[
    @[
      @"app", @"Apps", fronted,
      @"name\tidentifier\tkind\tsize\tfrom\tfile read\ttrouble\tpath"
    ],
    @[
      @"service", @"Services", served,
      @"label\tstarts\tsize\tfrom\tfile read\ttrouble\tprogram\tdefined in"
    ],
    @[
      @"program", @"Programs", @"path\t{numbers}\tsize\tfrom\tlast command",
      @"path\tsize\tfrom\tfile read\ttrouble"
    ],
  ];
  for (NSArray<NSString *> *kind in kinds) {
    BOOL app = [kind[0] isEqualToString:@"app"];
    NSMutableArray<NSDictionary *> *front = [NSMutableArray new];
    NSMutableArray<NSDictionary *> *ran = [NSMutableArray new];
    NSMutableArray<NSDictionary *> *never = [NSMutableArray new];
    for (NSDictionary *row in rows) {
      if (![row[@"kind"] isEqualToString:kind[0]]) {
        continue;
      }
      if (app && [row[@"fronts"] unsignedLongLongValue] > 0) {
        [front addObject:row];
      } else if ([row[@"ran"] boolValue]) {
        [ran addObject:row];
      } else {
        [never addObject:row];
      }
    }
    [front sortWithOptions:NSSortStable usingComparator:FLLatest(@"lastFront")];
    [ran sortWithOptions:NSSortStable usingComparator:FLLatest(@"last")];
    if (!neverOnly && app) {
      FLAppendRows(text, @"Apps that have been in front, the latest first", kind[2], front, YES);
      FLAppendRows(text, @"Apps that ran without being in front, the latest first", kind[2], ran,
                   YES);
    } else if (!neverOnly) {
      FLAppendRows(text, [kind[1] stringByAppendingString:@" that have run, the latest first"],
                   kind[2], ran, YES);
    }
    FLAppendRows(text, [kind[1] stringByAppendingString:@" that have never run"], kind[3], never,
                 NO);
  }
  return text;
}
