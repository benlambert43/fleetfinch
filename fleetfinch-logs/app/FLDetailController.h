#import "FLListController.h"

@interface FLDetailController : FLListController

- (instancetype)initWithTitle:(NSString *)title
                        pairs:(NSArray<NSArray<NSString *> *> *)pairs
                    monospace:(NSString *)monospaceField;

@end
