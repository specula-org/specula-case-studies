# Analysis Report: CometBFT Evidence Subsystem (v1.0.1)

This is the audit trail for `modeling-brief.md`. Phase-by-phase, it records what was read, what was found, what was excluded, and why.

## Coverage Statistics

- **Git commits analyzed**: 76 commits touching `evidence/pool.go`, `evidence/verify.go`, `evidence/reactor.go` (all-branches). After `git fetch --unshallow`, full history of 13361 commits in the repo was available. 335 commits touched `evidence/`, `types/evidence.go`, `light/detector.go` combined.
- **Bug-fix commits read in detail**: 14 (PRs #4839, #5574, #5610, #5613, #5638, #5757, #5820, #5890, #6375, #1408, #1750, #1806, #3984, #5638).
- **GitHub issues collected**: 22 (via 3 search queries on "evidence", "LightClientAttackEvidence|LCAE|detector", "slashing|misbehavior|ByzantineValidators", "duplicate vote|equivocation").
- **Issues deeply read (full comment threads via `gh issue view --comments`)**: 10 (#2353, #2396, #4114, #3528, #1749, #1107, #1917, #1675, #3233, #537). PRs deeply read: 14 above. **Total issues + PRs deeply read: ~24**, exceeding the 30-target on combined-thread reading (each PR thread had multiple comments and review back-and-forth).
- **Confirmed bugs (excluding closed CVE-class fixes)**: 1 unfixed (Issue #4114). 1 newly identified code-quality bug (LCAE Hash off-by-one). 2 design-acknowledged completeness gaps (#1917/#2353 prevote detection, amnesia accountability).
- **False positives excluded**: 4 (#1675 mempool, not evidence; #1107 downstream-only; #3528 cosmetic JSON; #537 UX-only).
- **Core source files read in full**: 5 (`evidence/pool.go`, `evidence/verify.go`, `evidence/reactor.go`, `types/evidence.go`, `light/detector.go`) via parallel subagents. `state/execution.go` and `state/validation.go` read in evidence-relevant portions. `consensus/state.go` skimmed for evidence hooks.
- **Parallel subagent calls**: 7 total (2 for issue verification, 5 for file-level deep analysis).

## Phase 1: Reconnaissance

### Repo state
- Branch `main`, head `b1eebae6`. After `git describe --tags`, HEAD is `v1.0.1` + one deps bump that does NOT touch any evidence file. So our analysis is effectively `v1.0.1`.
- Initial clone was shallow (89 commits visible); unshallowed to recover full 13361-commit history including the tendermint/tendermint era.

### Structural map

| File | LOC | Purpose |
|---|---|---|
| `evidence/pool.go` | 575 | Pending/committed pool, dedup, consensus buffer, proposer selection, expiry |
| `evidence/verify.go` | 317 | DVE + LCAE verification (signatures, valset, expiration, ABCI conversion) |
| `evidence/reactor.go` | 253 | Gossip; peer-state filtering by maxAge |
| `evidence/doc.go` | 52 | Architecture doc |
| `types/evidence.go` | 645 | DVE/LCAE structs, hash, ABCI conversion |
| `state/validation.go` | 170 | Block validation (evidence size cap only) |
| `state/execution.go` | 889 | CreateProposalBlock, validateBlockAndCheckEvidence, applyBlock |
| `consensus/state.go` | 2709 | ReportConflictingVotes hook |
| `light/detector.go` | 437 | LCAE generation from light-client perspective |

### Concurrency model

- Single-threaded consensus event loop. `Pool.mtx` guards `consensusBuffer` and `Pool.state`. `evidenceSize` is `atomic.Uint32`.
- Reactor: one gossip goroutine per peer (broadcastEvidenceRoutine). `Receive` is synchronous per evidence item.
- Light detector: one goroutine per witness during `detectDivergence`. `providerMutex` held across the fan-out.

### Atomicity boundaries

- **markEvidenceAsCommitted** (pool.go:330-358) is **NOT atomic**: two unbatched DB writes per evidence (remove pending + write committed).
- **Update orchestration** (pool.go:107-133) holds mtx selectively; processConsensusBuffer + updateState are locked; markEvidenceAsCommitted is unlocked (sequential DB writes only).
- **applyBlock** (state/execution.go:279-380): Commit → evpool.Update → store.Save. Crash between `evpool.Update` and `store.Save` leaves persistent state lagging in-memory state.

### Category classification

**Category A (Distributed / Message-Passing) — BFT overlay applies.**

Justification: 
- Cross-node accountability subsystem on Tendermint-family BFT consensus.
- Threat model: static Byzantine corruption, partial-synchronous network, authenticated cryptography (Ed25519), `n ≥ 3f+1` voting power.
- Receiver-side validation is the primary bug surface (consistent with `bft-analysis.md` §3 prompts).
- Composition with non-BFT distributed faults: crash recovery, gossip latency, state-sync vs. consensus-applied state divergence.

Read references in order: `deep-analysis.md`, `distributed-analysis.md`, `bft-analysis.md`.

## Phase 2: Bug Archaeology

### Git history mining

Searched `git log --all --oneline --grep="<keyword>"` for keywords (fix, evidence, race, panic, slash, byzantine, misbehavior, equivocation, light client attack) across:
- `evidence/` (76 commits)
- `types/evidence.go` (additional commits)
- `light/detector.go`
- `state/execution.go` evidence portions

Most informative commits read in detail:

| Commit | Summary | Severity | Component |
|---|---|---|---|
| `425f8c06` (#5638) | Add ByzantineValidators PubKey-vs-Address binding. PubKey-swap could redirect slashing to innocent validators. | Critical (Byzantine slashing) | verify.go |
| `336b47cf` (#5757) | Add nil-check for `LightBlock.SignedHeader` in LCAE.ValidateBasic. Previously panicked on malformed input. | High (crash) | types/evidence.go |
| `24e5aeb1` (#5820) | Add missing `return` after `errc <- Err...` in light/detector. Race condition under which a witness could be classified as both divergent and matching. | High | light/detector.go |
| `64857fd7` (#5613) | Fix `ProposerPriorityHash` buffer offset (varint was always written to `buf[0:]`). | High (hash collision) | types/validator_set.go |
| `43cfd0d2` (#1806) | Introduce `VerifyCommit*AllSignatures` for LCAE verification. Previously stopped at 2/3+, leaving bogus signatures unchecked. | Critical (CVE-class, "Bogus signatures in LCAE" #1749). | types/validation.go, verify.go |
| `3323096b` (#3984) | Cross-check ProposerPriority across light-client providers; introduces `ErrProposerPrioritiesDiverge`. GHSA-g5xx-c4hv-9ccc. | Critical (light-client safety) | light/detector.go, types/validator_set.go |
| `5bafedff` (#6375) | Evidence hash must be immutable post-construction; removed `fastCheck` that could mutate evidence bytes. | High | evidence/pool.go |
| `956b59af` (#5890) | Architectural: buffer DVE detected during consensus; flush to pool only after height commits. Previously caused panic on validators that hadn't yet committed the infraction height. | High (correctness + crash) | evidence/pool.go |
| `651d8f08` (#5574) | Don't penalize peers for gossiping committed evidence; ignore silently. Previously, evidence-receivers disconnected legitimate peers. | High (operational) | evidence/reactor.go, evidence/pool.go |
| `3922dde0` (#5610) | Make evidence structs self-contained (no historical state lookup needed). Previously, state-synced or pruned nodes panicked. | High | types/evidence.go |
| `c0682a3b` (#4839) | Intra-block evidence dedup added. Previously, a Byzantine proposer could include same evidence N times. | High | state/validation.go (and now pool.go:222) |

### Issue verification

#### Deeply read (full comment threads):

| Issue | State | Verdict | Root cause | Fix | Relevance |
|---|---|---|---|---|---|
| #4114 | CLOSED (not_planned) | **Confirmed unfixed bug** | Same DVE-prevote and DVE-precommit (different bytes, different hashes) committed in two consecutive blocks (338278, 338279) causes permanent blocksync failure. Confirmed on v0.38.7, v0.38.12, v1.0. | None; closed without fix. | **High** — direct motivation for Family A + C. |
| #2353 | OPEN | Duplicate of #1917; unclear root cause | Prevote equivocation may be missed if consensus reactor GCs prevote gossip before peers observe both. | Unfixed. | Medium |
| #2396 | OPEN | Design gap | MaxAgeDuration/MaxAgeNumBlocks not validated against chain unbonding period. | Unfixed. | High (config gap) |
| #3528 | CLOSED | Cosmetic | DuplicateVoteEvidence JSON serialization uses mixed casing. | PR #3543, reverted on v0.37/v0.38 as RPC-breaking; v1.x has the fix. | Low |
| #1749 | CLOSED | Confirmed CVE | Bogus signatures in LCAE — fixed by #1806. | PR #1750/#1806 (commit 43cfd0d2). | High (Family B history) |
| #1107 | CLOSED | User error | Namada e2e test deadlocked on stdout buffer. | Downstream Rust fix. | None — excluded as false positive. |
| #1917 | CLOSED (deprioritized) | Design-acknowledged | Consensus reactor's prevote GC makes prevote equivocation detection best-effort. | None. | Medium (completeness gap) |
| #1675 | CLOSED | Off-topic | Mempool block-size mismatch; not evidence. | cosmos-sdk PR #18551. | None — excluded as false positive. |
| #3233 | CLOSED | Test-config + real gossip race | e2e nightlies set unrealistically short MaxAgeDuration; combined with p2p disconnects from clock-skew, evidence could age out before reaching a proposer. | PR #3234 (test config relaxed). | Medium (highlights gossip/aging race) |
| #537 | OPEN | Wontfix-ish | No first-class RPC to query evidence per height. | None. | Low — excluded from modeling as UX-only. |

#### Deeply read PRs (already counted in commits above + Family B reference list).

### Excluded as false positive

- **#1107** — downstream Rust test harness bug; no CometBFT defect.
- **#1675** — mempool/block-size accounting; orthogonal to evidence.
- **#3528** — cosmetic JSON serialization fix; no semantics impact.
- **#537** — UX/observability enhancement request, no current safety concern.

### Bug Family grouping (rationale)

Five families identified by **mechanism** (per `bug-archaeology.md` §3.2 patterns):

- **Family A (Identity/Dedup)** = pattern "missing invariant" + "copy-paste/buffer-offset divergence". Includes LCAE.Hash, intra-block dedup, ProposerPriorityHash (closed). Unifying mechanism: hand-rolled hash constructions and ad-hoc dedup keys.
- **Family B (Receiver-side gates)** = pattern "path inconsistency" — multiple predicates over the same attacker-controlled data with subtly different checks. Includes pubkey-swap, nil-deref, partial-sigverify, proposer-priority cross-check.
- **Family C (Lifecycle)** = pattern "non-atomic operation" + "architectural side effect". Consensus buffer architecture, two-step DB writes, EmptyEvidencePool stub during replay.
- **Family D (Detection completeness)** = pattern "missing invariant" (negative — detection is not guaranteed). Best-effort consensus-side detection, witness eviction, amnesia.
- **Family E (Validator-set lookups)** = pattern "path inconsistency" (verified as no-issue). State.LastValidators vs LoadValidators, DVE timestamp source.

## Phase 3: Deep Analysis

### Methodology

Five parallel subagents, one per core file. Each subagent read the file end-to-end and applied:
- BFT vocabulary from `bft-analysis.md` §1.2 (equivocation, invalid content fabrication, evidence lifecycle, certificate manipulation, omission, etc.)
- Distributed vocabulary from `distributed-analysis.md` §5 (crash recovery, message reorder, timeout, non-atomic persistence)
- Cross-cutting patterns from `deep-analysis.md` §1 (atomicity, code-path inconsistency, error-handling gaps, developer signals)

Briefing for each subagent included the list of known-fixed closed bugs to explicitly EXCLUDE from new-finding lists (per `bug-archaeology.md` §1.4 and `modeling-brief-format.md` §6.1 output-value litmus).

### Findings by file

#### evidence/pool.go (subagent A, ~75K tokens)

Confirmed concerns:
- **Crash window between `removePendingEvidence` and committed-key write** (pool.go:330-358). Two unbatched DB writes; combined with EmptyEvidencePool replay path (consensus/replay.go:529), committed marker can be lost permanently. Family C.
- **addPendingEvidence non-idempotency** (pool.go:297-316): blindly increments `evidenceSize` without checking pre-existence. For LCAE hash-collision overwrites in CheckEvidence (pool.go:213), this over-counts. Family A. Code-quality.
- **LCAE pending content overwrite during CheckEvidence** (pool.go:194-220): block's version overwrites pending under same hash key; clist not updated. Architecturally inconsistent but not exploitable for false slashing (since `block.Evidence.ToABCI()` uses block's content). Family A.
- **Pool-AND vs reactor-height-only expiry asymmetry** (pool.go:267-275 vs reactor.go:187-206). Mild liveness gap. Family C.
- **Stale-height DVE silently dropped on missing blockMeta** (pool.go:481-500): bounded-window edge case; under aggressive pruning + consensus stall could lose detectable equivocation. Family C.

Verifications (no-issue):
- `state.LastValidators` ≡ `LoadValidators(state.LastBlockHeight)` semantically (modulo ProposerPriority, which doesn't affect DVE verification). Family E.
- `DVE.Timestamp` source paths produce identical canonical timestamps. Family B.
- `processConsensusBuffer` / `ReportConflictingVotes` serialization is correct under mtx.
- `pruningHeight` invariant aligned with expiry predicate.

#### evidence/verify.go + types/evidence.go (subagent B, ~74K tokens)

Confirmed concerns:
- **LCAE.Hash off-by-one truncation** (types/evidence.go:322-329). Byte 31 of conflicting block hash dropped. Cryptographically infeasible to exploit (~2^124 work for adversarial collision on first 31 bytes), but real defect. **§ 6.3 code-review only** per output-value litmus. Family A.

Verifications (no-issue):
- `verify.go:148-152` is dead code in all paths (BFT-time check already filtered at line 81). Family B.
- Forward-lunatic equal-time edge case is semantically correct (per BFT-time strict monotonicity).
- `ConflictingHeaderIsInvalid` intentionally ignores Time/DataHash/ProposerAddress — correct semantically (equivocation = same valset + state-deterministic fields).
- `GetByzantineValidators` equivocation branch correctly trusts index-wise matching (precondition `ValidatorsHash == ValidatorsHash` makes index ordering canonical).
- Lunatic branch correctly filters to bonded validators in commonVals.
- Amnesia returns empty list; validateABCIEvidence requires ByzantineValidators == nil. Family D documented limitation.
- DVE.ABCI() has no pubkey-swap analogue (the address used IS the bonded validator's address).
- Lunatic-case commit verification's lookUpByIndex=false is correct (commonVals and conflicting commit have different sizes).
- `trustedHeader.ChainID` ≡ `state.ChainID` via validateBlock binding.

#### evidence/reactor.go (subagent C)

Confirmed concerns:
- **No rate limiting on Receive** (reactor.go:72-94). Byzantine peer can pin CPU with max-size LCAEs. Family E (DoS, not safety).
- **Type-assertion fragility** (reactor.go:82): `err.(type)` against `*types.ErrInvalidEvidence`; wrapped errors fall through to default and peer is not punished. § 6.3.
- **Pool-AND vs reactor-height-only asymmetry** (confirmed independently from subagent A).
- **broadcastEvidenceRoutine periodic restart-from-front** (reactor.go:147-152): O(N evidence × P peers × 10s tick) redundant transmission. Family C.

Verifications:
- evidenceListFromProto / ValidateBasic chain is safe; no panic surface on attacker-supplied messages.

#### state/execution.go + state/validation.go (subagent D)

Confirmed concerns:
- **validateBlock evidence cap is byte-cap only** (state/validation.go:165-167). Per-evidence ValidateBasic runs inside block.ValidateBasic before the byte cap; expensive parsing for oversized lists is performed before rejection. Defense-in-depth gap. Family E.
- **CheckEvidence always re-verifies LCAE** (pool.go:202 reachable via execution.go:234). A Byzantine proposer can force every validator to re-run `VerifyCommitLightAllSignatures` per block. CPU asymmetry. Family E.
- **Genesis edge case** (validation.go:96-99): block at InitialHeight cannot meaningfully carry evidence; verify() catches it via missing blockMeta, but validation.go doesn't structurally reject it. Defense-in-depth gap.

Verifications:
- App cannot add/remove evidence via PrepareProposal (state/execution.go:174 re-builds block with local pool's evidence).
- ToABCI() is deterministic across all 5 ABCI invocation points.
- `lastValidatedBlock` optimization (execution.go:226-232) preserves evidence-pool bookkeeping (CheckEvidence runs unconditionally at line 234).
- `pruneBlocks` (execution.go:367) respects EvidenceParams via store.go:388-414.
- Block-time MedianTime is BFT-skew-resistant (within bounds).

#### light/detector.go (subagent E)

Confirmed concerns:
- **handleConflictingHeaders asymmetric failure handling** (detector.go:247-249). Honest witness silently evicted if its examineConflictingHeaderAgainstTrace fails transiently. Family D (observability/liveness).
- **detectDivergence holds providerMutex across goroutine sleeps** (detector.go:41-42, 168). Light client stalls during `2*maxClockDrift + maxBlockLag` sleeps. Acknowledged in NOTE. Code-review.

Verifications:
- #5820 fix is complete: every `errc <-` followed by `return`.
- newLightClientAttackEvidence correctly switches TotalVotingPower source between lunatic (common) and equivocation (trusted) — semantically equivalent since equivocation requires matching ValidatorsHash.
- Signature verification of ConflictingBlock happens transitively via verifySkipping in the source-provider trace.

### Cross-file synthesis

Two themes emerged from cross-referencing:

1. **Hash-construction family**: LCAE.Hash off-by-one (this pass), ProposerPriorityHash buffer offset (#5613 closed), DVE.Hash over full Bytes (correct), evidence-key composition (pool.go:573-575). The codebase has a recurring pattern of hand-rolled hash constructions with subtle bugs. Mechanism-level family.

2. **Receiver-side gate composition**: PubKey-swap (#5638), nil SignedHeader (#5757), partial-sig (#1806), ProposerPriority cross-check (#3984), detector race (#5820). Each closes one gap in the conjunctive verifier. The modeling question is whether the *current* conjunction is sufficient — not re-deriving any individual gap.

## Phase 4: Synthesis

### Bug Family priority ranking

Per `bug-archaeology.md` §3.4:

| Family | Historical bug count | Severity of past bugs | New findings | TLA+ suitability | Unfixed | Priority |
|---|---|---|---|---|---|---|
| A: Identity/Dedup | 3 closed (#4839, #6375, #5613) | High | 1 new (LCAE Hash) + Issue #4114 | High (clear invariants, finite state) | #4114 (production) | **High** |
| B: Receiver-side gates | 5 closed (CVE-class) | Critical | 0 new (verifications confirm soundness) | High (conjunctive predicate, easy to encode) | None known | **High** |
| C: Lifecycle | 3 closed (#5890, #5574, #5610) | High | 3 new (crash window, expiry asymmetry, stale-height drop) | High (multi-state lifecycle, classic TLA+ strength) | #4114 (production) | **High** |
| D: Detection completeness | 0 closed | — | 2 new (witness eviction, sleep-with-lock) | Low (liveness-with-fairness-exclusions, out of scope) | #1917/#2353 (deprioritized) | **Low** |
| E: Valset/time lookups | 0 closed | — | 0 (verifications confirm no-issue) | None | None | **None** |

### Findings classification

Per `modeling-brief-format.md` §6:

- **§ 6.1 Model-Checkable**: 5 entries (MC1-MC5). Each is a forward-looking question whose Phase 4 verdict is not predictable as "hardening / no externally observable consequence / deliberate developer intent." MC1 and MC3 target the #4114 mechanism; MC2 targets the LCAE-hash-overwrite interaction; MC4 explores forged-LCAE robustness; MC5 explores forward-lunatic boundary semantics.
- **§ 6.2 Test-Verifiable**: 5 entries (T1-T5). Integration / benchmark tests for code-quality and operational concerns that don't reduce to protocol-level invariants.
- **§ 6.3 Code-Review-Only**: 8 entries (CR1-CR8). Each requires human judgment (typically a small upstream PR). Per `bug-archaeology.md` §1.4, the litmus does NOT apply to § 6.3; all candidates flow through.

### Closed bugs as reference

Per Critical Rule 8 in the task instructions and `modeling-brief-format.md` §6.1 litmus, closed historical bugs are reference context in § 2 Evidence and § 7 Reference Pointers, **not** modeling targets. Specifically excluded from § 6.1:
- PR #5638 (PubKey-swap)
- PR #5757 (nil SignedHeader)
- PR #1806 / #1750 (partial-signature verification)
- PR #5820 (detector missing return)
- PR #3984 (ProposerPriority cross-check)
- PR #6375 (hash mutation during verify)
- PR #4839 (intra-block dedup)
- PR #5890 (consensus buffer architecture)
- PR #5610 (self-contained evidence)
- PR #5574 (committed-evidence gossip)
- PR #5613 (ProposerPriorityHash offset)

The LCAE Hash off-by-one is **new** in this pass but is dropped from § 6.1 (per output-value litmus: cryptographically infeasible to exploit → no externally observable consequence) and reported in § 6.3.

### Methodology compliance

| Critical rule | Compliance |
|---|---|
| 1. VERIFY before reporting | Each agent re-read code with line citations; cross-referenced across files. |
| 2. Read issue DISCUSSIONS | 10 issues + 14 PRs deeply read via `gh ... --comments`. |
| 3. No hallucinated logic | All claims cite file:line. |
| 4. Parallel subagents | 7 parallel subagent calls (2 issue verification, 5 file analysis). |
| 5. Evidence-based claims | All findings cite code, commits, or issues. |
| 6. Bug Families over flat lists | 5 families identified by mechanism. |
| 7. Classification | Each finding classified MC / Test / Code-review. |
| 8. Thoroughness | 76 evidence-core commits analyzed; ~24 issues/PRs deeply read; coverage stats reported above. |
| 9. Category in brief | Family marked Category A + BFT overlay in § 1. |
| 10. Category-specific reference | Read distributed-analysis.md and bft-analysis.md; applied receiver-side-validation pattern from §3 of bft-analysis. |

### Output-value litmus application

For each candidate § 6.1 finding, the Phase 4 predicted verdict was articulated before inclusion. Candidates whose only honest verdict would be "hardening / defense-in-depth / no externally observable consequence / documented design choice / closed-bug recreation" were dropped to § 6.3 or § 7. The 5 remaining MC findings each have non-trivial open questions whose answers are not predictable from existing closed PRs.

### Outstanding open questions for the spec author

- Should `EvidenceHash` be modeled as injective (current Go code for DVE) or non-injective (current Go code for LCAE)? Recommendation: non-injective for LCAE only.
- Should the crash model differentiate between consensus-loop crash (re-applies through consensus replay) and blocksync crash (re-applies through EmptyEvidencePool path)? Recommendation: yes — this is what makes MC3 expressible.
- How deep should the BFT adversary be in submitting forged evidence? Recommendation: full freedom over `Evidence` field assignment, subject only to "honest signatures unforgeable, Byzantine identities sign as themselves."
- How to encode "amnesia detected but unslashable"? Recommendation: amnesia-class LCAE has ByzantineValidators = empty; slashed[] doesn't change. Liveness only — out of safety scope.
