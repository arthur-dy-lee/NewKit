#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class NSStatusItem;

NS_ASSUME_NONNULL_BEGIN

@interface MenuBarNativeItem : NSObject

@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) CGRect screenFrame;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                   frame:(CGRect)frame
                             screenFrame:(CGRect)screenFrame;

@end

/// The macOS 27 menu bar backend is loaded at runtime so NewKit can still
/// launch when the private framework changes or is unavailable.
@interface MenuBarNativeBridge : NSObject

@property (nonatomic, readonly, getter=isAvailable) BOOL available;
- (nullable NSArray<NSString *> *)discoverBundleIdentifiers;
- (NSArray<MenuBarNativeItem *> *)visibleMenuBarItems;
/// Finds this exact status item among the app's hosted menu bar elements.
/// Returns nil if its on-screen button cannot be matched unambiguously.
- (nullable MenuBarNativeItem *)visibleMenuBarItemForStatusItem:(NSStatusItem *)statusItem
    NS_SWIFT_NAME(visibleMenuBarItem(for:));
- (nullable id)activateAllowingBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                     completion:(void (^)(NSError * _Nullable error))completion;
- (void)invalidateAssertion:(id)assertion;

@end

NS_ASSUME_NONNULL_END
