// Level-3 reproduction test for left-right Bug 1:
// take_inner stale-snapshot use-after-free (PR #144).
//
// This is a Level-3 escalation that requires a small instrumentation in
// src/write.rs: a `std::thread::sleep` is gated by env var
// `LR_REPRO_BUG1_SLEEP_US` and inserted between the last `publish()` and
// the NULL-swap (write.rs:175). The instrumentation does NOT alter the
// library's protocol logic — it only widens the race window so the
// scheduler reliably interleaves a reader's `enter()` into the gap.
//
// Run:
//   LR_REPRO_BUG1_SLEEP_US=200 cargo test --release --test repro_bug1_take_inner_uaf_l3 -- --ignored --nocapture
//
// Trigger sequence (matches MC_hunt_F1_uaf.cfg counterexample):
//   1. Writer publishes -> update_and_swap snapshots last_epochs
//   2. Window: writer sleeps for LR_REPRO_BUG1_SLEEP_US microseconds
//   3. Reader R calls enter(): bumps epoch (odd), reads inner_ptr (post-swap, non-NULL)
//   4. Writer wakes, NULL-swaps inner -> r_handle = post-swap pointer
//   5. Writer wait()s with stale last_epochs[R] = even -> skip rule fires -> wait returns
//   6. Writer drops both buffers (drop_first + Taken::drop_second)
//   7. Reader R's guard still aliases the dropped buffer
//   8. Reader's Counter::Drop has set CANARY, so g.0 == CANARY when reading freed mem
//      (assuming the allocator kept the page; modern jemalloc/musl usually do for small
//       blocks within the same lifetime).

use left_right::{Absorb, ReadHandleFactory};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

const CANARY: i32 = 0x7777_7777;

#[derive(Default, Clone)]
struct Counter {
    val: i32,
}

struct AddOp(i32);

impl Absorb<AddOp> for Counter {
    fn absorb_first(&mut self, op: &mut AddOp, _: &Self) {
        self.val += op.0;
    }
    fn absorb_second(&mut self, op: AddOp, _: &Self) {
        self.val += op.0;
    }
    // drop_first and drop_second use default impls (calls drop), so Drop runs.
    fn sync_with(&mut self, first: &Self) {
        self.val = first.val;
    }
}

impl Drop for Counter {
    fn drop(&mut self) {
        // Set a canary so that any reader still aliasing this freed buffer
        // sees CANARY when they dereference. (After Box::drop the heap memory
        // is returned to the allocator; if the allocator hasn't reused the
        // page, reads will see the canary value we just wrote.)
        self.val = CANARY;
    }
}

#[test]
#[ignore] // run only when LR_REPRO_BUG1_SLEEP_US is set
fn take_inner_stale_snapshot_uaf_l3() {
    if std::env::var("LR_REPRO_BUG1_SLEEP_US").is_err() {
        eprintln!(
            "Skipping: LR_REPRO_BUG1_SLEEP_US not set. \
             To reproduce, run: \
             LR_REPRO_BUG1_SLEEP_US=200 cargo test --release \
             --test repro_bug1_take_inner_uaf_l3 -- --ignored --nocapture"
        );
        return;
    }

    // Initialize tla_trace shim.
    std::env::set_var("LEFTRIGHT_TRACE_DIR", "/tmp/lr_trace_repro_bug1_l3");
    left_right::tla_trace::init();

    const ITERATIONS: usize = 100;
    let bug_observed = Arc::new(AtomicUsize::new(0));
    let total_reader_observations = Arc::new(AtomicUsize::new(0));

    for iter in 0..ITERATIONS {
        let (mut w, r) = left_right::new::<Counter, AddOp>();
        // Push the writer past first=true so the post-swap pointer is meaningful.
        w.append(AddOp(1));
        w.publish();

        let factory: ReadHandleFactory<Counter> = r.factory();
        let stop = Arc::new(AtomicBool::new(false));
        let barrier = Arc::new(Barrier::new(3 + 1));

        // 3 reader threads spinning on enter() + read.
        let mut readers = Vec::new();
        for _ in 0..3 {
            let factory = factory.clone();
            let stop = Arc::clone(&stop);
            let barrier = Arc::clone(&barrier);
            let bug_observed = Arc::clone(&bug_observed);
            let total_reader_observations = Arc::clone(&total_reader_observations);
            readers.push(thread::spawn(move || {
                barrier.wait();
                while !stop.load(Ordering::Relaxed) {
                    let rh = factory.handle();
                    if let Some(g) = rh.enter() {
                        // While we hold the guard, read the value. If the
                        // racing-reader window fired and the writer dropped
                        // our buffer, this read may either:
                        //   - return CANARY (UAF detected via canary) — proves bug
                        //   - SIGSEGV (page was unmapped) — also proves bug
                        //   - return 1 (the still-live original) — bug not triggered this time
                        let v = g.val;
                        // Pause inside the critical section briefly so the
                        // writer's drop has a chance to fire.
                        thread::sleep(Duration::from_micros(50));
                        let v2 = g.val;
                        total_reader_observations.fetch_add(1, Ordering::Relaxed);
                        if v == CANARY || v2 == CANARY || v != v2 {
                            // Bug observed: either we read the canary, or the
                            // value changed mid-guard (which should NEVER happen
                            // since publish blocks until guard releases).
                            bug_observed.fetch_add(1, Ordering::SeqCst);
                            eprintln!(
                                "BUG OBSERVED iter={}: v={:#x} v2={:#x} (CANARY={:#x})",
                                iter, v, v2, CANARY
                            );
                        }
                        drop(g);
                    }
                    drop(rh);
                }
            }));
        }

        barrier.wait();

        // Brief stagger so readers have started before we drop.
        thread::sleep(Duration::from_micros(10));

        // Drop the writer. With LR_REPRO_BUG1_SLEEP_US set, take_inner sleeps
        // before its NULL-swap, giving the readers a deterministic window to
        // race in.
        drop(w);

        stop.store(true, Ordering::Release);
        for j in readers {
            let _ = j.join();
        }
        drop(r);

        if iter % 20 == 0 {
            eprintln!(
                "iter={}/{} bugs={} obs={}",
                iter,
                ITERATIONS,
                bug_observed.load(Ordering::Relaxed),
                total_reader_observations.load(Ordering::Relaxed)
            );
        }
    }

    let n = bug_observed.load(Ordering::SeqCst);
    let obs = total_reader_observations.load(Ordering::Relaxed);
    eprintln!(
        "Total bug observations: {} / {} reader observations",
        n, obs
    );
    assert!(
        n > 0,
        "BUG NOT REPRODUCED in {} iterations. Either the window-widening was insufficient \
         (try increasing LR_REPRO_BUG1_SLEEP_US), or the allocator reused the freed page \
         before the reader could read the canary. The MC counterexample (F1_uaf_bfs.out) \
         and PR #144's TSAN evidence are the primary sources of confirmation.",
        ITERATIONS
    );
}
