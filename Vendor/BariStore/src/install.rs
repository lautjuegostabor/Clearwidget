//! From an IPA to an app on this iPhone: App IDs (one per app/extension),
//! app groups for the apps that need one, optional Increased Memory Limit,
//! profiles, signing, the loopback install, the pairing file written into
//! the apps that refresh themselves, and our record of what is installed.

use plist::{Dictionary, Value};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::pin::Pin;

use crate::apple::gsa::{Account, GrandSlam};
use crate::apple::portal::{self, AppId, DevCert, Portal, Team, FREE_APP_IDS};
use crate::device::{services, session::Session};
use crate::sign::bundle::{self, Ipa, Kind, Plan, Signing};
use crate::sign::codesign::Identity;
use crate::{der, logf, pairing, state};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Options {
    /// Leave app extensions out (saves App IDs: a free team gets 10 a week).
    pub remove_extensions: bool,
    /// Ask Apple for Increased Memory Limit on the main App ID.
    pub increased_memory: bool,
    /// A picture of the user's as the app's icon (a file in app-icons/,
    /// see `icons::custom_icon`); "" keeps the app's own.
    #[serde(default)]
    pub icon: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Installed {
    pub bundle_id: String,       // as installed (with .TEAMID)
    pub original_id: String,
    pub name: String,
    pub version: String,
    pub source_url: String,      // where the IPA came from (for refresh)
    pub ipa_path: String,        // cached original IPA
    pub team: String,
    pub expires: u64,            // unix seconds (profile expiry)
    pub installed_at: u64,
    pub options: Options,
    pub icon_url: String,
    /// Identifier each app/extension bundle was installed under (bundle dir
    /// inside the IPA -> identifier), so a refresh keeps them.
    #[serde(default)]
    pub ids: BTreeMap<String, String>,
    /// Increased Memory Limit as found in the installed profile.
    #[serde(default)]
    pub increased_memory: bool,
    /// What the app does with BariStore's files (see `kind_of`), from the
    /// IPA, never from the identifier it was installed under: an App ID can
    /// be reused for any app.
    #[serde(default)]
    pub kind: String,
    /// Serial of the certificate the app was signed with: while BariStore
    /// still signs with it, a refresh only needs new profiles.
    #[serde(default)]
    pub cert_serial: String,
    /// Where in the catalog it came from (app key, the version's source and
    /// channel), to offer its updates.
    #[serde(default)]
    pub store_key: String,
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub channel: String,
    /// The picture of the user's the app was signed with as its icon ("":
    /// its own); `options.icon` is the one its next signing takes.
    #[serde(default)]
    pub custom_icon: String,
}

impl Installed {
    /// The icon My Apps shows: the one the app on the iPhone has.
    pub fn shown_icon(&self) -> String {
        if self.custom_icon.is_empty() { self.icon_url.clone() } else { crate::icons::custom_icon_url(&self.custom_icon) }
    }

    /// The options the app is signed with again (an update, a full
    /// refresh): its own, and Increased Memory Limit kept once it has it.
    pub fn signing_options(&self) -> Options {
        Options { increased_memory: self.options.increased_memory || self.increased_memory, ..self.options.clone() }
    }
}

/// An identifier typed for a custom App ID: letters, digits, '-' and '.',
/// with the team appended as BariStore's own are (an App ID belongs to one
/// team everywhere).
pub fn custom_identifier(typed: &str, team: &str) -> Result<String, String> {
    let id = typed.trim();
    let ok = id.contains('.') && !id.starts_with('.') && !id.ends_with('.') && !id.contains("..")
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    if !ok {
        return Err("A custom App ID looks like com.example.app: letters, digits, '-' and dots.".into());
    }
    let full = new_identifier(id, team);
    if full.len() > 155 {
        return Err("That App ID is too long.".into());
    }
    Ok(full)
}

/// SideStore: reads the pairing file and ALTCertificate.p12.
pub const SIDESTORE: &str = "sidestore";
/// AltStore Classic: the same, its own file names.
pub const ALTSTORE: &str = "altstore";
/// LiveContainer alone: takes the certificate through its URL scheme.
pub const LIVECONTAINER: &str = "livecontainer";
/// LiveContainer with SideStore built in: SideStore's files inside it.
pub const LIVECONTAINER_SIDESTORE: &str = "livecontainer+sidestore";
/// StikDebug: reads the pairing file.
pub const STIKDEBUG: &str = "stikdebug";

/// What an app is, from its original identifier and whether SideStore is
/// built in. Beta builds of the stores read none of our files.
fn kind_for(original_id: &str, sidestore_inside: bool) -> &'static str {
    if original_id.contains(".Beta") {
        ""
    } else if original_id.starts_with("com.SideStore.SideStore") {
        SIDESTORE
    } else if original_id.starts_with("com.rileytestut.AltStore") {
        ALTSTORE
    } else if original_id.starts_with("com.kdt.livecontainer") {
        if sidestore_inside { LIVECONTAINER_SIDESTORE } else { LIVECONTAINER }
    } else if original_id.starts_with("com.stik.") {
        STIKDEBUG
    } else {
        ""
    }
}

