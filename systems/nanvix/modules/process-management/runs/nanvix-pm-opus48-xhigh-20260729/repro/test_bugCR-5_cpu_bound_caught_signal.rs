// CR-5 reproduction — guest-side test (snapshot for reference).
//
// This is the reproduction test added to the existing kill() integration suite at
//   src/tests/integration/test-rust-kill/src/tests/kill.rs
// and registered as the last entry of `pub fn run()`. It is driven by
//   repro/test_bugCR-5_cpu_bound_caught_signal.sh
// which builds the standalone `test-rust-kill.initrd` image and boots it under nanvixd
// (KVM microvm), then checks the console output for the reproduction signature.
//
// BUG (CR-5): The kernel delivers a *caught* signal only at the kernel-call return-to-user
// checkpoint (`deliver_pending_signals()` at the end of `do_kcall`,
// src/kernel/src/kcall/dispatcher.rs:245). There is NO delivery checkpoint on return from the
// timer interrupt (src/kernel/src/pm/clock.rs:109 `timer_handler` -> ProcessManager::tick(),
// src/kernel/src/pm/process/manager/unsafe.rs:899, which only reschedules — it never calls
// deliver_pending_signals / try_deliver_signal). Also, kill() for a caught signal only interrupts
// a *suspended* candidate thread (`interrupt_signal_candidate`, manager/mod.rs:1009 scans only the
// `suspended` list). Therefore a purely CPU-bound thread that never issues a kernel call never
// reaches a delivery point, and a caught signal posted to it via kill() is never delivered while it
// spins — even though the periodic timer preempts and reschedules it thousands of times.
//
// LEVEL 0 (pure black-box): only public APIs (fork, sigaction, sigprocmask, kill, IPC, waitpid,
// _exit). No failpoints, no state injection, no kernel source patch, no timing hacks.
//
// EXPECTED (POSIX / correct kernel): the handler runs during the spin -> child exits DELIVERED(71).
// OBSERVED (this kernel): the child completes its whole bounded spin undelivered -> exits
// NOT_DELIVERED(72); the parent's assertion then fails, reproducing CR-5.

// ---- Added imports (top of kill.rs) ----
//   ::syscall::unistd            (for unistd::write)
//   ::sysapi::unistd::STDOUT_FILENO
//   ::sys::pm::SIG_UNBLOCK

/// Records whether the CR-5 reproduction child's caught `SIGUSR1` handler ran.
static CR5_HANDLER_RAN: AtomicBool = AtomicBool::new(false);

/// Exit status: the CPU-bound child observed its caught-signal handler run *during* its spin.
const CR5_DELIVERED_DURING_SPIN: c_int = 71;
/// Exit status: the CPU-bound child completed its *entire* bounded spin without the handler ever
/// running — the CR-5 defect.
const CR5_NOT_DELIVERED_DURING_SPIN: c_int = 72;

/// Number of pure CPU-bound spin iterations the reproduction child performs while polling for its
/// caught-signal handler. Each iteration issues a `pause`, so this bound spans several seconds of
/// wall-clock CPU — a ~1000x margin over a correct kernel's sub-millisecond delivery latency — yet
/// is bounded so the buggy kernel (which never delivers to a running thread) terminates instead of
/// hanging forever.
const CR5_SPIN_ITERS: u64 = 100_000_000;

extern "C" fn cr5_sigusr1_handler(_signum: c_int) {
    CR5_HANDLER_RAN.store(true, Ordering::SeqCst);
}

#[allow(clippy::as_conversions)]
fn cr5_sigusr1_handler_addr() -> usize {
    cr5_sigusr1_handler as *const () as usize
}

