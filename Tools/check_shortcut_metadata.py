#!/usr/bin/env python3
import json, pathlib, sys, plistlib
host, widget = map(pathlib.Path, sys.argv[1:3])
ids = {"AppleWeatherUpdateIntent", "ActivityUpdateIntent", "ClearWidgetStatusIntent"}
target = [{'extensionPointIdentifier':'com.apple.widgetkit-extension','type':3}]
for directory, is_host in [(host, True), (widget, False)]:
    info = plistlib.loads((directory / 'Info.plist').read_bytes())
    assert info['CFBundleDisplayName'] == '\u2800'
    metadata = json.loads((directory / 'Metadata.appintents/extract.actionsdata').read_bytes())
    actions = metadata['actions']
    assert ids | {"NativeAppleWeatherIntent"} <= actions.keys(), ('Missing external actions',directory)
    for name in ids | {"NativeAppleWeatherIntent"}:
        a = actions[name]
        assert a.get('isDiscoverable') is True and a.get('allowedTargets') == target, (name,a.get('allowedTargets'))
    native = actions['NativeAppleWeatherIntent']
    # The compiler must emit every declared field in both targets.
    serialized = json.dumps(native, ensure_ascii=False)
    for param in ('location','currentTemperature','currentCondition','hourlyDates','hourlyTemperatures','hourlyConditions','todayLow','tomorrowHigh'):
        assert param in serialized, ('Missing native field',directory,param)
    auto = {a['actionIdentifier'] for a in metadata.get('autoShortcuts', [])}
    if is_host:
        assert ids | {'ClearSignPreventiveIntent'} <= auto, 'Missing host AppShortcuts'
        assert 'ClearSignPreventiveIntent' in actions
        root=(directory/'Metadata.appintents/root.ssu.yaml').read_text()
        assert root.splitlines().count('    bundleIdentifier: '+info['CFBundleIdentifier'])==1
    else:
        assert not ids & auto, 'Duplicate shortcut provider'
        assert 'ClearSignPreventiveIntent' not in actions, 'Signing action leaked into widget'
        assert actions['AdvanceSmall21'].get('allowedTargets') == target
        assert actions['AdvanceSmall21'].get('isDiscoverable') is True
        assert 'SelectPage' in actions
print('Host registration, identical external action targets, widget navigation, original identifier verified. Runtime routing still requires device validation.')
