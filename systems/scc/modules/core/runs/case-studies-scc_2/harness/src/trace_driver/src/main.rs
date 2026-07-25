//! Trace driver: exercises `scc::HashIndex` to produce TLA+ traces.
//!
//! Two scenarios:
//!   * `single_writer` — one thread inserts then removes; baseline coverage of
//!                       writer events.
//!   * `iter_vs_writer` — t1 iterates while t2 inserts/removes the same keys;
//!                        targets bug family F1 (caller misuse: iter+modify).
//!
//! The trace is configured via env vars consumed by `scc::tla_trace`:
//!   SCC_TRACE_DIR=<dir>
//!   SCC_TRACE_SCENARIO=<name>
//! Each thread `t<N>` writes a file `<dir>/<scenario>.t<N>.ndjson`.
//!
//! After all scenarios run, run `preprocess.py` to merge per-thread files into
//! the single JSON expected by `Trace.tla`.

use std::env;
use std::sync::Arc;
use std::sync::Barrier;
use std::thread;

use scc::HashIndex;
use scc::tla_trace;

/// Spec uses Key = {k1, k2}, Value = {v1}. Match those when calling
/// instrumented insert/remove so trace events carry valid spec values.
const KEY_NAMES: &[&str] = &["k1", "k2"];
const VAL_NAME: &str = "v1";

/// Set the per-op (key, val) thread-local before each instrumented call so
/// the emitted trace event reports a key/val from the spec's Key/Value set.
fn with_kv<R>(key: &str, val: &str, f: impl FnOnce() -> R) -> R {
    tla_trace::set_op_kv(key, val);
    f()
}

fn set_scenario(name: &str) {
    // Set env for child threads — they read it in tla_trace::thread_init.
    // SAFETY: single-threaded setup phase.
    unsafe {
        env::set_var("SCC_TRACE_SCENARIO", name);
    }
}

// ---------------------------------------------------------------------------
// Scenario 1: single_writer (sanity coverage of WriterStart..Release)
//
// One thread does ONE insert. This is the smallest trace that exercises all
// five Writer events end-to-end. Larger sequences risk the spec's
// BUCKET_LEN=1 abstraction colliding with the real BUCKET_LEN=32 (multiple
// real keys hash into the same bucket → spec's `~occBit[p]` precondition for
// WriterCommitInsert is violated on the second insert).
// ---------------------------------------------------------------------------

fn scenario_single_writer() {
    println!("=== single_writer ===");
    set_scenario("single_writer");

    // with_capacity(64) → minimum_capacity → array_len = 2 → matches BucketCount=2.
    let map: HashIndex<u32, u32> = HashIndex::with_capacity(64);

    let h = thread::spawn(move || {
        tla_trace::thread_init(1);
        with_kv("k1", "v1", || {
            map.insert_sync(1, 1).ok();
        });
        tla_trace::thread_shutdown();
    });
    h.join().unwrap();
}

// ---------------------------------------------------------------------------
// Scenario 2: iter_vs_writer
//   t1: iterates the table while t2 concurrently mutates it.
//   Both threads run simultaneously after a barrier — exposes the F1 race.
// ---------------------------------------------------------------------------

fn scenario_iter_vs_writer() {
    println!("=== iter_vs_writer ===");
    set_scenario("iter_vs_writer");

    // Empty map — matches spec's Init (all slots empty). The trace begins
    // post-construction, before any worker. Pre-population would diverge
    // from spec Init and break trace validation.
    let map: Arc<HashIndex<u32, u32>> = Arc::new(HashIndex::with_capacity(64));

    let barrier = Arc::new(Barrier::new(2));

    let map1 = Arc::clone(&map);
    let bar1 = Arc::clone(&barrier);
    let t1 = thread::spawn(move || {
        tla_trace::thread_init(1);
        bar1.wait();
        // One full iteration over the (initially empty) map. Produces
        // IterStart → IterReadEmpty (bucket 0) → IterAdvanceWithinBucket →
        // IterReadEmpty (bucket 1) → IterFinish.
        let g = sdd::Guard::new();
        let mut iter = map1.iter(&g);
        while iter.next().is_some() {
            std::hint::spin_loop();
        }
        drop(iter);
        drop(g);
        tla_trace::thread_shutdown();
    });

    let map2 = Arc::clone(&map);
    let bar2 = Arc::clone(&barrier);
    let t2 = thread::spawn(move || {
        tla_trace::thread_init(2);
        bar2.wait();
        // Single insert. The iter on t1 may or may not see it depending on
        // interleaving — that's exactly the F1 race.
        with_kv("k1", "v1", || {
            map2.insert_sync(1, 1).ok();
        });
        tla_trace::thread_shutdown();
    });

    t1.join().unwrap();
    t2.join().unwrap();
}

