// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// MC-8 reproduction
//==================================================================================================
//
// Reproduction for finding MC-8: "Blockable default-Terminate signal ignores the per-thread mask".
//
// Invariant MaskHonored (MCMaskHonored), config MC_hunt_scenario6.cfg,
// counterexample spec/output/MC_hunt_MC-8.out (trace length 6). CE actions:
//   Initial -> MCCreateProcess(p2) -> MCMaskChange(t1 blocks sig 1) -> MCSleep(p1 suspended,
//              t1 sleeping) -> MCSchedule(p2 running) -> MCPostSignalDefaultTerminate:
//   State 6: procTerminated[p1]=TRUE, maskViolated=TRUE, though sig 1 is blocked on p1's only
//   thread t1.
//
// ROOT CAUSE (real code):
//   `ProcessManager::kill` (manager/mod.rs:810) maps a `Default` disposition whose `default_action`
//   is Terminate/Core to `PostAction::Terminate` (:858-866) and calls `kill_terminate()`
//   UNCONDITIONALLY (:892-893) -- with NO per-thread blocked-mask check. Only the `Handler` arm
//   (:854-856) posts to the pending set and routes through the mask-gated
//   `interrupt_signal_candidate` (:894 -> :1009 -> `candidate_tid_for`, state/sleeping.rs:89 = "a
//   sleeping thread that does NOT block signum, or None if every sleeping thread blocks it"). So an
//   ordinary blockable signal (e.g. SIGTERM) with a fatal default action terminates a target that
//   has the signal masked on every thread -- contrary to POSIX, under which a blocked
//   terminate-default signal must remain pending. SIGKILL is handled separately at :842.
//
// HOW THIS REPRODUCES IT (in-kernel, feature = "test"; real entry points, NO product logic altered):
//   Builds an ISOLATED `ProcessManager` (the live kernel lists are untouched). Each single-threaded
//   target is driven through the REAL create/sleep transitions a freshly created process reaches
//   (`RunnableProcess::new` -> `run` -> `sleep(None)`, == CE MCCreateProcess followed by MCSleep).
//   The per-thread mask is set through the REAL `sigprocmask(tid, SIG_BLOCK, {SIGTERM})` entry point
//   (== CE MCMaskChange); the disposition is set through the REAL `sigaction` entry point; the
//   signal is posted through the REAL `kill(caller, target, SIGTERM)` entry point from a caller
//   granted Capability::ProcessManagement via the REAL `capctl` (as procd does in production).
//
//   The wrong outcome is observed by reading which manager list the REAL target sits on afterwards
//   (dictated entirely by the real transition's return type) plus the REAL interrupt reason and the
//   REAL pending set -- no internal state is hand-constructed.
//
//   Four suspended single-threaded targets, differing ONLY in {disposition x mask}:
//     D_MASKED   [Default, SIGTERM blocked on its only thread] == EXACT CE
//                  -> target TERMINATED: leaves `suspended`, enters `interrupted` with its thread
//                     marked Killed -- the per-thread mask was IGNORED. (BUG; MaskHonored violated.)
//     D_UNMASKED [Default, unblocked]        -> TERMINATED (baseline: fatal default, deliverable).
//     H_MASKED   [Handler, SIGTERM blocked]  -> stays `suspended`, SIGTERM left pending, thread
//                     NOT killed -- the per-thread mask IS honored on the handler path.
//     H_UNMASKED [Handler, unblocked]        -> interrupted/Signaled, SIGTERM pending (baseline:
//                     delivered/interrupted).
//
//   The bug is the asymmetry: with the SAME masked precondition the Default-Terminate path
//   terminates the target (mask ignored) while the Handler path leaves it alive with the signal
//   pending (mask honored). The manager owns a mask-honoring path that the default-Terminate branch
//   bypasses.
//
// Compiled only under the `test` feature.

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
        },
        thread::{
            self,
            InterruptReason,
            ReadyThread,
            ThreadRefMut,
        },
    },
};
use ::alloc::boxed::Box;
use ::sys::pm::{
    Capability,
    ProcessIdentifier,
    ThreadIdentifier,
    SIG_BLOCK,
    SIGTERM,
};

