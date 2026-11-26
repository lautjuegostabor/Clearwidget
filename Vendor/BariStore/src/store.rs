//! The catalog: BariStore's own picks (AltStore, SideStore, LiveContainer +
//! SideStore, LiveContainer; stable and nightly, resolved live from each
//! project's GitHub releases) plus every app from the user's AltSources.
//! An app offered by several sources keeps one entry with one version per
//! source, so the user picks where it comes from. Only plain LiveContainer
//! is recommended: the stores and LiveContainer + SideStore stay in the list.

use serde::{Deserialize, Serialize};
use serde_json::Value as Json;
use std::collections::BTreeMap;
use std::time::Duration;

use crate::{logf, state};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Source {
    pub url: String,
    pub name: String,
    #[serde(default)]
    pub error: String,
}

/// Open-source, widely used AltSources: preloaded on first run, and offered
/// again under Sources › Suggested once removed.
pub const DEFAULT_SOURCES: &[(&str, &str)] = &[
    ("https://community-apps.sidestore.io/sidecommunity.json", "SideStore Community"),
    ("https://stikdebug.xyz/index.json", "StikDebug"),
    ("https://alt.getutm.app", "UTM"),
    ("https://provenance-emu.com/apps.json", "Provenance"),
    ("https://raw.githubusercontent.com/Aidoku/Aidoku/altstore/apps.json", "Aidoku"),
    ("https://xitrix.github.io/iTorrent/AltStore.json", "iTorrent"),
    ("https://raw.githubusercontent.com/chachillie/Flycast-iOS/main/flycast-ios.json", "Flycast"),
    // Husk, AetherPS4, Utsuro, Henge… (the source Leviidev's README names).
    ("https://raw.githubusercontent.com/Leviidev/Husk/main/altsource.json", "Leviidev"),
];

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Version {
    pub source: String,       // source name ("BariStore" for the picks)
    pub source_url: String,
    /// "stable" / "nightly" for the picks; "" for an AltSource's own
    /// version, or the name of one of its beta tracks ("nightly", "alpha"…).
    pub channel: String,
    pub version: String,
    pub date: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
    pub min_os: String,
    pub notes: String,
    pub warning: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct App {
    pub key: String,          // "bundle id" or "bundle id|ipa asset" for the picks
    pub bundle_id: String,
    pub name: String,
    pub developer: String,
    pub subtitle: String,
    pub description: String,
    pub icon: String,
    pub tint: String,
    /// AltStore's category identifier ("games", "utilities", …; "" = other).
    pub category: String,
    /// One of BariStore's picks (resolved from GitHub releases).
    pub featured: bool,
    /// Shown under Recommended.
    #[serde(default)]
    pub recommended: bool,
    /// Screenshot URLs (iPhone ones first), at most six.
    #[serde(default)]
    pub screenshots: Vec<String>,
    pub versions: Vec<Version>,
}

/// The user's sources. A default source added in a later version joins an
/// existing list once (`defaults-seen` records which were offered), so one
/// the user removed stays removed.
pub fn sources() -> Vec<Source> {
    let source = |(u, n): &(&str, &str)| Source { url: u.to_string(), name: n.to_string(), error: String::new() };
    let Some(mut list) = std::fs::read(state::path("sources.json")).ok()
        .and_then(|b| serde_json::from_slice::<Vec<Source>>(&b).ok()) else {
        return DEFAULT_SOURCES.iter().map(source).collect();
    };
    let seen = std::fs::read_to_string(state::path("defaults-seen")).unwrap_or_default();
    let new: Vec<&(&str, &str)> = DEFAULT_SOURCES.iter().filter(|(u, _)| !seen.lines().any(|l| l == *u)).collect();
    if !new.is_empty() {
        for d in &new {
            if !list.iter().any(|s| s.url == d.0) {
                list.push(source(d));
            }
        }
        save_sources(&list);
    }
    list
}

/// Default sources the user's list does not have.
pub fn suggested(list: &[Source]) -> Vec<Source> {
    DEFAULT_SOURCES.iter().filter(|(u, _)| !list.iter().any(|s| s.url == *u))
        .map(|(u, n)| Source { url: u.to_string(), name: n.to_string(), error: String::new() }).collect()
}

pub fn default_name(url: &str) -> Option<&'static str> {
    DEFAULT_SOURCES.iter().find(|(u, _)| *u == url).map(|(_, n)| *n)
}

