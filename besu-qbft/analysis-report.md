# Analysis Report: hyperledger/besu QBFT

## 1. Scope and Coverage Statistics

### Codebase Analyzed
| Module | Path | LOC | Files |
|--------|------|-----|-------|
| qbft-core | consensus/qbft-core/src/main/ | 6,369 | 56 |
| qbft (adaptor) | consensus/qbft/src/main/ | 3,248 | 39 |
| common/bft | consensus/common/.../bft/ | 5,676 | ~60 |
| **Total** | | **~15,300** | **~155** |

### Core Files Deeply Read (Phase 3)
| File | Lines | Findings |
|------|-------|----------|
| QbftRound.java | 398 | 8 findings (2 high, 3 medium, 3 low) |
| QbftBlockHeightManager.java | 508 | 7 findings (1 high, 3 medium, 3 low) |
| QbftController.java | 317 | 12 findings (2 moderate, 5 structural) |
| BaseBftController.java | 269 | Analyzed with QbftController |
| RoundChangeManager.java | 271 | 6 findings (2 potential bugs, 4 design) |
| RoundState.java | 217 | 3 findings (1 design difference, 2 correct) |
| RoundChangeArtifacts.java | 105 | 2 findings (1 comparator defect, 1 gap) |
| ProposalValidator.java | 351 | 14 findings (all verified correct or informational) |
| RoundChangeMessageValidator.java | 154 | Analyzed with ProposalValidator |
| MessageValidator.java | 171 | Analyzed with ProposalValidator |
| BftProcessor.java | 95 | 1 finding (event loop architecture) |
| FutureMessageBuffer.java | 168 | 4 findings (buffer design) |
| BftHelpers.java | 100 | Quorum formula verified |

### Bug Archaeology Coverage
| Metric | Count |
|--------|-------|
| Git commits analyzed (bug-fix keywords) | 150+ |
| Consensus-logic bug-fix commits deeply examined | 20 |
| GitHub issues collected | 50 |
| GitHub issues deeply read (full discussion) | 27 |
| Issues confirmed as bugs | 35 |
| Issues classified as user error / design defect | 8 |
| Issues classified as uncertain | 7 |

---

## 2. Phase 1: Reconnaissance Summary

### Architecture

The Besu QBFT implementation follows a layered architecture:

```
BftMiningCoordinator (lifecycle)
  └── BftProcessor (event loop) ← BftEventQueue ← timer threads, network
       └── EventMultiplexer (dispatch by event type)
            └── QbftController (height routing, gossip)
                 └── QbftBlockHeightManager (per-height state machine)
                      ├── QbftRound (per-round consensus)
                      │    └── RoundState (quorum tracking)
                      └── RoundChangeManager (round change collection)
```

### QBFT Protocol Flow
1. **New Height**: Block imported → new `QbftBlockHeightManager` created
2. **Block Timer Fires**: Creates round 0; proposer builds block and multicasts Proposal
3. **Proposal Received**: Validators validate; if accepted, multicast Prepare
4. **Prepare Quorum (ceil(2n/3))**: Node is "prepared"; multicast Commit with seal
5. **Commit Quorum (ceil(2n/3))**: Block sealed with commit seals; imported to chain
6. **Round Timer Expires**: Construct PreparedCertificate (if prepared); multicast RoundChange
7. **RoundChange Quorum (2f+1)**: Proposer for new round creates Proposal using best prepared certificate
8. **f+1 RoundChange (early)**: Node jumps to the minimum higher round (experimental)

### Quorum Formulas
- Standard quorum: `ceil(2n/3)` where n = validator count
- Early round change: `(n-1)/3 + 1` (f+1)
- Prepare messages needed: `ceil(2n/3)` (QBFT differs from IBFT which uses `ceil(2n/3) - 1`)

