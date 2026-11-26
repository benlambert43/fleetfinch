#import "FFSettingsController.h"

@implementation FFSettingsController

- (NSArray<FFSection *> *)buildSections {
  NSDictionary *info = [NSBundle mainBundle].infoDictionary;
  return @[
    [FFSection sectionWithTitle:@"Device"
                           rows:@[
                             [FFRow rowWithTitle:@"More Settings"
                                          detail:nil
                                           about:@"Settings for this device that the stock "
                                                 @"Settings app does not have."],
                           ]
                         footer:nil],
    [FFSection sectionWithTitle:@"About"
                           rows:@[
                             [FFRow rowWithTitle:@"Version"
                                          detail:info[@"CFBundleShortVersionString"]],
                             [FFRow rowWithTitle:@"Build" detail:info[@"CFBundleVersion"]],
                           ]
                         footer:nil],
  ];
}

@end
