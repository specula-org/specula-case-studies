### Motivation

`handleBlockTimerExpiry` (`QbftController.java:261`) only checks `isMsgForCurrentHeight` but not whether the block for that height is already on the blockchain. If a block is imported via peer sync while the block timer is pending, the timer still fires and starts a redundant proposal at the already-decided height.

`handleRoundExpiry` (same file, line 274) already has this guard:

```java
if (roundExpiry.getView().getSequenceNumber() <= blockchain.getChainHeadBlockNumber()) {
    LOG.debug("Discarding a round-expiry which targets a height not above current chain height.");
    return;
}
```

`handleBlockTimerExpiry` is missing the same check.

### Modification

Add the blockchain-head guard to `handleBlockTimerExpiry`, matching `handleRoundExpiry`.

Test: `blockTimerForAlreadyImportedHeightIsDiscarded` — sets `chainHeadBlockNumber` to the current height (simulating peer sync), verifies `handleBlockTimerExpiry` is not called on the height manager.

### Result

Prevents redundant proposal attempts at already-decided heights.
