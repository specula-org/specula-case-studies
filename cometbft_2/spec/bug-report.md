# Bug Report — CometBFT Round 2 (Byzantine extensions)

## Summary

- Bug families tested: 6
- Bugs found: 0 (under bounded BFS within 30-minute per-family budget)
- Configs run:
  - `MC_hunt_family1_equivocation.cfg` (BFS + simulation)
  - `MC_hunt_family2_amnesia.cfg`       (BFS + simulation)
  - `MC_hunt_family3_vereuse.cfg`       (BFS + simulation)
  - `MC_hunt_family4_lunatic.cfg`       (BFS)
  - `MC_hunt_family5_evidence.cfg`      (BFS)
  - `MC_hunt_family6_locking.cfg`       (BFS)

No invariant violations were found within the bounded exploration budget
on the converged spec. Two spec/implementation gaps were discovered
*during* bug hunting (a Round-1 stuttering of `EventualAccountabilityStrong`
caused by non-atomic conflict-detect/buffer-write, and an honest-validator
double-sign that the spec accepted because it did not enforce the privval
`CheckHRS` rule). Both were Case B (spec modeling issues that the
implementation does not exhibit) and were fixed in the spec — see the
"Spec fixes during hunting" section and `changelog.md`. After the fixes,
all six families ran to their 30-minute budget with no safety violations.

## Coverage (per family)

| Family | Mechanism                                  | BFS Diameter | Distinct States | Sim Traces | Result      |
|--------|--------------------------------------------|--------------|-----------------|------------|-------------|
| 1      | Equivocation + selective dissemination     | 14           | 8.7M            | 166 / 1.0B states  | No violations |
| 2      | Amnesia (crash + WAL truncate + cross-round) | 19         | 160M            | 3.7M / 1.0B+ states | No violations |
| 3      | VE reuse / late commit / replay            | 15           | 181M            | (BFS-only)         | No violations |
| 4      | Lunatic header (light client `VerifyAdjacent`) | 20       | 186M            | (BFS-only)         | No violations |
| 5      | Evidence-lifecycle races                   | 17           | 198M            | (BFS-only)         | No violations |
| 6      | Locking transitions × Byzantine proposer   | 16           | 165M            | (BFS-only)         | No violations |

All BFS runs hit the 30-minute timeout before exhausting the state space
(none reached "complete state graph"; "states left on queue" remained
positive). At the given counter bounds the state spaces are open-ended in
the timeout dimension; the diameters above are the depths achieved within
the budget.

## Spec fixes during hunting

Two Case B fixes were applied before the final per-family runs (also
recorded in `changelog.md`).

### Round 3 — Atomic conflict-detect / consensus-buffer write

The first Family 1 BFS produced a counterexample at trace length 8
violating `EventualAccountabilityStrong`. Analysis showed that
`ReceivePrecommit(i, m)` recorded the conflicting pair into
`seenConflicting[i]` but the spec had decomposed the in-implementation
atomic `ReportConflictingVotes` call (evidence/pool.go:181-188, invoked
from consensus/state.go:2132-2149) into a separate `DetectEquivocation`
action. The intermediate state — `seenConflicting` non-empty,
`consensusBuffer` still empty — was a spec artifact that the
implementation does not exhibit.

**Fix**: Inlined the `consensusBuffer` write into `ReceivePrevote` and
`ReceivePrecommit` when a conflicting vote is detected. The
`DetectEquivocation` action remains as a (now-redundant) secondary
path. After the fix, MC.cfg BFS for 30 min reached diameter 13 / 258M
distinct states with no violation.

### Round 4 — Privval CheckHRS check on signing actions

The first Family 2 BFS produced a counterexample at trace length 11
violating `ConflictsOnlyFromByzantine`. The trace had an HONEST
validator s2 prevoting NilVote at (h=1, r=0), precommitting nil,
crashing, recovering, and then prevoting v1 at the same (h=1, r=0).
The implementation's `privval/file.go:100-131 CheckHRS` blocks this:
`pvLastSign` is persisted in a separate file from the WAL and survives
crashes, so attempting to sign at a previously-signed (H, R, S) for a
different `BlockID` raises `errSameHRS`. The spec, however, was
unconditionally signing in `EnterPrevote` / `EnterPrecommit*` /
`HandleTimeoutPropose` without consulting `pvLastSign`.

