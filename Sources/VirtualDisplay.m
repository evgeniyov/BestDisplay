#import "VirtualDisplay.h"
#import <dispatch/dispatch.h>

// These classes belong to CoreGraphics. Runtime lookup lets the app degrade if a class disappears.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NSObject *BDMakeVirtualDisplay(NSString *name, unsigned int serial, unsigned int width, unsigned int height,
                               double refreshRate, BOOL hiDPI, CGDirectDisplayID *displayID) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) { return nil; }

    @try {
        CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
        unsigned int density = hiDPI ? 2 : 1;
        descriptor.vendorID = 0x4244;
        descriptor.productID = 1;
        descriptor.serialNum = serial;
        if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) { descriptor.serialNumber = serial; }
        descriptor.name = name;
        descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        descriptor.maxPixelsWide = width * density;
        descriptor.maxPixelsHigh = height * density;
        descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / 110, 25.4 * height / 110);
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        if (!mode || !settings) { return nil; }
        settings.hiDPI = hiDPI ? 1 : 0;
        settings.modes = @[mode];
        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (![display applySettings:settings] || display.displayID == kCGNullDirectDisplay) { return nil; }
        *displayID = display.displayID;
        return display;
    } @catch (NSException *exception) {
        return nil;
    }
}
