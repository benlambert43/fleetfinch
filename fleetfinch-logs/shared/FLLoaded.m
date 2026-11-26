#import "FLLoaded.h"

NSArray<NSString *> *FLLoadedBy(NSDictionary *loaded, NSString *path) {
  NSArray<NSString *> *programs = loaded[@"programs"];
  NSDictionary *libraries = loaded[@"libraries"];
  NSData *by = [libraries isKindOfClass:[NSDictionary class]] ? libraries[path ?: @""][@"by"] : nil;
  if (![by isKindOfClass:[NSData class]] || ![programs isKindOfClass:[NSArray class]]) {
    return @[];
  }
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  const uint8_t *bytes = by.bytes;
  for (NSUInteger offset = 0; offset + 1 < by.length; offset += 2) {
    NSUInteger index = bytes[offset] | ((NSUInteger)bytes[offset + 1] << 8);
    if (index < programs.count) {
      [paths addObject:programs[index]];
    }
  }
  return [paths sortedArrayUsingSelector:@selector(compare:)];
}

NSData *FLLoadedIndices(NSIndexSet *programs) {
  NSMutableData *by = [NSMutableData dataWithCapacity:programs.count * 2];
  [programs enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
    uint8_t pair[2] = {(uint8_t)(index & 0xff), (uint8_t)((index >> 8) & 0xff)};
    [by appendBytes:pair length:sizeof(pair)];
  }];
  return by;
}
