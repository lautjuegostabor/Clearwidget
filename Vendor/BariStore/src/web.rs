//! The page: a tiny HTTP/1.1 server on 127.0.0.1 under a 128-bit random path
//! (other apps and websites on the iPhone can reach a loopback port, but not
//! guess the path), Host checked against the loopback (no DNS rebinding).
//! Shown in Minis's browser sheet with minis-open. A file handed to another
//! app (Install to LiveContainer) has an address of its own, see `Share`.

use serde_json::{json, Value as Json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::app::App;
use crate::install::Options;
use crate::logf;

const PAGE: &str = include_str!("../ui/index.html");
const LOGO: &[u8] = include_bytes!("../assets/baristore.svg");

/// Serves the page on 127.0.0.1:`port` under /`token`/ (both chosen by the
/// supervisor, so a restarted server keeps the page's address).
pub async fn serve(app: App, port: u16, token: &str) -> Result<(), String> {
    let _ = PORT.set(port);
    let mut tries = 0;
    let listener = loop {
        match TcpListener::bind(("127.0.0.1", port)).await {
            Ok(l) => break l,
            Err(e) if tries < 20 => {
                tries += 1;
                logf!("web: port {port}: {e}; retrying");
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            }
            Err(e) => return Err(format!("cannot serve the page on port {port}: {e}")),
        }
    };
    let prefix = format!("/{token}");
    let rebind = std::sync::Arc::new(tokio::sync::Notify::new());
    tokio::spawn(self_check(app.clone(), port, token.to_string(), rebind.clone()));
    tokio::spawn(async move {
        let mut listener = listener;
        let mut errors = 0u32;
        loop {
            let accepted = tokio::select! {
                accepted = listener.accept() => accepted,
                // The self-check found the address dead: rebuild at once.
                _ = rebind.notified() => {
                    errors = 4;
                    Err(std::io::Error::other("the page's address does not answer"))
                }
            };
            let (stream, _) = match accepted {
                Ok(accepted) => {
                    errors = 0;
                    accepted
                }
                Err(e) => {
                    // iOS can take a suspended app's sockets away; a listener
                    // that only fails is replaced by a new one on the port.
                    errors += 1;
                    logf!("web: accept: {e}");
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                    if errors >= 5 {
                        drop(listener);
                        listener = loop {
                            match TcpListener::bind(("127.0.0.1", port)).await {
                                Ok(l) => break l,
                                Err(e) => {
                                    logf!("web: cannot listen again on {port}: {e}");
                                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                                }
                            }
                        };
                        logf!("web: listening again on port {port}");
                        errors = 0;
                    }
                    continue;
                }
            };
            let app = app.clone();
            let prefix = prefix.clone();
            tokio::spawn(async move {
                let _ = handle(stream, app, &prefix, port).await;
            });
        }
    });
    Ok(())
}

/// Asks the page's own address every few seconds, as the page does. After
/// Minis was suspended iOS may have taken the listening socket without
/// accept() ever failing: then the page waits in vain. Two misses rebuild
/// the listener; still nothing after that, and no task running, the server
/// exits and its supervisor starts it again at once.
async fn self_check(app: App, port: u16, token: String, rebind: std::sync::Arc<tokio::sync::Notify>) {
    use std::time::{Duration, Instant};
    let mut misses = 0u32;
    let mut last = Instant::now();
    loop {
        tokio::time::sleep(Duration::from_secs(3)).await;
        // Late by far: Minis was suspended; judge only from now on.
        if last.elapsed() > Duration::from_secs(8) {
            misses = 0;
        }
        let answered = tokio::time::timeout(Duration::from_secs(3), async {
            let mut s = TcpStream::connect(("127.0.0.1", port)).await.ok()?;
            s.write_all(format!("GET /{token}/api/ping HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n").as_bytes())
                .await.ok()?;
            let mut head = [0u8; 12];
            s.read_exact(&mut head).await.ok()?;
            (&head == b"HTTP/1.1 200").then_some(())
        }).await.ok().flatten().is_some();
        last = Instant::now();
        if answered {
            misses = 0;
            continue;
        }
        misses += 1;
        logf!("web: the page's address did not answer ({misses})");
        if misses == 2 {
            rebind.notify_one();
        } else if misses >= 4 && !app.busy() {
            logf!("web: still no answer; exiting so the supervisor starts a new server");
            std::process::exit(1);
        }
    }
}

async fn respond(stream: &mut TcpStream, status: &str, kind: &str, body: &[u8]) -> std::io::Result<()> {
    respond_cached(stream, status, kind, body, "no-store").await
}

async fn respond_cached(stream: &mut TcpStream, status: &str, kind: &str, body: &[u8], cache: &str)
    -> std::io::Result<()>
{
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: {cache}\r\n\
         X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n", body.len());
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await
}

async fn handle(mut stream: TcpStream, app: App, prefix: &str, port: u16) -> std::io::Result<()> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break p + 4;
        }
        if buf.len() > 64 * 1024 {
            return respond(&mut stream, "431 Too Large", "text/plain", b"").await;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.split("\r\n");
    let request = lines.next().unwrap_or("");
    let mut parts = request.split(' ');
    let (method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    let mut host = "";
    let mut length = 0usize;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            match k.trim().to_ascii_lowercase().as_str() {
                "host" => host = v.trim(),
                "content-length" => length = v.trim().parse().unwrap_or(0),
                _ => {}
            }
        }
    }
    if host != format!("127.0.0.1:{port}") && host != format!("localhost:{port}") {
        return respond(&mut stream, "403 Forbidden", "text/plain", b"").await;
    }
    if let (Some(rest), "GET") = (path.strip_prefix("/share/"), method) {
        return send_share(&mut stream, rest).await;
    }
    let Some(route) = path.strip_prefix(prefix) else {
        return respond(&mut stream, "404 Not Found", "text/plain", b"").await;
    };
    if method == "POST" && route.starts_with("/api/upload-icon") {
        // A picture for an app's icon (the page sends it square, 512 px).
        if length > 4 << 20 {
            return respond(&mut stream, "413 Too Large", "text/plain", b"").await;
        }
        let mut body = buf[header_end..].to_vec();
        while body.len() < length {
            let n = stream.read(&mut chunk).await?;
            if n == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..n]);
        }
        let reply = match tokio::task::block_in_place(|| crate::icons::save_custom_icon(&body)) {
            Ok(name) => json!({"ok": true, "icon": name, "url": crate::icons::custom_icon_url(&name)}),
            Err(e) => json!({"ok": false, "message": e}),
        };
        return respond(&mut stream, "200 OK", "application/json", reply.to_string().as_bytes()).await;
    }
    if method == "POST" && route.starts_with("/api/upload") {
        let reply = upload(&mut stream, &buf[header_end..], length).await;
        return respond(&mut stream, "200 OK", "application/json", reply.to_string().as_bytes()).await;
    }
    if length > 1 << 20 {
        return respond(&mut stream, "413 Too Large", "text/plain", b"").await;
    }
    let mut body = buf[header_end..].to_vec();
    while body.len() < length {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    let (route, query) = route.split_once('?').unwrap_or((route, ""));
    match (method, route) {
        ("GET", "/icon") => {
            let url = query.split('&').find_map(|p| p.strip_prefix("u=")).map(percent_decode).unwrap_or_default();
            let size = query.split('&').find_map(|p| p.strip_prefix("s=")).and_then(|v| v.parse().ok())
                .unwrap_or(crate::icons::ICON);
            match crate::icons::get(&crate::store::client(), &url, size).await {
                Ok(bytes) => respond_cached(&mut stream, "200 OK", crate::icons::kind(&bytes), &bytes,
                                            "private, max-age=604800").await,
                Err(_) => respond(&mut stream, "404 Not Found", "text/plain", b"").await,
            }
        }
        ("GET", "/") | ("GET", "") => respond(&mut stream, "200 OK", "text/html; charset=utf-8", PAGE.as_bytes()).await,
        ("GET", "/logo.svg") => respond(&mut stream, "200 OK", "image/svg+xml", LOGO).await,
        // The supervisor's check that this server still answers.
        ("GET", "/api/ping") => {
            let s = json!({"boot": crate::app::boot_id(), "busy": app.busy()}).to_string();
            respond(&mut stream, "200 OK", "application/json", s.as_bytes()).await
        }
        ("GET", "/api/state") => {
            let s = app.snapshot().to_string();
            respond(&mut stream, "200 OK", "application/json", s.as_bytes()).await
        }
        ("GET", "/api/catalog") => {
            let s = app.catalog().to_string();
            respond(&mut stream, "200 OK", "application/json", s.as_bytes()).await
        }
        ("POST", "/api/action") => {
            let request: Json = serde_json::from_slice(&body).unwrap_or(Json::Null);
            let reply = action(&app, &request).await;
            respond(&mut stream, "200 OK", "application/json", reply.to_string().as_bytes()).await
        }
        _ => respond(&mut stream, "404 Not Found", "text/plain", b"").await,
    }
}

