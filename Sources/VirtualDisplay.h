#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NSObject * _Nullable BDMakeVirtualDisplay(
    NSString * _Nonnull name, unsigned int serial, unsigned int width, unsigned int height,
    double refreshRate, BOOL hiDPI, CGDirectDisplayID * _Nonnull displayID
) NS_RETURNS_RETAINED;

BOOL BDCanRequestDisplayOrientation(void);
BOOL BDRequestDisplayOrientation(CGDirectDisplayID displayID, int32_t degrees);

#import "SoftwareVolume.h"
