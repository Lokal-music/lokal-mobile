//! Morneye add-ons run in QuickJS, as on desktop (Lokal's
//! electron/morneye/worker.js and runtime.js).
//!
//! Each add-on gets its own thread, runtime and context. The guest sees one
//! synchronous `host(method, json)` function (desktop's bootstrap prelude
//! builds `http`, `file`, `storage`… on top of it). Its calls go to the app,
//! which answers asynchronously, while this thread waits; a progress callback
//! the app sends meanwhile runs inside that wait, and may call the host again.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures::channel::oneshot;
use futures::future::BoxFuture;
use rquickjs::context::EvalOptions;
use rquickjs::{Context, Ctx, Exception, Function, Object, Persistent, Runtime, Value};

/// Answers a guest's host call: (method, JSON arguments) → JSON reply.
pub type Host = Arc<dyn Fn(String, String) -> BoxFuture<'static, String> + Send + Sync>;

const NO_DEADLINE: u64 = u64::MAX;
const MEMORY_LIMIT: usize = 64 * 1024 * 1024;
const MAX_DOWNLOAD_MEMORY_LIMIT: usize = 256 * 1024 * 1024;

/// Normal source browsing remains lightweight. The desktop runtime allocates
/// 512 MiB for downloads; Android uses a bounded 256 MiB budget to avoid
/// rejecting otherwise valid extension jobs on the default 64 MiB heap.
fn guest_memory_limit(config_json: &str) -> usize {
    let requested = serde_json::from_str::<serde_json::Value>(config_json)
        .ok()
        .and_then(|config| config.get("heapMb")?.as_u64())
        .unwrap_or(64);
    requested.clamp(64, 256) as usize * 1024 * 1024
}
const STACK_LIMIT: usize = 512 * 1024;
const START_TIMEOUT_MS: u64 = 30_000;

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

enum Msg {
    Invoke { method: String, args: String, timeout_ms: u64, reply: oneshot::Sender<Result<String, String>> },
    Reply { call: u64, json: String },
    Callback { id: u64, args: String, ack: oneshot::Sender<String> },
    Close,
}

/// One running add-on.
pub struct Engine {
    tx: Mutex<mpsc::Sender<Msg>>,
    closed: Arc<AtomicBool>,
    methods: Vec<String>,
}

impl Engine {
    /// Loads [code] after desktop's [bootstrap] prelude with [config]; fails
    /// when the package doesn't call `registerExtension()` or takes too long.
    pub fn start(code: String, bootstrap: String, config_json: String, host: Host) -> Result<Engine, String> {
        let (tx, rx) = mpsc::channel::<Msg>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<Vec<String>, String>>();
        let closed = Arc::new(AtomicBool::new(false));
        let thread_tx = tx.clone();
        let thread_closed = closed.clone();
        std::thread::Builder::new()
            .name("morneye".into())
            .stack_size(8 * 1024 * 1024)
            .spawn(move || run(code, bootstrap, config_json, host, rx, thread_tx, thread_closed, ready_tx))
            .map_err(|e| e.to_string())?;
        let methods = match ready_rx.recv_timeout(Duration::from_millis(START_TIMEOUT_MS + 2_000)) {
            Ok(result) => result,
            Err(_) => Err("Extension loading timed out".to_string()),
        };
        match methods {
            Ok(methods) => Ok(Engine { tx: Mutex::new(tx), closed, methods }),
            Err(error) => {
                closed.store(true, Ordering::SeqCst);
                let _ = tx.send(Msg::Close);
                Err(error)
            }
        }
    }

