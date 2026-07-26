# HotShot

## Scope

Specula analyzed and tested HotShot's HotStuff-2 consensus core, including proposal, vote, and QC processing, timeout and view-sync certificates, epoch transitions and dual-epoch QCs, DRB-based leader rotation, and concurrent in-memory/persistent updates.

## Bugs

Specula found 6 new bugs:

- A decided upgrade certificate is installed in memory before an asynchronous persistence whose error is discarded, so a crash can restart the node on the old version after cutover.
- `TimeoutData2::commit` omits the epoch from its digest, allowing a timeout certificate signature to be retagged across epochs; this is associated with Issue #3918.
- The upgrade null window is enforced only by the proposer, so an honest lagging leader can propose a non-null block that voters accept after the voter-side check regressed.
- `validate_current_epoch` uses a one-sided comparison and accepts proposals declaring arbitrarily future epochs; this is associated with Issue #3918.
- Independent view-sync relay accumulators can each form a finalize certificate for the same view, violating certificate uniqueness.
- `handle_eqc_formed` advances in-memory high QCs before persistence and still discards formation state and broadcasts the event when storage fails.
