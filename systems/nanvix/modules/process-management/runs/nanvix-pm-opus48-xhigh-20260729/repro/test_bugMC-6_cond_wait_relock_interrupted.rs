// Reproduction for MC-6: `wait_cond` returns EINTR without re-holding the mutex.
//
// Counterexample: spec/output/MC_hunt_MC-6.out
//   invariant MCCondWaitReturnsLocked, trace:
//   Initial -> MCLockMutexAcquire -> MCCondWaitUnlock -> MCCondWaitRelockInterrupted
//   final state: t1 syncPc=idle (returned from cond_wait), condWaitBad=true,
//                held[t1]=[], mutexLocked[m1]=false  (thread returned NOT holding the mutex).
//
// Mechanism (src/kernel/src/pm/kcall/wait_cond.rs:104-131):
//   :105  take_mutex_guard(...)?           // releases the caller's mutex
//   :111  cond.wait(alarm)                 // waits (result stored)
//   :123  put_cond(cond_addr)?             // may early-return
//   :126  get_mutex(mutex_addr)?
//   :127  let guard = mutex.lock(None)?;   // <-- RE-ACQUIRE; `?` returns WITHOUT the mutex
//   :128  put_mutex_guard(mutex_addr, guard)?;  // SKIPPED when :127 errors
//   :130  result
//
// `Mutex::lock` (src/kernel/src/pm/sync/mutex.rs:174-186) sleeps on contention via
// `self.0.sleeping.wait(timeout)?`; `Condvar::wait` -> `ProcessManager::sleep`
// (src/kernel/src/pm/process/manager/unsafe.rs:845-873) returns
// `Err(SleepError::Interrupted(reason))` when a signal interrupts the sleep
// (unsafe.rs:867-870). Interruption of `wait_cond` is intended/reachable (issue #2695;
// dispatcher.rs:274-288 turns InterruptReason::Signaled into EINTR).
//
// THIS TEST is a REAL two-thread reproduction. It compiles the ACTUAL kernel `Mutex`
// / `MutexInner` / `MutexGuard` code VERBATIM (only imports/macros adapted for host
// build) and runs the ACTUAL `wait_cond` re-acquire tail (:123-130). The only modeled
// piece is `ProcessManager::sleep`, faithfully emulated by the mutex's internal condvar:
// a blocked waiter either wakes on unlock (-> Ok) or is interrupted by a delivered signal
// (-> Err(Interrupted(Signaled))) -- exactly as unsafe.rs:867-870 does. Delivering the
// interrupt to a thread blocked in the re-acquire is the admissible CE step
// `MCCondWaitRelockInterrupted` (Level 2: injected pre-condition reachable via kill/signal
// on a mutex-blocked thread).

use std::collections::BTreeMap;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar as StdCondvar, Mutex as StdMutex};
use std::thread;
use std::time::Duration;

// ---- host shims for kernel-only types (no logic) -------------------------------------

