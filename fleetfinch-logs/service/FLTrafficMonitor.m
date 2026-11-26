#import "FLMonitors.h"

#import <arpa/inet.h>
#import <fcntl.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FLStore.h"
#import "FLSystemInfo.h"

static NSString *const FLTrafficControl = @"com.apple.network.statistics";
static const uint32_t FLControlFamily = 2;
static const int FLControlProtocol = 2;
static const uint32_t FLProviderTCP = 2;
static const uint32_t FLProviderUDP = 3;
static const uint32_t FLAskAddAll = 1002;
static const uint32_t FLAskCounts = 1004;
static const uint32_t FLAskDescription = 1005;
static const uint32_t FLToldAdded = 10001;
static const uint32_t FLToldRemoved = 10002;
static const uint32_t FLToldDescription = 10003;
static const uint32_t FLToldCounts = 10004;
static const uint32_t FLEverySource = 0xffffffff;
static const size_t FLHeaderBytes = 16;
static const size_t FLLocalAt = 24;
static const size_t FLRemoteAt = 52;
static const size_t FLStateAt = 84;
static const size_t FLTCPPidAt = 148;
static const size_t FLUDPPidAt = 104;
static const size_t FLNameBytes = 64;
static const size_t FLTCPDescription = 284;
static const size_t FLUDPDescription = 236;
static const size_t FLCountsBytes = 72;
static const uint32_t FLListening = 1;
static const size_t FLPacketRoom = 32 * 1024;
static const size_t FLLinkBytes = 14;
static const uint32_t FLLinkEthernet = 1;
static const uint16_t FLNamePort = 53;
static const NSUInteger FLNamesKept = 3000;
static const NSUInteger FLPeersKept = 80;
static const NSUInteger FLAddressesKept = 4;
static const NSUInteger FLFailuresKept = 300;
static const NSTimeInterval FLTrafficSaveEvery = 300;
static const uint16_t FLPassingPorts = 49152;
static NSString *const FLOtherPeers = @"(others)";

struct FLControlInfo {
  uint32_t identifier;
  char name[96];
};

struct FLControlAddress {
  uint8_t length;
  uint8_t family;
  uint16_t system;
  uint32_t identifier;
  uint32_t unit;
  uint32_t reserved[5];
};

struct FLMessage {
  uint64_t context;
  uint32_t type;
  uint16_t length;
  uint16_t flags;
};

struct FLFilterStep {
  uint16_t code;
  uint8_t yes;
  uint8_t no;
  uint32_t value;
};

struct FLFilter {
  uint32_t count;
  struct FLFilterStep *steps;
};

struct FLPacketHeader {
  int32_t seconds;
  int32_t microseconds;
  uint32_t kept;
  uint32_t length;
  uint16_t header;
};

#define FLControlGetInfo _IOWR('N', 3, struct FLControlInfo)
#define FLPacketsSetRoom _IOWR('B', 102, u_int)
#define FLPacketsSetFilter _IOW('B', 103, struct FLFilter)
#define FLPacketsGetLink _IOR('B', 106, u_int)
#define FLPacketsSetInterface _IOW('B', 108, struct ifreq)
#define FLPacketsAtOnce _IOW('B', 112, u_int)

@interface FLSource : NSObject

@property(nonatomic) uint32_t provider;
@property(nonatomic, strong) NSDate *added;
@property(nonatomic, copy) NSString *program;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *behalf;
@property(nonatomic, copy) NSString *local;
@property(nonatomic, copy) NSString *remote;
@property(nonatomic) int pid;
@property(nonatomic) uint16_t localPort;
@property(nonatomic) uint16_t remotePort;
@property(nonatomic) uint32_t state;
@property(nonatomic) uint64_t received;
@property(nonatomic) uint64_t sent;
@property(nonatomic) uint32_t attempts;
@property(nonatomic) uint32_t successes;
@property(nonatomic) BOOL listening;

@end

@implementation FLSource
@end

static NSString *FLAddressText(const uint8_t *bytes, uint16_t *port) {
  uint8_t length = bytes[0];
  uint8_t family = bytes[1];
  char text[INET6_ADDRSTRLEN] = {0};
  memcpy(port, bytes + 2, sizeof(*port));
  *port = ntohs(*port);
  if (family == AF_INET && length >= sizeof(struct sockaddr_in)) {
    inet_ntop(AF_INET, bytes + 4, text, sizeof(text));
  } else if (family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
    inet_ntop(AF_INET6, bytes + 8, text, sizeof(text));
  } else {
    *port = 0;
    return nil;
  }
  NSString *address = @(text);
  BOOL unset = [address isEqualToString:@"0.0.0.0"] || [address isEqualToString:@"::"];
  return unset ? nil : address;
}

