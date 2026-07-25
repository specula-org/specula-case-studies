//! TLA+ Trace emission for arc-swap debt-based reader tracking.
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by setting the `ARCSWAP_TRACE_FILE` environment variable.
//!
//! Thread safety: Uses OnceLock<Mutex<TraceState>>. All emit calls
//! are serialized through the mutex.

use std::collections::HashMap;
use std::io::Write;
use std::sync::{Mutex, OnceLock};

static WRITER: OnceLock<Mutex<TraceState>> = OnceLock::new();

struct TraceState {
    file: std::io::BufWriter<std::fs::File>,
    thread_map: HashMap<std::thread::ThreadId, String>,
    thread_counter: usize,
    ptr_map: HashMap<usize, String>,
    ptr_counter: usize,
}

/// Try to initialize tracing from `ARCSWAP_TRACE_FILE` env var.
/// Call once at startup. No-op if not set or already initialized.
pub(crate) fn try_init() {
    if WRITER.get().is_some() {
        return;
    }
    if let Ok(path) = std::env::var("ARCSWAP_TRACE_FILE") {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("tla_trace: failed to open {}: {}", path, e));
        let _ = WRITER.set(Mutex::new(TraceState {
            file: std::io::BufWriter::new(file),
            thread_map: HashMap::new(),
            thread_counter: 0,
            ptr_map: HashMap::new(),
            ptr_counter: 0,
        }));
        eprintln!("[tla_trace] Tracing to: {}", path);
    }
}

/// Returns true if tracing is active. Auto-initializes on first call.
#[inline]
pub(crate) fn is_active() -> bool {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(try_init);
    WRITER.get().is_some()
}

