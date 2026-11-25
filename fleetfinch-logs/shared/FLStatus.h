#import <Foundation/Foundation.h>

NSDictionary *FLReadState(NSString *name);
void FLWriteState(NSString *name, NSDictionary *state);
BOOL FLWriteCompactState(NSString *name, NSDictionary *state);
NSDate *FLStateWritten(NSString *name);

NSDictionary *FLServiceStatus(void);
NSDictionary *FLServiceLive(void);
BOOL FLServiceRunning(NSDictionary *status);
void FLPostCommand(NSString *name);
void FLMarkGoingToSleep(BOOL sleeping);
BOOL FLGoingToSleep(void);
