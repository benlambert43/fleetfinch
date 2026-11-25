#import "FLListController.h"

@interface FLInventoryItemController : FLListController

+ (NSString *)titleOf:(NSDictionary *)item;
+ (NSString *)sizeOf:(NSDictionary *)item;
- (instancetype)initWithItem:(NSDictionary *)item;

@end
