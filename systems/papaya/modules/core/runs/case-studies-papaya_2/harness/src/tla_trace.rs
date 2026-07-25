// TLA+ Trace Emission Module for papaya lock-free hash map (Round 2)
//
// Category B (concurrent / lock-free): per-thread trace files, no mutex on
// the hot path. Each event records [start, end] timestamps around the
// linearization point. State is captured AFTER `end` to keep the interval
// tight.
//
// Round-2 emits the lowercase event names expected by Trace.tla:
//   insert_cas, insert_meta, insert_meta_fixup, insert_update, remove,
//   copy_mark_copying, copy_mark_copying_null, copy_insert, copy_mark_copied,
//   alloc_next, try_promote, abort_resize, init_table, park,
//   iter_begin, iter_yield, iter_skip, iter_end
//
// Existing emit_* helpers from round 1 are preserved as no-ops so the
// existing instrumentation in raw/mod.rs continues to compile. The round-2
// emit functions are named emit_<spec_name>().
//
// Output format: per-thread NDJSON; the preprocessor merges them into
//   { "threads": { "t1": [...], "t2": [...], ... } }
// with timestamps compressed to dense integers.

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

// Thread ID counter for deterministic thread naming (starts at 1: t1, t2, ...)
static THREAD_COUNTER: AtomicU64 = AtomicU64::new(1);

// ============================================================
// Per-thread state
// ============================================================

thread_local! {
    static WRITER: RefCell<Option<BufWriter<File>>> = RefCell::new(None);
    static THREAD_NAME: RefCell<Option<String>> = RefCell::new(None);
    static LOCAL_TABLE_CACHE: RefCell<HashMap<usize, u64>> = RefCell::new(HashMap::new());
    // Pending operation context: set by tests before the HashMap call
    static PENDING_KEY: RefCell<Option<String>> = RefCell::new(None);
    static PENDING_VAL: RefCell<Option<String>> = RefCell::new(None);
    // Logical operation start timestamp (for widening intervals)
    static OP_START: RefCell<u64> = RefCell::new(0);
    // Iter key formatter: tests set this so iter instrumentation can render K as string.
    // The closure receives the address of K (cast to *const u8) and returns its string form.
    #[allow(clippy::type_complexity)]
    static ITER_KEY_FMT: RefCell<Option<Box<dyn Fn(*const u8) -> String>>> = RefCell::new(None);
    // (src_table_id, src_slot) for the current copy operation, set by callers of
    // insert_copy so the copy_insert event can record the source slot.
    static PENDING_COPY_SRC: RefCell<Option<(u64, usize)>> = RefCell::new(None);
}

/// Register a key formatter for the iterator. Tests call this with a closure
/// that renders K as a string. Without it, iter_yield emits key="?".
pub fn set_iter_key_fmt<F>(f: F)
where F: Fn(*const u8) -> String + 'static {
    ITER_KEY_FMT.with(|cell| *cell.borrow_mut() = Some(Box::new(f)));
}

pub fn clear_iter_key_fmt() {
    ITER_KEY_FMT.with(|cell| *cell.borrow_mut() = None);
}

#[doc(hidden)]
pub fn fmt_iter_key(addr: *const u8) -> String {
    ITER_KEY_FMT.with(|cell| {
        match cell.borrow().as_ref() {
            Some(f) => f(addr),
            None => "?".to_string(),
        }
    })
}

#[doc(hidden)]
pub fn set_pending_copy_src(src_table_id: u64, src_slot: usize) {
    PENDING_COPY_SRC.with(|c| *c.borrow_mut() = Some((src_table_id, src_slot)));
}

#[doc(hidden)]
pub fn clear_pending_copy_src() {
    PENDING_COPY_SRC.with(|c| *c.borrow_mut() = None);
}

#[doc(hidden)]
pub fn pending_copy_src() -> (u64, usize) {
    PENDING_COPY_SRC.with(|c| c.borrow().unwrap_or((0, 0)))
}

// ============================================================
// Logical operation start tracking
// ============================================================

#[inline]
pub fn set_op_start(ts: u64) {
    OP_START.with(|s| *s.borrow_mut() = ts);
}

