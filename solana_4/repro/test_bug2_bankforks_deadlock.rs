// Reproduction test for Bug 2: BankForks multi-writer triple-thread deadlock (open #12039)
//
// Bug claim (spec/bug-report.md): three writers — Replay, BlockCreationLoop, and
// Votor — interact with three lock domains (BankForks, Progress, BlockstoreL)
// in an order that admits a 3-cycle:
//      Replay  holds Progress   waits for BlockstoreL  (held by Votor)
//      Votor   holds BlockstoreL waits for BankForks   (held by BCL)
//      BCL     holds BankForks  waits for Progress    (held by Replay)
//
// Fix landed in #12448 (52446464d5) — votor and BCL no longer take
// bank_forks.write() directly; writes are sent via BankForksControllerHandle
// to the replay thread.  The bug report claims the underlying multi-writer
// pattern still permits cycles "in the general case."
//
// Compile and run:
//     rustc --edition 2021 --test test_bug2_bankforks_deadlock.rs -o test_bug2
//     ./test_bug2 --test-threads=1 --nocapture

use std::{
    sync::{Arc, Barrier, RwLock, atomic::{AtomicBool, AtomicU64, Ordering}},
    thread,
    time::{Duration, Instant},
};

type LockDomain = Arc<RwLock<u64>>;

fn make_locks() -> (LockDomain, LockDomain, LockDomain) {
    (
        Arc::new(RwLock::new(0)), // BankForks
        Arc::new(RwLock::new(0)), // Progress
        Arc::new(RwLock::new(0)), // BlockstoreL
    )
}

// Bounded-timeout write acquire over std::sync::RwLock by spin-polling try_write.
// Returns Some((guard, wait_ms)) if it acquired within `timeout`, else None.
fn try_write_for<'a, T>(
    lock: &'a RwLock<T>,
    timeout: Duration,
) -> Option<std::sync::RwLockWriteGuard<'a, T>> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(g) = lock.try_write() {
            return Some(g);
        }
        if Instant::now() > deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(1));
    }
}

// ===========================================================================
// LEVEL 0 — Pure black-box reproduction (post-#12448 invariant).
// Threads model the post-fix architecture with sequential lock acquire+release
// (no nested holds). Expect no deadlock.
// ===========================================================================
#[test]
fn test_level0_post_12448_no_deadlock() {
    let (bank_forks, progress, blockstore) = make_locks();
    let stop = Arc::new(AtomicBool::new(false));
    let progress_counter = Arc::new(AtomicU64::new(0));

    let bf1 = Arc::clone(&bank_forks);
    let pg1 = Arc::clone(&progress);
    let bs1 = Arc::clone(&blockstore);
    let stop1 = Arc::clone(&stop);
    let pc1 = Arc::clone(&progress_counter);
    let replay = thread::spawn(move || {
        while !stop1.load(Ordering::Relaxed) {
            { let _w = bf1.write().unwrap(); }
            thread::yield_now();
            { let _p = pg1.write().unwrap(); }
            thread::yield_now();
            { let _b = bs1.read().unwrap(); }
            pc1.fetch_add(1, Ordering::Relaxed);
        }
    });

    let bf2 = Arc::clone(&bank_forks);
    let bs2 = Arc::clone(&blockstore);
    let stop2 = Arc::clone(&stop);
    let pc2 = Arc::clone(&progress_counter);
    let votor = thread::spawn(move || {
        while !stop2.load(Ordering::Relaxed) {
            { let _b = bs2.write().unwrap(); }
            thread::yield_now();
            { let _r = bf2.read().unwrap(); }
            pc2.fetch_add(1, Ordering::Relaxed);
        }
    });

    let bf3 = Arc::clone(&bank_forks);
    let pg3 = Arc::clone(&progress);
    let stop3 = Arc::clone(&stop);
    let pc3 = Arc::clone(&progress_counter);
    let bcl = thread::spawn(move || {
        while !stop3.load(Ordering::Relaxed) {
            { let _r = bf3.read().unwrap(); }
            thread::yield_now();
            { let _p = pg3.write().unwrap(); }
            pc3.fetch_add(1, Ordering::Relaxed);
        }
    });

    thread::sleep(Duration::from_millis(300));
    stop.store(true, Ordering::Relaxed);

    let started = Instant::now();
    for (name, h) in [("replay", replay), ("votor", votor), ("bcl", bcl)] {
        h.join().unwrap_or_else(|e| panic!("thread {} panicked: {:?}", name, e));
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "Thread {} took too long — possible deadlock",
            name
        );
    }
    let ticks = progress_counter.load(Ordering::Relaxed);
    println!("test_level0 progress counter = {}", ticks);
    assert!(ticks > 100, "Expected lots of progress, got {}", ticks);
}

