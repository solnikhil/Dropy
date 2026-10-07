#import "DropyStageShim.h"
#import <objc/runtime.h>

// Private CoreGraphics interfaces, as used by BetterDisplay, DeskPad and others.
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

BOOL DropyStageIsSupported(void) {
    return NSClassFromString(@"CGVirtualDisplay") != nil && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

NSObject *DropyStageCreate(NSString *name, uint32_t width, uint32_t height, double refreshRate,
                           uint32_t serialNumber, dispatch_queue_t queue, void (^terminated)(void)) {
    if (!DropyStageIsSupported() || width == 0 || height == 0) return nil;
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = queue;
    descriptor.name = name;
    descriptor.maxPixelsWide = width * 2;
    descriptor.maxPixelsHigh = height * 2;
    // About 127 dpi at 1x, like a laptop panel; macOS uses it only for its own UI scaling.
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.2, height * 0.2);
    // A stable identity, so macOS remembers the arrangement it was given.
    descriptor.vendorID = 0xD70E;
    descriptor.productID = 0x5747;
    descriptor.serialNum = serialNumber;
    if (terminated) {
        void (^handler)(void) = [terminated copy];
        descriptor.terminationHandler = ^(id display, id error) { handler(); };
    }
    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) return nil;
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height
                                                                             refreshRate:refreshRate]];
    if (![display applySettings:settings]) return nil;
    return display;
}

CGDirectDisplayID DropyStageDisplayID(NSObject *stage) {
    return ((CGVirtualDisplay *)stage).displayID;
}
