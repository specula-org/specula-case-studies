# Brief Coverage Self-Audit — left-right Round 2

Mapping `modeling-brief.md` §2 (Bug Families), §5 (Proposed Invariants),
§6.1 (Model-Checkable Findings) → spec/MC artifacts in `spec/`.

## Table 1 — Bug Families (brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled in that cfg | If skipped, why? |
|---|---|---|---|
| F1 — take_inner stale-snapshot UAF (PR #144) | `MC_hunt_F1_uaf.cfg` (buggy build) + `MC_hunt_F1_uaf_fixed.cfg` (PR #144 fix applied) | `MCTypeOK, MCEpochParity, MCPointerDisjoint, MCNoDropWhileRead, MCStaleSnapshotIsCaught` | — |
| F2 — Reentrant `enter()` panics on NULL pointer | `MC_hunt_F2_panic.cfg` | `MCTypeOK, MCEpochParity, MCPointerDisjoint, MCNoUnreachablePanic` | — |
| F3 — Long-held guard blocks publish (liveness) | `MC_hunt_F3_liveness.cfg` (no fairness — bug) + `MC_hunt_F3_liveness_fair.cfg` (with fairness — contract) | `MCTypeOK, MCEpochParity, MCPointerDisjoint`; PROPERTIES `EventualPublish` | — |
| F4 — Per-reader snapshot in `update_and_swap` | `MC_hunt_F4_snap.cfg` | `MCTypeOK, MCEpochParity, MCPointerDisjoint, MCNoWriteWhileRead, MCPerReaderSnapshotConsistency` | — |

Each family has at least one targeting hunt cfg.  F1 and F3 each have two
hunt cfgs (buggy/fixed and bug/fair) so both directions of the verification
are checked.

## Table 2 — Proposed Invariants (brief §5)

| Brief invariant | Defined at | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| `NoUAFInTakeInner` (Safety) | `base.tla:NoDropWhileRead` (≈line 595) | `MC.tla:MCNoDropWhileRead` | `MC_hunt_F1_uaf.cfg`, `MC_hunt_F1_uaf_fixed.cfg` | — |
| `StaleSnapshotIsCaught` (Safety) | `base.tla:StaleSnapshotIsCaught` | `MC.tla:MCStaleSnapshotIsCaught` | `MC_hunt_F1_uaf.cfg`, `MC_hunt_F1_uaf_fixed.cfg` | — |
| `NoReentrantPanic` (Safety) | `base.tla:NoUnreachablePanic` | `MC.tla:MCNoUnreachablePanic` | `MC_hunt_F2_panic.cfg` | — |
| `WriterEventuallyPublishes` (Liveness) | `MC.tla:EventualPublish` | yes (PROPERTIES) | `MC_hunt_F3_liveness_fair.cfg` (HOLDS) | — |
| `LongHeldGuardBlocksWriter` (Bug-hunting) | `MC.tla:EventualPublish` (negated under MCSpec) | yes (PROPERTIES) | `MC_hunt_F3_liveness.cfg` (VIOLATES) | — |
| `PerReaderSnapshotConsistency` (Safety) | `base.tla:PerReaderSnapshotConsistency` | `MC.tla:MCPerReaderSnapshotConsistency` | `MC_hunt_F4_snap.cfg` | — |
| `NoWriteWhileRead` (Safety, carryover) | `base.tla:NoWriteWhileRead` | `MC.tla:MCNoWriteWhileRead` | `MC.cfg` (always-on); `MC_hunt_F4_snap.cfg` | — |

Every Safety invariant in §5 is enabled in at least one hunt cfg.  Liveness
properties (`WriterEventuallyPublishes`, `LongHeldGuardBlocksWriter`) are
checked via the F3 cfgs as PROPERTIES, with two cfg variants (with /
without `ClientHoldGuardRelease` fairness) demonstrating both contract-
compliance and contract-violation paths.

## Table 3 — Model-Checkable Findings (brief §6.1)

| Finding ID | Trigger mechanism (action/fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC-1: reader enters between prior publish snap and `take_inner` NULL swap, writer then drops | `WriterStartTakeInner` after `WriterStartPublish`; `ReaderEnterFreshLoad` interleaving | `MCNoDropWhileRead` (and `MCStaleSnapshotIsCaught`) | `MC_hunt_F1_uaf.cfg` |
| MC-2: PR #144 fix applied — `lastEpochs` refreshed after NULL swap | Same as MC-1 with `ApplyPR144Fix = TRUE` enabling `WriterTakeInnerResnapshot` | (none — invariants HOLD) | `MC_hunt_F1_uaf_fixed.cfg` |
| MC-3: reader holds outer guard + WriteHandle drop + nested `enter()` reaches `unreachable!()` | `ReaderEnterNestedLoad` while `inner_ptr = "null"` | `MCNoUnreachablePanic` | `MC_hunt_F2_panic.cfg` |
| MC-4: writer wait terminates iff readers fair | `ClientHoldGuardSet` w/o release fairness vs. with `WF(ClientHoldGuardRelease)` | `EventualPublish` (PROPERTIES) | `MC_hunt_F3_liveness.cfg` (violates), `MC_hunt_F3_liveness_fair.cfg` (holds) |
| MC-5: split snap loop, reader epoch transitions during loop | `ReaderEnterFreshBumpEpoch` / `ReaderExit` interleaved with `WriterPubSnapReader(r)` | `MCPerReaderSnapshotConsistency` (and `MCNoWriteWhileRead`) | `MC_hunt_F4_snap.cfg` |
| MC-6: `try_publish` provides same safety as `publish` | `WriterStartTryPublish` -> `WriterTryPublishSucceed` -> reuses publish path | `MCNoDropWhileRead`, `MCNoWriteWhileRead`, `MCPerReaderSnapshotConsistency` | `MC_hunt_F4_snap.cfg` (MaxTryPublish = 1) |

All six §6.1 findings have a targeting hunt cfg whose counter setup makes
the trigger reachable.  MC-6 (`try_publish` safety) is folded into the F4
config because `try_publish` reuses the publish path — confirming F4
safety on `try_publish` is the only marginal coverage MC-6 needs beyond
the publish path's coverage.

## Coverage Summary

```
Families: 4 / 4 implemented + 0 partial (skipped: none)
Proposed Safety Invariants: 5 / 5 enabled in ≥1 hunt cfg (skipped: none)
Liveness Properties: 1 (EventualPublish) checked under both fair & unfair
  spec variants (MC_hunt_F3_liveness*.cfg)
Model-Checkable Findings: 6 / 6 targeted by a hunt cfg (skipped: none)
Hunt cfg files: 6 (F1_uaf, F1_uaf_fixed, F2_panic, F3_liveness,
  F3_liveness_fair, F4_snap)
```

## Notes

- The brief explicitly excludes re-running the prior round's
  `MCSkipReaderFence` / `MCSkipWriterFence` adversaries (0 bugs found).
  Memory-ordering invariants are therefore not in this audit.
- The brief's Family 1 has both a buggy and a fixed variant in spec form,
  matching MC-1 / MC-2 in §6.1.  This validates both the TSAN finding
  and the proposed PR #144 patch.
- All six hunt cfgs share `Reader = {R1, R2}` and small `MaxOps`/`MaxPublish`
  bounds.  These are sufficient to expose all four families because each
  family's bug mechanism activates in a single take_inner / publish /
  client-hold step against a 2-reader interleaving.
