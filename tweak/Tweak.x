// TorchLock — lock screen and Notification Center flashlight for iOS 6.
//
// Unlike FlashLock, this never builds an AVCaptureSession: since iOS 5 the torch can be
// driven directly through lockForConfiguration/setTorchMode. That makes toggling instant,
// keeps SpringBoard's main thread free and doesn't keep the camera streaming frames.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

@interface SBAwayController : NSObject
+ (id)sharedAwayController;
- (UIView *)awayView;
- (BOOL)isLocked;
- (BOOL)handleMenuButtonDoubleTap;
- (void)restartDimTimer;
- (BOOL)cameraIsActive;
- (void)handleCameraTapGesture:(UITapGestureRecognizer *)gesture;
@end

// iOS 6 Notification Center: the sliding panel includes the bottom grabber.
@interface SBBulletinListView : UIView
- (UIView *)slidingView;
- (UITableView *)tableView;
- (void)adjustLayoutForTableViewReload;
@end

@interface SBBulletinListController : UIViewController
- (SBBulletinListView *)listView;
@end

@interface SBAwayLockBar : UIView
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
// Non-owning: cleared by the list view's dealloc hook.
static SBBulletinListView *tlNotificationView;
static UIButton *tlNotificationButton;

static void TLSetNotificationButton(UIButton *button) {
	if (tlNotificationButton == button)
		return;
	[tlNotificationButton release];
	tlNotificationButton = [button retain];
}

// Preserve existing defaults; Notification Center is opt-in and position is left.
static BOOL tlEnabled = YES;
static BOOL tlAlwaysShowButton = YES;
static BOOL tlTurnOffOnUnlock = YES;
static BOOL tlShowInNotificationCenter = NO;
static BOOL tlButtonOnRight = NO;
static BOOL tlReplaceCameraGrabber = NO;
static NSUInteger tlIconStyle;

#import "TorchLockIcons.h"
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

static BOOL TLBoolPref(NSDictionary *prefs, NSString *key, BOOL defaultValue) {
	id value = [prefs objectForKey:key];
	return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : defaultValue;
}

static void TLLoadPrefs(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:TL_PREFS_PATH];
	tlEnabled = TLBoolPref(prefs, @"Enabled", YES);
	tlAlwaysShowButton = TLBoolPref(prefs, @"AlwaysShowButton", YES);
	tlTurnOffOnUnlock = TLBoolPref(prefs, @"TurnOffOnUnlock", YES);
	tlShowInNotificationCenter = TLBoolPref(prefs, @"ShowInNotificationCenter", NO);
	tlButtonOnRight = [[prefs objectForKey:@"ButtonPosition"] isEqual:@"right"];
	tlReplaceCameraGrabber = TLBoolPref(prefs, @"ReplaceCameraGrabber", NO);
	NSArray *styles = @[@"bolt", @"classic", @"metal", @"outline", @"bulb"];
	NSUInteger style = [styles indexOfObject:[prefs objectForKey:@"IconStyle"] ?: @"bolt"];
	tlIconStyle = style == NSNotFound ? 0 : style;
}

static UIImage *TLOriginalIcon(BOOL on) {
	static UIImage *icons[2];
	if (icons[on ? 1 : 0])
		return icons[on ? 1 : 0];
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
	icons[on ? 1 : 0] = [image retain];
	return image;
}

static UIImage *TLIcon(BOOL on) {
	return tlIconStyle == 0 ? TLOriginalIcon(on) : TLStyledIcon(tlIconStyle, on);
}

// Keep the original image view and all native camera recognizers in place.
// Only the image and the controller's completed-tap action change.
static char tlCameraImageKey;
static char tlCameraLabelKey;

static UIImageView *TLCameraGrabberInBar(UIView *bar) {
	Ivar ivar = bar ? class_getInstanceVariable([bar class], "_cameraGrabber") : NULL;
	id grabber = ivar ? object_getIvar(bar, ivar) : nil;
	return [grabber isKindOfClass:[UIImageView class]] ? grabber : nil;
}

static UIImageView *TLCameraGrabber(UIView *awayView) {
	return TLCameraGrabberInBar([awayView respondsToSelector:@selector(lockBar)] ? [awayView lockBar] : nil);
}

static BOOL TLUsesCameraGrabber(void) {
	SBAwayController *away = [objc_getClass("SBAwayController") sharedAwayController];
	UIImageView *grabber = TLCameraGrabber([away awayView]);
	return tlEnabled && tlReplaceCameraGrabber && TLTorchDevice() && grabber.superview && !grabber.hidden;
}

static UIImage *TLCameraIcon(CGSize size, BOOL on) {
	static UIImage *icons[5][2];
	UIImage **cached = &icons[tlIconStyle][on ? 1 : 0];
	if (*cached && CGSizeEqualToSize((*cached).size, size))
		return *cached;
	// Badge styles fit the 30pt slot; open glyphs keep their native 24pt height.
	CGFloat edge = MIN(44, (tlIconStyle == 0 || tlIconStyle == 2) ? MIN(size.width, size.height) : size.height);
	if (edge <= 0)
		return nil;
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	[TLIcon(on) drawInRect:CGRectMake((size.width - edge) / 2, (size.height - edge) / 2, edge, edge)];
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	[*cached release];
	*cached = [image retain];
	return *cached;
}

