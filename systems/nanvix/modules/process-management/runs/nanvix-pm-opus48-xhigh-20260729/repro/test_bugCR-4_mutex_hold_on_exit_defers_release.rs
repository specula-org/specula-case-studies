// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// CR-4 reproduction: a thread that exits while holding a mutex defers the unlock (and the
// Condvar::notify that would wake a blocked sibling) until the zombie is harvested.
//
// This mirrors the exact real-API sequence the kernel performs:
//   - lock_mutex() kcall: `Mutex::try_lock()` then `RunningThread::put_mutex_guard()`
//     (thread/running.rs:236 -> thread/state.rs:223, `store_mutex_guard`).
//   - thread exit: `RunningThread::exit()` (thread/running.rs:195) MOVES the ThreadState (with the
//     guard still in `locked_mutexes`) into the ZombieThread. The guard is NOT dropped here.
//   - zombie harvest: the ZombieThread's ThreadState is finally dropped; only then does
//     `MutexGuard::drop` -> `MutexInner::unlock_unchecked` (sync/mutex.rs:78) clear `locked` and
//     call `Condvar::notify_first`. `ThreadState::drop` (thread/state.rs:574) merely logs.
//
// A sibling thread blocked in `lock_mutex()` performs exactly `Mutex::try_lock()`; we use that as
// the sibling's acquisition probe. If the mutex is still locked after the owner terminated, the
// sibling cannot acquire it and receives no wakeup until harvest.
//==================================================================================================

use crate::{
    hal::arch::{
        x86::cpu::FpuState,
        ContextInformation,
    },
    pm::{
        sync::mutex::Mutex,
        thread::{
            ReadyThread,
            RunningThread,
        },
    },
};
use ::sys::{
    pm::{
        MutexAddress,
        ThreadIdentifier,
    },
    ExitStatus,
};

///
/// # Description
///
/// Builds a [`RunningThread`] with the given identifier and an otherwise empty context, mirroring
/// the fixture used by the other in-kernel state tests.
///
fn make_running_thread(tid: i32) -> RunningThread {
    let ready: ReadyThread = ReadyThread::new(
        ThreadIdentifier::from(tid),
        None,
        None,
        None,
        ContextInformation::default(),
        // SAFETY: calls to FpuState::new are synchronized (single-threaded kernel init).
        unsafe { FpuState::new() },
    );
    ready.run().0
}

///
/// # Description
///
/// Reproduces CR-4: releasing/notifying on a mutex owned by a thread that exits without unlocking
/// is deferred from thread-exit time to zombie-harvest time.
///
/// The function is a characterization test: it PASSES (returns `true`) precisely when the buggy
/// deferral is observed, and logs `CONFIRMED` markers. If a future fix released the mutex at exit
/// time, the post-exit probe would succeed and this returns `false`.
///
fn test_bug_cr4_mutex_hold_on_exit_defers_release() -> bool {
    let mutex_addr: MutexAddress = MutexAddress::from(0xdead_0000usize);
    let mutex: Mutex = Mutex::new();

    // lock_mutex(): acquire the guard on behalf of the owner thread.
    let guard = match mutex.try_lock() {
        Ok(g) => g,
        Err(()) => {
            error!("[CR-4] precondition failed: fresh mutex should lock");
            return false;
        },
    };

    // lock_mutex(): hand the guard to the owning RunningThread (store_mutex_guard).
    let mut owner = make_running_thread(1);
    owner.put_mutex_guard(mutex_addr, guard);

    // Sanity: while the owner holds it, a sibling's try_lock() fails (it would block).
    if mutex.try_lock().is_ok() {
        error!("[CR-4] precondition failed: mutex not held after put_mutex_guard");
        return false;
    }
    info!("[CR-4] owner holds mutex: sibling try_lock() -> Err (would block)");

    // Thread exit WHILE STILL HOLDING the mutex (owner never called unlock_mutex()).
    // RunningThread::exit() moves the ThreadState (with the guard in locked_mutexes) into the
    // zombie; the guard is NOT dropped here.
    let (zombie, _ctx) = owner.exit(ExitStatus::from(0u32));

    // BUG: the owner has terminated, yet the mutex is STILL locked. A sibling blocked in
    // lock_mutex() cannot acquire it and receives no Condvar::notify.
    let still_locked_after_exit: bool = mutex.try_lock().is_err();
    info!(
        "[CR-4] after owner exit(): sibling try_lock() -> {} (correct behavior would be Ok/unlocked)",
        if still_locked_after_exit { "Err (STILL LOCKED)" } else { "Ok (released)" }
    );

    // Zombie harvest: dropping the ZombieThread drops its ThreadState, which drops the guard and
    // finally runs unlock_unchecked() (clear locked + notify_first). This is the ONLY place the
    // mutex gets released for a thread that exited holding it.
    drop(zombie);
    let released_after_harvest: bool = mutex.try_lock().is_ok();
    info!(
        "[CR-4] after zombie harvest (ThreadState drop): sibling try_lock() -> {}",
        if released_after_harvest { "Ok (released now)" } else { "Err (still locked)" }
    );

    let bug_confirmed: bool = still_locked_after_exit && released_after_harvest;
    if bug_confirmed {
        info!(
            "[CR-4] CONFIRMED: mutex release+notify deferred from thread-exit to zombie-harvest; a \
             sibling blocked in lock_mutex() stays blocked across that entire window"
        );
    } else {
        info!("[CR-4] NOT reproduced: mutex was released at exit time (bug absent)");
    }

    bug_confirmed
}

/// Runs the CR-4 reproduction test.
pub(super) fn test() -> bool {
    let mut passed: bool = true;
    passed &= run_test!(test_bug_cr4_mutex_hold_on_exit_defers_release);
    passed
}
