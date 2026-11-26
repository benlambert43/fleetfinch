#import <Foundation/Foundation.h>

@interface FLImage : NSObject

@property(nonatomic) uint32_t fileType;
@property(nonatomic, copy) NSString *installName;
@property(nonatomic, strong) NSArray<NSString *> *links;
@property(nonatomic, strong) NSArray<NSString *> *weakLinks;
@property(nonatomic, strong) NSArray<NSString *> *searchPaths;
@property(nonatomic) uint64_t segmentBytes;
@property(nonatomic) uint64_t stringsAddress;
@property(nonatomic) uint64_t stringsOffset;
@property(nonatomic) uint64_t stringsSize;
@property(nonatomic) uint64_t signatureOffset;
@property(nonatomic) uint64_t signatureSize;
@property(nonatomic) BOOL encrypted;

- (BOOL)isProgram;
- (BOOL)isPlugIn;

@end

@interface FLSharedCache : NSObject

@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) int handle;
@property(nonatomic, readonly) uint64_t bytes;
@property(nonatomic, strong, readonly) NSArray<NSDictionary *> *images;

+ (NSArray<FLSharedCache *> *)caches;
- (BOOL)offset:(uint64_t *)offset ofAddress:(uint64_t)address;
- (void)settle;

@end

@interface FLNameSet : NSObject

- (instancetype)initWithNames:(NSArray<NSString *> *)names;
- (void)scan:(int)handle
      offset:(uint64_t)offset
        size:(uint64_t)size
        into:(NSMutableIndexSet *)found;

@end

FLImage *FLReadImage(int handle, uint64_t offset);
FLImage *FLReadImageFile(int handle);
NSDictionary *FLReadEntitlements(int handle, FLImage *image);
