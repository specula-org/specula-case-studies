//! TLA+ trace scenarios for left-right specification.
//!
//! Generates per-thread NDJSON files with timebox timestamps for Category B trace validation.
//! Run with: TLA_TRACE_DIR=<dir> cargo test --test tla_scenarios -- --test-threads=1

use left_right::Absorb;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::ptr::NonNull;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

// ============================================================
// Operation type for testing
// ============================================================

#[derive(Debug)]
struct Op(i32);

impl Absorb<Op> for i32 {
    fn absorb_first(&mut self, operation: &mut Op, _: &Self) {
        *self += operation.0;
    }
    fn absorb_second(&mut self, operation: Op, _: &Self) {
        *self += operation.0;
    }
    fn drop_first(self: Box<Self>) {}
    fn sync_with(&mut self, first: &Self) {
        *self = *first;
    }
}

// ============================================================
// Trace infrastructure
// ============================================================

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64
}

struct TraceWriter {
    file: BufWriter<File>,
    thread_id: String,
}

impl TraceWriter {
    fn new(dir: &str, thread_id: &str) -> Self {
        let path = format!("{}/trace-{}.ndjson", dir, thread_id);
        let file = File::create(&path).expect("Failed to open trace file");
        Self {
            file: BufWriter::new(file),
            thread_id: thread_id.to_string(),
        }
    }

    fn emit_reader(&mut self, event: &str, start: u64, end: u64, epoch: usize, enters: usize) {
        writeln!(
            self.file,
            r#"{{"tag":"trace","event":"{}","thread":"{}","start":{},"end":{},"state":{{"epoch":{},"enters":{}}}}}"#,
            event, self.thread_id, start, end, epoch, enters
        ).unwrap();
    }

    fn emit_writer_append(
        &mut self, start: u64, end: u64,
        copy_l: i32, copy_r: i32, first: bool, total_ops: i32,
    ) {
        writeln!(
            self.file,
            r#"{{"tag":"trace","event":"WriterAppend","thread":"writer","start":{},"end":{},"state":{{"copyL":{},"copyR":{},"first":{},"totalOps":{}}}}}"#,
            start, end, copy_l, copy_r, first, total_ops
        ).unwrap();
    }

    fn emit_writer_publish(
        &mut self, start: u64, end: u64,
        pointer: &str, copy_l: i32, copy_r: i32,
        first: bool, second: bool, total_ops: i32,
    ) {
        writeln!(
            self.file,
            r#"{{"tag":"trace","event":"WriterPublish","thread":"writer","start":{},"end":{},"state":{{"pointer":"{}","copyL":{},"copyR":{},"first":{},"second":{},"totalOps":{}}}}}"#,
            start, end, pointer, copy_l, copy_r, first, second, total_ops
        ).unwrap();
    }

    fn flush(&mut self) {
        self.file.flush().unwrap();
    }
}

/// Tracks which raw pointer address is "L" (initial reader copy) and "R" (initial writer copy).
struct CopyTracker {
    left_addr: usize,
    right_addr: usize,
}

impl CopyTracker {
    fn new(reader_ptr: NonNull<i32>, writer_ptr: NonNull<i32>) -> Self {
        Self {
            left_addr: reader_ptr.as_ptr() as usize,
            right_addr: writer_ptr.as_ptr() as usize,
        }
    }

    fn pointer_name(&self, ptr: Option<NonNull<i32>>) -> &str {
        match ptr {
            Some(p) => {
                let addr = p.as_ptr() as usize;
                if addr == self.left_addr { "L" }
                else if addr == self.right_addr { "R" }
                else { panic!("unknown pointer: 0x{:x}", addr) }
            }
            None => "null",
        }
    }

    fn copy_l(&self) -> i32 { unsafe { *(self.left_addr as *const i32) } }
    fn copy_r(&self) -> i32 { unsafe { *(self.right_addr as *const i32) } }
}

fn trace_dir(scenario: &str) -> String {
    let base = std::env::var("TLA_TRACE_DIR")
        .unwrap_or_else(|_| "../traces".to_string());
    let dir = format!("{}/{}", base, scenario);
    fs::create_dir_all(&dir).expect("create trace dir");
    dir
}