macro_rules! warn  { ($($t:tt)*) => {{ let _ = format_args!($($t)*); }} }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Error {
    code: ErrorCode,
}
impl Error {
    fn new(code: ErrorCode, _m: &str) -> Self {
        Error { code }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ErrorCode {
    OperationNotPermitted,
}

// src/kernel/src/pm/thread/interrupted.rs:24-31
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InterruptReason {
    #[allow(dead_code)]
    Killed,
    #[allow(dead_code)]
    TimedOut,
    Signaled,
}

// src/kernel/src/pm/process/manager/mod.rs:161-164
#[derive(Debug)]
enum SleepError {
    Interrupted(InterruptReason),
    #[allow(dead_code)]
    Generic(Error),
}

// stand-in for ::sys::time::SystemTime (only used as `Option<SystemTime>` here)
#[derive(Clone, Copy)]
struct SystemTime;

// ---- FAITHFUL model of ProcessManager::sleep for the mutex's internal condvar ---------
//
// The kernel's `Mutex.sleeping` is a `Condvar` whose `wait(timeout)` blocks the thread via
// `ProcessManager::sleep`. It returns Ok(()) when woken by `notify_first` (fired on unlock)
// or Err(SleepError::Interrupted(reason)) when a signal interrupts the sleep. `notify_first`
// wakes the first genuinely-sleeping thread. We emulate this with a std Mutex+Condvar and a
// per-waiter wake-slot so the reproduction is a genuine cross-thread block/interrupt.

#[derive(Clone, Copy, PartialEq)]
enum Wake {
    Sleeping,
    Woken,
    Interrupted,
}

struct CondState {
    // FIFO of (token, wake-state) for threads sleeping on this condvar.
    slots: VecDeque<(u64, Wake)>,
    next_token: u64,
}

struct Condvar {
    inner: Arc<(StdMutex<CondState>, StdCondvar)>,
}
impl Clone for Condvar {
    fn clone(&self) -> Self {
        Condvar { inner: self.inner.clone() }
    }
}
impl Condvar {
    fn new() -> Self {
        Condvar {
            inner: Arc::new((
                StdMutex::new(CondState { slots: VecDeque::new(), next_token: 1 }),
                StdCondvar::new(),
            )),
        }
    }

    // Faithful stand-in for condvar.rs `wait` -> ProcessManager::sleep: blocks until woken
    // (Ok) or interrupted (Err(Interrupted)). `timeout` is accepted to match the real
    // signature but is unused (the re-acquire uses `lock(None)`).
    fn wait(&self, _timeout: Option<SystemTime>) -> Result<(), SleepError> {
        let (m, cv) = &*self.inner;
        let token = {
            let mut st = m.lock().unwrap();
            let t = st.next_token;
            st.next_token += 1;
            st.slots.push_back((t, Wake::Sleeping));
            t
        };
        let mut st = m.lock().unwrap();
        loop {
            let state = st
                .slots
                .iter()
                .find(|(tk, _)| *tk == token)
                .map(|(_, w)| *w)
                .unwrap_or(Wake::Woken);
            match state {
                Wake::Sleeping => {
                    st = cv.wait(st).unwrap();
                }
                Wake::Woken => {
                    st.slots.retain(|(tk, _)| *tk != token);
                    return Ok(());
                }
                Wake::Interrupted => {
                    st.slots.retain(|(tk, _)| *tk != token);
                    // unsafe.rs:867-870
                    return Err(SleepError::Interrupted(InterruptReason::Signaled));
                }
            }
        }
    }

    // src/kernel/src/pm/sync/condvar.rs notify_first: wake the first sleeping thread.
    fn notify_first(&self) -> Result<u32, Error> {
        let (m, cv) = &*self.inner;
        let mut st = m.lock().unwrap();
        if let Some(slot) = st.slots.iter_mut().find(|(_, w)| *w == Wake::Sleeping) {
            slot.1 = Wake::Woken;
            cv.notify_all();
            return Ok(1);
        }
        Ok(0)
    }

    // Models the kernel interrupting a thread that is blocked on this mutex (signal/kill
    // delivered to a sleeping thread -> InterruptReason::Signaled). Returns true if a
    // sleeper was interrupted.
    fn interrupt_first_sleeper(&self) -> bool {
        let (m, cv) = &*self.inner;
        let mut st = m.lock().unwrap();
        if let Some(slot) = st.slots.iter_mut().find(|(_, w)| *w == Wake::Sleeping) {
            slot.1 = Wake::Interrupted;
            cv.notify_all();
            return true;
        }
        false
    }

    fn sleeper_count(&self) -> usize {
        let (m, _) = &*self.inner;
        let st = m.lock().unwrap();
        st.slots.iter().filter(|(_, w)| *w == Wake::Sleeping).count()
    }
}

// ---- ACTUAL kernel mutex code (src/kernel/src/pm/sync/mutex.rs), copied verbatim --------
// Only adaptation: `::sys`/`crate::` paths and the `warn!` macro are the host shims above.

struct MutexInner {
    locked: AtomicBool,
    sleeping: Condvar,
}

#[derive(Clone)]
struct Mutex(Arc<MutexInner>);

struct MutexGuard {
    mutex: Arc<MutexInner>,
}

impl MutexInner {
    // mutex.rs:78-81
    unsafe fn unlock_unchecked(&self) -> Result<(), Error> {
        self.locked.store(false, Ordering::Relaxed);
        self.sleeping.notify_first().map(|_awakened| ())
    }
}

impl Mutex {
    // mutex.rs:98-103
    fn new() -> Self {
        Self(Arc::new(MutexInner {
            locked: AtomicBool::new(false),
            sleeping: Condvar::new(),
        }))
    }

    // mutex.rs:133-146
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

    // mutex.rs:174-186
    unsafe fn lock(&self, timeout: Option<SystemTime>) -> Result<MutexGuard, SleepError> {
        loop {
            match self.try_lock() {
                Ok(guard) => break Ok(guard),
                Err(()) => {
                    self.0.sleeping.wait(timeout)?;
                }
            }
        }
    }

    fn is_locked(&self) -> bool {
        self.0.locked.load(Ordering::Relaxed)
    }

    fn sleeping(&self) -> Condvar {
        self.0.sleeping.clone()
    }
}

// mutex.rs:200-207
impl Drop for MutexGuard {
    fn drop(&mut self) {
        if let Err(_error) = unsafe { self.mutex.unlock_unchecked() } {
            warn!("failed to unlock mutex");
        }
    }
}

unsafe impl Send for MutexInner {}
unsafe impl Sync for MutexInner {}

// ---- per-thread mutex-ownership map (src/kernel/src/pm/thread/state.rs:240 + manager) ---
// locked_mutexes: address -> guard. put_mutex_guard inserts; take_mutex_guard removes.
// unlock_mutex (kcall/unlock_mutex.rs:56 -> manager remove_mutex_guard, mod.rs:2616-2638)
// fails with OperationNotPermitted "thread does not own mutex" when the map has no entry.

struct ThreadOwnership {
    locked_mutexes: BTreeMap<usize, MutexGuard>,
}
impl ThreadOwnership {
    fn new() -> Self {
        ThreadOwnership { locked_mutexes: BTreeMap::new() }
    }
    fn put_mutex_guard(&mut self, addr: usize, guard: MutexGuard) {
        self.locked_mutexes.insert(addr, guard);
    }
    fn owns(&self, addr: usize) -> bool {
        self.locked_mutexes.contains_key(&addr)
    }
    // models manager remove_mutex_guard / unlock_mutex kcall
    fn unlock_mutex(&mut self, addr: usize) -> Result<(), Error> {
        match self.locked_mutexes.remove(&addr) {
            Some(_guard) => Ok(()), // drop unlocks
            None => Err(Error::new(ErrorCode::OperationNotPermitted, "thread does not own mutex")),
        }
    }
}

// ---- the ACTUAL wait_cond re-acquire tail (wait_cond.rs:126-130), verbatim structure ---
// `get_mutex` returns the process-wide Mutex for `addr`; then the buggy re-acquire.
fn wait_cond_reacquire_tail(
    mutex: &Mutex,
    addr: usize,
    own: &mut ThreadOwnership,
    result: Result<(), SleepError>,
) -> Result<(), SleepError> {
    // :127  let guard: MutexGuard = mutex.lock(None)?;
    let guard: MutexGuard = unsafe { mutex.lock(None) }?;
    // :128  ProcessManager::put_mutex_guard(mutex_addr, guard)...?;
    own.put_mutex_guard(addr, guard);
    // :130  result
    result
}

const M1: usize = 0x1000;

fn wait_until<F: Fn() -> bool>(f: F) {
    for _ in 0..2000 {
        if f() {
            return;
        }
        thread::sleep(Duration::from_millis(1));
    }
    panic!("timed out waiting for a precondition");
}

// Scenario: another thread holds M during the re-acquire; the waiter blocks; then it is
// interrupted (Signaled) -> wait_cond returns Err WITHOUT the mutex held.  (the BUG)
fn run_interrupted() -> (Result<(), SleepError>, bool, Result<(), Error>) {
    let mutex = Mutex::new();
    let sleeping = mutex.sleeping();

    // Contender thread T acquires M and holds it until told to release.
    let contender_mutex = mutex.clone();
    let release = Arc::new(AtomicBool::new(false));
    let release_t = release.clone();
    let holding = Arc::new(AtomicBool::new(false));
    let holding_t = holding.clone();
    let t = thread::spawn(move || {
        let g = contender_mutex.try_lock().expect("contender must acquire M");
        holding_t.store(true, Ordering::SeqCst);
        while !release_t.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(1));
        }
        drop(g); // real unlock
    });

