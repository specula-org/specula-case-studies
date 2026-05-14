// Negative reproduction / sanity stress test for crossbeam-deque.
//
// Both the MC bug-report and the modeling brief concluded that no real safety
// bug exists in the current artifact: every TLC violation was an explicit
// fault-model adversary firing as designed (Family A `prematureReclaim`,
// Family B `relaxBackStore`). The asymmetric-recheck site (CR-1) is currently
// safe because `Worker::resize` preserves logical indices. The Injector
// `compare_exchange_weak` sites (CR-3) are a known liveness concern with a
// documented upstream fix (commit 1015b21d) and a doctest guard
// (`MIRI_FALLIBLE_WEAK_CAS`); developers acknowledge it.
//
// This program serves as a black-box stress driver to corroborate the
// "no real bug" verdict. It pushes a known-cardinality multiset through one
// Worker and N Stealers, then checks the LinearizableSteal invariant from the
// brief: every pushed value is consumed exactly once across pop + all steals.
//
// Run with:
//   rustc --edition 2021 -O test_neg_repro_sanity.rs \
//     --extern crossbeam_deque=<path-to-libcrossbeam_deque.rlib> \
//     -L <deps>
// or place this file under `crossbeam-deque/examples/` and `cargo run --example`.

use crossbeam_deque::{Steal, Worker};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const N_STEALERS: usize = 8;
const N_PUSHES: usize = 200_000;
const STRESS_BUDGET: Duration = Duration::from_secs(8);

fn main() {
    let w: Worker<u64> = Worker::new_lifo();
    let stealers: Vec<_> = (0..N_STEALERS).map(|_| w.stealer()).collect();
    let stop = Arc::new(AtomicBool::new(false));
    let consumed: Arc<Mutex<HashMap<u64, u64>>> = Arc::new(Mutex::new(HashMap::new()));

    let mut handles = Vec::new();
    for s in stealers {
        let consumed = consumed.clone();
        let stop = stop.clone();
        handles.push(thread::spawn(move || {
            let mut local = HashMap::<u64, u64>::new();
            while !stop.load(Ordering::Relaxed) {
                match s.steal() {
                    Steal::Success(v) => {
                        *local.entry(v).or_insert(0) += 1;
                    }
                    Steal::Empty | Steal::Retry => {
                        thread::yield_now();
                    }
                }
            }
            // One last drain pass to absorb anything left.
            for _ in 0..1024 {
                if let Steal::Success(v) = s.steal() {
                    *local.entry(v).or_insert(0) += 1;
                } else {
                    break;
                }
            }
            let mut g = consumed.lock().unwrap();
            for (k, v) in local {
                *g.entry(k).or_insert(0) += v;
            }
        }));
    }

    let started = Instant::now();
    let mut pushed = 0u64;
    let mut popped: HashMap<u64, u64> = HashMap::new();
    while pushed < N_PUSHES as u64 && started.elapsed() < STRESS_BUDGET {
        // Push a batch.
        for _ in 0..64 {
            if pushed >= N_PUSHES as u64 {
                break;
            }
            // Use values 1..=N to avoid collisions with default-initialized memory.
            w.push(pushed + 1);
            pushed += 1;
        }
        // Pop a few back ourselves to interleave worker actions.
        for _ in 0..8 {
            match w.pop() {
                Some(v) => *popped.entry(v).or_insert(0) += 1,
                None => break,
            }
        }
    }

    // Drain the rest from the worker side.
    while let Some(v) = w.pop() {
        *popped.entry(v).or_insert(0) += 1;
    }

    // Tell stealers to wind down.
    stop.store(true, Ordering::Relaxed);
    for h in handles {
        h.join().expect("stealer thread panicked");
    }

    let consumed = consumed.lock().unwrap();
    let mut grand: HashMap<u64, u64> = HashMap::new();
    for (k, v) in consumed.iter() {
        *grand.entry(*k).or_insert(0) += v;
    }
    for (k, v) in &popped {
        *grand.entry(*k).or_insert(0) += v;
    }

    let mut violations = 0u64;
    let mut missing = 0u64;
    let mut duplicates = 0u64;
    for v in 1..=pushed {
        match grand.get(&v) {
            None => {
                missing += 1;
                if missing < 5 {
                    eprintln!("MISSING: value {} was pushed but never consumed", v);
                }
            }
            Some(&c) if c == 1 => {}
            Some(&c) => {
                duplicates += 1;
                if duplicates < 5 {
                    eprintln!("DUPLICATE: value {} consumed {} times", v, c);
                }
            }
        }
    }
    violations += missing + duplicates;

    let mut ghost = 0u64;
    for (&k, &v) in &grand {
        if k == 0 || k > pushed {
            ghost += v;
            if ghost < 5 {
                eprintln!("GHOST: value {} consumed {} times (never pushed)", k, v);
            }
        }
    }
    violations += ghost;

    println!("pushed = {}", pushed);
    println!(
        "consumed_by_stealers_total = {}",
        consumed.values().copied().sum::<u64>()
    );
    println!(
        "consumed_by_worker_pop_total = {}",
        popped.values().copied().sum::<u64>()
    );
    println!("missing = {}", missing);
    println!("duplicates = {}", duplicates);
    println!("ghosts = {}", ghost);
    if violations == 0 {
        println!("RESULT: OK — LinearizableSteal holds across the run");
    } else {
        println!("RESULT: VIOLATION — {} anomalies found", violations);
        std::process::exit(1);
    }
}
