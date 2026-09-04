// Reproduction for CR-9: `CondvarInner::drop` panics on a non-empty waiter queue.
//
// Nanvix is a bare-metal kernel; driving this exact race end-to-end needs a full
// QEMU test-kernel build plus a bespoke guest program. This is instead a faithful
// Level-2/3 model: it replicates the VERBATIM `CondvarInner` / `Condvar` / `Drop`
// from src/kernel/src/pm/sync/condvar.rs together with the real reference-counting
// lifecycle (`get_cond`/`put_cond` with the `reference_count() <= 1` guard, the
// waiter's stack-held `Arc` clone, `notify_first`, `wait`'s push_back + `retain`,
// and the leak-on-forced-teardown of a suspended kernel stack).
//
// It exercises every REACHABLE teardown sequence (A/B/C) and shows none of them
// drops a `CondvarInner` with a non-empty queue, then a NEGATIVE CONTROL (D) that
// forces the panic from a hand-built, unreachable state — proving the panic
// branch is real code but is currently MASKED by the refcount discipline.
//
// Build & run:
//   rustc -O test_bugCR-9_condvar_drop_masked.rs -o /tmp/cr9 && /tmp/cr9

use std::cell::RefCell;
use std::collections::VecDeque;
use std::fmt;
use std::panic;
use std::sync::{Arc, Weak};

type ThreadIdentifier = u64;

// ---- verbatim structures from condvar.rs -------------------------------------
struct CondvarInner {
    sleeping: RefCell<VecDeque<ThreadIdentifier>>,
}

#[derive(Clone)]
struct Condvar {
    inner: Arc<CondvarInner>,
}

impl Condvar {
    fn new() -> Self {
        Self { inner: Arc::new(CondvarInner { sleeping: RefCell::new(VecDeque::new()) }) }
    }
    // condvar.rs: Arc::strong_count(&self.inner)
    fn reference_count(&self) -> usize {
        Arc::strong_count(&self.inner)
    }
    // condvar.rs wait(): self.inner.sleeping.borrow_mut().push_back(tid)
    fn enqueue(&self, tid: ThreadIdentifier) {
        self.inner.sleeping.borrow_mut().push_back(tid);
    }
    // condvar.rs wait() Err path: retain(|&t| t != tid)
    fn retain_remove(&self, tid: ThreadIdentifier) {
        self.inner.sleeping.borrow_mut().retain(|&t| t != tid);
    }
    // condvar.rs notify_first(): pop_front until a genuinely-sleeping tid is woken;
    // `live(tid)` models ProcessManager::wakeup_waiter (false = stale entry).
    fn notify_first(&self, live: &dyn Fn(ThreadIdentifier) -> bool) -> u32 {
        while let Some(tid) = self.inner.sleeping.borrow_mut().pop_front() {
            if live(tid) {
                return 1;
            }
        }
        0
    }
    fn queue(&self) -> Vec<ThreadIdentifier> {
        self.inner.sleeping.borrow().iter().copied().collect()
    }
    fn weak(&self) -> Weak<CondvarInner> {
        Arc::downgrade(&self.inner)
    }
}

impl fmt::Debug for CondvarInner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "CondvarInner {{ sleeping: {:?} }}", self.sleeping.borrow())
    }
}

// condvar.rs:286-291  (the finding site — panics on a non-empty queue)
impl Drop for CondvarInner {
    fn drop(&mut self) {
        if !self.sleeping.borrow().is_empty() {
            // condvar.rs (edition 2024) does `panic!("{self:?}")`; spelled out here
            // so this file builds identically under any edition.
            let msg = format!("{self:?}");
            panic!("{}", msg);
        }
    }
}

// ---- process-state `conditions` map helpers (state/mod.rs) -------------------
// put_cond: drop the map entry only when reference_count() <= 1 (state/mod.rs:723)
fn put_cond(map: &mut Option<Condvar>) {
    if let Some(c) = map.as_ref() {
        if c.reference_count() <= 1 {
            *map = None;
        }
    }
}

fn run<F: FnOnce() + panic::UnwindSafe>(name: &str, f: F) -> bool {
    let r = panic::catch_unwind(f);
    match r {
        Ok(()) => {
            println!("[{name}] NO PANIC");
            false
        }
        Err(_) => {
            println!("[{name}] PANIC (CondvarInner::drop fired on a non-empty queue)");
            true
        }
    }
}

