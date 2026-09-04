// Reproduction for finding MC-10:
//   "put_mutex removes a still-held mutex -> mutual-exclusion split-brain"
//
// Counterexample: spec/output/MC_hunt_scenario3_destroy_final.out
//   Invariant NoDestroyWithWaiter violated. Trace:
//     State 1: mu = mx1[ex=TRUE, ow=NULL, q=<<>>]                  (mutex exists, free)
//     State 2: mu = mx1[ex=TRUE, ow=t1,   q=<<>>], t1.hd={mx1}     (t1 LOCKS mx1)
//     State 3: mu = mx1[ex=FALSE,ow=t1,   q=<<>>], t1.hd={mx1}     (DESTROY while t1 still owns)
//   i.e. the modeled `putmutex` action fires while the mutex is still owned/held.
//
// This program faithfully mirrors the EXACT kernel primitives and the EXACT
// real call graph that reaches `put_mutex`, then walks the escalation ladder to
// decide whether the modeled destroy-while-owned transition is reachable through
// the real API, and whether it yields the claimed split-brain / orphaned waiter.
//
// Fidelity of the mirrored primitives (verbatim from the source under test):
//   * src/kernel/src/pm/sync/mutex.rs
//        struct MutexInner { locked: AtomicBool, sleeping: <cond queue> }
//        pub struct Mutex(Arc<MutexInner>);              #[derive(Clone)]
//        pub struct MutexGuard { mutex: Arc<MutexInner> }
//        reference_count() == Arc::strong_count(&self.0)
//        try_lock(): compare_exchange(false,true,Acquire,Relaxed) -> guard{ self.0.clone() }
//        Drop for MutexGuard: locked.store(false); notify_first()
//   * src/kernel/src/pm/process/state/mod.rs
//        get_mutex(): self.mutexes.entry(addr).or_insert_with(Mutex::new).clone()
//        put_mutex(): self.mutexes.extract_if(.., |&a,m| a==addr && m.reference_count() <= 2)
//   * src/kernel/src/pm/process/manager/mod.rs  (remove_mutex_guard, mod.rs:2616-2637)
//        let guard = take_mutex_guard(addr)?;   // remove owner's guard from locked_mutexes
//        put_mutex(addr)?;                       // <-- the ONLY caller of put_mutex
//        Ok(guard)                               // guard dropped by outer kcall AFTER return
//   * execution model: single global `&mut PROCESS_MANAGER` singleton, single
//     CURRENT_TID -> cooperative single-core; kernel calls run serialized and are
//     non-preemptible (the only yield point is ProcessManager::sleep()).
//
// Build & run:
//   rustc -O --edition 2021 test_bugMC-10_put_mutex_destroy_held.rs -o /tmp/mc10 && /tmp/mc10

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

// ----- verbatim mirror of pm/sync/mutex.rs ------------------------------------

struct MutexInner {
    locked: AtomicBool,
    // The real inner also carries a `Condvar` sleeping queue; for the mutex
    // wait-queue we model the parked tids explicitly in the World below so the
    // Arc bookkeeping (the only thing put_mutex looks at) stays faithful.
}

#[derive(Clone)]
struct Mutex(Arc<MutexInner>);

struct MutexGuard {
    mutex: Arc<MutexInner>,
}

impl Mutex {
    fn new() -> Self {
        Self(Arc::new(MutexInner { locked: AtomicBool::new(false) }))
    }
    fn reference_count(&self) -> usize {
        Arc::strong_count(&self.0)
    }
    fn try_lock(&self) -> Result<MutexGuard, ()> {
        if self
            .0
            .locked
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            Err(())
        } else {
            Ok(MutexGuard { mutex: self.0.clone() })
        }
    }
    fn is_locked(&self) -> bool {
        self.0.locked.load(Ordering::Relaxed)
    }
}

impl Drop for MutexGuard {
    fn drop(&mut self) {
        // Real Drop: unlock + notify_first(). Notify has no bearing on refcount.
        self.mutex.locked.store(false, Ordering::Relaxed);
    }
}

// ----- verbatim mirror of pm/process/state/mod.rs mutex map -------------------

#[derive(Default)]
struct ProcessState {
    mutexes: BTreeMap<usize, Mutex>,
}

impl ProcessState {
    // get_mutex: create-or-return the mutex for `addr`, returning a clone.
    fn get_mutex(&mut self, addr: usize) -> Mutex {
        self.mutexes.entry(addr).or_insert_with(Mutex::new).clone()
    }
    // put_mutex: the exact conditional removal from mod.rs:649-652.
    fn put_mutex(&mut self, addr: usize) {
        let _removed: BTreeMap<_, _> = self
            .mutexes
            .extract_if(.., |&a, m| a == addr && m.reference_count() <= 2)
            .collect();
    }
    fn contains(&self, addr: usize) -> bool {
        self.mutexes.contains_key(&addr)
    }
    fn map_ptr(&self, addr: usize) -> usize {
        self.mutexes
            .get(&addr)
            .map(|m| Arc::as_ptr(&m.0) as usize)
            .unwrap_or(0)
    }
}