fn has_sidestore_framework(ipa: &Ipa) -> bool {
    ipa.files.keys().any(|p| p.contains("/Frameworks/SideStoreApp.framework/") || p.contains("/Frameworks/SideStore.framework/"))
}

/// The kind of an entry recorded before kinds were (0.10.0-alpha.6), from
/// its original identifier and where it came from.
fn guess_kind(e: &Installed) -> String {
    kind_for(&e.original_id, e.name.contains("SideStore") || e.source_url.contains("SideStore")).to_string()
}

/// Whether apps of `kind` read the pairing file.
pub fn reads_pairing_file(kind: &str) -> bool {
    [SIDESTORE, ALTSTORE, LIVECONTAINER_SIDESTORE, STIKDEBUG].contains(&kind)
}

pub fn registry_path() -> std::path::PathBuf {
    state::path("installed.json")
}

pub fn installed() -> Vec<Installed> {
    let mut list: Vec<Installed> = std::fs::read(registry_path()).ok()
        .and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    for e in list.iter_mut().filter(|e| e.kind.is_empty()) {
        e.kind = guess_kind(e);
    }
    list
}

pub fn save_installed(list: &[Installed]) {
    if let Ok(b) = serde_json::to_vec_pretty(list) {
        let _ = state::write_private(&registry_path(), &b);
    }
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// Apps whose own code needs an app group (and reads ALTAppGroups), with the
/// group id each looks up (behaviour as documented by nab138/isideload).
fn group_for(original_main: &str, team: &str, ipa: &Ipa) -> Option<String> {
    let base = original_main.trim_end_matches(".Beta");
    if base == "com.kdt.livecontainer" && has_sidestore_framework(ipa) {
        return Some(format!("group.com.SideStore.SideStore.{team}"));
    }
    if base == "com.SideStore.SideStore" || base == "com.rileytestut.AltStore" || base == "com.kdt.livecontainer" {
        return Some(format!("group.{original_main}.{team}"));
    }
    None
}

pub fn new_identifier(original: &str, team: &str) -> String {
    if original.ends_with(&format!(".{team}")) { original.to_string() } else { format!("{original}.{team}") }
}

/// "New App ID": the app's own identifier (`new_identifier`; when its App ID
/// is left from an earlier install, that one is taken again), unless an app
/// on the iPhone is installed under it (another app that reused it, or a
/// copy of this one): then the first of `original`2, 3… that none is, so a
/// new install never takes another app's place.
fn fresh_identifier(original: &str, team: &str, on_device: &[String]) -> String {
    let own = new_identifier(original, team);
    if !on_device.contains(&own) {
        return own;
    }
    let base = own.strip_suffix(&format!(".{team}")).unwrap_or(&own).to_string();
    (2..).map(|n| format!("{base}{n}.{team}")).find(|id| !on_device.contains(id)).unwrap_or(own)
}

/// The identifiers of the apps on the iPhone.
async fn device_ids(session: &Session) -> Result<Vec<String>, String> {
    Ok(services::installed_apps(session).await?.iter()
        .filter_map(|d| d.get("CFBundleIdentifier").and_then(Value::as_string).map(str::to_string)).collect())
}

/// Asks the user to pick one of `options` (title, message, options).
pub type Asker = dyn Fn(String, String, Vec<String>) -> Pin<Box<dyn Future<Output = Option<String>> + Send>> + Send + Sync;

/// App IDs chosen on the install sheet.
#[derive(Clone, Default)]
pub struct Reuse {
    /// The App ID the app takes (an app the iPhone has under it is
    /// replaced). None: a new App ID, see `fresh_identifier`.
    pub pick: Option<String>,
    /// Extensions also take unused App IDs under the app's.
    pub extensions: bool,
}

pub struct Context<'a> {
    pub gs: &'a GrandSlam,
    pub account: &'a Account,
    pub team: &'a Team,
    pub udid: &'a str,
    pub device_name: &'a str,
    pub session: &'a Session,
    pub ask: &'a Asker,
    pub reuse: Reuse,
    /// On a refresh: the app's identifier and its bundles' identifiers.
    pub previous: Option<(&'a str, &'a BTreeMap<String, String>)>,
}

pub struct Prepared {
    pub ipa: Vec<u8>,
    pub main_id: String,
    pub expires: u64,
    pub version: String,
    pub ids: BTreeMap<String, String>,
    /// Whether the app's profile carries Increased Memory Limit.
    pub increased_memory: bool,
    pub kind: &'static str,
    pub cert_serial: String,
}

const INCREASED_MEMORY: &str = "com.apple.developer.kernel.increased-memory-limit";

fn date(unix: u64) -> String {
    let (y, m, d) = der::civil_from_days((unix / 86400) as i64);
    format!("{y}-{m:02}-{d:02}")
}

