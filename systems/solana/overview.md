# Solana

## Scope

Specula analyzed and tested Solana's Tower BFT consensus and its migration to Alpenglow, including vote lockouts, fork switching, optimistic confirmation, tower recovery after crashes, migration-phase transitions, genesis voting and certification, and protocol coexistence.

## Bugs

Specula found 8 previously known bugs:

- **Open:** Vote broadcast can outpace durable tower storage because the tower file is not fsynced, allowing a power-loss recovery to vote again across the crash window.
- **Open:** The switch-threshold calculation can count gossip-only votes that are absent from replay state, allowing Byzantine gossip to influence fork switching.
- **Open:** Optimistic-confirmation notifications carry only a slot and drop the voted hash, so RPC can promote a bank that differs from the hash confirmed by the cluster.
- **Open:** Receive-side vote accumulators accept lockout-violating gossip votes without checking the sender's tower, crediting Byzantine votes toward thresholds.
- **Fixed:** Crossing the duplicate threshold for two different hashes at one slot triggers an assertion and halts the validator.
- **Fixed:** Purging an unconfirmed slot clears fork-choice state without clearing the tower, which can strand tower state and require the freebie-vote workaround.
- **Fixed:** Adopting on-chain vote state historically updated `vote_state` without updating `last_vote`, splitting the tower's two views of its latest vote (Issue #32944).
- **Open:** When the last-vote ancestor set is empty, the switching-proof path can count same-fork gossip votes without locked-out evidence.
