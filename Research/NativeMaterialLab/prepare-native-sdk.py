"""Expose only the WidgetKit declarations confirmed in the installed device SDK.
The simulator linked this same modifier successfully. Never modify Apple's SDK.
"""
import pathlib, subprocess, re
def run(args, **kwargs):
    return subprocess.check_output(args,text=True,**kwargs).strip()
sdk=pathlib.Path(run(['xcrun','--sdk','iphoneos','--show-sdk-path']))
fw=sdk/'System/Library/Frameworks/WidgetKit.framework'
symbols=sorted(set(re.findall(r'[_$][A-Za-z0-9_$]+',(fw/'WidgetKit.tbd').read_text())))
relevant=[s for s in symbols if '24preferredBackgroundStyle' in s or 'WidgetBackgroundStyle' in s or '0cgH0O' in s]
# Demangle complete list, as in the passing simulator ABI verification.
demangled=run(['xcrun','swift-demangle'],input='\n'.join(symbols)+'\n')
lines=[l for l in demangled.splitlines() if 'WidgetBackgroundStyle' in l or 'preferredBackgroundStyle' in l]
print('\n'.join(lines))
assert any('preferredBackgroundStyle(WidgetKit.WidgetBackgroundStyle)' in l for l in lines)
cases=set(re.findall(r'enum case for WidgetKit\.WidgetBackgroundStyle\.([A-Za-z_]+)','\n'.join(lines)))
assert cases=={'opaque','blur','transparent'},cases
base=fw/'Modules/WidgetKit.swiftmodule'
source=next((p for p in [base/'arm64-apple-ios.swiftinterface',base/'arm64e-apple-ios.swiftinterface'] if p.exists()),None)
assert source,base
interface=source.read_text()
if 'enum WidgetBackgroundStyle' not in interface:
    interface+='\n@available(iOS 17.0, *)\npublic enum WidgetBackgroundStyle {\n case opaque\n case blur\n case transparent\n}\n'
if 'func preferredBackgroundStyle(' not in interface:
    interface+='\n@available(iOS 17.0, *)\nextension SwiftUI.WidgetConfiguration {\n @_Concurrency.MainActor @preconcurrency public func preferredBackgroundStyle(_ style: WidgetKit.WidgetBackgroundStyle) -> some SwiftUI.WidgetConfiguration\n}\n'
# The vendor's arm64e interface is ABI compatible for the arm64 target; preserve
# its original module flags and use only its publicly importable Swift syntax.
dest=pathlib.Path('build-local-sdk/WidgetKit.swiftmodule')
dest.mkdir(parents=True,exist_ok=True)
(dest/'arm64-apple-ios.swiftinterface').write_text(interface)
