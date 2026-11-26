#import <Foundation/Foundation.h>

#import "FLReports.h"

NSDictionary *FLTouchedReport(FLReportSource source);
int FLTouchedCommand(NSArray<NSString *> *arguments);
NSDictionary *FLReadingUnder(NSString *path, NSDictionary *inventory);
NSString *FLLastReadText(NSDate *last, NSDictionary *reading);
NSString *FLLastReadSentence(long long last, NSDictionary *reading);
