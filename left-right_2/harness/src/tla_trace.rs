//! Per-thread trace emission for left-right (Category B — Timebox).
//!
//! Each thread writes to its own NDJSON file. No mutex contention on the trace path.
//! Events carry [start, end] timestamp intervals for timebox validation.
//! Activated by setting `LEFTRIGHT_TRACE_DIR` environment variable.

#![allow(missing_docs)]
#![allow(clippy::missing_safety_doc)]

use std::cell::{Cell, RefCell};
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Base instant for relative timestamp computation (nanos since init).
static BASE_INSTANT: OnceLock<Instant> = OnceLock::new();

/// Whether tracing is active.
static ACTIVE: AtomicBool = AtomicBool::new(false);

/// Trace output directory path.
static TRACE_DIR: Mutex<String> = Mutex::new(String::new());

/// Generation counter — incremented on each init() call so thread-local writers
/// re-open per scenario.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Pointer mapping: l_addr is "L", r_addr is "R", null is "null".
/// Set once per scenario by the test scenario after channel construction.
static L_ADDR: AtomicUsize = AtomicUsize::new(0);
static R_ADDR: AtomicUsize = AtomicUsize::new(0);

thread_local! {
    static WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static TID: RefCell<Option<String>> = const { RefCell::new(None) };
    static LOCAL_GEN: Cell<u64> = const { Cell::new(0) };
    /// Suppress nested emissions (e.g. WriterPublish called from inside take_inner).
    static SUPPRESS_DEPTH: Cell<u32> = const { Cell::new(0) };
}

/// Initialize (or re-initialize) tracing for a new scenario.
/// Reads `LEFTRIGHT_TRACE_DIR` env var.
pub fn init() -> bool {
    if let Ok(dir) = std::env::var("LEFTRIGHT_TRACE_DIR") {
        fs::create_dir_all(&dir).expect("Failed to create trace dir");
        BASE_INSTANT.get_or_init(Instant::now);
        *TRACE_DIR.lock().unwrap() = dir;
        L_ADDR.store(0, Ordering::Release);
        R_ADDR.store(0, Ordering::Release);
        GENERATION.fetch_add(1, Ordering::Release);
        ACTIVE.store(true, Ordering::Release);
        true
    } else {
        false
    }
}

/// Set the L/R pointer mapping. Called once per scenario by the test, after
/// constructing the WriteHandle/ReadHandle pair, with the addresses returned by
/// the trace accessor functions exposed on those handles.
pub fn set_pointer_mapping(l_addr: usize, r_addr: usize) {
    L_ADDR.store(l_addr, Ordering::Release);
    R_ADDR.store(r_addr, Ordering::Release);
}

/// Set the TLA+ thread name for the current thread (e.g. "writer", "r1").
pub fn set_thread_name(name: &str) {
    TID.with(|t| *t.borrow_mut() = Some(name.to_string()));
}

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

/// Translate raw pointer address to "L", "R", or "null".
pub fn pointer_name(addr: usize) -> &'static str {
    if addr == 0 {
        return "null";
    }
    let l = L_ADDR.load(Ordering::Acquire);
    let r = R_ADDR.load(Ordering::Acquire);
    if addr == l {
        "L"
    } else if addr == r {
        "R"
    } else {
        "unknown"
    }
}

/// RAII guard that bumps SUPPRESS_DEPTH for its lifetime.
#[derive(Debug)]
pub struct SuppressGuard;

impl SuppressGuard {
    pub fn new() -> Self {
        SUPPRESS_DEPTH.with(|c| c.set(c.get() + 1));
        SuppressGuard
    }
}

impl Default for SuppressGuard {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for SuppressGuard {
    fn drop(&mut self) {
        SUPPRESS_DEPTH.with(|c| c.set(c.get().saturating_sub(1)));
    }
}

#[inline]
fn is_suppressed() -> bool {
    SUPPRESS_DEPTH.with(|c| c.get() > 0)
}

fn ensure_writer() {
    let gen = GENERATION.load(Ordering::Acquire);
    LOCAL_GEN.with(|g| {
        if g.get() != gen {
            WRITER.with(|w| *w.borrow_mut() = None);
            // Don't reset TID — set_thread_name was likely called before init for the writer thread.
            g.set(gen);
        }
    });

    WRITER.with(|w| {
        if w.borrow().is_none() {
            // Use thread name if set, else fall back to OS thread id.
            let tid_str = TID.with(|t| {
                t.borrow().clone().unwrap_or_else(|| {
                    let id = std::thread::current().id();
                    let s = format!("{:?}", id);
                    s.trim_start_matches("ThreadId(")
                        .trim_end_matches(')')
                        .to_string()
                })
            });
            // Re-store the TID in case we derived it from thread::current().
            TID.with(|t| {
                if t.borrow().is_none() {
                    *t.borrow_mut() = Some(tid_str.clone());
                }
            });
            let dir = TRACE_DIR.lock().unwrap().clone();
            let path = format!("{}/trace-thread-{}.ndjson", dir, tid_str);
            let file = File::create(&path).expect("Failed to create trace file");
            *w.borrow_mut() = Some(BufWriter::new(file));
        }
    });
}

fn get_tid() -> String {
    TID.with(|t| t.borrow().clone().unwrap_or_else(|| "unknown".to_string()))
}

fn emit_raw(line: &str) {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writeln!(writer, "{}", line).ok();
        }
    });
}

