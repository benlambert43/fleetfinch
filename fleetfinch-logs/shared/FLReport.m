#import "FLReport.h"

#import "FLCommon.h"

NSString *FLReportState(NSString *kind) {
  return [@"report-" stringByAppendingString:kind];
}

NSString *FLReportCommand(NSString *kind) {
  return [@"com.fleetfinch.logs.report." stringByAppendingString:kind];
}

NSString *FLReportNotice(NSString *kind) {
  return [NSString stringWithFormat:@"com.fleetfinch.logs.report.%@.ready", kind];
}

NSDictionary *FLReportRow(NSString *title, NSString *detail,
                          NSArray<NSArray<NSString *> *> *facts) {
  NSMutableArray<NSArray<NSString *> *> *kept = [NSMutableArray new];
  for (NSArray<NSString *> *fact in facts) {
    if (fact.count == 2 && fact[1].length > 0) {
      [kept addObject:fact];
    }
  }
  return @{@"title" : title ?: @"", @"detail" : detail ?: @"", @"facts" : kept};
}

NSDictionary *FLReportSection(NSString *title, NSString *note, NSArray<NSDictionary *> *rows) {
  return @{@"title" : title ?: @"", @"note" : note ?: @"", @"rows" : rows ?: @[]};
}

NSString *FLReportCount(unsigned long long count, NSString *one, NSString *many) {
  return [NSString stringWithFormat:@"%llu %@", count, count == 1 ? one : many];
}

NSString *FLReportText(NSDictionary *report) {
  NSMutableString *text = [NSMutableString new];
  for (NSString *note in report[@"notes"]) {
    [text appendFormat:@"%@\n", note];
  }
  for (NSDictionary *section in report[@"sections"]) {
    NSArray<NSDictionary *> *rows = section[@"rows"];
    [text appendFormat:@"\n%@: %lu\n", section[@"title"], (unsigned long)rows.count];
    if ([section[@"note"] length] > 0) {
      [text appendFormat:@"%@\n", section[@"note"]];
    }
    for (NSDictionary *row in rows) {
      [text appendFormat:@"%@\t%@", FLEscape(row[@"title"]), FLEscape(row[@"detail"])];
      for (NSArray<NSString *> *fact in row[@"facts"]) {
        [text appendFormat:@"\t%@: %@", fact[0], FLEscape(fact[1])];
      }
      [text appendString:@"\n"];
    }
  }
  return text;
}
