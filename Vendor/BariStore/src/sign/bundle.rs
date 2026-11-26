//! IPA in memory: find the bundles, rewrite identifiers, embed profiles, sign
//! deepest-first, seal CodeResources, check the result, write the IPA.

use plist::{Dictionary, Value};
use sha2::Digest;
use std::collections::{BTreeMap, HashMap};
use std::io::{BufReader, Cursor, Read, Write};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::OnceLock;

use super::codesign::{self, Identity, Target};
use crate::hash::{Sha1, Sha256};

#[derive(Clone)]
pub struct Entry {
    pub data: Vec<u8>,
    pub mode: u32,
    pub symlink: bool,
    /// Index in the original archive while the bytes are unchanged: the
    /// entry is then copied over compressed as it was, not compressed again.
    raw: Option<usize>,
    /// SHA-1 and SHA-256 of `data`, computed once (on the thread that
    /// signed it, when it is new): a parent bundle seals the files of its
    /// nested bundles too.
    digests: OnceLock<(Vec<u8>, Vec<u8>)>,
}

impl Entry {
    fn new(data: Vec<u8>, mode: u32, symlink: bool, raw: Option<usize>) -> Entry {
        Entry { data, mode, symlink, raw, digests: OnceLock::new() }
    }

    /// New bytes, hashed now.
    fn hashed_now(data: Vec<u8>, mode: u32) -> Entry {
        let entry = Entry::new(data, mode, false, None);
        entry.digests();
        entry
    }

    /// An unchanged file whose bytes are not kept: only its digests (for
    /// CodeResources) and its place in the original archive.
    fn hashed(mode: u32, raw: usize, digests: (Vec<u8>, Vec<u8>)) -> Entry {
        Entry { data: Vec::new(), mode, symlink: false, raw: Some(raw), digests: OnceLock::from(digests) }
    }

    fn digests(&self) -> &(Vec<u8>, Vec<u8>) {
        self.digests.get_or_init(|| (Sha1::digest(&self.data).to_vec(), Sha256::digest(&self.data).to_vec()))
    }
}

pub struct Ipa {
    pub files: BTreeMap<String, Entry>,
    order: Vec<String>,
    /// The archive as read, for copying unchanged entries.
    source: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    App,
    Extension,
    Framework,
}

#[derive(Clone, Debug)]
pub struct Bundle {
    pub dir: String,          // "Payload/X.app/PlugIns/W.appex"
    pub kind: Kind,
    pub id: String,
    pub name: String,
    pub version: String,
    pub executable: String,
    pub info: Dictionary,
}

impl Bundle {
    pub fn depth(&self) -> usize {
        self.dir.matches('/').count()
    }
}

/// What the portal produced for one app or extension bundle.
pub struct Signing {
    pub new_id: String,
    pub profile: Vec<u8>,
    pub entitlements: Dictionary,
}

pub struct Plan {
    pub identity: Identity,
    /// keyed by bundle dir; frameworks need no entry
    pub bundles: HashMap<String, Signing>,
    /// extra Info.plist keys per bundle dir (ALTAppGroups, ALTCertificateID…)
    pub info_edits: HashMap<String, Dictionary>,
    /// files to add or replace (path -> bytes)
    pub add_files: Vec<(String, Vec<u8>)>,
}

fn is_bundle_dir(name: &str) -> Option<Kind> {
    if name.ends_with(".app") {
        Some(Kind::App)
    } else if name.ends_with(".appex") {
        Some(Kind::Extension)
    } else if name.ends_with(".framework") {
        Some(Kind::Framework)
    } else {
        None
    }
}

/// The app an IPA file holds, read without unpacking it.
pub struct Peek {
    pub name: String,
    pub id: String,
    pub version: String,
    /// See `extension_counts`.
    pub extensions: usize,
    pub removable: usize,
}

/// An IPA file for reading its zip directory: buffered, since the directory
/// is read a few bytes at a time and each read is a system call (slow under
/// Minis's emulation; a big app has thousands of entries).
fn open(path: &std::path::Path) -> Result<BufReader<std::fs::File>, String> {
    Ok(BufReader::with_capacity(256 << 10, std::fs::File::open(path).map_err(|e| e.to_string())?))
}

/// The file names inside an IPA (its zip directory only).
pub fn names(path: &std::path::Path) -> Result<Vec<String>, String> {
    let zip = zip::ZipArchive::new(open(path)?).map_err(|_| "This file is not an IPA.".to_string())?;
    Ok(zip.file_names().map(str::to_string).collect())
}

/// From an IPA's file names: how many bundles besides the app need an App
/// ID of their own (extensions, a watch app), and how many of them Remove
/// extensions takes out (the app's PlugIns/ and Extensions/).
pub fn extension_counts<'a>(names: impl IntoIterator<Item = &'a str>) -> (usize, usize) {
    let dirs: std::collections::BTreeSet<&str> = names.into_iter().filter_map(|n| n.strip_suffix("/Info.plist"))
        .filter(|d| d.starts_with("Payload/")
            && matches!(is_bundle_dir(d.rsplit('/').next().unwrap_or("")), Some(Kind::App | Kind::Extension)))
        .collect();
    let Some(main) = dirs.iter().find(|d| d.matches('/').count() == 1) else { return (0, 0) };
    let (plugins, extensions) = (format!("{main}/PlugIns/"), format!("{main}/Extensions/"));
    let removable = dirs.iter().filter(|d| d.starts_with(&plugins) || d.starts_with(&extensions)).count();
    (dirs.len() - 1, removable)
}

