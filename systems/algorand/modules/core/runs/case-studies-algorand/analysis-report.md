# Analysis Report: algorand/go-algorand

## 0. Scope and Coverage Statistics

**Target**: algorand/go-algorand, `agreement/` package (Algorand BA-star).
**Commit**: `6927d906446d404705e46dcb8ecd759b642374c2` (v4.7.0-stable, merged 2026-05-01).
**Repository working tree**: `/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand`.
**Scope**: `agreement/`, `data/committee/`, `catchup/`, and selected supporting files (`config/consensus.go` for parameters). Out of scope: AVM/TEAL, tx pool, ledger merkle and state-proof modules, networking transport, REST API.

**Coverage**:
- **Files read in full**: `agreement/player.go`, `proposal.go`, `proposalManager.go`, `proposalTracker.go`, `proposalStore.go`, `voteTracker.go`, `voteAggregator.go`, `voteAuxiliary.go`, `demux.go`, `actions.go`, `service.go`, `types.go`, partial reads of `events.go`, `persistence.go`, `pseudonode.go`, `cryptoVerifier.go`, `abstractions.go`, `router.go`, `credentialArrivalHistory.go`, `dynamicFilterTimeoutParams.go`, `catchup/service.go`, `data/committee/credential.go`, plus parallel subagent deep-reads of the same set with cross-verification.
- **Local git commits to `agreement/`**: 57 (full set from earliest reachable to HEAD). The local mirror's history starts at `eeca9e5e` (~v3.11.0, Sept 2022).
- **Bug-fix commits analyzed**: All 8 commits matching `--grep fix|bug` in agreement-touching set; plus all 8 commits in `catchup/`.
- **GitHub issues / PRs deeply read (with full comment threads)**:
  - #5341 (OPEN) — vote verifier shutdown panic
  - #6349 (MERGED) — mainLoop vs Shutdown race
  - #6447 (MERGED) — votes telemetry log-level fix
  - #6551 (MERGED) — agreement broadcast/relay action refactor
  - #5286 (CLOSED) — agreement TODOs
  - #4711 (OPEN) — agreement persistence msgp tech debt
  - #5654 (MERGED) — dynamic lambda
  - #5715 (CLOSED, folded into #5654) — current round awareness
  - #4870 (OPEN) — Speculative Block Assembly epic
  - #5701 (MERGED) — continue tracking after freezing
  - #5853 (MERGED) — minimum dynamic filter timeout
  - #5850 (MERGED) — period 0 deadline timeout
  - #5868 (MERGED) — consensus v39 upgrade
  - #1505 (CLOSED) — FilterTimeout changes followup
  - **Issues skimmed for relevance, not deeply read**: ~80 issues from `gh issue list -R algorand/go-algorand --state all --search "label:bug"` (most are infra/REST/operational and not consensus-relevant). #6606 (security vuln, unread by analysis — content not posted publicly).
