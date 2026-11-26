#!/usr/bin/env python3
import json, pathlib, sys, plistlib
host, widget = map(pathlib.Path, sys.argv[1:3])
ids = {"AppleWeatherUpdateIntent", "ActivityUpdateIntent", "ClearWidgetStatusIntent"}
for directory, is_host in [(host, True), (widget, False)]:
    info = plistlib.loads((directory / 'Info.plist').read_bytes())
    assert info['CFBundleDisplayName'] == '\u2800', 'Invisible label changed'
    metadata = json.loads((directory / 'Metadata.appintents/extract.actionsdata').read_bytes())
    actions = metadata['actions']
    assert ids <= actions.keys(), f'Missing actions: {directory}'
    for name in ids:
        a = actions[name]
        assert a.get('isDiscoverable') is True, name
        targets = a.get('allowedTargets', [])
        assert len(targets) == 1 and targets[0].get('extensionPointIdentifier') == 'com.apple.widgetkit-extension', (name, targets)
    auto = {a['actionIdentifier'] for a in metadata.get('autoShortcuts', [])}
    if is_host:
        assert ids <= auto
        assert info.get('CFBundleDevelopmentRegion') == 'es'
    else:
        assert not ids & auto, 'Duplicate AppShortcuts provider in extension'
        assert 'AdvanceSmall21' in actions
        assert actions['AdvanceSmall21'].get('allowedTargets', [])[0].get('extensionPointIdentifier') == 'com.apple.widgetkit-extension'
print('Host registers and widget executes; on-device routing still needs verification.')
