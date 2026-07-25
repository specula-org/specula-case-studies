//! Test scenarios for flurry trace generation.
//!
//! Each test exercises specific protocol paths and writes per-thread NDJSON
//! traces to the directory specified by FLURRY_TRACE_DIR.

use flurry::HashMap;
use std::sync::{Arc, Barrier};
use std::thread;

fn init_tracing() {
    flurry::tla_trace::try_init();
}

fn emit_exit_guard() {
    if flurry::tla_trace::is_active() {
        let s = flurry::tla_trace::trace_rdtsc();
        let e = flurry::tla_trace::trace_rdtsc();
        flurry::tla_trace::emit_exit_guard(s, e);
    }
}

/// Scenario 1: Basic concurrent puts into empty and node bins.
/// Two threads insert non-overlapping keys into a small map.
/// Exercises: enter_guard, put_empty_bin, put_node_bin, exit_guard.
#[test]
fn test_basic_put() {
    init_tracing();

    let map: Arc<HashMap<usize, usize>> = Arc::new(HashMap::with_capacity(4));
    let barrier = Arc::new(Barrier::new(2));

    let handles: Vec<_> = (0..2)
        .map(|tid| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                barrier.wait();
                let guard = map.guard();
                // Each thread inserts 4 keys
                for i in 0..4 {
                    let key = tid + i * 2;
                    map.insert(key, key * 10, &guard);
                }
                emit_exit_guard();
                drop(guard);
                flurry::tla_trace::flush_thread();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
}

/// Scenario 2: Resize under contention.
/// Insert enough keys to trigger resize, with multiple threads.
/// Exercises: init_resize, claim_range, transfer_bin, transfer_finish_check,
///            complete_resize, help_transfer, put_help_transfer, claim_range_exhausted.
#[test]
fn test_resize() {
    init_tracing();

    // Start with capacity 4 (sizeCtl threshold ~3), insert 16 keys to force resize
    let map: Arc<HashMap<usize, usize>> = Arc::new(HashMap::with_capacity(4));
    let barrier = Arc::new(Barrier::new(2));

    let handles: Vec<_> = (0..2)
        .map(|tid| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                barrier.wait();
                let guard = map.guard();
                for i in 0..8 {
                    let key = tid * 8 + i;
                    map.insert(key, key, &guard);
                }
                emit_exit_guard();
                drop(guard);
                flurry::tla_trace::flush_thread();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
}

/// Scenario 3: Treeify bin under contention.
/// Insert many keys to trigger treeification of bins.
/// Exercises: put_node_bin (many), treeify_bin, put_tree_bin.
#[test]
fn test_treeify() {
    init_tracing();

    // With default hasher, we just insert many keys. Some bins will exceed
    // TREEIFY_THRESHOLD (8) due to hash collisions.
    // Use small initial capacity so bins fill up faster.
    let map: Arc<HashMap<usize, usize>> = Arc::new(HashMap::with_capacity(4));
    let barrier = Arc::new(Barrier::new(2));

    let handles: Vec<_> = (0..2)
        .map(|tid| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                barrier.wait();
                let guard = map.guard();
                // Insert many keys; with capacity 4 and 50 keys per thread,
                // some bins will reach the treeify threshold after resize
                for i in 0..50 {
                    let key = tid * 1000 + i;
                    map.insert(key, key, &guard);
                }
                emit_exit_guard();
                drop(guard);
                flurry::tla_trace::flush_thread();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
}
