#import "FLSettings.h"

#import "FLCommon.h"

NSString *const FLSettingArchiveAfter = @"ArchiveAfterSeconds";
NSString *const FLSettingDeleteAfter = @"DeleteAfterSeconds";
NSString *const FLSettingStoreLimit = @"StoreLimitBytes";
NSString *const FLSettingResourceInterval = @"ResourceIntervalSeconds";
NSString *const FLSettingProcessInterval = @"ProcessIntervalSeconds";
NSString *const FLSettingSnapshotInterval = @"SnapshotIntervalSeconds";
NSString *const FLSettingImportInterval = @"ImportIntervalSeconds";
NSString *const FLSettingDisabledCollectors = @"DisabledCollectors";

@implementation FLSettings

+ (NSDictionary *)defaults {
  return @{
    FLSettingArchiveAfter : @(24 * 60 * 60),
    FLSettingDeleteAfter : @(7 * 24 * 60 * 60),
    FLSettingStoreLimit : @(1024.0 * 1024.0 * 1024.0),
    FLSettingResourceInterval : @30,
    FLSettingProcessInterval : @5,
    FLSettingSnapshotInterval : @(24 * 60 * 60),
    FLSettingImportInterval : @300,
    FLSettingDisabledCollectors : @[],
  };
}

+ (NSDictionary *)current {
  NSMutableDictionary *settings = [[self defaults] mutableCopy];
  NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:FLSettingsPath()];
  [saved enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    id standard = settings[key];
    BOOL number = [standard isKindOfClass:[NSNumber class]] &&
                  [value isKindOfClass:[NSNumber class]];
    BOOL list = [standard isKindOfClass:[NSArray class]] &&
                [value isKindOfClass:[NSArray class]];
    if (number || list) {
      settings[key] = value;
    }
  }];
  return settings;
}

+ (double)number:(NSString *)key {
  id value = [self current][key];
  return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.0;
}

+ (BOOL)collectorEnabled:(NSString *)name {
  NSArray *disabled = [self current][FLSettingDisabledCollectors];
  return ![disabled containsObject:name];
}

+ (BOOL)save:(NSDictionary *)changes {
  NSMutableDictionary *saved =
    [[NSDictionary dictionaryWithContentsOfFile:FLSettingsPath()] mutableCopy]
      ?: [NSMutableDictionary new];
  [saved addEntriesFromDictionary:changes];
  FLMakeDirectory(FLRootPath);
  return [saved writeToFile:FLSettingsPath() atomically:YES];
}

@end
