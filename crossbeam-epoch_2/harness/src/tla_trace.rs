// TLA+ trace emission module for crossbeam-epoch.
//
// Category B (lock-free) timebox tracing: per-thread NDJSON shards, rdtsc
// timestamps, no shared mutex on the hot path. A separate Python preprocessor
// merges shards into a single JSON object suitable for ViablePIDs.
//
// Each emit point captures (start, end) intervals around the critical
// operation. State for spec validation is captured *after* `end` so the
// interval stays tight.
//
// This module is compiled only when the std feature is enabled (the default).
// All call sites in the rest of the crate are gated with `#[cfg(feature =
// "std")]` so the stock no_std build is unaffected.

#![allow(dead_code, missing_docs, unused_imports)]

extern crate std;

use std::cell::{Cell, RefCell};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::string::{String, ToString};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread_local;

/// Tracks Len(sealedBags) — incremented in push_bag, decremented when collect
/// pops a bag. Provides the `sealedBagsLenAfter` field for PushBag events.
pub static SEALED_BAGS_LEN: AtomicUsize = AtomicUsize::new(0);

thread_local! {
    static TRACE_WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static THREAD_ID: RefCell<String> = const { RefCell::new(String::new()) };
    /// Object ID the user is about to defer; consumed by `emit_defer`.
    static CURRENT_DEFER_OBJ: Cell<u64> = const { Cell::new(0) };
    /// Object ID the deferred fn currently being run is destroying;
    /// consumed by `emit_bag_drop`.
    static CURRENT_BAG_DROP_OBJ: Cell<u64> = const { Cell::new(0) };
    /// While true, suppress emission. Used inside `Bag::drop`'s deferred body
    /// invocation so reentrant pin()/unpin() do not produce events; the spec
    /// models reentrant pin via silent InDeferCallbackPin steps instead.
    static SUPPRESS: Cell<bool> = const { Cell::new(false) };
}

#[inline(always)]
pub fn rdtsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        use core::arch::x86_64::{_mm_mfence, _rdtsc};
        _mm_mfence();
        let r = _rdtsc();
        _mm_mfence();
        r
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        // Portable fallback: nanosecond monotonic clock.
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0)
    }
}

pub fn init_thread(tid: &str, dir: &str) {
    let mut path = PathBuf::from(dir);
    let _ = std::fs::create_dir_all(&path);
    path.push(std::format!("trace-{}.ndjson", tid));
    let f = File::create(&path).expect("failed to create trace file");
    TRACE_WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::with_capacity(64 * 1024, f)));
    THREAD_ID.with(|t| *t.borrow_mut() = tid.to_string());
}

pub fn shutdown_thread() {
    TRACE_WRITER.with(|w| {
        if let Some(mut writer) = w.borrow_mut().take() {
            let _ = writer.flush();
        }
    });
}

pub fn set_defer_obj(obj: u64) {
    CURRENT_DEFER_OBJ.with(|o| o.set(obj));
}

pub fn take_defer_obj() -> u64 {
    CURRENT_DEFER_OBJ.with(|o| {
        let v = o.get();
        o.set(0);
        v
    })
}

pub fn set_bag_drop_obj(obj: u64) {
    CURRENT_BAG_DROP_OBJ.with(|o| o.set(obj));
}

pub fn take_bag_drop_obj() -> u64 {
    CURRENT_BAG_DROP_OBJ.with(|o| {
        let v = o.get();
        o.set(0);
        v
    })
}

pub fn enter_suppress() -> bool {
    SUPPRESS.with(|s| {
        let prev = s.get();
        s.set(true);
        prev
    })
}

pub fn leave_suppress(prev: bool) {
    SUPPRESS.with(|s| s.set(prev));
}

fn emit(line: &str) {
    if SUPPRESS.with(|s| s.get()) {
        return;
    }
    TRACE_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writer.write_all(line.as_bytes());
            let _ = writer.write_all(b"\n");
        }
    });
}

fn thread_id_string() -> String {
    THREAD_ID.with(|t| t.borrow().clone())
}

fn thread_active() -> bool {
    THREAD_ID.with(|t| !t.borrow().is_empty())
}

/// Convert raw Epoch::data → spec-side localEpoch value.
/// Pinned bit set → unpinned epoch index; pinned bit clear → UNPINNED (-1).
pub fn local_epoch_spec_value(data: u64) -> i64 {
    if (data & 1) == 1 {
        (data >> 1) as i64
    } else {
        -1
    }
}

/// Convert raw Epoch::data → spec-side globalEpoch value (always unpinned).
pub fn global_epoch_spec_value(data: u64) -> i64 {
    (data >> 1) as i64
}

// Map a small numeric obj ID (1..=N) to a TLA+ Object name "o1", "o2", ...
fn obj_id_to_label(obj: u64) -> String {
    let n = if obj == 0 { 1 } else { obj };
    std::format!("o{}", n)
}

// ---- Event emitters ----

pub fn emit_pin_inc_guard_count(start: u64, end: u64, guard_count_after: usize) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"PinIncGuardCount\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"guardCountAfter\":{}}}",
        thread_id_string(),
        start,
        end,
        guard_count_after
    );
    emit(&line);
}

