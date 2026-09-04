// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// MC-9 reproduction
//==================================================================================================
//
// Reproduction for finding MC-9: "Immortal pending signal after a disposition change".
//
// Invariant NoImmortalPending (MCNoImmortalPending), config MC_hunt_scenario6.cfg,
// counterexample spec/output/MC_hunt_MC-9.out (trace length 5). CE actions:
//   Initial -> MCCreateProcess(p1 ready) -> MCSetDisposition(disposition[p1][1]=handler)
//           -> MCPostSignalHandler(pending[p1]={1}) -> MCSetDisposition(disposition[p1][1]=default)
//   State 5: pending[p1]={1}, disposition[p1][1]=default, immortalPending=TRUE.
//
// ROOT CAUSE (real code):
//   `SignalControl::set_disposition` (state/signal.rs:364-371) only `core::mem::replace`s the
//   disposition slot; it NEVER clears a pending instance. `ProcessManager::sigaction`
//   (manager/mod.rs:583-614) calls it at :605 and never touches the pending set. `kill`
//   (manager/mod.rs:849-882) posts a signal to the process pending set ONLY on the `Handler` arm
//   (:854-855); `try_deliver_signal` (manager/signal.rs:240-253) delivers ONLY `Handler`
//   dispositions and skips every other pending signal (leaving it pending). Therefore a signal
//   posted while caught (Handler) and then re-dispositioned via `sigaction` to `SIG_DFL` or
//   `SIG_IGN` is neither discarded nor delivered: it is stuck pending forever (NoImmortalPending
//   violated), contrary to POSIX SIG_IGN pending-discard semantics.
//
// HOW THIS REPRODUCES IT (in-kernel, feature = "test"; real entry points, NO product logic altered):
//   Builds an ISOLATED `ProcessManager` (the live kernel lists are untouched). Each single-threaded
//   target is driven through the REAL create-transition path a freshly created process reaches
//   (`RunnableProcess::new` -> `run` -> `sleep(None)`, == CE step MCCreateProcess followed by a
//   blocking kcall). The caught+pending precondition is then built by the REAL entry points
//   `sigaction` (kcall 41, == CE MCSetDisposition(handler)) and `kill` (kcall 43, from a caller
//   granted Capability::ProcessManagement via the REAL `capctl`, == CE MCPostSignalHandler). The
//   fatal re-disposition is the REAL `sigaction` (== CE MCSetDisposition(default/ignore)).
//
//   The wrong outcome is then observed through REAL consumers of the pending set — no internal
//   state is hand-constructed and the delivery selection loop is NOT replicated:
//     - `install_sigsuspend_mask` (manager/mod.rs:722): the REAL `sigsuspend()` deliverability
//       oracle. It returns `true` iff a pending caught signal is deliverable under the temporary
//       mask (so sigsuspend returns EINTR instead of sleeping forever). It uses the SAME
//       "only Handler dispositions" selection as try_deliver_signal.
//     - `signals().pending()` (manager/signal.rs:242): the exact set try_deliver_signal consumes.
//
//   Three single-threaded suspended targets (only the disposition timeline differs):
//     CONTROL   [handler installed, posted, NEVER re-dispositioned]
//                 -> install_sigsuspend_mask == true (a caught pending signal IS deliverable).
//     CASE B    [handler -> post -> SIG_DFL]  (the EXACT CE trace)
//                 -> pending STILL has the bit (immortal), and install_sigsuspend_mask == false:
//                    a real sigsuspend() would sleep forever on a signal that is neither delivered
//                    nor discarded. Permanence re-checked after a query sigaction(None) + null
//                    kill(0). => NoImmortalPending violated (CE State 5 exactly).
//     CASE A    [handler -> post -> SIG_IGN -> reinstall handler]
//                 -> after SIG_IGN the pending bit is NOT discarded (POSIX violation); reinstalling
//                    a handler makes install_sigsuspend_mask == true again -> the "ignored" signal
//                    is SPURIOUSLY resurrected and delivered.
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
            error!("MC-9 repro: new_vmem failed (error={e:?})");
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
/// to sleep: `RunnableProcess::new` (what `create_process` publishes) -> `run` -> `sleep(None)`
/// (fully suspended, no other runnable thread). This is exactly the CE create step followed by a
/// blocking kernel call; the immortal-pending invariant is over (pending set x disposition) and is
/// independent of which scheduling list the target occupies. Returns `false` on setup failure.
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
            error!("MC-9 repro: process pid={pid} unexpectedly stayed runnable after sleep");
            false
        },
    }
}

/// Returns the target's process-directed pending signal set (0 if the process is gone). This reads
/// the SAME `signals().pending()` set that `try_deliver_signal` (manager/signal.rs:242) consumes.
fn pending_of(pm: &ProcessManager, pid: i32) -> u64 {
    pm.find_process(ProcessIdentifier::from(pid))
        .map(|proc| proc.state().signals().pending())
        .unwrap_or(0)
}

