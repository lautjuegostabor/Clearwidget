#!/usr/bin/env python3
"""Check generated unsigned metadata; this is not an on-device discovery test."""
import json, pathlib, sys, plistlib
host, widget = map(pathlib.Path, sys.argv[1:3])
ids = {"AppleWeatherUpdateIntent", "ActivityUpdateIntent", "ClearWidgetStatusIntent"}
for directory, expected in [(host, True), (widget, False)]:
    info = plistlib.loads((directory / 'Info.plist').read_bytes())
    assert info['CFBundleDisplayName'] == '\u2800', 'Invisible label changed'
    metadata = json.loads((directory / 'Metadata.appintents/extract.actionsdata').read_bytes())
    actions = metadata['actions']
    if expected:
        assert ids <= actions.keys(), 'Missing shortcut actions in host'
        for name in ids:
            a = actions[name]
            assert a.get('isDiscoverable') is True
            assert a.get('allowedTargets'), f'No explicit execution target for {name}'
            assert not any(t.get('extensionPointIdentifier') == 'com.apple.widgetkit-extension' for t in a['allowedTargets']), name
        assert ids <= {a['actionIdentifier'] for a in metadata.get('autoShortcuts', [])}
        assert info.get('CFBundleDevelopmentRegion') == 'es', 'Incorrect development locale'
    else:
        assert not ids & actions.keys(), 'Duplicate externally discoverable intents in widget'
print('Unsigned shortcut metadata: target separation, discovery and locale checked')
