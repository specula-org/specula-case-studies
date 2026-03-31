/// Bug MC-1 Reproduction: Blocking Resize Abort Unparks Wrong Parker
///
/// ## Bug Summary
/// In `help_copy_blocking()` (raw/mod.rs:2073-2074), when a resize is aborted,
/// the code unparks `table.state().parker` (the SOURCE table's parker) instead
/// of `next.state().parker` (where threads are actually parked at lines 2134-2136).
/// This is a clear code inconsistency: `try_promote()` at line 2501 correctly uses
/// `next.state().parker`, but the abort path uses `table.state().parker`.
///
/// ## Reachability Analysis
/// The abort path triggers when `copy_at_blocking()` returns false, which happens
/// when `insert_copy()` can't find an empty slot within the probe limit in the
/// new table. However, analysis shows this is effectively unreachable:
///
/// 1. For any resize (double, same-size, or shrink), the new table M has enough
///    slots for the entries being copied:
///    - Double: copies ≤ old_len entries into 2*old_len slots
///    - Same-size: copies < old_len/2 entries into old_len slots
///    - Shrink: copies ≤ old_len/8 entries into ≥ old_len/2 slots
/// 2. Quadratic probing on power-of-2 tables gives N unique positions in the
///    first N probe steps, so K entries (K ≤ N) always fit within K probes.
/// 3. The probe limit (5 * log2(N)) exceeds the entry count in all cases.
///
/// ## Test Strategy
/// Despite the unreachability, this test attempts to exercise the blocking resize
/// path with adversarial (constant) hashing to maximize collision pressure.
/// Multiple threads concurrently trigger resize operations. A deadlock (thread
/// timeout) would indicate the bug was triggered.
///
/// Expected result: all threads complete (no deadlock) because the abort path
/// cannot be reached with current table sizing logic.

use std::hash::{BuildHasher, Hasher};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use papaya::{HashMap, ResizeMode};

/// A hasher that always returns 0, forcing all keys to the same probe chain.
#[derive(Clone)]
struct ZeroHashBuilder;

impl BuildHasher for ZeroHashBuilder {
    type Hasher = ZeroHasher;
    fn build_hasher(&self) -> ZeroHasher {
        ZeroHasher(0)
    }
}

struct ZeroHasher(u64);

impl Hasher for ZeroHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, _bytes: &[u8]) {}
}

fn main() {
    println!("=== Bug MC-1 Reproduction: Wrong Parker on Abort ===");
    println!();

    // Strategy 1: High-collision blocking resize with many threads
    // Use constant hash + blocking mode + small capacity to maximize resize pressure.
    println!("--- Strategy 1: Concurrent blocking resize with collision hashing ---");
    test_concurrent_blocking_resize();
    println!();

    // Strategy 2: Repeated insert/remove cycles to trigger shrink+regrow
    // Attempt to create table sizing conditions favorable for abort.
    println!("--- Strategy 2: Insert/remove cycles with shrink heuristic ---");
    test_shrink_regrow_cycle();
    println!();

    println!("=== Result ===");
    println!("Bug MC-1 is CONFIRMED by code audit (wrong parker variable at raw/mod.rs:2073)");
    println!("but the abort path appears unreachable with current table sizing logic.");
    println!("The deadlock cannot be triggered through public APIs.");
    println!();
    println!("Evidence of the bug (code inconsistency):");
    println!("  ABORT path (line 2073): table.state().parker.unpark(...)  // WRONG");
    println!("  PROMOTE path (line 2501): state.parker.unpark(...)        // CORRECT");
    println!("  PARK target (line 2134): next.state().parker.park(...)    // threads park HERE");

    // Exit with code 1 to indicate bug was NOT triggered (reproduction failed)
    std::process::exit(1);
}

