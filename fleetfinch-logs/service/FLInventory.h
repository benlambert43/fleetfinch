#import <Foundation/Foundation.h>

NSArray<NSString *> *FLInventoryKinds(void);
NSString *FLInventoryKindTitle(NSString *kind);
NSString *FLInventoryKindNamed(NSString *word);
NSDictionary *FLGatherInventory(void);
BOOL FLSaveInventory(NSDictionary *inventory);
NSString *FLInventoryText(NSDictionary *inventory, NSString *kind);
NSString *FLInventorySummary(NSDictionary *inventory);
NSString *FLInventoryMarks(void);
NSString *FLOriginOf(NSDictionary<NSString *, NSString *> *owners, NSArray<NSString *> *paths);
