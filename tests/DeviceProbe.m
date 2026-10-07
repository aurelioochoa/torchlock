// Device-only integration probe. Included in DEBUG=1 packages, never releases.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

@interface NSObject (TLProbePrivate)
+ (id)sharedAwayController;
+ (id)sharedInstance;
- (BOOL)isLocked;
- (UIView *)awayView;
- (UIView *)listView;
- (UITableView *)tableView;
- (UIView *)slidingView;
- (void)adjustLayoutForTableViewReload;
- (void)registerListener:(id)listener forName:(NSString *)name;
- (void)setHandled:(BOOL)handled;
- (NSString *)recursiveDescription;
- (UIView *)lockBar;
- (BOOL)cameraIsActive;
- (BOOL)cameraIsVisible;
- (void)handleCameraTapGesture:(UITapGestureRecognizer *)gesture;
- (void)handleCameraPanGesture:(UIPanGestureRecognizer *)gesture;
- (void)dismissCameraAnimated:(BOOL)animated;
- (void)_restoreWindowOrientationAndDelegate;
@end

static UIView *savedHeader;
static UILabel *fixture;
static UIView *savedFooter;
static UILabel *longContent;
static NSUncaughtExceptionHandler *previousExceptionHandler;

static UIImageView *CameraGrabber(id away) {
	UIView *bar = [[away awayView] lockBar];
	Ivar ivar = bar ? class_getInstanceVariable([bar class], "_cameraGrabber") : NULL;
	return ivar ? object_getIvar(bar, ivar) : nil;
}

static NSString *ImageFingerprint(UIImage *image) {
	NSData *png = UIImagePNGRepresentation(image);
	const unsigned char *bytes = png.bytes;
	uint64_t hash = 14695981039346656037ULL;
	for (NSUInteger i = 0; i < png.length; i++)
		hash = (hash ^ bytes[i]) * 1099511628211ULL;
	return [NSString stringWithFormat:@"%016llx", hash];
}

// Feed the native callbacks recognizer values to exercise the camera pipeline.
// This verifies callback behavior; a physical swipe remains a separate check.
@interface TorchLockProbeTap : UITapGestureRecognizer
@property(nonatomic, assign) UIGestureRecognizerState probeState;
@end
@implementation TorchLockProbeTap
- (UIGestureRecognizerState)state { return _probeState; }
@end

@interface TorchLockProbePan : UIPanGestureRecognizer
@property(nonatomic, assign) UIGestureRecognizerState probeState;
@property(nonatomic, assign) CGFloat distance;
@property(nonatomic, assign) CGFloat speed;
@end
@implementation TorchLockProbePan
- (UIGestureRecognizerState)state { return _probeState; }
- (CGPoint)translationInView:(UIView *)view { return CGPointMake(0, _distance); }
- (CGPoint)velocityInView:(UIView *)view { return CGPointMake(0, _speed); }
- (CGPoint)locationInView:(UIView *)view {
	id away = [objc_getClass("SBAwayController") sharedAwayController];
	UIImageView *grabber = CameraGrabber(away);
	return [grabber convertPoint:CGPointMake(15, 26) toView:view];
}
@end

// UIKit/SpringBoard may retain an unsafe tracking reference after a callback.
// Keep fixtures alive for the debug probe's lifetime, as native recognizers are.
static TorchLockProbeTap *probeTap;
static TorchLockProbePan *probePan;

