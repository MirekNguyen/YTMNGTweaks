// Replaces YouTube's bottom bar with a real UIKit UITabBar, plus an optional
// detached glass search button beside it.
//
// This is a genuine UITabBar, not a restyle: native glass, native SF Symbol
// icons, native selection animation and native tap handling. What it is NOT is
// a UITabBarController -- it does not own the view controllers, so behaviours
// that belong to the controller (swipe across the bar, minimize-on-scroll) are
// not present. Getting those would mean re-hosting YouTube's view controllers
// and reimplementing endpoint routing.
//
// Navigation is forwarded rather than reimplemented. Each YTPivotBarItemView
// holds its YTIPivotBarItemRenderer in the _renderer ivar, and the pivot bar's
// delegate (YTPivotBarViewController) exposes -didTapItemWithRenderer: -- the
// exact method a real tap on Google's bar calls. So we hand the same renderer
// to the same method and YouTube performs the navigation itself.

#import "YTMNGTweaks.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface YTIFormattedString : NSObject
- (NSString *)stringWithFormattingRemoved;
@end

@interface YTIPivotBarItemRenderer : NSObject
@property (nonatomic, copy) NSString *pivotIdentifier;
@property (nonatomic, strong) YTIFormattedString *title;
@end

// -selected and -pivotIdentifier are real methods on YouTube 21.33.6; they are
// how we learn which tab is active before any tap has happened.
@interface YTPivotBarItemView : UIView
@property (nonatomic, strong) YTIPivotBarItemRenderer *renderer;
@property (nonatomic, readonly, getter=isSelected) BOOL selected;
@property (nonatomic, readonly) NSString *pivotIdentifier;
@end

@interface YTPivotBarViewController : UIViewController
- (void)didTapItemWithRenderer:(id)renderer;
- (NSString *)selectedPivotIdentifier;
@end

@interface YTPivotBarView : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, readonly) UIView *contentView;
@property (nonatomic, readonly) NSArray *itemViews;
@property (nonatomic, weak) id delegate;
// Added below with %new; declared so they can be called from this file.
- (void)ytmng_rebuildNativeTabBar;
- (void)ytmng_selectIdentifier:(NSString *)identifier;
- (void)ytmng_syncSelectionFromYouTube;
- (void)ytmng_layoutSearchButton;
- (void)ytmng_searchTapped;
@end

static char kTabBarKey;
static char kIdentifiersKey;
static char kRenderersKey;
static char kPendingSelectionKey;
static char kSearchButtonKey;

// Gap between the tab bar capsule and the detached search button.
static const CGFloat YTMNGSearchGap = 8.0;
// Matches NativeBar.x so both bars sit on the same horizontal rails.
static const CGFloat YTMNGSearchEdgeInset = 12.0;

BOOL YTMNGNativeTabBarEnabled(void) {
    return YTMNGGetBool(YTMNGNativeTabBarKey);
}

static BOOL tabBarSearchEnabled(void) {
    return YTMNGNativeTabBarEnabled() && YTMNGGetBool(YTMNGTabBarSearchKey);
}

static UIVisualEffect *tabBarGlassEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) return nil;

    SEL selector = NSSelectorFromString(@"effectWithStyle:");
    if (![glassClass respondsToSelector:selector]) return nil;

    UIVisualEffect *(*send)(Class, SEL, NSInteger) = (void *)objc_msgSend;
    return send(glassClass, selector, 0);
}

// YouTube's pivot identifiers are stable server-side constants, so mapping them
// to SF Symbols is safe. Unknown identifiers fall back to a neutral glyph
// rather than rendering nothing.
static NSString *symbolForIdentifier(NSString *identifier, BOOL selected) {
    static NSDictionary *plain;
    static NSDictionary *filled;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        plain = @{
            @"FEwhat_to_watch": @"house",
            @"FEshorts":        @"play.square.stack",
            @"FEsubscriptions": @"rectangle.stack.badge.play",
            @"FElibrary":       @"person.crop.circle",
            @"FEmy_videos":     @"film.stack",
            @"FEexplore":       @"safari",
            @"FEactivity":      @"bell",
        };
        filled = @{
            @"FEwhat_to_watch": @"house.fill",
            @"FEshorts":        @"play.square.stack.fill",
            @"FEsubscriptions": @"rectangle.stack.badge.play.fill",
            @"FElibrary":       @"person.crop.circle.fill",
            @"FEmy_videos":     @"film.stack.fill",
            @"FEexplore":       @"safari.fill",
            @"FEactivity":      @"bell.fill",
        };
    });
    NSString *name = (selected ? filled : plain)[identifier ?: @""];
    return name ?: (selected ? @"circle.fill" : @"circle");
}

// The search screen is opened by YTHeaderViewController -didPressSearchButton:,
// the same method the topbar magnifier calls. Rather than rebuilding a search
// endpoint by hand we walk the view-controller tree for that controller and
// call it, so YouTube owns entry logging, context and presentation.
static UIViewController *findSearchHost(UIViewController *root) {
    if (!root) return nil;
    if ([root isKindOfClass:NSClassFromString(@"YTHeaderViewController")]) return root;

    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = findSearchHost(child);
        if (found) return found;
    }
    return findSearchHost(root.presentedViewController);
}

