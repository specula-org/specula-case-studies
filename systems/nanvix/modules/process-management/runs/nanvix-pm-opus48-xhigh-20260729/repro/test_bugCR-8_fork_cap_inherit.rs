// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! # fork/duplicate Capability-Inheritance Reproduction (CR-8)
//!
//! Reproduces the behaviour at `src/kernel/src/pm/process/state/mod.rs:253`, where
//! `ProcessState::new` unconditionally sets `capabilities: Capabilities::default()` (empty). The
//! fork/duplicate path (`ProcessManager::duplicate_process`, manager/mod.rs:1485) explicitly
//! inherits the parent's **signal** state (`set_signals(inherited_signals)`, line 1629) but has NO
//! equivalent step for **capabilities**, so a forked child always starts with an EMPTY capability
//! set — it does NOT inherit the parent's, unlike the documented libc `fork()` "exact copy of the
//! calling process" contract (unistd/bindings/fork.rs:18-19).
//!
//! This runs entirely at Level 0 through the public kcall API (an integration TEST is added to the
//! shipped test daemon `testd`; no system logic is modified). It is non-destructive: the
//! capability probe targets a process id that cannot exist (1_000_000), so `terminate()` can only
//! ever fail at the target-lookup stage and never actually kills anything. The capability state is
//! read purely from the `terminate()` authorization gate's error code:
//!   * `PermissionDenied`  => caller does NOT hold `ProcessManagement` (gate fires before lookup).
//!   * `NoSuchProcess`     => caller DOES hold `ProcessManagement` (gate passed; lookup then fails).
//!
//! Sequence:
//!   1. Parent (testd, unprivileged) probes the gate: `PermissionDenied` (baseline).
//!   2. Parent self-grants `ProcessManagement` (ungated capctl) and re-probes: `NoSuchProcess`
//!      (gate passes for the parent).
//!   3. Parent forks a child via `__kcall_duplicate`. The child probes the SAME gate:
//!        - INHERITED would show `NoSuchProcess`.
//!        - THE OBSERVED BEHAVIOUR is `PermissionDenied` -> the child did NOT inherit the
//!          parent's `ProcessManagement` capability.
//!   4. The child then self-grants `ProcessManagement` (ungated capctl, separately CR-7) and
//!      re-probes: `NoSuchProcess`. This demonstrates the MASK: the child is never actually stuck,
//!      because the ungated self-service `capctl` lets it re-establish any capability on demand.

//==================================================================================================
// Imports
//==================================================================================================

use ::arch::mem::PAGE_SIZE;
use ::proc::{
    wait,
    WaitOutcome,
    WaitTarget,
};
use ::sys::{
    error::ErrorCode,
    kcall::{
        mm,
        pm,
        sched,
    },
    mm::{
        AccessPermission,
        VirtualAddress,
    },
    pm::{
        Capability,
        ProcessIdentifier,
        ThreadCreateArgs,
    },
};

//==================================================================================================
// Constants
//==================================================================================================

/// A process identifier guaranteed not to correspond to any live process. Daemons occupy the low
/// pids and the init process a small pid; a value this large can never be a real pid, so a
/// termination request can only ever fail at the target-lookup stage — never actually kill anything.
const NON_EXISTENT_PID_RAW: i32 = 1_000_000;

/// Number of pages backing the child's main-thread stack.
const STACK_PAGES: usize = 2;

/// Size, in bytes, of the child's main-thread stack.
const STACK_BYTES: usize = STACK_PAGES * PAGE_SIZE;

/// Base virtual address of the region used to back the child stack. Lies in the guard region
/// between the unified mmap region and the user stack, matching the convention used by the
/// low-level memory-management and `duplicate_burst` tests.
const STACK_REGION_BASE: usize = ::config::memory_layout::USER_MMAP_END_RAW;

// Compile-time check: the child stack fits within the guard region and does not overflow into the
// user stack.
::static_assert::assert_eq!(
    STACK_REGION_BASE + STACK_BYTES <= ::config::memory_layout::USER_STACK_TOP_RAW
);

//==================================================================================================
// Child Entry Point
//==================================================================================================