/// The identifier each app/extension bundle gets: the previous install's,
/// else the original with the team appended; extensions stay under the app.
fn identifiers(apps: &[&bundle::Bundle], main: &bundle::Bundle, main_new: &str,
               previous: Option<&BTreeMap<String, String>>) -> BTreeMap<String, String> {
    apps.iter().map(|b| {
        let id = if b.dir == main.dir {
            main_new.to_string()
        } else if let Some(kept) = previous.and_then(|p| p.get(&b.dir)).filter(|id| id.starts_with(&format!("{main_new}."))) {
            kept.clone()
        } else if let Some(rest) = b.id.strip_prefix(&format!("{}.", main.id)) {
            format!("{main_new}.{rest}")
        } else {
            format!("{main_new}.{}", b.id.rsplit('.').next().unwrap_or("extension"))
        };
        (b.dir.clone(), id)
    }).collect()
}

/// Makes the App IDs fit a free team's 10: when more are needed than are
/// left, App IDs of apps no longer on the iPhone are reused (asking first
/// unless the settings say so). The app takes one whole; its extensions take
/// unused App IDs under it when the settings allow, else new ones.
async fn fit_app_ids(ctx: &Context<'_>, apps: &[&bundle::Bundle], main: &bundle::Bundle,
                     ids: &mut BTreeMap<String, String>, existing: &[AppId],
                     status: &(dyn Fn(String) + Send + Sync)) -> Result<(), String> {
    let known = |id: &str| existing.iter().any(|a| a.identifier == id);
    let missing = |ids: &BTreeMap<String, String>| ids.values().filter(|id| !known(id)).count();
    let left = FREE_APP_IDS.saturating_sub(existing.len());
    let wants_extensions = ctx.reuse.extensions && apps.len() > 1;
    if missing(ids) <= left && !wants_extensions {
        return Ok(());
    }
    status("Looking for App IDs to reuse".into());
    let on_device = device_ids(ctx.session).await?;
    let in_use = |id: &str| on_device.iter().any(|d| id == d || id.starts_with(&format!("{d}.")));
    let taken: Vec<String> = ids.values().cloned().collect();
    let mut free: Vec<&AppId> = existing.iter()
        .filter(|a| !in_use(&a.identifier) && !taken.contains(&a.identifier)).collect();
    let next = existing.iter().map(|a| a.expires).filter(|e| *e > 0).min();
    let out_of_ids = |ids: &BTreeMap<String, String>| {
        let when = next.map(|e| format!(" The next one frees up on {}.", date(e))).unwrap_or_default();
        format!("Not enough App IDs: this app needs {}, {left} of {FREE_APP_IDS} are left.{when} \
                 Remove extensions needs fewer.", missing(ids))
    };
    if missing(ids) > left && !known(&ids[&main.dir]) {
        if free.is_empty() {
            return Err(out_of_ids(ids));
        }
        // Ask which App ID of an app that is gone the new one takes.
        let labels: Vec<String> = free.iter().map(|a| format!("{} ({})", a.name, a.identifier)).collect();
        let mut options = labels.clone();
        options.push("Cancel".into());
        let message = format!("This app needs {} new App IDs and {left} of {FREE_APP_IDS} are left. Reuse the App ID \
                               of an app that is no longer on this iPhone:", missing(ids));
        let pick = (ctx.ask)("Not enough App IDs".into(), message, options).await;
        let Some(index) = pick.and_then(|p| labels.iter().position(|l| *l == p)) else {
            return Err("Cancelled".into());
        };
        let chosen = free.remove(index);
        logf!("install: reusing App ID {} for {}", chosen.identifier, main.name);
        *ids = identifiers(apps, main, &chosen.identifier, None);
    }
    if wants_extensions || missing(ids) > left {
        let main_new = ids[&main.dir].clone();
        for b in apps.iter().filter(|b| b.dir != main.dir) {
            if known(&ids[&b.dir]) {
                continue;
            }
            if let Some(pos) = free.iter().position(|a| a.identifier.starts_with(&format!("{main_new}."))) {
                let pick = free.remove(pos);
                logf!("install: reusing App ID {} for {}", pick.identifier, b.name);
                ids.insert(b.dir.clone(), pick.identifier.clone());
            }
        }
    }
    if missing(ids) > left {
        return Err(out_of_ids(ids));
    }
    Ok(())
}

/// The signing certificate. When the Apple ID has no room for a new one and
/// none of its certificates is BariStore's, the user picks one to revoke.
pub async fn certificate(portal: &Portal<'_>, team: &str, ask: &Asker) -> Result<DevCert, String> {
    match portal.certificate(team).await {
        Err(e) if e.code == portal::CERTS_FULL => {
            let certs = portal.certificate_list(team).await.map_err(|e| e.to_string())?;
            let labels: Vec<String> = certs.iter().map(|c| {
                let until = if c.expires > 0 { format!(", until {}", date(c.expires)) } else { String::new() };
                format!("{}{until} ({})", c.name, &c.serial[c.serial.len().saturating_sub(6)..])
            }).collect();
            let mut options = labels.clone();
            options.push("Cancel".into());
            let message = format!("Your Apple ID already has {} development certificates, the most Apple allows. \
                Revoke one so BariStore can make its own? Apps signed with it stop opening until they are \
                installed again.", certs.len());
            let pick = ask("No room for a certificate".into(), message, options).await;
            let Some(index) = pick.and_then(|p| labels.iter().position(|l| *l == p)) else {
                return Err("Cancelled: no certificate was revoked.".into());
            };
            logf!("install: revoking certificate {} ({})", certs[index].serial, certs[index].name);
            portal.revoke(team, &certs[index].serial).await.map_err(|e| e.to_string())?;
            portal.certificate(team).await.map_err(|e| e.to_string())
        }
        other => other.map_err(|e| e.to_string()),
    }
}

