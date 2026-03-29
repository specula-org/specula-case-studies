//! Per-thread trace emission for tokio broadcast channel (Category B — Timebox).
//!
//! Each thread writes to its own NDJSON file. No mutex contention on the trace path.
//! Events carry [start, end] timestamp intervals for timebox validation.
//! Activated by setting `BROADCAST_TRACE_DIR` environment variable.

use std::cell::{Cell, RefCell};
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Base instant for relative timestamp computation (nanos since init).
static BASE_INSTANT: OnceLock<Instant> = OnceLock::new();

/// Whether tracing is active.
static ACTIVE: AtomicBool = AtomicBool::new(false);

/// Trace output directory path (can be updated per scenario).
static TRACE_DIR: Mutex<String> = Mutex::new(String::new());

/// Generation counter — incremented on each init() call.
/// Thread-local writers re-open when generation changes.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Global monotonic receiver ID counter.
pub static NEXT_RECEIVER_ID: AtomicU64 = AtomicU64::new(1);

/// Global monotonic value ID counter (for cycling through v1, v2, ...).
pub static NEXT_VALUE_ID: AtomicU64 = AtomicU64::new(0);

thread_local! {
    static WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static TID: RefCell<Option<String>> = const { RefCell::new(None) };
    static LOCAL_GEN: Cell<u64> = const { Cell::new(0) };
}

/// Initialize (or re-initialize) tracing for a new scenario.
/// Reads `BROADCAST_TRACE_DIR` env var. Resets counters and thread-local writers.
pub fn init() -> bool {
    if let Ok(dir) = std::env::var("BROADCAST_TRACE_DIR") {
        fs::create_dir_all(&dir).expect("Failed to create trace dir");
        BASE_INSTANT.get_or_init(Instant::now);
        *TRACE_DIR.lock().unwrap() = dir;
        NEXT_RECEIVER_ID.store(1, Ordering::Release);
        NEXT_VALUE_ID.store(0, Ordering::Release);
        GENERATION.fetch_add(1, Ordering::Release);
        ACTIVE.store(true, Ordering::Release);
        true
    } else {
        false
    }
}

/// Check if tracing is active (fast path: single atomic load).
#[inline]
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

/// Get current timestamp as nanos since base instant.
#[inline]
pub fn now_ns() -> u64 {
    let base = BASE_INSTANT.get().expect("trace not initialized");
    Instant::now().duration_since(*base).as_nanos() as u64
}

/// Ensure the thread-local writer is initialized and up-to-date with current generation.
fn ensure_writer() {
    let gen = GENERATION.load(Ordering::Acquire);
    LOCAL_GEN.with(|g| {
        if g.get() != gen {
            // Close old writer, open new one for new scenario
            WRITER.with(|w| *w.borrow_mut() = None);
            TID.with(|t| *t.borrow_mut() = None);
            g.set(gen);
        }
    });

    WRITER.with(|w| {
        if w.borrow().is_none() {
            let tid = std::thread::current().id();
            let tid_str = format!("{:?}", tid);
            let tid_num = tid_str
                .trim_start_matches("ThreadId(")
                .trim_end_matches(')')
                .to_string();
            let dir = TRACE_DIR.lock().unwrap().clone();
            let path = format!("{}/trace-thread-{}.ndjson", dir, tid_num);
            let file = File::create(&path).expect("Failed to create trace file");
            *w.borrow_mut() = Some(BufWriter::new(file));
            TID.with(|t| *t.borrow_mut() = Some(format!("t{}", tid_num)));
        }
    });
}

/// Get the thread-local TLA+ thread ID (e.g., "t1", "t2").
fn get_tid() -> String {
    TID.with(|t| t.borrow().clone().unwrap_or_else(|| "t0".to_string()))
}

/// Write a raw JSON line to the thread-local trace file.
fn emit_raw(line: &str) {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writeln!(writer, "{}", line).ok();
            writer.flush().ok();
        }
    });
}

/// Flush all thread-local writers. Call at test end.
pub fn flush() {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writer.flush().ok();
        }
    });
}

// =========================================================================
// Event emission functions
// =========================================================================

pub fn emit_send(start: u64, end: u64, value: &str, tail_pos: u64, rx_cnt: usize) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"Send","thread":"{}","start":{},"end":{},"value":"{}","state":{{"tailPos":{},"rxCnt":{}}}}}"#,
        tid, start, end, value, tail_pos, rx_cnt
    );
    emit_raw(&line);
}

pub fn emit_subscribe(start: u64, end: u64, receiver: &str, rx_next: u64, rx_cnt: usize) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"Subscribe","thread":"{}","start":{},"end":{},"receiver":"{}","state":{{"rxNext":{},"rxCnt":{}}}}}"#,
        tid, start, end, receiver, rx_next, rx_cnt
    );
    emit_raw(&line);
}

pub fn emit_recv_success(start: u64, end: u64, receiver: &str, rx_next: u64) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"RecvSuccess","thread":"{}","start":{},"end":{},"receiver":"{}","state":{{"rxNext":{}}}}}"#,
        tid, start, end, receiver, rx_next
    );
    emit_raw(&line);
}

pub fn emit_recv_empty(start: u64, end: u64, receiver: &str) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"RecvEmpty","thread":"{}","start":{},"end":{},"receiver":"{}"}}"#,
        tid, start, end, receiver
    );
    emit_raw(&line);
}

pub fn emit_recv_closed(start: u64, end: u64, receiver: &str) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"RecvClosed","thread":"{}","start":{},"end":{},"receiver":"{}"}}"#,
        tid, start, end, receiver
    );
    emit_raw(&line);
}

pub fn emit_recv_lagged(start: u64, end: u64, receiver: &str, rx_next: u64) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"RecvLagged","thread":"{}","start":{},"end":{},"receiver":"{}","state":{{"rxNext":{}}}}}"#,
        tid, start, end, receiver, rx_next
    );
    emit_raw(&line);
}

pub fn emit_sender_drop(start: u64, end: u64, num_tx: usize) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"SenderDrop","thread":"{}","start":{},"end":{},"state":{{"numTx":{}}}}}"#,
        tid, start, end, num_tx
    );
    emit_raw(&line);
}

pub fn emit_close_channel(start: u64, end: u64, closed: bool) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"CloseChannel","thread":"{}","start":{},"end":{},"state":{{"closed":{}}}}}"#,
        tid, start, end, closed
    );
    emit_raw(&line);
}

pub fn emit_sender_clone(start: u64, end: u64) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"SenderClone","thread":"{}","start":{},"end":{}}}"#,
        tid, start, end
    );
    emit_raw(&line);
}

pub fn emit_receiver_drop(start: u64, end: u64, receiver: &str, rx_cnt: usize) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"ReceiverDrop","thread":"{}","start":{},"end":{},"receiver":"{}","state":{{"rxCnt":{}}}}}"#,
        tid, start, end, receiver, rx_cnt
    );
    emit_raw(&line);
}

pub fn emit_deregister_waiter(start: u64, end: u64, receiver: &str) {
    if !is_active() { return; }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"DeregisterWaiter","thread":"{}","start":{},"end":{},"receiver":"{}"}}"#,
        tid, start, end, receiver
    );
    emit_raw(&line);
}
