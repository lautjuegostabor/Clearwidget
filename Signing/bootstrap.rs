//! Explicit foreground-only bootstrap for the original ClearWidget IPA.
//! No revocations, no removal, no unrelated apps, no password login.
use super::*;
use crate::sign::{bundle::{self, Ipa, Kind, Plan, Signing}, codesign::Identity};
use rsa::pkcs8::EncodePrivateKey;
use sha2::{Digest,Sha256};
use std::{collections::{HashMap,HashSet},io::{Cursor,Read}};

const APP: &str = "com.clearwidget.app";
const WIDGET: &str = "com.clearwidget.app.widget";
const LIMIT: usize = 16*1024*1024;

#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct BootstrapInput { current_team: String, version: String, build: String, #[serde(default)] update: Option<Input> }

fn valid_team(s:&str)->bool {s.len()==10 && s.bytes().all(|b|b.is_ascii_uppercase()||b.is_ascii_digit())}
fn target_ids(team:&str)->Result<(String,String),String>{
    if !valid_team(team){return Err("bootstrap_team_invalid".into());}
    let host=format!("{APP}.{team}");
    Ok((host.clone(),format!("{host}.widget")))
}

fn update_identity(input:&Input)->Result<(String,String,String,String),String>{
    if input.bundles.len()!=2{return Err("expected_app_and_widget".into());}
    let host=&input.bundles[0];let widget=&input.bundles[1];
    let valid=host.bundleID==APP||host.bundleID.strip_prefix("com.clearwidget.app.")
        .is_some_and(|s|!s.is_empty()&&s.len()<=40&&s.bytes().all(|b|b.is_ascii_alphanumeric()));
    if !valid||widget.bundleID!=format!("{}.widget",host.bundleID){return Err("profile_identity_mismatch".into());}
    let a=profile(&STANDARD.decode(&host.profile).map_err(|_|"profile_invalid")?)?;
    let w=profile(&STANDARD.decode(&widget.profile).map_err(|_|"profile_invalid")?)?;
    let team_id=team(&a).ok_or("profile_invalid")?;
    if !valid_team(team_id)||team(&w)!=Some(team_id){return Err("profile_identity_mismatch".into());}
    let (prefix,aid)=app_id(&a).and_then(|x|x.split_once('.')).ok_or("profile_invalid")?;
    let (wp,wid)=app_id(&w).and_then(|x|x.split_once('.')).ok_or("profile_invalid")?;
    if prefix!=wp||aid!=host.bundleID||wid!=widget.bundleID{return Err("profile_identity_mismatch".into());}
    Ok((team_id.into(),host.bundleID.clone(),widget.bundleID.clone(),prefix.into()))
}
fn newer_build(new:&str,old:&str)->bool{
    match (new.parse::<u64>(),old.parse::<u64>()){(Ok(n),Ok(o))=>n>o,_=>false}
}
pub(crate) fn recovery_team(bytes:&[u8])->Result<String,String>{
    if bytes.len()>3_000_000{return Err("input_invalid".into());}
    let input:Input=serde_json::from_slice(bytes).map_err(|_|"input_invalid")?;
    Ok(update_identity(&input)?.0)
}
fn inspect_archive(bytes:&[u8])->Result<(),String>{
    if bytes.is_empty()||bytes.len()>LIMIT{return Err("bootstrap_ipa_size".into());}
    let mut archive=zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_|"bootstrap_ipa_invalid")?;
    if archive.len()>512{return Err("bootstrap_ipa_invalid".into());}
    let mut seen=HashSet::new();
    let mut expanded=0u64;
    for i in 0..archive.len(){
        let f=archive.by_index_raw(i).map_err(|_|"bootstrap_ipa_invalid")?;
        let name=f.name();
        if !seen.insert(name.to_owned()) || name.contains('\\') || name.split('/').any(|s|s==".."||s==".") ||
           !(name=="Payload/"||name.starts_with("Payload/ClearWidget.app/")) ||
           f.unix_mode().is_some_and(|m|m&0o170000==0o120000) {
            return Err("bootstrap_ipa_invalid".into());
        }
        expanded=expanded.checked_add(f.size()).ok_or("bootstrap_ipa_size")?;
        if expanded>96*1024*1024{return Err("bootstrap_ipa_size".into());}
    }
    Ok(())
}

