//! Trace generation test scenarios for tokio broadcast channel.
//!
//! Run with BROADCAST_TRACE_DIR set to capture per-thread NDJSON trace files.
//! Each test writes to a subdirectory under BROADCAST_TRACE_DIR.

#![cfg(feature = "sync")]

use tokio::sync::broadcast;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

fn setup_trace(scenario: &str) -> String {
    let base = std::env::var("BROADCAST_TRACE_BASE")
        .unwrap_or_else(|_| "/tmp/broadcast_traces".to_string());
    let dir = format!("{}/{}", base, scenario);
    std::fs::create_dir_all(&dir).unwrap();
    // Point trace module to this scenario's directory
    std::env::set_var("BROADCAST_TRACE_DIR", &dir);
    // Re-init trace module for this scenario
    tokio::sync::tla_trace::init();
    dir
}

/// Scenario 1: Basic send/recv — two receivers read two values.
/// Exercises: Subscribe, Send, RecvSuccess, ReceiverDrop, SenderDrop, CloseChannel
#[test]
fn trace_basic_send_recv() {
    let dir = setup_trace("basic_send_recv");

    // Capacity 2 to match Trace.cfg Capacity=2
    let (tx, mut rx1) = broadcast::channel::<String>(2);
    let mut rx2 = tx.subscribe();

    tx.send("v1".to_string()).unwrap();
    tx.send("v2".to_string()).unwrap();

    assert_eq!(rx1.try_recv().unwrap(), "v1");
    assert_eq!(rx1.try_recv().unwrap(), "v2");

    assert_eq!(rx2.try_recv().unwrap(), "v1");
    assert_eq!(rx2.try_recv().unwrap(), "v2");

    drop(rx1);
    drop(rx2);
    drop(tx);

    tokio::sync::tla_trace::flush();
    eprintln!("trace_basic_send_recv: traces in {}", dir);
}

/// Scenario 2: Concurrent send/recv from multiple threads.
/// Exercises overlapping timebox intervals for Category B validation.
#[test]
fn trace_concurrent_send_recv() {
    let dir = setup_trace("concurrent_send_recv");

    let (tx, _) = broadcast::channel::<String>(2);
    let barrier = Arc::new(Barrier::new(3));

    let mut rx1 = tx.subscribe();
    let b1 = barrier.clone();
    let t1 = thread::spawn(move || {
        b1.wait();
        loop {
            match rx1.try_recv() {
                Ok(_) => {}
                Err(broadcast::error::TryRecvError::Empty) => {
                    thread::sleep(Duration::from_micros(10));
                }
                Err(broadcast::error::TryRecvError::Closed) => break,
                Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            }
        }
    });

    let mut rx2 = tx.subscribe();
    let b2 = barrier.clone();
    let t2 = thread::spawn(move || {
        b2.wait();
        loop {
            match rx2.try_recv() {
                Ok(_) => {}
                Err(broadcast::error::TryRecvError::Empty) => {
                    thread::sleep(Duration::from_micros(10));
                }
                Err(broadcast::error::TryRecvError::Closed) => break,
                Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            }
        }
    });

    barrier.wait();
    for i in 0..4 {
        let val = format!("v{}", (i % 2) + 1);
        tx.send(val).unwrap();
        thread::sleep(Duration::from_micros(5));
    }

    drop(tx);
    t1.join().unwrap();
    t2.join().unwrap();

    tokio::sync::tla_trace::flush();
    eprintln!("trace_concurrent_send_recv: traces in {}", dir);
}

/// Scenario 3: Lagged receiver — exercises RecvLagged path.
#[test]
fn trace_lagged_receiver() {
    let dir = setup_trace("lagged_receiver");

    let (tx, mut rx1) = broadcast::channel::<String>(2);
    let mut rx2 = tx.subscribe();

    // Send 4 values into capacity-2 buffer
    tx.send("v1".to_string()).unwrap();
    tx.send("v2".to_string()).unwrap();
    tx.send("v1".to_string()).unwrap();
    tx.send("v2".to_string()).unwrap();

    // rx1 should get Lagged
    match rx1.try_recv() {
        Err(broadcast::error::TryRecvError::Lagged(n)) => {
            eprintln!("rx1 lagged by {}", n);
        }
        other => eprintln!("rx1: {:?}", other),
    }
    let _ = rx1.try_recv();

    // rx2 also lags
    match rx2.try_recv() {
        Err(broadcast::error::TryRecvError::Lagged(n)) => {
            eprintln!("rx2 lagged by {}", n);
        }
        other => eprintln!("rx2: {:?}", other),
    }
    let _ = rx2.try_recv();

    drop(rx1);
    drop(rx2);
    drop(tx);

    tokio::sync::tla_trace::flush();
    eprintln!("trace_lagged_receiver: traces in {}", dir);
}

/// Scenario 4: Close + recv race — exercises RecvClosed, SenderClone, SenderDrop, CloseChannel.
#[test]
fn trace_close_recv_race() {
    let dir = setup_trace("close_recv_race");

    let (tx, mut rx1) = broadcast::channel::<String>(2);
    let tx2 = tx.clone(); // SenderClone

    tx.send("v1".to_string()).unwrap();
    assert_eq!(rx1.try_recv().unwrap(), "v1");

    // Drop first sender (SenderDrop but not last)
    drop(tx);

    // Channel still open, should be empty
    match rx1.try_recv() {
        Err(broadcast::error::TryRecvError::Empty) => {}
        other => eprintln!("Expected empty, got: {:?}", other),
    }

    // Drop last sender -> triggers CloseChannel
    drop(tx2);

    // Now should get Closed
    match rx1.try_recv() {
        Err(broadcast::error::TryRecvError::Closed) => {}
        other => eprintln!("Expected closed, got: {:?}", other),
    }

    drop(rx1);

    tokio::sync::tla_trace::flush();
    eprintln!("trace_close_recv_race: traces in {}", dir);
}
