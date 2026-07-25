//! TLA+ trace emission module for crossbeam-skiplist.
//!
//! Category B (concurrent/lock-free): per-thread NDJSON files with rdtsc intervals.
//! Each event records [start, end] around the critical atomic operation.
//! State is captured AFTER end to keep intervals tight.
//!
//! This module only compiles when `feature = "tla-trace"` is enabled (which implies `std`).

extern crate std;

use std::cell::RefCell;
use std::collections::HashMap;
use std::format;
use std::string::{String, ToString};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// Global node ID counter (0 = Head sentinel, 1.. = allocated nodes)
static NODE_COUNTER: AtomicUsize = AtomicUsize::new(1);

/// Global node pointer -> ID mapping
static NODE_MAP: OnceLock<Mutex<HashMap<usize, usize>>> = OnceLock::new();

/// Global thread ID counter
static THREAD_COUNTER: AtomicUsize = AtomicUsize::new(0);

/// Whether tracing is active
static TRACING_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Trace output directory prefix (Mutex for re-init across tests)
static TRACE_PREFIX: OnceLock<Mutex<String>> = OnceLock::new();

std::thread_local! {
    static TL_WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static TL_TID: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// rdtsc with memory fences for tight interval measurement (~25 CPU cycles)
#[inline]
pub fn rdtsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    {
        let lo: u32;
        let hi: u32;
        unsafe {
            core::arch::x86_64::_mm_mfence();
            core::arch::asm!("rdtsc", out("eax") lo, out("edx") hi);
            core::arch::x86_64::_mm_mfence();
        }
        ((hi as u64) << 32) | lo as u64
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        // Fallback: use monotonic clock
        let t = std::time::Instant::now();
        t.elapsed().as_nanos() as u64
    }
}

/// Initialize tracing. Call once per test scenario.
/// `prefix` is the path prefix for per-thread files (e.g., "traces/test_basic").
pub fn init(prefix: &str) {
    // Initialize or update prefix
    let _ = TRACE_PREFIX.set(Mutex::new(prefix.to_string()));
    if let Some(p) = TRACE_PREFIX.get() {
        *p.lock().unwrap() = prefix.to_string();
    }
    // Initialize or clear node map
    let _ = NODE_MAP.set(Mutex::new(HashMap::new()));
    if let Some(m) = NODE_MAP.get() {
        m.lock().unwrap().clear();
    }
    TRACING_ACTIVE.store(true, Ordering::Release);
    // Reset counters for fresh test
    NODE_COUNTER.store(1, Ordering::Relaxed);
    THREAD_COUNTER.store(0, Ordering::Relaxed);
}

/// Check if tracing is active
#[inline]
pub fn is_active() -> bool {
    TRACING_ACTIVE.load(Ordering::Relaxed)
}

/// Initialize thread-local writer. Call at start of each thread.
pub fn thread_init() {
    if !is_active() {
        return;
    }
    let tid_num = THREAD_COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
    let tid = format!("t{}", tid_num);
    let prefix_guard = TRACE_PREFIX.get().expect("trace not initialized");
    let prefix = prefix_guard.lock().unwrap().clone();
    let path = format!("{}-thread-{}.ndjson", prefix, tid);
    let file = File::create(&path).unwrap_or_else(|e| {
        std::panic!("Failed to open trace file {}: {}", path, e)
    });
    TL_WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::new(file)));
    TL_TID.with(|t| *t.borrow_mut() = Some(tid));
}

/// Get the current thread's TLA+ ID (e.g., "t1")
pub fn get_tid() -> Option<String> {
    TL_TID.with(|t| t.borrow().clone())
}

/// Shutdown tracing for current thread. Flushes and closes the file.
pub fn thread_shutdown() {
    TL_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writer.flush();
        }
        *w.borrow_mut() = None;
    });
}

/// Shutdown global tracing.
pub fn shutdown() {
    TRACING_ACTIVE.store(false, Ordering::Release);
}

/// Map a raw node pointer to a stable integer ID.
/// Head sentinel (detected by caller) maps to 0.
/// New nodes get sequential IDs starting from 1.
pub fn get_node_id(ptr: usize) -> usize {
    if ptr == 0 {
        return 0; // Nil
    }
    let map = NODE_MAP.get().expect("trace not initialized");
    let mut map = map.lock().unwrap();
    *map.entry(ptr).or_insert_with(|| NODE_COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// Register the head sentinel pointer.
pub fn register_head(ptr: usize) {
    let map = NODE_MAP.get().expect("trace not initialized");
    let mut map = map.lock().unwrap();
    map.insert(ptr, 0);
}

/// Emit a raw JSON line to the thread-local trace file.
fn emit_raw(json: &str) {
    TL_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writeln!(writer, "{}", json);
        }
    });
}

// ============================================================================
// Key conversion helper
// ============================================================================