#[inline]
pub fn get_op_start(fallback: u64) -> u64 {
    OP_START.with(|s| {
        let v = *s.borrow();
        if v > 0 { v } else { fallback }
    })
}

// ============================================================
// Initialization / shutdown
// ============================================================

#[inline]
pub fn is_enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

pub fn init(trace_dir: &str, scenario: &str) {
    BASE_INSTANT.get_or_init(Instant::now);
    *TABLE_MAP.lock().unwrap() = Some(HashMap::new());
    TABLE_COUNTER.store(1, Ordering::SeqCst);
    THREAD_COUNTER.store(1, Ordering::SeqCst);
    *TRACE_DIR.lock().unwrap() = Some(trace_dir.to_string());
    *SCENARIO_NAME.lock().unwrap() = Some(scenario.to_string());
    ENABLED.store(true, Ordering::SeqCst);
}

pub fn thread_init() {
    let tid = current_thread_id();
    let dir = TRACE_DIR.lock().unwrap().clone().unwrap_or_else(|| ".".to_string());
    let scenario = SCENARIO_NAME.lock().unwrap().clone().unwrap_or_else(|| "trace".to_string());
    let path = format!("{}/{}-thread-{}.ndjson", dir, scenario, tid);
    let file = File::create(&path).unwrap_or_else(|e| panic!("Failed to create trace file {}: {}", path, e));
    WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::new(file)));
}

pub fn thread_shutdown() {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writer.flush().ok();
        }
        *w.borrow_mut() = None;
    });
}

pub fn shutdown() {
    ENABLED.store(false, Ordering::SeqCst);
}

// ============================================================
// Timestamps (monotonic ns)
// ============================================================

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

pub fn table_id(raw_addr: usize) -> u64 {
    if raw_addr == 0 {
        return 0;
    }
    LOCAL_TABLE_CACHE.with(|cache| {
        if let Some(&id) = cache.borrow().get(&raw_addr) {
            return id;
        }
        let mut map = TABLE_MAP.lock().unwrap();
        let id = if let Some(ref mut m) = *map {
            *m.entry(raw_addr).or_insert_with(|| TABLE_COUNTER.fetch_add(1, Ordering::SeqCst))
        } else {
            0
        };
        cache.borrow_mut().insert(raw_addr, id);
        id
    })
}

// ============================================================
// Thread ID management
// ============================================================

pub fn current_thread_id() -> String {
    THREAD_NAME.with(|tn| {
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

pub fn set_pending_key(k: &str) {
    PENDING_KEY.with(|pk| *pk.borrow_mut() = Some(k.to_string()));
}

pub fn set_pending_val(v: &str) {
    PENDING_VAL.with(|pv| *pv.borrow_mut() = Some(v.to_string()));
}

pub fn pending_key() -> String {
    PENDING_KEY.with(|pk| pk.borrow().clone().unwrap_or_else(|| "null".to_string()))
}

pub fn pending_val() -> String {
    PENDING_VAL.with(|pv| pv.borrow().clone().unwrap_or_else(|| "null".to_string()))
}

pub fn clear_pending() {
    PENDING_KEY.with(|pk| *pk.borrow_mut() = None);
    PENDING_VAL.with(|pv| *pv.borrow_mut() = None);
}

// ============================================================
// Trace emission (raw line)
// ============================================================

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

pub fn meta_byte(m: u8) -> &'static str {
    if m == 0x80 { "META_EMPTY" }
    else if m == 0xFE { "META_TOMBSTONE" }
    else { "H2" }
}

pub fn tag_str(raw_addr: usize) -> &'static str {
    const COPYING: usize = 0b001;
    const COPIED: usize = 0b010;
    const BORROWED: usize = 0b100;
    let bits = raw_addr & 0b111;
    if bits & (COPYING | COPIED) == (COPYING | COPIED) { "Copied" }
    else if bits & COPYING != 0 { "Copying" }
    else if bits & BORROWED != 0 { "Borrowed" }
    else { "None" }
}

pub fn meta_str(m: u8) -> &'static str { meta_byte(m) }
pub fn resize_status_str(s: u8) -> &'static str {
    match s { 0 => "Pending", 1 => "Aborted", 2 => "Promoted", _ => "Unknown" }
}

