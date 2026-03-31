/// Bug F1-1: wait() after wait_timeout() mishandles LOCKED_STARVATION state
///
/// When send_timeout/recv_timeout times out:
///   1. wait_timeout() sets signal state to LOCKED_STARVATION via CAS
///   2. Timeout fires, wait_timeout() returns false
///   3. Cancel is attempted but fails (counterpart already popped signal)
///   4. wait() is called to block until counterpart finishes
///   5. BUG: wait() CAS expects LOCKED but state is LOCKED_STARVATION
///      → CAS fails → returns Err(LOCKED_STARVATION) → LOCKED_STARVATION == UNLOCKED → false
///      → wait() returns false (treats it as channel-closed)
///   6. Sender reclaims data and returns, BUT counterpart still has signal pointer
///   7. Counterpart reads from freed signal → use-after-free / data corruption
///
/// Reproduction approach:
///   Level 0 — stress test with many threads and very short timeouts.
///   Level 3 — inject 100ms delay in SyncSignal::read_data (via "repro-f1-1" feature)
///             to make the race deterministic. The sender times out and reclaims data;
///             the receiver reads from freed memory, getting corrupted data.
///
/// When built with --features repro-f1-1:
///   Sender: send_timeout(MAGIC_VALUE, 10ms) on rendezvous channel
///   Receiver: recv() → enters read_data → 100ms delay → reads from freed signal
///   Detection: sender gets data back (timeout/closed) AND receiver gets garbage
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAGIC: u64 = 0xDEAD_BEEF_CAFE_BABE;

fn main() {
    println!("=== Bug F1-1: wait() after wait_timeout() LOCKED_STARVATION race ===\n");

    #[cfg(feature = "repro-f1-1")]
    {
        println!("Mode: Level 3 (delay injected in SyncSignal::read_data)\n");
        run_level3();
        return;
    }

    #[cfg(not(feature = "repro-f1-1"))]
    {
        println!("Mode: Level 0 (stress test, no source modification)\n");
        run_level0();
    }
}

#[cfg(not(feature = "repro-f1-1"))]
fn run_level0() {
    println!("Running stress test with short timeouts under contention...");
    println!("The bug requires receiver delayed >50μs between pop_signal and read_data.\n");

    let iterations = 5;
    let mut any_anomaly = false;

    for round in 0..iterations {
        println!("--- Round {} ---", round + 1);
        let anomaly = stress_test(Duration::from_secs(10));
        if anomaly {
            any_anomaly = true;
            break;
        }
    }

    if any_anomaly {
        println!("\n*** BUG F1-1 CONFIRMED: Anomaly detected ***");
        std::process::exit(0);
    } else {
        println!("\n--- Bug F1-1 NOT triggered after {} rounds (Level 0) ---", iterations);
        println!("The bug is confirmed by code audit but the race window is too narrow");
        println!("for Level 0 stress testing. Run with --features repro-f1-1 for Level 3.\n");
        println!("Code audit evidence:");
        println!("  signal.rs:233 — wait() CAS expects LOCKED, but after wait_timeout()");
        println!("  the state is already LOCKED_STARVATION. CAS fails with");
        println!("  Err(LOCKED_STARVATION=2), returns 2 == UNLOCKED(usize::MAX) = false.");
        println!("  lib.rs:842-861 — send_timeout: wait_timeout→cancel→wait()→false→Err");
        std::process::exit(1);
    }
}

