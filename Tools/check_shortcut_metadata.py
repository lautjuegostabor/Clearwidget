#!/usr/bin/env python3
import json, pathlib, sys, plistlib
host, widget = map(pathlib.Path, sys.argv[1:3])
ids = {"AppleWeatherUpdateIntent", "ActivityUpdateIntent", "ClearWidgetStatusIntent"}
for directory, is_host in [(host, True), (widget, False)]:
    info = plistlib.loads((directory / 'Info.plist').read_bytes())
    assert info['CFBundleDisplayName'] == '\u2800', 'Invisible label changed'
    metadata = json.loads((directory / 'Metadata.appintents/extract.actionsdata').read_bytes())
    actions = metadata['actions']
    if is_host:
        assert ids <= actions.keys(), 'Missing host actions'
        for name in ids:
            a = actions[name]
            assert a.get('isDiscoverable') is True and a.get('allowedTargets') == [{'type':1}], (name,a.get('allowedTargets'))
        assert ids <= {a['actionIdentifier'] for a in metadata.get('autoShortcuts', [])}
        root=(directory/'Metadata.appintents/root.ssu.yaml').read_text()
        assert root.splitlines().count('    bundleIdentifier: '+info['CFBundleIdentifier'])==1
    else:
        assert not ids & actions.keys(), 'Duplicate external actions'
        a=actions['AdvanceSmall21']
        assert a.get('allowedTargets') == [{'extensionPointIdentifier':'com.apple.widgetkit-extension','type':3}]
        assert a.get('isDiscoverable') is True
        assert 'SelectPage' in actions
print('Host-only discovery, widget-only navigation and original SSU identifier verified; signed runtime test still required.')