/// Prepares App IDs/profiles and signs. The CPU-heavy parts (reading,
/// signing and packing the IPA) run with `block_in_place`, so the page and
/// the tunnel keep their worker.
pub async fn prepare_and_sign(ctx: &Context<'_>, ipa_bytes: Vec<u8>, opts: &Options,
                              status: &(dyn Fn(String) + Send + Sync)) -> Result<Prepared, String> {
    let portal = Portal { gs: ctx.gs, account: ctx.account };
    let team = ctx.team.id.as_str();
    let started = std::time::Instant::now();
    let shown = std::sync::atomic::AtomicU64::new(u64::MAX);
    let mut ipa = tokio::task::block_in_place(|| Ipa::read(ipa_bytes, &|done, total| {
        let pct = done * 100 / total.max(1);
        if shown.swap(pct, std::sync::atomic::Ordering::Relaxed) != pct {
            status(format!("Reading the app: {pct}%"));
        }
    }))?;
    logf!("install: read in {:.1} s", started.elapsed().as_secs_f64());
    if opts.remove_extensions {
        let n = ipa.drop_extensions()?;
        logf!("install: removed {n} extension files");
    }
    let main = ipa.main_app()?;
    if !opts.icon.is_empty() {
        let picture = crate::icons::custom_icon(&opts.icon).ok_or("The icon you chose is gone: choose it again.")?;
        tokio::task::block_in_place(|| bundle::replace_icon(&mut ipa, &main, &picture))?;
    }
    let bundles = ipa.bundles()?;
    let mut apps: Vec<&bundle::Bundle> = bundles.iter().filter(|b| b.kind != Kind::Framework).collect();
    apps.sort_by_key(|b| b.depth());
    let mut main_new = ctx.previous.map(|(id, ids)| ids.get(&main.dir).cloned().unwrap_or_else(|| id.to_string()))
        .or_else(|| ctx.reuse.pick.clone())
        .unwrap_or_else(|| new_identifier(&main.id, team));
    let mut ids = identifiers(&apps, &main, &main_new, ctx.previous.map(|(_, ids)| ids));

    status("Registering this iPhone".into());
    portal.ensure_device(team, ctx.udid, ctx.device_name).await.map_err(|e| e.to_string())?;
    status("App IDs".into());
    let existing = portal.app_ids(team).await.map_err(|e| e.to_string())?;
    // A new App ID whose identifier exists: is an app installed under it?
    if ctx.previous.is_none() && ctx.reuse.pick.is_none() && existing.iter().any(|a| a.identifier == main_new) {
        let fresh = fresh_identifier(&main.id, team, &device_ids(ctx.session).await?);
        if fresh != main_new {
            logf!("install: an app on the iPhone is installed under {main_new}; {} gets {fresh}", main.name);
            main_new = fresh;
            ids = identifiers(&apps, &main, &main_new, None);
        }
    }
    fit_app_ids(ctx, &apps, &main, &mut ids, &existing, status).await?;
    status("Signing certificate".into());
    let cert = certificate(&portal, team, ctx.ask).await?;
    let leaf = cert.der.clone();
    let leaf_info = der::cert_info(&leaf)?;
    let common_name = der::name_value(leaf_info.subject, "2.5.4.3").unwrap_or_default();

    let group = group_for(&main.id, team, &ipa);
    let mut plan_bundles = HashMap::new();
    let mut info_edits: HashMap<String, Dictionary> = HashMap::new();
    let mut expires = u64::MAX;
    let mut increased_memory = false;
    for b in &apps {
        let new_id = ids[&b.dir].clone();
        let app_id = match existing.iter().find(|a| a.identifier == new_id) {
            Some(a) => a.clone(),
            None => {
                status(format!("New App ID for {}", b.name));
                portal.add_app_id(team, &new_id, &b.name).await
                    .map_err(|e| if e.code == 9401 || e.message.contains("maximum") {
                        format!("Apple has no App ID left for {} ({e}). Turning on Remove extensions needs fewer.", b.name)
                    } else if ctx.reuse.pick.is_some() && b.dir == main.dir {
                        format!("Apple refused the App ID {new_id} ({e}). An App ID belongs to one developer \
                                 everywhere: choose another.")
                    } else { e.to_string() })?
            }
        };
        if let Some(group) = &group {
            status(format!("App group for {}", b.name));
            if portal.assign_group(team, &app_id, group).await.map_err(|e| e.to_string())? {
                let mut d = Dictionary::new();
                d.insert("ALTAppGroups".into(), Value::Array(vec![Value::String(group.clone())]));
                info_edits.insert(b.dir.clone(), d);
            }
        }
        if opts.increased_memory && b.dir == main.dir {
            status("Increased Memory Limit".into());
            if let Err(e) = portal.add_increased_memory(team, &app_id).await {
                logf!("install: increased memory refused: {e}");
                status(format!("Apple refused Increased Memory Limit: {e}"));
            }
        }
        status(format!("Profile for {}", b.name));
        let profile = portal.profile(team, &app_id).await.map_err(|e| e.to_string())?;
        let p = bundle::profile_plist(&profile)?;
        if let Some(Value::Date(d)) = p.get("ExpirationDate") {
            let t: std::time::SystemTime = (*d).into();
            let secs = t.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            expires = expires.min(secs);
        }
        let mut entitlements = p.get("Entitlements").and_then(Value::as_dictionary).cloned()
            .ok_or("the profile has no entitlements")?;
        if b.dir == main.dir {
            increased_memory = entitlements.get(INCREASED_MEMORY).and_then(Value::as_boolean) == Some(true);
            if opts.increased_memory && !increased_memory {
                logf!("install: Apple's profile for {} has no Increased Memory Limit", b.name);
            }
        }
        entitlements.insert("application-identifier".into(), Value::String(format!("{team}.{new_id}")));
        entitlements.insert("com.apple.developer.team-identifier".into(), Value::String(team.into()));
        plan_bundles.insert(b.dir.clone(), Signing { new_id, profile, entitlements });
    }

    const INTERMEDIATES: [&[u8]; 5] = [
        include_bytes!("../assets/certs/AppleWWDRCAG3.cer"), include_bytes!("../assets/certs/AppleWWDRCAG4.cer"),
        include_bytes!("../assets/certs/AppleWWDRCAG5.cer"), include_bytes!("../assets/certs/AppleWWDRCAG6.cer"),
        include_bytes!("../assets/certs/AppleWWDRCAG2.cer"),
    ];
    const ROOTS: [&[u8]; 2] = [include_bytes!("../assets/certs/AppleRootCA.cer"), include_bytes!("../assets/certs/AppleRootCAG3.cer")];
    let mut chain = Vec::new();
    for cert in INTERMEDIATES {
        let Ok(info) = der::cert_info(cert) else { continue };
        if info.subject != leaf_info.issuer {
            continue;
        }
        chain.push(cert.to_vec());
        if let Some(root) = ROOTS.iter().find(|r| der::cert_info(r).map(|ri| ri.subject == info.issuer).unwrap_or(false)) {
            chain.push(root.to_vec());
        }
        break;
    }
    if chain.is_empty() {
        return Err("the certificate Apple issued chains to an Apple CA BariStore does not know".into());
    }
    let add_files = alt_certificate(&bundles, &main, &cert, ctx.udid, &mut info_edits)?;
    let cert_serial_of_plan = cert.serial.clone();
    let plan = Plan {
        identity: Identity { leaf, chain, key: cert.key, team: team.into(), common_name },
        bundles: plan_bundles,
        info_edits,
        add_files,
    };
    status("Signing".into());
    let started = std::time::Instant::now();
    let kind = kind_for(&main.id, has_sidestore_framework(&ipa));
    let out = tokio::task::block_in_place(|| {
        bundle::sign(&mut ipa, &plan, &mut |n, t| status(format!("Signing {n} of {t}")))?;
        logf!("install: signed in {:.1} s", started.elapsed().as_secs_f64());
        status("Packing the app".into());
        ipa.write()
    })?;
    logf!("install: signed and packed in {:.1} s", started.elapsed().as_secs_f64());
    Ok(Prepared { ipa: out, main_id: ids[&main.dir].clone(), expires: if expires == u64::MAX { 0 } else { expires },
                  version: main.version, ids, increased_memory, kind, cert_serial: cert_serial_of_plan })
}

