//! Trace harness scenarios for crossbeam-deque.
//!
//! Each `#[test]` writes per-thread NDJSON files into
//! `$CROSSBEAM_DEQUE_TRACE_DIR/<scenario>/` so the run script can preprocess
//! and validate them separately.

use crossbeam_deque::tla_trace::{close_thread, init_thread};
use crossbeam_deque::{Steal, Worker};
use std::sync::{
    Arc, Barrier,
    atomic::{AtomicBool, Ordering},
};
use std::thread;
use std::time::Duration;

fn set_scenario(name: &str) {
    if let Ok(base) = std::env::var("CROSSBEAM_DEQUE_TRACE_DIR_BASE") {
        let dir = format!("{base}/{name}");
        let _ = std::fs::create_dir_all(&dir);
        // SAFETY: env mutation in test setup, before any thread spawns.
        unsafe {
            std::env::set_var("CROSSBEAM_DEQUE_TRACE_DIR", &dir);
        }
    }
}

// ------------------------------------------------------------------------
// Scenario 1: FIFO worker + 2 stealers, simultaneous start
// ------------------------------------------------------------------------
//
// Worker pushes 8 values while two stealers race for them. Designed to
// produce overlapping rdtsc intervals between worker push and stealer steal.

#[test]
fn fifo_two_stealers() {
    set_scenario("fifo_two_stealers");

    let w: Worker<usize> = Worker::new_fifo();
    let s1 = w.stealer();
    let s2 = w.stealer();

    let n_pushes = 8usize;
    let barrier = Arc::new(Barrier::new(3));
    let stop = Arc::new(AtomicBool::new(false));

    let b_w = barrier.clone();
    let stop_w = stop.clone();
    let worker_h = thread::spawn(move || {
        init_thread("worker");
        b_w.wait();
        for v in 1..=n_pushes {
            w.push(v);
            // tiny pause to interleave with stealers
            thread::sleep(Duration::from_micros(20));
        }
        // Drain anything left
        while let Some(_) = w.pop() {}
        stop_w.store(true, Ordering::SeqCst);
        close_thread();
    });

    let stealers = [("s1", s1), ("s2", s2)];
    let handles: Vec<_> = stealers
        .into_iter()
        .map(|(name, st)| {
            let b = barrier.clone();
            let stop = stop.clone();
            thread::spawn(move || {
                init_thread(name);
                b.wait();
                while !stop.load(Ordering::SeqCst) {
                    let _ = st.steal();
                    thread::sleep(Duration::from_micros(5));
                }
                // Drain
                for _ in 0..16 {
                    if matches!(st.steal(), Steal::Empty) {
                        break;
                    }
                }
                close_thread();
            })
        })
        .collect();

    worker_h.join().unwrap();
    for h in handles {
        h.join().unwrap();
    }
}

// ------------------------------------------------------------------------
// Scenario 2: LIFO worker + 3 stealers (worker also pops mid-stream)
// ------------------------------------------------------------------------

#[test]
fn lifo_three_stealers() {
    set_scenario("lifo_three_stealers");

    let w: Worker<usize> = Worker::new_lifo();
    let s1 = w.stealer();
    let s2 = w.stealer();
    let s3 = w.stealer();

    let barrier = Arc::new(Barrier::new(4));
    let stop = Arc::new(AtomicBool::new(false));

    let b_w = barrier.clone();
    let stop_w = stop.clone();
    let worker_h = thread::spawn(move || {
        init_thread("worker");
        b_w.wait();
        // Push-only phase: stealers race against pushes here, no pop/steal
        // double-decision ambiguity.
        for round in 0..6usize {
            w.push(round * 10 + 1);
            thread::sleep(Duration::from_micros(15));
        }
        // Stop stealers, then drain whatever is left without contention so
        // the LIFOPopDecide events have unambiguous state capture.
        stop_w.store(true, Ordering::SeqCst);
        thread::sleep(Duration::from_micros(200));
        while let Some(_) = w.pop() {}
        close_thread();
    });

    let stealers = [("s1", s1), ("s2", s2), ("s3", s3)];
    let handles: Vec<_> = stealers
        .into_iter()
        .map(|(name, st)| {
            let b = barrier.clone();
            let stop = stop.clone();
            thread::spawn(move || {
                init_thread(name);
                b.wait();
                while !stop.load(Ordering::SeqCst) {
                    let _ = st.steal();
                    thread::sleep(Duration::from_micros(7));
                }
                for _ in 0..8 {
                    if matches!(st.steal(), Steal::Empty) {
                        break;
                    }
                }
                close_thread();
            })
        })
        .collect();

    worker_h.join().unwrap();
    for h in handles {
        h.join().unwrap();
    }
}

// ------------------------------------------------------------------------
// Scenario 3: FIFO worker + single stealer, deterministic short trace
// ------------------------------------------------------------------------
//
// Smaller trace useful for fast spec validation.

#[test]
fn fifo_short() {
    set_scenario("fifo_short");

    let w: Worker<usize> = Worker::new_fifo();
    let s1 = w.stealer();

    let barrier = Arc::new(Barrier::new(2));

    let b_w = barrier.clone();
    let worker_h = thread::spawn(move || {
        init_thread("worker");
        b_w.wait();
        for v in 1..=4usize {
            w.push(v);
            thread::sleep(Duration::from_micros(50));
        }
        // pop the rest
        while let Some(_) = w.pop() {
            thread::sleep(Duration::from_micros(20));
        }
        close_thread();
    });

    let b_s = barrier.clone();
    let stealer_h = thread::spawn(move || {
        init_thread("s1");
        b_s.wait();
        for _ in 0..6 {
            let _ = s1.steal();
            thread::sleep(Duration::from_micros(40));
        }
        close_thread();
    });

    worker_h.join().unwrap();
    stealer_h.join().unwrap();
}