static BOOL FLIsLocal(NSString *address) {
  return [address hasPrefix:@"127."] || [address isEqualToString:@"::1"] ||
         [address hasPrefix:@"fe80:"];
}

@implementation FLTrafficMonitor {
  dispatch_queue_t _queue;
  dispatch_source_t _reader;
  dispatch_source_t _listener;
  int _control;
  int _packets;
  uint8_t *_room;
  NSMutableDictionary<NSNumber *, FLSource *> *_sources;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_programs;
  NSMutableDictionary<NSString *, NSArray *> *_names;
  NSMutableDictionary<NSString *, NSString *> *_paths;
  NSMutableSet<NSNumber *> *_ports;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_failures;
  NSDate *_began;
  NSDate *_saved;
  BOOL _changed;
  BOOL _unknown;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _control = -1;
    _packets = -1;
    _sources = [NSMutableDictionary new];
    _programs = [NSMutableDictionary new];
    _names = [NSMutableDictionary new];
    _paths = [NSMutableDictionary new];
    _ports = [NSMutableSet new];
    _failures = [NSMutableDictionary new];
    NSDictionary *saved = FLReadState(FLTrafficState);
    NSDictionary *programs = saved[@"programs"];
    if ([programs isKindOfClass:[NSDictionary class]]) {
      for (NSString *program in programs) {
        NSMutableDictionary *record = [programs[program] mutableCopy];
        for (NSString *field in @[ @"peers", @"listens" ]) {
          NSMutableDictionary *inner = [NSMutableDictionary new];
          NSDictionary *kept = record[field];
          for (NSString *key in [kept isKindOfClass:[NSDictionary class]] ? kept : @{}) {
            inner[key] = [kept[key] mutableCopy];
          }
          record[field] = inner;
        }
        _programs[program] = record;
      }
    }
    NSDictionary *failures = saved[@"failures"];
    if ([failures isKindOfClass:[NSDictionary class]]) {
      for (NSString *name in failures) {
        _failures[name] = [failures[name] mutableCopy];
      }
    }
    _began = [saved[@"began"] isKindOfClass:[NSDate class]] ? saved[@"began"] : [NSDate date];
    _saved = [NSDate date];
  }
  return self;
}

- (void)send:(uint32_t)type value:(uint32_t)value room:(size_t)room {
  uint8_t message[64] = {0};
  struct FLMessage header = {0, type, 0, 0};
  memcpy(message, &header, sizeof(header));
  memcpy(message + FLHeaderBytes, &value, sizeof(value));
  send(_control, message, MIN(room, sizeof(message)), 0);
}