// Union of the (hidden) pivot item views. Used purely for geometry: it tells us
// where the icon row really is, which is what both the capsule and the search
// button must line up with. contentView spans the safe area and is useless here.
static CGRect itemRowRect(YTPivotBarView *bar) {
    CGRect items = CGRectNull;
    for (UIView *item in bar.itemViews) {
        if (![item isKindOfClass:[UIView class]] || item.hidden) continue;
        CGRect frame = [bar convertRect:item.bounds fromView:item];
        items = CGRectIsNull(items) ? frame : CGRectUnion(items, frame);
    }
    return items;
}

%hook YTPivotBarView

%new
- (void)ytmng_rebuildNativeTabBar {
    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);

    NSMutableArray *identifiers = [NSMutableArray array];
    NSMutableArray *renderers = [NSMutableArray array];
    NSMutableArray *items = [NSMutableArray array];
    NSString *activeIdentifier = nil;

    // itemViews is in construction order, not visual order, which put "You"
    // second. Sort by horizontal position so the native bar matches the layout.
    NSArray *ordered = [self.itemViews sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = [self convertRect:a.bounds fromView:a].origin.x;
        CGFloat bx = [self convertRect:b.bounds fromView:b].origin.x;
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (YTPivotBarItemView *itemView in ordered) {
        if (itemView.hidden) continue;

        YTIPivotBarItemRenderer *renderer = [itemView valueForKey:@"renderer"];
        NSString *identifier = renderer.pivotIdentifier;
        if (identifier.length == 0) continue;

        NSString *title = [renderer.title stringWithFormattingRemoved];
        UITabBarItem *item = [[UITabBarItem alloc]
            initWithTitle:title
                    image:[UIImage systemImageNamed:symbolForIdentifier(identifier, NO)]
            selectedImage:[UIImage systemImageNamed:symbolForIdentifier(identifier, YES)]];
        item.tag = (NSInteger)identifiers.count;

        // Google's bar knows which tab is live before any tap happens. Reading
        // it here is what stops the native bar from launching with nothing
        // selected: -selectItemWithPivotIdentifier: fires during startup,
        // before this tab bar exists, so relying on that hook alone loses the
        // very first selection.
        if ([itemView respondsToSelector:@selector(isSelected)] && itemView.selected)
            activeIdentifier = identifier;

        [identifiers addObject:identifier];
        [renderers addObject:renderer];
        [items addObject:item];
    }

    if (items.count == 0) return;

    // Rebuilding on every layout pass would cancel the selection animation, so
    // only rebuild when the set of tabs actually changed.
    NSArray *existing = objc_getAssociatedObject(self, &kIdentifiersKey);
    if (tabBar && [existing isEqualToArray:identifiers]) return;

    if (!tabBar) {
        tabBar = [[UITabBar alloc] initWithFrame:self.bounds];
        tabBar.delegate = (id)self;
        // The selected-tab capsule is drawn by UIKit on iOS 26; we only set the
        // tint. systemBlue was UIKit's default and looked like a stock Apple
        // app dropped into YouTube -- label/secondaryLabel matches how YouTube
        // renders its own bar (white on, grey off) while still inheriting the
        // native glass and selection animation.
        tabBar.tintColor = [UIColor labelColor];
        tabBar.unselectedItemTintColor = [UIColor secondaryLabelColor];
        [self addSubview:tabBar];
        objc_setAssociatedObject(self, &kTabBarKey, tabBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    tabBar.items = items;
    objc_setAssociatedObject(self, &kIdentifiersKey, identifiers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kRenderersKey, renderers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Setting -items drops any previous selection, so restore it: whatever
    // YouTube reported while we were rebuilding, else the live item, else the
    // first tab so the bar is never left blank.
    NSString *pending = objc_getAssociatedObject(self, &kPendingSelectionKey);
    NSString *restore = pending ?: activeIdentifier;
    if (![identifiers containsObject:restore]) restore = identifiers.firstObject;
    [self ytmng_selectIdentifier:restore];
}

%new
- (void)ytmng_selectIdentifier:(NSString *)identifier {
    if (!identifier) return;
    objc_setAssociatedObject(self, &kPendingSelectionKey, identifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    NSArray *identifiers = objc_getAssociatedObject(self, &kIdentifiersKey);
    if (!tabBar) return;

    NSUInteger index = [identifiers indexOfObject:identifier];
    if (index == NSNotFound || index >= tabBar.items.count) return;

    UITabBarItem *item = tabBar.items[index];
    if (tabBar.selectedItem != item) tabBar.selectedItem = item;
}

// Pulls the truth back out of YouTube. Cheap enough to call from layout, and it
// covers selection changes that never route through
// -selectItemWithPivotIdentifier: (deep links, back gesture, tab restoration).
%new
- (void)ytmng_syncSelectionFromYouTube {
    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    if (!tabBar) return;

    id delegate = self.delegate;
    if (![delegate respondsToSelector:@selector(selectedPivotIdentifier)]) return;

    NSString *identifier = [(YTPivotBarViewController *)delegate selectedPivotIdentifier];
    if (identifier.length == 0) return;
    [self ytmng_selectIdentifier:identifier];
}

// --- Detached search button ---

%new
- (void)ytmng_searchTapped {
    UIViewController *host = findSearchHost(self.window.rootViewController);
    SEL press = NSSelectorFromString(@"didPressSearchButton:");
    if ([host respondsToSelector:press])
        ((void (*)(id, SEL, id))objc_msgSend)(host, press, nil);
}

%new
- (void)ytmng_layoutSearchButton {
    UIButton *button = objc_getAssociatedObject(self, &kSearchButtonKey);

    if (!tabBarSearchEnabled()) {
        button.hidden = YES;
        return;
    }

    CGRect items = itemRowRect(self);
    if (CGRectIsNull(items) || items.size.height <= 0) return;

    if (!button) {
        UIVisualEffect *effect = tabBarGlassEffect();
        if (!effect) return;  // pre-iOS 26: no glass to match the bar with

        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tintColor = [UIColor labelColor];
        [button setImage:[UIImage systemImageNamed:@"magnifyingglass"] forState:UIControlStateNormal];
        [button addTarget:self
                   action:NSSelectorFromString(@"ytmng_searchTapped")
         forControlEvents:UIControlEventTouchUpInside];

        // The glass sits inside the button rather than behind it so the two can
        // never drift apart during layout.
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        glass.tag = 0x59544D47;  // 'YTMG', so we can find it again below
        [button insertSubview:glass atIndex:0];

        [self addSubview:button];
        objc_setAssociatedObject(self, &kSearchButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    button.hidden = NO;

    // A circle the same height as the tab bar capsule, pinned to the trailing
    // edge -- the layout Messages/Zalo use for a detached action button.
    CGFloat side = CGRectGetHeight(items) + 16.0;
    CGRect frame = CGRectMake(CGRectGetWidth(self.bounds) - YTMNGSearchEdgeInset - side,
                              CGRectGetMidY(items) - (side / 2.0),
                              side, side);
    if (!CGRectEqualToRect(button.frame, frame)) button.frame = frame;

    UIView *glass = [button viewWithTag:0x59544D47];
    glass.frame = button.bounds;
    glass.layer.cornerRadius = side / 2.0;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;

    [self bringSubviewToFront:button];
}

// UITabBarDelegate. Hands the renderer straight back to YouTube.
%new
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSArray *renderers = objc_getAssociatedObject(self, &kRenderersKey);
    NSArray *identifiers = objc_getAssociatedObject(self, &kIdentifiersKey);
    if (item.tag < 0 || (NSUInteger)item.tag >= renderers.count) return;

    if ((NSUInteger)item.tag < identifiers.count)
        objc_setAssociatedObject(self, &kPendingSelectionKey, identifiers[item.tag], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id delegate = self.delegate;
    if (![delegate respondsToSelector:@selector(didTapItemWithRenderer:)]) return;

    [delegate didTapItemWithRenderer:renderers[item.tag]];
}

- (void)layoutSubviews {
    %orig;

    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    UIButton *search = objc_getAssociatedObject(self, &kSearchButtonKey);

    if (!YTMNGNativeTabBarEnabled()) {
        // Toggled off: put YouTube's own bar back.
        if (tabBar) {
            [tabBar removeFromSuperview];
            [search removeFromSuperview];
            objc_setAssociatedObject(self, &kTabBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kIdentifiersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kSearchButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            self.contentView.hidden = NO;
            self.blurView.hidden = NO;
        }
        return;
    }

    [self ytmng_rebuildNativeTabBar];

    tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    if (!tabBar) return;

    // Google's icons and its own material would otherwise show through.
    self.contentView.hidden = YES;
    self.blurView.hidden = YES;
    self.separatorView.hidden = YES;
    self.backgroundColor = [UIColor clearColor];

    // The search button eats the trailing edge, so the tab bar has to give it
    // back rather than sit underneath.
    CGRect frame = self.bounds;
    if (tabBarSearchEnabled()) {
        CGRect items = itemRowRect(self);
        if (!CGRectIsNull(items) && items.size.height > 0)
            frame.size.width -= (CGRectGetHeight(items) + 16.0) + YTMNGSearchGap;
    }
    if (!CGRectEqualToRect(tabBar.frame, frame)) tabBar.frame = frame;

    [self ytmng_layoutSearchButton];
    [self bringSubviewToFront:tabBar];
    [self ytmng_syncSelectionFromYouTube];
}

// Keeps the native selection in sync when YouTube changes tabs itself, e.g.
// via a deep link or the back gesture.
- (void)selectItemWithPivotIdentifier:(NSString *)identifier {
    %orig;
    if (YTMNGNativeTabBarEnabled()) [self ytmng_selectIdentifier:identifier];
}

%end
