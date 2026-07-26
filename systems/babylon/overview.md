# Babylon

## Scope

Specula analyzed and tested Babylon's finality, BTC staking, BTC checkpoint, and checkpointing modules, including EOTS voting, delegation and slashing lifecycles, checkpoint confirmation and reorg handling, and vote-extension aggregation.

## Bugs

Specula found 1 new bug:

- `BTCDelegation.GetStatus` does not consider whether the finality provider is slashed, so it can report a delegation under a slashed provider as active.

Specula also found 2 previously known bugs:

- **Open:** `CommitPubRandList` accepts retroactive public-randomness commitments because it does not enforce a lower bound on `StartHeight`; see Issue #1984.
- **Open:** Reactivating a finality provider does not reset its liveness bitmap or missed-block counter, allowing stale state to bypass jailing; see Issue #1852.
