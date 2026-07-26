# Aptos

## Scope

Specula analyzed and tested Aptos's AptosBFT and Quorum Store modules, including HotStuff/Jolteon voting and ordering, optimistic proposals, epoch and execution-pipeline transitions, batch dissemination, proof aggregation, persistence, garbage collection, and missing-batch fetching.

## Bugs

Specula found 3 new bugs:

- The two-chain vote path signs before persisting safety data, and the on-disk store lacks `fsync`, creating a crash window in which a validator can vote twice at the same round; this is associated with Issue #18298.
- `BatchRequester` repeatedly polls a closed oneshot receiver after expired-payload cleanup drops its sender, causing a busy spin or panic.
- `clean_and_get_batch_id` asserts that epochs never regress and therefore panics if persisted state contains a higher epoch than the current database state.