/// Invokes the REAL `sigsuspend()` deliverability oracle (`install_sigsuspend_mask`) with an empty
/// temporary mask (== `sigsuspend(empty)` waiting for any signal). Returns `true` iff a pending
/// caught signal is deliverable — i.e. iff sigsuspend would return EINTR instead of sleeping.
fn sigsuspend_deliverable(pm: &mut ProcessManager, pid: i32, tid: i32) -> bool {
    match pm.install_sigsuspend_mask(
        ProcessIdentifier::from(pid),
        ThreadIdentifier::from(tid),
        0,
    ) {
        Ok(deliverable) => deliverable,
        Err(e) => {
            error!("MC-9 repro: install_sigsuspend_mask failed (pid={pid}, error={e:?})");
            false
        },
    }
}

///
/// # Description
///
/// Reproduces finding MC-9. Returns `true` once the scenario has been driven (so the in-kernel boot
/// test suite proceeds); the concrete verdict is emitted as `MC-9 ...` log markers.
///
pub(super) fn run() -> bool {
    // SIGTERM (15): blockable, catchable, and its default action is Terminate. bit 14.
    let bit: u64 = 1u64 << (SIGTERM - 1);

    // Build an isolated process manager so the live kernel's process lists are untouched. Its
    // running process is the KERNEL process; grant it ProcessManagement so it may post cross-process
    // signals (as procd does in production) through the REAL capctl entry point.
    let (kernel, tm) = thread::init();
    let root: Vmem = match fresh_vmem() {
        Some(v) => v,
        None => return true,
    };
    let mut pm: ProcessManager = ProcessManager::new(false, kernel, root, tm);
    let caller: ProcessIdentifier = ProcessIdentifier::KERNEL;
    let _ = pm.capctl(caller, Capability::ProcessManagement, true);

    const CT_PID: i32 = 230; // CONTROL: handler, posted, never re-dispositioned
    const CT_TID: i32 = 50;
    const B_PID: i32 = 231; //  CASE B: handler -> post -> SIG_DFL (exact CE)
    const B_TID: i32 = 51;
    const A_PID: i32 = 232; //  CASE A: handler -> post -> SIG_IGN -> reinstall handler
    const A_TID: i32 = 52;

    if !spawn_suspended(&mut pm, CT_PID, CT_TID)
        || !spawn_suspended(&mut pm, B_PID, B_TID)
        || !spawn_suspended(&mut pm, A_PID, A_TID)
    {
        return true;
    }

    // ---- CONTROL: handler installed, SIGTERM posted, NEVER re-dispositioned. -----------------------
    // Proves the harness observes a real delivery decision: a caught pending signal IS deliverable.
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(CT_PID), SIGTERM, Some(handler_disposition())) {
        error!("MC-9 repro: CONTROL sigaction(handler) failed (error={e:?})");
        return true;
    }
    let ct_kill = pm.kill(caller, ProcessIdentifier::from(CT_PID), SIGTERM);
    let ct_pending: u64 = pending_of(&pm, CT_PID);
    let ct_deliverable: bool = sigsuspend_deliverable(&mut pm, CT_PID, CT_TID);

    // ---- CASE B: handler -> post -> SIG_DFL. This is the EXACT CE trace. ---------------------------
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(B_PID), SIGTERM, Some(handler_disposition())) {
        error!("MC-9 repro: CASE B sigaction(handler) failed (error={e:?})");
        return true;
    } // CE State 3: disposition[p][SIGTERM]=handler
    let b_kill = pm.kill(caller, ProcessIdentifier::from(B_PID), SIGTERM); // CE State 4: pending={SIGTERM}
    let b_pending_posted: u64 = pending_of(&pm, B_PID);
    // Re-disposition to SIG_DFL while the signal is already pending (CE State 5).
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(B_PID), SIGTERM, Some(SignalDisposition::Default)) {
        error!("MC-9 repro: CASE B sigaction(SIG_DFL) failed (error={e:?})");
        return true;
    }
    let b_pending_after_dfl: u64 = pending_of(&pm, B_PID);
    // REAL sigsuspend() oracle: with the signal pending & unblocked but its disposition no longer a
    // Handler, delivery is skipped -> sigsuspend would sleep forever. The signal is immortal.
    let b_deliverable: bool = sigsuspend_deliverable(&mut pm, B_PID, B_TID);
    // Permanence: further manager operations do not clear it (query sigaction + POSIX null probe).
    let _ = pm.sigaction(ProcessIdentifier::from(B_PID), SIGTERM, None);
    let _ = pm.kill(caller, ProcessIdentifier::from(B_PID), 0);
    let b_pending_permanent: u64 = pending_of(&pm, B_PID);

    // ---- CASE A: handler -> post -> SIG_IGN -> reinstall handler. ----------------------------------
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(A_PID), SIGTERM, Some(handler_disposition())) {
        error!("MC-9 repro: CASE A sigaction(handler) failed (error={e:?})");
        return true;
    }
    let _ = pm.kill(caller, ProcessIdentifier::from(A_PID), SIGTERM);
    // POSIX: setting the disposition to SIG_IGN must DISCARD any pending instance of the signal.
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(A_PID), SIGTERM, Some(SignalDisposition::Ignore)) {
        error!("MC-9 repro: CASE A sigaction(SIG_IGN) failed (error={e:?})");
        return true;
    }
    let a_pending_after_ign: u64 = pending_of(&pm, A_PID);
    // Reinstall a handler: the un-discarded pending bit is resurrected and now selectable.
    if let Err(e) = pm.sigaction(ProcessIdentifier::from(A_PID), SIGTERM, Some(handler_disposition())) {
        error!("MC-9 repro: CASE A sigaction(reinstall handler) failed (error={e:?})");
        return true;
    }
    let a_spurious_deliverable: bool = sigsuspend_deliverable(&mut pm, A_PID, A_TID);

    info!(
        "MC-9 CONTROL (handler, never re-dispositioned): kill={ct_kill:?} \
         pending={ct_pending:#018b} sigsuspend_deliverable={ct_deliverable} \
         (expected: pending has SIGTERM, deliverable=true)"
    );
    info!(
        "MC-9 CASE B (handler -> post -> SIG_DFL, exact CE): kill={b_kill:?} \
         pending_posted={b_pending_posted:#018b} pending_after_dfl={b_pending_after_dfl:#018b} \
         sigsuspend_deliverable={b_deliverable} pending_after_query+nullkill={b_pending_permanent:#018b} \
         (POSIX/immortal: pending should NOT persist inert; a real sigsuspend sleeps forever)"
    );
    info!(
        "MC-9 CASE A (handler -> post -> SIG_IGN -> reinstall handler): \
         pending_after_ign={a_pending_after_ign:#018b} spurious_deliverable_after_reinstall={a_spurious_deliverable} \
         (POSIX: SIG_IGN must DISCARD pending; expected pending_after_ign=0)"
    );

    // The bug is reproduced when, driven ONLY through real entry points:
    //  - CONTROL: a caught pending signal is deliverable (harness sanity: it CAN observe delivery);
    //  - CASE B: after re-disposition to SIG_DFL the signal is STILL pending (immortal) yet the REAL
    //    sigsuspend() oracle reports it NON-deliverable, and it survives further manager ops
    //    (permanence) -> NoImmortalPending violated, matching CE State 5 exactly;
    //  - CASE A: after SIG_IGN the signal is NOT discarded, and a later handler reinstall makes it
    //    spuriously deliverable again -> POSIX SIG_IGN discard semantics violated.
    let control_ok: bool = (ct_pending & bit) != 0 && ct_deliverable;
    let case_b_immortal: bool = (b_pending_posted & bit) != 0
        && (b_pending_after_dfl & bit) != 0
        && !b_deliverable
        && (b_pending_permanent & bit) != 0;
    let case_a_undiscarded: bool = (a_pending_after_ign & bit) != 0 && a_spurious_deliverable;
    let reproduced: bool = control_ok && case_b_immortal && case_a_undiscarded;

    if reproduced {
        error!(
            "MC-9 BUG REPRODUCED: a SIGTERM posted while caught (Handler) and then re-dispositioned \
             via sigaction to SIG_DFL (CASE B, exact CE) remained pending forever -- the REAL \
             sigsuspend() oracle (install_sigsuspend_mask) reports it non-deliverable, so a real \
             sigsuspend() would sleep forever on a signal that is neither delivered nor discarded, \
             and it survives further sigaction/kill operations (permanence). Under SIG_IGN (CASE A) \
             the pending instance is NOT discarded and a later handler reinstall SPURIOUSLY \
             resurrects it. set_disposition (state/signal.rs:364) only swaps the disposition slot; \
             sigaction (manager/mod.rs:605) never clears pending; try_deliver_signal / \
             install_sigsuspend_mask select ONLY Handler dispositions. NoImmortalPending violated, \
             contrary to POSIX SIG_IGN pending-discard semantics."
        );
    } else {
        info!(
            "MC-9 NOT-REPRODUCED: control_ok={control_ok}, case_b_immortal={case_b_immortal} \
             (posted={b_pending_posted:#018b}, after_dfl={b_pending_after_dfl:#018b}, \
             deliverable={b_deliverable}, permanent={b_pending_permanent:#018b}), \
             case_a_undiscarded={case_a_undiscarded} (after_ign={a_pending_after_ign:#018b}, \
             spurious={a_spurious_deliverable})"
        );
    }

    // Drop the isolated manager, reclaiming the test address spaces.
    drop(pm);
    true
}