**Fix**: Added `PrivvalCanSign(s, h, r, vstep, blockID)` predicate
modelling `CheckHRS` and applied it as a precondition to all seven
signing actions. Step ordering follows the `privval/file.go` const
block: `newHeight < propose < prevote < precommit`. After the fix,
Family 2 BFS for 30 min reached diameter 19 / 160M distinct states
with no violation.

These two fixes restrict the spec by ruling out behaviors that the
implementation does not exhibit, so they do not affect trace validation
of the 9 captured implementation traces (re-verified after each fix).

## Not Reproduced

Below are the bug-family targets and the per-family outcomes within the
bounded BFS budget. None reproduced within the budget; this is *not*
proof of absence — see "Caveats" below.

| Bug Family | Target Bugs                          | Config                                    | States Explored | Result |
|------------|--------------------------------------|-------------------------------------------|-----------------|--------|
| 1 — Equivocation + selective dissem.    | MC-1, MC-2, MC-13                  | `MC_hunt_family1_equivocation.cfg`         | 8.7M (BFS), 1B+ (sim) | No violation |
| 2 — Amnesia × crash × WAL truncate      | MC-3, MC-4                          | `MC_hunt_family2_amnesia.cfg`              | 160M (BFS), 1B+ (sim) | No violation |
| 3 — VE reuse / late commit / replay     | MC-5, MC-6                          | `MC_hunt_family3_vereuse.cfg`              | 181M (BFS)            | No violation |
| 4 — Lunatic header (LightClient.VerifyAdjacent) | MC-7                          | `MC_hunt_family4_lunatic.cfg` (f=2)        | 186M (BFS)            | No violation |
| 5 — Evidence races (expiry, buffer, flood) | MC-8, MC-9, MC-12                | `MC_hunt_family5_evidence.cfg`             | 198M (BFS)            | No violation |
| 6 — Locking × Byzantine proposer        | MC-10, MC-11                        | `MC_hunt_family6_locking.cfg`              | 165M (BFS)            | No violation |

### Caveats

1. **Bounded counters**: Every family config uses `MaxByz*Limit ≤ 2` for
   each fault category. Many of the brief's bug families (e.g.,
   Equivocation × Amnesia composition, MC-4) require composing two
   distinct Byzantine actions; under tight per-class bounds the
   composition is reachable but BFS depth is dominated by the consensus
   state machine's interleaving. Within 30 minutes BFS only reached
   diameters 14–20, well below the depth at which the worst-case
   bug-composition traces would appear.

2. **No fairness in MCSpec**: The `~>` temporal properties
   (`EventualAccountability`, `VELiveness`) cannot be checked against
   `MCSpec` because the latter has no fairness constraint — TLC reports
   trivial stuttering counterexamples and terminates early. These
   properties were disabled in the hunt configs (commented out) so the
   BFS could explore the full state space. The safety projections of the
   eventual properties (`EventualAccountabilityStrong`,
   `VEContextBound`, `LastCommitVECoverage`) **are** checked and held
   across all runs.

3. **MC.tla state-space too large for full BFS**: The convergence config
   `MC.cfg` enables all bug families together; BFS for 30 min reached
   diameter 13 with 258M distinct states and a queue of 230M+ states
   left, indicating the state space at the convergence bounds is
   intractable for exhaustive BFS. Per-family hunt configs disable
   irrelevant Byzantine actions to focus the search, but even these run
   out of time before completing BFS.