fn main() {
    // Quiet the default panic hook so only our own lines show.
    panic::set_hook(Box::new(|_| {}));

    println!("== CR-9: CondvarInner::drop panic — reachability of a non-empty-queue drop ==\n");

    // --------------------------------------------------------------------------
    // A (Level 0): normal wait_cond + signal_cond(notify) + resume + put_cond.
    //   A waiter enqueues (holding its stack clone), a notifier pops it, the
    //   waiter resumes (Ok path: tid already popped) and drops its clone; put_cond
    //   then reclaims the map entry with an EMPTY queue.
    // --------------------------------------------------------------------------
    let a_panicked = run("A normal-wait/notify/resume", || {
        let mut map: Option<Condvar> = Some(Condvar::new()); // conditions map: 1 ref
        let waiter = map.as_ref().unwrap().clone();          // get_cond -> stack clone (ref 2)
        waiter.enqueue(1);                                   // wait(): push_back tid=1
        assert_eq!(map.as_ref().unwrap().reference_count(), 2);

        // signal_cond: notify_first pops tid=1 (genuinely sleeping) and wakes it.
        {
            let s = map.as_ref().unwrap().clone();           // get_cond (ref 3)
            let n = s.notify_first(&|_| true);
            assert_eq!(n, 1);
            put_cond(&mut map);                              // ref 2 (>1) -> stays
        }
        assert!(map.as_ref().unwrap().queue().is_empty());

        // waiter resumes: Ok path (tid already popped) -> drop stack clone.
        drop(waiter);                                        // ref 1
        put_cond(&mut map);                                  // ref<=1 -> drop, queue empty
        assert!(map.is_none());
    });

    // --------------------------------------------------------------------------
    // B (Level 1): two waiters, notify wakes one, the other stays enqueued.
    //   Proves the MASK: put_cond REFUSES to reclaim while a second waiter still
    //   holds a clone (refcount 2, queue=[B]). The condvar can only be reclaimed
    //   after B resumes and `retain`-removes itself.
    // --------------------------------------------------------------------------
    let b_panicked = run("B two-waiters-notify-one (mask fires)", || {
        let mut map: Option<Condvar> = Some(Condvar::new());
        let a = map.as_ref().unwrap().clone();
        a.enqueue(10);
        let b = map.as_ref().unwrap().clone();
        b.enqueue(20);
        assert_eq!(map.as_ref().unwrap().reference_count(), 3); // map + a + b

        // notify_first pops A only.
        let s = map.as_ref().unwrap().clone();
        assert_eq!(s.notify_first(&|_| true), 1);
        drop(s);
        // A resumes and drops its clone.
        drop(a);
        put_cond(&mut map);
        // MASK PROOF: queue is non-empty ([20]) but put_cond refused to drop,
        // because B's live clone keeps reference_count() == 2 (> 1).
        let m = map.as_ref().unwrap();
        assert_eq!(m.reference_count(), 2);
        assert_eq!(m.queue(), vec![20]);
        println!("       mask proven: refcount=2, queue={:?} -> put_cond did NOT reclaim", m.queue());

        // Later B times out / is interrupted: wait() Err path retains it out.
        b.retain_remove(20);
        drop(b);
        put_cond(&mut map);                                  // now ref<=1 -> drop, empty
        assert!(map.is_none());
    });

    // --------------------------------------------------------------------------
    // C (Level 2): forced teardown (kill/terminate) of a BLOCKED waiter.
    //   The waiter's `Condvar` clone lives in its kernel stack; ready->zombie->
    //   harvest frees that stack as raw bytes WITHOUT unwinding, so the clone's
    //   Arc strong count LEAKS (modeled by mem::forget). Dropping the process's
    //   map ref then leaves the leaked ref, so CondvarInner is never dropped.
    // --------------------------------------------------------------------------
    let c_panicked = run("C forced-teardown-leaks-clone", || {
        let mut map: Option<Condvar> = Some(Condvar::new());
        let waiter = map.as_ref().unwrap().clone();
        waiter.enqueue(99);                                  // wait(): tid=99 enqueued
        assert_eq!(map.as_ref().unwrap().reference_count(), 2);
        let w: Weak<CondvarInner> = map.as_ref().unwrap().weak();

        // Abrupt kill: kernel stack freed without running Drop -> Arc clone leaks.
        std::mem::forget(waiter);

        // Process teardown drops the conditions-map ref (harvest_zombies).
        map = None;                                          // ref 2 -> 1 (leaked ref remains)

        // CondvarInner was NOT dropped: the leaked clone keeps it alive.
        assert!(w.upgrade().is_some(), "expected leak to keep CondvarInner alive");
        let remaining = w.upgrade().unwrap();
        println!(
            "       forced kill leaked the waiter's Arc: CondvarInner still alive \
             (strong_count={}, queue={:?}) -> no drop, no panic (resource leak instead)",
            Arc::strong_count(&remaining),
            remaining.sleeping.borrow(),
        );
    });

    // --------------------------------------------------------------------------
    // D (NEGATIVE CONTROL — injected UNREACHABLE state): a lone Arc whose queue is
    //   non-empty is dropped. This is the ONLY way to reach the panic, and it
    //   corresponds to "last reference dropped while a tid remains AND no waiter
    //   clone / leak exists" — a state no reachable flow (A/B/C) produces, because
    //   a tid in the queue is always backed by a live-or-leaked stack clone.
    // --------------------------------------------------------------------------
    let d_panicked = run("D injected-unreachable-state (control)", || {
        let c = Condvar::new(); // lone Arc, ref 1
        c.enqueue(7);           // impossible: last ref holds a non-empty queue
        drop(c);                // CondvarInner::drop -> panic!("CondvarInner { sleeping: [7] }")
    });

    println!("\n== SUMMARY ==");
    println!("A reachable normal path .......... {}", if a_panicked { "PANIC" } else { "no panic" });
    println!("B reachable notify path (mask) ... {}", if b_panicked { "PANIC" } else { "no panic" });
    println!("C reachable kill path (leak) ..... {}", if c_panicked { "PANIC" } else { "no panic" });
    println!("D injected UNREACHABLE control .... {}", if d_panicked { "PANIC" } else { "no panic" });

    let reachable_ok = !a_panicked && !b_panicked && !c_panicked;
    let control_ok = d_panicked;
    if reachable_ok && control_ok {
        println!(
            "\nVERDICT-SUPPORT: No reachable teardown (A/B/C) drops a condvar with a non-empty\n\
             queue; the panic fires ONLY from the injected, unreachable state (D). The DoS is\n\
             a real code hazard but is currently MASKED by the refcount/leak discipline."
        );
    } else {
        println!("\nUNEXPECTED: reachable_ok={reachable_ok}, control_ok={control_ok}");
        std::process::exit(1);
    }
}
