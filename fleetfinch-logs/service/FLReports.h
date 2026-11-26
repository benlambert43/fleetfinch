#import <Foundation/Foundation.h>

typedef NSDictionary * (^FLReportSource)(NSString *name);

NSArray<NSString *> *FLReportKinds(void);
NSArray<NSString *> *FLLiveReportKinds(void);
NSArray<NSString *> *FLTracedReportKinds(void);
NSString *FLReportTitle(NSString *kind);
NSString *FLReportKindNamed(NSString *word);
NSDictionary *FLBuildReport(NSString *kind, FLReportSource source);
void FLSetReportSource(FLReportSource source);
FLReportSource FLCurrentReportSource(void);
