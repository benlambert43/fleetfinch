#import <Foundation/Foundation.h>

@interface FLDependencyIndex : NSObject

@property(nonatomic, strong, readonly) NSDictionary *dependencies;
@property(nonatomic, strong, readonly) NSDictionary *inventory;

- (instancetype)initWithDependencies:(NSDictionary *)dependencies
                           inventory:(NSDictionary *)inventory;
- (NSDictionary *)itemAtPath:(NSString *)path;
- (NSDictionary *)nodeAtPath:(NSString *)path;
- (NSDictionary *)nodeOfItem:(NSDictionary *)item;
- (NSDictionary *)itemOfNode:(NSDictionary *)node;
- (NSString *)nameOfNode:(NSDictionary *)node;
- (NSArray<NSDictionary *> *)usersOfNode:(NSDictionary *)node;
- (NSArray<NSDictionary *> *)openersOfNode:(NSDictionary *)node;
- (NSArray<NSDictionary *> *)clientsOfItem:(NSDictionary *)item;
- (NSArray<NSString *> *)namesOfferedBy:(NSDictionary *)item;
- (NSArray<NSDictionary *> *)relationsOfItem:(NSDictionary *)item;
- (NSArray<NSArray<NSString *> *> *)entitlementsOfItem:(NSDictionary *)item;
- (NSArray<NSDictionary *> *)itemsNamed:(NSString *)name;

@end

NSString *FLNeedText(NSString *need);
NSArray<NSString *> *FLNeedOrder(void);
