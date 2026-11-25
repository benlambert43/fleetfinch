#import <UIKit/UIKit.h>

@interface FLRow : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) BOOL stacked;
@property(nonatomic) BOOL monospace;
@property(nonatomic) BOOL button;
@property(nonatomic) BOOL destructive;
@property(nonatomic) BOOL disclosure;
@property(nonatomic) BOOL checked;
@property(nonatomic) BOOL dimmed;
@property(nonatomic, strong) UIColor *titleColor;
@property(nonatomic, strong) UIView *accessory;
@property(nonatomic, copy) void (^action)(void);

+ (instancetype)rowWithTitle:(NSString *)title detail:(NSString *)detail;
+ (instancetype)linkWithTitle:(NSString *)title
                       detail:(NSString *)detail
                       action:(void (^)(void))action;
+ (instancetype)buttonWithTitle:(NSString *)title action:(void (^)(void))action;

@end

@interface FLSection : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *footer;
@property(nonatomic, strong) NSMutableArray<FLRow *> *rows;

+ (instancetype)sectionWithTitle:(NSString *)title;
- (FLRow *)add:(NSString *)title detail:(NSString *)detail;
- (void)addRow:(FLRow *)row;

@end

@interface FLListController : UITableViewController

@property(nonatomic) NSTimeInterval refreshInterval;
@property(nonatomic) BOOL watchesService;
@property(nonatomic, copy, readonly) NSArray<FLSection *> *sections;

- (instancetype)initGrouped:(BOOL)grouped;
- (NSArray<FLSection *> *)buildSections;
- (void)reload;
- (void)showMessage:(NSString *)message title:(NSString *)title;

@end
