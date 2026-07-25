//! TLA+ trace emission for `scc`.
//!
//! Category B (concurrent / lock-free) timebox harness. Each worker thread
//! writes NDJSON events to its own file (no shared mutex on the hot path).
//! Each event records `[start, end]` rdtsc timestamps so TLC can search
//! the partial order of overlapping operations.
//!
//! Public API (called from instrumented code):
//!   * [`thread_init`] — opens this thread's NDJSON file
//!   * [`thread_shutdown`] — flushes/closes it
//!   * [`array_id`] / [`array_id_opt`] — interns a `*const BucketArray` to a u32
//!   * [`now`] — rdtsc snapshot
//!   * [`emit_*`] — convenience wrappers per spec event
//!
//! Compile-time gated by feature flag `tla-trace` to avoid any cost when off.

#![allow(dead_code)]
#![allow(clippy::missing_safety_doc)]

/// The spec uses BucketCount=2; we modulo real bucket indices by this so
/// emitted bucketIdx fields stay within the spec's domain. Tests should
/// also use `HashIndex::with_capacity(64)` to keep `array_len = 2`.
pub const SPEC_BUCKET_COUNT: u32 = 2;

#[cfg(feature = "tla-trace")]
mod imp {
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::fs::File;
    use std::io::{BufWriter, Write};
    use std::path::PathBuf;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU32, Ordering};

    thread_local! {
        static TID: RefCell<u32> = const { RefCell::new(0) };
        static WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
        // Per-thread cache of array_ptr -> id (avoids global mutex on hot path).
        static ARRAY_CACHE: RefCell<HashMap<usize, u32>> = RefCell::new(HashMap::new());
        // Caller-provided "current operation kv" — set by the test before
        // each insert_sync / remove_if_sync call so emit_* can record key/val.
        static OP_KV: RefCell<(String, String)> =
            RefCell::new((String::from("k0"), String::from("v0")));
        // Per-iterator state set by IterStart and updated by IterAdvance/Cross.
        static ITER_BUCKET_IDX: RefCell<u32> = const { RefCell::new(0) };
        static ITER_CACHED_ARRAY: RefCell<u32> = const { RefCell::new(0) };
    }

    static ARRAY_COUNTER: AtomicU32 = AtomicU32::new(1);
    // Slow-path global registry: only consulted on first observation per thread.
    static ARRAY_REGISTRY: Mutex<Option<HashMap<usize, u32>>> = Mutex::new(None);

    /// Read rdtsc with mfence for monotonic-ish per-core nanos.
    #[inline]
    pub fn now() -> u64 {
        #[cfg(target_arch = "x86_64")]
        unsafe {
            core::arch::x86_64::_mm_mfence();
            let lo: u32;
            let hi: u32;
            core::arch::asm!("rdtsc", out("eax") lo, out("edx") hi, options(nomem, nostack));
            core::arch::x86_64::_mm_mfence();
            ((hi as u64) << 32) | lo as u64
        }
        #[cfg(not(target_arch = "x86_64"))]
        {
            use std::time::Instant;
            // Fallback: monotonic nanos. Less precision but works.
            let t = Instant::now();
            (t.elapsed().as_nanos()) as u64
        }
    }

    /// Initialize the per-thread trace writer. `tid` becomes this thread's
    /// stable id (mapped to "t1", "t2", ... in the post-processed JSON).
    pub fn thread_init(tid: u32) {
        TID.with(|t| *t.borrow_mut() = tid);
        let dir = std::env::var("SCC_TRACE_DIR").unwrap_or_else(|_| "./traces-raw".into());
        let _ = std::fs::create_dir_all(&dir);
        let scenario = std::env::var("SCC_TRACE_SCENARIO").unwrap_or_else(|_| "default".into());
        let path: PathBuf = format!("{dir}/{scenario}.t{tid}.ndjson").into();
        let f = File::create(&path).expect("scc trace: cannot create per-thread file");
        WRITER.with(|w| *w.borrow_mut() = Some(BufWriter::with_capacity(64 * 1024, f)));
    }

    pub fn thread_shutdown() {
        WRITER.with(|w| {
            if let Some(mut bw) = w.borrow_mut().take() {
                let _ = bw.flush();
            }
        });
        ARRAY_CACHE.with(|c| c.borrow_mut().clear());
    }

    /// Caller sets the current op's key/val before invoking the instrumented
    /// public API. The instrumented insert_sync / remove_if_sync read these
    /// to fill the WriterStart / WriterCommitInsert / WriterCommitMarkRemoved
    /// `key` / `val` fields.
    pub fn set_op_kv(key: &str, val: &str) {
        OP_KV.with(|kv| {
            let mut g = kv.borrow_mut();
            g.0.clear();
            g.0.push_str(key);
            g.1.clear();
            g.1.push_str(val);
        });
    }

    pub fn current_kv() -> (String, String) {
        OP_KV.with(|kv| kv.borrow().clone())
    }

    pub fn set_iter_state(cached_array: u32, bucket_idx: u32) {
        ITER_CACHED_ARRAY.with(|c| *c.borrow_mut() = cached_array);
        ITER_BUCKET_IDX.with(|b| *b.borrow_mut() = bucket_idx);
    }

    pub fn iter_cached_array() -> u32 {
        ITER_CACHED_ARRAY.with(|c| *c.borrow())
    }

    pub fn iter_bucket_idx() -> u32 {
        ITER_BUCKET_IDX.with(|b| *b.borrow())
    }

    /// Intern a `*const BucketArray<...>` to a stable u32 id.
    /// We only need pointer identity, so we accept a raw `usize`.
    pub fn array_id(ptr: usize) -> u32 {
        if ptr == 0 {
            return 0;
        }
        ARRAY_CACHE.with(|cache| {
            if let Some(&id) = cache.borrow().get(&ptr) {
                return id;
            }
            // Slow path: register in the global map.
            let id = {
                let mut guard = ARRAY_REGISTRY.lock().unwrap();
                let map = guard.get_or_insert_with(HashMap::new);
                if let Some(&id) = map.get(&ptr) {
                    id
                } else {
                    let new_id = ARRAY_COUNTER.fetch_add(1, Ordering::Relaxed);
                    map.insert(ptr, new_id);
                    new_id
                }
            };
            cache.borrow_mut().insert(ptr, id);
            id
        })
    }

    pub fn array_id_opt(ptr_opt: Option<usize>) -> u32 {
        ptr_opt.map_or(0, array_id)
    }

    /// Emit a single NDJSON line to this thread's file. No mutex.
    fn emit_line(line: &str) {
        WRITER.with(|w| {
            if let Some(ref mut bw) = *w.borrow_mut() {
                // writeln! formats with \n; ignore IO errors silently.
                let _ = writeln!(bw, "{line}");
            }
        });
    }

    fn tid() -> u32 {
        TID.with(|t| *t.borrow())
    }

    // ----- Field-encoding helpers -------------------------------------------

    fn quote_str(s: &str) -> String {
        // Minimal JSON-string escape: only quote and backslash. The keys/vals
        // we emit are alphanumeric; nothing tricky needed.
        let mut out = String::with_capacity(s.len() + 2);
        out.push('"');
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                _ => out.push(c),
            }
        }
        out.push('"');
        out
    }

    // ----- Per-event emitters ------------------------------------------------
    //
    // Each function captures: t_start (caller passes in), t_end (we sample
    // here), then the spec-mandated state fields. Caller is expected to call
    // `now()` immediately before the linearization point and hand the value
    // in as `start`.

    /// Compose the common envelope plus arbitrary suffix fields. Suffix must
    /// already be valid JSON object members WITHOUT trailing comma, e.g.
    /// `,"key":"k1","val":"v1"`.
    fn emit_envelope(event: &'static str, start: u64, end: u64, fields: &str) {
        let line = format!(
            "{{\"tag\":\"trace\",\"event\":\"{event}\",\"tid\":{},\"start\":{start},\"end\":{end}{fields}}}",
            tid()
        );
        emit_line(&line);
    }

    pub fn emit_writer_start(start: u64, cached_array: u32, key: &str, val: &str) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"writer\",\"step\":\"loaded_array\",\"cachedArray\":{cached_array}}},\
             \"key\":{},\"val\":{}",
            quote_str(key), quote_str(val)
        );
        emit_envelope("WriterStart", start, end, &f);
    }

    pub fn emit_writer_maybe_rehash_ok(start: u64, cached_array: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"writer\",\"step\":\"post_rehash\",\"cachedArray\":{cached_array}}}"
        );
        emit_envelope("WriterMaybeRehashOK", start, end, &f);
    }

    pub fn emit_writer_maybe_rehash_retry(start: u64, cached_array: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"writer\",\"step\":\"loaded_array\",\"cachedArray\":{cached_array}}}"
        );
        emit_envelope("WriterMaybeRehashRetry", start, end, &f);
    }

    pub fn emit_writer_acquire_lock(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"writer\",\"step\":\"locked\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("WriterAcquireLock", start, end, &f);
    }

    pub fn emit_writer_commit_insert(
        start: u64,
        cached_array: u32,
        bucket_idx: u32,
        key: &str,
        val: &str,
    ) {
        let end = now();
        // Post-state for an insert: occBit=true, remBit=false on this slot.
        let f = format!(
            ",\"state\":{{\"kind\":\"writer\",\"step\":\"committed\",\"cachedArray\":{cached_array},\
                \"occBit\":true,\"remBit\":false}},\
             \"bucketIdx\":{bucket_idx},\"key\":{},\"val\":{}",
            quote_str(key), quote_str(val)
        );
        emit_envelope("WriterCommitInsert", start, end, &f);
    }

    pub fn emit_writer_commit_mark_removed(
        start: u64,
        cached_array: u32,
        bucket_idx: u32,
        key: &str,
    ) {
        let end = now();
        // Post-state: occBit still TRUE, remBit now TRUE.
        let f = format!(
            ",\"state\":{{\"kind\":\"writer\",\"step\":\"committed\",\"cachedArray\":{cached_array},\
                \"occBit\":true,\"remBit\":true}},\
             \"bucketIdx\":{bucket_idx},\"key\":{}",
            quote_str(key)
        );
        emit_envelope("WriterCommitMarkRemoved", start, end, &f);
    }

    pub fn emit_writer_release(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"idle\",\"step\":\"idle\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("WriterRelease", start, end, &f);
    }

    pub fn emit_iter_start(start: u64, cached_array: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"iter\",\"step\":\"scanning\",\"cachedArray\":{cached_array}}},\
             \"cachedArray\":{cached_array}"
        );
        emit_envelope("IterStart", start, end, &f);
    }

    pub fn emit_iter_read_occupied(
        start: u64,
        cached_array: u32,
        bucket_idx: u32,
        key: &str,
        val: &str,
    ) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"iter\",\"step\":\"scanning\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx},\"key\":{},\"val\":{}",
            quote_str(key), quote_str(val)
        );
        emit_envelope("IterReadOccupied", start, end, &f);
    }

    pub fn emit_iter_read_empty(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        // IterReadEmpty: pc unchanged, no kind/step required by Trace.tla
        let f = format!(
            ",\"state\":{{\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("IterReadEmpty", start, end, &f);
    }

    pub fn emit_iter_advance_within_bucket(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("IterAdvanceWithinBucket", start, end, &f);
    }

    pub fn emit_iter_cross_array(start: u64, cached_array_post: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"iter\",\"step\":\"scanning\",\"cachedArray\":{cached_array_post}}}"
        );
        emit_envelope("IterCrossArray", start, end, &f);
    }

    pub fn emit_iter_finish(start: u64) {
        let end = now();
        let f = ",\"state\":{\"kind\":\"idle\",\"step\":\"idle\"}";
        emit_envelope("IterFinish", start, end, f);
    }

    pub fn emit_try_resize(start: u64, current_array_post: u32) {
        let end = now();
        let f = format!(",\"state\":{{\"currentArray\":{current_array_post}}}");
        emit_envelope("TryResize", start, end, &f);
    }

    pub fn emit_end_incremental_rehash(start: u64, current_array: u32) {
        let end = now();
        let f = format!(",\"state\":{{\"currentArray\":{current_array}}}");
        emit_envelope("EndIncrementalRehash", start, end, &f);
    }

    pub fn emit_dealloc_garbage(start: u64) {
        let end = now();
        let f = ",\"state\":{\"kind\":\"idle\",\"step\":\"idle\"}";
        emit_envelope("DeallocGarbage", start, end, f);
    }

    pub fn emit_migrate_lock_old_bucket(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"rehasher\",\"step\":\"old_locked\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("MigrateLockOldBucket", start, end, &f);
    }

    pub fn emit_migrate_publish_new(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"rehasher\",\"step\":\"published\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("MigratePublishNew", start, end, &f);
    }

    pub fn emit_migrate_clear_old(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"rehasher\",\"step\":\"cleared\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("MigrateClearOld", start, end, &f);
    }

    pub fn emit_migrate_empty(start: u64, cached_array: u32, bucket_idx: u32) {
        let end = now();
        let f = format!(
            ",\"state\":{{\"kind\":\"rehasher\",\"step\":\"cleared\",\"cachedArray\":{cached_array}}},\
             \"bucketIdx\":{bucket_idx}"
        );
        emit_envelope("MigrateEmpty", start, end, &f);
    }

    pub fn emit_migrate_kill_old_bucket(start: u64) {
        let end = now();
        let f = ",\"state\":{\"kind\":\"idle\",\"step\":\"idle\"}";
        emit_envelope("MigrateKillOldBucket", start, end, f);
    }
}

