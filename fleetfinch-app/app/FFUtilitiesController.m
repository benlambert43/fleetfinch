#import "FFUtilitiesController.h"

@implementation FFUtilitiesController

- (NSArray<FFSection *> *)buildSections {
  return @[
    [FFSection sectionWithTitle:@"Progress"
                           rows:@[
                             [FFRow rowWithTitle:@"Stock apps and services" detail:@"Not checked"],
                             [FFRow rowWithTitle:@"Cydia" detail:@"Not checked"],
                             [FFRow rowWithTitle:@"Patches" detail:@"Not checked"],
                             [FFRow rowWithTitle:@"Updates" detail:@"Not checked"],
                           ]
                         footer:@"This will sum up what Fleet Finch has removed, patched and "
                                @"installed on this device, and what is left to do."],
    [FFSection
      sectionWithTitle:@"Clean Up"
                  rows:@[
                    [FFRow rowWithTitle:@"Stock Apps and Services"
                                 detail:nil
                                  about:@"Removes as many of the stock apps and stock services as "
                                        @"the device can run without."],
                    [FFRow rowWithTitle:@"Cydia"
                                 detail:nil
                                  about:@"Removes the Cydia app and the software components that "
                                        @"come with it."],
                  ]
                footer:nil],
    [FFSection
      sectionWithTitle:@"Patch"
                  rows:@[
                    [FFRow rowWithTitle:@"System Dependencies"
                                 detail:nil
                                  about:@"Lifts what the device depends on from the stock system "
                                        @"and from Cydia's tooling into Fleet Finch, then tracks "
                                        @"and updates it here."],
                    [FFRow rowWithTitle:@"Software Updates"
                                 detail:nil
                                  about:@"Updates as much of the software on the device as "
                                        @"possible, including its certificates and Safari."],
                  ]
                footer:nil],
  ];
}

@end
