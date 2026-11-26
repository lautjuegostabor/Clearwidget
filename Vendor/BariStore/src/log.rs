//! One log for everything: timestamped lines in ~/.baristore/baristore.log
//! (its newest part only, see `trim`), and the last lines in memory for the
//! page and `baristore log`.

use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static RECENT: Mutex<Vec<String>> = Mutex::new(Vec::new());
const KEEP: usize = 400;
/// A log file longer than this is cut to its last TRIMMED bytes.
const MAX_FILE: u64 = 2 << 20;
const TRIMMED: u64 = 512 << 10;
static WRITTEN: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Cuts a log file (baristore.log, server.out) that grew past MAX_FILE to
/// its last lines: both were only ever appended to.
pub fn trim(path: &std::path::Path) {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = std::fs::File::open(path) else { return };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    if len <= MAX_FILE || file.seek(SeekFrom::Start(len - TRIMMED)).is_err() {
        return;
    }
    let mut tail = Vec::new();
    if file.read_to_end(&mut tail).is_err() {
        return;
    }
    let start = tail.iter().position(|b| *b == b'\n').map_or(0, |p| p + 1);
    let _ = crate::state::write_private(path, &tail[start..]);
}

pub fn stamp() -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = now.as_secs();
    let (h, m, s) = ((secs / 3600) % 24, (secs / 60) % 60, secs % 60);
    format!("{h:02}:{m:02}:{s:02}.{:03}Z", now.subsec_millis())
}

pub fn line(text: impl AsRef<str>) {
    let entry = format!("{} {}", stamp(), text.as_ref());
    if std::env::var_os("BARISTORE_ECHO").is_some() {
        eprintln!("{entry}");
    }
    let path = crate::state::path("baristore.log");
    if WRITTEN.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % 1000 == 0 {
        trim(&path);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "{entry}");
    }
    let mut recent = RECENT.lock().unwrap_or_else(|e| e.into_inner());
    recent.push(entry);
    if recent.len() > KEEP {
        let extra = recent.len() - KEEP;
        recent.drain(..extra);
    }
}

pub fn recent() -> Vec<String> {
    RECENT.lock().map(|r| r.clone()).unwrap_or_default()
}

#[macro_export]
macro_rules! logf {
    ($($arg:tt)*) => { $crate::log::line(format!($($arg)*)) };
}

#[cfg(test)]
mod tests {
    #[test]
    fn long_logs_keep_their_last_lines() {
        let path = std::env::temp_dir().join(format!("baristore-log-{}", std::process::id()));
        let text: String = (0..300_000).map(|n| format!("line {n}\n")).collect();
        std::fs::write(&path, &text).unwrap();
        super::trim(&path);
        let kept = std::fs::read_to_string(&path).unwrap();
        let _ = std::fs::remove_file(&path);
        assert!(kept.len() as u64 <= super::TRIMMED && kept.len() > 400_000);
        assert!(kept.starts_with("line ") && kept.ends_with("line 299999\n") && text.ends_with(&kept));
    }
}