#[cfg(not(feature = "tla-trace"))]
mod imp {
    // Zero-cost stubs when feature disabled.
    #[inline(always)]
    pub fn now() -> u64 { 0 }
    #[inline(always)]
    pub fn thread_init(_tid: u32) {}
    #[inline(always)]
    pub fn thread_shutdown() {}
    #[inline(always)]
    pub fn array_id(_ptr: usize) -> u32 { 0 }
    #[inline(always)]
    pub fn array_id_opt(_ptr_opt: Option<usize>) -> u32 { 0 }

    #[inline(always)] pub fn emit_writer_start(_s: u64, _a: u32, _k: &str, _v: &str) {}
    #[inline(always)] pub fn emit_writer_maybe_rehash_ok(_s: u64, _a: u32) {}
    #[inline(always)] pub fn emit_writer_maybe_rehash_retry(_s: u64, _a: u32) {}
    #[inline(always)] pub fn emit_writer_acquire_lock(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_writer_commit_insert(_s: u64, _a: u32, _b: u32, _k: &str, _v: &str) {}
    #[inline(always)] pub fn emit_writer_commit_mark_removed(_s: u64, _a: u32, _b: u32, _k: &str) {}
    #[inline(always)] pub fn emit_writer_release(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_iter_start(_s: u64, _a: u32) {}
    #[inline(always)] pub fn emit_iter_read_occupied(_s: u64, _a: u32, _b: u32, _k: &str, _v: &str) {}
    #[inline(always)] pub fn emit_iter_read_empty(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_iter_advance_within_bucket(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_iter_cross_array(_s: u64, _a: u32) {}
    #[inline(always)] pub fn emit_iter_finish(_s: u64) {}
    #[inline(always)] pub fn emit_try_resize(_s: u64, _a: u32) {}
    #[inline(always)] pub fn emit_end_incremental_rehash(_s: u64, _a: u32) {}
    #[inline(always)] pub fn emit_dealloc_garbage(_s: u64) {}
    #[inline(always)] pub fn emit_migrate_lock_old_bucket(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_migrate_publish_new(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_migrate_clear_old(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_migrate_empty(_s: u64, _a: u32, _b: u32) {}
    #[inline(always)] pub fn emit_migrate_kill_old_bucket(_s: u64) {}

    #[inline(always)] pub fn set_op_kv(_k: &str, _v: &str) {}
    #[inline(always)] pub fn current_kv() -> (String, String) {
        (String::new(), String::new())
    }
    #[inline(always)] pub fn set_iter_state(_a: u32, _b: u32) {}
    #[inline(always)] pub fn iter_cached_array() -> u32 { 0 }
    #[inline(always)] pub fn iter_bucket_idx() -> u32 { 0 }
}

pub use imp::*;
