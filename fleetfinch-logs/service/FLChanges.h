#import <Foundation/Foundation.h>

#import "FLReports.h"

extern NSString *const FLHeldFolder;

int FLChangeCommand(NSString *verb, NSArray<NSString *> *arguments, dispatch_block_t save);
NSDictionary *FLChangesReport(FLReportSource source);
BOOL FLRestoreChange(NSNumber *identifier, NSString *why);
void FLWatchChanges(dispatch_queue_t queue);
NSSet<NSString *> *FLPathsKept(FLReportSource source);
BOOL FLPathIsKept(NSString *path, NSString *program, NSSet<NSString *> *kept);
