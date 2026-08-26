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
- (void)ytmng_installNativeSearch;
- (void)ytmng_submitQuery:(NSString *)query;
@end

static char kSuggestionsKey;
static char kTableKey;
static char kSearchBarKey;

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
    objc_setAssociatedObject(self, &kSuggestionsKey, [NSArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    [(UISearchBar *)objc_getAssociatedObject(self, &kSearchBarKey) becomeFirstResponder];
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
