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
#import <objc/message.h>

// UIGlassEffect is declared by the iOS 26 SDK, so redeclaring it here is a
// duplicate-interface error when building against that SDK -- but hard-coding
// a direct call would break on older SDKs and require availability
// annotations against our 14.0 deployment target. Resolve it purely at
// runtime instead, which compiles on any SDK and keeps the guard honest.
static UIVisualEffect *makeGlassEffect(NSInteger style) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) return nil;

    SEL selector = NSSelectorFromString(@"effectWithStyle:");
    if (![glassClass respondsToSelector:selector]) return nil;

    UIVisualEffect *(*send)(Class, SEL, NSInteger) = (void *)objc_msgSend;
    return send(glassClass, selector, style);
}

@interface YTPivotBarView : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, readonly) UIView *contentView;
@property (nonatomic, readonly) NSArray *itemViews;
@end

@interface YTPivotBarViewController : UIViewController
- (BOOL)isFrostedPivotBarPermitted;
@end

// Horizontal inset that turns the full-width bar into a floating capsule.
static const CGFloat YTMNGCapsuleInset = 12.0;
// Breathing room above and below the icon row inside the capsule.
static const CGFloat YTMNGCapsulePadding = 8.0;

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
        UIVisualEffect *glass = makeGlassEffect(0);
        if (glass) blur.effect = glass;
    }

    // The hairline above the bar is part of the old flat design.
    bar.separatorView.hidden = YES;
    bar.backgroundColor = [UIColor clearColor];

    // Reshape into the system floating capsule.
    //
    // Sizing this from contentView is wrong: contentView spans the bottom safe
    // area, so the capsule ran far below the icons and left dead space under
    // them. Measure the actual item views instead and pad around those, and
    // leave contentView's own frame alone so the icons stay where YouTube put
    // them.
    CGRect items = CGRectNull;
    for (UIView *item in bar.itemViews) {
        if (![item isKindOfClass:[UIView class]] || item.hidden) continue;
        CGRect f = [bar convertRect:item.bounds fromView:item];
        items = CGRectIsNull(items) ? f : CGRectUnion(items, f);
    }
    if (CGRectIsNull(items) || items.size.height <= 0) return;

    CGFloat width = bar.bounds.size.width - (YTMNGCapsuleInset * 2);
    if (width <= 0) return;

    CGRect capsule = CGRectMake(YTMNGCapsuleInset,
                                CGRectGetMinY(items) - YTMNGCapsulePadding,
                                width,
                                CGRectGetHeight(items) + (YTMNGCapsulePadding * 2));

    if (!CGRectEqualToRect(blur.frame, capsule)) blur.frame = capsule;

    blur.layer.cornerRadius = CGRectGetHeight(capsule) / 2.0;
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