pub fn emit_pin_load_global(start: u64, end: u64, captured_global: i64) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"PinLoadGlobal\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"capturedGlobal\":{}}}",
        thread_id_string(),
        start,
        end,
        captured_global
    );
    emit(&line);
}

pub fn emit_pin_publish(start: u64, end: u64, local_epoch_after: i64) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"PinPublish\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"localEpochAfter\":{}}}",
        thread_id_string(),
        start,
        end,
        local_epoch_after
    );
    emit(&line);
}

pub fn emit_pin_maybe_collect(
    start: u64,
    end: u64,
    pin_count_after: usize,
    triggered_collect: bool,
) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"PinMaybeCollect\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"pinCountAfter\":{},\"triggeredCollect\":{}}}",
        thread_id_string(),
        start,
        end,
        pin_count_after,
        triggered_collect
    );
    emit(&line);
}

pub fn emit_unpin_dec(start: u64, end: u64, guard_count_after: usize) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"UnpinDec\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"guardCountAfter\":{}}}",
        thread_id_string(),
        start,
        end,
        guard_count_after
    );
    emit(&line);
}

pub fn emit_unpin_publish(start: u64, end: u64) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"UnpinPublish\",\"thread\":\"{}\",\"start\":{},\"end\":{}}}",
        thread_id_string(),
        start,
        end
    );
    emit(&line);
}

pub fn emit_repin(start: u64, end: u64, local_epoch_after: i64, was_no_op: bool) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"Repin\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"localEpochAfter\":{},\"wasNoOp\":{}}}",
        thread_id_string(),
        start,
        end,
        local_epoch_after,
        was_no_op
    );
    emit(&line);
}

pub fn emit_try_adv_load_global(start: u64, end: u64, captured_global: i64) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"TryAdvLoadGlobal\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"capturedGlobal\":{}}}",
        thread_id_string(),
        start,
        end,
        captured_global
    );
    emit(&line);
}

pub fn emit_try_adv_iter(
    start: u64,
    end: u64,
    observed_thread: &str,
    observed_epoch: i64,
    pinned: bool,
    aborted: &str,
) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"TryAdvIter\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"observedThread\":\"{}\",\"observedEpoch\":{},\"pinned\":{},\"aborted\":\"{}\"}}",
        thread_id_string(),
        start,
        end,
        observed_thread,
        observed_epoch,
        pinned,
        aborted
    );
    emit(&line);
}

pub fn emit_try_adv_finish_store(start: u64, end: u64, global_epoch_after: i64) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"TryAdvFinishStore\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"globalEpochAfter\":{}}}",
        thread_id_string(),
        start,
        end,
        global_epoch_after
    );
    emit(&line);
}

pub fn emit_defer(start: u64, end: u64, obj: u64, bag_len_after: usize) {
    if !thread_active() {
        return;
    }
    let obj_label = obj_id_to_label(obj);
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"Defer\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"obj\":\"{}\",\"bagLenAfter\":{}}}",
        thread_id_string(),
        start,
        end,
        obj_label,
        bag_len_after
    );
    emit(&line);
}

pub fn emit_push_bag(start: u64, end: u64, seal_epoch: i64, sealed_bags_len_after: usize) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"PushBag\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"sealEpoch\":{},\"sealedBagsLenAfter\":{}}}",
        thread_id_string(),
        start,
        end,
        seal_epoch,
        sealed_bags_len_after
    );
    emit(&line);
}

pub fn emit_flush(start: u64, end: u64) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"Flush\",\"thread\":\"{}\",\"start\":{},\"end\":{}}}",
        thread_id_string(),
        start,
        end
    );
    emit(&line);
}

pub fn emit_collect_scan(start: u64, end: u64, popped: bool) {
    if !thread_active() {
        return;
    }
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"CollectScan\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"popped\":{}}}",
        thread_id_string(),
        start,
        end,
        popped
    );
    emit(&line);
}

pub fn emit_bag_drop(start: u64, end: u64, idx: usize, obj: u64) {
    if !thread_active() {
        return;
    }
    let obj_label = obj_id_to_label(obj);
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"BagDrop\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"idx\":{},\"obj\":\"{}\"}}",
        thread_id_string(),
        start,
        end,
        idx,
        obj_label
    );
    emit(&line);
}

pub fn emit_publish_object(start: u64, end: u64, obj: u64) {
    if !thread_active() {
        return;
    }
    let obj_label = obj_id_to_label(obj);
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"PublishObject\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"obj\":\"{}\"}}",
        thread_id_string(),
        start,
        end,
        obj_label
    );
    emit(&line);
}

pub fn emit_unlink_object(start: u64, end: u64, obj: u64) {
    if !thread_active() {
        return;
    }
    let obj_label = obj_id_to_label(obj);
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"UnlinkObject\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"obj\":\"{}\"}}",
        thread_id_string(),
        start,
        end,
        obj_label
    );
    emit(&line);
}

pub fn emit_read_and_deref(start: u64, end: u64, obj: u64) {
    if !thread_active() {
        return;
    }
    let obj_label = obj_id_to_label(obj);
    let line = std::format!(
        "{{\"tag\":\"trace\",\"event\":\"ReadAndDeref\",\"thread\":\"{}\",\"start\":{},\"end\":{},\"obj\":\"{}\"}}",
        thread_id_string(),
        start,
        end,
        obj_label
    );
    emit(&line);
}
