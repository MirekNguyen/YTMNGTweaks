// YTMNGTweaks — hide channel page tabs (Live, Shorts, ...).
//
// Where the tabs actually come from
// ---------------------------------
// The channel tab strip is driven by YTTabsViewController, NOT by
// YTBrowseResponseViewController. The two are unrelated classes -- dumping the
// superclass chain of 21.33.6 gives:
//
//   YTBrowseResponseViewController -> YTVariableHeightHeaderViewController
//                                  -> YTBaseViewController
//   YTTabsViewController           -> (superclass not in image)
//
// so hooking the browse response view controller never affects channel tabs.
// YTTabsViewController receives its data through -loadWithModel: and friends,
// and the model exposes `tabsArray` (an NSMutableArray of
// YTIBrowseTabSupportedRenderers), the same array type carried by
// YTISingleColumnBrowseResultsRenderer.
//
// We mutate that array in place at the earliest point we see it, so the tab
// titles, the index maps and the content view controllers are all built from
// one already-filtered source. Filtering a copy instead would desync
// -rebuildIndexMapsWithTabsArray: from the model and mismatch tab content.

#import "YTMNGTweaks.h"

const YTMNGTabSpec YTMNGHideableTabs[] = {
    { @"YTMNGHideLive",      @"Live",      @"EgdzdHJlYW1z"   },
    { @"YTMNGHideShorts",    @"Shorts",    @"EgZzaG9ydHM"    },
    { @"YTMNGHidePlaylists", @"Playlists", @"EglwbGF5bGlzdHM" },
    { @"YTMNGHidePosts",     @"Posts",     @"EgVwb3N0cw"     },
    { @"YTMNGHideStore",     @"Store",     @"EgVzdG9yZQ"     },
    { @"YTMNGHideReleases",  @"Releases",  @"EghyZWxlYXNlcw" },
    { @"YTMNGHidePodcasts",  @"Podcasts",  @"Eghwb2RjYXN0cw" },
    { @"YTMNGHideChannels",  @"Channels",  @"EghjaGFubmVscw" },
};
const NSUInteger YTMNGHideableTabsCount = sizeof(YTMNGHideableTabs) / sizeof(YTMNGTabSpec);

BOOL YTMNGGetBool(NSString *key) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Hiding Live is the reason this tweak exists, so it defaults to on.
    // Everything else stays off until explicitly enabled.
    if ([defaults objectForKey:key] == nil)
        return [key isEqualToString:@"YTMNGHideLive"];
    return [defaults boolForKey:key];
}

void YTMNGSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
}

static NSString *paramsForTabEntry(id entry) {
    if (![entry isKindOfClass:%c(YTIBrowseTabSupportedRenderers)]) return nil;

    YTIBrowseTabSupportedRenderers *tab = (YTIBrowseTabSupportedRenderers *)entry;
    YTICommand *endpoint = nil;

    if (tab.hasTabRenderer)
        endpoint = tab.tabRenderer.endpoint;
    else if (tab.hasExpandableTabRenderer)
        endpoint = tab.expandableTabRenderer.endpoint;

    if (!endpoint || !endpoint.hasBrowseEndpoint) return nil;
    return endpoint.browseEndpoint.params;
}

static BOOL shouldHideTabEntry(id entry) {
    NSString *params = paramsForTabEntry(entry);
    if (params.length == 0) return NO;

    for (NSUInteger i = 0; i < YTMNGHideableTabsCount; i++) {
        YTMNGTabSpec spec = YTMNGHideableTabs[i];
        if ([params hasPrefix:spec.params] && YTMNGGetBool(spec.key))
            return YES;
    }
    return NO;
}

static void filterTabsArray(id maybeArray) {
    if (![maybeArray isKindOfClass:[NSMutableArray class]]) return;

    NSMutableArray *tabs = (NSMutableArray *)maybeArray;
    if (tabs.count == 0) return;

    NSIndexSet *doomed = [tabs indexesOfObjectsPassingTest:
        ^BOOL(id entry, NSUInteger idx, BOOL *stop) {
            return shouldHideTabEntry(entry);
        }];

    // Never strip every tab -- an empty strip leaves the channel page blank.
    if (doomed.count > 0 && doomed.count < tabs.count)
        [tabs removeObjectsAtIndexes:doomed];
}

void YTMNGFilterTabsInModel(id model) {
    if (!model) return;

    if ([model isKindOfClass:%c(YTIBrowseResponse)]) {
        YTIBrowseResponse *browse = (YTIBrowseResponse *)model;
        if (!browse.hasContents) return;
        YTIBrowseResponseSupportedRenderers *contents = browse.contents;
        if (contents.hasSingleColumnBrowseResultsRenderer)
            filterTabsArray(contents.singleColumnBrowseResultsRenderer.tabsArray);
        if (contents.hasTwoColumnBrowseResultsRenderer)
            filterTabsArray(contents.twoColumnBrowseResultsRenderer.tabsArray);
        return;
    }

    // The model handed to YTTabsViewController is not a fixed class across
    // versions, so probe for the accessor rather than naming a type.
    if ([model respondsToSelector:@selector(tabsArray)])
        filterTabsArray([model valueForKey:@"tabsArray"]);
}

// ---------------------------------------------------------------------------

%hook YTTabsViewController

- (void)loadWithModel:(id)model {
    YTMNGFilterTabsInModel(model);
    %orig;
}

- (void)loadWithModel:(id)model reloadContentViewControllers:(BOOL)reload {
    YTMNGFilterTabsInModel(model);
    %orig;
}

- (void)updateWithModel:(id)model isDefaultModel:(BOOL)isDefault reloadContentViewControllers:(BOOL)reload {
    YTMNGFilterTabsInModel(model);
    %orig;
}

// Backstops. These receive the model's own array, so mutating in place here is
// a no-op once the calls above have already filtered it.
- (void)reloadTabTitlesWithTabsArray:(id)tabs {
    filterTabsArray(tabs);
    %orig;
}

- (void)rebuildIndexMapsWithTabsArray:(id)tabs {
    filterTabsArray(tabs);
    %orig;
}

%end

// Harmless on channel pages, but catches any other surface that renders tabs
// straight from a browse response.
%hook YTBrowseResponseViewController

- (void)handleInitialOrContinuationBrowseResponse:(id)response {
    YTMNGFilterTabsInModel(response);
    %orig;
}

%end