static void RecordException(NSException *exception) {
	[[NSString stringWithFormat:@"%@\n%@\n", exception, exception.callStackSymbols]
		writeToFile:@"/tmp/torchlock-test-exception.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	if (previousExceptionHandler)
		previousExceptionHandler(exception);
}

// Native Notification Center expects these messages on even a table header.
@interface TorchLockProbeHeaderFixture : UILabel
@end
@implementation TorchLockProbeHeaderFixture
- (void)setShowsLinen:(BOOL)value {}
- (void)setGradientAlpha:(CGFloat)value {}
- (void)adjustContents {}
@end

static UIButton *FindButton(UIView *view) {
	if ([view isKindOfClass:[UIButton class]] &&
		[[view accessibilityLabel] hasPrefix:@"Flashlight "])
		return (UIButton *)view;
	for (UIView *child in view.subviews) {
		UIButton *button = FindButton(child);
		if (button)
			return button;
	}
	return nil;
}

static NSDictionary *ButtonState(UIButton *button) {
	if (!button)
		return @{ @"present": @NO };
	return @{ @"present": @YES, @"hidden": @(button.hidden),
		@"x": @(button.frame.origin.x), @"y": @(button.frame.origin.y),
		@"width": @(button.frame.size.width), @"height": @(button.frame.size.height),
		@"hitTest": @(button.window && [button.window hitTest:[button convertPoint:CGPointMake(22, 22) toView:button.window] withEvent:nil] == button),
		@"windowY": @([button convertRect:button.bounds toView:button.window].origin.y),
		@"image": ImageFingerprint([button imageForState:UIControlStateNormal]),
		@"label": button.accessibilityLabel ?: @"", @"parentWidth": @(button.superview.bounds.size.width) };
}

@interface TorchLockDeviceProbe : NSObject
@end

@implementation TorchLockDeviceProbe

- (void)activator:(id)activator receiveEvent:(id)event forListenerName:(NSString *)name {
	NSDictionary *command = [NSDictionary dictionaryWithContentsOfFile:@"/tmp/torchlock-test-command.plist"];
	if (!command)
		return;
	[[NSFileManager defaultManager] removeItemAtPath:@"/tmp/torchlock-test-command.plist" error:NULL];
	NSString *action = command[@"action"];
	id away = [objc_getClass("SBAwayController") sharedAwayController];
	if ([action isEqual:@"open-settings"])
		[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"prefs:root=TorchLock"]];
	if ([action isEqual:@"inspect-camera"]) {
		NSMutableString *dump = [NSMutableString stringWithFormat:@"%@\n", [[away awayView] recursiveDescription]];
		int count = objc_getClassList(NULL, 0);
		Class *classes = malloc(sizeof(Class) * count);
		count = objc_getClassList(classes, count);
		for (int i = 0; i < count; i++) {
			NSString *name = NSStringFromClass(classes[i]);
			if (![name hasPrefix:@"SBAway"] && ![name hasPrefix:@"SBLock"] && ![name hasPrefix:@"SBCamera"])
				continue;
			[dump appendFormat:@"\nCLASS %@\n", name];
			unsigned int n = 0;
			Ivar *ivars = class_copyIvarList(classes[i], &n);
			for (unsigned int j = 0; j < n; j++)
				[dump appendFormat:@"ivar %s %s\n", ivar_getName(ivars[j]), ivar_getTypeEncoding(ivars[j])];
			free(ivars);
			Method *methods = class_copyMethodList(classes[i], &n);
			for (unsigned int j = 0; j < n; j++)
				[dump appendFormat:@"method %s %s\n", sel_getName(method_getName(methods[j])), method_getTypeEncoding(methods[j])];
			free(methods);
		}
		free(classes);
		[dump writeToFile:@"/tmp/torchlock-camera-inspect.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	}
	if ([action isEqual:@"tap-camera"] || [action isEqual:@"cancel-camera-tap"]) {
		if (!probeTap) probeTap = [[TorchLockProbeTap alloc] init];
		TorchLockProbeTap *tap = probeTap;
		tap.probeState = [action isEqual:@"tap-camera"] ? UIGestureRecognizerStateRecognized : UIGestureRecognizerStateCancelled;
		[away handleCameraTapGesture:tap];
	} else if ([action isEqual:@"swipe-camera"] || [action isEqual:@"cancel-camera-pan"]) {
		if (!probePan) probePan = [[TorchLockProbePan alloc] init];
		TorchLockProbePan *pan = probePan;
		pan.distance = 0; pan.speed = 0;
		pan.probeState = UIGestureRecognizerStateBegan;
		[away handleCameraPanGesture:pan];
		pan.probeState = UIGestureRecognizerStateChanged;
		pan.distance = [action isEqual:@"swipe-camera"] ? -420 : -20;
		[away handleCameraPanGesture:pan];
		pan.probeState = [action isEqual:@"swipe-camera"] ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateCancelled;
		pan.speed = [action isEqual:@"swipe-camera"] ? -1000 : 0;
		[away handleCameraPanGesture:pan];
	} else if ([action isEqual:@"dismiss-camera"]) {
		// Direct callback injection bypasses the system gesture's window cleanup.
		// Restore the native delegate before destroying the camera page controller.
		[away _restoreWindowOrientationAndDelegate];
		[away dismissCameraAnimated:YES];
	}
	id listController = [objc_getClass("SBBulletinListController") sharedInstance];
	UIView *list = [listController listView];
	UITableView *table = [(id)list tableView];
	if ([action isEqual:@"prefs"]) {
		[command[@"prefs"] writeToFile:@"/var/mobile/Library/Preferences/com.aurelio.torchlock.plist" atomically:YES];
		CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
			CFSTR("com.aurelio.torchlock/prefs-changed"), NULL, NULL, YES);
	} else if ([action isEqual:@"reload-prefs"]) {
		CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
			CFSTR("com.aurelio.torchlock/prefs-changed"), NULL, NULL, YES);
	} else if ([action isEqual:@"tap-notification"]) {
		[FindButton(list) sendActionsForControlEvents:UIControlEventTouchUpInside];
	} else if ([action isEqual:@"tap-lock"]) {
		[FindButton([away awayView]) sendActionsForControlEvents:UIControlEventTouchUpInside];
	} else if ([action isEqual:@"long-content"]) {
		if (!longContent) {
			savedFooter = [table.tableFooterView retain];
			longContent = [[TorchLockProbeHeaderFixture alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, 960)];
			longContent.text = @"Long notification content fixture";
			table.tableFooterView = longContent;
			[(id)list adjustLayoutForTableViewReload];
		}
	} else if ([action isEqual:@"scroll-bottom"]) {
		[table setContentOffset:CGPointMake(0, MAX(-table.contentInset.top,
			table.contentSize.height - table.bounds.size.height + table.contentInset.bottom)) animated:NO];
	} else if ([action isEqual:@"restore-content"]) {
		if (longContent) {
			table.tableFooterView = savedFooter;
			[savedFooter release]; savedFooter = nil;
			[longContent release]; longContent = nil;
			[(id)list adjustLayoutForTableViewReload];
			[table setContentOffset:CGPointMake(0, -table.contentInset.top) animated:NO];
		}
	} else if ([action isEqual:@"fixture"]) {
		if (!fixture) {
			savedHeader = [table.tableHeaderView retain];
			fixture = [[TorchLockProbeHeaderFixture alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, 23)];
			fixture.text = @"Existing header fixture";
			table.tableHeaderView = fixture;
			[(id)list adjustLayoutForTableViewReload];
		}
	} else if ([action isEqual:@"restore-header"]) {
		if (fixture) {
			table.tableHeaderView = savedHeader;
			[savedHeader release];
			savedHeader = nil;
			[fixture release];
			fixture = nil;
			[(id)list adjustLayoutForTableViewReload];
		}
	}
	// Wait for the real Darwin callback, layout and hardware state to settle.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		id currentAway = [objc_getClass("SBAwayController") sharedAwayController];
		UIView *currentList = [listController listView];
		UITableView *currentTable = [(id)currentList tableView];
		AVCaptureDevice *device = nil;
		for (AVCaptureDevice *candidate in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
			if (candidate.hasTorch) { device = candidate; break; }
		UIView *header = currentTable.tableHeaderView;
		UIImageView *camera = CameraGrabber(currentAway);
		NSMutableArray *gestures = [NSMutableArray array];
		for (UIGestureRecognizer *gesture in camera.gestureRecognizers)
			[gestures addObject:@{ @"class": NSStringFromClass([gesture class]),
				@"address": [NSString stringWithFormat:@"%p", gesture], @"enabled": @(gesture.enabled),
				@"delegate": [NSString stringWithFormat:@"%p", gesture.delegate] }];
		if ([action isEqual:@"save-icons"]) {
			UIImage *icon = [FindButton([currentAway awayView]) imageForState:UIControlStateNormal];
			[UIImagePNGRepresentation(icon) writeToFile:@"/tmp/torchlock-icon.png" atomically:YES];
			[UIImagePNGRepresentation(camera.image) writeToFile:@"/tmp/torchlock-camera-icon.png" atomically:YES];
		}
		UIButton *notificationButton = FindButton(currentList);
		UIView *bar = notificationButton.superview;
		UIView *panel = [(id)currentList slidingView];
		Ivar grabberIvar = currentList ? class_getInstanceVariable([currentList class], "_grabber") : NULL;
		UIView *grabber = grabberIvar ? object_getIvar(currentList, grabberIvar) : nil;
		CGFloat grabberY = grabber ? [grabber convertRect:grabber.bounds toView:panel].origin.y : panel.bounds.size.height - 20;
		NSDictionary *state = @{
			@"nonce": command[@"nonce"] ?: @"", @"locked": @([currentAway isLocked]),
			@"torchMode": @(device.torchMode), @"torchActive": @(device.torchActive),
			@"cameraActive": @([currentAway cameraIsActive]), @"cameraVisible": @([currentAway cameraIsVisible]),
			@"cameraGrabber": @{ @"present": @(camera != nil), @"hidden": @(camera.hidden),
				@"image": ImageFingerprint(camera.image),
				@"x": @(camera.frame.origin.x), @"y": @(camera.frame.origin.y),
				@"width": @(camera.frame.size.width), @"height": @(camera.frame.size.height),
				@"gestures": gestures, @"label": camera.accessibilityLabel ?: @"" },
			@"lockButton": ButtonState(FindButton([currentAway awayView])),
			@"notificationButton": ButtonState(notificationButton),
			@"barPinned": @(bar && bar.superview == panel),
			@"barBackgroundAlpha": @(bar.backgroundColor ? CGColorGetAlpha(bar.backgroundColor.CGColor) : 0),
			@"blankTouchesPass": @(bar && ![bar pointInside:CGPointMake(bar.bounds.size.width / 2, 32) withEvent:nil]),
			@"barY": @(bar.frame.origin.y), @"barHeight": @(bar.frame.size.height),
			@"grabberY": @(grabberY), @"bottomInset": @(currentTable.contentInset.bottom),
			@"indicatorBottomInset": @(currentTable.scrollIndicatorInsets.bottom),
			@"contentBottomY": @([currentTable convertPoint:CGPointMake(0, currentTable.contentSize.height) toView:panel].y),
			@"headerClass": header ? NSStringFromClass([header class]) : @"nil",
			@"headerHeight": @(header.frame.size.height),
			@"fixtureDirect": @(fixture && header == fixture),
			@"fixtureWrapped": @(fixture && fixture.superview == header && header != fixture),
			@"fixtureY": @(fixture.frame.origin.y)
		};
		NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:NULL];
		[json writeToFile:@"/tmp/torchlock-test.json" atomically:YES];
	});
	[event setHandled:YES];
}

- (NSString *)activator:(id)activator requiresLocalizedTitleForListenerName:(NSString *)name {
	return @"TorchLock device test probe";
}
- (NSString *)activator:(id)activator requiresLocalizedGroupForListenerName:(NSString *)name {
	return @"TorchLock";
}
@end

__attribute__((constructor)) static void RegisterProbe(void) {
	@autoreleasepool {
		previousExceptionHandler = NSGetUncaughtExceptionHandler();
		NSSetUncaughtExceptionHandler(RecordException);
		// Tweak.x opens libactivator during its constructor. Defer until all constructors finish.
		dispatch_async(dispatch_get_main_queue(), ^{
			id activator = [objc_getClass("LAActivator") sharedInstance];
			[activator registerListener:[[TorchLockDeviceProbe alloc] init] forName:@"com.aurelio.torchlock.test"];
		});
	}
}
