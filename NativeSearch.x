// Replaces YouTube's search screen with a native UIKit search UI.
//
// This is a real reimplementation, not a restyle: a UISearchBar plus a plain
// UITableView of result titles, in the style of a stock iOS search screen.
// YouTube's own search view hierarchy is hidden behind it.
//
// Verified call chain (YouTube 21.33.6)
// -------------------------------------
//   [self valueForKey:@"services"]              -> id<YTServices>
//   [services searchService]                    -> YTAppSearchService
//   +[YTISearchRequest searchRequestWithQuery:params:]
//   -[YTAppSearchService makeRequest:refresh:responseBlock:errorBlock:]
//     -> YTISearchResponse
//          .contents.sectionListRenderer.contentsArray
//            -> YTISectionListSupportedRenderers.itemSectionRenderer
//                 .contentsArray
//                   -> YTIItemSectionSupportedRenderers
//                        .videoRenderer / .compactVideoRenderer
//                          .title (YTIFormattedString) + .navigationEndpoint
//
// Tapping a row sends YTVideoCellTappedActionResponderEvent -- the app's own
// "a video cell was tapped" event -- so playback is handled by YouTube rather
// than reimplemented.
//
// Scope, deliberately: titles only. No thumbnails, channel names, durations,
// filters, voice search or suggestions. Those are all separate InnerTube
// renderers and would each need their own extraction and layout.

#import "YTMNGTweaks.h"
#import <objc/runtime.h>

@interface YTIFormattedString : NSObject
- (NSString *)stringWithFormattingRemoved;
@end

@interface YTIVideoRenderer : NSObject
@property (nonatomic, strong) YTIFormattedString *title;
@property (nonatomic, strong) YTICommand *navigationEndpoint;
@end

@interface YTIItemSectionSupportedRenderers : NSObject
@property (nonatomic, readonly) BOOL hasVideoRenderer;
@property (nonatomic, strong) YTIVideoRenderer *videoRenderer;
@property (nonatomic, readonly) BOOL hasCompactVideoRenderer;
@property (nonatomic, strong) YTIVideoRenderer *compactVideoRenderer;
@end

@interface YTIItemSectionRenderer : NSObject
@property (nonatomic, strong) NSMutableArray *contentsArray;
@end

@interface YTISectionListSupportedRenderers : NSObject
@property (nonatomic, readonly) BOOL hasItemSectionRenderer;
@property (nonatomic, strong) YTIItemSectionRenderer *itemSectionRenderer;
@end

@interface YTISectionListRenderer : NSObject
@property (nonatomic, strong) NSMutableArray *contentsArray;
@end

@interface YTISearchResponseSupportedRenderers : NSObject
@property (nonatomic, readonly) BOOL hasSectionListRenderer;
@property (nonatomic, strong) YTISectionListRenderer *sectionListRenderer;
@end

@interface YTISearchResponse : NSObject
@property (nonatomic, readonly) BOOL hasContents;
@property (nonatomic, strong) YTISearchResponseSupportedRenderers *contents;
@end

@interface YTISearchRequest : NSObject
+ (instancetype)searchRequestWithQuery:(NSString *)query params:(NSString *)params;
@end

// Declared as uniquely-named protocols rather than @interfaces: the concrete
// classes are declared elsewhere in the headers, and redeclaring them is a
// duplicate-interface error (the same trap UIGlassEffect hit).
@protocol YTMNGSearchService <NSObject>
- (void)makeRequest:(id)request
            refresh:(BOOL)refresh
      responseBlock:(void (^)(id response))responseBlock
         errorBlock:(void (^)(id error))errorBlock;
@end

@protocol YTMNGCommandEvent <NSObject>
- (instancetype)initWithCommand:(id)command firstResponder:(id)responder;
- (void)send;
@end

@interface YTSearchViewController : UIViewController
- (void)ytmng_installNativeSearch;
- (void)ytmng_runQuery:(NSString *)query;
@end

static char kResultsKey;
static char kTableKey;
static char kSearchBarKey;

// A result row: the display title plus the renderer we hand back to YouTube.
@interface YTMNGResult : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) id renderer;
@end
@implementation YTMNGResult
@end

static BOOL nativeSearchEnabled(void) {
    return YTMNGGetBool(YTMNGNativeSearchKey);
}

// Walks the search response and pulls out video titles and their renderers.
static NSArray *resultsFromResponse(YTISearchResponse *response) {
    NSMutableArray *results = [NSMutableArray array];
    if (![response respondsToSelector:@selector(hasContents)] || !response.hasContents) return results;

    YTISearchResponseSupportedRenderers *contents = response.contents;
    if (!contents.hasSectionListRenderer) return results;

    for (YTISectionListSupportedRenderers *section in contents.sectionListRenderer.contentsArray) {
        if (![section respondsToSelector:@selector(hasItemSectionRenderer)]) continue;
        if (!section.hasItemSectionRenderer) continue;

        for (YTIItemSectionSupportedRenderers *entry in section.itemSectionRenderer.contentsArray) {
            YTIVideoRenderer *video = nil;
            if ([entry respondsToSelector:@selector(hasVideoRenderer)] && entry.hasVideoRenderer)
                video = entry.videoRenderer;
            else if ([entry respondsToSelector:@selector(hasCompactVideoRenderer)] && entry.hasCompactVideoRenderer)
                video = entry.compactVideoRenderer;
            if (!video) continue;

            NSString *title = [video.title stringWithFormattingRemoved];
            if (title.length == 0) continue;

            YTMNGResult *result = [[YTMNGResult alloc] init];
            result.title = title;
            result.renderer = video;
            [results addObject:result];
        }
    }
    return results;
}

