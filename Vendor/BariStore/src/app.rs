//! The running store: state the page shows, the one task that runs at a time,
//! questions to the user, and the cached device and Apple sessions.

use serde::Serialize;
use serde_json::{json, Value as Json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::{oneshot, Mutex as AsyncMutex};

use crate::apple::{anisette, gsa, portal};
use crate::device::{services, session::{self, Session}};
use crate::install::{self, Installed, Options};
use crate::pairing::flow;
use crate::{logf, minis, state, store};

#[derive(Clone, Default, Serialize)]
pub struct Task {
    pub title: String,
    pub step: String,
    pub progress: Option<u32>,
    pub error: String,
    pub done: bool,
    /// What the user can do about an error ("retry" re-runs the same action).
    pub retry: Option<Json>,
    /// A follow-up the done sheet offers as a button: {"label", "action", …}.
    pub next: Option<Json>,
}

#[derive(Clone, Serialize)]
pub struct Question {
    pub id: u64,
    pub kind: String,      // "code" | "text" | "choice"
    pub title: String,
    pub message: String,
    pub options: Vec<String>,
}

#[derive(Clone, Default, Serialize)]
pub struct Setup {
    pub vpn: Option<bool>,
    pub paired: bool,
    pub devmode: Option<bool>,
    pub signed_in: bool,
    pub email: String,
    pub team: String,
    pub team_name: String,
    pub udid: String,
    pub device_name: String,
}

#[derive(Default)]
struct Inner {
    setup: Setup,
    task: Option<Task>,
    question: Option<Question>,
    answers: HashMap<u64, oneshot::Sender<Option<String>>>,
    next_id: u64,
    pairing_code: String,
    /// A pairing run is advertising (the page shows where to tap).
    pairing_waiting: bool,
    /// What keeps Minis running during pairing ("" when nothing does).
    pairing_keepalive: String,
    catalog: Vec<store::App>,
    sources: Vec<store::Source>,
    refreshing: bool,
    device_apps: Vec<Json>,
    /// The team's App IDs, as My Apps shows them (null until asked).
    app_ids: Json,
    /// Whether a newer BariStore build is published (None until checked).
    self_update: Option<bool>,
}

#[derive(Clone)]
pub struct App {
    inner: Arc<Mutex<Inner>>,
    session: Arc<AsyncMutex<Option<Arc<Session>>>>,
    apple: Arc<AsyncMutex<Option<Arc<(gsa::GrandSlam, gsa::Account)>>>>,
    busy: Arc<AsyncMutex<()>>,
}

impl App {
    pub fn new() -> App {
        let app = App {
            inner: Arc::new(Mutex::new(Inner::default())),
            session: Arc::new(AsyncMutex::new(None)),
            apple: Arc::new(AsyncMutex::new(None)),
            busy: Arc::new(AsyncMutex::new(())),
        };
        {
            let mut i = app.inner.lock().unwrap();
            i.catalog = store::cached_catalog();
            i.sources = store::sources();
            if let Some(r) = flow::load_record() {
                i.setup.paired = true;
                i.setup.udid = r.peer.udid.clone();
                i.setup.device_name = r.peer.name.clone();
            }
            if let Some(a) = gsa::Account::load() {
                i.setup.signed_in = true;
                i.setup.email = a.email;
            }
            if let Ok(t) = std::fs::read_to_string(state::path("team")) {
                let mut parts = t.splitn(2, '\n');
                i.setup.team = parts.next().unwrap_or("").trim().into();
                i.setup.team_name = parts.next().unwrap_or("").trim().into();
            }
        }
        prune_files();
        app
    }

    pub fn snapshot(&self) -> Json {
        let updates = self.updates();
        let i = self.inner.lock().unwrap();
        json!({
            "version": env!("CARGO_PKG_VERSION"),
            "boot": boot_id(),
            "setup": i.setup,
            "task": i.task,
            "question": i.question,
            "pairing_code": i.pairing_code,
            "pairing_waiting": i.pairing_waiting,
            "pairing_keepalive": i.pairing_keepalive,
            "settings": state::settings(),
            // With the icon the app on the iPhone has, and whether its IPA
            // is still here (a change to it can be signed in at once).
            "installed": install::installed().into_iter().map(|e| {
                let mut v = json!(e);
                v["icon_url"] = json!(e.shown_icon());
                v["ipa"] = json!(std::path::Path::new(&e.ipa_path).is_file());
                v
            }).collect::<Vec<_>>(),
            "updates": updates,
            "device_apps": i.device_apps,
            "app_ids": i.app_ids,
            "self_update": i.self_update,
            "anisette_defaults": anisette::SERVERS,
            "log": crate::log::recent().iter().rev().take(80).rev().collect::<Vec<_>>(),
        })
    }

    pub fn catalog(&self) -> Json {
        let i = self.inner.lock().unwrap();
        json!({"apps": i.catalog, "sources": i.sources, "suggested": store::suggested(&i.sources),
               "refreshing": i.refreshing})
    }

    fn set_task(&self, f: impl FnOnce(&mut Task)) {
        let mut i = self.inner.lock().unwrap();
        let t = i.task.get_or_insert_with(Task::default);
        f(t);
    }

    pub fn step(&self, text: impl Into<String>) {
        let text = text.into();
        logf!("task: {text}");
        self.set_task(|t| { t.step = text; t.progress = None; });
    }

    pub fn progress(&self, text: impl Into<String>, pct: u32) {
        let text = text.into();
        self.set_task(|t| { t.step = text; t.progress = Some(pct.min(100)); });
    }

    /// Shows a question on the page and waits for the answer (None: cancelled).
    pub async fn ask(&self, kind: &str, title: &str, message: &str, options: &[&str]) -> Option<String> {
        let (tx, rx) = oneshot::channel();
        {
            let mut i = self.inner.lock().unwrap();
            i.next_id += 1;
            let id = i.next_id;
            i.answers.insert(id, tx);
            i.question = Some(Question { id, kind: kind.into(), title: title.into(), message: message.into(),
                                         options: options.iter().map(|s| s.to_string()).collect() });
        }
        let answer = rx.await.ok().flatten();
        self.inner.lock().unwrap().question = None;
        answer
    }

    pub fn answer(&self, id: u64, value: Option<String>) {
        let tx = self.inner.lock().unwrap().answers.remove(&id);
        if let Some(tx) = tx {
            let _ = tx.send(value);
        }
    }

    /// Runs `job` as the one task; its error ends the task with a message.
    pub fn spawn<F, Fut>(&self, title: &str, retry: Option<Json>, job: F)
    where F: FnOnce(App) -> Fut + Send + 'static, Fut: std::future::Future<Output = Result<String, String>> + Send
    {
        let app = self.clone();
        let title = title.to_string();
        tokio::spawn(async move {
            let Ok(_guard) = app.busy.try_lock() else {
                logf!("task: {title} refused: another task is running");
                return;
            };
            {
                let mut i = app.inner.lock().unwrap();
                i.task = Some(Task { title: title.clone(), ..Default::default() });
            }
            logf!("task: start {title}");
            let result = job(app.clone()).await;
            // Before the next task can start: IPAs this one left unneeded.
            prune_files();
            let mut i = app.inner.lock().unwrap();
            let t = i.task.get_or_insert_with(Task::default);
            t.done = true;
            t.progress = None;
            match result {
                Ok(msg) => { logf!("task: done {title}: {msg}"); t.step = msg; }
                Err(e) => { logf!("task: failed {title}: {e}"); t.error = e; t.retry = retry; }
            }
        });
    }

    /// `spawn` for work that must not stop halfway (install, refresh, JIT,
    /// update): silent speech keeps Minis running meanwhile, as during
    /// pairing, in case the user leaves Minis.
    pub fn spawn_kept<F, Fut>(&self, title: &str, retry: Option<Json>, job: F)
    where F: FnOnce(App) -> Fut + Send + 'static, Fut: std::future::Future<Output = Result<String, String>> + Send
    {
        self.spawn(title, retry, move |a| async move {
            let alive = minis::KeepAlive::speech();
            logf!("task: keeping Minis running with {}", alive.as_ref().map(|k| k.name()).unwrap_or("nothing"));
            let result = job(a).await;
            drop(alive);
            result
        });
    }

    /// Whether a task is running (the supervisor waits for it to end).
    pub fn busy(&self) -> bool {
        self.busy.try_lock().is_err()
    }

    /// The button the done sheet shows after this task.
    pub fn offer_next(&self, next: Json) {
        self.set_task(|t| t.next = Some(next));
    }

    pub fn dismiss_task(&self) {
        let mut i = self.inner.lock().unwrap();
        if i.task.as_ref().is_some_and(|t| t.done) {
            i.task = None;
        }
    }

    // --- device ---------------------------------------------------------

    pub async fn check_vpn(&self) -> bool {
        let up = session::vpn_up().await;
        self.inner.lock().unwrap().setup.vpn = Some(up);
        up
    }

    /// A live session (reused while it works), or a clear reason why not.
    pub async fn device(&self) -> Result<Arc<Session>, String> {
        let mut guard = self.session.lock().await;
        if let Some(s) = guard.as_ref() {
            // Bounded: after Minis was in the background, a tunnel iOS took
            // away may never answer.
            let alive = tokio::time::timeout(std::time::Duration::from_secs(10), services::developer_mode(s)).await;
            if matches!(alive, Ok(Ok(_))) {
                return Ok(s.clone());
            }
            logf!("device: the cached tunnel does not answer; opening a new one");
            *guard = None;
        }
        if !self.check_vpn().await {
            return Err(session::NO_ROUTE.into());
        }
        let record = flow::load_record().ok_or("This iPhone is not paired yet.")?;
        // Bounded: on mobile data LocalDevVPN can take a connection and then
        // never answer.
        let s = match tokio::time::timeout(std::time::Duration::from_secs(45), Session::open(&record)).await {
            Ok(Ok(s)) => Arc::new(s),
            Ok(Err(e)) => return Err(e.to_string()),
            Err(_) => {
                logf!("device: no tunnel within 45 s");
                return Err(session::NO_ROUTE.into());
            }
        };
        let dm = services::developer_mode(&s).await.ok().flatten();
        {
            let mut i = self.inner.lock().unwrap();
            i.setup.devmode = dm;
            if !s.udid.is_empty() {
                i.setup.udid = s.udid.clone();
            }
            if let Some(n) = s.properties.get("DeviceName").and_then(plist::Value::as_string) {
                i.setup.device_name = n.to_string();
            }
        }
        *guard = Some(s.clone());
        Ok(s)
    }

    /// `player`: keep Minis running with its player instead of silent speech.
    pub async fn pair(&self, player: bool) -> Result<String, String> {
        // Pairing itself would work on mobile data, but nothing after it would.
        self.step("Checking Wi-Fi and LocalDevVPN");
        if !self.check_vpn().await {
            return Err(session::NO_ROUTE.into());
        }
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let app = self.clone();
        let watcher = tokio::spawn(async move {
            while let Some(ev) = rx.recv().await {
                match ev {
                    flow::Event::Waiting { keepalive } => {
                        {
                            let mut i = app.inner.lock().unwrap();
                            i.pairing_waiting = true;
                            i.pairing_keepalive = keepalive.unwrap_or("").to_string();
                        }
                        app.step(match keepalive {
                            Some(_) => "Waiting for Settings",
                            None => "Waiting for Settings. Minis may stop in the background: be quick.",
                        });
                    }
                    flow::Event::Code { code, attempt, notification } => {
                        app.inner.lock().unwrap().pairing_code = code;
                        let new = if attempt == 1 { "the code" } else { "the new code" };
                        app.step(if notification { format!("Type {new} from the notification in Settings") }
                                 else { format!("Type {new} below in Settings (no notification could be sent)") });
                    }
                    flow::Event::WrongCode { attempts_left } => {
                        app.inner.lock().unwrap().pairing_code.clear();
                        app.step(format!("Wrong code. Tap Pair with BariStore again ({attempts_left} tries left)."));
                    }
                    flow::Event::Paired { name } => app.step(format!("Paired with {name}")),
                }
            }
        });
        let result = flow::run(tx, player).await;
        watcher.abort();
        {
            let mut i = self.inner.lock().unwrap();
            i.pairing_code.clear();
            i.pairing_waiting = false;
        }
        let record = result?;
        *self.session.lock().await = None;
        {
            let mut i = self.inner.lock().unwrap();
            i.setup.paired = true;
            i.setup.udid = record.peer.udid.clone();
            i.setup.device_name = record.peer.name.clone();
        }
        // Prove the new record works and learn Developer Mode's state now.
        self.step("Checking the connection");
        match self.device().await {
            Ok(_) => Ok(format!("Paired with {}.", record.peer.name)),
            Err(e) => {
                logf!("pair: paired, but the first connection failed: {e}");
                Ok(format!("Paired with {}. Not connected yet: check LocalDevVPN.", record.peer.name))
            }
        }
    }

    pub async fn developer_mode(&self, action: Option<u64>) -> Result<String, String> {
        let s = self.device().await?;
        if let Some(a) = action {
            services::amfi_action(&s, a).await?;
            if a == 1 {
                *self.session.lock().await = None;
                return Ok("The iPhone restarts to turn Developer Mode on. Open BariStore again afterwards.".into());
            }
            return Ok("Developer Mode is now in Settings › Privacy & Security.".into());
        }
        let dm = services::developer_mode(&s).await?;
        self.inner.lock().unwrap().setup.devmode = dm;
        Ok(match dm { Some(true) => "Developer Mode is on.", Some(false) => "Developer Mode is off.", None => "Developer Mode: unknown." }.into())
    }

    // --- Apple ----------------------------------------------------------

    pub async fn apple(&self) -> Result<Arc<(gsa::GrandSlam, gsa::Account)>, String> {
        let mut guard = self.apple.lock().await;
        if let Some(a) = guard.as_ref() {
            if a.1.token_fresh() {
                return Ok(a.clone());
            }
        }
        match gsa::resume().await {
            Ok(pair) => {
                let pair = Arc::new(pair);
                *guard = Some(pair.clone());
                Ok(pair)
            }
            // A network failure must not sign anyone out: the page keeps the
            // account and says what failed.
            Err(e) => {
                logf!("apple: saved session unusable: {e}");
                Err(format!("Apple did not accept the saved sign-in ({e}). Try again, or sign in again in Options."))
            }
        }
    }

    pub async fn login(&self, email: String, password: String) -> Result<String, String> {
        let app = self.clone();
        let ask: Box<gsa::CodeAsker> = Box::new(move |kind, hint| {
            let app = app.clone();
            Box::pin(async move {
                let where_ = match kind {
                    gsa::CodeKind::TrustedDevice => "Enter the code Apple sent to your devices.",
                    gsa::CodeKind::Sms => "Enter the code Apple sent by text message.",
                };
                let msg = match hint { Some(h) => format!("{h} {where_}"), None => where_.to_string() };
                let options: &[&str] = if kind == gsa::CodeKind::TrustedDevice { &["sms"] } else { &[] };
                app.ask("code", "Two-factor code", &msg, options).await
            })
        });
        self.step("Signing in to Apple");
        let app = self.clone();
        let status = move |text: String| app.step(text);
        let (gs, account) = gsa::login(email.trim(), &password, ask.as_ref(), &status).await.map_err(|e| e.to_string())?;
        account.save().map_err(|e| format!("signed in, but the session could not be saved: {e}"))?;
        self.step("Loading your team");
        let teams = portal::Portal { gs: &gs, account: &account }.teams().await.map_err(|e| e.to_string())?;
        let team = match teams.len() {
            0 => return Err("This Apple ID has no developer team".into()),
            1 => teams[0].clone(),
            _ => {
                let labels: Vec<String> = teams.iter().map(|t| format!("{} ({})", t.name, t.kind)).collect();
                let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
                let pick = self.ask("choice", "Team", "Which team signs your apps?", &refs).await
                    .ok_or("Cancelled")?;
                teams.into_iter().zip(labels).find(|(_, l)| *l == pick).map(|(t, _)| t).ok_or("no team chosen")?
            }
        };
        let _ = std::fs::write(state::path("team"), format!("{}\n{}", team.id, team.name));
        {
            let mut i = self.inner.lock().unwrap();
            i.setup.signed_in = true;
            i.setup.email = account.email.clone();
            i.setup.team = team.id.clone();
            i.setup.team_name = team.name.clone();
        }
        *self.apple.lock().await = Some(Arc::new((gs, account)));
        Ok("Signed in.".into())
    }

    // --- store ----------------------------------------------------------

    pub fn refresh_catalog(&self) {
        let app = self.clone();
        tokio::spawn(async move { app.refresh_catalog_now().await });
    }

    /// Fetches every source again (one fetch at a time: a second call waits
    /// for the running one), then makes every app's icon ready.
    async fn refresh_catalog_now(&self) {
        let running = {
            let mut i = self.inner.lock().unwrap();
            std::mem::replace(&mut i.refreshing, true)
        };
        if running {
            for _ in 0..200 {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                if !self.inner.lock().unwrap().refreshing {
                    break;
                }
            }
            return;
        }
        let (catalog, sources) = store::refresh().await;
        let icons: Vec<String> = catalog.iter().map(|a| a.icon.clone()).collect();
        // Every picture the page may still show; the cache drops the rest.
        let mut keep: Vec<String> = catalog.iter().flat_map(|a| a.screenshots.iter().chain([&a.icon])).cloned().collect();
        keep.extend(install::installed().into_iter().flat_map(|i| [i.shown_icon(), i.icon_url]));
        {
            let mut i = self.inner.lock().unwrap();
            i.catalog = catalog;
            i.sources = sources;
            i.refreshing = false;
        }
        if let Ok(_idle) = self.busy.try_lock() {
            prune_files();
        }
        tokio::spawn(async move {
            let _ = tokio::task::spawn_blocking(move || crate::icons::prune(&keep)).await;
            crate::icons::prefetch(icons, crate::icons::ICON, 2).await;
        });
    }

    /// My Apps › Updates › Check: every source again, and whether a newer
    /// BariStore is published.
    pub async fn check_updates(&self) -> Result<(), String> {
        self.refresh_catalog_now().await;
        self.check_self_update().await
    }

    /// For the install sheet's App ID choice: how many extensions a store
    /// app has, and how many of them Remove extensions takes out.
    pub async fn ipa_info(&self, key: &str, version: usize) -> Result<Json, String> {
        let v = {
            let i = self.inner.lock().unwrap();
            i.catalog.iter().find(|a| a.key == key).and_then(|a| a.versions.get(version)).cloned()
                .ok_or("This version is no longer offered.")?
        };
        let names = store::ipa_names(&v).await?;
        let (extensions, removable) = crate::sign::bundle::extension_counts(names.iter().map(String::as_str));
        Ok(json!({"extensions": extensions, "removable": removable}))
    }

    /// My Apps › an app › Beta updates: which of its source's tracks
    /// (stable, nightly, alpha…) Updates follows.
    pub fn set_channel(&self, bundle_id: &str, channel: &str) -> Result<String, String> {
        let mut list = install::installed();
        let e = list.iter_mut().find(|i| i.bundle_id == bundle_id).ok_or("BariStore did not install this app.")?;
        let offered = {
            let i = self.inner.lock().unwrap();
            i.catalog.iter().filter(|a| a.key == e.store_key).flat_map(|a| &a.versions)
                .any(|v| v.source_url == e.origin && v.channel == channel)
        };
        if !offered {
            return Err("Its source does not offer that track.".into());
        }
        e.channel = channel.to_string();
        install::save_installed(&list);
        Ok(String::new())
    }

    /// Options › Anisette server: "" for automatic, else one of BariStore's
    /// servers or one the user added, which must answer as an anisette v3
    /// server (asked first). Used from the next sign-in: the current session
    /// belongs to the server it was made with.
    pub async fn set_anisette(&self, url: &str) -> Result<String, String> {
        let url = url.trim().trim_end_matches('/');
        if url.is_empty() {
            state::save_settings(&json!({"anisette": ""}));
            return Ok("Automatic: BariStore tries its servers in turn.".into());
        }
        if !anisette::SERVERS.contains(&url) && !anisette::added().iter().any(|s| s == url) {
            return Err("Add the server first.".into());
        }
        self.choose_anisette(url).await
    }

    /// Options › Anisette server › Add: a server of the user's own (http://
    /// too, after the page's warning), checked, kept in the list and chosen.
    pub async fn add_anisette(&self, url: &str) -> Result<String, String> {
        let url = url.trim().trim_end_matches('/');
        let host = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://")).unwrap_or("");
        if host.is_empty() || host.contains(char::is_whitespace) {
            return Err("Enter the server's address, starting with https://".into());
        }
        let message = self.choose_anisette(url).await?;
        let mut list = anisette::added();
        if !anisette::SERVERS.contains(&url) && !list.iter().any(|s| s == url) {
            list.push(url.to_string());
            state::save_settings(&json!({"anisette_servers": list}));
        }
        Ok(message)
    }

    /// Takes a server the user added off the list; Automatic again when it
    /// was the chosen one.
    pub fn remove_anisette(&self, url: &str) {
        let list: Vec<String> = anisette::added().into_iter().filter(|s| s != url).collect();
        state::save_settings(&json!({"anisette_servers": list}));
        if anisette::chosen().as_deref() == Some(url) {
            state::save_settings(&json!({"anisette": ""}));
        }
    }

    async fn choose_anisette(&self, url: &str) -> Result<String, String> {
        let info = anisette::Anisette::advertised(&gsa::http_client(), url).await?;
        state::save_settings(&json!({"anisette": url}));
        logf!("anisette: chosen {url} ({})", info.client_info);
        Ok(format!("Saved. {} answers as {}.", url.split("://").nth(1).unwrap_or(url),
                   info.client_info.split('>').next().unwrap_or("").trim_start_matches('<')))
    }

    pub fn add_source(&self, url: &str) -> Result<(), String> {
        let url = url.trim();
        if !url.starts_with("https://") {
            return Err("The address must start with https://".into());
        }
        let mut list = store::sources();
        if !list.iter().any(|s| s.url == url) {
            let name = store::default_name(url).unwrap_or(url).to_string();
            list.push(store::Source { url: url.into(), name, error: String::new() });
            store::save_sources(&list);
        }
        self.refresh_catalog();
        Ok(())
    }

    pub fn remove_source(&self, url: &str) {
        let mut list = store::sources();
        list.retain(|s| s.url != url);
        store::save_sources(&list);
        self.refresh_catalog();
    }

    async fn ready_to_install(&self) -> Result<(Arc<Session>, Arc<(gsa::GrandSlam, gsa::Account)>), String> {
        self.step("Connecting");
        let s = self.device().await?;
        if services::developer_mode(&s).await? == Some(false) {
            return Err("Developer Mode is off. Turn it on in Settings › Privacy & Security, then try again.".into());
        }
        self.step("Checking your Apple ID");
        let apple = self.apple().await?;
        Ok((s, apple))
    }

    fn team(&self) -> Result<portal::Team, String> {
        let i = self.inner.lock().unwrap();
        if i.setup.team.is_empty() {
            return Err("Sign in to Apple first (Options › Apple ID).".into());
        }
        Ok(portal::Team { id: i.setup.team.clone(), name: i.setup.team_name.clone(), kind: String::new() })
    }

    pub async fn install_version(&self, app_key: &str, version: usize, opts: Options, reuse: install::Reuse)
        -> Result<String, String>
    {
        let (entry, v) = {
            let i = self.inner.lock().unwrap();
            let entry = i.catalog.iter().find(|a| a.key == app_key).cloned().ok_or("This app is no longer in the store.")?;
            let v = entry.versions.get(version).cloned().ok_or("This version is no longer offered.")?;
            (entry, v)
        };
        let (session, apple) = self.ready_to_install().await?;
        let app = self.clone();
        let started = std::time::Instant::now();
        let ipa_path = store::download(&v, &move |done, total| {
            let pct = if total > 0 { (done * 100 / total) as u32 } else { 0 };
            app.progress(format!("Downloading {} of {} MB", done / 1_000_000, total.max(done) / 1_000_000), pct);
        }).await?;
        logf!("install: downloaded in {:.1} s", started.elapsed().as_secs_f64());
        let bytes = tokio::task::block_in_place(|| std::fs::read(&ipa_path)).map_err(|e| e.to_string())?;
        let mut installed = Installed {
            original_id: entry.bundle_id.clone(), name: entry.name.clone(), version: v.version.clone(),
            source_url: v.url.clone(), ipa_path: ipa_path.to_string_lossy().into(), icon_url: entry.icon.clone(),
            store_key: entry.key.clone(), origin: v.source_url.clone(), channel: v.channel.clone(),
            ..Default::default()
        };
        let reuse = replacing(&mut installed, reuse);
        self.sign_and_install(&session, &apple, bytes, opts, reuse, installed).await
    }

    /// Installs an IPA the user picked (uploaded by the page into ipas/).
    pub async fn install_local(&self, path: &str, opts: Options, reuse: install::Reuse) -> Result<String, String> {
        let path = std::path::Path::new(path);
        if path.parent() != Some(state::path("ipas").as_path()) {
            return Err("That file is not one BariStore received.".into());
        }
        let info = crate::sign::bundle::peek(path)?;
        let (session, apple) = self.ready_to_install().await?;
        self.step(format!("Reading {}", info.name));
        let bytes = tokio::task::block_in_place(|| std::fs::read(path)).map_err(|e| e.to_string())?;
        let mut installed = Installed {
            original_id: info.id, name: info.name, version: info.version, ipa_path: path.to_string_lossy().into(),
            icon_url: crate::icons::ipa_icon_url(path), ..Default::default()
        };
        let reuse = replacing(&mut installed, reuse);
        self.sign_and_install(&session, &apple, bytes, opts, reuse, installed).await
    }

    async fn sign_and_install(&self, session: &Session, apple: &(gsa::GrandSlam, gsa::Account), bytes: Vec<u8>,
                              opts: Options, reuse: install::Reuse, mut entry: Installed) -> Result<String, String> {
        let team = self.team()?;
        let (udid, name) = {
            let i = self.inner.lock().unwrap();
            (if session.udid.is_empty() { i.setup.udid.clone() } else { session.udid.clone() }, i.setup.device_name.clone())
        };
        if udid.is_empty() {
            return Err("This iPhone's UDID is unknown. Pair again (Options › Pairing).".into());
        }
        let app = self.clone();
        let ask: Box<install::Asker> = Box::new(move |title, message, options| {
            let app = app.clone();
            Box::pin(async move {
                let refs: Vec<&str> = options.iter().map(String::as_str).collect();
                app.ask("choice", &title, &message, &refs).await
            })
        });
        let previous = (!entry.bundle_id.is_empty()).then(|| (entry.bundle_id.clone(), entry.ids.clone()));
        let ctx = install::Context {
            gs: &apple.0, account: &apple.1, team: &team, udid: &udid,
            device_name: if name.is_empty() { "iPhone" } else { &name },
            session, ask: ask.as_ref(),
            reuse,
            previous: previous.as_ref().map(|(id, ids)| (id.as_str(), ids)),
        };
        let app = self.clone();
        let status = move |s: String| app.step(s);
        let prepared = install::prepare_and_sign(&ctx, bytes, &opts, &status).await?;
        if entry.version.is_empty() {
            entry.version = prepared.version.clone();
        }
        let app = self.clone();
        let status = move |stage: &str, pct: u32| {
            let what = if stage == "Uploading" { "Uploading" } else { "Installing" };
            app.progress(format!("{what} {pct}%"), pct);
        };
        entry.bundle_id = prepared.main_id.clone();
        entry.kind = prepared.kind.to_string();
        entry.cert_serial = prepared.cert_serial.clone();
        entry.ids = prepared.ids.clone();
        entry.increased_memory = prepared.increased_memory;
        entry.team = team.id.clone();
        entry.expires = prepared.expires;
        entry.custom_icon = opts.icon.clone();
        let opts_memory = opts.increased_memory;
        entry.options = opts;
        let started = std::time::Instant::now();
        install::install_signed(session, &prepared.ipa, entry.clone(), &status).await?;
        logf!("install: uploaded and installed {} MB in {:.1} s", prepared.ipa.len() / 1_000_000,
              started.elapsed().as_secs_f64());
        if let Some(record) = flow::load_record().filter(|_| install::reads_pairing_file(&entry.kind)) {
            self.step("Giving the app the pairing file");
            if let Err(e) = install::place_pairing_file(session, &prepared.main_id, &entry.kind, &record).await {
                logf!("install: pairing file not placed: {e}");
            }
        }
        self.inner.lock().unwrap().app_ids = Json::Null;
        let first = install::installed().len() <= 1;
        let memory = if opts_memory && !prepared.increased_memory {
            " Apple did not add Increased Memory Limit to its profile."
        } else { "" };
        let trust = if first {
            " First trust your Apple ID in Settings › General › VPN & Device Management."
        } else { "" };
        // Right after installing LiveContainer (a refresh keeps what it stored).
        let livecontainer = entry.kind == install::LIVECONTAINER || entry.kind == install::LIVECONTAINER_SIDESTORE;
        if livecontainer && previous.is_none() {
            self.offer_next(json!({"label": "Give LiveContainer the certificate", "action": "lc_certificate",
                                   "bundle_id": entry.bundle_id, "name": entry.name}));
            return Ok(format!("{} is installed.{memory}{trust} Then give it the certificate: LiveContainer opens and \
                               stores it for its JIT-less mode.", entry.name));
        }
        Ok(format!("{} is installed.{memory}{trust}", entry.name))
    }

    pub async fn refresh_app(&self, bundle_id: &str) -> Result<String, String> {
        let entry = install::installed().into_iter().find(|i| i.bundle_id == bundle_id)
            .ok_or("BariStore did not install this app.")?;
        self.refresh(vec![entry]).await
    }

    pub async fn refresh_all(&self) -> Result<String, String> {
        let list = install::installed();
        if list.is_empty() {
            return Ok("No apps to refresh.".into());
        }
        self.refresh(list).await
    }

    /// Every app that can takes the quick refresh, all in one pass (new
    /// profiles, nothing signed or uploaded); the others are signed and
    /// installed again, one after another.
    async fn refresh(&self, list: Vec<Installed>) -> Result<String, String> {
        let single = (list.len() == 1).then(|| list[0].name.clone());
        let (session, apple) = self.ready_to_install().await?;
        let team = self.team()?;
        let (udid, device) = {
            let i = self.inner.lock().unwrap();
            (if session.udid.is_empty() { i.setup.udid.clone() } else { session.udid.clone() }, i.setup.device_name.clone())
        };
        let started = std::time::Instant::now();
        let app = self.clone();
        let status = move |s: String| app.step(s);
        let portal = portal::Portal { gs: &apple.0, account: &apple.1 };
        let quick = install::refresh_profiles(&portal, &team.id, &udid, if device.is_empty() { "iPhone" } else { &device },
                                              &session, &list, &status).await;
        let mut slow = Vec::new();
        let mut done = 0;
        match quick {
            Ok(results) => {
                let mut saved = install::installed();
                for (entry, result) in list.into_iter().zip(results) {
                    match result {
                        Ok(r) => {
                            logf!("refresh: {}: new profiles installed, nothing re-signed", entry.name);
                            if let Some(e) = saved.iter_mut().find(|e| e.bundle_id == entry.bundle_id) {
                                e.expires = r.expires;
                                e.cert_serial = r.cert_serial;
                            }
                            done += 1;
                        }
                        Err(why) => {
                            logf!("refresh: {}: quick refresh not possible ({why}); signing again", entry.name);
                            slow.push(entry);
                        }
                    }
                }
                install::save_installed(&saved);
                logf!("refresh: {done} app(s) by new profiles in {:.1} s", started.elapsed().as_secs_f64());
            }
            Err(e) => {
                logf!("refresh: quick refresh not possible ({e}); signing again");
                slow = list;
            }
        }
        let mut failed = Vec::new();
        let total = slow.len();
        for (n, entry) in slow.into_iter().enumerate() {
            if total > 1 {
                if let Some(t) = self.inner.lock().unwrap().task.as_mut() {
                    t.title = format!("Signing again: {} of {total}", n + 1);
                }
            }
            let name = entry.name.clone();
            match self.resign(&session, &apple, entry).await {
                Ok(_) => done += 1,
                Err(err) => {
                    logf!("refresh: {name}: {err}");
                    failed.push(format!("{name}: {err}"));
                }
            }
        }
        let refreshed = match (done, single) {
            (0, _) => String::new(),
            (_, Some(name)) => format!("{name} is refreshed for 7 more days."),
            (n, None) => format!("{n} app{} refreshed for 7 more days.", if n == 1 { "" } else { "s" }),
        };
        if failed.is_empty() {
            Ok(refreshed)
        } else {
            Err(format!("{refreshed}{}Not refreshed:\n{}", if refreshed.is_empty() { "" } else { "\n" }, failed.join("\n")))
        }
    }

    /// The full refresh: signed and installed again from the cached IPA
    /// (downloaded again when the cache was cleared), with its options.
    async fn resign(&self, session: &Session, apple: &(gsa::GrandSlam, gsa::Account), mut entry: Installed)
        -> Result<String, String>
    {
        if !std::path::Path::new(&entry.ipa_path).is_file() {
            // Cleared from the cache: download it again from where it came from.
            if entry.source_url.is_empty() {
                return Err("The IPA this app was installed from is gone. Add it again with Add IPA.".into());
            }
            let v = store::Version {
                source: String::new(), source_url: String::new(), channel: String::new(), version: entry.version.clone(),
                date: String::new(), url: entry.source_url.clone(), size: 0, sha256: String::new(), min_os: String::new(),
                notes: String::new(), warning: String::new(),
            };
            let app = self.clone();
            let path = store::download(&v, &move |done, total| {
                let pct = if total > 0 { (done * 100 / total) as u32 } else { 0 };
                app.progress(format!("Downloading {} of {} MB", done / 1_000_000, total.max(done) / 1_000_000), pct);
            }).await?;
            entry.ipa_path = path.to_string_lossy().into();
        }
        let bytes = tokio::task::block_in_place(|| std::fs::read(&entry.ipa_path)).map_err(|e| e.to_string())?;
        let opts = entry.signing_options();
        self.sign_and_install(session, apple, bytes, opts, install::Reuse::default(), entry).await
    }

    /// The catalog's offer for an installed app: the same app from the same
    /// source and channel (older records: the same download address).
    fn offer(&self, e: &Installed) -> Option<(String, usize, store::Version)> {
        let i = self.inner.lock().unwrap();
        i.catalog.iter().find_map(|a| {
            let at = if !e.store_key.is_empty() {
                (a.key == e.store_key).then(|| a.versions.iter().position(|v| v.source_url == e.origin && v.channel == e.channel))?
            } else {
                (a.bundle_id == e.original_id).then(|| a.versions.iter().position(|v| v.url == e.source_url))?
            }?;
            Some((a.key.clone(), at, a.versions[at].clone()))
        })
    }

    /// Installed apps whose source offers another version.
    pub fn updates(&self) -> Vec<Json> {
        install::installed().iter().filter_map(|e| {
            let (_, _, v) = self.offer(e)?;
            (!v.version.is_empty() && v.version != e.version).then(|| json!({
                "bundle_id": e.bundle_id, "name": e.name, "icon_url": e.shown_icon(), "from": e.version, "to": v.version,
            }))
        }).collect()
    }

    /// Installs the newer version over the app, keeping its App IDs and
    /// options.
    pub async fn update_app(&self, bundle_id: &str) -> Result<String, String> {
        let mut entry = install::installed().into_iter().find(|i| i.bundle_id == bundle_id)
            .ok_or("BariStore did not install this app.")?;
        let (_, _, v) = self.offer(&entry).ok_or("Its source no longer offers it.")?;
        let (session, apple) = self.ready_to_install().await?;
        let app = self.clone();
        let path = store::download(&v, &move |done, total| {
            let pct = if total > 0 { (done * 100 / total) as u32 } else { 0 };
            app.progress(format!("Downloading {} of {} MB", done / 1_000_000, total.max(done) / 1_000_000), pct);
        }).await?;
        let old = std::mem::replace(&mut entry.ipa_path, path.to_string_lossy().into());
        if old != entry.ipa_path && !install::installed().iter().any(|o| o.bundle_id != entry.bundle_id && o.ipa_path == old) {
            let _ = std::fs::remove_file(&old);
        }
        let name = entry.name.clone();
        entry.version = v.version.clone();
        entry.source_url = v.url.clone();
        let bytes = tokio::task::block_in_place(|| std::fs::read(&entry.ipa_path)).map_err(|e| e.to_string())?;
        let opts = entry.signing_options();
        self.sign_and_install(&session, &apple, bytes, opts, install::Reuse::default(), entry).await?;
        Ok(format!("{name} is updated to {}.", v.version))
    }

    pub async fn update_all(&self) -> Result<String, String> {
        let list = self.updates();
        let mut failed = Vec::new();
        for (n, u) in list.iter().enumerate() {
            let (id, name) = (u["bundle_id"].as_str().unwrap_or(""), u["name"].as_str().unwrap_or(""));
            if let Some(t) = self.inner.lock().unwrap().task.as_mut() {
                t.title = format!("Updating {} of {}", n + 1, list.len());
            }
            if let Err(err) = self.update_app(id).await {
                logf!("update: {name}: {err}");
                failed.push(format!("{name}: {err}"));
            }
        }
        if failed.is_empty() {
            Ok(format!("{} app{} updated.", list.len(), if list.len() == 1 { "" } else { "s" }))
        } else {
            Err(failed.join("\n"))
        }
    }

    /// The install sheet's custom App ID: what was typed, checked, with the
    /// team appended.
    pub fn custom_app_id(&self, typed: &str) -> Result<String, String> {
        install::custom_identifier(typed, &self.team()?.id)
    }

    /// My Apps › an app › Increased Memory Limit or Change icon. Both live in
    /// the app's signature, so they are kept in its options (every later
    /// signing applies them: an update, a full refresh, Install again).
    /// Whether BariStore still has its IPA to sign it again now; nothing is
    /// downloaded for this.
    pub fn set_app_options(&self, bundle_id: &str, memory: bool, icon: Option<&str>) -> Result<bool, String> {
        let mut list = install::installed();
        let e = list.iter_mut().find(|i| i.bundle_id == bundle_id).ok_or("BariStore did not install this app.")?;
        if let Some(icon) = icon {
            if !icon.is_empty() && crate::icons::custom_icon(icon).is_none() {
                return Err("The icon you chose is gone: choose it again.".into());
            }
            e.options.icon = icon.to_string();
        }
        e.options.increased_memory |= memory;
        let kept = std::path::Path::new(&e.ipa_path).is_file();
        install::save_installed(&list);
        Ok(kept)
    }

    /// Signs an app again from the IPA BariStore still has, with its options,
    /// and installs it over itself: its data and App IDs stay.
    pub async fn sign_again(&self, bundle_id: &str) -> Result<String, String> {
        let entry = install::installed().into_iter().find(|i| i.bundle_id == bundle_id)
            .ok_or("BariStore did not install this app.")?;
        if !std::path::Path::new(&entry.ipa_path).is_file() {
            return Err("BariStore no longer has this app's IPA. The change is kept for its next update.".into());
        }
        let (session, apple) = self.ready_to_install().await?;
        self.resign(&session, &apple, entry).await
    }

    /// Install to LiveContainer, for an app from a source. An app from one
    /// of the user's AltSources goes through LiveContainer's own Sources:
    /// when LiveContainer does not list that source yet, it gets it
    /// (livecontainer://source?url=, LCAltStoreSourcesView) and shows its
    /// apps, this one installed from there with a tap. Otherwise
    /// LiveContainer downloads the IPA itself (livecontainer://install?url=,
    /// LCAppListView.handleURL; what its Sources tab does too). iOS lets an
    /// app open only one other app at a time, so both cannot be sent.
    pub async fn lc_install(&self, key: &str, version: usize) -> Result<String, String> {
        let (name, v) = {
            let i = self.inner.lock().unwrap();
            let app = i.catalog.iter().find(|a| a.key == key).ok_or("This app is no longer in the store.")?;
            (app.name.clone(), app.versions.get(version).ok_or("This version is no longer offered.")?.clone())
        };
        if let Some(source) = store::sources().into_iter().find(|s| s.url == v.source_url) {
            self.step("Checking LiveContainer's sources");
            match self.lc_sources().await {
                Ok(listed) if !listed.iter().any(|u| u.trim_end_matches('/') == source.url.trim_end_matches('/')) => {
                    self.step("Opening LiveContainer");
                    open_livecontainer(&format!("livecontainer://source?url={}", install::percent_encode(&source.url)))
                        .await?;
                    return Ok(format!("LiveContainer has {} in its Sources now and shows its apps: tap {name} there                                        to install it.", source.name));
                }
                Ok(_) => {}
                Err(e) => logf!("livecontainer: its sources cannot be read ({e}); installing {name} directly"),
            }
        }
        self.step("Opening LiveContainer");
        open_livecontainer(&format!("livecontainer://install?url={}", install::percent_encode(&v.url))).await?;
        Ok(format!("LiveContainer downloads and installs {name}."))
    }

    /// The AltSources LiveContainer lists (LCAltStoreSourceURLs in its
    /// preferences, read through house_arrest: a development-signed app's
    /// container).
    async fn lc_sources(&self) -> Result<Vec<String>, String> {
        let s = self.device().await?;
        let id = services::installed_apps(&s).await?.iter()
            .filter_map(|d| d.get("CFBundleIdentifier").and_then(plist::Value::as_string).map(str::to_string))
            .find(|id| id.starts_with("com.kdt.livecontainer"))
            .or_else(|| install::installed().into_iter()
                .find(|i| i.kind == install::LIVECONTAINER || i.kind == install::LIVECONTAINER_SIDESTORE).map(|i| i.bundle_id))
            .ok_or("LiveContainer is not on this iPhone")?;
        let mut afc = services::app_container(&s, &id, false).await?;
        let prefs = afc.read_file(&format!("/Library/Preferences/{id}.plist"), 4 << 20).await.unwrap_or_default();
        if prefs.is_empty() {
            return Ok(Vec::new());
        }
        let prefs = plist::from_bytes::<plist::Value>(&prefs).map_err(|e| e.to_string())?;
        Ok(prefs.as_dictionary().and_then(|d| d.get("LCAltStoreSourceURLs")).and_then(plist::Value::as_array)
            .map(|list| list.iter().filter_map(plist::Value::as_string).map(str::to_string).collect())
            .unwrap_or_default())
    }

    /// Install to LiveContainer, for an added IPA: BariStore hands the file
    /// to LiveContainer from its own address (a path made for this one
    /// file) and stays until it was all sent.
    pub async fn lc_install_local(&self, path: &str) -> Result<String, String> {
        let path = std::path::Path::new(path);
        if path.parent() != Some(state::path("ipas").as_path()) {
            return Err("That file is not one BariStore received.".into());
        }
        let info = crate::sign::bundle::peek(path)?;
        let share = crate::web::Share::new(path)?;
        self.step("Opening LiveContainer");
        open_livecontainer(&format!("livecontainer://install?url={}", install::percent_encode(&share.url()))).await?;
        self.step(format!("Waiting for LiveContainer to ask for {}", info.name));
        let mut last = (0, std::time::Instant::now());
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let (sent, size) = (share.sent(), share.size());
            if share.done() {
                break;
            }
            if sent != last.0 {
                last = (sent, std::time::Instant::now());
                self.progress(format!("LiveContainer is receiving {}: {} of {} MB", info.name, sent / 1_000_000,
                                      size / 1_000_000), (sent * 100 / size.max(1)) as u32);
            } else if last.1.elapsed() > std::time::Duration::from_secs(if sent == 0 { 120 } else { 60 }) {
                return Err(if sent == 0 {
                    "LiveContainer did not ask for the app. Open LiveContainer, then try again.".into()
                } else {
                    "LiveContainer stopped receiving the app. Try again.".into()
                });
            }
        }
        logf!("livecontainer: {} sent ({} MB)", info.name, share.size() / 1_000_000);
        Ok(format!("LiveContainer received {} and installs it now.", info.name))
    }

    /// Whether the release BariStore updates from holds a build other than
    /// this one (My Apps › Updates shows BariStore then).
    pub async fn check_self_update(&self) -> Result<(), String> {
        let newer = crate::update::newer_available().await?;
        self.inner.lock().unwrap().self_update = Some(newer);
        Ok(())
    }

    /// The team's App IDs for My Apps: each one's app, expiry, and how many
    /// a free team has left.
    pub async fn load_app_ids(&self) -> Result<(), String> {
        let apple = self.apple().await?;
        let team = self.team()?;
        let ids = portal::Portal { gs: &apple.0, account: &apple.1 }.app_ids(&team.id).await.map_err(|e| e.to_string())?;
        // Which app holds each App ID: the apps on the iPhone (any tool's),
        // else BariStore's own list when the iPhone cannot be reached.
        let mut apps: Vec<(String, String)> = install::installed().into_iter().map(|i| (i.bundle_id, i.name)).collect();
        if let Ok(s) = self.device().await {
            if let Ok(list) = services::installed_apps(&s).await {
                let on_device = device_list(&list);
                apps = on_device.iter().filter(|d| d["name"] != "")
                    .map(|d| (d["bundle_id"].as_str().unwrap_or("").to_string(), d["name"].as_str().unwrap_or("").to_string()))
                    .collect();
                self.inner.lock().unwrap().device_apps = on_device;
            }
        }
        let list = label_app_ids(&ids, &apps, &install::installed());
        self.inner.lock().unwrap().app_ids = json!({
            "list": list, "left": portal::FREE_APP_IDS.saturating_sub(ids.len()), "max": portal::FREE_APP_IDS,
        });
        Ok(())
    }

    /// Options › Apple ID › Certificates: the team's development certificates.
    pub async fn certificates(&self) -> Result<Json, String> {
        let apple = self.apple().await?;
        let team = self.team()?;
        let list = portal::Portal { gs: &apple.0, account: &apple.1 }.certificate_list(&team.id).await
            .map_err(|e| e.to_string())?;
        Ok(json!(list))
    }

    pub async fn revoke_certificate(&self, serial: &str) -> Result<String, String> {
        let apple = self.apple().await?;
        let team = self.team()?;
        self.step("Revoking the certificate");
        portal::Portal { gs: &apple.0, account: &apple.1 }.revoke(&team.id, serial).await.map_err(|e| e.to_string())?;
        logf!("certificates: revoked {serial}");
        Ok("Revoked. Apps signed with it stop opening until they are installed again.".into())
    }

    /// BariStore's signing certificate as a .p12 with a new password (for
    /// LiveContainer's own import, or any other tool).
    async fn signing_p12(&self) -> Result<(Vec<u8>, String), String> {
        let apple = self.apple().await?;
        let team = self.team()?;
        let app = self.clone();
        let ask: Box<install::Asker> = Box::new(move |title, message, options| {
            let app = app.clone();
            Box::pin(async move {
                let refs: Vec<&str> = options.iter().map(String::as_str).collect();
                app.ask("choice", &title, &message, &refs).await
            })
        });
        self.step("Loading the signing certificate");
        let cert = install::certificate(&portal::Portal { gs: &apple.0, account: &apple.1 }, &team.id, ask.as_ref()).await?;
        let password = install::p12_password();
        let p12 = crate::sign::p12::pkcs12(&cert.der, &cert.key, &password, "BariStore")?;
        Ok((p12, password))
    }

    /// Options › Apple ID › Export certificate: the page shares the file.
    pub async fn export_certificate(&self) -> Result<Json, String> {
        use base64::Engine;
        let (p12, password) = self.signing_p12().await?;
        Ok(json!({"name": "BariStore-Certificate.p12", "type": "application/x-pkcs12",
                  "base64": base64::engine::general_purpose::STANDARD.encode(p12), "password": password}))
    }

    /// LiveContainer stores the certificate (JIT-less mode) from its
    /// livecontainer://certificate URL, the way SideStore hands it over.
    pub async fn lc_certificate(&self) -> Result<String, String> {
        let (p12, password) = self.signing_p12().await?;
        self.step("Opening LiveContainer");
        match minis::open_url(&install::livecontainer_certificate_url(&p12, &password)).await {
            Ok(true) => Ok("Sent to LiveContainer: its Settings tab shows the certificate. If iOS said Untrusted \
                            Developer, trust your Apple ID in Settings › General › VPN & Device Management and try \
                            again.".into()),
            Ok(false) => Err("iOS did not open LiveContainer. Trust your Apple ID in Settings › General › VPN & \
                              Device Management, open LiveContainer once, then try again.".into()),
            Err(e) => Err(format!("Minis could not open LiveContainer: {e}")),
        }
    }

    /// JIT for an app BariStore installed: the developer disk image (once),
    /// then the app started under the debugger.
    pub async fn enable_jit(&self, bundle_id: &str) -> Result<String, String> {
        let name = install::installed().into_iter().find(|i| i.bundle_id == bundle_id).map(|i| i.name)
            .ok_or("BariStore did not install this app.")?;
        let s = self.device().await?;
        if services::developer_mode(&s).await? == Some(false) {
            return Err("Developer Mode is off. Turn it on in Settings › Privacy & Security, then try again.".into());
        }
        let app = self.clone();
        let progress = move |text: String| app.step(text);
        self.step("Checking the developer disk image");
        if !crate::device::jit::ddi_installed(&s).await? {
            let bytes = crate::device::jit::ddi_download_size().await?;
            if bytes > 0 {
                let message = format!("The first time, JIT needs Apple's developer disk image: about {} MB is \
                                       downloaded once.", bytes.div_ceil(1_000_000));
                let pick = self.ask("choice", "Developer disk image", &message, &["Download", "Cancel"]).await;
                if pick.as_deref() != Some("Download") {
                    return Err("Cancelled: nothing was downloaded.".into());
                }
            }
        }
        let s = if crate::device::jit::ensure_ddi(&s, &progress).await? {
            // The debugger service appears with the image: ask RSD again.
            *self.session.lock().await = None;
            self.device().await?
        } else {
            s
        };
        crate::device::jit::enable(&s, bundle_id, &name, &progress).await
    }

    pub async fn delete_app(&self, bundle_id: &str) -> Result<String, String> {
        let s = self.device().await?;
        self.step("Deleting");
        services::uninstall(&s, bundle_id).await?;
        let mut list = install::installed();
        if let Some(e) = list.iter().find(|i| i.bundle_id == bundle_id) {
            let still_used = list.iter().filter(|o| o.ipa_path == e.ipa_path).count() > 1;
            if !still_used {
                let _ = std::fs::remove_file(&e.ipa_path);
            }
        }
        list.retain(|i| i.bundle_id != bundle_id);
        install::save_installed(&list);
        self.load_device_apps().await.ok();
        self.inner.lock().unwrap().app_ids = Json::Null;
        Ok("Deleted. Its App IDs stay reserved until they expire and can be reused.".into())
    }

    pub async fn load_device_apps(&self) -> Result<(), String> {
        let s = self.device().await?;
        let list = device_list(&services::installed_apps(&s).await?);
        self.inner.lock().unwrap().device_apps = list;
        Ok(())
    }

    pub async fn place_pairing(&self, bundle_id: &str) -> Result<String, String> {
        let kind = install::installed().into_iter().find(|i| i.bundle_id == bundle_id).map(|i| i.kind)
            .unwrap_or_default();
        if !install::reads_pairing_file(&kind) {
            return Err("This app does not read a pairing file.".into());
        }
        let s = self.device().await?;
        let record = flow::load_record().ok_or("This iPhone is not paired yet.")?;
        if install::place_pairing_file(&s, bundle_id, &kind, &record).await? {
            Ok("The app has the pairing file now.".into())
        } else {
            Err("This app does not read a pairing file.".into())
        }
    }

    /// Options › Pairing › Export: the page shares the file (share sheet:
    /// Save to Files, AirDrop, another app).
    pub fn export_pairing(&self) -> Result<Json, String> {
        use base64::Engine;
        let record = flow::load_record().ok_or("This iPhone is not paired yet.")?;
        Ok(json!({"name": "BariStore-Pairing.plist", "type": "application/x-plist",
                  "base64": base64::engine::general_purpose::STANDARD.encode(record.to_remote_only_xml())}))
    }

    pub async fn sign_out(&self) {
        let _ = std::fs::remove_file(state::path("account.plist"));
        *self.apple.lock().await = None;
        let mut i = self.inner.lock().unwrap();
        i.setup.signed_in = false;
        i.setup.email.clear();
    }

    /// Forgets everything except installed apps on the iPhone itself.
    pub async fn reset(&self) {
        *self.apple.lock().await = None;
        *self.session.lock().await = None;
        for name in ["account.plist", "team", "pairing.plist", "host.plist", "installed.json", "catalog.json",
                     "sources.json", "settings.json", "signing-key.der", "anisette-server", "host-uuid",
                     "device-port", "silence.wav", "server.out", "defaults-seen"] {
            let _ = std::fs::remove_file(state::path(name));
        }
        let _ = std::fs::remove_dir_all(state::path("ipas"));
        let _ = std::fs::remove_dir_all(state::path("icons"));
        let _ = std::fs::remove_dir_all(crate::icons::custom_dir());
        if let Ok(dir) = std::fs::read_dir(state::home()) {
            for e in dir.flatten() {
                if e.file_name().to_string_lossy().starts_with("anisette-") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        let mut i = self.inner.lock().unwrap();
        *i = Inner::default();
        i.sources = store::sources();
        i.catalog = store::cached_catalog();
    }

    /// Options › Clear cache: icons, the catalog copy and every IPA, added
    /// ones too (owner, 1.1.0: the IPA just installed stayed and its size
    /// with it). An app signed again later (a new certificate) is downloaded
    /// again; an added one must be added again. While a task runs, the IPAs
    /// of the last hour stay (it may be using one).
    pub fn clear_cache(&self) -> String {
        let hour_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
        let busy = self.busy();
        let mut freed = dir_size(&state::path("icons"));
        let _ = std::fs::remove_dir_all(state::path("icons"));
        if let Ok(meta) = std::fs::metadata(state::path("catalog.json")) {
            freed += meta.len();
        }
        let _ = std::fs::remove_file(state::path("catalog.json"));
        if let Ok(dir) = std::fs::read_dir(state::path("ipas")) {
            for e in dir.flatten() {
                let Ok(meta) = e.metadata() else { continue };
                if busy && meta.modified().map_or(true, |m| m > hour_ago) {
                    continue;
                }
                if std::fs::remove_file(e.path()).is_ok() {
                    freed += meta.len();
                }
            }
        }
        logf!("cache: cleared {} MB", freed / 1_000_000);
        format!("Freed {} MB.", (freed + 500_000) / 1_000_000)
    }

    pub fn cache_size(&self) -> u64 {
        dir_size(&state::path("icons")) + dir_size(&state::path("ipas"))
            + std::fs::metadata(state::path("catalog.json")).map(|m| m.len()).unwrap_or(0)
    }

    /// Options › Update BariStore: the newest build, then a restart into it.
    pub async fn update(&self) -> Result<String, String> {
        let app = self.clone();
        match crate::update::download_and_replace(&move |s| app.step(s)).await? {
            crate::update::Outcome::UpToDate => Ok(format!("BariStore {} is the newest build.", env!("CARGO_PKG_VERSION"))),
            crate::update::Outcome::Updated(version) => {
                // The supervisor starts the new build at the same address.
                tokio::spawn(async {
                    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
                    std::process::exit(crate::UPDATED);
                });
                Ok(format!("Updated to {version}. BariStore restarts; this page reloads by itself."))
            }
        }
    }
}

/// The iPhone's apps as the page gets them (whoever installed them: the
/// page finds LiveContainer among them).
fn device_list(apps: &[plist::Dictionary]) -> Vec<Json> {
    apps.iter().map(|d| {
        let t = |k: &str| d.get(k).and_then(plist::Value::as_string).unwrap_or("").to_string();
        json!({"bundle_id": t("CFBundleIdentifier"), "name": if t("CFBundleDisplayName").is_empty() { t("CFBundleName") } else { t("CFBundleDisplayName") },
               "version": t("CFBundleShortVersionString"), "signer": t("SignerIdentity")})
    }).collect()
}

/// Opens a livecontainer:// URL (through iOS: Minis's browser cannot).
async fn open_livecontainer(url: &str) -> Result<(), String> {
    match minis::open_url(url).await {
        Ok(true) => Ok(()),
        Ok(false) => Err("iOS did not open LiveContainer. Install it (Featured › LiveContainer), trust your Apple ID \
                          in Settings › General › VPN & Device Management, open it once, then try again.".into()),
        Err(e) => Err(format!("Minis could not open LiveContainer: {e}")),
    }
}

/// The install sheet's "Replace": the App ID picked is the one a copy of
/// the same app that BariStore installed has. The new build goes over it as
/// an update does: under its App IDs (extensions' too), keeping its data,
/// and in its place in My Apps.
fn replacing(entry: &mut Installed, reuse: install::Reuse) -> install::Reuse {
    let copy = reuse.pick.as_deref().and_then(|pick| install::installed().into_iter()
        .find(|i| i.bundle_id == pick && i.original_id == entry.original_id));
    match copy {
        Some(copy) => {
            logf!("install: {} goes over {} ({})", entry.name, copy.name, copy.bundle_id);
            entry.bundle_id = copy.bundle_id;
            entry.ids = copy.ids;
            install::Reuse::default()
        }
        None => reuse,
    }
}

/// What My Apps says about each App ID. An app installed under the App ID
/// of another (a reused one) is named as the App ID, "used by" the app;
/// its extensions' App IDs, made under that App ID, are named as the app,
/// "created under" the App ID. A free App ID under another says which.
fn label_app_ids(ids: &[portal::AppId], apps: &[(String, String)], installed: &[Installed]) -> Vec<Json> {
    // The app on the iPhone an identifier belongs to: itself, or the app it
    // is an extension of (the longest match).
    let holder = |id: &str| apps.iter().filter(|(b, _)| id == b || id.starts_with(&format!("{b}.")))
        .max_by_key(|(b, _)| b.len());
    let app_id_name = |id: &str| ids.iter().find(|a| a.identifier == id).map(|a| a.name.clone());
    // Whether `bundle` is an App ID first made for another app: BariStore's
    // own record says so; for other tools' apps, the App ID's name differs.
    let reused = |bundle: &str, app_name: &str| match installed.iter().find(|e| e.bundle_id == bundle) {
        Some(e) => !e.original_id.is_empty() && !bundle.starts_with(&e.original_id),
        None => app_id_name(bundle).is_some_and(|n| !n.eq_ignore_ascii_case(&portal::clean_name(app_name))),
    };
    ids.iter().map(|a| {
        let (title, note, app) = match holder(&a.identifier) {
            Some((bundle, name)) if *bundle == a.identifier => {
                if reused(bundle, name) {
                    (a.name.clone(), format!("used by {name}"), name.clone())
                } else {
                    (name.clone(), String::new(), name.clone())
                }
            }
            Some((bundle, name)) => {
                let note = match app_id_name(bundle).filter(|_| reused(bundle, name)) {
                    Some(parent) => format!("created under the {parent} App ID"),
                    None => "extension".into(),
                };
                (name.clone(), note, name.clone())
            }
            None => {
                let parent = ids.iter().filter(|p| a.identifier.starts_with(&format!("{}.", p.identifier)))
                    .max_by_key(|p| p.identifier.len());
                (a.name.clone(), parent.map(|p| format!("under {}", p.name)).unwrap_or_default(), String::new())
            }
        };
        json!({"identifier": a.identifier, "name": a.name, "expires": a.expires, "app": app,
               "title": title, "note": note})
    }).collect()
}

/// Changes when the server restarts: the page reloads itself then.
pub fn boot_id() -> &'static str {
    static BOOT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    BOOT.get_or_init(|| format!("{}-{}", std::process::id(), std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis()))
}

/// Drops the IPAs no installed app needs (other versions, apps deleted or
/// replaced, IPAs added but never installed) and broken downloads, and the
/// icons chosen for no installed app. Files from the last hour stay: an
/// install sheet may be open for one, or a failed install be tried again.
/// Run while no task is.
fn prune_files() {
    let installed = install::installed();
    let keep: Vec<std::path::PathBuf> = installed.iter().map(|i| i.ipa_path.clone().into())
        .chain(installed.iter().flat_map(|i| [&i.options.icon, &i.custom_icon])
            .filter(|n| !n.is_empty()).map(|n| crate::icons::custom_dir().join(n)))
        .collect();
    let hour_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    let mut freed = 0;
    for dir in [state::path("ipas"), crate::icons::custom_dir()] {
        let Ok(dir) = std::fs::read_dir(dir) else { continue };
        for e in dir.flatten() {
            let Ok(meta) = e.metadata() else { continue };
            if meta.modified().map_or(true, |m| m > hour_ago) || keep.contains(&e.path()) {
                continue;
            }
            if std::fs::remove_file(e.path()).is_ok() {
                freed += meta.len();
            }
        }
    }
    if freed > 0 {
        logf!("cache: {} MB of IPAs no app needs removed", freed / 1_000_000);
    }
}

fn dir_size(dir: &std::path::Path) -> u64 {
    std::fs::read_dir(dir).map(|d| d.flatten().filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum()).unwrap_or(0)
}

pub fn minis_ok() -> bool {
    minis::available("minis-bonjour")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_id_labels() {
        let id = |identifier: &str, name: &str| portal::AppId {
            id: identifier.into(), identifier: identifier.into(), name: name.into(), features: Default::default(), expires: 0,
        };
        let ids = [id("com.rileytestut.AltStore.T", "AltStore"), id("com.rileytestut.AltStore.T.Widget", "HuskWidget"),
                   id("com.kdt.livecontainer.T", "LiveContainer"), id("com.kdt.livecontainer.T.Share", "LCShare"),
                   id("com.SideStore.SideStore.T", "SideStore"), id("com.SideStore.SideStore.T.AltWidget", "AltWidget")];
        let apps = [("com.rileytestut.AltStore.T".to_string(), "Husk".to_string()),
                    ("com.kdt.livecontainer.T".to_string(), "LiveContainer".to_string())];
        let installed = [Installed { bundle_id: "com.rileytestut.AltStore.T".into(), original_id: "com.leviidev.Husk".into(),
                                     ..Default::default() }];
        let labels = label_app_ids(&ids, &apps, &installed);
        let row = |i: usize| (labels[i]["title"].as_str().unwrap(), labels[i]["note"].as_str().unwrap(),
                              labels[i]["app"].as_str().unwrap());
        assert_eq!(row(0), ("AltStore", "used by Husk", "Husk"));
        assert_eq!(row(1), ("Husk", "created under the AltStore App ID", "Husk"));
        assert_eq!(row(2), ("LiveContainer", "", "LiveContainer"));
        assert_eq!(row(3), ("LiveContainer", "extension", "LiveContainer"));
        assert_eq!(row(4), ("SideStore", "", ""));
        assert_eq!(row(5), ("AltWidget", "under SideStore", ""));
    }
}
