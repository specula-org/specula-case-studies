// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// In-kernel reproduction for finding MC-2
//==================================================================================================
//
//   "Caught signal never delivered to a sleeper in a non-suspended process"
//   invariant MCSignalReachesSafety, config MC_hunt_scenario1.cfg,
//   counterexample spec/output/MC_hunt_MC-2.out (trace length 7).
//
// MC counterexample (verbatim actions):
//   Initial -> MCCreateProcess -> MCCreateThread -> MCSetDisposition -> MCSleep -> MCSchedule
//           -> MCPostSignalHandler
//   Final: procState[p1]="ready" (RunnableProcess), threadState[t1]="sleeping", t3="ready" (both
//          owned by p1), disposition[p1][1]="handler", pending[p1]={1}, signalDeliveryFailed=TRUE.
//   i.e. a caught (handler) signal is posted to a process that is NOT fully suspended (it sits on
//   the `ready` list with a ready thread t3 and a sleeping thread t1), and no thread is interrupted.
//
// ROOT CAUSE (real code, this worktree):
//   ProcessManager::interrupt_signal_candidate (manager/mod.rs:1009) resolves the candidate thread
//   ONLY from `self.suspended`:
//       self.suspended.iter().find(|p| p.state().pid()==pid).and_then(|p| p.candidate_tid_for(signum))
//   It never scans `self.ready` (RunnableProcess) or `self.interrupted` (InterruptedProcess), both of
//   which can carry sleeping threads. kill() (manager/mod.rs:810), for a Handler disposition, posts
//   the signal and runs `PostAction::Interrupt => interrupt_signal_candidate` (mod.rs:854-857, 892-894).
//   The other delivery path, try_deliver_signal (manager/signal.rs:206, run from kcall/handler.rs:189
//   at every kcall return), delivers ONLY to the *currently running* thread, using
//   `deliverable = (signals.pending() | thread_pending) & !blocked` (signal.rs:242).
//
//   Consequence: when a caught signal is posted to a process on `ready`/`interrupted` whose ONLY
//   thread that does not block the signal is a SLEEPER (every runnable sibling masks it), NEITHER
//   path delivers: interrupt_signal_candidate skips the sleeper (process not on `suspended`), and the
//   masked runnable sibling excludes the signal from its checkpoint `deliverable`. The caught signal
//   is starved indefinitely (handler never runs; the sleeper's blocking call never EINTRs).
//
// WHAT THIS TEST DOES (Level 2 — reachable state injection driven through REAL PM / type-state
// transitions and the REAL public `kill()` entry; no product logic altered):
//   * CE-FAITHFUL: a RunnableProcess {ready:[t_r unmasked], sleeping:[t_s unmasked]} on `ready` with
//     disposition[SIGUSR1]=Handler. Real kill(pid,pid,SIGUSR1) posts the signal but interrupts
//     nothing: the sleeper t_s stays `Sleeping`, matching the CE (no candidate found). (In this exact
//     state t_r is unmasked, so t_r *would* deliver later — this is the benign state the model flags.)
//   * HARM: a RunnableProcess {ready:[t_r MASKS SIGUSR1], sleeping:[t_s unmasked]} on `ready` with
//     disposition[SIGUSR1]=Handler. This instantiates the finding's precondition "sole unmasked
//     eligible thread is a sleeper". Real kill() posts the signal, interrupts NOTHING (t_s stays
//     Sleeping), and t_r masks SIGUSR1 so it cannot take it at its checkpoint => the caught signal is
//     starved. Reachable via sigprocmask on t_r.
//   * CONTROL: the SAME configuration but fully suspended — a SleepingProcess {sleeping:[t_c
//     unmasked]} on `suspended`, disposition[SIGUSR1]=Handler. The identical real kill() DOES
//     interrupt t_c (process moves to `interrupted`, t_c -> Interrupted(Signaled)) => delivery is set
//     in motion. This isolates the defect: the eligible sleeper is interrupted ONLY when its process
//     sits on `suspended`.