%hook YTSearchViewController

%new
- (void)ytmng_installNativeSearch {
    if (objc_getAssociatedObject(self, &kTableKey)) return;

    UIView *host = self.view;
    if (!host) return;

    UISearchBar *searchBar = [[UISearchBar alloc] init];
    searchBar.placeholder = @"Search YouTube";
    searchBar.delegate = (id)self;
    searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    searchBar.searchBarStyle = UISearchBarStyleMinimal;

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.dataSource = (id)self;
    table.delegate = (id)self;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.backgroundColor = [UIColor clearColor];
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    [host addSubview:searchBar];
    [host addSubview:table];

    UILayoutGuide *guide = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [searchBar.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [searchBar.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [searchBar.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [table.topAnchor constraintEqualToAnchor:searchBar.bottomAnchor],
        [table.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
    ]];

    objc_setAssociatedObject(self, &kSearchBarKey, searchBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kTableKey, table, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kResultsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [searchBar becomeFirstResponder];
}

%new
- (void)ytmng_runQuery:(NSString *)query {
    if (query.length == 0) return;

    id services = [self valueForKey:@"services"];
    if (![services respondsToSelector:@selector(searchService)]) return;

    id<YTMNGSearchService> service = [services performSelector:@selector(searchService)];
    if (![service respondsToSelector:@selector(makeRequest:refresh:responseBlock:errorBlock:)]) return;

    id request = [%c(YTISearchRequest) searchRequestWithQuery:query params:nil];
    if (!request) return;

    __weak typeof(self) weakSelf = self;
    [service makeRequest:request
                 refresh:NO
           responseBlock:^(id response) {
               NSArray *results = resultsFromResponse(response);
               dispatch_async(dispatch_get_main_queue(), ^{
                   typeof(self) strongSelf = weakSelf;
                   if (!strongSelf) return;
                   objc_setAssociatedObject(strongSelf, &kResultsKey, results, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                   [(UITableView *)objc_getAssociatedObject(strongSelf, &kTableKey) reloadData];
               });
           }
              errorBlock:^(id error) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      typeof(self) strongSelf = weakSelf;
                      if (!strongSelf) return;
                      objc_setAssociatedObject(strongSelf, &kResultsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                      [(UITableView *)objc_getAssociatedObject(strongSelf, &kTableKey) reloadData];
                  });
              }];
}

%new
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self ytmng_runQuery:searchBar.text];
}

%new
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[(NSArray *)objc_getAssociatedObject(self, &kResultsKey) count];
}

%new
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YTMNGResultCell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"YTMNGResultCell"];

    NSArray *results = objc_getAssociatedObject(self, &kResultsKey);
    if ((NSUInteger)indexPath.row < results.count) {
        YTMNGResult *result = results[indexPath.row];
        cell.textLabel.text = result.title;
        cell.textLabel.numberOfLines = 2;
        cell.backgroundColor = [UIColor clearColor];
    }
    return cell;
}

%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSArray *results = objc_getAssociatedObject(self, &kResultsKey);
    if ((NSUInteger)indexPath.row >= results.count) return;

    YTIVideoRenderer *video = ((YTMNGResult *)results[indexPath.row]).renderer;
    id command = video.navigationEndpoint;
    if (!command) return;

    // The app's own "video cell tapped" event, so YouTube performs playback.
    Class eventClass = %c(YTVideoCellTappedActionResponderEvent);
    id<YTMNGCommandEvent> event =
        [(id<YTMNGCommandEvent>)[eventClass alloc] initWithCommand:command firstResponder:self];
    if ([event respondsToSelector:@selector(send)]) [event send];
}

- (void)viewDidLoad {
    %orig;
    if (!nativeSearchEnabled()) return;
    [self ytmng_installNativeSearch];
}

// Keep YouTube's own search chrome out of the way without tearing it down, so
// dismissal and lifecycle still work.
- (void)viewDidLayoutSubviews {
    %orig;
    if (!nativeSearchEnabled()) return;

    UIView *table = objc_getAssociatedObject(self, &kTableKey);
    UIView *searchBar = objc_getAssociatedObject(self, &kSearchBarKey);
    if (!table) return;

    for (UIView *subview in self.view.subviews) {
        if (subview == table || subview == searchBar) continue;
        subview.hidden = YES;
    }
    [self.view bringSubviewToFront:table];
    [self.view bringSubviewToFront:searchBar];
}

%end
