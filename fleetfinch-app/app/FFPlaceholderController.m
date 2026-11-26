#import "FFPlaceholderController.h"

@implementation FFPlaceholderController {
  NSString *_about;
}

- (instancetype)initWithTitle:(NSString *)title about:(NSString *)about {
  self = [super init];
  if (self) {
    self.title = title;
    _about = [about copy];
  }
  return self;
}

- (NSArray<FFSection *> *)buildSections {
  return @[
    [FFSection sectionWithTitle:nil
                           rows:@[ [FFRow rowWithTitle:@"Status" detail:@"Coming soon"] ]
                         footer:_about],
  ];
}

@end
