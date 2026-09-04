// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// CR-1 reproduction: join_thread reaps the zombie BEFORE copying the exit status out
//==================================================================================================
//
// Finding CR-1 (code-review, Medium): `kcall::join_thread`
// (src/kernel/src/pm/kcall/join_thread.rs:70-77) reaps the target thread's zombie and
// only THEN copies its exit status to the caller-supplied `retval` pointer:
//
//     let status = ProcessManager::join_thread(pid, tid)?;                 // (A) REAPS zombie
//     pm::copy_to_user::<ExitStatus>(get_mut(), pid, retval, &status)      // (B) may FAIL
//         .map_err(SleepError::Generic)?;
//     Ok(ExitStatus::ok())
//
// (A) removes the zombie from the process zombie queue (`RunningProcess::try_join_thread`,
// running.rs:561-566) and harvests it (`harvest_zombie_thread`, unsafe.rs:654-709). If the
// user-controlled `retval` pointer is invalid, (B) fails AFTER the zombie is already gone,
// so the exit status is lost and the join cannot be retried (a second join returns
// `NoSuchProcess`, running.rs:618-620). This test drives the REAL reap + REAL copy-out on a
// running process that owns a joinable zombie sibling — exactly the state produced by
// `create_thread(2)` + child `exit_thread(42)` while thread 1 keeps running — and shows the
// status is permanently lost. A control test shows the fixed ordering (validate the
// destination before reaping) preserves the status.
//
//==================================================================================================
// Imports
//==================================================================================================

use super::{
    ProcessState,
    RunningProcess,
};
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
        thread::{
            ReadyThread,
            RunningThread,
            ZombieThread,
        },
        ProcessManager,
    },
};
use ::alloc::boxed::Box;
use ::sys::{
    error::ErrorCode,
    pm::{
        ProcessIdentifier,
        ThreadIdentifier,
    },
    ExitStatus,
};
use ::type_safe::NonEmptyVecDeque;

//==================================================================================================
// Fixture helpers (mirror test_detach.rs)
//==================================================================================================

/// Distinctive exit status carried by the joinable zombie thread under test.
const JOINED_STATUS: u32 = 42;

