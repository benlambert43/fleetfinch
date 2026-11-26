#import "FFHomeController.h"

@implementation FFHomeController

- (NSArray<FFSection *> *)buildSections {
  UIDevice *device = [UIDevice currentDevice];
  return @[
    [FFSection sectionWithTitle:@"This Device"
                           rows:@[
                             [FFRow rowWithTitle:@"Name" detail:device.name],
                             [FFRow rowWithTitle:@"Model" detail:device.model],
                             [FFRow rowWithTitle:@"iOS" detail:device.systemVersion],
                           ]
                         footer:nil],
  ];
}

@end
