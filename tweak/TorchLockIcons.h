// Vector icons rendered at the screen's native scale. No modern symbol APIs.
static void TLGradient(UIBezierPath *path, UIColor *top, UIColor *bottom) {
	CGContextRef context = UIGraphicsGetCurrentContext();
	CGContextSaveGState(context);
	[path addClip];
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	NSArray *colors = @[(id)top.CGColor, (id)bottom.CGColor];
	CGGradientRef gradient = CGGradientCreateWithColors(space, (CFArrayRef)colors, NULL);
	CGRect bounds = path.bounds;
	CGContextDrawLinearGradient(context, gradient, CGPointMake(CGRectGetMidX(bounds), CGRectGetMinY(bounds)),
		CGPointMake(CGRectGetMidX(bounds), CGRectGetMaxY(bounds)), 0);
	CGGradientRelease(gradient);
	CGColorSpaceRelease(space);
	CGContextRestoreGState(context);
}

static UIBezierPath *TLFlashlightPath(void) {
	UIBezierPath *path = [UIBezierPath bezierPath];
	[path moveToPoint:CGPointMake(14, 13)];
	[path addLineToPoint:CGPointMake(30, 13)];
	[path addLineToPoint:CGPointMake(30, 18)];
	[path addLineToPoint:CGPointMake(26, 23)];
	[path addLineToPoint:CGPointMake(26, 35)];
	[path addQuadCurveToPoint:CGPointMake(24, 37) controlPoint:CGPointMake(26, 37)];
	[path addLineToPoint:CGPointMake(20, 37)];
	[path addQuadCurveToPoint:CGPointMake(18, 35) controlPoint:CGPointMake(18, 37)];
	[path addLineToPoint:CGPointMake(18, 23)];
	[path addLineToPoint:CGPointMake(14, 18)];
	[path closePath];
	return path;
}

static void TLRays(UIColor *color) {
	[color setStroke];
	UIBezierPath *rays = [UIBezierPath bezierPath];
	[rays moveToPoint:CGPointMake(22, 4)]; [rays addLineToPoint:CGPointMake(22, 8)];
	[rays moveToPoint:CGPointMake(12, 6)]; [rays addLineToPoint:CGPointMake(15, 9)];
	[rays moveToPoint:CGPointMake(32, 6)]; [rays addLineToPoint:CGPointMake(29, 9)];
	rays.lineWidth = 1.8;
	rays.lineCapStyle = kCGLineCapRound;
	[rays stroke];
}

