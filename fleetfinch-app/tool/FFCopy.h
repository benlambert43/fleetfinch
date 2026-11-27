#import <Foundation/Foundation.h>

extern NSString *const FFPartSuffix;

NSString *FFCopyTree(NSString *from, NSString *to);
BOOL FFSameTree(NSString *first, NSString *second);
BOOL FFIsInside(NSString *path, NSString *folder);
NSString *FFCleanPath(NSString *word);
BOOL FFOnSystemVolume(NSString *path);
void FFPruneEmptyFolders(NSString *folder, NSString *stop);