/// Creates a fresh virtual memory space cloned off the current (kernel) address space.
fn fresh_vmem() -> Option<Vmem> {
    // SAFETY: the process/virtual-memory managers are initialized before in-kernel tests run and
    // access is synchronized (the kernel is single-threaded with interrupts disabled here).
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("MC-8 repro: new_vmem failed (error={e:?})");
            None
        },
    }
}

/// Creates a [`ReadyThread`] with the given identifier and an otherwise-empty context.
fn ready_thread(tid: i32) -> ReadyThread {
    ReadyThread::new(
        ThreadIdentifier::from(tid),
        None,
        None,
        None,
        ContextInformation::default(),
        // SAFETY: FpuState::new is synchronized (single-threaded kernel init/test).
        unsafe { FpuState::new() },
    )
}

/// Builds a caught (handler) disposition pointing at an arbitrary user-space entry.
fn handler_disposition() -> SignalDisposition {
    SignalDisposition::Handler(Box::new(SignalHandler {
        entry: VirtualAddress::new(0x1000),
        mask: 0,
        flags: 0,
        sigaction: 0,
    }))
}

/// Constructs a single-threaded, fully-suspended process and parks it on `pm.suspended`.
///
/// Driven through the REAL transitions a freshly created process reaches when its only thread goes
/// to sleep: `RunnableProcess::new` (what `create_process` publishes) -> `run` -> `sleep(None)`.
/// This is exactly the CE create step (MCCreateProcess) followed by MCSleep. Returns `false` on
/// setup failure.
fn spawn_suspended(pm: &mut ProcessManager, pid: i32, tid: i32) -> bool {
    let vmem: Vmem = match fresh_vmem() {
        Some(v) => v,
        None => return false,
    };
    let p: RunnableProcess = RunnableProcess::new(
        ProcessIdentifier::from(pid),
        ProcessIdentifier::from(0),
        ready_thread(tid),
        vmem,
    );
    let (running, _r, _c, _t) = p.run();
    match running.sleep(None) {
        Err((sleeping, _ctx)) => {
            pm.suspended.push_back(sleeping);
            true
        },
        Ok(_) => {
            error!("MC-8 repro: process pid={pid} unexpectedly stayed runnable after sleep");
            false
        },
    }
}

/// Returns which manager list the REAL target currently sits on. The list is dictated entirely by
/// the real transition's return type (`terminate()` folds a suspended process into `interrupted`,
/// an ignored/pending signal leaves it on `suspended`, etc.).
fn list_of(pm: &ProcessManager, pid: i32) -> &'static str {
    let pid: ProcessIdentifier = ProcessIdentifier::from(pid);
    if pm.ready.iter().any(|p| p.state().pid() == pid) {
        "ready"
    } else if pm.suspended.iter().any(|p| p.state().pid() == pid) {
        "suspended"
    } else if pm.interrupted.iter().any(|p| p.state().pid() == pid) {
        "interrupted"
    } else if pm.zombies.iter().any(|p| p.state().pid() == pid) {
        "zombie"
    } else {
        "gone"
    }
}

/// Returns the target's process-directed pending signal set (0 if the process is gone). Reads the
/// SAME `signals().pending()` set that `try_deliver_signal` consumes.
fn pending_of(pm: &ProcessManager, pid: i32) -> u64 {
    pm.find_process(ProcessIdentifier::from(pid))
        .map(|proc| proc.state().signals().pending())
        .unwrap_or(0)
}

/// Reads the REAL interrupt reason recorded on the target's thread (only meaningful once the thread
/// has been interrupted/killed). `killed` == the thread was terminated; `signaled` == it was
/// interrupted for signal delivery; `sleeping` == still parked (never disturbed).
fn thread_reason(pm: &mut ProcessManager, tid: i32) -> &'static str {
    match pm.find_thread_mut(ThreadIdentifier::from(tid)) {
        Ok(ThreadRefMut::Interrupted(t)) => match t.reason() {
            InterruptReason::Killed => "killed",
            InterruptReason::Signaled => "signaled",
            _ => "interrupted-other",
        },
        Ok(ThreadRefMut::Sleeping(_)) => "sleeping",
        Ok(ThreadRefMut::Ready(_)) => "ready",
        Ok(ThreadRefMut::Running(_)) => "running",
        Ok(ThreadRefMut::Zombie(_)) => "zombie",
        Err(_) => "gone",
    }
}

