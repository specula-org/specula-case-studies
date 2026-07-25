//! TLA+ trace emission for crossbeam-deque (Category B timebox).
//!
//! Per-thread NDJSON writer; rdtsc timestamps; thread-local buffer-pointer
//! cache backed by a global mutex'd registry. See the harness INSTRUMENTATION.md
//! for the full event schema.

#![allow(dead_code)]

extern crate std;

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::string::{String, ToString};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{format, thread_local};

thread_local! {
    static TRACE_WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static THREAD_NAME: RefCell<String> = RefCell::new(String::from("unknown"));
    static BUF_ID_CACHE: RefCell<HashMap<usize, u64>> = RefCell::new(HashMap::new());
}

static BUF_ID_REGISTRY: Mutex<Option<HashMap<usize, u64>>> = Mutex::new(None);
static NEXT_BUF_ID: AtomicUsize = AtomicUsize::new(0);

/// Read a fast monotonic timestamp (rdtsc on x86_64; fallback elsewhere).
#[inline]
pub fn rdtsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        std::arch::x86_64::_mm_mfence();
        let r = std::arch::x86_64::_rdtsc();
        std::arch::x86_64::_mm_mfence();
        r
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        use std::time::Instant;
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        let start = START.get_or_init(Instant::now);
        start.elapsed().as_nanos() as u64
    }
}

/// Map a raw buffer pointer to a stable, dense ID (1, 2, 3, …).
///
/// Fast path: thread-local cache. Slow path: global mutex registry — only
/// taken on the first time a thread sees a particular buffer.
pub fn buf_id(ptr: usize) -> u64 {
    if ptr == 0 {
        return 0;
    }
    BUF_ID_CACHE.with(|c| {
        if let Some(&id) = c.borrow().get(&ptr) {
            return id;
        }
        let id = {
            let mut reg = BUF_ID_REGISTRY.lock().unwrap();
            let map = reg.get_or_insert_with(HashMap::new);
            *map.entry(ptr).or_insert_with(|| {
                (NEXT_BUF_ID.fetch_add(1, Ordering::Relaxed) + 1) as u64
            })
        };
        c.borrow_mut().insert(ptr, id);
        id
    })
}

fn trace_dir() -> Option<PathBuf> {
    std::env::var("CROSSBEAM_DEQUE_TRACE_DIR").ok().map(PathBuf::from)
}

/// Open a per-thread NDJSON file. Call once per thread before any emits.
pub fn init_thread(name: &str) {
    THREAD_NAME.with(|n| *n.borrow_mut() = name.to_string());
    let Some(dir) = trace_dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join(format!("trace-{}.ndjson", name));
    if let Ok(f) = OpenOptions::new().create(true).truncate(true).write(true).open(&path) {
        TRACE_WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::new(f)));
    }
}

pub fn close_thread() {
    TRACE_WRITER.with(|w| {
        if let Some(mut writer) = w.borrow_mut().take() {
            let _ = writer.flush();
        }
    });
}

#[inline]
fn write_line(line: &str) {
    TRACE_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writer.write_all(line.as_bytes());
            let _ = writer.write_all(b"\n");
        }
    });
}

#[inline]
fn current_name<F: FnOnce(&str) -> String>(f: F) -> String {
    THREAD_NAME.with(|n| f(&n.borrow()))
}

/// State snapshot captured outside the timebox interval.
#[derive(Clone, Copy)]
pub struct State {
    pub front: i64,
    pub back: i64,
    pub buf_id: u64,
}

/// Best-effort u64 view of any T, for debug "val" fields (not validated by spec).
///
/// Tests use `T = usize` so this round-trips. For other T the bytes are still
/// stable but uninterpreted.
#[inline]
pub fn val_view<T>(p: *const T) -> u64 {
    let size = std::mem::size_of::<T>();
    if size == 0 {
        return 0;
    }
    let mut bytes = [0u8; 8];
    let n = if size > 8 { 8 } else { size };
    unsafe {
        std::ptr::copy_nonoverlapping(p as *const u8, bytes.as_mut_ptr(), n);
    }
    u64::from_le_bytes(bytes)
}

