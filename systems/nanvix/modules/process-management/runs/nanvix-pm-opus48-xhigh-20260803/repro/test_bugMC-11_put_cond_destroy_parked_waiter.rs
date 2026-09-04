// Reproduction for finding MC-11:
//   "put_cond destroys a condvar with a parked waiter -> CondvarInner::drop panics"
//
// Invariant under test (spec): NoDestroyWithWaiter  (witness g.destroyWaiter)
// Counterexample: spec/output/MC_hunt_scenario3_destroy_final.out
//
// -------------------------------------------------------------------------------------------------
// WHAT THIS TEST DOES
// -------------------------------------------------------------------------------------------------
// It faithfully replicates the EXACT lifetime/refcount semantics of the real kernel code:
//
//   * CondvarInner { sleeping: RefCell<VecDeque<Tid>> }   with the SAME Drop panic
//       (src/kernel/src/pm/sync/condvar.rs:286-292)
//   * Condvar { inner: Arc<CondvarInner> }, Clone, reference_count() = Arc::strong_count
//       (condvar.rs:51-95)
//   * Condvar::wait(&self, ...) pushes the tid onto `sleeping` and, because it takes &self, the
//       caller's Condvar clone stays ALIVE for the whole parked duration
//       (condvar.rs:232-267 ; kcall/wait_cond.rs:110-123)
//   * conditions: BTreeMap<Addr, Condvar> with put_cond destroying an entry ONLY when
//       `cond.reference_count() <= 1`
//       (src/kernel/src/pm/process/state/mod.rs:702-716)
//
// None of the system's logic is altered; the predicates and Drop are copied verbatim in behaviour.
//
// The test walks the escalation ladder and prints, for each level, whether the drop-panic fired.
// The bug's CLAIM ("destroy a condvar that has a parked waiter") is judged against the real refcount
// guard. Panics are caught with catch_unwind so the harness can report which level triggered them.

use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::panic::{self, AssertUnwindSafe};
use std::rc::Rc; // single-threaded, cooperative kernel model -> Rc mirrors Arc strong_count exactly

type Tid = u32;
type Addr = usize;

// ------------------------------------------------------------------------------------------------
// Verbatim replica of sync/condvar.rs (behaviour-preserving)
// ------------------------------------------------------------------------------------------------

struct CondvarInner {
    sleeping: RefCell<VecDeque<Tid>>,
}

impl Drop for CondvarInner {
    fn drop(&mut self) {
        // condvar.rs:286-292 -- panic if a waiter is still parked when the condvar is destroyed.
        if !self.sleeping.borrow().is_empty() {
            panic!(
                "CondvarInner dropped with non-empty sleeping queue: {:?}",
                self.sleeping.borrow()
            );
        }
    }
}

#[derive(Clone)]
struct Condvar {
    inner: Rc<CondvarInner>,
}

impl Condvar {
    fn new() -> Self {
        Self { inner: Rc::new(CondvarInner { sleeping: RefCell::new(VecDeque::new()) }) }
    }
    // condvar.rs:93-95
    fn reference_count(&self) -> usize {
        Rc::strong_count(&self.inner)
    }
    // condvar.rs:257 -- enqueue self before parking. `&self` keeps the caller's clone alive.
    fn enqueue(&self, tid: Tid) {
        self.inner.sleeping.borrow_mut().push_back(tid);
    }
    // condvar.rs:263 -- the wait() error path removes the tid before returning.
    fn dequeue_self(&self, tid: Tid) {
        self.inner.sleeping.borrow_mut().retain(|&t| t != tid);
    }
    // condvar.rs:123 notify_first -- pop the woken tid out of the queue.
    fn notify_first(&self) {
        let _ = self.inner.sleeping.borrow_mut().pop_front();
    }
    fn queue_len(&self) -> usize {
        self.inner.sleeping.borrow().len()
    }
}

// ------------------------------------------------------------------------------------------------
// Verbatim replica of ProcessState::put_cond (process/state/mod.rs:702-716)
// ------------------------------------------------------------------------------------------------

struct ProcessState {
    conditions: BTreeMap<Addr, Condvar>,
}

