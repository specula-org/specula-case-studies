//! Test scenarios for crossbeam-skiplist trace generation.
//!
//! Each test exercises specific protocol paths to generate trace events
//! for TLA+ trace validation. Uses per-thread timebox traces (Category B).

use crossbeam_skiplist::SkipMap;
use std::sync::{Arc, Barrier};

// The tla_trace module is compiled into the crate under `#[cfg(feature = "tla-trace")]`
use crossbeam_skiplist::tla_trace;

/// Helper: initialize tracing for a test scenario.
fn setup_trace(name: &str) -> String {
    let dir = std::env::var("TRACE_DIR").unwrap_or_else(|_| "../traces".to_string());
    let prefix = format!("{}/{}", dir, name);
    tla_trace::init(&prefix);
    prefix
}

/// Helper: finalize tracing.
fn teardown_trace() {
    tla_trace::thread_shutdown();
    tla_trace::shutdown();
}

/// Test 1: Basic sequential insert + get + remove.
/// Exercises: InsertBegin, InsertCAS, InsertBuildLevel, Get, RemoveBegin,
///            RemoveMarkTower, RemoveUnlink, ReleaseEntry
#[test]
fn test_basic_ops() {
    let prefix = setup_trace("basic_ops");
    tla_trace::thread_init(); // main thread = t1

    let map: SkipMap<i64, i64> = SkipMap::new();

    // Register head sentinel
    tla_trace::register_head(map.inner_head_ptr());

    // Insert key 1
    let e1 = map.insert(1, 100);
    drop(e1); // triggers ReleaseEntry via Entry::drop

    // Insert key 2
    let e2 = map.insert(2, 200);
    drop(e2);

    // Remove key 1
    let r = map.remove(&1);
    assert!(r.is_some());
    drop(r);

    // Remove key 2
    let r2 = map.remove(&2);
    assert!(r2.is_some());
    drop(r2);

    teardown_trace();
    eprintln!("[trace] basic_ops written to {}-thread-*.ndjson", prefix);
}

/// Test 2: Concurrent insert + remove from two threads.
/// Exercises concurrent timebox overlap for Category B validation.
#[test]
fn test_concurrent_insert_remove() {
    let prefix = setup_trace("concurrent_insert_remove");
    tla_trace::thread_init(); // main thread = t1

    let map = Arc::new(SkipMap::new());
    tla_trace::register_head(map.inner_head_ptr());

    let barrier = Arc::new(Barrier::new(2));

    let map2 = map.clone();
    let barrier2 = barrier.clone();

    // Thread 2: inserts and removes concurrently
    let t2 = std::thread::spawn(move || {
        tla_trace::thread_init(); // t2
        barrier2.wait();

        // Insert keys 1 and 2
        let e1 = map2.insert(1, 10);
        drop(e1);
        let e2 = map2.insert(2, 20);
        drop(e2);

        // Remove key 1
        let r = map2.remove(&1);
        drop(r);

        // Re-insert key 1 (tests replace path)
        let e3 = map2.insert(1, 11);
        drop(e3);

        tla_trace::thread_shutdown();
    });

    // Main thread (t1): concurrent operations
    barrier.wait();

    // Insert key 2 (races with t2's insert of key 2)
    let e = map.insert(2, 21);
    drop(e);

    // Remove key 2 (races with t2)
    let r = map.remove(&2);
    drop(r);

    t2.join().unwrap();

    teardown_trace();
    eprintln!("[trace] concurrent_insert_remove written to {}-thread-*.ndjson", prefix);
}

/// Test 3: Stress test with interleaved push/pop from multiple threads.
/// Generates genuine cross-thread interval overlap for timebox testing.
#[test]
fn test_interleaved_ops() {
    let prefix = setup_trace("interleaved_ops");
    tla_trace::thread_init(); // main thread = t1

    let map = Arc::new(SkipMap::new());
    tla_trace::register_head(map.inner_head_ptr());

    let barrier = Arc::new(Barrier::new(2));

    let map2 = map.clone();
    let barrier2 = barrier.clone();

    // Thread 2: alternating insert/remove
    let t2 = std::thread::spawn(move || {
        tla_trace::thread_init(); // t2
        barrier2.wait();

        for i in 0..5i64 {
            let key = i * 2; // Even keys: 0, 2, 4, 6, 8
            let e = map2.insert(key, key * 10);
            drop(e);
        }
        // Remove some
        for i in 0..3i64 {
            let key = i * 2;
            let r = map2.remove(&key);
            drop(r);
        }

        tla_trace::thread_shutdown();
    });

    // Main thread (t1): alternating insert/remove on odd keys
    barrier.wait();

    for i in 0..5i64 {
        let key = i * 2 + 1; // Odd keys: 1, 3, 5, 7, 9
        let e = map.insert(key, key * 10);
        drop(e);
    }
    // Remove some
    for i in 0..3i64 {
        let key = i * 2 + 1;
        let r = map.remove(&key);
        drop(r);
    }

    t2.join().unwrap();

    teardown_trace();
    eprintln!("[trace] interleaved_ops written to {}-thread-*.ndjson", prefix);
}
