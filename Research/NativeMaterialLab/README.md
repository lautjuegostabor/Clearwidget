# Native Material Lab

Research-only project. Not a fix or replacement IPA for ClearWidget. No dependency on its original application, accounts, IPC, signing bridge, data caches or artwork.

Four distinct widget kinds are registered. System is an unmodified descriptor control. Clear and Blur request historical native descriptor values 1 and 2, respectively, using only the lab's own widget descriptors. Glass is an unmodified descriptor with transparent content, serving as a system-rendering reference. The Xcode 27.2 iPhone SDK explicitly rejects widgetTexture(.glass) as unavailable in iOS; it is not an iPhone API and was removed. The four Widget types have independent zero-argument initializers required by Widget.

Acceptance criteria:
- System and Glass must be compared with iOS Home Screen normal and clear appearance to confirm the baseline.
- Clear and Blur must differ from the controls under the same global appearance, without any wallpaper image.
- Widget logs must establish whether the expected descriptor collection was intercepted and rewritten. A rewrite is not proof that the renderer accepted it.
- Only once a fixed native descriptor works on the target OS can dynamic switching be investigated separately.
- Production still requires the four modes selectable inside the app; these four gallery widgets are a diagnostic isolation, not that user-facing feature.

References:
- https://github.com/pookjw/ClearAndBlurredWidgets/blob/main/MyWidget/FooObject.mm
- https://mucahitk.com/es/blog/transparent-widget-iphone
- https://developer.apple.com/videos/play/wwdc2026/277/
- https://developer.apple.com/documentation/swiftui/widgetconfiguration/widgettexture(_:)
- https://developer.limneos.net/?framework=ChronoServices.framework&ios=27.0 (index lists glass options; individual headers blocked by verification at time of research)

No private glass enum value is asserted. The private adapter is optional, guarded, and does not edit other processes or signing permissions. CI checks only compilation and identifier scope, not iPhone rendering. No account or device changes are initiated.

## 0.1.1 — device evidence and local tint investigation
On iOS 27.2.1 (24B156), the user's screenshot confirms clear and blur under fullColor; the original glass control did not produce Liquid Glass. The runtime report confirms CHSGlassOptions. iOS 26 headers independently show CHSWidgetTintParameters owns glassOptions, isClearGlass, isAccentedGlass and wantsGlassMaterial. SBHWidgetDisplayConfiguration consumes tintParameters on the host. This does not establish an extension-controlled path. The diagnostic tests only bounded temporary tint objects (filterStyle 0...12), checks method signatures, reads boolean predicates, and lists local class methods relating to tint/glass. No host request, no descriptor changes, no guessed glass mode shipped. The four previously tested widget implementations remain identical.

## 0.1.2 — native visual tests
Device report: tint filterStyle 3/4 returns wantsGlassMaterial and isClearGlass; 5/6 returns accented glass. These are local tint object predicates, not proof that a widget can submit them. No tint parameters are sent to SpringBoard. Two new fixed kinds combine the already validated descriptor styles 1 and 2 with SwiftUI native glassEffect(.clear) in the content layer, removing margins only on those kinds. Original controls retained. A separate local-only descriptor probe checks readback, material predicates and description for candidate preferredBackgroundStyle values. Unknown descriptor values are not shipped to the renderer. Visual tests are experiments, not a claimed optical result. No production changes.

## 0.1.3 — host-only material candidate
Source: https://github.com/flekstore/FlekDeck/blob/afa5061119cb858d76178b081c78de816c376562/WidgetExtension/SystemGlassBackground.swift and AppsWidget.swift. FlekDeck documents style 2 as the host's own glass; it sets ONLY preferredBackgroundStyle during encoding, not transparency or vibrancy, and uses a single family per kind. This is materially different from the lab's proven Blur path. Independent implementation: two fixed-size kinds, normal flags, clear content, guarded encoding of a verified immutable copy of the extension's own descriptor. No raw ivar mutation, no code copied, no guessed tint filterStyle passed as backgroundStyle. Existing 0.1.1 controls unchanged; supersedes the untested SwiftUI combinations from 0.1.2. No production changes. Optical result not verified on iPhone.

## 0.1.4 — Apple WidgetKit configuration
The two new fixed-family kinds use the exported WidgetKit preferredBackgroundStyle(.blur) modifier, as found in Apple widget binaries. The previous style-only encoder hook is removed. Existing Clear/Blur controls retain the scoped legacy hook. The build verifies the real iPhone SDK case symbols, native import and package identifiers. Simulator gallery registration was observed, but on-Home-Screen optical output was not verified: the prior UI test failed to match the Add Widget label with leading whitespace. This is a native-material candidate, not a proven independent Liquid Glass implementation. No wallpaper or synthetic glass background is used.

## 0.1.5 — Compare lighter materials
Four fixed variants on the previously working Clear descriptor: white tint 8%/16%, Ultra Thin Material opacity 50%/85%. Original Clear and host Blur remain unchanged. The opacity controls the SwiftUI material layer, not the host blur radius. Whether the material samples the real Home Screen behind the extension is unverified. No wallpaper capture or synthetic image.