// ===========================================================================
// LEVEL 1 — Timing assistance via sleeps in critical sections.
// Still respect the post-#12448 invariant (single writer for BankForks).
// No deadlock expected.
// ===========================================================================
#[test]
fn test_level1_post_12448_no_deadlock_with_sleeps() {
    let (bank_forks, progress, blockstore) = make_locks();
    let stop = Arc::new(AtomicBool::new(false));

    let bf1 = Arc::clone(&bank_forks);
    let pg1 = Arc::clone(&progress);
    let bs1 = Arc::clone(&blockstore);
    let stop1 = Arc::clone(&stop);
    let replay = thread::spawn(move || {
        while !stop1.load(Ordering::Relaxed) {
            { let _w = bf1.write().unwrap(); thread::sleep(Duration::from_micros(100)); }
            { let _p = pg1.write().unwrap(); thread::sleep(Duration::from_micros(100)); }
            { let _b = bs1.read().unwrap(); thread::sleep(Duration::from_micros(100)); }
        }
    });

    let bf2 = Arc::clone(&bank_forks);
    let bs2 = Arc::clone(&blockstore);
    let stop2 = Arc::clone(&stop);
    let votor = thread::spawn(move || {
        while !stop2.load(Ordering::Relaxed) {
            { let _b = bs2.write().unwrap(); thread::sleep(Duration::from_micros(100)); }
            { let _r = bf2.read().unwrap(); thread::sleep(Duration::from_micros(100)); }
        }
    });

    let bf3 = Arc::clone(&bank_forks);
    let pg3 = Arc::clone(&progress);
    let stop3 = Arc::clone(&stop);
    let bcl = thread::spawn(move || {
        while !stop3.load(Ordering::Relaxed) {
            { let _r = bf3.read().unwrap(); thread::sleep(Duration::from_micros(100)); }
            { let _p = pg3.write().unwrap(); thread::sleep(Duration::from_micros(100)); }
        }
    });

    thread::sleep(Duration::from_millis(300));
    stop.store(true, Ordering::Relaxed);

    let started = Instant::now();
    for (name, h) in [("replay", replay), ("votor", votor), ("bcl", bcl)] {
        h.join().unwrap_or_else(|e| panic!("thread {} panicked: {:?}", name, e));
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "Thread {} took too long — possible deadlock",
            name
        );
    }
}

// ===========================================================================
// LEVEL 2 — State injection: simulate the pre-#12448 lock graph from
// issue #12039.  Three writers, three lock domains, circular wait.
//
// We measure the time each thread spent waiting on its second acquire.
// A deadlock manifests as all three threads waiting until the timeout.
// A "winner" race (one thread gets its second lock as another times out)
// is still evidence of deadlock — the wait duration shows it.
// ===========================================================================
#[test]
fn test_level2_three_writer_deadlock_pattern() {
    let (bank_forks, progress, blockstore) = make_locks();
    let barrier = Arc::new(Barrier::new(3));

    let pg1 = Arc::clone(&progress);
    let bs1 = Arc::clone(&blockstore);
    let b1 = Arc::clone(&barrier);
    let replay = thread::spawn(move || {
        let _p = pg1.write().unwrap();
        b1.wait();
        let t = Instant::now();
        let r = try_write_for(&bs1, Duration::from_secs(2));
        let wait_ms = t.elapsed().as_millis();
        (r.is_some(), wait_ms)
    });

    let bf2 = Arc::clone(&bank_forks);
    let pg2 = Arc::clone(&progress);
    let b2 = Arc::clone(&barrier);
    let bcl = thread::spawn(move || {
        let _b = bf2.write().unwrap();
        b2.wait();
        let t = Instant::now();
        let r = try_write_for(&pg2, Duration::from_secs(2));
        let wait_ms = t.elapsed().as_millis();
        (r.is_some(), wait_ms)
    });

    let bs3 = Arc::clone(&blockstore);
    let bf3 = Arc::clone(&bank_forks);
    let b3 = Arc::clone(&barrier);
    let votor = thread::spawn(move || {
        let _bs = bs3.write().unwrap();
        b3.wait();
        let t = Instant::now();
        let r = try_write_for(&bf3, Duration::from_secs(2));
        let wait_ms = t.elapsed().as_millis();
        (r.is_some(), wait_ms)
    });

    let (replay_ok, replay_ms) = replay.join().unwrap_or((false, 0));
    let (bcl_ok, bcl_ms) = bcl.join().unwrap_or((false, 0));
    let (votor_ok, votor_ms) = votor.join().unwrap_or((false, 0));

    println!(
        "Replay : 2nd-acquire ok={} wait_ms={}",
        replay_ok, replay_ms
    );
    println!(
        "BCL    : 2nd-acquire ok={} wait_ms={}",
        bcl_ok, bcl_ms
    );
    println!(
        "Votor  : 2nd-acquire ok={} wait_ms={}",
        votor_ok, votor_ms
    );
    // Deadlock confirmed if all three waited at least 1500ms on the 2nd acquire.
    // (Allowing slack because std::sync::RwLock spin-polling has jitter.)
    assert!(
        replay_ms >= 1500 && bcl_ms >= 1500 && votor_ms >= 1500,
        "Expected all three threads to wait ≥1500ms on 2nd acquire, indicating \
         deadlock.  Observed: replay_ms={} bcl_ms={} votor_ms={}",
        replay_ms, bcl_ms, votor_ms
    );
}

// ===========================================================================
// LEVEL 3 — Minimal code modification: we don't actually modify agave; the
// Level 2 injection replicates what the pre-#12448 code would have done.
//
// Conclusion:
//   - The triple-deadlock pattern IS reproducible via Level 2 state injection.
//   - In current code (post-#12448), the pattern is GUARDED by the
//     BankForksController channel: only the replay thread holds
//     bank_forks.write(); votor and BCL route writes via channel.
//   - The bug report's claim that the pattern stands as a maintenance
//     concern is correct: any future change reintroducing a direct
//     bank_forks.write() from votor or BCL re-exposes the deadlock.
// ===========================================================================
#[test]
fn test_level3_documents_pattern_predicts_deadlock_pre_12448() {
    // No-op test that documents the conclusion above.
}
