# Instrumentation Spec: besu QBFT

Maps TLA+ spec actions to source code locations for trace generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO-8601 timestamp>",
  "event": {
    "name": "<spec action name>",
    "nid": "<server/validator address>",
    "state": {
      "height": <int>,
      "round": <int>,
      "phase": "<Proposing|Prepared|Committed>",
      "committed": <boolean>,
      "blockImported": <boolean>,
      "blockchainHeight": <int>
    },
    "msg": {
      "from": "<sender address>",
      "to": "<recipient address>",
      "type": "<ProposalMsg|PrepareMsg|CommitMsg|RoundChangeMsg>",
      "height": <int>,
      "round": <int>,
      "blockHash": "<hex hash>",
      "blockContent": "<block content identifier>",
      "preparedRound": <int>,
      "preparedBlock": "<block content or null>"
    }
  }
}
```

### State Fields

| Implementation Getter | TLA+ Variable | Capture Point |
|----------------------|---------------|---------------|
| `currentHeightManager.getChainHeight()` | `currentHeight` | Every event |
| `currentRound.getRoundIdentifier().getRoundNumber()` | `currentRound` | Every event (-1 if `currentRound.isEmpty()`) |
| `roundState.isPrepared()` → Prepared, `roundState.isCommitted()` → Committed | `phase` | Every event |
| `roundState.isCommitted()` | `committed` | Every event |
| `blockImporter.importBlock() result` | `blockImported` | After HandleCommit |
| `blockchain.getChainHeadBlockNumber()` | `blockchainHeight` | Every event |

### Message Fields

| Implementation Field | TLA+ Field | Notes |
|---------------------|------------|-------|
| `msg.getAuthor()` | `msource` | Sender address |
| local node address | `mdest` | Receiving node |
| `msg.getRoundIdentifier().getSequenceNumber()` | `mheight` | Block height |
| `msg.getRoundIdentifier().getRoundNumber()` | `mround` | Round number |
| `block.getHash().toHexString()` | `mblockHash` | For Proposal/Prepare/Commit |
| `roundChange.getPreparedRoundMetadata().getPreparedRound()` | `mpreparedRound` | For RoundChange |

## Section 2: Action-to-Code Mapping

### 1. BlockTimerExpiry

- **Spec action**: `BlockTimerExpiry(s)`
- **Code location**: `QbftBlockHeightManager.java:164-187`
- **Trigger point**: After `startNewRound(0)` at line 173, before `buildBlockAndMaybePropose`
- **Trace event name**: `BlockTimerExpiry`
- **Fields**: state snapshot (height, round=0, phase=Proposing)
- **Notes**:
  - Entry guard is `currentRound.isPresent()` returning false (line 165)
  - Controller guard at `QbftController.java:263` checks `isMsgForCurrentHeight`
  - Family 2: No blockchain-head guard (unlike RoundExpiry)

### 2. HandleProposal

- **Spec action**: `HandleProposal(s, m)`
- **Code locations**:
  - `QbftBlockHeightManager.java:323-339` — `handleProposalPayload()` entry
  - `QbftRound.java:224-233` — `handleProposalMessage()` processing
- **Trigger point**: After `updateStateWithProposedBlock(msg)` at QbftRound.java:230
- **Trace event name**: `HandleProposal`
- **Fields**: state + msg{from=proposal.getAuthor(), type=ProposalMsg, blockHash, round}
- **Notes**:
  - Family 1: Block hash includes round and proposer — capture both the received block hash and the reconstructed hash from `ProposalValidator.java:167-189`
  - For future-round proposals, `startNewRound()` is called first (line 336)
  - The proposer's own proposal goes through `updateStateWithProposalAndTransmit` (QbftRound.java:193-217), NOT this path — instrument separately in BlockTimerExpiry

### 3. HandlePrepare

- **Spec action**: `HandlePrepare(s, m)`
- **Code locations**:
  - `QbftBlockHeightManager.java:343-348` — `handlePreparePayload()`
  - `QbftRound.java:253-259` — `handlePrepareMessage()`
  - `QbftRound.java:326-339` — `peerIsPrepared()`
- **Trigger point**: After `roundState.addPrepareMessage(msg)` at QbftRound.java:328
- **Trace event name**: `HandlePrepare`
- **Fields**: state + msg{from, type=PrepareMsg, blockHash, round}
- **Notes**:
  - `putIfAbsent` semantics at RoundState.java:119
  - Phase transition to Prepared happens when `wasPrepared != roundState.isPrepared()` (line 329)

### 4. HandleCommit

- **Spec action**: `HandleCommit(s, m)`
- **Code locations**:
  - `QbftBlockHeightManager.java:352-357` — `handleCommitPayload()`
  - `QbftRound.java:266-272` — `handleCommitMessage()`
  - `QbftRound.java:342-348` — `peerIsCommitted()`
- **Trigger point**: After `roundState.addCommitMessage(msg)` at QbftRound.java:344
- **Trace event name**: `HandleCommit`
- **Fields**: state + msg{from, type=CommitMsg, blockHash, round}
- **Notes**:
  - Family 5: `committed` latch at RoundState.java:141
  - `importBlockToChain()` called at line 346 — capture import success/failure
  - `blockImported` field should reflect `blockImporter.importBlock()` result at QbftRound.java:373-374

### 5. RoundExpiry

- **Spec action**: `RoundExpiry(s)`
- **Code locations**:
  - `QbftController.java:274-290` — `handleRoundExpiry()`
  - `QbftBlockHeightManager.java:265-282` — `roundExpired()`
  - `QbftBlockHeightManager.java:284-320` — `doRoundChange()`
- **Trigger point**: After `doRoundChange()` at QbftBlockHeightManager.java:281
- **Trace event name**: `RoundExpiry`
- **Fields**: state snapshot with new round number
- **Notes**:
  - Family 2: Dual guard — `QbftController.java:277` checks blockchain head number, line 282 checks height manager height
  - `doRoundChange` is `synchronized` (line 284) — only one thread enters
  - Prepared certificate constructed at line 293-294

### 6. HandleRoundChange

- **Spec action**: `HandleRoundChange(s, m)`
- **Code locations**:
  - `QbftBlockHeightManager.java:378-450` — `handleRoundChangePayload()`
  - `RoundChangeManager.java:213-227` — `appendRoundChangeMessage()`
  - `RoundChangeManager.java:151-171` — `storeAndLogRoundChangeSummary()`
  - `RoundChangeManager.java:180-204` — `futureRCQuorumReceived()`
- **Trigger point**: After `roundChangeManager.appendRoundChangeMessage(message)` at line 398
- **Trace event name**: `HandleRoundChange`
- **Fields**: state + msg{from, type=RoundChangeMsg, targetRound, preparedRound, preparedBlock}
- **Notes**:
  - Family 3: Two paths — standard 2f+1 (lines 401-419) vs early f+1 (lines 420-449)
  - `roundSummary` uses `put` (overwrites) at RoundChangeManager.java:156
  - `roundChangeCache` uses `putIfAbsent` at RoundChangeManager.java:70
  - `actioned` flag at line 69 prevents re-creation of certificate
  - MC-2: Capture `actioned` flag state in trace for debugging
  - MC-3: Capture `roundSummary` contents for detecting stale data

### 7. NewChainHead

- **Spec action**: `NewChainHead(s)`
- **Code location**: `QbftController.java:228-258` — `handleNewBlockEvent()`
- **Trigger point**: After `startNewHeightManager(newBlockHeader)` at line 257
- **Trace event name**: `NewChainHead`
- **Fields**: state snapshot with new height
- **Notes**:
  - Guard checks at lines 235-256 (height comparison, duplicate detection)
  - Family 2: This event bridges the gap between blockchainHeight and heightManagerHeight

### 8. Crash

- **Spec action**: `Crash(s)`
- **Code location**: N/A — crash is detected externally
- **Trigger point**: When node stops responding / process terminates
- **Trace event name**: `Crash`
- **Fields**: nid only (no state available after crash)
- **Notes**: May need to be synthesized from missing heartbeats or process monitoring

### 9. Recover

- **Spec action**: `Recover(s)`
- **Code location**: `QbftController.java:163-173` — `start()`
- **Trigger point**: After `startNewHeightManager(blockchain.getChainHeadHeader())` at line 165
- **Trace event name**: `Recover`
- **Fields**: state snapshot with recovered height from blockchain
- **Notes**: All volatile consensus state is reset; only blockchain height persists

## Section 3: Special Considerations

### 3.1 Proposer's Own Proposal

The proposer creates and processes its own proposal within `BlockTimerExpiry` (for round 0) or `HandleRoundChange` (for round > 0). The `BlockTimerExpiry` event covers both the round creation and the proposal transmission. The proposer does NOT emit a separate `HandleProposal` event for its own block.

### 3.2 Family 1: Block Hash Reconstruction

Block identity in QBFT includes `(blockContent, roundNumber, proposerAddress)` embedded in extra data. When a prepared block is re-proposed in a higher round:
- `QbftRound.java:170-172`: `blockInterface.replaceRoundAndProposerForProposalBlock()` updates the block
- `ProposalValidator.java:167-189`: Validator reconstructs the expected hash

**Instrumentation requirement**: Capture BOTH the original prepared block hash AND the re-wrapped block hash in `HandleProposal` events for round > 0 proposals. Add fields:
- `originalBlockHash`: hash before round/proposer substitution
- `rewrittenBlockHash`: hash after substitution (should match received proposal)

### 3.3 Family 2: Event Queue Ordering

The `BftProcessor.java:67-83` event loop processes events from `BftEventQueue` in FIFO order. Timer events are enqueued asynchronously. The trace must preserve the actual processing order, not the enqueueing order.

**Instrumentation requirement**: All trace events must be emitted from within the event loop thread (the `BftProcessor.run()` loop), ensuring trace ordering matches processing ordering.

### 3.4 Family 3: Dual Data Structure Tracking

`RoundChangeManager` maintains two data structures with different semantics:
- `roundChangeCache` (line 102): `Map<ConsensusRoundIdentifier, RoundChangeStatus>` — uses `putIfAbsent` per validator
- `roundSummary` (line 105): `Map<Address, ConsensusRoundIdentifier>` — uses `put` (overwrites)

**Instrumentation requirement**: In `HandleRoundChange` events, capture:
- `rcCacheSize`: `roundChangeCache.get(targetRound).receivedMessages.size()` — message count for target round
- `summaryRound`: `roundSummary.get(msg.getAuthor()).getRoundNumber()` — latest round for sender (BEFORE update)
- `actioned`: `roundChangeCache.get(targetRound).actioned` — one-shot flag state

### 3.5 Family 5: Import Failure

`QbftRound.java:350-383` — `importBlockToChain()` can fail. The `committed` latch at `RoundState.java:141` prevents retry.

**Instrumentation requirement**: After `HandleCommit` events where `committed` transitions to true, add:
- `importResult`: result of `blockImporter.importBlock()` at line 373-374
- This is critical for verifying the committed-but-not-imported stuck state

### 3.6 Thread Safety

All consensus logic runs on the single `BftProcessor` thread. Timer callbacks only enqueue events. The `synchronized` keyword on `doRoundChange()` (QbftBlockHeightManager.java:284) is defensive.

**Instrumentation requirement**: Verify that all trace event emission happens on the BftProcessor thread. Timer thread events (BlockTimerExpiry, RoundExpiry) are emitted when the event loop processes them, not when the timer fires.

### 3.7 Serialization Quirks

- Block hash is a `Hash` (Keccak-256) — serialize as hex string
- Addresses are `Address` — serialize as hex string (lowercase, 0x-prefixed)
- `ConsensusRoundIdentifier` contains both height (sequenceNumber) and round — serialize both
- `Optional.empty()` fields should be serialized as `null` in JSON
- PreparedRound of -1 means no prepared certificate (maps to spec's -1)
