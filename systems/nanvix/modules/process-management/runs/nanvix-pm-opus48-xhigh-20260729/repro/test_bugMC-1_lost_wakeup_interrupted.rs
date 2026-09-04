// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// In-kernel reproduction for finding MC-1
//==================================================================================================
//
//   "Lost condvar/join notification to a sleeper embedded in an interrupted process"
//   invariant MCNoLostNotify, config MC_hunt_scenario1.cfg,
//   counterexample spec/output/MC_hunt_MC-1.out (trace length 10).
//
// MC counterexample (verbatim actions):
//   Initial -> MCCreateProcess -> MCCreateThread -> MCSleep -> MCSchedule -> MCSleep
//           -> MCSchedule -> MCAlarmFire -> MCNotifyDequeue -> MCWakeDequeued
//   Final state: procState[p1]=interrupted, threadState[t3]=sleeping, threadOwner[t3]=p1,
//                condWaiters[c1]=[] (t3 dequeued by notify), lostNotify=TRUE.
//   i.e. a notify pops a still-sleeping waiter (t3) that is parked inside an *interrupted*
//   process (p1), but the wakeup cannot find it, so the notification is lost.
//
// ROOT CAUSE (real code, this worktree):
//   ProcessManager::try_wakeup (manager/mod.rs:1880) scans only `self.suspended` and `self.ready`;
//   try_wakeup_thread (1852) additionally checks `self.running`. NONE of them scan
//   `self.interrupted`. The wakeup path used by condvar/join notify is
//     Condvar::notify_first (sync/condvar.rs:118) -> ProcessManager::wakeup_waiter
//     (manager/unsafe.rs:1142) -> try_wakeup_thread,
//   and do_wakeup (manager/mod.rs:1821) wraps the same try_wakeup_thread. When the target thread is
//   a residual sleeper embedded in an *interrupted* process, wakeup_waiter returns false /
//   do_wakeup returns NoSuchEntry, so notify_first discards the dequeued waiter (Ok(0)) while the
//   thread stays asleep forever.
//
// HOW A SLEEPER ENDS UP INSIDE AN INTERRUPTED PROCESS (durable, unmasked): the signal path.
//   kill(target, signum) with a handler installed -> interrupt_signal_candidate ->
//   interrupt_suspended_thread (manager/mod.rs:1034) moves a fully-suspended multi-thread process
//   to `interrupted`, interrupting ONE thread while its siblings stay `sleeping`. The kill kcall
//   returns without calling schedule(), so the process sits durably on `interrupted`.
//
// WHAT THIS TEST DOES (Level 2 — reachable state injection driven entirely through REAL PM /
// type-state transitions; no product logic altered):
//   * BUG:      build a fully-suspended two-thread process via the REAL chain
//               (new -> run -> add_thread -> sleep -> run -> sleep), place it on `suspended`, then
//               apply the REAL signal transition `interrupt_suspended_thread(sibling)` so the
//               process moves to `interrupted` while the waiter stays sleeping. The REAL condvar
//               wakeup `ProcessManager::wakeup_waiter(waiter)` (== do_wakeup) then returns
//               false / NoSuchEntry and the waiter is still sleeping  => notification LOST.
//   * CONTROL:  the identical wakeup on a process left on `suspended` succeeds.
//   * PERMANENCE: the REAL `InterruptedProcess::resume()` (what schedule() runs when it drains the
//               interrupted list) does NOT wake the residual sleeper (the consumed notify is not
//               resent).
//   * ISOLATION: once the process sits on `ready` (a list try_wakeup scans), the SAME wakeup call
//               succeeds — proving the loss is caused solely by the interrupted-list omission.

use super::ProcessManager;
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
        process::state::{
            RunnableProcess,
            SleepingProcess,
        },
        thread::{
            ReadyThread,
            ThreadRef,
        },
    },
};
use ::alloc::collections::LinkedList;
use ::sys::pm::{
    ProcessIdentifier,
    ThreadIdentifier,
};

//==================================================================================================
// Fixture helpers
//==================================================================================================

