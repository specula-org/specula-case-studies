/// Bug MC-1 Diagnostic: Determine if the deadlock is caused by the wrong-parker abort path.
///
/// This test runs several variants to isolate the root cause:
/// 1. Blocking mode + constant hash → expected deadlock (abort path)
/// 2. Incremental mode + constant hash → should NOT deadlock (no parking)
/// 3. Blocking mode + normal hash → should NOT deadlock (no collisions → no abort)
/// 4. Blocking mode + constant hash + small scale → deadlock boundary

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use papaya::{HashMap, ResizeMode};

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

fn run_test<S: BuildHasher + Clone + Send + Sync + 'static>(
    label: &str,
    hasher: S,
    mode: ResizeMode,
    num_threads: usize,
    keys_per_thread: usize,
    timeout_secs: u64,
) -> bool {
    let map: Arc<HashMap<u64, u64, S>> = Arc::new(
        HashMap::builder()
            .capacity(2)
            .hasher(hasher)
            .resize_mode(mode)
            .build(),
    );

    let barrier = Arc::new(Barrier::new(num_threads));
    let completed = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::new();

    for t in 0..num_threads {
        let map = map.clone();
        let barrier = barrier.clone();
        let completed = completed.clone();

        handles.push(thread::spawn(move || {
            barrier.wait();
            let guard = map.guard();
            for i in 0..keys_per_thread {
                let key = (t * keys_per_thread + i) as u64;
                map.insert(key, key, &guard);
            }
            completed.fetch_add(1, Ordering::Release);
        }));
    }

    let start = Instant::now();
    let deadline = start + Duration::from_secs(timeout_secs);

    while Instant::now() < deadline {
        if completed.load(Ordering::Acquire) == num_threads {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    let done = completed.load(Ordering::Acquire);
    let elapsed = start.elapsed().as_secs_f64();

    if done == num_threads {
        println!("  {}: COMPLETED ({}/{} threads, {:.1}s)", label, done, num_threads, elapsed);
        for h in handles {
            let _ = h.join();
        }
        false
    } else {
        let stuck = num_threads - done;
        println!("  {}: DEADLOCK ({} stuck, {:.1}s)", label, stuck, elapsed);
        true
    }
}

fn main() {
    println!("=== Bug MC-1 Diagnostic: Isolating the deadlock root cause ===");
    println!();

    // Test 1: Blocking + constant hash → expected deadlock
    println!("Test 1: Blocking resize + constant hash (ZeroHash)");
    let dl1 = run_test("Blocking+ZeroHash", ZeroHashBuilder, ResizeMode::Blocking, 8, 200, 8);

    // Test 2: Incremental + constant hash → should complete (no parking in incremental mode)
    println!("Test 2: Incremental resize + constant hash (ZeroHash)");
    let dl2 = run_test("Incremental+ZeroHash", ZeroHashBuilder, ResizeMode::Incremental(1), 8, 200, 8);

    // Test 3: Blocking + normal hash → should complete (no extreme collisions)
    println!("Test 3: Blocking resize + normal hash (RandomState)");
    let dl3 = run_test("Blocking+RandomState", RandomState::new(), ResizeMode::Blocking, 8, 200, 8);

    // Test 4: Blocking + constant hash + fewer entries (below abort threshold)
    println!("Test 4: Blocking resize + constant hash + 2 threads × 10 keys");
    let dl4 = run_test("Blocking+ZeroHash+Small", ZeroHashBuilder, ResizeMode::Blocking, 2, 10, 8);

    // Test 5: Blocking + constant hash + moderate scale
    println!("Test 5: Blocking resize + constant hash + 4 threads × 50 keys");
    let dl5 = run_test("Blocking+ZeroHash+Medium", ZeroHashBuilder, ResizeMode::Blocking, 4, 50, 8);

    println!();
    println!("=== Summary ===");
    println!("  Blocking + ZeroHash:        {}", if dl1 { "DEADLOCK" } else { "OK" });
    println!("  Incremental + ZeroHash:     {}", if dl2 { "DEADLOCK" } else { "OK" });
    println!("  Blocking + RandomState:     {}", if dl3 { "DEADLOCK" } else { "OK" });
    println!("  Blocking + ZeroHash (small):{}", if dl4 { "DEADLOCK" } else { "OK" });
    println!("  Blocking + ZeroHash (med):  {}", if dl5 { "DEADLOCK" } else { "OK" });

    println!();
    if dl1 && !dl2 && !dl3 {
        println!("DIAGNOSIS: Deadlock occurs ONLY with Blocking resize + hash collisions.");
        println!("This is consistent with MC-1: the abort path in help_copy_blocking()");
        println!("unparks the wrong parker when the resize is aborted due to probe limit");
        println!("overflow in the new table (caused by extreme hash collisions + shrink).");
    } else if dl1 && dl2 {
        println!("DIAGNOSIS: Deadlock occurs in both modes — may be a different bug.");
    } else if !dl1 {
        println!("DIAGNOSIS: No deadlock in any test — bug not triggered in this run.");
    }

    if dl1 {
        std::process::exit(0); // Bug triggered
    } else {
        std::process::exit(1); // Bug not triggered
    }
}
