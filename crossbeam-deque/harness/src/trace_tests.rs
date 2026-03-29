//! Trace-generating integration tests for crossbeam-deque.
//!
//! Each test exercises specific protocol paths and emits NDJSON trace events
//! via the tla_trace module. Run each test in a separate cargo invocation
//! with CROSSBEAM_DEQUE_TRACE_DIR set to a unique directory.
//!
//! Usage (via run.sh):
//!   CROSSBEAM_DEQUE_TRACE_DIR=traces/push_lifo_pop \
//!     cargo test --test trace_tests test_push_lifo_pop -- --exact --nocapture

use crossbeam_deque::{tla_trace, Steal, Worker};
use std::thread;

/// LIFO mode: push 5 items, pop all 5 from the back.
/// Expected trace events: Push x5, LIFOPop x5.
#[test]
fn test_push_lifo_pop() {
    tla_trace::init_worker_thread();

    let w = Worker::new_lifo();

    for i in 1..=5i32 {
        w.push(i);
    }
    // Pop all (LIFO order: 5, 4, 3, 2, 1)
    for _ in 0..5 {
        let v = w.pop();
        assert!(v.is_some());
    }
    // Empty pop
    assert_eq!(w.pop(), None);

    tla_trace::shutdown_thread();
    eprintln!("[trace_tests] test_push_lifo_pop done");
}

/// FIFO mode: push 5 items, pop all 5 from the front.
/// Expected trace events: Push x5, FIFOPopAttempt x5.
#[test]
fn test_push_fifo_pop() {
    tla_trace::init_worker_thread();

    let w = Worker::new_fifo();

    for i in 1..=5i32 {
        w.push(i);
    }
    // Pop all (FIFO order: 1, 2, 3, 4, 5)
    for _ in 0..5 {
        let v = w.pop();
        assert!(v.is_some());
    }
    // Empty pop
    assert_eq!(w.pop(), None);

    tla_trace::shutdown_thread();
    eprintln!("[trace_tests] test_push_fifo_pop done");
}

/// LIFO mode: push 5 items, one stealer steals all via single steal.
/// Expected trace events: Push x5, (StealBegin + StealReadTask + StealCommit) x5.
#[test]
fn test_steal_single() {
    tla_trace::init_worker_thread();

    let w = Worker::new_lifo();
    let s = w.stealer();

    // Push 5 items first (worker thread)
    for i in 1..=5i32 {
        w.push(i);
    }

    // Steal from a separate thread
    let handle = thread::spawn(move || {
        tla_trace::init_stealer_thread();

        let mut stolen = 0;
        for _ in 0..50 {
            match s.steal() {
                Steal::Success(_) => {
                    stolen += 1;
                    if stolen >= 5 {
                        break;
                    }
                }
                Steal::Empty => break,
                Steal::Retry => {}
            }
        }

        tla_trace::shutdown_thread();
        stolen
    });

    let stolen = handle.join().unwrap();
    assert_eq!(stolen, 5, "stealer should steal all 5 items");

    tla_trace::shutdown_thread();
    eprintln!("[trace_tests] test_steal_single done, stolen={}", stolen);
}

/// FIFO mode: push 8 items, worker pops + 2 stealers steal concurrently.
/// Exercises timebox overlap between worker and stealer events.
/// Expected: all 8 items consumed exactly once.
#[test]
fn test_concurrent_fifo() {
    tla_trace::init_worker_thread();

    let w = Worker::new_fifo();
    let s1_handle = w.stealer();
    let s2_handle = s1_handle.clone();

    // Push items first
    for i in 1..=8i32 {
        w.push(i);
    }

    // Use a barrier to start all threads simultaneously for maximum overlap
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));

    let b1 = barrier.clone();
    let h1 = thread::spawn(move || {
        tla_trace::init_stealer_thread();
        b1.wait();
        let mut stolen = 0;
        for _ in 0..50 {
            match s1_handle.steal() {
                Steal::Success(_) => stolen += 1,
                Steal::Empty => break,
                Steal::Retry => {}
            }
        }
        tla_trace::shutdown_thread();
        stolen
    });

    let b2 = barrier.clone();
    let h2 = thread::spawn(move || {
        tla_trace::init_stealer_thread();
        b2.wait();
        let mut stolen = 0;
        for _ in 0..50 {
            match s2_handle.steal() {
                Steal::Success(_) => stolen += 1,
                Steal::Empty => break,
                Steal::Retry => {}
            }
        }
        tla_trace::shutdown_thread();
        stolen
    });

    // Worker also pops concurrently
    barrier.wait();
    let mut popped = 0;
    for _ in 0..50 {
        if w.pop().is_some() {
            popped += 1;
        } else {
            break;
        }
    }

    let s1_count = h1.join().unwrap();
    let s2_count = h2.join().unwrap();

    assert_eq!(
        popped + s1_count + s2_count,
        8,
        "all items consumed: worker={}, s1={}, s2={}",
        popped,
        s1_count,
        s2_count
    );

    tla_trace::shutdown_thread();
    eprintln!(
        "[trace_tests] test_concurrent_fifo done: worker={}, s1={}, s2={}",
        popped, s1_count, s2_count
    );
}