// ---------------------------------------------------------------------------
// Scenario 3: contended_writers
//   t1 + t2 each insert/remove the same keys. Exercises lock contention on
//   the bucket and writer-vs-writer ordering.
// ---------------------------------------------------------------------------

fn scenario_contended_writers() {
    println!("=== contended_writers ===");
    set_scenario("contended_writers");

    let map: Arc<HashIndex<u32, u32>> = Arc::new(HashIndex::with_capacity(64));
    let barrier = Arc::new(Barrier::new(2));

    let map1 = Arc::clone(&map);
    let bar1 = Arc::clone(&barrier);
    let t1 = thread::spawn(move || {
        tla_trace::thread_init(1);
        bar1.wait();
        with_kv("k1", "v1", || {
            map1.insert_sync(1, 1).ok();
        });
        tla_trace::thread_shutdown();
    });

    let map2 = Arc::clone(&map);
    let bar2 = Arc::clone(&barrier);
    let t2 = thread::spawn(move || {
        tla_trace::thread_init(2);
        bar2.wait();
        with_kv("k2", "v1", || {
            map2.insert_sync(2, 1).ok();
        });
        tla_trace::thread_shutdown();
    });

    t1.join().unwrap();
    t2.join().unwrap();
}

// ---------------------------------------------------------------------------
// Scenario 4: insert_then_remove
//
// One thread inserts then removes the same key. Exercises both
// WriterCommitInsert and WriterCommitMarkRemoved on the same bucket — but
// note this WILL fail spec validation past the second WriterAcquireLock
// because the spec's remove path requires the slot's `occBit=TRUE,
// remBit=FALSE` precondition, while the post-insert state has `occBit=TRUE,
// remBit=FALSE` — so the validation should reach WriterCommitMarkRemoved.
// ---------------------------------------------------------------------------

fn scenario_insert_then_remove() {
    println!("=== insert_then_remove ===");
    set_scenario("insert_then_remove");

    let map: HashIndex<u32, u32> = HashIndex::with_capacity(64);

    let h = thread::spawn(move || {
        tla_trace::thread_init(1);
        with_kv("k1", "v1", || {
            map.insert_sync(1, 1).ok();
        });
        with_kv("k1", "v1", || {
            map.remove_sync(&1);
        });
        tla_trace::thread_shutdown();
    });
    h.join().unwrap();
}

fn main() {
    // Print spec key set as a sanity check.
    let spec_keys = KEY_NAMES.join(",");
    println!("scc trace driver — spec Key={{{spec_keys}}} Value={{{VAL_NAME}}}");

    let dir = env::var("SCC_TRACE_DIR").unwrap_or_else(|_| "./traces-raw".into());
    println!("Output directory: {dir}");
    std::fs::create_dir_all(&dir).expect("cannot create trace dir");

    // Pick scenarios from arg (default: all).
    let args: Vec<String> = env::args().skip(1).collect();
    let want = |name: &str| args.is_empty() || args.iter().any(|a| a == name);

    if want("single_writer") {
        scenario_single_writer();
    }
    if want("insert_then_remove") {
        scenario_insert_then_remove();
    }
    if want("iter_vs_writer") {
        scenario_iter_vs_writer();
    }
    if want("contended_writers") {
        scenario_contended_writers();
    }

    println!("done — per-thread NDJSON files in {dir}");
}
