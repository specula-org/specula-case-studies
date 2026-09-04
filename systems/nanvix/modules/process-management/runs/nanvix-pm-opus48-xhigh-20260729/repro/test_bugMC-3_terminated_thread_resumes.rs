// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// In-kernel reproduction for finding MC-3
//==================================================================================================
//
//   "Terminated/exited process resumes user code on a carried-forward interrupted thread"
//   invariant TerminatedThreadsDie, config MC_hunt_scenario2.cfg,
//   counterexample spec/output/MC_hunt_MC-3.out (trace length 11).
//
// MC counterexample (verbatim actions):
//   Initial -> MCCreateThread -> MCSleep -> MCRunnableTerminate -> MCResumeInterrupted
//           -> MCSchedule -> MCSleep -> MCAlarmFire -> MCResumeInterrupted -> MCSchedule
//           -> MCDispatcherCheckpoint
//   Final state: procTerminated[p1]=true, procState[p1]="running", threadState[t1]="running",
//                resumedAfterTerminate=true  (a TERMINATED process is running user code).
//
// ROOT CAUSE (real code, this worktree):
//   Termination is enforced ONLY by marking a thread's interrupt reason `Killed`: when the thread
//   later resumes from its blocking call, ProcessManager::sleep (manager/unsafe.rs:864-869) returns
//   Err(Interrupted(reason)); kcall/sleep.rs:62-66 maps Killed -> handle_sleep_error -> exit()
//   (thread dies), but maps TimedOut -> Ok(()) and Signaled -> EINTR (thread RETURNS TO USER).
//   There is no separate "terminated" scheduling gate.
//
//   InterruptedProcess::terminate (state/interrupted.rs:110-125) upholds this contract: it force-
//   marks EVERY already-interrupted thread `Killed` (set_killed, thread/interrupted.rs:128) so the
//   thread exits once resumed. But the two sibling termination paths do NOT:
//     * RunnableProcess::terminate (state/runnable.rs:180-181): `self.interrupted_threads.take()`
//       and re-attaches the interrupted threads UNCHANGED (line 192-193) — a pre-existing
//       TimedOut/Signaled reason survives.
//     * RunningProcess::exit       (state/running.rs:293-294): same `take()` unchanged, then
//       InterruptedProcess::from_sleeping(...).resume() (line 313) => returns Ok((RunnableProcess,
//       ctx)) — the "exited" process becomes RUNNABLE again with a live thread whose reason is
//       still TimedOut/Signaled.
//   When that carried thread is next scheduled, RunnableProcess::run (state/runnable.rs:134-162,
//   via ReadyThread::run, thread/ready.rs:174) surfaces Some(TimedOut); the scheduler stores it and
//   ProcessManager::sleep returns Err(Interrupted(TimedOut)) which kcall/sleep.rs:64 maps to Ok(())
//   -> the terminated process's thread resumes user code. That is the TerminatedThreadsDie violation.
//
// WHAT THIS TEST DOES (REAL PM type-state transitions only; no product logic altered; no illegal
// state injection — every object is produced by the same methods the scheduler drives):
//   build_runnable_with_carried_timedout() drives the REAL chain
//     RunnableProcess::new -> run -> add_thread -> sleep(alarm) -> run -> sleep(alarm)
//       -> SleepingProcess::wakeup_alarm(now)  [two expired alarms -> two TimedOut interrupts]
//       -> InterruptedProcess::resume()        [pops one to ready, CARRIES the other forward]
//   yielding a live RunnableProcess that holds one carried interrupted thread, reason=TimedOut
//   (tid 2). This is exactly the state reached in the CE after MCResumeInterrupted.
//
//   CONTROL [InterruptedProcess::terminate]:  survivor is force-marked Killed  (correct sibling).
//   BUG A   [RunnableProcess::terminate]:      survivor keeps reason=TimedOut  (expected Killed).
//   BUG B   [RunningProcess::exit]:            exit() returns Ok(RunnableProcess) — the "exited"
//                                              process is RUNNABLE, and running its carried thread
//                                              surfaces Some(TimedOut) — the exact value pm::sleep
//                                              maps to Ok(()) -> user code (resumedAfterTerminate).

use super::{
    InterruptedProcess,
    ProcessState,
    RunnableProcess,
    RunningProcess,
    SleepingProcess,
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
        thread::{
            InterruptReason,
            ReadyThread,
        },
        ProcessManager,
    },
};
use ::alloc::boxed::Box;
use ::sys::{
    pm::{
        ProcessIdentifier,
        ThreadIdentifier,
    },
    time::SystemTime,
    ExitStatus,
};
use ::type_safe::NonEmptyVecDeque;

//==================================================================================================
// Fixture helpers
//==================================================================================================

