#import <UIKit/UIKit.h>

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

#define YTMNGPrefsDomain @"com.mireknguyen.ytmngtweaks"

// Each hideable channel tab is identified by the `browseEndpoint.params` the
// server sends for it. That value is base64 of a protobuf whose field 2 is a
// fixed ASCII tab name ("streams", "shorts", ...), identical in every UI
// language -- so it survives locale changes in a way the visible title cannot.
//
// We base64-DECODE params and read that name out, rather than prefix-matching
// the base64 text. Prefix matching is subtly broken: base64 encodes in 3-byte
// groups, and the real params has a trailing blob appended after the name.
// Unless the name chunk happens to be a multiple of 3 bytes, the characters at
// the boundary differ from the name encoded on its own:
//
//   \x12\x07streams  = 9 bytes -> "EgdzdHJlYW1z"  + trailer -> "EgdzdHJlYW1z8gY..."  stable
//   \x12\x06shorts   = 8 bytes -> "EgZzaG9ydHM"   + trailer -> "EgZzaG9ydHPyBgQ..."  diverges
//
// which is why Live (streams) matched and every other tab silently did not.

typedef struct {
    __unsafe_unretained NSString *key;    // NSUserDefaults key
    __unsafe_unretained NSString *title;  // Settings row label
    __unsafe_unretained NSString *name;   // decoded protobuf tab name
} YTMNGTabSpec;

extern const YTMNGTabSpec YTMNGHideableTabs[];
extern const NSUInteger YTMNGHideableTabsCount;

// Master switch for YouTube's own Liquid Glass code path.
#define YTMNGLiquidGlassKey @"YTMNGLiquidGlass"

// Replaces the pivot bar material with the system UIGlassEffect.
#define YTMNGNativeBarKey @"YTMNGNativeBar"

// Replaces the pivot bar entirely with a real UIKit UITabBar.
#define YTMNGNativeTabBarKey @"YTMNGNativeTabBar"

// Glass material behind the search field.
#define YTMNGGlassSearchKey @"YTMNGGlassSearch"

// Replaces YouTube's search screen with a native UIKit search UI.
#define YTMNGNativeSearchKey @"YTMNGNativeSearch"

// GitHub-style glass capsule behind the header action buttons.
#define YTMNGGlassHeaderKey @"YTMNGGlassHeader"

BOOL YTMNGNativeTabBarEnabled(void);
BOOL YTMNGGetBool(NSString *key);
void YTMNGSetBool(NSString *key, BOOL value);

// ---------------------------------------------------------------------------
// YouTube internals (verified by class-dumping YouTube 21.33.6)
// ---------------------------------------------------------------------------

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
@property (nonatomic, strong) NSMutableArray *tabsArray;
@end

@interface YTITwoColumnBrowseResultsRenderer : NSObject
@property (nonatomic, strong) NSMutableArray *tabsArray;
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

// Decodes browseEndpoint.params to its protobuf tab name, or nil.
NSString *YTMNGTabNameFromParams(NSString *params);

// Shared entry point used by every hook site.
void YTMNGFilterTabsInModel(id model);

// ---------------------------------------------------------------------------
// Settings internals
// ---------------------------------------------------------------------------

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)description
            accessibilityIdentifier:(NSString *)identifier
                           switchOn:(BOOL)on
                        switchBlock:(BOOL (^)(id cell, BOOL enabled))block;
@end

@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSArray *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
                   icon:(id)icon
       titleDescription:(NSString *)description
           headerHidden:(BOOL)hidden;
@end
