# AGENTS.md — YTMNGTweaks

Personal YouTube-for-iOS tweak by MirekNguyen (`com.mireknguyen.ytmngtweaks`).
Built by GitHub Actions in `MirekNguyen/YTPlusM` (`_build_tweaks.yml`, gated on the
`enable_ytmng` input) and injected into a decrypted YouTube IPA with `cyan`.
Broader workspace context: see the workspace-level `AGENTS.md` one directory up.

## Target

- YouTube **21.33.6** — every interface in `YTMNGTweaks.h` was class-dumped from
  that build. Re-verify them before assuming hooks work on a newer IPA.
- Theos/logos, `arm64`, iOS 14.0 min (15.0 for `rootless`/`roothide`), ARC on.
- CI builds **rootful** with `make clean package DEBUG=0 FINALPACKAGE=1`.
- MobileSubstrate filter: bundle `com.google.ios.youtube` (`YTMNGTweaks.plist`).

## Files

| File | Purpose |
|---|---|
| `YTMNGTweaks.h` | Prefs domain, `YTMNGTabSpec`, all `YTMNG*` defaults keys, YouTube class re-declarations. |
| `Tweak.x` | Hide channel-page tabs. Base64-decodes `browseEndpoint.params` and reads protobuf field 2 (tag `0x12`) to identify a tab. Hooks `YTTabsViewController` (`loadWithModel:`, `updateWithModel:…`, `reloadTabTitlesWithTabsArray:`, `rebuildIndexMapsWithTabsArray:`) and `YTBrowseResponseViewController -handleInitialOrContinuationBrowseResponse:`. Guards against removing every tab and re-promotes a selection when Home is dropped. |
| `Settings.x` | Registers category `'ytmg'` into YouGroupSettings' **Tweaks** group (`+[YTSettingsGroupData tweaks]`), which also supplies the gear icon — so the icon is passed as `nil` on purpose. Falls back to the Account group when YouGroupSettings is absent. Rows built in `-updateSectionForCategory:withEntry:`. |
| `LiquidGlass.x` | Forces `YTColdConfig -mainAppCoreClientIos27EnableLiquidGlass` / `-enableLiquidGlassEffect` to YES. Only effective if `UIDesignRequiresCompatibility` is `false` in the app Info.plist — the YTPlusM workflow patches that. |
| `NativeBar.x` | Runtime-resolved `UIGlassEffect` on `YTPivotBarView.blurView`, reshaped as an iOS 26 floating capsule. |
| `NativeTabBar.x` | Real `UITabBar` + SF Symbols replacing the pivot bar; taps forwarded to `-[YTPivotBarViewController didTapItemWithRenderer:]` via the `_renderer` ivar. Selection is restored from `YTPivotBarItemView -selected` at build time and re-synced from `YTPivotBarViewController -selectedPivotIdentifier` on layout, because `-selectItemWithPivotIdentifier:` fires before the tab bar exists. Also owns the optional detached glass search button, which calls `YTHeaderViewController -didPressSearchButton:`. |
| `SearchGlass.x` | Glass view behind `YTSearchBoxView` (associated object `kGlassViewKey`). **`YTSearchBarView` is deliberately not hooked** — it is a `UITextField` subclass and inserting a subview into it drew the capsule across the whole topbar. |
| `NativeSearch.x` | Native UIKit search bar driving YouTube's own suggestions (`setSearchText:forceRefreshSuggestions:`, `-setSuggestions:`, `performSearch:selectedIndexPath:searchMethod:`). Results are Elements payloads, rendered by YouTube. |
| `HeaderGlass.x` | Glass capsule grouping header icon buttons (≤64pt per side), pad H10/V6. Skips buttons with no drawn content and clamps to the **safe area**, not `bounds` — otherwise it drew empty grey blobs and a stray circle over the status bar. |
| `ChannelHeader.x` | Hides `subscribeSwitch` / `sponsorButton` in `YTC4TabbedHeaderView -layoutSubviews`. |

## Defaults keys

`YTMNGLiquidGlass`, `YTMNGNativeBar`, `YTMNGNativeTabBar`, `YTMNGGlassSearch`,
`YTMNGNativeSearch`, `YTMNGGlassHeader`, `YTMNGHideSubscribe`, `YTMNGTabBarSearch`, and the tab keys
`YTMNGHideHome/Live/Shorts/Playlists/Posts/Store/Releases/Podcasts/Channels`.

**`YTMNGHideLive` is the only key that defaults to ON.** Everything else is opt-in.

## Rules when changing things

1. New `.x` file → add it to `YTMNGTweaks_FILES` in `Makefile`, or it silently won't build in.
2. Every feature must be behind a defaults key declared in `YTMNGTweaks.h` and exposed in `Settings.x`.
3. Bump `Version:` in `control` (semver) for anything user-visible — CI reads it for the release tag.
4. Keep the code warning-clean — unused hook parameters have broken CI before (`0291921`).
5. `main` is the release branch: CI clones `--depth=1` from `main`, so pushing ships.
6. Don't add a CI workflow here; building is YTPlusM's job.
7. Conventional commits (`feat:`, `fix(scope):`, `chore:`); body explains why.

## Changelog

Append one line per session. Newest last.

- **2026-09-08** — Documented the repo (this file). No code changes; `main` @ `195b6d4`, v2.6.0.
- **2026-09-08** — v2.7.0 (`7fd8183`). Fixed: blank tab bar selection at launch,
  systemBlue tab tint, stale search text on re-entry, duplicate clear button,
  search bar running off the screen edges, oversized header capsule. Added the
  detached tab bar search button (`YTMNGTabBarSearch`).
- **2026-09-08** — v2.8.0. Search keeps its query on re-entry; header glass no
  longer wraps invisible buttons or escapes into the status bar; tab bar
  re-clears YouTube's chrome in `-styleBackgroundColors`; search glyph contrast;
  settings moved into the YouGroupSettings Tweaks group as `'ytmg'`.
