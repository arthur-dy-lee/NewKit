#import "MenuBarNativeBridge.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>

static id _Nullable AXAttribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static NSArray *AXChildren(AXUIElementRef element) {
    id value = AXAttribute(element, kAXChildrenAttribute);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static BOOL AXFrame(AXUIElementRef element, CGRect *frame) {
    id position = AXAttribute(element, kAXPositionAttribute);
    id size = AXAttribute(element, kAXSizeAttribute);
    if (!position || !size ||
        CFGetTypeID((__bridge CFTypeRef)position) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)size) != AXValueGetTypeID()) return NO;
    CGPoint origin = CGPointZero;
    CGSize dimensions = CGSizeZero;
    if (!AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &origin) ||
        !AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &dimensions)) return NO;
    *frame = (CGRect){origin, dimensions};
    return dimensions.width > 0 && dimensions.height > 0;
}

// A hosted status item may contain one or more MenuBarAgent wrapper elements
// before the element belonging to the app. Looking only at the immediate child
// misses those icons on some macOS/menu extra implementations.
static pid_t HostedOwnerPID(AXUIElementRef element, pid_t agentPID, NSUInteger depth) {
    pid_t pid = 0;
    if (AXUIElementGetPid(element, &pid) == kAXErrorSuccess &&
        pid > 0 && pid != agentPID) return pid;
    if (depth == 0) return 0;
    for (id childObject in AXChildren(element)) {
        AXUIElementRef child = (__bridge AXUIElementRef)childObject;
        AXUIElementSetMessagingTimeout(child, 0.25);
        pid_t owner = HostedOwnerPID(child, agentPID, depth - 1);
        if (owner > 0) return owner;
    }
    return 0;
}

@implementation MenuBarNativeItem

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                   frame:(CGRect)frame
                             screenFrame:(CGRect)screenFrame {
    self = [super init];
    if (!self) return nil;
    _bundleIdentifier = [bundleIdentifier copy];
    _frame = frame;
    _screenFrame = screenFrame;
    return self;
}

@end

static NSArray<MenuBarNativeItem *> *HostedMenuBarItems(void) {
    NSRunningApplication *agent = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return @[];

    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.25);
    id windowValue = AXAttribute(root, kAXWindowsAttribute);
    NSArray *windows = [windowValue isKindOfClass:NSArray.class]
        ? windowValue : AXChildren(root);
    NSMutableArray<MenuBarNativeItem *> *items = [NSMutableArray array];
    for (id windowObject in windows) {
        AXUIElementRef window = (__bridge AXUIElementRef)windowObject;
        AXUIElementSetMessagingTimeout(window, 0.25);
        if (![AXAttribute(window, kAXRoleAttribute) isEqual:@"AXWindow"]) continue;
        CGRect screenFrame;
        if (!AXFrame(window, &screenFrame)) continue;
        for (id hostObject in AXChildren(window)) {
            AXUIElementRef host = (__bridge AXUIElementRef)hostObject;
            AXUIElementSetMessagingTimeout(host, 0.25);
            CGRect frame;
            // Menu bar windows can clip an item by a fraction of a point, or
            // leave part of a wide item outside the visible region.
            if (!AXFrame(host, &frame) || !CGRectIntersectsRect(screenFrame, frame)) continue;

            pid_t ownerPID = HostedOwnerPID(host, agent.processIdentifier, 4);
            if (ownerPID <= 0 || ownerPID == agent.processIdentifier) continue;
            NSString *bundle = [NSRunningApplication
                runningApplicationWithProcessIdentifier:ownerPID].bundleIdentifier;
            if (!bundle.length) continue;
            [items addObject:[[MenuBarNativeItem alloc]
                initWithBundleIdentifier:bundle frame:frame screenFrame:screenFrame]];
        }
    }
    CFRelease(root);
    return items;
}

// NSStatusItem is not itself exposed in MenuBarAgent's AX tree. Its button's
// AppKit window gives us a precise on-screen rectangle; match that to the host
// on the same Quartz display. This distinguishes NewKit's reveal control from
// its ordinary menu icon, even though both have the same bundle identifier.
static BOOL StatusItemLocation(NSStatusItem *statusItem, CGRect *buttonFrame,
                               CGRect *displayBounds) {
    NSStatusBarButton *button = statusItem.button;
    NSWindow *window = button.window;
    NSNumber *display = window.screen.deviceDescription[@"NSScreenNumber"];
    if (!button || !window || !display) return NO;
    NSRect local = [button convertRect:button.bounds toView:nil];
    *buttonFrame = [window convertRectToScreen:local];
    *displayBounds = CGDisplayBounds((CGDirectDisplayID)display.unsignedIntValue);
    return CGRectGetWidth(*buttonFrame) > 0 && CGRectGetHeight(*buttonFrame) > 0 &&
        CGRectGetWidth(*displayBounds) > 0 && CGRectGetHeight(*displayBounds) > 0;
}

static MenuBarNativeItem *StatusItemHost(NSArray<MenuBarNativeItem *> *items,
                                         NSString *ownBundle, CGRect buttonFrame,
                                         CGRect displayBounds) {
    if (!ownBundle.length) return nil;
    CGFloat buttonX = CGRectGetMidX(buttonFrame);
    MenuBarNativeItem *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    CGFloat secondDistance = CGFLOAT_MAX;
    for (MenuBarNativeItem *item in items) {
        if (![item.bundleIdentifier isEqualToString:ownBundle]) continue;
        CGPoint center = CGPointMake(CGRectGetMidX(item.frame), CGRectGetMidY(item.frame));
        if (!CGRectContainsPoint(displayBounds, center)) continue;
        CGFloat distance = fabs(center.x - buttonX);
        if (distance < bestDistance) {
            secondDistance = bestDistance;
            bestDistance = distance;
            best = item;
        } else if (distance < secondDistance) {
            secondDistance = distance;
        }
    }
    if (!best) return nil;
    // A wrong target would move an icon across the ordinary NewKit menu item.
    // Reject missing, offset, and equally plausible matches instead of guessing.
    CGFloat tolerance = MAX(5.0, MIN(CGRectGetWidth(buttonFrame),
                                     CGRectGetWidth(best.frame)) * 0.45);
    if (bestDistance > tolerance || secondDistance - bestDistance < 4.0) return nil;
    return best;
}