use super::ProcessManager;
use crate::{
    hal::{
        arch::{
            x86::cpu::FpuState,
            ContextInformation,
        },
        mem::VirtualAddress,
    },
    mm::{
        VirtMemoryManager,
        Vmem,
    },
    pm::{
        process::state::{
            signal::{
                SignalDisposition,
                SignalHandler,
            },
            RunnableProcess,
            SleepingProcess,
        },
        thread::{
            InterruptReason,
            ReadyThread,
            ThreadRef,
        },
    },
};
use ::alloc::{
    boxed::Box,
    collections::LinkedList,
};
use ::sys::pm::{
    ProcessIdentifier,
    ThreadIdentifier,
    SIGUSR1,
};

//==================================================================================================
// Fixture helpers (mirroring kill_test.rs / mc1_repro.rs)
//==================================================================================================

/// Clones a fresh virtual memory space off the current (kernel) process.
fn make_test_vmem() -> Option<Vmem> {
    // SAFETY: the process and virtual memory managers are initialized before in-kernel tests run;
    // access is synchronized because the kernel is single-threaded with interrupts disabled.
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("mc2: new_vmem failed (error={e:?})");
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

/// A caught-signal disposition (what `sigaction()` installs for a handled signal).
fn handler_disposition() -> SignalDisposition {
    SignalDisposition::Handler(Box::new(SignalHandler {
        entry: VirtualAddress::new(0x1000),
        mask: 0,
        flags: 0,
        sigaction: 0,
    }))
}

/// Builds — through the REAL type-state chain the manager uses in production — a RunnableProcess that
/// sits on the `ready` list carrying one ready thread (`ready_tid`, with blocked mask `ready_mask`)
/// and one sleeping thread (`sleeper_tid`, unmasked).
///
/// Chain: RunnableProcess::new(sleeper) -> run (sleeper runs) -> add_thread(ready sibling) ->
/// sleep (sleeper blocks; the ready sibling remains => the process stays runnable).
fn make_runnable_with_sleeper(
    pid: i32,
    sleeper_tid: i32,
    ready_tid: i32,
    ready_mask: u64,
) -> Option<RunnableProcess> {
    let vmem: Vmem = make_test_vmem()?;
    let process: RunnableProcess = RunnableProcess::new(
        ProcessIdentifier::from(pid),
        ProcessIdentifier::from(0),
        make_ready_thread(sleeper_tid),
        vmem,
    );

    // The sleeper-to-be runs first, then we add the ready sibling.
    let (mut running, _reason, _ctx, _tda) = process.run();
    let mut ready_sibling: ReadyThread = make_ready_thread(ready_tid);
    // The ready sibling's per-thread blocked mask (what sigprocmask() sets).
    ready_sibling.thread_state_mut().set_blocked(ready_mask);
    running.add_thread(ready_sibling);

    // The first thread blocks. A ready sibling remains, so the process stays runnable: a
    // RunnableProcess { ready:[ready_tid], sleeping:[sleeper_tid] }.
    match running.sleep(None) {
        Ok((runnable, _ctx)) => Some(runnable),
        Err(_) => {
            error!("mc2: expected a runnable process (a ready sibling remained after the sleep)");
            None
        },
    }
}

/// Builds a fully-suspended single-thread process (a SleepingProcess) via the REAL chain:
/// RunnableProcess::new -> run -> sleep (no ready sibling remains => fully suspended).
fn make_single_sleeper(pid: i32, tid: i32) -> Option<SleepingProcess> {
    let vmem: Vmem = make_test_vmem()?;
    let process: RunnableProcess = RunnableProcess::new(
        ProcessIdentifier::from(pid),
        ProcessIdentifier::from(0),
        make_ready_thread(tid),
        vmem,
    );
    let (running, _reason, _ctx, _tda) = process.run();
    match running.sleep(None) {
        Err((sleeping, _ctx)) => Some(sleeping),
        Ok(_) => {
            error!("mc2: expected a fully-suspended process (no ready sibling remained)");
            None
        },
    }
}

/// Installs a caught-signal disposition for `signum` on the process `pid`, found on whatever manager
/// list it currently sits (via the REAL `find_process_mut` used by kill()).
fn install_handler(pid: ProcessIdentifier, signum: usize) -> bool {
    let pm: &mut ProcessManager = unsafe { ProcessManager::get_mut() };
    match pm.find_process_mut(pid) {
        Ok(mut pref) => {
            pref.state_mut().signals_mut().set_disposition(signum, handler_disposition());
            true
        },
        Err(e) => {
            error!("mc2: could not install handler disposition (pid={pid:?}, error={e:?})");
            false
        },
    }
}

//==================================================================================================
// Observation helpers
//==================================================================================================

/// True iff a process `pid` is on the `ready` list and thread `tid` is `Sleeping` inside it.
fn ready_sleeper_still_sleeping(pid: ProcessIdentifier, tid: ThreadIdentifier) -> bool {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    for p in pm.ready.iter() {
        if p.state().pid() == pid {
            return matches!(p.find_thread(tid), Some(ThreadRef::Sleeping(_)));
        }
    }
    false
}

/// The blocked mask of thread `tid` in the `ready`-list process `pid`, if present.
fn ready_thread_blocked(pid: ProcessIdentifier, tid: ThreadIdentifier) -> Option<u64> {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    for p in pm.ready.iter() {
        if p.state().pid() == pid {
            return p.find_thread(tid).map(|t| t.thread_state().blocked());
        }
    }
    None
}

/// The process-directed pending set of the `ready`-list process `pid`, if present.
fn ready_process_pending(pid: ProcessIdentifier) -> Option<u64> {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    for p in pm.ready.iter() {
        if p.state().pid() == pid {
            return Some(p.state().signals().pending());
        }
    }
    None
}

/// True iff process `pid` is on the `interrupted` list with thread `tid` interrupted for `Signaled`.
fn interrupted_signaled(pid: ProcessIdentifier, tid: ThreadIdentifier) -> bool {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    for p in pm.interrupted.iter() {
        if p.state().pid() == pid {
            if let Some(ThreadRef::Interrupted(t)) = p.find_thread(tid) {
                return matches!(t.reason(), InterruptReason::Signaled);
            }
            return false;
        }
    }
    false
}

/// True iff process `pid` currently sits on the `suspended` list.
fn on_suspended(pid: ProcessIdentifier) -> bool {
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    pm.suspended.iter().any(|p| p.state().pid() == pid)
}

/// Removes every test process (matched by pid) from all manager lists, freeing their cloned vmem.
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

fn test_mc2_signal_starved_in_nonsuspended_process() -> bool {
    let signum: usize = SIGUSR1;
    let bit: u64 = 1u64 << (signum - 1);

    let ce_pid: ProcessIdentifier = ProcessIdentifier::from(8210);
    let ce_sleeper: ThreadIdentifier = ThreadIdentifier::from(8211);

    let bug_pid: ProcessIdentifier = ProcessIdentifier::from(8220);
    let bug_sleeper: ThreadIdentifier = ThreadIdentifier::from(8221);
    let bug_ready: ThreadIdentifier = ThreadIdentifier::from(8222);

    let ctl_pid: ProcessIdentifier = ProcessIdentifier::from(8230);
    let ctl_sleeper: ThreadIdentifier = ThreadIdentifier::from(8231);

    let mut ok: bool = true;

    // ===== CE-FAITHFUL: RunnableProcess {ready:[t_r UNMASKED], sleeping:[t_s]} on `ready` =====
    match make_runnable_with_sleeper(8210, 8211, 8212, /* ready_mask */ 0) {
        Some(process) => {
            unsafe { ProcessManager::get_mut() }.ready.push_back(process);
            ok &= install_handler(ce_pid, signum);

            // REAL public entry: a process may always signal itself.
            let outcome = unsafe { ProcessManager::get_mut() }.kill(ce_pid, ce_pid, signum);

            let sleeper_untouched: bool = ready_sleeper_still_sleeping(ce_pid, ce_sleeper);
            let pending: u64 = ready_process_pending(ce_pid).unwrap_or(0);
            info!(
                "MC-2 CE [ready, unmasked sibling]: kill()={outcome:?}  sleeper t{ce_sleeper:?} still \
                 sleeping (not interrupted)={sleeper_untouched}  pending&bit={}",
                (pending & bit) != 0
            );
            // Matches the CE: the signal is posted but NO thread is interrupted.
            if !sleeper_untouched || (pending & bit) == 0 {
                error!("mc2: CE case — expected the signal posted with the sleeper left uninterrupted");
                ok = false;
            }
        },
        None => ok = false,
    }

    // ===== HARM: RunnableProcess {ready:[t_r MASKS signum], sleeping:[t_s unmasked]} on `ready` =====
    match make_runnable_with_sleeper(8220, 8221, 8222, /* ready_mask */ bit) {
        Some(process) => {
            unsafe { ProcessManager::get_mut() }.ready.push_back(process);
            ok &= install_handler(bug_pid, signum);

            let outcome = unsafe { ProcessManager::get_mut() }.kill(bug_pid, bug_pid, signum);

            let sleeper_untouched: bool = ready_sleeper_still_sleeping(bug_pid, bug_sleeper);
            let ready_masks: bool = ready_thread_blocked(bug_pid, bug_ready).map_or(false, |m| (m & bit) != 0);
            let pending: u64 = ready_process_pending(bug_pid).unwrap_or(0);
            let posted: bool = (pending & bit) != 0;

            // The sole thread that does NOT block the signal is the sleeper; the runnable sibling
            // masks it. Neither delivery path can reach the signal:
            //   - interrupt_signal_candidate skipped the sleeper (process not on `suspended`);
            //   - try_deliver_signal on the runnable sibling excludes it (masked out of deliverable).
            let starved: bool = posted && sleeper_untouched && ready_masks;
            info!(
                "MC-2 BUG [ready, sole eligible thread is the sleeper]: kill()={outcome:?}  \
                 posted={posted}  sleeper t{bug_sleeper:?} interrupted=false (still sleeping={sleeper_untouched})  \
                 runnable sibling t{bug_ready:?} masks signum={ready_masks}  => caught signal STARVED={starved}"
            );
            if !starved {
                error!("mc2: HARM case — expected the caught signal to be starved (no thread can take it)");
                ok = false;
            }
        },
        None => ok = false,
    }

    // ===== CONTROL: SleepingProcess {sleeping:[t_c unmasked]} on `suspended` =====
    match make_single_sleeper(8230, 8231) {
        Some(process) => {
            unsafe { ProcessManager::get_mut() }.suspended.push_back(process);
            ok &= install_handler(ctl_pid, signum);

            let outcome = unsafe { ProcessManager::get_mut() }.kill(ctl_pid, ctl_pid, signum);

            let delivered: bool = interrupted_signaled(ctl_pid, ctl_sleeper);
            let left_suspended: bool = on_suspended(ctl_pid);
            info!(
                "MC-2 CONTROL [suspended, same signal & disposition]: kill()={outcome:?}  eligible \
                 sleeper t{ctl_sleeper:?} interrupted(Signaled)->`interrupted`={delivered}  \
                 still_on_suspended={left_suspended}"
            );
            if !delivered || left_suspended {
                error!("mc2: CONTROL case — expected the suspended sleeper to be interrupted (delivery)");
                ok = false;
            }
        },
        None => ok = false,
    }

    // Teardown.
    purge_test_processes(&[ce_pid, bug_pid, ctl_pid]);

    if ok {
        info!(
            "MC-2 BUG REPRODUCED: a caught (handler) signal posted to a NON-suspended process whose \
             sole unmasked eligible thread is a sleeper is never delivered — interrupt_signal_candidate \
             (manager/mod.rs:1009) scans only `self.suspended`, so the sleeper is not interrupted, and \
             the masked runnable sibling cannot take it at its checkpoint. The identical kill() delivers \
             when the process sits on `suspended`. Matches MCSignalReachesSafety (signalDeliveryFailed=true)."
        );
    }

    ok
}

//==================================================================================================
// Test aggregator
//==================================================================================================

/// Runs the in-kernel reproduction for finding MC-2.
pub(super) fn run() -> bool {
    run_test!(test_mc2_signal_starved_in_nonsuspended_process)
}