fn profile_for_new(raw:&[u8], team_id:&str, id:&str, udid:&str, leaf:&[u8], now:u64)->Result<(Dictionary,u64),String>{
    let p=profile(raw)?;
    if team(&p)!=Some(team_id) || !app_id(&p).is_some_and(|v|v.split_once('.').is_some_and(|(_,rest)|rest==id)){
        return Err("profile_identity_mismatch".into());
    }
    if !device_allowed(&p,udid){return Err("device_mismatch".into());}
    if !certs(&p).contains(&leaf){return Err("certificate_changed".into());}
    let expires=expiry(&p).ok_or("profile_invalid")?;
    if expires<=now+3600{return Err("profile_not_extended".into());}
    let mut ent=p.get("Entitlements").and_then(Value::as_dictionary).cloned().ok_or("profile_invalid")?;
    if ent.get("com.apple.developer.team-identifier").and_then(Value::as_string)!=Some(team_id){
        return Err("profile_identity_mismatch".into());
    }
    // Default group first; add only the narrow data bridge authorized by the profile.
    let app=app_id(&p).ok_or("profile_invalid")?;
    let prefix=app.split_once('.').ok_or("profile_invalid")?.0;
    let wild=format!("{prefix}.*");
    let permitted=ent.get("keychain-access-groups").and_then(Value::as_array).ok_or("bootstrap_keychain_not_authorized")?;
    let shared = format!("{prefix}.com.clearwidget.bridge");
    let permits = |wanted: &str| permitted.iter().filter_map(Value::as_string)
        .any(|g|g==wanted||g==wild.as_str());
    if !permits(app)||!permits(&shared) {
        return Err("bootstrap_keychain_not_authorized".into());
    }
    let mut groups=vec![Value::String(app.to_owned()),Value::String(shared.clone())];
    for g in permitted.iter().filter_map(Value::as_string){
        if !g.contains('*') && g!=app && g!=shared.as_str() {groups.push(Value::String(g.to_owned()));}
    }
    ent.insert("keychain-access-groups".into(),Value::Array(groups));
    Ok((ent,expires))
}

fn chain_for(leaf:&[u8])->Result<Vec<Vec<u8>>,String>{
    const INTERMEDIATES:[&[u8];5]=[
        include_bytes!("../assets/certs/AppleWWDRCAG3.cer"),include_bytes!("../assets/certs/AppleWWDRCAG4.cer"),
        include_bytes!("../assets/certs/AppleWWDRCAG5.cer"),include_bytes!("../assets/certs/AppleWWDRCAG6.cer"),
        include_bytes!("../assets/certs/AppleWWDRCAG2.cer")];
    const ROOTS:[&[u8];2]=[include_bytes!("../assets/certs/AppleRootCA.cer"),include_bytes!("../assets/certs/AppleRootCAG3.cer")];
    let info=der::cert_info(leaf).map_err(|_|"bootstrap_certificate_invalid")?;
    for ca in INTERMEDIATES {
        if let Ok(c)=der::cert_info(ca){
            if c.subject==info.issuer {
                if let Some(root)=ROOTS.iter().find(|r|der::cert_info(r).is_ok_and(|i|i.subject==c.issuer)){
                    return Ok(vec![ca.to_vec(),root.to_vec()]);
                }
            }
        }
    }
    Err("bootstrap_certificate_chain_unknown".into())
}

