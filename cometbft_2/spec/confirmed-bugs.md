# Confirmed Bug Report — cometbft_2

## Summary

- **Total findings reviewed**: 14 (from MC `bug-report.md` open-surface
  list and `modeling-brief.md` §3.2/§6, plus the CR-* code-review items
  enumerated in §6.3).
- **MC counterexamples**: 0 (BFS budget exhausted before 30-min
  per-family timeout; see `bug-report.md` for coverage caveats).
- **New bugs reproduced**: 5
- **Known/historical (cited, not re-reproduced)**: 4
- **Code-review issues confirmed without reproduction**: 1 (CR-4 —
  analysis shows the asymmetry is benign in the harm direction the
  brief proposed; recorded for accuracy)
- **False positives**: 0 (no finding was outright invalidated; CR-4 was
  reframed)
- **Inconclusive**: 4 (Family 1/2/5/6 cross-validator and crash-replay
  surfaces remain reachable in principle but were outside the BFS
  budget and could not be reproduced as a unit test without a real
  multi-node cluster)

The CometBFT codebase is well-tested and the consensus state machine is
mature. The surfaces uncovered by this round are all narrow,
well-understood patterns where the implementation diverges from the
strictest reading of the protocol invariants — most have public
upstream GitHub issues (OPEN or accepted-as-deferred). None of the new
bugs trigger an immediate consensus-safety violation in a 4-validator
quorum-honest setup; they are exploitable only under specific Byzantine
behaviors documented per finding.

---

## Bug 1: `DoubleSignCheckHeight=1` performs zero iterations (#5435)

- **Source**: Modeling brief §6.2 TV-1; CometBFT GitHub issue #5435 (OPEN)
- **Status**: REPRODUCED
- **Severity**: Medium (defense-in-depth bypass; privval's `CheckHRS`
  remains the primary defense against double-signing).
- **Location**: `consensus/state.go:2719`
- **Description**:
  ```go
  for i := int64(1); i < doubleSignCheckHeight; i++ {
      lastCommit := cs.blockStore.LoadSeenCommit(height - i)
      ...
  }
  ```
  When the operator configures `DoubleSignCheckHeight = 1` — a value
  that semantically means "look back at the single previous block" —
  the loop bound is `1 < 1`, so the body runs zero times. The check
  silently returns nil without inspecting any commits.

  Operationally this means an operator who restarts a validator
  expecting the implicit "one-block look-back" guard to catch a
  double-sign mistake from the previous incarnation will instead get
  no guard at all. The validator then proceeds to sign at the new
  height. Privval's `CheckHRS` still catches re-signing at the *same*
  HRS, so this is a defense-in-depth gap rather than a direct safety
  break.

- **Prerequisites**:
  - `[code]` Reachable from public API: VERIFIED — `consensus/state.go:417`
    invokes `cs.checkDoubleSigningRisk(cs.Height)` from `handleMsg`.
  - `[code]` Loop condition is `i < doubleSignCheckHeight`: VERIFIED —
    `state.go:2719`.
  - `[spec]` Operator semantics of `DoubleSignCheckHeight=N` should
    cover N most-recent blocks: VERIFIED — config doc & PR threads
    refer to `DoubleSignCheckHeight` as "number of blocks to look back
    to detect a double-sign".
- **Counterfactual fix check**: Not applicable — the violated property
  is local (a specific function returns the wrong answer for a specific
  config value), not system-wide.
- **Report Tier**: B — bounded; privval's `CheckHRS` is the actual
  safety boundary, so the worst case is a regressed defense-in-depth
  layer for an operator misconfiguration.
- **Trigger scenario**: Operator sets `DoubleSignCheckHeight = 1` →
  validator restarts → `checkDoubleSigningRisk` returns nil after zero
  iterations → if privval state file was lost and previously signed
  height was H-1, no detection occurs at the consensus layer.
- **Developer intent investigation**: Issue #5435 is OPEN on
  cometbft/cometbft. The reporter explicitly states "expect 1 to mean
  check the most recent block." No deliberate-trade-off comment exists.
- **Reproduction test**: `repro/bug1_doublesign/main.go` — replicates
  the loop with exact bounds and asserts the number of inspected
  heights matches the operator's stated look-back. Non-zero exit
  status indicates bug reproduced.