    wait_until(|| holding.load(Ordering::SeqCst)); // M is now held by T

    // Waiter thread W runs the real re-acquire tail; it will block in Mutex::lock.
    let waiter_mutex = mutex.clone();
    let w = thread::spawn(move || {
        let mut own = ThreadOwnership::new();
        // `result` is the value cond.wait produced; irrelevant to the ownership bug.
        let r = wait_cond_reacquire_tail(&waiter_mutex, M1, &mut own, Ok(()));
        let owns = own.owns(M1);
        // Downstream: what unlock_mutex would see for this thread.
        let unlock = own.unlock_mutex(M1);
        (r, owns, unlock)
    });

    // Wait until W is genuinely blocked in the re-acquire, then deliver the interrupt.
    wait_until(|| sleeping.sleeper_count() >= 1);
    assert!(sleeping.interrupt_first_sleeper(), "must interrupt the blocked waiter");

    let out = w.join().unwrap();
    release.store(true, Ordering::SeqCst);
    t.join().unwrap();
    out
}

// Positive control A: contended re-acquire that is NOT interrupted -> waiter ends holding M.
fn run_contended_not_interrupted() -> (Result<(), SleepError>, bool) {
    let mutex = Mutex::new();
    let sleeping = mutex.sleeping();

    let contender_mutex = mutex.clone();
    let release = Arc::new(AtomicBool::new(false));
    let release_t = release.clone();
    let holding = Arc::new(AtomicBool::new(false));
    let holding_t = holding.clone();
    let t = thread::spawn(move || {
        let g = contender_mutex.try_lock().expect("contender must acquire M");
        holding_t.store(true, Ordering::SeqCst);
        while !release_t.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(1));
        }
        drop(g);
    });
    wait_until(|| holding.load(Ordering::SeqCst));

    let waiter_mutex = mutex.clone();
    let w = thread::spawn(move || {
        let mut own = ThreadOwnership::new();
        let r = wait_cond_reacquire_tail(&waiter_mutex, M1, &mut own, Ok(()));
        (r, own.owns(M1))
    });

    wait_until(|| sleeping.sleeper_count() >= 1);
    // Instead of interrupting, let the contender release: W must wake and acquire M.
    release.store(true, Ordering::SeqCst);
    let out = w.join().unwrap();
    t.join().unwrap();
    out
}

