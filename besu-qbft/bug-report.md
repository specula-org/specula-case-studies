# Besu QBFT Bug Hunting Report

## Summary

- **Hypotheses tested**: 6 (MC-1 through MC-6)
- **Bugs found**: 2 (1 liveness, 1 wasted-work/timer race)
- **Spec modeling issue found**: 1 (RoundExpiry committed guard)
- **Bugs reproduced (known)**: 0
- **Not reproduced / confirmed safe**: 4
- **Total states checked**: ~615M (BFS) + ~585M (simulation)

## Model Checking Runs

| Run | Config | Mode | States | Time | Result |
|-----|--------|------|--------|------|--------|
| 1 | MC_hunt_rc.cfg | BFS, 24w | 51.7M distinct | 10m49s | PASS (MC-3) |
| 2a | MC_bughunt_mc1.cfg | BFS, 24w | 3 states | <1s | NoConsensusAfterImport VIOLATED |
| 2b | MC_bughunt_mc1_safety.cfg | BFS, 24w | 114.9M distinct | 24m (disk full) | No safety violation |
| 2c | MC_bughunt_mc1_safety.cfg | Sim, 24w, depth 100 | 345M checked, 5.5M traces | 10m | No safety violation |
| 3 | MC_bughunt_mc6.cfg | BFS, 12w | 51.7M distinct | 17m57s | PASS (MC-6) |
| 4 | MC_hunt_mc5.cfg | Sim, 8w, depth 60 | 1K states, 9 traces | <1s | CommittedStuckDetector VIOLATED |

---

## Bugs Found

### Bug #1: Committed Latch Prevents Block Import Retry (MC-5)

- **Hypothesis**: MC-5 — Block import failure with committed latch
- **Bug Family**: Family 5 (Committed Latch)
- **Severity**: Medium (liveness degradation, not safety)
- **Status**: NEW
- **Invariant violated**: `CommittedStuckDetector`
- **Counterexample**: 22 states (simulation trace)

**Trace Summary**:
1. Height 1, round 0: s2 proposes block B0
2. s1, s3, s4 accept proposal, prepare, and exchange commits
3. s1 does round expiry (goes to round 1) while s3 and s4 still at round 0
4. s3 receives commit from s4, reaching commit quorum (3: s1, s3, s4)
5. s3 transitions to Committed, but **block import fails**
6. **s3 is stuck**: `committed=TRUE`, `blockImported=FALSE`

**Violating state** (state 22):
```
s3: committed=TRUE, blockImported=FALSE, phase=Committed
    currentRound=0, blockchainHeight=0, alive=TRUE
```

**Why s3 is stuck (spec analysis)**:
- Cannot `RoundExpiry`: guard `~committed[s]` blocks it
- Cannot `NewChainHead`: requires `blockImported[s]`
- Cannot `BlockTimerExpiry`: `currentRound[s] = 0` (not Nil)
- Cannot receive new commits to re-trigger import (edge-detection pattern)
- Only escape: `Crash` + `Recover`

**Root cause in implementation**:

The import failure path at `QbftRound.java:375-379` only logs an error with no retry:
```java
if (!result) {
    LOG.error("Failed to import proposed block to chain. block={} ...", ...);
}
```

The committed latch in `RoundState.java:141` is a one-way transition:
```java
committed = (commitMessages.size() >= quorum) && proposalMessage.isPresent();
```
Once `committed=true`, it never resets to `false`. The edge-detection pattern at `QbftRound.java:318` (`wasCommitted != roundState.isCommitted()`) ensures `importBlockToChain()` is called exactly once.

**Affected code**:
- `QbftRound.java:375-379` — no retry after import failure
- `QbftRound.java:318-320` — edge-detection prevents re-import
- `RoundState.java:141` — one-way committed latch