/// Add IPA: the page sends the file's bytes as the request body. They go
/// straight to ~/.baristore/ipas/ (never all in memory), then the app inside
/// is read for the install sheet. The socket is read in big pieces, and
/// each piece is written with `block_in_place`: a slow disk must not hold
/// up the worker the page's other requests need.
async fn upload(stream: &mut TcpStream, first: &[u8], length: usize) -> Json {
    use std::io::Write;
    const PIECE: usize = 4 << 20;
    let fail = |m: &str| json!({"ok": false, "message": m});
    if length == 0 {
        return fail("The file is empty.");
    }
    let started = std::time::Instant::now();
    let dir = crate::state::path("ipas");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join(format!("added-{}.ipa", hex::encode(rand::random::<[u8; 6]>())));
    let Ok(mut file) = std::fs::File::create(&path) else { return fail("Cannot save the file.") };
    let mut piece = vec![0u8; PIECE];
    let mut filled = first.len().min(length);
    piece[..filled].copy_from_slice(&first[..filled]);
    let mut received = filled;
    let mut saved = true;
    while received < length {
        let want = (PIECE - filled).min(length - received);
        let n = stream.read(&mut piece[filled..filled + want]).await.unwrap_or(0);
        if n == 0 {
            break;
        }
        filled += n;
        received += n;
        if filled == PIECE {
            saved = tokio::task::block_in_place(|| file.write_all(&piece)).is_ok();
            filled = 0;
            if !saved {
                break;
            }
        }
    }
    if saved && filled > 0 {
        saved = tokio::task::block_in_place(|| file.write_all(&piece[..filled])).is_ok();
    }
    drop(file);
    if !saved {
        let _ = std::fs::remove_file(&path);
        return fail("Cannot save the file (is the iPhone full?).");
    }
    if received < length {
        let _ = std::fs::remove_file(&path);
        return fail("The upload stopped before the end.");
    }
    let secs = started.elapsed().as_secs_f64();
    match tokio::task::block_in_place(|| crate::sign::bundle::peek(&path)) {
        Ok(info) => {
            logf!("upload: {} {} ({} MB in {secs:.1} s)", info.id, info.version, length / 1_000_000);
            json!({"ok": true, "path": path.to_string_lossy(), "name": info.name, "bundle_id": info.id,
                   "version": info.version, "size": length, "icon_url": crate::icons::ipa_icon_url(&path),
                   "info": {"extensions": info.extensions, "removable": info.removable}})
        }
        Err(e) => {
            let _ = std::fs::remove_file(&path);
            fail(&e)
        }
    }
}

