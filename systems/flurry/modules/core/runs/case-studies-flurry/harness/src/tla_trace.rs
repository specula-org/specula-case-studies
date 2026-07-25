//! TLA+ Trace Emission Module for flurry ConcurrentHashMap
//!
//! Category B (concurrent/lock-free): per-thread NDJSON files with rdtsc
//! [start, end] intervals. No mutex on the hot path.
//!
//! Activation: set FLURRY_TRACE_DIR to a directory path.
//! Each thread writes to `<dir>/trace-thread-<N>.ndjson`.

use std::cell::RefCell;
use std::env;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::OnceLock;

// ── Global State ──────────────────────────────────────────────────────

static ACTIVE: AtomicBool = AtomicBool::new(false);
static TRACE_DIR: OnceLock<String> = OnceLock::new();
static THREAD_COUNTER: AtomicUsize = AtomicUsize::new(0);

// ── Per-Thread State ──────────────────────────────────────────────────

thread_local! {
    static TL_WRITER: RefCell<Option<BufWriter<File>>> = RefCell::new(None);
    static TL_TID: RefCell<usize> = RefCell::new(usize::MAX);
    static TL_CURRENT_BIN: RefCell<usize> = RefCell::new(0);
}

pub fn set_current_bin(bin: usize) {
    TL_CURRENT_BIN.with(|b| *b.borrow_mut() = bin);
}

pub fn get_current_bin() -> usize {
    TL_CURRENT_BIN.with(|b| *b.borrow())
}

// ── rdtsc ─────────────────────────────────────────────────────────────

#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub fn trace_rdtsc() -> u64 {
    let lo: u32;
    let hi: u32;
    unsafe {
        core::arch::x86_64::_mm_mfence();
        core::arch::asm!("rdtsc", out("eax") lo, out("edx") hi);
    }
    ((hi as u64) << 32) | lo as u64
}

#[cfg(not(target_arch = "x86_64"))]
#[inline(always)]
pub fn trace_rdtsc() -> u64 {
    use std::time::Instant;
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    let epoch = EPOCH.get_or_init(Instant::now);
    epoch.elapsed().as_nanos() as u64
}

// ── Init / Query ──────────────────────────────────────────────────────

pub fn try_init() {
    if let Ok(dir) = env::var("FLURRY_TRACE_DIR") {
        fs::create_dir_all(&dir).expect("cannot create trace dir");
        TRACE_DIR.get_or_init(|| dir);
        ACTIVE.store(true, Ordering::SeqCst);
    }
}

#[inline(always)]
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

fn ensure_thread_writer() {
    TL_WRITER.with(|w| {
        if w.borrow().is_none() {
            let tid = THREAD_COUNTER.fetch_add(1, Ordering::SeqCst);
            TL_TID.with(|t| *t.borrow_mut() = tid);
            if let Some(dir) = TRACE_DIR.get() {
                let path = format!("{}/trace-thread-{}.ndjson", dir, tid);
                let file = File::create(&path).expect("cannot create thread trace file");
                *w.borrow_mut() = Some(BufWriter::new(file));
            }
        }
    });
}

fn get_tid() -> usize {
    TL_TID.with(|t| {
        let v = *t.borrow();
        if v == usize::MAX {
            ensure_thread_writer();
            *t.borrow()
        } else {
            v
        }
    })
}

pub fn flush_thread() {
    TL_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writer.flush().ok();
        }
    });
}

fn emit_line(line: &str) {
    ensure_thread_writer();
    TL_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            writeln!(writer, "{}", line).ok();
        }
    });
}

// ── Emit Helpers ──────────────────────────────────────────────────────

fn fmt_state_count(count: isize) -> String {
    format!("\"state\":{{\"count\":{}}}", count)
}

fn fmt_state_sizectl_tablesize_count(size_ctl: isize, table_size: usize, count: isize) -> String {
    format!(
        "\"state\":{{\"sizeCtl\":{},\"tableSize\":{},\"count\":{}}}",
        size_ctl, table_size, count
    )
}

fn fmt_state_sizectl(size_ctl: isize) -> String {
    format!("\"state\":{{\"sizeCtl\":{}}}", size_ctl)
}

fn fmt_state_transfer_index(ti: isize) -> String {
    format!("\"state\":{{\"transferIndex\":{}}}", ti)
}

fn fmt_state_sizectl_tablesize(size_ctl: isize, table_size: usize) -> String {
    format!(
        "\"state\":{{\"sizeCtl\":{},\"tableSize\":{}}}",
        size_ctl, table_size
    )
}

fn fmt_state_lockstate(ls: i64) -> String {
    format!("\"state\":{{\"lockState\":{}}}", ls)
}

// ── Put Events ────────────────────────────────────────────────────────

pub fn emit_put_empty_bin(start: u64, end: u64, key: u64, bin: usize, _count: isize) {
    let tid = get_tid();
    // NOTE: count omitted — inherently racy for concurrent puts (Category B)
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"put_empty_bin\",\"tid\":{},\"start\":{},\"end\":{},\"key\":{},\"bin\":{}}}",
        tid, start, end, key, bin
    );
    emit_line(&line);
}

pub fn emit_put_node_bin(start: u64, end: u64, key: u64, bin: usize, _count: isize) {
    let tid = get_tid();
    // NOTE: count omitted — inherently racy for concurrent puts (Category B)
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"put_node_bin\",\"tid\":{},\"start\":{},\"end\":{},\"key\":{},\"bin\":{}}}",
        tid, start, end, key, bin
    );
    emit_line(&line);
}

