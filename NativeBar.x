// Replaces YouTube's own bottom-bar material with the real iOS 26 Liquid Glass
// and reshapes it into the system floating-capsule look.
//
// Why not a real UITabBar
// -----------------------
// YTPivotBarViewController is not just a view -- it owns app navigation:
//
//   -handleNavigationEndpoint:      -maybeSwitchTabForNavigationEndpoint:
//   -selectItemWithPivotIdentifier: -resetViewControllersCache
//   -setNotificationUnseenContentCount:  -pivotBarItemViewForIndex:
//
// Swapping in a UITabBarController would mean reimplementing tab-to-view-
// controller mapping, the VC cache, badge counts, deep links and endpoint
// routing, then forwarding all of it back. That trades a cosmetic win for a
// high chance of broken navigation.
//
// Instead we keep Google's bar and navigation entirely intact and change only
// the material. YTPivotBarView already exposes `blurView` as a real
// UIVisualEffectView, so assigning a UIGlassEffect to it yields genuine system
// Liquid Glass -- the same UIKit class the OS uses, not Google's
// M3CMaterialGlassEffect reimplementation.
//
// +[YTFrostedGlassView liquidGlassEffect] disassembles to an iOS 26 check
// followed by [UIGlassEffect effectWithStyle:], where the style is 0 (regular)
// or 1 (clear), which is what we mirror here.

#import "YTMNGTweaks.h"
#import <QuartzCore/QuartzCore.h>

@interface UIGlassEffect : UIVisualEffect
+ (instancetype)effectWithStyle:(NSInteger)style;
@property (nonatomic) BOOL interactive;
@end

@interface YTPivotBarView : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, readonly) UIView *contentView;
@end

@interface YTPivotBarViewController : UIViewController
- (BOOL)isFrostedPivotBarPermitted;
@end

// Horizontal inset that turns the full-width bar into a floating capsule.
static const CGFloat YTMNGCapsuleInset = 12.0;

static BOOL nativeBarEnabled(void) {
    if (!YTMNGGetBool(YTMNGNativeBarKey)) return NO;
    // UIGlassEffect only exists on iOS 26+; below that there is nothing to do.
    return NSClassFromString(@"UIGlassEffect") != nil;
}

static void applyGlass(YTPivotBarView *bar) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    UIVisualEffectView *blur = bar.blurView;
    if (!glassClass || ![blur isKindOfClass:[UIVisualEffectView class]]) return;

    // Reassigning an effect is expensive and animates, so only do it once.
    if (![blur.effect isKindOfClass:glassClass]) {
        UIVisualEffect *glass = [glassClass effectWithStyle:0];
        if (glass) blur.effect = glass;
    }

    // The hairline above the bar is part of the old flat design.
    bar.separatorView.hidden = YES;
    bar.backgroundColor = [UIColor clearColor];

    // Reshape into the system floating capsule. contentView holds the row of
    // item views, so insetting both keeps the icons inside the glass.
    UIView *content = bar.contentView;
    CGRect frame = content.frame;
    if (frame.size.height <= 0 || frame.size.width <= 0) return;

    CGFloat width = bar.bounds.size.width - (YTMNGCapsuleInset * 2);
    if (width <= 0) return;

    CGRect capsule = CGRectMake(YTMNGCapsuleInset, frame.origin.y, width, frame.size.height);
    if (!CGRectEqualToRect(blur.frame, capsule)) blur.frame = capsule;
    if (!CGRectEqualToRect(content.frame, capsule)) content.frame = capsule;

    blur.layer.cornerRadius = frame.size.height / 2.0;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
}

%hook YTPivotBarView

- (void)layoutSubviews {
    %orig;
    if (nativeBarEnabled()) applyGlass(self);
}

// YouTube restyles the background on theme and scroll-state changes, which
// would otherwise put the flat colour back over the glass.
- (void)styleBackgroundColors {
    %orig;
    if (nativeBarEnabled()) applyGlass(self);
}

%end

%hook YTPivotBarViewController

// Without a frosted bar there is no blurView to attach the glass effect to.
- (BOOL)isFrostedPivotBarPermitted {
    if (nativeBarEnabled()) return YES;
    return %orig;
}

%end