pub fn peek(path: &std::path::Path) -> Result<Peek, String> {
    let mut zip = zip::ZipArchive::new(open(path)?).map_err(|_| "This file is not an IPA.".to_string())?;
    let (extensions, removable) = extension_counts(zip.file_names());
    let name = (0..zip.len()).filter_map(|i| zip.name_for_index(i).map(str::to_string))
        .find(|n| n.starts_with("Payload/") && n.ends_with(".app/Info.plist") && n.matches('/').count() == 2)
        .ok_or("This IPA has no app in Payload/.")?;
    let mut data = Vec::new();
    zip.by_name(&name).map_err(|e| e.to_string())?.read_to_end(&mut data).map_err(|e| e.to_string())?;
    let info = plist::from_bytes::<Value>(&data).ok().and_then(Value::into_dictionary)
        .ok_or("The app's Info.plist cannot be read.")?;
    let text = |k: &str| info.get(k).and_then(Value::as_string).unwrap_or("").to_string();
    let id = text("CFBundleIdentifier");
    if id.is_empty() {
        return Err("The app has no bundle identifier.".into());
    }
    let name = [text("CFBundleDisplayName"), text("CFBundleName"), text("CFBundleExecutable")]
        .into_iter().find(|s| !s.is_empty()).unwrap_or_default();
    Ok(Peek { name, id, version: text("CFBundleShortVersionString"), extensions, removable })
}

/// The app's icon from an IPA file, as it is stored (often an Apple
/// "CgBI" PNG, see `icons::uncrush`): the biggest PNG directly in the app
/// that Info.plist names as an icon (CFBundleIcons, also ~ipad,
/// CFBundleIconFiles, CFBundleIconFile), else one called AppIcon… or Icon….
/// Apps whose icon is only in Assets.car have none here.
pub fn icon(path: &std::path::Path) -> Result<Vec<u8>, String> {
    let mut zip = zip::ZipArchive::new(open(path)?).map_err(|_| "This file is not an IPA.".to_string())?;
    let info_name = zip.file_names()
        .find(|n| n.starts_with("Payload/") && n.ends_with(".app/Info.plist") && n.matches('/').count() == 2)
        .ok_or("This IPA has no app in Payload/.")?.to_string();
    let dir = info_name.trim_end_matches("Info.plist").to_string();
    let mut data = Vec::new();
    zip.by_name(&info_name).map_err(|e| e.to_string())?.take(1 << 20).read_to_end(&mut data).map_err(|e| e.to_string())?;
    let info = plist::from_bytes::<Value>(&data).ok().and_then(Value::into_dictionary).unwrap_or_default();
    let mut names: Vec<String> = Vec::new();
    let mut add = |v: Option<&Value>| match v {
        Some(Value::String(s)) => names.push(s.trim_end_matches(".png").to_string()),
        Some(Value::Array(list)) => names.extend(list.iter().filter_map(Value::as_string)
            .map(|s| s.trim_end_matches(".png").to_string())),
        _ => {}
    };
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        let primary = info.get(key).and_then(Value::as_dictionary).and_then(|d| d.get("CFBundlePrimaryIcon"))
            .and_then(Value::as_dictionary);
        add(primary.and_then(|p| p.get("CFBundleIconFiles")));
        add(primary.and_then(|p| p.get("CFBundleIconName")));
    }
    add(info.get("CFBundleIconFiles"));
    add(info.get("CFBundleIconFile"));
    names.retain(|n| !n.is_empty());
    let pngs: Vec<(String, u64)> = (0..zip.len()).filter_map(|i| {
        let f = zip.by_index_raw(i).ok()?;
        let leaf = f.name().strip_prefix(&dir)?;
        (!leaf.contains('/') && leaf.to_ascii_lowercase().ends_with(".png")).then(|| (f.name().to_string(), f.size()))
    }).collect();
    let leaf = |n: &str| n.rsplit('/').next().unwrap_or("").to_string();
    let named = |n: &&(String, u64)| names.iter().any(|base| leaf(&n.0).starts_with(base.as_str()));
    let guessed = |n: &&(String, u64)| leaf(&n.0).starts_with("AppIcon") || leaf(&n.0).starts_with("Icon");
    let best = pngs.iter().filter(named).filter(|p| p.1 <= 2 << 20).max_by_key(|p| p.1)
        .or_else(|| pngs.iter().filter(guessed).filter(|p| p.1 <= 2 << 20).max_by_key(|p| p.1))
        .ok_or("no icon file in the app")?;
    let mut bytes = Vec::new();
    zip.by_name(&best.0).map_err(|e| e.to_string())?.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    Ok(bytes)
}