### Key Design Decisions
1. **Block hash includes round + proposer**: Unlike simpler BFT implementations, QBFT embeds the round number and proposer address in the block header's extra data, making the block hash round-dependent.
2. **In-memory consensus state**: No persistence of consensus state (proposals, prepares, commits, round changes). Crash = full state loss.
3. **Single-threaded event loop**: All consensus processing happens on one thread, serializing all operations. Timer threads only enqueue events.
4. **Dual-guard on round expiry**: Checks both `blockchain.getChainHeadBlockNumber()` and `heightManager.getChainHeight()` to prevent stale timer events.

---

## 3. Phase 2: Bug Archaeology Findings

### 3.1 Critical Safety Bugs (Historical)

#### Issue #1734: Two honest IBFT2 validators commit different blocks at same height
- **Status**: Closed, fixed by PR #1575
- **Root cause**: Race condition in event queue. A `RoundExpiry` event could be processed AFTER a block was imported (blockchain advanced) but BEFORE the `NewChainHead` event was processed (height manager still at old height). An honest validator would then send a spurious RoundChange with an empty prepared certificate, enabling a byzantine validator to cause two honest nodes to finalize different blocks.
- **Discovery**: Found via formal verification by `saltiniroberto`
- **QBFT mitigation**: Dual-guard pattern at `QbftController.java:276-289` checks `blockchain.getChainHeadBlockNumber()` before processing round expiry
- **Model-checkable**: Yes — this is the canonical event-interleaving safety bug

#### Issue #1736: Duplicate IBFT2 messages not discarded in Prepared Certificate
- **Status**: Closed, fixed by PR #1671
- **Root cause**: `BftMessage` lacked `equals()`/`hashCode()`. Duplicate prepare messages from the same validator were not deduplicated when building a PreparedCertificate for RoundChange messages. A byzantine node could inflate the prepare count.
- **Discovery**: Found via formal verification by `saltiniroberto`
- **QBFT fix**: Commit `5ab214e894` added proper `equals()`/`hashCode()` to `BftMessage`
- **Model-checkable**: Yes — model quorum as counting distinct authors, not message count

### 3.2 Chain-Stalling Bugs (Historical)