/// AltStore-family apps refresh themselves with the certificate they were
/// signed with: SideStore and AltStore read ALTCertificate.p12 from their
/// bundle, the certificate named by ALTCertificateID, opened with the
/// certificate's machine identifier (SideStore's CertificateProvisioningFlow;
/// isideload does the same). Without it they ask Apple for a new certificate
/// or to revoke one. In LiveContainer+SideStore the target is the embedded
/// SideStore framework. AltStore also learns this iPhone's UDID (ALTDeviceID).
fn alt_certificate(bundles: &[bundle::Bundle], main: &bundle::Bundle, cert: &DevCert, udid: &str,
                   info_edits: &mut HashMap<String, Dictionary>) -> Result<Vec<(String, Vec<u8>)>, String> {
    let target = bundles.iter().find(|b| b.kind == Kind::Framework && b.id == "com.SideStore.SideStore")
        .or_else(|| [main].into_iter().find(|m| m.id.starts_with("com.SideStore.SideStore")
                                             || m.id.starts_with("com.rileytestut.AltStore")));
    let Some(target) = target else { return Ok(vec![]) };
    if cert.machine_id.is_empty() || cert.serial.is_empty() {
        logf!("install: the portal did not list the certificate's serial or machine id; no ALTCertificate.p12");
        return Ok(vec![]);
    }
    let p12 = crate::sign::p12::pkcs12(&cert.der, &cert.key, &cert.machine_id, "BariStore")?;
    let edits = info_edits.entry(target.dir.clone()).or_default();
    edits.insert("ALTCertificateID".into(), Value::String(cert.serial.clone()));
    if main.id.starts_with("com.rileytestut.AltStore") {
        info_edits.entry(main.dir.clone()).or_default().insert("ALTDeviceID".into(), Value::String(udid.into()));
    }
    logf!("install: ALTCertificate.p12 for {} (certificate {})", target.name, cert.serial);
    Ok(vec![(format!("{}/ALTCertificate.p12", target.dir), p12)])
}