- (BOOL)openControl {
  int handle = socket(PF_SYSTEM, SOCK_DGRAM, FLControlProtocol);
  if (handle < 0) {
    return NO;
  }
  struct FLControlInfo info;
  memset(&info, 0, sizeof(info));
  strlcpy(info.name, FLTrafficControl.UTF8String, sizeof(info.name));
  struct FLControlAddress address;
  memset(&address, 0, sizeof(address));
  address.length = sizeof(address);
  address.family = AF_SYSTEM;
  address.system = FLControlFamily;
  if (ioctl(handle, FLControlGetInfo, &info) != 0) {
    close(handle);
    return NO;
  }
  address.identifier = info.identifier;
  if (connect(handle, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(handle);
    return NO;
  }
  fcntl(handle, F_SETFL, O_NONBLOCK);
  _control = handle;
  return YES;
}

- (BOOL)openPackets:(NSString *)interface {
  int handle = -1;
  for (int index = 0; index < 16 && handle < 0; index++) {
    NSString *device = [NSString stringWithFormat:@"/dev/bpf%d", index];
    handle = open(device.fileSystemRepresentation, O_RDONLY);
  }
  if (handle < 0) {
    return NO;
  }
  static struct FLFilterStep steps[] = {
    {0x28, 0, 0, 12},     {0x15, 0, 7, 0x0800}, {0x30, 0, 0, 23},  {0x15, 0, 11, 17},
    {0x28, 0, 0, 20},     {0x45, 9, 0, 0x1fff}, {0xb1, 0, 0, 14},  {0x48, 0, 0, 14},
    {0x15, 5, 6, 53},     {0x15, 0, 5, 0x86dd}, {0x30, 0, 0, 20},  {0x15, 0, 3, 17},
    {0x28, 0, 0, 54},     {0x15, 0, 1, 53},     {0x06, 0, 0, 4096}, {0x06, 0, 0, 0},
  };
  struct FLFilter filter = {sizeof(steps) / sizeof(steps[0]), steps};
  struct ifreq request;
  memset(&request, 0, sizeof(request));
  strlcpy(request.ifr_name, interface.UTF8String, sizeof(request.ifr_name));
  u_int room = (u_int)FLPacketRoom;
  u_int link = 0;
  u_int yes = 1;
  ioctl(handle, FLPacketsSetRoom, &room);
  if (ioctl(handle, FLPacketsSetInterface, &request) != 0 ||
      ioctl(handle, FLPacketsGetLink, &link) != 0 || link != FLLinkEthernet ||
      ioctl(handle, FLPacketsSetFilter, &filter) != 0) {
    close(handle);
    return NO;
  }
  ioctl(handle, FLPacketsAtOnce, &yes);
  fcntl(handle, F_SETFL, O_NONBLOCK);
  _packets = handle;
  _room = malloc(FLPacketRoom);
  return _room != NULL;
}

- (void)startOnQueue:(dispatch_queue_t)queue {
  _queue = queue;
  if (![self openControl]) {
    FLNote(@"finchlogs", FLLevelWarning, @"connections",
           @"The kernel's record of network connections could not be opened, so which "
           @"process talks to which server is not recorded");
    return;
  }
  __weak FLTrafficMonitor *weak = self;
  _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_control, 0, queue);
  dispatch_source_set_event_handler(_reader, ^{
    [weak readControl];
  });
  dispatch_resume(_reader);
  [self send:FLAskAddAll value:FLProviderTCP room:32];
  [self send:FLAskAddAll value:FLProviderUDP room:32];
  [self watchNames];
  if (_packets < 0) {
    FLNote(@"finchlogs", FLLevelInfo, @"connections",
           @"Name lookups on the Wi-Fi interface cannot be watched yet, so until they can "
           @"servers are recorded by address only");
  }
}

- (void)watchNames {
  if (_packets >= 0 || _queue == nil || ![self openPackets:@"en0"]) {
    return;
  }
  __weak FLTrafficMonitor *weak = self;
  _listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_packets, 0, _queue);
  dispatch_source_set_event_handler(_listener, ^{
    [weak readPackets];
  });
  dispatch_resume(_listener);
}

- (void)refresh {
  [self watchNames];
  if (_control >= 0) {
    [self send:FLAskCounts value:FLEverySource room:20];
    [self send:FLAskDescription value:FLEverySource room:20];
  }
}

- (void)describe:(FLSource *)source from:(const uint8_t *)bytes length:(size_t)length {
  BOOL stream = source.provider == FLProviderTCP;
  if (length != (stream ? FLTCPDescription : FLUDPDescription)) {
    if (!_unknown) {
      _unknown = YES;
      FLNote(@"finchlogs", FLLevelWarning, @"connections",
             @"This version of iOS describes a connection in %lu bytes, a form Finch Logs "
             @"does not know, so connections are not recorded",
             (unsigned long)length);
    }
    return;
  }
  uint16_t port = 0;
  NSString *local = FLAddressText(bytes + FLLocalAt, &port);
  source.local = local ?: source.local;
  source.localPort = port ?: source.localPort;
  NSString *remote = FLAddressText(bytes + FLRemoteAt, &port);
  if (remote != nil) {
    source.remote = remote;
    source.remotePort = port;
  }
  size_t at = stream ? FLTCPPidAt : FLUDPPidAt;
  uint32_t pid = 0;
  uint32_t other = 0;
  memcpy(&pid, bytes + at, sizeof(pid));
  memcpy(&other, bytes + at + sizeof(pid) + FLNameBytes + sizeof(uint64_t), sizeof(other));
  char name[FLNameBytes + 1] = {0};
  memcpy(name, bytes + at + sizeof(pid), FLNameBytes);
  if (stream) {
    uint32_t state = 0;
    memcpy(&state, bytes + FLStateAt, sizeof(state));
    source.state = state;
    source.listening = source.listening || state == FLListening;
  }
  NSString *reported = [NSString stringWithUTF8String:name] ?: @"";
  if (pid == 0 || ((int)pid == source.pid && [reported isEqualToString:source.name ?: @""])) {
    return;
  }
  source.pid = (int)pid;
  source.name = reported;
  NSString *path = FLProcessSketch((int)pid, NO).path;
  if ([path.lastPathComponent hasPrefix:reported] && reported.length > 0) {
    _paths[reported] = path;
  }
  source.program = _paths[reported] ?: reported;
  if (other != 0 && other != pid) {
    FLProcess *served = FLProcessSketch((int)other, NO);
    source.behalf = served.path.lastPathComponent ?: served.name;
  }
}