const SHORTCUT_ROOT: &str = "Payload/ClearWidget.app/Metadata.appintents/root.ssu.yaml";
fn read_shortcut_root(bytes:&[u8])->Result<Vec<u8>,String>{
    let mut z=zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_|"bootstrap_ipa_invalid")?;
    let f=z.by_name(SHORTCUT_ROOT).map_err(|_|"bootstrap_shortcut_metadata_missing")?;
    if f.size()>64*1024{return Err("bootstrap_shortcut_metadata_invalid".into());}
    let mut raw=Vec::new();f.take(64*1024+1).read_to_end(&mut raw).map_err(|_|"bootstrap_shortcut_metadata_invalid")?;
    if raw.len()>64*1024{return Err("bootstrap_shortcut_metadata_invalid".into());}
    Ok(raw)
}
fn rewrite_shortcut_root(raw:&[u8],id:&str)->Result<Vec<u8>,String>{
    let s=std::str::from_utf8(raw).map_err(|_|"bootstrap_shortcut_metadata_invalid")?;
    let old="    bundleIdentifier: com.clearwidget.app";
    if s.lines().filter(|l|*l==old).count()!=1 || !(id==APP || id.starts_with("com.clearwidget.app.")) ||
       !id.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'.') {
        return Err("bootstrap_shortcut_metadata_invalid".into());
    }
    Ok(s.replacen(old,&format!("    bundleIdentifier: {id}"),1).into_bytes())
}
async fn install(input:BootstrapInput, bytes:Vec<u8>)->Result<serde_json::Value,String>{
    if !valid_team(&input.current_team){return Err("bootstrap_current_team_invalid".into());}
    inspect_archive(&bytes)?;
    let shortcut_root=read_shortcut_root(&bytes)?;
    let mut ipa=tokio::task::block_in_place(||Ipa::read(bytes,&|_,_|{})).map_err(|_|"bootstrap_ipa_invalid")?;
    let bundles=ipa.bundles().map_err(|_|"bootstrap_ipa_invalid")?;
    if bundles.len()!=2{return Err("expected_app_and_widget".into());}
    let host=bundles.iter().find(|b|b.kind==Kind::App&&b.id==APP&&b.dir=="Payload/ClearWidget.app").ok_or("bootstrap_original_ipa_required")?;
    let widget=bundles.iter().find(|b|b.kind==Kind::Extension&&b.id==WIDGET&&b.dir=="Payload/ClearWidget.app/PlugIns/ClearWidgetExtension.appex").ok_or("bootstrap_original_ipa_required")?;
    let candidate_build=host.info.get("CFBundleVersion").and_then(Value::as_string).ok_or("bootstrap_ipa_invalid")?;
    if host.version!=widget.version||widget.info.get("CFBundleVersion").and_then(Value::as_string)!=Some(candidate_build){
        return Err("bootstrap_ipa_invalid".into());
    }
    let upgrading=input.update.is_some();
    if !upgrading && (host.version!=input.version||candidate_build!=input.build){
        return Err("bootstrap_same_version_required".into());
    }
    if widget.info.get("NSExtension").and_then(Value::as_dictionary).and_then(|e|e.get("NSExtensionPointIdentifier")).and_then(Value::as_string)!=Some("com.apple.widgetkit-extension"){
        return Err("bootstrap_original_ipa_required".into());
    }
    if bundles.iter().any(|b|ipa.files.contains_key(&format!("{}/embedded.mobileprovision",b.dir))){
        return Err("bootstrap_original_ipa_required".into());
    }
    let record=std::fs::read(state::path("pairing.plist")).ok().and_then(|x|PairingRecord::from_bytes(&x)).ok_or("pairing_missing")?;
    let session=Session::open(&record).await.map_err(|_|"vpn_or_pairing_unavailable")?;
    if session.udid!=record.peer.udid{return Err("device_mismatch".into());}
    let (gs,account)=gsa::resume().await.map_err(|_|"session_unavailable")?;
    let portal=Portal{gs:&gs,account:&account};
    let teams=portal.teams().await.map_err(|e|portal_failure("listTeams",e))?;
    let (team_id,host_id,widget_id,old_prefix)=if let Some(old)=&input.update{
        let (team_id,host_id,widget_id,prefix)=update_identity(old)?;
        if team_id!=input.current_team||!teams.iter().any(|t|t.id==team_id){return Err("portal:team_not_authorized".into());}
        for b in &old.bundles{
            let p=profile(&STANDARD.decode(&b.profile).map_err(|_|"profile_invalid")?)?;
            if !device_allowed(&p,&session.udid){return Err("device_mismatch".into());}
        }
        (team_id,host_id,widget_id,Some(prefix))
    }else{
        if teams.len()!=1{return Err("bootstrap_select_single_team".into());}
        let team_id=teams[0].id.clone();
        if team_id==input.current_team{return Err("bootstrap_same_team_use_renew".into());}
        let (host_id,widget_id)=target_ids(&team_id)?;
        (team_id,host_id,widget_id,None)
    };
    let shortcut_root=rewrite_shortcut_root(&shortcut_root,&host_id)?;
    let existing=services::installed_apps(&session).await.map_err(|_|"bootstrap_list_apps_failed")?;
    let installed=existing.iter().find(|a|a.get("CFBundleIdentifier").and_then(Value::as_string)==Some(host_id.as_str()));
    if upgrading{
        let old_build=installed.and_then(|a|a.get("CFBundleVersion")).and_then(Value::as_string).ok_or("update_installed_app_missing")?;
        if !newer_build(candidate_build,old_build){return Err("update_newer_build_required".into());}
    }else if installed.is_some(){return Err("bootstrap_already_installed".into());}
    let ids=portal.app_ids(&team_id).await.map_err(|e|portal_failure("listAppIds",e))?;
    if upgrading && [&host_id,&widget_id].iter().any(|id|!ids.iter().any(|a|a.identifier.as_str()==id.as_str())){
        return Err("app_id_missing".into());
    }
    // The foreground confirmation authorizes at most one new cert, this phone
    // and these two identifiers. Never replace or delete an unrelated app.
    let cert=portal.certificate(&team_id).await.map_err(|e|portal_failure("certificate",e))?;
    let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let cert_info=der::cert_info(&cert.der).map_err(|_|"bootstrap_certificate_invalid")?;
    if cert_info.not_before>now||cert_info.not_after<=now+3600{return Err("bootstrap_certificate_invalid".into());}
    let chain=chain_for(&cert.der)?;
    let common_name=der::name_value(cert_info.subject,"2.5.4.3").unwrap_or_default();
    let cert_end=cert_info.not_after;
    if !upgrading{portal.ensure_device(&team_id,&session.udid,"ClearWidget iPhone").await.map_err(|e|portal_failure("ensureDevice",e))?;}
    let mut plan_bundles=HashMap::new();
    let mut info_edits=HashMap::new();
    let mut fresh=Vec::new();
    let fingerprint=hex::encode(Sha256::digest(&cert.der));
    for (b,id,name) in [(host,&host_id,"ClearWidget"),(widget,&widget_id,"ClearWidget Widget")]{
        let a=match ids.iter().find(|a|a.identifier==*id){
            Some(a)=>a.clone(),
            None if upgrading=>return Err("app_id_missing".into()),
            None=>portal.add_app_id(&team_id,id,name).await.map_err(|e|portal_failure("addAppId",e))?,
        };
        let raw=portal.profile(&team_id,&a).await.map_err(|e|portal_failure("downloadTeamProvisioningProfile",e))?;
        let (ent,e)=profile_for_new(&raw,&team_id,id,&session.udid,&cert.der,now)?;
        if let Some(prefix)=&old_prefix{
            if ent.get("application-identifier").and_then(Value::as_string)!=Some(format!("{prefix}.{id}").as_str()){
                return Err("profile_identity_mismatch".into());
            }
        }
        let mut info=Dictionary::new();
        info.insert("ClearSignCertificateSHA256".into(),Value::String(fingerprint.clone()));
        info.insert("ClearSignCertificateExpires".into(),Value::Integer(cert_end.into()));
        info_edits.insert(b.dir.clone(),info);
        plan_bundles.insert(b.dir.clone(),Signing{new_id:id.to_owned(),profile:raw.clone(),entitlements:ent});
        fresh.push((raw,e.min(cert_end)));
    }
    let plan=Plan{identity:Identity{leaf:cert.der,chain,key:cert.key,team:team_id,common_name},
        bundles:plan_bundles,info_edits,add_files:vec![(SHORTCUT_ROOT.into(),shortcut_root)]};
    let signed=tokio::task::block_in_place(||{
        bundle::sign(&mut ipa,&plan,&mut |_,_|{})?;
        bundle::verify(&ipa)?;
        ipa.write()
    }).map_err(|_|"bootstrap_sign_failed")?;
    // Install exact authorized identifiers. On update, iOS may terminate the old process.
    services::install(&session,&signed,&mut |_,_|{}).await.map_err(|_|"bootstrap_install_unconfirmed")?;
    let found=services::installed_apps(&session).await.map_err(|_|"bootstrap_install_unconfirmed")?
        .iter().any(|a|a.get("CFBundleIdentifier").and_then(Value::as_string)==Some(host_id.as_str()) &&
            a.get("CFBundleVersion").and_then(Value::as_string)==Some(candidate_build));
    if !found{return Err("bootstrap_install_unconfirmed".into());}
    let expected:Vec<(&[u8],u64)>=fresh.iter().map(|(raw,e)|(raw.as_slice(),*e)).collect();
    // Installation and profile evidence remain distinct. Never say renewal worked.
    let verified=readback(&session,&expected).await;
    Ok(match verified{
        Ok(e)=>json!({"ok":true,"installedID":host_id,"expiry":e,"profilesVerified":true}),
        Err(code)=>json!({"ok":true,"installedID":host_id,"profilesVerified":false,"code":code}),
    })
}