/// Entry point for the forked child. Probes whether it inherited the parent's `ProcessManagement`
/// capability, then demonstrates the mask (ungated `capctl` self-grant lets it recover), then spins
/// until the parent terminates it. Performs no IPC, so the parent's mailbox stays empty across the
/// `duplicate()` (which refuses a caller owning special resources such as a non-empty mailbox).
extern "C" fn cap_child_entry(_arg: usize) -> usize {
    // The child inherited the parent's cached pid through the duplicated address space; drop it so
    // any later self-identification re-queries the kernel (mirrors `duplicate_burst`).
    pm::invalidate_cached_pid();

    let victim: ProcessIdentifier = ProcessIdentifier::from(NON_EXISTENT_PID_RAW);

    // Probe: did the child inherit the parent's ProcessManagement capability?
    match pm::__kcall_terminate(victim) {
        Err(error) if error.code == ErrorCode::NoSuchProcess => {
            ::syslog::info!(
                "[CR-8][child] terminate() -> NoSuchProcess (capability INHERITED from parent)"
            );
        },
        Err(error) if error.code == ErrorCode::PermissionDenied => {
            ::syslog::info!(
                "[CR-8][child] terminate() -> PermissionDenied (capability NOT inherited from parent)"
            );
        },
        other => {
            ::syslog::info!("[CR-8][child] terminate() -> unexpected {:?}", other);
        },
    }

    // Demonstrate the mask: the ungated self-service capctl (CR-7) lets the child re-establish the
    // capability on demand, so it is never actually stuck.
    match pm::__kcall_capctl(Capability::ProcessManagement, true) {
        Ok(()) => match pm::__kcall_terminate(victim) {
            Err(error) if error.code == ErrorCode::NoSuchProcess => {
                ::syslog::info!(
                    "[CR-8][child] after self-capctl: terminate() -> NoSuchProcess (MASK fires: child recovered)"
                );
            },
            other => {
                ::syslog::info!("[CR-8][child] after self-capctl: terminate() -> {:?}", other);
            },
        },
        other => {
            ::syslog::info!("[CR-8][child] self-capctl refused: {:?}", other);
        },
    }

    // Spin until the parent terminates us.
    loop {
        let _ = sched::__kcall_sched_yield();
    }
}

//==================================================================================================
// Private Standalone Functions
//==================================================================================================