- (NSMutableDictionary *)program:(FLSource *)source {
  NSString *key = source.program.length > 0 ? source.program : @"(unknown)";
  NSMutableDictionary *record = _programs[key];
  if (record == nil) {
    record = [NSMutableDictionary new];
    record[@"peers"] = [NSMutableDictionary new];
    record[@"listens"] = [NSMutableDictionary new];
    _programs[key] = record;
  }
  record[@"name"] = source.name.length > 0 ? source.name : key.lastPathComponent;
  return record;
}

- (NSString *)nameOf:(NSString *)address {
  return address == nil ? nil : _names[address].firstObject;
}

- (NSString *)peerOf:(FLSource *)source {
  NSString *protocol = source.provider == FLProviderTCP ? @"TCP" : @"UDP";
  if (source.remote == nil) {
    return source.localPort == 0 || source.localPort >= FLPassingPorts
      ? [NSString stringWithFormat:@"no fixed peer, %@", protocol]
      : [NSString stringWithFormat:@"no fixed peer, from %@ port %u", protocol,
                                   source.localPort];
  }
  NSString *host = FLIsLocal(source.remote) ? @"this device"
                                            : ([self nameOf:source.remote] ?: source.remote);
  if ([_ports containsObject:@(source.localPort)]) {
    return [NSString stringWithFormat:@"from %@, into %@ port %u", host, protocol,
                                      source.localPort];
  }
  return [NSString stringWithFormat:@"%@, %@ port %u", host, protocol, source.remotePort];
}

- (void)listen:(FLSource *)source {
  NSMutableDictionary *listens = [self program:source][@"listens"];
  NSString *key = [NSString stringWithFormat:@"TCP port %u", source.localPort];
  [_ports addObject:@(source.localPort)];
  NSMutableDictionary *record = listens[key];
  if (record == nil) {
    record = [NSMutableDictionary new];
    record[@"first"] = [NSDate date];
    listens[key] = record;
    _changed = YES;
  }
  record[@"last"] = [NSDate date];
}

- (void)finish:(FLSource *)source {
  BOOL stream = source.provider == FLProviderTCP;
  BOOL failed = stream && source.attempts > source.successes;
  BOOL quiet = source.received == 0 && source.sent == 0;
  if (source.program.length == 0 || source.listening || (quiet && !failed) ||
      (stream && source.remote == nil)) {
    return;
  }
  NSMutableDictionary *peers = [self program:source][@"peers"];
  NSString *key = [self peerOf:source];
  if (peers[key] == nil && peers.count >= FLPeersKept) {
    key = FLOtherPeers;
  }
  NSMutableDictionary *peer = peers[key];
  NSDate *now = [NSDate date];
  if (peer == nil) {
    peer = [NSMutableDictionary new];
    peer[@"first"] = source.added ?: now;
    peers[key] = peer;
  }
  peer[@"last"] = now;
  peer[@"count"] = @([peer[@"count"] unsignedLongLongValue] + 1);
  peer[@"in"] = @([peer[@"in"] unsignedLongLongValue] + source.received);
  peer[@"out"] = @([peer[@"out"] unsignedLongLongValue] + source.sent);
  if (failed) {
    peer[@"failed"] = @([peer[@"failed"] unsignedLongLongValue] + 1);
  }
  if (source.behalf.length > 0) {
    peer[@"behalf"] = source.behalf;
  }
  NSArray<NSString *> *addresses = peer[@"addresses"] ?: @[];
  if (source.remote != nil && ![addresses containsObject:source.remote] &&
      addresses.count < FLAddressesKept) {
    peer[@"addresses"] = [addresses arrayByAddingObject:source.remote];
  }
  _changed = YES;
  NSString *behalf = source.behalf.length > 0
    ? [NSString stringWithFormat:@" for %@", source.behalf]
    : @"";
  NSString *outcome = failed ? @" and could not connect" : @"";
  if (source.remote == nil) {
    return;
  }
  FLNote(@"connection", FLLevelInfo, source.name.length > 0 ? source.name : @"unknown",
         @"pid %d%@ %@ %@ for %@%@: sent %@, received %@", source.pid, behalf,
         [key hasPrefix:@"from "] ? @"was reached" : @"talked to", key,
         FLFormatDuration(-source.added.timeIntervalSinceNow), outcome,
         FLFormatBytes(source.sent), FLFormatBytes(source.received));
}

