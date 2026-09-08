// Removes YouTube's own search fields, leaving the tab bar search button as the
// only way in.
//
// Two separate widgets, both broken in the current design:
//
//   YTSearchBoxView  the rounded "Search YouTube" pill -- in the topbar, and
//                    again in the middle of the Home zero state
//   YTSearchBarView  the editable field on the results page, which is a
//                    UITextField subclass that lays itself out edge to edge and
//                    ends up underlapping the back button and the clear button
//
// SearchGlass.x already gave up on styling the second one (a text field manages
// its own subviews, so a glass layer inserted into it renders wrong). With the
// tab bar search button as a working entry point, neither field has a job left,
// and hiding them is what actually fixes the layout rather than papering over
// it.
//
// Hidden rather than removed from the hierarchy: YouTube still owns these views
// and reads their frames, so pulling them out risks constraint and layout
// breakage for no extra benefit.

#import "YTMNGTweaks.h"

static void hideSearchWidget(id view) {
    if (!YTMNGGetBool(YTMNGHideYouTubeSearchKey)) return;

    UIView *widget = view;
    if (!widget.hidden) widget.hidden = YES;
}

%hook YTSearchBoxView

- (void)layoutSubviews {
    %orig;
    hideSearchWidget(self);
}

%end

%hook YTSearchBarView

- (void)layoutSubviews {
    %orig;
    hideSearchWidget(self);
}

%end
