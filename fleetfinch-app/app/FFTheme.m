#import "FFTheme.h"

static UIColor *FFHex(uint32_t value) {
  return [UIColor colorWithRed:((value >> 16) & 0xff) / 255.0
                         green:((value >> 8) & 0xff) / 255.0
                          blue:(value & 0xff) / 255.0
                         alpha:1.0];
}

UIColor *FFTintColor(void) {
  return FFHex(0x924d04);
}

UIColor *FFMutedColor(void) {
  return FFHex(0x5f6781);
}

static void FFStroke(UIBezierPath *path) {
  path.lineWidth = 2;
  path.lineCapStyle = kCGLineCapRound;
  path.lineJoinStyle = kCGLineJoinRound;
  [path stroke];
}

static void FFLine(CGFloat fromX, CGFloat fromY, CGFloat toX, CGFloat toY) {
  UIBezierPath *path = [UIBezierPath bezierPath];
  [path moveToPoint:CGPointMake(fromX, fromY)];
  [path addLineToPoint:CGPointMake(toX, toY)];
  FFStroke(path);
}

UIImage *FFTabIcon(FFIcon icon) {
  CGSize size = CGSizeMake(26, 26);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  [[UIColor blackColor] set];
  switch (icon) {
    case FFIconHome: {
      UIBezierPath *roof = [UIBezierPath bezierPath];
      [roof moveToPoint:CGPointMake(3, 13)];
      [roof addLineToPoint:CGPointMake(13, 4)];
      [roof addLineToPoint:CGPointMake(23, 13)];
      FFStroke(roof);
      UIBezierPath *walls = [UIBezierPath bezierPath];
      [walls moveToPoint:CGPointMake(6, 11)];
      [walls addLineToPoint:CGPointMake(6, 22)];
      [walls addLineToPoint:CGPointMake(20, 22)];
      [walls addLineToPoint:CGPointMake(20, 11)];
      FFStroke(walls);
      [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(11, 15, 4, 7) cornerRadius:1] fill];
      break;
    }
    case FFIconUtilities: {
      FFStroke([UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 9, 20, 13) cornerRadius:2]);
      FFStroke([UIBezierPath bezierPathWithRoundedRect:CGRectMake(9, 5, 8, 4) cornerRadius:1]);
      FFLine(3, 14, 23, 14);
      [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(11, 12, 4, 4) cornerRadius:1] fill];
      break;
    }
    case FFIconApps:
      for (int row = 0; row < 2; row++) {
        for (int column = 0; column < 2; column++) {
          CGRect square = CGRectMake(4 + column * 10, 4 + row * 10, 8, 8);
          [[UIBezierPath bezierPathWithRoundedRect:square cornerRadius:2] fill];
        }
      }
      break;
    case FFIconSettings:
      FFLine(4, 7, 22, 7);
      FFLine(4, 13, 22, 13);
      FFLine(4, 19, 22, 19);
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(14, 3.5, 7, 7)] fill];
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(6, 9.5, 7, 7)] fill];
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(12, 15.5, 7, 7)] fill];
      break;
  }
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