- (void)take:(const uint8_t *)bytes length:(size_t)length {
  struct FLMessage header;
  if (length < FLHeaderBytes + sizeof(uint32_t)) {
    return;
  }
  memcpy(&header, bytes, sizeof(header));
  uint32_t first = 0;
  uint32_t second = 0;
  memcpy(&first, bytes + FLHeaderBytes, sizeof(first));
  if (length >= FLLocalAt) {
    memcpy(&second, bytes + FLHeaderBytes + sizeof(first), sizeof(second));
  }
  if (header.type == FLToldAdded && length >= FLLocalAt) {
    FLSource *source = [FLSource new];
    source.provider = first;
    source.added = [NSDate date];
    _sources[@(second)] = source;
    [self send:FLAskDescription value:second room:20];
    return;
  }
  FLSource *source = _sources[@(first)];
  if (source == nil) {
    return;
  }
  if (header.type == FLToldDescription && !_unknown) {
    [self describe:source from:bytes length:length];
    if (source.listening && source.localPort != 0 && source.program.length > 0) {
      [self listen:source];
    }
  } else if (header.type == FLToldCounts && length >= FLCountsBytes) {
    uint64_t received = 0, sent = 0;
    uint32_t attempts = 0, successes = 0;
    memcpy(&received, bytes + 28, sizeof(received));
    memcpy(&sent, bytes + 44, sizeof(sent));
    memcpy(&attempts, bytes + 64, sizeof(attempts));
    memcpy(&successes, bytes + 68, sizeof(successes));
    source.received = received;
    source.sent = sent;
    source.attempts = attempts;
    source.successes = successes;
  } else if (header.type == FLToldRemoved) {
    [self finish:source];
    [_sources removeObjectForKey:@(first)];
  }
}

- (void)readControl {
  uint8_t message[2048];
  for (;;) {
    ssize_t count = recv(_control, message, sizeof(message), 0);
    if (count <= 0) {
      return;
    }
    @autoreleasepool {
      [self take:message length:(size_t)count];
    }
  }
}

- (size_t)skipName:(const uint8_t *)data length:(size_t)length at:(size_t)at {
  while (at < length) {
    uint8_t size = data[at];
    if (size == 0) {
      return at + 1;
    }
    if ((size & 0xc0) == 0xc0) {
      return at + 2;
    }
    at += (size_t)size + 1;
  }
  return length;
}

- (NSString *)nameIn:(const uint8_t *)data length:(size_t)length at:(size_t)at {
  NSMutableArray<NSString *> *labels = [NSMutableArray new];
  NSUInteger jumps = 0;
  while (at < length && jumps < 16 && labels.count < 64) {
    uint8_t size = data[at];
    if (size == 0) {
      break;
    }
    if ((size & 0xc0) == 0xc0) {
      if (at + 1 >= length) {
        return nil;
      }
      at = (size_t)((size & 0x3f) << 8) | data[at + 1];
      jumps++;
      continue;
    }
    if (at + 1 + size > length) {
      return nil;
    }
    NSString *label = [[NSString alloc] initWithBytes:data + at + 1
                                               length:size
                                             encoding:NSASCIIStringEncoding];
    if (label == nil) {
      return nil;
    }
    [labels addObject:label];
    at += (size_t)size + 1;
  }
  return labels.count > 0 ? [labels componentsJoinedByString:@"."] : nil;
}

