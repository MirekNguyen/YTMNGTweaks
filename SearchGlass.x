// Gives the search field the system Liquid Glass material.
//
// Unlike YTPivotBarView -- which exposes a ready-made UIVisualEffectView in its
// blurView property -- YTSearchBoxView has no effect view at all; its only
// subviews are searchLabel and cancelButtonContainer. So there is nothing to
// swap, and we insert our own glass view behind the content instead.
//
// This is a restyle of Google's search field, not Apple's search system.
// YouTube's search is YTSearchViewController + YTSearchSuggestionsController +
// YTGetSearchSuggestionsService, all InnerTube-renderer driven; UISearchBar and
// UISearchController are linked into the binary but only used by peripheral
// surfaces like the Shorts audio picker. Substituting a real UISearchController
// would mean reimplementing suggestions, filters, voice and results rendering.

#import "YTMNGTweaks.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char kGlassViewKey;

static UIVisualEffect *searchGlassEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) return nil;

    SEL selector = NSSelectorFromString(@"effectWithStyle:");
    if (![glassClass respondsToSelector:selector]) return nil;

    UIVisualEffect *(*send)(Class, SEL, NSInteger) = (void *)objc_msgSend;
    return send(glassClass, selector, 0);
}

// Takes id rather than UIView *: these classes are declared elsewhere in the
// headers with an opaque superclass, so a typed parameter fails -Werror even
// though they are views at runtime.
static void applySearchGlass(id container) {
    UIView *view = container;
    if (!YTMNGGetBool(YTMNGGlassSearchKey)) return;
    if (view.bounds.size.height <= 0 || view.bounds.size.width <= 0) return;

    UIVisualEffectView *glass = objc_getAssociatedObject(view, &kGlassViewKey);

    if (!glass) {
        UIVisualEffect *effect = searchGlassEffect();
        if (!effect) return;  // pre-iOS 26

        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        [view insertSubview:glass atIndex:0];
        objc_setAssociatedObject(view, &kGlassViewKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!CGRectEqualToRect(glass.frame, view.bounds)) glass.frame = view.bounds;

    glass.layer.cornerRadius = view.bounds.size.height / 2.0;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;

    // The flat grey pill would sit on top of the glass otherwise.
    view.backgroundColor = [UIColor clearColor];
    [view sendSubviewToBack:glass];
}

%hook YTSearchBoxView

- (void)layoutSubviews {
    %orig;
    applySearchGlass(self);
}

%end

%hook YTSearchBarView

- (void)layoutSubviews {
    %orig;
    applySearchGlass(self);
}

%end