// ============================================================
// Scenario 1: Basic sequential publish cycle
// Writer: 3 append+publish cycles
// Reader r1: enter+exit after each publish (sequential via channels)
// ============================================================

#[test]
fn tla_basic_publish() {
    let dir = trace_dir("basic_publish");
    let (mut w, r) = left_right::new_from_empty::<i32, Op>(0);
    let copies = CopyTracker::new(r.raw_handle().unwrap(), w.raw_write_handle());
    let mut wt = TraceWriter::new(&dir, "writer");
    let mut total_ops: i32 = 0;

    // Channel-based sequential coordination with reader thread
    let (tx_cmd, rx_cmd) = std::sync::mpsc::channel::<&str>();
    let (tx_ack, rx_ack) = std::sync::mpsc::channel::<()>();

    let reader_thread = {
        let r = r.clone(); // Registers a new epoch slot (always idle on main r)
        let dir = dir.clone();
        thread::spawn(move || {
            let mut rt = TraceWriter::new(&dir, "r1");
            while let Ok(cmd) = rx_cmd.recv() {
                if cmd == "done" { break; }
                // "enter_exit" command: do one enter + exit cycle
                let t1 = now_ns();
                let guard = r.enter().unwrap();
                let t2 = now_ns();
                rt.emit_reader("ReaderEnter", t1, t2, r.trace_epoch(), r.trace_enters());

                let _val = *guard; // read value

                let t1 = now_ns();
                drop(guard);
                let t2 = now_ns();
                rt.emit_reader("ReaderExit", t1, t2, r.trace_epoch(), r.trace_enters());

                tx_ack.send(()).unwrap();
            }
            rt.flush();
        })
    };

    // --- Cycle 1: first publish (first=true) ---
    let t1 = now_ns();
    w.append(Op(1));
    let t2 = now_ns();
    total_ops += 1;
    wt.emit_writer_append(t1, t2, copies.copy_l(), copies.copy_r(), true, total_ops);

    let t1 = now_ns();
    w.publish();
    let t2 = now_ns();
    wt.emit_writer_publish(
        t1, t2, copies.pointer_name(r.raw_handle()),
        copies.copy_l(), copies.copy_r(),
        w.trace_first(), w.trace_second(), total_ops,
    );

    tx_cmd.send("enter_exit").unwrap();
    rx_ack.recv().unwrap();

    // --- Cycle 2: normal publish (first=false, second=true→false) ---
    let t1 = now_ns();
    w.append(Op(1));
    let t2 = now_ns();
    total_ops += 1;
    wt.emit_writer_append(t1, t2, copies.copy_l(), copies.copy_r(), w.trace_first(), total_ops);

    let t1 = now_ns();
    w.publish();
    let t2 = now_ns();
    wt.emit_writer_publish(
        t1, t2, copies.pointer_name(r.raw_handle()),
        copies.copy_l(), copies.copy_r(),
        w.trace_first(), w.trace_second(), total_ops,
    );

    tx_cmd.send("enter_exit").unwrap();
    rx_ack.recv().unwrap();

    // --- Cycle 3: normal publish (second=false) ---
    let t1 = now_ns();
    w.append(Op(1));
    let t2 = now_ns();
    total_ops += 1;
    wt.emit_writer_append(t1, t2, copies.copy_l(), copies.copy_r(), w.trace_first(), total_ops);

    let t1 = now_ns();
    w.publish();
    let t2 = now_ns();
    wt.emit_writer_publish(
        t1, t2, copies.pointer_name(r.raw_handle()),
        copies.copy_l(), copies.copy_r(),
        w.trace_first(), w.trace_second(), total_ops,
    );

    tx_cmd.send("enter_exit").unwrap();
    rx_ack.recv().unwrap();

    tx_cmd.send("done").unwrap();
    reader_thread.join().unwrap();
    wt.flush();
}

