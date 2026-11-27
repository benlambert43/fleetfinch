#import "FFArrangement.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>

#import "FFCleanup.h"

typedef mach_port_t (*FFServerPort)(void);
typedef kern_return_t (*FFGetState)(mach_port_t port, int format, vm_address_t *bytes,
                                    mach_msg_type_number_t *length);
typedef kern_return_t (*FFSetState)(mach_port_t port, vm_address_t bytes,
                                    mach_msg_type_number_t length);

static NSString *const FFHomeScreenServices =
  @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices";
static NSString *const FFArrangementName = @"arrangement.plist";
static NSString *const FFIconIdentifier = @"displayIdentifier";
static NSString *const FFFolderLists = @"iconLists";
static const int FFFolderFormat = 1;
static const unsigned FFArrangeTries = 20;
static const unsigned FFArrangeWait = 3;

static void *FFHomeScreenCall(const char *name) {
  static void *library;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    library = dlopen(FFHomeScreenServices.fileSystemRepresentation, RTLD_NOW);
  });
  return library != NULL ? dlsym(library, name) : NULL;
}

static mach_port_t FFHomeScreenPort(void) {
  FFServerPort server = (FFServerPort)FFHomeScreenCall("SBSSpringBoardServerPort");
  return server != NULL ? server() : MACH_PORT_NULL;
}

static NSString *FFArrangementPath(void) {
  return [FFStateFolder stringByAppendingPathComponent:FFArrangementName];
}

static NSData *FFReadArrangement(void) {
  FFGetState get = (FFGetState)FFHomeScreenCall("SBGetIconState");
  mach_port_t port = FFHomeScreenPort();
  vm_address_t bytes = 0;
  mach_msg_type_number_t length = 0;
  if (get == NULL || port == MACH_PORT_NULL ||
      get(port, FFFolderFormat, &bytes, &length) != KERN_SUCCESS || bytes == 0) {
    return nil;
  }
  NSData *arrangement = [NSData dataWithBytes:(const void *)bytes length:length];
  vm_deallocate(mach_task_self(), bytes, length);
  return arrangement;
}

static BOOL FFWriteArrangement(NSData *arrangement) {
  FFSetState set = (FFSetState)FFHomeScreenCall("SBSetIconState");
  mach_port_t port = FFHomeScreenPort();
  return set != NULL && port != MACH_PORT_NULL &&
         set(port, (vm_address_t)arrangement.bytes,
             (mach_msg_type_number_t)arrangement.length) == KERN_SUCCESS;
}

static void FFCollectIcons(id entry, NSMutableArray<NSString *> *into) {
  if ([entry isKindOfClass:[NSArray class]]) {
    for (id each in entry) {
      FFCollectIcons(each, into);
    }
    return;
  }
  if (![entry isKindOfClass:[NSDictionary class]]) {
    return;
  }
  id lists = entry[FFFolderLists];
  id identifier = entry[FFIconIdentifier];
  if ([lists isKindOfClass:[NSArray class]]) {
    FFCollectIcons(lists, into);
  } else if ([identifier isKindOfClass:[NSString class]]) {
    [into addObject:identifier];
  }
}

static NSArray<NSArray<NSString *> *> *FFPlaces(NSData *arrangement) {
  id lists = arrangement == nil ? nil
                                : [NSPropertyListSerialization propertyListWithData:arrangement
                                                                            options:0
                                                                             format:NULL
                                                                              error:NULL];
  NSMutableArray<NSArray<NSString *> *> *places = [NSMutableArray new];
  for (id list in [lists isKindOfClass:[NSArray class]] ? lists : @[]) {
    NSMutableArray<NSString *> *icons = [NSMutableArray new];
    FFCollectIcons(list, icons);
    [places addObject:icons];
  }
  return places;
}

static NSSet<NSString *> *FFIcons(NSArray<NSArray<NSString *> *> *places) {
  NSMutableSet<NSString *> *icons = [NSMutableSet new];
  for (NSArray<NSString *> *list in places) {
    [icons addObjectsFromArray:list];
  }
  return icons;
}

static NSArray<NSArray<NSString *> *> *FFOnly(NSArray<NSArray<NSString *> *> *places,
                                              NSSet<NSString *> *wanted) {
  NSMutableArray<NSArray<NSString *> *> *kept = [NSMutableArray new];
  for (NSUInteger index = 0; index < places.count; index++) {
    NSMutableArray<NSString *> *icons = [NSMutableArray new];
    for (NSString *icon in places[index]) {
      if ([wanted containsObject:icon]) {
        [icons addObject:icon];
      }
    }
    if (index == 0 || icons.count > 0) {
      [kept addObject:icons];
    }
  }
  return kept;
}

static BOOL FFArrangedAs(NSData *saved, NSData *shown, NSArray<NSString *> *returned) {
  NSArray<NSArray<NSString *> *> *wanted = FFPlaces(saved);
  NSArray<NSArray<NSString *> *> *found = FFPlaces(shown);
  NSSet<NSString *> *before = FFIcons(wanted);
  NSMutableSet<NSString *> *both = [FFIcons(found) mutableCopy];
  for (NSString *identifier in returned) {
    if ([before containsObject:identifier] && ![both containsObject:identifier]) {
      return NO;
    }
  }
  [both intersectSet:before];
  return both.count > 0 && [FFOnly(wanted, both) isEqual:FFOnly(found, both)];
}

BOOL FFSaveArrangement(void) {
  NSData *arrangement = FFReadArrangement();
  return FFPlaces(arrangement).count > 0 &&
         [arrangement writeToFile:FFArrangementPath() atomically:YES];
}

BOOL FFHasSavedArrangement(void) {
  return access(FFArrangementPath().fileSystemRepresentation, R_OK) == 0;
}

BOOL FFRestoreArrangement(NSArray<NSString *> *returned) {
  NSData *saved = [NSData dataWithContentsOfFile:FFArrangementPath()];
  if (FFPlaces(saved).count == 0) {
    return NO;
  }
  for (unsigned attempt = 0; attempt < FFArrangeTries; attempt++) {
    BOOL sent = FFWriteArrangement(saved);
    sleep(FFArrangeWait);
    if (sent && FFArrangedAs(saved, FFReadArrangement(), returned)) {
      unlink(FFArrangementPath().fileSystemRepresentation);
      return YES;
    }
  }
  return NO;
}
