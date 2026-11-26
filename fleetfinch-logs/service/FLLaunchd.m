#import "FLLaunchd.h"

#import <fcntl.h>
#import <mach/mach.h>
#import <unistd.h>

#import "FLCommon.h"

typedef void *FLMessage;
typedef void *FLPipe;

extern mach_port_t bootstrap_port;
extern FLMessage xpc_dictionary_create(const char *const *keys, const FLMessage *values,
                                       size_t count);
extern void xpc_dictionary_set_uint64(FLMessage dictionary, const char *key, uint64_t value);
extern void xpc_dictionary_set_string(FLMessage dictionary, const char *key, const char *value);
extern void xpc_dictionary_set_fd(FLMessage dictionary, const char *key, int handle);
extern int64_t xpc_dictionary_get_int64(FLMessage dictionary, const char *key);
extern void xpc_release(FLMessage object);
extern FLPipe xpc_pipe_create_from_port(mach_port_t port, uint32_t flags);
extern int xpc_pipe_routine(FLPipe pipe, FLMessage request, FLMessage *reply);

static const uint64_t FLDescribeService = 708;
static const uint64_t FLSystemDomain = 1;
static const size_t FLFactsMost = 64 * 1024;
static NSString *const FLScratchName = @"launchd.tmp";

static int FLScratchFile(void) {
  static int handle = -1;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *file = [FLStatePath() stringByAppendingPathComponent:FLScratchName];
    handle = open(file.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (handle >= 0) {
      unlink(file.fileSystemRepresentation);
    }
  });
  return handle;
}

static FLPipe FLLaunchdPipe(void) {
  static FLPipe pipe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pipe = xpc_pipe_create_from_port(bootstrap_port, 0);
  });
  return pipe;
}

NSDictionary<NSString *, NSString *> *FLLaunchdFacts(NSString *label) {
  int handle = FLScratchFile();
  FLPipe pipe = FLLaunchdPipe();
  if (label.length == 0 || handle < 0 || pipe == NULL || getuid() != 0) {
    return nil;
  }
  if (ftruncate(handle, 0) != 0 || lseek(handle, 0, SEEK_SET) != 0) {
    return nil;
  }
  FLMessage request = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(request, "subsystem", FLDescribeService >> 8);
  xpc_dictionary_set_uint64(request, "routine", FLDescribeService);
  xpc_dictionary_set_uint64(request, "type", FLSystemDomain);
  xpc_dictionary_set_uint64(request, "handle", 0);
  xpc_dictionary_set_string(request, "name", label.UTF8String);
  xpc_dictionary_set_fd(request, "fd", handle);
  FLMessage reply = NULL;
  int failed = xpc_pipe_routine(pipe, request, &reply);
  int64_t refused = reply == NULL ? -1 : xpc_dictionary_get_int64(reply, "error");
  xpc_release(request);
  if (reply != NULL) {
    xpc_release(reply);
  }
  if (failed != 0 || refused != 0) {
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:FLFactsMost];
  ssize_t count = pread(handle, data.mutableBytes, data.length, 0);
  if (count <= 0) {
    return nil;
  }
  data.length = (NSUInteger)count;
  NSMutableDictionary<NSString *, NSString *> *facts = [NSMutableDictionary new];
  for (NSString *line in [FLStringFromData(data) componentsSeparatedByString:@"\n"]) {
    NSRange equals = [line rangeOfString:@" = "];
    if (![line hasPrefix:@"\t"] || [line hasPrefix:@"\t\t"] || equals.location == NSNotFound ||
        [line hasSuffix:@"{"]) {
      continue;
    }
    NSString *key = [line substringWithRange:NSMakeRange(1, equals.location - 1)];
    if (facts[key] == nil) {
      facts[key] = [line substringFromIndex:NSMaxRange(equals)];
    }
  }
  return facts;
}

NSString *FLLaunchReasonText(NSString *reason) {
  NSDictionary<NSString *, NSString *> *known = @{
    @"ipc (mach)" : @"a program asked for a service it offers",
    @"ipc (socket)" : @"a connection came in on its socket",
    @"xpc event" : @"an event it had asked to be started for",
    @"semaphore" : @"a condition it is kept running under held",
    @"speculative" : @"launchd started it without being asked",
    @"non-ipc demand" : @"launchd was told to start it",
    @"system support" : @"launchd needs it for itself",
  };
  return reason.length == 0 ? @"" : (known[reason] ?: reason);
}
