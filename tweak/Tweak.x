// TorchLock — lock screen flashlight for iOS 6.
//
// Unlike FlashLock, this never builds an AVCaptureSession: since iOS 5 the torch can be
// driven directly through lockForConfiguration/setTorchMode. That makes toggling instant,
// keeps SpringBoard's main thread free and doesn't keep the camera streaming frames.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface SBAwayController : NSObject
+ (id)sharedAwayController;
- (UIView *)awayView;
- (BOOL)isLocked;
- (BOOL)handleMenuButtonDoubleTap;
- (void)restartDimTimer;
@end

@interface UIView (TorchLockPrivate)
- (UIView *)lockBar;
- (NSString *)recursiveDescription;
@end

@interface LAActivator : NSObject
+ (id)sharedInstance;
- (void)registerListener:(id)listener forName:(NSString *)name;
@end

@interface LAEvent : NSObject
- (void)setHandled:(BOOL)handled;
@end

#define TL_PREFS_PATH @"/var/mobile/Library/Preferences/com.aurelio.torchlock.plist"
#define TL_LISTENER_TOGGLE @"com.aurelio.torchlock.toggle"
#define TL_LISTENER_DEBUG @"com.aurelio.torchlock.debug"
// Posted by the Settings pane (PostNotification in TorchLock.plist) after each change.
#define TL_PREFS_CHANGED "com.aurelio.torchlock/prefs-changed"

static UIButton *tlButton;

// Settings → TorchLock. Every default is YES, so a missing plist means "on".
static BOOL tlEnabled = YES;
static BOOL tlAlwaysShowButton = YES;
static BOOL tlTurnOffOnUnlock = YES;
// With AlwaysShowButton off, double-clicking Home on the lock screen reveals the
// button until the lock screen is next shown.
static BOOL tlRevealed;

static AVCaptureDevice *TLTorchDevice(void) {
	AVCaptureDevice *fallback = nil;
	for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
		if (![device hasTorch])
			continue;
		if ([device position] == AVCaptureDevicePositionBack)
			return device;
		fallback = device;
	}
	return fallback;
}

static BOOL TLTorchIsOn(void) {
	AVCaptureDevice *device = TLTorchDevice();
	return device && [device torchMode] == AVCaptureTorchModeOn;
}

static BOOL TLBoolPref(NSDictionary *prefs, NSString *key) {
	id value = [prefs objectForKey:key];
	return value ? [value boolValue] : YES;
}

static void TLLoadPrefs(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:TL_PREFS_PATH];
	tlEnabled = TLBoolPref(prefs, @"Enabled");
	tlAlwaysShowButton = TLBoolPref(prefs, @"AlwaysShowButton");
	tlTurnOffOnUnlock = TLBoolPref(prefs, @"TurnOffOnUnlock");
}

