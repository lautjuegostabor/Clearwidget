#!/usr/bin/env python3
"""Prepare isolated shortcut test from verified pinned vendor; no account operations."""
import pathlib,sys
import prepare_signer as p
root=pathlib.Path(__file__).resolve().parents[1]
dest=pathlib.Path(sys.argv[1])
main=dest/'src/main.rs'; install=dest/'src/install.rs'; bundle=dest/'src/sign/bundle.rs'
s=main.read_text()
s=p.replace(s,'mod bridge_entitlements;','mod bridge_entitlements;\nmod shortcut_trial;')
# Restrict entire binary to one explicit command; no UI, login, update, or other operations.
start=s.index('    let args: Vec<String> = std::env::args().skip(1).collect();')
end=s.index('\nasync fn run(',start)
s=s[:start]+'''    if std::env::args().skip(1).collect::<Vec<_>>() != vec!["test-shortcuts".to_string()] {
        eprintln!("Usage: clearwidget-shortcut-trial test-shortcuts");
        return ExitCode::FAILURE;
    }
    let rt=tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("runtime");
    match rt.block_on(shortcut_trial::run()) {
        Ok(())=>ExitCode::SUCCESS,
        Err(e)=>{eprintln!("{e}");ExitCode::FAILURE}
    }
}
'''+s[end:]
main.write_text(s)
s=install.read_text()
anchor='    apps.sort_by_key(|b| b.depth());'
s=p.replace(s,anchor,anchor+'''
    if bundles.len()!=2 || main.version!="0.5.8" ||
        apps.iter().any(|b| b.info.get("CFBundleVersion").and_then(Value::as_string)!=Some("14")) ||
        bundles.iter().any(|b| ipa.files.contains_key(&format!("{}/embedded.mobileprovision",b.dir))) {
        return Err("Expected unsigned ClearWidget 0.5.8 build 14".into());
    }''')
anchor='        let p = bundle::profile_plist(&profile)?;'
# This exact anchor may occur only in prepare_and_sign; restrict first occurrence to its function.
start=s.index('pub async fn prepare_and_sign')
end=s.index('/// AltStore-family',start)
body=s[start:end]
body=p.replace(body,anchor,anchor+'''
        if p.get("TeamIdentifier").and_then(Value::as_array).is_none_or(|v|!v.iter().any(|x|x.as_string()==Some(team))) ||
            p.get("ProvisionedDevices").and_then(Value::as_array).is_none_or(|v|!v.iter().any(|x|x.as_string()==Some(ctx.udid))) {
            return Err("Profile team or device mismatch".into());
        }''')
body=p.replace(body,'        bundle::sign(&mut ipa, &plan, &mut |n, t| status(format!("Signing {n} of {t}")))?;',
'''        bundle::sign(&mut ipa, &plan, &mut |n, t| status(format!("Signing {n} of {t}")))?;
        bundle::verify_shortcut_trial(&ipa,&plan)?;''')
install.write_text(s[:start]+body+s[end:])
bundle.write_text(bundle.read_text()+(root/'Recovery/shortcut_signature_audit.rs').read_text())
(dest/'src/shortcut_trial.rs').write_text((root/'Recovery/shortcut_trial.rs').read_text())