#### Issues #3785, #6053, #6613, #6732: "Latest Prepared Metadata blockhash does not align with proposed block"
- **Status**: All closed, fixed by PR #7875 (commit `f64c147c4a`)
- **Root cause**: When re-proposing a prepared block in a new round, the round number was not updated in the block header. The validator's hash comparison (which substituted the old round) would fail because the block already had the old round.
- **Production impact**: Permanent chain stall with exponentially increasing round timeouts
- **Triggers**: Any round change after a block was prepared in round > 0: validator crash (#6613), slow tx selection (#6732), transient storage error (#6053)
- **Model-checkable**: Yes — model block identity as function of round

#### Issue #8307: Restarted BFT validators fail to agree on new blocks
- **Status**: Closed, fixed by PR #8308 (commit `083b1d3986`)
- **Root cause**: `BftMiningCoordinator.stop()` did not reset the controller's `started` flag or stop the block height manager. After sync-triggered restart, `start()` threw `IllegalStateException` or silently did nothing.
- **Model-checkable**: Partially — validator lifecycle (running/stopped/restarted) can be modeled

### 3.3 Validator Transition Bugs (Historical)

#### Issues #2868, #2874, #2935: Wrong validator set at fork transitions
- **Status**: All closed, fixed by commits `0ffe977f86`, `91ef16d378`, `71e6b0ccf1`
- **Root cause**: Off-by-one in fork schedule lookup — used current block number instead of next block number. When transitioning between validator selection modes (contract → block header or vice versa), the wrong mode's rules were used.
- **Model-checkable**: Yes — model validator set as height-dependent, verify all paths use same set

### 3.4 Timer and Round Change Bugs (Historical)

#### Issue #2095: Round change sent before block period
- **Status**: Closed, fixed by PR #2112 (commit `8827603c77`)
- **Root cause**: Round-change timer started immediately at new height, before block period elapsed. If request timeout < block period, round changes triggered before any proposer could create a block.
- **Model-checkable**: Yes — timer ordering invariant

#### Issue #1822: f+1 round change quorum missing for 3.5 years
- **Status**: Closed, fixed by PR #7838 (commit `81e1ab9bf4`)
- **Root cause**: The QBFT specification requires f+1 round change messages to trigger a jump to a higher round. Besu only implemented the 2f+1 standard path until late 2024.
- **Model-checkable**: Yes — liveness property under round synchronization

### 3.5 Confirmed Bugs Excluded from Bug Families

| Issue | Why Excluded |
|-------|-------------|
| #5842 (Shanghai validation) | EVM fork-specific, not consensus protocol logic |
| #9644 (zero address beneficiary) | Block creator logic, not consensus protocol |
| #2109, #2134, #2145 (encoding) | Serialization interop, not protocol logic |
| #9681 (time-based transitions) | Fork schedule config issue, not consensus logic |
| #7589 (tx pool stuck) | Transaction pool implementation, not consensus |
| #9040 (world state unavailable) | Storage layer, not consensus protocol |

---

## 4. Phase 3: Deep Analysis Findings

### 4.1 QbftRound.java Findings

**Finding R-1 (HIGH): Block import failure + committed latch = no retry**
- Location: `QbftRound.java:350-383`, `RoundState.java:141`
- The `committed` flag is a one-way latch (`committed = commitMessages.size() >= quorum && proposalMessage.isPresent()`). Once set, `importBlockToChain()` cannot be re-triggered even if import fails.
- Impact: Transient storage failures cause the node to be stuck for the remainder of the round.
- Compensating mechanism: Round timer eventually expires, triggering a new round. Other nodes may import successfully.

**Finding R-2 (MEDIUM): Commit seal creation failure loses local commit vote**
- Location: `QbftRound.java:292-295`, `307-314`
- If `createCommitSeal()` throws `SecurityModuleException`, the method returns `true` (proposal accepted) but the local commit message is never added to `roundState.commitMessages`. The node loses its own vote toward commit quorum.
- Compensating mechanism: `peerIsPrepared()` at line 333 retries `createCommitSeal()`. If the retry succeeds, the commit is multicast. But the local commit is still not in `roundState`.

**Finding R-3 (LOW): Non-atomic propose-then-update-local-state**
- Location: `QbftRound.java:208-215`
- Proposal is multicast (line 208-213) before local state is updated (line 214). Crash between these steps means the network has a proposal the local node doesn't know about.
- Assessment: Inherent to in-memory protocol. Recovery via round changes.

### 4.2 QbftBlockHeightManager.java Findings

**Finding H-1 (MEDIUM): Empty block handling resets currentRound to empty**
- Location: `QbftBlockHeightManager.java:226-236`
- When an empty block's period hasn't expired, the round timer is canceled and `currentRound = Optional.empty()`. During this window:
  - Incoming messages are treated as FUTURE_ROUND and buffered
  - Early RC path can recreate round 0, potentially conflicting with the pending empty block timer
- Assessment: The block timer check at line 165 (`currentRound.isPresent()` returns early) prevents double-round creation. Minor inefficiency, not a correctness bug.

**Finding H-2 (MEDIUM): doRoundChange() synchronized but potential for deep call stack**
- Location: `QbftBlockHeightManager.java:284-320`
- `doRoundChange()` calls `handleRoundChangePayload()` (line 314), which can call `doRoundChange()` again via the f+1 early RC path. Java's re-entrant locks prevent deadlock, and the guard at line 286-289 prevents infinite recursion.
- Assessment: Correct but call stack could grow proportionally to round jumps.

**Finding H-3 (LOW): Dead code in non-early-RC path**
- Location: `QbftBlockHeightManager.java:412-414`
- The `currentRound.isEmpty()` check and `startNewRound(0)` fallback appear unreachable when early RC is disabled.
- Assessment: Defensive code, harmless.

### 4.3 RoundChangeManager.java Findings

**Finding RC-1 (MEDIUM): roundSummary vs roundChangeCache inconsistency**
- Location: `RoundChangeManager.java:156` (put) vs `RoundChangeManager.java:70` (putIfAbsent)
- `roundSummary` uses `put()` — a validator's latest round change overwrites previous entries.
- `roundChangeCache` uses `putIfAbsent()` — only the first message per validator per round is stored.
- A validator that sends RC for round 5 then round 3 will show round 3 in `roundSummary` but still count toward round 5 quorum in `roundChangeCache`.
- Impact on f+1: `futureRCQuorumReceived()` uses `roundSummary`, so it sees the "latest" round per validator. If a validator regresses (sends a lower round), the summary would show the lower round.

**Finding RC-2 (LOW): roundSummary never cleaned by discardRoundsPriorTo()**
- Location: `RoundChangeManager.java:249-251`
- `discardRoundsPriorTo()` only removes entries from `roundChangeCache`, not `roundSummary`.
- Impact: Stale entries in `roundSummary` with old round numbers. The `isAFutureRound` filter in `futureRCQuorumReceived()` excludes them, so no incorrect behavior — just memory growth.

**Finding RC-3 (LOW): actioned flag prevents certificate re-creation**
- Location: `RoundChangeManager.java:52,69,90`
- Once `createRoundChangeCertificate()` is called, `actioned = true` and no further messages are accepted for that round. If the proposal created from the certificate fails for any reason, no retry is possible from the same `RoundChangeStatus`.
- Compensating mechanism: The protocol will eventually time out and advance to a new round where a new certificate can be formed.

### 4.4 RoundChangeArtifacts.java Findings

**Finding RA-1 (LOW): Comparator violates antisymmetric contract**
- Location: `RoundChangeArtifacts.java:72-85`
- When both operands have empty `PreparedRoundMetadata`, the comparator returns `-1` for both `compare(a,b)` and `compare(b,a)`, violating the `Comparator` contract.
- Assessment: No practical impact because `Stream.max()` uses a fold-based approach and the result is discarded by the subsequent `flatMap` when no blocks exist. But technically incorrect.

**Finding RA-2 (LOW): No fallback to lower prepared round if highest lacks block**
- Location: `RoundChangeArtifacts.java:88-90`
- If the round change with the highest prepared round has no block (should not happen for a validly formed message), `flatMap` returns `Optional.empty()` without falling back to the next-highest.
- Assessment: Mitigated by `RoundChangeMessageValidator` which rejects messages with metadata but no block.

### 4.5 ProposalValidator.java Findings

**Finding PV-1 (INFORMATIONAL): Proposal validation is correct**
- The complete validation of proposals (round 0 and non-zero) was verified line by line.
- Non-zero round proposals correctly: check 2f+1 round changes, select highest prepared round, reconstruct block hash with old round + old proposer, validate piggybacked prepares, check metadata consistency.
- The QBFT paper's requirement that "the proposer must propose the block from the highest prepared certificate" is correctly enforced via hash comparison at `ProposalValidator.java:183`.

**Finding PV-2 (LOW): Different "best prepared" filter on proposer vs validator side**
- Location: `RoundChangeArtifacts.java:90` checks `getProposedBlock()` (block presence), while `ProposalValidator.java:304` checks `getPreparedRoundMetadata()` (metadata presence)
- Assessment: Equivalent in practice because `RoundChangeMessageValidator` enforces that metadata present ↔ block present for valid messages.

### 4.6 QbftController.java / BaseBftController.java Findings

**Finding C-1 (MODERATE): Block timer expiry lacks blockchain-head guard**
- Location: `QbftController.java:261-271` vs `276-289`
- Round expiry checks both `blockchain.getChainHeadBlockNumber()` AND `heightManager.getChainHeight()`.
- Block timer expiry only checks `heightManager.getChainHeight()` via `isMsgForCurrentHeight()`.
- Assessment: Lower risk than round expiry (block timer only triggers proposal creation, not state changes), but the asymmetry is notable.

**Finding C-2 (MODERATE): Future messages buffered without validator check**
- Location: `QbftController.java:305-307`
- Any message targeting a future height is buffered regardless of sender identity.
- Impact: A non-validator peer could fill the buffer with garbage, evicting legitimate future messages.

**Finding C-3 (INFORMATIONAL): Gossip before content validation**
- Location: `QbftController.java:221-223`
- Messages are gossiped after the controller-level check (height, known validator) but before the height manager's content validation.
- Assessment: Invalid messages (invalid block, wrong round) are propagated but harmlessly rejected by receiving nodes.

**Finding C-4 (INFORMATIONAL): TOCTOU in validator set check**
- Location: `QbftController.java:303` + `295-297`
- `processMessage()` checks `finalState.getValidators()` which may reflect the new chain head, while the height manager was created for the old height.
- Assessment: The window is small (between block import and NEW_CHAIN_HEAD processing). In practice, validator set changes are rare and the single-threaded event loop limits the race.

---

## 5. Bug Family Summary

| Family | Name | Severity | Historical | New Findings | Model-Checkable? |
|--------|------|----------|------------|-------------|-----------------|
| 1 | Proposal Re-Proposal Hash Mismatch | Critical | 6 issues, 2 commits | PV-2 | Yes |
| 2 | Event Queue Timer Race | Critical | 2 issues, 1 commit | C-1, R-1 | Yes |
| 3 | Round Change Quorum/Certificate | High | 2 issues, 2 commits | RC-1, RC-2, RC-3, RA-1, RA-2 | Yes |
| 4 | Validator Set Transitions | High | 3 issues, 3 commits | C-2, C-4 | Yes |
| 5 | Block Import Failure + Latch | Medium | 1 issue | R-1, R-2 | Yes |
| 6 | Empty Block Timer Interaction | Medium | 3 issues | H-1 | Partially |

---

## 6. Reference Deviation Analysis

### QBFT vs IBFT (within Besu)

| Feature | QBFT | IBFT2 | Implication |
|---------|------|-------|-------------|
| Prepare quorum | `ceil(2n/3)` | `ceil(2n/3) - 1` | QBFT requires proposer to also send PREPARE |
| Round in block hash | Yes (in extra data) | Yes (in extra data) | Both have re-proposal hash complexity |
| f+1 early round change | Optional (experimental) | No | QBFT has additional round-change path |
| Block persistence | Committed only (since PR #7204) | Committed only (since PR #7631) | Both fixed same issue |

### QBFT Paper vs Besu Implementation

| Paper Requirement | Implementation | Assessment |
|------------------|---------------|------------|
| 2f+1 round changes for non-zero round proposal | `ProposalValidator.java:229` checks `hasSufficientEntries(roundChanges, quorumMessageCount)` | Correct |
| Propose block from highest prepared certificate | `ProposalValidator.java:151-206` selects max prepared round, verifies hash match | Correct |
| f+1 future round changes trigger round jump | `RoundChangeManager.futureRCQuorumReceived()` at line 180-204 | Correct (experimental flag) |
| Prepared = proposal + 2f+1 prepares | `RoundState.java:140` — `prepared = (prepareMessages.size() >= quorum) && proposalMessage.isPresent()` | Correct (note: QBFT uses full quorum, not quorum-1) |

---

## 7. TODO/FIXME/HACK Comments Found

| File | Line | Comment | Significance |
|------|------|---------|-------------|
| QbftRoundFactory.java | 100 | `// TODO(tmm): Why is this created everytime?!` | Questions why `QbftMessageTransmitter` is created per round |
| BlockTimer.java | 99-101 | Test-mode warning for millisecond block periods | Experimental feature, not production |
| BftMiningCoordinator.java | 242-249 | "One-off block creation has not been implemented" | `createBlock` methods return empty |
