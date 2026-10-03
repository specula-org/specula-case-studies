# CR-2 investigation

## Scope and source

- Finding source: Code Review. No model-checking violation or counterexample was supplied.
- Checkout: `d5da3a0f168c532fa348edda44427649b422139e` (2025-11-23).
- Cited sites inspected: `openraft/src/core/raft_core.rs:1812-1980`, `openraft/src/engine/command.rs:30-269`, `openraft/src/engine/engine_impl.rs:662-712`, and the storage/state-machine contracts they call.

## Step 1: code audit

### Call chains and atomicity boundaries

1. Follower RPC response:
   `Raft::append_entries()` -> `ProtocolApi::append_entries()` -> `RaftCore::handle_append_entries_request()` (`raft_core.rs:1285-1296`) -> `Engine::handle_append_entries()` (`engine_impl.rs:418-454`) -> `FollowingHandler::append_entries()` -> `Command::AppendEntries` -> `RaftCore::run_command()` (`raft_core.rs:1837-1863`). The engine creates `Command::Respond { when: IOFlushed(accepted_log_io), ... }` at `engine_impl.rs:440-451`. If the callback has not advanced `log_progress.flushed`, `run_command()` returns the response command for postponement (`raft_core.rs:1815-1824`), `EngineOutput::postpone_command()` moves it into `pending_responds.on_log_io` (`engine_output.rs:42-74`), and only `send_satisfied_responds()` sends it after the condition is met (`raft_core.rs:970-993`).
2. Vote RPC response:
   `Raft::vote()` -> `ProtocolApi::vote()` -> `RaftCore::handle_vote_request()` (`raft_core.rs:1271-1282`). The response waits for `IOFlushed(IOId::new(current_vote))`. `Command::SaveVote` awaits `RaftLogStorage::save_vote()` before posting `Notification::LocalIO` (`raft_core.rs:1864-1887`), and the storage contract says the vote must be on disk before that method returns (`raft_log_storage.rs:57-62`).
3. Client response:
   `Raft::client_write()` -> `AppApi::client_write()` (`raft/api/app.rs:46-59`) -> `RaftCore::write_entry()` (`raft_core.rs:484-523`) -> leader append/replication -> quorum progress -> `RaftState::update_local_committed()` -> progress-driven `SaveCommittedAndApply` (`engine_impl.rs:662-712`) -> `RaftCore::apply_to_state_machine()` (`raft_core.rs:797-838`) -> `RaftStateMachine::apply()`. The responder is drained into the apply command and its externally visible completion is sent by `ApplyResponder::send()` only from the state-machine implementation (`storage/v2/apply_responder.rs:51-59`; memstore `stores/memstore/src/lib.rs:479-506`).
4. Durability accounting:
   `Command::AppendEntries` marks the I/O submitted before calling storage, because storage may invoke the callback before returning (`raft_core.rs:1851-1862`). `Notification::LocalIO` is the only path that advances flushed progress and, for a leader, local replication progress (`raft_core.rs:1540-1558`). A leader may nevertheless commit/apply before its own disk flush when a quorum excluding it has flushed; the code and docs distinguish cluster durability from local durability.
5. Commit/apply ordering:
   `SaveCommittedAndApply` records apply submission, awaits `save_committed()`, and only then dispatches apply (`raft_core.rs:1920-1929`). The state-machine contract permits a transient state machine and requires either persistent apply or persistent snapshots plus saved committed position (`raft_state_machine.rs:50-89`).

### Reachable trigger scenario

The suspected window is reachable without state injection:

1. A legitimate leader sends a follower an `AppendEntries` containing entry `E` and `leader_commit = E`.
2. The follower's storage makes `E` readable and returns from `append()`, but retains the `IOFlushed` callback while its disk flush is in progress.
3. The core can record local commit and dispatch state-machine apply because `E` is submitted/readable and the leader states that it is quorum-committed.
4. Before the callback, an RPC consumer waits on the public `append_entries()` future. Separately, on a leader, a public `client_write()` waits while its own entry is submitted but the local flush has not yet contributed to the single-node quorum.
5. Release the callback, or shut down the node first, and observe whether either caller receives a successful response before the promised durability boundary.

