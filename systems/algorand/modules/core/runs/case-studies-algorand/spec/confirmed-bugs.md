# Confirmed Bug Report — algorand (go-algorand v4.7.0-stable, agreement/)

## Summary

- **Total findings reviewed**: 11
  - 10 code-review items from the modeling brief §6.3 (CR-1 through CR-10)
  - 1 open upstream PR (PR #5341) referenced in bug-report.md and modeling brief §6.2 T-2
- **Reproduced**: 7 (CR-1, CR-2, CR-5, CR-6, CR-7, PR #5341, plus the cert-cert short-circuit sub-finding of CR-7)
- **Reproduction failed (escalation exhausted, claim stands on audit)**: 0
- **False positives** (real-code behavior dismissed by upstream safeguards or developer intent): 1 (CR-3)
- **Static / code-quality findings** (no runtime behavior to trigger; reproduction is source verification): 3 (CR-4, CR-8, CR-9, CR-10 — counted as one bundle for CR-8/9/10 because all three are TODO-only)

**MC-side note**: `bug-report.md` reports **0 Case C real bugs** found by the model checker across 6 bug-family hunts (107M distinct states explored, 30 min budget each). There are therefore **no MC counterexamples to confirm**. All 11 candidates below come from code review; the MC negative result is noted in a dedicated section below.

## Coverage caveat

`bug-report.md` explicitly flags coverage as **partial**: every MC hunt hit its 30-minute time budget with millions of states still queued, and all 6 family hunts ran with `MaxPeriod = 1` to fit BFS in budget. The model has not explored the period-3+ partition-recovery regime or the full catchup-vs-live interleaving. This case study therefore confirms **no MC-derived bug**, but cannot rule out bugs MC would have found at higher fault counters / `MaxPeriod ≥ 3`. The conclusion below is reported with that caveat.

---

## Bug 1: CR-1 — `fetchRound` fork detection is log-only

- **Source**: Code Review (modeling brief §6.3 CR-1; bug-report.md §"Implementation Findings to Re-Check Manually")
- **Status**: REPRODUCED (Level 0, static source assertion)
- **Severity**: Medium (operational; safety not directly violated, but fork is silently un-escalated)
- **Location**: `catchup/service.go:819-840`
- **Description**: Inside `Service.fetchRound`, if a peer returns a block that doesn't match the cert hash AND the peer's `fetchedCert` is itself valid for that wrong block, the code constructs a multi-line "FORK DETECTED" string and logs it at `Error` level. The leading comment promises "panic as loudly as possible" but the branch contains **no** `panic()`, `os.Exit`, `return`, or `break` — the enclosing `for s.ledger.LastRound() < cert.Round` loop simply continues to the next peer iteration.
- **Trigger scenario**: An adversarial peer (or a peer that participated in a real chain fork) returns a block + cert pair that is internally signed-and-authentic but doesn't match the cert the local agreement service handed to `fetchRound`. The fork branch fires; the node logs ERROR and silently retries against other peers. No halt, no operator alert beyond a routine ERROR log line.
- **Developer intent investigation**: The leading comment ("As a failsafe, ... panic as loudly as possible") demonstrates the developer's intent was a hard failure; the code as committed does not match that intent. `git blame` shows the entire block was introduced as part of the initial v4.7.0 checkpoint commit so individual line-level rationale is not in the artifact's git history. No filed issue acknowledges this discrepancy.
- **Reproduction test**: `repro/test_bug_cr1_fork_detection_log_only.sh` — Level 0 (source assertion: extract the branch body and verify it contains zero halt primitives).
- **Reproduction result**: PASS (bug confirmed). Test output:
  ```
  [1/3] confirming the comment promises a panic
    819: 		// As a failsafe, if the cert we fetched is valid but for the wrong block, panic as loudly as possible
  [2/3] extracting the fork-detection branch body
    ... (branch body printed; ends with logging.Base().Error(s); no panic/return/break/os.Exit)
  [3/3] asserting branch does NOT actually panic, return, or break the loop
    panic( calls in branch:       0
    return statements in branch:  0
    break statements in branch:   0
    os.Exit calls in branch:      0
  CR-1 CONFIRMED: branch body only logs (logging.Base().Error + fmt.Println).
  ```
- **Recommendation**: Either (a) change the comment to match the behavior ("log loudly, continue retrying"), or (b) escalate to operator alert + circuit-breaker (don't keep silently retrying on a fork). Option (b) matches the comment's intent and the protocol's safety-prioritization stance.

---

## Bug 2: CR-2 — `voteTracker` panics on Byzantine-majority equivocation (DoS surface)

- **Source**: Code Review (modeling brief §6.3 CR-2; bug-report.md §"Implementation Findings to Re-Check Manually")
- **Status**: REPRODUCED (Level 0, direct unit test)
- **Severity**: Low (requires Byzantine-majority equivocation, under which safety is already broken; the panic adds a process-abort DoS condition but doesn't itself violate safety)
- **Location**: `agreement/voteTracker.go:189` — `r.t.log.Panicf("too many equivocators for step %d: %d", e.Vote.R.Step, tracker.EquivocatorsCount)`
- **Description**: When an attacker submits enough distinct equivocating votes for the same step that `tracker.EquivocatorsCount` reaches the step's quorum threshold (e.g., 2267 for soft step in v40+), the voteTracker `Panicf`s. The comment at line 185-188 acknowledges that this state already compromises the honest-node assumption.
- **Trigger scenario**: An attacker controlling a majority of stake-weight produces, for each Byzantine validator, two conflicting votes for the same (round, period, step). The honest voteTracker first records each sender as a Voter (proposalA), then upon receiving the second (proposalB) marks them an Equivocator and adds their weight to `EquivocatorsCount`. Once `EquivocatorsCount ≥ step.threshold(proto)`, the next equivocating vote triggers Panicf.
- **Developer intent investigation**: The comment immediately above the Panicf reads: "*In order for this to be triggered, more than 75% of the vote for the given step need to vote for more than a single proposal. In that state, all the proposals become 'above threshold'. That's a serious issue, since it would compromise the honest node core assumption.*" The author explicitly chose `Panicf` to make the protocol-violation state loud and unrecoverable — they preferred fail-stop over silent corruption. This matches Algorand's general "safety first" stance.
- **Reproduction test**: `repro/test_bug_cr2_equivocator_panic.sh` — Level 0.
- **Reproduction result**: PASS. Test output:
  ```
  soft step quorum threshold = 2267
  After single equivocator: EquivocatorsCount=1 (no panic yet, 1 < quorum=2267)
  time="..." level=panic msg="too many equivocators for step 1: 2267" file=voteTracker.go line=189
  CR-2 REPRODUCED: voteTracker.go:189 panic fired — "too many equivocators for step 1: 2267"
  --- PASS: TestReproBugCR2EquivocatorPanic (0.12s)
  ```
- **Recommendation**: The current `Panicf` matches the protocol's fail-stop intent and is defensible. The modeling brief suggests "*downgrading to logged Warn + thresholdEvent-suppression*" which would let an honest node keep running through a Byzantine-majority assault but at the cost of allowing visible-fork conditions to persist. The trade-off favors the current behavior; mark as **DESIGN AS INTENDED** with a note that the brief's CR-2 concern is acknowledged but not actionable without changing the fail-stop posture.

---

## Bug 3: CR-3 — `voteAggregator` "bad round" panic is unreachable through public message path

- **Source**: Code Review (modeling brief §6.3 CR-3; bug-report.md §"Implementation Findings to Re-Check Manually")
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `agreement/voteAggregator.go:130` — `r.t.log.Panicf("bad round (%v, %v)", ...)` with adjacent TODO "this should be a postcondition check; move it"
- **Description**: The brief flagged this as DoS-reachable on a late-vote race. Audit conclusion: `voteFresh` at `voteAggregator.go:198-263` (called before any dispatch) enforces `vote.R.Round ∈ {PlayerRound, PlayerRound+1}`. The threshold emitted downstream inherits the vote's round (`voteTracker.go:246-247`: `round := e.Vote.R.Round`). Therefore the Panicf at line 130 is unreachable through the normal message path.
- **Trigger scenario**: None — `voteFresh` blocks the only path that would reach the panic. The brief's late-vote-race concern would require a vote with `vote.R.Round` outside `{PlayerRound, PlayerRound+1}` to bypass `voteFresh`; no such path exists in the current code.
- **Developer intent investigation**: The TODO comment "this should be a postcondition check; move it" indicates the developer recognized this is a debug-time invariant, not a reachable runtime panic. The fix they intended is cleanup (move it to a contract checker), not a behavior change.
- **Reproduction test**: `repro/test_bug_cr3_bad_round_guarded.sh` — Level 0 (drive `voteFresh` directly with in-range and out-of-range rounds and confirm the upstream rejection).
- **Reproduction result**: PASS as FALSE POSITIVE. Test output:
  ```
  Stale vote rejected by voteFresh: filtered vote from bad round: player.Round=100; vote.Round=50
  Premature vote rejected by voteFresh: filtered vote from bad round: player.Round=100; vote.Round=105
  In-range vote accepted: round=100 (=PlayerRound)
  In-range vote accepted: round=101 (=PlayerRound+1)
  ```
- **Recommendation**: Per the existing TODO, refactor the panic into a `playerContract` postcondition check (it is already wrapped in `checkedListener` etc.) and remove the runtime `Panicf`. No behavior change; pure cleanup.

---

## Bug 4: CR-4 — "It should be impossible to hit this condition" dead branch

- **Source**: Code Review (modeling brief §6.3 CR-4)
- **Status**: REPRODUCED as a code-quality finding (Level 0, source inspection — no runtime trigger to reproduce because the branch is dead code by design)
- **Severity**: Low (cleanup)
- **Location**: `agreement/proposalManager.go:184-188`
- **Description**: When the proposal-vote was kept past freshness for late-credential-tracking and the downstream proposalMachineRound returns `voteFiltered`, the post-dispatch handler reads `LateCredentialTrackingNote` and tolerates any value that isn't one of the two expected enum values by remapping it to `NoLateCredentialTrackingImpact` and emitting a Debugf. The comment says this should be impossible.
- **Trigger scenario**: To exercise the branch you'd need the upstream proposalMachineRound to emit a `filteredEvent` with `LateCredentialTrackingNote ∈ {UnverifiedLateCredentialForTracking, <enum default 0>}` — which the upstream code never does (the seekers only ever return the two whitelisted values). The branch is structurally dead in honest execution.
- **Developer intent investigation**: The comment makes the developer's intent explicit ("It should be impossible to hit"). The presence of the defensive branch suggests an earlier development cycle when an upstream emitter could produce an unexpected note value, since cleaned up.
- **Reproduction test**: `repro/test_bug_cr4_late_credential_branch.sh` — Level 0 source inspection.
- **Reproduction result**: PASS (branch present, no runtime path). Test output enumerates the branch body and confirms upstream emitters never produce out-of-whitelist values.
- **Recommendation**: Either delete the unreachable branch or replace the Debugf with a `r.t.log.Panicf` consistent with the "impossible" comment. Pure cleanup; no behavior change.

---

## Bug 5: CR-5 — `lowestCredentialArrivals` is reset on crash recovery

- **Source**: Code Review (modeling brief §6.3 CR-5; bug-report.md §"Implementation Findings to Re-Check Manually")
- **Status**: REPRODUCED (Level 0, encode/decode round-trip)
- **Severity**: Low (liveness-latency regression in the immediate post-crash window; safety unaffected)
- **Location**: `agreement/persistence.go:246, 262` — `p2.lowestCredentialArrivals = makeCredentialArrivalHistory(dynamicFilterCredentialArrivalHistory)` in both decode branches.
- **Description**: The `lowestCredentialArrivals` circular buffer (40 samples used to compute the dynamic filter timeout) is unconditionally replaced with a fresh empty buffer on `decode()`. After a crash and restore, `calculateFilterTimeout` at `player.go:338-341` falls back to the default `FilterTimeout(0, ver)` because `isFull()` is false. The node will rebuild the history over the next 40 successful period-0 rounds. This is a documented design choice but is **not advertised in operator documentation** — it can surface as elevated period-0 filter timeouts (default vs. dynamic, ~2 s) post-restart, slightly worsening latency until samples accumulate.
- **Trigger scenario**: Operator restarts an algod participating node (planned restart, OOM, machine reboot, software upgrade, etc.). On startup, agreement's `restore()` reads the crash DB, calls `decode()`, and the `lowestCredentialArrivals` field is empty regardless of what was previously persisted. For ~40 rounds the node uses the default filter timeout rather than the lower dynamic value.
- **Developer intent investigation**: The decode function unconditionally calls `makeCredentialArrivalHistory(...)` to initialize the field with the correct size for the current consensus parameter. The struct's `msgp` codec at `agreement/msgp_gen.go` does not include `lowestCredentialArrivals` in the encoded representation. Both observations are consistent with intentional non-persistence — the field is annotated as in-memory-only.
- **Reproduction test**: `repro/test_bug_cr5_credarrival_persistence.sh` — Level 0 (drive `encode()` → `decode()` round-trip).
- **Reproduction result**: PASS. Test output:
  ```
  Before persist: history full=true, order_statistic[37]=137ms
  After decode: history full=false (expected false)
  CR-5 CONFIRMED: persistence.go:246/262 explicitly resets lowestCredentialArrivals on decode.
  Until ~40 successful period-0 rounds pass post-crash, filter timeout reverts to default.
  ```
- **Recommendation**: Either (a) add `lowestCredentialArrivals` to the `diskState` schema and the player msgp codec to persist it (preserve the timeout across crashes), or (b) document the known post-crash liveness regression in `agreement/README.md` and runbook docs. Option (a) is invasive (msgp regeneration, version compatibility); option (b) is a low-risk doc patch.

---

## Bug 6: CR-6 — `proposalTracker` silently overwrites `Staging` on threshold

- **Source**: Code Review (modeling brief §6.3 CR-6)
- **Status**: REPRODUCED as behavior (Level 0), but classified **FALSE POSITIVE for safety** under the upstream guarantee
- **Severity**: Low (the behavior is observable but the upstream voteTracker contract makes the overwrite a no-op in honest execution)
- **Location**: `agreement/proposalTracker.go:203-211`
- **Description**: For `softThreshold` and `certThreshold` events, the proposalTracker's handler sets `t.Staging = e.Proposal` unconditionally, with no comparison against the existing `t.Staging`. The brief asks whether this is safe given upstream guarantees.
- **Trigger scenario for the overwrite**: Directly inject two threshold events for the same period but different proposals; the second silently overwrites the first.
- **Why it's still safe**: Each proposalTracker is scoped to one (round, period). Upstream:
  1. `voteTracker` emits `softThreshold` at most once per step per period (the `overBefore || !overAfter` guard at `voteTracker.go:235-237`).
  2. Senders are filtered by `proposalTracker.Duplicate[v.R.Sender]` (`proposalTracker.go:164-168`) so a Byzantine sender cannot inject two proposal-votes that both promote different thresholds at this tracker.
  3. `certThreshold` only forms after `softThreshold` has staged a value; cert votes are for the staged value, so the cert threshold event carries the same proposal.

  The only way to drive two distinct threshold events for one tracker would be a bug in the voteTracker emitter or a network-level injection that bypasses the in-process router — neither is reachable through the protocol surface.
- **Developer intent investigation**: No comment justifies the overwrite, but the existing `if prevStaging == bottom && e.Proposal != bottom { SpecTraceUpdateStaging(&p, e) }` (lines 207-209) shows the developer thought about prev/new but did not encode a freshness check. The architecture intends the upstream voteTracker contract to enforce single-threshold-per-period.
- **Reproduction test**: `repro/test_bug_cr6_staging_overwrite.sh` — Level 0.
- **Reproduction result**: PASS for the behavior (overwrite reproduces). Test output:
  ```
  After 1st softThreshold: Staging = pA
  After 2nd softThreshold with DIFFERENT proposal: Staging = pB (overwritten silently)
  CR-6 BEHAVIOR CONFIRMED: proposalTracker.go:203-211 always assigns t.Staging = e.Proposal
  ```
- **Recommendation**: Add a defensive `if t.Staging != bottom && t.Staging != e.Proposal { r.t.log.Panicf("staging inconsistency: %v vs %v", t.Staging, e.Proposal) }` to make the upstream invariant explicit. This is defense-in-depth, not a bug fix.

---

## Bug 7: CR-7 — `none.fresherThan(none) == true` is reflexive (and the cert-cert short-circuit)

- **Source**: Code Review (modeling brief §6.3 CR-7; modeling brief §6.1 MC-3 family)
- **Status**: REPRODUCED (Level 0, direct unit test)
- **Severity**: Low (documentation vs. behavior mismatch; the reflexive return is intentionally used by `voteTrackerRound.handle` to allow the empty-cache replacement path to fire)
- **Location**: `agreement/events.go:745-748` (none-reflexive) and `agreement/events.go:777-779` (cert-cert short-circuit)
- **Description**: `thresholdEvent.fresherThan` is documented as a "partial ordering" but has two non-standard cases:
  1. `none.fresherThan(none) == true` — irreflexive partial orders would say false.
  2. Once a `certThreshold` is the cached freshest, no other `certThreshold` (even from a later period) can replace it: the function returns false unconditionally when `o.T == certThreshold`.
- **Trigger scenario**:
  - For (1): the `voteTrackerRound.handle` initialization-time replacement path uses this to allow the first non-empty event to install itself as `Freshest`. Removing the reflexive-true would require initializing `Freshest` explicitly.
  - For (2): an honest committee that has cached a `certThreshold` from period P and then receives a `certThreshold` from period P' > P for a different value — the cache is never updated. Combined with `partitionPolicy` rebroadcasting the cached cert (`player.go:541-545`), an honest node may rebroadcast a stale cert when an updated one exists.
- **Developer intent investigation**: The cert-cert short-circuit is intentional — a `certThreshold` ends the round in the happy path, so two `certThreshold` events for one round should be impossible for honest nodes. Under a real fork the node will eventually catch up; the stale rebroadcast cannot violate safety (a cert is for a value already certified). The reflexive-`none` case is acknowledged in the brief as "*intentional for the empty-cache replacement path but inconsistent with the documented 'partial ordering' comment*."
- **Reproduction test**: `repro/test_bug_cr7_fresherthan_reflexive.sh` — Level 0.
- **Reproduction result**: PASS. Test output:
  ```
  BUG: none.fresherThan(none) returned true (events.go:745-748)
  Contrast: softThreshold.fresherThan(softThreshold same period) returned false
  Cert-cert short-circuit confirmed: neither (Per0 cert).fresherThan(Per1 cert) nor reverse is true
  ```
- **Recommendation**: Document both behaviors explicitly in the function doc-comment (it currently says "partial ordering" without noting the reflexive-`none` exception nor the cert-cert short-circuit). No behavior change required.

---

## Bug 8: CR-8 — `BlockValidator.Validate` TODO ("second Round argument")

- **Source**: Code Review (modeling brief §6.3 CR-8)
- **Status**: REPRODUCED as a static TODO finding (Level 0 source check)
- **Severity**: Low (cleanup)
- **Location**: `agreement/abstractions.go:49`
- **Description**: A TODO comment notes that `BlockValidator.Validate(context.Context, bookkeeping.Block) (ValidatedBlock, error)` probably needs a `round` argument so the validator knows which round's protocol rules to apply. As-shipped the validator gets the block (which carries its own round), so the TODO is informational, not load-bearing.
- **Trigger scenario**: None. The validator currently extracts the round from `Block.Round()`; an explicit round argument would only be needed if a caller wanted to validate against a *different* round's rules.
- **Developer intent investigation**: The TODO has been present since the v4.7.0 checkpoint commit. No filed issue or follow-up PR addresses it.
- **Reproduction test**: `repro/test_bug_cr8_cr9_cr10_todos.sh` — verifies the TODO is still present.
- **Reproduction result**: PASS.
- **Recommendation**: Either remove the TODO (current contract is fine — the block carries its round) or file a tracking issue.

---

## Bug 9: CR-9 — Redundant `Hash()` call in `verifyProposer`

- **Source**: Code Review (modeling brief §6.3 CR-9)
- **Status**: REPRODUCED as a static TODO finding (Level 0)
- **Severity**: Low (micro-inefficiency; no correctness impact)
- **Location**: `agreement/proposal.go:245-247`
- **Description**: A TODO comment notes that the `Hash()` call at line 247 is redundant with the VRF `Verify()` call already performed at line 241. Removing it would save one Ed25519-VRF hash per proposal verification.
- **Trigger scenario**: None — pure performance cleanup.
- **Developer intent investigation**: The TODO acknowledges the redundancy; no follow-up PR has addressed it.
- **Reproduction test**: `repro/test_bug_cr8_cr9_cr10_todos.sh`.
- **Reproduction result**: PASS.
- **Recommendation**: Remove the redundant call; quantify the savings under benchmark.

---

## Bug 10: CR-10 — PR #5286 TODO file still present, not actioned

- **Source**: Code Review (modeling brief §6.3 CR-10; bug-report.md §"Implementation Findings to Re-Check Manually")
- **Status**: REPRODUCED as a static finding (Level 0)
- **Severity**: Low (un-investigated maintainer concern; not a behavior bug until shown otherwise)
- **Location**: `agreement/TODO` (a 2-line file at the package root)
- **Description**: The modeling brief claimed the TODO file was deleted in PR #5286 without follow-up issues. **In the v4.7.0-stable artifact, the file IS still present** with these two lines:
  ```
  Blocks are not correctly attached to next-vote bundles
  Blocks attached to next-vote bundles are not correctly processed
  ```
  These are the un-investigated items the maintainer (bbroder-algo) admitted not understanding well enough to file follow-ups for. The brief's claim about the file's deletion is incorrect; the items remain in the tree but no work items track them.
- **Trigger scenario**: Unknown — the TODO author did not understand the items well enough to articulate a trigger.
- **Developer intent investigation**: PR #5286 closed without filing follow-up issues. The maintainer comment acknowledges incomplete understanding. No git-blame or commit message in the artifact tells us what the original observation was about. The items reference "next-vote bundles" specifically, suggesting `voteAuxiliary.go` / `proposalStore.go` / `actions.go` interaction with `nextThreshold` events, but the exact scenario is undocumented.
- **Reproduction test**: `repro/test_bug_cr8_cr9_cr10_todos.sh` (verifies the file is present and contains the two lines).
- **Reproduction result**: PASS (file present; items unaddressed).
- **Recommendation**: Either delete the file (treat as stale) or re-investigate with current code and file fresh issues. Without the author's original context, neither path is decidable from the artifact alone.

---

## Bug 11: PR #5341 — `AsyncVoteVerifier.Quit` shutdown race

- **Source**: Code Review (bug-report.md §"Implementation Findings to Re-Check Manually"; modeling brief §1, §2 Family 1, §6.2 T-2; PR #5341 open)
- **Status**: REPRODUCED (Level 1 — concurrent stress test under `go test -race`)
- **Severity**: Medium (panic on shutdown is a process-abort condition affecting orderly node restart, but only fires during shutdown — bounded blast radius)
- **Location**: `agreement/asyncVoteVerifier.go:142-143` (`wg.Add(1)` + `EnqueueBacklog`) racing `agreement/asyncVoteVerifier.go:180` (`wg.Wait()`); downstream consequence is `agreement/asyncVoteVerifier.go:186` (`close(execpoolOut)`) racing `agreement/asyncVoteVerifier.go:91` (`asyncResponse.req.out <- ...`).
- **Description**: `Quit()` calls `ctxCancel()` then `wg.Wait()`. A concurrent `verifyVote()` caller can check `<-avv.ctx.Done()` (TOCTOU window before ctxCancel), then call `wg.Add(1)` and `EnqueueBacklog`. The race detector flags the unsynchronized `wg.Add(1)` vs `wg.Wait()` access. Worst case: the late-added task is processed by the backlog worker after `close(execpoolOut)`, panicking with "send on closed channel."
- **Trigger scenario**: An algod restart (or `algod stop`) calls `AsyncVoteVerifier.Quit()` while the agreement service still has in-flight vote verifications. If a vote arrives on the wire at the exact moment of `ctxCancel()`, the verifier's `select{ <-avv.ctx.Done(): default: }` can take the default branch before the cancel propagates, enqueue work after `wg.Wait()` has observed 0, and the worker then sends to a closed channel.
- **Developer intent investigation**: PR #5341 is **open** and the maintainer comment acknowledges the panic. The fix has been blocked / deferred. The `wg.Add(1)` placement after the ctx check is the known structural cause. The `// case <-verctx.Done(): DO NOT DO THIS!` comment at lines 137-138 shows the developer was aware of cancellation correctness on the per-request context but did not apply the same care to the shutdown context.
- **Reproduction test**: `repro/test_bug_pr5341_avv_shutdown_race.sh` — Level 1 (concurrent stress test; relies on `-race` to detect the unsynchronized wg access; the actual "send on closed channel" panic is a downstream consequence requiring an even tighter timing window).
- **Reproduction result**: PASS under `-race`. Test output (excerpt):
  ```
  ==================
  WARNING: DATA RACE
  Write at 0x00c0002ba100 by goroutine 131:
    github.com/algorand/go-algorand/agreement.(*AsyncVoteVerifier).Quit()
        asyncVoteVerifier.go:180 +0x50
  Previous read at 0x00c0002ba100 by goroutine 348:
    github.com/algorand/go-algorand/agreement.(*AsyncVoteVerifier).verifyVote()
        asyncVoteVerifier.go:142 +0x198
  ==================
  --- FAIL: TestReproBugPR5341AsyncVoteVerifierShutdownRace (0.78s)
  ```
  Without `-race` (regular run), 200 trials produced no panic — the precise timing window for the closed-channel send is tight. The race is structurally present and detected by Go's race detector; the panic is a low-but-nonzero probability downstream consequence.
- **Recommendation**: Reorder `Quit()` to use a `sync.Mutex` or atomic flag set before `ctxCancel()`, with `verifyVote` checking the flag under the same lock. Alternative: replace the `select{ ctx.Done(): default: }` TOCTOU with a `defer/recover` to absorb late panics — uglier but localized. Match the existing per-request `verctx` ordering pattern. The PR #5341 thread already proposes a fix; that fix should be reviewed and merged.

---

## MC Bug Families — Negative Results

`bug-report.md` documents 6 BFS hunts that explored the converged spec for 30 minutes each and found **no Case C real bug** (no safety invariant violation). For each, Phase 1 investigation confirms the modeling brief's hypothesis is **theoretically present in code but bound by upstream guarantees**:

| Family | Hypothesis | Phase 1 conclusion |
|--------|-----------|-------------------|
| **F1** — Catchup vs Live Agreement race | `pseudonode` votes drain before `ledgerNextRoundCh` deliver | Possible during a tight window, but the freshness filter (`voteFresh` + `voteStepFresh`) drops votes once player has advanced. The race observed in MC bug-report.md is a property of message ordering, not a safety violation. Related concrete code-review issue is PR #5341 (Bug 11). |
| **F2** — Reproposal guard asymmetry | cert/next/fast vote paths trust upstream `Staging` without re-applying the reproposer check | Audit confirms the asymmetry exists (`player.go:209-212, 222-251, 253-284` vs `player.go:170-212`), but the upstream `proposalTracker.Duplicate` and `voteTracker.Voters` maps prevent the same sender from re-staging different values. Family-2 BFS at `MaxPeriod=1, byz×5` found no violation. CR-6 (Bug 6) addresses a related symptom. |
| **F3** — Dynamic filter timeout divergence | Per-node `lowestCredentialArrivals` differs after partition healing | Not a safety target. Eventual convergence is enforced by the protocol-wide `min(2500ms, defaultTimeout)` clamp. CR-5 (Bug 5) is the related crash-recovery case. |
| **F4** — Freshest bundle cert-cert short-circuit | `certThreshold.fresherThan(certThreshold)` always false | Confirmed via CR-7 (Bug 7). The short-circuit is deliberate; with `MaxPeriod=1` the rebroadcast can only carry the original cert, so no safety violation. |
| **F5** — VRF seed lookback forks | Same validator can be in or out of committee depending on the branch's `Seed(R-2)` | Standard BA* safety argument (per-branch stake-weighted thresholds) covers this; IACR 2023/1344 audit also addresses it. Liveness-only concern; not safety. |
| **F6** — Crash recovery state coverage | Post-crash state regression | CR-5 (Bug 5) reproduces the documented regression; safety is preserved by the persist-then-broadcast contract at `pseudonode.go:457-469`. |

**Coverage caveat (re-iterated)**: each hunt ran at the 30-min BFS budget with diameter 8–17, well below the 25-step threshold the workflow recommends for high-confidence verification. The MC's "no bug found" result is partial. The modeling brief recommends simulation follow-ups with deeper traces and `MaxPeriod = 3` partition recovery — work not yet done.

---

## Final classification summary

| Bug | Severity | Status | Reproduction Level | Real bug? |
|-----|----------|--------|-------------------|-----------|
| CR-1 fork detection log-only | Medium | REPRODUCED | 0 | Yes — comment vs code |
| CR-2 equivocator Panicf | Low | REPRODUCED | 0 | By design (fail-stop), reachable under Byzantine majority |
| CR-3 bad-round Panicf | N/A | FALSE POSITIVE | 0 | No — voteFresh guards |
| CR-4 dead branch | Low | REPRODUCED (source) | 0 | Cleanup |
| CR-5 cred-history not persisted | Low | REPRODUCED | 0 | Yes — undocumented liveness regression |
| CR-6 Staging overwrite | Low | REPRODUCED (behavior); SAFE per upstream | 0 | Behavior present but benign |
| CR-7 fresherThan reflexivity & cert-cert short-circuit | Low | REPRODUCED | 0 | Documentation vs behavior |
| CR-8 Validate Round TODO | Low | REPRODUCED (TODO present) | 0 | Cleanup |
| CR-9 redundant Hash() TODO | Low | REPRODUCED (TODO present) | 0 | Micro-cleanup |
| CR-10 unactioned TODO file | Low | REPRODUCED (file present, items unactioned) | 0 | Maintenance debt |
| PR #5341 AsyncVoteVerifier race | Medium | REPRODUCED under -race | 1 | Yes — open upstream PR |

**No critical or high-severity safety bug confirmed.** This is consistent with `bug-report.md`'s MC result and the IACR 2023/1344 audit. Two findings (CR-1, PR #5341) are medium-severity operational issues that should be addressed; the remaining items are documentation, cleanup, or design-as-intended.
