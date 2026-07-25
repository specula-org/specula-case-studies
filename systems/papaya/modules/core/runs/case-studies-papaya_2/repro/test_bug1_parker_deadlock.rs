// Reproduction test for PAPAYA-001: Wrong parker unparked on resize abort.
//
// Bug: In help_copy_blocking, when a resize is aborted because the destination
// table ran out of space, the code unparks threads on the SOURCE table's parker
// (line 2219: `table.state()`) instead of the DESTINATION table's parker
// (`next.state()`). Threads parked on the destination table are never woken,
// causing a permanent deadlock.
//
// Run with: RUSTFLAGS="--cfg papaya_stress" cargo test --test repro_parker_deadlock -- --test-threads 1
// The papaya_stress cfg prevents tables from growing, forcing resize aborts.
// The test uses blocking resize mode to hit the buggy code path.

use papaya::{HashMap, ResizeMode};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

#[test]
fn parker_deadlock_on_resize_abort() {
    // Use a small capacity to trigger resize quickly.
    // Under papaya_stress, the new table will be the same size, so copies
    // will fail and trigger the abort path in help_copy_blocking.
    let map: HashMap<usize, usize> = HashMap::builder()
        .capacity(4)
        .resize_mode(ResizeMode::Blocking)
        .build();

    let map = Arc::new(map);
    let num_threads = 4;
    let barrier = Arc::new(Barrier::new(num_threads));

    let handles: Vec<_> = (0..num_threads)
        .map(|tid| {
            let map = map.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                barrier.wait();
                let guard = map.guard();
                // Insert enough keys to fill the table and force resize + abort.
                // With capacity 4 and papaya_stress, this quickly triggers the
                // abort path where threads park on the destination table.
                for i in 0..50 {
                    map.insert(tid * 1000 + i, i, &guard);
                }
            })
        })
        .collect();

    // Wait with a timeout. If the bug is present, threads will deadlock.
    let deadline = Duration::from_secs(30);
    let start = std::time::Instant::now();
    let mut all_done = true;

    for h in handles {
        let remaining = deadline.saturating_sub(start.elapsed());
        if remaining.is_zero() {
            all_done = false;
            eprintln!("DEADLOCK DETECTED: thread did not complete within timeout");
            break;
        }
        // We can't join with a timeout in stable Rust, so we use a polling approach.
        // The thread::JoinHandle doesn't have a timeout join, so we'll use a channel.
        let (tx, rx) = std::sync::mpsc::channel();
        let join_thread = thread::spawn(move || {
            let result = h.join();
            let _ = tx.send(result);
        });
        match rx.recv_timeout(remaining) {
            Ok(Ok(())) => {}
            Ok(Err(_)) => {
                eprintln!("Thread panicked!");
                all_done = false;
            }
            Err(_) => {
                eprintln!("DEADLOCK DETECTED: thread did not complete within {:?}", deadline);
                all_done = false;
                break;
            }
        }
        let _ = join_thread.join();
    }

    assert!(all_done, "BUG REPRODUCED: Deadlock detected - threads parked on destination table were never unparked because abort path unparks the wrong (source) table's parker");
}