const MX1: usize = 0x1000;

fn line() {
    println!("--------------------------------------------------------------------------");
}

// Faithful mirror of remove_mutex_guard (manager/mod.rs:2616-2637): the ONLY
// caller of put_mutex. Requires the running thread to OWN the guard; it removes
// the guard from locked_mutexes, calls put_mutex, and returns the guard, which
// the outer kcall drops AFTER this returns (all within one non-yielding kcall).
fn remove_mutex_guard(
    st: &mut ProcessState,
    locked_mutexes: &mut BTreeMap<usize, MutexGuard>,
    addr: usize,
) -> Option<MutexGuard> {
    let guard = locked_mutexes.remove(&addr)?; // take_mutex_guard: owner check
    st.put_mutex(addr); //                        the ONLY put_mutex call site
    Some(guard) //                                dropped by caller after return
}

fn main() {
    println!("MC-10 reproduction: put_mutex destroy-while-held / split-brain\n");

    // =====================================================================
    // LEVEL 0 -- black-box, real API sequence (single-core cooperative kcalls)
    // =====================================================================
    // Real sequence: t1 lock_mutex(mx1); t1 unlock_mutex(mx1).  unlock_mutex ->
    // remove_mutex_guard -> put_mutex.  Show whether the CE state
    // (ex=FALSE while t1 still owns) is ever observable.
    println!("[Level 0] Real API: lock_mutex(t1,mx1) then unlock_mutex(t1,mx1)");
    let mut st = ProcessState::default();
    let mut t1_locked: BTreeMap<usize, MutexGuard> = BTreeMap::new();

    // --- lock_mutex(t1, mx1): get_mutex + try_lock + store guard -------------
    {
        let mutex = st.get_mutex(MX1); // map ref (1) + local `mutex` (1)
        let guard = mutex.try_lock().expect("free lock must succeed");
        t1_locked.insert(MX1, guard); // guard stored in t1.locked_mutexes
        // `mutex` local dropped here (end of block) -> refs: map(1)+guard(1)=2
    }
    let held_rc = st.mutexes.get(&MX1).unwrap().reference_count();
    let held_locked = st.mutexes.get(&MX1).unwrap().is_locked();
    println!(
        "   after lock: map contains mx1={}, refcount={}, locked={}  (== model State 2: owned)",
        st.contains(MX1),
        held_rc,
        held_locked
    );
    assert_eq!(held_rc, 2, "a held mutex has exactly 2 Arc refs (map + owner guard)");

    // --- unlock_mutex(t1, mx1): remove_mutex_guard(...) then drop guard ------
    // Observe the map at the *instant* put_mutex returns but BEFORE the guard is
    // dropped -- this is the only instant in the whole kcall where an external
    // observer could see the CE state (ex=FALSE while still owned/locked).
    let returned_guard = remove_mutex_guard(&mut st, &mut t1_locked, MX1)
        .expect("t1 owns mx1, remove must succeed");
    let removed_while_locked = !st.contains(MX1) && returned_guard.mutex.locked.load(Ordering::Relaxed);
    println!(
        "   at put_mutex return: map contains mx1={}, guard.locked={}  (CE-state window)",
        st.contains(MX1),
        returned_guard.mutex.locked.load(Ordering::Relaxed)
    );
    // Now the kcall drops the guard (unlock). No yield occurred between put_mutex
    // and this drop, so NO other thread could run get_mutex in between.
    drop(returned_guard);
    println!(
        "   after guard drop: map contains mx1={}  (mutex fully released)\n",
        st.contains(MX1)
    );
    println!(
        "   => put_mutex DID remove mx1 while the lock bit was still true ({}),\n      \
         but the owner's guard is dropped in the SAME kcall with no yield in between.",
        removed_while_locked
    );
    line();

    // =====================================================================
    // LEVEL 1 -- timing: interleave a *blocked mutex waiter* (real contention)
    // =====================================================================
    // t1 holds mx1; t2 calls lock_mutex(mx1) and BLOCKS inside Mutex::lock().
    // In the real stackful kernel, a thread blocked in lock() keeps its `mutex`
    // clone alive on its suspended stack (mutex.rs:174-186).  Show this raises
    // the refcount above the <=2 threshold, so put_mutex CANNOT remove it.
    println!("[Level 1] Contended: t1 holds mx1, t2 BLOCKED in Mutex::lock() (waiter)");
    let mut st = ProcessState::default();
    let mut t1_locked: BTreeMap<usize, MutexGuard> = BTreeMap::new();
    {
        let m = st.get_mutex(MX1);
        t1_locked.insert(MX1, m.try_lock().unwrap());
    }
    // t2 lock_mutex(mx1): get_mutex returns a clone; try_lock fails; t2 parks
    // *while still holding* the `mutex` clone on its suspended kcall stack.
    let t2_blocked_clone: Mutex = st.get_mutex(MX1); // t2's live handle in lock()
    assert!(t2_blocked_clone.try_lock().is_err(), "t2 must fail to lock (t1 holds)");
    let rc_with_waiter = st.mutexes.get(&MX1).unwrap().reference_count();
    println!(
        "   refcount with 1 blocked waiter = {}  (map + t1.guard + t2.stack-clone)",
        rc_with_waiter
    );
    assert_eq!(rc_with_waiter, 3, "blocked waiter contributes a 3rd Arc ref");
    // t1 unlock_mutex -> remove_mutex_guard -> put_mutex: predicate 3 <= 2 FALSE.
    let g = remove_mutex_guard(&mut st, &mut t1_locked, MX1).unwrap();
    println!(
        "   after t1 unlock's put_mutex: map contains mx1={}  (waiter PROTECTED, not destroyed)",
        st.contains(MX1)
    );
    assert!(st.contains(MX1), "put_mutex must NOT remove a mutex with a blocked waiter");
    drop(g); // t1's guard drops -> notify wakes t2, which then re-loops try_lock.
    drop(t2_blocked_clone);
    println!("   => the <=2 threshold EXACTLY excludes the blocked-waiter case.\n");
    line();

    // =====================================================================
    // LEVEL 2 -- state injection matching the CE step literally
    // =====================================================================
    // The CE (State 2 -> 3) requires `putmutex` to fire while the mutex is owned
    // AND the owner CONTINUES to own it (State 3 keeps ow=t1, hd={mx1}) AND a new
    // get_mutex then mints a distinct object. Inject exactly that and show the
    // consequence IS real at the data-structure level -- but that the trigger is
    // NOT producible by the real call graph.
    println!("[Level 2] Inject the CE step: put_mutex while owner keeps holding, then re-get");
    let mut st = ProcessState::default();
    let mut t1_locked: BTreeMap<usize, MutexGuard> = BTreeMap::new();
    {
        let m = st.get_mutex(MX1);
        t1_locked.insert(MX1, m.try_lock().unwrap()); // t1 owns A, keeps it in locked_mutexes
    }
    let a_ptr = st.map_ptr(MX1);
    // Force the modeled decoupled destroy: call put_mutex WITHOUT removing t1's
    // guard first (this is what the model's `putmutex` action does -- see the
    // reachability analysis below for why the real code never does this).
    st.put_mutex(MX1);
    println!(
        "   injected put_mutex (owner still holds): map contains mx1={}",
        st.contains(MX1)
    );
    // A new locker now mints a DISTINCT mutex B for the same address.
    let b = st.get_mutex(MX1);
    let b_ptr = st.map_ptr(MX1);
    let b_guard = b.try_lock();
    let a_still_locked = t1_locked.get(&MX1).unwrap().mutex.locked.load(Ordering::Relaxed);
    println!("   old object A ptr = {:#x} (t1 still holds, locked={})", a_ptr, a_still_locked);
    println!("   new object B ptr = {:#x} (fresh, distinct)", b_ptr);
    println!("   B.try_lock() succeeded = {}", b_guard.is_ok());
    let split_brain = a_ptr != b_ptr && a_still_locked && b_guard.is_ok();
    println!(
        "   => SPLIT-BRAIN at data-structure level = {}  (two live guards, same address)\n",
        split_brain
    );
    assert!(split_brain, "mechanism confirmed: decoupled destroy yields split-brain");
    line();

    // =====================================================================
    // REACHABILITY VERDICT (the decisive analysis)
    // =====================================================================
    println!("[Reachability] Can the real call graph produce the Level-2 injected step?");
    println!(
        "   * put_mutex has exactly ONE caller: remove_mutex_guard (manager/mod.rs:2635),\n   \
           reachable only via unlock_mutex / wait_cond.\n   \
         * remove_mutex_guard REMOVES the running thread's guard from locked_mutexes\n   \
           (take_mutex_guard) BEFORE calling put_mutex, and requires the caller to OWN it.\n   \
           => at put_mutex time the owner is ALREADY leaving hd; the CE post-state\n   \
              (ex=FALSE AND ow=t1 AND hd={{mx1}}) is never realized.\n   \
         * The returned guard is dropped by the SAME kcall AFTER put_mutex returns,\n   \
           with NO ProcessManager::sleep() in between -> no other thread runs in the\n   \
           window, so no concurrent get_mutex can mint B while A is still locked.\n   \
         * Any thread blocked in Mutex::lock() keeps an Arc clone (refcount>=3),\n   \
           so put_mutex's `reference_count() <= 2` predicate is FALSE -> a genuine\n   \
           waiter is never destroyed (proven at Level 1).\n   \
         * Single global &mut PROCESS_MANAGER + single CURRENT_TID => cooperative\n   \
           single-core; PM kcalls are serialized and non-preemptible.\n"
    );
    println!(
        "   CONCLUSION: the mechanism is real (Level 2), but the modeled `putmutex`\n   \
         transition that fires while the object is still owned/held is UNREACHABLE\n   \
         through the real API. The counterexample is a spec over-approximation:\n   \
         the model's putmutex action is decoupled from the owner's guard-release and\n   \
         omits the `reference_count() <= 2` (no-blocked-waiter) guard.\n"
    );
    println!("RESULT: mechanism-confirmed / real-API-trigger-UNREACHABLE (spec artifact)");
}