impl Ipa {
    /// Reads an IPA. Only what signing changes or reads is kept in memory
    /// (Mach-O files, plists, profiles, symlinks); every other file is hashed
    /// as it is read and later copied from `bytes` as it was, so a big app
    /// does not need its whole unpacked size in memory. Entries are unpacked
    /// and hashed on several threads, the biggest spread first. `progress`
    /// gets the compressed bytes done and their total, from those threads.
    pub fn read(bytes: Vec<u8>, progress: &(dyn Fn(u64, u64) + Sync)) -> Result<Ipa, String> {
        let mut files = BTreeMap::new();
        let mut order = Vec::new();
        {
            let mut zip = zip::ZipArchive::new(Cursor::new(&bytes[..])).map_err(|e| format!("not an IPA (zip): {e}"))?;
            let mut entries = Vec::new();
            for i in 0..zip.len() {
                let f = zip.by_index_raw(i).map_err(|e| e.to_string())?;
                if f.is_dir() {
                    continue;
                }
                let name = f.name().to_string();
                if name.split('/').any(|p| p == "..") || name.starts_with('/') {
                    return Err(format!("unsafe path in IPA: {name}"));
                }
                entries.push((i, f.compressed_size()));
                order.push(name);
            }
            let total: u64 = entries.iter().map(|(_, size)| size).sum();
            let done = AtomicU64::new(0);
            let workers = codesign::workers();
            let mut shares: Vec<(u64, Vec<(usize, u64)>)> = vec![(0, Vec::new()); workers];
            let mut by_size = entries.clone();
            by_size.sort_by_key(|(_, size)| std::cmp::Reverse(*size));
            for (index, size) in by_size {
                let lightest = shares.iter_mut().min_by_key(|(load, _)| *load).expect("one worker");
                lightest.0 += size;
                lightest.1.push((index, size));
            }
            let parts: Vec<Result<Vec<(String, Entry)>, String>> = std::thread::scope(|scope| {
                let handles: Vec<_> = shares.into_iter().map(|(_, share)| {
                    let mut zip = zip.clone();
                    let done = &done;
                    scope.spawn(move || share.into_iter().map(|(i, size)| {
                        let entry = read_entry(&mut zip, i);
                        progress(done.fetch_add(size, Ordering::Relaxed) + size, total);
                        entry
                    }).collect())
                }).collect();
                handles.into_iter().map(|h| h.join().unwrap_or_else(|_| Err("reading the IPA failed".into()))).collect()
            });
            for part in parts {
                for (name, entry) in part? {
                    files.insert(name, entry);
                }
            }
        }
        Ok(Ipa { files, order, source: bytes })
    }

    pub fn bundles(&self) -> Result<Vec<Bundle>, String> {
        let mut dirs: Vec<String> = Vec::new();
        for path in self.files.keys() {
            let parts: Vec<&str> = path.split('/').collect();
            let mut prefix = String::new();
            for p in &parts[..parts.len().saturating_sub(1)] {
                if !prefix.is_empty() {
                    prefix.push('/');
                }
                prefix.push_str(p);
                if is_bundle_dir(p).is_some() && !dirs.contains(&prefix) {
                    dirs.push(prefix.clone());
                }
            }
        }
        let mut out = Vec::new();
        for dir in dirs {
            let Some(info_entry) = self.files.get(&format!("{dir}/Info.plist")) else { continue };
            let Ok(Value::Dictionary(info)) = plist::from_bytes::<Value>(&info_entry.data) else { continue };
            let text = |k: &str| info.get(k).and_then(Value::as_string).unwrap_or("").to_string();
            let executable = text("CFBundleExecutable");
            if executable.is_empty() || !self.files.contains_key(&format!("{dir}/{executable}")) {
                continue;
            }
            let leaf = dir.rsplit('/').next().unwrap_or("");
            out.push(Bundle {
                kind: is_bundle_dir(leaf).unwrap(),
                id: text("CFBundleIdentifier"),
                name: [text("CFBundleDisplayName"), text("CFBundleName"), executable.clone()]
                    .into_iter().find(|s| !s.is_empty()).unwrap_or_default(),
                version: text("CFBundleShortVersionString"),
                executable,
                dir,
                info,
            });
        }
        if !out.iter().any(|b| b.kind == Kind::App && b.dir.starts_with("Payload/") && b.depth() == 1) {
            return Err("no app found in Payload/".into());
        }
        Ok(out)
    }

    pub fn main_app(&self) -> Result<Bundle, String> {
        self.bundles()?.into_iter().find(|b| b.kind == Kind::App && b.depth() == 1)
            .ok_or_else(|| "no app found in Payload/".into())
    }

    /// Removes app extensions (PlugIns/ and Extensions/) of the main app.
    pub fn drop_extensions(&mut self) -> Result<usize, String> {
        let app = self.main_app()?;
        let before = self.files.len();
        let plugins = format!("{}/PlugIns/", app.dir);
        let extensions = format!("{}/Extensions/", app.dir);
        self.files.retain(|p, _| !p.starts_with(&plugins) && !p.starts_with(&extensions));
        self.order.retain(|p| !p.starts_with(&plugins) && !p.starts_with(&extensions));
        Ok(before - self.files.len())
    }

    fn put(&mut self, path: &str, data: Vec<u8>, mode: u32) {
        self.set(path, Entry::new(data, mode, false, None));
    }

    fn set(&mut self, path: &str, entry: Entry) {
        if !self.files.contains_key(path) {
            self.order.push(path.to_string());
        }
        self.files.insert(path.to_string(), entry);
    }

    /// The mode of a file (an executable's when it is new).
    fn mode(&self, path: &str) -> u32 {
        self.files.get(path).map(|e| e.mode).unwrap_or(0o755)
    }

