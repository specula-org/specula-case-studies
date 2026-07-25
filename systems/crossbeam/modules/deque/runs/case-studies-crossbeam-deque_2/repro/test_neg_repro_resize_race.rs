// CR-1 / MC-1 targeted negative reproduction.
//
// CR-1 from the modeling brief: the *first* CAS of `steal_batch_with_limit_and_pop`
// Lifo (currently deque.rs:1263) is the only stealer-side `front.compare_exchange`
// site that does NOT precede the CAS with `self.inner.buffer.load(Acquire) != buffer`.
// The brief argues this is currently safe because `Worker::resize` preserves
// logical indices (deque.rs:299-303): `ptr::copy_nonoverlapping(buffer.at(i), new.at(i), 1)`
// for the same logical index `i`.
//
// To stress that argument, this test forces many resizes (push/pop-bursts past
// MIN_CAP) while N stealers continuously call `steal_batch_and_pop`, which is
// the API path that lands on the unguarded first CAS. If the index-preservation
// invariant ever broke (e.g., a future refactor compacted indices on resize),
// `LinearizableSteal` would fail under this exact harness.
//
// Run with:
//   cargo run --release --bin test_neg_repro_resize_race \
//     --manifest-path .specula-output/repro/Cargo.toml

use crossbeam_deque::{Steal, Worker};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const N_STEALERS: usize = 6;
const STRESS: Duration = Duration::from_secs(8);

fn main() {
    // Worker::new_lifo forces the LIFO path through `steal_batch_with_limit_and_pop`.
    let w: Worker<u64> = Worker::new_lifo();
    let stealers: Vec<_> = (0..N_STEALERS).map(|_| w.stealer()).collect();
    let stop = Arc::new(AtomicBool::new(false));
    let consumed: Arc<Mutex<HashMap<u64, u64>>> = Arc::new(Mutex::new(HashMap::new()));
    let total_steals = Arc::new(AtomicU64::new(0));
    let total_batches = Arc::new(AtomicU64::new(0));

    let mut handles = Vec::new();
    for s in stealers {
        let consumed = consumed.clone();
        let stop = stop.clone();
        let total_steals = total_steals.clone();
        let total_batches = total_batches.clone();
        handles.push(thread::spawn(move || {
            // Each stealer keeps its own "destination" worker so it can call
            // `steal_batch_and_pop`, which exercises the asymmetric CR-1 site.
            let dest: Worker<u64> = Worker::new_lifo();
            let mut local = HashMap::<u64, u64>::new();
            while !stop.load(Ordering::Relaxed) {
                match s.steal_batch_and_pop(&dest) {
                    Steal::Success(v) => {
                        *local.entry(v).or_insert(0) += 1;
                        total_steals.fetch_add(1, Ordering::Relaxed);
                        // Drain the dest worker's batch.
                        let mut batch = 0u64;
                        while let Some(x) = dest.pop() {
                            *local.entry(x).or_insert(0) += 1;
                            batch += 1;
                        }
                        if batch > 0 {
                            total_batches.fetch_add(batch, Ordering::Relaxed);
                        }
                    }
                    Steal::Empty | Steal::Retry => {
                        thread::yield_now();
                    }
                }
            }
            // Final drain.
            for _ in 0..1024 {
                if let Steal::Success(v) = s.steal_batch_and_pop(&dest) {
                    *local.entry(v).or_insert(0) += 1;
                    while let Some(x) = dest.pop() {
                        *local.entry(x).or_insert(0) += 1;
                    }
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

    // Drive resize churn: alternate large bursts of push (forces grow) with
    // popping the queue empty (forces shrink). MIN_CAP is 64; bursts of 1024
    // and drains-to-zero exercise multiple grow/shrink cycles per iteration.
    while started.elapsed() < STRESS {
        for _ in 0..1024 {
            pushed += 1;
            w.push(pushed);
        }
        // Drain self half-way to provoke shrink.
        let mut local_pops = 0u64;
        while let Some(v) = w.pop() {
            *popped.entry(v).or_insert(0) += 1;
            local_pops += 1;
            if local_pops > 600 {
                break;
            }
        }
    }

    // Final drain.
    while let Some(v) = w.pop() {
        *popped.entry(v).or_insert(0) += 1;
    }

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

    let mut missing = 0u64;
    let mut duplicates = 0u64;
    for v in 1..=pushed {
        match grand.get(&v) {
            None => missing += 1,
            Some(&c) if c == 1 => {}
            Some(_) => duplicates += 1,
        }
    }
    let mut ghost = 0u64;
    for (&k, &c) in &grand {
        if k == 0 || k > pushed {
            ghost += c;
        }
    }

    println!("pushed = {}", pushed);
    println!("steal_batch_and_pop calls = {}", total_steals.load(Ordering::Relaxed));
    println!("batch elements drained = {}", total_batches.load(Ordering::Relaxed));
    println!("worker pops = {}", popped.values().sum::<u64>());
    println!("stealer consumes = {}", consumed.values().sum::<u64>());
    println!("missing = {}", missing);
    println!("duplicates = {}", duplicates);
    println!("ghosts = {}", ghost);
    if missing + duplicates + ghost == 0 {
        println!("RESULT: OK — index-preservation invariant holds under resize churn");
    } else {
        println!("RESULT: VIOLATION");
        std::process::exit(1);
    }
}