/// Convert a key reference to i64 for trace emission.
/// Works for i64, i32, u32, u64 keys by size-based detection.
/// For other types, returns 0.
pub fn key_to_i64<K>(key: &K) -> i64 {
    let size = core::mem::size_of::<K>();
    if size == 8 {
        // Assume i64 or u64 (most common in our tests)
        unsafe { *(key as *const K as *const i64) }
    } else if size == 4 {
        unsafe { *(key as *const K as *const i32) as i64 }
    } else {
        0
    }
}

/// Extract ref_count from refs_and_height field.
/// HEIGHT_BITS = 5
pub fn extract_ref_count(refs_and_height: usize) -> usize {
    refs_and_height >> 5
}

// ============================================================================
// Event emission functions
// ============================================================================

/// Emit InsertBegin event
pub fn emit_insert_begin(
    start: u64,
    end: u64,
    key: i64,
    node: usize,
    height: usize,
    found: Option<usize>,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let found_str = match found {
        Some(ptr) => format!("\"{}\"", get_node_id(ptr)),
        None => "\"nil\"".to_string(),
    };
    let json = format!(
        r#"{{"tag":"trace","event":"InsertBegin","tid":"{}","start":{},"end":{},"key":{},"node":"{}","height":{},"found":{},"state":{{"nodeKey":{}}}}}"#,
        tid, start, end, key, node_id, height, found_str, key
    );
    emit_raw(&json);
}

/// Emit InsertCAS event
pub fn emit_insert_cas(
    start: u64,
    end: u64,
    key: i64,
    node: usize,
    result: bool,
    old_node: Option<usize>,
    list_size: usize,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let result_str = if result { "\"success\"" } else { "\"fail\"" };
    let old_str = match old_node {
        Some(ptr) => format!("\"{}\"", get_node_id(ptr)),
        None => "\"nil\"".to_string(),
    };
    let json = format!(
        r#"{{"tag":"trace","event":"InsertCAS","tid":"{}","start":{},"end":{},"key":{},"node":"{}","result":{},"oldNode":{},"state":{{"nodeKey":{},"listSize":{}}}}}"#,
        tid, start, end, key, node_id, result_str, old_str, key, list_size
    );
    emit_raw(&json);
}

/// Emit InsertBuildLevel event
pub fn emit_insert_build_level(
    start: u64,
    end: u64,
    key: i64,
    node: usize,
    level: usize,
    ref_count: usize,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let json = format!(
        r#"{{"tag":"trace","event":"InsertBuildLevel","tid":"{}","start":{},"end":{},"key":{},"node":"{}","level":{},"state":{{"level":{},"refCount":{}}}}}"#,
        tid, start, end, key, node_id, level, level, ref_count
    );
    emit_raw(&json);
}

/// Emit RemoveBegin event
pub fn emit_remove_begin(
    start: u64,
    end: u64,
    key: i64,
    node: usize,
    ref_count: usize,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let json = format!(
        r#"{{"tag":"trace","event":"RemoveBegin","tid":"{}","start":{},"end":{},"key":{},"node":"{}","state":{{"refCount":{}}}}}"#,
        tid, start, end, key, node_id, ref_count
    );
    emit_raw(&json);
}

/// Emit RemoveMarkTower event
pub fn emit_remove_mark_tower(
    start: u64,
    end: u64,
    key: i64,
    node: usize,
    won: bool,
    removed: bool,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let json = format!(
        r#"{{"tag":"trace","event":"RemoveMarkTower","tid":"{}","start":{},"end":{},"key":{},"node":"{}","won":{},"state":{{"removed":{}}}}}"#,
        tid, start, end, key, node_id, won, removed
    );
    emit_raw(&json);
}

/// Emit RemoveUnlink event
pub fn emit_remove_unlink(
    start: u64,
    end: u64,
    key: i64,
    node: usize,
    unlinked_levels: usize,
    ref_count: usize,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let json = format!(
        r#"{{"tag":"trace","event":"RemoveUnlink","tid":"{}","start":{},"end":{},"key":{},"node":"{}","unlinkedLevels":{},"state":{{"refCount":{}}}}}"#,
        tid, start, end, key, node_id, unlinked_levels, ref_count
    );
    emit_raw(&json);
}

/// Emit Get event
pub fn emit_get(
    start: u64,
    end: u64,
    key: i64,
    found: bool,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let json = format!(
        r#"{{"tag":"trace","event":"Get","tid":"{}","start":{},"end":{},"key":{},"found":{}}}"#,
        tid, start, end, key, found
    );
    emit_raw(&json);
}

/// Emit ReleaseEntry event
pub fn emit_release_entry(
    start: u64,
    end: u64,
    node: usize,
    ref_count: usize,
) {
    if !is_active() { return; }
    let tid = match get_tid() { Some(t) => t, None => return };
    let node_id = get_node_id(node);
    let json = format!(
        r#"{{"tag":"trace","event":"ReleaseEntry","tid":"{}","start":{},"end":{},"node":"{}","state":{{"refCount":{}}}}}"#,
        tid, start, end, node_id, ref_count
    );
    emit_raw(&json);
}
