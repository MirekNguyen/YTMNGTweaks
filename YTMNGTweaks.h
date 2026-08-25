#import <UIKit/UIKit.h>

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

#define YTMNGPrefsDomain @"com.mireknguyen.ytmngtweaks"

// Each hideable channel tab is keyed by the `browseEndpoint.params` value the
// server sends for it. That value is a base64 protobuf blob (field 2 = a fixed
// ASCII tab name) and is byte-identical in every UI language, so matching on it
// survives locale changes in a way that matching the visible title would not.
//
//   home EgRob21l | videos EgZ2aWRlb3M | shorts EgZzaG9ydHM
//   streams (Live) EgdzdHJlYW1z | playlists EglwbGF5bGlzdHM
//   posts EgVwb3N0cw | store EgVzdG9yZQ | releases EghyZWxlYXNlcw
//   podcasts Eghwb2RjYXN0cw | channels EghjaGFubmVscw | about EgVhYm91dA

typedef struct {
    __unsafe_unretained NSString *key;     // NSUserDefaults key
    __unsafe_unretained NSString *title;   // Settings row label
    __unsafe_unretained NSString *params;  // browseEndpoint.params prefix
} YTMNGTabSpec;

extern const YTMNGTabSpec YTMNGHideableTabs[];
extern const NSUInteger YTMNGHideableTabsCount;

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
