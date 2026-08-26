// Hides the Subscribe and Join buttons on channel pages.
//
// YTC4TabbedHeaderView exposes both directly:
//   subscribeSwitch  (YTSubscribeSwitch)  -- the Subscribe pill
//   sponsorButton    (YTSponsorButton)    -- the Join button
//
// Both are readonly properties, so we hide the views rather than clearing the
// renderers. That keeps the header's own layout maths intact -- removing them
// from the hierarchy would leave the row's constraints referencing missing
// views.

#import "YTMNGTweaks.h"

@interface YTC4TabbedHeaderView : UIView
@property (nonatomic, readonly) UIView *subscribeSwitch;
@property (nonatomic, readonly) UIView *sponsorButton;
@end

%hook YTC4TabbedHeaderView

- (void)layoutSubviews {
    %orig;

    BOOL hide = YTMNGGetBool(YTMNGHideSubscribeKey);
    self.subscribeSwitch.hidden = hide;
    self.sponsorButton.hidden = hide;
}

%end
