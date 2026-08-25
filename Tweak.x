// YTMNGTweaks — hide the "Live" tab on YouTube channel pages.
//
// Approach: filter the browse response before the view controller renders it.
// Channel tabs arrive as:
//   YTIBrowseResponse
//     .contents (YTIBrowseResponseSupportedRenderers)
//       .singleColumnBrowseResultsRenderer.tabsArray  (iPhone)
//       .twoColumnBrowseResultsRenderer.tabsArray     (iPad / wide layouts)
//         -> YTIBrowseTabSupportedRenderers
//              .tabRenderer / .expandableTabRenderer
//                .endpoint.browseEndpoint.params
//
// We match on `params`, not on the title. `params` is a base64 protobuf blob
// that is identical in every UI language:
//   Home "EgVob21l" | Videos "EgZ2aWRlb3M" | Shorts "EgZzaG9ydHM"
//   Live "EgdzdHJlYW1z" (= \x12\x07"streams") | Playlists "EglwbGF5bGlzdHM"
// Matching @"Live" would break on any non-English locale.
//
// Verified against YouTube 21.33.6 (class-dumped).

#import <UIKit/UIKit.h>

static NSString *const kLiveTabParamsPrefix = @"EgdzdHJlYW1z";

@interface YTIBrowseEndpoint : NSObject
@property (nonatomic, copy) NSString *params;
@property (nonatomic, copy) NSString *browseId;
@end

@interface YTICommand : NSObject
@property (nonatomic, strong) YTIBrowseEndpoint *browseEndpoint;
@property (nonatomic, readonly) BOOL hasBrowseEndpoint;
@end

@interface YTITabRenderer : NSObject
@property (nonatomic, strong) YTICommand *endpoint;
@property (nonatomic, readonly) BOOL hasEndpoint;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *tabIdentifier;
@end

@interface YTIExpandableTabRenderer : NSObject
@property (nonatomic, strong) YTICommand *endpoint;
@property (nonatomic, copy) NSString *title;
@end

@interface YTIBrowseTabSupportedRenderers : NSObject
@property (nonatomic, readonly) BOOL hasTabRenderer;
@property (nonatomic, strong) YTITabRenderer *tabRenderer;
@property (nonatomic, readonly) BOOL hasExpandableTabRenderer;
@property (nonatomic, strong) YTIExpandableTabRenderer *expandableTabRenderer;
@end

@interface YTISingleColumnBrowseResultsRenderer : NSObject
@property (nonatomic, strong) NSMutableArray<YTIBrowseTabSupportedRenderers *> *tabsArray;
@end

@interface YTITwoColumnBrowseResultsRenderer : NSObject
@property (nonatomic, strong) NSMutableArray<YTIBrowseTabSupportedRenderers *> *tabsArray;
@end

@interface YTIBrowseResponseSupportedRenderers : NSObject
@property (nonatomic, readonly) BOOL hasSingleColumnBrowseResultsRenderer;
@property (nonatomic, strong) YTISingleColumnBrowseResultsRenderer *singleColumnBrowseResultsRenderer;
@property (nonatomic, readonly) BOOL hasTwoColumnBrowseResultsRenderer;
@property (nonatomic, strong) YTITwoColumnBrowseResultsRenderer *twoColumnBrowseResultsRenderer;
@end

@interface YTIBrowseResponse : NSObject
@property (nonatomic, readonly) BOOL hasContents;
@property (nonatomic, strong) YTIBrowseResponseSupportedRenderers *contents;
@end

static BOOL isLiveTab(YTIBrowseTabSupportedRenderers *entry) {
    YTICommand *endpoint = nil;
    if ([entry respondsToSelector:@selector(hasTabRenderer)] && entry.hasTabRenderer) {
        endpoint = entry.tabRenderer.endpoint;
    } else if ([entry respondsToSelector:@selector(hasExpandableTabRenderer)] && entry.hasExpandableTabRenderer) {
        endpoint = entry.expandableTabRenderer.endpoint;
    }
    if (!endpoint || ![endpoint respondsToSelector:@selector(hasBrowseEndpoint)] || !endpoint.hasBrowseEndpoint)
        return NO;

    NSString *params = endpoint.browseEndpoint.params;
    return params.length > 0 && [params hasPrefix:kLiveTabParamsPrefix];
}

static void stripLiveTab(NSMutableArray<YTIBrowseTabSupportedRenderers *> *tabs) {
    if (![tabs isKindOfClass:[NSMutableArray class]] || tabs.count == 0) return;

    NSIndexSet *doomed = [tabs indexesOfObjectsPassingTest:
        ^BOOL(YTIBrowseTabSupportedRenderers *entry, NSUInteger idx, BOOL *stop) {
            return isLiveTab(entry);
        }];
    if (doomed.count > 0) [tabs removeObjectsAtIndexes:doomed];
}

static void filterBrowseResponse(id response) {
    if (![response isKindOfClass:%c(YTIBrowseResponse)]) return;

    YTIBrowseResponse *browse = (YTIBrowseResponse *)response;
    if (!browse.hasContents) return;

    YTIBrowseResponseSupportedRenderers *contents = browse.contents;
    if (contents.hasSingleColumnBrowseResultsRenderer)
        stripLiveTab(contents.singleColumnBrowseResultsRenderer.tabsArray);
    if (contents.hasTwoColumnBrowseResultsRenderer)
        stripLiveTab(contents.twoColumnBrowseResultsRenderer.tabsArray);
}

%hook YTBrowseResponseViewController

- (void)handleInitialOrContinuationBrowseResponse:(id)response {
    filterBrowseResponse(response);
    %orig;
}

%end
