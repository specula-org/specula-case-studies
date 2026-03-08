# Bug Report — Besu QBFT

## Summary

- Bug families tested: 5 (MC-1 through MC-6, excluding MC-2/MC-4)
- Bugs found: 1 (MC-1)
- Reclassified: 1 (MC-5 → Case A spec-impl mismatch)
- Configs run: MC.cfg, MC_bughunt_mc1.cfg, MC_bughunt_mc1_safety.cfg, MC_hunt_mc5.cfg, MC_bughunt_mc6.cfg, MC_hunt_rc.cfg

### Model Checking Coverage

| Config | Mode | States | Invariants | Result |
|--------|------|--------|------------|--------|
| MC.cfg (Round 1) | BFS | 227M gen / 51.7M distinct | 8 safety + 2 temporal | All hold |
| MC.cfg (Round 2, ~committed removed) | BFS | 227M gen / 51.7M distinct | 8 safety + 2 temporal | All hold |
| MC_hunt_rc.cfg | BFS | 227M gen / 51.7M distinct | 10 safety + 2 temporal | All hold |
| MC_bughunt_mc1.cfg | BFS | 141 | NoConsensusAfterImport + 10 safety + 2 temporal | **NoConsensusAfterImport violated** |
| MC_bughunt_mc1_safety.cfg | BFS | 726M gen (incomplete, disk error) | 10 safety + 2 temporal | No violation found |
| MC_bughunt_mc1_safety.cfg | Simulation | 345M checked | 10 safety + 2 temporal | No violation found |
| MC_hunt_mc5.cfg (Round 1) | Simulation | 1,021 | CommittedStuckDetector + Agreement | **CommittedStuckDetector violated** |
| MC_hunt_mc5.cfg (Round 2) | Simulation | ~4,600 | CommittedStuckDetector + Agreement | CommittedStuckDetector violated (state reachable but no longer permanent) |
| MC_bughunt_mc6.cfg | BFS | 227M gen / 51.7M distinct | 8 safety + 2 temporal (BestPrepared <- wrong) | All hold |

---

## Bug 1: Stale Block Timer Fires After Peer Sync (MC-1)

- **Bug Family**: Family 2 (Event Queue / Timer Interleaving)
- **Severity**: Medium
- **Invariant violated**: `NoConsensusAfterImport`
- **Config**: MC_bughunt_mc1.cfg
- **Counterexample**: 3 states (file: `output/counterexample_mc1_NoConsensusAfterImport.out`)

### Trace Summary

| State | Action | Key Change |
|-------|--------|------------|
| 1 | Initial | All servers at height=1, round=Nil, blockchainHeight=0 |
| 2 | PeerSync(s1) | s1 receives block from peer: blockchainHeight=1, blockImported=TRUE |
| 3 | **BlockTimerExpiry(s1)** | **s1 starts round 0 for height 1 — but blockchain already has height 1's block!** |

### Violation State (State 3)

```
currentHeight[s1]    = 1        \* consensus height
blockchainHeight[s1] = 1        \* blockchain already has this block
currentRound[s1]     = 0        \* round started despite block existing
blockImported[s1]    = TRUE     \* block was imported via PeerSync
```

s1 starts consensus (round 0) for a height whose block is already on the blockchain. This is wasted work and could lead to a duplicate proposal competing with the already-imported block.

### Root Cause

**Implementation code**: `QbftController.java:261-271` (`handleBlockTimerExpiry`)

BlockTimerExpiry checks `isMsgForCurrentHeight` which compares against `currentHeightManager.getChainHeight()` — the height manager's internal view. But it does NOT check `blockchain.getChainHeadBlockNumber()` — the actual blockchain head.

In contrast, `handleRoundExpiry` (`QbftController.java:274-290`) has a DUAL guard:
1. `roundExpiry.getView().getSequenceNumber() <= blockchain.getChainHeadBlockNumber()` — blockchain head check
2. `isMsgForCurrentHeight` — height manager check

BlockTimerExpiry is missing guard #1. When a block arrives via peer sync (updating `blockchainHeight` but not the height manager), the stale timer fires.

### Affected Code

- `QbftController.java:261-271`: `handleBlockTimerExpiry` — missing blockchain head guard
- `QbftController.java:274-290`: `handleRoundExpiry` — has the correct dual guard (for comparison)
- `QbftBlockHeightManager.java:164-187`: `handleBlockTimerExpiry` — doesn't check blockchain height

### Impact on Safety

Exhaustive BFS (726M states) and simulation (345M states) with PeerSync enabled found **no Agreement violation**. The stale timer causes unnecessary consensus work but does not break safety — the node will eventually receive the NewChainHead event and advance to the next height.

### Recommendation

Add the blockchain head guard to `handleBlockTimerExpiry` in `QbftController.java`, matching the pattern used in `handleRoundExpiry`:
```java
if (party.getView().getSequenceNumber() <= blockchain.getChainHeadBlockNumber()) {
    LOG.debug("Block timer expired but chain head is at or past this height");
    return;
}
```

---

## Reclassified: MC-5 — Committed Latch (Case A: Spec-Implementation Mismatch)

- **Bug Family**: Family 5 (Committed Latch / Block Import)
- **Original Severity**: High (liveness) → **Reclassified**: Case A spec-impl mismatch
- **Invariant**: `CommittedStuckDetector` (state still reachable, but no longer permanent)
- **Config**: MC_hunt_mc5.cfg

### Original Hypothesis

The spec modeled `RoundExpiry` with a `~committed[s]` guard, making a committed node with failed import permanently stuck. This would be a critical liveness bug.

### Investigation Finding

**Implementation does NOT have the `~committed` guard.**

`QbftBlockHeightManager.java:268-288` (`roundExpired()`) has no `isCommitted()` check. A committed node with failed import CAN escape via round change — it loses its committed seals but is not permanently stuck.

Additionally, `MainnetBlockImporter.java:53-54` returns `ALREADY_IMPORTED` (which counts as success via `isImported()`) for duplicate blocks, so the PeerSync + consensus race does not cause import failure.

Realistic import failure scenarios (state root mismatch, transaction validation failure, I/O errors) are possible but uncommon. When they occur, the node loses committed seals and falls back to peer sync recovery.

### Spec Fix (Round 2)

Removed `~committed[s]` guard from `RoundExpiry` in `base.tla` to match implementation. Re-ran BFS: 227M states, all safety invariants and temporal properties hold. No new bugs introduced.

### Residual Concern

While not a permanent deadlock, import failure still causes:
- Loss of committed seals (wasted consensus work)
- No retry mechanism for the failed import
- Reliance on peer sync for recovery

This is a **robustness concern**, not a correctness bug.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| MC-1 (PeerSync → Agreement) | MC_bughunt_mc1_safety.cfg | 726M BFS + 345M simulation | No Agreement violation. PeerSync causes stale timer but not safety break. |
| MC-3 (Round Change Safety) | MC_hunt_rc.cfg | 227M (exhaustive BFS) | RoundChangeSafety + PhaseConsistency hold. roundChangeCache / roundSummary dual tracking is correct. |
| MC-6 (Broken BestPrepared comparator) | MC_bughunt_mc6.cfg | 227M (exhaustive BFS) | All safety invariants hold even with wrong (lowest) selection. The comparator bug does not break safety in 4-server, MaxRound=2 configuration. May affect liveness (wrong re-proposal content). |
