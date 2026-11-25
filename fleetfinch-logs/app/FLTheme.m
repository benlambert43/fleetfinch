#import "FLTheme.h"

static UIColor *FLHex(uint32_t value) {
  return [UIColor colorWithRed:((value >> 16) & 0xff) / 255.0
                         green:((value >> 8) & 0xff) / 255.0
                          blue:(value & 0xff) / 255.0
                         alpha:1.0];
}

UIColor *FLTintColor(void) {
  return FLHex(0x924d04);
}

UIColor *FLInkColor(void) {
  return FLHex(0x222636);
}

UIColor *FLMutedColor(void) {
  return FLHex(0x5f6781);
}

UIColor *FLFaintColor(void) {
  return FLHex(0xbdc0cb);
}

UIColor *FLDangerColor(void) {
  return FLHex(0xa3291a);
}

UIColor *FLLevelColor(FLLevel level) {
  switch (level) {
    case FLLevelDebug:
    case FLLevelInfo:
      return FLMutedColor();
    case FLLevelNotice:
      return FLInkColor();
    case FLLevelWarning:
      return FLTintColor();
    case FLLevelError:
    case FLLevelFault:
      return FLDangerColor();
  }
  return FLInkColor();
}

UIFont *FLMonoFont(CGFloat size) {
  return [UIFont fontWithName:@"Menlo-Regular" size:size] ?: [UIFont systemFontOfSize:size];
}

static void FLStroke(CGFloat fromX, CGFloat fromY, CGFloat toX, CGFloat toY) {
  UIBezierPath *path = [UIBezierPath bezierPath];
  path.lineWidth = 2;
  path.lineCapStyle = kCGLineCapRound;
  [path moveToPoint:CGPointMake(fromX, fromY)];
  [path addLineToPoint:CGPointMake(toX, toY)];
  [path stroke];
}

UIImage *FLTabIcon(FLIcon icon) {
  CGSize size = CGSizeMake(26, 26);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  [[UIColor blackColor] set];
  switch (icon) {
    case FLIconOverview: {
      UIBezierPath *dial = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, 20, 20)];
      dial.lineWidth = 2;
      [dial stroke];
      FLStroke(13, 13, 18, 8);
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(11, 11, 4, 4)] fill];
      break;
    }
    case FLIconLogs:
      FLStroke(4, 6, 22, 6);
      FLStroke(4, 11, 17, 11);
      FLStroke(4, 16, 22, 16);
      FLStroke(4, 21, 13, 21);
      break;
    case FLIconProcesses:
      [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4, 13, 4.5, 9) cornerRadius:1] fill];
      [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(10.75, 5, 4.5, 17) cornerRadius:1] fill];
      [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(17.5, 9, 4.5, 13) cornerRadius:1] fill];
      break;
    case FLIconServices:
      for (int row = 0; row < 2; row++) {
        for (int column = 0; column < 2; column++) {
          CGRect square = CGRectMake(4 + column * 10, 4 + row * 10, 8, 8);
          UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:square cornerRadius:2];
          if (row == 0 && column == 0) {
            [path fill];
          } else {
            path.lineWidth = 1.5;
            [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(square, 0.75, 0.75)
                                        cornerRadius:2] stroke];
          }
        }
      }
      break;
    case FLIconSettings:
      FLStroke(4, 7, 22, 7);
      FLStroke(4, 13, 22, 13);
      FLStroke(4, 19, 22, 19);
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(14, 3.5, 7, 7)] fill];
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(6, 9.5, 7, 7)] fill];
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(12, 15.5, 7, 7)] fill];
      break;
  }
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

NSString *FLAgo(NSDate *date) {
  if (date == nil) {
    return @"never";
  }
  NSTimeInterval seconds = -date.timeIntervalSinceNow;
  if (seconds < 2) {
    return @"just now";
  }
  return [FLFormatDuration(seconds) stringByAppendingString:@" ago"];
}

NSString *FLPercent(double value) {
  return [NSString stringWithFormat:(value >= 10 ? @"%.0f%%" : @"%.1f%%"), value];
}

NSString *FLCount(NSUInteger count, NSString *noun) {
  return [NSString stringWithFormat:@"%lu %@%@", (unsigned long)count, noun,
                                    count == 1 ? @"" : @"s"];
}
