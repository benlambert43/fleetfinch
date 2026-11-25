#import "FLListController.h"

@interface FLUsageController : FLListController

+ (NSDictionary *)report;
+ (void)ask;
- (instancetype)initWithKind:(NSString *)kind neverOnly:(BOOL)neverOnly;

@end
