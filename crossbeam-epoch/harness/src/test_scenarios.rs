//! TLA+ trace validation test scenarios for crossbeam-epoch.
//!
//! Each test exercises specific protocol paths to generate trace events.
//! Run each test separately with CROSSBEAM_TRACE_FILE set to collect
//! per-scenario traces:
//!
//!   CROSSBEAM_TRACE_FILE=traces/basic_pin.ndjson \
//!     cargo test -p crossbeam-epoch tla_test_basic_pin -- --nocapture
//!
//! These tests use the public API only (Collector, LocalHandle, Guard).

use crossbeam_epoch::{Collector, Owned};

/// Basic pin/unpin: single thread, one pin/unpin cycle.
/// Expected events: ReadGlobalForPin, CompletePin, Unpin
#[test]
fn tla_test_basic_pin() {
    let collector = Collector::new();
    let handle = collector.register();

    // Single pin/unpin cycle
    let guard = handle.pin();
    drop(guard);

    // Second cycle to verify state reset
    let guard = handle.pin();
    drop(guard);
}

/// Nested pin: single thread, nested guard creation.
/// Expected events: ReadGlobalForPin, CompletePin, NestedPin, Unpin, Unpin
#[test]
fn tla_test_nested_pin() {
    let collector = Collector::new();
    let handle = collector.register();

    // Outer pin
    let guard1 = handle.pin();
    // Nested pin (guard_count > 0 path)
    let guard2 = handle.pin();
    // Drop inner guard
    drop(guard2);
    // Drop outer guard (last unpin — clears epoch)
    drop(guard1);
}

/// Epoch advance with garbage collection.
/// Single thread pins many times to trigger collect() (every 128 pins),
/// which calls try_advance(). Deferred garbage creates sealed bags.
/// Expected events: ReadGlobalForPin, CompletePin, Unpin (many times),
///   PushLocalBag, ScanForAdvance, StoreAdvancedEpoch, CollectExpiredBag
#[test]
fn tla_test_epoch_advance() {
    let collector = Collector::new();
    let handle = collector.register();

    // Pin many times, deferring garbage to fill bags and trigger collection.
    // PINNINGS_BETWEEN_COLLECT = 128, so after 128 pins we get a collect().
    // MAX_OBJECTS = 64, so after 64 defers the bag is pushed.
    for i in 0..300 {
        let guard = handle.pin();
        unsafe {
            // Defer destruction of a heap object → fills local bag
            let p = Owned::new(i as i32).into_shared(&guard);
            guard.defer_destroy(p);
        }
        // Periodically flush to push bag to global queue
        if i % 60 == 59 {
            guard.flush();
        }
        drop(guard);
    }

    // Final collection pass to drain remaining garbage
    for _ in 0..10 {
        let guard = handle.pin();
        guard.flush();
        drop(guard);
    }
}

/// Multi-threaded concurrent epoch advancement.
/// Multiple threads pin, defer garbage, and unpin concurrently.
/// This exercises the TOCTOU window in pin() and concurrent try_advance().
/// Expected events: interleaved pin/unpin/advance events from multiple threads.
#[test]
fn tla_test_concurrent_epoch() {
    let collector = Collector::new();

    std::thread::scope(|s| {
        for _ in 0..3 {
            let collector = &collector;
            s.spawn(move || {
                let handle = collector.register();
                for i in 0..200 {
                    let guard = handle.pin();
                    if i % 5 == 0 {
                        unsafe {
                            let p = Owned::new(i as i32).into_shared(&guard);
                            guard.defer_destroy(p);
                        }
                    }
                    if i % 40 == 39 {
                        guard.flush();
                    }
                    drop(guard);
                }
            });
        }
    });

    // Drain remaining garbage
    let handle = collector.register();
    for _ in 0..20 {
        let guard = handle.pin();
        guard.flush();
        drop(guard);
    }
}

/// Handle release and finalization.
/// When the last LocalHandle is dropped (and guard_count == 0),
/// finalize() is called which pushes remaining garbage and removes
/// the Local from the global list.
/// Expected events: pin/unpin cycle, ReleaseHandle, Finalize
#[test]
fn tla_test_finalize() {
    let collector = Collector::new();
    let handle = collector.register();

    // Pin, defer some garbage, unpin
    {
        let guard = handle.pin();
        unsafe {
            let p = Owned::new(42i32).into_shared(&guard);
            guard.defer_destroy(p);
        }
        drop(guard);
    }

    // Drop the handle → release_handle() → finalize()
    // (collector kept alive by binding; finalize does NOT drop the Global)
    drop(handle);
}
