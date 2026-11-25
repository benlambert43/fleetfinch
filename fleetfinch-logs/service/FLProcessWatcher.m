#import "FLProcessWatcher.h"

#import <mach/mach.h>
#import <mach/thread_policy.h>
#import <pthread.h>
#import <sys/event.h>
#import <unistd.h>

#define FL_PROC_PPID_ONLY 6
#define FL_EVENT_BATCH 64
#define FL_CHILD_LIMIT 512

extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);

static const integer_t FLWatcherImportance = 16;

@implementation FLProcessEvent
@end

@implementation FLProcessWatcher {
  dispatch_queue_t _queue;
  void (^_handler)(NSArray<FLProcessEvent *> *events);
  NSMutableDictionary<NSNumber *, FLProcess *> *_watched;
  int _events;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                      handler:(void (^)(NSArray<FLProcessEvent *> *events))handler {
  self = [super init];
  if (self) {
    _queue = queue;
    _handler = [handler copy];
    _watched = [NSMutableDictionary new];
    _events = -1;
  }
  return self;
}

- (BOOL)watch:(int)pid {
  struct kevent change;
  EV_SET(&change, pid, EVFILT_PROC, EV_ADD, NOTE_FORK | NOTE_EXEC | NOTE_EXIT, 0, NULL);
  return kevent(_events, &change, 1, NULL, 0, NULL) == 0;
}

- (FLProcessEvent *)event:(FLProcessChange)change process:(FLProcess *)process at:(NSDate *)at {
  FLProcessEvent *event = [FLProcessEvent new];
  event.change = change;
  event.process = process;
  event.at = at;
  event.named = process.path.length > 0;
  return event;
}

- (void)became:(int)pid into:(NSMutableArray<FLProcessEvent *> *)batch {
  FLProcess *before = _watched[@(pid)];
  FLProcess *now = FLProcessSketch(pid, YES);
  NSDate *at = [NSDate date];
  if (now == nil) {
    now = [FLProcess new];
    now.pid = pid;
  }
  if (now.started == nil) {
    now.started = before.started ?: at;
    now.parent = before.parent;
    now.user = before.user;
    now.name = now.path.length > 0 ? now.path.lastPathComponent : @"";
  }
  if (now.path.length > 0) {
    _watched[@(pid)] = now;
  }
  [batch addObject:[self event:FLProcessBecame process:now at:at]];
}

- (void)forked:(int)parent into:(NSMutableArray<FLProcessEvent *> *)batch {
  NSMutableArray<NSNumber *> *parents = [NSMutableArray arrayWithObject:@(parent)];
  while (parents.count > 0) {
    int pid = parents.firstObject.intValue;
    [parents removeObjectAtIndex:0];
    int children[FL_CHILD_LIMIT];
    int bytes = proc_listpids(FL_PROC_PPID_ONLY, (uint32_t)pid, children, sizeof(children));
    int found = bytes > 0 ? bytes / (int)sizeof(int) : 0;
    for (int index = 0; index < found; index++) {
      int child = children[index];
      if (child <= 0 || _watched[@(child)] != nil) {
        continue;
      }
      BOOL watching = [self watch:child];
      FLProcess *process = FLProcessSketch(child, NO);
      NSDate *at = [NSDate date];
      FLProcess *origin = _watched[@(pid)];
      BOOL copy = process.path.length > 0 && [process.path isEqualToString:origin.path];
      if (process == nil) {
        process = [FLProcess new];
        process.pid = child;
        process.parent = pid;
        process.started = at;
        process.name = @"";
      }
      if (process.path.length > 0) {
        NSArray<NSString *> *own = FLProcessSketch(child, YES).arguments;
        copy = copy && (own.count == 0 || [own isEqualToArray:origin.arguments]);
        process.arguments = copy ? origin.arguments : own;
      }
      FLProcessEvent *event = [self event:FLProcessAppeared process:process at:at];
      event.clone = copy;
      [batch addObject:event];
      if (watching && process.path.length > 0) {
        _watched[@(child)] = process;
        [parents addObject:@(child)];
      } else {
        [batch addObject:[self event:FLProcessExited process:process at:at]];
      }
    }
  }
}

- (void)exited:(int)pid into:(NSMutableArray<FLProcessEvent *> *)batch {
  FLProcess *process = _watched[@(pid)];
  if (process == nil) {
    return;
  }
  FLProcessEvent *event = [self event:FLProcessExited process:process at:[NSDate date]];
  event.processor = FLProcessorSecondsSpent(pid);
  [batch addObject:event];
  [_watched removeObjectForKey:@(pid)];
}

- (void)run {
  thread_extended_policy_data_t steady = {.timeshare = FALSE};
  thread_policy_set(mach_thread_self(), THREAD_EXTENDED_POLICY, (thread_policy_t)&steady,
                    THREAD_EXTENDED_POLICY_COUNT);
  thread_precedence_policy_data_t above = {.importance = FLWatcherImportance};
  thread_policy_set(mach_thread_self(), THREAD_PRECEDENCE_POLICY, (thread_policy_t)&above,
                    THREAD_PRECEDENCE_POLICY_COUNT);
  for (FLProcess *process in FLProcessList(NO)) {
    @autoreleasepool {
      if ([self watch:process.pid]) {
        _watched[@(process.pid)] = FLProcessSketch(process.pid, YES) ?: process;
      }
    }
  }
  for (;;) {
    struct kevent events[FL_EVENT_BATCH];
    int count = kevent(_events, NULL, 0, events, FL_EVENT_BATCH, NULL);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      return;
    }
    @autoreleasepool {
      NSMutableArray<FLProcessEvent *> *batch = [NSMutableArray new];
      for (int index = 0; index < count; index++) {
        if (events[index].fflags & NOTE_EXEC) {
          [self became:(int)events[index].ident into:batch];
        }
      }
      for (int index = 0; index < count; index++) {
        if (events[index].fflags & NOTE_FORK) {
          [self forked:(int)events[index].ident into:batch];
        }
      }
      for (int index = 0; index < count; index++) {
        if (events[index].fflags & NOTE_EXIT) {
          [self exited:(int)events[index].ident into:batch];
        }
      }
      if (batch.count > 0) {
        void (^handler)(NSArray<FLProcessEvent *> *) = _handler;
        dispatch_async(_queue, ^{
          handler(batch);
        });
      }
    }
  }
}

static void *FLWatcherMain(void *context) {
  pthread_setname_np("com.fleetfinch.logs.processes");
  FLProcessWatcher *watcher = (__bridge_transfer FLProcessWatcher *)context;
  [watcher run];
  return NULL;
}

- (BOOL)start {
  if (_events >= 0) {
    return YES;
  }
  _events = kqueue();
  if (_events < 0) {
    return NO;
  }
  pthread_t thread;
  if (pthread_create(&thread, NULL, FLWatcherMain, (__bridge_retained void *)self) != 0) {
    close(_events);
    _events = -1;
    return NO;
  }
  pthread_detach(thread);
  return YES;
}

@end