static void TLApplyCameraImage(UIImageView *grabber) {
	if (!grabber)
		return;
	UIImage *original = objc_getAssociatedObject(grabber, &tlCameraImageKey);
	if (tlEnabled && tlReplaceCameraGrabber && TLTorchDevice() && !grabber.hidden) {
		if (!original && grabber.image) {
			objc_setAssociatedObject(grabber, &tlCameraImageKey, grabber.image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(grabber, &tlCameraLabelKey, grabber.accessibilityLabel ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
		}
		grabber.image = TLCameraIcon(grabber.bounds.size, TLTorchIsOn());
		grabber.accessibilityLabel = @"Flashlight. Swipe up for camera";
	} else if (original) {
		grabber.image = original;
		NSString *label = objc_getAssociatedObject(grabber, &tlCameraLabelKey);
		grabber.accessibilityLabel = label.length ? label : nil;
		objc_setAssociatedObject(grabber, &tlCameraImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(grabber, &tlCameraLabelKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
	}
}

static void TLUpdateCameraGrabber(void) {
	SBAwayController *away = [objc_getClass("SBAwayController") sharedAwayController];
	TLApplyCameraImage(TLCameraGrabber([away awayView]));
}

static void TLUpdateButton(void) {
	BOOL on = TLTorchIsOn();
	// A lit torch always keeps its button, or there'd be no way to turn it off.
	[tlButton setHidden:!(tlAlwaysShowButton || tlRevealed || on)];
	[tlButton setImage:TLIcon(on) forState:UIControlStateNormal];
	[tlButton setAccessibilityLabel:on ? @"Flashlight on" : @"Flashlight off"];
	[tlNotificationButton setImage:TLIcon(on) forState:UIControlStateNormal];
	[tlNotificationButton setAccessibilityLabel:on ? @"Flashlight on" : @"Flashlight off"];
	TLUpdateCameraGrabber();
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
	[out appendFormat:@"prefs: ShowInNotificationCenter=%d ButtonPosition=%@\n",
		tlShowInNotificationCenter, tlButtonOnRight ? @"right" : @"left"];
	[out appendFormat:@"prefs: ReplaceCameraGrabber=%d IconStyle=%lu cameraGrabber=%@\n",
		tlReplaceCameraGrabber, (unsigned long)tlIconStyle, TLCameraGrabber(awayView)];
	[out appendFormat:@"notificationButton=%@ superview=%@ bottomBar=%@\n",
		tlNotificationButton, [tlNotificationButton superview], [tlNotificationButton superview]];
	[out appendFormat:@"Notification Center:\n%@\n", [tlNotificationView recursiveDescription]];
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
	if (!tlEnabled)
		return;
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

static CGFloat TLButtonX(CGFloat width) {
	return tlButtonOnRight ? MAX(12, width - 44 - 12) : 12;
}

// A fixed bottom row in the sliding panel, with room to scroll the final notification above it.
@interface TorchLockNotificationBar : UIView {
	UIButton *_button;
	UITableView *_table;
}
- (UIButton *)button;
- (void)attachToTable:(UITableView *)table;
- (void)detach;
@end

@implementation TorchLockNotificationBar

- (id)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
		self.backgroundColor = [UIColor clearColor];
		_button = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
		[_button setShowsTouchWhenHighlighted:YES];
		[_button addTarget:tlController action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
		[self addSubview:_button];
	}
	return self;
}

- (UIButton *)button { return _button; }

- (void)attachToTable:(UITableView *)table {
	if (_table == table)
		return;
	[self detach];
	_table = [table retain];
	UIEdgeInsets inset = table.contentInset;
	inset.bottom += 64;
	table.contentInset = inset;
	inset = table.scrollIndicatorInsets;
	inset.bottom += 64;
	table.scrollIndicatorInsets = inset;
}

- (void)detach {
	if (_table) {
		UIEdgeInsets inset = _table.contentInset;
		inset.bottom -= 64;
		_table.contentInset = inset;
		inset = _table.scrollIndicatorInsets;
		inset.bottom -= 64;
		_table.scrollIndicatorInsets = inset;
		[_table release];
		_table = nil;
	}
	[self removeFromSuperview];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	_button.frame = CGRectMake(TLButtonX(self.bounds.size.width), 10, 44, 44);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
	// Let touches outside the icon reach the original notifications underneath.
	return CGRectContainsPoint(_button.frame, point);
}

- (void)dealloc {
	[self detach];
	[_button release];
	[super dealloc];
}

@end

static TorchLockNotificationBar *tlNotificationBar;

static void TLInstallNotificationButton(void) {
	if (!tlNotificationView)
		return;
	UITableView *table = [tlNotificationView tableView];
	UIView *panel = [tlNotificationView slidingView];
	SBAwayController *away = [objc_getClass("SBAwayController") sharedAwayController];
	BOOL show = tlEnabled && tlShowInNotificationCenter && ![away isLocked] && TLTorchDevice();
	if (!show || !table || !panel) {
		TLSetNotificationButton(nil);
		[tlNotificationBar detach];
		return;
	}
	if (!tlNotificationBar)
		tlNotificationBar = [[TorchLockNotificationBar alloc] initWithFrame:CGRectZero];
	[tlNotificationBar attachToTable:table];
	CGFloat bottom = panel.bounds.size.height - 20;
	Ivar grabberIvar = class_getInstanceVariable([tlNotificationView class], "_grabber");
	UIView *grabber = grabberIvar ? object_getIvar(tlNotificationView, grabberIvar) : nil;
	if (grabber && grabber.superview) {
		CGRect grabberFrame = [grabber convertRect:grabber.bounds toView:panel];
		if (CGRectGetMinY(grabberFrame) > 64)
			bottom = CGRectGetMinY(grabberFrame);
	}
	tlNotificationBar.frame = CGRectMake(0, MAX(0, bottom - 64), panel.bounds.size.width, 64);
	[panel addSubview:tlNotificationBar];
	TLSetNotificationButton([tlNotificationBar button]);
	[tlNotificationBar setNeedsLayout];
	[tlNotificationBar layoutIfNeeded];
	TLUpdateButton();
}

static void TLInstallButton(SBAwayController *controller) {
	TLUpdateCameraGrabber();
	if (TLUsesCameraGrabber()) {
		[tlButton removeFromSuperview];
		return;
	}
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

	// Sit just above the chosen end of the slide-to-unlock bar.
	CGFloat size = 44;
	CGRect frame = CGRectMake(TLButtonX(awayView.bounds.size.width), awayView.bounds.size.height - 96 - size - 10, size, size);
	UIView *lockBar = [awayView respondsToSelector:@selector(lockBar)] ? [awayView lockBar] : nil;
	if (lockBar && [lockBar superview]) {
		CGRect barFrame = [lockBar convertRect:[lockBar bounds] toView:awayView];
		frame.origin.y = barFrame.origin.y - size - 10;
	}
	[tlButton setFrame:frame];
	[tlButton setAutoresizingMask:UIViewAutoresizingFlexibleTopMargin |
		(tlButtonOnRight ? UIViewAutoresizingFlexibleLeftMargin : UIViewAutoresizingFlexibleRightMargin)];
	if ([tlButton superview] != awayView)
		[tlButton removeFromSuperview];
	[awayView addSubview:tlButton];
	TLUpdateButton();
}

static void TLPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object,
		CFDictionaryRef userInfo) {
	// Darwin notifications may arrive off the UI thread.
	dispatch_async(dispatch_get_main_queue(), ^{
		TLLoadPrefs();
		if (!tlEnabled && TLTorchIsOn())
			TLSetTorch(NO);
		TLInstallButton([objc_getClass("SBAwayController") sharedAwayController]);
		TLInstallNotificationButton();
	});
}

%hook SBBulletinListView

- (id)initWithFrame:(CGRect)frame delegate:(id)delegate {
	id view = %orig;
	if (view) {
		tlNotificationView = view;
		TLInstallNotificationButton();
	}
	return view;
}

- (void)layoutForOrientation:(UIInterfaceOrientation)orientation {
	%orig;
	tlNotificationView = self;
	TLInstallNotificationButton();
}

- (void)dealloc {
	if (tlNotificationView == self) {
		[tlNotificationBar detach];
		tlNotificationView = nil;
		TLSetNotificationButton(nil);
	}
	%orig;
}

%end

%hook SBBulletinListController

- (void)prepareToShowListViewAnimated:(BOOL)animated aboveBanner:(BOOL)aboveBanner {
	%orig;
	tlNotificationView = [self listView];
	TLInstallNotificationButton();
}

%end

%hook SBAwayController

- (void)handleCameraTapGesture:(UITapGestureRecognizer *)gesture {
	if (TLUsesCameraGrabber() && ![self cameraIsActive]) {
		if (gesture.state == UIGestureRecognizerStateRecognized)
			TLToggle();
		return;
	}
	%orig;
}

- (void)activate {
	%orig;
	tlRevealed = NO;
	TLInstallButton(self);
	TLInstallNotificationButton();
}

- (void)didFinishAnimatingOut {
	%orig;
	if (tlEnabled && tlTurnOffOnUnlock && TLTorchIsOn())
		TLSetTorch(NO);
	TLInstallNotificationButton();
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

%hook SBAwayLockBar

- (void)layoutSubviews {
	%orig;
	// awayView is lazily created. Do not fetch it inside lock-bar initialization.
	TLApplyCameraImage(TLCameraGrabberInBar(self));
}

- (void)setShowsCameraGrabber:(BOOL)show {
	%orig;
	TLApplyCameraImage(TLCameraGrabberInBar(self));
}

- (void)setOrientation:(UIInterfaceOrientation)orientation {
	%orig;
	TLApplyCameraImage(TLCameraGrabberInBar(self));
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
