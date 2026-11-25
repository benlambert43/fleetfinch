#import "FLListController.h"

@interface FLFilesController : FLListController

- (instancetype)initWithGroup:(NSString *)group
                        title:(NSString *)title
                       stream:(NSString *)stream;
- (instancetype)initWithFolder:(NSString *)folder title:(NSString *)title;

@end
