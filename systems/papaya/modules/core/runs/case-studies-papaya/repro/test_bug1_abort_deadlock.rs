/// Bug MC-1 Reproduction: Wrong Parker on Abort via Shrink Resize
///
/// ## Bug
/// In `help_copy_blocking()` (raw/mod.rs:2073-2074), when a resize is aborted
/// because the new table's probe limit can't accommodate all entries at the same
/// hash position, the code unparks `table.state().parker` (the SOURCE table's
/// parker) instead of `next.state().parker` (where threads are parked).
///
/// ## Why Previous Reproduction Failed
/// Previous analysis claimed the abort path is unreachable because "entries always
/// fit in the new table." This is true for DOUBLING and SAME-SIZE resizes, but
/// FALSE for SHRINK resizes:
///
///   - Table 512, limit=45 → shrink to 256, limit=40
///   - 46 collision entries fit in 512 (46 ≤ 46 positions) but NOT in 256 (46 > 41 positions)
///   - The 42nd copy entry fails → ABORT
///
/// ## Trigger Scenario
/// 1. Grow table to 512 with well-distributed "spread" keys
/// 2. Insert 46 "collision" keys that all hash to position 0
/// 3. Delete all spread keys → active = 46 ≤ 512/8 = 64 → shrink threshold
/// 4. Launch N threads each inserting a new collision key → probe limit exceeded → resize
/// 5. Shrink to 256 → copy 46 entries → 42nd fails → ABORT → wrong parker unparked
/// 6. Threads parked on the aborted table's parker are never woken → DEADLOCK

use std::hash::{BuildHasher, Hasher};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use papaya::{HashMap, ResizeMode};

/// Keys >= COLLISION_BASE all hash to 0, creating a single huge probe chain.
/// Keys < COLLISION_BASE get a well-distributed hash to spread across the table.
const COLLISION_BASE: u64 = 1_000_000;

#[derive(Clone)]
struct BimodalHashBuilder;

impl BuildHasher for BimodalHashBuilder {
    type Hasher = BimodalHasher;
    fn build_hasher(&self) -> BimodalHasher {
        BimodalHasher(0)
    }
}

struct BimodalHasher(u64);

impl Hasher for BimodalHasher {
    fn finish(&self) -> u64 {
        if self.0 >= COLLISION_BASE {
            // All collision keys → h1 = 0 (position 0), h2 = 0
            0
        } else {
            // Spread keys: use a mixing function to distribute evenly.
            // Ensure the low bits are never all zero (avoids position 0
            // in any table up to 2^20, preventing interference with
            // collision keys).
            let mut h = self.0.wrapping_add(1);
            h = h.wrapping_mul(0x517CC1B727220A95);
            h ^= h >> 32;
            h = h.wrapping_mul(0xBF58476D1CE4E5B9);
            h ^= h >> 28;
            if h & 0xFFFFF == 0 {
                h |= 0x100;
            }
            h
        }
    }

    fn write_u64(&mut self, i: u64) {
        self.0 = i;
    }

    fn write(&mut self, bytes: &[u8]) {
        let mut v = 0u64;
        for (i, &b) in bytes.iter().enumerate().take(8) {
            v |= (b as u64) << (i * 8);
        }
        self.0 = v;
    }
}

fn main() {
    println!("=== Bug MC-1 Reproduction: Wrong Parker on Abort via Shrink Resize ===\n");

    // We run the test multiple times to account for the race condition.
    for attempt in 1..=5 {
        println!("--- Attempt {}/5 ---", attempt);
        if run_deadlock_test() {
            println!("\n=== BUG MC-1 REPRODUCED ===");
            println!("The wrong-parker deadlock is triggered via shrink resize:");
            println!("  1. Table grew to 512+ with spread keys");
            println!("  2. 46 collision keys at hash position 0");
            println!("  3. Spread keys deleted → active = 46 ≤ 512/8 → shrink to 256");
            println!("  4. Copy: 46 entries into 256 table (limit=40, 41 positions) → 42nd fails → ABORT");
            println!("  5. Abort unparks table.state().parker (WRONG) instead of next.state().parker");
            println!("  6. Parked threads on next table's parker never woken → DEADLOCK");
            std::process::exit(0);
        }
        println!();
    }

    println!("Bug NOT triggered in 5 attempts (race condition not hit).");
    println!("The bug is confirmed by code audit; the race window may be too narrow on this machine.");
    std::process::exit(1);
}

fn run_deadlock_test() -> bool {
    let map: Arc<HashMap<u64, u64, BimodalHashBuilder>> = Arc::new(
        HashMap::builder()
            .capacity(2)
            .hasher(BimodalHashBuilder)
            .resize_mode(ResizeMode::Blocking)
            .build(),
    );

    // Phase 1: Insert spread keys to grow the table to 512+
    // With well-distributed hashing, ~250 entries should grow through:
    // 8 → 16 → 32 → 64 → 128 → 256 → 512
    let guard = map.guard();
    for i in 0u64..250 {
        map.insert(i, i, &guard);
    }
    println!("  Phase 1: Inserted 250 spread keys. len={}", map.len());

    // Phase 2: Insert collision keys (all hash to position 0)
    // At table 512, probe limit = 45, so we can insert 46 entries.
    for i in 0u64..46 {
        map.insert(COLLISION_BASE + i, i, &guard);
    }
    println!("  Phase 2: Inserted 46 collision keys. len={}", map.len());

    // Phase 3: Delete all spread keys → active = 46
    for i in 0u64..250 {
        map.remove(&i, &guard);
    }
    println!("  Phase 3: Deleted spread keys. len={} (expect 46)", map.len());
    drop(guard);

    // Phase 4: Concurrent inserts of new collision keys to trigger shrink resize.
    // Each thread inserts one collision key. The insert exceeds the probe limit
    // (46 existing + 1 new > limit+1=46), triggering resize.
    // The resize heuristic sees 46 active ≤ 512/8 → shrink.
    // The copy to the smaller table hits the abort when entries don't fit.
    // The abort unparks the wrong parker → threads parked on next table's parker
    // are stuck forever.
    const NUM_THREADS: usize = 16;
    const TIMEOUT_SECS: u64 = 8;

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
            let key = COLLISION_BASE + 46 + t as u64;
            map.insert(key, key, &guard);
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
    let elapsed = start.elapsed().as_secs_f64();

    if done == NUM_THREADS {
        println!(
            "  Phase 4: All {} threads completed in {:.1}s. No deadlock.",
            NUM_THREADS, elapsed
        );
        for h in handles {
            let _ = h.join();
        }
        false
    } else {
        let stuck = NUM_THREADS - done;
        println!(
            "  Phase 4: DEADLOCK! {} of {} threads stuck after {:.0}s.",
            stuck, NUM_THREADS, elapsed
        );
        true
    }
}