/// The port the page is served on (for the addresses of shared files).
static PORT: OnceLock<u16> = OnceLock::new();

/// What a share has sent: the bytes of its latest request, and whether one
/// request got the whole file.
#[derive(Default)]
struct Sent {
    bytes: AtomicU64,
    whole: AtomicBool,
}

/// Shared files by their random id: the file and its size.
type Shares = Mutex<HashMap<String, (std::path::PathBuf, u64, Arc<Sent>)>>;
static SHARES: std::sync::LazyLock<Shares> = std::sync::LazyLock::new(Default::default);

/// A file handed to another app on this iPhone by address (Install to
/// LiveContainer: LiveContainer downloads it like any other IPA). Served at
/// /share/<128-bit random>/<file name> to whoever asks 127.0.0.1 for it,
/// without the page's token, until dropped.
pub struct Share {
    id: String,
    name: String,
    size: u64,
    sent: Arc<Sent>,
}

impl Share {
    pub fn new(path: &std::path::Path) -> Result<Share, String> {
        let size = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
        let id = hex::encode(rand::random::<[u8; 16]>());
        let sent = Arc::new(Sent::default());
        SHARES.lock().unwrap_or_else(|e| e.into_inner()).insert(id.clone(), (path.to_path_buf(), size, sent.clone()));
        let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        Ok(Share { id, name, size, sent })
    }

    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}/share/{}/{}", PORT.get().copied().unwrap_or(0), self.id, self.name)
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    pub fn sent(&self) -> u64 {
        self.sent.bytes.load(Ordering::Relaxed)
    }

    pub fn done(&self) -> bool {
        self.sent.whole.load(Ordering::Relaxed)
    }
}

impl Drop for Share {
    fn drop(&mut self) {
        SHARES.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.id);
    }
}

