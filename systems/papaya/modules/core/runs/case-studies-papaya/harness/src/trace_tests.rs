// TLA+ trace test scenarios for papaya lock-free hash map.
// These tests exercise the protocol code paths to generate trace events
// for trace validation against the TLA+ spec.

use papaya::{HashMap, ResizeMode};
use std::sync::{Arc, Barrier};
use std::thread;

fn trace_dir() -> String {
    std::env::var("TLA_TRACE_DIR").unwrap_or_else(|_| "traces".to_string())
}

/// Helper: insert with trace context
fn traced_insert(map: &HashMap<String, String>, k: &str, v: &str, guard: &impl papaya::Guard) {
    papaya::tla_trace::set_pending_key(k);
    papaya::tla_trace::set_pending_val(v);
    map.insert(k.to_string(), v.to_string(), guard);
    papaya::tla_trace::clear_pending();
}

/// Helper: remove with trace context
fn traced_remove(map: &HashMap<String, String>, k: &str, guard: &impl papaya::Guard) {
    papaya::tla_trace::set_pending_key(k);
    let _ = map.remove(&k.to_string(), guard);
    papaya::tla_trace::clear_pending();
}

/// Helper: get with trace context (gets emit trace events directly, no pending context needed)
fn traced_get(map: &HashMap<String, String>, k: &str, guard: &impl papaya::Guard) {
    let _ = map.get(&k.to_string(), guard);
}

// ================================================================
// Scenario 1: Basic Insert/Remove (2 threads)
// Exercises: InsertBegin, InsertProbe, InsertCAS, StoreMeta,
//            RemoveBegin, RemoveProbe, RemoveCAS, RemoveStoreMeta,
//            InsertUpdate
// ================================================================
#[test]
fn trace_insert_remove() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    papaya::tla_trace::init(&dir, "insert_remove");

    let map: HashMap<String, String> = HashMap::builder()
        .capacity(8)
        .resize_mode(ResizeMode::Blocking)
        .build();

    let map = Arc::new(map);
    let barrier = Arc::new(Barrier::new(2));

    let handles: Vec<_> = (0..2)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                barrier.wait();

                let guard = map.guard();

                if i == 0 {
                    // Thread 0: insert k1=v1, k2=v2, get, remove k1, insert k1=v2, get
                    traced_insert(&map, "k1", "v1", &guard);
                    traced_insert(&map, "k2", "v2", &guard);
                    traced_get(&map, "k1", &guard);
                    traced_get(&map, "k2", &guard);
                    traced_remove(&map, "k1", &guard);
                    traced_insert(&map, "k1", "v2", &guard);
                    traced_get(&map, "k1", &guard);
                } else {
                    // Thread 1: insert k1=v2 (races with thread 0), get, remove k2
                    traced_insert(&map, "k1", "v2", &guard);
                    traced_get(&map, "k1", &guard);
                    traced_remove(&map, "k2", &guard);
                    traced_insert(&map, "k2", "v1", &guard);
                    traced_get(&map, "k2", &guard);
                    traced_get(&map, "k3", &guard); // get of non-existent key
                }

                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    papaya::tla_trace::shutdown();
}

// ================================================================
// Scenario 2: Resize (blocking mode, 4 threads)
// Exercises: AllocNextTable, MarkCopying, MarkCopyingEmpty,
//            CopyEntry, TryPromote, ParkThread, UnparkThread
// ================================================================
#[test]
fn trace_resize_blocking() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    papaya::tla_trace::init(&dir, "resize_blocking");

    // Small initial capacity to force early resize
    let map: HashMap<String, String> = HashMap::builder()
        .capacity(4)
        .resize_mode(ResizeMode::Blocking)
        .build();

    let map = Arc::new(map);
    let barrier = Arc::new(Barrier::new(4));

    let handles: Vec<_> = (0..4)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                barrier.wait();

                let guard = map.guard();

                // Each thread inserts unique keys to fill and force resize
                for j in 0..4 {
                    let k = format!("k{}_{}", i, j);
                    let v = format!("v{}_{}", i, j);
                    traced_insert(&map, &k, &v, &guard);
                }

                // Also do some removes
                for j in 0..2 {
                    let k = format!("k{}_{}", i, j);
                    traced_remove(&map, &k, &guard);
                }

                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    papaya::tla_trace::shutdown();
}

// ================================================================
// Scenario 3: Concurrent Insert/Remove Race (Family 2)
// Exercises the two-step insert visibility window where
// StoreMeta can race with RemoveStoreMeta.
// ================================================================
#[test]
fn trace_concurrent_race() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    papaya::tla_trace::init(&dir, "concurrent_race");

    let map: HashMap<String, String> = HashMap::builder()
        .capacity(8)
        .resize_mode(ResizeMode::Blocking)
        .build();

    let map = Arc::new(map);
    let barrier = Arc::new(Barrier::new(2));

    let handles: Vec<_> = (0..2)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                barrier.wait();

                let guard = map.guard();

                if i == 0 {
                    // Thread 0: repeatedly insert k1 with alternating values
                    for round in 0..8 {
                        let v = if round % 2 == 0 { "v1" } else { "v2" };
                        traced_insert(&map, "k1", v, &guard);
                    }
                } else {
                    // Thread 1: repeatedly remove k1
                    for _ in 0..8 {
                        traced_remove(&map, "k1", &guard);
                        // Re-insert to keep the race going
                        traced_insert(&map, "k1", "v1", &guard);
                    }
                }

                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    papaya::tla_trace::shutdown();
}

// ================================================================
// Scenario 4: Incremental resize mode
// Exercises: MarkCopied, BORROWED entry handling
// ================================================================
#[test]
fn trace_resize_incremental() {
    let dir = trace_dir();
    std::fs::create_dir_all(&dir).ok();

    papaya::tla_trace::init(&dir, "resize_incremental");

    let map: HashMap<String, String> = HashMap::builder()
        .capacity(4)
        .resize_mode(ResizeMode::Incremental(1)) // Small chunk to force many copy steps
        .build();

    let map = Arc::new(map);
    let barrier = Arc::new(Barrier::new(3));

    let handles: Vec<_> = (0..3)
        .map(|i| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                papaya::tla_trace::thread_init();
                barrier.wait();

                let guard = map.guard();

                // Each thread inserts keys to force incremental resize
                for j in 0..5 {
                    let k = format!("k{}_{}", i, j);
                    let v = format!("v{}_{}", i, j);
                    traced_insert(&map, &k, &v, &guard);
                }

                // Do interleaved removes and inserts during/after resize
                for j in 0..3 {
                    let k = format!("k{}_{}", i, j);
                    traced_remove(&map, &k, &guard);
                }

                papaya::tla_trace::thread_shutdown();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    papaya::tla_trace::shutdown();
}