- (void)answer:(const uint8_t *)data length:(size_t)length {
  if (length < 12 || (data[2] & 0x80) == 0) {
    return;
  }
  uint16_t questions = (uint16_t)((data[4] << 8) | data[5]);
  uint16_t answers = (uint16_t)((data[6] << 8) | data[7]);
  uint8_t outcome = data[3] & 0x0f;
  NSString *asked = questions > 0 ? [self nameIn:data length:length at:12] : nil;
  if (asked == nil) {
    return;
  }
  NSDate *now = [NSDate date];
  if (outcome == 3 && answers == 0) {
    NSMutableDictionary *failure = _failures[asked];
    if (failure == nil && _failures.count < FLFailuresKept) {
      failure = [NSMutableDictionary new];
      failure[@"first"] = now;
      _failures[asked] = failure;
    }
    failure[@"last"] = now;
    failure[@"count"] = @([failure[@"count"] unsignedLongLongValue] + 1);
    _changed = _changed || failure != nil;
    return;
  }
  size_t at = 12;
  for (uint16_t index = 0; index < questions; index++) {
    at = [self skipName:data length:length at:at] + 4;
  }
  for (uint16_t index = 0; index < answers && at + 10 <= length; index++) {
    at = [self skipName:data length:length at:at];
    if (at + 10 > length) {
      return;
    }
    uint16_t type = (uint16_t)((data[at] << 8) | data[at + 1]);
    uint16_t size = (uint16_t)((data[at + 8] << 8) | data[at + 9]);
    at += 10;
    if (at + size > length) {
      return;
    }
    char text[INET6_ADDRSTRLEN] = {0};
    if (type == 1 && size == 4) {
      inet_ntop(AF_INET, data + at, text, sizeof(text));
    } else if (type == 28 && size == 16) {
      inet_ntop(AF_INET6, data + at, text, sizeof(text));
    }
    if (text[0] != '\0') {
      _names[@(text)] = @[ asked, now ];
    }
    at += size;
  }
  if (_names.count > FLNamesKept) {
    NSArray<NSString *> *oldest = [_names
      keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *first, NSArray *second) {
        return [first[1] compare:second[1]];
      }];
    NSRange spare = NSMakeRange(0, oldest.count - FLNamesKept / 2);
    [_names removeObjectsForKeys:[oldest subarrayWithRange:spare]];
  }
}

- (void)packet:(const uint8_t *)frame length:(size_t)length {
  if (length < FLLinkBytes + 28) {
    return;
  }
  const uint8_t *packet = frame + FLLinkBytes;
  size_t rest = length - FLLinkBytes;
  size_t header = (packet[0] >> 4) == 4 ? (size_t)(packet[0] & 0x0f) * 4 : 40;
  if (rest < header + 8 + 12) {
    return;
  }
  uint16_t port = (uint16_t)((packet[header] << 8) | packet[header + 1]);
  if (port == FLNamePort) {
    [self answer:packet + header + 8 length:rest - header - 8];
  }
}

- (void)readPackets {
  for (;;) {
    ssize_t count = read(_packets, _room, FLPacketRoom);
    if (count <= 0) {
      return;
    }
    size_t at = 0;
    while (at + sizeof(struct FLPacketHeader) <= (size_t)count) {
      struct FLPacketHeader header;
      memcpy(&header, _room + at, sizeof(header));
      size_t start = at + header.header;
      if (header.header == 0 || start + header.kept > (size_t)count) {
        break;
      }
      @autoreleasepool {
        [self packet:_room + start length:header.kept];
      }
      at = (start + header.kept + 3) & ~(size_t)3;
    }
  }
}

- (NSDictionary *)contents {
  NSMutableArray<NSDictionary *> *open = [NSMutableArray new];
  for (FLSource *source in _sources.allValues) {
    if (source.program.length == 0 || source.listening || source.remote == nil) {
      continue;
    }
    [open addObject:@{
      @"program" : source.program,
      @"peer" : [self peerOf:source],
      @"since" : source.added ?: [NSDate date],
      @"in" : @(source.received),
      @"out" : @(source.sent),
    }];
  }
  return @{
    @"version" : @1,
    @"began" : _began,
    @"saved" : [NSDate date],
    @"programs" : _programs,
    @"failures" : _failures,
    @"open" : open,
    @"named" : @(_names.count),
    @"watching" : @(_control >= 0 && !_unknown),
    @"naming" : @(_packets >= 0),
  };
}

- (BOOL)save {
  if (!FLWriteCompactState(FLTrafficState, [self contents])) {
    return NO;
  }
  _saved = [NSDate date];
  _changed = NO;
  return YES;
}

- (BOOL)saveIfDue {
  if (!_changed || -_saved.timeIntervalSinceNow < FLTrafficSaveEvery) {
    return NO;
  }
  return [self save];
}

@end
