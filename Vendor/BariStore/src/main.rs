mod app;
mod apple;
mod der;
mod device;
mod doctor;
mod hash;
mod icons;
mod install;
mod log;
mod minis;
mod pairing;
mod sign;
mod siphash;
mod srp;
mod store;
mod web;
mod state;
mod update;

use std::process::ExitCode;

const USAGE: &str = "usage: baristore            open the store
       baristore update     install the newest BariStore
       baristore log        print the log (as Options › Log)
       baristore --version";

/// Set for the store's server process: "<port> <token>" to serve on.
const SERVE: &str = "BARISTORE_SERVE";
/// The server's exit code after it installed a new build: the supervisor
/// starts the new file at the same address (it never execs: in Minis's
/// kernel an exec leaves the process's other threads running).
pub const UPDATED: i32 = 75;
/// A server that answered and then does not for this long is stopped and
/// started again. Long: a slow step must never be mistaken for a hang.
const HUNG: std::time::Duration = std::time::Duration::from_secs(60);

/// Ctrl-C in the terminal (SIGINT): quit the store.
static INTERRUPTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn on_interrupt(_: libc::c_int) {
    INTERRUPTED.store(true, std::sync::atomic::Ordering::SeqCst);
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let _ = std::fs::create_dir_all(state::home());
    if args.is_empty() && std::env::var_os(SERVE).is_none() {
        return supervise();
    }
    // Two workers: Minis's shell runs on an emulated CPU with little memory.
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()
        .expect("tokio runtime");
    match runtime.block_on(run(args)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("baristore: {message}");
            ExitCode::FAILURE
        }
    }
}

