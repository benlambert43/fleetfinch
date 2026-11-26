#import <Foundation/Foundation.h>

extern NSString *const FLSettingArchiveAfter;
extern NSString *const FLSettingDeleteAfter;
extern NSString *const FLSettingStoreLimit;
extern NSString *const FLSettingResourceInterval;
extern NSString *const FLSettingProcessInterval;
extern NSString *const FLSettingSnapshotInterval;
extern NSString *const FLSettingImportInterval;
extern NSString *const FLSettingTraceInterval;
extern NSString *const FLSettingDisabledCollectors;

@interface FLSettings : NSObject

+ (NSDictionary *)defaults;
+ (NSDictionary *)current;
+ (double)number:(NSString *)key;
+ (BOOL)collectorEnabled:(NSString *)name;
+ (BOOL)save:(NSDictionary *)changes;

@end
