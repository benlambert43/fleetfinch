#import "FFAppsController.h"

@implementation FFAppsController

- (NSArray<FFSection *> *)buildSections {
  return @[
    [FFSection sectionWithTitle:@"Browse"
                           rows:@[
                             [FFRow rowWithTitle:@"Apps"
                                          detail:nil
                                           about:@"Apps to download and install on this device."],
                             [FFRow rowWithTitle:@"Tools"
                                          detail:nil
                                           about:@"Software tools to download and install on "
                                                 @"this device."],
                             [FFRow rowWithTitle:@"Extensions"
                                          detail:nil
                                           about:@"Extensions to download and install on this "
                                                 @"device."],
                           ]
                         footer:nil],
    [FFSection sectionWithTitle:@"On This Device"
                           rows:@[
                             [FFRow rowWithTitle:@"Installed"
                                          detail:nil
                                           about:@"What has been installed from Fleet Finch, "
                                                 @"with its updates."],
                           ]
                         footer:nil],
  ];
}

@end