/// A quick refresh that worked: the profiles' expiry and the certificate the
/// app is signed with (now recorded for records older than `cert_serial`).
pub struct Refreshed {
    pub expires: u64,
    pub cert_serial: String,
}

/// Whether `entry` is signed with `cert`. Records from before `cert_serial`
/// (0.10.0-alpha.12) are when the certificate already existed at the
/// install: BariStore signs only with the certificate of its own key, and a
/// new key comes only with a reset, which also forgets the records.
fn signed_with(entry: &Installed, cert: &DevCert, team: &str) -> bool {
    if !entry.cert_serial.is_empty() {
        return entry.cert_serial == cert.serial;
    }
    let made = der::cert_info(&cert.der).map(|i| i.not_before).unwrap_or(0);
    entry.team == team && made > 0 && made <= entry.installed_at
}

/// The quick refresh, as AltStore and SideStore do it: an app still on the
/// iPhone, signed with the certificate BariStore still signs with, only
/// needs fresh profiles for its App IDs; misagent installs them and nothing
/// is signed or uploaded. All apps are done in one pass: the certificate,
/// the App IDs and the iPhone's apps are asked for once, and every profile
/// at the same time. Per app: the result, or why it needs a full refresh.
pub async fn refresh_profiles(portal: &Portal<'_>, team: &str, udid: &str, device_name: &str, session: &Session,
                              entries: &[Installed], status: &(dyn Fn(String) + Send + Sync))
    -> Result<Vec<Result<Refreshed, String>>, String>
{
    status("Checking the certificate, App IDs and apps".into());
    let (cert, device, existing, on_device) = tokio::join!(portal.certificate(team),
        portal.ensure_device(team, udid, device_name), portal.app_ids(team), device_ids(session));
    let (cert, existing) = (cert.map_err(|e| e.to_string())?, existing.map_err(|e| e.to_string())?);
    device.map_err(|e| e.to_string())?;
    let on_device = on_device?;
    // Which App IDs each app needs, or why it cannot be refreshed this way.
    let plans: Vec<Result<Vec<&AppId>, String>> = entries.iter().map(|e| {
        if !on_device.contains(&e.bundle_id) {
            return Err("the app is not on the iPhone".into());
        }
        if !signed_with(e, &cert, team) {
            return Err("it is signed with another certificate".into());
        }
        let ids: Vec<&String> = if e.ids.is_empty() { vec![&e.bundle_id] } else { e.ids.values().collect() };
        ids.into_iter().map(|id| existing.iter().find(|a| a.identifier == *id).ok_or(format!("the App ID {id} is gone")))
            .collect()
    }).collect();
    let mut wanted: Vec<&AppId> = plans.iter().flatten().flatten().copied().collect();
    wanted.sort_by(|a, b| a.id.cmp(&b.id));
    wanted.dedup_by(|a, b| a.id == b.id);
    status(format!("Getting {} new profile{}", wanted.len(), if wanted.len() == 1 { "" } else { "s" }));
    let cert_der = cert.der.as_slice();
    let fetched = futures_util::future::join_all(wanted.iter().map(|app| async move {
        let profile = portal.profile(team, app).await.map_err(|e| e.to_string())?;
        let p = bundle::profile_plist(&profile)?;
        let lists_cert = p.get("DeveloperCertificates").and_then(Value::as_array).into_iter().flatten()
            .any(|c| c.as_data() == Some(cert_der));
        if !lists_cert {
            return Err("the new profile does not list the app's certificate".to_string());
        }
        let expires = match p.get("ExpirationDate") {
            Some(Value::Date(d)) => std::time::SystemTime::from(*d).duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs()).unwrap_or(0),
            _ => 0,
        };
        Ok::<_, String>((profile, expires))
    })).await;
    let profiles: HashMap<&str, Result<(Vec<u8>, u64), String>> =
        wanted.iter().map(|a| a.id.as_str()).zip(fetched).collect();
    status("Installing the new profiles".into());
    let mut installed: HashMap<&str, Result<u64, String>> = HashMap::new();
    let mut out = Vec::new();
    for plan in plans {
        let apps = match plan {
            Ok(apps) => apps,
            Err(e) => {
                out.push(Err(e));
                continue;
            }
        };
        let mut expires = u64::MAX;
        let mut failed = None;
        for app in apps {
            let done = match installed.get(app.id.as_str()) {
                Some(done) => done.clone(),
                None => {
                    let done = match &profiles[app.id.as_str()] {
                        Ok((profile, until)) => services::install_profile(session, profile).await.map(|_| *until),
                        Err(e) => Err(e.clone()),
                    };
                    installed.insert(app.id.as_str(), done.clone());
                    done
                }
            };
            match done {
                Ok(until) => expires = expires.min(until),
                Err(e) => failed = Some(e),
            }
        }
        out.push(match failed {
            Some(e) => Err(e),
            None => Ok(Refreshed { expires: if expires == u64::MAX { 0 } else { expires }, cert_serial: cert.serial.clone() }),
        });
    }
    Ok(out)
}