/// Creates a fresh virtual memory space cloned off the current (kernel) process.
fn make_test_vmem() -> Option<Vmem> {
    // SAFETY: the process and virtual memory managers are initialized before in-kernel tests run;
    // access is synchronized because the kernel is single-threaded with interrupts disabled.
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("new_vmem failed (error={e:?})");
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

/// A valid [`SystemTime`] `secs` seconds after the epoch.
fn at(secs: u64) -> SystemTime {
    SystemTime::new(secs, 0).expect("valid system time")
}

//==================================================================================================
// Real type-state driver
//==================================================================================================

///
/// Drives the REAL type-state machine to a live [`RunnableProcess`] that holds exactly one
/// carried-forward interrupted thread (tid 2) whose reason is [`InterruptReason::TimedOut`].
///
/// This mirrors the CE up to `MCResumeInterrupted`: two threads sleep with alarms, both alarms
/// fire (`SleepingProcess::wakeup_alarm` -> two TimedOut interrupts), then `resume()` promotes one
/// to ready and carries the other forward.
///
fn build_runnable_with_carried_timedout() -> Option<RunnableProcess> {
    // RunnableProcess { ready:[t1] }
    let runnable: RunnableProcess = RunnableProcess::new(
        ProcessIdentifier::from(1),
        ProcessIdentifier::from(0),
        make_ready_thread(1),
        make_test_vmem()?,
    );

    // run t1 -> RunningProcess { running:t1 }; then admit t2.
    let (mut running, _r, _ctx, _tda): (RunningProcess, _, _, _) = runnable.run();
    running.add_thread(make_ready_thread(2));

    // t1 sleeps with an alarm; a ready sibling (t2) exists -> RunnableProcess { ready:[t2], sleeping:[t1] }.
    let runnable: RunnableProcess = match running.sleep(Some(at(10))) {
        Ok((r, _ctx)) => r,
        Err(_) => {
            error!("mc3: expected RunnableProcess after t1 slept with a ready sibling");
            return None;
        },
    };

    // run t2 -> RunningProcess { running:t2, sleeping:[t1] }.
    let (running, _r, _ctx, _tda): (RunningProcess, _, _, _) = runnable.run();

    // t2 sleeps with an alarm; no ready and no interrupted threads remain -> SleepingProcess { sleeping:[t1,t2] }.
    let sleeping: SleepingProcess = match running.sleep(Some(at(20))) {
        Err((s, _ctx)) => s,
        Ok(_) => {
            error!("mc3: expected SleepingProcess after the last runnable thread slept");
            return None;
        },
    };

    // Both alarms have expired by t=100 -> InterruptedProcess { interrupted:[t1 TimedOut, t2 TimedOut] }.
    let interrupted: InterruptedProcess = match sleeping.wakeup_alarm(at(100)) {
        Ok(i) => i,
        Err(_) => {
            error!("mc3: expected both expired alarms to interrupt the sleeping threads");
            return None;
        },
    };

    // resume() promotes t1 to ready and CARRIES t2 forward (reason still TimedOut)
    // -> RunnableProcess { ready:[t1], interrupted:[t2 TimedOut] }.
    Some(interrupted.resume())
}

/// Returns the reason of the single carried interrupted thread (t2, else t1) in `interrupted`.
fn survivor_reason(interrupted: &InterruptedProcess) -> Option<InterruptReason> {
    let reason: Option<&InterruptReason> = interrupted
        .thread_reason(ThreadIdentifier::from(2))
        .or_else(|| interrupted.thread_reason(ThreadIdentifier::from(1)));
    match reason {
        Some(InterruptReason::Killed) => Some(InterruptReason::Killed),
        Some(InterruptReason::TimedOut) => Some(InterruptReason::TimedOut),
        Some(InterruptReason::Signaled) => Some(InterruptReason::Signaled),
        None => None,
    }
}

//==================================================================================================
// The reproduction
//==================================================================================================

fn test_mc3_terminated_thread_resumes_on_carried_interrupted() -> bool {
    info!("MC3-REPRO: begin (finding MC-3: TerminatedThreadsDie)");
    let mut ok: bool = true;

    // ---- CONTROL: InterruptedProcess::terminate force-marks the interrupted thread Killed. --------
    // A single already-interrupted thread whose reason is TimedOut (the same fixture the existing
    // kill_test uses), reachable exactly like the carried thread above.
    match make_test_vmem() {
        Some(vmem) => {
            let state: Box<ProcessState> =
                Box::new(ProcessState::new(ProcessIdentifier::from(1), ProcessIdentifier::from(0), vmem));
            let interrupted_thread =
                make_ready_thread(2).run().0.sleep(None).0.interrupt(InterruptReason::TimedOut);
            let control: InterruptedProcess =
                InterruptedProcess::new(state, NonEmptyVecDeque::new(interrupted_thread), None);
            let control: InterruptedProcess = control.terminate();
            match survivor_reason(&control) {
                Some(InterruptReason::Killed) => {
                    info!(
                        "MC-3 CONTROL [InterruptedProcess::terminate]: survivor tid=2 reason=Killed \
                         (correct: thread will exit() when resumed)"
                    );
                },
                other => {
                    error!("mc3: CONTROL expected Killed, got {other:?}");
                    ok = false;
                },
            }
        },
        None => {
            error!("mc3: CONTROL setup failed (no vmem)");
            ok = false;
        },
    }

    // ---- BUG A: RunnableProcess::terminate leaves the carried interrupted thread TimedOut. --------
    match build_runnable_with_carried_timedout() {
        Some(runnable) => {
            match runnable.terminate() {
                Ok(interrupted) => match survivor_reason(&interrupted) {
                    Some(InterruptReason::TimedOut) => {
                        error!(
                            "MC-3 BUG A [RunnableProcess::terminate]: terminated process retains \
                             interrupted thread tid=2 reason=TimedOut (expected Killed)"
                        );
                        error!(
                            "MC-3 BUG A consequence: ProcessManager::sleep returns \
                             Err(Interrupted(TimedOut)) -> kcall/sleep.rs:64 maps TimedOut -> Ok(()) \
                             -> the terminated process's thread RESUMES USER CODE"
                        );
                    },
                    Some(InterruptReason::Killed) => {
                        info!("MC-3 BUG A: survivor was Killed (bug NOT present on this path)");
                        ok = false;
                    },
                    other => {
                        error!("mc3: BUG A unexpected survivor reason {other:?}");
                        ok = false;
                    },
                },
                Err(_zombie) => {
                    // A zombie would mean the process actually died — i.e. the bug is absent.
                    info!("MC-3 BUG A: RunnableProcess::terminate produced a ZombieProcess (bug absent)");
                    ok = false;
                },
            }
        },
        None => {
            error!("mc3: BUG A setup failed to build the carried-TimedOut RunnableProcess");
            ok = false;
        },
    }

    // ---- BUG B: RunningProcess::exit returns a RUNNABLE process; run() surfaces Some(TimedOut). ----
    match build_runnable_with_carried_timedout() {
        Some(runnable) => {
            // Schedule the resumed ready thread -> RunningProcess carrying interrupted [t2 TimedOut].
            let (running, _r, _ctx, _tda): (RunningProcess, _, _, _) = runnable.run();
            match running.exit(ExitStatus::ok()) {
                Ok((runnable_after_exit, _ctx)) => {
                    // The process EXITED yet is Runnable (not Zombie). Run its carried thread and
                    // observe the interrupt reason the scheduler would store.
                    let (_running, reason, _ctx, _tda) = runnable_after_exit.run();
                    match reason {
                        Some(InterruptReason::TimedOut) => {
                            error!(
                                "MC-3 BUG B [RunningProcess::exit]: exited process stayed RUNNABLE; \
                                 scheduling its carried thread surfaces Some(TimedOut)"
                            );
                            error!(
                                "MC-3 BUG B consequence: that Some(TimedOut) is exactly the value \
                                 pm::sleep maps to Ok(()) -> the exited process's thread RESUMES \
                                 USER CODE (resumedAfterTerminate)"
                            );
                        },
                        other => {
                            error!("mc3: BUG B expected Some(TimedOut) from run(), got {other:?}");
                            ok = false;
                        },
                    }
                },
                Err(_zombie) => {
                    // A zombie would mean exit() actually killed the process — bug absent.
                    info!("MC-3 BUG B: RunningProcess::exit produced a ZombieProcess (bug absent)");
                    ok = false;
                },
            }
        },
        None => {
            error!("mc3: BUG B setup failed to build the carried-TimedOut RunnableProcess");
            ok = false;
        },
    }

    if ok {
        info!(
            "MC-3 BUG REPRODUCED: RunnableProcess::terminate and RunningProcess::exit both carry a \
             pre-existing interrupted thread forward with reason TimedOut (not Killed), unlike \
             InterruptedProcess::terminate. When resumed, ProcessManager::sleep returns \
             Err(Interrupted(TimedOut)) which kcall/sleep.rs:64 maps to Ok(()), so a TERMINATED / \
             EXITED process resumes user code. Matches TerminatedThreadsDie (resumedAfterTerminate=true)."
        );
    }
    info!("MC3-REPRO: end");

    ok
}

//==================================================================================================
// Test aggregator
//==================================================================================================

/// Runs the in-kernel reproduction for finding MC-3.
pub(super) fn run() -> bool {
    run_test!(test_mc3_terminated_thread_resumes_on_carried_interrupted)
}
