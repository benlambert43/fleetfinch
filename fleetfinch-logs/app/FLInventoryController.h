#import "FLListController.h"

@class FLDependencyIndex;

@interface FLInventoryController : FLListController

+ (NSDictionary *)inventory;
+ (NSDictionary *)startup;
+ (FLDependencyIndex *)index;
+ (NSDate *)listed;

@end