static BOOL HasMenuBarExtra(pid_t pid) {
    AXUIElementRef root = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(root, 0.25);

    // Some apps expose their own status items here. Others, including Little
    // Snitch Agent on macOS 27, are visible only in MenuBarAgent's host tree.
    id extras = AXAttribute(root, CFSTR("AXExtrasMenuBar"));
    BOOL found = NO;
    if (extras && CFGetTypeID((__bridge CFTypeRef)extras) == AXUIElementGetTypeID()) {
        AXUIElementRef extrasElement = (__bridge AXUIElementRef)extras;
        AXUIElementSetMessagingTimeout(extrasElement, 0.25);
        found = AXChildren(extrasElement).count > 0;
    }

    if (!found) {
        // Some older status-item implementations still expose a direct child.
        for (id child in AXChildren(root)) {
            AXUIElementRef childElement = (__bridge AXUIElementRef)child;
            AXUIElementSetMessagingTimeout(childElement, 0.25);
            NSString *role = AXAttribute(childElement, kAXRoleAttribute);
            if ([role isEqual:@"AXMenuExtra"] || [role isEqual:@"AXMenuBarItem"]) {
                found = YES;
                break;
            }
        }
    }
    CFRelease(root);
    return found;
}

@implementation MenuBarNativeBridge {
    void *_framework;
    Class _configurationClass;
    Class _assertionClass;
    SEL _configurationSelector;
    SEL _activationSelector;
    SEL _invalidationSelector;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY);
    _configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    _assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    _configurationSelector = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
    _activationSelector = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
    _invalidationSelector = NSSelectorFromString(@"invalidate");
    return self;
}

- (BOOL)isAvailable {
    return _framework &&
        [_configurationClass instancesRespondToSelector:_configurationSelector] &&
        [_assertionClass instancesRespondToSelector:_activationSelector] &&
        [_assertionClass instancesRespondToSelector:_invalidationSelector];
}

- (nullable NSArray<NSString *> *)discoverBundleIdentifiers {
    if (!AXIsProcessTrusted()) return nil;
    NSArray<NSRunningApplication *> *running = NSWorkspace.sharedWorkspace.runningApplications;
    NSMutableSet<NSString *> *bundles = [NSMutableSet set];
    for (MenuBarNativeItem *item in HostedMenuBarItems()) {
        [bundles addObject:item.bundleIdentifier];
    }
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 8;
    queue.qualityOfService = NSQualityOfServiceUserInitiated;
    for (NSRunningApplication *app in running) {
        NSString *bundle = [app.bundleIdentifier copy];
        pid_t pid = app.processIdentifier;
        if (!bundle.length || pid <= 0) continue;
        [queue addOperationWithBlock:^{
            if (!HasMenuBarExtra(pid)) return;
            @synchronized (bundles) { [bundles addObject:bundle]; }
        }];
    }
    [queue waitUntilAllOperationsAreFinished];
    return [[bundles allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray<MenuBarNativeItem *> *)visibleMenuBarItems {
    return AXIsProcessTrusted() ? HostedMenuBarItems() : @[];
}

- (nullable MenuBarNativeItem *)visibleMenuBarItemForStatusItem:(NSStatusItem *)statusItem {
    if (!AXIsProcessTrusted()) return nil;
    CGRect buttonFrame, displayBounds;
    if (!StatusItemLocation(statusItem, &buttonFrame, &displayBounds)) return nil;
    return StatusItemHost(HostedMenuBarItems(), NSBundle.mainBundle.bundleIdentifier,
                          buttonFrame, displayBounds);
}

- (nullable id)activateAllowingBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                     completion:(void (^)(NSError * _Nullable))completion {
    if (!self.isAvailable) return nil;
    id assertion = nil;
    @try {
        // The observed assessment interface does not cover all Control Center
        // extras. Preserve every known system identifier.
        NSArray<NSNumber *> *systemItems = @[@0, @1, @2, @3, @4, @5, @6, @7, @8];
        id (*makeConfiguration)(id, SEL, id, id) = (void *)objc_msgSend;
        id configuration = makeConfiguration([_configurationClass alloc],
                                              _configurationSelector,
                                              systemItems, bundleIdentifiers);
        assertion = [[_assertionClass alloc] init];
        if (!configuration || !assertion) return nil;

        void (*activate)(id, SEL, id, void (^)(NSError *)) = (void *)objc_msgSend;
        activate(assertion, _activationSelector, configuration, ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        });
        return assertion;
    } @catch (NSException *exception) {
        [self invalidateAssertion:assertion];
        NSLog(@"Menu bar hiding unavailable: %@", exception.reason);
        return nil;
    }
}

- (void)invalidateAssertion:(id)assertion {
    if (!assertion || ![assertion respondsToSelector:_invalidationSelector]) return;
    @try {
        void (*invalidate)(id, SEL) = (void *)objc_msgSend;
        invalidate(assertion, _invalidationSelector);
    } @catch (NSException *exception) {
        NSLog(@"Could not restore menu bar visibility: %@", exception.reason);
    }
}

@end
