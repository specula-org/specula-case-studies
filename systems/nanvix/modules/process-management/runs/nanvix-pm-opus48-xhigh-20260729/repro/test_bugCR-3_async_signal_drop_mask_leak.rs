// Reference copy of the in-kernel reproduction test for finding CR-3.
// Location in tree: src/kernel/src/pm/process/manager/test.rs
// Wired into the aggregator test() and executed during pm::init() when the kernel is built
// with the 'test' feature (make all-test-kernel; booted via scripts/run-uservm.py / uservm.elf).
//
// Driver: repro/test_bugCR-3_async_signal_drop_mask_leak.sh

/// Reproduction for finding CR-3: the asynchronous caught-signal delivery checkpoint
/// [`ProcessManager::try_deliver_signal`] silently drops the signal and leaks the `sigsuspend()`
/// temporary mask when the target process has installed a caught-signal handler but no restorer
/// trampoline.
///
/// The scenario is reachable through the real kernel interface: `sigaction()` installs a `Handler`
/// disposition independently of `sig_restorer()` (they are distinct kernel calls, and crt0 registers
/// the restorer only best-effort), so a process can catch a signal with the restorer unset. The
/// synchronous exception path ([`ProcessManager::try_deliver_synchronous_signal`]) already handles
/// this by returning `Terminate`; the asynchronous path instead clears the pending signal, returns
/// `None`, and — crucially — never restores the mask a `sigsuspend()` saved, so the per-thread
/// blocked mask is permanently corrupted.
///
/// This test builds a real running process whose single thread has a real kernel stack stamped with
/// a synthetic ring-3 trap frame (so the delivery checkpoint believes it returns to user mode),
/// installs a real `sigsuspend()` mask via [`ProcessManager::install_sigsuspend_mask`], posts a
/// caught signal, and then drives the real `try_deliver_signal`. It asserts the *correct* behavior
/// (loud failure via `Escalate`, or the `sigsuspend()` mask restored); under the current code both
/// fail, demonstrating the swallowed signal plus the leaked mask.
///
/// Returns `true` only if the kernel behaves correctly; `false` (the current, buggy result) means
/// the bug reproduced.
#[cfg(target_arch = "x86")]
fn test_async_delivery_without_restorer_drops_signal_and_leaks_sigsuspend_mask() -> bool {
    use crate::{
        hal::{
            arch::{
                x86::cpu::FpuState,
                ContextInformation,
            },
            mem::VirtualAddress,
        },
        mm::{
            kstack::KernelStack,
            VirtMemoryManager,
        },
        pm::process::state::{
            signal::{
                SignalDisposition,
                SignalHandler,
            },
            RunnableProcess,
        },
    };
    use crate::pm::thread::ReadyThread;
    use super::SignalDeliveryOutcome;
    use ::sys::mm::Address;
    use ::alloc::boxed::Box;
    use ::sys::pm::{
        ThreadIdentifier,
        SIGCHLD,
        SIGUSR1,
        SIGUSR2,
    };

    // D: the caught signal delivered asynchronously. P: a signal blocked before sigsuspend().
    // T: the signal blocked by the sigsuspend() temporary mask. All distinct and catchable.
    const D: usize = SIGUSR1;
    const P: usize = SIGUSR2;
    const T: usize = SIGCHLD;
    let pre_suspend: u64 = 1u64 << (P - 1);
    let temp: u64 = 1u64 << (T - 1);
    let d_bit: u64 = 1u64 << (D - 1);

    let pid: ProcessIdentifier = ProcessIdentifier::from(4242);
    let tid: ThreadIdentifier = ThreadIdentifier::from(4242);

    // SAFETY: the process and virtual memory managers are initialized before in-kernel tests run;
    // access is synchronized because the kernel is single-threaded with interrupts disabled.
    let pm: &mut ProcessManager = unsafe { ProcessManager::get_mut() };

    // Build a fresh user-like address space cloned from the running (kernel) process.
    let vmem = {
        let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
        match mm.new_vmem(pm.current_vmem()) {
            Ok(vmem) => vmem,
            Err(error) => {
                error!("CR-3-REPRO: new_vmem failed (error={error:?})");
                return false;
            },
        }
    };

    // Allocate a real kernel stack for the fixture thread.
    let kstack = {
        let mm: &mut VirtMemoryManager = unsafe { VirtMemoryManager::get_mut() };
        match KernelStack::new(mm) {
            Ok(kstack) => kstack,
            Err(error) => {
                error!("CR-3-REPRO: KernelStack::new failed (error={error:?})");
                return false;
            },
        }
    };

    // Transition a ready thread (owning the kernel stack) into a running process fixture.
    let ready: ReadyThread = ReadyThread::new(
        tid,
        Some(kstack),
        None,
        None,
        ContextInformation::default(),
        // SAFETY: FpuState::new is synchronized (single-threaded kernel).
        unsafe { FpuState::new() },
    );
    let (mut running, _reason, _ctx, _tda) =
        RunnableProcess::new(pid, ProcessIdentifier::from(0), ready, vmem).run();

    // Install a caught handler for D and ensure NO restorer is registered (the reachable
    // precondition: sigaction() without sig_restorer()).
    {
        let signals = running.state_mut().signals_mut();
        signals.set_disposition(
            D,
            SignalDisposition::Handler(Box::new(SignalHandler {
                // Arbitrary user-space-looking handler entry. It is never dereferenced on the
                // no-restorer path, which returns before reading the trap frame.
                entry: VirtualAddress::new(0x4000_0000),
                mask: 0,
                flags: 0,
                sigaction: 0,
            })),
        );
        signals.set_restorer(None);
    }

    // Read the kernel-stack top (esp0) and stamp a synthetic ring-3 trap frame so the delivery
    // checkpoint's returning_to_user() gate passes. The x86 TrapFrame is 10 words just below esp0;
    // CS is the 7th word, i.e. at esp0-16. Writing a user selector (RPL=3) there is enough.
    let esp0: usize = match running.find_thread_mut(tid) {
        Some(mut thread) => match thread.thread_state_mut().kernel_stack_top() {
            Some(top) => top.into_raw_value(),
            None => {
                error!("CR-3-REPRO: fixture thread has no kernel stack");
                return false;
            },
        },
        None => {
            error!("CR-3-REPRO: fixture thread not found");
            return false;
        },
    };
    const OFF_CS: usize = 16;
    const USER_CS_RPL3: u32 = 0x1B;
    // SAFETY: esp0-16 lies within the freshly allocated kernel-stack pages (top is one-past-end).
    unsafe {
        core::ptr::write_volatile((esp0 - OFF_CS) as *mut u32, USER_CS_RPL3);
    }

    // Establish the pre-suspend blocked mask on the running thread.
    if let Some(mut thread) = running.find_thread_mut(tid) {
        thread.thread_state_mut().set_blocked(pre_suspend);
    }

    // Swap the fixture in as the running process. From here we must restore the saved (kernel)
    // running process before returning, avoiding any panicking operation in between.
    let saved = core::mem::replace(&mut pm.running, Some(running));

    // Drive the REAL sigsuspend() mask install: saves the pre-suspend mask into saved_blocked and
    // installs the temporary mask as the thread's blocked mask.
    let _ = pm.install_sigsuspend_mask(pid, tid, temp);

    // Post the caught signal D as thread-directed pending (as kill()/exception delivery would).
    if let Ok(mut thread) = pm.find_thread_mut(tid) {
        thread.thread_state_mut().post_pending(D);
    }

    // Invoke the REAL asynchronous-delivery checkpoint (the code under test).
    let outcome: SignalDeliveryOutcome = pm.try_deliver_signal(0);

    // Observe the post-delivery thread state.
    let (post_blocked, post_saved, post_pending): (u64, Option<u64>, u64) =
        match pm.find_thread_mut(tid) {
            Ok(mut thread) => {
                let state = thread.thread_state_mut();
                (state.blocked(), state.saved_blocked_ref(), state.pending())
            },
            Err(_) => (0, None, 0),
        };

    // Restore the real (kernel) running process before returning.
    pm.running = saved;

    // Evaluate. Correct behavior on a missing restorer is a loud failure (Escalate -> terminate) or,
    // at minimum, restoration of the sigsuspend() mask (blocked == pre_suspend, saved_blocked None).
    let signal_swallowed: bool =
        matches!(outcome, SignalDeliveryOutcome::None) && (post_pending & d_bit) == 0;
    let mask_leaked: bool = post_blocked == temp && post_saved == Some(pre_suspend);

    error!(
        "CR-3-REPRO: outcome={:?} (expected Escalate to terminate on missing restorer)",
        outcome
    );
    error!(
        "CR-3-REPRO: blocked after delivery={:#x} temp={:#x} pre_suspend={:#x}",
        post_blocked, temp, pre_suspend
    );
    error!(
        "CR-3-REPRO: saved_blocked after delivery={:?} (expected None once sigsuspend unwinds)",
        post_saved
    );
    error!(
        "CR-3-REPRO: caught signal D pending-after-delivery={} (a delivered/terminated signal \
         would not silently remain cleared-and-swallowed)",
        (post_pending & d_bit) != 0
    );

    if signal_swallowed && mask_leaked {
        error!(
            "CR-3-REPRO: BUG REPRODUCED: async caught signal silently dropped (no loud failure) \
             AND sigsuspend() temporary mask leaked (blocked stuck at temp, saved_blocked never \
             restored)"
        );
    }

    // Return whether the kernel behaved correctly. It did NOT (bug present) -> false.
    let correct: bool = !(signal_swallowed && mask_leaked);
    if correct {
        info!("CR-3-REPRO: kernel behaved correctly (bug appears fixed)");
    }
    correct
}
