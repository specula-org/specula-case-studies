// Reproduction test for left-right Bug 1:
// take_inner stale-snapshot use-after-free (PR #144).
//
// Bug location: src/write.rs:175-180. The NULL-swap publishes a NULL inner
// pointer, and then wait() runs against `self.last_epochs` whose contents are
// from the previous publish — *before* the NULL-swap. A reader that entered
// between that snapshot and the NULL-swap has odd `epoch[r]` but
// `last_epochs[r]` is even (or 0), so the wait skip rule (write.rs:272-274)
// drops them on the floor. The two backing buffers are then freed at
// write.rs:190 (drop_first) and via Taken's drop_second, while the reader's
// guard still aliases one of them — UAF.
//
// Status: This bug is **already reported upstream** as
//   PR #144 "Fix data race on writehandle drop"
//   https://github.com/jonhoo/left-right/pull/144
// by Fredi Raspall. The PR includes a TSAN-confirmed reproduction (a stress
// test where one thread repeatedly creates and drops `WriteHandle<V>` while
// other threads create new `ReadHandle`s via the factory and call `enter()`).
// The fix in PR #144 inserts a `last_epochs` refresh after the NULL-swap
// (write.rs:175) and before the wait (write.rs:180).
//
// This test attempts to trigger the same race in our local copy *without*
// PR #144's fix applied. Because the window between `publish()` returning and
// the NULL-swap is small (a few instructions), we hammer the race in a tight
// loop and rely on the OS scheduler to occasionally interleave a reader
// `enter()` into the window. We use ThreadSanitizer to detect the data race;
// without TSAN the UAF may go unnoticed because freed memory is often not
// returned to the OS (the allocator keeps the page, and the bytes look
// plausible to the reader's `Deref`).
//
// To run with TSAN:
//   RUSTFLAGS="-Z sanitizer=thread" cargo +nightly test --test repro_bug1_take_inner_uaf -- --nocapture --test-threads 1
//
// To run plain (deterministic crash unlikely in plain mode; use TSAN):
//   cargo test --test repro_bug1_take_inner_uaf -- --nocapture
//
// Reference: this is the "headline finding" of left-right_2 Round 2 (MC config
// MC_hunt_F1_uaf.cfg, 12,943 distinct states; counterexample at depth 16
// involving `MCWriterTakeInnerPubSnapReader(R1)` -> `MCReaderEnterFreshBumpEpoch(R1)`
// -> `MCWriterTakeInnerNullSwap` -> `MCWriterTakeInnerWait` skipping R1).

use left_right::{Absorb, ReadHandle, ReadHandleFactory, WriteHandle};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