// Positive control B: uncontended re-acquire -> waiter ends holding M.
fn run_uncontended() -> (Result<(), SleepError>, bool) {
    let mutex = Mutex::new();
    let mut own = ThreadOwnership::new();
    let r = wait_cond_reacquire_tail(&mutex, M1, &mut own, Ok(()));
    (r, own.owns(M1))
}

fn main() {
    println!("== MC-6: wait_cond re-acquire interrupted -> returns without the mutex held ==\n");

    // ---- Positive control B: uncontended ----
    let (rb, owns_b) = run_uncontended();
    println!("[control B] uncontended re-acquire: result={:?}, owns_mutex_on_return={}", rb, owns_b);
    assert!(rb.is_ok() && owns_b, "control B: uncontended re-acquire must return holding the mutex");

    // ---- Positive control A: contended, not interrupted ----
    let (ra, owns_a) = run_contended_not_interrupted();
    println!(
        "[control A] contended, NOT interrupted: result={:?}, owns_mutex_on_return={}",
        ra, owns_a
    );
    assert!(ra.is_ok() && owns_a, "control A: non-interrupted re-acquire must return holding the mutex");

    // ---- BUG case: contended, interrupted during re-acquire ----
    let (rbug, owns_bug, unlock_bug) = run_interrupted();
    println!(
        "\n[BUG] contended + interrupted re-acquire: result={:?}, owns_mutex_on_return={}",
        rbug, owns_bug
    );
    println!(
        "[BUG] downstream unlock_mutex() on return: {:?}  (POSIX expects the thread to still hold M)",
        unlock_bug
    );

    // POSIX / invariant CondWaitReturnsLocked: wait_cond must return with the mutex held,
    // even on error. Demonstrate the violation.
    let returned_err = matches!(rbug, Err(SleepError::Interrupted(_)));
    if returned_err && !owns_bug {
        println!("\nRESULT: BUG REPRODUCED");
        println!(
            "  wait_cond returned {:?} but the thread does NOT hold the mutex (held[t]=[]).",
            rbug
        );
        println!(
            "  Downstream unlock_mutex fails: {:?} => the caller resumed its critical section",
            unlock_bug
        );
        println!("  without mutual exclusion. Matches MC MCCondWaitReturnsLocked (condWaitBad=true).");
    } else {
        panic!(
            "did NOT reproduce: returned_err={}, owns_mutex={}",
            returned_err, owns_bug
        );
    }

    // Assert the invariant violation precisely.
    assert!(returned_err, "expected wait_cond to return Err(Interrupted) on interrupted re-acquire");
    assert!(!owns_bug, "BUG: wait_cond returned without the mutex held (CondWaitReturnsLocked violated)");
    assert!(
        matches!(unlock_bug, Err(Error { code: ErrorCode::OperationNotPermitted })),
        "downstream unlock_mutex must report the thread does not own the mutex"
    );
    println!("\nAll assertions held: the invariant CondWaitReturnsLocked is violated by real code.");
}
