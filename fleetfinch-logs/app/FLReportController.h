#import "FLListController.h"

@interface FLReportController : FLListController

+ (NSArray<NSArray<NSString *> *> *)kinds;
- (instancetype)initWithKind:(NSString *)kind title:(NSString *)title;

@end