/// Creates a fresh virtual memory space cloned off the current (kernel) process.
fn make_test_vmem() -> Option<Vmem> {
    // SAFETY: pm/init() runs after the process and virtual memory managers are initialized;
    // access is synchronized because the kernel is single-threaded with interrupts disabled.
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("join_status_test: new_vmem failed (error={e:?})");
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

/// Creates a JOINABLE (non-detached) [`ZombieThread`] carrying `status` — exactly the object a
/// normal `create_thread(tid)` + child `exit_thread(status)` produces on the running process's
/// zombie queue.
fn make_joinable_zombie(tid: i32, status: u32) -> ZombieThread {
    make_running_thread(tid).exit(ExitStatus::from(status)).0
}

/// Assembles a running process (running thread `tid=1`) owning the supplied joinable zombie.
fn make_running_process_with_zombie(zombie: ZombieThread) -> Option<RunningProcess> {
    let vmem: Vmem = make_test_vmem()?;
    let state: Box<ProcessState> =
        Box::new(ProcessState::new(ProcessIdentifier::from(1), ProcessIdentifier::from(0), vmem));
    let running: RunningThread = make_running_thread(1);
    let zombies: NonEmptyVecDeque<ZombieThread> = NonEmptyVecDeque::new(zombie);
    Some(RunningProcess::new(state, running, None, None, None, Some(zombies)))
}

//==================================================================================================
// Tests
//==================================================================================================

///
/// # Description
///
/// Reproduces CR-1. Replays the exact body of `kcall::join_thread` (reap first, copy second) on a
/// running process that owns a joinable zombie sibling `tid=2` with exit status 42, using an
/// invalid (NULL) `retval` pointer. Demonstrates that the copy-out fails AFTER the zombie has been
/// reaped, so the exit status is lost and a retried join returns `NoSuchProcess`.
///
/// Returns `true` when the CR-1 data loss is observed (i.e. the bug reproduces).
///
fn test_join_thread_loses_status_when_retval_copy_fails() -> bool {
    let zombie: ZombieThread = make_joinable_zombie(2, JOINED_STATUS);
    let mut process: RunningProcess = match make_running_process_with_zombie(zombie) {
        Some(process) => process,
        None => return false,
    };
    let target: ThreadIdentifier = ThreadIdentifier::from(2);

    // -------------------------------------------------------------------------------------------
    // (A) Reap. This is what `ProcessManager::join_thread` does at join_thread.rs:72 — the REAL
    // `RunningProcess::try_join_thread` removes the zombie from the queue and returns it, and
    // `harvest_zombie_thread` reclaims its resources. After this point the zombie is gone.
    // -------------------------------------------------------------------------------------------
    let reaped: ZombieThread = match process.try_join_thread(target) {
        Ok(zombie_thread) => zombie_thread,
        Err(_) => {
            error!("join_status_test: setup broken — zombie tid=2 was not joinable");
            return false;
        },
    };
    let status: ExitStatus = reaped.status();
    if status.as_u32() != JOINED_STATUS {
        error!("join_status_test: unexpected zombie status {:?}", status);
        return false;
    }
    // Real resource reclaim performed by harvest_zombie_thread(): consumes the zombie.
    let _reclaimed = reaped.harvest();

    // -------------------------------------------------------------------------------------------
    // (B) Copy the status out to the user-supplied `retval` pointer (join_thread.rs:74). The
    // pointer is INVALID (NULL, i.e. outside the user address range), so the REAL two-pass
    // `copy_to_user` returns Err(BadAddress) gracefully — but the zombie was already reaped in (A).
    // -------------------------------------------------------------------------------------------
    let retval: VirtualAddress = VirtualAddress::from_raw_value(0); // NULL — not in user space
    let src: VirtualAddress =
        VirtualAddress::from_raw_value(&status as *const ExitStatus as usize);
    let size: usize = core::mem::size_of::<ExitStatus>();
    match process.state_mut().copy_to_user_unaligned(retval, src, size) {
        Ok(()) => {
            error!("join_status_test: copy_to_user unexpectedly succeeded for a NULL retval");
            return false;
        },
        Err(error) => {
            info!(
                "buggy order (reap->copy): copy_to_user(retval=NULL) failed as expected: {:?}",
                error
            );
        },
    }

    // -------------------------------------------------------------------------------------------
    // Consequence: the join failed (B returned Err), yet the zombie is already consumed. The exit
    // status 42 is nowhere — a retried join can no longer find the thread.
    // -------------------------------------------------------------------------------------------
    match process.try_join_thread(target) {
        Ok(_) => {
            error!("join_status_test: zombie unexpectedly still joinable after failed copy");
            false
        },
        Err(Ok(_cond)) => {
            error!("join_status_test: unexpected condvar wait on a reaped thread");
            false
        },
        Err(Err(error)) => {
            let lost: bool = error.code == ErrorCode::NoSuchProcess;
            if lost {
                info!(
                    "BUG CONFIRMED (CR-1): after the failed retval copy, join tid=2 is \
                     un-retriable ({:?}); exit status {} is permanently LOST",
                    error.code, JOINED_STATUS
                );
            } else {
                error!("join_status_test: unexpected retry error {:?}", error.code);
            }
            lost
        },
    }
}

///
/// # Description
///
/// Control for CR-1: the FIXED ordering validates the destination `retval` pointer BEFORE
/// consuming the zombie, so an invalid pointer leaves the zombie intact and the exit status
/// recoverable by a retried join. Uses `Vmem::is_user_region_writable` — the existing kernel
/// helper documented as the pre-write validation a kernel-side writer should perform on a
/// user-controlled destination — as the up-front guard.
///
/// Returns `true` when the exit status survives the invalid-pointer join under the correct order.
///
fn test_correct_order_validate_before_reap_preserves_status() -> bool {
    let zombie: ZombieThread = make_joinable_zombie(2, JOINED_STATUS);
    let mut process: RunningProcess = match make_running_process_with_zombie(zombie) {
        Some(process) => process,
        None => return false,
    };
    let target: ThreadIdentifier = ThreadIdentifier::from(2);
    let size: usize = core::mem::size_of::<ExitStatus>();

    // Fixed order step 1: validate the user destination FIRST, before touching the zombie.
    let retval: VirtualAddress = VirtualAddress::from_raw_value(0); // NULL — invalid
    let writable: bool = process.state().vmem().is_user_region_writable(retval, size);
    if writable {
        error!("join_status_test: NULL retval unexpectedly reported writable");
        return false;
    }
    // Because validation failed, the corrected join returns the error WITHOUT reaping the zombie.
    info!(
        "correct order (validate->reap): NULL retval rejected up front; zombie NOT reaped"
    );

    // The zombie is retained: a retried join with a valid destination still delivers status 42.
    match process.try_join_thread(target) {
        Ok(zombie_thread) => {
            let status: ExitStatus = zombie_thread.status();
            let preserved: bool = status.as_u32() == JOINED_STATUS;
            if preserved {
                info!(
                    "correct order: exit status {} preserved and thread still joinable",
                    JOINED_STATUS
                );
            } else {
                error!("join_status_test: retained zombie had wrong status {:?}", status);
            }
            let _reclaimed = zombie_thread.harvest();
            preserved
        },
        Err(_) => {
            error!("join_status_test: zombie was lost even under the correct order");
            false
        },
    }
}

//==================================================================================================
// Entry Point
//==================================================================================================

/// Runs the CR-1 reproduction tests.
pub(super) fn test() -> bool {
    let mut passed: bool = true;
    passed &= run_test!(test_join_thread_loses_status_when_retval_copy_fails);
    passed &= run_test!(test_correct_order_validate_before_reap_preserves_status);
    passed
}
