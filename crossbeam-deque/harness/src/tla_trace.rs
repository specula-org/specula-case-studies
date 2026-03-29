//! Per-thread timebox trace emission for crossbeam-deque TLA+ validation.
//!
//! Category B (concurrent/lock-free): each thread writes to its own file
//! using rdtsc timestamps for [start, end] intervals. No mutex on the hot path.
//!
//! Activated by `CROSSBEAM_DEQUE_TRACE_DIR=<directory>`.
//! When not set, all trace calls are no-ops (single atomic load check).

use core::cell::RefCell;
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering as AO};

use alloc::format;
use alloc::string::String;

use std::collections::HashMap;
use std::io::Write;
use std::sync::{Mutex, OnceLock};

// ============================================================================
// Global state
// ============================================================================

static ACTIVE: AtomicBool = AtomicBool::new(false);
static TRACE_DIR: OnceLock<String> = OnceLock::new();
static BUFFER_MAP: OnceLock<Mutex<BufferMap>> = OnceLock::new();
static STEALER_COUNTER: AtomicUsize = AtomicUsize::new(0);

struct BufferMap {
    map: HashMap<usize, usize>,
    counter: usize,
}

// ============================================================================
// Per-thread state
// ============================================================================

struct ThreadWriter {
    writer: std::io::BufWriter<std::fs::File>,
    name: String,
}

std::thread_local! {
    static TL_WRITER: RefCell<Option<ThreadWriter>> = const { RefCell::new(None) };
}

// ============================================================================
// rdtsc
// ============================================================================

/// High-resolution timestamp for timebox intervals (~25 CPU cycles).
#[inline(always)]
pub fn rdtsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    {
        unsafe {
            core::arch::asm!("mfence");
            let lo: u32;
            let hi: u32;
            core::arch::asm!("rdtsc", out("eax") lo, out("edx") hi);
            core::arch::asm!("mfence");
            ((hi as u64) << 32) | lo as u64
        }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::SystemTime::UNIX_EPOCH)
            .unwrap_or_default();
        ts.as_nanos() as u64
    }
}

// ============================================================================
// Initialization
// ============================================================================

fn try_init() {
    if let Ok(dir) = std::env::var("CROSSBEAM_DEQUE_TRACE_DIR") {
        std::fs::create_dir_all(&dir).ok();
        let _ = TRACE_DIR.set(dir);
        let _ = BUFFER_MAP.set(Mutex::new(BufferMap {
            map: HashMap::new(),
            counter: 0,
        }));
        ACTIVE.store(true, AO::Release);
    }
}

/// Returns true if tracing is active. Auto-initializes on first call.
#[inline]
pub fn is_active() -> bool {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(try_init);
    ACTIVE.load(AO::Relaxed)
}

/// Initialize current thread as the worker. Call from the worker thread.
pub fn init_worker_thread() {
    if !is_active() {
        return;
    }
    init_thread("worker");
}

/// Initialize current thread as a stealer. Returns assigned ID ("s1", "s2", ...).
pub fn init_stealer_thread() -> String {
    let n = STEALER_COUNTER.fetch_add(1, AO::Relaxed) + 1;
    let id = format!("s{}", n);
    if is_active() {
        init_thread(&id);
    }
    id
}

fn init_thread(tid: &str) {
    if let Some(dir) = TRACE_DIR.get() {
        let path = format!("{}/trace-{}.ndjson", dir, tid);
        let file = std::fs::File::create(&path)
            .unwrap_or_else(|e| panic!("tla_trace: open {}: {}", path, e));
        TL_WRITER.with(|w| {
            *w.borrow_mut() = Some(ThreadWriter {
                writer: std::io::BufWriter::new(file),
                name: String::from(tid),
            });
        });
    }
}

/// Flush and close the current thread's trace file.
pub fn shutdown_thread() {
    TL_WRITER.with(|w| {
        if let Some(ref mut tw) = *w.borrow_mut() {
            let _ = tw.writer.flush();
        }
        *w.borrow_mut() = None;
    });
}

/// Map a raw buffer pointer address to a sequential ID (1, 2, 3, ...).
pub fn map_buffer_ptr(ptr: usize) -> usize {
    if let Some(bm) = BUFFER_MAP.get() {
        if let Ok(mut guard) = bm.lock() {
            if let Some(&id) = guard.map.get(&ptr) {
                return id;
            }
            guard.counter += 1;
            let id = guard.counter;
            guard.map.insert(ptr, id);
            id
        } else {
            0
        }
    } else {
        0
    }
}

