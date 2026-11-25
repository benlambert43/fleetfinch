#import "FLFilesController.h"

#import "FLLogViewController.h"
#import "FLReader.h"
#import "FLTextController.h"
#import "FLTheme.h"

@implementation FLFilesController {
  NSString *_group;
  NSString *_folder;
  NSString *_stream;
}

- (instancetype)initWithGroup:(NSString *)group
                        title:(NSString *)title
                       stream:(NSString *)stream {
  self = [super initGrouped:NO];
  if (self) {
    _group = [group copy];
    _stream = [stream copy];
    self.title = title;
    self.hidesBottomBarWhenPushed = YES;
  }
  return self;
}

- (instancetype)initWithFolder:(NSString *)folder title:(NSString *)title {
  self = [super initGrouped:NO];
  if (self) {
    _folder = [folder copy];
    self.title = title;
    self.hidesBottomBarWhenPushed = YES;
  }
  return self;
}

- (NSString *)nameOfFile:(FLLogFile *)file {
  if (_stream == nil || file.name.length < 13) {
    return file.name;
  }
  NSString *day = [file.name substringToIndex:10];
  NSString *hour = [file.name substringWithRange:NSMakeRange(11, 2)];
  return [NSString stringWithFormat:@"%@, %@:00 to %@:59", day, hour, hour];
}

- (NSArray<FLSection *> *)buildSections {
  FLSection *section = [FLSection sectionWithTitle:nil];
  __weak FLFilesController *weak = self;
  if (_folder != nil) {
    for (NSString *group in [FLReader groupsUnder:_folder]) {
      NSArray<FLLogFile *> *files = [FLReader filesInGroup:group];
      uint64_t bytes = 0;
      for (FLLogFile *file in files) {
        bytes += file.size;
      }
      NSString *name = group.length > _folder.length + 1
        ? [group substringFromIndex:_folder.length + 1]
        : group;
      [section addRow:[FLRow linkWithTitle:name
                                    detail:[NSString stringWithFormat:@"%@, %@",
                                                                      FLCount(files.count,
                                                                              @"file"),
                                                                      FLFormatBytes(bytes)]
                                    action:^{
                                      [weak openGroup:group title:name.lastPathComponent];
                                    }]];
    }
    if (section.rows.count == 0) {
      section.footer = @"Nothing has been copied here yet.";
    }
    return @[ section ];
  }
  for (FLLogFile *file in [FLReader filesInGroup:_group].reverseObjectEnumerator) {
    NSString *detail = [NSString
      stringWithFormat:@"%@ · written %@%@", FLFormatBytes(file.size),
                       FLFormatDay(file.modified), file.archived ? @" · archived" : @""];
    FLRow *row = [FLRow linkWithTitle:[self nameOfFile:file]
                               detail:detail
                               action:^{
                                 [weak openFile:file];
                               }];
    row.stacked = YES;
    [section addRow:row];
  }
  if (section.rows.count == 0) {
    section.footer = @"There are no files here yet.";
  }
  return @[ section ];
}

- (void)openGroup:(NSString *)group title:(NSString *)title {
  FLFilesController *files = [[FLFilesController alloc] initWithGroup:group
                                                                title:title
                                                               stream:nil];
  [self.navigationController pushViewController:files animated:YES];
}

- (void)openFile:(FLLogFile *)file {
  UIViewController *viewer = _stream != nil
    ? [[FLLogViewController alloc] initWithFile:file stream:_stream]
    : [[FLTextController alloc] initWithPath:file.path title:file.name];
  if (_stream != nil) {
    viewer.title = [self nameOfFile:file];
  }
  [self.navigationController pushViewController:viewer animated:YES];
}

@end