/// A password for an exported .p12: short enough to type, from letters and
/// digits that cannot be mistaken for each other.
pub fn p12_password() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    (0..10).map(|_| ALPHABET[rand::random::<usize>() % ALPHABET.len()] as char).collect()
}

pub fn percent_encode(text: &str) -> String {
    text.bytes().map(|b| match b {
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
        _ => format!("%{b:02X}"),
    }).collect()
}

/// LiveContainer's certificate import (LCSettingsView.handleURL, the
/// callback SideStore's certificate export calls): the p12 in base64 and its
/// password; LiveContainer stores both in its app group for JIT-less mode.
pub fn livecontainer_certificate_url(p12: &[u8], password: &str) -> String {
    use base64::Engine;
    let cert = base64::engine::general_purpose::STANDARD.encode(p12);
    format!("livecontainer://certificate?cert={}&password={}", percent_encode(&cert), percent_encode(password))
}

/// Writes the pairing record into apps that refresh themselves over the
/// loopback. Destinations as SideInstaller and StikDebug document them:
/// SideStore nightlies (>= 0.7.0-20260920) read Documents/PairingFile_RemoteRP.plist
/// once their preferences say isPairingReset = false and
/// activePairingProtocol = rppairing; older SideStore and LiveContainer's
/// built-in one read ALTPairingFile.mobiledevicepairing; AltStore Classic
/// 2.3.1+ reads Documents/ALTPairingFile.plist (not the Beta); StikDebug
/// reads Documents/pairingFile.plist (its PairingFileStore). LiveContainer
/// without SideStore reads none.
pub async fn place_pairing_file(session: &Session, installed_id: &str, kind: &str,
                                record: &pairing::record::PairingRecord) -> Result<bool, String> {
    let (files, prefs): (&[&str], Option<String>) = match kind {
        SIDESTORE => (&["/Documents/ALTPairingFile.mobiledevicepairing", "/Documents/PairingFile_RemoteRP.plist"],
                      Some(format!("/Library/Preferences/{installed_id}.plist"))),
        LIVECONTAINER_SIDESTORE => (&["/Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing",
                                      "/Documents/SideStore/Documents/PairingFile_RemoteRP.plist"],
                                    Some("/Documents/SideStore/Library/Preferences/com.SideStore.SideStore.plist".into())),
        ALTSTORE => (&["/Documents/ALTPairingFile.plist"], None),
        // StikDebug copies Documents/pairingFile.plist into its own store.
        STIKDEBUG => (&["/Documents/pairingFile.plist"], None),
        _ => return Ok(false),
    };
    let mut afc = services::app_container(session, installed_id, false).await?;
    let mkdirs = |path: &str| {
        let mut dirs = Vec::new();
        let mut current = String::new();
        let parent = path.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
        for part in parent.split('/').filter(|p| !p.is_empty()) {
            current.push('/');
            current.push_str(part);
            dirs.push(current.clone());
        }
        dirs
    };
    let xml = record.to_remote_only_xml();
    for path in files {
        for dir in mkdirs(path) {
            let _ = afc.mkdir(&dir).await;
        }
        afc.write_file(path, &xml, &mut |_, _| {}).await?;
    }
    if let Some(prefs_path) = prefs {
        for dir in mkdirs(&prefs_path) {
            let _ = afc.mkdir(&dir).await;
        }
        let existing = afc.read_file(&prefs_path, 1 << 20).await.unwrap_or_default();
        let mut prefs: Dictionary = if existing.is_empty() { Dictionary::new() } else {
            plist::from_bytes::<Value>(&existing).ok().and_then(Value::into_dictionary).unwrap_or_default()
        };
        prefs.insert("isPairingReset".into(), Value::Boolean(false));
        prefs.insert("activePairingProtocol".into(), Value::String("rppairing".into()));
        afc.write_file(&prefs_path, &crate::pairing::record::plist_xml(&prefs), &mut |_, _| {}).await?;
    }
    logf!("install: pairing file written into {installed_id}");
    Ok(true)
}

