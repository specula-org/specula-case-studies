//! Trace generation test scenarios for left-right.
//!
//! Runs as `cargo test --test trace_tests`. Each test sets `LEFTRIGHT_TRACE_DIR`
//! to a per-scenario subdirectory and emits per-thread NDJSON files. The
//! `Reader = {"r1", "r2"}` constraint from `Trace.cfg` means each scenario
//! must spawn exactly two reader threads named `r1` and `r2`.

use left_right::{Absorb, ReadHandle, WriteHandle};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

#[derive(Debug)]
struct CounterAddOp(i32);

impl Absorb<CounterAddOp> for i32 {
    fn absorb_first(&mut self, op: &mut CounterAddOp, _: &Self) {
        *self += op.0;
    }

    fn absorb_second(&mut self, op: CounterAddOp, _: &Self) {
        *self += op.0;
    }

    fn drop_first(self: Box<Self>) {}

    fn sync_with(&mut self, first: &Self) {
        *self = *first
    }
}

fn setup_trace(scenario: &str) -> String {
    let base = std::env::var("LEFTRIGHT_TRACE_BASE")
        .unwrap_or_else(|_| "/tmp/leftright_traces".to_string());
    let dir = format!("{}/{}", base, scenario);
    std::fs::create_dir_all(&dir).unwrap();
    std::env::set_var("LEFTRIGHT_TRACE_DIR", &dir);
    left_right::tla_trace::init();
    dir
}

fn install_pointers(w: &WriteHandle<i32, CounterAddOp>, r: &ReadHandle<i32>) {
    // After construction:
    //   r.inner points to the L copy (the read pointer)
    //   w.w_handle points to the R copy (the write copy)
    let l_addr = r._tla_trace_inner_addr();
    let r_addr = w._tla_trace_w_handle_addr();
    left_right::tla_trace::set_pointer_mapping(l_addr, r_addr);
}

/// Scenario 1: sequential — single thread does writer ops, then readers see null pointer.
/// Exercises: WriterAppend, WriterPublish, ReaderEnterNone, WriterTakeInner.
#[test]
fn trace_sequential() {
    let dir = setup_trace("sequential");

    let (mut w, r) = left_right::new_from_empty::<i32, CounterAddOp>(0);
    install_pointers(&w, &r);

    let r1 = r.clone();
    let r2 = r.clone();
    drop(r);

    let wh = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("writer");
        w.append(CounterAddOp(1));
        w.publish();
        w.append(CounterAddOp(2));
        w.publish();
        w.append(CounterAddOp(3));
        w.publish();
        left_right::tla_trace::flush();
        // dropping w triggers take_inner -> WriterTakeInner
    });
    wh.join().unwrap();

    let h1 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r1");
        let g = r1.enter();
        assert!(g.is_none());
        left_right::tla_trace::flush();
    });
    let h2 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r2");
        let g = r2.enter();
        assert!(g.is_none());
        left_right::tla_trace::flush();
    });
    h1.join().unwrap();
    h2.join().unwrap();

    eprintln!("trace_sequential: traces in {}", dir);
}

/// Scenario 2: concurrent reads + writes.  r1 holds a slow guard while writer
/// publishes to force the writer's wait() to spin, producing a long-interval
/// WriterPublish that overlaps with r2's tight enter/exit loop.
#[test]
fn trace_slow_reader_overlap() {
    let dir = setup_trace("slow_reader_overlap");

    let (mut w, r) = left_right::new_from_empty::<i32, CounterAddOp>(0);
    install_pointers(&w, &r);

    let r1 = r.clone();
    let r2 = r.clone();
    drop(r);

    // Pre-publish on the writer thread so subsequent publishes are in
    // first=false mode (they actually wait for readers).
    let barrier = Arc::new(Barrier::new(3));
    let b_w = barrier.clone();
    let b_r1 = barrier.clone();
    let b_r2 = barrier.clone();

    let wh = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("writer");
        // Two priming publishes so first=false and lastEpochs reflects current
        // (odd) reader epochs after r1 enters.
        w.append(CounterAddOp(1));
        w.publish();
        w.append(CounterAddOp(2));
        w.publish();
        b_w.wait();
        // Give r1 time to enter and start holding.
        thread::sleep(Duration::from_millis(2));
        // First publish after r1 enters: lastEpochs[r1] is even, so wait skips.
        // But it snapshots lastEpochs[r1] = 1 (odd).
        w.append(CounterAddOp(3));
        w.publish();
        // Second publish: lastEpochs[r1] is odd, epoch[r1] still equals it,
        // so wait() spins. This produces a long-interval WriterPublish event.
        w.append(CounterAddOp(4));
        w.publish();
        // Final publishes after r1 releases.
        w.append(CounterAddOp(5));
        w.publish();
        left_right::tla_trace::flush();
        // drop w -> take_inner
    });

    let h1 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r1");
        b_r1.wait();
        // Hold a single guard for ~50ms, forcing the writer's second publish
        // to spin in wait().
        if let Some(g) = r1.enter() {
            thread::sleep(Duration::from_millis(50));
            drop(g);
        }
        left_right::tla_trace::flush();
    });

    let h2 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r2");
        b_r2.wait();
        // Tight enter/exit loop while writer is potentially blocked, producing
        // many short events that overlap with the long WriterPublish interval.
        for _ in 0..30 {
            if let Some(g) = r2.enter() {
                drop(g);
            }
            thread::sleep(Duration::from_micros(100));
        }
        left_right::tla_trace::flush();
    });

    wh.join().unwrap();
    h1.join().unwrap();
    h2.join().unwrap();

    eprintln!("trace_slow_reader_overlap: traces in {}", dir);
}