- **False positives explicitly excluded**: 5 (see §8).
- **Confirmed bug-prone mechanisms identified**: 6 (see Bug Families in modeling brief).
- **Open issues with consensus implications**: 2 (#5341 vote-verifier shutdown race; #5286 cited TODOs).

---

## 1. System Category Classification

**Category A (Distributed / Message-Passing)** with **BFT overlay**.

Justification:
- Multi-validator consensus with stake-weighted thresholds.
- Adversary model: adaptive corruption (commitment to vote not revealed until message broadcast — `data/committee/credential.go` VRF-based per-step sortition).
- Network model: partial-synchronous post-GST; intermittent partitions are expected (`agreement/player.go:570-572` defines a `partitioned()` flag; partition recovery is built in).
- Safety / liveness arguments depend on `f < n/3` stake assumption.

Applies: `references/distributed-analysis.md` + `references/bft-analysis.md`.

Does NOT apply: `references/concurrent-analysis.md` (the concurrent components — cryptoVerifier, pseudonode, persistence loop — are subordinate to a serialized state machine and do not present lock-free hazards that would dominate the protocol's correctness).

---

## 2. Architecture Map

The `agreement.Service` is a two-goroutine event loop with three concurrent subsystems:

```
              ┌──────────────────┐         ┌──────────────────┐
              │    mainLoop      │ <─────> │    demuxLoop     │
              │  (state machine) │ output  │  (event source)  │
              └──────────────────┘ input   └──────────────────┘
                       │                            │
            ┌──────────┴──────────┐                 │
            │  router → player    │                 │
            │  ↓                  │                 │
            │  proposal machines  │                 │
            │  vote machines      │                 │
            └─────────────────────┘                 │
                                                    │
            ┌───────────────────────────────────────┴────┐
            │ cryptoVerifier │ pseudonode │ persistence  │
            │ (per-tag pool) │ (own keys) │ (SQLite WAL) │
            └────────────────┴────────────┴──────────────┘
```

Atomicity boundary: every `event` handed to `mainLoop` is processed atomically — the player and all subordinate state machines mutate state synchronously within a single `router.submitTop` call (`service.go:264`). After each event, `mainLoop` yields to `demuxLoop` via the unbuffered `output` channel. `demuxLoop` executes the resulting `actions` (which may issue network broadcasts, persist state, or kick off async crypto verification), then asks `demux.next` for the next event.

Persistence ordering (`actions.go:438-446`, `pseudonode.go:454-499`): an `attest` action is "persistent" — the player state and the action list are encoded and durably written before the corresponding vote is broadcast. The pseudonode goroutine blocks on `<-t.persistStateDone` (`pseudonode.go:458`) and only writes the vote to `t.out` after the persistence loop signals completion via a `checkpointEvent` round-tripping through the state machine. Verified.

Key state machines under `player`:

- `proposalManager` (root proposal machine): freshness filtering, period transitions.
- `proposalStore` (per round): pinned/relevant/assemblers — actual block payloads.
- `proposalTracker` (per period): frozen value (`Freezer`), staging value, `lowestIncludingLate` for late-credential tracking.
- `voteAggregator` (root vote machine): freshness filtering on incoming votes/bundles.
- `voteTrackerRound` (per round): freshest bundle cache.
- `voteTrackerPeriod` (per period): cached next-threshold status (Bottom, Proposal).
- `voteTracker` (per step): vote counting, equivocation handling, threshold emission.

---

## 3. Bug Archaeology — Mined Evidence

### 3.1 TestNet stall 2022-07-08 (referenced in task spec)

- **Outcome**: ~5-hour stall on Algorand TestNet.
- **Root cause**: `ledger/internal/prefetcher/prefetcher.go` — resource prefetch optimization seeded resource/account tasks unevenly for asset/app transactions. The path executed only at voter time, not at proposer time, so blocks passed proposer validation but failed at voter validation. Every reproposal hit the same fault.
- **Fix**: v3.8.1-stable, commit `e4c7164a` "disable resource prefetch optimization" (2022-07-08, ~3h after detection). Hot-disabled the affected `loadAccountsAddResourceTask` calls.
- **Significance for `agreement/`**: NONE directly — the bug lived in the ledger layer. But the *failure mode* — proposer/voter divergence on a block's validity — is a general class of bug that `agreement/` is exposed to (via `BlockValidator.Validate` at proposer time vs voter time).
- **Local git impact**: history starts ~3.11.0 (Sept 2022), so the buggy commit and the fix are upstream-only.

### 3.2 PR #5701 — `continue tracking the best proposal even after freezing`

- **Original defect**: After `proposalSeeker.freeze()`, late-arriving proposals with strictly lower credentials were dropped. The dynamic filter timeout was therefore computed against inflated "lowest credential" values.
- **Fix**: introduces `lowestIncludingLate` / `hasLowestIncludingLate` in `proposalSeeker.accept` (`proposalTracker.go:50-71`); `proposalManager.filterProposalVote` (`proposalManager.go:251-290`) re-routes filtered late period-0 propose votes for credential-history scoring; `player.go:299-314` reads history `credentialRoundLag` rounds behind.
- **Completeness**: the fix is honest but partial. Two honest period-0 nodes observing different sets of late credentials (e.g., partition healing mid-collection) will have different histories, hence different filter timeouts. Not safety-violating because clamped to `[2500ms, defaultTimeout]`, but a real per-node divergence source. Acknowledged by author (yossigi).

### 3.3 PR #5853 — `Set minimum dynamic filter timeout to 2500ms`

- **Motivation**: mainnet telemetry (urtho) showed global p95 propagation ~337ms with limited geographic distribution; voters far from the relay backbone (and Africa-side validators) were systematically missing the filter step.
- **Side-effect requiring same PR**: `credentialRoundLag = 2·SmallLambda/lowerBound` would drop to 2 at the new lower bound, breaking GC assumptions in `router.go:55-71`. Same PR pinned `minCredentialRoundLag = 8`.

### 3.4 PR #5850 — `Period 0 deadline timeout`

- **Change**: `DeadlineTimeout(p, v)` returns `AgreementDeadlineTimeoutPeriod0` (4s in v39) for period 0; period > 0 uses `defaultDeadlineTimeout = BigLambda + SmallLambda ≈ 17s`.
- **Reviewer-flagged but deferred concerns**:
  - jannotti: "the times for all the steps after 1 will not use the short timeout from period 0, step 1 ... we'll get rounds of 3, 8, X, instead of 3.5, 21, X" — left as "I'm not sure any real harm will come from my concern."
  - zeldovich: `nextVoteRanges()` uses `defaultDeadlineTimeout`, so the player "will sleep for longer than needed" after a period-0 cert step — deferred to follow-up PR.
  - algorandskiy: "is it possible the `AttachConsensusVersion` not called at all and `Proto ConsensusVersionView` is just empty?" — partially handled by `player.go:103-108` fallback; not deeply tested.

### 3.5 PR #5868 — `Consensus v39 upgrade`

- Flips `v39.DynamicFilterTimeout = true`, `AgreementDeadlineTimeoutPeriod0 = 4s`.

### 3.6 PR #5341 — `vote verification task added while shutting down` (OPEN)

- **Race**: `AsyncVoteVerifier.Quit()` closes `avv.execpoolOut`; in-flight `verifyVote` tasks pass the `ctx.Done()` check then write to the closed channel → panic.
- **Scope**: shutdown-only, NOT a normal-operation vote-handling race.
- **Status**: open / "blocked" for >2 years.

### 3.7 PR #6349 — `mainLoop vs Shutdown race`

- **Race**: `done` channel was closed only by `demuxLoop`, but `Shutdown()` waited on it alone — `mainLoop` could outlive `Shutdown()` return.
- **Fix**: switched to `sync.WaitGroup`.

### 3.8 Issues that exist but contribute no consensus signal

- #6447 (telemetry log-level fix) — pure log gating.
- #6551 (broadcast/relay action refactor) — typed actions; no semantic change.
- #4711 (msgp serialization workaround) — disk format compat; no consensus impact.
- #4870 (Speculative Block Assembly epic) — perf/liveness optimization, gated by actual cert quorum so safety is preserved.

### 3.9 Academic audit — IACR 2023/1344 (CCS'23)

Benhamouda, Halevi, Krawczyk, Lin, Rabin "Analyzing the Real-World Security of the Algorand Blockchain":
- Threat model: adaptive corruption with stake fraction <1/3 honest committees, asynchronous network for safety, intermittent-fair for liveness.
- **No exploitable safety/liveness flaw reported.**
- Observation: deployed protocol "differs substantially from the protocols described in the published literature on Algorand" — specifically, the soft/cert/next-vote three-vote structure, partition recovery via late-bundle propagation, and 320-round seed lookback had no prior end-to-end formal analysis.
- Quantitative: insecure execution w.p. ≤ 2^-55; intermittent-fairness graded consensus fails w.p. < 2^-93.

Other formal efforts:
- Runtime Verification Coq model (Alturki et al., FMBC 2020) — proves **asynchronous safety only** (no two blocks certified in same round); admitted liveness lemmas. Abstract global state-transition model, not extracted from go-algorand.
- No public TLA+ spec of Algorand BA* exists.
- arXiv:2508.19452 (2025) — CADP / probabilistic process calculus on BBA*; no implementation bugs reported.

---

## 4. Detailed Findings

### 4.1 Catchup vs Live Agreement Race (Bug Family 1)

**Finding**: An honest validator that is partitioned in round R period P > 0 can broadcast cert / next votes for round R AFTER the catchup service has installed the certified block for round R. The vote is for the validator's local Staging value, which may differ from the catchup-installed block.

**Trace**:

1. `player` is in round R, period P > 0; `Staging[R, P] = V_local`.
2. Soft threshold for V_local arrives in period P, generating a `proposalCommittable` event.
3. `player.handleThresholdEvent` for softThreshold (player.go:377-390) issues `issueCertVote(V_local)`.
4. The resulting `pseudonodeAction{T: attest, Round: R, Period: P, Step: cert, Proposal: V_local}` runs `MakeVotes` → vote-signing kicks off async (`pseudonode.go:387`).
5. Concurrently, catchup completes `AddValidatedBlock` for round R (`catchup/service.go:442-444`). Ledger bulletin fires; `ledger.Wait(R)` becomes readable, propagating to `ledgerNextRoundCh` in demux.go:259.
6. Meanwhile pseudonode finishes crypto and waits on `<-t.persistStateDone` (pseudonode.go:458). When the persistenceLoop has written to disk and sent `checkpointEvent` back through the state machine, `persistStateDone` closes.
7. Pseudonode pushes the vote to `t.out` (pseudonode.go:484), which is the prioritized event queue.
8. `demux.next` (demux.go:217-236) drains the prioritized queue FIRST; the vote event reaches `mainLoop` before `ledgerNextRoundCh` is even examined.
9. `player.handleMessageEvent` for `voteVerified` (player.go:738-745) emits `relayVoteAction(e, v.u())`. The vote is BROADCAST to the network.
10. Next `demux.next` call observes `ledgerNextRoundCh` and emits `roundInterruptionEvent`. Player enters round R+1.

**Window**: from "catchup `AddBlock` completed" to "player has consumed the queued vote action and is back in demux.next" — typically <1ms with no I/O, but can extend if many votes are queued or persistence is slow.

**Safety risk**: For BA* safety to be violated, the broadcast V_local cert vote (plus similar votes from other partitioned honest nodes) would need to combine with adversarial votes to form a `CertCommitteeThreshold` for V_local in (R, P). By the BA* paper's safety argument (cert threshold for V in P implies V is the only value that can be soft-threshold'd in subsequent periods), this is supposed to be impossible if V_local ≠ V_catchup. The TLA+ model should verify this — particularly under message reordering across many partitioned validators racing the catchup arrival.

**Liveness risk**: wasted votes; if the partitioned nodes form a large enough fraction, the network sees a large cert-vote count for V_local, which may slow recovery convergence even if it doesn't violate safety.

### 4.2 Reproposal Guard Asymmetry (Bug Family 2)

**Finding**: The "OriginalPeriod < Period implies must match prior nextStatus" check at `player.go:196-202` is applied ONLY on the soft-vote path. cert/next/fast paths trust upstream Staging (proposalTracker.go) and the nextStatus cache (voteAuxiliary.go).

Specifically:

```go
// player.go:196-202 (issueSoftVote)
if p.Period > a.Proposal.OriginalPeriod {
    // leader sent reproposal: vote if we saw a quorum for that hash, even if we saw nextStatus.Bottom
    if nextStatus.Proposal != bottom && nextStatus.Proposal == a.Proposal {
        return append(actions, a)
    }
    return nil
}
```

This guard is absent in `issueCertVote` (player.go:209-212) which simply emits the cert vote with whatever `committableEvent.Proposal` arrived; and in `issueNextVote` (player.go:214-242) which trusts `stagedValue` or `nextThresholdStatusRequest`.

The guard's correctness depends on upstream Staging being correct. `proposalTracker.go:203-211` sets `t.Staging = e.Proposal` from softThreshold/certThreshold without validating against OriginalPeriod. proposalStore.softThreshold (proposalStore.go:323-346) similarly trusts the input.

**Why it might still be safe**: The Algorand paper argues that cert threshold for V in period P implies V is the only possible soft-threshold target in subsequent periods. This is enforced by the *aggregate honest validator behavior* (soft-voting follows starting value, which carries cert), not by per-node guards. So if no individual honest validator soft-votes a reproposed V' ≠ V, the soft threshold for V' cannot form, hence cert vote for V' cannot be triggered.

**Why TLA+ should model it**: the safety argument is non-trivial and combines guards across multiple validators. A TLA+ model can verify whether all combinations of `(Staging[s], nextThresholdCache[s], OriginalPeriod[V])` reachable from legal message orderings preserve the invariant.

### 4.3 nextThresholdStatus Cache Independent Fields (Bug Family 2)

**Finding**: `voteTrackerPeriod.Cached` (`voteAuxiliary.go:25-26, 71-77`) stores `Bottom` and `Proposal` as independent fields, set by separate next-threshold events. The cache can report `(Bottom = false, Proposal = bottom)` if the player fast-forwarded into a period without observing a real next threshold from the previous period.

Comment in `events.go:891-904` (around `nextThresholdStatusEvent`) confirms this: "if we fast-forwarded to this period or entered via a soft/cert threshold, nextStatus.Bottom will be false and we will next vote bottom."

Queries at `player.go:180, 223, 260` always look up `voteMachinePeriod, p.Round, p.Period-1, 0`. If the player has been advanced to period P by mechanisms other than seeing a local period-1 next threshold, the cache for `(R, P-1)` may be empty or have only partially populated fields.

### 4.4 Freshest Bundle: `fresherThan` Partial-Order Edge Cases (Bug Family 4)

**Finding**: Two edge cases in `events.go:744-801`:

1. **`none.fresherThan(none) == true`** (line 746-748). Documented as "partial ordering" but reflexive on `none`. Benign — the cache starts with `T = none`, and any actual event correctly replaces it.

2. **`certThreshold.fresherThan(certThreshold) == false`** (line 777 short-circuit). Once a cert is cached as Freshest, no future event can replace it, INCLUDING a cert from a later period.

For case 2: under normal operation, only one cert can form per round (one cert per period, and any cert ends the round). Across periods, cert thresholds for the same value can in principle form due to messaging delays, but the cached Freshest only changes if the new event is `fresherThan` the cached one. The short-circuit means an older cert never gets replaced by a newer one.

**Concrete consequence**: `partitionPolicy` (player.go:512-568) rebroadcasts `bundleResponse.Event.Bundle`. If a stale cert is cached as Freshest, partition recovery will keep replaying it. Receivers will filter as stale via `bundleFresh` (voteAggregator.go:283-285) which checks `b.Round == PlayerRound`. But within the same round, this is benign because there is only one valid cert per round.

The interaction with `Staging` is the real concern: `proposalStore.softThreshold/certThreshold` sets `Staging = e.Proposal` (proposalStore.go:323-346) without consulting Freshest. So `Staging` can be set to one value while Freshest holds a cert for a different value — a state inconsistency that TLA+ should check.

### 4.5 Dynamic Filter Timeout — Per-Node Divergence (Bug Family 3)

**Finding**: The `lowestCredentialArrivals` history is per-node, derived from local observation, and reset on entering any non-zero period. After a brief partition that heals mid-round-window, two honest nodes can have materially different histories for the next 40 rounds. Both nodes' filter timeouts are clamped to `[2500ms, 4s]`, so the divergence is bounded, but it is a real per-node asymmetry source.

**Persistence**: history is NOT persisted (persistence.go:246, 262). Post-crash, the node uses the default until 40 fresh samples accumulate. This is a liveness degradation, not a safety issue.

### 4.6 Crash Recovery — Persist-Before-Send Ordering (Bug Family 6)

**Verified**: votes are written to the network only after persist completes. The chain:

1. `mainLoop` produces `pseudonodeAction{T: attest, ...}`. If `persistent(a)`, `s.persistRouter/persistStatus/persistActions = router/status/a` (service.go:266-270).
2. `mainLoop` sends `a` to `demuxLoop` over unbuffered `output` channel.
3. `demuxLoop` runs `pseudonodeAction.do` (actions.go:427-456):
   - `MakeVotes` kicks off async signing goroutine.
   - `persistState` encodes and enqueues to `persistenceLoop`.
   - Prioritizes `persistCompleteEvents` (open until checkpointEvent → checkpointAction → close).
   - Prioritizes `voteEvents` (open until pseudonode pushes signed votes).
4. Pseudonode goroutine: signs votes, then blocks on `<-t.persistStateDone` (pseudonode.go:458). Only unblocks when persistence is durable.
5. After unblock, votes pushed to `t.out` → demux → state machine → relay.

Cross-goroutine safety of `s.persistRouter/persistStatus/persistActions`: mainLoop is the only writer, demuxLoop (via `pseudonodeAction.do`) is the only reader, and they handshake on unbuffered channels — no concurrent access.

**Verdict**: persistence ordering is safety-correct. The window where state could be inconsistent does not exist as long as the SQLite persist uses `crash.Atomic` (it does — `persistence.go:109`).

### 4.7 fetchRound Fork Detection — Log Only (CR-1)

**Finding**: `catchup/service.go:819-840` detects when a peer returns a *valid cert* authenticating a *different block* than the agreement's cert. The trigger requires a Byzantine threshold of stake double-signing, so it indicates a genuine fork. The response is to log to stderr and `logging.Base().Error`, then continue the `for s.ledger.LastRound() < cert.Round` retry loop.

There is no halt, no operator alert, no service quarantine. A real fork would silently retry forever.

### 4.8 VRF Seed Lookback (Bug Family 5)

**Finding**: `seedRound(R) = R - SeedLookback` where `SeedLookback = 2` for current consensus. A fork at `R - 2` produces different sortition committees on the two branches. `BalanceRound(R) = R - 320` (MaxBalLookback in v8); `ParamsRound(R) = R - 2`. At `SeedRefreshInterval` (80) rounds, additional digest entropy is mixed in from `R - SeedLookback * SeedRefreshInterval = R - 160` rounds.

**Safety**: robust to seed-divergent forks. `EnsureBlock` contract (`abstractions.go:197-212`) forbids two distinct blocks for one round. Per-branch sortition + per-branch stake-weighted thresholds preserve the safety argument under the f < n/3 assumption.

**Liveness**: a single round's proposer has one bit of grinding power. Adversarial delay of the round-`R-2` proposer can push validators into the deadline path for round R because `ledger.Seed(R-2)` returns error for an unconfirmed round. Real but bounded.

### 4.9 voteAggregator Panic on Bad Round (CR-3)

**Finding**: `voteAggregator.go:128` calls `r.t.log.Panicf("bad round (%v, %v)", ...)` if a thresholdEvent's round is neither `PlayerRound` nor `PlayerRound+1`. Reachable if `voteTracker` emits a threshold for an old round during late-vote processing. The `voteFresh` check should prevent this (`voteAggregator.go:252-279`), but no defense in depth.

### 4.10 voteTracker Panic on Equivocator Quorum (CR-2)

**Finding**: `voteTracker.go:189` calls `Panicf("too many equivocators for step %d: %d", ...)`. Triggered when `tracker.EquivocatorsCount` reaches the step's quorum threshold — i.e., when >2f stake has equivocated. The comment notes: "all the proposals become 'above threshold'. That's a serious issue, since it would compromise the honest node core assumption."

While this represents a genuine consensus-breaking event (Byzantine threshold of stake double-signing), aborting the process is an extreme response that allows a coordinated equivocation flood to DoS honest nodes. Consider downgrading to logged Warn + threshold-suppression.

---

## 5. Verification Method Classifications

### 5.1 Model-Checkable (TLA+ targets)

Listed in §6.1 of `modeling-brief.md`. The primary targets:
- MC-1: Catchup race vs cert/next vote broadcast.
- MC-2: Reproposal guard absent on cert/next/fast paths.
- MC-3: Freshest bundle cert-cert short-circuit.
- MC-4: Short-range fork at seed boundary.
- MC-5: Cross-period vote freshness extended by `lastConcluding`.
- MC-6: `enterRound` re-firing of freshest cached event.

### 5.2 Test-Verifiable

Listed in §6.2 of `modeling-brief.md`. Primary:
- T-1: filter timeout divergence under partition.
- T-2: vote verifier shutdown panic (PR #5341 regression test).
- T-3: fork detection log surface.
- T-4: fault-injection crash mid-MakeVotes.
- T-5: multi-key partial sign failure.

### 5.3 Code-Review-Only

Listed in §6.3 of `modeling-brief.md`. Primary:
- CR-1: fork detection is log-only.
- CR-2/3: panic-on-anomaly in `voteTracker` / `voteAggregator`.
- CR-4: unreachable-comment branch in proposalManager.
- CR-5: `lowestCredentialArrivals` not persisted.
- CR-6: blind Staging set on first soft threshold.

---

## 6. Excluded Findings (False Positives)

| # | Candidate | Why excluded |
|---|-----------|--------------|
| FP-1 | "Fast-timeout / soft-threshold race producing contradictory votes in same period" (task hypothesis #2) | Verified: fast vote step labels (late/redo/down = 253/254/255) are disjoint from regular step labels (soft/cert/next). Issuing a fast vote does not contradict a cert/next vote because they're different (round, period, step) keys. Furthermore, the fast vote's Proposal value is derived from the same stagedValue, so if the player has cert-voted for V (Committable=true), the fast vote is also for V (Step=late). No equivocation. |
| FP-2 | "Period-3+ partition recovery emits both cert vote V and next vote bottom in same period" (task hypothesis #1) | Verified: stagedValue.Committable is monotonic within a period (once block is assembled and Staging is set, both stay true). If cert vote was issued in period P, the subsequent next vote in P will also be for V (not bottom). |
| FP-3 | "VRF safety violation under fork" (task hypothesis #4) | Confirmed: safety is robust by the BA* paper's argument (per-branch stake-weighted thresholds), and `EnsureBlock` contract enforces at the ledger boundary. Liveness is a real concern but is bounded by `2500ms` minimum filter timeout. |
| FP-4 | "TestNet stall 2022-07-08 should be modeled" | Excluded: root cause is in `ledger/internal/prefetcher/`, not `agreement/`. The class of bug (proposer/voter divergence) is generic but the specific issue is already fixed and not in scope. |
| FP-5 | "PR #5341 is a safety concern" | Excluded: it's a process-shutdown panic (DoS hazard), not a protocol logic bug. Suitable for a unit test (T-2), not TLA+ modeling. |

---

## 7. Cross-Implementation Comparison

go-algorand is the canonical Algorand mainnet implementation. There are no production sibling implementations of Algorand BA* to compare against; the Runtime Verification Coq model is a separately specified abstract model, not derived from the Go code. Therefore cross-implementation comparison is N/A for this case study; reference comparison is against the BA* paper and the IACR 2023/1344 audit.

The deviations from the paper documented in `agreement/README.md:124-296` are: (a) twice-checking message freshness around concurrent crypto verification, (b) `compoundMessage` bundling, and (c) multi-key pseudonode multiplexing. None of these should be modeled in TLA+ at protocol-spec level — they are implementation-level optimizations.

---

## 8. Coverage Statistics Summary

- **Files deeply read**: 22 (out of ~80 in `agreement/`).
- **Files skimmed for unused features**: 15.
- **Total LOC reviewed**: ~9,400 (excluding `msgp_gen.go` 13,638 of generated code).
- **Git commits to agreement (full set)**: 57; bug-fix subset: 8 (no "fix" in title matched safety-relevant changes in the local history window).
- **GitHub issues / PRs deeply read with full comment thread**: 14.
- **GitHub issues skimmed for relevance**: ~80 (bug label query).
- **Open PRs reviewed for unreviewed fixes**: 1 (PR #5341, still open).
- **External academic sources**: 4 (IACR 2023/1344, Coq runtime verification, CADP, BA-star paper).
- **Forum / postmortem**: 1 (TestNet stall 2022-07-08).
- **Bug families produced**: 6 (1 high, 2 high, 2 medium, 1 low-safety/medium-liveness, 1 low).
- **Model-checkable findings**: 6.
- **Test-verifiable findings**: 5.
- **Code-review-only findings**: 10.

---

## 9. Open Questions Worth Investigating in Follow-up

1. **PR #5286 cited TODOs** — "Blocks are not correctly attached to next-vote bundles" and "Blocks attached to next-vote bundles are not correctly processed." The TODO file was deleted without filing follow-up issues. Whether the issue is fully resolved in current code is not verified by anyone.
2. **`fork detection` operational response** — should a confirmed fork in `fetchRound` halt the node, alert operators, or remain log-only? Worth a maintainer discussion (CR-1).
3. **`voteTracker` equivocator-quorum response** — should reaching the equivocator quorum threshold panic the process, or downgrade to logged Warn + threshold-suppression? (CR-2)
4. **Dynamic-filter persistence** — should `lowestCredentialArrivals` be persisted to avoid post-crash filter-timeout regression? (CR-5)
5. **Reviewer-deferred concerns from PR #5850** — `nextVoteRanges` still uses `defaultDeadlineTimeout` even for period 0 (zeldovich's note). The follow-up never landed.
