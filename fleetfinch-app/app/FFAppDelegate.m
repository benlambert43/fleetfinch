#import "FFAppDelegate.h"

#import "FFAppsController.h"
#import "FFHomeController.h"
#import "FFSettingsController.h"
#import "FFTheme.h"
#import "FFUtilitiesController.h"

@implementation FFAppDelegate

- (UIViewController *)tab:(UIViewController *)root title:(NSString *)title icon:(FFIcon)icon {
  root.title = title;
  UINavigationController *navigation =
    [[UINavigationController alloc] initWithRootViewController:root];
  navigation.tabBarItem = [[UITabBarItem alloc] initWithTitle:title
                                                        image:FFTabIcon(icon)
                                                          tag:(NSInteger)icon];
  return navigation;
}

- (BOOL)application:(UIApplication *)application
  didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.tintColor = FFTintColor();
  UITabBarController *tabs = [UITabBarController new];
  tabs.viewControllers = @[
    [self tab:[FFHomeController new] title:@"Home" icon:FFIconHome],
    [self tab:[FFUtilitiesController new] title:@"Utilities" icon:FFIconUtilities],
    [self tab:[FFAppsController new] title:@"Apps" icon:FFIconApps],
    [self tab:[FFSettingsController new] title:@"Settings" icon:FFIconSettings],
  ];
  self.window.rootViewController = tabs;
  [self.window makeKeyAndVisible];
  return YES;
}

@end