// =========================================================================
// Worker events
// =========================================================================

pub fn emit_push_write_slot(start: u64, end: u64, st: State, val: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"PushWriteSlot\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"val\":{val}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_push_store_back(start: u64, end: u64, st: State) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"PushStoreBack\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_lifo_pop_decr_fence(start: u64, end: u64, st: State) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"LIFOPopDecrFence\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_lifo_pop_decide(start: u64, end: u64, st: State, result: &str, val: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"LIFOPopDecide\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"result\":\"{result}\",\"val\":{val}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_fifo_pop_attempt(start: u64, end: u64, st: State, result: &str, val: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"FIFOPopAttempt\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"result\":\"{result}\",\"val\":{val}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_fifo_pop_rollback(start: u64, end: u64, st: State) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"FIFOPopRollback\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_resize_grow(start: u64, end: u64, st: State, old_buf: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"ResizeGrow\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"oldBufferID\":{old_buf}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

// =========================================================================
// Stealer events
// =========================================================================

pub fn emit_steal_load_front_single(start: u64, end: u64, st: State, cached_front: i64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealLoadFront_Single\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"cachedFront\":{cached_front}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_load_front_batch_fifo(start: u64, end: u64, st: State, cached_front: i64, batch_size: i64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealLoadFront_BatchFifo\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"cachedFront\":{cached_front},\"batchSize\":{batch_size}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_load_front_batch_lifo(start: u64, end: u64, st: State, cached_front: i64, batch_size: i64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealLoadFront_BatchLifo\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"cachedFront\":{cached_front},\"batchSize\":{batch_size}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_pin(start: u64, end: u64, st: State, was_reentrant: bool) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealPin\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"wasReentrant\":{wr}}}",
        f = st.front, b = st.back, buf = st.buf_id, wr = was_reentrant
    );
    write_line(&line);
}

pub fn emit_steal_load_back(start: u64, end: u64, st: State, cached_back: i64, result: &str) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealLoadBack\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"cachedBack\":{cached_back},\"result\":\"{result}\"}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_load_buffer(start: u64, end: u64, st: State, cached_buf: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealLoadBuffer\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"cachedBuf\":{cached_buf}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_read_slot(start: u64, end: u64, st: State, read_val: u64, read_from_buf: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealReadSlot\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"readVal\":{read_val},\"readFromBuf\":{read_from_buf}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_recheck_cas(
    start: u64,
    end: u64,
    st: State,
    site: &str,
    recheck_result: &str,
    cas_result: &str,
    stolen_count: i64,
) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealRecheckCAS\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"site\":\"{site}\",\"recheckResult\":\"{recheck_result}\",\
         \"casResult\":\"{cas_result}\",\"stolenCount\":{stolen_count}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

pub fn emit_steal_lifo_batch_iter(
    start: u64,
    end: u64,
    st: State,
    iter: i64,
    iter_result: &str,
    tmp_val: u64,
) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealLIFOBatchIter\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"state\":{{\"front\":{f},\"back\":{b},\"bufferID\":{buf}}},\
         \"iter\":{iter},\"iterResult\":\"{iter_result}\",\"tmpVal\":{tmp_val}}}",
        f = st.front, b = st.back, buf = st.buf_id
    );
    write_line(&line);
}

// =========================================================================
// Caller-harness events (Family C)
// =========================================================================

pub fn emit_stealer_clone_adv(start: u64, end: u64, new_stealer: &str) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"StealerCloneAdv\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end},\
         \"newStealer\":\"{new_stealer}\"}}"
    );
    write_line(&line);
}

pub fn emit_worker_drop_adv(start: u64, end: u64) {
    let name = current_name(|n| n.to_string());
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"WorkerDropAdv\",\"thread\":\"{name}\",\
         \"start\":{start},\"end\":{end}}}"
    );
    write_line(&line);
}
