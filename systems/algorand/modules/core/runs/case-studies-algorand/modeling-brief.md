# Modeling Brief: algorand/go-algorand (Algorand BA*)

## 1. System Overview

- **System**: algorand/go-algorand, `agreement/` package — production Byzantine Agreement for the Algorand mainnet at `v4.7.0-stable` (commit `6927d906`, 2026-05-01).
- **Language**: Go, ~9,400 LOC of non-generated agreement core (`agreement/player.go` 767, `proposalStore.go` 398, `proposalManager.go` 310, `proposalTracker.go` 263, `events.go` 1,066, `actions.go` 569, `pseudonode.go` 627, `voteTracker.go` 355, `service.go` 290, plus support files); `catchup/service.go` 907 lines.
- **Protocol**: Algorand BA* (Gilad et al. SOSP'17; Chen-Micali 2017) — VRF-sortition Byzantine consensus with per-step sub-committees weighted by stake. Each round runs in periods (period 0 happy path, period ≥ 3 partition recovery), each period has propose → soft → cert → next steps with fast-recovery variants (late/redo/down). Threshold formation drives all state transitions.
- **System category**: **Category A (Distributed / Message-Passing) + BFT overlay**. Justification: the safety argument depends on stake-weighted thresholds against an adversary that may equivocate and reorder messages; honest validators follow the protocol. Adversary model is adaptive (committees are revealed only when they speak), partial-synchronous post-GST, stake-weighted `2f+1` thresholds. See `references/bft-analysis.md`.
- **Threat model deviations from default BFT**: adaptive (not static) corruption; committees are *replaceable* and revealed by signed messages; thresholds are stake-weighted (`SoftCommitteeThreshold`, `CertCommitteeThreshold`, etc. in `agreement/types.go:122-140`); `Faulty` is effectively a posterior set since a key's committee membership is per-(round, period, step).
- **Concurrency model**: a serialized state-machine `mainLoop` (`service.go:216-273`) handshakes with a concurrent `demuxLoop` (`service.go:192-207`) over unbuffered channels. Crypto verification (`cryptoVerifier`), vote signing (`pseudonode`), and durable state persistence (`asyncPersistenceLoop`) all run on separate goroutines. The pseudonode blocks vote broadcast on `<-t.persistStateDone` (`pseudonode.go:457-469`) so persisted state is durably on disk before the corresponding vote hits the wire.
- **Key implementation choices that deviate from BA-star paper**:
  1. **Concurrent crypto verification** — votes/payloads pass through the state machine twice (filtered pre-verify, then re-checked post-verify) (`agreement/README.md:124-155`).
  2. **`compoundMessage`** bundling — proposal-vote and payload sent together to avoid re-period recovery if reordered (`agreement/README.md:267-296`).
  3. **Pseudonode multi-key multiplexing** — one validator process may carry multiple participation keys, modeled as distinct paper-spec participants behind a single transport (`agreement/README.md:138-148`).
  4. **Dynamic filter timeout** (consensus v39) — period-0 filter timeout for round R is derived from a 40-round sliding history of lowest-credential arrival times (`player.go:317-347`, `dynamicFilterTimeoutParams.go`, `credentialArrivalHistory.go`). The history is NOT persisted across crashes (`persistence.go:246,262`) and is reset on entering any non-zero period (`player.go:419-423`).
  5. **Late credential tracking after freeze** — `proposalSeeker.lowestIncludingLate` (`proposalTracker.go:25-71`) keeps recording lower-credential proposals even after the seeker is frozen, so credential-arrival history is fed by all observed late proposals. The relay-rule change for late credential tracking (`player.go:617-643`) is NOT consensus-gated and ships on pre-v39 chains.
  6. **Period-0 deadline timeout** (consensus v39) — `DeadlineTimeout(p, v)` returns `AgreementDeadlineTimeoutPeriod0` only for period 0 (`types.go:66-72`); period > 0 uses the legacy `BigLambda + SmallLambda ≈ 17s`.
  7. **Independent `FastRecoveryDeadline`** — fast recovery votes (late/redo/down) are driven by a separate timer (`player.go:54-56, 150-168`) and use step labels (253/254/255) disjoint from regular step counters.

---

## 2. Bug Families

### Family 1: Catchup vs Live Agreement Race (HIGH)

**Mechanism**: When the `catchup` service installs the certified block for round R via `ledger.AddBlock` while the `player` is still in round R, period P > 0, the prioritized pseudonode-event queue (votes for period P) drains before the demux observes `ledgerNextRoundCh`. The honest node can broadcast cert / next votes for round R, period P, AFTER round R has been certified externally.

**Evidence**:
- Historical: TestNet stall 2022-07-08 (~5 hours) — root cause was a *ledger validation* divergence between proposer and voter paths (`ledger/internal/prefetcher/prefetcher.go`, fixed in v3.8.1-stable). The fix was outside `agreement/`, but the incident demonstrated that proposer/voter divergence is a real production failure mode. forum.algorand.co/t/7416.
- Code analysis: `catchup/service.go:442-444` (`AddBlock`/`AddValidatedBlock` from `fetchAndWrite`), `demux.go:259, 287-300` (ledgerNextRoundCh → `roundInterruptionEvent`), `demux.go:217-236` (prioritized queue drains before the select), `actions.go:438-446` (pseudonode push order: persist → votes), `pseudonode.go:454-499` (votes blocked on `<-t.persistStateDone`, then pushed to output channel), `voteAggregator.go:232-238` (soft/cert/next votes ALWAYS propagated by `voteStepFresh`).
- Open PR: #5341 "panic when a vote verification task added while shutting down" — same code path: `AsyncVoteVerifier.Quit` racing in-flight vote tasks. Still open / blocked.

**Affected code paths**:
- `pseudonodeAction.do` (`actions.go:387-456`) — emits attest, then enqueues votes to demux prioritized queue.
- `demux.next` (`demux.go:195-365`) — drains prioritized queue first, then falls through to `ledgerNextRoundCh`.
- `player.handleMessageEvent` for `voteVerified` (`player.go:726-745`) — own votes are re-injected as if from the network and re-emit `relayVoteAction`.
- `catchup.fetchRound` (`catchup/service.go:744-841`) including the **fork-detection branch (`service.go:819-840`) which is log-only**.

**Suggested modeling approach**:
- Variables: `ledgerCertified [Round → ProposalValue]`, `playerView [Server → (Round, Period)]`, `inFlight [Server → SUBSET Vote]` (votes signed but not yet broadcast).
- Actions: Split `IssueVote` into two: `SignVote` (creates an in-flight vote, persists state) and `BroadcastVote` (drains in-flight onto the wire). Insert a separate `CatchupInstall(R, V)` action that advances `ledgerCertified[R]` independently of player state. Add `ObserveLedgerAdvance` action that consumes in-flight votes from `inFlight` ONLY when invoked after `BroadcastVote`.
- Granularity: model the catchup install and the player's round advance as separate transitions; do NOT fold them into one atomic step.

**Priority**: High
**Rationale**: Direct racy interaction between two co-resident services, plausibly reachable under partition healing. Not previously formally verified. TLA+ is well-suited to explore the partial-order of `Catchup!AddBlock`, `Pseudonode!Sign`, `Player!EnterRound`, and `Network!Deliver`. If the model finds a counterexample, it produces a concrete schedule; if not, the model is the first formal evidence that this race is benign.

---

### Family 2: Period 0 → P > 0 Carryover & Reproposal Guard (HIGH)

**Mechanism**: The "reproposer can't change value" invariant is enforced only on the soft-vote path (`player.go:196-202`, the `OriginalPeriod` check). The cert-vote (`player.go:209-212`), next-vote (`player.go:214-242`), and fast-vote (`player.go:244-274`) paths do not re-apply the check — they trust the upstream `Staging` set by softThreshold and the `nextStatus` cache from the previous-period voteTrackerPeriod. When the player fast-forwards into period P via a `softThreshold` or `nextThreshold` event without locally observing the prior `softThreshold` (because `nextThresholdStatusEvent.Cached` was populated by message reordering), the cache for `p.Period-1` queried at `player.go:182,223,260` can be stale (`voteAuxiliary.go:71-77` caches Bottom / Proposal separately and never invalidates).

**Evidence**:
- Code analysis: `voteAuxiliary.go:71-78` (Bottom/Proposal accumulated independently — the cache can report `Bottom = false, Proposal = bottom` if a node fast-forwarded via a softThreshold without ever seeing a real next threshold from period-1).
- Code analysis: `player.go:182-202` (soft-vote reproposer guard requires nextStatus.Proposal != bottom AND match a.Proposal; absent for cert/next/fast paths).
- Code analysis: `proposalTracker.go:203-211` (`Staging = e.Proposal` set blindly by softThreshold/certThreshold; not validated against OriginalPeriod).
- Historical: PR #5286 "Process 'agreement' TODO" — explicit unfixed TODOs: *"Blocks are not correctly attached to next-vote bundles"* and *"Blocks attached to next-vote bundles are not correctly processed"* (per maintainer comment, the TODO file was deleted without filing follow-up issues).

**Affected code paths**:
- `player.issueSoftVote` (`player.go:170-206`) — applies guard.
- `player.issueCertVote` (`player.go:209-212`) — no guard.
- `player.issueNextVote` (`player.go:214-242`) — no guard.
- `player.issueFastVote` (`player.go:244-274`) — no guard, additionally writes Step=late/redo/down.
- `voteTrackerPeriod.handle` for `nextThreshold` (`voteAuxiliary.go:71-77`) — populates the cache used in queries.
- `proposalTracker.handle` for `softThreshold`/`certThreshold` (`proposalTracker.go:203-211`) — sets Staging.

**Suggested modeling approach**:
- Variables: `nextThresholdCache [Server → (Round, Period) → (Bottom, Proposal)]`; `staging [Server → (Round, Period) → ProposalValue]`; `lastConcluding [Server → Step]`.
- Actions: model `EnterPeriodViaSoftThreshold`, `EnterPeriodViaNextThreshold`, and the carryover separately. After `EnterPeriod`, mark `nextThresholdCache[server][r, p-1]` as potentially-stale to expose the absence of a local fresh signal.
- Granularity: do NOT collapse cert-vote and next-vote into a single "vote" action — different guard surfaces.

**Priority**: High
**Rationale**: This is the most subtle "code paths that should be identical aren't" pattern in `agreement/`. The protocol's safety argument (cert ⇒ starting value carries forward) is supposed to compensate for the guard asymmetry, but no in-tree property check validates this. Suitable for TLA+ because the question is about which combinations of `(staged, nextStatus.Bottom, nextStatus.Proposal, OriginalPeriod)` can co-exist after legal message orderings — a finite combinatorial question.

---

### Family 3: Dynamic Filter Timeout — Cross-Round Divergence (MEDIUM)

**Mechanism**: The dynamic filter timeout for round R, period 0 is computed from a per-node 40-sample circular history of past lowest-credential arrival times (`lowestCredentialArrivals`, `player.go:64`, `credentialArrivalHistory.go:25-83`). Two honest nodes that observed different sets of late-arriving credentials over the last 40 rounds (e.g., due to a brief partition that healed mid-collection) will have different filter timeouts. The history is reset on entering any non-zero period (`player.go:419-423`) and is NOT persisted across crashes (`persistence.go:246, 262`). The relay rule change introduced for credential tracking is NOT gated by the v39 protocol flag (`player.go:626-642`) and ships even on chains where dynamic-filter is disabled.

**Evidence**:
- Historical: PR #5701 (2023-10-13) — "continue tracking the best proposal even after freezing." The original v5654 implementation read `validatedAt` from the current round just after `ensureAction`, missing late-arriving better credentials. Fix added the `lowestIncludingLate` shadow slot and pushed history reads `credentialRoundLag` rounds behind (`player.go:299-314`).
- Historical: PR #5853 (2023-12-07) — raised dynamic filter timeout lower bound from 500ms → 2500ms after mainnet telemetry showed cross-cloud p95 arrival ≈ 337ms but Africa-side validators systematically lagging. Same PR pinned `minCredentialRoundLag = 8` because the dynamic relationship `credentialRoundLag = 2·SmallLambda/lowerBound` would otherwise drop to 2 at the new bound, breaking GC assumptions (`router.go:55-71`).
- Historical: PR #5850 (2023-12-07) — added period-0 deadline timeout `AgreementDeadlineTimeoutPeriod0`. Reviewer warnings deferred to follow-up: (jannotti) "the times for all the steps after 1 will not use the short timeout from period 0, step 1"; (zeldovich) "nextVoteRanges uses defaultDeadlineTimeout, so the player will sleep for longer than needed".
- Code analysis: `player.calculateFilterTimeout` (`player.go:317-347`) selects sample 37 of 40 and clamps to `[2500ms, defaultTimeout]`. Two nodes observing different period-0 histories arrive at different clamped timeouts in `[2500ms, defaultTimeout]`.

**Affected code paths**:
- `player.calculateFilterTimeout` (`player.go:317-347`).
- `player.updateCredentialArrivalHistory` (`player.go:287-315`).
- `proposalManager.filterProposalVote` (`proposalManager.go:251-290`) — gates late-credential relay.
- `proposalSeeker.accept` (`proposalTracker.go:50-71`) — tracks lowestIncludingLate.
- `router.update` (`router.go:144-170`) — GC retains rounds for `credentialRoundLag`.

**Suggested modeling approach**:
- Variables: `filterTimeout [Server → Round → TimeoutBucket]` where TimeoutBucket is a finite abstraction (e.g., {Short, Default}). Per-server divergence.
- Actions: `RecordCredentialArrival(server, round, time)`. Period-0 entry into round R with `filterTimeout = max(2500ms, computed(history))`.
- Liveness: check that *eventually* nodes' filter timeouts converge after the network stabilizes — i.e., no "permanently divergent timeout" state.
- Safety: not directly a safety target, but the cross-node timeout asymmetry can produce period 0 deadline races that worsen reproposal probability.

**Priority**: Medium
**Rationale**: Two confirmed historical bugs (#5701, #5853), and several reviewer-flagged but deferred concerns. Not safety-critical (clamped to a safe range, partition heals eventually), but a real liveness-degradation surface. Modeling value is medium — the dynamic-timeout logic itself is a per-node computation, so a TLA+ model would mostly check that diverged timeouts don't cause permanent inability to commit period 0.

---

### Family 4: Freshest Bundle / `fresherThan` Partial Order Edge Cases (MEDIUM)

**Mechanism**: The freshest bundle cache (`voteTrackerRound.Freshest`, `voteAuxiliary.go:103-157`) is updated only when a new threshold event satisfies `fresherThan`. The relation has two corner-case behaviors that diverge from a strict partial order:
1. `none.fresherThan(none) == true` (`events.go:746-748`) — reflexive on the unset cache (benign, but unusual).
2. `certThreshold.fresherThan(certThreshold) == false` (events.go:777 short-circuits) — once a cert is cached, ANY future event including a cert from a later period cannot replace it. Combined with `partitionPolicy` rebroadcasting the cached cert (`player.go:517-525`), this can produce an honest node that perpetually rebroadcasts a stale cert bundle when an updated cert exists.

Together with the `proposalStore.softThreshold/certThreshold` handler (`proposalStore.go:323-346`) which sets `Staging = e.Proposal` blindly without freshness comparison, this creates a state in which `Staging` and `Freshest` can refer to inconsistent values across periods within the same round.

**Evidence**:
- Code analysis: `events.go:744-801` (`fresherThan` definition).
- Code analysis: `voteAuxiliary.go:144-150` (Freshest cache replacement).
- Code analysis: `player.partitionPolicy` (`player.go:512-568`) — rebroadcasts `bundleResponse.Event.Bundle` regardless of age beyond what `fresherThan` permits.
- Code analysis: `proposalStore.go:323-346` (Staging set unconditionally).

**Affected code paths**:
- `voteTrackerRound.handle` (`voteAuxiliary.go:132-157`).
- `player.handleThresholdEvent` (`player.go:349-403`).
- `player.partitionPolicy` (`player.go:512-568`).
- `proposalStore.handle` softThreshold/certThreshold (`proposalStore.go:323-346`).
- `proposalManager.handle` (`proposalManager.go:57-77`).

**Suggested modeling approach**:
- Variables: `freshestBundle [Server → Round → ThresholdEvent]`, `staging [Server → (Round, Period) → ProposalValue]`.
- Actions: Model `UpdateFreshest` as a single transition using the actual partial-order predicate (reproduce the cert-cert short-circuit faithfully). Check that across periods, the relationship `freshestBundle.Period == staging.Period` holds, or the model surfaces a counterexample where they desynchronize.

**Priority**: Medium
**Rationale**: The cert-cert short-circuit is unlikely to be exploitable (only one cert can form per period in a non-Byzantine schedule, and a cert ends the round), but the freshest-cache + Staging-set interaction is sensitive to Byzantine and partition-recovery message orderings. Worth modeling because the partial-order is not assert-checked anywhere in code.

---

### Family 5: VRF Seed Lookback Forks (LOW for safety, MEDIUM for liveness)

**Mechanism**: Sortition for round R uses the seed from round `R - SeedLookback` (`SeedLookback = 2` in v8+, `agreement/selector.go:63-65`; balance lookup uses `BalanceRound(R) = R - 320` via `MaxBalLookback`). A fork at `R - 2` produces different `Seed` values on the two branches, so the same validator computes different sortition outcomes per branch. The local ledger's `Seed(R-2)` returns whichever block is locally committed at `R-2`. Additionally, at the `SeedRefreshInterval` boundary (every 80 rounds in v8), the seed inherits entropy from `LookupDigest(R - SeedLookback*SeedRefreshInterval)`, which goes much deeper into history.

**Evidence**:
- Code analysis: `agreement/proposal.go:155-196` (`deriveNewSeed`).
- Code analysis: `agreement/proposal.go:201-272` (`verifyProposer`).
- Code analysis: `agreement/selector.go` and `agreement/params.go` (lookback constants).
- Code analysis: `data/committee/credential.go:107-124` (VRF→weight sortition).
- Code analysis: `agreement/abstractions.go:170-173` — Ledger only retains digests "from the most recent multiple of `config.Protocol.BalLookback/2`"; non-refresh-boundary rounds rely on this guarantee.
- Reference: Benhamouda et al. IACR 2023/1344 (CCS'23) — proves safety in any "secure" execution; does not prove liveness against adversarial seed-influencing strategies at the lookback boundary.

**Affected code paths**:
- `proposal.deriveNewSeed`, `proposal.verifyProposer`.
- `data/committee/credential.Verify`, `lowestOutput`.
- `ledger.Seed`, `ledger.LookupDigest` (abstract behind interfaces).

**Suggested modeling approach**:
- Variables: abstract `committee [Round × Period × Step → SUBSET Server]` non-deterministically chosen at the start of each (R, P, S). Do NOT model the VRF function itself.
- For forks: model `ledgerView [Server → Round → ProposalValue]` and allow different views per server. At the seed boundary, allow the abstract `committee` for round R to be different across servers if their `ledgerView[R - SeedLookback]` differs.
- Safety check: even with divergent committees, `EnsureBlock` invariant holds (no two distinct blocks for the same round, `abstractions.go:197-212`).

**Priority**: Low for safety, Medium for liveness
**Rationale**: Safety is robust to seed forks by the protocol's standard argument (per-branch stake-weighted thresholds). Liveness is potentially fragile because a single round's proposer has one bit of grinding power at the seed boundary, and a fork-causing adversary can perturb the round-R committee composition. Modeling target: NOT primary; secondary if Family 1 or 2 needs a richer adversary model.

---

### Family 6: Crash Recovery State Coverage (LOW)

**Mechanism**: The `lowestCredentialArrivals` history (40 entries, ~5KB) is NOT persisted (`persistence.go:246, 262`) and the `historicalClocks` map is also not persisted. After a crash, the node reverts to the default filter timeout until 40 fresh samples accumulate. Vote-signing and broadcast are correctly gated on disk persistence (`pseudonode.go:457-469`), so safety is preserved.

**Evidence**:
- Code analysis: `persistence.go:74-78, 144-294` (what is encoded/decoded).
- Code analysis: `actions.go:438-446`, `pseudonode.go:454-499` (persist-before-send ordering).
- Historical: PR #6349 (2025-05-29) "fix mainLoop vs Shutdown race" — `sync.WaitGroup` fix for two-goroutine teardown.
- Historical: PR #5341 (OPEN) "panic when a vote verification task added while shutting down" — `AsyncVoteVerifier.Quit` race; the closed-channel write is on `avv.execpoolOut` (`asyncVoteVerifier.go:179-188`).

**Affected code paths**:
- `restore`, `decode`, `encode`, `persist` in `agreement/persistence.go`.
- `pseudonodeVotesTask.execute` (`pseudonode.go:379-500`).
- `Service.persistState` (`service.go:281-284`).

**Suggested modeling approach**:
- Variables: `persistedPlayer [Server → Player]`, `volatilePlayer [Server → Player]`. Crash action resets `volatilePlayer = persistedPlayer`.
- Optional: model the dynamic filter timeout's post-crash reset as a liveness-degradation event.

**Priority**: Low
**Rationale**: Persistence ordering is correct and safety is preserved; the open shutdown-race PR is a panic concern (DoS), not equivocation. Worth a passing mention in the spec but not a primary modeling target.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Catchup vs Live Agreement race | Family 1: confirmed race window; previously unmodeled | Split `IssueVote` into `Sign` + `Broadcast`; add `CatchupInstall(R, V)` action that races `BroadcastVote(R, P, V')` |
| Reproposal guard asymmetry | Family 2: present only on soft-vote path; cert/next/fast paths trust upstream Staging | Distinct actions `IssueSoftVote`, `IssueCertVote`, `IssueNextVote`, `IssueFastVote` each with their own guard structure |
| nextThresholdStatus cache divergence | Family 2: cache populated independently by Bottom/Proposal, queried after fast-forward | Variable `nextThresholdCache [Server × (R,P) → (Bottom: BOOLEAN, Proposal: Value)]` |
| Freshest bundle cert-cert short-circuit | Family 4: once cert cached, never replaced | Faithfully encode `fresherThan` predicate including the short-circuit; check Staging-vs-Freshest co-consistency |
| Partition recovery (period ≥ 3, Step ≥ partitionStep) | Family 2 + 4: `partitionPolicy` rebroadcasts may carry stale bundles | Model `partitioned()` flag and `partitionPolicy` as a separate action that emits broadcast bundles |
| Fast recovery votes (late/redo/down) | Family 2: separate step labels, independent timer; subagent confirmed no equivocation within a single key but cross-key needs check | Optional add-on after main families |
| Adaptive committee assignment | BFT overlay: per-(R,P,S) committee is a non-deterministic subset weighted by stake | Abstract VRF as an oracle that returns committee membership; do NOT model VRF crypto |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| VRF cryptographic primitives | Abstract as committee oracle; modeling VRF mechanics adds state space without exposing protocol bugs |
| `cryptoVerifier` cancellation lifecycle | Implementation correctness; not protocol-level. Crypto context cleanup at `cryptoRequestContext.go:108-145` is a robustness mechanism for resource management |
| Dynamic filter timeout numeric value | Family 3: degrade-to-default fallback already exists; modeling exact ms values won't expose new bugs |
| Pseudonode multi-key fan-out | `agreement/README.md:138-148` documents these are "modeled as distinct participants" — your spec already treats them as separate servers |
| TestNet stall 2022-07-08 prefetcher bug | Outside `agreement/` scope; fix is one-line cache disable; no value in re-deriving |
| Shutdown / race panic in `AsyncVoteVerifier` (PR #5341) | Process-lifecycle race, not protocol logic |
| AVM / TEAL, tx pool, ledger merkle / state-proof, networking transport | Out-of-scope per task instructions |
| Catchpoint / fast catchup | Catchup-via-block-cert is enough; catchpoint adds significant state |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Split Sign / Broadcast vote actions | `inFlightVotes [Server → SUBSET (R,P,S,V)]` | Expose the window between persist-flush and network broadcast | 1 |
| External ledger advance | `ledgerCertified [Round → ProposalValue]` | Model catchup installing a cert independently of player state | 1 |
| Per-server next-threshold cache | `nextThresholdCache [Server × (R,P) → (Bottom, Proposal)]` | Reproduce the soft-vote / cert-vote guard asymmetry | 2 |
| Per-server Staging | `staging [Server × (R,P) → ProposalValue]` | Track proposalTracker.Staging set by softThreshold/certThreshold | 2, 4 |
| Per-server Freshest bundle | `freshest [Server × Round → ThresholdEvent]` | Reproduce `fresherThan` partial order including cert-cert short-circuit | 4 |
| Per-server lastConcluding | `lastConcluding [Server → Step]` | Snapshot of player.Step at the moment of enterPeriod | 4 |
| Partition flag | `partitioned [Server → BOOLEAN]` computed from `(Step, Period)` | Trigger partitionPolicy rebroadcast | 2, 4 |
| Persisted vs volatile player | `persistedPlayer [Server]`, `volatilePlayer [Server]` | Model crash recovery and the "filter timeout reset" liveness regression | 3, 6 |
| Committee oracle | `committee [(R,P,S) → SUBSET Server]` (constant per (R,P,S), stake-weighted) | Stake-weighted threshold formation without modeling VRF | (all) |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| AgreementSafety | Safety | At most one block can be certified (cert threshold reached) per round, across all periods | Standard BA*; Families 1, 2, 4 |
| LedgerConsistency | Safety | If `EnsureBlock(R, B1)` and `EnsureBlock(R, B2)` then `B1 = B2` | Family 1 (abstractions.go:197-212 contract) |
| StagingMatchesFreshest | Safety | For any server S in round R period P with `freshest.Period == P`, `staging[S][R,P] == freshest.Proposal` (or `staging = bottom`) | Family 4 |
| ReproposalGuardEnforced | Safety | If server S issues `softVote(R, P, V)` and `OriginalPeriod(V) < P`, then S has seen `nextThreshold(R, P-1, V)` | Family 2 (already in code at `player.go:196-202`); check it holds emerging from cert/next paths too |
| CertImpliesStartingValue | Safety | If `certThreshold(R, P, V)` formed, then for all P' > P, any soft threshold in (R, P') is for V | Standard BA* paper safety argument; Family 1, 2 |
| NoCrossRoundEquivocation | Safety | If server S broadcasts vote v1 in (R, P, S) and the local player has advanced to round R+1, S does not broadcast vote v2 in (R, P, S) with v1.Value ≠ v2.Value | Family 1, 6 |
| PersistedBeforeBroadcast | Safety | If `attest(R, P, S, V)` action is observable on the wire from server S, then S has persisted `player.Round = R, player.Period = P, player.Step = S` to durable storage | Family 6 (pseudonode.go:457-469 contract) |
| EventuallyConverge | Liveness | After GST and stake majority is honest, all honest servers eventually reach the same round | Standard BA*; Family 3 (timeout divergence shouldn't permanently stall) |
| FilterTimeoutWithinBounds | Safety/Liveness | Every server's filter timeout for round R, period 0 lies in `[2500ms, defaultTimeout]` | Family 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Catchup race: after `Catchup!Install(R, V_c)` and before `Player!EnterRound(R+1)` on server S, S broadcasts `attest(R, P, cert, V_l)` for V_l ≠ V_c. Can a `CertCommitteeThreshold` form for V_l in (R, P)? | AgreementSafety | 1 |
| MC-2 | Fast-forward via `softThreshold(R, P)` with `voteTrackerPeriod.Cached.Bottom = false, Cached.Proposal = bottom` because nodes never observed a local period P-1 next threshold. Subsequent `issueSoftVote` in period P uses the cache and may soft-vote without the reproposer constraint. | ReproposalGuardEnforced | 2 |
| MC-3 | `certThreshold(R, P_1)` cached as Freshest. A later `certThreshold(R, P_2)` for a *different* value arrives at the same server. Cache is NOT replaced (cert-cert short-circuit). `partitionPolicy` rebroadcasts the stale P_1 cert. Does any receiver act on the stale cert in a safety-violating way? | AgreementSafety, StagingMatchesFreshest | 4 |
| MC-4 | Two honest servers' committees for (R, P, S) computed against different `ledgerView[R-2]` snapshots (short-range fork). Can BOTH branches independently produce cert thresholds for different values? | LedgerConsistency | 5 |
| MC-5 | After `EnterPeriod(P+1)`: `lastConcluding = previous p.Step`. If `Step >= partitionStep` at the time, the previous-period vote freshness window is greatly expanded by `voteStepFresh` (voteAggregator.go:241-246). Can adversarial votes from period P be accepted as fresh in period P+1 in a way that creates an unintended quorum? | NoCrossRoundEquivocation | 2, 4 |
| MC-6 | During `enterRound(R+1)` (from `certThreshold(R, p)`), the freshest cached event is replayed via `freshestBundleRequestEvent` (player.go:495-500). If a `nextThreshold(R, P')` was cached as freshest before cert, the replay may trigger `enterPeriod` in the freshly zeroed round. Verify that `p.Period > e.Period` guard at player.go:396-398 suppresses this. | EventuallyConverge | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| T-1 | Filter timeout cross-node divergence under brief partition healing mid-round-window (Family 3) | Integration test: orchestrate 4-node network, partition 2 nodes for 30 rounds, heal. Compare each node's `lowestCredentialArrivals` after recovery. |
| T-2 | `AsyncVoteVerifier.Quit` race with in-flight `verifyVote` (PR #5341, still open) | Unit test: stress-test concurrent `Quit()` while submitting `verifyVote` tasks; assert no panic on `execpoolOut` send to closed channel |
| T-3 | `fetchRound` fork detection branch never fires under correct catchup behavior (catchup/service.go:819-840) | Adversarial peer test: have a peer return a fake-but-validly-signed cert for a different block; assert that `fork detection` log fires (and that the node does NOT halt) |
| T-4 | Persist-before-broadcast ordering on simulated crash mid-MakeVotes (Family 6) | Fault-injection test: kill the process between `MakeVotes` and `t.out` send; on restart verify no votes on wire and persisted state has the same (round, period, step) |
| T-5 | Multi-key key pseudonode atomicity — if K1 succeeds and K2's crypto fails, only K1's vote ships; on restart both K1 and K2 re-attempt | Integration test: simulate one key's signing failure |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-1 | `fetchRound` fork detection (catchup/service.go:819-840) is log-only — no halt, no operator alert, no quarantine. A real fork would silently keep retrying. | Discuss with maintainers: should fork detection escalate to operator alert + circuit-breaker? |
| CR-2 | `voteTracker.go:189` `Panicf("too many equivocators for step %d: %d", ...)` — a coordinated equivocation flood can DoS an honest node via process abort. | Consider downgrading to logged Warn + thresholdEvent-suppression rather than panic |
| CR-3 | `voteAggregator.go:128` `Panicf("bad round ...")` reachable if voteTracker emits threshold for old round during late-vote processing. `voteFresh` should prevent it, but no defense in depth. | Discuss: should this be `Warn + drop` instead of `Panic`? |
| CR-4 | `proposalManager.go:163-186` keep-for-late-credential-tracking path mutates filteredEvent.LateCredentialTrackingNote after-dispatch; logic at line 181-186 has an unreachable-comment-but-still-runs branch ("It should be impossible to hit this condition"). Either prove unreachable or remove the comment. | Cleanup |
| CR-5 | `lowestCredentialArrivals` not persisted across crashes (`persistence.go:246, 262`); post-crash filter timeout regresses to default. | Document as known degradation, or add to persistence schema |
| CR-6 | `proposalStore.softThreshold/certThreshold` (`proposalStore.go:323-346`) sets `Staging = e.Proposal` without checking freshness against any other received soft threshold. proposalTracker.go:172 has the `t.Staging != bottom` guard that prevents *re-setting*, but the first soft threshold seen is accepted unconditionally. | Verify this is safe given upstream guarantees, otherwise add a check |
| CR-7 | `events.go:746-748`: `none.fresherThan(none) == true`. Reflexivity on `none` is intentional for the empty-cache replacement path but inconsistent with the documented "partial ordering" comment. | Document as intentional or rename |
| CR-8 | `agreement/abstractions.go:49` "TODO There should probably be a second Round argument here" on `BlockValidator.Validate`. | Cleanup |
| CR-9 | `agreement/proposal.go:245` "TODO remove the following Hash() call, redundant with the Verify() call above" — minor inefficiency, no correctness impact. | Cleanup |
| CR-10 | PR #5286 cited TODO: "Blocks are not correctly attached to next-vote bundles" and "Blocks attached to next-vote bundles are not correctly processed" — TODO file deleted; maintainer (bbroder-algo) admitted not understanding the items well enough to file follow-up issues. | Re-investigate with current code; either prove they're stale or file fresh issues |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/algorand/.specula-output/analysis-report.md`
- **Key source files**:
  - `agreement/player.go` (767 LOC) — central state machine, all vote-issuance paths
  - `agreement/proposalStore.go` (398 LOC) — proposal payload storage per round
  - `agreement/proposalTracker.go` (263 LOC) — frozen/staging value per period; `lowestIncludingLate`
  - `agreement/proposalManager.go` (310 LOC) — proposal acceptance / freshness rules
  - `agreement/voteAuxiliary.go` (157 LOC) — `voteTrackerPeriod` cache, `voteTrackerRound` freshest bundle
  - `agreement/voteAggregator.go` (296 LOC) — top-level vote dispatcher; `voteFresh`, `voteStepFresh`
  - `agreement/voteTracker.go` (355 LOC) — per-step vote counting and threshold formation
  - `agreement/events.go` (1066 LOC) — threshold events, `fresherThan` partial order at lines 732-801
  - `agreement/demux.go` (417 LOC) — `next()` with prioritized queue and ledger-bulletin handling
  - `agreement/actions.go` (569 LOC) — pseudonodeAction lifecycle, persist-then-vote ordering
  - `agreement/persistence.go` (388 LOC) — `encode/decode/restore`, `asyncPersistenceLoop`
  - `agreement/pseudonode.go` (627 LOC) — vote signing and `persistStateDone` gating
  - `agreement/service.go` (290 LOC) — mainLoop / demuxLoop coordination
  - `agreement/types.go` (183 LOC) — step constants, deadline timeouts, threshold queries
  - `agreement/abstractions.go` (335 LOC) — interfaces; `EnsureBlock` contract at lines 197-212
  - `agreement/credentialArrivalHistory.go` — dynamic filter timeout state
  - `agreement/dynamicFilterTimeoutParams.go` — dynamic filter constants
  - `catchup/service.go` (907 LOC) — fetch loop, `fetchRound` with fork detection at lines 819-840
  - `data/committee/credential.go` (225 LOC) — VRF verify, sortition, `lowestOutput`
- **GitHub issues / PRs**:
  - #5341 (OPEN) — `AsyncVoteVerifier` shutdown panic
  - #6349 (MERGED 2025-05-29) — `mainLoop` vs `Shutdown` race
  - #5286 (CLOSED) — agreement TODOs
  - #5654 (MERGED 2023-08-31) — dynamic lambda
  - #5701 (MERGED 2023-10-13) — continue tracking after freezing
  - #5850 (MERGED 2023-12-07) — period 0 deadline timeout
  - #5853 (MERGED 2023-12-07) — minimum dynamic filter timeout 2500ms
  - #5868 (MERGED 2023-12-14) — consensus v39 upgrade
  - #4870 (OPEN) — Speculative Block Assembly epic
  - #4711 (OPEN) — agreement persistence msgp tech debt
- **Reference spec / paper / audit**:
  - Chen, Micali, "Algorand" (2017)
  - Gilad et al., "Algorand: Scaling Byzantine Agreements for Cryptocurrencies", SOSP'17
  - Algorand spec repository: github.com/algorandfoundation/specs
  - Benhamouda, Halevi, Krawczyk, Lin, Rabin, "Analyzing the Real-World Security of the Algorand Blockchain", CCS'23 / IACR 2023/1344
  - TestNet stall post-mortem: forum.algorand.co/t/7416
  - Runtime Verification Coq async-safety proof: github.com/runtimeverification/algorand-verification
