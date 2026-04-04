// TLA+ Trace Emission Module for papaya lock-free hash map
// Category B (Concurrent/Lock-Free): per-thread trace files, timebox intervals
//
// Each event records [start, end] timestamps around the critical operation.
// State is captured AFTER the interval to keep it tight.
// Per-thread files avoid mutex contention that would cause probe effects.

#![allow(dead_code)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

// ============================================================
// Global state
// ============================================================

static ENABLED: AtomicBool = AtomicBool::new(false);
static TRACE_DIR: Mutex<Option<String>> = Mutex::new(None);
static SCENARIO_NAME: Mutex<Option<String>> = Mutex::new(None);

// Base instant for monotonic timestamps (ns precision)
static BASE_INSTANT: OnceLock<Instant> = OnceLock::new();

// Table ID registry: raw pointer address -> sequential table ID
static TABLE_COUNTER: AtomicU64 = AtomicU64::new(1);
static TABLE_MAP: Mutex<Option<HashMap<usize, u64>>> = Mutex::new(None);

// Thread ID counter for deterministic thread naming
static THREAD_COUNTER: AtomicU64 = AtomicU64::new(0);

// ============================================================
// Per-thread state
// ============================================================

thread_local! {
    static WRITER: RefCell<Option<BufWriter<File>>> = RefCell::new(None);
    static THREAD_NAME: RefCell<Option<String>> = RefCell::new(None);
    // Pending operation context: set by test before HashMap call,
    // read by instrumented code during the call
    static PENDING_KEY: RefCell<Option<String>> = RefCell::new(None);
    static PENDING_VAL: RefCell<Option<String>> = RefCell::new(None);
}

// ============================================================
// Initialization / shutdown
// ============================================================

/// Check if tracing is enabled. Very cheap (single relaxed atomic load).
#[inline]
pub fn is_enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// Initialize tracing for a scenario. Call once before spawning threads.
pub fn init(trace_dir: &str, scenario: &str) {
    BASE_INSTANT.get_or_init(Instant::now);
    *TABLE_MAP.lock().unwrap() = Some(HashMap::new());
    TABLE_COUNTER.store(1, Ordering::SeqCst);
    THREAD_COUNTER.store(0, Ordering::SeqCst);
    *TRACE_DIR.lock().unwrap() = Some(trace_dir.to_string());
    *SCENARIO_NAME.lock().unwrap() = Some(scenario.to_string());
    ENABLED.store(true, Ordering::SeqCst);
}

/// Initialize per-thread trace writer. Call at start of each traced thread.
pub fn thread_init() {
    let tid = current_thread_id();
    let dir = TRACE_DIR.lock().unwrap().clone().unwrap_or_else(|| ".".to_string());
    let scenario = SCENARIO_NAME.lock().unwrap().clone().unwrap_or_else(|| "trace".to_string());
    let path = format!("{}/{}-thread-{}.ndjson", dir, scenario, tid);
    let file = File::create(&path).unwrap_or_else(|e| panic!("Failed to create trace file {}: {}", path, e));
    WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::new(file)));
}

/// Flush and close per-thread trace writer. Call at end of each traced thread.
pub fn thread_shutdown() {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writer.flush().ok();
        }
        *w.borrow_mut() = None;
    });
}

/// Disable tracing globally.
pub fn shutdown() {
    ENABLED.store(false, Ordering::SeqCst);
}

// ============================================================
// Timestamps
// ============================================================

/// Returns monotonic timestamp in nanoseconds from process start.
#[inline]
pub fn timestamp_ns() -> u64 {
    BASE_INSTANT
        .get()
        .map(|base| base.elapsed().as_nanos() as u64)
        .unwrap_or(0)
}

// ============================================================
// Table ID management
// ============================================================

/// Get or register a table ID for a raw pointer address.
/// First call for an address assigns a new sequential ID.
pub fn table_id(raw_addr: usize) -> u64 {
    if raw_addr == 0 {
        return 0;
    }
    let mut map = TABLE_MAP.lock().unwrap();
    if let Some(ref mut m) = *map {
        if let Some(&id) = m.get(&raw_addr) {
            return id;
        }
        let id = TABLE_COUNTER.fetch_add(1, Ordering::SeqCst);
        m.insert(raw_addr, id);
        id
    } else {
        0
    }
}