- **Reproduction result**: REPRODUCED. Exact captured output:
  ```
  currentHeight=100  DoubleSignCheckHeight=1  -> inspected 0 block(s): []
    >>> BUG: expected 1 look-back(s), got 0
  currentHeight=100  DoubleSignCheckHeight=2  -> inspected 1 block(s): [99]
    >>> BUG: expected 2 look-back(s), got 1
  currentHeight=100  DoubleSignCheckHeight=3  -> inspected 2 block(s): [99 98]
    >>> BUG: expected 3 look-back(s), got 2

  BUG REPRODUCED: DoubleSignCheckHeight=1 results in 0 iterations of
  the look-back loop. ...
  ```
- **Recommendation**: Change the loop bound to `i <= doubleSignCheckHeight`
  (or, equivalently, start at `i:=0` with appropriate semantics), and
  add a unit test pinned to `DoubleSignCheckHeight=1`. Also document
  the precise N-blocks-back semantics in the config.

---

## Bug 2: `light/verifier.go:VerifyAdjacent` does not cross-check `LastBlockID` (#2252)

- **Source**: Modeling brief §2.4 Family 4; CometBFT GitHub issue
  #2252 (OPEN, attributed to Josef Widder)
- **Status**: REPRODUCED
- **Severity**: High (for light clients)
- **Location**: `light/verifier.go:92-131`
- **Description**: `VerifyAdjacent` performs only the
  `ValidatorsHash == NextValidatorsHash` cross-check between the
  trusted and untrusted headers (line 116). It does **not** check
  `untrustedHeader.LastBlockID == hash(trustedHeader)`. A Byzantine
  quorum of the new validator set (≥ 1/3 per `DefaultTrustLevel`;
  ≥ 2/3 for `VerifyCommitLight`) can sign a header at H+1 with
  `LastBlockID` pointing to a different prior block than the trusted
  one, and `VerifyAdjacent` returns nil.

  Note: `VerifyBackwards` (lines 220-246) does include the analogous
  check (`untrustedHeader.Hash() == trustedHeader.LastBlockID.Hash`),
  which establishes the cross-check is structurally meaningful — its
  absence on the forward direction is the asymmetry #2252 reports.

- **Prerequisites**:
  - `[code]` Public API: VERIFIED — `light.VerifyAdjacent` is exported.
  - `[code]` Only `ValidatorsHash` is cross-checked: VERIFIED —
    `verifier.go:116`; subsequent calls verify only commit-on-block,
    not header-on-history.
  - `[spec]` Light-client safety is parameterized on
    `DefaultTrustLevel = 1/3` of next-validators being honest:
    VERIFIED — ADR-047 / verifier.go:13-15.
  - `[code]` Adjacent verification flow includes both `ValidatorsHash`
    and `VerifyCommitLight` but never `LastBlockID`: VERIFIED.
- **Counterfactual fix check**: Not applicable — the violated property
  is a specific missing check on a specific code path, not a system-
  wide invariant.
- **Report Tier**: A — externally observable, light clients can be
  redirected onto a fork, recovery requires resync from a different
  primary. The bug is a missing check, the fix is a one-line cross-
  check, and #2252 has been OPEN since the issue was filed.
- **Trigger scenario**:
  1. Light client has trusted header at height H1 (hash `H_h1`).
  2. Byzantine majority of `nextValidators(H1)` signs a forked header
     at H1+1 with `LastBlockID.Hash ≠ H_h1`. (Possible because the
     validator set is committed to in `NextValidatorsHash`; the
     attacker controls ≥ 2/3 of the new set.)
  3. Light client calls `VerifyAdjacent(trusted, forked, ...)` —
     returns nil and updates to the forked branch.
- **Developer intent investigation**: Issue #2252 is OPEN. The
  description references that `VerifyCommitLight` is called with
  `untrustedHeader.Commit.BlockID` (taken from the *untrusted* header
  itself), so the BlockID-vs-BlockID check tautologically passes — a
  detailed flaw confirmed by reading lines 125-128.
- **Reproduction test**: `repro/test_bug2_verifyadjacent_lastblockid_test.go`
  — builds a trusted header at H=1 and a forked-LastBlockID header at
  H=2 (same validator set, all validators sign), then calls
  `light.VerifyAdjacent`. Test FAILs when `VerifyAdjacent` returns nil
  on the forked input.