#[cfg(not(feature = "repro-f1-1"))]
fn stress_test(duration: Duration) -> bool {
    let (sender, receiver) = kanal::bounded::<u64>(0);
    let stop = Arc::new(AtomicBool::new(false));
    let anomaly_count = Arc::new(AtomicUsize::new(0));
    let send_timeout_count = Arc::new(AtomicU64::new(0));
    let send_ok_count = Arc::new(AtomicU64::new(0));
    let recv_ok_count = Arc::new(AtomicU64::new(0));

    // Contention threads to cause scheduling delays.
    let num_contention = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(8);
    let mut handles = Vec::new();
    let stop_c = stop.clone();
    for _ in 0..num_contention {
        let s = stop_c.clone();
        handles.push(std::thread::spawn(move || {
            let mut x: u64 = 1;
            while !s.load(Ordering::Relaxed) {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
                std::hint::black_box(x);
            }
        }));
    }

    for tid in 0..4u64 {
        let s = sender.clone();
        let stop_s = stop.clone();
        let anomaly = anomaly_count.clone();
        let timeout_cnt = send_timeout_count.clone();
        let ok_cnt = send_ok_count.clone();
        handles.push(std::thread::spawn(move || {
            let mut seq = (tid + 1) << 48;
            while !stop_s.load(Ordering::Relaxed) {
                seq += 1;
                match s.send_timeout(seq, Duration::from_micros(1)) {
                    Ok(()) => { ok_cnt.fetch_add(1, Ordering::Relaxed); }
                    Err(kanal::SendTimeoutError::Timeout(_)) => {
                        timeout_cnt.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(kanal::SendTimeoutError::Closed(_)) => {
                        if !stop_s.load(Ordering::Relaxed) {
                            anomaly.fetch_add(1, Ordering::Relaxed);
                        }
                        break;
                    }
                }
            }
        }));
    }

    for _ in 0..4 {
        let r = receiver.clone();
        let stop_r = stop.clone();
        let anomaly = anomaly_count.clone();
        let cnt = recv_ok_count.clone();
        handles.push(std::thread::spawn(move || {
            while !stop_r.load(Ordering::Relaxed) {
                match r.recv_timeout(Duration::from_millis(1)) {
                    Ok(val) => {
                        cnt.fetch_add(1, Ordering::Relaxed);
                        if val == 0 { anomaly.fetch_add(1, Ordering::Relaxed); }
                    }
                    Err(_) => {}
                }
            }
        }));
    }

    let start = Instant::now();
    while start.elapsed() < duration {
        std::thread::sleep(Duration::from_millis(100));
        if anomaly_count.load(Ordering::Relaxed) > 0 {
            println!("  Anomaly detected after {:?}!", start.elapsed());
            break;
        }
    }

    stop.store(true, Ordering::Relaxed);
    drop(sender);
    drop(receiver);
    for h in handles { let _ = h.join(); }

    let timeouts = send_timeout_count.load(Ordering::Relaxed);
    let send_ok = send_ok_count.load(Ordering::Relaxed);
    let recv_ok = recv_ok_count.load(Ordering::Relaxed);
    let anomalies = anomaly_count.load(Ordering::Relaxed);

    println!("  send_ok: {}, send_timeout: {}, recv_ok: {}, anomalies: {}",
        send_ok, timeouts, recv_ok, anomalies);
    anomalies > 0
}

#[cfg(feature = "repro-f1-1")]
fn run_level3() {
    // With the "repro-f1-1" feature, SyncSignal::read_data has a 100ms delay
    // injected BEFORE reading data and swapping state. This means:
    //   1. Sender pushes signal to wait_list, calls wait_timeout(10ms)
    //   2. Receiver pops sender's signal, enters read_data, hits 100ms delay
    //   3. Sender times out after 10ms, cancel fails, wait() returns false
    //   4. Sender returns Err with reclaimed data
    //   5. Receiver finishes read_data, reads from freed signal → UAF
    //
    // IMPORTANT: Sender must register BEFORE receiver arrives, so the receiver
    // pops the sender's signal (calling read_data). If receiver goes first, the
    // sender does a direct handoff via write_data (different code path).

    let total_runs = 20;
    let mut sender_got_back = 0u64;
    let mut receiver_got_value = 0u64;
    let mut corrupted = 0u64;
    let mut double_delivery = 0u64;
    let mut closed_anomaly = 0u64;

    for run in 0..total_runs {
        let (sender, receiver) = kanal::bounded::<u64>(0);

        // Sender goes FIRST: spawns a thread that does send_timeout.
        // On rendezvous channel with no waiting receiver, sender pushes signal
        // to wait_list and calls wait_timeout.
        let s = sender.clone();
        let send_handle = std::thread::spawn(move || -> Result<(), kanal::SendTimeoutError<u64>> {
            s.send_timeout(MAGIC, Duration::from_millis(10))
        });

        // Short sleep to let sender register signal in wait_list.
        std::thread::sleep(Duration::from_millis(5));

        // Receiver goes SECOND: it finds sender's signal in wait_list, pops it,
        // and calls SyncSignal::read_data (which has the 100ms delay).
        let r = receiver.clone();
        let recv_handle = std::thread::spawn(move || -> Option<u64> {
            match r.recv() {
                Ok(val) => Some(val),
                Err(_) => None,
            }
        });

        // Wait for both to complete.
        // Sender should return in ~10ms (timeout) + ~50ms (spin in wait()).
        // Receiver should return in ~100ms (delay) + completion.
        let send_result = send_handle.join().unwrap();

        // Give receiver extra time to finish (delay is 100ms).
        std::thread::sleep(Duration::from_millis(200));
        drop(sender);
        drop(receiver);

        let recv_result = recv_handle.join().unwrap();

        match (&send_result, &recv_result) {
            (Ok(()), Some(val)) => {
                // Normal success: sender waited for receiver (unlikely with 100ms delay
                // and 10ms timeout, but possible if read_data delay was less than timeout).
                if *val != MAGIC {
                    corrupted += 1;
                    println!("  Run {}: CORRUPT — sent {:#018x}, received {:#018x}",
                        run, MAGIC, val);
                }
                receiver_got_value += 1;
            }
            (Err(kanal::SendTimeoutError::Timeout(returned_data)), Some(val)) => {
                // Sender timed out BUT receiver also got data → double delivery / UAF
                double_delivery += 1;
                sender_got_back += 1;
                receiver_got_value += 1;
                println!("  Run {}: DOUBLE DELIVERY — sender got timeout (data={:#018x}), receiver got {:#018x}",
                    run, returned_data, val);
                if *val != MAGIC {
                    corrupted += 1;
                    println!("    ALSO CORRUPT — expected {:#018x}", MAGIC);
                }
            }
            (Err(kanal::SendTimeoutError::Closed(returned_data)), Some(val)) => {
                // BUG TRIGGERED: sender thinks channel closed, but receiver got data
                closed_anomaly += 1;
                sender_got_back += 1;
                receiver_got_value += 1;
                println!("  Run {}: BUG — sender got Closed (data={:#018x}), receiver got {:#018x}",
                    run, returned_data, val);
                if *val != MAGIC {
                    corrupted += 1;
                    println!("    ALSO CORRUPT — expected {:#018x}", MAGIC);
                }
            }
            (Err(kanal::SendTimeoutError::Timeout(_)), None) => {
                // Sender timed out, cancel succeeded, receiver found nothing.
                sender_got_back += 1;
            }
            (Err(kanal::SendTimeoutError::Closed(_)), None) => {
                // Sender saw closed, receiver saw nothing.
                closed_anomaly += 1;
                sender_got_back += 1;
                println!("  Run {}: Sender got spurious Closed error (receivers alive)", run);
            }
            (Ok(()), None) => {
                println!("  Run {}: sender Ok but receiver got nothing?", run);
            }
            _ => {
                println!("  Run {}: unexpected: send={:?}, recv={:?}",
                    run, send_result.is_ok(), recv_result);
            }
        }
    }

    println!("\n=== Results ({} runs) ===", total_runs);
    println!("Sender got data back (timeout/closed): {}", sender_got_back);
    println!("Receiver got a value: {}", receiver_got_value);
    println!("Double deliveries: {}", double_delivery);
    println!("Spurious 'Closed' errors: {}", closed_anomaly);
    println!("Data corruptions: {}", corrupted);

    if double_delivery > 0 || corrupted > 0 || closed_anomaly > 0 {
        println!("\n*** BUG F1-1 CONFIRMED (Level 3) ***");
        if double_delivery > 0 {
            println!("  Sender reclaimed data AND receiver got data → use-after-free");
        }
        if closed_anomaly > 0 {
            println!("  wait() returned false due to LOCKED_STARVATION CAS mismatch");
            println!("  → sender interpreted it as channel-closed on live channel");
        }
        if corrupted > 0 {
            println!("  Receiver read corrupted data from freed signal");
        }
        std::process::exit(0);
    } else {
        println!("\nBug not triggered even with Level 3 delay.");
        std::process::exit(1);
    }
}
