// Dev check without a second monitor: plugs in a virtual display (private CGVirtualDisplay API, test tool only,
// never linked into the app), changes its resolution, then unplugs it, printing the wallpaper windows at each step.
// Build: clang -fobjc-arc -framework AppKit -framework CoreGraphics scripts/dev/virtual-display.m -o virtual-display
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static void stamp(NSString *text) {
    printf("%.3f %s\n", NSProcessInfo.processInfo.systemUptime, text.UTF8String);
    fflush(stdout);
}

static void pump(double seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void report(void) {
    for (NSScreen *screen in NSScreen.screens) {
        stamp([NSString stringWithFormat:@"  screen %@ %@", screen.localizedName, NSStringFromRect(screen.frame)]);
    }
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *window in windows) {
        if (![window[(id)kCGWindowOwnerName] isEqual:@"Live Wallpaper"]) continue;
        NSDictionary *b = window[(id)kCGWindowBounds];
        stamp([NSString stringWithFormat:@"  wallpaper window %@,%@ %@x%@", b[@"X"], b[@"Y"], b[@"Width"], b[@"Height"]]);
    }
}

static CGVirtualDisplaySettings *settings(NSUInteger width, NSUInteger height) {
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
    return settings;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        [descriptor setDispatchQueue:dispatch_get_main_queue()];
        descriptor.name = @"LW Test Display";
        descriptor.maxPixelsWide = 1920;
        descriptor.maxPixelsHigh = 1080;
        descriptor.sizeInMillimeters = CGSizeMake(527, 296);
        descriptor.vendorID = 0xEEEE;
        descriptor.productID = 0x1234;
        descriptor.serialNum = 1;

        stamp(@"plug in 1920x1080");
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display || ![display applySettings:settings(1920, 1080)]) {
            stamp(@"virtual display not available");
            return 1;
        }
        pump(8);
        report();

        stamp(@"change resolution to 1280x720");
        [display applySettings:settings(1280, 720)];
        pump(6);
        report();

        stamp(@"unplug");
        display = nil;
        pump(5);
        report();
    }
    return 0;
}
