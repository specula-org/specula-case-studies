# Besu

## Scope

Specula analyzed and tested Besu's QBFT module, including proposal, prepare, commit, and round-change processing, quorum formation, timer-driven events, re-proposal across rounds, and crash-state recovery.

## Bugs

Specula found 2 new bugs:

- **Fixed:** `handleBlockTimerExpiry` lacks the blockchain-head guard used by `handleRoundExpiry`, so a stale timer can trigger a redundant proposal attempt for an imported height.
- `preparedRoundComparator` returns `-1` in both directions when both operands have empty metadata, violating the comparator's antisymmetry contract.

Specula also found 1 previously known bug:

- **Fixed:** The fast-commit path can mark a round committed without marking it prepared because those states are computed independently; see Issue #1734 and PR #1575.
