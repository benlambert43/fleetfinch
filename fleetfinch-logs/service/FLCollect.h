#import <Foundation/Foundation.h>

NSArray<NSString *> *FLCollectKinds(void);
NSString *FLCollectTitle(NSString *kind);
NSString *FLCollect(NSString *kind);
BOOL FLCollectPieces(NSString *kind, void (^write)(NSString *piece));
NSString *FLSnapshotHeading(NSString *kind, NSString *why, NSDate *taken);

NSString *FLDescribeValue(id value);
void FLEachLaunchDefinition(void (^visit)(NSDictionary *service, NSDictionary *plist));
NSArray<NSDictionary *> *FLLaunchServices(void);
NSDictionary<NSString *, NSDictionary *> *FLLaunchJobs(void);
NSArray<NSDictionary *> *FLServiceTable(NSDictionary<NSString *, NSDictionary *> *jobs,
                                        NSArray<NSDictionary *> *definitions);
NSString *FLServiceStarts(NSDictionary *service);
NSString *FLDescribeExit(NSInteger status);
NSArray<NSDictionary *> *FLInstalledApps(void);
NSArray<NSDictionary *> *FLInstalledPackages(void);
NSString *FLKernelMessages(void);
void *FLSymbol(const char *library, const char *name);
