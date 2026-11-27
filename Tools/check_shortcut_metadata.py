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
    assert ids <= actions.keys(), ('Missing external actions',directory)
    for name in ids:
        a = actions[name]
        assert a.get('isDiscoverable') is True and a.get('allowedTargets') == target, (name,a.get('allowedTargets'))
    auto = {a['actionIdentifier'] for a in metadata.get('autoShortcuts', [])}
    if is_host:
        assert ids <= auto, 'Missing host AppShortcuts'
        root=(directory/'Metadata.appintents/root.ssu.yaml').read_text()
        assert root.splitlines().count('    bundleIdentifier: '+info['CFBundleIdentifier'])==1
    else:
        assert not ids & auto, 'Duplicate shortcut provider'
        assert actions['AdvanceSmall21'].get('allowedTargets') == target
        assert actions['AdvanceSmall21'].get('isDiscoverable') is True
        assert 'SelectPage' in actions
print('Host registration, identical external action targets, widget navigation, original identifier verified. Runtime routing still requires device validation.')
