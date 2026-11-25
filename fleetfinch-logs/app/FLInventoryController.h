#import "FLListController.h"

@class FLDependencyIndex;

@interface FLInventoryController : FLListController

+ (NSDictionary *)inventory;
+ (FLDependencyIndex *)index;
+ (NSDate *)listed;

@end
