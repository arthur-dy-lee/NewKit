// clang -fobjc-arc -fmodules -I Sources/App Tools/test_menu_bar_pointer_safety.m \
//   -framework AppKit -framework ApplicationServices -o /tmp/newkit-pointer-checks
// NEWKIT_BRIDGE_SOURCE can point to a pre-fix bridge for historical replay.
#ifndef NEWKIT_BRIDGE_SOURCE
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#pragma GCC poison CGEventPost CGEventPostToPid CGEventPostToPSN CGEventTapPostEvent
#pragma GCC poison CGWarpMouseCursorPosition CGDisplayMoveCursorToPoint CGAssociateMouseAndMouseCursorPosition
#pragma GCC poison CGDisplayHideCursor CGDisplayShowCursor
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../Sources/App/MenuBarNativeBridge.m"
#pragma clang diagnostic pop

int main(void) {
    puts("Menu bar bridge builds without posting mouse events or controlling the cursor.");
    return 0;
}
#else
// This runs the actual drag implementation with simulated hardware and event
// posting. No event is sent to the desktop and no real cursor is hidden/warped.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <time.h>
#import <unistd.h>

typedef struct {
    CGEventType type;
    CGPoint point;
    CGEventFlags flags;
} PostedEvent;

static PostedEvent events[256];
static int eventCount, warpCount, hideCount, showCount, checks;
static double now, idle, inputAt, cancelAt, stallAt;
static uint32_t hardwareCount;
static CGPoint pointer, resumedPointer;
static BOOL heldButton, heldKey, snapshotUnavailable, sourceUnavailable, hideUnavailable;
static CGEventFlags hardwareFlags;

static void Check(BOOL condition, NSString *context) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", context.UTF8String);
        exit(1);
    }
    checks++;
}

static void Reset(void) {
    eventCount = warpCount = hideCount = showCount = 0;
    now = 0;
    idle = 10;
    inputAt = cancelAt = stallAt = INFINITY;
    hardwareCount = 0;
    pointer = CGPointMake(640, 480);
    resumedPointer = CGPointMake(720, 350);
    heldButton = heldKey = snapshotUnavailable = sourceUnavailable = hideUnavailable = NO;
    hardwareFlags = 0;
}

static CGEventRef TestCurrentEvent(CGEventSourceRef source) {
    if (snapshotUnavailable) return NULL;
    return CGEventCreateMouseEvent(source, kCGEventMouseMoved, pointer, kCGMouseButtonLeft);
}

static CGEventSourceRef TestSource(CGEventSourceStateID state) {
    return sourceUnavailable ? NULL : CGEventSourceCreate(state);
}

static void TestPost(CGEventTapLocation location, CGEventRef event) {
    CGEventSourceRef source = CGEventCreateSourceFromEvent(event);
    CGEventSourceStateID state = CGEventSourceGetSourceStateID(source);
#ifndef NEWKIT_LEGACY_REPLAY
    Check(state != kCGEventSourceStateHIDSystemState, @"synthetic input must not use hardware state");
    Check(CGEventSourceGetLocalEventsSuppressionInterval(source) == 0,
          @"synthetic events must not suppress hardware input");
    Check(CGEventSourceGetLocalEventsFilterDuringSuppressionState(source,
              kCGEventSuppressionStateRemoteMouseDrag) == kCGEventFilterMaskPermitAllEvents,
          @"user input remains enabled during drag");
    Check(CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 0x4E4B4D454E55,
          @"synthetic input has a diagnostic tag");
#endif
    if (state == kCGEventSourceStateHIDSystemState) hardwareCount++;
    CFRelease(source);
    Check(eventCount < 256, @"event replay fits its buffer");
    events[eventCount++] = (PostedEvent){ CGEventGetType(event), CGEventGetLocation(event),
                                        CGEventGetFlags(event) };
    pointer = CGEventGetLocation(event);
}

static CGError TestWarp(CGPoint point) {
    warpCount++;
    pointer = point;
    return kCGErrorSuccess;
}

static CGError TestHide(CGDirectDisplayID display) {
    if (hideUnavailable) return kCGErrorFailure;
    hideCount++;
    return kCGErrorSuccess;
}

static CGError TestShow(CGDirectDisplayID display) {
    showCount++;
    return kCGErrorSuccess;
}