    fn write_info(&mut self, dir: &str, info: &Dictionary) -> Result<(), String> {
        let path = format!("{dir}/Info.plist");
        let binary = self.files.get(&path).map(|e| e.data.starts_with(b"bplist00")).unwrap_or(false);
        let mut out = Vec::new();
        let value = Value::Dictionary(info.clone());
        if binary {
            plist::to_writer_binary(&mut out, &value).map_err(|e| e.to_string())?;
        } else {
            plist::to_writer_xml(&mut out, &value).map_err(|e| e.to_string())?;
        }
        let mode = self.files.get(&path).map(|e| e.mode).unwrap_or(0o644);
        self.put(&path, out, mode);
        Ok(())
    }

    fn code_resources(&self, dir: &str, executable: &str) -> Vec<u8> {
        let prefix = format!("{dir}/");
        let mut files = Dictionary::new();
        let mut files2 = Dictionary::new();
        for (path, entry) in self.files.range(prefix.clone()..) {
            let Some(rel) = path.strip_prefix(&prefix) else { break };
            if rel.starts_with("_CodeSignature/") || rel == executable {
                continue;
            }
            let name = rel.rsplit('/').next().unwrap_or(rel);
            let omit_both = name == ".DS_Store" || rel.ends_with(".lproj/locversion.plist");
            let omit_v2 = rel == "Info.plist" || rel == "PkgInfo";
            if entry.symlink {
                if !omit_v2 && !omit_both {
                    let mut d = Dictionary::new();
                    d.insert("symlink".into(), Value::String(String::from_utf8_lossy(&entry.data).into_owned()));
                    files2.insert(rel.to_string(), Value::Dictionary(d));
                }
                continue;
            }
            let (sha1, sha256) = entry.digests();
            if !omit_both {
                files.insert(rel.to_string(), Value::Data(sha1.clone()));
            }
            if !omit_v2 && !omit_both {
                let mut d = Dictionary::new();
                d.insert("hash2".into(), Value::Data(sha256.clone()));
                files2.insert(rel.to_string(), Value::Dictionary(d));
            }
        }
        let rule = |pairs: &[(&str, Value)]| {
            let mut d = Dictionary::new();
            for (k, v) in pairs {
                d.insert((*k).into(), v.clone());
            }
            Value::Dictionary(d)
        };
        let t = Value::Boolean(true);
        let w = |n: f64| ("weight", Value::Real(n));
        let mut rules = Dictionary::new();
        rules.insert("^.*".into(), t.clone());
        rules.insert("^.*\\.lproj/".into(), rule(&[("optional", t.clone()), w(1000.0)]));
        rules.insert("^.*\\.lproj/locversion.plist$".into(), rule(&[("omit", t.clone()), w(1100.0)]));
        rules.insert("^Base\\.lproj/".into(), rule(&[w(1010.0)]));
        rules.insert("^version.plist$".into(), t.clone());
        let mut rules2 = Dictionary::new();
        rules2.insert(".*\\.dSYM($|/)".into(), rule(&[w(11.0)]));
        rules2.insert("^(.*/)?\\.DS_Store$".into(), rule(&[("omit", t.clone()), w(2000.0)]));
        rules2.insert("^.*".into(), t.clone());
        rules2.insert("^.*\\.lproj/".into(), rule(&[("optional", t.clone()), w(1000.0)]));
        rules2.insert("^.*\\.lproj/locversion.plist$".into(), rule(&[("omit", t.clone()), w(1100.0)]));
        rules2.insert("^Base\\.lproj/".into(), rule(&[w(1010.0)]));
        rules2.insert("^Info\\.plist$".into(), rule(&[("omit", t.clone()), w(20.0)]));
        rules2.insert("^PkgInfo$".into(), rule(&[("omit", t.clone()), w(20.0)]));
        rules2.insert("^embedded\\.provisionprofile$".into(), rule(&[w(20.0)]));
        rules2.insert("^version\\.plist$".into(), rule(&[w(20.0)]));
        let mut top = Dictionary::new();
        top.insert("files".into(), Value::Dictionary(files));
        top.insert("files2".into(), Value::Dictionary(files2));
        top.insert("rules".into(), Value::Dictionary(rules));
        top.insert("rules2".into(), Value::Dictionary(rules2));
        codesign::plist_xml(&Value::Dictionary(codesign::sorted(&top)))
    }