/// Drives one target: optionally installs a handler, optionally blocks SIGTERM on its only thread,
/// then posts SIGTERM via the REAL `kill` and returns (list_after, reason_after, pending_after).
fn drive(
    pm: &mut ProcessManager,
    caller: ProcessIdentifier,
    pid: i32,
    tid: i32,
    handler: bool,
    mask: bool,
) -> (&'static str, &'static str, u64) {
    let bit: u64 = 1u64 << (SIGTERM - 1);

    // Disposition: explicitly Default (fatal -> Terminate) or an installed Handler, via REAL sigaction.
    let disposition: SignalDisposition = if handler {
        handler_disposition()
    } else {
        SignalDisposition::Default
    };
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(pid), SIGTERM, Some(disposition)) {
        error!("MC-8 repro: sigaction(pid={pid}) failed (error={e:?})");
    }

    // Per-thread mask: block SIGTERM on the target's only (sleeping) thread via REAL sigprocmask.
    if mask {
        match pm.sigprocmask(ThreadIdentifier::from(tid), SIG_BLOCK, Some(bit)) {
            Ok(_) => {},
            Err(e) => error!("MC-8 repro: sigprocmask(tid={tid}) failed (error={e:?})"),
        }
    }

    // Post SIGTERM through the REAL cross-process kill entry point.
    let _ = pm.kill(caller, ProcessIdentifier::from(pid), SIGTERM);

    let list: &'static str = list_of(pm, pid);
    let reason: &'static str = thread_reason(pm, tid);
    let pending: u64 = pending_of(pm, pid);
    (list, reason, pending)
}