static UIImage *TLIcon(BOOL on) {
	CGFloat size = 44;
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGRect circle = CGRectInset(CGRectMake(0, 0, size, size), 2, 2);

	[(on ? [UIColor colorWithWhite:1 alpha:0.9] : [UIColor colorWithWhite:0 alpha:0.45]) setFill];
	CGContextFillEllipseInRect(ctx, circle);
	[[UIColor colorWithWhite:1 alpha:on ? 1 : 0.6] setStroke];
	CGContextSetLineWidth(ctx, 1.5);
	CGContextStrokeEllipseInRect(ctx, CGRectInset(circle, 0.75, 0.75));

	UIBezierPath *bolt = [UIBezierPath bezierPath];
	[bolt moveToPoint:CGPointMake(24.5, 9)];
	[bolt addLineToPoint:CGPointMake(14, 24)];
	[bolt addLineToPoint:CGPointMake(21, 24)];
	[bolt addLineToPoint:CGPointMake(19, 35)];
	[bolt addLineToPoint:CGPointMake(30, 19.5)];
	[bolt addLineToPoint:CGPointMake(23, 19.5)];
	[bolt closePath];
	[(on ? [UIColor colorWithRed:1 green:0.72 blue:0 alpha:1] : [UIColor colorWithWhite:1 alpha:0.85]) setFill];
	[bolt fill];

	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

static void TLUpdateButton(void) {
	if (!tlButton)
		return;
	BOOL on = TLTorchIsOn();
	// A lit torch always keeps its button, or there'd be no way to turn it off.
	[tlButton setHidden:!(tlAlwaysShowButton || tlRevealed || on)];
	[tlButton setImage:TLIcon(on) forState:UIControlStateNormal];
	[tlButton setAccessibilityLabel:on ? @"Flashlight on" : @"Flashlight off"];
}

static void TLSetTorch(BOOL on) {
	AVCaptureDevice *device = TLTorchDevice();
	if (!device)
		return;
	NSError *error = nil;
	if ([device lockForConfiguration:&error]) {
		if (on && [device isTorchModeSupported:AVCaptureTorchModeOn])
			[device setTorchMode:AVCaptureTorchModeOn];
		else
			[device setTorchMode:AVCaptureTorchModeOff];
		[device unlockForConfiguration];
	} else {
		NSLog(@"[TorchLock] lockForConfiguration failed: %@", error);
	}
	TLUpdateButton();
}

static void TLToggle(void) {
	TLSetTorch(!TLTorchIsOn());
	// Tapping the button counts as activity, so the lock screen doesn't dim right after.
	SBAwayController *controller = [objc_getClass("SBAwayController") sharedAwayController];
	if ([controller isLocked] && [controller respondsToSelector:@selector(restartDimTimer)])
		[controller restartDimTimer];
}

#if TL_DEBUG
static void TLDebugDump(void) {
	SBAwayController *controller = [objc_getClass("SBAwayController") sharedAwayController];
	UIView *awayView = [controller awayView];
	AVCaptureDevice *device = TLTorchDevice();
	NSMutableString *out = [NSMutableString string];
	[out appendFormat:@"device=%@ torchMode=%ld torchActive=%d locked=%d\n", device, (long)[device torchMode],
		[device respondsToSelector:@selector(isTorchActive)] ? [device isTorchActive] : -1, [controller isLocked]];
	[out appendFormat:@"button=%@ superview=%@\n", tlButton, [tlButton superview]];
	[out appendFormat:@"prefs: Enabled=%d AlwaysShowButton=%d TurnOffOnUnlock=%d revealed=%d\n",
		tlEnabled, tlAlwaysShowButton, tlTurnOffOnUnlock, tlRevealed];
	[out appendFormat:@"%@\n", [awayView recursiveDescription]];
	[out writeToFile:@"/tmp/torchlock-debug.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];

	CGImageRef (*getScreenImage)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
	if (getScreenImage) {
		CGImageRef cgImage = getScreenImage();
		UIImage *image = [UIImage imageWithCGImage:cgImage];
		[UIImagePNGRepresentation(image) writeToFile:@"/tmp/torchlock-screen.png" atomically:YES];
		CGImageRelease(cgImage);
	}
}
#endif

@interface TorchLockController : NSObject
@end

@implementation TorchLockController

- (void)buttonTapped:(UIButton *)button {
	TLToggle();
}

- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event forListenerName:(NSString *)listenerName {
#if TL_DEBUG
	if ([listenerName isEqualToString:TL_LISTENER_DEBUG]) {
		TLDebugDump();
		[event setHandled:YES];
		return;
	}
#endif
	// Disabled means disabled: leave the event unhandled for anything else bound to it.
	if (!tlEnabled)
		return;
	TLToggle();
	[event setHandled:YES];
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedTitleForListenerName:(NSString *)listenerName {
#if TL_DEBUG
	if ([listenerName isEqualToString:TL_LISTENER_DEBUG])
		return @"TorchLock debug dump";
#endif
	return @"Toggle Flashlight";
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedDescriptionForListenerName:(NSString *)listenerName {
	return @"Turn the flashlight on or off";
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedGroupForListenerName:(NSString *)listenerName {
	return @"TorchLock";
}

- (NSArray *)activator:(LAActivator *)activator requiresCompatibleEventModesForListenerWithName:(NSString *)listenerName {
	return [NSArray arrayWithObjects:@"springboard", @"lockscreen", @"application", nil];
}

@end

static TorchLockController *tlController;

static void TLInstallButton(SBAwayController *controller) {
	if (!tlEnabled) {
		[tlButton removeFromSuperview];
		return;
	}
	if (!TLTorchDevice())
		return;
	UIView *awayView = [controller awayView];
	if (!awayView)
		return;

	if (!tlButton) {
		tlButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
		[tlButton setShowsTouchWhenHighlighted:YES];
		[tlButton addTarget:tlController action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
	}

	// Sit just above the left end of the slide-to-unlock bar.
	CGFloat size = 44;
	CGRect frame = CGRectMake(12, awayView.bounds.size.height - 96 - size - 10, size, size);
	UIView *lockBar = [awayView respondsToSelector:@selector(lockBar)] ? [awayView lockBar] : nil;
	if (lockBar && [lockBar superview]) {
		CGRect barFrame = [lockBar convertRect:[lockBar bounds] toView:awayView];
		frame.origin.y = barFrame.origin.y - size - 10;
	}
	[tlButton setFrame:frame];
	[tlButton setAutoresizingMask:UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin];
	if ([tlButton superview] != awayView)
		[tlButton removeFromSuperview];
	[awayView addSubview:tlButton];
	TLUpdateButton();
}

static void TLPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object,
		CFDictionaryRef userInfo) {
	TLLoadPrefs();
	// Turning TorchLock off also turns off a torch it lit; nothing else would.
	if (!tlEnabled && TLTorchIsOn())
		TLSetTorch(NO);
	TLInstallButton([objc_getClass("SBAwayController") sharedAwayController]);
}

%hook SBAwayController

- (void)activate {
	%orig;
	tlRevealed = NO;
	TLInstallButton(self);
}

- (void)didFinishAnimatingOut {
	%orig;
	if (tlEnabled && tlTurnOffOnUnlock && TLTorchIsOn())
		TLSetTorch(NO);
}

// Returns BOOL on iOS 6.1.3 (type encoding c8@0:4), so the result is passed through.
- (BOOL)handleMenuButtonDoubleTap {
	BOOL handled = %orig;
	if (tlEnabled && !tlAlwaysShowButton) {
		tlRevealed = YES;
		TLUpdateButton();
	}
	return handled;
}

%end

%ctor {
	@autoreleasepool {
		TLLoadPrefs();
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TLPrefsChanged,
			CFSTR(TL_PREFS_CHANGED), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
		tlController = [[TorchLockController alloc] init];
		dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
		LAActivator *activator = [objc_getClass("LAActivator") sharedInstance];
		[activator registerListener:tlController forName:TL_LISTENER_TOGGLE];
#if TL_DEBUG
		[activator registerListener:tlController forName:TL_LISTENER_DEBUG];
#endif
	}
}