    /// The signed IPA. Unchanged entries are copied over compressed as they
    /// were; the new ones are compressed side by side, each into a zip of its
    /// own, and copied in from there.
    pub fn write(&self) -> Result<Vec<u8>, String> {
        let mut new: Vec<(&String, &Entry)> = self.order.iter()
            .filter_map(|p| self.files.get(p).map(|e| (p, e)))
            .filter(|(_, e)| e.raw.is_none() && !e.symlink).collect();
        new.sort_by_key(|(_, e)| std::cmp::Reverse(e.data.len()));
        let packed: HashMap<&String, Vec<u8>> = new.iter().map(|(p, _)| *p)
            .zip(parallel(&new, |(path, entry)| pack(path, entry))?).collect();
        let mut source = zip::ZipArchive::new(Cursor::new(&self.source[..])).map_err(|e| e.to_string())?;
        let mut out = zip::ZipWriter::new(Cursor::new(Vec::with_capacity(self.source.len() + (1 << 20))));
        for path in &self.order {
            let Some(entry) = self.files.get(path) else { continue };
            if let Some(index) = entry.raw {
                let file = source.by_index_raw(index).map_err(|e| e.to_string())?;
                out.raw_copy_file(file).map_err(|e| e.to_string())?;
            } else if entry.symlink {
                let target = String::from_utf8_lossy(&entry.data).into_owned();
                out.add_symlink(path, target, zip::write::SimpleFileOptions::default())
                    .map_err(|e| e.to_string())?;
            } else {
                let mut one = zip::ZipArchive::new(Cursor::new(&packed[path][..])).map_err(|e| e.to_string())?;
                out.raw_copy_file(one.by_index_raw(0).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            }
        }
        Ok(out.finish().map_err(|e| e.to_string())?.into_inner())
    }
}

/// One new entry as a zip of its own (deflated, level 1).
fn pack(path: &str, entry: &Entry) -> Result<Vec<u8>, String> {
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .compression_level(Some(1))
        .unix_permissions(entry.mode & 0o7777);
    let mut one = zip::ZipWriter::new(Cursor::new(Vec::with_capacity(entry.data.len() / 2 + 512)));
    one.start_file(path, options).map_err(|e| e.to_string())?;
    one.write_all(&entry.data).map_err(|e| e.to_string())?;
    Ok(one.finish().map_err(|e| e.to_string())?.into_inner())
}

/// `f` over `items` on up to `codesign::workers()` threads (Minis runs each
/// on its own core), the results in the items' order; the first error wins.
fn parallel<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> Result<R, String> + Sync) -> Result<Vec<R>, String> {
    let threads = codesign::workers().min(items.len());
    if threads < 2 {
        return items.iter().map(f).collect();
    }
    let next = AtomicUsize::new(0);
    let mut results: Vec<(usize, Result<R, String>)> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..threads).map(|_| scope.spawn(|| {
            let mut mine = Vec::new();
            loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                let Some(item) = items.get(i) else { break mine };
                mine.push((i, f(item)));
            }
        })).collect();
        handles.into_iter()
            .flat_map(|h| h.join().unwrap_or_else(|_| vec![(usize::MAX, Err("a signing thread failed".into()))]))
            .collect()
    });
    results.sort_by_key(|(i, _)| *i);
    results.into_iter().map(|(_, r)| r).collect()
}

/// One entry of the archive: kept whole when signing needs its bytes, else
/// only hashed.
fn read_entry(zip: &mut zip::ZipArchive<Cursor<&[u8]>>, i: usize) -> Result<(String, Entry), String> {
    let mut f = zip.by_index(i).map_err(|e| e.to_string())?;
    let name = f.name().to_string();
    let mode = f.unix_mode().unwrap_or(0o644);
    let symlink = mode & 0o170000 == 0o120000;
    let mut head = [0u8; 4];
    let mut got = 0;
    while got < 4 {
        let n = f.read(&mut head[got..]).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        got += n;
    }
    let keep = symlink || codesign::is_macho(&head[..got]) || name.ends_with(".plist") || name.ends_with(".mobileprovision");
    if keep {
        let mut data = Vec::with_capacity(f.size() as usize);
        data.extend_from_slice(&head[..got]);
        f.read_to_end(&mut data).map_err(|e| e.to_string())?;
        return Ok((name, Entry::new(data, mode, symlink, Some(i))));
    }
    let (mut sha1, mut sha256) = (Sha1::new(), Sha256::new());
    sha1.update(&head[..got]);
    sha256.update(&head[..got]);
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        sha1.update(&buf[..n]);
        sha256.update(&buf[..n]);
    }
    Ok((name, Entry::hashed(mode, i, (sha1.finalize().to_vec(), sha256.finalize().to_vec()))))
}

/// The icon files a picture of the user's becomes, at the sizes iOS shows
/// an app's icon on an iPhone (60 pt @2x, @3x) and an iPad (76 pt, 83.5 pt).
const ICON_FILES: [(&str, u32); 4] = [("BariStoreIcon60x60@2x.png", 120), ("BariStoreIcon60x60@3x.png", 180),
                                       ("BariStoreIcon76x76@2x~ipad.png", 152), ("BariStoreIcon83.5x83.5@2x~ipad.png", 167)];

