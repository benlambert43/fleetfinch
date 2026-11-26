#import <UIKit/UIKit.h>

@interface FFRow : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *about;

+ (instancetype)rowWithTitle:(NSString *)title detail:(NSString *)detail;
+ (instancetype)rowWithTitle:(NSString *)title
                      detail:(NSString *)detail
                       about:(NSString *)about;

@end

@interface FFSection : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *footer;
@property(nonatomic, copy) NSArray<FFRow *> *rows;

+ (instancetype)sectionWithTitle:(NSString *)title
                            rows:(NSArray<FFRow *> *)rows
                          footer:(NSString *)footer;

@end

@interface FFListController : UITableViewController

- (NSArray<FFSection *> *)buildSections;
- (void)reload;

@end
