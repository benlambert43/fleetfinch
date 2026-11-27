#import <Foundation/Foundation.h>

#import "FFCleaner.h"
#import "FFStayJoined.h"

static NSString *const FFAppInfo = @"/Applications/FleetFinch.app/Info.plist";

static void FFUsage(void) {
  printf("Fleet Finch cleans up, patches and extends this device.\n\n"
         "  fleetfinch cleanup status        what the cleanup list holds, group by group, and\n"
         "                                   what has been removed\n"
         "  fleetfinch cleanup list [GROUP]  each thing on the list with its size\n"
         "  fleetfinch cleanup check         whether the device can still be reached\n"
         "  fleetfinch cleanup remove [GROUP | PATH ...]\n"
         "                                   copy what is listed to the data volume, then\n"
         "                                   delete it from the system volume; with nothing\n"
         "                                   named, every group\n"
         "  fleetfinch cleanup restore [GROUP | PATH ...]\n"
         "                                   put it back where it was; with nothing named,\n"
         "                                   everything that was removed\n"
         "  fleetfinch serve                 do what the app asked for (launchd does this)\n"
         "  fleetfinch keep-reachable        ask Wi-Fi to stay joined while the device sleeps,\n"
         "                                   so that it still answers (launchd does this)\n"
         "  fleetfinch version\n");
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSMutableArray<NSString *> *arguments = [NSMutableArray new];
    for (int index = 1; index < argc; index++) {
      [arguments addObject:@(argv[index])];
    }
    NSString *verb = arguments.firstObject;
    if ([verb isEqualToString:@"cleanup"]) {
      [arguments removeObjectAtIndex:0];
      return FFCleanupCommand(arguments);
    }
    if ([verb isEqualToString:@"serve"]) {
      return FFServe();
    }
    if ([verb isEqualToString:@"keep-reachable"]) {
      return FFKeepReachable();
    }
    if ([verb isEqualToString:@"version"]) {
      NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:FFAppInfo];
      printf("Fleet Finch %s\n", [info[@"CFBundleShortVersionString"] description].UTF8String);
      return 0;
    }
    FFUsage();
    return verb == nil ? 0 : 2;
  }
}