// Thread-local flag: only emit writer events during an active swap() call.
// Suppresses events from ArcSwapAny::drop() and compare_and_swap().
std::thread_local! {
    static IN_SWAP: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

pub(crate) fn set_in_swap(v: bool) {
    IN_SWAP.with(|f| f.set(v));
}

fn is_in_swap() -> bool {
    IN_SWAP.with(|f| f.get())
}

/// Map a thread ID to "T1", "T2", etc.
fn get_tid(state: &mut TraceState) -> String {
    let id = std::thread::current().id();
    if let Some(name) = state.thread_map.get(&id) {
        return name.clone();
    }
    state.thread_counter += 1;
    let name = format!("T{}", state.thread_counter);
    state.thread_map.insert(id, name.clone());
    name
}

/// Map a pointer address to "P1", "P2", etc. "null" for NONE (0b11).
fn map_ptr(state: &mut TraceState, addr: usize) -> String {
    use super::debt::Debt;
    if addr == Debt::NONE {
        return "null".to_string();
    }
    if let Some(name) = state.ptr_map.get(&addr) {
        return name.clone();
    }
    state.ptr_counter += 1;
    let name = format!("P{}", state.ptr_counter);
    state.ptr_map.insert(addr, name.clone());
    name
}

/// Emit a raw JSON line to the trace file.
fn emit_raw(state: &mut TraceState, json: &str) {
    let _ = writeln!(state.file, "{}", json);
    let _ = state.file.flush();
}

// ============================================================================
// Reader events
// ============================================================================

/// ReaderAcquireFast: after fast slot acquired
pub(crate) fn emit_reader_acquire_fast(ptr_addr: usize, storage_addr: usize, slot: usize) {
    if is_in_swap() { return; } // suppress during wait_for_readers
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, ptr_addr);
            let storage = map_ptr(&mut s, storage_addr);
            let json = format!(
                r#"{{"event":"ReaderAcquireFast","thread":"{}","ptr":"{}","slot":{},"state":{{"rPC":"r_fast_confirm","storagePtr":"{}","rHasDebt":true,"rPath":"fast"}}}}"#,
                tid, ptr, slot, storage
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// ReaderConfirmFast: after confirm check
pub(crate) fn emit_reader_confirm_fast(ptr_addr: usize, matched: bool, has_debt: bool) {
    if is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, ptr_addr);
            let rpc = if matched { "r_holding" } else { "r_fast_resolve" };
            let json = format!(
                r#"{{"event":"ReaderConfirmFast","thread":"{}","ptr":"{}","state":{{"rPC":"{}","rHasDebt":{},"rPtr":"{}"}}}}"#,
                tid, ptr, rpc, has_debt, ptr
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// ReaderResolveFast: after resolve (pay attempt)
pub(crate) fn emit_reader_resolve_fast(ptr_addr: usize, pay_succeeded: bool) {
    if is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, ptr_addr);
            let (rpc, has_debt) = if pay_succeeded {
                ("r_idle", false)
            } else {
                ("r_holding", false)
            };
            let json = format!(
                r#"{{"event":"ReaderResolveFast","thread":"{}","ptr":"{}","state":{{"rPC":"{}","rHasDebt":{}}}}}"#,
                tid, ptr, rpc, has_debt
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// ReaderFallbackLoad: after fallback path completes
pub(crate) fn emit_reader_fallback_load(ptr_addr: usize, has_debt: bool) {
    if is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, ptr_addr);
            let json = format!(
                r#"{{"event":"ReaderFallbackLoad","thread":"{}","ptr":"{}","state":{{"rPC":"r_holding","rHasDebt":{},"rPath":"fallback"}}}}"#,
                tid, ptr, has_debt
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// ReaderDropGuard: at guard drop
pub(crate) fn emit_reader_drop_guard(ptr_addr: usize, had_debt: bool) {
    if is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, ptr_addr);
            let json = format!(
                r#"{{"event":"ReaderDropGuard","thread":"{}","ptr":"{}","state":{{"rPC":"r_idle","rHasDebt":{}}}}}"#,
                tid, ptr, had_debt
            );
            emit_raw(&mut s, &json);
        }
    }
}

// ============================================================================
// Writer events
// ============================================================================

/// WriterSwap: after ptr.swap(new, SeqCst)
pub(crate) fn emit_writer_swap(new_ptr_addr: usize, old_ptr_addr: usize) {
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            // Register old pointer first (it's the initial/previous value → P1)
            let old_ptr = map_ptr(&mut s, old_ptr_addr);
            let new_ptr = map_ptr(&mut s, new_ptr_addr);
            let json = format!(
                r#"{{"event":"WriterSwap","thread":"{}","ptr":"{}","state":{{"storagePtr":"{}","wPC":"w_pay_init","wOldPtr":"{}"}}}}"#,
                tid, old_ptr, new_ptr, old_ptr
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// WriterPayInit: after T::inc(&val)
pub(crate) fn emit_writer_pay_init(ptr_addr: usize) {
    if !is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, ptr_addr);
            let json = format!(
                r#"{{"event":"WriterPayInit","thread":"{}","ptr":"{}","state":{{"wPC":"w_scanning"}}}}"#,
                tid, ptr
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// WriterScanSlot: per slot scanned in pay_all
pub(crate) fn emit_writer_scan_slot(
    target_thread_ptr: usize,
    slot_idx: usize,
    slot_value: usize,
    paid: bool,
) {
    if !is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let slot_val = map_ptr(&mut s, slot_value);
            let json = format!(
                r#"{{"event":"WriterScanSlot","thread":"{}","target_node":"0x{:x}","slot":{},"slotValue":"{}","paid":{},"state":{{"wPC":"w_scanning"}}}}"#,
                tid, target_thread_ptr, slot_idx, slot_val, paid
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// WriterPayDone: after traverse completes
pub(crate) fn emit_writer_pay_done() {
    if !is_in_swap() { return; }
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let json = format!(
                r#"{{"event":"WriterPayDone","thread":"{}","state":{{"wPC":"w_returning"}}}}"#,
                tid
            );
            emit_raw(&mut s, &json);
        }
    }
}

/// WriterReturn: after from_ptr(old)
pub(crate) fn emit_writer_return(old_ptr_addr: usize) {
    if let Some(w) = WRITER.get() {
        if let Ok(mut s) = w.lock() {
            let tid = get_tid(&mut s);
            let ptr = map_ptr(&mut s, old_ptr_addr);
            let json = format!(
                r#"{{"event":"WriterReturn","thread":"{}","ptr":"{}","state":{{"wPC":"w_idle"}}}}"#,
                tid, ptr
            );
            emit_raw(&mut s, &json);
        }
    }
}