/// Replaces the app's icon with `picture` (a square PNG or JPEG): icon files
/// at each size in the app, named in Info.plist (CFBundleIcons and ~ipad).
/// The asset catalog's icon (CFBundleIconName) is no longer named, so iOS
/// takes these files; alternate icons stay.
pub fn replace_icon(ipa: &mut Ipa, app: &Bundle, picture: &[u8]) -> Result<(), String> {
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(2048);
    limits.max_image_height = Some(2048);
    let mut reader = image::ImageReader::new(Cursor::new(picture)).with_guessed_format().map_err(|e| e.to_string())?;
    reader.limits(limits);
    let img = reader.decode().map_err(|e| format!("the icon cannot be read: {e}"))?;
    let side = img.width().min(img.height());
    let img = img.crop_imm((img.width() - side) / 2, (img.height() - side) / 2, side, side);
    for (name, px) in ICON_FILES {
        let small = image::DynamicImage::ImageRgb8(img.resize_exact(px, px, image::imageops::FilterType::Lanczos3).into_rgb8());
        let mut png = Cursor::new(Vec::new());
        small.write_to(&mut png, image::ImageFormat::Png).map_err(|e| e.to_string())?;
        ipa.put(&format!("{}/{name}", app.dir), png.into_inner(), 0o644);
    }
    let names = |list: &[&str]| Value::Array(list.iter().map(|n| Value::String(n.to_string())).collect());
    let mut info = ipa.files.get(&format!("{}/Info.plist", app.dir))
        .and_then(|e| plist::from_bytes::<Value>(&e.data).ok()).and_then(Value::into_dictionary)
        .ok_or("the app's Info.plist cannot be read")?;
    for (key, files) in [("CFBundleIcons", names(&["BariStoreIcon60x60"])),
                         ("CFBundleIcons~ipad", names(&["BariStoreIcon60x60", "BariStoreIcon76x76", "BariStoreIcon83.5x83.5"]))] {
        let mut icons = info.get(key).and_then(Value::as_dictionary).cloned().unwrap_or_default();
        let mut primary = Dictionary::new();
        primary.insert("CFBundleIconFiles".into(), files);
        icons.insert("CFBundlePrimaryIcon".into(), Value::Dictionary(primary));
        info.insert(key.into(), Value::Dictionary(icons));
    }
    for key in ["CFBundleIconFiles", "CFBundleIconFile", "CFBundleIconName"] {
        info.remove(key);
    }
    ipa.write_info(&app.dir, &info)
}

/// The plist inside a .mobileprovision (CMS-wrapped).
pub fn profile_plist(profile: &[u8]) -> Result<Dictionary, String> {
    let start = profile.windows(5).position(|w| w == b"<?xml").ok_or("profile has no plist")?;
    let end = profile.windows(8).rposition(|w| w == b"</plist>").ok_or("profile has no plist end")? + 8;
    plist::from_bytes::<Value>(&profile[start..end]).map_err(|e| e.to_string())?
        .into_dictionary().ok_or_else(|| "profile plist is not a dictionary".into())
}

/// Signs every bundle in `ipa` according to `plan`, then self-checks.
pub fn sign(ipa: &mut Ipa, plan: &Plan, progress: &mut dyn FnMut(usize, usize)) -> Result<(), String> {
    for (path, data) in &plan.add_files {
        ipa.put(path, data.clone(), 0o644);
    }
    let mut bundles = ipa.bundles()?;
    // Identifier rewrites and Info.plist edits first: parents seal children.
    for b in bundles.iter_mut() {
        let mut info = b.info.clone();
        let mut changed = false;
        if let Some(s) = plan.bundles.get(&b.dir) {
            if b.id != s.new_id {
                info.insert("CFBundleIdentifier".into(), Value::String(s.new_id.clone()));
                if let Some(Value::Array(tasks)) = info.get("BGTaskSchedulerPermittedIdentifiers").cloned() {
                    let old = b.id.clone();
                    let new = s.new_id.clone();
                    let tasks = tasks.into_iter().map(|t| match t {
                        Value::String(x) => Value::String(x.replacen(&old, &new, 1)),
                        other => other,
                    }).collect();
                    info.insert("BGTaskSchedulerPermittedIdentifiers".into(), Value::Array(tasks));
                }
                b.id = s.new_id.clone();
                changed = true;
            }
        }
        if let Some(edits) = plan.info_edits.get(&b.dir) {
            for (k, v) in edits {
                info.insert(k.clone(), v.clone());
            }
            changed = true;
        }
        if changed {
            ipa.write_info(&b.dir, &info)?;
            b.info = info;
        }
    }
    if let Some(b) = bundles.iter().find(|b| b.kind != Kind::Framework && !plan.bundles.contains_key(&b.dir)) {
        return Err(format!("no profile was prepared for {} ({})", b.name, b.id));
    }
    let dirs: Vec<String> = bundles.iter().map(|b| b.dir.clone()).collect();
    let mut depths: Vec<usize> = bundles.iter().map(Bundle::depth).collect();
    depths.sort_unstable();
    depths.dedup();
    let (total, mut done) = (bundles.len(), 0);
    // Deepest first (parents seal their children), a depth at a time: the
    // bundles of one depth never contain one another, so their binaries are
    // signed side by side, and hashed for their parents' seal right there.
    for depth in depths.into_iter().rev() {
        let level: Vec<&Bundle> = bundles.iter().filter(|b| b.depth() == depth).collect();
        for b in &level {
            if let Some(s) = plan.bundles.get(&b.dir) {
                ipa.put(&format!("{}/embedded.mobileprovision", b.dir), s.profile.clone(), 0o644);
            }
        }
        // Loose Mach-O files (dylibs, helpers) of these bundles, biggest first.
        let mut loose: Vec<(&String, &Entry)> = level.iter().flat_map(|b| {
            let prefix = format!("{}/", b.dir);
            let main = format!("{}/{}", b.dir, b.executable);
            let nested: Vec<String> = dirs.iter().filter(|d| d.starts_with(&prefix)).map(|d| format!("{d}/")).collect();
            ipa.files.range(prefix.clone()..).take_while(move |(p, _)| p.starts_with(&prefix))
                .filter(move |(p, e)| **p != main && !e.symlink && !nested.iter().any(|d| p.starts_with(d))
                        && codesign::is_macho(&e.data))
                .collect::<Vec<_>>()
        }).collect();
        loose.sort_by_key(|(_, e)| std::cmp::Reverse(e.data.len()));
        let signed = parallel(&loose, |(path, entry)| {
            let name = path.rsplit('/').next().unwrap_or("");
            let identifier = match codesign::macho_uuid(&entry.data) {
                Some(u) => format!("{name}-{u}"),
                None => name.to_string(),
            };
            let target = Target { identifier: &identifier, entitlements: None, info_plist: None, code_resources: None };
            let signed = codesign::sign_macho(&entry.data, &target, &plan.identity).map_err(|e| format!("{path}: {e}"))?;
            Ok(((*path).clone(), Entry::hashed_now(signed, entry.mode)))
        })?;
        for (path, entry) in signed {
            ipa.set(&path, entry);
        }
        // Each bundle's seal, then its executable.
        let sealed = parallel(&level, |b| {
            let resources = ipa.code_resources(&b.dir, &b.executable);
            let info = ipa.files.get(&format!("{}/Info.plist", b.dir)).map(|e| e.data.as_slice());
            let target = Target { identifier: &b.id, entitlements: plan.bundles.get(&b.dir).map(|s| &s.entitlements),
                                  info_plist: info, code_resources: Some(&resources) };
            let main = format!("{}/{}", b.dir, b.executable);
            let signed = codesign::sign_macho(&ipa.files[&main].data, &target, &plan.identity)
                .map_err(|e| format!("{main}: {e}"))?;
            Ok((b.dir.clone(), resources, main, signed))
        })?;
        for (dir, resources, main, signed) in sealed {
            let path = format!("{dir}/_CodeSignature/CodeResources");
            let mode = ipa.files.get(&path).map(|e| e.mode).unwrap_or(0o644);
            ipa.set(&path, Entry::hashed_now(resources, mode));
            // The app's own executable is sealed by no one: not hashed.
            let mode = ipa.mode(&main);
            ipa.set(&main, if depth > 1 { Entry::hashed_now(signed, mode) } else { Entry::new(signed, mode, false, None) });
        }
        done += level.len();
        progress(done, total);
    }
    verify(ipa)
}

