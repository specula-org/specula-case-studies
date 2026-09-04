// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.
//
// Reproduction for finding MC-3:
//   "A mutex owned by a never-joined joinable zombie is held forever (blocks all waiters,
//    incl. condvar reacquire)."
//
// HOW THIS RUNS (it is actually executed):
//   This file is `include!`d by the in-kernel test module
//   `src/kernel/src/pm/process/state/mc3_repro.rs` and wired into `state::test()`. Building the
//   kernel with the `test` feature and booting it via `make run-kernel-tests` (standalone UserVM)
//   executes `test()` during `pm::init()`. The `MC3-REPRO:` log lines below appear on the kernel
//   console; the captured output is pasted into the verdict.
//
// FIDELITY: the reproduction drives the REAL Nanvix types and the REAL public transitions that the
// production kcalls use — no logic is altered:
//   * `Mutex` / `MutexGuard` (`pm/sync/mutex.rs`)                     — real acquire / Drop-unlock
//   * `RunningThread::put_mutex_guard` (`pm/thread/running.rs:236`)   — the exact call the
//         `lock_mutex` kcall reaches via `ProcessManager::store_mutex_guard`
//   * `RunningThread::exit` (`pm/thread/running.rs:195`)              — the real running->zombie
//         transition used by `do_exit_thread` on thread exit
//   * `RunningProcess::{new, find_thread, detach_thread}`            — real live-process assembly
//         and the real detach->harvest path
//   * `ZombieThread::harvest` (`pm/thread/zombie.rs:110`)            — the real harvest that
//         `harvest_zombie_thread` performs (drops ThreadState -> drops the guard -> unlock)
//
// The only thing omitted is the scheduler/context-switch plumbing around these transitions (which
// would require a booted user program and would *deadlock* the test if a second thread actually
// called the blocking `Mutex::lock`). A fresh `Mutex::try_lock()` FAILING after the owner has
// exited is the direct, non-hanging proof that a real `Mutex::lock()` (lock_mutex / wait_cond
// reacquire) would sleep with no owner alive to ever wake it.

use super::{
    ProcessState,
    RunningProcess,
};
use crate::{
    hal::arch::{
        x86::cpu::FpuState,
        ContextInformation,
    },
    mm::{
        VirtMemoryManager,
        Vmem,
    },
    pm::{
        sync::mutex::Mutex,
        thread::{
            InterruptedThread,
            ReadyThread,
            RunningThread,
            SleepingThread,
            ZombieThread,
        },
        ProcessManager,
    },
};
use ::alloc::boxed::Box;
use ::sys::{
    pm::{
        MutexAddress,
        ProcessIdentifier,
        ThreadIdentifier,
    },
    ExitStatus,
};
use ::type_safe::NonEmptyVecDeque;

//==================================================================================================
// Fixture helpers (mirrors pm/process/state/test_detach.rs)
//==================================================================================================

/// Creates a fresh virtual memory space cloned off the current (kernel) process.
fn make_test_vmem() -> Option<Vmem> {
    // SAFETY: tests run inside pm::init(), after the process and virtual memory managers are
    // initialized; access is synchronized because the kernel is single-threaded with interrupts
    // disabled.
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("MC3-REPRO: new_vmem failed (error={e:?})");
            None
        },
    }
}

/// Creates a [`ReadyThread`] with the given identifier and an otherwise empty context.
fn make_ready_thread(tid: i32) -> ReadyThread {
    ReadyThread::new(
        ThreadIdentifier::from(tid),
        None,
        None,
        None,
        ContextInformation::default(),
        // SAFETY: calls to FpuState::new are synchronized (single-threaded kernel init).
        unsafe { FpuState::new() },
    )
}

/// Creates a [`RunningThread`] with the given identifier.
fn make_running_thread(tid: i32) -> RunningThread {
    make_ready_thread(tid).run().0
}

/// Assembles a running process from the supplied running thread and optional thread queues.
fn make_test_process(
    running: RunningThread,
    ready: Option<NonEmptyVecDeque<ReadyThread>>,
    interrupted: Option<NonEmptyVecDeque<InterruptedThread>>,
    sleeping: Option<NonEmptyVecDeque<SleepingThread>>,
    zombie: Option<NonEmptyVecDeque<ZombieThread>>,
) -> Option<RunningProcess> {
    let vmem: Vmem = make_test_vmem()?;
    let state: Box<ProcessState> =
        Box::new(ProcessState::new(ProcessIdentifier::from(1), ProcessIdentifier::from(0), vmem));
    Some(RunningProcess::new(state, running, ready, interrupted, sleeping, zombie))
}

//==================================================================================================
// Reproduction
//==================================================================================================

