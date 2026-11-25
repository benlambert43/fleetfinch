#import <Foundation/Foundation.h>

#import "FLSystemInfo.h"

@interface FLUsageLedger : NSObject

- (instancetype)initForBoot:(NSString *)boot;
- (void)began:(FLProcess *)process label:(NSString *)label starter:(NSString *)starter;
- (void)began:(FLProcess *)process
        label:(NSString *)label
      starter:(NSString *)starter
         from:(NSDate *)from
           at:(NSDate *)now;
- (void)passed:(FLProcess *)process
       starter:(NSString *)starter
          from:(NSDate *)from
            to:(NSDate *)to;
- (void)missed:(NSString *)starter at:(NSDate *)when;
- (void)rebase:(FLProcess *)process processor:(double)processor;
- (void)seen:(FLProcess *)process;
- (void)ended:(FLProcess *)process processor:(NSNumber *)processor memory:(NSNumber *)memory;
- (void)ended:(FLProcess *)process
    processor:(NSNumber *)processor
       memory:(NSNumber *)memory
           at:(NSDate *)when;
- (void)keepOnly:(NSSet<NSString *> *)identities;
- (void)service:(NSString *)label endedWith:(NSString *)ending;
- (NSDictionary *)contents;
- (BOOL)saveIfDue;
- (BOOL)save;

@end

void FLSetUsageLedger(FLUsageLedger *ledger);
NSDictionary *FLCurrentUsage(void);
NSString *FLServiceFamily(NSString *label);
NSString *FLScriptOf(FLProcess *process);
NSString *FLBundledServiceIdentifier(NSString *path);
NSString *FLBundledServiceLabel(NSString *path);
NSDictionary *FLUsageReport(NSDictionary *usage);
NSString *FLUsageText(NSDictionary *report, BOOL neverOnly);
BOOL FLWriteUsageReport(NSDictionary *report);
