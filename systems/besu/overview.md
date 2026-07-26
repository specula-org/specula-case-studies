# Besu

## Scope

Specula analyzed and tested Besu's QBFT module, including proposal, prepare, commit, and round-change processing, quorum formation, timer-driven events, re-proposal across rounds, and crash-state recovery.

## Bugs

Specula found 2 new bugs:

- `handleBlockTimerExpiry` lacks the blockchain-head guard used by `handleRoundExpiry`, so a stale timer can trigger a redundant proposal attempt for an imported height; the issue is fixed.
- `preparedRoundComparator` returns `-1` in both directions when both operands have empty metadata, violating the comparator's antisymmetry contract.

The bug tracker also records 1 known bug examined by Specula:

- The fast-commit path can mark a round committed without marking it prepared because those states are computed independently; Issue #1734 was fixed by PR #1575.
