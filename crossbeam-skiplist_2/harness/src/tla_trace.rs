#![allow(
    clippy::std_instead_of_alloc,
    clippy::std_instead_of_core,
    clippy::alloc_instead_of_core,
    missing_docs
)]
//! TLA+ trace emission for crossbeam-skiplist (Category B / timebox).
//!
//! Each thread writes its own NDJSON file at `$CROSSBEAM_SKIPLIST_TRACE_DIR/thread_<tid>.ndjson`.
//! Events carry `[start, end]` rdtsc intervals so TLC can search legal interleavings
//! with the OmniLink-style `ViablePIDs` constraint in `Trace.tla`.
//!
//! Activated by the `tla-trace` Cargo feature. When the feature is off the
//! emitter functions are stub no-ops, the source compiles unchanged, and there
//! is zero runtime overhead.

extern crate std;

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::{create_dir_all, File};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::string::String;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::{format, thread_local, write};

static TRACE_DIR: OnceLock<Option<PathBuf>> = OnceLock::new();
static THREAD_COUNTER: AtomicU32 = AtomicU32::new(0);
static NODE_COUNTER: AtomicU64 = AtomicU64::new(0);
static NODE_REGISTRY: OnceLock<Mutex<HashMap<usize, u64>>> = OnceLock::new();
static ITER_COUNTER: AtomicU64 = AtomicU64::new(0);

thread_local! {
    static TID_CELL: RefCell<Option<u32>> = const { RefCell::new(None) };
    static WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static NODE_CACHE: RefCell<HashMap<usize, u64>> = RefCell::new(HashMap::new());

    static CUR_KEY: RefCell<i64> = const { RefCell::new(0) };
    static CUR_VALUE: RefCell<i64> = const { RefCell::new(0) };

    static ITER_KIND: RefCell<&'static str> = const { RefCell::new("iter") };
    static ITER_PREV_STATE: RefCell<&'static str> = const { RefCell::new("Fresh") };
    static ITER_ID: RefCell<u64> = const { RefCell::new(0) };
}

fn dir() -> Option<&'static PathBuf> {
    TRACE_DIR
        .get_or_init(|| {
            std::env::var("CROSSBEAM_SKIPLIST_TRACE_DIR").ok().map(|s| {
                let pb = PathBuf::from(&s);
                let _ = create_dir_all(&pb);
                pb
            })
        })
        .as_ref()
}

#[inline]
pub fn enabled() -> bool {
    dir().is_some()
}

fn tid() -> u32 {
    TID_CELL.with(|t| {
        if let Some(v) = *t.borrow() {
            return v;
        }
        let v = THREAD_COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
        *t.borrow_mut() = Some(v);
        v
    })
}

fn ensure_writer() {
    WRITER.with(|w| {
        if w.borrow().is_some() {
            return;
        }
        if let Some(d) = dir() {
            let id = tid();
            let path = d.join(format!("thread_{}.ndjson", id));
            if let Ok(f) = File::create(&path) {
                *w.borrow_mut() = Some(BufWriter::new(f));
            }
        }
    });
}

/// Read the time-stamp counter on x86_64 (with mfence). Falls back to a
/// monotonic clock on other architectures.
#[inline(always)]
pub fn read_tsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        core::arch::x86_64::_mm_mfence();
        let lo: u32;
        let hi: u32;
        core::arch::asm!("rdtsc", out("eax") lo, out("edx") hi, options(nomem, nostack));
        ((hi as u64) << 32) | (lo as u64)
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        use std::time::SystemTime;
        SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }
}

/// Map a raw node pointer to a stable, sequential id (1-indexed).
/// Returns 0 for null.
pub fn node_id(ptr: usize) -> u64 {
    if ptr == 0 {
        return 0;
    }
    NODE_CACHE.with(|cache| {
        if let Some(&id) = cache.borrow().get(&ptr) {
            return id;
        }
        let registry = NODE_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()));
        let id = {
            let mut m = registry.lock().unwrap();
            *m.entry(ptr).or_insert_with(|| {
                NODE_COUNTER.fetch_add(1, Ordering::Relaxed) + 1
            })
        };
        cache.borrow_mut().insert(ptr, id);
        id
    })
}