fn run(dir:&str,request:&[u8])->Result<serde_json::Value,String>{
    if request.len()>3_010_000{return Err("input_invalid".into());}
    let input=serde_json::from_slice(request).map_err(|_|"input_invalid")?;
    run_input(dir,input)
}
pub(crate) fn update_from_recovery(dir:&str,request:&[u8])->Result<serde_json::Value,String>{
    let team=recovery_team(request)?;
    let old=serde_json::from_slice(request).map_err(|_|"input_invalid")?;
    run_input(dir,BootstrapInput{current_team:team,version:String::new(),build:String::new(),update:Some(old)})
}
fn run_input(dir:&str,input:BootstrapInput)->Result<serde_json::Value,String>{
    if !Path::new(dir).is_absolute(){return Err("input_invalid".into());}
    let _guard=LOCK.try_lock().map_err(|_|"engine_busy")?;
    let _preserve=RenewalGuard::start();
    std::env::set_var("BARISTORE_HOME",dir);
    let route=std::fs::read_to_string(state::path("anisette-server")).map_err(|_|"session_unavailable")?;
    if !route.lines().next().is_some_and(|s|s.starts_with("https://")){return Err("session_route_invalid".into());}
    if !state::path("signing-key.der").is_file(){return Err("bootstrap_key_missing".into());}
    let file=state::path("bootstrap.ipa");
    if std::fs::metadata(&file).map_err(|_|"bootstrap_ipa_invalid")?.len()>LIMIT as u64{return Err("bootstrap_ipa_size".into());}
    let bytes=std::fs::read(file).map_err(|_|"bootstrap_ipa_invalid")?;
    let rt=tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|_|"engine_unavailable")?;
    let result=rt.block_on(async{tokio::time::timeout(Duration::from_secs(180),install(input,bytes)).await.map_err(|_|"bootstrap_timeout")?});
    rt.shutdown_timeout(Duration::from_secs(2));
    result
}