static UIImage *TLStyledIcon(NSUInteger style, BOOL on) {
	static UIImage *icons[5][2];
	if (icons[style][on ? 1 : 0])
		return icons[style][on ? 1 : 0];
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(44, 44), NO, 0);
	CGContextRef context = UIGraphicsGetCurrentContext();
	UIColor *silver = [UIColor colorWithWhite:0.82 alpha:1];
	UIColor *light = [UIColor colorWithWhite:0.98 alpha:1];
	UIColor *gold = [UIColor colorWithRed:1 green:0.79 blue:0.28 alpha:1];
	UIBezierPath *body = TLFlashlightPath();
	if (style == 1) {
		// iOS 6: an embossed silver silhouette, like the native camera grabber.
		CGContextSaveGState(context);
		CGContextSetShadowWithColor(context, CGSizeMake(0, 1), 1, [UIColor colorWithWhite:0 alpha:0.85].CGColor);
		TLGradient(body, on ? light : silver, on ? gold : [UIColor colorWithWhite:0.57 alpha:1]);
		CGContextRestoreGState(context);
		[[UIColor colorWithWhite:0.1 alpha:0.75] setStroke];
		body.lineWidth = 0.6; [body stroke];
		[[UIColor colorWithWhite:1 alpha:0.65] setStroke];
		UIBezierPath *rim = [UIBezierPath bezierPath];
		[rim moveToPoint:CGPointMake(15, 14)]; [rim addLineToPoint:CGPointMake(29, 14)];
		rim.lineWidth = 1; [rim stroke];
		[[UIColor colorWithWhite:0.15 alpha:0.65] setFill];
		[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(21, 26, 2, 6) cornerRadius:1] fill];
		if (on) TLRays(gold);
	} else if (style == 2) {
		// Metal: inset dark enamel, polished rim, and a compact torch silhouette.
		UIBezierPath *rim = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 40, 40)];
		TLGradient(rim, light, [UIColor colorWithWhite:0.32 alpha:1]);
		UIBezierPath *face = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(5, 5, 34, 34)];
		TLGradient(face, [UIColor colorWithWhite:on ? 0.36 : 0.26 alpha:1], [UIColor colorWithWhite:0.07 alpha:1]);
		CGContextSaveGState(context);
		CGContextTranslateCTM(context, 5.5, 5.5); CGContextScaleCTM(context, 0.75, 0.75);
		TLGradient(body, on ? light : silver, on ? gold : [UIColor colorWithWhite:0.61 alpha:1]);
		if (on) TLRays(gold);
		CGContextRestoreGState(context);
	} else if (style == 3) {
		// Outline: open torch body and rays with the wallpaper visible through it.
		CGContextSetShadowWithColor(context, CGSizeMake(0, 1), 1.5, [UIColor blackColor].CGColor);
		[(on ? gold : light) setStroke];
		body.lineWidth = 1.8; body.lineJoinStyle = kCGLineJoinRound; [body stroke];
		UIBezierPath *rim = [UIBezierPath bezierPath];
		[rim moveToPoint:CGPointMake(14, 18)]; [rim addLineToPoint:CGPointMake(30, 18)];
		[rim moveToPoint:CGPointMake(21, 28)]; [rim addLineToPoint:CGPointMake(23, 28)];
		rim.lineWidth = 1.8; rim.lineCapStyle = kCGLineCapRound; [rim stroke];
		TLRays(on ? gold : silver);
	} else {
		// Bulb: frosted glass dome with a ribbed chrome screw base.
		UIBezierPath *glass = [UIBezierPath bezierPath];
		[glass moveToPoint:CGPointMake(17, 29)];
		[glass addCurveToPoint:CGPointMake(12, 17) controlPoint1:CGPointMake(17, 25) controlPoint2:CGPointMake(12, 23)];
		[glass addCurveToPoint:CGPointMake(32, 17) controlPoint1:CGPointMake(12, 4) controlPoint2:CGPointMake(32, 4)];
		[glass addCurveToPoint:CGPointMake(27, 29) controlPoint1:CGPointMake(32, 23) controlPoint2:CGPointMake(27, 25)];
		[glass closePath];
		CGContextSaveGState(context);
		CGContextSetShadowWithColor(context, CGSizeMake(0, 1), on ? 3 : 1, (on ? gold : [UIColor blackColor]).CGColor);
		TLGradient(glass, light, on ? gold : [UIColor colorWithWhite:0.55 alpha:1]);
		CGContextRestoreGState(context);
		[[UIColor colorWithWhite:0.25 alpha:0.9] setStroke];
		UIBezierPath *filament = [UIBezierPath bezierPath];
		[filament moveToPoint:CGPointMake(20, 28)]; [filament addLineToPoint:CGPointMake(18, 18)];
		[filament addLineToPoint:CGPointMake(22, 21)]; [filament addLineToPoint:CGPointMake(26, 18)];
		[filament addLineToPoint:CGPointMake(24, 28)];
		filament.lineWidth = 1; [filament stroke];
		UIBezierPath *base = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(17, 29, 10, 8) cornerRadius:2];
		TLGradient(base, silver, [UIColor colorWithWhite:0.35 alpha:1]);
		[[UIColor colorWithWhite:1 alpha:0.6] setStroke];
		UIBezierPath *ribs = [UIBezierPath bezierPath];
		for (CGFloat y = 30.5; y < 37; y += 2) {
			[ribs moveToPoint:CGPointMake(18, y)]; [ribs addLineToPoint:CGPointMake(26, y)];
		}
		ribs.lineWidth = 0.7; [ribs stroke];
		if (on) {
			[gold setFill];
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(20, 37, 4, 2)] fill];
		}
	}
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	icons[style][on ? 1 : 0] = [image retain];
	return image;
}
