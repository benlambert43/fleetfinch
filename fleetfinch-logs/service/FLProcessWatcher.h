#import <Foundation/Foundation.h>

#import "FLSystemInfo.h"

typedef NS_ENUM(NSInteger, FLProcessChange) {
  FLProcessAppeared = 0,
  FLProcessBecame,
  FLProcessExited,
};

@interface FLProcessEvent : NSObject

@property(nonatomic) FLProcessChange change;
@property(nonatomic, strong) FLProcess *process;
@property(nonatomic, strong) NSDate *at;
@property(nonatomic) BOOL clone;
@property(nonatomic) BOOL named;
@property(nonatomic, strong) NSNumber *processor;

@end

@interface FLProcessWatcher : NSObject

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                      handler:(void (^)(NSArray<FLProcessEvent *> *events))handler;
- (BOOL)start;

@end
