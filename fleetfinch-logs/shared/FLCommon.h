#import <Foundation/Foundation.h>

extern NSString *const FLVersion;
extern NSString *const FLRootPath;
extern NSString *const FLDaemonLabel;
extern NSString *const FLAppIdentifier;

extern NSString *const FLCommandSnapshot;
extern NSString *const FLCommandImport;
extern NSString *const FLCommandMaintain;
extern NSString *const FLCommandSettings;
extern NSString *const FLCommandWatch;
extern NSString *const FLCommandUsage;
extern NSString *const FLNoticeChanged;
extern NSString *const FLNoticeUsage;
extern NSString *const FLUsageState;
extern NSString *const FLUsageReportState;
extern NSString *const FLNoticeSleeping;

typedef NS_ENUM(NSInteger, FLLevel) {
  FLLevelDebug = 0,
  FLLevelInfo,
  FLLevelNotice,
  FLLevelWarning,
  FLLevelError,
  FLLevelFault,
};

NSString *FLLivePath(void);
NSString *FLArchivePath(void);
NSString *FLStatePath(void);
NSString *FLSettingsPath(void);

NSString *FLLevelLetter(FLLevel level);
NSString *FLLevelName(FLLevel level);
FLLevel FLLevelFromLetter(NSString *letter);

NSString *FLTimestamp(NSDate *date);
NSDate *FLDateFromTimestamp(NSString *text);
NSString *FLHourKey(NSDate *date);
NSString *FLMomentKey(NSDate *date);

NSString *FLEscape(NSString *text);
NSString *FLUnescape(NSString *text);

NSString *FLFormatBytes(uint64_t bytes);
NSString *FLFormatDuration(NSTimeInterval seconds);
NSString *FLFormatClock(NSDate *date);
NSString *FLFormatDay(NSDate *date);

NSString *FLStringFromData(NSData *data);
BOOL FLMakeDirectory(NSString *path);
uint64_t FLFileSize(NSString *path);
NSDate *FLFileModified(NSString *path);
