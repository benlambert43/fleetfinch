#import "FLAppDelegate.h"

#import "FLLogsController.h"
#import "FLOverviewController.h"
#import "FLProcessesController.h"
#import "FLServicesController.h"
#import "FLSettingsController.h"
#import "FLTheme.h"

@implementation FLAppDelegate

- (UIViewController *)tab:(UIViewController *)root title:(NSString *)title icon:(FLIcon)icon {
  UINavigationController *navigation =
    [[UINavigationController alloc] initWithRootViewController:root];
  navigation.tabBarItem = [[UITabBarItem alloc] initWithTitle:title
                                                        image:FLTabIcon(icon)
                                                          tag:(NSInteger)icon];
  return navigation;
}

- (BOOL)application:(UIApplication *)application
  didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.tintColor = FLTintColor();
  UITabBarController *tabs = [UITabBarController new];
  tabs.viewControllers = @[
    [self tab:[FLOverviewController new] title:@"Overview" icon:FLIconOverview],
    [self tab:[FLLogsController new] title:@"Logs" icon:FLIconLogs],
    [self tab:[FLProcessesController new] title:@"Processes" icon:FLIconProcesses],
    [self tab:[FLServicesController new] title:@"Services" icon:FLIconServices],
    [self tab:[FLSettingsController new] title:@"Settings" icon:FLIconSettings],
  ];
  self.window.rootViewController = tabs;
  [self.window makeKeyAndVisible];
  return YES;
}

@end
