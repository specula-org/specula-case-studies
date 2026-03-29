//! Trace generation test scenarios for papaya TLA+ trace validation.
//!
//! Each test exercises specific protocol paths and writes per-thread
//! NDJSON traces to the directory specified by PAPAYA_TRACE_DIR.
//!
//! Test scenarios:
//!   1. basic_insert:           Single-thread inserts → init_table + insert_cas + insert_meta
//!   2. concurrent_insert_resize: Multi-thread inserts → triggers resize (alloc_next, copy, promote)
//!   3. concurrent_insert_remove: Multi-thread insert+remove → exercises update_at for both paths

use papaya::{HashMap, ResizeMode};
use std::sync::{Arc, Barrier};
use std::thread;

/// Scenario 1: Basic single-thread inserts.
/// Exercises: init_table, insert_cas, insert_meta.
/// Expected events: 1 init_table + N insert_cas + N insert_meta.
#[test]
fn basic_insert() {
    let map: HashMap<i32, i32> = HashMap::builder()
        .capacity(32)
        .resize_mode(ResizeMode::Blocking)
        .build();
    let guard = map.guard();
    for i in 0..8 {
        map.insert(i, i * 10, &guard);
    }
    // Verify all keys are present
    for i in 0..8 {
        assert_eq!(map.get(&i, &guard), Some(&(i * 10)));
    }
    drop(guard);
    papaya::tla_trace::flush();
}

/// Scenario 2: Concurrent inserts that trigger resize.
/// Uses small capacity (4) + incremental(1) to force resize quickly.
/// Exercises: init_table, insert_cas, insert_meta, alloc_next,
///            copy_mark_copying, copy_insert, copy_mark_copied, try_promote.
#[test]
fn concurrent_insert_resize() {
    let map: Arc<HashMap<i32, i32>> = Arc::new(
        HashMap::builder()
            .capacity(4)
            .resize_mode(ResizeMode::Incremental(1))
            .build(),
    );
    let num_threads = 4;
    let keys_per_thread = 8;
    let barrier = Arc::new(Barrier::new(num_threads));

    let handles: Vec<_> = (0..num_threads)
        .map(|t| {
            let map = Arc::clone(&map);
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                let guard = map.guard();
                barrier.wait();
                let base = t as i32 * keys_per_thread;
                for i in 0..keys_per_thread {
                    map.insert(base + i, (base + i) * 100, &guard);
                }
                drop(guard);
                papaya::tla_trace::flush();
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    // Verify all keys present
    let guard = map.guard();
    for t in 0..num_threads {
        let base = t as i32 * keys_per_thread;
        for i in 0..keys_per_thread {
            assert_eq!(map.get(&(base + i), &guard), Some(&((base + i) * 100)));
        }
    }
    drop(guard);
    papaya::tla_trace::flush();
}

/// Scenario 3: Concurrent inserts and removes.
/// Exercises: insert_cas, insert_meta, remove (via update_at), insert_update.
#[test]
fn concurrent_insert_remove() {
    let map: Arc<HashMap<i32, i32>> = Arc::new(
        HashMap::builder()
            .capacity(16)
            .resize_mode(ResizeMode::Blocking)
            .build(),
    );
    let barrier = Arc::new(Barrier::new(3));

    // Thread 1: inserts keys 0..16
    let map1 = Arc::clone(&map);
    let b1 = Arc::clone(&barrier);
    let h1 = thread::spawn(move || {
        let guard = map1.guard();
        b1.wait();
        for i in 0..16_i32 {
            map1.insert(i, i * 10, &guard);
        }
        drop(guard);
        papaya::tla_trace::flush();
    });

    // Thread 2: removes even keys 0,2,4..14 (retries until present)
    let map2 = Arc::clone(&map);
    let b2 = Arc::clone(&barrier);
    let h2 = thread::spawn(move || {
        let guard = map2.guard();
        b2.wait();
        for i in (0..16_i32).step_by(2) {
            // Spin until the key exists, then remove
            loop {
                if map2.remove(&i, &guard).is_some() {
                    break;
                }
                std::hint::spin_loop();
            }
        }
        drop(guard);
        papaya::tla_trace::flush();
    });

    // Thread 3: updates odd keys 1,3,5..15 with new values (retries until present)
    let map3 = Arc::clone(&map);
    let b3 = Arc::clone(&barrier);
    let h3 = thread::spawn(move || {
        let guard = map3.guard();
        b3.wait();
        for i in (1..16_i32).step_by(2) {
            loop {
                if map3.get(&i, &guard).is_some() {
                    map3.insert(i, i * 100, &guard);
                    break;
                }
                std::hint::spin_loop();
            }
        }
        drop(guard);
        papaya::tla_trace::flush();
    });

    h1.join().unwrap();
    h2.join().unwrap();
    h3.join().unwrap();
    papaya::tla_trace::flush();
}
