//! TLA+ trace emission for tokio::sync::broadcast.
//!
//! Emits per-action NDJSON events with:
//!   {"tag":"trace","name":<action>,"thread":<actor>,"start":<ts>,"end":<ts>,"state":{...},...}
//!
//! `thread` is a logical actor identity (e.g. "s1", "r1") set via `actor_scope`.
//! Timestamps come from rdtsc (or a monotonic clock fallback). All emits go to
//! a single global file; the preprocessor groups by `thread` for trace
//! validation. We use a Mutex around the writer because Category B rules
//! tolerate it here: tokio's broadcast is consumed from async tasks (not
//! cycle-tight CAS loops), and our scenarios mostly use the current_thread
//! runtime where the mutex is uncontended in practice.

#![allow(dead_code, unused_imports, unused_variables)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

// ----- Global trace writer -----

static GLOBAL_WRITER: Mutex<Option<BufWriter<File>>> = Mutex::new(None);

/// Initialize the trace writer. Truncates `path`.
pub fn init(path: &str) {
    let f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .expect("tla_trace: open failed");
    let mut g = GLOBAL_WRITER.lock().unwrap();
    *g = Some(BufWriter::new(f));
}

/// Flush + close the trace writer.
pub fn shutdown() {
    let mut g = GLOBAL_WRITER.lock().unwrap();
    if let Some(mut bw) = g.take() {
        let _ = bw.flush();
    }
    // Reset waiter registry.
    let mut m = WAITER_ACTORS.lock().unwrap();
    if let Some(map) = m.as_mut() {
        map.clear();
    }
}

fn write_line(line: &str) {
    if let Ok(mut g) = GLOBAL_WRITER.lock() {
        if let Some(bw) = g.as_mut() {
            let _ = writeln!(bw, "{}", line);
        }
    }
}

// ----- Timestamps -----

#[inline(always)]
pub fn now() -> u64 {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        // mfence + rdtsc to prevent CPU reordering.
        std::arch::x86_64::_mm_mfence();
        let v = core::arch::x86_64::_rdtsc();
        std::arch::x86_64::_mm_mfence();
        v
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }
}

// ----- Actor identity (thread-local) -----

thread_local! {
    static ACTOR: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// RAII guard: sets the thread-local actor for its lifetime.
pub struct ActorGuard {
    prev: Option<String>,
}

impl ActorGuard {
    pub fn new(name: impl Into<String>) -> Self {
        let prev = ACTOR.with(|c| c.borrow().clone());
        ACTOR.with(|c| *c.borrow_mut() = Some(name.into()));
        ActorGuard { prev }
    }
}

impl Drop for ActorGuard {
    fn drop(&mut self) {
        let p = self.prev.take();
        ACTOR.with(|c| *c.borrow_mut() = p);
    }
}

/// Returns the current thread's actor id, or "?" if unset.
pub fn actor() -> String {
    ACTOR.with(|c| c.borrow().clone()).unwrap_or_else(|| "?".to_string())
}

// ----- Waiter -> actor registry -----
//
// notify_rx pops a waiter pointer; we need to know which actor that waiter
// belongs to. We register on push_front (recv_ref slow path) and lookup on
// pop_back (notify_rx).

static WAITER_ACTORS: Mutex<Option<HashMap<usize, String>>> = Mutex::new(None);

pub fn register_waiter(ptr: usize, actor_name: &str) {
    let mut g = WAITER_ACTORS.lock().unwrap();
    let map = g.get_or_insert_with(HashMap::new);
    map.insert(ptr, actor_name.to_string());
}

pub fn lookup_waiter(ptr: usize) -> String {
    let g = WAITER_ACTORS.lock().unwrap();
    if let Some(map) = g.as_ref() {
        if let Some(s) = map.get(&ptr) {
            return s.clone();
        }
    }
    "?".to_string()
}

pub fn forget_waiter(ptr: usize) {
    let mut g = WAITER_ACTORS.lock().unwrap();
    if let Some(map) = g.as_mut() {
        map.remove(&ptr);
    }
}

// ----- JSON helpers (avoid serde dependency) -----
//
// We hand-roll just enough to emit numbers, booleans, and string-escaped values.

pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// ----- Emit helpers -----
//
// Each helper produces a complete NDJSON event line.

#[allow(clippy::too_many_arguments)]
pub fn emit_send(
    name: &str,
    start: u64,
    end: u64,
    sender: &str,
    extra: &str,
    tail_pos: u64,
    tail_rx_cnt: usize,
    tail_closed: bool,
    tail_waiter_count: usize,
    num_tx: usize,
) {
    let line = format!(
        r#"{{"tag":"trace","name":{name},"thread":{thread},"sender":{sender},"start":{start},"end":{end},"state":{{"tailPos":{tp},"tailRxCnt":{trx},"tailClosed":{tc},"tailWaiterCount":{tw},"numTx":{ntx}}}{extra}}}"#,
        name = esc(name),
        thread = esc(sender),
        sender = esc(sender),
        start = start,
        end = end,
        tp = tail_pos,
        trx = tail_rx_cnt,
        tc = tail_closed,
        tw = tail_waiter_count,
        ntx = num_tx,
        extra = extra,
    );
    write_line(&line);
}

#[allow(clippy::too_many_arguments)]
pub fn emit_recv(
    name: &str,
    start: u64,
    end: u64,
    receiver: &str,
    extra: &str,
    tail_pos: u64,
    tail_rx_cnt: usize,
    tail_closed: bool,
    tail_waiter_count: usize,
    num_tx: usize,
    queued: bool,
    next: u64,
) {
    let line = format!(
        r#"{{"tag":"trace","name":{name},"thread":{thread},"receiver":{receiver},"start":{start},"end":{end},"state":{{"tailPos":{tp},"tailRxCnt":{trx},"tailClosed":{tc},"tailWaiterCount":{tw},"numTx":{ntx},"queued":{q},"next":{n}}}{extra}}}"#,
        name = esc(name),
        thread = esc(receiver),
        receiver = esc(receiver),
        start = start,
        end = end,
        tp = tail_pos,
        trx = tail_rx_cnt,
        tc = tail_closed,
        tw = tail_waiter_count,
        ntx = num_tx,
        q = queued,
        n = next,
        extra = extra,
    );
    write_line(&line);
}

// Generic emit — for events that don't fit the send/recv shapes (e.g.
// notify_rx events triggered by neither a sender nor a receiver actor).
pub fn emit_generic(
    name: &str,
    start: u64,
    end: u64,
    thread: &str,
    extra: &str,
    tail_pos: u64,
    tail_rx_cnt: usize,
    tail_closed: bool,
    tail_waiter_count: usize,
    num_tx: usize,
) {
    let line = format!(
        r#"{{"tag":"trace","name":{name},"thread":{thread},"start":{start},"end":{end},"state":{{"tailPos":{tp},"tailRxCnt":{trx},"tailClosed":{tc},"tailWaiterCount":{tw},"numTx":{ntx}}}{extra}}}"#,
        name = esc(name),
        thread = esc(thread),
        start = start,
        end = end,
        tp = tail_pos,
        trx = tail_rx_cnt,
        tc = tail_closed,
        tw = tail_waiter_count,
        ntx = num_tx,
        extra = extra,
    );
    write_line(&line);
}
