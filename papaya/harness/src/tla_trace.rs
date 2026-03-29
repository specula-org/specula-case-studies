//! Per-thread timebox trace writer for papaya TLA+ trace validation.
//!
//! Category B (concurrent/lock-free): uses per-thread files with rdtsc [start, end]
//! intervals. No mutex on the hot path — each thread writes to its own file.
//!
//! Activation: set PAPAYA_TRACE_DIR=/path/to/dir before running tests.
//! Each thread creates trace-thread-{tid}.ndjson in that directory.
//!
//! Key/value extraction uses raw byte reading (no Debug bound needed).
//! For i32 keys/values, this produces the integer directly.

use std::cell::RefCell;
use std::collections::HashMap as StdHashMap;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

// ===== Global state =====

static ACTIVE: AtomicBool = AtomicBool::new(false);
static TRACE_DIR: OnceLock<String> = OnceLock::new();
static THREAD_COUNTER: AtomicUsize = AtomicUsize::new(0);
static TABLE_ID_COUNTER: AtomicUsize = AtomicUsize::new(1);

fn table_id_map() -> &'static Mutex<StdHashMap<usize, usize>> {
    static MAP: OnceLock<Mutex<StdHashMap<usize, usize>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(StdHashMap::new()))
}

// ===== Per-thread state =====

thread_local! {
    static WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static TID: RefCell<usize> = const { RefCell::new(usize::MAX) };
}

// ===== rdtsc timestamp =====

#[inline]
pub fn rdtsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    {
        unsafe {
            core::arch::x86_64::_mm_mfence();
            let lo: u32;
            let hi: u32;
            core::arch::asm!("rdtsc", out("eax") lo, out("edx") hi);
            core::arch::x86_64::_mm_mfence();
            ((hi as u64) << 32) | lo as u64
        }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        use std::time::Instant;
        static START: OnceLock<Instant> = OnceLock::new();
        let start = START.get_or_init(Instant::now);
        start.elapsed().as_nanos() as u64
    }
}

// ===== Initialization =====

fn init() {
    static INITIALIZED: OnceLock<()> = OnceLock::new();
    INITIALIZED.get_or_init(|| {
        if let Ok(dir) = std::env::var("PAPAYA_TRACE_DIR") {
            fs::create_dir_all(&dir).ok();
            TRACE_DIR.set(dir.clone()).ok();
            ACTIVE.store(true, Ordering::Release);
            eprintln!("[tla_trace] Tracing active, dir={}", dir);
        }
    });
}

#[inline]
pub fn is_active() -> bool {
    let active = ACTIVE.load(Ordering::Relaxed);
    if !active {
        init();
        ACTIVE.load(Ordering::Relaxed)
    } else {
        true
    }
}

// ===== Thread registration =====

fn ensure_writer() -> usize {
    TID.with(|tid| {
        let mut t = tid.borrow_mut();
        if *t == usize::MAX {
            let new_tid = THREAD_COUNTER.fetch_add(1, Ordering::Relaxed);
            *t = new_tid;
            let dir = TRACE_DIR.get().unwrap();
            let path = format!("{}/trace-thread-{}.ndjson", dir, new_tid);
            let file = File::create(&path).expect("Failed to create trace file");
            WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::new(file)));
            eprintln!("[tla_trace] Thread {} -> {}", new_tid, path);
        }
        *t
    })
}

// ===== Table ID mapping =====

pub fn table_id<T>(ptr: *mut T) -> usize {
    if ptr.is_null() {
        return 0;
    }
    let addr = ptr as usize;
    let mut map = table_id_map().lock().unwrap();
    *map.entry(addr)
        .or_insert_with(|| TABLE_ID_COUNTER.fetch_add(1, Ordering::Relaxed))
}

// ===== Raw key/value extraction =====

/// Extract a value as i64 from raw bytes. Works for types <= 8 bytes.
/// For i32 keys, this gives the integer value directly.
#[inline]
pub fn raw_to_i64<T>(val: &T) -> i64 {
    let size = std::mem::size_of::<T>();
    let mut buf = [0u8; 8];
    unsafe {
        std::ptr::copy_nonoverlapping(val as *const T as *const u8, buf.as_mut_ptr(), size.min(8));
    }
    i64::from_ne_bytes(buf)
}