/// Test 1: Concurrent inserts with constant hash in blocking mode.
/// Multiple threads insert keys that all hash to position 0, forcing
/// maximum probe chain lengths and frequent resizes.
fn test_concurrent_blocking_resize() {
    const NUM_THREADS: usize = 8;
    const KEYS_PER_THREAD: usize = 500;
    const TIMEOUT_SECS: u64 = 10;

    let map: Arc<HashMap<u64, u64, ZeroHashBuilder>> = Arc::new(
        HashMap::builder()
            .capacity(2)
            .hasher(ZeroHashBuilder)
            .resize_mode(ResizeMode::Blocking)
            .build(),
    );

    let barrier = Arc::new(Barrier::new(NUM_THREADS));
    let completed = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::new();

    for t in 0..NUM_THREADS {
        let map = map.clone();
        let barrier = barrier.clone();
        let completed = completed.clone();

        handles.push(thread::spawn(move || {
            barrier.wait();
            let guard = map.guard();
            for i in 0..KEYS_PER_THREAD {
                let key = (t * KEYS_PER_THREAD + i) as u64;
                map.insert(key, key, &guard);
            }
            completed.fetch_add(1, Ordering::Release);
        }));
    }

    let start = Instant::now();
    let deadline = start + Duration::from_secs(TIMEOUT_SECS);

    while Instant::now() < deadline {
        if completed.load(Ordering::Acquire) == NUM_THREADS {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }

    let done = completed.load(Ordering::Acquire);
    if done == NUM_THREADS {
        println!("  All {} threads completed in {:.1}s. No deadlock.", NUM_THREADS, start.elapsed().as_secs_f64());
        for h in handles {
            let _ = h.join();
        }
    } else {
        let stuck = NUM_THREADS - done;
        println!("  DEADLOCK DETECTED! {} of {} threads stuck after {}s.", stuck, NUM_THREADS, TIMEOUT_SECS);
        println!("  BUG REPRODUCED: abort unparked wrong parker.");
        std::process::exit(0);
    }
}

/// Test 2: Insert/remove cycles to provoke shrink heuristic.
/// Fill table → remove most entries → re-insert → repeat.
/// This forces repeated resize/shrink transitions in blocking mode.
fn test_shrink_regrow_cycle() {
    const CYCLES: usize = 50;
    const ENTRIES: usize = 200;
    const NUM_THREADS: usize = 4;
    const TIMEOUT_SECS: u64 = 15;

    let completed = Arc::new(AtomicBool::new(false));

    let map: Arc<HashMap<u64, u64, ZeroHashBuilder>> = Arc::new(
        HashMap::builder()
            .capacity(2)
            .hasher(ZeroHashBuilder)
            .resize_mode(ResizeMode::Blocking)
            .build(),
    );

    let completed_clone = completed.clone();
    let map_clone = map.clone();

    let worker = thread::spawn(move || {
        let barrier = Arc::new(Barrier::new(NUM_THREADS));
        for cycle in 0..CYCLES {
            // Phase A: concurrent inserts
            let mut handles = Vec::new();
            for t in 0..NUM_THREADS {
                let map = map_clone.clone();
                let barrier = barrier.clone();
                handles.push(thread::spawn(move || {
                    barrier.wait();
                    let guard = map.guard();
                    let start = t * (ENTRIES / NUM_THREADS);
                    let end = start + (ENTRIES / NUM_THREADS);
                    for i in start..end {
                        map.insert(i as u64, i as u64, &guard);
                    }
                }));
            }
            for h in handles {
                let _ = h.join();
            }

            // Phase B: remove most entries (trigger shrink on next resize)
            {
                let guard = map_clone.guard();
                for i in 0..(ENTRIES * 7 / 8) {
                    map_clone.remove(&(i as u64), &guard);
                }
            }

            // Phase C: concurrent re-inserts (triggers resize/shrink)
            let mut handles = Vec::new();
            for t in 0..NUM_THREADS {
                let map = map_clone.clone();
                let barrier = barrier.clone();
                handles.push(thread::spawn(move || {
                    barrier.wait();
                    let guard = map.guard();
                    let base = (cycle * ENTRIES + ENTRIES) as u64;
                    let start = t * (ENTRIES / NUM_THREADS);
                    let end = start + (ENTRIES / NUM_THREADS);
                    for i in start..end {
                        map.insert(base + i as u64, i as u64, &guard);
                    }
                }));
            }
            for h in handles {
                let _ = h.join();
            }

            // Phase D: clear for next cycle
            {
                let guard = map_clone.guard();
                map_clone.clear(&guard);
            }
        }
        completed_clone.store(true, Ordering::Release);
    });

    let start = Instant::now();
    let deadline = start + Duration::from_secs(TIMEOUT_SECS);

    while Instant::now() < deadline {
        if completed.load(Ordering::Acquire) {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }

    if completed.load(Ordering::Acquire) {
        println!("  Completed {} cycles in {:.1}s. No deadlock.", CYCLES, start.elapsed().as_secs_f64());
        let _ = worker.join();
    } else {
        println!("  DEADLOCK DETECTED after {}s during insert/remove cycles.", TIMEOUT_SECS);
        println!("  BUG REPRODUCED: abort unparked wrong parker.");
        std::process::exit(0);
    }
}
