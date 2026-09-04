// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// MC-10a reproduction
//==================================================================================================
//
// Reproduction for finding MC-10a: "Nested sigsuspend overwrites the single saved-mask slot".
//
// Invariant SavedMaskRestored (MCSavedMaskRestored), config MC_hunt_scenario7.cfg,
// counterexample spec/output/MC_hunt_MC-10a.out (trace length 4). CE actions:
//   State1 Initial -> State2 MCSetDisposition (install a handler)
//   -> State3 MCSigSuspendInstall  (savedBlocked[t1]: NoMask -> {}, i.e. slot now occupied)
//   -> State4 MCSigSuspendInstall  (a SECOND install while savedBlocked[t1] is still occupied
//                                   -> savedMaskViolated = TRUE)
//
// ROOT CAUSE (real code):
//   `ProcessManager::install_sigsuspend_mask` (src/kernel/src/pm/process/manager/mod.rs:722-749)
//   unconditionally does `state.set_saved_blocked(Some(previous))` at :734, storing into
//   `ThreadState.saved_blocked` — a SINGLE `Option<u64>` slot (src/kernel/src/pm/thread/state.rs:105).
//   A signal handler that runs between the outer `sigsuspend()` install and the outer `sigreturn()`
//   may itself legally call `sigsuspend()` (POSIX allows it). That NESTED install re-enters :734 and
//   OVERWRITES the outer saved mask. When the outer `sigsuspend()` later unwinds, the slot is empty:
//     - `restore_sigsuspend_mask` (mod.rs:771-778) `take_saved_blocked()` -> None -> NO-OP; or
//     - `sigreturn_restore` (manager/signal.rs:607-610) `take_saved_blocked()` -> None -> falls back
//       to `frame.blocked` (the temporary suspend mask).
//   Either way the pre-suspend mask the outer `sigsuspend()` was supposed to reinstate is GONE. A
//   single slot cannot represent two nested in-flight sigsuspend contexts. This violates POSIX:
//   "sigsuspend() ... shall restore the signal mask ... to the set that existed before the call."
//
// HOW THIS REPRODUCES IT (in-kernel, feature = "test"; REAL entry points, NO product logic altered):
//   Builds an ISOLATED `ProcessManager` (the live kernel lists are untouched). A single-threaded
//   process is created through the REAL create/sleep transition path a freshly created process
//   reaches (`RunnableProcess::new` -> `run` -> `sleep(None)`). The mask-slot manipulation performed
//   by `install_sigsuspend_mask` / `restore_sigsuspend_mask` is scheduling-state-independent (both go
//   through `find_thread_mut(tid) -> thread_state_mut()`), so a suspended target exercises the exact
//   same slot logic a running thread would.
//
//   Every step below is a REAL public ProcessManager entry point, invoked in the exact order a
//   nested sigsuspend produces (mapping the CE MCSigSuspendInstall x2 on t1):
//     BUG (nested):
//       1. sigprocmask(SET, {SIGUSR2})     app's pre-suspend mask (blocks SIGUSR2)  == orig
//       2. install_sigsuspend_mask({})     OUTER sigsuspend -> saved_blocked = Some(orig)
//       3. sigprocmask(SET, {SIGUSR1})     the handler-running mask the delivery path installs while
//                                          the first caught handler runs (delivery never touches
//                                          saved_blocked, so this faithfully models blocked() then)
//       4. install_sigsuspend_mask({})     NESTED sigsuspend (called from the handler) -> :734
//                                          OVERWRITES saved_blocked with Some({SIGUSR1}); orig LOST
//       5. restore_sigsuspend_mask()       inner sigsuspend unwinds -> consumes the single slot
//       6. restore_sigsuspend_mask()       OUTER sigsuspend unwinds -> slot empty -> cannot reinstate
//                                          orig; SIGUSR2 ends up UNBLOCKED though the app blocked it.
//     CONTROL (single, non-nested):  1..3 collapse to one install + one restore -> orig RESTORED.
//
//   The wrong outcome is observed through REAL consumers, no hand-built internal state:
//     - `sigprocmask(tid, SIG_SETMASK, None)` (the POSIX mask query) reports the final blocked mask;
//     - `sigpending(pid, tid)` (mod.rs:685, returns `pending & blocked`) reports whether a freshly
//       posted SIGUSR2 is still held. In the BUG case SIGUSR2 is pending-but-NOT-masked (deliverable)
//       though the application had blocked it — the same `!blocked` term `try_deliver_signal`
//       (manager/signal.rs:242, `(pending|thread_pending) & !blocked`) acts on. In the CONTROL case
//       SIGUSR2 stays masked/pending (correct).
//
//   `saved_blocked_ref()` (thread/state.rs, feature="test") is used ONLY to snapshot the slot for
//   evidence; it never drives the logic.
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
            ReadyThread,
        },
    },
};
use ::alloc::boxed::Box;
use ::sys::pm::{
    Capability,
    ProcessIdentifier,
    ThreadIdentifier,
    SIGUSR1,
    SIGUSR2,
    SIG_SETMASK,
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
            error!("MC-10a repro: new_vmem failed (error={e:?})");
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
/// Returns `false` on setup failure.
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
            error!("MC-10a repro: process pid={pid} unexpectedly stayed runnable after sleep");
            false
        },
    }
}

