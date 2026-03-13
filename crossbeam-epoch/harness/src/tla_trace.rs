//! TLA+ trace emission for crossbeam-epoch.
//!
//! Activated by setting the `CROSSBEAM_TRACE_FILE` environment variable.
//! When active, instrumentation points in `internal.rs` emit NDJSON events
//! that can be validated against the TLA+ trace spec (`spec/Trace.tla`).

use alloc::format;
use alloc::string::String;

use core::cell::Cell;

use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use crate::epoch::Epoch;
use crate::primitive::thread_local;

// ---------------------------------------------------------------------------
// Thread-local suppress flag — used during finalize() to suppress intermediate
// pin/push/unpin events that are modeled as a single atomic Finalize action.
// ---------------------------------------------------------------------------

thread_local! {
    static SUPPRESS: Cell<bool> = const { Cell::new(false) };
}

// ---------------------------------------------------------------------------
// Global writer (lazily initialized from env var)
// ---------------------------------------------------------------------------

struct TraceWriter {
    file: File,
    thread_map: HashMap<std::thread::ThreadId, String>,
    thread_counter: usize,
}

static WRITER: OnceLock<Option<Mutex<TraceWriter>>> = OnceLock::new();

fn writer() -> &'static Option<Mutex<TraceWriter>> {
    WRITER.get_or_init(|| {
        std::env::var("CROSSBEAM_TRACE_FILE").ok().and_then(|path| {
            File::create(&path).ok().map(|file| {
                Mutex::new(TraceWriter {
                    file,
                    thread_map: HashMap::new(),
                    thread_counter: 0,
                })
            })
        })
    })
}

// ---------------------------------------------------------------------------
// Public API for instrumentation points
// ---------------------------------------------------------------------------

/// Returns `true` if tracing is active and not suppressed on this thread.
pub(crate) fn is_active() -> bool {
    writer().is_some() && SUPPRESS.try_with(|s| !s.get()).unwrap_or(false)
}

/// Set/clear the suppress flag for the current thread.
pub(crate) fn suppress(val: bool) {
    let _ = SUPPRESS.try_with(|s| s.set(val));
}

/// Convert implementation `Epoch` to TLA+ spec integer.
///
/// The implementation stores epochs as even numbers (LSB = pinned flag),
/// so `data >> 1` gives the abstract epoch number: 0, 1, 2, 3, ...
pub(crate) fn epoch_to_spec(epoch: Epoch) -> i64 {
    epoch.wrapping_sub(Epoch::starting()) as i64
}

/// Emit a full epoch state event (most pin/unpin/advance events).
pub(crate) fn emit_epoch_event(
    event: &str,
    global_epoch: Epoch,
    local_epoch: Epoch,
    pinned: bool,
    guard_count: usize,
) {
    if let Some(mutex) = writer() {
        if let Ok(mut w) = mutex.lock() {
            let t = get_tid(&mut w);
            let ge = epoch_to_spec(global_epoch);
            let le = epoch_to_spec(local_epoch);
            let _ = writeln!(
                w.file,
                r#"{{"event":"{}","thread":"{}","ts":{},"globalEpoch":{},"localEpoch":{},"pinned":{},"guardCount":{}}}"#,
                event, t, ts_nanos(), ge, le, pinned, guard_count
            );
            let _ = w.file.flush();
        }
    }
}

/// Emit a weak state event (only pinned + globalEpoch).
pub(crate) fn emit_weak_event(event: &str, global_epoch: Epoch, pinned: bool) {
    if let Some(mutex) = writer() {
        if let Ok(mut w) = mutex.lock() {
            let t = get_tid(&mut w);
            let ge = epoch_to_spec(global_epoch);
            let _ = writeln!(
                w.file,
                r#"{{"event":"{}","thread":"{}","ts":{},"globalEpoch":{},"pinned":{}}}"#,
                event, t, ts_nanos(), ge, pinned
            );
            let _ = w.file.flush();
        }
    }
}

/// Emit a lifecycle event (ReleaseHandle).
pub(crate) fn emit_lifecycle_event(
    event: &str,
    handle_count: usize,
    guard_count: usize,
) {
    if let Some(mutex) = writer() {
        if let Ok(mut w) = mutex.lock() {
            let t = get_tid(&mut w);
            let _ = writeln!(
                w.file,
                r#"{{"event":"{}","thread":"{}","ts":{},"handleCount":{},"guardCount":{}}}"#,
                event, t, ts_nanos(), handle_count, guard_count
            );
            let _ = w.file.flush();
        }
    }
}

/// Emit a Finalize event.
pub(crate) fn emit_finalize_event(global_epoch: Epoch) {
    if let Some(mutex) = writer() {
        if let Ok(mut w) = mutex.lock() {
            let t = get_tid(&mut w);
            let ge = epoch_to_spec(global_epoch);
            let _ = writeln!(
                w.file,
                r#"{{"event":"Finalize","thread":"{}","ts":{},"globalEpoch":{}}}"#,
                t, ts_nanos(), ge
            );
            let _ = w.file.flush();
        }
    }
}

/// Emit a garbage collection event (PushLocalBag, CollectExpiredBag).
pub(crate) fn emit_bag_event(event: &str, global_epoch: Epoch, bag_epoch: Option<Epoch>) {
    if let Some(mutex) = writer() {
        if let Ok(mut w) = mutex.lock() {
            let t = get_tid(&mut w);
            let ge = epoch_to_spec(global_epoch);
            let ts = ts_nanos();
            match bag_epoch {
                Some(be) => {
                    let _ = writeln!(
                        w.file,
                        r#"{{"event":"{}","thread":"{}","ts":{},"globalEpoch":{},"pinned":true,"bagEpoch":{}}}"#,
                        event, t, ts, ge, epoch_to_spec(be)
                    );
                }
                None => {
                    let _ = writeln!(
                        w.file,
                        r#"{{"event":"{}","thread":"{}","ts":{},"globalEpoch":{},"pinned":true}}"#,
                        event, t, ts, ge
                    );
                }
            }
            let _ = w.file.flush();
        }
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn ts_nanos() -> u128 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn get_tid(w: &mut TraceWriter) -> String {
    let id = std::thread::current().id();
    w.thread_map
        .entry(id)
        .or_insert_with(|| {
            w.thread_counter += 1;
            format!("T{}", w.thread_counter)
        })
        .clone()
}
