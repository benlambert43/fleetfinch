#import "FLCommon.h"

extern NSString *const FLSnapshotFolder;
extern NSString *const FLImportFolder;

@interface FLStore : NSObject

@property(atomic, copy) NSSet<NSString *> *disabledStreams;

+ (instancetype)shared;

- (BOOL)prepare;
- (void)log:(NSString *)stream
      level:(FLLevel)level
     source:(NSString *)source
    message:(NSString *)message;
- (void)log:(NSString *)stream
      level:(FLLevel)level
     source:(NSString *)source
    message:(NSString *)message
       date:(NSDate *)date;
- (NSString *)saveSnapshot:(NSString *)kind
                    pieces:(BOOL (^)(void (^write)(NSString *piece)))pieces;
- (NSString *)importFile:(NSString *)path folder:(NSString *)folder;
- (NSDictionary *)maintain;
- (NSDictionary *)counts;
- (void)sync;

@end

BOOL FLGzipFile(NSString *source, NSString *target, BOOL merge);
NSDictionary *FLStoreUsage(void);
NSDate *FLNewestLogWrite(void);
