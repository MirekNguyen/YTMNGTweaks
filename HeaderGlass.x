// GitHub-app style header buttons: the right-hand actions share one glass
// capsule, and a lone left-hand button gets a circular glass background.
//
// YTHeaderView vends -setLeftBarButtonItems: / -setRightBarButtonItems:, but
// the items wrap custom views rather than plain UIBarButtonItems, so we work
// from the rendered button subviews instead of the item objects. Buttons are
// grouped by which half of the header they sit in, then a single glass view is
// placed behind each group's union rect.

#import "YTMNGTweaks.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char kLeftGlassKey;
static char kRightGlassKey;

// Padding around the button group, so the capsule reads as a container rather
// than a tight outline.
static const CGFloat YTMNGHeaderPadH = 10.0;
static const CGFloat YTMNGHeaderPadV = 6.0;

// Header hierarchies contain large invisible UIButtons -- full-width tap
// targets, the banner, the channel row. Including those blew the union rect out
// to a giant blob covering the status bar. Only icon-sized controls qualify.
static const CGFloat YTMNGMaxButtonSide = 64.0;

static UIVisualEffect *headerGlassEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) return nil;

    SEL selector = NSSelectorFromString(@"effectWithStyle:");
    if (![glassClass respondsToSelector:selector]) return nil;

    UIVisualEffect *(*send)(Class, SEL, NSInteger) = (void *)objc_msgSend;
    return send(glassClass, selector, 0);
}

static void collectButtons(UIView *view, NSMutableArray *out) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha < 0.01) continue;
        CGSize size = subview.bounds.size;
        BOOL iconSized = size.width > 0 && size.height > 0 &&
                         size.width <= YTMNGMaxButtonSide && size.height <= YTMNGMaxButtonSide;
        if ([subview isKindOfClass:[UIButton class]] && iconSized)
            [out addObject:subview];
        else
            collectButtons(subview, out);
    }
}

// Places (or moves) a glass view behind the union of `buttons`.
static void applyGroupGlass(UIView *header, NSArray *buttons, const void *key) {
    if (header.bounds.size.width <= 0) return;
    UIVisualEffectView *glass = objc_getAssociatedObject(header, key);

    if (buttons.count == 0) {
        glass.hidden = YES;
        return;
    }

    CGRect group = CGRectNull;
    for (UIView *button in buttons) {
        CGRect frame = [header convertRect:button.bounds fromView:button];
        group = CGRectIsNull(group) ? frame : CGRectUnion(group, frame);
    }
    if (CGRectIsNull(group) || group.size.height <= 0) return;

    group = CGRectInset(group, -YTMNGHeaderPadH, -YTMNGHeaderPadV);

    // Never let the capsule escape the header, or it rides up into the status
    // bar and off the screen edge.
    group = CGRectIntersection(group, header.bounds);
    if (CGRectIsNull(group) || CGRectIsEmpty(group)) return;

    if (!glass) {
        UIVisualEffect *effect = headerGlassEffect();
        if (!effect) return;  // pre-iOS 26

        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        [header insertSubview:glass atIndex:0];
        objc_setAssociatedObject(header, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    glass.hidden = NO;
    if (!CGRectEqualToRect(glass.frame, group)) glass.frame = group;

    glass.layer.cornerRadius = CGRectGetHeight(group) / 2.0;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;

    [header sendSubviewToBack:glass];
}

%hook YTHeaderView

- (void)layoutSubviews {
    %orig;
    if (!YTMNGGetBool(YTMNGGlassHeaderKey)) return;

    // YTHeaderView is only forward-declared in the headers, so it is an
    // incomplete type here. Cast rather than redeclaring it, which would be a
    // duplicate-interface error if the real declaration differs.
    UIView *header = (UIView *)self;

    NSMutableArray *buttons = [NSMutableArray array];
    collectButtons(header, buttons);
    if (buttons.count == 0) return;

    CGFloat midX = header.bounds.size.width / 2.0;
    NSMutableArray *left = [NSMutableArray array];
    NSMutableArray *right = [NSMutableArray array];

    for (UIView *button in buttons) {
        CGRect frame = [header convertRect:button.bounds fromView:button];
        // A button straddling the centre is a title control, not an action.
        if (CGRectGetMaxX(frame) < midX) [left addObject:button];
        else if (CGRectGetMinX(frame) > midX) [right addObject:button];
    }

    applyGroupGlass(header, left, &kLeftGlassKey);
    applyGroupGlass(header, right, &kRightGlassKey);
}

%end
