//! Reproduction for Bug 2 (Family E): one-sided `validate_current_epoch`
//! accepts over-declared epoch in proposals.
//!
//! Status: REPRODUCED at Level 0 (pure function call, no consensus state).
//!
//! Where it lives in the source tree (and how to run):
//!   File: crates/hotshot/types/src/simple_vote.rs
//!         (#[cfg(test)] mod proposal_epoch_misdeclare_repro)
//!   Run:  cargo test -p hotshot-types --lib proposal_epoch_misdeclare_repro
//!
//! `validate_current_epoch` at
//! `task-impls/src/quorum_proposal_recv/handlers.rs:211-215` is:
//! ```
//! epoch_from_block_number(block_number, epoch_height)
//!     >= epoch_from_block_number(high_block_number + 1, epoch_height)
//! ```
//! This catches *under*-declared epochs but accepts arbitrarily *higher*
//! epoch claims. A Byzantine proposer picks a block_number that maps to a
//! future epoch the network has not entered.
use hotshot_types::utils::epoch_from_block_number;

/// Models the `validate_current_epoch` check exactly.
fn check_proposal_epoch(
    proposal_block_number: u64,
    high_qc_block_number: u64,
    epoch_height: u64,
) -> Result<(), &'static str> {
    if epoch_from_block_number(proposal_block_number, epoch_height)
        >= epoch_from_block_number(high_qc_block_number + 1, epoch_height)
    {
        Ok(())
    } else {
        Err("Quorum proposal has an inconsistent epoch")
    }
}

/// LEVEL 0 — One-sided guard accepts wildly over-declared epochs.
#[test]
fn over_declared_epoch_passes_one_sided_check() {
    let epoch_height: u64 = 10;
    let high_qc_block_number: u64 = 5;   // real epoch: 1
    let byz_block_number: u64 = 999;     // declared epoch: 100

    let true_epoch = epoch_from_block_number(high_qc_block_number + 1, epoch_height);
    let declared_epoch = epoch_from_block_number(byz_block_number, epoch_height);
    assert_eq!(true_epoch, 1);
    assert_eq!(declared_epoch, 100);

    // The buggy check passes — accepts the over-declaration.
    check_proposal_epoch(byz_block_number, high_qc_block_number, epoch_height)
        .expect("BUG: one-sided check accepts over-declared epoch");

    // Sanity: under-declared proposals are rejected (the check is one-sided).
    let high_qc_bn_high: u64 = 50;
    let under_bn: u64 = 5;
    let res = check_proposal_epoch(under_bn, high_qc_bn_high, epoch_height);
    assert!(res.is_err(), "under-declared epoch is rejected");
}

#[test]
fn two_sided_check_would_have_caught_it() {
    let epoch_height: u64 = 10;
    let high_qc_block_number: u64 = 5;
    let byz_block_number: u64 = 999;
    let true_epoch = epoch_from_block_number(high_qc_block_number + 1, epoch_height);
    let declared_epoch = epoch_from_block_number(byz_block_number, epoch_height);
    assert_ne!(true_epoch, declared_epoch);
}