async fn run(args: Vec<String>) -> Result<(), String> {
    match args.first().map(String::as_str) {
        None => serve().await,
        Some("update") => {
            // Progress stays on one line: "\r" goes back to its start.
            let on_line = std::sync::atomic::AtomicBool::new(false);
            let show = |step: String| {
                use std::io::Write;
                let progress = step.starts_with("Downloading");
                let back = on_line.swap(progress, std::sync::atomic::Ordering::SeqCst);
                let mut out = std::io::stdout();
                let _ = match (back, progress) {
                    (_, true) => write!(out, "\r{step}\x1b[K"),
                    (true, false) => write!(out, "\n{step}\n"),
                    (false, false) => writeln!(out, "{step}"),
                };
                let _ = out.flush();
            };
            let outcome = update::download_and_replace(&show).await;
            if on_line.load(std::sync::atomic::Ordering::SeqCst) {
                println!();
            }
            match outcome? {
                update::Outcome::UpToDate => println!("BariStore {} is the newest build.", env!("CARGO_PKG_VERSION")),
                update::Outcome::Updated(version) => println!("Updated to {version}. Type baristore to open the store."),
            }
            Ok(())
        }
        Some("log") => {
            println!("{}", doctor::report(false).await);
            Ok(())
        }
        Some("--version") | Some("-V") => {
            println!("baristore {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        #[cfg(debug_assertions)]
        Some("dev") => dev(&args[1..]).await,
        _ => {
            println!("{USAGE}");
            Ok(())
        }
    }
}

/// A line for the terminal. Never panics: once Minis closes the terminal,
/// writing to it fails, and `println!` would take the supervisor down.
fn say(text: &str) {
    use std::io::Write;
    let _ = writeln!(std::io::stdout(), "{text}");
}

/// Where the running store is: "<port> <token> <server pid> <supervisor pid>"
/// in ~/.baristore/running, so `baristore` finds a store that outlived its
/// terminal.
struct Running {
    port: u16,
    token: String,
    server: u32,
    supervisor: u32,
}

impl Running {
    fn load() -> Option<Running> {
        let text = std::fs::read_to_string(state::path("running")).ok()?;
        let mut parts = text.split_whitespace();
        Some(Running {
            port: parts.next()?.parse().ok()?,
            token: parts.next()?.to_string(),
            server: parts.next()?.parse().ok()?,
            supervisor: parts.next()?.parse().ok()?,
        })
    }

    fn save(&self) {
        let _ = state::write_private(&state::path("running"),
            format!("{} {} {} {}", self.port, self.token, self.server, self.supervisor).as_bytes());
    }
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    pid > 0 && unsafe { libc::kill(pid as libc::pid_t, 0) } == 0
}

/// Asks the server at `port` whether it answers within `wait`; Some(busy)
/// when it does. Blocking I/O on a thread of its own: Minis's kernel refuses
/// the socket timeouts a 64-bit program sets (SO_RCVTIMEO is 20 there; iSH
/// takes only 66), so the wait is the channel's. One ping at a time: while
/// the last one still waits for a hung server, the next counts as no answer.
fn ping(port: u16, token: &str, wait: std::time::Duration) -> Option<bool> {
    use std::sync::atomic::{AtomicBool, Ordering};
    static WAITING: AtomicBool = AtomicBool::new(false);
    if WAITING.swap(true, Ordering::SeqCst) {
        return None;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let token = token.to_string();
    let asked = std::thread::Builder::new().stack_size(64 << 10).spawn(move || {
        let _ = tx.send(ask(port, &token));
        WAITING.store(false, Ordering::SeqCst);
    });
    if asked.is_err() {
        WAITING.store(false, Ordering::SeqCst);
        return None;
    }
    rx.recv_timeout(wait).ok().flatten()
}

fn ask(port: u16, token: &str) -> Option<bool> {
    use std::io::{Read, Write};
    let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).ok()?;
    write!(s, "GET /{token}/api/ping HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n").ok()?;
    let mut reply = Vec::new();
    s.take(4096).read_to_end(&mut reply).ok()?;
    let reply = String::from_utf8_lossy(&reply);
    reply.starts_with("HTTP/1.1 200").then(|| reply.contains("\"busy\":true"))
}

/// What ended one server run.
enum End {
    /// Return, Ctrl-C.
    Quit,
    Exited(std::process::ExitStatus),
    /// Alive but not answering for `HUNG`: it was killed.
    Hung,
}

/// Waits up to `wait` for Return or Ctrl-C.
fn quit_asked(quit: &std::sync::mpsc::Receiver<()>, wait: std::time::Duration) -> bool {
    use std::sync::mpsc::RecvTimeoutError;
    match quit.recv_timeout(wait) {
        Ok(()) => return true,
        // The terminal's input ended (Minis closed it): wait all the same,
        // or this loop would spin on the emulated CPU.
        Err(RecvTimeoutError::Disconnected) => std::thread::sleep(wait),
        Err(RecvTimeoutError::Timeout) => {}
    }
    INTERRUPTED.load(std::sync::atomic::Ordering::SeqCst)
}

/// Waits for the server to end, and ends it when it stops answering while
/// the supervisor itself keeps running (a hung server keeps the page's
/// buttons waiting forever; a crashed one is simply started again). Only a
/// server that has answered once is judged: where pings cannot get through,
/// nothing is killed.
fn watch(child: &mut std::process::Child, port: u16, token: &str, quit: &std::sync::mpsc::Receiver<()>) -> End {
    use std::time::{Duration, Instant};
    let (mut answered, mut tick, mut next_ping) = (Instant::now(), Instant::now(), Instant::now() + Duration::from_secs(5));
    let mut armed = false;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return End::Exited(status);
        }
        if quit_asked(quit, Duration::from_millis(250)) {
            return End::Quit;
        }
        let now = Instant::now();
        // A long gap: iOS suspended Minis (and the server with it). Give the
        // server time to come back before judging it.
        if now.duration_since(tick) > Duration::from_secs(5) {
            answered = now;
        }
        tick = now;
        if now >= next_ping {
            if ping(port, token, Duration::from_secs(5)).is_some() {
                answered = Instant::now();
                armed = true;
            } else if armed && answered.elapsed() > HUNG {
                logf!("supervisor: the server did not answer for {} s; restarting it", HUNG.as_secs());
                let _ = child.kill();
                let _ = child.wait();
                return End::Hung;
            }
            tick = Instant::now();
            next_ping = tick + Duration::from_secs(3);
        }
    }
}