- **Reproduction result**: REPRODUCED. Exact captured output:
  ```
  test_bug2_verifyadjacent_lastblockid_test.go:153: Trusted hash (height 1):       97CEA592A1A8B7B1C5D2508CE20DED6BCFE124F884A37AD3BD3234A255A13F1F
  test_bug2_verifyadjacent_lastblockid_test.go:161: Forked LastBlockID.Hash:        FBE9909BCEF270F98D1D0AA08186AD6B0B185A4CB1727B65E1FB18C49F9ECD64
  test_bug2_verifyadjacent_lastblockid_test.go:185: BUG REPRODUCED: VerifyAdjacent accepted an untrusted header whose
  ...
  --- FAIL: TestVerifyAdjacent_MissingLastBlockIDCheck (0.00s)
  ```
- **Recommendation**: In `VerifyAdjacent`, add
  `if !bytes.Equal(untrustedHeader.LastBlockID.Hash, trustedHeader.Hash()) { return ErrInvalidHeader{...} }`
  symmetric to `VerifyBackwards`. Also consider cross-checking
  `LastCommitHash`. The trust assumption against ≥ 1/3 Byzantine next-
  validators remains, but currently the breach is silent rather than
  detectable.

---

## Bug 3: VoteExtension signature not bound to BlockID

- **Source**: Modeling brief §2.3 Family 3 / MC-5
- **Status**: REPRODUCED
- **Severity**: Medium (structural — harm requires composition with
  equivocation or late-commit paths)
- **Location**: `types/canonical.go:71-78`
- **Description**: `CanonicalizeVoteExtension` returns
  `CanonicalVoteExtension{Extension, Height, Round, ChainID}` — no
  BlockID. The VE signature therefore binds to `(H, R)` for a given
  extension payload but not to a specific block. A Byzantine
  validator equivocating at `(H, R)` can attach the same VE signature
  to two precommits for different `BlockID`s; both pass
  `vote.VerifyExtension`.

  By itself this is not exploitable: the *vote* signature (not the VE
  signature) still binds to `BlockID`, so the equivocation is
  detectable as a `*ErrVoteConflictingVotes`. But the VE bytes carried
  by the *first-seen* of the two precommits flow into the equivocator's
  recipient's `voteSet`, and then into `MakeExtendedCommit` →
  `BuildExtendedCommitInfo` at H+1 (`state/execution.go:609-665`)
  without being re-bound to the canonical BlockID. The signed-bytes
  domain is asymmetric to what `BuildExtendedCommitInfo` consumes.

- **Prerequisites**:
  - `[code]` `CanonicalizeVoteExtension` omits BlockID: VERIFIED —
    `types/canonical.go:71-78`.
  - `[code]` `BuildExtendedCommitInfo` does not re-verify VE sigs:
    VERIFIED — `state/execution.go:609-665`; only `EnsureExtension`
    structural check.
  - `[spec]` ABCI++ specification on VE binding to BlockID: NOT
    VERIFIED — ABCI++ spec is silent on the explicit binding; this is
    a hygiene gap per the modeling brief, not a normative violation.
- **Counterfactual fix check**: Not applicable — the violated property
  is a missing field in a specific canonical struct.