/// Clones a fresh virtual memory space off the current (kernel) process so test processes can be
/// constructed without disturbing live kernel mappings.
fn make_test_vmem() -> Option<Vmem> {
    // SAFETY: the process and virtual memory managers are initialized before in-kernel tests run;
    // access is synchronized because the kernel is single-threaded with interrupts disabled.
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("mc1: new_vmem failed (error={e:?})");
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

/// Builds — through the REAL type-state transition chain the manager uses in production — a
/// fully-suspended two-thread process (`tid_a` and `tid_b` both sleeping): a `SleepingProcess`.
///
/// Chain: RunnableProcess::new -> run (tid_a runs) -> add_thread(tid_b) -> sleep (tid_a sleeps,
/// tid_b still ready => runnable) -> run (tid_b runs) -> sleep (tid_b sleeps, no ready threads
/// left => fully suspended).
fn make_two_thread_sleeping_process(pid: i32, tid_a: i32, tid_b: i32) -> Option<SleepingProcess> {
    let vmem: Vmem = make_test_vmem()?;
    let process: RunnableProcess = RunnableProcess::new(
        ProcessIdentifier::from(pid),
        ProcessIdentifier::from(0),
        make_ready_thread(tid_a),
        vmem,
    );

    // Run the first thread, then add a sibling ready thread.
    let (mut running, _reason, _ctx, _tda) = process.run();
    running.add_thread(make_ready_thread(tid_b));

    // First thread blocks: a sibling is still ready, so the process stays runnable.
    let runnable: RunnableProcess = match running.sleep(None) {
        Ok((runnable, _ctx)) => runnable,
        Err(_) => {
            error!("mc1: expected a runnable process after the first thread slept");
            return None;
        },
    };

    // Sibling runs, then blocks too: no ready threads remain, so the process becomes fully
    // suspended (a SleepingProcess carrying both sleepers).
    let (running2, _reason, _ctx, _tda) = runnable.run();
    match running2.sleep(None) {
        Err((sleeping, _ctx)) => Some(sleeping),
        Ok(_) => {
            error!("mc1: expected a fully-suspended process after both threads slept");
            None
        },
    }
}

/// True iff a process with `pid` is currently on the `interrupted` list and thread `tid` is a
/// still-`Sleeping` residual thread inside it.
fn sleeper_alive_in_interrupted(pid: ProcessIdentifier, tid: ThreadIdentifier) -> bool {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    for process in pm.interrupted.iter() {
        if process.state().pid() == pid {
            return matches!(process.find_thread(tid), Some(ThreadRef::Sleeping(_)));
        }
    }
    false
}

/// True iff a process with `pid` is currently on the `ready` list and thread `tid` is a
/// still-`Sleeping` residual thread inside it.
fn sleeper_alive_in_ready(pid: ProcessIdentifier, tid: ThreadIdentifier) -> bool {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    for process in pm.ready.iter() {
        if process.state().pid() == pid {
            return matches!(process.find_thread(tid), Some(ThreadRef::Sleeping(_)));
        }
    }
    false
}

/// Removes every process created by this test (matched by pid) from all manager lists, restoring
/// the manager to its pre-test state. Dropped processes free their cloned vmem.
fn purge_test_processes(pids: &[ProcessIdentifier]) {
    let pm: &mut ProcessManager = unsafe { ProcessManager::get_mut() };

    let mut keep_suspended: LinkedList<SleepingProcess> = LinkedList::new();
    while let Some(process) = pm.suspended.pop_front() {
        if !pids.contains(&process.state().pid()) {
            keep_suspended.push_back(process);
        }
    }
    pm.suspended = keep_suspended;

    let mut keep_ready: LinkedList<RunnableProcess> = LinkedList::new();
    while let Some(process) = pm.ready.pop_front() {
        if !pids.contains(&process.state().pid()) {
            keep_ready.push_back(process);
        }
    }
    pm.ready = keep_ready;

    let mut keep_interrupted = LinkedList::new();
    while let Some(process) = pm.interrupted.pop_front() {
        if !pids.contains(&process.state().pid()) {
            keep_interrupted.push_back(process);
        }
    }
    pm.interrupted = keep_interrupted;
}

//==================================================================================================
// Test
//==================================================================================================

fn test_mc1_lost_wakeup_to_interrupted_sleeper() -> bool {
    let bug_pid: ProcessIdentifier = ProcessIdentifier::from(9110);
    let ctl_pid: ProcessIdentifier = ProcessIdentifier::from(9120);
    let iso_pid: ProcessIdentifier = ProcessIdentifier::from(9130);

    let mut ok: bool = true;

    // ===== BUG: waiter parked inside an INTERRUPTED process =====
    let waiter: ThreadIdentifier = ThreadIdentifier::from(9112);
    let sibling: ThreadIdentifier = ThreadIdentifier::from(9111);
    match make_two_thread_sleeping_process(9110, 9112, 9111) {
        Some(process) => {
            // Place the fully-suspended process on the manager's `suspended` list.
            unsafe { ProcessManager::get_mut() }.suspended.push_back(process);

            // REAL signal-delivery transition (kill -> interrupt_signal_candidate ->
            // interrupt_suspended_thread): interrupt the SIBLING so the process moves to the
            // `interrupted` list while the waiter thread stays genuinely `sleeping`.
            unsafe { ProcessManager::get_mut() }.interrupt_suspended_thread(sibling);

            let pre_ok: bool = sleeper_alive_in_interrupted(bug_pid, waiter);
            info!(
                "MC-1 PRECONDITION: process on `interrupted`, waiter t{waiter:?} still sleeping = \
                 {pre_ok}"
            );

            // REAL wakeup path used by Condvar::notify_first on a dequeued waiter:
            //   notify_first -> ProcessManager::wakeup_waiter(tid) -> try_wakeup_thread
            let woke: bool = unsafe { ProcessManager::wakeup_waiter(waiter) };
            // The same underlying try_wakeup_thread through the public do_wakeup entry the finding
            // cites (returns NoSuchEntry rather than a bool).
            let dw = unsafe { ProcessManager::get_mut() }.do_wakeup(waiter);
            let still_sleeping: bool = sleeper_alive_in_interrupted(bug_pid, waiter);
            let lost: bool = !woke;
            info!(
                "MC-1 BUG [interrupted]: wakeup_waiter(t{waiter:?})={woke}  do_wakeup={dw:?}  \
                 lost={lost}  waiter still sleeping (stranded)={still_sleeping}"
            );
            if woke || dw.is_ok() || !still_sleeping {
                error!("mc1: expected a LOST wakeup (false / NoSuchEntry) with the waiter stranded");
                ok = false;
            }
        },
        None => ok = false,
    }

    // ===== CONTROL: identical waiter on a SUSPENDED process =====
    let ctl_waiter: ThreadIdentifier = ThreadIdentifier::from(9122);
    match make_two_thread_sleeping_process(9120, 9122, 9121) {
        Some(process) => {
            unsafe { ProcessManager::get_mut() }.suspended.push_back(process);
            // No interrupt: the process stays on `suspended`, which try_wakeup DOES scan.
            let woke: bool = unsafe { ProcessManager::wakeup_waiter(ctl_waiter) };
            info!("MC-1 CONTROL [suspended]: wakeup_waiter(t{ctl_waiter:?})={woke} (delivered={woke})");
            if !woke {
                error!("mc1: control wakeup on a suspended process unexpectedly failed");
                ok = false;
            }
        },
        None => ok = false,
    }

    // ===== PERMANENCE + ISOLATION: after the REAL resume() -> `ready` =====
    let iso_waiter: ThreadIdentifier = ThreadIdentifier::from(9132);
    let iso_sibling: ThreadIdentifier = ThreadIdentifier::from(9131);
    match make_two_thread_sleeping_process(9130, 9132, 9131) {
        Some(process) => {
            unsafe { ProcessManager::get_mut() }.suspended.push_back(process);
            unsafe { ProcessManager::get_mut() }.interrupt_suspended_thread(iso_sibling);

            // Lost again while interrupted.
            let lost: bool = !unsafe { ProcessManager::wakeup_waiter(iso_waiter) };
            info!("MC-1 ISOLATION/1 [interrupted]: lost={lost}");

            // REAL resume() — exactly what schedule() runs when it drains the interrupted list
            // (manager/mod.rs:1679-1682): pop the interrupted process, resume it to a
            // RunnableProcess, push it to `ready`. resume() must NOT wake the residual sleeper.
            {
                let pm: &mut ProcessManager = unsafe { ProcessManager::get_mut() };
                let mut others = LinkedList::new();
                while let Some(interrupted) = pm.interrupted.pop_front() {
                    if interrupted.state().pid() == iso_pid {
                        pm.ready.push_back(interrupted.resume());
                    } else {
                        others.push_back(interrupted);
                    }
                }
                pm.interrupted = others;
            }

            // PERMANENCE: the consumed notification was not re-sent; the sleeper is still asleep.
            let sleeping_after_resume: bool = sleeper_alive_in_ready(iso_pid, iso_waiter);
            info!(
                "MC-1 PERMANENCE [after resume()->ready]: waiter t{iso_waiter:?} still \
                 sleeping={sleeping_after_resume}"
            );

            // ISOLATION: the SAME wakeup call now succeeds purely because the process sits on a
            // list try_wakeup scans (`ready`).
            let woke_iso: bool = unsafe { ProcessManager::wakeup_waiter(iso_waiter) };
            info!("MC-1 ISOLATION/2 [ready]: wakeup_waiter(t{iso_waiter:?})={woke_iso} (wakeable={woke_iso})");

            if !lost || !sleeping_after_resume || !woke_iso {
                error!("mc1: isolation/permanence differential failed");
                ok = false;
            }
        },
        None => ok = false,
    }

    // Teardown: remove every test process from all manager lists.
    purge_test_processes(&[bug_pid, ctl_pid, iso_pid]);

    if ok {
        info!(
            "MC-1 BUG REPRODUCED: a notification to a still-sleeping waiter embedded in an \
             interrupted process is LOST (try_wakeup omits the interrupted list); the identical \
             call succeeds on suspended/ready. Matches MCNoLostNotify (lostNotify=true)."
        );
    }

    ok
}

//==================================================================================================
// Test aggregator
//==================================================================================================

/// Runs the in-kernel reproduction for finding MC-1.
pub(super) fn run() -> bool {
    run_test!(test_mc1_lost_wakeup_to_interrupted_sleeper)
}