/// Snapshots the per-thread `saved_blocked` slot (evidence only; feature="test" accessor).
fn saved_of(pm: &mut ProcessManager, tid: i32) -> Option<u64> {
    pm.find_thread_mut(ThreadIdentifier::from(tid))
        .ok()
        .and_then(|mut t| t.thread_state_mut().saved_blocked_ref())
}

///
/// # Description
///
/// Reproduces finding MC-10a. Returns `true` once the scenario has been driven (so the in-kernel
/// boot test suite proceeds); the concrete verdict is emitted as `MC-10a ...` log markers.
///
pub(super) fn run() -> bool {
    let usr1: u64 = 1u64 << (SIGUSR1 - 1); // SIGUSR1 = 10 -> 0x200
    let usr2: u64 = 1u64 << (SIGUSR2 - 1); // SIGUSR2 = 12 -> 0x800
    let orig: u64 = usr2; // the application deliberately blocks SIGUSR2 before sigsuspend()
    let handler_mask: u64 = usr1; // mask in effect while the first interrupting handler runs

    // Isolated process manager: live kernel lists untouched. Its running process is the KERNEL
    // process; grant it ProcessManagement via the REAL capctl entry point so it may post signals.
    let (kernel, tm) = thread::init();
    let root: Vmem = match fresh_vmem() {
        Some(v) => v,
        None => return true,
    };
    let mut pm: ProcessManager = ProcessManager::new(false, kernel, root, tm);
    let caller: ProcessIdentifier = ProcessIdentifier::KERNEL;
    let _ = pm.capctl(caller, Capability::ProcessManagement, true);

    const BUG_PID: i32 = 310;
    const BUG_TID: i32 = 60;
    const CTL_PID: i32 = 311;
    const CTL_TID: i32 = 61;

    if !spawn_suspended(&mut pm, BUG_PID, BUG_TID) || !spawn_suspended(&mut pm, CTL_PID, CTL_TID) {
        return true;
    }

    let bug_pid: ProcessIdentifier = ProcessIdentifier::from(BUG_PID);
    let bug_tid: ThreadIdentifier = ThreadIdentifier::from(BUG_TID);
    let ctl_pid: ProcessIdentifier = ProcessIdentifier::from(CTL_PID);
    let ctl_tid: ThreadIdentifier = ThreadIdentifier::from(CTL_TID);

    // ================= BUG: NESTED sigsuspend (maps CE MCSigSuspendInstall x2 on t1) =================
    // 1. Application installs its pre-suspend mask (blocks SIGUSR2) via REAL sigprocmask.
    let _ = pm.sigprocmask(bug_tid, SIG_SETMASK, Some(orig));
    // 2. OUTER sigsuspend installs a temporary mask {} -> saves orig into the single slot (:734).
    let _ = pm.install_sigsuspend_mask(bug_pid, bug_tid, 0);
    let saved_after_outer: Option<u64> = saved_of(&mut pm, BUG_TID);
    // 3. First caught signal is delivered; the delivery path installs the handler-running mask.
    //    Represent that mask (SIGUSR1) through the REAL sigprocmask entry point. Delivery never
    //    writes saved_blocked, so this faithfully models blocked() while the first handler runs.
    let _ = pm.sigprocmask(bug_tid, SIG_SETMASK, Some(handler_mask));
    // 4. The handler legally calls sigsuspend({}) (NESTED) -> install re-enters :734 and OVERWRITES
    //    the single saved slot; the outer pre-suspend mask (orig) is destroyed here.
    let _ = pm.install_sigsuspend_mask(bug_pid, bug_tid, 0);
    let saved_after_nested: Option<u64> = saved_of(&mut pm, BUG_TID);
    // 5. Inner sigsuspend unwinds -> consumes the single slot (take_saved_blocked).
    let _ = pm.restore_sigsuspend_mask(bug_tid);
    let saved_after_inner: Option<u64> = saved_of(&mut pm, BUG_TID);
    // 6. OUTER sigsuspend unwinds -> slot already empty -> cannot reinstate orig.
    let _ = pm.restore_sigsuspend_mask(bug_tid);

    // Observe through REAL consumers.
    let bug_final: u64 = pm.sigprocmask(bug_tid, SIG_SETMASK, None).unwrap_or(0);
    let bug_usr2_blocked: bool = (bug_final & usr2) != 0;
    // Post SIGUSR2 (Handler disposition) through the REAL kill path, then ask the REAL sigpending
    // (pending & blocked). SIGUSR2 pending but NOT in the masked set == deliverable.
    let _ = pm.sigaction(bug_pid, SIGUSR2, Some(handler_disposition()));
    let _ = pm.kill(caller, bug_pid, SIGUSR2);
    let bug_sigpending: u64 = pm.sigpending(bug_pid, bug_tid).unwrap_or(0);
    let bug_usr2_deliverable: bool = (bug_sigpending & usr2) == 0;

    // ================= CONTROL: single (non-nested) sigsuspend -> orig correctly restored ===========
    let _ = pm.sigprocmask(ctl_tid, SIG_SETMASK, Some(orig));
    let _ = pm.install_sigsuspend_mask(ctl_pid, ctl_tid, 0);
    let ctl_saved: Option<u64> = saved_of(&mut pm, CTL_TID);
    let _ = pm.restore_sigsuspend_mask(ctl_tid);
    let ctl_final: u64 = pm.sigprocmask(ctl_tid, SIG_SETMASK, None).unwrap_or(0);
    let ctl_usr2_blocked: bool = (ctl_final & usr2) != 0;
    let _ = pm.sigaction(ctl_pid, SIGUSR2, Some(handler_disposition()));
    let _ = pm.kill(caller, ctl_pid, SIGUSR2);
    let ctl_sigpending: u64 = pm.sigpending(ctl_pid, ctl_tid).unwrap_or(0);
    let ctl_usr2_deliverable: bool = (ctl_sigpending & usr2) == 0;

    info!(
        "MC-10a slot: saved_after_outer={saved_after_outer:?} saved_after_nested={saved_after_nested:?} \
         saved_after_inner={saved_after_inner:?} (orig={orig:#06x}=SIGUSR2 handler_mask={handler_mask:#06x}=SIGUSR1)"
    );
    info!(
        "MC-10a BUG (nested): final_blocked={bug_final:#06x} usr2_still_blocked={bug_usr2_blocked} \
         sigpending(pending&blocked)={bug_sigpending:#06x} usr2_deliverable={bug_usr2_deliverable} \
         (POSIX-correct: usr2_still_blocked=true, usr2_deliverable=false)"
    );
    info!(
        "MC-10a CONTROL (single): saved={ctl_saved:?} final_blocked={ctl_final:#06x} \
         usr2_still_blocked={ctl_usr2_blocked} sigpending={ctl_sigpending:#06x} \
         usr2_deliverable={ctl_usr2_deliverable} (single sigsuspend must restore orig)"
    );

    // Reproduced when, under an all-real-API nested sigsuspend:
    //  - the nested install OVERWROTE the single slot (saved went orig -> handler_mask -> None),
    //    proving the outer saved mask was destroyed; and
    //  - the outer unwind could NOT reinstate orig, so the app-blocked SIGUSR2 is now UNBLOCKED and
    //    a freshly posted SIGUSR2 is deliverable through the same `!blocked` term the delivery path
    //    uses; WHILE
    //  - the single-sigsuspend CONTROL correctly restored orig (SIGUSR2 still blocked, not
    //    deliverable) — proving the sole cause of the wrong outcome is the nesting overwrite.
    let overwrote: bool = saved_after_outer == Some(orig)
        && saved_after_nested == Some(handler_mask)
        && saved_after_inner.is_none();
    let bug_lost_orig: bool = !bug_usr2_blocked && bug_usr2_deliverable;
    let control_ok: bool = ctl_saved == Some(orig) && ctl_usr2_blocked && !ctl_usr2_deliverable;
    let reproduced: bool = overwrote && bug_lost_orig && control_ok;

    if reproduced {
        error!(
            "MC-10a BUG REPRODUCED: a nested sigsuspend OVERWROTE the single saved_blocked slot \
             (install_sigsuspend_mask mod.rs:734 set_saved_blocked over Option<u64> thread/state.rs:105): \
             saved went Some({orig:#06x}=SIGUSR2 pre-suspend) -> Some({handler_mask:#06x}=SIGUSR1) on the \
             nested install -> None after the inner unwind, so the OUTER sigsuspend could not reinstate \
             the pre-suspend mask. Final blocked={bug_final:#06x}: the app-blocked SIGUSR2 is now UNBLOCKED \
             and a freshly posted SIGUSR2 is deliverable (sigpending={bug_sigpending:#06x}) — the same \
             `!blocked` term try_deliver_signal (manager/signal.rs:242) acts on. An identical SINGLE \
             sigsuspend correctly restored orig (SIGUSR2 still blocked). POSIX: sigsuspend must restore \
             the pre-call mask. SavedMaskRestored violated."
        );
    } else {
        info!(
            "MC-10a NOT-REPRODUCED: overwrote={overwrote} bug_lost_orig={bug_lost_orig} control_ok={control_ok}"
        );
    }

    // Drop the isolated manager, reclaiming the test address spaces.
    drop(pm);
    true
}
