# CometBFT

## Scope

Specula analyzed and tested CometBFT's consensus, app-mempool, evidence, PBTS/ABCI++ and state-sync, MConnection transport, and remote private-validator modules, including round and ingest handling, gossip and peer lifecycle, evidence validation, timing, and signer reconnect/retry behavior.

## Bugs

Specula found 13 new bugs:

- Evidence expiration uses height in the pool but time in the gossip reactor, so height-valid evidence can be suppressed from gossip and require repeated verification.
- Future-height conflicting votes are silently discarded from the in-memory consensus buffer without persistence or retry.
- Repeated light-client attack evidence increments the pending-evidence counter without checking key existence, causing `Size()` to overcount.
- An unattributable commit-chain validation failure bans both block providers for 60 seconds, allowing a Byzantine block to cause an honest peer's collateral ban.
- `LightClientAttackEvidence.Hash()` omits the final byte of the conflicting block hash, reducing its collision resistance.
- Committing evidence uses two unbatched database writes, so a crash between deletion and committed-marker insertion can make the evidence re-acceptable.
- Proposal validation accepts `POLRound >= Round` instead of requiring `POLRound < Round`.
- File private-validator state renames its HRS watermark without syncing the parent directory, allowing power loss to roll back anti-double-sign state.
- AppReactor can advertise a receive capacity smaller than a valid singleton transaction batch when `MaxBatchBytes < MaxTxBytes`, causing peers to disconnect.
- Timed-out connection filters cannot be canceled, allowing blocked unauthenticated callbacks to accumulate after their sockets and admission slots are released.
- SignerServer exits its only service loop after exhausting dial retries while still reporting itself as running, preventing later reconnection without a restart.
- Remote private-validator sign requests may omit their vote or proposal payload, which is dereferenced and can crash the signer process.
- A stale retryable `CheckTx` completion can expire a newer seen-cache generation for the same transaction and admit a duplicate application callback.

Specula also found 5 previously known bugs:

- **Open:** During blocksync handoff, the mempool is enabled before consensus starts, creating a window in which peer-flooded `CheckTx` work reaches the application; see Issue #3398.
- **Open:** A proposer skips verifying its own vote extension, so other validators can reject its precommit and permanently deadlock consensus; see Issue #5204.
- **Open:** Late precommits from the previous height can enter `LastCommit` without application-level vote-extension verification; see Issue #2523.
- **Open:** `DoubleSignCheckHeight=1` performs no historical look-back because of an off-by-one loop bound; see Issue #5435.
- **Open:** Early catch-up block parts are silently dropped when the proposal part set is not initialized, with no buffering or re-request; see Issue #3340.
