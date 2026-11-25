#import <Foundation/Foundation.h>

@interface FLProcess : NSObject

@property(nonatomic) int pid;
@property(nonatomic) int parent;
@property(nonatomic) unsigned user;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSArray<NSString *> *arguments;
@property(nonatomic, strong) NSDate *started;
@property(nonatomic) double processorSeconds;
@property(nonatomic) uint64_t residentBytes;
@property(nonatomic) uint64_t footprintBytes;
@property(nonatomic) uint64_t virtualBytes;
@property(nonatomic) uint64_t readBytes;
@property(nonatomic) uint64_t writtenBytes;
@property(nonatomic) uint64_t wakeups;
@property(nonatomic) int threads;
@property(nonatomic) int faults;
@property(nonatomic) int pageIns;
@property(nonatomic) BOOL detailed;

- (NSString *)identity;
- (NSString *)appBundlePath;
- (NSString *)displayName;
- (NSString *)commandLine;

@end

@interface FLVolume : NSObject

@property(nonatomic, copy) NSString *mount;
@property(nonatomic, copy) NSString *device;
@property(nonatomic, copy) NSString *type;
@property(nonatomic) uint64_t totalBytes;
@property(nonatomic) uint64_t freeBytes;
@property(nonatomic) uint64_t availableBytes;
@property(nonatomic) uint32_t flags;

@end

@interface FLInterface : NSObject

@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned flags;
@property(nonatomic, copy) NSString *hardwareAddress;
@property(nonatomic, strong) NSMutableArray<NSString *> *addresses;
@property(nonatomic) uint64_t receivedBytes;
@property(nonatomic) uint64_t sentBytes;
@property(nonatomic) uint64_t receivedPackets;
@property(nonatomic) uint64_t sentPackets;
@property(nonatomic) uint64_t receiveErrors;
@property(nonatomic) uint64_t sendErrors;

- (BOOL)isUp;
- (BOOL)isLoopback;

@end

NSString *FLSysctlString(NSString *name);
BOOL FLSysctlNumber(NSString *name, int64_t *value);
NSDate *FLBootTime(void);
NSTimeInterval FLUptime(void);
NSString *FLUserName(unsigned user);

NSArray<FLProcess *> *FLProcessList(BOOL detailed);
FLProcess *FLProcessWithIdentifier(int pid);
FLProcess *FLProcessSketch(int pid, BOOL arguments);
NSNumber *FLProcessorSecondsSpent(int pid);

NSDictionary<NSString *, NSNumber *> *FLProcessorTicks(void);
NSArray<NSDictionary<NSString *, NSNumber *> *> *FLProcessorCoreTicks(void);
NSDictionary<NSString *, NSNumber *> *FLMemoryStatistics(void);
NSArray<NSNumber *> *FLLoadAverages(void);

NSArray<FLVolume *> *FLVolumes(void);
NSArray<FLInterface *> *FLInterfaces(void);
NSDictionary *FLWirelessNetwork(void);
NSDictionary *FLBatteryProperties(void);
NSString *FLBatterySummary(NSDictionary *battery);
NSDictionary *FLBundleInfo(NSString *bundlePath);