/// `baristore`: a small supervisor that runs the store's server as a child
/// and starts it again when it dies or hangs. iOS can take memory from Minis
/// in the background, and the server then aborts ("memory allocation …
/// failed"); the page stays at the same address and reconnects. The server
/// runs in its own process group, so whatever ends the terminal's (Minis
/// closing it: SIGHUP, or killing the command's group) leaves the store
/// running; the supervisor ignores SIGHUP. Return, Ctrl-C or Options › Quit
/// quit. The supervisor itself allocates almost nothing after start.
fn supervise() -> ExitCode {
    // SAFETY: plain signal dispositions; the handler only stores an atomic.
    unsafe {
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        libc::signal(libc::SIGINT, on_interrupt as extern "C" fn(libc::c_int) as libc::sighandler_t);
    }
    let me = std::process::id();
    let running = Running::load().filter(|r| ping(r.port, &r.token, std::time::Duration::from_secs(3)).is_some());
    if let Some(r) = running.as_ref().filter(|r| r.supervisor != me && alive(r.supervisor)) {
        say("BariStore is already running.");
        if !minis::open(&format!("http://127.0.0.1:{}/{}/", r.port, r.token)) {
            say(&format!("Open this address in Minis's browser: http://127.0.0.1:{}/{}/", r.port, r.token));
        }
        return ExitCode::SUCCESS;
    }
    let (port, token) = match &running {
        // A store that outlived its terminal: this one takes it over at the
        // same address.
        Some(r) => (r.port, r.token.clone()),
        None => {
            let port = std::net::TcpListener::bind(("127.0.0.1", 0)).and_then(|l| l.local_addr())
                .map(|a| a.port()).unwrap_or(47801);
            (port, hex::encode(rand::random::<[u8; 16]>()))
        }
    };
    let url = format!("http://127.0.0.1:{port}/{token}/");
    let Ok(exe) = std::env::current_exe() else {
        say("baristore: cannot find its own file");
        return ExitCode::FAILURE;
    };
    say(&format!("BariStore {}", env!("CARGO_PKG_VERSION")));
    if !app::minis_ok() {
        say("Note: this is not Open Minis 1.16+ (no minis-bonjour): pairing will not work here.");
    }
    let (quit_tx, quit_rx) = std::sync::mpsc::channel::<()>();
    let log_exe = exe.clone();
    std::thread::spawn(move || {
        // What is typed here while the store runs: Return quits, "log"
        // prints the log, anything else gets a hint. With no terminal input
        // (stdin at its end) nothing quits.
        let mut line = String::new();
        while std::io::stdin().read_line(&mut line).unwrap_or(0) > 0 {
            match line.trim() {
                "" | "q" | "quit" | "exit" => {
                    let _ = quit_tx.send(());
                    return;
                }
                "log" | "baristore log" => {
                    let _ = std::process::Command::new(&log_exe).arg("log").stdin(std::process::Stdio::null()).status();
                }
                _ => say("BariStore is running here: Return quits it, log prints its log."),
            }
            line.clear();
        }
    });
    let (mut opened, mut hinted) = (false, false);
    if let Some(old) = running.filter(|r| r.supervisor != me && alive(r.server)) {
        opened = true;
        if !minis::open(&url) {
            say(&format!("Open this address in Minis's browser: {url}"));
        }
        say("Taking over the BariStore that is still running.");
        while ping(port, &token, std::time::Duration::from_secs(5)) == Some(true) {
            if quit_asked(&quit_rx, std::time::Duration::from_secs(2)) {
                return ExitCode::SUCCESS;
            }
        }
        for signal in [libc::SIGTERM, libc::SIGKILL] {
            // SAFETY: ends the earlier server (its own process group).
            unsafe { libc::kill(old.server as libc::pid_t, signal) };
            for _ in 0..40 {
                if !alive(old.server) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        }
    }
    let log = || {
        crate::log::trim(&state::path("server.out"));
        std::fs::OpenOptions::new().create(true).append(true).open(state::path("server.out"))
    };
    let mut crashes: Vec<std::time::Instant> = Vec::new();
    let mut own_group = true;
    loop {
        // The server's own stdout/stderr (a crash's last words) go to a
        // file: the terminal may be gone.
        let mut command = std::process::Command::new(&exe);
        command.env(SERVE, format!("{port} {token}")).stdin(std::process::Stdio::null());
        if let (Ok(out), Ok(err)) = (log(), log()) {
            command.stdout(out).stderr(err);
        }
        if own_group {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child = match command.spawn() {
            Ok(c) => c,
            Err(e) if own_group => {
                say(&format!("baristore: cannot start the store in its own process group ({e})"));
                own_group = false;
                continue;
            }
            Err(e) => {
                // In the background iOS may refuse memory for a new process
                // for a while: keep trying.
                say(&format!("baristore: cannot start the store ({e}); trying again"));
                if quit_asked(&quit_rx, std::time::Duration::from_secs(5)) {
                    return ExitCode::SUCCESS;
                }
                continue;
            }
        };
        Running { port, token: token.clone(), server: child.id(), supervisor: me }.save();
        if !opened {
            opened = true;
            // The page polls until the server answers, so it can open now.
            if !minis::open(&url) {
                say(&format!("Open this address in Minis's browser: {url}"));
            }
        }
        if !hinted {
            hinted = true;
            say("The store is open.");
            say("To quit: press Return here (or Ctrl-C), or Options › Quit in the store.");
        }
        let status = match watch(&mut child, port, &token, &quit_rx) {
            End::Quit => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(state::path("running"));
                say("BariStore closed. Type baristore to open it again.");
                return ExitCode::SUCCESS;
            }
            End::Hung => {
                say("BariStore stopped answering; starting it again.");
                None
            }
            End::Exited(status) => Some(status),
        };
        match status.and_then(|s| s.code()) {
            Some(0) => {
                let _ = std::fs::remove_file(state::path("running"));
                say("BariStore closed. Type baristore to open it again.");
                return ExitCode::SUCCESS;
            }
            // The new build is in place of the old file: the next run of
            // the loop starts it at the same address.
            Some(UPDATED) => say("BariStore updated; starting the new build."),
            _ => {
                let now = std::time::Instant::now();
                crashes.retain(|t| now.duration_since(*t).as_secs() < 60);
                crashes.push(now);
                if let Some(status) = status {
                    say(&format!("BariStore stopped ({status}); starting it again."));
                }
                // In the background iOS may refuse memory for a while: wait
                // longer when it keeps failing.
                let pause = if crashes.len() > 3 { 10 } else { 1 };
                if quit_asked(&quit_rx, std::time::Duration::from_secs(pause)) {
                    let _ = std::fs::remove_file(state::path("running"));
                    return ExitCode::SUCCESS;
                }
            }
        }
    }
}

/// The store's server (the supervisor's child): serves the page at the
/// address it was given until Options › Quit or an update ends it.
async fn serve() -> Result<(), String> {
    let spec = std::env::var(SERVE).map_err(|_| "not started by baristore".to_string())?;
    let (port, token) = spec.split_once(' ').ok_or("bad BARISTORE_SERVE")?;
    let port: u16 = port.parse().map_err(|_| "bad port")?;
    logf!("baristore {} starting (pid {})", env!("CARGO_PKG_VERSION"), std::process::id());
    let store = app::App::new();
    web::serve(store, port, token).await?;
    std::future::pending::<()>().await;
    Ok(())
}

/// Developer commands for interop tests (debug builds only).
#[cfg(debug_assertions)]
async fn dev(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("pairhost") => {
            let port: u16 = args.get(1).and_then(|p| p.parse().ok()).ok_or("dev pairhost <port> <code>")?;
            let code = args.get(2).ok_or("dev pairhost <port> <code>")?;
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await.map_err(|e| e.to_string())?;
            let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
            let identity = pairing::record::HostIdentity::generate();
            let log = |line: String| println!("host: {line}");
            let peer = pairing::host::PairableHost::new(stream, &identity, "BariStore", &log)
                .accept(|| async { code.clone() }).await.map_err(|e| e.to_string())?;
            println!("paired: udid={} model={} name={}", peer.udid, peer.model, peer.name);
            Ok(())
        }
        Some("tunnel") => {
            // Through CDTunnel against BARISTORE_DEVICE, then one raw packet.
            let record = pairing::record::PairingRecord {
                host: pairing::record::HostIdentity::generate(),
                peer: Default::default(),
            };
            let tunnel = device::session::Tunnel::open(&record).await.map_err(|e| e.to_string())?;
            println!("tunnel: rsd {}", tunnel.rsd_port);
            match tokio::time::timeout(std::time::Duration::from_secs(5), tunnel.stack.connect(tunnel.rsd_port)).await {
                Ok(Err(e)) => println!("tcp over the echo link: {e}"),
                Ok(Ok(_)) => println!("tcp over the echo link: connected"),
                Err(_) => println!("tcp over the echo link: no answer (expected from an echo)"),
            }
            Ok(())
        }
        Some("sign") => {
            // dev sign <in.ipa> <out.ipa> <cert.der> <key.pk8.der> <team>: every
            // app/appex gets a dummy profile and minimal entitlements.
            use plist::Value;
            let a = |i: usize| args.get(i).cloned().ok_or("dev sign <in> <out> <cert.der> <key.der> <team>");
            let bytes = std::fs::read(a(1)?).map_err(|e| e.to_string())?;
            let leaf = std::fs::read(a(3)?).map_err(|e| e.to_string())?;
            let key = {
                use rsa::pkcs8::DecodePrivateKey;
                rsa::RsaPrivateKey::from_pkcs8_der(&std::fs::read(a(4)?).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?
            };
            let team = a(5)?;
            let mut ipa = sign::bundle::Ipa::read(bytes, &|_, _| {})?;
            let mut plan = sign::bundle::Plan {
                identity: sign::codesign::Identity { leaf, chain: vec![], key, team: team.clone(), common_name: "Test".into() },
                bundles: Default::default(), info_edits: Default::default(), add_files: vec![],
            };
            for b in ipa.bundles()? {
                if b.kind == sign::bundle::Kind::Framework { continue; }
                let new_id = format!("{}.{team}", b.id);
                let mut ent = plist::Dictionary::new();
                ent.insert("application-identifier".into(), Value::String(format!("{team}.{new_id}")));
                ent.insert("com.apple.developer.team-identifier".into(), Value::String(team.clone()));
                ent.insert("get-task-allow".into(), Value::Boolean(true));
                println!("bundle {} {} -> {}", b.dir, b.id, new_id);
                plan.bundles.insert(b.dir.clone(), sign::bundle::Signing { new_id, profile: b"profile".to_vec(), entitlements: ent });
            }
            let started = std::time::Instant::now();
            sign::bundle::sign(&mut ipa, &plan, &mut |n, t| println!("signed {n}/{t}"))?;
            std::fs::write(a(2)?, ipa.write()?).map_err(|e| e.to_string())?;
            println!("ok in {:?}", started.elapsed());
            Ok(())
        }
        _ => Err("dev: unknown command".into()),
    }
}
