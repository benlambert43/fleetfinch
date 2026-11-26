#import <Foundation/Foundation.h>

NSString *FLReportState(NSString *kind);
NSString *FLReportCommand(NSString *kind);
NSString *FLReportNotice(NSString *kind);
NSDictionary *FLReportRow(NSString *title, NSString *detail,
                          NSArray<NSArray<NSString *> *> *facts);
NSDictionary *FLReportSection(NSString *title, NSString *note, NSArray<NSDictionary *> *rows);
NSString *FLReportText(NSDictionary *report);
NSString *FLReportCount(unsigned long long count, NSString *one, NSString *many);
