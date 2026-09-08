// Native search screen: a UIKit search bar with YouTube's own autocomplete
// suggestions, handing off to YouTube's results screen on submit.
//
// Why suggestions rather than a native results list
// -------------------------------------------------
// Search results no longer arrive as videoRenderer/compactVideoRenderer.
// YTIItemSectionSupportedRenderers has 210 renderer variants including
// hasElementRenderer, and search results now come back as Elements payloads --
// a serialized layout format, not a plain protobuf message with a title field.
// Walking for videoRenderer therefore found zero results every time. Decoding
// Elements is a much larger problem, so the native list is dropped and YouTube
// renders results.
//
// How the data is obtained
// ------------------------
// Not by constructing services. The earlier attempt to look up a search service
// failed because the services locator is YTLiveServices, which vends none, and
// no class holds one as an ivar. Instead we drive YouTube's own methods:
//
//   -[YTSearchViewController setSearchText:forceRefreshSuggestions:]
//        triggers a suggest fetch
//   -[YTSearchViewController setSuggestions:]
//        is where they land -- hooked to render them natively
//   -[YTSearchViewController performSearch:selectedIndexPath:searchMethod:]
//        runs the search, with YouTube building the request
//
// So context, auth and params are all YouTube's, not hand-assembled.

#import "YTMNGTweaks.h"
#import <objc/runtime.h>

@interface YTSearchSuggestion : NSObject
@property (nonatomic, readonly) NSString *text;
@end

@interface YTSearchViewController : UIViewController
- (void)performSearch:(NSString *)query selectedIndexPath:(id)indexPath searchMethod:(int)method;
- (void)setSearchText:(NSString *)text forceRefreshSuggestions:(BOOL)refresh;
- (void)dismissSearch;
- (NSString *)latestQuery;
- (NSString *)query;
- (void)ytmng_installNativeSearch;
- (void)ytmng_submitQuery:(NSString *)query;
- (void)ytmng_resetSearch;
- (void)ytmng_syncQueryFromYouTube;
@end

static char kSuggestionsKey;
static char kTableKey;
static char kSearchBarKey;

// Breathing room around the search field so the glass capsule floats instead of
// bleeding off the screen edges.
static const CGFloat YTMNGSearchBarInsetH = 8.0;
static const CGFloat YTMNGSearchBarInsetV = 4.0;

static BOOL nativeSearchEnabled(void) {
    return YTMNGGetBool(YTMNGNativeSearchKey);
}

// Suggestion objects expose -text; fall back defensively so an unexpected model
// degrades to something readable rather than an empty list.
static NSString *suggestionText(id suggestion) {
    if ([suggestion isKindOfClass:[NSString class]]) return suggestion;
    if ([suggestion respondsToSelector:@selector(text)]) {
        id value = [suggestion performSelector:@selector(text)];
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    return nil;
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
    searchBar.showsCancelButton = YES;
    searchBar.returnKeyType = UIReturnKeySearch;
    searchBar.enablesReturnKeyAutomatically = NO;
    searchBar.autocorrectionType = UITextAutocorrectionTypeNo;

    // UISearchBar draws its own round "clear text" button inside the field, and
    // we already show a cancel button beside it -- two X's for one job. The
    // field's is the redundant one: the cancel button leaves the screen, which
    // is what the user actually wants, and on iOS 26 it is the one wearing the
    // glass capsule. Suppress the inner one.
    searchBar.searchTextField.clearButtonMode = UITextFieldViewModeNever;

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.dataSource = (id)self;
    table.delegate = (id)self;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.backgroundColor = [UIColor clearColor];
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    [host addSubview:searchBar];
    [host addSubview:table];

    UILayoutGuide *guide = host.safeAreaLayoutGuide;

    // Bottom-anchored, the way Photos does it.
    //
    // The field used to sit at the top, which broke the one thing the tab bar
    // button was for: the button is at the bottom-right, so expanding it and
    // then showing a field at the opposite end of the screen reads as the
    // button vanishing and an unrelated screen appearing. Docking the field at
    // the bottom makes the expansion continuous -- the circle grows into the
    // field, in place -- and puts the input next to the thumb instead of a
    // reach away.
    //
    // keyboardLayoutGuide (iOS 15+) tracks the keyboard for us, including the
    // interactive dismiss drag. Below that, fall back to the safe area: the
    // field simply does not rise with the keyboard, which is degraded but not
    // broken. The @available guard is required -- this project deploys to 14.0.
    NSLayoutConstraint *bottom;
    if (@available(iOS 15.0, *)) {
        bottom = [searchBar.bottomAnchor constraintEqualToAnchor:host.keyboardLayoutGuide.topAnchor
                                                        constant:-YTMNGSearchBarInsetV];
    } else {
        bottom = [searchBar.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor
                                                        constant:-YTMNGSearchBarInsetV];
    }

    [NSLayoutConstraint activateConstraints:@[
        bottom,
        [searchBar.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:YTMNGSearchBarInsetH],
        [searchBar.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-YTMNGSearchBarInsetH],
        // Suggestions fill everything above the field.
        [table.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [table.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:searchBar.topAnchor],
    ]];

    objc_setAssociatedObject(self, &kSearchBarKey, searchBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kTableKey, table, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kSuggestionsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)ytmng_resetSearch {
    UISearchBar *searchBar = objc_getAssociatedObject(self, &kSearchBarKey);
    UITableView *table = objc_getAssociatedObject(self, &kTableKey);

    searchBar.text = @"";
    objc_setAssociatedObject(self, &kSuggestionsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [table reloadData];

    // Clear YouTube's copy too, otherwise it keeps serving suggestions for the
    // old query and the next -setSuggestions: repopulates our list with it.
    if ([self respondsToSelector:@selector(setSearchText:forceRefreshSuggestions:)])
        [self setSearchText:@"" forceRefreshSuggestions:NO];
}

// Mirrors YouTube's own idea of the current query into the field.
//
// The first attempt at fixing stale text cleared the field on every appearance,
// which broke the behaviour it was meant to protect: stock YouTube keeps the
// query when you come back from a results page, so you can edit and re-run it.
// Clearing unconditionally threw that away.
//
// YouTube already tracks this (-latestQuery, falling back to -query), and it is
// the same value the results page was built from -- so mirroring it gives both
// halves for free: the query persists when returning from results, and it is
// empty when search is opened fresh from another screen. No guessing about
// which case we are in.
%new
- (void)ytmng_syncQueryFromYouTube {
    UISearchBar *searchBar = objc_getAssociatedObject(self, &kSearchBarKey);
    if (!searchBar) return;

    NSString *query = nil;
    if ([self respondsToSelector:@selector(latestQuery)]) query = [self latestQuery];
    if (query.length == 0 && [self respondsToSelector:@selector(query)]) query = [self query];

    if (![searchBar.text isEqualToString:query ?: @""]) searchBar.text = query ?: @"";

    // The suggestion list belongs to the previous visit either way; YouTube
    // refills it as soon as the field is edited.
    objc_setAssociatedObject(self, &kSuggestionsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [(UITableView *)objc_getAssociatedObject(self, &kTableKey) reloadData];
}

%new
- (void)ytmng_submitQuery:(NSString *)query {
    if (query.length == 0) return;
    [(UISearchBar *)objc_getAssociatedObject(self, &kSearchBarKey) resignFirstResponder];
    if ([self respondsToSelector:@selector(performSearch:selectedIndexPath:searchMethod:)])
        [self performSearch:query selectedIndexPath:nil searchMethod:0];
}

// --- UISearchBarDelegate ---

%new
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if ([self respondsToSelector:@selector(setSearchText:forceRefreshSuggestions:)])
        [self setSearchText:text forceRefreshSuggestions:YES];
}

%new
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self ytmng_submitQuery:searchBar.text];
}

%new
- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self ytmng_resetSearch];

    // YouTube owns how this screen was presented (pushed, or grafted onto the
    // root VC), so let it tear itself down where it can; the navigation
    // fallbacks only run if that method is missing.
    if ([self respondsToSelector:@selector(dismissSearch)]) {
        [self dismissSearch];
        return;
    }
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else if (self.presentingViewController)
        [self dismissViewControllerAnimated:YES completion:nil];
}

