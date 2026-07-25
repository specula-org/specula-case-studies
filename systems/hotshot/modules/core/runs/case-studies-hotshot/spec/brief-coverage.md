# Brief Coverage Self-Audit — HotShot

Audit mapping brief §2 (Bug Families), §5 (Proposed Invariants), and §6.1
(Model-Checkable Findings) onto the spec / MC artifacts in this directory.
This is the **boring-by-design** self-check before moving on to the trace spec
(§ guide.md Phase 2.5).

---

## §2 Bug Families → hunt cfgs

| Family | Mechanism (one-liner) | Hunt cfg |
|---|---|---|
| A (TC/VSC epoch binding) | `TimeoutData2.commit()` strips epoch; verifier picks stake table by cert-self-declared epoch | `MC_hunt_familyA.cfg` |
| B (Equivocation invisibility + non-durable vote + locked-view holes) | `update_high_qc` silently drops conflicting same-view QCs; `submit_vote` doesn't persist; HS2 liveness-rule lock-advance | `MC_hunt_familyB.cfg` |
| C (View-sync parallel-relay non-determinism) | Three per-relay maps run concurrently; replicas accept any-relay cert | `MC_hunt_familyC.cfg` |
| D (Non-atomic in-mem ↔ persistent) | `update_high_qc` storage write before in-mem check; `handle_eqc_formed` drops lock then awaits storage | `MC_hunt_familyD.cfg` |
| E (Cross-epoch binding gaps in proposal validation) | `validate_current_epoch` is one-sided; cert-self-declared epoch drives downstream stake-table lookups | `MC_hunt_familyE.cfg` |

No family is merged into another, and none is silently dropped.

---

## §5 Proposed Invariants → defined / wired / enabled

For each Safety invariant in brief §5, where is it defined and in which cfg
does it run? "Enabled in cfg" was filled by re-reading the cfg files.

| Brief §5 invariant | Defined in | Wired in MC.tla? | Enabled in cfg(s) |
|---|---|---|---|
| `ElectionSafety_HS2` | `base.tla` | yes (inherited) | `MC.cfg`, `MC_hunt_familyA.cfg`, `MC_hunt_familyB.cfg`, `MC_hunt_familyD.cfg`, `MC_hunt_familyE.cfg` |
| `LockedViewMonotonic` | — | — | Not added. Brief notes this is "non-decreasing under correct operation; crash recovery may reset it." Under our `Crash` action `lockedView` is reset to 0, so the invariant would be vacuously violated by any crash. The brief's *interesting* composition is covered by `LockedViewBelowOrEqualHighQC` (Family B), which we do enable. |
| `HighQCMonotonic_InMem` | `base.tla` | yes | `MC.cfg`, `MC_hunt_familyB.cfg` (implicit via base safety) |
| `HighQC_PersistedConsistent` | `base.tla` | yes | `MC_hunt_familyD.cfg` |
| `NoEpochReplayedTC` | `base.tla` | yes | `MC_hunt_familyA.cfg` |
| `UniqueFinalizeCertPerView` | `base.tla` | yes | `MC_hunt_familyC.cfg` |
| `FinalizeCertImpliesCommitCert` | `base.tla` | yes | `MC_hunt_familyC.cfg` |
| `ProposalEpochMatchesView` | `base.tla` | yes | `MC_hunt_familyE.cfg` |
| `NoEquivocationGoesUnflagged` (brief lists as Liveness/Accountability) | `base.tla` | yes | `MC_hunt_familyB.cfg`. Brief tags it Liveness/Accountability; we encode it as a state-predicate Safety invariant on `equivocationFlagged` so TLC can refute it directly. |
| `LockedViewBelowOrEqualHighQC` | `base.tla` | yes | `MC_hunt_familyB.cfg` |

**The column that breaks most often is the rightmost.** Re-reading the cfg
files: every defined safety invariant from §5 (except `LockedViewMonotonic`,
explained above) is enabled in at least one hunt cfg. `MC.cfg` keeps the
extension invariants commented out — this is intentional and matches the
methodology guidance (group invariants, comment out extension ones, enable per
hunt cfg).

---

## §6.1 Model-Checkable Findings → hunt cfgs that can reach them

| ID | Finding | Hunt cfg | Reachable in cfg? |
|---|---|---|---|
| MC1 | TC retag across epochs verifies under E' stake table | `MC_hunt_familyA.cfg` | yes — `MaxTcReplay=1`, `MaxTimeoutVote=3`, two epochs in `MaxEpoch=1`, `NoEpochReplayedTC` enabled. |
| MC2 | Crash-recovery + Byzantine double-vote → two same-view QCs | `MC_hunt_familyB.cfg` | yes — `MaxCrash=1`, `MaxRecover=1`, `MaxDoubleVote=1`, `MaxQcs=3`, `NoEquivocationGoesUnflagged` and `ElectionSafety_HS2` enabled. |
| MC3 | Two parallel view-sync relays → two valid finalize certs | `MC_hunt_familyC.cfg` | yes — 4 honest servers (`s1..s4` for two threshold pools at low MaxView), `MaxVscs=3`, both `UniqueFinalizeCertPerView` and `FinalizeCertImpliesCommitCert` enabled. |
| MC4 | Crash between in-mem and storage in `handle_eqc_formed` desynchronizes high QC | `MC_hunt_familyD.cfg` | yes — `MaxCrash=2`, `MaxRecover=2`, `UpdateHighQcPersistThenInMem` branches into persist-first then in-mem path, `HighQC_PersistedConsistent` enabled. |
| MC5 | Mis-declared epoch satisfies one-sided `validate_current_epoch`; downstream uses attacker's stake table | `MC_hunt_familyE.cfg` | yes — `MaxMisdeclaredEpoch=1`, `MaxTcReplay=1` (composition with A), `ProposalEpochMatchesView` enabled. |
| MC6 | Byzantine leader pushes lockedView past sibling-branch QC | `MC_hunt_familyB.cfg` | yes — `MaxForceLockedAdvance=1`, `LockedViewBelowOrEqualHighQC` enabled. |

Every §6.1 finding has a targeting cfg whose fault setup makes the trigger
reachable.

---

## Gaps & honest notes

1. **`LockedViewMonotonic`** is not encoded — the brief itself flags that crash
   recovery may reset it, so the property as written is trivially violated by
   `Crash`. The interesting composition is the `LockedViewBelowOrEqualHighQC`
   relation, which is enabled.
2. **Family C's `FinalizeCertImpliesCommitCert`** is a weakened structural form
   (`pool = {}` admitted) for initial states. The MC hunt cfg also accepts
   that. The honest reading: any finalize cert produced by `FormViewSyncCert`
   *requires* threshold signers in the Commit phase pool too; the relaxed
   `pool = {}` arm only saves the property from a vacuous start state.
3. **Family E composition with Family A** is encoded in `MC_hunt_familyE.cfg`
   (`MaxTcReplay = 1`) rather than as a dedicated cfg. The brief explicitly
   ties them ("composition: TC with stripped epoch + proposal validator that
   trusts the cert's self-declared epoch"), so one cfg is sufficient.
4. **Family D's `handle_eqc_formed` window** is modeled by `UpdateHighQcPersistThenInMem`'s
   two branches; we did not add a dedicated `pendingEqcStorage` write action
   because the simpler `UpdateHighQcPersistThenInMem` already exposes the
   ordering. `pendingEqcStorage` exists as a variable so a future refinement
   can wire it without changing the schema.
