#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, FFIcon) {
  FFIconHome = 0,
  FFIconUtilities,
  FFIconApps,
  FFIconSettings,
};

UIColor *FFTintColor(void);
UIColor *FFMutedColor(void);
UIImage *FFTabIcon(FFIcon icon);
