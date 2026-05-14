// Reproduction test for left-right Bug 2:
// Reentrant `enter()` panics when WriteHandle is dropped while reader holds an outer guard.
//
// Bug location: src/read.rs:120-148, specifically `unreachable!()` at read.rs:146.
//
// Trigger sequence:
//   1. Reader R takes outer guard via enter() while inner_ptr is non-NULL.
//      - `enters` becomes 1, `epoch[R]` becomes odd.
//   2. Writer W is dropped (or `take`d), which calls `take_inner`.
//      - `take_inner` does inner.swap(NULL) at write.rs:175.
//      - `take_inner` then calls wait(), which correctly spins on R's odd epoch.
//   3. Reader R calls enter() *again* while still holding the outer guard.
//      - `enters != 0`, so reentrant branch (read.rs:120-148) is taken.
//      - `inner.load() == NULL`, `as_ref()` returns None.
//      - Hits `unreachable!()` at read.rs:146 -> PANIC.
//
// Expected behavior: nested enter() should return None (mirroring the non-reentrant
// path's NULL handling at read.rs:206-213). The library author has not yet adopted
// this fix; the bug exists in the current main branch.
//
// Severity: Medium. The panic propagates to the reader thread; if the reader is the
// main thread, the process aborts. Even on a worker thread, it triggers a
// uncontrolled thread death and is reachable in any code that uses
// `WriteHandle::take` or relies on the WriteHandle being dropped while readers
// may still race on enter().

use left_right::Absorb;
use std::sync::mpsc::channel;
use std::thread;
use std::time::Duration;

#[derive(Default)]
struct Counter(i32);

struct AddOp(i32);

impl Absorb<AddOp> for Counter {
    fn absorb_first(&mut self, op: &mut AddOp, _: &Self) {
        self.0 += op.0;
    }
    fn absorb_second(&mut self, op: AddOp, _: &Self) {
        self.0 += op.0;
    }
    fn drop_first(self: Box<Self>) {}
    fn drop_second(self: Box<Self>) {}
    fn sync_with(&mut self, first: &Self) {
        self.0 = first.0;
    }
}

#[test]
fn reentrant_enter_on_dropped_writehandle_panics() {
    // The artifact has tla_trace instrumentation that panics in now_ns() if
    // not initialized. Set the env var and call init() to get past it.
    // This does NOT affect the bug — it only enables the trace path.
    std::env::set_var("LEFTRIGHT_TRACE_DIR", "/tmp/lr_trace_repro_bug2");
    left_right::tla_trace::init();

    // Phase 0: set up a writer / reader pair, do an initial publish so we are past
    // the `first` optimization phase (so that take_inner's NULL-swap will affect
    // the live r_handle pointer).
    let (mut w, r) = left_right::new::<Counter, AddOp>();
    w.append(AddOp(1));
    w.publish();

    // We need the reader on a worker thread (so that we can observe its panic via
    // join().is_err()). The main test thread orchestrates the writer drop.
    let (reader_ready_tx, reader_ready_rx) = channel::<()>();
    let (drop_done_tx, drop_done_rx) = channel::<()>();

    let r_for_reader = r.clone();
    let reader_thread = thread::spawn(move || {
        // Step 1: take outer guard. Now `enters[R] == 1`, epoch[R] is odd.
        let outer = r_for_reader.enter().expect("outer enter must succeed");

        // Signal main thread that we are holding the outer guard.
        reader_ready_tx.send(()).expect("send ready");

        // Wait for main to finish issuing the drop (the drop will block in
        // take_inner's wait() because of our odd epoch, so we control when it
        // *starts* but not when it returns).
        drop_done_rx.recv().expect("recv drop_done");

        // Give the writer-drop thread time to perform the NULL-swap. After
        // that point, inner.load() == NULL.
        thread::sleep(Duration::from_millis(50));

        // Step 3: call enter() again. With `enters > 0`, this takes the
        // reentrant branch at read.rs:120-148. The branch loads inner_ptr
        // (now NULL), gets None from `as_ref()`, and reaches `unreachable!()`
        // at read.rs:146.
        //
        // The test-success criterion is that this call PANICS. If it returned
        // Some or None without panicking, the bug would be absent.
        let nested = r_for_reader.enter();

        // If we reach this line, the bug has NOT been triggered. Drop the
        // outer guard (so the writer's wait() can finish) and report.
        drop(nested);
        drop(outer);
        false // bug NOT triggered
    });

    // Wait for the reader to acquire its outer guard.
    reader_ready_rx.recv().expect("recv ready");

    // Step 2: drop the writer in another thread, since drop will block on the
    // reader's odd epoch and we don't want to block the test driver.
    let writer_drop_thread = thread::spawn(move || {
        drop(w);
    });

    // Give the writer-drop thread time to do the NULL-swap (it will then enter
    // wait() and spin).
    thread::sleep(Duration::from_millis(20));

    // Tell the reader to proceed with the nested enter().
    drop_done_tx.send(()).expect("send drop_done");

    // The reader thread should panic on the unreachable!(). Capture the panic.
    let reader_result = reader_thread.join();

    // The writer drop should now finish (since the reader's panic causes the
    // outer ReadGuard to drop, restoring the epoch to even).
    let _ = writer_drop_thread.join();

    match reader_result {
        Err(panic_payload) => {
            // Confirm the panic message matches the bug.
            let msg = if let Some(s) = panic_payload.downcast_ref::<&'static str>() {
                (*s).to_string()
            } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };
            eprintln!("BUG REPRODUCED: reader panicked with: {}", msg);
            assert!(
                msg.contains("if pointer is null, no ReadGuard should have been issued"),
                "panic occurred but with unexpected message: {}",
                msg
            );
        }
        Ok(triggered) => {
            assert!(
                triggered,
                "BUG NOT REPRODUCED: nested enter() returned without panicking. \
                 The reentrant branch must hit unreachable!() at read.rs:146 \
                 when inner_ptr has been NULLed by a concurrent take_inner."
            );
        }
    }
}
