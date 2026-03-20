//! Test scenarios for TLA+ trace generation.
//!
//! Each test exercises a specific protocol path and emits trace events.
//! Run with ARCSWAP_TRACE_FILE=<path> to capture traces.
//! Tracing auto-initializes from the env var on first arc-swap operation.

use std::sync::Arc;
use arc_swap::ArcSwap;

/// Test 1: Single-thread store + load.
/// Exercises: WriterSwap → WriterPayInit → WriterScanSlot(s) → WriterPayDone → WriterReturn
///            ReaderAcquireFast → ReaderConfirmFast → ReaderDropGuard
#[test]
fn single_swap_load() {
    let initial = Arc::new(42u64);
    let swap = ArcSwap::new(initial);

    // Writer: store new value (internally calls swap)
    let new_val = Arc::new(99u64);
    swap.store(new_val);

    // Reader: load the current value
    let guard = swap.load();
    assert_eq!(**guard, 99);
    drop(guard);

    // One more swap + load cycle
    let new_val2 = Arc::new(200u64);
    swap.store(new_val2);

    let guard2 = swap.load();
    assert_eq!(**guard2, 200);
    drop(guard2);
}

/// Test 2: Two threads — one writer, one reader, sequentialized.
#[test]
fn two_thread_swap_load() {
    let swap = Arc::new(ArcSwap::new(Arc::new(1u64)));
    let swap2 = swap.clone();

    // Thread 1: writer
    let t1 = std::thread::spawn(move || {
        let new_val = Arc::new(2u64);
        swap2.store(new_val);
    });

    t1.join().unwrap();

    // Main thread: reader after writer done
    let guard = swap.load();
    assert_eq!(**guard, 2);
    drop(guard);
}

/// Test 3: Load without any swap — exercises the fast path
/// on the initial value.
#[test]
fn load_initial() {
    let swap = ArcSwap::new(Arc::new(77u64));

    let g1 = swap.load();
    assert_eq!(**g1, 77);
    drop(g1);

    let g2 = swap.load();
    assert_eq!(**g2, 77);
    drop(g2);
}
