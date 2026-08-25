// Replaces YouTube's bottom bar with a real UIKit UITabBar.
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
#import <objc/runtime.h>

@interface YTIFormattedString : NSObject
- (NSString *)stringWithFormattingRemoved;
@end

@interface YTIPivotBarItemRenderer : NSObject
@property (nonatomic, copy) NSString *pivotIdentifier;
@property (nonatomic, strong) YTIFormattedString *title;
@end

@interface YTPivotBarItemView : UIView
@property (nonatomic, strong) YTIPivotBarItemRenderer *renderer;
@end

@interface YTPivotBarViewController : UIViewController
- (void)didTapItemWithRenderer:(id)renderer;
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
@end

static char kTabBarKey;
static char kIdentifiersKey;
static char kRenderersKey;

BOOL YTMNGNativeTabBarEnabled(void) {
    return YTMNGGetBool(YTMNGNativeTabBarKey);
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

%hook YTPivotBarView

%new
- (void)ytmng_rebuildNativeTabBar {
    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);

    NSMutableArray *identifiers = [NSMutableArray array];
    NSMutableArray *renderers = [NSMutableArray array];
    NSMutableArray *items = [NSMutableArray array];

    for (YTPivotBarItemView *itemView in self.itemViews) {
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
        [self addSubview:tabBar];
        objc_setAssociatedObject(self, &kTabBarKey, tabBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    tabBar.items = items;
    objc_setAssociatedObject(self, &kIdentifiersKey, identifiers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kRenderersKey, renderers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)ytmng_selectIdentifier:(NSString *)identifier {
    UITabBar *tabBar = objc_getAssociatedObject(self, &kTabBarKey);
    NSArray *identifiers = objc_getAssociatedObject(self, &kIdentifiersKey);
    if (!tabBar || !identifier) return;

    NSUInteger index = [identifiers indexOfObject:identifier];
    if (index == NSNotFound || index >= tabBar.items.count) return;

    UITabBarItem *item = tabBar.items[index];
    if (tabBar.selectedItem != item) tabBar.selectedItem = item;
}

// UITabBarDelegate. Hands the renderer straight back to YouTube.
%new
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSArray *renderers = objc_getAssociatedObject(self, &kRenderersKey);
    if (item.tag < 0 || (NSUInteger)item.tag >= renderers.count) return;

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
    self.contentView.hidden = YES;
    self.blurView.hidden = YES;
    self.separatorView.hidden = YES;
    self.backgroundColor = [UIColor clearColor];

    if (!CGRectEqualToRect(tabBar.frame, self.bounds)) tabBar.frame = self.bounds;
    [self bringSubviewToFront:tabBar];
}

// Keeps the native selection in sync when YouTube changes tabs itself, e.g.
// via a deep link or the back gesture.
- (void)selectItemWithPivotIdentifier:(NSString *)identifier {
    %orig;
    if (YTMNGNativeTabBarEnabled()) [self ytmng_selectIdentifier:identifier];
}

%end
