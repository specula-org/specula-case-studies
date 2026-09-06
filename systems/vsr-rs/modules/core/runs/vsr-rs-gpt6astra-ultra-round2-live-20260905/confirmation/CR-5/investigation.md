# CR-5 Investigation

## Code Audit

- Source: Code Review. There is no supplied model-checking counterexample for this finding.
- Checked source revision: `3ac0104a567092139534c9022205d02281a2da41`.
- The source worktree was dirty before this confirmation turn (`Cargo.toml`, `lib.rs`, untracked `tla_trace/`); the relevant recovery code in `examples/kvstore/main.rs` is unchanged by that local diff. The dirty `lib.rs` changes are trace-harness instrumentation around public calls, not recovery nonce logic.
- `examples/kvstore/main.rs:683-699` reads `kvstore-node-N.view`; if present and parseable, it computes `nonce` with `SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_nanos() as u64).unwrap_or(0)` and calls `Replica::recover(args.id, config.clone(), Store::default(), view, nonce)`.
- `lib.rs:519-537` documents the library-side requirement: the recovery nonce "must differ from that of any earlier recovery of this replica" so late responses are not mistaken for the current recovery.
- `lib.rs:1175-1221` accepts a `RecoveryResponse` only while `Status::Recovering` and only when `nonce == self.recovery_nonce`; after a quorum including the latest-view primary's state, it installs that state and enters normal status. There is no additional epoch or freshness check.
- The kvstore peer wire format serializes recovery messages as plain text: `RECOVERY {replica_id} {nonce} {view_number}` and `RECOVERYRESPONSE {view_number} {nonce} {replica_id} ...` at `examples/kvstore/main.rs:166-182`, decoded at `examples/kvstore/main.rs:294-315`.
- The example transport accepts every decoded peer line and enqueues it as an event (`examples/kvstore/main.rs:397-410`). It has no per-process epoch, connection generation, or source binding that would let `Replica` distinguish a delayed old response from a current response if the nonce repeats.
- Normal call chain: kvstore startup with a valid view file -> wall-clock nonce generation -> `Replica::recover` -> recovery messages drained by `flush` -> peer responses decoded by `run_peer_acceptor` -> `replica.on_message` -> `on_recovery_response`.

## Trigger Scenario

1. Replica 1 previously persisted view 0 and starts recovery with nonce `N`.
2. Normal peers 0 and 2 answer with `RecoveryResponse` messages for nonce `N`, but those responses are delayed before delivery to replica 1.
3. Replica 1 crashes again before consuming those responses.
4. While replica 1 is down, primary 0 commits more operations with replica 2.
5. Replica 1 restarts and the kvstore example again supplies nonce `N` because the wall-clock token source is not a durable monotonic recovery counter.
6. The delayed responses from step 2 arrive. They pass the library nonce check and can make replica 1 leave recovery with the earlier primary state.

Observed safeguard to test in Phase 2: once replica 1 is back in normal status as a stale backup, the next current primary `Commit` whose `commit_number` is beyond its log triggers `state_transfer()` at `lib.rs:792-800`; `NewState` then appends the missing suffix and catches the backup up at `lib.rs:856-909`.

## Developer Knowledge / Known Status

- Upstream issue search checked all current issues and PRs in `penberg/vsr-rs`, including recently active PRs.
- Issue #9 (`https://github.com/penberg/vsr-rs/issues/9`) reports three kvstore issues: sender reconnect backoff, missing disconnect cleanup, and client ID reuse from second-granularity startup time. It does not report recovery nonces or stale `RecoveryResponse` acceptance.
- PR #10 (`https://github.com/penberg/vsr-rs/pull/10`) is open and says it fixes issue #9 items (1) and (2), explicitly leaving the client ID issue aside. Its diff only changes `run_sender` backoff and `run_client_connection` cleanup. Its comments discuss the sender backoff. It does not mention recovery nonce freshness.
- `gh search issues --repo penberg/vsr-rs 'nonce recovery recover SystemTime as_nanos RECOVERYRESPONSE'` over open and closed issues/PRs returned no matches.
- Local git history/blame shows the recovery contract dates to the initial commit (`716c5bf`) and the kvstore nonce generation was introduced by `b97ffdd` ("Add key-value store example"). `git log --grep` for recovery/nonce/SystemTime/client/kvstore found no commit message indicating a recovery-nonce fix or accepted limitation.

Known-status conclusion for Phase 2: not a duplicate of an already reported upstream issue or PR. Novelty is `NEW` for this exact mechanism.