pub fn save_sources(list: &[Source]) {
    if let Ok(b) = serde_json::to_vec_pretty(list) {
        let _ = std::fs::write(state::path("sources.json"), b);
    }
    // A list saved by the user has seen every current default.
    let all: Vec<&str> = DEFAULT_SOURCES.iter().map(|(u, _)| *u).collect();
    let _ = std::fs::write(state::path("defaults-seen"), all.join("\n"));
}

/// One client for the whole server: it keeps connections (and their TLS
/// handshakes, slow on Minis's emulated CPU) for the next request.
pub fn client() -> reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| reqwest::Client::builder()
        .user_agent(concat!("BariStore/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(30))
        .build()
        .expect("HTTP client")).clone()
}

fn text(v: &Json, k: &str) -> String {
    match v.get(k) {
        Some(Json::String(s)) => s.clone(),
        Some(Json::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

/// Screenshots as AltSources give them: `screenshots` as URLs, as
/// {imageURL, width, height} objects, or as {iphone: […], ipad: […]}; or
/// the legacy `screenshotURLs`.
fn screenshots(a: &Json) -> Vec<String> {
    let url = |v: &Json| match v {
        Json::String(s) => Some(s.clone()),
        Json::Object(_) => v.get("imageURL").and_then(Json::as_str).map(str::to_string),
        _ => None,
    };
    let list = |v: Option<&Json>| -> Vec<String> {
        v.and_then(Json::as_array).into_iter().flatten().filter_map(url).collect()
    };
    let mut out = match a.get("screenshots") {
        Some(Json::Object(_)) => {
            let s = a.get("screenshots");
            [list(s.and_then(|s| s.get("iphone"))), list(s.and_then(|s| s.get("ipad")))].concat()
        }
        other => list(other),
    };
    if out.is_empty() {
        out = list(a.get("screenshotURLs"));
    }
    out.retain(|u| u.starts_with("https://") || u.starts_with("http://"));
    out.truncate(6);
    out
}

/// Parses an AltSource document (versions[] or the legacy flat fields),
/// with the beta tracks of SideStore's format (`releaseChannels`: a track
/// name and its releases, newest first).
pub fn parse_source(doc: &Json, source: &Source) -> (String, Vec<App>) {
    let name = { let n = text(doc, "name"); if n.is_empty() { source.name.clone() } else { n } };
    let version = |v: &Json, channel: &str| Version {
        source: name.clone(), source_url: source.url.clone(), channel: channel.into(),
        version: text(v, "version"), date: text(v, "date"), url: text(v, "downloadURL"),
        size: v.get("size").and_then(Json::as_u64).unwrap_or(0), sha256: text(v, "sha256"),
        min_os: text(v, "minOSVersion"), notes: text(v, "localizedDescription"),
        warning: if channel.is_empty() { String::new() } else {
            format!("A beta track ({channel}): pre-release builds may be unstable.")
        },
    };
    let mut apps = Vec::new();
    for a in doc.get("apps").and_then(Json::as_array).into_iter().flatten() {
        let bundle_id = text(a, "bundleIdentifier");
        if bundle_id.is_empty() {
            continue;
        }
        let tracks: Vec<(String, &Json)> = a.get("releaseChannels").and_then(Json::as_array).into_iter().flatten()
            .filter_map(|t| Some((text(t, "track").trim().to_lowercase(), t.get("releases")?.as_array()?.first()?)))
            .filter(|(track, _)| !track.is_empty())
            .collect();
        let mut versions: Vec<Version> = a.get("versions").and_then(Json::as_array).into_iter().flatten()
            .take(1).map(|v| version(v, "")).collect();
        if versions.is_empty() {
            versions.extend(tracks.iter().filter(|(t, _)| t == "stable").map(|(_, v)| version(v, "")));
        }
        if versions.is_empty() && !text(a, "downloadURL").is_empty() {
            versions.push(Version {
                source: name.clone(), source_url: source.url.clone(), channel: String::new(),
                version: text(a, "version"), date: text(a, "versionDate"), url: text(a, "downloadURL"),
                size: a.get("size").and_then(Json::as_u64).unwrap_or(0), sha256: String::new(),
                min_os: text(a, "minOSVersion"), notes: text(a, "versionDescription"), warning: String::new(),
            });
        }
        for (track, v) in tracks.iter().filter(|(t, _)| t != "stable") {
            if !versions.iter().any(|x| x.channel == *track) {
                versions.push(version(v, track));
            }
        }
        versions.retain(|v| !v.url.is_empty());
        if versions.is_empty() {
            continue;
        }
        apps.push(App {
            key: bundle_id.clone(), bundle_id, name: text(a, "name"), developer: text(a, "developerName"),
            subtitle: text(a, "subtitle"), description: text(a, "localizedDescription"),
            icon: text(a, "iconURL"), tint: text(a, "tintColor"), category: text(a, "category").to_lowercase(),
            featured: false, recommended: false, screenshots: screenshots(a), versions,
        });
    }
    (name, apps)
}

struct Pick {
    name: &'static str,
    bundle_id: &'static str,
    repo: &'static str,
    asset: &'static str,
    developer: &'static str,
    subtitle: &'static str,
    description: &'static str,
    icon: &'static str,
    nightly: bool,
    recommended: bool,
    category: &'static str,
}

const PICKS: &[Pick] = &[
    Pick { name: "SideStore", bundle_id: "com.SideStore.SideStore", repo: "SideStore/SideStore", asset: "SideStore.ipa",
           developer: "SideStore Team", subtitle: "Sideload apps and refresh them on your iPhone", nightly: true,
           recommended: false, category: "stores",
           description: "An app store that installs and refreshes apps on the iPhone itself over LocalDevVPN. \
                         BariStore gives it the pairing file and the signing certificate.",
           icon: "https://raw.githubusercontent.com/SideStore/SideStore/develop/AltStore/Resources/Icons.xcassets/AppIcon.appiconset/180.png" },
    Pick { name: "LiveContainer + SideStore", bundle_id: "com.kdt.livecontainer", repo: "LiveContainer/LiveContainer",
           asset: "LiveContainer+SideStore.ipa", developer: "LiveContainer", nightly: true, recommended: false,
           category: "stores",
           subtitle: "Run apps inside one container, with SideStore built in",
           description: "LiveContainer with SideStore built in. BariStore gives the built-in SideStore the pairing file \
                         and the signing certificate.",
           icon: "https://raw.githubusercontent.com/LiveContainer/LiveContainer/main/screenshots/AppIcon1024.png" },
    Pick { name: "LiveContainer", bundle_id: "com.kdt.livecontainer", repo: "LiveContainer/LiveContainer",
           asset: "LiveContainer.ipa", developer: "LiveContainer", nightly: true, recommended: true,
           category: "utilities",
           subtitle: "Run apps without installing them, beyond the 3-app limit",
           description: "Runs apps inside one app, so a free Apple ID's limit of 3 apps and 10 App IDs no longer \
                         matters. My Apps › LiveContainer › Give it the certificate turns on its JIT-less mode.",
           icon: "https://raw.githubusercontent.com/LiveContainer/LiveContainer/main/screenshots/AppIcon1024.png" },
    Pick { name: "AltStore Classic", bundle_id: "com.rileytestut.AltStore", repo: "altstoreio/AltStore", asset: ".ipa",
           developer: "Riley Testut", subtitle: "The original alternative app store", nightly: false,
           recommended: false, category: "stores",
           description: "The original alternative app store. BariStore gives it the pairing file and the signing \
                         certificate.",
           // AltStore 2.0's icon, at the commit that added it (the branch moved).
           icon: "https://raw.githubusercontent.com/altstoreio/AltStore/252bea18795f8beef2e1ea5aa8ea4d36427f675c/AltStore/Resources/Assets.xcassets/AppIcon.appiconset/AltStore-180.png" },
];

fn release_version(rel: &Json, asset: &Json, channel: &str, pick: &Pick) -> Version {
    let body = text(rel, "body");
    let title = text(rel, "name");
    let upper = format!("{title}\n{body}").to_uppercase();
    let mut warning = String::new();
    if channel == "nightly" {
        warning = "Nightly builds are pre-release and may be unstable.".into();
    }
    if upper.contains("OUTDATED") {
        warning = "The developers mark this build as outdated and recommend the nightly.".into();
    }
    let digest = text(asset, "digest");
    Version {
        source: "BariStore".into(),
        source_url: format!("https://github.com/{}/releases", pick.repo),
        channel: channel.into(),
        version: if channel == "nightly" { format!("nightly {}", &text(asset, "updated_at").get(..10).unwrap_or("")) } else { text(rel, "tag_name") },
        date: text(asset, "updated_at").get(..10).unwrap_or("").to_string(),
        url: text(asset, "browser_download_url"),
        size: asset.get("size").and_then(Json::as_u64).unwrap_or(0),
        sha256: digest.strip_prefix("sha256:").unwrap_or("").to_string(),
        min_os: String::new(),
        notes: body.chars().take(1500).collect(),
        warning,
    }
}

fn is_unusable(rel: &Json) -> bool {
    let all = format!("{}\n{}", text(rel, "name"), text(rel, "body")).to_uppercase();
    all.contains("DO NOT USE") || all.contains("SIGN-IN IS BROKEN")
}

fn stable_tag(tag: &str) -> bool {
    let t = tag.to_lowercase();
    !(t.contains("alpha") || t.contains("beta") || t.contains("rc") || t == "nightly")
}

/// Stable: the newest non-pre-release whose tag is not alpha/beta/rc; if the
/// developers mark it unusable, no stable is offered (we do not fall back to an
/// older one). Nightly: the release tagged "nightly" (rolling; its asset date
/// is the version shown).
async fn picks(http: &reqwest::Client) -> Vec<App> {
    let mut out = Vec::new();
    let mut cache: BTreeMap<&str, Vec<Json>> = BTreeMap::new();
    for pick in PICKS {
        if !cache.contains_key(pick.repo) {
            let url = format!("https://api.github.com/repos/{}/releases?per_page=30", pick.repo);
            let list = match http.get(&url).header("Accept", "application/vnd.github+json").send().await {
                Ok(r) if r.status().is_success() => r.json::<Vec<Json>>().await.unwrap_or_default(),
                Ok(r) => { logf!("store: {url}: HTTP {}", r.status()); Vec::new() }
                Err(e) => { logf!("store: {url}: {e}"); Vec::new() }
            };
            cache.insert(pick.repo, list);
        }
        let releases = &cache[pick.repo];
        let asset_of = |rel: &Json| -> Option<Json> {
            rel.get("assets")?.as_array()?.iter().find(|a| {
                let n = text(a, "name");
                if pick.asset.starts_with('.') { n.ends_with(pick.asset) } else { n == pick.asset }
            }).cloned()
        };
        let mut versions = Vec::new();
        if let Some(rel) = releases.iter().find(|r| r.get("draft") != Some(&Json::Bool(true))
            && r.get("prerelease") != Some(&Json::Bool(true)) && stable_tag(&text(r, "tag_name")))
        {
            if !is_unusable(rel) {
                if let Some(a) = asset_of(rel) {
                    versions.push(release_version(rel, &a, "stable", pick));
                }
            }
        }
        if pick.nightly {
            if let Some(rel) = releases.iter().find(|r| text(r, "tag_name") == "nightly") {
                if let Some(a) = asset_of(rel) {
                    versions.push(release_version(rel, &a, "nightly", pick));
                }
            }
        }
        if versions.is_empty() {
            continue;
        }
        out.push(App {
            key: format!("{}|{}", pick.bundle_id, pick.asset),
            bundle_id: pick.bundle_id.into(), name: pick.name.into(), developer: pick.developer.into(),
            subtitle: pick.subtitle.into(), description: pick.description.into(), icon: pick.icon.into(),
            tint: String::new(), category: pick.category.into(), featured: true, recommended: pick.recommended,
            screenshots: Vec::new(), versions,
        });
    }
    out
}

/// Fetches everything (concurrently); falls back to the cached catalog for
/// sources that do not answer.
pub async fn refresh() -> (Vec<App>, Vec<Source>) {
    let http = client();
    let mut list = sources();
    let fetches = list.iter().map(|s| {
        let http = http.clone();
        let s = s.clone();
        async move {
            let r = http.get(&s.url).send().await;
            let doc = match r {
                Ok(r) if r.status().is_success() => r.json::<Json>().await.map_err(|e| format!("not an AltSource: {e}")),
                Ok(r) => Err(format!("the source answered HTTP {}", r.status().as_u16())),
                Err(e) if e.is_timeout() => Err("the source did not answer in time".into()),
                Err(e) => { logf!("store: {}: {e}", s.url); Err("could not reach the source".into()) }
            };
            (s, doc)
        }
    });
    let (picked, results) = tokio::join!(picks(&http), futures_util::future::join_all(fetches));
    let cached = cached_catalog();
    let mut merged: BTreeMap<String, App> = BTreeMap::new();
    for app in picked {
        merged.insert(app.key.clone(), app);
    }
    if !merged.values().any(|a| a.featured) {
        for app in cached.iter().filter(|a| a.featured) {
            merged.insert(app.key.clone(), app.clone());
        }
    }
    for (i, (source, doc)) in results.into_iter().enumerate() {
        let apps = match doc {
            Ok(doc) => {
                let (name, apps) = parse_source(&doc, &source);
                list[i].name = name;
                list[i].error.clear();
                apps
            }
            Err(e) => {
                list[i].error = e;
                cached.iter().filter(|a| a.versions.iter().any(|v| v.source_url == source.url)).cloned().collect()
            }
        };
        for app in apps {
            match merged.get_mut(&app.key) {
                Some(existing) if !existing.featured => {
                    for v in app.versions {
                        if !existing.versions.iter().any(|x| x.source_url == v.source_url && x.channel == v.channel) {
                            existing.versions.push(v);
                        }
                    }
                    if existing.icon.is_empty() {
                        existing.icon = app.icon;
                    }
                    if existing.screenshots.is_empty() {
                        existing.screenshots = app.screenshots;
                    }
                    if existing.category.is_empty() {
                        existing.category = app.category;
                    }
                }
                Some(_) => {}
                None => {
                    merged.insert(app.key.clone(), app);
                }
            }
        }
    }
    let catalog: Vec<App> = merged.into_values().collect();
    if let Ok(b) = serde_json::to_vec(&catalog) {
        let _ = std::fs::write(state::path("catalog.json"), b);
    }
    save_sources(&list);
    (catalog, list)
}

pub fn cached_catalog() -> Vec<App> {
    std::fs::read(state::path("catalog.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Where `download` keeps `v`.
fn cache_path(v: &Version) -> std::path::PathBuf {
    use sha2::{Digest, Sha256};
    let name = hex::encode(&Sha256::digest(format!("{}|{}|{}", v.url, v.version, v.date))[..12]);
    state::path("ipas").join(format!("{name}.ipa"))
}

/// The file names inside the IPA of `v`: from the downloaded copy when there
/// is one, else from its zip directory, read with range requests (two or
/// three small ones instead of the whole download).
pub async fn ipa_names(v: &Version) -> Result<Vec<String>, String> {
    let path = cache_path(v);
    if path.is_file() {
        return crate::sign::bundle::names(&path);
    }
    let http = client();
    let get = |range: String| {
        let http = http.clone();
        async move {
            let resp = http.get(&v.url).header("Range", range).send().await.map_err(|e| e.to_string())?;
            // A host that ignores ranges would send the whole IPA: stop.
            if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
                return Err(format!("the host does not answer range requests (HTTP {})", resp.status().as_u16()));
            }
            let total = resp.headers().get("content-range").and_then(|h| h.to_str().ok())
                .and_then(|h| h.rsplit('/').next()).and_then(|t| t.parse::<u64>().ok()).unwrap_or(0);
            let body = resp.bytes().await.map_err(|e| e.to_string())?;
            Ok::<_, String>((body.to_vec(), total))
        }
    };
    // The size first: GitHub's release storage refuses suffix ranges
    // ("bytes=-N", HTTP 501). The end record is within the last 22 bytes and
    // a comment of up to 64 KiB.
    let (_, total) = get("bytes=0-0".into()).await?;
    if total < 22 {
        return Err("the host did not say how large the IPA is".into());
    }
    let tail_start = total.saturating_sub(65_558);
    let (tail, _) = get(format!("bytes={tail_start}-{}", total - 1)).await?;
    let (at, size) = match zip_directory(&tail) {
        Some(Directory::Found { at, size }) => (at, size),
        Some(Directory::Zip64 { record }) => {
            let bytes = match record.checked_sub(tail_start) {
                Some(rel) => tail.get(rel as usize..).unwrap_or_default().to_vec(),
                None => get(format!("bytes={record}-{}", record + 55)).await?.0,
            };
            zip64_directory(&bytes).ok_or("the IPA's ZIP64 directory cannot be read")?
        }
        None => return Err("the IPA's zip directory cannot be read".into()),
    };
    if size > 64 << 20 {
        return Err("the IPA's zip directory is too large".into());
    }
    let dir = match at.checked_sub(tail_start) {
        Some(rel) => tail.get(rel as usize..rel as usize + size as usize).ok_or("short zip directory")?.to_vec(),
        None => get(format!("bytes={at}-{}", at + size - 1)).await?.0,
    };
    Ok(directory_names(&dir))
}

enum Directory {
    /// The central directory's offset and size.
    Found { at: u64, size: u64 },
    /// Offset of the ZIP64 end record that holds them.
    Zip64 { record: u64 },
}

fn le(bytes: &[u8], at: usize, n: usize) -> Option<u64> {
    let b = bytes.get(at..at + n)?;
    Some(b.iter().rev().fold(0u64, |v, x| v << 8 | u64::from(*x)))
}

/// Finds the end of central directory record in the end of a zip file.
fn zip_directory(tail: &[u8]) -> Option<Directory> {
    let end = (0..tail.len().checked_sub(21)?).rev().find(|&i| tail[i..].starts_with(b"PK\x05\x06"))?;
    let (entries, size, at) = (le(tail, end + 10, 2)?, le(tail, end + 12, 4)?, le(tail, end + 16, 4)?);
    if entries == 0xFFFF || size == 0xFFFF_FFFF || at == 0xFFFF_FFFF {
        let locator = end.checked_sub(20).filter(|&l| tail[l..].starts_with(b"PK\x06\x07"))?;
        return Some(Directory::Zip64 { record: le(tail, locator + 8, 8)? });
    }
    Some(Directory::Found { at, size })
}

fn zip64_directory(record: &[u8]) -> Option<(u64, u64)> {
    record.starts_with(b"PK\x06\x06").then_some(())?;
    Some((le(record, 48, 8)?, le(record, 40, 8)?))
}

/// The names of a central directory's entries.
fn directory_names(dir: &[u8]) -> Vec<String> {
    let mut names = Vec::new();
    let mut i = 0;
    while dir.get(i..).is_some_and(|d| d.starts_with(b"PK\x01\x02")) {
        let (Some(n), Some(extra), Some(comment)) = (le(dir, i + 28, 2), le(dir, i + 30, 2), le(dir, i + 32, 2)) else { break };
        let Some(name) = dir.get(i + 46..i + 46 + n as usize) else { break };
        names.push(String::from_utf8_lossy(name).into_owned());
        i += 46 + (n + extra + comment) as usize;
    }
    names
}

/// Downloads `v` into ~/.baristore/ipas/, reusing a complete earlier copy.
pub async fn download(v: &Version, progress: &(dyn Fn(u64, u64) + Send + Sync)) -> Result<std::path::PathBuf, String> {
    use crate::hash::Sha256;
    use futures_util::StreamExt;
    use sha2::Digest;
    use std::io::Write;
    let dir = state::path("ipas");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = cache_path(v);
    let name = path.file_stem().unwrap_or_default().to_string_lossy().into_owned();
    if let Ok(meta) = std::fs::metadata(&path) {
        let size_ok = v.size == 0 || meta.len() == v.size;
        // Hashing a big IPA takes a while on Minis's emulated CPU: off the
        // async workers.
        let sha_ok = v.sha256.is_empty() || tokio::task::block_in_place(|| std::fs::read(&path)
            .map(|d| hex::encode(Sha256::digest(&d)) == v.sha256.to_lowercase()).unwrap_or(false));
        if size_ok && sha_ok {
            return Ok(path);
        }
    }
    let resp = client().get(&v.url).timeout(Duration::from_secs(1800)).send().await
        .map_err(|e| format!("download failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("download failed: HTTP {}", resp.status()));
    }
    let total = resp.content_length().unwrap_or(v.size);
    // Streamed to disk: only one chunk is in memory at a time.
    let partial = dir.join(format!("{name}.part"));
    let mut file = std::fs::File::create(&partial).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let (mut done, mut head) = (0u64, Vec::new());
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("download broke: {e}"))?;
        if head.len() < 2 {
            head.extend_from_slice(&chunk[..chunk.len().min(2)]);
        }
        hasher.update(&chunk);
        file.write_all(&chunk).map_err(|e| e.to_string())?;
        done += chunk.len() as u64;
        progress(done, total);
    }
    drop(file);
    let fail = |e: String| { let _ = std::fs::remove_file(&partial); Err(e) };
    if v.size > 0 && done != v.size {
        return fail(format!("download incomplete ({done} of {} bytes)", v.size));
    }
    if !v.sha256.is_empty() && hex::encode(hasher.finalize()) != v.sha256.to_lowercase() {
        return fail("the download does not match its published SHA-256".into());
    }
    if head.get(..2) != Some(b"PK") {
        return fail("the download is not an IPA".into());
    }
    std::fs::rename(&partial, &path).map_err(|e| e.to_string())?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_versions_and_legacy() {
        let doc: Json = serde_json::json!({"name": "Demo", "apps": [
            {"name": "A", "bundleIdentifier": "a.b", "versions": [{"version": "2", "downloadURL": "https://x/a.ipa", "size": 5}]},
            {"name": "B", "bundleIdentifier": "c.d", "version": "1", "downloadURL": "https://x/b.ipa"},
            {"name": "C", "bundleIdentifier": ""}
        ]});
        let src = Source { url: "https://s".into(), name: "S".into(), error: String::new() };
        let (name, apps) = parse_source(&doc, &src);
        assert_eq!(name, "Demo");
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].versions[0].version, "2");
        assert_eq!(apps[1].versions[0].url, "https://x/b.ipa");
    }

    #[test]
    fn beta_tracks() {
        let doc: Json = serde_json::json!({"apps": [{"name": "S", "bundleIdentifier": "s",
            "versions": [{"version": "0.6.4", "downloadURL": "https://x/s.ipa"}],
            "releaseChannels": [
                {"track": "nightly", "releases": [{"version": "0.7.0-2", "downloadURL": "https://x/n.ipa"}]},
                {"track": "Alpha", "releases": [{"version": "0.7.0-1", "downloadURL": "https://x/a.ipa"}]},
                {"track": "stable", "releases": [{"version": "0.6.4", "downloadURL": "https://x/s.ipa"}]},
                {"track": "empty", "releases": []}]},
            {"name": "T", "bundleIdentifier": "t", "releaseChannels": [
                {"track": "stable", "releases": [{"version": "1", "downloadURL": "https://x/t.ipa"}]}]}]});
        let src = Source { url: "https://s".into(), name: "S".into(), error: String::new() };
        let (_, apps) = parse_source(&doc, &src);
        let channels: Vec<(&str, &str)> = apps[0].versions.iter().map(|v| (v.channel.as_str(), v.version.as_str())).collect();
        assert_eq!(channels, [("", "0.6.4"), ("nightly", "0.7.0-2"), ("alpha", "0.7.0-1")]);
        assert!(apps[0].versions[0].warning.is_empty() && !apps[0].versions[1].warning.is_empty());
        assert_eq!(apps[1].versions[0].channel, "");
    }

    #[test]
    fn screenshots_in_every_format() {
        let doc: Json = serde_json::json!({"apps": [
            {"name": "A", "bundleIdentifier": "a", "downloadURL": "https://x/a.ipa",
             "screenshots": ["https://s/1.png", {"imageURL": "https://s/2.png", "width": 1, "height": 2}]},
            {"name": "B", "bundleIdentifier": "b", "downloadURL": "https://x/b.ipa",
             "screenshots": {"ipad": [{"imageURL": "https://s/pad.png"}], "iphone": ["https://s/phone.png"]}},
            {"name": "C", "bundleIdentifier": "c", "downloadURL": "https://x/c.ipa", "category": "Games",
             "screenshotURLs": ["https://s/old.png", "file:///etc/passwd"]}
        ]});
        let src = Source { url: "https://s".into(), name: "S".into(), error: String::new() };
        let (_, apps) = parse_source(&doc, &src);
        assert_eq!(apps[0].screenshots, ["https://s/1.png", "https://s/2.png"]);
        assert_eq!(apps[1].screenshots, ["https://s/phone.png", "https://s/pad.png"]);
        assert_eq!(apps[2].screenshots, ["https://s/old.png"]);
        assert_eq!(apps[2].category, "games");
    }

    /// The zip directory read from the end of an IPA, as range requests get
    /// it, and what it says about the app's extensions.
    #[test]
    fn reads_the_zip_directory() {
        use std::io::Write;
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let opts = zip::write::SimpleFileOptions::default();
        for name in ["Payload/A.app/Info.plist", "Payload/A.app/A", "Payload/A.app/PlugIns/W.appex/Info.plist",
                     "Payload/A.app/PlugIns/W.appex/W", "Payload/A.app/Frameworks/F.framework/Info.plist",
                     "Payload/A.app/Watch/B.app/Info.plist"] {
            zip.start_file(name, opts).unwrap();
            zip.write_all(b"x").unwrap();
        }
        zip.set_comment("a comment");
        let bytes = zip.finish().unwrap().into_inner();
        let Some(Directory::Found { at, size }) = zip_directory(&bytes) else { panic!("no directory") };
        let names = directory_names(&bytes[at as usize..(at + size) as usize]);
        assert_eq!(names.len(), 6);
        assert_eq!(crate::sign::bundle::extension_counts(names.iter().map(String::as_str)), (2, 1));
    }

    #[test]
    fn unusable_and_tags() {
        assert!(is_unusable(&serde_json::json!({"name": "0.6.4 (DO NOT USE)", "body": ""})));
        assert!(!stable_tag("0.7.0-alpha"));
        assert!(stable_tag("3.8.0"));
    }
}