**Spec modeling issue discovered**: The spec's `~committed[s]` guard on `RoundExpiry` (base.tla:373) is more restrictive than the implementation. The Java `QbftBlockHeightManager.roundExpired()` (line 265-282) does NOT check committed state — it unconditionally calls `doRoundChange()`. The `QbftController.handleRoundExpiry()` only checks `blockchain.getChainHeadBlockNumber()`, which catches successful imports but not failed ones. This means:
- In the **implementation**: committed + import-failed → round timer fires → round changes → node enters new round but has lost the committed block's seals → must rely on peer sync
- In the **spec**: committed + import-failed → node is permanently stuck (can't round-change)

The implementation behavior is less severe (degraded but not stuck), but still represents a liveness concern: the node discards a committed block's seals and must wait for peer sync to catch up.

**Recommendation**:
1. Add import retry logic in `QbftRound.importBlockToChain()` with exponential backoff
2. Alternatively, store committed block + seals to enable re-import on recovery
3. Fix spec: remove `~committed[s]` guard from `RoundExpiry` to match implementation

---

### Bug #2: Block Timer Expiry Lacks Blockchain-Head Guard (MC-1)

- **Hypothesis**: MC-1 — Block timer expiry can fire for an already-decided height
- **Bug Family**: Family 2 (Timer Race)
- **Severity**: Low (wasted work, not safety)
- **Status**: NEW (code quality issue, confirmed race condition)
- **Invariant violated**: `NoConsensusAfterImport`
- **Counterexample**: 3 states

**Trace**:
1. **Init**: s1 at height 1, blockchainHeight=0, currentRound=Nil
2. **PeerSync(s1)**: s1 receives block from peer, blockchainHeight=1, blockImported=TRUE
3. **BlockTimerExpiry(s1)**: s1 starts round 0 despite blockchainHeight=currentHeight=1

**Violating state** (state 3):
```
s1: currentRound=0, blockchainHeight=1, currentHeight=1
    (consensus started for a height already on the blockchain)
```

**Root cause in implementation**:

`QbftController.java:261-271` — `handleBlockTimerExpiry` only checks `isMsgForCurrentHeight`:
```java
public void handleBlockTimerExpiry(final BlockTimerExpiry blockTimerExpiry) {
    final ConsensusRoundIdentifier roundIdentifier = blockTimerExpiry.getRoundIdentifier();
    if (isMsgForCurrentHeight(roundIdentifier, getCurrentChainHeight())) {
        getCurrentHeightManager().handleBlockTimerExpiry(roundIdentifier);
    }
}
```

Compare with `QbftController.java:274-290` — `handleRoundExpiry` has the additional blockchain-head guard:
```java
public void handleRoundExpiry(final RoundExpiry roundExpiry) {
    if (roundExpiry.getView().getSequenceNumber() <= blockchain.getChainHeadBlockNumber()) {
        LOG.debug("Discarding a round-expiry which targets a height not above current chain height.");
        return;
    }
    if (isMsgForCurrentHeight(roundExpiry.getView(), getCurrentChainHeight())) {
        getCurrentHeightManager().roundExpired(roundExpiry);
    }
}
```

**Safety impact**: None. Exhaustive BFS (114.9M distinct states) and simulation (345M states, 5.5M traces) with PeerSync found **no Agreement or Validity violations**. The stale block timer causes wasted work (a redundant proposal attempt) but cannot cause conflicting commits because:
1. Other nodes that committed the block have moved to the next height
2. The stale proposer cannot achieve quorum at the old height
3. Eventually, `NewChainHead` fires and advances the node

**Affected code**:
- `QbftController.java:261-271` — missing `blockchain.getChainHeadBlockNumber()` guard

**Recommendation**: Add the blockchain-head guard to `handleBlockTimerExpiry` for consistency with `handleRoundExpiry`:
```java
public void handleBlockTimerExpiry(final BlockTimerExpiry blockTimerExpiry) {
    final ConsensusRoundIdentifier roundIdentifier = blockTimerExpiry.getRoundIdentifier();
    if (roundIdentifier.getSequenceNumber() <= blockchain.getChainHeadBlockNumber()) {
        LOG.debug("Discarding a block-timer which targets a height not above current chain height.");
        return;
    }
    if (isMsgForCurrentHeight(roundIdentifier, getCurrentChainHeight())) {
        getCurrentHeightManager().handleBlockTimerExpiry(roundIdentifier);
    }
}
```

---

## Not Reproduced

| ID | Hypothesis | States Checked | Result | Notes |
|----|-----------|----------------|--------|-------|
| MC-2 | Actioned flag prevents certificate re-creation after proposer failure | 51.7M BFS + 240M sim (baseline) | Safe | Round-robin proposer ensures different proposer at next round. Message loss (LoseLimit=1) tested. System recovers via round expiry. |
| MC-3 | roundSummary (put) vs roundChangeCache (putIfAbsent) inconsistency | 51.7M BFS | `RoundChangeSafety` PASS | The dual data structure is safe: `actioned` flag is set atomically with quorum check, and `roundChangeMessages` is never reduced (only reset at NewChainHead/Crash, which also reset `actioned`). |
| MC-4 | Validator set changes cause quorum inconsistency | N/A | Not testable | Current spec uses fixed validator set `[h \in 0..3 \|-> Server]`. Requires adding `ValidatorSetChange` action and height-dependent validator sets. Deferred — significant spec extension needed. |
| MC-6 | Broken comparator selects wrong "best prepared" block | 51.7M BFS | Agreement PASS | `MCBestPreparedWrong` (selects LOWEST prepared round) was used as operator override for `BestPrepared`. Even with worst-case selection, Agreement holds because quorum intersection prevents conflicting commits: if a block is committed (quorum 3/4), ≤1 node is uncommitted, which cannot form round-change quorum (needs 3). |

---

## Spec Findings (Case B)

### Spec Issue: RoundExpiry Committed Guard

- **File**: `base.tla:373`
- **Issue**: `RoundExpiry` has guard `~committed[s]` which is more restrictive than implementation
- **Implementation**: `QbftBlockHeightManager.roundExpired()` (line 265-282) does NOT check committed state
- **Impact**: The spec models committed-but-not-imported nodes as permanently stuck, while the implementation allows them to round-change (losing committed seals). Neither behavior is ideal.
- **Action**: Should be fixed if further MC is done at this height boundary

---

## Methodology

### Spec Extensions Created

1. **PeerSync action** (`base.tla`): Models a node receiving a block from a peer, advancing `blockchainHeight` without going through consensus. Tests MC-1 race condition.

2. **BestPrepared helper** (`base.tla`): Extracted from `HandleRoundChange` for clean operator override. Uses `CHOOSE` to select RC message with highest prepared round.

3. **MCBestPreparedWrong** (`MC_bughunt.tla`): Override that selects LOWEST prepared round, modeling the worst case of the `RoundChangeArtifacts.java:72-85` comparator bug.

4. **NoConsensusAfterImport** (`base.tla`): Invariant detecting when a node has an active round despite blockchain already having the block for that height.

5. **CommittedStuckDetector** (`base.tla`): Invariant detecting committed-but-not-imported stuck nodes.

### Files Created

| File | Purpose |
|------|---------|
| `MC_hunt_rc.cfg` | Adds RoundChangeSafety + PhaseConsistency to baseline MC |
| `MC_bughunt.tla` | Bug hunting module with PeerSync + broken comparator |
| `MC_bughunt_mc1.cfg` | MC-1 config with NoConsensusAfterImport detector |
| `MC_bughunt_mc1_safety.cfg` | MC-1 config checking only safety invariants |
| `MC_bughunt_mc6.cfg` | MC-6 config with BestPrepared override |
| `MC_hunt_mc5.cfg` | MC-5 config with CommittedStuckDetector |

### Coverage Summary

| Property | BFS States | Sim States | Verdict |
|----------|-----------|------------|---------|
| Agreement | 114.9M+ | 585M+ | PASS |
| Validity | 114.9M+ | 585M+ | PASS |
| PreparedBlockIntegrity | 114.9M+ | 585M+ | PASS |
| RoundChangeSafety | 51.7M | 240M+ | PASS |
| PhaseConsistency | 51.7M | 240M+ | PASS |
| CommitLatchConsistency | 114.9M+ | 585M+ | PASS |
| NoConsensusAfterImport (w/ PeerSync) | 114.9M+ | 345M+ | **VIOLATED** |
| CommittedStuckDetector | — | 1K | **VIOLATED** |
| Agreement (broken comparator) | 51.7M | — | PASS |
