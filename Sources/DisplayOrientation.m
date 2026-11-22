#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "VirtualDisplay.h"

static Class BDOrientationClass(void) {
    static Class displayClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
                    RTLD_LAZY | RTLD_LOCAL)) return;
        Class candidate = NSClassFromString(@"MPDisplay");
        Method init = class_getInstanceMethod(candidate, NSSelectorFromString(@"initWithCGSDisplayID:"));
        Method set = class_getInstanceMethod(candidate, NSSelectorFromString(@"setOrientation:"));
        if (!init || !set) return;
        char displayType[16] = {};
        char orientationType[16] = {};
        method_getArgumentType(init, 2, displayType, sizeof(displayType));
        method_getArgumentType(set, 2, orientationType, sizeof(orientationType));
        if (strcmp(displayType, @encode(int32_t)) == 0 &&
            strcmp(orientationType, @encode(int32_t)) == 0) displayClass = candidate;
    });
    return displayClass;
}

BOOL BDCanRequestDisplayOrientation(void) {
    return BDOrientationClass() != Nil;
}

BOOL BDRequestDisplayOrientation(CGDirectDisplayID displayID, int32_t degrees) {
    Class displayClass = BDOrientationClass();
    if (!displayClass || CGDisplayIsOnline(displayID) == 0 || CGDisplayIsBuiltin(displayID) != 0 ||
        degrees < 0 || degrees > 270 || degrees % 90 != 0) return NO;
    @try {
        typedef id (*BDInitializeDisplay)(id __attribute__((ns_consumed)), SEL, int32_t)
            __attribute__((ns_returns_retained));
        BDInitializeDisplay initialize = (BDInitializeDisplay)objc_msgSend;
        void (*setOrientation)(id, SEL, int32_t) = (void *)objc_msgSend;
        id display = initialize([displayClass alloc], NSSelectorFromString(@"initWithCGSDisplayID:"),
                                (int32_t)displayID);
        if (!display) return NO;
        setOrientation(display, NSSelectorFromString(@"setOrientation:"), degrees);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