impl ProcessState {
    fn new() -> Self {
        Self { conditions: BTreeMap::new() }
    }
    // get_cond (state/mod.rs:672-687): returns a CLONE (refcount++).
    fn get_cond(&mut self, addr: Addr) -> Condvar {
        self.conditions.entry(addr).or_insert_with(Condvar::new).clone()
    }
    // put_cond (state/mod.rs:702-716): destroy iff reference_count() <= 1.
    // extract_if is replicated exactly via a retain over the same predicate.
    fn put_cond(&mut self, cond_addr: Addr) {
        if !self.conditions.contains_key(&cond_addr) {
            return; // "condition variable not found" branch (no-op error)
        }
        // extract_if(.., |&addr, cond| cond_addr == addr && cond.reference_count() <= 1)
        self.conditions
            .retain(|&addr, cond| !(cond_addr == addr && cond.reference_count() <= 1));
    }
}

// ------------------------------------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------------------------------------

fn banner(s: &str) {
    println!("\n================ {s} ================");
}

/// Run `f`, reporting whether it panicked (i.e. the drop-panic fired).
fn did_panic<F: FnOnce()>(f: F) -> bool {
    let prev = panic::take_hook();
    panic::set_hook(Box::new(|_| {})); // silence the default panic printout
    let r = panic::catch_unwind(AssertUnwindSafe(f));
    panic::set_hook(prev);
    r.is_err()
}

// ------------------------------------------------------------------------------------------------
// LEVEL 0/1 -- real-API trigger sequence (matches the MC "scenario 3" ordering)
//
// t1 waits on cv1 (parks, holding its clone); t2 tries to destroy cv1 via put_cond while t1 is
// still parked. This is the exact "destroy while a waiter is present" scenario the finding claims.
// ------------------------------------------------------------------------------------------------
fn level0_real_api_destroy_with_parked_waiter() -> bool {
    let mut st = ProcessState::new();
    const CV1: Addr = 0xC0;
    let t1: Tid = 1;

    // --- t1: wait_cond(cv1) up to the park point ---
    // get_cond -> clone; refcount = map(1) + t1_local(1) = 2
    let t1_cond: Condvar = st.get_cond(CV1);
    t1_cond.enqueue(t1); //  Condvar::wait: push tid, about to park.
    // t1 is now PARKED. Its `t1_cond` clone stays alive on t1's (suspended) stack frame.
    // We model that by keeping `t1_cond` in scope for the rest of the function.
    println!(
        "[t1 parked on cv1]  queue_len={}  reference_count={}",
        t1_cond.queue_len(),
        t1_cond.reference_count()
    );

    // --- t2: reaches put_cond(cv1) while t1 is parked (e.g. its own signal_cond/wait_cond tail) ---
    // t2's own local `cond` (if any) is already dropped before put_cond, so it does NOT contribute.
    println!("[t2 calls put_cond(cv1)]  (t1 still parked)");
    let panicked = did_panic(|| st.put_cond(CV1));

    let destroyed = !st.conditions.contains_key(&CV1);
    println!(
        "  -> put_cond returned. condvar destroyed? {destroyed}.  guard (refcount<=1) fired? {}",
        !destroyed
    );
    // FAITHFUL MODEL of "t1 is still parked": a suspended kernel thread's stack frame is NOT
    // unwound, so its `Condvar` clone persists for as long as the thread stays parked (here:
    // indefinitely, since nobody woke t1). We model that persistence with mem::forget. Dropping it
    // at scope-exit instead would fabricate a NON-real event (a parked thread's stack being torn
    // down in-order), which the kernel never does. With the clone persisting, when `st` (the map)
    // is dropped at end of scope its refcount only drops 2->1 (the parked clone remains), so
    // CondvarInner is NOT dropped and NO panic occurs -- exactly the real behaviour.
    std::mem::forget(t1_cond);
    panicked
}

