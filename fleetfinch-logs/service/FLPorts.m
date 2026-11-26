#import "FLPorts.h"

#import <mach/mach.h>
#import <mach_debug/ipc_info.h>
#import <unistd.h>

#import "FLSystemInfo.h"

static const mach_port_type_t FLCanSend = MACH_PORT_TYPE_SEND | MACH_PORT_TYPE_SEND_ONCE;

NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *FLPortLinks(NSUInteger *looked,
                                                                              NSUInteger *closed) {
  NSMutableDictionary<NSNumber *, NSNumber *> *receivers = [NSMutableDictionary new];
  NSMutableDictionary<NSNumber *, NSString *> *programs = [NSMutableDictionary new];
  NSMutableDictionary<NSNumber *, NSData *> *held = [NSMutableDictionary new];
  for (FLProcess *process in FLProcessList(NO)) {
    @autoreleasepool {
      int pid = process.pid;
      NSString *path = FLProcessSketch(pid, NO).path;
      mach_port_t task = MACH_PORT_NULL;
      if (pid == getpid() || path.length == 0) {
        continue;
      }
      if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        *closed += 1;
        continue;
      }
      ipc_info_space_t space;
      ipc_info_name_array_t table = NULL;
      ipc_info_tree_name_array_t tree = NULL;
      mach_msg_type_number_t count = 0, treeCount = 0;
      if (mach_port_space_info(task, &space, &table, &count, &tree, &treeCount) ==
          KERN_SUCCESS) {
        NSMutableData *sends = [NSMutableData new];
        for (mach_msg_type_number_t index = 0; index < count; index++) {
          natural_t object = table[index].iin_object;
          if (object == 0) {
            continue;
          }
          if ((table[index].iin_type & MACH_PORT_TYPE_RECEIVE) != 0) {
            receivers[@(object)] = @(pid);
          }
          if ((table[index].iin_type & FLCanSend) != 0) {
            [sends appendBytes:&object length:sizeof(object)];
          }
        }
        held[@(pid)] = sends;
        programs[@(pid)] = path;
        *looked += 1;
        vm_deallocate(mach_task_self(), (vm_address_t)table, count * sizeof(*table));
        vm_deallocate(mach_task_self(), (vm_address_t)tree, treeCount * sizeof(*tree));
      } else {
        *closed += 1;
      }
      mach_port_deallocate(mach_task_self(), task);
    }
  }
  NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *links =
    [NSMutableDictionary new];
  for (NSNumber *pid in held) {
    NSData *sends = held[pid];
    const natural_t *objects = sends.bytes;
    NSString *holder = programs[pid];
    for (NSUInteger index = 0; index < sends.length / sizeof(natural_t); index++) {
      NSNumber *receiver = receivers[@(objects[index])];
      NSString *owner = receiver == nil || [receiver isEqualToNumber:pid] ? nil
                                                                           : programs[receiver];
      if (owner == nil || [owner isEqualToString:holder]) {
        continue;
      }
      NSMutableDictionary<NSString *, NSNumber *> *reached = links[holder];
      if (reached == nil) {
        reached = [NSMutableDictionary new];
        links[holder] = reached;
      }
      reached[owner] = @(reached[owner].unsignedIntegerValue + 1);
    }
  }
  return links;
}