    /// The functions the package registered.
    pub fn methods(&self) -> Vec<String> {
        self.methods.clone()
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    fn send(&self, msg: Msg) -> bool {
        !self.is_closed() && self.tx.lock().map(|tx| tx.send(msg).is_ok()).unwrap_or(false)
    }

    /// Calls the add-on's [method] with JSON [args]; resolves to its JSON result.
    pub async fn invoke(&self, method: String, args: String, timeout_ms: u64) -> Result<String, String> {
        let (reply, answer) = oneshot::channel();
        if !self.send(Msg::Invoke { method, args, timeout_ms, reply }) {
            return Err("Extension runtime closed".into());
        }
        answer.await.unwrap_or_else(|_| Err("Extension runtime closed".into()))
    }

    /// Runs the guest callback [id] (a progress function it passed to the
    /// host) while the host call it belongs to is waiting. Resolves to the
    /// guest's error message, empty when it succeeded.
    pub async fn callback(&self, id: u64, args: String) -> String {
        let (ack, answer) = oneshot::channel();
        if !self.send(Msg::Callback { id, args, ack }) {
            return "Extension operation cancelled".into();
        }
        answer.await.unwrap_or_else(|_| "Extension operation cancelled".into())
    }

    /// Stops the add-on; anything waiting on it fails.
    pub fn close(&self) {
        if !self.closed.swap(true, Ordering::SeqCst) {
            if let Ok(tx) = self.tx.lock() {
                let _ = tx.send(Msg::Close);
            }
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.close();
    }
}

/// State the guest's host function shares with the loop that runs invokes.
struct Shared {
    rx: mpsc::Receiver<Msg>,
    tx: mpsc::Sender<Msg>,
    host: Host,
    closed: Arc<AtomicBool>,
    deadline: Arc<AtomicU64>,
    next_call: RefCell<u64>,
    /// Invokes that arrived during a host call wait their turn.
    queued: RefCell<VecDeque<Msg>>,
    /// Replies to an outer call that arrived while an inner one waited.
    replies: RefCell<HashMap<u64, String>>,
    api: RefCell<Option<Persistent<Object<'static>>>>,
}

fn message(ctx: &Ctx<'_>, error: rquickjs::Error) -> String {
    let text = if let rquickjs::Error::Exception = error {
        let value = ctx.catch();
        if let Some(exception) = value.as_exception() {
            exception.message().unwrap_or_else(|| "Extension error".into())
        } else if let Some(text) = value.as_string().and_then(|s| s.to_string().ok()) {
            text
        } else {
            "Extension error".into()
        }
    } else {
        error.to_string()
    };
    // QuickJS's interrupt surfaces as an uncatchable "interrupted" error.
    if text.to_lowercase().contains("interrupted") { "Extension execution timed out".into() } else { text }
}

/// The guest's synchronous view of an asynchronous host call.
fn bridge<'js>(ctx: Ctx<'js>, shared: &Shared, method: String, json: String) -> rquickjs::Result<String> {
    let call = {
        let mut next = shared.next_call.borrow_mut();
        *next += 1;
        *next
    };
    let host = shared.host.clone();
    let tx = shared.tx.clone();
    std::thread::spawn(move || {
        let json = futures::executor::block_on(host(method, json));
        let _ = tx.send(Msg::Reply { call, json });
    });
    loop {
        if let Some(json) = shared.replies.borrow_mut().remove(&call) {
            return Ok(json);
        }
        if shared.closed.load(Ordering::SeqCst) {
            return Err(Exception::throw_message(&ctx, "Extension operation cancelled"));
        }
        if now_ms() > shared.deadline.load(Ordering::SeqCst) {
            return Err(Exception::throw_message(&ctx, "Extension execution timed out"));
        }
        match shared.rx.recv_timeout(Duration::from_millis(250)) {
            Ok(Msg::Reply { call: id, json }) if id == call => return Ok(json),
            Ok(Msg::Reply { call: id, json }) => {
                shared.replies.borrow_mut().insert(id, json);
            }
            Ok(Msg::Callback { id, args, ack }) => {
                let _ = ack.send(run_callback(&ctx, shared, id, args));
            }
            Ok(Msg::Close) => {
                shared.closed.store(true, Ordering::SeqCst);
                return Err(Exception::throw_message(&ctx, "Extension operation cancelled"));
            }
            Ok(invoke @ Msg::Invoke { .. }) => shared.queued.borrow_mut().push_back(invoke),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(Exception::throw_message(&ctx, "Extension operation cancelled"));
            }
        }
    }
}

