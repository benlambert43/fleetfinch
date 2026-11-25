#import <UIKit/UIKit.h>

#import "FLReader.h"

@interface FLLogViewController : UIViewController

- (instancetype)initWithStream:(NSString *)stream;
- (instancetype)initWithFile:(FLLogFile *)file stream:(NSString *)stream;

@end
