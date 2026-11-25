#import "FLCommon.h"

@interface FLLogFile : NSObject

@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *group;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL archived;
@property(nonatomic) uint64_t size;
@property(nonatomic, strong) NSDate *modified;

@end

@interface FLRecord : NSObject

@property(nonatomic, copy) NSString *stream;
@property(nonatomic, strong) NSDate *date;
@property(nonatomic) FLLevel level;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSString *message;

+ (instancetype)recordFromLine:(NSString *)line stream:(NSString *)stream;

@end

@interface FLReader : NSObject

+ (NSArray<NSString *> *)streams;
+ (NSArray<NSString *> *)groupsUnder:(NSString *)folder;
+ (NSArray<FLLogFile *> *)filesInGroup:(NSString *)group;
+ (NSArray<FLLogFile *> *)liveFilesInGroup:(NSString *)group;
+ (NSArray<NSString *> *)knownStreams;
+ (NSString *)streamTitle:(NSString *)stream;
+ (NSString *)streamDescription:(NSString *)stream;
+ (NSData *)dataOfFile:(NSString *)path tail:(NSUInteger)maximum;
+ (NSData *)startOfFile:(NSString *)path limit:(NSUInteger)limit;
+ (NSArray<NSString *> *)linesOfFile:(NSString *)path tail:(NSUInteger)maximum;
+ (NSArray<FLRecord *> *)recordsOfFile:(NSString *)path
                               stream:(NSString *)stream
                                 tail:(NSUInteger)maximum;
+ (NSArray<FLRecord *> *)tailOfStream:(NSString *)stream count:(NSUInteger)count;
+ (NSDictionary *)readAfterCursor:(NSString *)cursor
                          streams:(NSArray<NSString *> *)streams
                            limit:(NSUInteger)limit;

@end
