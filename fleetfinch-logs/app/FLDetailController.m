#import "FLDetailController.h"

@implementation FLDetailController {
  NSArray<NSArray<NSString *> *> *_pairs;
  NSString *_monospace;
}

- (instancetype)initWithTitle:(NSString *)title
                        pairs:(NSArray<NSArray<NSString *> *> *)pairs
                    monospace:(NSString *)monospaceField {
  self = [super initGrouped:YES];
  if (self) {
    self.title = title;
    _pairs = [pairs copy];
    _monospace = [monospaceField copy];
    self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Copy"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(copyAll)];
  }
  return self;
}

- (void)copyAll {
  NSMutableArray *lines = [NSMutableArray new];
  for (NSArray<NSString *> *pair in _pairs) {
    [lines addObject:[NSString stringWithFormat:@"%@: %@", pair[0], pair[1]]];
  }
  [UIPasteboard generalPasteboard].string = [lines componentsJoinedByString:@"\n"];
  [self showMessage:@"Everything on this screen was copied." title:nil];
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  for (NSArray<NSString *> *pair in _pairs) {
    if (pair.count < 2 || pair[1].length == 0) {
      continue;
    }
    FLRow *row = [section add:pair[0] detail:pair[1]];
    if ([pair[0] isEqualToString:_monospace]) {
      row.stacked = YES;
      row.monospace = YES;
    }
  }
  section.footer = @"Touch and hold a row to copy it.";
  return @[ section ];
}

@end
