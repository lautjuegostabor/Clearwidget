#!/usr/bin/env python3
"""Patch a clean pinned MIT source checkout, for ClearWidget ONLY. No network/signing."""
import pathlib, subprocess, sys, shutil
PIN = '56165783f31d3e441ae9f76df42c3cc55e239777'
HERE = pathlib.Path(__file__).resolve().parent

def patch_install(s):
    old='''    let main = ipa.main_app()?;
    if !opts.icon.is_empty()'''
    new='''    let main = ipa.main_app()?;
    // The recovery installer is intentionally limited to ClearWidget.
    if main.id != "com.clearwidget.app" || opts.remove_extensions || opts.increased_memory || !opts.icon.is_empty() {
        return Err("ClearRecovery only accepts the original ClearWidget IPA, with extensions".into());
    }
    if !opts.icon.is_empty()'''
    s=replace(s,old,new)
    old='''    apps.sort_by_key(|b| b.depth());'''
    new=old+'''
    if apps.len() != 2 || !apps.iter().any(|b| b.id == "com.clearwidget.app.widget") {
        return Err("ClearWidget host and original widget extension are both required".into());
    }'''
    s=replace(s,old,new)
    old='    status("Registering this iPhone".into());\n    portal.ensure_device(team, ctx.udid, ctx.device_name).await.map_err(|e| e.to_string())?;'
    s=replace(s,old,'    // Recovery never registers a new device.')
    old='    fit_app_ids(ctx, &apps, &main, &mut ids, &existing, status).await?;'
    new='    if ctx.previous.is_none() || apps.iter().any(|b| !existing.iter().any(|a| a.identifier == ids[&b.dir])) {\n        return Err("Recovery requires the prior installation and both existing App IDs".into());\n    }'
    s=replace(s,old,new)
    old='''    let mut plan_bundles = HashMap::new();'''
    s=replace(s,old,old+'\n    let mut clearwidget_prefix: Option<String> = None;')
    old='''        entitlements.insert("com.apple.developer.team-identifier".into(), Value::String(team.into()));
        plan_bundles.insert'''
    new='''        entitlements.insert("com.apple.developer.team-identifier".into(), Value::String(team.into()));
        let profile_entitlements = p.get("Entitlements").and_then(Value::as_dictionary)
            .ok_or("No entitlements in profile")?;
        let prefix = crate::bridge_entitlements::apply(profile_entitlements, &mut entitlements, &new_id)?;
        if let Some(previous) = &clearwidget_prefix {
            if previous != &prefix { return Err("The two Apple profiles do not share a Keychain prefix".into()); }
        } else { clearwidget_prefix = Some(prefix); }
        if !p.get("DeveloperCertificates").and_then(Value::as_array).into_iter().flatten()
            .filter_map(Value::as_data).any(|x| x == leaf.as_slice()) {
            return Err("Current certificate is not authorized by the profile".into());
        }
        plan_bundles.insert'''
    return replace(s,old,new)

def replace(s,old,new):
    if s.count(old)!=1: raise ValueError('Expected one exact upstream anchor: '+old[:100])
    return s.replace(old,new,1)

def patch_portal(s):
    old = '        let key = load_or_create_key().map_err(err)?;'
    s = replace(s, old, '        let key = load_key().ok_or_else(|| err("Existing signing key is required; no new certificate will be requested"))?;')
    start = s.index('        let csr = build_csr(&key).map_err(err)?;')
    end = s.index('\n    pub async fn app_ids', start)
    s = s[:start] + '        Err(err("Existing certificate unavailable; no certificate issued or revoked"))\n    }\n' + s[end:]
    old = '    pub async fn call(&self, endpoint: &str, team: Option<&str>, mut body: Dictionary) -> Result<Dictionary, PortalError> {'
    new = old + '\n        if !matches!(endpoint, "listTeams" | "listDevices" | "listAllDevelopmentCerts" | "listAppIds" | "downloadTeamProvisioningProfile") { return Err(err("ClearRecovery: developer account mutation disabled")); }'
    return replace(s, old, new)

def main():
    root=pathlib.Path(sys.argv[1]).resolve()
    def git(*args): return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()
    if git('rev-parse','HEAD')!=PIN or git('status','--porcelain'):
        raise SystemExit('Requires exact clean pinned upstream source')
    p=root/'src/install.rs'; q=root/'src/main.rs'; portal=root/'src/apple/portal.rs'; dest=root/'src/bridge_entitlements.rs'
    assert not dest.exists()
    install=patch_install(p.read_text()); main=replace(q.read_text(),'mod apple;','mod apple;\nmod bridge_entitlements;')
    portal_text=patch_portal(portal.read_text())
    p.write_text(install); q.write_text(main); portal.write_text(portal_text); shutil.copy2(HERE/'bridge_entitlements.rs',dest)
    print('Prepared narrow recovery signer source. Not built or signed.')
if __name__=='__main__': main()
