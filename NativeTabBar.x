// Replaces YouTube's bottom bar with a real UIKit UITabBar, with search as one
// of its items.
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
- (void)ytmng_searchTapped;
- (void)ytmng_hideYouTubeChrome;
- (void)ytmng_openSearchScreen;
@end

static char kTabBarKey;
static char kIdentifiersKey;
static char kRenderersKey;
static char kPendingSelectionKey;
static char kExpandingKey;

// Marks the search item so a tap on it can be told apart from a real tab.
static NSString *const YTMNGSearchIdentifier = @"YTMNGSearch";

BOOL YTMNGNativeTabBarEnabled(void) {
    return YTMNGGetBool(YTMNGNativeTabBarKey);
}

static BOOL tabBarSearchEnabled(void) {
    return YTMNGNativeTabBarEnabled() && YTMNGGetBool(YTMNGTabBarSearchKey);
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

    // Search is a tab, not a separate button.
    //
    // It used to be a detached circle beside the bar, the way Photos does it.
    // Apple Music keeps search inside the same capsule as the tabs, which is
    // the better fit here: one pill instead of two shapes competing at the
    // bottom of the screen, no width juggling between them, and the whole bar
    // is already the size and position of the search field it turns into -- so
    // the morph is the bar itself rather than one small piece of it.
    //
    // It is not a real tab: selecting it is intercepted below and the previous
    // tab stays selected, so it behaves as an action that happens to live in
    // the tab strip.
    if (tabBarSearchEnabled()) {
        UITabBarItem *search = [[UITabBarItem alloc]
            initWithTitle:@"Search"
                    image:[UIImage systemImageNamed:@"magnifyingglass"]
            selectedImage:[UIImage systemImageNamed:@"magnifyingglass"]];
        search.tag = (NSInteger)identifiers.count;
        [identifiers addObject:YTMNGSearchIdentifier];
        [renderers addObject:[NSNull null]];
        [items addObject:search];
    }

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
- (void)ytmng_openSearchScreen {
    UIViewController *host = findSearchHost(self.window.rootViewController);
    SEL press = NSSelectorFromString(@"didPressSearchButton:");
    if ([host respondsToSelector:press])
        ((void (*)(id, SEL, id))objc_msgSend)(host, press, nil);
}

// Fades the tab strip out as the search field arrives.
//
// The bar is already the size and position of the field it becomes, so the
// morph is a crossfade in place rather than a shape animation: the tabs go and
// the field fades in over the same capsule. That is what makes it read as the
// bar turning into the field, rather than a screen arriving from elsewhere.
%new
- (void)ytmng_searchTapped {
    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    if (!tabBar) {
        [self ytmng_openSearchScreen];
        return;
    }

    objc_setAssociatedObject(self, &kExpandingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Opened as the animation starts, not after it, so the real field fades in
    // over the bar at the same size and position.
    [self ytmng_openSearchScreen];

    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        tabBar.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        // Restore once the search screen covers us, so the bar is back to
        // normal by the time it is next visible.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            tabBar.alpha = 1.0;
            objc_setAssociatedObject(self, &kExpandingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self setNeedsLayout];
        });
    }];
}

// Strips YouTube's own bar chrome so only the UITabBar's glass shows.
//
// This has to be callable from more than layoutSubviews. YouTube repaints the
// pivot bar in -styleBackgroundColors on every theme and scroll-state change,
// and NativeBar.x -- which is where that hook used to be handled -- bails out
// entirely when the native tab bar is enabled. So nothing was re-clearing the
// background, and YouTube's grey slab came back and sat behind the floating
// capsule as a full-width band.
%new
- (void)ytmng_hideYouTubeChrome {
    self.contentView.hidden = YES;
    self.blurView.hidden = YES;
    self.separatorView.hidden = YES;
    self.backgroundColor = [UIColor clearColor];
    self.layer.backgroundColor = [UIColor clearColor].CGColor;
    self.opaque = NO;
}

// UITabBarDelegate. Hands the renderer straight back to YouTube.
%new
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSArray *renderers = objc_getAssociatedObject(self, &kRenderersKey);
    NSArray *identifiers = objc_getAssociatedObject(self, &kIdentifiersKey);
    if (item.tag < 0 || (NSUInteger)item.tag >= renderers.count) return;

    // The search item is an action, not a destination. Put the selection back
    // where it was before opening search, so returning from the search screen
    // does not leave the bar highlighting a tab that was never navigated to.
    if ([identifiers[item.tag] isEqualToString:YTMNGSearchIdentifier]) {
        NSString *previous = objc_getAssociatedObject(self, &kPendingSelectionKey);
        [self ytmng_selectIdentifier:previous];
        [self ytmng_searchTapped];
        return;
    }

    if ((NSUInteger)item.tag < identifiers.count)
        objc_setAssociatedObject(self, &kPendingSelectionKey, identifiers[item.tag], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id delegate = self.delegate;
    if (![delegate respondsToSelector:@selector(didTapItemWithRenderer:)]) return;

    [delegate didTapItemWithRenderer:renderers[item.tag]];
}

- (void)layoutSubviews {
    %orig;

    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);

    if (!YTMNGNativeTabBarEnabled()) {
        // Toggled off: put YouTube's own bar back.
        if (tabBar) {
            [tabBar removeFromSuperview];
            objc_setAssociatedObject(self, &kTabBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kIdentifiersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            self.contentView.hidden = NO;
            self.blurView.hidden = NO;
        }
        return;
    }

    [self ytmng_rebuildNativeTabBar];

    tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    if (!tabBar) return;

    // Google's icons and its own material would otherwise show through.
    [self ytmng_hideYouTubeChrome];

    // Search lives inside the bar now, so the bar spans the full width.
    // Skipped mid-morph, when the animation owns the bar.
    if (![objc_getAssociatedObject(self, &kExpandingKey) boolValue] &&
        !CGRectEqualToRect(tabBar.frame, self.bounds))
        tabBar.frame = self.bounds;

    [self bringSubviewToFront:tabBar];
    [self ytmng_syncSelectionFromYouTube];
}

// YouTube restyles the bar background on theme and scroll-state changes, which
// puts the flat grey back over (well, behind) the glass.
- (void)styleBackgroundColors {
    %orig;
    if (YTMNGNativeTabBarEnabled()) [self ytmng_hideYouTubeChrome];
}

// Keeps the native selection in sync when YouTube changes tabs itself, e.g.
// via a deep link or the back gesture.
- (void)selectItemWithPivotIdentifier:(NSString *)identifier {
    %orig;
    if (YTMNGNativeTabBarEnabled()) [self ytmng_selectIdentifier:identifier];
}

%end