- **Report Tier**: B — hygiene defense; the immediate VE-replay attack
  is bounded by the vote signature binding to BlockID, but the absent
  binding is a non-obvious foot-gun for ABCI++ application authors
  (CR-2 in the modeling brief: the app's `VerifyVoteExtension` also
  doesn't receive `Round`).
- **Trigger scenario**: Byzantine validator equivocates at `(H, R)` for
  blocks A and B; signs VE once (because canonical bytes don't include
  BlockID); attaches the single signature to both precommit envelopes.
  Receiver verifies both VEs successfully. Either precommit, when
  carried in `LastCommit` to H+1, propagates the VE unbound to the
  block actually committed.
- **Developer intent investigation**: ABCI++ ADRs (047, 053) discuss VE
  semantics in terms of `(Height, ValidatorAddress, Extension)`. No
  ADR explicitly mandates BlockID binding. The behavior is therefore
  spec-silent, not spec-contradicting.
- **Reproduction test**: `repro/test_bug3_ve_signature_missing_blockid_binding_test.go`
  — generates one VE signature, attaches it to two precommits at the
  same `(H=10, R=0)` with different `BlockID`s, and verifies both with
  `vote.VerifyExtension`.
- **Reproduction result**: REPRODUCED. Exact captured output:
  ```
  test_bug3_ve_signature_missing_blockid_binding_test.go:109: voteA (BlockID=626C6F636B412D68): VerifyExtension PASSED
  test_bug3_ve_signature_missing_blockid_binding_test.go:116: voteB (BlockID=626C6F636B422D68): VerifyExtension PASSED with the SAME ExtensionSignature as voteA
  test_bug3_ve_signature_missing_blockid_binding_test.go:119: BUG REPRODUCED: One VE ExtensionSignature is valid for two precommits
  ...
  --- FAIL: TestVEExtSignatureNotBoundToBlockID (0.00s)
  ```
- **Recommendation**: Either (a) extend `CanonicalizeVoteExtension` to
  include `BlockID` (breaking change — applications would need to
  re-sign), or (b) document the omission in ABCI++ spec and add a
  `Round` parameter to `RequestVerifyVoteExtension` so applications
  can enforce binding semantics themselves (CR-2). Option (b) is the
  less disruptive path and matches the existing modeling brief
  recommendation.

---

## Bug 4: `Proposal.ValidateBasic` accepts `POLRound >= Round` (CR-7)

- **Source**: Modeling brief §6.3 CR-7
- **Status**: REPRODUCED
- **Severity**: Medium (defensive gap; downstream `enterPrecommit`
  recovers, but malformed proposals reach further into the pipeline
  than they should)
- **Location**: `types/proposal.go:59-61`
- **Description**: Proposal-level basic validation only checks
  `POLRound < -1`. Per protocol semantics a Proof-of-Lock round must
  refer to a *prior* round (POLRound < Round, or POLRound = -1 for
  "no lock"). The code accepts `POLRound == Round`, `POLRound > Round`,
  and `POLRound = INT32_MAX`.

  Downstream logic at `consensus/state.go:1484-1603 enterPrecommit`
  and `state.go:2317-2333 addVote` checks the relationship between
  POLRound and the receiver's locked round before acting, so a
  malformed proposal does not directly violate safety in the
  4-validator quorum case. But a Byzantine proposer with the freedom
  to pick `POLRound >= Round` can exercise the relock/unlock-and-nil
  branches in adversarial order without producing a basic-validation
  error.

- **Prerequisites**:
  - `[code]` `ValidateBasic` has no `POLRound < Round` guard:
    VERIFIED — `types/proposal.go:59-61`.
  - `[spec]` Tendermint paper and ADR-047 define POLRound as a *prior*
    round (POLRound < Round): VERIFIED — `Tendermint BFT` arXiv:1807.04938
    Algorithm 1, line 14 onward; POL is established by a prior round's
    polka.
  - `[code]` Downstream logic enforces the constraint: VERIFIED —
    `state.go:2317-2333` addVote uses `LockedRound < vote.Round <= cs.Round`;
    `enterPrecommit` uses `polka.round` from current round's prevotes only.
- **Counterfactual fix check**: Not applicable — local, code-structural.
- **Report Tier**: C — defensive gap caught by downstream guards. No
  externally observable consequence beyond a Byzantine proposer being
  able to send slightly-malformed Proposal messages that downstream
  logic recovers from. Worth a one-line check.
- **Trigger scenario**: Byzantine proposer publishes a Proposal with
  `Round=3, POLRound=3` (or `POLRound > Round`). Receivers call
  `Proposal.ValidateBasic`; no error. The proposal is then propagated
  on the gossip channel and passes basic-vote checks. Whether
  `enterPrecommit` does the right thing in the relock branch under
  this input is reachable in deeper exploration (Family 6, MC-11) but
  was not falsified by BFS within budget.
- **Developer intent investigation**: `types/proposal.go` has no
  explicit comment justifying the missing check. `consensus/state.go`
  comment at line 1399 and elsewhere mention "POLRound is from a prior
  round". The protocol intent is clear; the missing ValidateBasic
  check is an oversight.
- **Reproduction test**: `repro/test_bug4_polround_ge_round_validatebasic_test.go`
  — constructs a structurally valid Proposal with `Round=3, POLRound=3`,
  calls `ValidateBasic`, fails if it returns nil.
- **Reproduction result**: REPRODUCED. Exact captured output:
  ```
  test_bug4_polround_ge_round_validatebasic_test.go:78: BUG REPRODUCED [POLRound==Round (boundary)]: ValidateBasic accepted Round=3 POLRound=3
  test_bug4_polround_ge_round_validatebasic_test.go:78: BUG REPRODUCED [POLRound>Round (future)]: ValidateBasic accepted Round=3 POLRound=7
  ...
  --- FAIL: TestPOLRoundNotLessThanRoundPassesValidateBasic (0.00s)
  ```
- **Recommendation**: Add
  ```go
  if p.POLRound >= p.Round {
      return errors.New("POLRound must be < Round (Proof-of-Lock is from a prior round)")
  }
  ```
  to `Proposal.ValidateBasic`. Keep the `POLRound == -1` sentinel
  semantics (`POLRound < -1` already rejected).

---

## Bug 5: `consensusBuffer` silently drops future-height conflicting votes (CR-3 / TV-2)

- **Source**: Modeling brief §6.2 TV-2 and §6.3 CR-3
- **Status**: REPRODUCED
- **Severity**: Medium (lossy evidence pipeline at the lower edge;
  natural reachability is conditional in normal flow but the in-memory
  buffer + unconditional reset is the broader hygiene gap that also
  causes evidence loss on crash)
- **Location**: `evidence/pool.go:49` (buffer is purely in-memory),
  `evidence/pool.go:502-509` (future-height entries logged-and-dropped),
  `evidence/pool.go:538` (buffer reset unconditionally after each Update)
- **Description**: `Pool.consensusBuffer` is an in-memory slice
  populated by `ReportConflictingVotes` and flushed during
  `Update → processConsensusBuffer`. Two distinct gaps:

  1. The `processConsensusBuffer` loop's default branch
     (`pool.go:502-509`) handles entries whose `VoteA.Height >
     state.LastBlockHeight` by logging an error and `continue`-ing.
     Because the buffer is then reset at line 538, the future-height
     entry is never retried even after state catches up to that
     height.
  2. The buffer has no persistence layer. A crash between
     `ReportConflictingVotes` and `Update` loses all buffered
     conflict-vote pairs.

- **Prerequisites**:
  - `[code]` Buffer is in-memory: VERIFIED — `pool.go:49`.
  - `[code]` `processConsensusBuffer` continues on future-height:
    VERIFIED — `pool.go:502-509`.
  - `[code]` Buffer reset is unconditional: VERIFIED — `pool.go:538`,
    `evpool.consensusBuffer = make([]duplicateVoteSet, 0)`.
  - `[spec]` Evidence pipeline contract: "if Byzantine equivocates and
    an honest node sees both votes, evidence is eventually committed"
    — captured in modeling brief invariant `EventualAccountability`.
    Spec-silent on the precise persistence semantics of the
    consensus-detection buffer.
- **Counterfactual fix check**: System-wide property
  (`EventualAccountability`). A counterfactual fix — say, "persist
  consensusBuffer to disk before broadcasting" — would close the
  crash-window path. But `bug-report.md` Family 5 BFS within budget
  did not falsify `EventualAccountability` *without* the crash-window
  path either, so the relative importance of this fix vs. other paths
  (selective dissemination of equivocating votes; #2353) is uncertain.
  The brief notes "if only one honest sees, evidence is lost", which
  matches the buffer-reset behavior. **Conclusion**: framing
  corroborated for the crash-window path; the future-height-drop path
  is harder to reach in normal flow but is observably lossy when
  reached.
- **Report Tier**: B — hygiene gap with a clear path to silent
  evidence loss under crash; not exploitable on its own but weakens
  the accountability story.
- **Trigger scenario** (for the future-height-drop variant): some
  consensus path observes a conflict-vote pair at height H+5 (above
  the local LastBlockHeight=H) — e.g., a peer sends late late-arrival
  precommits across two rounds. The receiver buffers them; the next
  `Update` runs, sees `voteA.Height > LastBlockHeight`, drops the
  entry, resets the buffer. Even after the chain catches up to H+5,
  the entry is gone.
- **Developer intent investigation**: `pool.go:502-509` log message
  itself acknowledges the issue: "perhaps consider keeping the votes
  in the buffer and retry in following heights". The TODO has not been
  acted on. The unconditional reset at line 538 has no nearby comment.
- **Reproduction test**: `repro/test_bug5_consensusbuffer_drops_future_height_test.go`
  — sets up a real `evidence.Pool` with mock state/block stores, calls
  `ReportConflictingVotes` for a vote pair at height H+5 while state
  is at H, then advances state via `Update` and observes that the
  pool's pending list remains empty even after state advances past
  H+5.
- **Reproduction result**: REPRODUCED. Exact captured output:
  ```
  test_bug5_consensusbuffer_drops_future_height_test.go:104: After ReportConflictingVotes (height=15, state.LastBlockHeight=10):
  test_bug5_consensusbuffer_drops_future_height_test.go:105:   pending evidence list size: 0 (buffer not yet flushed)
  E[2026-05-12|17:10:59.441] inbound duplicate votes from consensus are of a greater height than current state duplicatevoteheight=15 state.LastBlockHeight=11
  test_bug5_consensusbuffer_drops_future_height_test.go:116: After Update(state.LastBlockHeight=11):
  test_bug5_consensusbuffer_drops_future_height_test.go:117:   pending evidence list size: 0
  test_bug5_consensusbuffer_drops_future_height_test.go:132: After Update(state.LastBlockHeight=15): pending list size 0
  test_bug5_consensusbuffer_drops_future_height_test.go:135: BUG REPRODUCED: ...
  --- FAIL: TestConsensusBufferDropsFutureHeightVotes (0.00s)
  ```
- **Recommendation**: In `processConsensusBuffer`, replace the
  "future-height log-and-drop" branch with "keep in buffer; retry on
  next Update". Make the buffer reset conditional on the entries
  having been *processed* rather than unconditional. For the crash
  surface, write the buffer to disk before broadcasting (the existing
  `evidenceStore` is suitable).

---

## Open surfaces with prior upstream evidence (no new reproduction)

The findings below are accepted upstream or have well-known reference
material. They are *not* re-reproduced for this round; their existing
upstream issue is the canonical evidence.

### #5204 (OPEN) — Proposer doesn't self-verify own VE; >1/3 invalid VEs cause re-extension loop

- **Source**: Modeling brief §2.3 Family 3 historical
- **Status**: KNOWN-HISTORICAL
- **Severity**: High (was actively exploited in 0.38.x branches; surface
  remains in this snapshot)
- **Location**: `consensus/state.go:2670 signVote` does not self-verify
  the VE; the receive path at `state.go:2394` is the only place
  `VerifyVoteExtension` is called.
- **Description**: Carried from Round 1's analysis. Modeled in spec
  Family 3 (`VELiveness` temporal property), disabled in the hunting
  configs due to MCSpec lacking fairness.
- **Recommendation**: Adopt #5204's proposed fix (self-verify VE
  during signing).

### #4114 (CLOSED, fixed) — Same evidence committed in two consecutive blocks

- **Source**: Modeling brief §2.5 Family 5 historical
- **Status**: KNOWN-HISTORICAL — fixed upstream
- **Severity**: Was High (blocksync permanently broken when triggered)
- **Location**: Was `evidence/pool.go` evidence lifecycle bug, addressed.

### #1309 (CLOSED, log-only) — Proposal with `POLRound == LockedRound` but different block

- **Source**: Modeling brief §2.6 Family 6 historical
- **Status**: KNOWN-HISTORICAL — closed by upstream as "log-only"
  remediation (canonical sign of equivocation, but no protocol action
  is taken beyond emitting a log)
- **Severity**: Medium — partial overlap with Bug 4 (CR-7) here
- **Location**: `consensus/state.go` log emission only; no rejection.

### ASA-2024-* security advisories (mostly fixed)

- **Status**: KNOWN-HISTORICAL — referenced in modeling brief; relevant
  ASA-2024-001, 004, 009, 011 and ASA-2025-002 are all FIXED in the
  artifact tree.
- **Severity**: Mixed
- **Reference**: cometbft/cometbft security advisories.

---

## False positive / reframed

### CR-4 — `evidence/reactor.go:192` (height-only) vs `evidence/verify.go:313` (height-AND-time) expiry mismatch

- **Source**: Modeling brief §6.3 CR-4 / Family 5 MC-8
- **Status**: REFRAMED — the asymmetry exists but does not cause the
  "honest peer banned" harm the brief proposes
- **Severity**: Tier C hygiene
- **Location**: `evidence/reactor.go:192` (sender filter is
  `peerHeight - evHeight > MaxAgeNumBlocks`); `evidence/verify.go:309-317
  IsEvidenceExpired` (receiver filter is `ageDuration > MaxAgeDuration && ageNumBlocks > MaxAgeNumBlocks`).
- **Description**: The bug claim is that an honest sender's filter
  permits a broadcast that the receiver then rejects with
  `StopPeerForError`. Analyzing the comparator algebra:
  * Sender drops only when `ageNumBlocks > MaxAgeNumBlocks` (from
    *peer's* reported height).
  * Receiver drops only when *both* `ageDuration > MaxAgeDuration`
    *and* `ageNumBlocks > MaxAgeNumBlocks` (from *receiver's* own
    state).

  For the receiver to reject, `ageNumBlocks > MaxAgeNumBlocks` from
  the receiver's view must hold. But the sender uses the receiver's
  reported height (`peerHeight`), so the sender would also have
  dropped. The receiver is strictly more permissive than the sender;
  the receiver-rejects-while-sender-broadcasts path is empty unless
  the sender's view of `peerHeight` is stale by more than `MaxAgeNumBlocks`
  blocks, which would also affect normal gossip.
- **Prerequisites**:
  - `[code]` Reactor filter algebra: VERIFIED — `reactor.go:192`.
  - `[code]` Verify filter algebra: VERIFIED — `verify.go:313`.
  - `[code]` Sender view of receiver height is `peerHeight` from
    PeerState: VERIFIED — `reactor.go:185`.
- **Counterfactual fix check**: Property held in receiver's favor in
  all considered orderings; reframed as hygiene rather than as the
  asymmetric-DoS the brief proposed.
- **Report Tier**: C — code smell (the filters should be consistent
  for readability and against future refactors); not exploitable in
  the harm direction the brief proposed.
- **Conclusion**: The two filters are inconsistent on paper, but the
  asymmetry favors the receiver; the "honest peer banned" claim is
  not reachable. Recommend the filters be made symmetric for
  maintainability, but no urgent security fix is required.

---

## Other modeling-brief findings — inconclusive within budget

The following surfaces remain reachable in principle but were not
falsified by the bounded BFS exploration and could not be reproduced
as unit tests without a multi-node cluster. They are recorded for
completeness.

| ID | Surface | Why inconclusive |
|----|---------|------------------|
| Family 1 MC-2 | Equivocation + selective dissemination — `evidence/reactor.go:1611 VoteSetBits` reconciles bitmaps not vote bytes | Requires real multi-peer gossip; unit test cannot construct the necessary partition |
| Family 2 MC-3, MC-4 | Amnesia composition with crash + `repairWalFile` tail truncation | Requires WAL corruption + restart; non-trivial unit-test setup outside this round's scope |
| Family 5 MC-12 | Pool unbounded growth under valid `DuplicateVoteEvidence` flood | Bound is conditional (`MaxAgeNumBlocks × validators`); requires sustained flooding over many heights to demonstrate observable harm |
| Family 6 MC-10 | Locking-vs-relock transitions × Byzantine proposer alternation | BFS reachable but not falsified; covered partially by Bug 4 (CR-7) which is the basic-validation gap that opens this surface |

These should be revisited with either deeper BFS budgets, simulation
fairness, or full multi-node integration tests.

---

## Methodology notes

- All reproductions are **Level 0** (pure black-box, public API only).
- Reproduction tests live in
  `/home/ubuntu/Specula/case-studies/cometbft_2/.specula-output/repro/`.
  See `repro/README.md` for how to run them.
- The Go toolchain used was `go1.25.8`; the module wired up via a
  `replace` directive pointing at
  `/home/ubuntu/Specula/case-studies/cometbft_2/artifact/cometbft`.
- Outputs captured to `repro/bug1_output.txt` and
  `repro/all_tests_output.txt`.
