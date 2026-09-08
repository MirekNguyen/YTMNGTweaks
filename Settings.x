// Adds a "YTMNGTweaks" row to the YouTube Settings screen.
//
// 21.33.6 builds the settings list from groups, not from one flat category
// list. YTSettingsGroupData vends the categories per group:
//
//   -accountCategories                    -> "Account"
//   -videoandAudioPreferencesCategories   -> "Video and audio preferences"
//   -helpAndPoliciesCategories            -> "Help and policies"
//
// which is exactly the section layout the app renders. The older
// +[YTAppSettingsPresentationData settingsCategoryOrder] still exists but no
// longer drives the screen, so appending to it alone renders nothing.
//
// Where the row goes
// ------------------
// Sitting in "Account" was wrong -- this is a tweak, not an account setting.
// YouGroupSettings (built alongside us, since RYD depends on it) adds a
// "Tweaks" group and populates it from a class method it grafts onto
// YTSettingsGroupData: +tweaks, a mutable array of category IDs. Every tweak in
// that list is rendered in the Tweaks group, and any of them that passes a nil
// icon is given YouTube's gear glyph. So registering there is all it takes to
// sit alongside RYD and the rest, with a matching icon.
//
// The Account fallback is kept for the case where YouGroupSettings is not
// installed, because otherwise the settings row would vanish entirely.
//
// Rows themselves come from
//   -[YTSettingsSectionItemManager updateSectionForCategory:withEntry:]
// which is called once per category ID in the group.

#import "YTMNGTweaks.h"

// Four-character code, matching the convention YouGroupSettings uses for tweaks
// that have no upstream-assigned number ('ytwk', 'ytic', ...). Well clear of
// YouTube's own numeric category IDs.
static const NSUInteger YTMNGSettingsCategory = 'ytmg';

// Set when YouGroupSettings accepted our registration, so the Account-group
// fallback can stand down and we do not appear twice.
static BOOL YTMNGRegisteredInTweaksGroup = NO;

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray *)settingsCategoryOrder;
@end

@interface YTSettingsGroupData : NSObject
- (NSArray *)accountCategories;
// Grafted on by YouGroupSettings; absent when that tweak is not installed.
+ (NSMutableArray *)tweaks;
@end

@interface YTSettingsSectionItemManager : NSObject
- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry;
@end

// Registers with YouGroupSettings' Tweaks group. Returns NO when that tweak is
// not present, in which case the caller falls back to the Account group.
static BOOL registerInTweaksGroup(void) {
    if (YTMNGRegisteredInTweaksGroup) return YES;

    Class groupData = NSClassFromString(@"YTSettingsGroupData");
    if (![groupData respondsToSelector:@selector(tweaks)]) return NO;

    NSMutableArray *tweaks = [groupData tweaks];
    if (![tweaks isKindOfClass:[NSMutableArray class]]) return NO;

    NSNumber *category = @(YTMNGSettingsCategory);
    if (![tweaks containsObject:category]) [tweaks addObject:category];

    YTMNGRegisteredInTweaksGroup = YES;
    return YES;
}

static NSArray *appendCategory(NSArray *categories) {
    if (![categories isKindOfClass:[NSArray class]]) return categories;

    NSNumber *category = @(YTMNGSettingsCategory);
    if ([categories containsObject:category]) return categories;

    NSMutableArray *updated = [categories mutableCopy];
    [updated addObject:category];
    return updated;
}

%hook YTSettingsGroupData

- (NSArray *)accountCategories {
    // %orig must be bound to a local first: logos mis-parses it when nested
    // directly inside another call's argument list.
    NSArray *categories = %orig;
    if (registerInTweaksGroup()) return categories;
    return appendCategory(categories);
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *categories = %orig;
    if (registerInTweaksGroup()) return categories;
    return appendCategory(categories);
}

%end


%hook YTSettingsSectionItemManager

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category != YTMNGSettingsCategory) {
        %orig;
        return;
    }

    YTSettingsViewController *delegate = [self valueForKey:@"_settingsViewControllerDelegate"];
    if (!delegate) {
        %orig;
        return;
    }

    NSMutableArray *rows = [NSMutableArray array];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Liquid Glass (experimental)"
           titleDescription:@"Forces YouTube's built-in Liquid Glass styling. "
                            @"Requires iOS 26 and a full app restart. This code "
                            @"is unfinished in the app, so expect rough edges."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGLiquidGlassKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGLiquidGlassKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Replace bottom bar with native tab bar"
           titleDescription:@"Swaps YouTube's bar for a real UIKit UITabBar with "
                            @"SF Symbol icons. Navigation is forwarded to YouTube, "
                            @"so badges and the create button are not carried over. "
                            @"Requires iOS 26."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGNativeTabBarKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGNativeTabBarKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Search button beside the tab bar"
           titleDescription:@"Adds a detached glass search button next to the "
                            @"native tab bar, the way Messages and Zalo do it. "
                            @"Requires the native tab bar."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGTabBarSearchKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGTabBarSearchKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Native search screen"
           titleDescription:@"Native search bar with YouTube's autocomplete "
                            @"suggestions. Submitting hands off to YouTube's "
                            @"results screen."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGNativeSearchKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGNativeSearchKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Hide Subscribe and Join"
           titleDescription:@"Removes the Subscribe pill and the Join button "
                            @"from channel pages."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGHideSubscribeKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGHideSubscribeKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Glass header buttons"
           titleDescription:@"Groups the header actions into a glass capsule, "
                            @"like the GitHub app. Requires iOS 26."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGGlassHeaderKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGGlassHeaderKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Glass search field"
           titleDescription:@"Gives the search field the system Liquid Glass "
                            @"material. Requires iOS 26."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGGlassSearchKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGGlassSearchKey, enabled);
                    return YES;
                }]];

    [rows addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Native glass bottom bar"
           titleDescription:@"Replaces the bottom bar's material with the real "
                            @"iOS UIGlassEffect and reshapes it into the system "
                            @"floating capsule. Requires iOS 26."
    accessibilityIdentifier:nil
                   switchOn:YTMNGGetBool(YTMNGNativeBarKey)
                switchBlock:^BOOL(id cell, BOOL enabled) {
                    YTMNGSetBool(YTMNGNativeBarKey, enabled);
                    return YES;
                }]];

    for (NSUInteger i = 0; i < YTMNGHideableTabsCount; i++) {
        YTMNGTabSpec spec = YTMNGHideableTabs[i];
        NSString *key = spec.key;

        YTSettingsSectionItem *row = [%c(YTSettingsSectionItem)
            switchItemWithTitle:[NSString stringWithFormat:@"Hide %@ tab", spec.title]
               titleDescription:[NSString stringWithFormat:
                                    @"Removes the %@ tab from channel pages. "
                                    @"Reopen the channel to apply.", spec.title]
        accessibilityIdentifier:nil
                       switchOn:YTMNGGetBool(key)
                    switchBlock:^BOOL(id cell, BOOL enabled) {
                        YTMNGSetBool(key, enabled);
                        return YES;
                    }];
        if (row) [rows addObject:row];
    }

    // icon stays nil on purpose: YouGroupSettings fills in YouTube's gear glyph
    // for every category in its Tweaks list, which is how the other tweaks get
    // theirs. Passing our own would look inconsistent beside them.
    [delegate setSectionItems:rows
                  forCategory:YTMNGSettingsCategory
                        title:@"YTMNGTweaks"
                         icon:nil
             titleDescription:@"Native tab bar, search, Liquid Glass and channel tab hiding."
                 headerHidden:NO];
}

%end
