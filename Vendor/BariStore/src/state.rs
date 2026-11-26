//! Where BariStore keeps its files, its settings, and how secrets are
//! written.

use std::io::Write;
use std::path::{Path, PathBuf};

/// `$BARISTORE_HOME`, else `~/.baristore`.
pub fn home() -> PathBuf {
    if let Some(dir) = std::env::var_os("BARISTORE_HOME") {
        return PathBuf::from(dir);
    }
    let base = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    base.join(".baristore")
}

pub fn path(name: &str) -> PathBuf {
    home().join(name)
}

/// Writes `data` atomically with mode 0600 (pairing records, sessions, keys).
pub fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut file = std::fs::OpenOptions::new()
            .write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        file.write_all(data)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

/// What settings.json may hold, with the defaults: the page's theme, the
/// install defaults, whether setup is done, the anisette server chosen in
/// Options ("" = automatic) and the anisette servers the user added.
fn defaults() -> serde_json::Value {
    serde_json::json!({"theme": "system", "increased_memory": false, "remove_extensions": false,
                       "setup_done": false, "anisette": "", "anisette_servers": []})
}

pub fn settings() -> serde_json::Value {
    let mut s = defaults();
    let saved: serde_json::Value = std::fs::read(path("settings.json")).ok()
        .and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    merge(&mut s, &saved);
    s
}

/// Known keys of `patch` replace the saved ones.
pub fn save_settings(patch: &serde_json::Value) {
    let mut s = settings();
    merge(&mut s, patch);
    let _ = std::fs::write(path("settings.json"), s.to_string());
}

fn merge(into: &mut serde_json::Value, from: &serde_json::Value) {
    if let (Some(obj), Some(from)) = (into.as_object_mut(), from.as_object()) {
        for (k, v) in from {
            if obj.get(k).is_some_and(|d| std::mem::discriminant(d) == std::mem::discriminant(v)) {
                obj.insert(k.clone(), v.clone());
            }
        }
    }
}
