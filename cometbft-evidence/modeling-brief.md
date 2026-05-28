# Modeling Brief: CometBFT evidence subsystem (v1.0.1)

## 1. System Overview

- **System**: `cometbft/cometbft` evidence pipeline at tag `v1.0.1` (commit `b1eebae` = `v1.0.1` + one deps bump that does not touch evidence files).
- **Language**: Go. Core LOC: `evidence/pool.go` 575, `evidence/verify.go` 317, `evidence/reactor.go` 253, `types/evidence.go` 645, `state/execution.go` evidence path ~150, `state/validation.go` 170, `light/detector.go` 437, `consensus/state.go` evidence-relevant lines ~50. Total directly in scope ≈ 2300 LOC.
- **System category**: **Category A (Distributed / Message-Passing) — BFT overlay applies.** Justification: this is a slashing accountability subsystem on top of Tendermint-family BFT consensus. Honest validators follow the consensus state machine; the adversary submits forged, stale, or hash-colliding evidence aiming to (a) cause false slashing of honest validators, or (b) escape slashing for real Byzantine behavior. We read both `references/distributed-analysis.md` and `references/bft-analysis.md`.
- **Threat model dimensions**: static corruption (PoS with key retirement is out of scope at this pass — the consensus state machine is treated as a black-box artifact producer); partial-synchronous network; authenticated cryptography (Ed25519 signatures); threshold `n ≥ 3f+1`.
- **Key architectural choices**:
  - Two evidence types in v1.x: `DuplicateVoteEvidence` (DVE) and `LightClientAttackEvidence` (LCAE). `AmnesiaEvidence` was deleted in v0.34 and remains absent.
  - **Consensus buffer** (`pool.go:181`, `461`): equivocating votes detected during consensus are buffered, not added to the pool immediately. They are converted to DVE only after the *next* block is committed, so that the evidence's timestamp matches the header time at the infraction height. This was added by PR #5890 (closed) to avoid timestamp inconsistency.
  - **Self-contained evidence** (PR #5610 closed): LCAE carries its own `ConflictingBlock.ValidatorSet` — verification does not depend on an external historical state lookup for the conflicting chain.
  - **LCAE hash collapses permutations by design** (`types/evidence.go:319-321` TODO): two LCAEs whose conflicting block + common height match — but whose `Commit.Signatures` permutation or `ByzantineValidators` ordering differ — produce the same `Hash()`. The pool deduplicates by hash, so only one canonical LCAE per (conflicting block, common height) reaches the chain. The Hash() construction has a separate one-byte truncation bug — see Family A.
  - **ABCI hand-off**: CometBFT never slashes itself. `block.Evidence.Evidence.ToABCI()` is passed to the app via `BeginBlock`/`PrepareProposal`/`ProcessProposal`/`FinalizeBlock`/`ExtendVote`/`VerifyVoteExtension` — five places in `state/execution.go`. The Cosmos SDK x/slashing module reads `Misbehavior` and slashes validator stake. Bug consequences are real economic loss for honest validators (false-positive slash) or missed slashing for Byzantine ones (false-negative).
- **Concurrency model**: Single-threaded consensus event loop. `Pool.mtx` guards the consensus buffer + `Pool.state`; `evidenceSize` is atomic. Reactor has one gossip goroutine per peer; `Receive` runs verification synchronously per evidence item.
- **Out of scope (Pass 1 / Pass 2 already cover)**: height/round/step state machine, vote extension verification, PBTS, ABCI++ proposer side, state sync, p2p reactor scaffolding, core Tendermint timeouts, Cosmos SDK x/slashing semantics.

---

## 2. Bug Families

### Family A: Evidence Identity & Dedup (LCAE hash, intra-block, hash-vs-content)

**Mechanism**: Evidence identity in CometBFT is collapse-prone by design (LCAE.Hash intentionally ignores signature permutations and `ByzantineValidators` ordering — see `types/evidence.go:319-321` TODO). Layered on top, the pool deduplicates pending/committed evidence by hash, and `CheckEvidence` deduplicates intra-block by hash. Bugs in the hash construction, or asymmetry between the hash dedup key and the actual content under that key, create gaps where (a) different attacks collide into one slot, or (b) the same offense surfaces as two different hashes.

**Evidence**:
- **Code analysis (new)**: `types/evidence.go:322-329` LCAE.Hash() has a one-byte off-by-one. `tmhash.Size = 32` (verified at `crypto/tmhash/hash.go:8-11`). `bz := make([]byte, tmhash.Size+n)` allocates `32+n` bytes; `copy(bz[:tmhash.Size-1], ConflictingBlock.Hash().Bytes())` writes only indices 0..30 (31 bytes of the 32-byte SHA-256); `copy(bz[tmhash.Size:], buf)` writes the varint into indices 32..32+n-1, **leaving `bz[31]` uninitialized (zero)**. The 32nd byte of `ConflictingBlock.Hash()` is silently dropped from the LCAE.Hash input. Collision resistance is reduced from 256-bit to ~248-bit. Cryptographically infeasible to exploit but a real implementation defect.
- **Code analysis (new)**: `pool.go:202` — for LCAE, `CheckEvidence` always re-verifies even when `isPending` is true ("there could be a different conflicting block with the same hash"). The block's content overwrites the pending DB entry under the same hash key via `addPendingEvidence` at `pool.go:213` → `pool.go:310` calls `Set(key, evBytes)` without checking pre-existence, and unconditionally increments `evidenceSize` (`pool.go:314`). The clist is not updated. Result: `evidenceSize` drifts upward (broken invariant), and pool DB diverges from clist view for the colliding entry.
- **Historical (closed)**: PR #4839 — proposer could include duplicate evidence within one block; fixed by intra-block hash dedup at `pool.go:222-228`.
- **Historical (closed)**: PR #6375 ("evidence: fix bug with hashes") — earlier code mutated evidence during verify, making stored hash differ from gossiped hash; fixed.
- **Historical (closed)**: PR #5613 — `ValidatorSet.ProposerPriorityHash` always wrote varint to `buf[0:]` instead of `buf[offset:]`, so only the last validator's priority survived. Fixed by `64857fd7`. *Same family of "buffer offset bug in a hand-rolled hash" as the LCAE.Hash truncation.*
- **Historical (production, UNFIXED)**: Issue #4114 — DuplicateVoteEvidence for the same validator at the same height (one DVE for prevote double-sign, one for precommit double-sign — different vote bytes, different hashes) committed in two consecutive blocks (338278, 338279). Confirmed on v0.38.7, v0.38.12, and v1.0. Causes permanent blocksync failure for fresh nodes ("evidence was already committed"). Maintainers closed `not_planned` 2026-01; jchappelow: "If you cannot or fail to rollback the block, it permanently prevents block sync."

**Affected code paths**:
- `evidence/pool.go:222-228` (intra-block dedup loop, O(n²) by hash)
- `evidence/pool.go:194-220` (LCAE-special case in CheckEvidence)
- `evidence/pool.go:297-316` (addPendingEvidence — non-idempotent counter)
- `evidence/pool.go:330-358` (markEvidenceAsCommitted — writes committed-key by hash)
- `types/evidence.go:322-329` (LCAE.Hash truncation)
- `types/evidence.go:107-109` (DVE.Hash over full proto Bytes — fine)

**Suggested modeling approach**:
- **Variables**: `pendingPool : Server → SUBSET Evidence`, `committedSet : Server → SUBSET EvidenceHash` (not full evidence — just the hash key), `chainEvidence : Height → Seq(Evidence)`. Separate the hash-key abstraction from evidence content explicitly.
- **Actions**:
  - `IncludeEvidence(proposer, height, ev)` — proposer picks evidence from `pendingPool[proposer]`. The hash key is computed from a model `EvidenceHash(ev)` function.
  - `ApplyBlock(node, block)` — for each evidence: if `EvidenceHash(ev) ∈ committedSet[node]`, REJECT; else add to `committedSet[node]` and remove from `pendingPool[node]`.
  - `EvidenceHash` is **not** injective for LCAE: define an equivalence class of LCAE instances that share `(ConflictingBlock, CommonHeight)` and let `EvidenceHash` collapse the class.
- **Granularity**: model proposer and validator pools as separate per-node mappings to capture #4114's lagging-pool scenario.

**Priority**: **High**.
**Rationale**: #4114 is an unfixed production bug with permanent-chain-halt consequence on fresh sync. The hash-collapse design + buffer-offset hash bugs are a recurring family across the codebase (PR #5613, the LCAE Hash truncation). A formal model can explore whether the dedup invariants hold under message reordering and Byzantine submission.

---

### Family B: Receiver-side Validation Gates for Forged Evidence

**Mechanism**: Evidence verification (`evidence/verify.go`) is a chain of predicates over attacker-controllable fields (`VoteA`/`VoteB`, `ConflictingBlock`, `ByzantineValidators`, `Timestamp`, `TotalVotingPower`). The historical bug pattern is gaps between predicates: e.g., one predicate accepts based on Address, another acts based on PubKey.Address(); one verifies enough signatures for 2/3+, another walks the full signature list for slashing. Each gap potentially allows false slashing of innocents.

**Evidence**:
- **Historical (closed, recent)**: PR #5638 (commit `425f8c06`, 2026-02-23) — *PubKey-swap attack*: a Byzantine submitter could supply `ByzantineValidators[i].Address = victim's address` while `ByzantineValidators[i].PubKey = attacker's pubkey`. Since `validateABCIEvidence` only checked Address+VotingPower against the computed-from-trace byzantine set, and the ABCI app slashes by `PubKey.Address()`, slashing was redirected to the victim. Fixed by binding `evByz.Address == evByz.PubKey.Address()` at `verify.go:278-287`.
- **Historical (closed, recent)**: PR #5757 (commit `336b47cf`, 2026-04-08) — `LCAE.ValidateBasic` dereferenced `ConflictingBlock.Header` (promoted field of `SignedHeader`) without a `SignedHeader != nil` guard. Fixed at `types/evidence.go:362-364`.
- **Historical (closed)**: PR #1750/#1806 (commit `43cfd0d2`, 2023-12) — `VerifyCommitLight` / `VerifyCommitLightTrusting` short-circuited once 2/3+ voting power was reached, leaving the remaining signatures unchecked. An attacker could pad the conflicting commit with bogus signatures from honest validators after the verified prefix, slashing them when `GetByzantineValidators` walks the full signature list. Fixed by introducing `VerifyCommitLightAllSignatures` / `VerifyCommitLightTrustingAllSignatures`, now used at `verify.go:124, 136`.
- **Historical (closed)**: PR #3984 / GHSA-g5xx-c4hv-9ccc — `ValidatorSet.Hash()` excludes `ProposerPriority`; light client comparing primary vs witness accepted divergent proposer-priority states. Fixed by `ProposerPriorityHash()` + cross-check in detector; introduced `ErrProposerPrioritiesDiverge`.
- **Historical (closed, recent)**: PR #5820 — light-client detector's `compareNewLightBlockWithWitness` was missing `return` after `errc <- Err...`, so a witness could be classified as both divergent and matching under a race. Fixed.
- **Code analysis (new)**: `verify.go:124` uses `trustedHeader.ChainID` to verify the conflicting commit (`VerifyCommitLightTrustingAllSignatures(trustedHeader.ChainID, ...)`), while DVE verification at `verify.go:55` uses `state.ChainID`. Both should equal the chain's canonical ChainID — and they do, because `validateBlock` (`state/validation.go:39-43`) rejects any block with `block.ChainID != state.ChainID`, so `trustedHeader.ChainID = block.ChainID = state.ChainID`. No-issue, but worth modeling as an invariant.
- **Code analysis (new)**: `verify.go:148-152` (the BFT-time monotonicity check in forward lunatic) is **dead code in the only branch that can reach it**. The actual gate is `verify.go:81` (`trustedHeader.Time.Before(ev.ConflictingBlock.Time)` in the fallback path), which already rejects when `latest.Time < conflicting.Time`. Line 148's predicate `conflicting.Time.After(latest.Time)` is the same negated check. Boundary case `latest.Time == conflicting.Time` at higher conflicting height is *accepted* — which is semantically correct under BFT-time strict-monotonic semantics, but worth documenting in the spec.
- **Code analysis (new)**: `verify.go:32-35` — *exact* equality between `evidence.Time()` and `blockMeta.Header.Time` at evidence.Height. Honest evidence will match (both DVE construction paths in `pool.go:477, 498` use the canonical header time). An attacker-submitted forged DVE/LCAE with `Timestamp` not exactly equal to local chain's header time at that height is rejected. This binds evidence to the canonical chain time, preventing time-warp attacks against expiry.

**Affected code paths**:
- `evidence/verify.go:26-46` (height + time + expiry envelope)
- `evidence/verify.go:111-160` (VerifyLightClientAttack — five distinct verification stages)
- `evidence/verify.go:168-228` (VerifyDuplicateVote — H/R/Type/Addr/BlockID/Pubkey/Sig chain)
- `evidence/verify.go:232-291` (validateABCIEvidence — ByzantineValidators binding)
- `types/evidence.go:250-300` (GetByzantineValidators — lunatic vs equivocation vs amnesia branching)

**Suggested modeling approach**:
- **Variables**: `chainHeader : Height → Header`, `chainCommit : Height → Commit`, `chainValSet : Height → ValidatorSet`, `bondedAt : Height → SUBSET Validator`. Distinguish `Validator` (address + pubkey + power) from `Address` and `PubKey` separately.
- **Actions**:
  - `SubmitForgedEvidence(attacker, ev)` — attacker chooses any well-typed `ev` (DVE or LCAE) with adversary-controlled fields, subject only to "Byzantine identities sign as themselves; honest signatures unforgeable."
  - `VerifyEvidence(node, ev)` — runs the full verify chain (`verify.go:19-98`). Each predicate is an explicit conjunct in the spec.
  - `ApplyMisbehavior(app, misbehavior)` — opaque ABCI receiver that slashes `misbehavior.Validator.Address`. Use a distinct `slashed : Validator → BOOLEAN` ghost variable so we can write the invariant.
- **Granularity**: split LCAE verification into the three attack-type sub-actions (lunatic / equivocation / amnesia) per `ConflictingHeaderIsInvalid` branching at `types/evidence.go:259-300`.

**Priority**: **High**.
**Rationale**: this is where every closed CVE-class bug has landed. The mechanism is bug-prone (five+ closed receiver-side issues), and modeling the conjunction of all gates explicitly lets MC search for "what attacker-supplied combination causes `slashed[honest_validator]` to become true." Per the output-value litmus, we do **not** propose re-deriving any of the specific closed PRs (#5638, #5757, #1806, #5820, #3984) — those are reference context only. The modeling question is whether the *current* conjunction of gates is sufficient against the BFT adversary, not whether any specific historical fix is load-bearing.

---

### Family C: Evidence Lifecycle — Pool / Consensus / Gossip / Crash Recovery

**Mechanism**: Evidence flows through four states: (1) buffered in consensus, (2) pending in pool DB + clist, (3) included in a block, (4) committed in pool DB (height marker only). Transitions cross persistence boundaries and rely on the consensus event loop to fire `Update` exactly once per block. Bugs in this lifecycle either (a) lose evidence permanently or (b) allow the same evidence to surface twice.

**Evidence**:
- **Historical (closed)**: PR #5890 (commit `956b59af`, 2021-01) — *consensus buffer architecture*. Before the fix, DVE detected during consensus was added directly to the pending pool, broadcast, and potentially included in a block at height H before height H finished committing. Honest validators that hadn't yet committed H would panic when validating the proposal because they couldn't load `blockMeta.Header.Time at H` (no block yet). Fixed by buffering DVE until `Update(state)` runs with `state.LastBlockHeight >= voteA.Height`.
- **Historical (closed)**: PR #5574 — committed evidence kept being broadcast by the gossip routine after a peer disconnected and reconnected; receiving committed evidence was treated as a protocol violation and triggered peer-disconnect. Fixed by adding `isCommitted` short-circuit in `Receive` and in the broadcast loop.
- **Historical (closed)**: PR #5610 — evidence ABCI conversion previously required loading historical validator-set state; nodes that state-synced or pruned past the infraction height couldn't form ABCI evidence. Fixed by making each evidence struct self-contained (`ConflictingBlock` carries its own ValidatorSet).
- **Code analysis (new)**: `evidence/pool.go:330-358` (`markEvidenceAsCommitted`) performs two unbatched DB writes per evidence: `removePendingEvidence` (delete pending key, line 334) then `evidenceStore.Set(keyCommitted, ...)` (write committed key, line 349). A crash between these writes — combined with `applyBlock`'s order (`evpool.Update` at `execution.go:353` before `store.Save(state)` at `execution.go:359`) — can leave the evidence with neither pending nor committed marker. On replay through consensus, `Update` re-runs and idempotently re-writes the committed marker (`pool.go:340-351`, since `isPending` is false). However, **`consensus/replay.go:529` uses an `EmptyEvidencePool` stub during certain replay paths** whose `Update` is a no-op; if recovery routes through that path for the affected height, the committed marker is permanently lost. Worth modeling.
- **Code analysis (new)**: pool's expiry predicate uses `AND` (`pool.go:273-274`: `ageNumBlocks > MaxAgeNumBlocks AND ageDuration > MaxAgeDuration`), while reactor's gossip-eligibility check uses only `ageNumBlocks` (`reactor.go:192`). Evidence past the height threshold but not the time threshold sits in the pool as actionable but is gossip-suppressed. A Byzantine proposer holding such evidence can include it in their block and force every honest validator to re-verify it from scratch — the gossip layer never pre-warmed any cache. Liveness/CPU asymmetry, not a safety bug.
- **Code analysis (new)**: `evidence/pool.go:481-500` — stale-height DVE construction requires both `LoadValidators(voteA.Height)` and `LoadBlockMeta(voteA.Height)` to succeed. If either fails, votes are silently dropped via `continue`. For the normal path (voteA.Height = state.LastBlockHeight - 1), the window before pruning is one block. But under aggressive ABCI-driven pruning (`execution.go:367 pruneBlocks`) plus a consensus stall that leaves votes unprocessed for many heights, evidence can be lost without warning.
- **Code analysis (new)**: `pool.go:471-509` — `processConsensusBuffer` has a `default` branch (line 502-509) that logs "shouldn't expect to get votes from consensus of a height that is above the current state" and `continue`s, dropping the votes. Developer comment acknowledges this as a known limitation; could happen if `ReportConflictingVotes` races with `Update` ordering.
- **Code analysis (new)**: `evidence/reactor.go:147-152` — periodic restart-from-front (TODO at line 151). Every 10s, the broadcaster resets `next = nil` and re-iterates the entire clist. Combined with the per-evidence `verify` cost on the receiver (no rate-limiting in `Receive`), this magnifies gossip-induced CPU consumption.

**Affected code paths**:
- `evidence/pool.go:107-133` (`Update` orchestration)
- `evidence/pool.go:330-358` (`markEvidenceAsCommitted` — non-atomic two-step DB writes)
- `evidence/pool.go:461-539` (`processConsensusBuffer`)
- `evidence/pool.go:267-275` vs `evidence/reactor.go:187-206` (expiry-predicate asymmetry)
- `state/execution.go:347-360` (Commit → Update → store.Save ordering)
- `consensus/replay.go:529` (EmptyEvidencePool path during replay/blocksync)

**Suggested modeling approach**:
- **Variables**: `consensusBuffer : Server → Seq(VotePair)`, `pendingPool`, `committedPool`, `clist : Server → Seq(Evidence)`, `persistedState : Server → State`, `inMemoryState : Server → State`. Separate persisted vs in-memory so crash actions can lose only the in-memory parts.
- **Actions**:
  - `ReportConflictingVotes(node, voteA, voteB)` — append to `consensusBuffer[node]`.
  - `BufferFlush(node, newState)` — `processConsensusBuffer` semantics. Includes the timestamp-source switch on `voteA.Height` vs `state.LastBlockHeight`.
  - `MarkCommitted(node, block)` — `markEvidenceAsCommitted`. Splittable into `RemovePending` and `WriteCommitted` to model the crash window.
  - `Crash(node)` — drops `consensusBuffer`, `clist`, and in-memory `state`. Persistent DB (pendingPool, committedPool) retained as durable.
  - `Recover(node)` — `NewPool` semantics: reload pending from DB, rebuild clist, prune expired.
- **Granularity**: a separate `ApplyBlockViaEmptyEvidencePool(node, block)` action models the blocksync path that skips evpool.Update. This is the key to reproducing #4114 in spec.

**Priority**: **High**.
**Rationale**: #4114 is the unfixed production bug; the consensus-buffer/EmptyEvidencePool/dual-DB-write nexus is exactly where it lives. The mechanism is well-defined and Cosmos SDK's slashing is opaque to us (so we treat slashing as a ghost variable and ask whether the same offense can be slashed twice).

---

### Family D: Detection-Completeness Gaps (Best-Effort Slashing)

**Mechanism**: Evidence creation is best-effort at three points: (1) the consensus reactor garbage-collects prevote messages once peers move past the Prevote step, so prevote equivocations can go unreported (#1917, #2353); (2) the light-client detector silently evicts honest witnesses if their `verifySkipping` returns a transient error (`light/detector.go:247-249`); (3) amnesia LCAE evidence carries no `ByzantineValidators` — the chain detects the attack but no validator is slashed (`types/evidence.go:296-299`, validated against `nil` at `verify.go:249-254`). All three are documented design choices, not bugs.

**Evidence**:
- **Historical (open, deprioritized)**: Issue #1917 "TestByzantinePrevoteEquivocation is flaky" — prevote equivocation detection is best-effort. Closed 2024-07-04 without code fix.
- **Historical (open)**: Issue #2353 "Evidence may not work consistently" — duplicate of #1917; deprioritized but not closed.
- **Historical (open)**: Issue #2396 — `MaxAgeDuration` not validated against chain unbonding period; silently invalidates the slashing guarantee for some configurations.
- **Code analysis (new)**: `light/detector.go:232-289` (`handleConflictingHeaders`) — if the first call to `examineConflictingHeaderAgainstTrace` (witness side) fails, the witness is silently removed (line 75 in caller) and the detection cycle proceeds to next witnesses. A Byzantine primary that can transiently interfere with witness's verifySkipping path (e.g., by hijacking the witness's source provider connection) can cause the honest witness to be evicted without generating evidence.
- **Code analysis (new)**: `light/detector.go:41-42` — `providerMutex.Lock()` held across the entire fan-out, including `compareNewLightBlockWithWitness` goroutines that may sleep for `2*maxClockDrift + maxBlockLag` (line 168). All light-client operations are stalled during this window.
- **Code analysis (new)**: `types/evidence.go:296-299` — amnesia returns empty validator list; chain forks are detected but unpunished. Documented in code comment; consistent with ADR-056 open question.

**Affected code paths**:
- `light/detector.go:28-110` (detectDivergence orchestration)
- `light/detector.go:232-289` (handleConflictingHeaders)
- `types/evidence.go:250-299` (GetByzantineValidators including amnesia path)
- `consensus/state.go:2123-2173` (tryAddVote → ReportConflictingVotes — only fires for ErrVoteConflictingVotes, which is itself best-effort)

**Suggested modeling approach**:
- This family is poorly suited for invariant-style TLA+ modeling because the "completeness gap" is a *negative property* (some attacker behaviors are not detected). It would be modeled as **liveness invariants** (e.g., "if a validator equivocates, eventually evidence appears in a block") **with explicit fairness exclusions** for the detection-best-effort points.
- However, this is mostly outside scope for the current pass — the spec for Pass 1 (`case-studies/cometbft`) already models the consensus state machine and is the right home for "detection completeness" questions.

**Priority**: **Low** (for this pass).
**Rationale**: known design choices; modeling negative-detection-properties would expand scope significantly beyond the evidence pipeline.

---

### Family E: Validator-Set / Time-Reference Lookups at Evidence Height

**Mechanism**: Evidence verification looks up the validator set and block metadata at `evidence.Height()`. For DVE, this is `voteA.Height`. For LCAE, this is `CommonHeight`. The lookup is via `stateDB.LoadValidators(height)` and `blockStore.LoadBlockMeta(height)`. Pruning of historical data, or inconsistency between in-memory `state.LastValidators` and persisted-on-disk valsets, would change verifier outcomes.

**Evidence**:
- **Code analysis (new — verification)**: For voteA.Height == state.LastBlockHeight, the DVE-generation path at `pool.go:474-479` uses `state.LastValidators` directly (no DB lookup). The verification path at `verify.go:51` uses `stateDB.LoadValidators(evidence.Height())`. These must be semantically equivalent. Confirmed: after `updateState` in `execution.go:754`, `state.LastValidators = state.Validators.Copy()` (the validators at LastBlockHeight). `stateDB.LoadValidators(H)` returns the validators bonded at H (via `saveValidatorsInfo` at execution.go:539). They are the same set. No-issue.
- **Code analysis (new — verification)**: For voteA.Height < state.LastBlockHeight, the DVE-generation path at `pool.go:483-500` uses `stateDB.LoadValidators(voteA.Height)` and `blockMeta.Header.Time` at voteA.Height. The verification path uses the same DB lookups. Symmetric. No-issue.
- **Code analysis (new — verification)**: ChainID. `verify.go:55` uses `state.ChainID` for DVE; `verify.go:124` uses `trustedHeader.ChainID` for LCAE. `validateBlock` enforces `block.ChainID == state.ChainID` (`state/validation.go:39-43`), so the local chain's headers all carry the same ChainID. No-issue.

**Priority**: **None for modeling.** Listed for completeness; the verification confirmed there is no inconsistency.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Evidence-pool dual-DB state (pending + committed) | Family A, C: enables modeling LCAE hash collisions, intra-block dedup, crash windows | `pendingPool : Server × EvidenceHash → Evidence`, `committedSet : Server × EvidenceHash → Height`. **Hash key is distinct from evidence content** to capture the collapse design. |
| Consensus buffer | Family C: the architectural fix from #5890 is load-bearing; we model the buffer as the staging area between detection and pool | `consensusBuffer : Server → Seq(VotePair)`. Drained by `BufferFlush` action that runs as part of block-commit transition. |
| Crash + recovery + EmptyEvidencePool replay | Family C: this is the channel through which #4114's "same evidence in two blocks" most plausibly arises | `Crash(node)` drops volatile state; `Recover` rebuilds pending from DB; `BlocksyncReplay` applies a block without invoking `evpool.Update` (models the EmptyEvidencePool stub). |
| Receiver-side verifier as a conjunction of explicit predicates | Family B: each historical receiver-side bug closed a different conjunct; the modeling question is whether the current conjunction is sufficient | Express `VerifyDVE(ev)` and `VerifyLCAE(ev)` as explicit conjunctions of: signature validity, valset-membership, address-vs-pubkey binding, time-vs-blockMeta equality, expiry-AND, total-voting-power, ByzantineValidators-derived-from-trace. |
| Byzantine evidence submission as an explicit action | Family A, B: the adversary chooses any well-typed forged evidence | `SubmitForgedEvidence(byzNode, ev)` where `ev` ranges over a typed `Evidence` domain. Authentication axiom: only honest signatures verify if the validator hasn't double-signed; Byzantine identities can sign as themselves. |
| Slashing as a ghost variable | Allows safety invariants over slashing outcomes without modeling x/slashing | `slashed : Validator → BOOLEAN` set by an `ApplyMisbehaviorToApp` action that opaquely flips the bit. Invariant: `slashed[v] ⇒ EquivocatedOrLightClientAttacked(v)`. |

### 3.2 Do Not Model

| What | Why |
|---|---|
| Recreating PR #5638 PubKey-swap | Fixed (commit `425f8c06`); reproducing in spec = `git revert <commit>`; zero information beyond the closed PR. Reference only. |
| Recreating PR #5757 nil SignedHeader | Fixed (commit `336b47cf`); same reasoning. |
| Recreating PR #1806 partial-signature verification | Fixed (commit `43cfd0d2`); same reasoning. |
| Recreating PR #5820 detector missing-return | Fixed; same reasoning. |
| Recreating PR #3984 ProposerPriority cross-check | Fixed; same reasoning. |
| LCAE.Hash off-by-one truncation | Real implementation bug but cryptographically infeasible to exploit (2^124 work for adversarial collision on first 31 bytes). Predicted Phase 4 conclusion is "no externally observable consequence." Per output-value litmus, drop from § 6.1; report in § 6.3 as code-review-only. |
| Cosmos SDK x/slashing semantics | Out of scope per pass instructions. Model the ABCI hand-off as opaque. |
| Consensus state machine (height/round/step) | Pass 1 covers this. Treat as black-box producer of `(SignedHeader, Commit, Vote)` artifacts. |
| Light-client detector internals | Family D's mechanism is best-effort detection; properly modeled as liveness with fairness exclusions, which is beyond this pass's scope. The full-node verifier side of LCAE handling IS in scope. |
| Reactor gossip CPU exhaustion (rate-limiting absent) | DoS / performance concern; not safety. Test-verifiable. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| Per-node evidence pool | `pendingPool[s]`, `committedSet[s]` | Capture pool divergence across nodes (lagging proposer scenario #4114) | A, C |
| Consensus buffer | `consensusBuffer[s] : Seq(VotePair)` | Model the staging area where votes wait for block commit | C |
| Persistent vs volatile state | `persistedPending[s]`, `persistedCommitted[s]`, `volatileClist[s]`, `volatileState[s]` | Model crash windows in `markEvidenceAsCommitted` | C |
| Hash-vs-content separation | `EvidenceHash : Evidence → HashValue` non-injective; `evidenceContent : HashValue → Evidence` capturing the canonical version | Model LCAE's intentional permutation-collapse and the consequences for dedup | A |
| Forged-evidence adversary action | `forgedSpace : SUBSET Evidence` typed but unconstrained beyond crypto axioms | Capture the BFT adversary's submission surface | B |
| ABCI slashing ghost | `slashed : Validator → BOOLEAN` | Enable safety invariants over slashing outcomes | B |
| EmptyEvidencePool replay | `applyBlockBlocksync(s, block)` action that skips evpool.Update | Models the consensus/replay.go EmptyEvidencePool path | C |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `NoFalseSlash` | Safety | `slashed[v] ⇒ Equivocated(v) ∨ LightClientAttacker(v)` — only validators that actually committed a slashable offense get slashed | Family B |
| `EvidenceCommittedOncePerHash` | Safety | For any (node, blockHeight, hash), the committed set is a set: each hash appears at most once. (Captures whether #4114 is reproducible as a function of message reordering.) | Family A, C |
| `IntraBlockNoDuplicates` | Safety | Within a single block's evidence list, no two entries share a hash. (Enforced by `CheckEvidence` pool.go:222-228; invariant to verify against adversary blocks.) | Family A |
| `PendingClistConsistency` | Safety | For every node, the set of evidence hashes in `pendingPool[s]` equals the set of hashes in `volatileClist[s]` (modulo in-flight removal). (Captures the `evidenceSize` drift identified in pool.go:297-316.) | Family A, C |
| `ABCIBindingPubkey` | Safety | For every `Misbehavior` event handed to the app, `misbehavior.Validator.Address == misbehavior.Validator.PubKey.Address()`. (Captures the PR #5638 invariant explicitly rather than re-deriving the bug.) | Family B |
| `EvidenceTimestampMatchesHeader` | Safety | For every committed evidence `ev`, `ev.Time() == chainHeader[ev.Height()].Time`. (Models the verify.go:32-35 binding.) | Family B |
| `EvidenceInExpiryWindow` | Safety | For every committed evidence `ev` at block height H, `NOT IsEvidenceExpired(H, ..., ev.Height(), ev.Time(), ...)`. | Family B |
| `LCAEByzValsBondedAtCommonHeight` | Safety | For every committed LCAE, every entry in `ByzantineValidators` was bonded at `CommonHeight`. (Models the GetByzantineValidators filter at types/evidence.go:265-269.) | Family B |
| `NoSlashWithoutBlockEvidence` | Safety | `slashed[v]` requires that some block in `chainEvidence` contained an evidence entry whose ABCI() form identified v. (Trivial given the model but useful as a sanity check.) | Family B |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| MC1 | **Same offense, multiple evidence entries committed.** A Byzantine validator double-signs at height H, producing one DVE-prevote and one DVE-precommit (different vote bytes → different hashes). Both pass dedup. Multiple proposers at consecutive heights H+k and H+k+1 each include a subset, possibly overlapping. Can both blocks commit successfully and the same offense thus be slashed twice? Also: can the same evidence (same hash) end up in two consecutive blocks via the EmptyEvidencePool/blocksync race in #4114? | `EvidenceCommittedOncePerHash`, possibly `NoFalseSlash` (slashing twice for one validator instance) | A, C |
| MC2 | **LCAE hash collapse + content overwrite.** LCAE A and LCAE B share `(ConflictingBlock, CommonHeight)` but differ in `ByzantineValidators` (e.g., A has 1 byzantine validator, B has 3 — different permutations of who actually signed the conflicting commit). A enters pool first; B arrives via block. CheckEvidence calls `addPendingEvidence(B)` which overwrites A's content under the same hash key. What's the actual ABCI handoff: A's byzantine list or B's? (block.Evidence.ToABCI() uses block's content — should be B's, the version in the block. But the pool's clist still has A; gossip continues with A's content.) | `PendingClistConsistency`, possibly `LCAEByzValsBondedAtCommonHeight` if B is malformed | A |
| MC3 | **Crash window in markEvidenceAsCommitted + EmptyEvidencePool replay.** Node commits block H whose evidence list = [E1, E2]. Crashes after `removePendingEvidence(E1)` (DB delete done) but before `Set(keyCommitted(E1), ...)`. On restart, replay routes through blocksync with EmptyEvidencePool (whose `Update` is no-op). The committed key for E1 is never written. Now block H+1 arrives gossiped (containing E1 again, because a Byzantine proposer included it knowing some nodes might have lost the marker). Verify finds it's not committed; CheckEvidence accepts it. Same evidence appears in two blocks. | `EvidenceCommittedOncePerHash` | C |
| MC4 | **Forged LCAE with inflated ByzantineValidators.** Attacker submits LCAE where `ConflictingBlock.Commit.Signatures` contains valid signatures from 1/3+ commonVals (passing `VerifyCommitLightTrustingAllSignatures`) AND `ByzantineValidators` contains those same validators. But: can attacker introduce an additional entry into `ByzantineValidators` whose Address is in commonVals but whose PubKey is from a different validator? Should fail at validateABCIEvidence's PubKey-vs-Address check (verify.go:282-287), but what if `ByzantineValidators` is permuted such that the order doesn't match what `GetByzantineValidators` produces? The `expected: %d byzantine validators ... got %d` check (verify.go:256) catches length mismatch. The element-wise check (verify.go:260-262) catches address mismatch at the same index. But if the attacker submits a length-matching list in the *wrong order*, the index-wise check fires. Model whether all permutation attacks are caught. | `NoFalseSlash`, `LCAEByzValsBondedAtCommonHeight` | B |
| MC5 | **Forward-lunatic at equal time.** Attacker submits LCAE with `ConflictingBlock.Height > local.LatestHeight` and `ConflictingBlock.Time == local.LatestHeader.Time` (exact equality). verify.go:81 `latest.Time.Before(conflicting.Time)` is false (strict); verify.go:148-152 `conflicting.Time.After(latest.Time)` is also false. Evidence is accepted. Under BFT-time strict monotonicity, accepting this case is *correct* (a block at a later height cannot have an earlier or equal time). But verify whether honest blocks could ever have identical Time fields across heights (e.g., low-clock-resolution scenarios), which would create a false-positive. | `NoFalseSlash` (if honest blocks can equal-time) | B |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T1 | `addPendingEvidence` non-idempotency drifts `evidenceSize` counter. | Integration test: call AddEvidence with same LCAE twice (in different blocks); assert evidenceSize matches actual DB key count. |
| T2 | Reactor gossip CPU exhaustion via maximum-size LCAE batches. | Benchmark: Byzantine peer sends 1MB batches of max-validator-set LCAEs; measure validator CPU consumption per batch. |
| T3 | broadcastEvidenceRoutine periodic restart-from-front amplifies gossip cost. | Long-running test with N evidence × P peers; measure redundant transmission rate over time. |
| T4 | Pool-AND vs reactor-height-only expiry asymmetry. | Integration test: configure MaxAgeNumBlocks low, MaxAgeDuration high. Inject evidence; advance heights past NumBlocks but not Duration. Confirm: evidence remains pool-actionable but gossip-suppressed. |
| T5 | Detector goroutine sleep with providerMutex held stalls light client for `2*maxClockDrift + maxBlockLag`. | Integration test with a witness that triggers the forward-lunatic sleep path; measure latency of unrelated light-client operations. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | `LightClientAttackEvidence.Hash()` (types/evidence.go:322-329) drops byte 31 of the conflicting block hash due to `copy(bz[:tmhash.Size-1], ...)` writing only 31 bytes and `copy(bz[tmhash.Size:], buf)` skipping byte 31. Cryptographically infeasible to exploit but a real defect. The TODO at line 320 acknowledges that the broader hash should be redesigned. | File an upstream PR with the corrected hash construction. Suggested fix: `copy(bz[:tmhash.Size], l.ConflictingBlock.Hash().Bytes())` and increase bz size accordingly, or use `tmhash.SumMany(l.ConflictingBlock.Hash().Bytes(), buf[:n])`. |
| CR2 | `evidence/reactor.go:82` uses `err.(type)` switch to detect `*types.ErrInvalidEvidence`. If a future change wraps the error with `fmt.Errorf` or `errors.Join`, the type switch will silently fall through to the `default` branch and peers will not be punished for invalid evidence. | Replace with `errors.As(err, &target)`. |
| CR3 | `verify.go:148-152` BFT-time check is unreachable code (already filtered at `verify.go:81`). | Either remove or document that line 81 is the live gate and line 148 is documentary defense-in-depth. |
| CR4 | `evidence/pool.go:533` `evidenceList.PushBack(dve)` happens AFTER `addPendingEvidence` (line 528) but ONLY if addPendingEvidence succeeded (the if-continue at line 530). The clist and pending-DB are kept consistent. **No-issue**. (Listed here because at first reading the order looked race-prone.) | No action; verification only. |
| CR5 | `markEvidenceAsCommitted` (pool.go:330-358) performs two unbatched DB writes per evidence (`removePendingEvidence` + `Set(keyCommitted, ...)`). For atomicity, these should be batched via `dbm.NewBatch` + `WriteSync`. | File upstream PR using `dbm.Batch` to make the pending→committed transition atomic. |
| CR6 | `evidence/pool.go:298-316` (`addPendingEvidence`) blindly increments `evidenceSize` without checking pre-existence of the key. For LCAE hash-collision overwrites in `CheckEvidence` (pool.go:213), this over-counts. | Add `Has(key)` check before `AddUint32`. |
| CR7 | `light/detector.go:41-42` holds `providerMutex` across goroutines that sleep `2*maxClockDrift + maxBlockLag` (line 168). Stalls all other light-client operations during the sleep. Acknowledged in NOTE at lines 193-195. | Release the lock during the sleep; re-acquire for cleanup. Or document the bound explicitly. |
| CR8 | `evidence/pool.go:502-509` silently drops conflicting votes whose height is greater than `state.LastBlockHeight`. Developer comment acknowledges the limitation ("perhaps consider keeping the votes in the buffer and retry"). Could matter under specific consensus-stall scenarios. | Investigate whether retry would be beneficial or just delay-batch loss. |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/cometbft-evidence/.specula-output/analysis-report.md`
- **Pass 1 (consensus state machine)**: `/home/ubuntu/Specula/case-studies/cometbft/` — treats consensus as primary; evidence is incidental.
- **Pass 2 (PBTS / ABCI++ / state-sync)**: `/home/ubuntu/Specula/case-studies/cometbft-pbts/` — adjacent timing/state-sync surface.
- **Key source files** (artifact at `/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft`):
  - `evidence/pool.go` (575 LOC) — pool lifecycle
  - `evidence/verify.go` (317 LOC) — verifier (DVE + LCAE)
  - `evidence/reactor.go` (253 LOC) — gossip
  - `types/evidence.go` (645 LOC) — DVE/LCAE structs, hash, ABCI conversion
  - `state/execution.go:108-380` — proposer + validator paths
  - `state/validation.go` (170 LOC) — block-level evidence size cap
  - `light/detector.go` (437 LOC) — light-client LCAE generation
  - `consensus/state.go:60-64, 2123-2173, 1911-1923` — consensus-side hooks
  - `consensus/replay.go:529` — EmptyEvidencePool path
  - `crypto/tmhash/hash.go:8-11` — confirms `Size=32`
- **Closed GitHub issues / PRs (reference, not modeling targets)**:
  - Family A: PR #4839 (intra-block dedup), PR #6375 (hash stability), PR #5613 (ProposerPriorityHash offset)
  - Family B: PR #5638 (PubKey-swap), PR #5757 (nil SignedHeader), PR #1750/#1806 (all-signatures), PR #3984 (ProposerPriority cross-check), PR #5820 (detector missing return)
  - Family C: PR #5890 (consensus buffer), PR #5574 (committed-evidence gossip), PR #5610 (self-contained evidence)
- **Open GitHub issues**:
  - **#4114** ("issues with validator updates and duplicate evidence handling") — *closed not_planned, but real unfixed production bug*. Permanent blocksync failure when same evidence appears in two consecutive blocks. Confirmed on v0.38.7, v0.38.12, v1.0. Direct motivation for Family A + C.
  - #1917 / #2353 — prevote equivocation detection is best-effort. Design-acknowledged completeness gap.
  - #2396 — MaxAgeDuration / MaxAgeNumBlocks alignment with chain unbonding period; configuration validation gap.
  - #537 — Poor evidence UX (no first-class RPC); observability concern, not safety.
- **Reference algorithm**: Tendermint paper, "Equivocation slashing" section. CometBFT evidence module docs: `docs/architecture/adr-047-handling-evidence-from-light-client.md`, `docs/architecture/adr-059-evidence-composition-and-lifecycle.md`, `docs/architecture/adr-056-amnesia-attacks.md`.