///
/// # Description
///
/// Reproduces finding MC-8. Returns `true` once the scenario has been driven (so the in-kernel boot
/// test suite proceeds); the concrete verdict is emitted as `MC-8 ...` log markers.
///
pub(super) fn run() -> bool {
    // SIGTERM (15): blockable, catchable, and its default action is Terminate. bit 14.
    let bit: u64 = 1u64 << (SIGTERM - 1);

    // Build an isolated process manager so the live kernel's lists are untouched. Its running
    // process is the KERNEL process; grant it ProcessManagement so it may post cross-process signals
    // (as procd does in production) through the REAL capctl entry point.
    let (kernel, tm) = thread::init();
    let root: Vmem = match fresh_vmem() {
        Some(v) => v,
        None => return true,
    };
    let mut pm: ProcessManager = ProcessManager::new(false, kernel, root, tm);
    let caller: ProcessIdentifier = ProcessIdentifier::KERNEL;
    let _ = pm.capctl(caller, Capability::ProcessManagement, true);

    const DM_PID: i32 = 240; // Default  + masked   (EXACT CE -> should stay pending; ACTUAL: killed)
    const DM_TID: i32 = 60;
    const DU_PID: i32 = 241; // Default  + unmasked (baseline: terminate)
    const DU_TID: i32 = 61;
    const HM_PID: i32 = 242; // Handler  + masked   (correct: stays suspended, pending)
    const HM_TID: i32 = 62;
    const HU_PID: i32 = 243; // Handler  + unmasked (baseline: interrupted/Signaled)
    const HU_TID: i32 = 63;

    if !spawn_suspended(&mut pm, DM_PID, DM_TID)
        || !spawn_suspended(&mut pm, DU_PID, DU_TID)
        || !spawn_suspended(&mut pm, HM_PID, HM_TID)
        || !spawn_suspended(&mut pm, HU_PID, HU_TID)
    {
        return true;
    }

    // All four start fully suspended (t* sleeping). Record the shared precondition.
    let dm_before: &'static str = list_of(&pm, DM_PID);
    let hm_before: &'static str = list_of(&pm, HM_PID);

    // ---- Drive each target through the REAL entry points. ------------------------------------------
    let (dm_list, dm_reason, dm_pending) = drive(&mut pm, caller, DM_PID, DM_TID, false, true);
    let (du_list, du_reason, du_pending) = drive(&mut pm, caller, DU_PID, DU_TID, false, false);
    let (hm_list, hm_reason, hm_pending) = drive(&mut pm, caller, HM_PID, HM_TID, true, true);
    let (hu_list, hu_reason, hu_pending) = drive(&mut pm, caller, HU_PID, HU_TID, true, false);

    info!(
        "MC-8 D_MASKED  (Default,  SIGTERM blocked; EXACT CE): before={dm_before} \
         after={dm_list} thread_reason={dm_reason} pending={dm_pending:#018b} \
         (POSIX: should stay suspended with SIGTERM pending; a blocked terminate-default signal \
         must remain pending)"
    );
    info!(
        "MC-8 D_UNMASKED(Default,  unblocked; baseline):        after={du_list} \
         thread_reason={du_reason} pending={du_pending:#018b} (expected terminate)"
    );
    info!(
        "MC-8 H_MASKED  (Handler,  SIGTERM blocked; correct):   before={hm_before} \
         after={hm_list} thread_reason={hm_reason} pending={hm_pending:#018b} \
         (mask honored: stays suspended, signal left pending)"
    );
    info!(
        "MC-8 H_UNMASKED(Handler,  unblocked; baseline):        after={hu_list} \
         thread_reason={hu_reason} pending={hu_pending:#018b} (expected interrupted/signaled)"
    );

    // Bug oracle. With the SAME masked precondition:
    //   - Default path IGNORES the mask -> target terminated (leaves suspended, enters interrupted,
    //     thread Killed);
    //   - Handler path HONORS the mask -> target stays suspended with SIGTERM left pending, thread
    //     never disturbed.
    let d_masked_terminated: bool =
        dm_before == "suspended" && dm_list == "interrupted" && dm_reason == "killed";
    let h_masked_survived_pending: bool =
        hm_before == "suspended" && hm_list == "suspended" && (hm_pending & bit) != 0
            && hm_reason == "sleeping";
    // Baselines that prove the harness observes real, correct decisions on the other quadrants.
    let d_unmasked_terminated: bool = du_list == "interrupted" && du_reason == "killed";
    let h_unmasked_delivered: bool =
        hu_list == "interrupted" && hu_reason == "signaled" && (hu_pending & bit) != 0;

    let reproduced: bool = d_masked_terminated && h_masked_survived_pending;

    if reproduced {
        error!(
            "MC-8 BUG REPRODUCED: kill(SIGTERM) with a Default (fatal) disposition TERMINATED a \
             target whose only thread blocks SIGTERM (D_MASKED: suspended -> interrupted, thread \
             Killed, pending={dm_pending:#018b}), while the otherwise-identical Handler-disposition \
             target under the SAME mask was left ALIVE with SIGTERM merely pending (H_MASKED: stays \
             suspended, pending={hm_pending:#018b}). The per-thread blocked mask is honored on the \
             Handler/interrupt path (interrupt_signal_candidate -> candidate_tid_for) but IGNORED \
             on the Default-Terminate path (kill -> PostAction::Terminate -> kill_terminate at \
             manager/mod.rs:858-866,:892-893). MaskHonored violated; contrary to POSIX a blocked \
             terminate-default signal must remain pending. baselines: d_unmasked_terminated={d_unmasked_terminated}, \
             h_unmasked_delivered={h_unmasked_delivered}"
        );
    } else {
        info!(
            "MC-8 NOT-REPRODUCED: d_masked_terminated={d_masked_terminated} \
             (before={dm_before}, after={dm_list}, reason={dm_reason}, pending={dm_pending:#018b}), \
             h_masked_survived_pending={h_masked_survived_pending} \
             (before={hm_before}, after={hm_list}, reason={hm_reason}, pending={hm_pending:#018b}), \
             d_unmasked_terminated={d_unmasked_terminated}, h_unmasked_delivered={h_unmasked_delivered}"
        );
    }

    // Drop the isolated manager, reclaiming the test address spaces.
    drop(pm);
    true
}