/// Scenario 3: nested reader enters — r1 takes a nested guard while writer is
/// still active.  Exercises ReaderEnterNested plus normal flow.
#[test]
fn trace_nested_enters() {
    let dir = setup_trace("nested_enters");

    let (mut w, r) = left_right::new_from_empty::<i32, CounterAddOp>(0);
    install_pointers(&w, &r);

    let r1 = r.clone();
    let r2 = r.clone();
    drop(r);

    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let done_w = done.clone();
    let done_r2 = done.clone();

    // Writer thread keeps the WriteHandle alive while readers nest.
    let (start_tx, start_rx) = std::sync::mpsc::channel::<()>();
    let wh = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("writer");
        w.append(CounterAddOp(10));
        w.publish();
        w.append(CounterAddOp(20));
        w.publish();
        // Signal readers to start their nested-enter sequence.
        start_tx.send(()).unwrap();
        // Idle so the WriteHandle stays alive; readers will signal done.
        while !done_w.load(std::sync::atomic::Ordering::Acquire) {
            thread::sleep(Duration::from_millis(1));
        }
        // One more publish so we observe writer state changes.
        w.append(CounterAddOp(30));
        w.publish();
        left_right::tla_trace::flush();
        // drop w -> take_inner
    });

    let h1 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r1");
        // wait for writer to publish
        start_rx.recv().unwrap();
        // Nested enter: g1 -> g2 (nested) -> drop g2 -> drop g1.
        if let Some(g1) = r1.enter() {
            if let Some(g2) = r1.enter() {
                drop(g2);
            }
            drop(g1);
        }
        // Allow writer to proceed.
        done.store(true, std::sync::atomic::Ordering::Release);
        left_right::tla_trace::flush();
    });

    let h2 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r2");
        // r2 does normal enter/exit a couple of times during writer's life.
        for _ in 0..3 {
            if let Some(g) = r2.enter() {
                drop(g);
            }
            thread::sleep(Duration::from_micros(200));
            if done_r2.load(std::sync::atomic::Ordering::Acquire) {
                break;
            }
        }
        left_right::tla_trace::flush();
    });

    wh.join().unwrap();
    h1.join().unwrap();
    h2.join().unwrap();

    eprintln!("trace_nested_enters: traces in {}", dir);
}

/// Scenario 4: try_publish — exercise both success path and the failure path
/// (reader holding a guard at the time of try_publish).
#[test]
fn trace_try_publish() {
    let dir = setup_trace("try_publish");

    let (mut w, r) = left_right::new_from_empty::<i32, CounterAddOp>(0);
    install_pointers(&w, &r);

    let r1 = r.clone();
    let r2 = r.clone();
    drop(r);

    let barrier = Arc::new(Barrier::new(3));
    let b_w = barrier.clone();
    let b_r1 = barrier.clone();
    let b_r2 = barrier.clone();

    let wh = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("writer");
        // Prime: first publish so first=false; second publish so lastEpochs
        // reflects post-publish state.
        w.append(CounterAddOp(1));
        w.publish();
        b_w.wait();
        // Give r1 time to enter and hold; lastEpochs[r1] is even from the
        // previous snapshot, so the first try_publish below succeeds and
        // makes lastEpochs[r1] odd.  The second try_publish then sees an
        // unchanged odd lastEpoch and returns false.
        thread::sleep(Duration::from_millis(2));
        w.append(CounterAddOp(2));
        let _ = w.try_publish();
        thread::sleep(Duration::from_millis(2));
        w.append(CounterAddOp(3));
        let _ = w.try_publish();
        // Wait for r1 to release, then a publish that succeeds.
        thread::sleep(Duration::from_millis(60));
        w.append(CounterAddOp(4));
        let _ = w.try_publish();
        left_right::tla_trace::flush();
    });

    let h1 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r1");
        b_r1.wait();
        if let Some(g) = r1.enter() {
            thread::sleep(Duration::from_millis(40));
            drop(g);
        }
        left_right::tla_trace::flush();
    });
    let h2 = thread::spawn(move || {
        left_right::tla_trace::set_thread_name("r2");
        b_r2.wait();
        // Quick reads without holding.
        for _ in 0..5 {
            if let Some(g) = r2.enter() {
                drop(g);
            }
            thread::sleep(Duration::from_micros(500));
        }
        left_right::tla_trace::flush();
    });

    wh.join().unwrap();
    h1.join().unwrap();
    h2.join().unwrap();

    eprintln!("trace_try_publish: traces in {}", dir);
}
