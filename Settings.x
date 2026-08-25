// Adds a "YTMNGTweaks" row to the YouTube Settings screen.
//
// The app builds its settings list from two places:
//   +[YTAppSettingsPresentationData settingsCategoryOrder]  -> ordered category IDs
//   -[YTSettingsSectionItemManager updateSectionForCategory:withEntry:] -> rows
// so we append a private category ID to the order, then populate it when the
// manager asks about that ID.

#import "YTMNGTweaks.h"

// Arbitrary ID well clear of YouTube's own category numbering.
static const NSUInteger YTMNGSettingsCategory = 8064;

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray *)settingsCategoryOrder;
@end

@interface YTSettingsSectionItemManager : NSObject
- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry;
@end

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    if (![order isKindOfClass:[NSArray class]]) return order;

    NSNumber *category = @(YTMNGSettingsCategory);
    if ([order containsObject:category]) return order;

    NSMutableArray *updated = [order mutableCopy];
    [updated addObject:category];
    return updated;
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

    [delegate setSectionItems:rows
                  forCategory:YTMNGSettingsCategory
                        title:@"YTMNGTweaks"
                         icon:nil
             titleDescription:@"Hide channel page tabs."
                 headerHidden:NO];
}

%end