fn api<'js>(ctx: &Ctx<'js>, shared: &Shared) -> rquickjs::Result<Object<'js>> {
    let saved = shared.api.borrow().clone();
    match saved {
        Some(api) => api.restore(ctx),
        None => Err(rquickjs::Error::new_from_js("undefined", "object")),
    }
}

fn run_callback(ctx: &Ctx<'_>, shared: &Shared, id: u64, args: String) -> String {
    let result = (|| -> rquickjs::Result<()> {
        let callback: Function = api(ctx, shared)?.get("callback")?;
        let value: Value = callback.call((id as f64, args))?;
        // A callback that returns a promise is settled before acknowledging.
        if let Some(promise) = value.as_promise() {
            promise.finish::<Value>()?;
        }
        Ok(())
    })();
    match result {
        Ok(()) => String::new(),
        Err(error) => message(ctx, error),
    }
}

fn invoke(ctx: &Ctx<'_>, shared: &Shared, method: &str, args: &str) -> Result<String, String> {
    let result = (|| -> rquickjs::Result<String> {
        let invoke: Function = api(ctx, shared)?.get("invoke")?;
        let value: Value = invoke.call((method, args))?;
        let value = match value.as_promise() {
            Some(promise) => promise.finish::<Value>()?,
            None => value,
        };
        Ok(value.as_string().map(|s| s.to_string()).transpose()?.unwrap_or_else(|| "null".into()))
    })();
    result.map_err(|error| match error {
        rquickjs::Error::WouldBlock => "Extension never finished its work".to_string(),
        error => message(ctx, error),
    })
}

