# Algorand

## Scope

Specula analyzed and tested Algorand's BA* agreement core and catch-up boundary, including proposal and vote processing, stake-weighted committee thresholds, period transitions and fast recovery, dynamic timeouts, and vote persistence.

## Bugs

Specula found 2 new bugs:

- `AsyncVoteVerifier.Quit` can race with a late verification task, allowing task registration after shutdown waiting and a send to the closed `execpoolOut` channel; PR #5341 remains open.
- The `fetchRound` fork-detection branch only logs the fork and continues trying other peers instead of halting as intended.
