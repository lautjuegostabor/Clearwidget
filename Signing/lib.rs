//! Native iOS static library adapter to the pinned MIT BariStore modules.
//! Renewal only: no password login, certificate issuance/revocation, App ID
//! creation, install of binaries, or modification of unrelated applications.
#[macro_export]
macro_rules! logf { ($($arg:tt)*) => {{}}; }
mod apple;
mod device;
mod pairing;
mod der;
mod hash;
mod siphash;
mod srp;
mod state;
mod setup;

use base64::{engine::general_purpose::STANDARD, Engine};
use plist::{Dictionary,Value};
use serde::Deserialize;
use serde_json::json;
use std::{ffi::{CStr,CString,c_char},path::Path, sync::Mutex,time::{Duration,SystemTime,UNIX_EPOCH}};
use apple::{gsa,portal::Portal};
use device::{session::Session,services};
use pairing::record::PairingRecord;
static LOCK: Mutex<()> = Mutex::new(());

#[derive(Deserialize)]
struct Input { bundles: Vec<BundleInput>, previousExpiry: u64 }
#[derive(Deserialize)]
struct BundleInput { bundleID: String, profile: String }

fn profile(data: &[u8]) -> Result<Dictionary,&'static str> {
    if data.len() > 1_000_000 { return Err("profile_invalid"); }
    let start = data.windows(6).position(|x| x == b"<plist").ok_or("profile_invalid")?;
    let end = data[start..].windows(8).position(|x| x == b"</plist>").ok_or("profile_invalid")? + start + 8;
    plist::from_bytes::<Value>(&data[start..end]).ok().and_then(Value::into_dictionary).ok_or("profile_invalid")
}
fn expiry(d: &Dictionary) -> Option<u64> {
    match d.get("ExpirationDate")? {
        Value::Date(x) => SystemTime::from(*x).duration_since(UNIX_EPOCH).ok().map(|x|x.as_secs()),
        _ => None,
    }
}
fn team(d: &Dictionary) -> Option<&str> {
    d.get("TeamIdentifier")?.as_array()?.first()?.as_string()
}
fn app_id(d: &Dictionary) -> Option<&str> {
    d.get("Entitlements")?.as_dictionary()?.get("application-identifier")?.as_string()
}
fn certs(d: &Dictionary) -> Vec<&[u8]> {
    d.get("DeveloperCertificates").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_data).collect()
}
fn device_allowed(d: &Dictionary,udid: &str) -> bool {
    let norm = |s: &str| s.replace('-', "").to_lowercase();
    !udid.is_empty() && d.get("ProvisionedDevices").and_then(Value::as_array).into_iter().flatten()
        .filter_map(Value::as_string).any(|x|norm(x)==norm(udid))
}
fn verify(old: &Dictionary,new: &Dictionary,udid: &str,previous: u64,now: u64) -> Result<u64,&'static str> {
    if team(old).is_none() || team(old)!=team(new) || app_id(old).is_none() || app_id(old)!=app_id(new) {
        return Err("profile_identity_mismatch");
    }
    let old_certs=certs(old);let new_certs=certs(new);
    // Conservative: retain ALL certificates from the installed profile, not merely
    // an arbitrary common certificate. Never create or revoke one.
    if old_certs.is_empty() || !old_certs.iter().all(|c|new_certs.contains(c)) {return Err("certificate_changed");}
    if old.get("Entitlements")!=new.get("Entitlements") {return Err("entitlements_changed");}
    if !device_allowed(old,udid) || !device_allowed(new,udid) {return Err("device_mismatch");}
    let e=expiry(new).ok_or("profile_invalid")?;
    let old_e=expiry(old).ok_or("profile_invalid")?;
    if e <= now+3600 || e <= old_e.max(previous)+60 {return Err("profile_not_extended");}
    Ok(e)
}
async fn renew(input: Input) -> Result<u64,&'static str> {
    if input.bundles.len()!=2 {return Err("expected_app_and_widget");}
    let mut old=Vec::new();
    for b in &input.bundles {
        let p=profile(&STANDARD.decode(&b.profile).map_err(|_|"profile_invalid")?)?;
        let id=app_id(&p).ok_or("profile_invalid")?;
        if !id.split_once('.').map(|(_,rest)|rest==b.bundleID).unwrap_or(false) {return Err("profile_identity_mismatch");}
        old.push(p);
    }
    if input.bundles[0].bundleID==input.bundles[1].bundleID {return Err("profile_identity_mismatch");}
    let team_id=team(&old[0]).ok_or("profile_invalid")?.to_string();
    if team(&old[1])!=Some(team_id.as_str()) {return Err("profile_identity_mismatch");}
    let record=std::fs::read(state::path("pairing.plist")).ok().and_then(|x|PairingRecord::from_bytes(&x)).ok_or("pairing_missing")?;
    let session=Session::open(&record).await.map_err(|_|"vpn_or_pairing_unavailable")?;
    if !old.iter().all(|p|device_allowed(p,&session.udid)) {return Err("device_mismatch");}
    // gsa::resume uses the imported session; it never initiates a password login.
    let (gs,account)=gsa::resume().await.map_err(|_|"session_unavailable")?;
    let portal=Portal{gs:&gs,account:&account};
    let ids=portal.app_ids(&team_id).await.map_err(|_|"portal_unavailable")?;
    let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let mut fresh=Vec::new();
    // Preflight both profiles completely before installing either.
    for (b,p) in input.bundles.iter().zip(old.iter()) {
        let app=ids.iter().find(|a|a.identifier==b.bundleID).ok_or("app_id_missing")?;
        let raw=portal.profile(&team_id,app).await.map_err(|_|"profile_request_failed")?;
        let candidate=profile(&raw)?;
        let e=verify(p,&candidate,&session.udid,input.previousExpiry,now)?;
        fresh.push((raw,e));
    }
    let mut expires=u64::MAX;
    for (raw,e) in fresh {
        services::install_profile(&session,&raw).await.map_err(|_|"device_install_failed")?;
        expires=expires.min(e);
    }
    Ok(expires)
}
fn execute(dir:&str,bytes:&[u8])->Result<u64,&'static str>{
    if bytes.len()>3_000_000 || !Path::new(dir).is_absolute(){return Err("input_invalid");}
    let _guard=LOCK.try_lock().map_err(|_|"engine_busy")?;
    std::env::set_var("BARISTORE_HOME",dir);
    let route=std::fs::read_to_string(state::path("anisette-server")).map_err(|_|"session_unavailable")?;
    if !route.lines().next().map(|x|x.starts_with("https://")).unwrap_or(false){return Err("session_route_invalid");}
    let input:Input=serde_json::from_slice(bytes).map_err(|_|"input_invalid")?;
    let rt=tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|_|"engine_unavailable")?;
    let r=rt.block_on(async {tokio::time::timeout(Duration::from_secs(120),renew(input)).await.map_err(|_|"timeout")?});
    rt.shutdown_timeout(Duration::from_secs(2));
    r
}
// Same conservative profile-only operation for the independent recovery binary.
pub fn recover_profiles(dir:&str,bytes:&[u8])->Result<u64,&'static str>{execute(dir,bytes)}
#[no_mangle]
pub unsafe extern "C" fn clearsign_refresh(dir:*const c_char,data:*const u8,len:usize)->*mut c_char{
    let result=std::panic::catch_unwind(||{
        if dir.is_null()||data.is_null()||len>3_000_000{return Err("input_invalid");}
        let path=CStr::from_ptr(dir).to_str().map_err(|_|"input_invalid")?;
        execute(path,std::slice::from_raw_parts(data,len))
    }).unwrap_or(Err("engine_unavailable"));
    let response=match result{Ok(e)=>json!({"ok":true,"expiry":e}),Err(code)=>json!({"ok":false,"code":code})};
    CString::new(response.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn clearsign_free(value:*mut c_char){if !value.is_null(){drop(CString::from_raw(value));}}
