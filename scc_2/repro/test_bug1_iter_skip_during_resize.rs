// MC-1 hypothesis: HashIndex::iter may skip a still-live key when the
// underlying BucketArray is resized while the iterator is mid-flight, in
// particular when migration relocates an entry to a bucket index the iterator
// has already passed before the old array is unlinked. This pattern was not
// reachable in the model checker due to the (MaxResize <= 1, BUCKET_LEN = 1)
// state-space budget, so we attempt empirical reproduction here.
//
// We populate a HashIndex with a fixed key set, then run a thread that
// alternates between forcing growth and triggering shrink (via clear/insert
// cycles is not enough — we use the explicit `reserve` API to drive resize)
// while readers continuously iterate. Each iteration must yield every key in
// the live key set at least once. A "skip" is observable as a missing key in
// a single iter pass.
//
// Reproduction methodology:
// - Level 0 black-box stress, no failpoints, no source modification.
// - Live key set is *immutable* during each iteration (no concurrent
//   inserts/removes for those specific keys), so the iterator is *required*
//   to see every key — there is no caller-misuse loophole here.
// - Resizes are driven by `reserve()` (which can grow) and by mass insert
//   followed by mass remove of *different* keys, which provokes the
//   incremental rehash machinery used by HashIndex.

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use scc::HashIndex;

const STABLE_KEY_COUNT: usize = 256;
const SCRATCH_KEY_COUNT: usize = 4096;

fn main() {
    let stop = Arc::new(AtomicBool::new(false));
    let map: Arc<HashIndex<u64, u64>> = Arc::new(HashIndex::with_capacity(8));

    // Insert the "stable" keys that must always be visible.
    for k in 0..STABLE_KEY_COUNT as u64 {
        map.insert_sync(k, k).expect("insert stable");
    }

    let stable_set: HashSet<u64> = (0..STABLE_KEY_COUNT as u64).collect();

    // Resizer thread: provoke growth and shrink by inserting+removing
    // disjoint scratch keys (offset above the stable range).
    let resizer = {
        let map = map.clone();
        let stop = stop.clone();
        thread::spawn(move || {
            let scratch_base: u64 = 1_000_000;
            while !stop.load(Ordering::Relaxed) {
                for i in 0..SCRATCH_KEY_COUNT as u64 {
                    let _ = map.insert_sync(scratch_base + i, i);
                }
                for i in 0..SCRATCH_KEY_COUNT as u64 {
                    let _ = map.remove_sync(&(scratch_base + i));
                }
            }
        })
    };

    // Multiple iterator threads.
    let n_iter_threads = 4;
    let mut iters = Vec::with_capacity(n_iter_threads);
    let skip_count = Arc::new(AtomicUsize::new(0));
    let pass_count = Arc::new(AtomicUsize::new(0));

    for tid in 0..n_iter_threads {
        let map = map.clone();
        let stop = stop.clone();
        let stable_set = stable_set.clone();
        let skip_count = skip_count.clone();
        let pass_count = pass_count.clone();
        iters.push(thread::spawn(move || {
            // Each thread runs a fresh iterator each loop iteration.
            let mut local_skip_examples: Vec<Vec<u64>> = Vec::new();
            while !stop.load(Ordering::Relaxed) {
                let guard = sdd::Guard::new();
                let mut seen = HashSet::<u64>::new();
                for (k, _v) in map.iter(&guard) {
                    if *k < 1_000_000 {
                        seen.insert(*k);
                    }
                }
                if seen.is_superset(&stable_set) {
                    pass_count.fetch_add(1, Ordering::Relaxed);
                } else {
                    let missed: Vec<u64> = stable_set.difference(&seen).copied().collect();
                    skip_count.fetch_add(1, Ordering::Relaxed);
                    if local_skip_examples.len() < 3 {
                        local_skip_examples.push(missed);
                    }
                }
                drop(guard);
            }
            if !local_skip_examples.is_empty() {
                eprintln!("[iter-thread {tid}] skip examples (first {}):",
                    local_skip_examples.len());
                for ex in local_skip_examples.iter().take(3) {
                    eprintln!("  missed {} keys, e.g. {:?}", ex.len(), &ex[..ex.len().min(8)]);
                }
            }
        }));
    }

    let duration = std::env::var("REPRO_SECS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(20);
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(duration) {
        thread::sleep(Duration::from_millis(500));
    }
    stop.store(true, Ordering::Release);

    resizer.join().unwrap();
    for h in iters {
        h.join().unwrap();
    }

    let skips = skip_count.load(Ordering::Relaxed);
    let passes = pass_count.load(Ordering::Relaxed);
    println!("Total iterator passes: {passes}");
    println!("Iterator passes with missing key(s): {skips}");
    if skips > 0 {
        println!("REPRODUCED: HashIndex::iter skipped a key from the stable set");
        println!(" -> a fresh `iter()` returned fewer than the {} stable keys", STABLE_KEY_COUNT);
        std::process::exit(1);
    } else {
        println!("NOT REPRODUCED in this run: no iter pass missed a stable key");
        std::process::exit(0);
    }
}