#[allow(clippy::too_many_arguments)]
fn run(
    code: String,
    bootstrap: String,
    config_json: String,
    host: Host,
    rx: mpsc::Receiver<Msg>,
    tx: mpsc::Sender<Msg>,
    closed: Arc<AtomicBool>,
    ready: mpsc::Sender<Result<Vec<String>, String>>,
) {
    let deadline = Arc::new(AtomicU64::new(now_ms() + START_TIMEOUT_MS));
    let memory_limit = guest_memory_limit(&config_json);
    let setup = (|| -> Result<(Runtime, Context), String> {
        let runtime = Runtime::new().map_err(|e| e.to_string())?;
        runtime.set_memory_limit(memory_limit);
        runtime.set_max_stack_size(STACK_LIMIT);
        let watch = deadline.clone();
        let stop = closed.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            stop.load(Ordering::SeqCst) || now_ms() > watch.load(Ordering::SeqCst)
        })));
        let context = Context::full(&runtime).map_err(|e| e.to_string())?;
        Ok((runtime, context))
    })();
    let (runtime, context) = match setup {
        Ok(pair) => pair,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    let shared = Rc::new(Shared {
        rx,
        tx,
        host,
        closed: closed.clone(),
        deadline: deadline.clone(),
        next_call: RefCell::new(0),
        queued: RefCell::new(VecDeque::new()),
        replies: RefCell::new(HashMap::new()),
        api: RefCell::new(None),
    });

    let started = context.with(|ctx| -> Result<Vec<String>, String> {
        let guest = shared.clone();
        let host = Function::new(ctx.clone(), move |ctx: Ctx<'_>, method: String, json: String| {
            bridge(ctx, &guest, method, json)
        })
        .map_err(|e| message(&ctx, e))?;
        let factory: Function = ctx.eval(bootstrap).map_err(|e| message(&ctx, e))?;
        let config = ctx.json_parse(config_json).map_err(|e| message(&ctx, e))?;
        let api: Object = factory.call((host, config)).map_err(|e| message(&ctx, e))?;
        shared.api.replace(Some(Persistent::save(&ctx, api.clone())));
        let mut options = EvalOptions::default();
        options.global = true;
        options.strict = false;
        options.filename = Some("extension.js".into());
        ctx.eval_with_options::<Value, _>(code, options).map_err(|e| message(&ctx, e))?;
        while ctx.execute_pending_job() {}
        let registered: Function = api.get("registered").map_err(|e| message(&ctx, e))?;
        if !registered.call::<_, bool>(()).map_err(|e| message(&ctx, e))? {
            return Err("Package did not call registerExtension()".into());
        }
        let methods: Function = api.get("methods").map_err(|e| message(&ctx, e))?;
        let json: String = methods.call(()).map_err(|e| message(&ctx, e))?;
        serde_json::from_str(&json).map_err(|e| e.to_string())
    });
    let failed = started.is_err();
    let _ = ready.send(started);
    deadline.store(NO_DEADLINE, Ordering::SeqCst);

    while !failed {
        let next = shared.queued.borrow_mut().pop_front();
        let msg = match next {
            Some(msg) => msg,
            None => match shared.rx.recv() {
                Ok(msg) => msg,
                Err(_) => break,
            },
        };
        match msg {
            Msg::Invoke { method, args, timeout_ms, reply } => {
                deadline.store(now_ms().saturating_add(timeout_ms.max(1)), Ordering::SeqCst);
                let result = context.with(|ctx| invoke(&ctx, &shared, &method, &args));
                deadline.store(NO_DEADLINE, Ordering::SeqCst);
                let timed_out = matches!(&result, Err(e) if e.contains("timed out") || e.contains("cancelled"));
                let _ = reply.send(result);
                // An interrupted guest can be left half-way: never reuse it.
                if timed_out || closed.load(Ordering::SeqCst) {
                    break;
                }
            }
            Msg::Callback { ack, .. } => {
                // Nothing is waiting on a host call: the callback is stale.
                let _ = ack.send(String::new());
            }
            Msg::Reply { .. } => {}
            Msg::Close => break,
        }
    }
    closed.store(true, Ordering::SeqCst);
    // Fail whatever was queued behind the last invoke.
    for msg in shared.queued.borrow_mut().drain(..) {
        if let Msg::Invoke { reply, .. } = msg {
            let _ = reply.send(Err("Extension runtime closed".into()));
        }
    }
    while let Ok(msg) = shared.rx.try_recv() {
        if let Msg::Invoke { reply, .. } = msg {
            let _ = reply.send(Err("Extension runtime closed".into()));
        }
    }
    shared.api.replace(None);
    drop(shared);
    drop(context);
    runtime.run_gc();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guest_heap_is_bounded_by_host_config() {
        assert_eq!(guest_memory_limit("{}"), MEMORY_LIMIT);
        assert_eq!(guest_memory_limit(r#"{"heapMb":256}"#), MAX_DOWNLOAD_MEMORY_LIMIT);
        assert_eq!(guest_memory_limit(r#"{"heapMb":5}"#), MEMORY_LIMIT);
        assert_eq!(guest_memory_limit(r#"{"heapMb":999999999999}"#), MAX_DOWNLOAD_MEMORY_LIMIT);
        assert_eq!(guest_memory_limit(r#"{"heapMb":"512"}"#), MEMORY_LIMIT);
        assert_eq!(guest_memory_limit("invalid"), MEMORY_LIMIT);
    }

    const BOOTSTRAP: &str = r#"(function(bridge, config) {
      globalThis.host = (m, a) => JSON.parse(bridge(m, JSON.stringify(a)));
      globalThis.registerExtension = v => { globalThis.ext = v; };
      const callbacks = new Map(); let next = 0;
      globalThis.withCallback = fn => { const id = ++next; callbacks.set(id, fn); return id; };
      return {
        registered: () => !!globalThis.ext,
        methods: () => JSON.stringify(Object.keys(globalThis.ext || {})),
        callback: (id, args) => callbacks.get(id)(...JSON.parse(args)),
        invoke: (name, args) => {
          const r = globalThis.ext[name](...JSON.parse(args));
          return r && typeof r.then === 'function' ? r.then(v => JSON.stringify(v)) : JSON.stringify(r);
        },
      };
    })"#;

    fn echo_host() -> Host {
        Arc::new(|method, json| Box::pin(async move { format!("{{\"method\":{:?},\"args\":{}}}", method, json) }))
    }

    fn start(code: &str, host: Host) -> Result<Engine, String> {
        Engine::start(code.into(), BOOTSTRAP.into(), "{}".into(), host)
    }

    #[test]
    fn registers_and_invokes() {
        let engine = start("registerExtension({ add: (a, b) => a + b, hi() { return 'x' } })", echo_host()).unwrap();
        assert_eq!(engine.methods(), vec!["add", "hi"]);
        let value = futures::executor::block_on(engine.invoke("add".into(), "[2,3]".into(), 1000));
        assert_eq!(value.unwrap(), "5");
    }

    #[test]
    fn missing_registration_fails() {
        let error = start("1 + 1", echo_host()).err().unwrap();
        assert!(error.contains("registerExtension"), "{error}");
    }

    #[test]
    fn host_calls_are_synchronous_for_the_guest() {
        let engine = start("registerExtension({ ask: () => host('http.request', ['u']).args[0] })", echo_host()).unwrap();
        let value = futures::executor::block_on(engine.invoke("ask".into(), "[]".into(), 1000));
        assert_eq!(value.unwrap(), "\"u\"");
    }

    #[test]
    fn promises_settle() {
        let engine = start("registerExtension({ later: async () => { await null; return 7 } })", echo_host()).unwrap();
        let value = futures::executor::block_on(engine.invoke("later".into(), "[]".into(), 1000));
        assert_eq!(value.unwrap(), "7");
    }

    #[test]
    fn errors_carry_their_message() {
        let engine = start("registerExtension({ boom: () => { throw new Error('no track') } })", echo_host()).unwrap();
        let error = futures::executor::block_on(engine.invoke("boom".into(), "[]".into(), 1000)).unwrap_err();
        assert_eq!(error, "no track");
        // A thrown error leaves the add-on usable.
        assert!(!engine.is_closed());
    }

    #[test]
    fn runaway_code_times_out_and_closes() {
        let engine = start("registerExtension({ spin: () => { for (;;) {} } })", echo_host()).unwrap();
        let error = futures::executor::block_on(engine.invoke("spin".into(), "[]".into(), 200)).unwrap_err();
        assert!(error.contains("timed out"), "{error}");
        std::thread::sleep(Duration::from_millis(50));
        let again = futures::executor::block_on(engine.invoke("spin".into(), "[]".into(), 200));
        assert!(again.is_err());
    }

    #[test]
    fn callbacks_run_during_a_host_call_and_may_call_the_host() {
        // The host answers 'download' only after running the guest's progress
        // callback, which itself calls the host.
        let slot: Arc<Mutex<Option<Arc<Engine>>>> = Arc::new(Mutex::new(None));
        let seen = Arc::new(Mutex::new(Vec::<String>::new()));
        let host: Host = {
            let slot = slot.clone();
            let seen = seen.clone();
            Arc::new(move |method, json| {
                let slot = slot.clone();
                let seen = seen.clone();
                Box::pin(async move {
                    seen.lock().unwrap().push(method.clone());
                    if method == "download" {
                        let id: Vec<f64> = serde_json::from_str(&json).unwrap();
                        let engine = loop {
                            if let Some(engine) = slot.lock().unwrap().clone() {
                                break engine;
                            }
                            std::thread::sleep(Duration::from_millis(5));
                        };
                        let error = engine.callback(id[0] as u64, "[50]".into()).await;
                        assert_eq!(error, "");
                        return "\"done\"".to_string();
                    }
                    "true".to_string()
                })
            })
        };
        let engine = Arc::new(
            start(
                "registerExtension({ get: () => { let p = 0; const r = host('download', [withCallback(v => { p = v; host('log', [v]); })]); return r + ':' + p } })",
                host,
            )
            .unwrap(),
        );
        *slot.lock().unwrap() = Some(engine.clone());
        let value = futures::executor::block_on(engine.invoke("get".into(), "[]".into(), 5000));
        assert_eq!(value.unwrap(), "\"done:50\"");
        assert_eq!(*seen.lock().unwrap(), vec!["download", "log"]);
        engine.close();
    }
}