/// Checks the Info.plist and CodeResources slots of each main executable
/// against the final bytes: a bundle edited after it was signed fails here,
/// before an install. (Page hashes are not hashed a second time: on a big
/// app that doubled the signing time.)
pub fn verify(ipa: &Ipa) -> Result<(), String> {
    for b in ipa.bundles()? {
        let main = format!("{}/{}", b.dir, b.executable);
        let data = &ipa.files[&main].data;
        let slice = thin_arm64(data).ok_or_else(|| format!("{main}: no arm64 slice"))?;
        let cd = code_directory_of(slice).ok_or_else(|| format!("{main}: no CodeDirectory"))?;
        let be = |o: usize| u32::from_be_bytes(cd[o..o + 4].try_into().unwrap()) as usize;
        let (hash_off, special) = (be(16), be(24));
        let slot = |n: usize| (n <= special).then(|| &cd[hash_off - n * 32..hash_off - n * 32 + 32]);
        if let (Some(want), Some(info)) = (slot(1), ipa.files.get(&format!("{}/Info.plist", b.dir))) {
            if Sha256::digest(&info.data).as_slice() != want {
                return Err(format!("{main}: Info.plist slot mismatch"));
            }
        }
        if let (Some(want), Some(res)) = (slot(3), ipa.files.get(&format!("{}/_CodeSignature/CodeResources", b.dir))) {
            if Sha256::digest(&res.data).as_slice() != want {
                return Err(format!("{main}: CodeResources slot mismatch"));
            }
        }
    }
    Ok(())
}

fn thin_arm64(data: &[u8]) -> Option<&[u8]> {
    if data.get(..4)? == [0xCF, 0xFA, 0xED, 0xFE] {
        return Some(data);
    }
    if data.get(..4)? != [0xCA, 0xFE, 0xBA, 0xBE] {
        return None;
    }
    let be = |o: usize| u32::from_be_bytes(data[o..o + 4].try_into().unwrap());
    for i in 0..be(4) as usize {
        let b = 8 + i * 20;
        if be(b) == 0x0100000C {
            return data.get(be(b + 8) as usize..(be(b + 8) + be(b + 12)) as usize);
        }
    }
    None
}

