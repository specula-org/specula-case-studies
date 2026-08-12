# Validation Changelog

## Round 1 - Trace Validation

- All three enriched Category A traces passed with exact post-state validation; no spec or instrumentation changes were required.

## Round 1 - Model Checking

- `MC.cfg` found no standard or structural invariant violation during the prescribed 30-minute BFS run (depth 22; 1,148,121,026 states generated; 175,345,834 distinct states). No spec or invariant changes were required.
- The first launch exhausted the default `/tmp` state volume after 17 minutes without a property violation; the valid run was restarted with the same model bounds and its TLC state directory redirected to a larger volume. Both outputs are retained in `spec/output/`.

## Round 2 - Trace Validation

- [fix] `FinalizerTimeoutAsReady`: regenerated `finalizer_deadline.ndjson` from the raw trace after correcting the reducer's invented restoration claim; all three traces then passed exact post-state validation with no regressions.

## Round 2 - Model Checking

- [fix-spec] `FinalizerTimeoutAsReady`: Case B fidelity gap found while hunting Scenario 2. The checked-in finalizer only accepts exact `reconciled` state (`finalize-warmboot.sh:151-170`) and the harness-only timeout probe at lines 274-285 does not mutate production readiness. Removed the invented restored-epoch update from `base.tla` and the trace reducer; the event now records timeout without claiming restoration.
- The corrected `MC.cfg` found no standard or structural invariant violation during the prescribed 30-minute BFS run (depth 21; 1,148,927,589 states generated; 177,669,498 distinct states at the final progress sample). No further spec or invariant changes were required.

## Bug Hunting Adjustments

- [fix-inv] `CausalFreeze`: Case A found in Scenario 3. `fast-reboot` deliberately pauses orchagent before stopping services (`fast-reboot:1159-1185,1235-1246`), so requiring the abstract producer to be stopped rejected expected behavior. Retained the falsifiable implementation-backed constraint that no causally prior update remains in flight when the consumer freezes.

## Bug Hunting

- [bug] `OwnershipRecovery`: backend restart resets process-local ownership to idle while the host still has an accepted reboot pending (Scenario 1, High).
- [bug] `NoPrematureFinalization`: the finalizer's one-time component snapshot omits a late warm component and allows global completion before its reconciliation (Scenario 2, High).
- [bug] `CausalFreeze`: configuration producers can emit an update after orchagent crosses its freeze boundary because no causal drain barrier precedes the pause (Scenario 3, High).
- [bug] `SnapshotSafety`: a failed direct snapshot copy can leave a stale or partial file that the restore path accepts based only on existence (Scenario 4, High).
- [bug] `FailureClassification`: transient D-Bus transport loss is collapsed into the same definitive non-retry result as an authoritative host failure (Scenario 5, Medium).

## Result

Converged in 2 rounds. Bug hunting: 5 bugs found.