/// Set the typed key/value of the current operation. The test harness calls
/// this BEFORE invoking insert/get/remove so the generic body of
/// `insert_internal` etc. can include the key/value in trace events.
pub fn set_current_op(k: i64, v: i64) {
    CUR_KEY.with(|c| *c.borrow_mut() = k);
    CUR_VALUE.with(|c| *c.borrow_mut() = v);
}

pub fn current_key() -> i64 {
    CUR_KEY.with(|c| *c.borrow())
}
pub fn current_value() -> i64 {
    CUR_VALUE.with(|c| *c.borrow())
}

/// Allocate a fresh iterator id for the current thread.
pub fn new_iter_id() -> u64 {
    let id = ITER_COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
    ITER_ID.with(|c| *c.borrow_mut() = id);
    ITER_PREV_STATE.with(|c| *c.borrow_mut() = "Fresh");
    id
}

pub fn set_iter_kind(k: &'static str) {
    ITER_KIND.with(|c| *c.borrow_mut() = k);
}
pub fn iter_kind() -> &'static str {
    ITER_KIND.with(|c| *c.borrow())
}

pub fn iter_prev_state() -> &'static str {
    ITER_PREV_STATE.with(|c| *c.borrow())
}
pub fn set_iter_prev_state(s: &'static str) {
    ITER_PREV_STATE.with(|c| *c.borrow_mut() = s);
}
pub fn current_iter_id() -> u64 {
    ITER_ID.with(|c| *c.borrow())
}

#[inline]
fn write_line(line: &str) {
    if !enabled() {
        return;
    }
    ensure_writer();
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writer.write_all(line.as_bytes());
            let _ = writer.write_all(b"\n");
        }
    });
}

/// Flush this thread's writer. Tests call this at the end of each scenario
/// because cargo test does not always flush per-thread BufWriters.
pub fn flush_writer() {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writer.flush();
        }
    });
}

// =========================================================================
// Per-event emit helpers. JSON is hand-formatted; the per-event field shapes
// are defined in instrumentation-spec.md (Section 1).
// =========================================================================

#[inline]
fn envelope_open(buf: &mut String, name: &str, start: u64, end: u64) {
    use std::fmt::Write;
    let _ = write!(
        buf,
        "{{\"tag\":\"trace\",\"event\":\"{}\",\"thread\":\"t{}\",\"start\":{},\"end\":{}",
        name,
        tid(),
        start,
        end
    );
}

pub fn emit_insert_begin(start: u64, end: u64, len: usize, found_node: u64) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Insert_Begin", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"len\":{}}},\"key\":{},\"value\":{},\"found_node\":{}}}",
        len,
        current_key(),
        current_value(),
        found_node
    );
    write_line(&buf);
}

pub fn emit_insert_alloc_cas_level0(
    start: u64,
    end: u64,
    node: u64,
    len: usize,
    refcount: usize,
    height: usize,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(180);
    envelope_open(&mut buf, "Insert_AllocCASLevel0", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"len\":{},\"refcount\":{}}},\"node\":{},\"height\":{}}}",
        len, refcount, node, height
    );
    write_line(&buf);
}

pub fn emit_insert_mark_old(
    start: u64,
    end: u64,
    node: u64,
    mark_won: bool,
    len: usize,
    marked0: bool,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(180);
    envelope_open(&mut buf, "Insert_MarkOld", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"len\":{},\"marked0\":{}}},\"node\":{},\"mark_won\":{}}}",
        len, marked0, node, mark_won
    );
    write_line(&buf);
}

pub fn emit_insert_build_level(
    start: u64,
    end: u64,
    node: u64,
    level: usize,
    refcount: usize,
    result: &str,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(180);
    envelope_open(&mut buf, "Insert_BuildLevel", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"refcount\":{}}},\"node\":{},\"level\":{},\"result\":\"{}\"}}",
        refcount, node, level, result
    );
    write_line(&buf);
}

pub fn emit_insert_post_build_check(
    start: u64,
    end: u64,
    node: u64,
    top_level_marked: bool,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Insert_PostBuildCheck", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{}},\"node\":{},\"top_level_marked\":{}}}",
        node, top_level_marked
    );
    write_line(&buf);
}

pub fn emit_insert_done(start: u64, end: u64, node: u64, refcount: usize) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Insert_Done", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"refcount\":{}}},\"node\":{}}}",
        refcount, node
    );
    write_line(&buf);
}