static uint32_t TestCounter(CGEventSourceStateID state, CGEventType type) {
    return type == kCGAnyInputEventType || type == kCGEventMouseMoved ? hardwareCount : 0;
}

static CFTimeInterval TestIdle(CGEventSourceStateID state, CGEventType type) { return idle; }
static bool TestButton(CGEventSourceStateID state, CGMouseButton button) {
    return heldButton && button == kCGMouseButtonLeft;
}
static bool TestKey(CGEventSourceStateID state, CGKeyCode key) { return heldKey && key == 0; }
static CGEventFlags TestFlags(CGEventSourceStateID state) { return hardwareFlags; }
static uint64_t TestClock(clockid_t clock) { return (uint64_t)llround(now * 1e9); }
static CFAbsoluteTime TestAbsoluteTime(void) { return now; }
static CGError TestDisplayAtPoint(CGPoint point, uint32_t capacity,
                                  CGDirectDisplayID *displays, uint32_t *count) {
    *count = 1;
    displays[0] = point.x >= 2560 ? 2 : point.y < 0 ? 3 : 1;
    return kCGErrorSuccess;
}
static CGRect TestDisplayBounds(CGDirectDisplayID display) {
    return CGRectMake(display == 2 ? 2560 : 0, display == 3 ? -1440 : 0, 2560, 1440);
}

static int TestSleep(useconds_t duration) {
    now += (double)duration / 1e6;
    if (now >= stallAt) {
        now += 3;
        stallAt = INFINITY;
    }
    if (now >= inputAt) {
        hardwareCount++;
        pointer = resumedPointer;
        inputAt = INFINITY;
    }
    return 0;
}

#define CGEventCreate TestCurrentEvent
#define CGEventSourceCreate TestSource
#define CGEventPost TestPost
#define CGWarpMouseCursorPosition TestWarp
#define CGDisplayHideCursor TestHide
#define CGDisplayShowCursor TestShow
#define CGEventSourceCounterForEventType TestCounter
#define CGEventSourceSecondsSinceLastEventType TestIdle
#define CGEventSourceButtonState TestButton
#define CGEventSourceKeyState TestKey
#define CGEventSourceFlagsState TestFlags
#define clock_gettime_nsec_np TestClock
#define CFAbsoluteTimeGetCurrent TestAbsoluteTime
#define CGGetDisplaysWithPoint TestDisplayAtPoint
#define CGDisplayBounds TestDisplayBounds
#define usleep TestSleep

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wmismatched-parameter-types"
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#include NEWKIT_BRIDGE_SOURCE
#pragma clang diagnostic pop

static int Count(CGEventType type) {
    int count = 0;
    for (int index = 0; index < eventCount; index++) if (events[index].type == type) count++;
    return count;
}

static MenuBarMoveResult Run(void) {
    MenuBarNativeItem *source = [[MenuBarNativeItem alloc]
        initWithBundleIdentifier:@"source" frame:CGRectMake(1000, 0, 30, 30)
        screenFrame:CGRectMake(0, 0, 2560, 30)];
    MenuBarNativeItem *target = [[MenuBarNativeItem alloc]
        initWithBundleIdentifier:@"target" frame:CGRectMake(2000, 0, 30, 30)
        screenFrame:CGRectMake(0, 0, 2560, 30)];
#ifdef NEWKIT_LEGACY_REPLAY
    return DragItem(source, target, YES, nil, @"replay")
        ? MenuBarMoveResultMoved : MenuBarMoveResultFailed;
#else
    MenuBarMoveResult result = DragItem(source, target, YES, nil, @"replay",
                                        ^BOOL(void) { return now >= cancelAt; });
    Check(hideCount == showCount, @"cursor visibility must be restored on every exit");
    return result;
#endif
}