/// Answers a share's address with the file, read a mebibyte at a time.
async fn send_share(stream: &mut TcpStream, rest: &str) -> std::io::Result<()> {
    use std::io::Read;
    let id = rest.split('/').next().unwrap_or("");
    let found = SHARES.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
    let Some((path, size, sent)) = found else {
        return respond(stream, "404 Not Found", "text/plain", b"").await;
    };
    let mut file = std::fs::File::open(&path)?;
    let head = format!("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {size}\r\n\
                        Cache-Control: no-store\r\nConnection: close\r\n\r\n");
    stream.write_all(head.as_bytes()).await?;
    let mut piece = vec![0u8; 1 << 20];
    let mut done = 0u64;
    sent.bytes.store(0, Ordering::Relaxed);
    while done < size {
        let n = tokio::task::block_in_place(|| file.read(&mut piece))?;
        if n == 0 {
            break;
        }
        stream.write_all(&piece[..n]).await?;
        done += n as u64;
        sent.bytes.store(done, Ordering::Relaxed);
    }
    stream.flush().await?;
    if done == size {
        sent.whole.store(true, Ordering::Relaxed);
    }
    Ok(())
}

/// The install sheet's App ID choice: one picked from the list, or a
/// custom one typed (checked, the team appended).
fn reuse(app: &App, r: &Json) -> Result<crate::install::Reuse, String> {
    let custom = s(r, "custom_id");
    let pick = if custom.trim().is_empty() {
        r.get("reuse_id").and_then(Json::as_str).filter(|s| !s.is_empty()).map(str::to_string)
    } else {
        Some(app.custom_app_id(&custom)?)
    };
    Ok(crate::install::Reuse { pick, extensions: r.get("reuse_extensions").and_then(Json::as_bool).unwrap_or(false) })
}

fn options(r: &Json) -> Options {
    Options {
        remove_extensions: r.get("remove_extensions").and_then(Json::as_bool).unwrap_or(false),
        increased_memory: r.get("increased_memory").and_then(Json::as_bool).unwrap_or(false),
        icon: s(r, "icon"),
    }
}

/// Decodes %XX escapes (as encodeURIComponent writes them).
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match (bytes[i], bytes.get(i + 1).copied().and_then(hex), bytes.get(i + 2).copied().and_then(hex)) {
            (b'%', Some(hi), Some(lo)) => {
                out.push(hi << 4 | lo);
                i += 3;
            }
            (b, _, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A share answers with the whole file while it lives, counts it, and
    /// is gone once dropped.
    #[tokio::test(flavor = "multi_thread")]
    async fn shares_a_file_once_asked() {
        let path = std::env::temp_dir().join(format!("baristore-share-{}.ipa", std::process::id()));
        let data: Vec<u8> = (0..(3 << 20) + 123).map(|i: u32| (i * 7 + i / 991) as u8).collect();
        std::fs::write(&path, &data).unwrap();
        let share = Share::new(&path).unwrap();
        assert!(share.url().ends_with(&format!("/share/{}/{}", share.id, share.name)));
        let fetch = |rest: String| async move {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                send_share(&mut stream, &rest).await.unwrap();
            });
            let mut client = TcpStream::connect(addr).await.unwrap();
            let mut got = Vec::new();
            client.read_to_end(&mut got).await.unwrap();
            server.await.unwrap();
            got
        };
        let got = fetch(format!("{}/x.ipa", share.id)).await;
        let end = got.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        let head = String::from_utf8_lossy(&got[..end]);
        assert!(head.starts_with("HTTP/1.1 200") && head.contains(&format!("Content-Length: {}", data.len())), "{head}");
        assert!(got[end..] == data[..]);
        assert!(share.done() && share.sent() == data.len() as u64);
        let id = share.id.clone();
        drop(share);
        assert!(fetch(format!("{id}/x.ipa")).await.starts_with(b"HTTP/1.1 404"));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn percent_decoding() {
        assert_eq!(super::percent_decode("https%3A%2F%2Fa.b%2Fx%20y.png"), "https://a.b/x y.png");
        assert_eq!(super::percent_decode("100%"), "100%");
        assert_eq!(super::percent_decode("%zz%4"), "%zz%4");
    }
}

fn s(v: &Json, k: &str) -> String {
    v.get(k).and_then(Json::as_str).unwrap_or("").to_string()
}