The request is legitimate: `leader_commit = E` in the same `AppendEntries` is normal Raft traffic and represents a commit already established by a quorum elsewhere. No private function or impossible peer message is required.

### Safeguards recorded for Phase 2

- Successful AppendEntries and vote replies use `Condition::IOFlushed`, and unsatisfied replies are moved to a separate pending-response queue.
- The leader's local replication `matching` position advances only from `Notification::LocalIO`, not from append submission.
- Client completion is emitted during state-machine apply after cluster commit; local leader flush is not itself the promise when another quorum has persisted the entry.
- `RaftLogStorage` requires all vote/log write I/O to be serialized (`raft_log_storage.rs:26-31`), so a test store that lets a later `save_vote()` become durable ahead of an earlier append is inadmissible.
- A shutdown drops pending responders; it does not convert them into successful acknowledgements.

## Step 2: developer-knowledge evidence

- The storage trait states: "All write-IO must be serialized" across vote and log I/O (`openraft/src/storage/v2/raft_log_storage.rs:26-31`), `save_vote()` must persist before return (`:57-62`), and append's callback means the entries are persisted (`:88-106`).
- `openraft/src/docs/data/log_pointers.md:26-35` explicitly permits `committed` to exceed the local `flushed` pointer because the durability quorum need not include the local node.
- Maintainer discussion in issue #702 states that the leader need not flush locally before commit, while a follower must wait for flush before replying: https://github.com/databendlabs/openraft/issues/702#issuecomment-1462053929.
- Maintainer closure of the transient-commit RFC says commit-before-local-flush is a core design principle and recovery is by snapshot plus log replay: https://github.com/databendlabs/openraft/issues/284#issuecomment-3690782769.
- PR #1169 introduced the non-blocking append/callback mechanism: https://github.com/databendlabs/openraft/pull/1169.
- PR #1434 made apply progress-driven once entries are submitted/readable and describes that precondition: https://github.com/databendlabs/openraft/pull/1434.
- Issue #1252 documents a different callback-ordering failure during initialization. It was closed after the reporter confirmed their store violated OpenRaft's required I/O ordering: https://github.com/databendlabs/openraft/issues/1252#issuecomment-2408643408.
- Issue #1960 and its merged fix concern a later watch-channel implementation losing a newer completion when callbacks arrive out of order, not an early client/RPC acknowledgement at this checkout: https://github.com/databendlabs/openraft/issues/1960.
- PR #1999 fixes a RocksDB example whose state-machine implementation acknowledged before its own promised persistent apply; that is an application storage-site defect, not the core response-gating mechanism cited here: https://github.com/databendlabs/openraft/pull/1999.

## Step 3: known-status and precedent

- Searches performed on 2026-09-07 over all GitHub issue/PR states, including closed and merged work: `SaveCommittedAndApply`, `IOFlushed`, `persistence ack`, `durability`, plus local `git log --all` searches over the affected files and related commits.
- Related reports found: #284, #702, #1252, #1460, #1960, PRs #1169, #1430, #1434, #1444, and #1999. None reports a successful core client or AppendEntries/Vote reply escaping before the durability promised by that reply at the cited core sites. The closest items either document the behavior as intentional, concern an invalid storage implementation, concern a later dropped-notification bug, or concern an example state machine.
- Novelty evidence: NEW for this alleged mechanism/site. This records that no prior report of the exact early-ack defect was found; it does not prejudge the Phase-2 verdict.

## Reproduction preflight

- Rust toolchain present: `rustc 1.92.0-nightly`, `cargo 1.92.0-nightly`.
- `cargo metadata --no-deps` succeeds and resolves the workspace target directory to `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/cargo-target` for this exact checkout.
- The worktree already contains scoped Specula instrumentation changes; the reproduction does not alter those files. It adds only the external reproduction source plus `tests/tests/cr2_persistence/main.rs`, a two-line Cargo discovery wrapper that makes the required external source directly rerunnable.
