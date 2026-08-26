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
    { @"YTMNGHideHome",      @"Home",      @"home"      },
    { @"YTMNGHideLive",      @"Live",      @"streams"   },
    { @"YTMNGHideShorts",    @"Shorts",    @"shorts"    },
    { @"YTMNGHidePlaylists", @"Playlists", @"playlists" },
    { @"YTMNGHidePosts",     @"Posts",     @"posts"     },
    { @"YTMNGHideStore",     @"Store",     @"store"     },
    { @"YTMNGHideReleases",  @"Releases",  @"releases"  },
    { @"YTMNGHidePodcasts",  @"Podcasts",  @"podcasts"  },
    { @"YTMNGHideChannels",  @"Channels",  @"channels"  },
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

// params arrives as base64 that may be URL-safe (-_ instead of +/), percent
// encoded, and stripped of = padding. Normalise all three, then read protobuf
// field 2 (tag 0x12, one length byte, then the ASCII name).
NSString *YTMNGTabNameFromParams(NSString *params) {
    if (params.length == 0) return nil;

    NSString *encoded = [params stringByRemovingPercentEncoding] ?: params;
    encoded = [encoded stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (encoded.length % 4 != 0)
        encoded = [encoded stringByAppendingString:@"="];

    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:encoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (decoded.length < 3) return nil;

    const unsigned char *bytes = (const unsigned char *)decoded.bytes;
    if (bytes[0] != 0x12) return nil;

    NSUInteger length = bytes[1];
    if (length == 0 || 2 + length > decoded.length) return nil;

    return [[NSString alloc] initWithBytes:bytes + 2 length:length
                                  encoding:NSUTF8StringEncoding];
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
    NSString *name = YTMNGTabNameFromParams(paramsForTabEntry(entry));
    if (name.length == 0) return NO;

    for (NSUInteger i = 0; i < YTMNGHideableTabsCount; i++) {
        YTMNGTabSpec spec = YTMNGHideableTabs[i];
        if ([name isEqualToString:spec.name] && YTMNGGetBool(spec.key))
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
    if (doomed.count == 0 || doomed.count >= tabs.count) return;

    [tabs removeObjectsAtIndexes:doomed];

    // Hiding Home removes the tab the server marked selected, which would leave
    // the page with no active tab. Promote the first survivor so Videos (or
    // whatever remains) opens by default.
    BOOL hasSelection = NO;
    for (YTIBrowseTabSupportedRenderers *entry in tabs) {
        if (entry.hasTabRenderer && entry.tabRenderer.selected) { hasSelection = YES; break; }
    }
    if (hasSelection) return;

    for (YTIBrowseTabSupportedRenderers *entry in tabs) {
        if (entry.hasTabRenderer) { entry.tabRenderer.selected = YES; break; }
    }
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