/// Part 1 (thread level): a joinable thread acquires a mutex and exits. The mutex stays owned by
/// the resulting zombie and is released ONLY when the zombie is harvested — never at exit. Maps to
/// counterexample states S3 (lock) and S4 (exit -> zombie still owns mx1).
fn test_orphaned_mutex_released_only_at_harvest() -> bool {
    let mx_addr: MutexAddress = MutexAddress::from(0x1000usize);
    let mutex: Mutex = Mutex::new();

    // t1 (joinable) locks mx: the real lock_mutex() path
    // (get_mutex -> Mutex::try_lock/lock -> put_mutex_guard -> RunningThread::put_mutex_guard).
    let mut t1: RunningThread = make_running_thread(1);
    let guard = match mutex.try_lock() {
        Ok(g) => g,
        Err(()) => {
            error!("MC3-REPRO[1]: precondition failed: a fresh mutex was already locked");
            return false;
        },
    };
    t1.put_mutex_guard(mx_addr, guard);
    info!(
        "MC3-REPRO[1]: t1 (joinable) locked mx@0x1000; refcount={} (held)",
        mutex.reference_count()
    );

    if mutex.try_lock().is_ok() {
        error!("MC3-REPRO[1]: mutex was not actually held after lock");
        return false;
    }

    // t1 exits as a JOINABLE (non-detached) zombie: the real running->zombie transition used by
    // do_exit_thread(). The whole ThreadState (incl. locked_mutexes) moves into the ZombieThread;
    // the guard is NOT dropped here.
    let (zombie_t1, _ctx): (ZombieThread, *mut ContextInformation) = t1.exit(ExitStatus::from(0u32));

    // *** BUG ***: the owner has exited, yet the mutex is still owned by the un-harvested zombie.
    // In a correct kernel, exit/kill would release owned mutexes and this try_lock would succeed.
    let held_after_exit: bool = mutex.try_lock().is_err();
    info!(
        "MC3-REPRO[1]: after t1.exit()->zombie, mutex STILL held (try_lock=Err): {}; refcount={}",
        held_after_exit,
        mutex.reference_count()
    );

    // Release happens ONLY when the ThreadState drops == harvest_zombie_thread (join/detach/reap).
    let _ = zombie_t1.harvest();
    let released_after_harvest: bool = mutex.try_lock().is_ok();
    info!(
        "MC3-REPRO[1]: mutex released ONLY after zombie.harvest() (try_lock=Ok): {}; refcount={}",
        released_after_harvest,
        mutex.reference_count()
    );

    let reproduced: bool = held_after_exit && released_after_harvest;
    if reproduced {
        info!("MC3-REPRO[1]: REPRODUCED — joinable zombie orphaned the mutex until harvest");
    } else {
        error!(
            "MC3-REPRO[1]: NOT reproduced (held_after_exit={held_after_exit}, \
             released_after_harvest={released_after_harvest})"
        );
    }
    reproduced
}

/// Part 2 (live process): reconstructs the counterexample state after S4/S5 — process p1 is still
/// alive (sibling t2 running) while joinable zombie t1 remains in p1's zombie deque owning mx1. A
/// second locker's `lock_mutex(mx1)` (S6) would sleep forever. The lock is recoverable ONLY by
/// harvesting the zombie (a join/detach that, in the bug scenario, never comes).
fn test_orphaned_mutex_blocks_sibling_in_live_process() -> bool {
    let mx_addr: MutexAddress = MutexAddress::from(0x2000usize);
    let mutex: Mutex = Mutex::new();

    // t1 (joinable) locks mx then exits -> a joinable zombie that still owns mx.
    let mut t1: RunningThread = make_running_thread(1);
    let guard = match mutex.try_lock() {
        Ok(g) => g,
        Err(()) => {
            error!("MC3-REPRO[2]: precondition failed: a fresh mutex was already locked");
            return false;
        },
    };
    t1.put_mutex_guard(mx_addr, guard);
    let (zombie_t1, _ctx): (ZombieThread, *mut ContextInformation) = t1.exit(ExitStatus::from(0u32));

    // Assemble a STILL-ALIVE process p1: sibling t2 running, t1 retained in the zombie deque.
    let t2_running: RunningThread = make_running_thread(2);
    let t1_tid: ThreadIdentifier = ThreadIdentifier::from(1);
    let zq: NonEmptyVecDeque<ZombieThread> = NonEmptyVecDeque::new(zombie_t1);
    let mut process: RunningProcess = match make_test_process(t2_running, None, None, None, Some(zq))
    {
        Some(p) => p,
        None => {
            error!("MC3-REPRO[2]: process fixture unavailable (vmem)");
            return false;
        },
    };

    // The joinable zombie is retained in the LIVE process; nothing auto-harvests it.
    if process.find_thread(t1_tid).is_none() {
        error!("MC3-REPRO[2]: joinable zombie t1 was not retained in the live process");
        return false;
    }
    // A second thread's lock_mutex(mx1) -> Mutex::lock() -> try_lock fails -> sleeps forever.
    let sibling_would_block: bool = mutex.try_lock().is_err();
    info!(
        "MC3-REPRO[2]: p1 alive (t2 running); t1 zombie still owns mx@0x2000; \
         sibling lock_mutex would block forever: {sibling_would_block}"
    );

    // The lock is recoverable ONLY by harvesting the zombie (join/detach). Do that now to release
    // the mutex and clean up the fixture; in the real bug this join never comes.
    let released: bool = match process.detach_thread(t1_tid) {
        Ok(Some(z)) => {
            let _ = z.harvest();
            mutex.try_lock().is_ok()
        },
        Ok(None) => {
            error!("MC3-REPRO[2]: detach_thread returned Ok(None), expected the zombie");
            false
        },
        Err(e) => {
            error!("MC3-REPRO[2]: detach_thread failed (error={e:?})");
            false
        },
    };
    info!("MC3-REPRO[2]: mutex released only after harvest (via detach/join): {released}");

    let reproduced: bool = sibling_would_block && released;
    if reproduced {
        info!(
            "MC3-REPRO[2]: REPRODUCED — live process; orphaned mutex blocks sibling until harvest"
        );
    }
    reproduced
}

/// Runs the MC-3 reproduction. Returns `true` iff the orphaned-mutex behavior is observed.
pub(super) fn test() -> bool {
    let mut passed: bool = true;
    passed &= test_orphaned_mutex_released_only_at_harvest();
    passed &= test_orphaned_mutex_blocks_sibling_in_live_process();
    if passed {
        info!("MC3-REPRO: VERDICT = REPRODUCED (owned mutex released only at harvest, not at exit)");
    } else {
        error!("MC3-REPRO: VERDICT = NOT REPRODUCED");
    }
    passed
}