// ============================================================
// Thread ID management
// ============================================================

/// Returns a deterministic thread name (t0, t1, t2, ...).
/// Assigned on first call per thread; stable for the thread's lifetime.
pub fn current_thread_id() -> String {
    THREAD_NAME.with(|tn| {
        // Check if already assigned (drop borrow before potential borrow_mut)
        let existing = { tn.borrow().clone() };
        if let Some(name) = existing {
            return name;
        }
        let id = THREAD_COUNTER.fetch_add(1, Ordering::SeqCst);
        let name = format!("t{}", id);
        *tn.borrow_mut() = Some(name.clone());
        name
    })
}

// ============================================================
// Pending operation context
// ============================================================

/// Set the key for the current pending operation (call before HashMap::insert/remove).
pub fn set_pending_key(k: &str) {
    PENDING_KEY.with(|pk| *pk.borrow_mut() = Some(k.to_string()));
}

/// Set the value for the current pending operation (call before HashMap::insert).
pub fn set_pending_val(v: &str) {
    PENDING_VAL.with(|pv| *pv.borrow_mut() = Some(v.to_string()));
}

/// Get the pending key, or "null" if none set.
pub fn pending_key() -> String {
    PENDING_KEY.with(|pk| pk.borrow().clone().unwrap_or_else(|| "null".to_string()))
}

/// Get the pending value, or "null" if none set.
pub fn pending_val() -> String {
    PENDING_VAL.with(|pv| pv.borrow().clone().unwrap_or_else(|| "null".to_string()))
}

/// Clear the pending operation context.
pub fn clear_pending() {
    PENDING_KEY.with(|pk| *pk.borrow_mut() = None);
    PENDING_VAL.with(|pv| *pv.borrow_mut() = None);
}

// ============================================================
// Trace emission
// ============================================================

/// Emit a raw JSON line to the current thread's trace file.
pub fn emit(line: &str) {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writeln!(writer, "{}", line).ok();
        }
    });
}

// ============================================================
// Formatting helpers
// ============================================================

/// Convert a metadata byte to its TLA+ name.
pub fn meta_str(m: u8) -> &'static str {
    if m == 0x80 {
        "Empty"
    } else if m == 0xFF {
        "Tombstone"
    } else {
        "H2"
    }
}

/// Convert entry pointer tag bits to TLA+ tag name.
pub fn tag_str(raw_addr: usize) -> &'static str {
    const COPYING: usize = 0b001;
    const COPIED: usize = 0b010;
    const BORROWED: usize = 0b100;
    let bits = raw_addr & 0b111;

    if bits & (COPYING | COPIED) == (COPYING | COPIED) {
        "Copied"
    } else if bits & COPYING != 0 {
        "Copying"
    } else if bits & BORROWED != 0 {
        "Borrowed"
    } else {
        "None"
    }
}

/// Convert resize status byte to TLA+ name.
pub fn resize_status_str(s: u8) -> &'static str {
    match s {
        0 => "Pending",
        1 => "Aborted",
        2 => "Promoted",
        _ => "Unknown",
    }
}

// ============================================================
// Per-event emit helpers
// ============================================================

pub fn emit_insert_begin(start: u64, end: u64, tbl: u64) {
    let tid = current_thread_id();
    let key = pending_key();
    let val = pending_val();
    emit(&format!(
        r#"{{"tag":"trace","event":"InsertBegin","thread":"{}","start":{},"end":{},"key":"{}","val":"{}","state":{{"table":{}}}}}"#,
        tid, start, end, key, val, tbl
    ));
}

pub fn emit_insert_read_meta(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"InsertProbe","thread":"{}","start":{},"end":{},"table_id":{},"slot":{},"state":{{"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_insert_cas(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"InsertCAS","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_insert_store_meta(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"StoreMeta","thread":"{}","start":{},"end":{},"table_id":{},"slot":{},"state":{{"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_insert_update(start: u64, end: u64, tbl: u64, slot: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"InsertUpdate","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{}}}}}"#,
        tid, start, end, tbl, slot
    ));
}

pub fn emit_remove_begin(start: u64, end: u64, tbl: u64) {
    let tid = current_thread_id();
    let key = pending_key();
    emit(&format!(
        r#"{{"tag":"trace","event":"RemoveBegin","thread":"{}","start":{},"end":{},"key":"{}","state":{{"table":{}}}}}"#,
        tid, start, end, key, tbl
    ));
}