/// Install signed bytes and remember the app.
#[allow(clippy::too_many_arguments)]
pub async fn install_signed(session: &Session, signed: &[u8], entry: Installed,
                            status: &(dyn Fn(&str, u32) + Send + Sync)) -> Result<(), String> {
    services::install(session, signed, &mut |stage, pct| status(stage, pct)).await?;
    let mut list = installed();
    list.retain(|i| i.bundle_id != entry.bundle_id);
    list.push(Installed { installed_at: now(), ..entry });
    save_installed(&list);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn livecontainer_url_round_trips() {
        let p12 = [0xFBu8, 0xFF, 0xBF, 0x00, 0x3E];
        let url = livecontainer_certificate_url(&p12, "a b&c");
        assert_eq!(url, "livecontainer://certificate?cert=%2B%2F%2B%2FAD4%3D&password=a%20b%26c");
        let pw = p12_password();
        assert_eq!(pw.len(), 10);
        assert!(pw.chars().all(|c| c.is_ascii_alphanumeric() && !"lo01i".contains(c)));
    }

    /// The URL carries a .p12 that OpenSSL 3 (LiveContainer's ZSign) opens
    /// with the password from the URL, after undoing the encoding the way
    /// URLComponents.queryItems does.
    #[test]
    fn livecontainer_url_carries_a_usable_p12() {
        use base64::Engine;
        let dir = std::env::temp_dir().join(format!("baristore-lc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (key_path, cert_path) = (dir.join("k.pem"), dir.join("c.der"));
        assert!(std::process::Command::new("openssl")
            .args(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Apple Development: Test/OU=TEAMID1234",
                   "-days", "1", "-outform", "DER", "-keyout", key_path.to_str().unwrap(), "-out", cert_path.to_str().unwrap()])
            .output().unwrap().status.success());
        use rsa::pkcs8::DecodePrivateKey;
        let key = rsa::RsaPrivateKey::from_pkcs8_pem(&std::fs::read_to_string(&key_path).unwrap()).unwrap();
        let password = p12_password();
        let p12 = crate::sign::p12::pkcs12(&std::fs::read(&cert_path).unwrap(), &key, &password, "BariStore").unwrap();
        let url = livecontainer_certificate_url(&p12, &password);
        let query = url.strip_prefix("livecontainer://certificate?").unwrap();
        let field = |name: &str| -> String {
            let raw = query.split('&').find_map(|kv| kv.strip_prefix(&format!("{name}="))).unwrap();
            crate::web::percent_decode(raw)
        };
        assert_eq!(field("password"), password);
        let decoded = base64::engine::general_purpose::STANDARD.decode(field("cert")).unwrap();
        assert_eq!(decoded, p12);
        let p12_path = dir.join("lc.p12");
        std::fs::write(&p12_path, &decoded).unwrap();
        let out = std::process::Command::new("openssl")
            .args(["pkcs12", "-in", p12_path.to_str().unwrap(), "-passin", &format!("pass:{password}"), "-nodes"])
            .output().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        assert!(String::from_utf8_lossy(&out.stdout).contains("OU = TEAMID1234")
            || String::from_utf8_lossy(&out.stdout).contains("OU=TEAMID1234"));
    }

    #[test]
    fn new_app_ids_never_take_an_apps_place() {
        let on = |ids: &[&str]| ids.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(fresh_identifier("com.a.b", "T1", &on(&[])), "com.a.b.T1");
        // Its own App ID, free again: taken again.
        assert_eq!(fresh_identifier("com.a.b", "T1", &on(&["com.x.y.T1"])), "com.a.b.T1");
        // Another app (or a copy) is installed under it.
        assert_eq!(fresh_identifier("com.a.b", "T1", &on(&["com.a.b.T1"])), "com.a.b2.T1");
        assert_eq!(fresh_identifier("com.a.b.T1", "T1", &on(&["com.a.b.T1", "com.a.b2.T1"])), "com.a.b3.T1");
    }

    #[test]
    fn custom_app_ids() {
        assert_eq!(custom_identifier(" com.me.app ", "T1").unwrap(), "com.me.app.T1");
        assert_eq!(custom_identifier("com.me.app.T1", "T1").unwrap(), "com.me.app.T1");
        for bad in ["app", ".com.me", "com..me", "com.me.", "com.me/app", "com.me app", ""] {
            assert!(custom_identifier(bad, "T1").is_err(), "{bad}");
        }
    }

    #[test]
    fn kinds_of_old_entries() {
        let mut e = Installed {
            bundle_id: "com.kdt.livecontainer.T".into(), original_id: "com.kdt.livecontainer".into(),
            name: "LiveContainer".into(), version: String::new(),
            source_url: "https://github.com/LiveContainer/LiveContainer/releases/download/nightly/LiveContainer.ipa".into(),
            ..Default::default()
        };
        assert_eq!(guess_kind(&e), LIVECONTAINER);
        e.source_url = e.source_url.replace("LiveContainer.ipa", "LiveContainer+SideStore.ipa");
        assert_eq!(guess_kind(&e), LIVECONTAINER_SIDESTORE);
        // An app installed under LiveContainer's App ID is still itself.
        e.original_id = "dev.whetstone.jitprobe".into();
        assert_eq!(guess_kind(&e), "");
        e.original_id = "com.rileytestut.AltStore.Beta".into();
        assert_eq!(guess_kind(&e), "");
        assert!(!reads_pairing_file(LIVECONTAINER) && reads_pairing_file(LIVECONTAINER_SIDESTORE));
    }
}