// ============================================================================
// Emit helpers
// ============================================================================

fn emit_line(json: &str) {
    TL_WRITER.with(|w| {
        if let Some(ref mut tw) = *w.borrow_mut() {
            let _ = writeln!(tw.writer, "{}", json);
        }
    });
}

fn tid() -> String {
    TL_WRITER.with(|w| {
        if let Some(ref tw) = *w.borrow() {
            tw.name.clone()
        } else {
            String::from("unknown")
        }
    })
}

// ============================================================================
// Worker event emitters
// ============================================================================

/// Push event: worker stored a value.
pub fn emit_push(start: u64, end: u64, front: isize, back: isize) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"Push","thread":"{}","start":{},"end":{},"state":{{"front":{},"back":{}}}}}"#,
        t, start, end, front, back
    ));
}

/// ResizeGrow event: worker grew the buffer.
pub fn emit_resize_grow(start: u64, end: u64, front: isize, back: isize) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"ResizeGrow","thread":"{}","start":{},"end":{},"state":{{"front":{},"back":{}}}}}"#,
        t, start, end, front, back
    ));
}

/// LIFOPop event: worker popped from back.
pub fn emit_lifo_pop(start: u64, end: u64, front: isize, back: isize, result: &str) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"LIFOPop","thread":"{}","start":{},"end":{},"state":{{"front":{},"back":{}}},"result":"{}"}}"#,
        t, start, end, front, back, result
    ));
}

/// FIFOPopAttempt event: worker did fetch_add on front.
pub fn emit_fifo_pop_attempt(start: u64, end: u64, front: isize, back: isize, result: &str) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"FIFOPopAttempt","thread":"{}","start":{},"end":{},"state":{{"front":{},"back":{}}},"result":"{}"}}"#,
        t, start, end, front, back, result
    ));
}

/// FIFOPopRollback event: front index restored after false advance.
pub fn emit_fifo_pop_rollback(start: u64, end: u64, front: isize, back: isize) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"FIFOPopRollback","thread":"{}","start":{},"end":{},"state":{{"front":{},"back":{}}}}}"#,
        t, start, end, front, back
    ));
}

// ============================================================================
// Stealer event emitters
// ============================================================================

/// StealBegin: stealer loaded front, back, buffer.
pub fn emit_steal_begin(start: u64, end: u64, cached_front: isize, cached_back: isize, result: &str) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"StealBegin","thread":"{}","start":{},"end":{},"cachedFront":{},"cachedBack":{},"result":"{}"}}"#,
        t, start, end, cached_front, cached_back, result
    ));
}

/// StealReadTask: stealer speculatively read from buffer.
pub fn emit_steal_read_task(start: u64, end: u64) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"StealReadTask","thread":"{}","start":{},"end":{}}}"#,
        t, start, end
    ));
}

/// StealCommit: stealer attempted CAS on front.
pub fn emit_steal_commit(
    start: u64,
    end: u64,
    front: isize,
    site: &str,
    cas_result: &str,
    stolen_count: isize,
) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"StealCommit","thread":"{}","start":{},"end":{},"state":{{"front":{}}},"site":"{}","casResult":"{}","stolenCount":{}}}"#,
        t, start, end, front, site, cas_result, stolen_count
    ));
}

/// BatchStealBeginFIFO event.
pub fn emit_batch_steal_begin_fifo(
    start: u64,
    end: u64,
    cached_front: isize,
    cached_back: isize,
    batch_size: usize,
    result: &str,
) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"BatchStealBeginFIFO","thread":"{}","start":{},"end":{},"cachedFront":{},"cachedBack":{},"batchSize":{},"result":"{}"}}"#,
        t, start, end, cached_front, cached_back, batch_size, result
    ));
}

/// BatchStealBeginLIFO event.
pub fn emit_batch_steal_begin_lifo(
    start: u64,
    end: u64,
    cached_front: isize,
    cached_back: isize,
    batch_size: usize,
    result: &str,
) {
    let t = tid();
    emit_line(&format!(
        r#"{{"tag":"trace","event":"BatchStealBeginLIFO","thread":"{}","start":{},"end":{},"cachedFront":{},"cachedBack":{},"batchSize":{},"result":"{}"}}"#,
        t, start, end, cached_front, cached_back, batch_size, result
    ));
}
