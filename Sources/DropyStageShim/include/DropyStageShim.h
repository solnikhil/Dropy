// A Dropy-owned virtual display (the Stage), created through CoreGraphics'
// private CGVirtualDisplay classes. Kept to the smallest surface: create, read the
// display ID, and release by dropping the returned object. See
// docs/design/2026-10-07-interaction-engine-plan.md.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether this macOS has the private classes at all.
BOOL DropyStageIsSupported(void);

/// Creates a HiDPI virtual display of `width` × `height` points at `refreshRate` Hz.
/// Returns the owning object, or nil when macOS refused; the display lives exactly as
/// long as the object. `terminated` runs on `queue` if WindowServer ends it.
NSObject *_Nullable DropyStageCreate(NSString *name, uint32_t width, uint32_t height, double refreshRate,
                                     uint32_t serialNumber, dispatch_queue_t queue,
                                     void (^_Nullable terminated)(void));

/// The display ID of a Stage returned by `DropyStageCreate`.
CGDirectDisplayID DropyStageDisplayID(NSObject *stage);

NS_ASSUME_NONNULL_END