#[no_mangle]
pub extern "C" fn clearsign_prepare_key()->*mut c_char{
    let result=std::panic::catch_unwind(||{
        let key=rsa::RsaPrivateKey::new(&mut rand::rngs::OsRng,2048).ok()?;
        let pkcs=key.to_pkcs8_der().ok()?;
        CString::new(STANDARD.encode(pkcs.as_bytes())).ok()
    });
    result.ok().flatten().map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn clearsign_bootstrap(dir:*const c_char,data:*const u8,len:usize)->*mut c_char{
    let result=std::panic::catch_unwind(||{
        if dir.is_null()||data.is_null()||len>3_010_000{return Err("input_invalid".into());}
        run(CStr::from_ptr(dir).to_str().map_err(|_|"input_invalid")?,std::slice::from_raw_parts(data,len))
    }).unwrap_or(Err("engine_unavailable".into()));
    let v=result.unwrap_or_else(|code|json!({"ok":false,"code":code}));
    CString::new(v.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}
#[cfg(test)]
mod tests{
    use super::*;
    #[test] fn exact_identifiers(){
        assert_eq!(target_ids("A123456789").unwrap(),("com.clearwidget.app.A123456789".into(),"com.clearwidget.app.A123456789.widget".into()));
        assert!(target_ids("../bad").is_err());
    }
    #[test] fn update_build_monotonic(){
        assert!(newer_build("14","13"));assert!(!newer_build("13","13"));assert!(!newer_build("12","13"));assert!(!newer_build("x","13"));
    }
    #[test] fn reject_non_ipa(){assert!(inspect_archive(b"not an ipa").is_err());}
    #[test] fn shortcut_root_rewrites_only_identifier(){
        let original=b"nlu:\n    bundleIdentifier: com.clearwidget.app\n    intents:\n";
        assert_eq!(rewrite_shortcut_root(original,"com.clearwidget.app.A123456789").unwrap(),b"nlu:\n    bundleIdentifier: com.clearwidget.app.A123456789\n    intents:\n");
        assert!(rewrite_shortcut_root(b"unrelated", "com.clearwidget.app.A123456789").is_err());
        assert!(rewrite_shortcut_root(original,"com.other.app").is_err());
    }
}