// ============================================================
// Scenario 2: Concurrent read/write
// Writer: 1 initial append+publish (first=true), then 3 concurrent append+publish cycles
// Reader r1, r2: enter+exit loops running concurrently with writer
// ============================================================

#[test]
fn tla_concurrent_rw() {
    let dir = trace_dir("concurrent_rw");
    let (mut w, r) = left_right::new_from_empty::<i32, Op>(0);
    let copies = Arc::new(CopyTracker::new(r.raw_handle().unwrap(), w.raw_write_handle()));
    let mut total_ops: i32 = 0;

    let mut wt = TraceWriter::new(&dir, "writer");

    // --- Initial publish (first=true, no readers yet) ---
    let t1 = now_ns();
    w.append(Op(1));
    let t2 = now_ns();
    total_ops += 1;
    wt.emit_writer_append(t1, t2, copies.copy_l(), copies.copy_r(), true, total_ops);

    let t1 = now_ns();
    w.publish();
    let t2 = now_ns();
    wt.emit_writer_publish(
        t1, t2, copies.pointer_name(r.raw_handle()),
        copies.copy_l(), copies.copy_r(),
        w.trace_first(), w.trace_second(), total_ops,
    );

    // --- Concurrent phase ---
    let barrier = Arc::new(Barrier::new(3));
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));

    // Spawn reader r1
    let r1_handle = {
        let r = r.clone();
        let barrier = barrier.clone();
        let done = done.clone();
        let dir = dir.clone();
        thread::spawn(move || {
            let mut rt = TraceWriter::new(&dir, "r1");
            barrier.wait();
            for _ in 0..5 {
                if done.load(std::sync::atomic::Ordering::Relaxed) { break; }
                let t1 = now_ns();
                if let Some(guard) = r.enter() {
                    let t2 = now_ns();
                    rt.emit_reader("ReaderEnter", t1, t2, r.trace_epoch(), r.trace_enters());

                    let _val = *guard;
                    thread::yield_now(); // encourage overlap

                    let t1 = now_ns();
                    drop(guard);
                    let t2 = now_ns();
                    rt.emit_reader("ReaderExit", t1, t2, r.trace_epoch(), r.trace_enters());
                } else {
                    break;
                }
                thread::yield_now();
            }
            rt.flush();
        })
    };

    // Spawn reader r2
    let r2_handle = {
        let r = r.clone();
        let barrier = barrier.clone();
        let done = done.clone();
        let dir = dir.clone();
        thread::spawn(move || {
            let mut rt = TraceWriter::new(&dir, "r2");
            barrier.wait();
            for _ in 0..5 {
                if done.load(std::sync::atomic::Ordering::Relaxed) { break; }
                let t1 = now_ns();
                if let Some(guard) = r.enter() {
                    let t2 = now_ns();
                    rt.emit_reader("ReaderEnter", t1, t2, r.trace_epoch(), r.trace_enters());

                    let _val = *guard;
                    thread::yield_now();

                    let t1 = now_ns();
                    drop(guard);
                    let t2 = now_ns();
                    rt.emit_reader("ReaderExit", t1, t2, r.trace_epoch(), r.trace_enters());
                } else {
                    break;
                }
                thread::yield_now();
            }
            rt.flush();
        })
    };

    // Writer: concurrent append+publish cycles
    barrier.wait();
    for _ in 0..3 {
        let t1 = now_ns();
        w.append(Op(1));
        let t2 = now_ns();
        total_ops += 1;
        wt.emit_writer_append(t1, t2, copies.copy_l(), copies.copy_r(), w.trace_first(), total_ops);

        let t1 = now_ns();
        w.publish();
        let t2 = now_ns();
        wt.emit_writer_publish(
            t1, t2, copies.pointer_name(r.raw_handle()),
            copies.copy_l(), copies.copy_r(),
            w.trace_first(), w.trace_second(), total_ops,
        );
        thread::yield_now();
    }

    done.store(true, std::sync::atomic::Ordering::Relaxed);
    r1_handle.join().unwrap();
    r2_handle.join().unwrap();
    wt.flush();
}