// ============================================================
// Round-2 spec-aligned emit functions
//
// Each emits the lowercase event name expected by Trace.tla. Field names
// match the round-2 instrumentation spec exactly.
// ============================================================

/// `insert_cas` — Phase-1 CAS success (winner claims slot).
pub fn emit_insert_cas(start: u64, end: u64, table: u64, slot: usize, pre_meta: &str, pre_entry: u64) {
    let tid = current_thread_id();
    let key = pending_key();
    let val = pending_val();
    emit(&format!(
        r#"{{"tag":"trace","event":"insert_cas","thread":"{}","start":{},"end":{},"table":{},"slot":{},"key":"{}","value":"{}","pre_meta":"{}","pre_entry":{}}}"#,
        tid, start, end, table, slot, key, val, pre_meta, pre_entry
    ));
}

/// `insert_meta` — Phase-2 winner unconditional meta store.
pub fn emit_insert_meta(start: u64, end: u64, table: u64, slot: usize, meta: &str, entry_at_store_null: bool) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"insert_meta","thread":"{}","start":{},"end":{},"table":{},"slot":{},"meta":"{}","entry_at_store_null":{}}}"#,
        tid, start, end, table, slot, meta, entry_at_store_null
    ));
}

/// `insert_meta_fixup` — Loser fixup path.
pub fn emit_insert_meta_fixup(start: u64, end: u64, table: u64, slot: usize, observed_key: &str, meta_pre: &str, meta: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"insert_meta_fixup","thread":"{}","start":{},"end":{},"table":{},"slot":{},"observed_key":"{}","meta_pre":"{}","meta":"{}"}}"#,
        tid, start, end, table, slot, observed_key, meta_pre, meta
    ));
}

/// `insert_update` — Replace existing entry value.
pub fn emit_insert_update(start: u64, end: u64, table: u64, slot: usize, old_value: &str) {
    let tid = current_thread_id();
    let key = pending_key();
    let val = pending_val();
    emit(&format!(
        r#"{{"tag":"trace","event":"insert_update","thread":"{}","start":{},"end":{},"table":{},"slot":{},"key":"{}","value":"{}","old_value":"{}"}}"#,
        tid, start, end, table, slot, key, val, old_value
    ));
}

/// `remove` — CAS entry → TOMBSTONE.
pub fn emit_remove(start: u64, end: u64, table: u64, slot: usize) {
    let tid = current_thread_id();
    let key = pending_key();
    emit(&format!(
        r#"{{"tag":"trace","event":"remove","thread":"{}","start":{},"end":{},"table":{},"slot":{},"key":"{}"}}"#,
        tid, start, end, table, slot, key
    ));
}

/// `copy_mark_copying` — fetch_or COPYING tag on source slot.
pub fn emit_copy_mark_copying(start: u64, end: u64, table: u64, slot: usize, mode: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"copy_mark_copying","thread":"{}","start":{},"end":{},"table":{},"slot":{},"mode":"{}"}}"#,
        tid, start, end, table, slot, mode
    ));
}

/// `copy_mark_copying_null` — Tombstone null/empty source slot.
pub fn emit_copy_mark_copying_null(start: u64, end: u64, table: u64, slot: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"copy_mark_copying_null","thread":"{}","start":{},"end":{},"table":{},"slot":{}}}"#,
        tid, start, end, table, slot
    ));
}

/// `copy_insert` — Insert copied entry into next table.
pub fn emit_copy_insert(start: u64, end: u64, src_table: u64, src_slot: usize, dst_table: u64, dst_slot: usize, key: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"copy_insert","thread":"{}","start":{},"end":{},"src_table":{},"src_slot":{},"dst_table":{},"dst_slot":{},"key":"{}"}}"#,
        tid, start, end, src_table, src_slot, dst_table, dst_slot, key
    ));
}

/// `copy_mark_copied` — Set COPIED tag on source.
pub fn emit_copy_mark_copied(start: u64, end: u64, table: u64, slot: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"copy_mark_copied","thread":"{}","start":{},"end":{},"table":{},"slot":{}}}"#,
        tid, start, end, table, slot
    ));
}