pub fn emit_remove_read_meta(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"RemoveProbe","thread":"{}","start":{},"end":{},"table_id":{},"slot":{},"state":{{"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_remove_cas(start: u64, end: u64, tbl: u64, slot: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"RemoveCAS","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{}}}}}"#,
        tid, start, end, tbl, slot
    ));
}

pub fn emit_remove_store_meta(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"RemoveStoreMeta","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_alloc_next_table(start: u64, end: u64, root_tbl: u64, current_tbl: u64, next_tbl: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"AllocNextTable","thread":"{}","start":{},"end":{},"state":{{"root":{},"table":{},"next_table":{}}}}}"#,
        tid, start, end, root_tbl, current_tbl, next_tbl
    ));
}

pub fn emit_mark_copying(start: u64, end: u64, tbl: u64, slot: usize, tag_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"MarkCopying","thread":"{}","start":{},"end":{},"table_id":{},"slot":{},"state":{{"tag":"{}"}}}}"#,
        tid, start, end, tbl, slot, tag_val
    ));
}

pub fn emit_mark_copying_empty(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"MarkCopyingEmpty","thread":"{}","start":{},"end":{},"table_id":{},"slot":{},"state":{{"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_copy_entry(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"CopyEntry","thread":"{}","start":{},"end":{},"table_id":{},"slot":{},"state":{{"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_mark_copied(start: u64, end: u64, tbl: u64, slot: usize, tag_val: &str, copied_count: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"MarkCopied","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"tag":"{}","copied_count":{}}}}}"#,
        tid, start, end, tbl, slot, tag_val, copied_count
    ));
}

pub fn emit_abort_resize(start: u64, end: u64, status: &str, status_tbl: u64, next_tbl: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"AbortResize","thread":"{}","start":{},"end":{},"state":{{"resize_status":"{}","status_table":{},"next_table":{}}}}}"#,
        tid, start, end, status, status_tbl, next_tbl
    ));
}

pub fn emit_try_promote(start: u64, end: u64, root_tbl: u64, status: &str, status_tbl: u64, copied_count: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"TryPromote","thread":"{}","start":{},"end":{},"state":{{"root":{},"resize_status":"{}","status_table":{},"copied_count":{}}}}}"#,
        tid, start, end, root_tbl, status, status_tbl, copied_count
    ));
}

pub fn emit_park_thread(start: u64, end: u64, tbl: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"ParkThread","thread":"{}","start":{},"end":{},"state":{{"table":{}}}}}"#,
        tid, start, end, tbl
    ));
}

pub fn emit_unpark_thread(start: u64, end: u64, tbl: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"UnparkThread","thread":"{}","start":{},"end":{},"state":{{"table":{}}}}}"#,
        tid, start, end, tbl
    ));
}

// --- Get operation events ---

pub fn emit_get_read_meta(start: u64, end: u64, tbl: u64, slot: usize, meta_val: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"GetReadMeta","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"meta":"{}"}}}}"#,
        tid, start, end, tbl, slot, meta_val
    ));
}

pub fn emit_get_load_entry(start: u64, end: u64, tbl: u64, slot: usize, entry_key: &str, entry_tags: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"GetLoadEntry","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"entry_key":"{}","entry_tags":"{}"}}}}"#,
        tid, start, end, tbl, slot, entry_key, entry_tags
    ));
}

// --- Insert load-for-update event ---

pub fn emit_insert_load_update(start: u64, end: u64, tbl: u64, slot: usize, entry_key: &str, entry_tags: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"InsertLoadUpdate","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"entry_key":"{}","entry_tags":"{}"}}}}"#,
        tid, start, end, tbl, slot, entry_key, entry_tags
    ));
}

// --- Remove load-entry event ---

pub fn emit_remove_load_entry(start: u64, end: u64, tbl: u64, slot: usize, entry_key: &str, entry_tags: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"debug","event":"RemoveLoadEntry","thread":"{}","start":{},"end":{},"state":{{"table":{},"slot":{},"entry_key":"{}","entry_tags":"{}"}}}}"#,
        tid, start, end, tbl, slot, entry_key, entry_tags
    ));
}
