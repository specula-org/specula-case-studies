# Sui

## Scope

Specula analyzed and tested Sui's Mysticeti DAG-BFT consensus, including block proposal and certification across rounds, leader commit rules, equivocation and amnesia recovery, garbage collection, timeout-driven progress, and Byzantine input handling.

## Bugs

Specula found 2 new bugs:

- `find_supported_block` can panic when it follows a high-round ancestor missing from `DagState`, because this path lacks the usual ancestor-presence guard.
- Threshold-clock catch-up can advance without a quorum at the new round, after which force-proposal asserts that the missing quorum exists and panics.