/// Flush thread-local writer.
pub fn flush() {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writer.flush().ok();
        }
    });
}

// ============================================================================
// Event emission
// ============================================================================

pub fn emit_reader_enter(start: u64, end: u64, epoch: usize, enters: usize, ptr_addr: usize) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let ptr = pointer_name(ptr_addr);
    let line = format!(
        r#"{{"tag":"trace","event":"ReaderEnter","tid":"{}","start":{},"end":{},"state":{{"epoch":{},"enters":{},"pointer":"{}"}}}}"#,
        tid, start, end, epoch, enters, ptr
    );
    emit_raw(&line);
}

pub fn emit_reader_enter_none(start: u64, end: u64, epoch: usize, _enters: usize) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    // Omit `enters` from the state: the spec's TraceReaderEnterNone keeps
    // enters UNCHANGED and only refers to it via TraceUnchangedAll, so emitting
    // it would force ValidateReaderState to evaluate `enters'[r]` before the
    // UNCHANGED clause has constrained it (TLC evaluates conjuncts in order).
    let line = format!(
        r#"{{"tag":"trace","event":"ReaderEnterNone","tid":"{}","start":{},"end":{},"state":{{"epoch":{}}}}}"#,
        tid, start, end, epoch
    );
    emit_raw(&line);
}

pub fn emit_reader_enter_nested(start: u64, end: u64, _epoch: usize, enters: usize, ptr_addr: usize) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let ptr = pointer_name(ptr_addr);
    // Omit `epoch` from the state: the spec's TraceReaderEnterNested keeps
    // epoch UNCHANGED via a clause that comes AFTER ValidateReaderState, so
    // emitting it would make TLC evaluate `epoch'[r]` before it is constrained
    // (TLC evaluates conjuncts in order).
    let line = format!(
        r#"{{"tag":"trace","event":"ReaderEnterNested","tid":"{}","start":{},"end":{},"state":{{"enters":{},"pointer":"{}"}}}}"#,
        tid, start, end, enters, ptr
    );
    emit_raw(&line);
}

pub fn emit_reader_exit(start: u64, end: u64, epoch: usize, enters: usize) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"ReaderExit","tid":"{}","start":{},"end":{},"state":{{"epoch":{},"enters":{}}}}}"#,
        tid, start, end, epoch, enters
    );
    emit_raw(&line);
}

pub fn emit_writer_append(start: u64, end: u64, first: bool, second: bool) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"WriterAppend","tid":"{}","start":{},"end":{},"state":{{"first":{},"second":{}}}}}"#,
        tid, start, end, first, second
    );
    emit_raw(&line);
}

pub fn emit_writer_publish(start: u64, end: u64, ptr_addr: usize, first: bool, second: bool) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let ptr = pointer_name(ptr_addr);
    let line = format!(
        r#"{{"tag":"trace","event":"WriterPublish","tid":"{}","start":{},"end":{},"state":{{"pointer":"{}","first":{},"second":{}}}}}"#,
        tid, start, end, ptr, first, second
    );
    emit_raw(&line);
}

pub fn emit_writer_try_publish_ok(start: u64, end: u64, ptr_addr: usize, first: bool, second: bool) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let ptr = pointer_name(ptr_addr);
    let line = format!(
        r#"{{"tag":"trace","event":"WriterTryPublishOk","tid":"{}","start":{},"end":{},"state":{{"pointer":"{}","first":{},"second":{}}}}}"#,
        tid, start, end, ptr, first, second
    );
    emit_raw(&line);
}

pub fn emit_writer_try_publish_fail(start: u64, end: u64, ptr_addr: usize, first: bool, second: bool) {
    if !is_active() || is_suppressed() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let ptr = pointer_name(ptr_addr);
    let line = format!(
        r#"{{"tag":"trace","event":"WriterTryPublishFail","tid":"{}","start":{},"end":{},"state":{{"pointer":"{}","first":{},"second":{}}}}}"#,
        tid, start, end, ptr, first, second
    );
    emit_raw(&line);
}

pub fn emit_writer_take_inner(start: u64, end: u64, first: bool, taken: bool) {
    if !is_active() {
        return;
    }
    ensure_writer();
    let tid = get_tid();
    let line = format!(
        r#"{{"tag":"trace","event":"WriterTakeInner","tid":"{}","start":{},"end":{},"state":{{"pointer":"null","first":{},"taken":{}}}}}"#,
        tid, start, end, first, taken
    );
    emit_raw(&line);
}