pub fn emit_put_tree_bin(start: u64, end: u64, key: u64, bin: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"put_tree_bin\",\"tid\":{},\"start\":{},\"end\":{},\"key\":{},\"bin\":{}}}",
        tid, start, end, key, bin
    );
    emit_line(&line);
}

pub fn emit_put_help_transfer(start: u64, end: u64, key: u64, bin: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"put_help_transfer\",\"tid\":{},\"start\":{},\"end\":{},\"key\":{},\"bin\":{}}}",
        tid, start, end, key, bin
    );
    emit_line(&line);
}

// ── Treeify Events ────────────────────────────────────────────────────

pub fn emit_treeify_bin(start: u64, end: u64, bin: usize, result: &str) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"treeify_bin\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{},\"result\":\"{}\"}}",
        tid, start, end, bin, result
    );
    emit_line(&line);
}

// ── Resize Events ─────────────────────────────────────────────────────

pub fn emit_init_resize(start: u64, end: u64, size_ctl: isize, table_size: usize, count: isize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"init_resize\",\"tid\":{},\"start\":{},\"end\":{},{}}}",
        tid, start, end, fmt_state_sizectl_tablesize_count(size_ctl, table_size, count)
    );
    emit_line(&line);
}

pub fn emit_claim_range(start: u64, end: u64, transfer_index: isize, bound: isize, i: isize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"claim_range\",\"tid\":{},\"start\":{},\"end\":{},{},\"bound\":{},\"i\":{}}}",
        tid, start, end, fmt_state_transfer_index(transfer_index), bound, i
    );
    emit_line(&line);
}

pub fn emit_claim_range_exhausted(start: u64, end: u64) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"claim_range_exhausted\",\"tid\":{},\"start\":{},\"end\":{}}}",
        tid, start, end
    );
    emit_line(&line);
}

pub fn emit_transfer_bin(start: u64, end: u64, bin: usize, bin_type: &str) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"transfer_bin\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{},\"bin_type\":\"{}\"}}",
        tid, start, end, bin, bin_type
    );
    emit_line(&line);
}

pub fn emit_transfer_finish_check(start: u64, end: u64, size_ctl: isize, finishing: bool) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"transfer_finish_check\",\"tid\":{},\"start\":{},\"end\":{},{},\"finishing\":{}}}",
        tid, start, end, fmt_state_sizectl(size_ctl), finishing
    );
    emit_line(&line);
}

pub fn emit_finishing_sweep(start: u64, end: u64, bin: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"finishing_sweep\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{}}}",
        tid, start, end, bin
    );
    emit_line(&line);
}

pub fn emit_complete_resize(start: u64, end: u64, size_ctl: isize, table_size: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"complete_resize\",\"tid\":{},\"start\":{},\"end\":{},{}}}",
        tid, start, end, fmt_state_sizectl_tablesize(size_ctl, table_size)
    );
    emit_line(&line);
}

pub fn emit_help_transfer(start: u64, end: u64, size_ctl: isize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"help_transfer\",\"tid\":{},\"start\":{},\"end\":{},{}}}",
        tid, start, end, fmt_state_sizectl(size_ctl)
    );
    emit_line(&line);
}

// ── Guard Events ──────────────────────────────────────────────────────

pub fn emit_enter_guard(start: u64, end: u64) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"enter_guard\",\"tid\":{},\"start\":{},\"end\":{}}}",
        tid, start, end
    );
    emit_line(&line);
}

pub fn emit_exit_guard(start: u64, end: u64) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"exit_guard\",\"tid\":{},\"start\":{},\"end\":{}}}",
        tid, start, end
    );
    emit_line(&line);
}

// ── TreeBin Lock Events ───────────────────────────────────────────────

pub fn emit_reader_acquire(start: u64, end: u64, bin: usize, lock_state: i64) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"reader_acquire\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{},{}}}",
        tid, start, end, bin, fmt_state_lockstate(lock_state)
    );
    emit_line(&line);
}

pub fn emit_reader_release(start: u64, end: u64, bin: usize, lock_state: i64, unparked: bool) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"reader_release\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{},{},\"unparked\":{}}}",
        tid, start, end, bin, fmt_state_lockstate(lock_state), unparked
    );
    emit_line(&line);
}

pub fn emit_writer_acquire_fast(start: u64, end: u64, bin: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"writer_acquire_fast\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{}}}",
        tid, start, end, bin
    );
    emit_line(&line);
}

pub fn emit_writer_set_waiter(start: u64, end: u64, bin: usize, lock_state: i64) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"writer_set_waiter\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{},{}}}",
        tid, start, end, bin, fmt_state_lockstate(lock_state)
    );
    emit_line(&line);
}

pub fn emit_writer_acquire_contended(start: u64, end: u64, bin: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"writer_acquire_contended\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{}}}",
        tid, start, end, bin
    );
    emit_line(&line);
}

pub fn emit_writer_release(start: u64, end: u64, bin: usize) {
    let tid = get_tid();
    let line = format!(
        "{{\"tag\":\"trace\",\"event\":\"writer_release\",\"tid\":{},\"start\":{},\"end\":{},\"bin\":{}}}",
        tid, start, end, bin
    );
    emit_line(&line);
}