// ------------------------------------------------------------------------------------------------
// LEVEL 1 -- same as level 0; there is no timing window to widen. A queued tid ALWAYS coincides
// with a live clone through the real API, so "timing help" cannot create (tid in queue ^ refcount 1).
// Also exercise the interrupt/timeout ordering to show it, too, never leaves a dangling tid.
// ------------------------------------------------------------------------------------------------
fn level1_interrupt_ordering() -> bool {
    let mut st = ProcessState::new();
    const CV1: Addr = 0xC0;
    let t1: Tid = 1;

    let t1_cond: Condvar = st.get_cond(CV1); // refcount 2
    t1_cond.enqueue(t1); // parked
    // t1 is interrupted/timed-out: wait()'s error path removes its tid BEFORE returning...
    t1_cond.dequeue_self(t1); // condvar.rs:263
    // ...then wait_cond drops the local clone, THEN calls put_cond.
    drop(t1_cond); // refcount -> 1, queue already empty
    println!("[t1 interrupted: dequeued self, dropped clone]  then t2 put_cond(cv1)");
    let panicked = did_panic(|| st.put_cond(CV1));
    let destroyed = !st.conditions.contains_key(&CV1);
    println!("  -> condvar destroyed? {destroyed} (queue was empty, so Drop sees empty -> no panic)");
    panicked
}

// ------------------------------------------------------------------------------------------------
// LEVEL 2 -- STATE INJECTION (documented UNREACHABLE via the real API).
//
// To make put_cond destroy a condvar whose `sleeping` queue is non-empty, we must fabricate a
// state the real system can never produce: a tid sitting in the queue while NO thread holds a
// Condvar clone (so reference_count() == 1). Through the real API this is impossible, because
// Condvar::wait takes &self -- the queued waiter's clone is alive for exactly as long as its tid
// is in the queue (see investigation.md: queued-waiter <-> live-clone invariant). We inject it
// anyway, purely to prove the Drop panic *exists* once that impossible precondition is granted.
// ------------------------------------------------------------------------------------------------
fn level2_injected_unreachable_state() -> bool {
    let mut st = ProcessState::new();
    const CV1: Addr = 0xC0;
    let phantom_tid: Tid = 7;

    // Create the map entry (refcount == 1, the map is the sole holder)...
    let _ = st.get_cond(CV1); // returned clone dropped immediately -> refcount back to 1
    // ...then INJECT a queued waiter with NO corresponding clone. UNREACHABLE via real API.
    st.conditions.get(&CV1).unwrap().enqueue(phantom_tid);
    println!(
        "[INJECTED unreachable state]  queue_len={}  reference_count={}",
        st.conditions.get(&CV1).unwrap().queue_len(),
        st.conditions.get(&CV1).unwrap().reference_count()
    );

    println!("[put_cond(cv1) on injected state]");
    let panicked = did_panic(|| st.put_cond(CV1));
    println!("  -> drop-panic fired? {panicked}");
    panicked
}

fn main() {
    println!("MC-11 reproduction: put_cond destroy vs. CondvarInner::drop panic");
    println!("(faithful standalone replica of condvar.rs + state/mod.rs::put_cond)");

    banner("LEVEL 0 - real API: destroy while a waiter is PARKED");
    let l0 = level0_real_api_destroy_with_parked_waiter();
    println!("LEVEL 0 result: drop-panic triggered = {l0}");

    banner("LEVEL 1 - real API: interrupt/timeout ordering + timing");
    let l1 = level1_interrupt_ordering();
    println!("LEVEL 1 result: drop-panic triggered = {l1}");

    banner("LEVEL 2 - STATE INJECTION (unreachable precondition)");
    let l2 = level2_injected_unreachable_state();
    println!("LEVEL 2 result: drop-panic triggered = {l2}");

    banner("SUMMARY");
    println!("Level 0 (real API, parked waiter present) panic : {l0}");
    println!("Level 1 (real API, interrupt ordering)     panic : {l1}");
    println!("Level 2 (injected unreachable state)       panic : {l2}");
    println!();
    if !l0 && !l1 && l2 {
        println!("VERDICT EVIDENCE: The drop-panic is UNREACHABLE through the real API.");
        println!("  - Real API paths (L0/L1): refcount>=2 whenever the queue is non-empty, so the");
        println!("    put_cond guard `reference_count() <= 1` NEVER destroys a condvar with a waiter.");
        println!("  - The panic fires ONLY from an injected state (L2) the real system cannot reach");
        println!("    (a queued tid with no live clone). => MC counterexample is a SPEC artifact.");
    } else if l0 || l1 {
        println!("VERDICT EVIDENCE: real-API path triggered the panic => REPRODUCED.");
    } else {
        println!("VERDICT EVIDENCE: inconclusive.");
    }
}