fn code_directory_of(m: &[u8]) -> Option<&[u8]> {
    let le = |o: usize| u32::from_le_bytes(m[o..o + 4].try_into().unwrap());
    let ncmds = le(16) as usize;
    let mut off = 32;
    for _ in 0..ncmds {
        if le(off) == 0x1D {
            let (dataoff, size) = (le(off + 8) as usize, le(off + 12) as usize);
            let sb = m.get(dataoff..dataoff + size)?;
            let be = |o: usize| u32::from_be_bytes(sb[o..o + 4].try_into().unwrap());
            for i in 0..be(8) as usize {
                if be(12 + i * 8) == 0 {
                    let at = be(16 + i * 8) as usize;
                    let len = u32::from_be_bytes(sb[at + 4..at + 8].try_into().unwrap()) as usize;
                    return sb.get(at..at + len);
                }
            }
        }
        off += le(off + 4) as usize;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sign::codesign::tests::{blob_at, identity, macho};

    fn info(id: &str, exe: &str, extra: &[(&str, Value)]) -> Vec<u8> {
        let mut d = Dictionary::new();
        d.insert("CFBundleIdentifier".into(), Value::String(id.into()));
        d.insert("CFBundleExecutable".into(), Value::String(exe.into()));
        for (k, v) in extra {
            d.insert((*k).into(), v.clone());
        }
        codesign::plist_xml(&Value::Dictionary(d))
    }

    /// An app with a framework, a loose dylib and a resource, signed (the
    /// binaries of a depth side by side), a picture made its icon, packed
    /// (new entries compressed side by side) and read back.
    #[test]
    fn signs_and_packs_an_app() {
        let mut primary = Dictionary::new();
        primary.insert("CFBundleIconName".into(), Value::String("AppIcon".into()));
        let mut icons = Dictionary::new();
        icons.insert("CFBundlePrimaryIcon".into(), Value::Dictionary(primary));
        let files: Vec<(&str, Vec<u8>, u32)> = vec![
            ("Payload/A.app/Info.plist", info("com.a", "A", &[("CFBundleIcons", Value::Dictionary(icons))]), 0o644),
            ("Payload/A.app/A", macho(0x8000), 0o755),
            ("Payload/A.app/res.txt", b"resource".repeat(5000), 0o644),
            ("Payload/A.app/Frameworks/libx.dylib", macho(0xC000), 0o755),
            ("Payload/A.app/Frameworks/F.framework/Info.plist", info("com.f", "F", &[]), 0o644),
            ("Payload/A.app/Frameworks/F.framework/F", macho(0x8000), 0o755),
        ];
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, data, mode) in &files {
            let opts = zip::write::SimpleFileOptions::default().unix_permissions(*mode);
            zip.start_file(*name, opts).unwrap();
            zip.write_all(data).unwrap();
        }
        let bytes = zip.finish().unwrap().into_inner();
        let reported = std::sync::Mutex::new(0);
        let mut ipa = Ipa::read(bytes, &|done, total| *reported.lock().unwrap() = done * 100 / total).unwrap();
        assert_eq!(*reported.lock().unwrap(), 100);
        let main = ipa.main_app().unwrap();
        let mut picture = Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(600, 400, image::Rgba([200, 30, 30, 255]))
            .write_to(&mut picture, image::ImageFormat::Png).unwrap();
        replace_icon(&mut ipa, &main, picture.get_ref()).unwrap();
        let mut ent = Dictionary::new();
        ent.insert("application-identifier".into(), Value::String("T.com.a.T".into()));
        let plan = Plan {
            identity: identity(),
            bundles: HashMap::from([("Payload/A.app".to_string(),
                                     Signing { new_id: "com.a.T".into(), profile: b"profile".to_vec(), entitlements: ent })]),
            info_edits: HashMap::new(),
            add_files: vec![],
        };
        let mut steps = Vec::new();
        sign(&mut ipa, &plan, &mut |n, t| steps.push((n, t))).unwrap();
        assert_eq!(steps.last(), Some(&(2, 2)));
        let out = ipa.write().unwrap();
        let mut back = zip::ZipArchive::new(Cursor::new(&out[..])).unwrap();
        let mut read = |name: &str| {
            let mut f = back.by_name(name).unwrap_or_else(|_| panic!("{name} missing"));
            let mode = f.unix_mode().unwrap_or(0) & 0o777;
            let mut data = Vec::new();
            f.read_to_end(&mut data).unwrap();
            (data, mode)
        };
        let (exe, mode) = read("Payload/A.app/A");
        assert_eq!(mode, 0o755);
        let info: Dictionary = plist::from_bytes(&read("Payload/A.app/Info.plist").0).unwrap();
        assert_eq!(info["CFBundleIdentifier"].as_string(), Some("com.a.T"));
        let primary = info["CFBundleIcons"].as_dictionary().unwrap()["CFBundlePrimaryIcon"].as_dictionary().unwrap();
        assert!(primary.get("CFBundleIconName").is_none());
        assert_eq!(primary["CFBundleIconFiles"].as_array().unwrap()[0].as_string(), Some("BariStoreIcon60x60"));
        for (name, px) in ICON_FILES {
            let icon = image::load_from_memory(&read(&format!("Payload/A.app/{name}")).0).unwrap();
            assert_eq!((icon.width(), icon.height()), (px, px));
        }
        let resources: Dictionary = plist::from_bytes(&read("Payload/A.app/_CodeSignature/CodeResources").0).unwrap();
        let files2 = resources["files2"].as_dictionary().unwrap();
        let hash = |name: &str| files2[name].as_dictionary().unwrap()["hash2"].as_data().unwrap().to_vec();
        assert_eq!(hash("res.txt"), Sha256::digest(b"resource".repeat(5000)).to_vec());
        assert_eq!(hash("Frameworks/libx.dylib"), Sha256::digest(read("Payload/A.app/Frameworks/libx.dylib").0).to_vec());
        assert_eq!(hash("Frameworks/F.framework/F"), Sha256::digest(read("Payload/A.app/Frameworks/F.framework/F").0).to_vec());
        assert_eq!(hash("BariStoreIcon60x60@3x.png"),
                   Sha256::digest(read("Payload/A.app/BariStoreIcon60x60@3x.png").0).to_vec());
        assert!(blob_at(&exe, 0x10000).is_some());
        assert_eq!(read("Payload/A.app/res.txt").0, b"resource".repeat(5000));
    }
}