/// `alloc_next` — Allocate next table.
pub fn emit_alloc_next(start: u64, end: u64, table: u64, next_table: u64, capacity: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"alloc_next","thread":"{}","start":{},"end":{},"table":{},"next_table":{},"capacity":{}}}"#,
        tid, start, end, table, next_table, capacity
    ));
}

/// `try_promote` — CAS root pointer to next table.
pub fn emit_try_promote(start: u64, end: u64, old_root: u64, new_root: u64, copied_count: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"try_promote","thread":"{}","start":{},"end":{},"old_root":{},"new_root":{},"copied_count":{}}}"#,
        tid, start, end, old_root, new_root, copied_count
    ));
}

/// `abort_resize` — Abort current resize (Family 3 / D2-1).
/// `parker_used` and `key_used` capture the buggy unpark target (source table id)
/// per the upstream-master code at `raw/mod.rs:2282-2283`.
pub fn emit_abort_resize(start: u64, end: u64, src_table: u64, aborted_table: u64, parker_used: u64, key_used: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"abort_resize","thread":"{}","start":{},"end":{},"src_table":{},"aborted_table":{},"parker_used":{},"key_used":{}}}"#,
        tid, start, end, src_table, aborted_table, parker_used, key_used
    ));
}

/// `init_table` — Lazy CAS of root.
pub fn emit_init_table(start: u64, end: u64, table: u64, capacity: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"init_table","thread":"{}","start":{},"end":{},"table":{},"capacity":{}}}"#,
        tid, start, end, table, capacity
    ));
}

/// `park` — Thread parks on (parker, key) tuple.
pub fn emit_park(start: u64, end: u64, table: u64, key_addr: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"park","thread":"{}","start":{},"end":{},"table":{},"key_addr":{}}}"#,
        tid, start, end, table, key_addr
    ));
}

/// `iter_begin` — Iterator snapshot (after linearize).
pub fn emit_iter_begin(start: u64, end: u64, snapshot_table: u64) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"iter_begin","thread":"{}","start":{},"end":{},"snapshot_table":{}}}"#,
        tid, start, end, snapshot_table
    ));
}

/// `iter_yield` — Iter::next yields one entry.
pub fn emit_iter_yield(start: u64, end: u64, snapshot_table: u64, slot: usize, key: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"iter_yield","thread":"{}","start":{},"end":{},"snapshot_table":{},"slot":{},"key":"{}"}}"#,
        tid, start, end, snapshot_table, slot, key
    ));
}

/// `iter_skip` — Iter advances past empty/tombstone/null entry.
pub fn emit_iter_skip(start: u64, end: u64, snapshot_table: u64, slot: usize, reason: &str) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"iter_skip","thread":"{}","start":{},"end":{},"snapshot_table":{},"slot":{},"reason":"{}"}}"#,
        tid, start, end, snapshot_table, slot, reason
    ));
}

/// `iter_end` — Iter exhausted.
pub fn emit_iter_end(start: u64, end: u64, snapshot_table: u64, total_yielded: usize) {
    let tid = current_thread_id();
    emit(&format!(
        r#"{{"tag":"trace","event":"iter_end","thread":"{}","start":{},"end":{},"snapshot_table":{},"total_yielded":{}}}"#,
        tid, start, end, snapshot_table, total_yielded
    ));
}

// ============================================================
// Round-1 emit_* shims (no-ops): kept so existing instrumentation
// in raw/mod.rs continues to compile during the round-2 migration.
// They emit no NDJSON, leaving only round-2 events in traces.
// ============================================================

