# Build 28 — native appearance diagnostics
- Base: 85c8474449e65367097a64e2e316a121251ee7de. No wallpaper processing, emulation or artwork changes.
- Clear: descriptor style 1, do not require or explicitly change vibrant flag. Blur: style 2. Glass probe: style 1 plus native SwiftUI glassEffect(.clear) on the widget content background. Does not claim that WidgetKit retains the effect, nor that host Blur is independent of system appearance.
- Direct reconstruction of widgetDescriptors through original secure coder; other keys preserved. Fallback previous delegate when collection key differs. Validate copied and frozen style; fail closed.
- Hook: early registration and main queue retry, plus timeline retry. No preference reads in constructor.
- Host: reload own effective identifier and then fetch own descriptors; bounded timeout and separate delivery/readback. Error or unrecognized response displayed, not interpreted as success. Callback ABI and result schema observed on earlier system versions remain to be confirmed in iOS 27.2.1.
- Device acceptance: original appearance; Clear/Blur/Glass, on same wallpaper in normal appearance; verify native refraction with real wallpaper changes; restore System; test both families and all designs plus navigation. Compare reported descriptor and visual outcome. No claim of device success before test.