#[derive(Default, Clone)]
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
#[ignore] // run explicitly: this is a stress test that relies on scheduler luck
fn take_inner_stale_snapshot_uaf_stress() {
    // Initialize the artifact's tla_trace shim so its `now_ns()` does not panic.
    std::env::set_var("LEFTRIGHT_TRACE_DIR", "/tmp/lr_trace_repro_bug1");
    left_right::tla_trace::init();

    // Stress driver: many iterations of (create writer + readers, publish,
    // drop writer while reader is racing enter()). Hopes to interleave the
    // racing enter() between the writer's last snap and the NULL-swap.
    const ITERATIONS: usize = 5000;
    let mut iterations_with_racing_reader: usize = 0;

    for iter in 0..ITERATIONS {
        let (mut w, r) = left_right::new::<Counter, AddOp>();
        // Bump w past `first=true` so take_inner's publish is non-trivial.
        w.append(AddOp(1));
        w.publish();

        let factory: ReadHandleFactory<Counter> = r.factory();
        let stop = Arc::new(AtomicBool::new(false));
        let racing_observed = Arc::new(AtomicBool::new(false));

        // Spawn racing reader threads — each one repeatedly creates a new
        // ReadHandle via the factory and calls enter(). The factory creates
        // new slab slots, increasing the chance that wait()'s
        // `last_epochs.resize(.., 0)` initializes the new slot to 0 (even),
        // which causes the wait skip rule to drop the reader on the floor.
        let mut readers = Vec::new();
        let barrier = Arc::new(Barrier::new(3 + 1));
        for _ in 0..3 {
            let factory = factory.clone();
            let stop = Arc::clone(&stop);
            let racing_observed = Arc::clone(&racing_observed);
            let barrier = Arc::clone(&barrier);
            readers.push(thread::spawn(move || {
                barrier.wait();
                while !stop.load(Ordering::Relaxed) {
                    let rh = factory.handle();
                    if let Some(g) = rh.enter() {
                        // Read the data — if this dereferences freed memory,
                        // TSAN will flag it; without TSAN, it may silently
                        // succeed.
                        let v = g.0;
                        racing_observed.store(true, Ordering::Relaxed);
                        let _ = v;
                        drop(g);
                    }
                    drop(rh);
                }
            }));
        }

        barrier.wait();

        // Tiny stagger so the reader threads have started spinning on enter().
        thread::sleep(Duration::from_micros(10));

        // Drop the writer. take_inner runs: publish (sets last_epochs) ->
        // NULL-swap -> wait (uses stale last_epochs) -> drop both buffers.
        // Any reader who managed to enter between the publish-snap and the
        // NULL-swap holds a guard on the buffer about to be dropped.
        drop(w);

        stop.store(true, Ordering::Release);
        for j in readers {
            let _ = j.join();
        }
        drop(r);

        if racing_observed.load(Ordering::Relaxed) {
            iterations_with_racing_reader += 1;
        }

        if iter % 500 == 0 {
            eprintln!(
                "iter={}/{} iters_with_racing_reader={}",
                iter, ITERATIONS, iterations_with_racing_reader
            );
        }
    }

    eprintln!(
        "Stress test completed: {}/{} iterations had a racing reader observation. \
         If running under TSAN, look above for 'data race' diagnostics. \
         Without TSAN, a successful completion does NOT prove the bug is absent — \
         the UAF may be silently masked by the allocator's freelist. \
         Cite PR #144 for confirmed TSAN evidence.",
        iterations_with_racing_reader, ITERATIONS
    );
}

// A Level-3 escalation variant: this test inserts a small sleep inside
// take_inner via a feature-gated hook to deterministically interleave the
// racing reader. We cannot modify the source from a test, so this is a
// best-effort test that documents the expected trigger.
#[test]
#[ignore]
fn take_inner_stale_snapshot_uaf_documented() {
    // This is a placeholder test that documents the expected trigger but does
    // not modify source code (Level 3 would require editing src/write.rs to
    // insert a sleep between line 168 (publish() return) and line 175
    // (NULL-swap)). The MC counterexample (MC_hunt_F1_uaf.cfg) and the TSAN
    // evidence in PR #144 already confirm this bug.
    //
    // To deterministically reproduce locally, apply this patch to write.rs:
    //
    //   --- a/src/write.rs
    //   +++ b/src/write.rs
    //   @@ -171,6 +171,9 @@ fn take_inner(&mut self) -> Option<Taken<T, O>> {
    //            assert!(self.oplog.is_empty());
    //
    //   +        // [Level-3 instrumentation] Widen the race window for repro.
    //   +        std::thread::sleep(std::time::Duration::from_micros(50));
    //   +
    //            // next, grab the read handle and set it to NULL
    //            let r_handle = self.r_handle.inner.swap(ptr::null_mut(), Ordering::Release);
    //
    // Then run the stress test above with --release; under TSAN, you should
    // see "data race" diagnostics; under ASan, the use-after-free should be
    // flagged when the reader dereferences the freed buffer.
    eprintln!(
        "This test is a documentation-only marker. \
         The bug is confirmed by:\n\
         - MC counterexample at .specula-output/spec/output/F1_uaf_bfs.out\n\
         - Upstream PR #144 with TSAN-confirmed test\n\
         To reproduce locally, see the patch in this test's comments."
    );
}