pub fn emit_insert_begin(_s: u64, _e: u64, _t: u64) {}
pub fn emit_insert_read_meta(_s: u64, _e: u64, _t: u64, _slot: usize, _m: &str) {}
pub fn emit_insert_store_meta(start: u64, end: u64, table: u64, slot: usize, meta_val: &str) {
    // Map round-1 emit_insert_store_meta → round-2 insert_meta. Unknown
    // entry_at_store_null defaults to false; the actual instrumentation
    // call site computes it explicitly via emit_insert_meta.
    emit_insert_meta(start, end, table, slot, meta_val, false);
}
pub fn emit_insert_cas_new(start: u64, end: u64, table: u64, slot: usize) {
    // Round-1 winner-CAS event → round-2 insert_cas with default fields.
    emit_insert_cas(start, end, table, slot, "META_EMPTY", 0);
}
pub fn emit_remove_begin(_s: u64, _e: u64, _t: u64) {}
pub fn emit_remove_read_meta(_s: u64, _e: u64, _t: u64, _slot: usize, _m: &str) {}
pub fn emit_remove_cas(start: u64, end: u64, table: u64, slot: usize) {
    // Round-1 RemoveCAS → round-2 remove. The meta-store at line 906-918
    // happens immediately after; we widen the [start, end] interval to
    // cover both the entry CAS and the meta TOMBSTONE store.
    emit_remove(start, end, table, slot);
}
pub fn emit_remove_store_meta(_s: u64, _e: u64, _t: u64, _slot: usize, _m: &str) {
    // Folded into emit_remove (covers up to the meta tombstone store).
}
pub fn emit_alloc_next_table(start: u64, end: u64, _root_tbl: u64, current_tbl: u64, next_tbl: u64) {
    // Capacity unknown at this site; pass 0 (Trace.tla doesn't validate it).
    emit_alloc_next(start, end, current_tbl, next_tbl, 0);
}
pub fn emit_mark_copying(start: u64, end: u64, table: u64, slot: usize, _tag: &str) {
    emit_copy_mark_copying(start, end, table, slot, "blocking");
}
pub fn emit_mark_copying_empty(start: u64, end: u64, table: u64, slot: usize, _meta_val: &str) {
    emit_copy_mark_copying_null(start, end, table, slot);
}
pub fn emit_copy_entry(_s: u64, _e: u64, _t: u64, _slot: usize, _m: &str) {
    // Insufficient context here (no src/dst slot mapping). The new
    // round-2 instrumentation directly calls emit_copy_insert.
}
pub fn emit_mark_copied(start: u64, end: u64, table: u64, slot: usize, _tag: &str, _copied_count: usize) {
    emit_copy_mark_copied(start, end, table, slot);
}
pub fn emit_park_thread(start: u64, end: u64, table: u64) {
    emit_park(start, end, table, table);
}
pub fn emit_unpark_thread(_s: u64, _e: u64, _t: u64) {
    // Not a spec action — the unpark side effect is part of TryPromote / AbortResize.
}

// --- get/getter events: not in round-2 spec, drop them ---
pub fn emit_get_begin(_s: u64, _e: u64, _t: u64) {}
pub fn emit_get_read_meta(_s: u64, _e: u64, _t: u64, _slot: usize, _m: &str) {}
pub fn emit_get_load_entry(_s: u64, _e: u64, _t: u64, _slot: usize, _ek: &str, _et: &str) {}
pub fn emit_get_result(_s: u64, _e: u64, _k: &str, _r: &str) {}

// --- insert/remove retry/copying/deleted events: not in round-2 spec ---
pub fn emit_insert_load_update(_s: u64, _e: u64, _t: u64, _slot: usize, _ek: &str, _et: &str) {}
pub fn emit_remove_load_entry(_s: u64, _e: u64, _t: u64, _slot: usize, _ek: &str, _et: &str) {}
pub fn emit_insert_copying_retry(_s: u64, _e: u64, _t: u64) {}
pub fn emit_insert_update_copying(_s: u64, _e: u64, _t: u64) {}
pub fn emit_insert_update_deleted(_s: u64, _e: u64, _t: u64, _slot: usize) {}
pub fn emit_insert_update_retry(_s: u64, _e: u64, _t: u64, _slot: usize) {}
pub fn emit_remove_not_found(_s: u64, _e: u64, _t: u64) {}
pub fn emit_remove_copying(_s: u64, _e: u64, _t: u64) {}
pub fn emit_copy_begin(_s: u64, _e: u64) {}
pub fn emit_copy_done(_s: u64, _e: u64, _t: u64, _c: usize) {}
