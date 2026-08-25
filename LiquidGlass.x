// Forces YouTube's own Liquid Glass code path on.
//
// The app already ships a full Liquid Glass implementation (M3CLiquidGlass,
// YTFrostedGlassView, YTGlassContainerView, M3CMaterialGlassEffectView), gated
// behind +[M3CLiquidGlass computeIsLiquidGlassAvailable]. Disassembling that
// method on 21.33.6 shows three conditions:
//
//   1. _availability_version_check(platform 2 = iOS, 0x1a = 26)
//   2. NSClassFromString("UIGlassEffect") responds to "effectWithStyle:"
//   3. Info.plist "UIDesignRequiresCompatibility" -- the result is EOR'd with 1,
//      i.e. the method returns its logical NOT. An absent key branches to
//      "mov w20, #1" and is treated as available.
//
// Google ships the app built against the iphoneos26.4 SDK but sets that plist
// key to true, which is what turns the whole thing off. The build workflow
// flips the key; this file forces the accompanying YTColdConfig flags, which
// are otherwise server-controlled.
//
// These are cold config values, so YouTube reads them at launch: toggling the
// switch requires a full app restart to take effect.

#import "YTMNGTweaks.h"

@interface YTColdConfig : NSObject
- (BOOL)mainAppCoreClientIos27EnableLiquidGlass;
- (BOOL)enableLiquidGlassEffect;
@end

%hook YTColdConfig

- (BOOL)mainAppCoreClientIos27EnableLiquidGlass {
    if (YTMNGGetBool(YTMNGLiquidGlassKey)) return YES;
    return %orig;
}

- (BOOL)enableLiquidGlassEffect {
    if (YTMNGGetBool(YTMNGLiquidGlassKey)) return YES;
    return %orig;
}

%end
