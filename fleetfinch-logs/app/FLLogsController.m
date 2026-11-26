#import "FLLogsController.h"

#import "FLFilesController.h"
#import "FLLogViewController.h"
#import "FLReader.h"
#import "FLStatus.h"
#import "FLStore.h"
#import "FLTheme.h"

static NSString *FLSnapshotTitle(NSString *kind) {
  NSDictionary *titles = @{
    @"environment" : @"Environment",
    @"device" : @"Device",
    @"processes" : @"Processes",
    @"services" : @"Services",
    @"apps" : @"Apps",
    @"packages" : @"Packages",
    @"volumes" : @"Storage Volumes",
    @"network" : @"Network",
    @"power" : @"Power and Battery",
    @"kernel" : @"Kernel Messages",
    @"extensions" : @"Kernel Extensions",
    @"sysctl" : @"Kernel Settings",
    @"registry" : @"Hardware Registry",
    @"usage" : @"What Has Run",
    @"inventory" : @"What Is Installed",
    @"dependencies" : @"What Depends on What",
    @"health" : @"Problems per Component",
    @"connections" : @"Programs and Servers",
    @"loaded" : @"Loaded Libraries",
    @"changes" : @"Changes",
    @"calls" : @"System Calls",
    @"opened" : @"Files Reached",
    @"talks" : @"Connections Between Programs",
    @"candidates" : @"What Looks Unused",
  };
  return titles[kind] ?: kind.capitalizedString;
}

@implementation FLLogsController

- (instancetype)init {
  self = [super initGrouped:YES];
  if (self) {
    self.title = @"Logs";
    self.refreshInterval = 10;
  }
  return self;
}

- (void)open:(UIViewController *)controller {
  [self.navigationController pushViewController:controller animated:YES];
}

- (void)importNow {
  if (!FLServiceRunning(FLServiceStatus())) {
    [self showMessage:@"The Finch Logs service is not running, so nothing can be imported."
                title:@"Service Not Running"];
    return;
  }
  FLPostCommand(FLCommandImport);
  [self showMessage:@"The service is looking for new crash reports, dumps and log files now. "
                    @"What it finds appears under Dumps in a few seconds."
              title:nil];
}

- (NSString *)summaryOfGroup:(NSString *)group {
  NSArray<FLLogFile *> *files = [FLReader filesInGroup:group];
  uint64_t bytes = 0;
  NSDate *newest = nil;
  for (FLLogFile *file in files) {
    bytes += file.size;
    if (newest == nil || [file.modified compare:newest] == NSOrderedDescending) {
      newest = file.modified;
    }
  }
  return [NSString stringWithFormat:@"%lu kept, %@, newest %@", (unsigned long)files.count,
                                    FLFormatBytes(bytes), FLAgo(newest)];
}

- (NSArray<FLSection *> *)buildSections {
  NSMutableArray *sections = [NSMutableArray new];
  __weak FLLogsController *weak = self;

  FLSection *tail = [FLSection sectionWithTitle:nil];
  FLRow *everything = [FLRow linkWithTitle:@"Tail Every Log"
                                    detail:@"Watch new lines from every log as they are written"
                                    action:^{
                                      [weak open:[[FLLogViewController alloc] initWithStream:nil]];
                                    }];
  everything.stacked = YES;
  everything.titleColor = FLTintColor();
  [tail addRow:everything];
  [sections addObject:tail];

  FLSection *logs = [FLSection sectionWithTitle:@"Logs"];
  for (NSString *stream in [FLReader streams]) {
    FLRow *row = [FLRow linkWithTitle:[FLReader streamTitle:stream]
                               detail:[FLReader streamDescription:stream]
                               action:^{
                                 [weak open:[[FLLogViewController alloc] initWithStream:stream]];
                               }];
    row.stacked = YES;
    [logs addRow:row];
  }
  logs.footer = logs.rows.count == 0
    ? @"Nothing has been logged yet. The service writes here as soon as it starts."
    : @"Open a log to read it and tail it. Each log keeps a file for every hour.";
  [sections addObject:logs];

  FLSection *snapshots = [FLSection sectionWithTitle:@"Snapshots"];
  NSArray<NSString *> *kinds = [[FLReader groupsUnder:FLSnapshotFolder]
    sortedArrayUsingComparator:^(NSString *first, NSString *second) {
      return [FLSnapshotTitle(first.lastPathComponent)
        compare:FLSnapshotTitle(second.lastPathComponent)];
    }];
  for (NSString *group in kinds) {
    NSString *title = FLSnapshotTitle(group.lastPathComponent);
    FLRow *row = [FLRow linkWithTitle:title
                               detail:[self summaryOfGroup:group]
                               action:^{
                                 [weak open:[[FLFilesController alloc] initWithGroup:group
                                                                               title:title
                                                                              stream:nil]];
                               }];
    row.stacked = YES;
    [snapshots addRow:row];
  }
  snapshots.footer = @"A snapshot is a full picture of one part of the system at one moment, "
                     @"taken when the device starts and again each day.";
  [sections addObject:snapshots];

  FLSection *dumps = [FLSection sectionWithTitle:@"Dumps"];
  NSUInteger groups = [FLReader groupsUnder:FLImportFolder].count;
  FLRow *copied = [FLRow
    linkWithTitle:@"Dumps Copied from the System"
           detail:FLCount(groups, @"folder")
           action:^{
             [weak open:[[FLFilesController alloc] initWithFolder:FLImportFolder
                                                            title:@"Dumps"]];
           }];
  [dumps addRow:copied];
  [dumps addRow:[FLRow buttonWithTitle:@"Import Log Dumps Now"
                                action:^{
                                  [weak importNow];
                                }]];
  NSDictionary *last = FLServiceStatus()[@"import"];
  NSString *looked = @"";
  if ([last[@"at"] isKindOfClass:[NSDate class]]) {
    NSDictionary *result = last[@"result"];
    looked = [NSString
      stringWithFormat:@" It last looked %@ and copied %@ and read %@.", FLAgo(last[@"at"]),
                       FLCount([result[@"copied"] unsignedIntegerValue], @"new dump"),
                       FLCount([result[@"lines"] unsignedIntegerValue], @"new line")];
  }
  dumps.footer = [@"Crash reports and other dumps the system writes are copied in every few "
                  @"minutes, and new lines in its own log files are read into Log Files."
    stringByAppendingString:looked];
  [sections addObject:dumps];
  return sections;
}

@end