pub fn emit_get(start: u64, end: u64, key: i64, result_node: u64, len: usize) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Get", start, end);
    use std::fmt::Write;
    let result = if result_node == 0 { "none" } else { "some" };
    let _ = write!(
        buf,
        ",\"state\":{{\"len\":{}}},\"key\":{},\"result\":\"{}\",\"node\":{}}}",
        len, key, result, result_node
    );
    write_line(&buf);
}

pub fn emit_remove_begin(start: u64, end: u64, key: i64, target_node: u64, len: usize) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Remove_Begin", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"len\":{}}},\"key\":{},\"target_node\":{}}}",
        len, key, target_node
    );
    write_line(&buf);
}

pub fn emit_remove_acquire(
    start: u64,
    end: u64,
    node: u64,
    acquired: bool,
    refcount: usize,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Remove_Acquire", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"refcount\":{}}},\"node\":{},\"acquired\":{}}}",
        refcount, node, acquired
    );
    write_line(&buf);
}

pub fn emit_remove_mark_tower(
    start: u64,
    end: u64,
    node: u64,
    mark_won: bool,
    len: usize,
    refcount: usize,
    marked0: bool,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(200);
    envelope_open(&mut buf, "Remove_MarkTower", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"len\":{},\"refcount\":{},\"marked0\":{}}},\"node\":{},\"mark_won\":{}}}",
        len, refcount, marked0, node, mark_won
    );
    write_line(&buf);
}

pub fn emit_remove_unlink_level(
    start: u64,
    end: u64,
    node: u64,
    level: usize,
    cas_ok: bool,
    refcount: usize,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(180);
    envelope_open(&mut buf, "Remove_UnlinkLevel", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{\"refcount\":{}}},\"node\":{},\"level\":{},\"cas_ok\":{}}}",
        refcount, node, level, cas_ok
    );
    write_line(&buf);
}

pub fn emit_remove_done(start: u64, end: u64, node: u64, refcount: usize, found: bool) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Remove_Done", start, end);
    use std::fmt::Write;
    let result = if found { "some" } else { "none" };
    let _ = write!(
        buf,
        ",\"state\":{{\"refcount\":{}}},\"node\":{},\"result\":\"{}\"}}",
        refcount, node, result
    );
    write_line(&buf);
}

pub fn emit_iter_begin(start: u64, end: u64, kind: &str, iter_id: u64) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(160);
    envelope_open(&mut buf, "Iter_Begin", start, end);
    use std::fmt::Write;
    let _ = write!(
        buf,
        ",\"state\":{{}},\"iter_kind\":\"{}\",\"iter_id\":{}}}",
        kind, iter_id
    );
    write_line(&buf);
}

pub fn emit_iter_next(
    start: u64,
    end: u64,
    iter_id: u64,
    yielded_node: u64,
    prev_state: &str,
    refcount: Option<usize>,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(180);
    envelope_open(&mut buf, "Iter_Next", start, end);
    use std::fmt::Write;
    let result = if yielded_node == 0 { "none" } else { "some" };
    if let Some(rc) = refcount {
        let _ = write!(
            buf,
            ",\"state\":{{\"refcount\":{}}},\"iter_id\":{},\"node\":{},\"result\":\"{}\",\"prev_state\":\"{}\"}}",
            rc, iter_id, yielded_node, result, prev_state
        );
    } else {
        let _ = write!(
            buf,
            ",\"state\":{{}},\"iter_id\":{},\"node\":{},\"result\":\"{}\",\"prev_state\":\"{}\"}}",
            iter_id, yielded_node, result, prev_state
        );
    }
    write_line(&buf);
}

pub fn emit_iter_drop(
    start: u64,
    end: u64,
    iter_id: u64,
    head_decremented: bool,
    tail_decremented: bool,
    head_refcount: Option<usize>,
    tail_refcount: Option<usize>,
) {
    if !enabled() {
        return;
    }
    let mut buf = String::with_capacity(220);
    envelope_open(&mut buf, "Iter_Drop", start, end);
    use std::fmt::Write;
    let head_rc = head_refcount.map(|x| x as i64).unwrap_or(-1);
    let tail_rc = tail_refcount.map(|x| x as i64).unwrap_or(-1);
    let _ = write!(
        buf,
        ",\"state\":{{}},\"iter_id\":{},\"head_decremented\":{},\"tail_decremented\":{},\"head_refcount\":{},\"tail_refcount\":{}}}",
        iter_id, head_decremented, tail_decremented, head_rc, tail_rc
    );
    write_line(&buf);
}
