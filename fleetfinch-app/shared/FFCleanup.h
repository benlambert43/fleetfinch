#import <Foundation/Foundation.h>

extern NSString *const FFManifestPath;
extern NSString *const FFStateFolder;
extern NSString *const FFRemovedFolder;
extern NSString *const FFBatchFolder;
extern NSString *const FFJournalPath;
extern NSString *const FFProgressPath;
extern NSString *const FFRequestFolder;
extern NSString *const FFCleanupChanged;
extern NSString *const FFVerbRemove;
extern NSString *const FFVerbRestore;

typedef NS_ENUM(NSInteger, FFItemState) {
  FFItemPresent = 0,
  FFItemRemoved,
  FFItemAbsent,
};

@interface FFCleanupGroup : NSObject

@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *about;
@property(nonatomic, copy) NSArray<NSString *> *paths;

@end

@interface FFCleanupCount : NSObject

@property(nonatomic) NSUInteger present;
@property(nonatomic) NSUInteger removed;
@property(nonatomic) NSUInteger absent;
@property(nonatomic) uint64_t presentBytes;
@property(nonatomic) uint64_t removedBytes;

- (void)add:(FFCleanupCount *)other;

@end

NSArray<FFCleanupGroup *> *FFCleanupGroups(void);
NSArray<NSDictionary *> *FFCleanupTested(void);
NSString *FFKeptPath(NSString *path);
FFItemState FFStateOfPath(NSString *path);
uint64_t FFSpaceTaken(NSString *path, NSUInteger *entries, uint64_t *length);
FFCleanupCount *FFCountGroup(FFCleanupGroup *group, BOOL measure);
NSDictionary *FFReadJournal(void);
NSDictionary *FFReadProgress(void);
NSString *FFSendRequest(NSString *verb, NSArray<NSString *> *groups);
uint64_t FFRoomAt(NSString *path);
NSString *FFFormatBytes(uint64_t bytes);
NSString *FFFormatDay(NSDate *date);
NSString *FFDeviceModel(void);
NSString *FFHardwareValue(NSString *key);
NSString *FFSystemVersion(void);
BOOL FFDeviceIsTested(void);