// ===== Core emit function =====

pub fn emit(event: &str, start: u64, end: u64, extra_fields: &str) {
    if !is_active() {
        return;
    }
    let tid = ensure_writer();
    let line = if extra_fields.is_empty() {
        format!(
            r#"{{"tag":"trace","event":"{}","tid":{},"start":{},"end":{}}}"#,
            event, tid, start, end
        )
    } else {
        format!(
            r#"{{"tag":"trace","event":"{}","tid":{},"start":{},"end":{},{}}}"#,
            event, tid, start, end, extra_fields
        )
    };
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writeln!(writer, "{}", line).ok();
        }
    });
}

// ===== Convenience emit functions =====

pub fn emit_insert_cas<K, V>(key: &K, value: &V, table_ptr: *mut u8, slot: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("insert_cas", start, end,
        &format!(r#""key":{},"value":{},"table":{},"slot":{}"#,
            raw_to_i64(key), raw_to_i64(value), tid, slot));
}

pub fn emit_insert_meta(table_ptr: *mut u8, slot: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("insert_meta", start, end,
        &format!(r#""table":{},"slot":{}"#, tid, slot));
}

pub fn emit_insert_update<K, V>(key: &K, value: &V, table_ptr: *mut u8, slot: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("insert_update", start, end,
        &format!(r#""key":{},"value":{},"table":{},"slot":{}"#,
            raw_to_i64(key), raw_to_i64(value), tid, slot));
}

pub fn emit_remove<K>(key: &K, table_ptr: *mut u8, slot: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("remove", start, end,
        &format!(r#""key":{},"table":{},"slot":{}"#, raw_to_i64(key), tid, slot));
}

pub fn emit_copy_mark_copying(table_ptr: *mut u8, slot: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("copy_mark_copying", start, end,
        &format!(r#""table":{},"slot":{}"#, tid, slot));
}

pub fn emit_copy_insert(src_table_ptr: *mut u8, src_slot: usize, dst_table_ptr: *mut u8, dst_slot: usize, start: u64, end: u64) {
    let src_tid = table_id(src_table_ptr);
    let dst_tid = table_id(dst_table_ptr);
    emit("copy_insert", start, end,
        &format!(r#""src_table":{},"src_slot":{},"dst_table":{},"dst_slot":{}"#,
            src_tid, src_slot, dst_tid, dst_slot));
}

pub fn emit_copy_mark_copied(table_ptr: *mut u8, slot: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("copy_mark_copied", start, end,
        &format!(r#""table":{},"slot":{}"#, tid, slot));
}

pub fn emit_alloc_next(table_ptr: *mut u8, next_table_ptr: *mut u8, capacity: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    let next_tid = table_id(next_table_ptr);
    emit("alloc_next", start, end,
        &format!(r#""table":{},"next_table":{},"capacity":{}"#, tid, next_tid, capacity));
}

pub fn emit_try_promote(old_root_ptr: *mut u8, new_root_ptr: *mut u8, copied_count: usize, start: u64, end: u64) {
    let old_id = table_id(old_root_ptr);
    let new_id = table_id(new_root_ptr);
    emit("try_promote", start, end,
        &format!(r#""old_root":{},"new_root":{},"copied_count":{}"#, old_id, new_id, copied_count));
}

pub fn emit_abort_resize(src_table_ptr: *mut u8, aborted_table_ptr: *mut u8, start: u64, end: u64) {
    let src_id = table_id(src_table_ptr);
    let aborted_id = table_id(aborted_table_ptr);
    emit("abort_resize", start, end,
        &format!(r#""src_table":{},"aborted_table":{}"#, src_id, aborted_id));
}

pub fn emit_init_table(table_ptr: *mut u8, capacity: usize, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("init_table", start, end,
        &format!(r#""table":{},"capacity":{}"#, tid, capacity));
}

pub fn emit_park(table_ptr: *mut u8, start: u64, end: u64) {
    let tid = table_id(table_ptr);
    emit("park", start, end, &format!(r#""table":{}"#, tid));
}

// ===== Shutdown =====

pub fn flush() {
    WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writer.flush().ok();
        }
    });
}
