# Severity Classification — hotshot

## Summary

- Total bugs: 5
- Critical: 0
- High: 3
- Medium: 2
- Low: 0
- FALSE POSITIVE (no severity): 0

## Per-bug classification

| Bug | Title | Status | Severity | Reasoning |
|-----|-------|--------|----------|-----------|
| 1   | TC epoch retag — `TimeoutData2::commit()` strips epoch | REPRODUCED | High | The signed TC digest omits `epoch`, so a BLS signature on `TimeoutData2{epoch=E}` verifies against `epoch=E'` (reproduction proves byte-identical digests across all epochs). At epoch boundaries with partial stake-table overlap, a Byzantine collector can retag a TC into a wrong epoch's view-change pipeline — a cross-epoch certificate-binding break in a BFT consensus protocol, reachable via the public timeout-vote aggregator surface. |
| 2   | One-sided `validate_current_epoch` accepts over-declared proposal epoch | REPRODUCED | High | The `>=` check in `validate_current_epoch` lets a Byzantine leader pick `block_number=999` to declare an arbitrary future epoch, causing `validate_qc_and_next_epoch_qc` to look up the attacker-chosen StakeTable(E') for signature verification. Missing security check on attacker-controlled input reachable via the proposal pipeline, and it composes with Bug 1 for full epoch-attribution control. |
| 3   | Parallel-relay view-sync emits multiple finalize certs per view | REPRODUCED | Medium | Independent per-relay accumulators can each reach threshold and produce distinct valid `ViewSyncFinalizeCertificate2`s for the same `(epoch, view)`, violating the `UniqueFinalizeCertPerView` invariant; replicas accept whichever arrives first, risking leader/parent-QC divergence across nodes. Internal invariant break with downstream risk — partial mitigation via opportunistic relay-lifting on the consumer side keeps direct safety harm bounded, reachable via the view-sync gossip surface. |
| 4   | `update_high_qc` / `update_locked_view` silently drop same-view equivocation evidence | REPRODUCED | High | Same-view-different-leaf QCs return `Err` from `update_high_qc`, but every caller discards the result with `let _ = …`, so observable Byzantine equivocation produces no log, event, or slashing evidence at the only place the node sees both QCs. A maintainer TODO at `consensus.rs:1147-1151` acknowledges the gap, and the missing detection is reachable on any honest replica that receives both conflicting same-view QCs from the network. |
| 5   | `handle_eqc_formed` non-atomic in-memory vs storage updates | REPRODUCED | Medium | `handle_eqc_formed` updates in-memory `high_qc` and `next_epoch_high_qc` before awaiting `storage.update_eqc`, so a storage error or crash between lock-drop and durable-write leaves persisted state behind in-memory; on restart the node loses an eQC it may already have broadcast `ExtendedQc2Formed` for, causing local/peer divergence until standard catchup repairs it. Internal invariant break with demonstrated external effect under a single fault (storage failure or crash), reachable through normal eQC-formation control flow. |
