#import <Foundation/Foundation.h>

#import "FLReports.h"

int FLTraceCommand(NSArray<NSString *> *arguments);
BOOL FLTraceRelease(void);
NSDictionary *FLCallsReport(FLReportSource source);
NSDictionary *FLFilesReport(FLReportSource source);
NSDictionary *FLTalksReport(FLReportSource source);
