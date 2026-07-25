//! Test scenarios for TLA+ trace generation.
//!
//! Each test exercises a specific set of kanal code paths to produce
//! NDJSON traces. Set KANAL_TRACE_DIR to enable tracing.
//!
//! Scenarios:
//! 1. basic_send_recv: buffered send + recv from queue (2 threads, bounded(1))
//! 2. direct_handoff: rendezvous channel send/recv handoff (2 threads, bounded(0))
//! 3. close_protocol: sender/receiver drop triggering close (3 threads)
//! 4. contention: concurrent senders + receivers with blocking (3 threads, bounded(1))

use kanal::bounded;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

/// Test 1: Basic buffered send and recv.
/// Exercises: send_to_queue, recv_from_queue, clone_sender, clone_receiver,
///            drop_sender, drop_receiver, thread_reset
#[test]
fn trace_basic_send_recv() {
    kanal::tla_trace::init();
    let (tx, rx) = bounded::<u64>(1);

    let barrier = Arc::new(Barrier::new(2));

    let b = barrier.clone();
    let tx2 = tx.clone(); // clone_sender
    let t_send = thread::spawn(move || {
        b.wait();
        tx2.send(1u64).unwrap(); // send_to_queue (queue empty, cap=1)
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        tx2.send(2u64).unwrap(); // may block or queue depending on timing
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        // tx2 dropped here -> drop_sender
    });

    let b = barrier.clone();
    let rx2 = rx.clone(); // clone_receiver
    let t_recv = thread::spawn(move || {
        b.wait();
        // Small delay to let sender queue first item
        thread::sleep(Duration::from_millis(1));
        let v1 = rx2.recv().unwrap(); // recv_from_queue
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        let v2 = rx2.recv().unwrap();
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        assert!(v1 == 1 || v1 == 2);
        assert!(v2 == 1 || v2 == 2);
        // rx2 dropped here -> drop_receiver
    });

    t_send.join().unwrap();
    t_recv.join().unwrap();

    // Original tx, rx dropped here -> drop_sender, drop_receiver
    drop(tx);
    drop(rx);

    kanal::tla_trace::flush();
}

/// Test 2: Rendezvous (zero-capacity) direct handoff.
/// Exercises: send_direct_handoff, recv_direct_handoff, send_block, recv_block,
///            signal_write_data, thread_reset
#[test]
fn trace_direct_handoff() {
    kanal::tla_trace::init();
    let (tx, rx) = bounded::<u64>(0);

    let barrier = Arc::new(Barrier::new(2));

    let b = barrier.clone();
    let t_send = thread::spawn(move || {
        b.wait();
        // Zero-capacity: sender blocks until receiver arrives
        tx.send(1u64).unwrap(); // send_block -> (wait) -> signal resolved
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        tx.send(2u64).unwrap();
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
    });

    let b = barrier.clone();
    let t_recv = thread::spawn(move || {
        b.wait();
        // Small delay to ensure sender blocks first
        thread::sleep(Duration::from_millis(2));
        let v = rx.recv().unwrap(); // recv_direct_handoff (sender is waiting)
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        assert_eq!(v, 1);
        thread::sleep(Duration::from_millis(2));
        let v = rx.recv().unwrap();
        kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        assert_eq!(v, 2);
    });

    t_send.join().unwrap();
    t_recv.join().unwrap();
    kanal::tla_trace::flush();
}

/// Test 3: Close protocol - senders/receivers drop, channel closes.
/// Exercises: send_closed, recv_closed, drop_sender, drop_receiver,
///            clone_sender, clone_receiver, close
#[test]
fn trace_close_protocol() {
    kanal::tla_trace::init();
    let (tx, rx) = bounded::<u64>(1);

    // Clone to get extra handles
    let tx2 = tx.clone(); // clone_sender
    let rx2 = rx.clone(); // clone_receiver

    // Send one item
    tx.send(1u64).unwrap();
    kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());

    // Drop all senders
    drop(tx);  // drop_sender (send_count: 2 -> 1)
    drop(tx2); // drop_sender (send_count: 1 -> 0, terminates signals)

    // Receiver should still get the queued item
    let v = rx.recv().unwrap();
    kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
    assert_eq!(v, 1);

    // Next recv should get closed error
    let err = rx.recv();
    assert!(err.is_err()); // recv_closed

    drop(rx);  // drop_receiver
    drop(rx2); // drop_receiver

    kanal::tla_trace::flush();
}

/// Test 4: Contention - multiple threads competing for bounded channel.
/// Exercises: send_to_queue, send_block, send_direct_handoff,
///            recv_from_queue, recv_direct_handoff,
///            thread_reset (concurrent overlapping intervals)
#[test]
fn trace_contention() {
    kanal::tla_trace::init();
    let (tx, rx) = bounded::<u64>(1);

    let barrier = Arc::new(Barrier::new(3));

    // Sender thread 1
    let b = barrier.clone();
    let tx1 = tx.clone();
    let t1 = thread::spawn(move || {
        b.wait();
        for i in 0..4u64 {
            let _ = tx1.send(i + 1);
            kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        }
    });

    // Sender thread 2
    let b = barrier.clone();
    let tx2 = tx.clone();
    let t2 = thread::spawn(move || {
        b.wait();
        for i in 0..4u64 {
            let _ = tx2.send(i + 10);
            kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        }
    });

    // Receiver thread: uses recv() (instrumented) instead of recv_timeout
    let b = barrier.clone();
    let rx1 = rx.clone();
    let t3 = thread::spawn(move || {
        b.wait();
        for _ in 0..8 {
            let _ = rx1.recv();
            kanal::tla_trace::emit_simple_event("thread_reset", kanal::tla_trace::ts_start());
        }
    });

    t1.join().unwrap();
    t2.join().unwrap();
    t3.join().unwrap();

    drop(tx);
    drop(rx);

    kanal::tla_trace::flush();
}
