#import <UIKit/UIKit.h>

#import "FLCommon.h"

typedef NS_ENUM(NSInteger, FLIcon) {
  FLIconOverview = 0,
  FLIconLogs,
  FLIconProcesses,
  FLIconServices,
  FLIconSettings,
};

UIColor *FLTintColor(void);
UIColor *FLInkColor(void);
UIColor *FLMutedColor(void);
UIColor *FLFaintColor(void);
UIColor *FLDangerColor(void);
UIColor *FLLevelColor(FLLevel level);
UIFont *FLMonoFont(CGFloat size);
UIImage *FLTabIcon(FLIcon icon);
NSString *FLAgo(NSDate *date);
NSString *FLPercent(double value);
NSString *FLCount(NSUInteger count, NSString *noun);