4. **Family 4 with f=2 of 4**: Family 4 deliberately uses `Faulty = {s3,
   s4}` (2 of 4) which exceeds the BFT bound `f < n/3` for consensus
   safety. This is intentional — the `LightClientFollowsCanonicalChain`
   invariant has a disjunct allowing the breach when ≥ 1/3 of next
   validators are Byzantine, so the invariant is *expected* to hold
   here. The bug surface is the missing cross-check in
   `light/verifier.go:VerifyAdjacent` (#2252) — but the spec models the
   missing check exactly, so a violation requires composing the missing
   check with a fork-vs-canonical-chain divergence. The BFS depth of 20
   was insufficient to construct that scenario.

5. **Spec abstractions**: The spec abstracts several Byzantine surfaces
   into single actions (`ByzInjectInvalidEvidence`, `ByzFloodEvidence`,
   etc.) without per-attempt parameter variation. This may hide
   composition bugs that only appear with finer-grained models. The
   `byz_*` trace fixtures exercised each surface in isolation; they all
   pass validation, but full BFS over compositions remained shallow
   within the budget.

## Open Bug-Surface Findings (from brief; not falsified by BFS)

The following surfaces from `modeling-brief.md` §3.2 were *modeled* but
not falsified by the BFS exploration above. The implementation evidence
is unchanged from the modeling-brief; what the BFS confirms is that the
spec's converged state-graph remains consistent under these surfaces
within the budget.

- **#2252 LightClient.VerifyAdjacent missing `LastBlockID` cross-check**.
  Modeled in `LightClientVerify`; `LightClientFollowsCanonicalChain` is
  enforced as an invariant. Not falsified at f=2, diameter 20.
- **#5204 VE-deadlock under invalid VE**. Carried from Round 1; the
  liveness aspect `VELiveness` is the temporal property disabled here.
  Safety projection `VEContextBound` held.
- **#5435 DoubleSignCheckHeight=1 zero-iteration bug**. Spec models the
  recover/replay surface; the bug is in the implementation logic that
  is below the spec's abstraction.
- **#1309 POLRound = LockedRound but different block (log-only)**.
  `Round1ProposalValidation` invariant added in Family 6 hunt; held
  across BFS.
- **#4114 Same evidence committed in two consecutive blocks**.
  `EvidenceConsistency` invariant added in Family 5; held across BFS.
- **CR-4 reactor.go:192 (height-only) vs verify.go:313 (AND-with-time)
  expiry mismatch**. `HonestPeerNotPunished` invariant added in Family
  5; held across BFS, but the time-based race may require finer clock
  granularity than the bounded model exposes.

## How to reproduce

```bash
cd /home/ubuntu/Specula/case-studies/cometbft_2/.specula-output/spec
for f in 1 2 3 4 5 6; do
    cfg=MC_hunt_family${f}_*.cfg
    timeout 30m java -XX:+UseParallelGC -Xmx100G \
      -DTLA-Library=/path/to/CommunityModules-deps.jar \
      -cp /path/to/tla2tools.jar:/path/to/CommunityModules-deps.jar \
      tlc2.TLC -fp 73 -workers 80 -checkpoint 0 \
      -metadir /home/ubuntu/Specula/tlc-tmp/family${f} \
      -fpmem 0.4 -config ${cfg} MC.tla 2>&1 | tee output/MC_hunt_family${f}_bfs.out
done
```

Output files in `spec/output/`:

- `MC_run5.out` (Round 2 MC.cfg convergence run)
- `MC_run6.out` (Round 3 MC.cfg convergence run after Case B fix)
- `MC_hunt_family{1..6}_bfs.out` (BFS hunt outputs)
- `MC_hunt_family{1,2,3}_sim.out` (simulation hunt outputs)

## Recommendations

1. **Adopt the two Case B fixes in any future iteration of the spec**
   (atomic conflict-detect/buffer-write, privval CheckHRS check). They
   are minimal restrictions matching implementation behavior.

2. **Add a fairness constraint to `MCSpec`** so the `~>` temporal
   properties (`EventualAccountability`, `VELiveness`) can be checked
   directly. The current safety projections suffice for BFS bug hunting
   but cannot detect liveness violations.

3. **Increase per-family BFS budget or invest in PORs / partial-order
   reductions** to push diameter past ~20. Several of the brief's
   composition bugs (MC-4 = Family 1 × Family 2; MC-13 = three-way
   composition) require deeper traces than 20 actions.

4. **Consider tightening `ConflictsOnlyFromByzantine`** to also assert
   the more conservative invariant that no honest validator's
   `signedVotes` set contains a conflicting pair, even pre-detection.
   The current invariant is on `seenConflicting`; a separate
   `signedVotes` invariant would catch any future spec change that
   permits an honest re-sign.