int main(void) {
    @autoreleasepool {
#ifdef NEWKIT_LEGACY_REPLAY
        Reset(); idle = 0.05;
        Run();
        Check(Count(kCGEventLeftMouseDragged) == 16 && warpCount == 1,
              @"legacy version takes over the pointer during active input");
        Reset(); inputAt = 0.45;
        Run();
        Check(Count(kCGEventLeftMouseDragged) == 16 && warpCount == 1
                  && !CGPointEqualToPoint(pointer, resumedPointer),
              @"legacy version continues dragging and warps over resumed movement");
        printf("Reproduced legacy bug: 16 synthetic drag steps during input, then stale cursor warp.\n");
#else
        Reset(); idle = 0.05;
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0 && warpCount == 0,
              @"recent movement defers without synthetic input");

        Reset(); pointer = CGPointMake(1650, 20);
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0,
              @"stationary pointer at the menu bar defers");
        Reset(); pointer = CGPointMake(1650, 40);
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0,
              @"approaching the lower edge of the menu bar defers");
        Reset(); pointer = CGPointMake(4200, 20);
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0,
              @"menu bar on another display also blocks a drag");
        Reset(); pointer = CGPointMake(1600, -1420);
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0,
              @"display above the main screen uses its own top edge");

        Reset(); heldButton = YES;
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0, @"held mouse blocks drag");
        Reset(); heldKey = YES;
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0, @"held nonmodifier key blocks drag");
        Reset(); hardwareFlags = kCGEventFlagMaskCommand;
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0, @"held modifier blocks drag");

        for (NSNumber *invalid in @[@(NAN), @(INFINITY), @(-1)]) {
            Reset(); idle = invalid.doubleValue;
            Check(Run() == MenuBarMoveResultDeferred && eventCount == 0, @"invalid idle clock defers");
        }

        Reset(); inputAt = 0.05;
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0 && warpCount == 0,
              @"movement during preflight prevents mouse-down");

        for (NSNumber *instant in @[@0.2, @0.45, @0.95]) {
            Reset(); inputAt = instant.doubleValue;
            Check(Run() == MenuBarMoveResultDeferred && Count(kCGEventLeftMouseDragged) < 16
                      + (instant.doubleValue > 0.9 ? 1 : 0),
                  @"resumed user input stops remaining drag steps");
            Check(warpCount == 0 && CGPointEqualToPoint(pointer, resumedPointer),
                  @"resumed pointer is preserved instead of restored to stale coordinates");
            Check(Count(kCGEventLeftMouseDown) == Count(kCGEventLeftMouseUp),
                  @"interrupted drag releases its synthetic mouse button");
        }

        Reset(); cancelAt = 0.45;
        Check(Run() == MenuBarMoveResultDeferred && Count(kCGEventLeftMouseDragged) < 16,
              @"visibility change or sleep cancels running drag");
        Check(CGPointEqualToPoint(pointer, CGPointMake(640, 480)),
              @"cancel without user movement restores pointer safely");
        Reset(); cancelAt = 0;
        Check(Run() == MenuBarMoveResultDeferred && eventCount == 0, @"queued cancellation posts nothing");

        Reset(); stallAt = 0.4;
        Check(Run() == MenuBarMoveResultFailed && Count(kCGEventLeftMouseDragged) < 16,
              @"slow worker stops rather than replaying a long stale drag");
        Check(Count(kCGEventLeftMouseDown) == Count(kCGEventLeftMouseUp),
              @"timeout releases synthetic mouse button");
        Reset(); stallAt = inputAt = 0.4;
        Check(Run() == MenuBarMoveResultDeferred && warpCount == 0
                  && CGPointEqualToPoint(pointer, resumedPointer),
              @"input during a delayed system call still defers without a stale warp");

        Reset(); snapshotUnavailable = YES;
        Check(Run() == MenuBarMoveResultFailed && eventCount == 0, @"missing cursor snapshot fails closed");
        Reset(); sourceUnavailable = YES;
        Check(Run() == MenuBarMoveResultFailed && eventCount == 0, @"missing event source fails closed");
        Reset(); hideUnavailable = YES;
        Check(Run() == MenuBarMoveResultFailed && eventCount == 0, @"no visible sweep if hiding fails");

        Reset();
        Check(Run() == MenuBarMoveResultMoved && Count(kCGEventLeftMouseDragged) == 16,
              @"idle reorder still completes");
        Check(warpCount == 1 && CGPointEqualToPoint(pointer, CGPointMake(640, 480)),
              @"successful idle drag restores cursor");
        Check(hideCount == 1 && showCount == 1, @"background sweep is hidden");
        Check(events[eventCount - 1].type == kCGEventMouseMoved
                  && !(events[eventCount - 1].flags & kCGEventFlagMaskCommand),
              @"completion clears synthetic Command for the next click");
        printf("Menu bar pointer safety: %d checks passed; no desktop events posted.\n", checks);
#endif
    }
    return 0;
}
#endif