///
/// # Description
///
/// Demonstrates that a forked child does NOT inherit the parent's capabilities. The parent
/// self-grants `ProcessManagement`, confirms it passes the `terminate()` authorization gate, then
/// forks a child that probes the same gate. The authoritative evidence is the child's console
/// marker (`[CR-8][child] ...`), grepped by the harness.
///
/// # Returns
///
/// Returns `true` once the child has been created (so the boot continues and the markers are
/// emitted). The verdict is read from the grepped child marker, not from this boolean.
///
fn test_fork_child_does_not_inherit_capabilities() -> bool {
    let parent_pid: ProcessIdentifier = match pm::getpid_uncached() {
        Ok(pid) => pid,
        Err(e) => {
            ::syslog::info!("[CR-8][parent] getpid failed: {:?}", e);
            return false;
        },
    };

    let victim: ProcessIdentifier = ProcessIdentifier::from(NON_EXISTENT_PID_RAW);

    // Baseline: as an unprivileged process the gate must deny us before target lookup.
    match pm::__kcall_terminate(victim) {
        Err(error) if error.code == ErrorCode::PermissionDenied => {
            ::syslog::info!(
                "[CR-8][parent] baseline terminate() -> PermissionDenied (unprivileged)"
            );
        },
        other => {
            ::syslog::info!("[CR-8][parent] precondition not met: {:?}", other);
            return false;
        },
    }

    // Parent self-grants ProcessManagement (ungated capctl).
    if pm::__kcall_capctl(Capability::ProcessManagement, true).is_err() {
        ::syslog::info!("[CR-8][parent] capctl(ProcessManagement, true) failed");
        return false;
    }

    // Parent now passes the gate: terminate() reaches the (failing) lookup.
    match pm::__kcall_terminate(victim) {
        Err(error) if error.code == ErrorCode::NoSuchProcess => {
            ::syslog::info!(
                "[CR-8][parent] privileged terminate() -> NoSuchProcess (gate PASSED for parent)"
            );
        },
        other => {
            ::syslog::info!("[CR-8][parent] gate did not pass for parent: {:?}", other);
            let _ = pm::__kcall_capctl(Capability::ProcessManagement, false);
            return false;
        },
    }

    // Map the child's stack into the parent's OWN address space (unprivileged: pid == caller). The
    // child inherits this mapping via copy-on-write and runs its main thread on it.
    let stack_base: VirtualAddress = VirtualAddress::from_raw_value(STACK_REGION_BASE);
    if mm::__kcall_mmap(parent_pid, stack_base, STACK_PAGES, AccessPermission::RDWR).is_err() {
        ::syslog::info!("[CR-8][parent] mmap child stack failed");
        let _ = pm::__kcall_capctl(Capability::ProcessManagement, false);
        return false;
    }

    // Fork a child via the raw duplicate primitive. The parent has done no IPC yet, so its mailbox
    // is empty and duplicate() is accepted.
    let args: ThreadCreateArgs = ThreadCreateArgs {
        user_fn: VirtualAddress::from_raw_value(cap_child_entry as *const () as usize),
        user_fn_arg0: 0,
        user_fn_arg1: 0,
        user_stack_base: stack_base,
        user_stack_size: STACK_BYTES,
        user_tda: None,
    };

    let child: ProcessIdentifier = match pm::__kcall_duplicate(&args) {
        Ok(child) if child != parent_pid => {
            ::syslog::info!("[CR-8][parent] duplicated child pid={:?}", child);
            child
        },
        other => {
            ::syslog::info!("[CR-8][parent] duplicate() failed: {:?}", other);
            // Best-effort cleanup.
            for page in 0..STACK_PAGES {
                let addr: usize = STACK_REGION_BASE + page * PAGE_SIZE;
                let _ = mm::__kcall_munmap(parent_pid, VirtualAddress::from_raw_value(addr));
            }
            let _ = pm::__kcall_capctl(Capability::ProcessManagement, false);
            return false;
        },
    };

    // Yield generously so the child is scheduled and completes its probe + logging before we tear
    // it down (single-core cooperative scheduler: each yield hands control to the ready child).
    for _ in 0..128 {
        let _ = sched::__kcall_sched_yield();
    }

    // Tear the child down (the parent holds ProcessManagement) and reap it so no slot leaks.
    if pm::__kcall_terminate(child).is_err() {
        ::syslog::info!("[CR-8][parent] terminate(child) failed");
    }
    match wait(WaitTarget::Pid(child), 0) {
        Ok(WaitOutcome::Reaped { child: reaped, .. }) if reaped == child => {
            ::syslog::info!("[CR-8][parent] reaped child pid={:?}", reaped);
        },
        Ok(WaitOutcome::Reaped { child: reaped, .. }) => {
            ::syslog::info!("[CR-8][parent] wait(child) reaped unexpected pid={:?}", reaped);
        },
        Ok(WaitOutcome::NoneReady) => {
            ::syslog::info!("[CR-8][parent] wait(child) returned NoneReady");
        },
        Err(e) => {
            ::syslog::info!("[CR-8][parent] wait(child) error: {:?}", e);
        },
    }

    // Cleanup: release the child's stack mapping and the parent's capability.
    for page in 0..STACK_PAGES {
        let addr: usize = STACK_REGION_BASE + page * PAGE_SIZE;
        let _ = mm::__kcall_munmap(parent_pid, VirtualAddress::from_raw_value(addr));
    }
    let _ = pm::__kcall_capctl(Capability::ProcessManagement, false);

    true
}

//==================================================================================================
// Public Standalone Functions
//==================================================================================================

///
/// # Description
///
/// Runs the fork/duplicate capability-inheritance reproduction for CR-8.
///
pub fn test() {
    crate::test!(test_fork_child_does_not_inherit_capabilities());
}
