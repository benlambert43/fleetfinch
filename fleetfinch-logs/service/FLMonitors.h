#import <Foundation/Foundation.h>

#import "FLCommon.h"
#import "FLStatus.h"
#import "FLUsage.h"

void FLNote(NSString *stream, FLLevel level, NSString *source, NSString *format, ...)
  NS_FORMAT_FUNCTION(4, 5);

@interface FLSyslogMonitor : NSObject

@property(atomic, readonly) BOOL connected;
@property(atomic, readonly) NSUInteger received;
@property(atomic, copy) void (^troubled)(NSString *sender, int pid, FLLevel level);

- (void)start;
- (void)stop;

@end

@interface FLKernelMonitor : NSObject

@property(nonatomic, copy) NSString *seen;

- (void)poll;

@end

@interface FLProcessMonitor : NSObject

@property(nonatomic, strong) FLUsageLedger *ledger;

- (void)poll;
- (void)watchOnQueue:(dispatch_queue_t)queue;
- (void)checkApps;
- (void)sampleUsage:(BOOL)record;
- (NSArray<NSDictionary *> *)liveProcesses;
- (NSString *)frontApp;
- (NSUInteger)processCount;
- (NSString *)serviceLabelForProcess:(int)pid;
- (NSArray<NSDictionary *> *)services;
- (NSUInteger)servicesVersion;
- (NSUInteger)serviceCount;
- (NSUInteger)runningServiceCount;

@end

@interface FLResourceMonitor : NSObject

- (void)sample:(BOOL)record;
- (NSDictionary *)latest;

@end

@interface FLPowerMonitor : NSObject

@property(nonatomic, copy) void (^woke)(void);

- (void)start;
- (void)checkBattery;

@end

@interface FLNetworkMonitor : NSObject

- (void)check;

@end

@interface FLTrafficMonitor : NSObject

- (void)startOnQueue:(dispatch_queue_t)queue;
- (void)refresh;
- (NSDictionary *)contents;
- (BOOL)saveIfDue;
- (BOOL)save;

@end

@interface FLLoadedMonitor : NSObject

- (void)startOnQueue:(dispatch_queue_t)queue;
- (void)sweep;
- (void)noticed:(FLProcess *)process after:(NSTimeInterval)delay;
- (NSDictionary *)contents;
- (BOOL)saveIfDue;
- (BOOL)save;

@end

@interface FLEventMonitor : NSObject

- (void)startOnQueue:(dispatch_queue_t)queue
            network:(void (^)(void))network
              power:(void (^)(void))power
               apps:(void (^)(void))apps;

@end

@interface FLImportMonitor : NSObject

@property(nonatomic, copy) void (^reported)(NSString *name, NSString *kind, NSString *path);

- (NSDictionary *)scan;

@end