// --- UITableView ---

%new
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[(NSArray *)objc_getAssociatedObject(self, &kSuggestionsKey) count];
}

%new
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YTMNGSuggestionCell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"YTMNGSuggestionCell"];

    NSArray *suggestions = objc_getAssociatedObject(self, &kSuggestionsKey);
    if ((NSUInteger)indexPath.row < suggestions.count)
        cell.textLabel.text = suggestions[indexPath.row];

    cell.backgroundColor = [UIColor clearColor];
    return cell;
}

%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSArray *suggestions = objc_getAssociatedObject(self, &kSuggestionsKey);
    if ((NSUInteger)indexPath.row >= suggestions.count) return;

    NSString *query = suggestions[indexPath.row];
    ((UISearchBar *)objc_getAssociatedObject(self, &kSearchBarKey)).text = query;
    [self ytmng_submitQuery:query];
}

// --- YouTube hooks ---

// Where suggestions land after -setSearchText:forceRefreshSuggestions:.
- (void)setSuggestions:(NSArray *)suggestions {
    %orig;
    if (!nativeSearchEnabled()) return;

    UITableView *table = objc_getAssociatedObject(self, &kTableKey);
    if (!table) return;

    NSMutableArray *texts = [NSMutableArray array];
    for (id suggestion in suggestions) {
        NSString *text = suggestionText(suggestion);
        if (text.length > 0) [texts addObject:text];
    }

    objc_setAssociatedObject(self, &kSuggestionsKey, texts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [table reloadData];
}

- (void)viewDidLoad {
    %orig;
    if (!nativeSearchEnabled()) return;
    [self ytmng_installNativeSearch];
}

// becomeFirstResponder in viewDidLoad is a no-op: the view is not in a window
// yet. Installing here too covers a hierarchy built later than viewDidLoad --
// the install guard makes it idempotent.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!nativeSearchEnabled()) return;
    [self ytmng_installNativeSearch];

    UISearchBar *searchBar = objc_getAssociatedObject(self, &kSearchBarKey);
    [searchBar becomeFirstResponder];

    // The field is pre-filled with the last query (see
    // -ytmng_syncQueryFromYouTube). Selecting it rather than parking the caret
    // at the end means typing replaces the old query -- the useful default --
    // while a tap still drops in to edit or re-run it.
    if (searchBar.text.length > 0) [searchBar.searchTextField selectAll:nil];
}

// YouTube keeps this controller alive and re-presents it, so the field has to
// be re-synced on every appearance rather than only on load.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!nativeSearchEnabled()) return;
    [self ytmng_installNativeSearch];
    [self ytmng_syncQueryFromYouTube];
}

// -setSearchText: is how YouTube reports a query it set itself (a suggestion
// tap, a voice search, restoring a results page), so follow it.
- (void)setSearchText:(NSString *)text forceRefreshSuggestions:(BOOL)refresh {
    %orig;
    if (!nativeSearchEnabled()) return;

    UISearchBar *searchBar = objc_getAssociatedObject(self, &kSearchBarKey);
    if (searchBar && !searchBar.isFirstResponder && ![searchBar.text isEqualToString:text ?: @""])
        searchBar.text = text ?: @"";
}

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
