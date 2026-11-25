# ClearWidget 0.4.0 — personal-use validation
Native iPhone medium widget, iOS 27+, SwiftUI and WidgetKit.
The original app and widget bundle identifiers and widget kind are unchanged. No App Groups, GPS, background service, timers or runtime asset requests.

## Changes
- Original Clear Medium (Lokki) RGBA artwork: frame, metallic keys, greeting and orange disc. The build verifies exact pixel hashes against the supplied 1480 × 708 reference files and crops keys without resampling. Only the selected key has a new subtle darkened state. This is a personal-use reconstruction; do not distribute the original artwork without permission.
- Original panel alpha is 20%; the outer glass is supplied by iOS in its transparent appearance. No wallpaper capture.
- Native blurReplace animation targeted at panel only (0.28 s), Reduce Motion respected in requested animation; fixed frame. Optimistic Toggle states (0.10 s), no permanent animation. Timing and visual behavior require physical verification.
- RunSystemShortcutIntent, Apple's iOS 27 API: long-press widget → Edit Widget → choose the installed Weather and Calendar applications. No URL relay or UIApplication.open. Unconfigured areas remain in the widget. One-time user choice is mandatory.
- Single stored page + tap marker; timeline consumes the marker before networking. Scheduled weather refresh remains separate; WidgetKit provides no guaranteed reload reason and can coalesce requests. The currently supported single widget shares local state across copies.
- Existing ECMWF/Open-Meteo 30-minute cache, retry throttling and 6 h expiry retained. Córdoba fixed; no GPS. Custom Widgy weather icon mapping is not verified, so SF Symbols and the existing local weather glyph remain for now.
- Weather and calendar links are now native buttons. The user must select both destinations. No opening ClearWidget as an intermediate step.

## Build
Xcode 27 runner; tests before packaging; build-time original asset retrieval and checksum verification. If the original server is unavailable, supply the two exact PNG files under OriginalAssets/ (ignored by git) on the build machine. Never substitute approximate assets silently.
The IPA remains unsigned; install with BariStore preserving BOTH components and existing App IDs.
## Acceptance on iPhone
1. Update existing app using same IDs; add/edit widget and configure both shortcuts.
2. Verify tapping weather/calendar opens destination directly with no ClearWidget intermediate.
3. Compare same-wallpaper screenshots, all three views, red date, original artwork and native glass.
4. Record 30 interactions at 60 fps and measure tap-to-visible median/p95 vs Widgy; evaluate blur and selected key response separately.
5. Check battery in comparable 24 h usage and offline cache; measure rather than promise.
CI verifies code and asset generation; cannot prove signing, physical appearance, latency or battery.