/// CR-5 reproduction child. Installs a caught `SIGUSR1` handler, unblocks `SIGUSR1`, notifies the
/// parent it is about to spin (its *last* kernel call), then spins in a pure CPU-bound loop with no
/// kernel calls, polling for the handler.
fn run_cr5_spin_child() -> ! {
    CR5_HANDLER_RAN.store(false, Ordering::SeqCst);

    let parent: ProcessIdentifier = match pm::__kcall_getppid() {
        Ok(parent) => parent,
        Err(_) => unsafe { bindings::_exit::_exit(CHILD_FAIL) },
    };
    let signum: c_int = match as_signum(SIGUSR1) {
        Ok(signum) => signum,
        Err(_) => unsafe { bindings::_exit::_exit(CHILD_FAIL) },
    };

    let act: SigAction = SigAction {
        sa_handler: cr5_sigusr1_handler_addr(),
        sa_mask: 0,
        sa_flags: 0,
        sa_sigaction: 0,
    };
    if unsafe { pm::__kcall_sigaction(signum, &raw const act, ptr::null_mut()) }.is_err() {
        unsafe { bindings::_exit::_exit(CHILD_FAIL) };
    }

    let unblock: SigSet = 1u64 << (SIGUSR1 - 1);
    if unsafe { pm::__kcall_sigprocmask(SIG_UNBLOCK, &raw const unblock, ptr::null_mut()) }.is_err() {
        unsafe { bindings::_exit::_exit(CHILD_FAIL) };
    }

    if notify_ready(parent).is_err() {
        unsafe { bindings::_exit::_exit(CHILD_FAIL) };
    }

    let mut i: u64 = 0;
    while i < CR5_SPIN_ITERS {
        if CR5_HANDLER_RAN.load(Ordering::SeqCst) {
            unsafe { bindings::_exit::_exit(CR5_DELIVERED_DURING_SPIN) };
        }
        ::core::hint::spin_loop();
        i += 1;
    }
    unsafe { bindings::_exit::_exit(CR5_NOT_DELIVERED_DURING_SPIN) };
}

fn spawn_cr5_spin_child() -> Result<ProcessIdentifier, Error> {
    let ret: pid_t = bindings::fork::fork();
    if ret == 0 {
        run_cr5_spin_child();
    }
    assert!(ret > 0, "fork() failed in parent (ret={})", ret);
    Ok(ProcessIdentifier::from(ret))
}

fn test_cr5_caught_signal_to_cpu_bound() -> Result<(), Error> {
    let child: ProcessIdentifier = spawn_cr5_spin_child()?;
    await_ready()?;

    // The child is now spinning CPU-bound. Post the caught signal; a POSIX kernel delivers it at the
    // next return-to-user from the periodic timer interrupt, long before the bounded spin ends.
    post_signal(child, as_signum(SIGUSR1)?);

    let mut status: c_int = 0;
    let reaped: pid_t = unsafe { bindings::waitpid::waitpid(i32::from(child), &raw mut status, 0) };
    assert!(reaped == i32::from(child), "waitpid() must reap the CR-5 child (ret={})", reaped);
    assert!(wifexited(status), "CR-5 child must exit normally (status={:#x})", status);
    let observed: c_int = wexitstatus(status);

    let banner: &[u8] = if observed == CR5_NOT_DELIVERED_DURING_SPIN {
        b"\n[CR-5] REPRODUCED: caught SIGUSR1 was NEVER delivered to a CPU-bound thread while it spun\n"
    } else if observed == CR5_DELIVERED_DURING_SPIN {
        b"\n[CR-5] not-reproduced: caught SIGUSR1 handler ran during the CPU-bound spin\n"
    } else {
        b"\n[CR-5] inconclusive: CR-5 child setup failed\n"
    };
    let _ = unistd::write(STDOUT_FILENO, banner);

    assert!(
        observed == CR5_DELIVERED_DURING_SPIN,
        "CR-5 REPRODUCED: a caught SIGUSR1 posted to a CPU-bound thread was never delivered while it \
         spun (child exit={}, expected DELIVERED={}, observed NOT_DELIVERED={}).",
        observed, CR5_DELIVERED_DURING_SPIN, CR5_NOT_DELIVERED_DURING_SPIN
    );
    Ok(())
}
