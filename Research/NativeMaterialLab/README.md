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
