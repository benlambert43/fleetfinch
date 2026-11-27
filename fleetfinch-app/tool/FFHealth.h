#import <Foundation/Foundation.h>

extern NSString *const FFReachHome;
extern NSString *const FFReachShell;
extern NSString *const FFReachNetwork;
extern NSString *const FFReachCalm;
extern NSString *const FFReachSteady;

NSDictionary<NSString *, NSNumber *> *FFReach(void);
NSString *FFReachMissing(NSDictionary *before, NSDictionary *now);
NSString *FFReachSentence(NSDictionary *reach);
NSArray<NSNumber *> *FFProcessesUnder(NSString *path);
NSDate *FFBootTime(void);
double FFBusyShare(unsigned seconds);
void FFRunAboveOthers(void);
void FFKeepInMemory(uint32_t megabytes);