async fn action(app: &App, r: &Json) -> Json {
    let name = s(r, "action");
    let ok = |msg: &str| json!({"ok": true, "message": msg});
    let fail = |msg: String| json!({"ok": false, "message": msg});
    if name != "answer" {
        logf!("page: {name}");
    }
    match name.as_str() {
        "check" => {
            if !app.check_vpn().await {
                return fail(crate::device::session::NO_ROUTE.into());
            }
            if crate::pairing::flow::load_record().is_some() {
                if let Err(e) = app.device().await {
                    return fail(e);
                }
                // What is on the iPhone (whether LiveContainer is, for one).
                app.load_device_apps().await.ok();
            }
            ok("connected")
        }
        "pair" => {
            // A failed run with silent speech is retried with Minis's player.
            let player = r.get("player").and_then(Json::as_bool).unwrap_or(false);
            app.spawn("Pairing", Some(json!({"action": "pair", "player": true})), move |a| async move { a.pair(player).await });
            ok("started")
        }
        "devmode_status" => { app.spawn("Developer Mode", Some(r.clone()), |a| async move { a.developer_mode(None).await }); ok("started") }
        "devmode_show" => { app.spawn("Developer Mode", Some(r.clone()), |a| async move { a.developer_mode(Some(0)).await }); ok("started") }
        "devmode_on" => { app.spawn("Developer Mode", None, |a| async move { a.developer_mode(Some(1)).await }); ok("started") }
        "login" => {
            let (email, password) = (s(r, "email"), s(r, "password"));
            if email.is_empty() || password.is_empty() {
                return fail("Enter your Apple ID email and password".into());
            }
            app.spawn("Signing in", None, move |a| async move { a.login(email, password).await });
            ok("started")
        }
        "sign_out" => { app.sign_out().await; ok("signed out") }
        "answer" => {
            let id = r.get("id").and_then(Json::as_u64).unwrap_or(0);
            let value = r.get("value").and_then(Json::as_str).map(str::to_string);
            app.answer(id, value);
            ok("")
        }
        "dismiss" => { app.dismiss_task(); ok("") }
        "catalog_refresh" => { app.refresh_catalog(); ok("") }
        "source_add" => match app.add_source(&s(r, "url")) { Ok(()) => ok("added"), Err(e) => fail(e) },
        "source_remove" => { app.remove_source(&s(r, "url")); ok("removed") }
        "install" => {
            let key = s(r, "key");
            let version = r.get("version").and_then(Json::as_u64).unwrap_or(0) as usize;
            let reuse = match reuse(app, r) { Ok(reuse) => reuse, Err(e) => return fail(e) };
            let opts = options(r);
            let title = s(r, "name");
            app.spawn_kept(&format!("Installing {title}"), Some(r.clone()),
                           move |a| async move { a.install_version(&key, version, opts, reuse).await });
            ok("started")
        }
        "install_local" => {
            let path = s(r, "path");
            let reuse = match reuse(app, r) { Ok(reuse) => reuse, Err(e) => return fail(e) };
            let opts = options(r);
            app.spawn_kept(&format!("Installing {}", s(r, "name")), Some(r.clone()),
                           move |a| async move { a.install_local(&path, opts, reuse).await });
            ok("started")
        }
        "lc_install" => {
            let key = s(r, "key");
            let version = r.get("version").and_then(Json::as_u64).unwrap_or(0) as usize;
            app.spawn(&format!("{} to LiveContainer", s(r, "name")), Some(r.clone()),
                      move |a| async move { a.lc_install(&key, version).await });
            ok("started")
        }
        "lc_install_local" => {
            let path = s(r, "path");
            app.spawn_kept(&format!("{} to LiveContainer", s(r, "name")), Some(r.clone()),
                           move |a| async move { a.lc_install_local(&path).await });
            ok("started")
        }
        "app_options" => {
            let (id, name) = (s(r, "bundle_id"), s(r, "name"));
            let memory = r.get("increased_memory").and_then(Json::as_bool).unwrap_or(false);
            let icon = r.get("icon").and_then(Json::as_str);
            match app.set_app_options(&id, memory, icon) {
                Ok(true) => {
                    app.spawn_kept(&format!("Signing {name} again"), Some(json!({"action": "sign_again", "bundle_id": id,
                        "name": name})), move |a| async move { a.sign_again(&id).await });
                    ok("started")
                }
                Ok(false) => ok(&format!("Saved: {name} gets it with its next update. BariStore no longer has its IPA \
                                          and downloads nothing for this.")),
                Err(e) => fail(e),
            }
        }
        "sign_again" => {
            let id = s(r, "bundle_id");
            app.spawn_kept(&format!("Signing {} again", s(r, "name")), Some(r.clone()),
                           move |a| async move { a.sign_again(&id).await });
            ok("started")
        }
        "clear_cache" => ok(&app.clear_cache()),
        "cache_size" => json!({"ok": true, "bytes": app.cache_size()}),
        "refresh" => {
            let id = s(r, "bundle_id");
            app.spawn_kept(&format!("Refreshing {}", s(r, "name")), Some(r.clone()), move |a| async move { a.refresh_app(&id).await });
            ok("started")
        }
        "refresh_all" => { app.spawn_kept("Refreshing all apps", Some(r.clone()), |a| async move { a.refresh_all().await }); ok("started") }
        "delete" => {
            let id = s(r, "bundle_id");
            app.spawn(&format!("Deleting {}", s(r, "name")), Some(r.clone()), move |a| async move { a.delete_app(&id).await });
            ok("started")
        }
        "jit" => {
            let id = s(r, "bundle_id");
            app.spawn_kept(&format!("JIT for {}", s(r, "name")), Some(r.clone()), move |a| async move { a.enable_jit(&id).await });
            ok("started")
        }
        "app_ids" => match app.load_app_ids().await { Ok(()) => ok(""), Err(e) => fail(e) },
        "check_self_update" => match app.check_self_update().await { Ok(()) => ok(""), Err(e) => fail(e) },
        "check_updates" => match app.check_updates().await { Ok(()) => ok(""), Err(e) => fail(e) },
        "ipa_info" => {
            let version = r.get("version").and_then(Json::as_u64).unwrap_or(0) as usize;
            match app.ipa_info(&s(r, "key"), version).await { Ok(info) => json!({"ok": true, "info": info}), Err(e) => fail(e) }
        }
        "set_channel" => match app.set_channel(&s(r, "bundle_id"), &s(r, "channel")) { Ok(m) => ok(&m), Err(e) => fail(e) },
        "anisette" => match app.set_anisette(&s(r, "url")).await { Ok(m) => ok(&m), Err(e) => fail(e) },
        "anisette_add" => match app.add_anisette(&s(r, "url")).await { Ok(m) => ok(&m), Err(e) => fail(e) },
        "anisette_remove" => { app.remove_anisette(&s(r, "url")); ok("removed") }
        "update_app" => {
            let id = s(r, "bundle_id");
            app.spawn_kept(&format!("Updating {}", s(r, "name")), Some(r.clone()), move |a| async move { a.update_app(&id).await });
            ok("started")
        }
        "update_all" => { app.spawn_kept("Updating apps", Some(r.clone()), |a| async move { a.update_all().await }); ok("started") }
        "update" => { app.spawn_kept("Updating BariStore", Some(r.clone()), |a| async move { a.update().await }); ok("started") }
        "device_apps" => match app.load_device_apps().await { Ok(()) => ok(""), Err(e) => fail(e) },
        "place_pairing" => {
            let id = s(r, "bundle_id");
            app.spawn("Pairing file", Some(r.clone()), move |a| async move { a.place_pairing(&id).await });
            ok("started")
        }
        "export_pairing" => match app.export_pairing() { Ok(file) => json!({"ok": true, "file": file}), Err(e) => fail(e) },
        "certificates" => match app.certificates().await { Ok(list) => json!({"ok": true, "list": list}), Err(e) => fail(e) },
        "revoke_certificate" => {
            let serial = s(r, "serial");
            app.spawn("Revoking a certificate", Some(r.clone()), move |a| async move { a.revoke_certificate(&serial).await });
            ok("started")
        }
        "export_certificate" => {
            app.spawn("Exporting the certificate", Some(r.clone()), |a| async move {
                let file = a.export_certificate().await?;
                a.offer_next(json!({"label": "Share the file", "share": file}));
                Ok("BariStore-Certificate.p12 is ready. Apps that import it ask for this password:".into())
            });
            ok("started")
        }
        "lc_certificate" => {
            app.spawn("Certificate for LiveContainer", Some(r.clone()), |a| async move { a.lc_certificate().await });
            ok("started")
        }
        "settings" => { crate::state::save_settings(r.get("settings").unwrap_or(&Json::Null)); ok("saved") }
        "log" => ok(&crate::doctor::report(false).await),
        "checks" => ok(&crate::doctor::report(true).await),
        "reset" => { app.reset().await; ok("reset") }
        "quit" => {
            tokio::spawn(async {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                std::process::exit(0)
            });
            ok("bye")
        }
        _ => fail(format!("unknown action {name}")),
    }
}
