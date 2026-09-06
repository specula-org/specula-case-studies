# Confirmation Report — vsr-rs

## Final Result

Reproduced bugs: 3 = 3 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 1
False positives: 1
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 6
Dispositions: 6 total = 3 reproduced + 1 env-limited + 1 masked + 1 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | REPRODUCED | yes |
| 2 | CR-2 | REPRODUCED | yes |
| 3 | CR-3 | REPRODUCED | yes |
| 4 | CR-4 | ENV_LIMITED | no |
| 5 | CR-5 | MASKED | no |
| 6 | CR-6 | FALSE POSITIVE | no |

## Entry 1: Existing identity silently restarts as new

- **Finding ID**: CR-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: examples/kvstore/main.rs:687

## Description
CR-1 is confirmed. `examples/kvstore/main.rs:687-699` collapses an existing invalid/unreadable view file into the same `None` case as a missing file, starts the old replica identity with `Replica::new`, and then rewrites the view file through `persist_view`.

This bypasses the library’s intended recovery guard: `Replica::recover` starts in `Recovering` and ignores normal messages, while the fresh `Replica::new` instance is a normal view-0 participant.

## Trigger scenario
A view-0 primary keeps an uncommitted slot-1 operation X. Replicas 1 and 2 form view 1 and replica 1 commits slot-1 operation Y. Replica 1 then restarts with an existing invalid `kvstore-node-1.view`; kvstore skips recovery, restarts it as a fresh view-0 replica, and it acknowledges the old primary’s view-0 prepare for X. The old primary then commits X, so two real client replies exist for different slot-1 operations.

Prior-report search checked upstream issues and PRs, including issue #9 and PR #10; those cover kvstore connection lifecycle/client-id items, not this persisted-view parse fallback:
https://github.com/penberg/vsr-rs/issues/9
https://github.com/penberg/vsr-rs/pull/10

## Developer intent
The docs and library comments say the view number must survive crashes and be passed to `Replica::recover`; without it, a replica can forget a view change and let two views run at once (`lib.rs:14-21`, `README.md:69-70`, `examples/kvstore/README.md:38-39`). Existing tests cover correct recovery only when callers actually use `Replica::recover`.

## Reproduction result
Executed:
```bash
timeout 10m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-1_existing_identity_restarts_as_new.sh
```

Key output:
```text
view file before startup: ff 0a
kvstore process status: 124 (124 means timeout stopped the long-running server)
kvstore stdout:
node 1 of 3: replicas on 127.0.0.1:0, clients on 127.0.0.1:0, primary is node 0
view 1: primary is node 1 (this node)
view 2: primary is node 2
view file after startup: 32 0a
observed: the example accepted an existing invalid view file, skipped recovery, and rewrote it with a normal numeric view

view 0 primary has uncommitted slot 1 op X
replicas 1 and 2 formed view 1 with primary 1
new-view client reply: view=1 client=200 request=0 result=Y
replica 2 has committed slot 1 op Y in view 1
malformed-view restart selected Replica::new: previous persisted view should be 1, restarted status Normal, view 0
old-view client reply: view=0 client=100 request=0 result=X
BUG TRIGGERED: committed slot 1 differs: replica0=X, replica2=Y
control with Replica::recover(view=1): old view produced 0 replies; replica0 status ViewChange, view 1
CR-1 reproduction completed
```

Checklist:
1. Level 0 alone triggered it: **yes**.
2. Level 2/3 injection: **N/A**; no state injection or source patch was used.
3. Real consumer/caller: `Replica::drain_replies` at `lib.rs:1492-1495` releases conflicting client replies; kvstore would send them via `deliver_reply` at `examples/kvstore/main.rs:528`.
4. Permanence/masking: the committed conflict is permanent in the reproduced state; the `Replica::recover(view=1)` control prevents it, but the malformed-file startup path bypasses that guard.

## Recommendation
Treat an existing but unreadable or unparsable view file as a fatal startup error, not as first initialization. Only choose `Replica::new` when the file is definitely absent; otherwise require valid persisted view data before the old identity can release outputs.

---

## Entry 2: Accepted self-quorum never triggers commit

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:698

## Description
`Config::add_replica` accepts a one-replica configuration and `Config::quorum()` returns 1, but the singleton primary does not commit its own request after recording its self-ack. The primary records `{self}` in `on_request`, then only evaluates quorum inside `on_prepare_ok`; with no peers, no `PrepareOk` can arrive and no reply is produced.

## Trigger scenario
Create a one-member config through the public API, create `Client` and `Replica`, submit one client request, deliver the client's public `Request` to replica 0, then run normal idle/retry/drain rounds. The replica reaches `op_number == 1`, but stays at `commit_number == 0`, leaves the state machine unapplied, and produces no reply.

## Developer intent
The public README owner loop says callers deliver messages, call `on_idle`, then drain messages/replies; it does not reject or document singleton clusters as unsupported. The simulator also validates `replica_count >= 1` at `simulator/lib.rs:258-260`, while randomized runs choose 3..7.

Prior-report search covered upstream issues and recently open/closed PRs via `gh issue list`, `gh pr list`, and searches for `single replica`, `replica_count 1`, and `PrepareOk`. Nearby reports are not this mechanism: issue #4 is resend timeout, issue #9 and PR #10 are kvstore issues, and PR #2 is duplicate-message handling.

## Reproduction result
Test written and executed: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-2_singleton_self_quorum.sh`

Command:
```sh
timeout 5m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-2_singleton_self_quorum.sh
```

Output:
```text
control_three_replicas: op=1 commit=1 value=7 replies=1
singleton_config: replicas=[0] quorum=1
singleton_request: request_number=0
singleton_round_0: delivered_before_idle=1 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_1: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_2: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_3: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_4: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_5: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_6: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_round_7: delivered_before_idle=0 delivered_after_idle=1 op=1 commit=0 value=0 replies=0
singleton_final: op=1 commit=0 value=0 replies=0 no_replica_messages_left=true no_replies_left=true
BUG REPRODUCED: singleton accepts quorum=1 and records the request, but no public owner-loop step commits it or returns a reply
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes, Level 0.
2. Level 2/3 precondition: N/A.
3. Real consumer/caller observing wrong outcome: the public owner loop that drains `Replica::drain_replies` (`README.md:119-126`, `lib.rs:1492-1494`) receives no reply; the state machine is not applied despite the accepted request.
4. Permanent or masked: permanent under the public owner-loop path. `send_to_others` skips self (`lib.rs:1424-1429`), primary idle only sends to others, and client retries remain unanswered; the repro shows repeated rounds with no messages/replies left.

## Recommendation
Either reject/document singleton configurations consistently, or commit immediately after inserting the primary self-ack when `acks.len() == config.quorum()` in `on_request`.

---

## Entry 3: One blocked peer stalls all queued destinations

- **Finding ID**: CR-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: examples/kvstore/main.rs:342

## Description
`examples/kvstore/main.rs` uses one shared sender thread and one FIFO `frames` channel for all peer destinations. `run_sender` bounds `connect_timeout`, but once a `TcpStream` exists it performs blocking `write_all` calls without a write timeout at `examples/kvstore/main.rs:383-387`. A connected peer that stops draining its TCP receive buffer can therefore hold the sender thread and delay queued frames to healthy peers.

## Trigger scenario
Start the shipped three-node kvstore. Let the primary establish TCP streams to both backups. Stall one real backup process with `SIGSTOP`, then send a normal public client `SET` containing a 4 MiB single-word value to node 0. The primary blocks writing the `Prepare` frame to the stalled backup, so the `Prepare` to the healthy backup waits behind it and the client sees no reply past the 500 ms failure-detector budget.

## Developer intent
No existing upstream issue or PR reports this exact connected-write blocking mechanism. I searched open and closed issues/PRs for `kvstore`, `write_all`, `sender`, `timeout`, `blocked peer`, `stalled peer`, and `run_sender`.

Issue #9 reports reconnect backoff, client disconnect cleanup, and client-id reuse. PR #10 fixes the first two of those and leaves the connected `write_all` path without a write timeout or per-destination isolation.

## Reproduction result
Test written and executed: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-3_sender_stall.py`

Command:
```text
timeout 2m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-3_sender_stall.py
```

Output:
```text
repo=/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-3/worktree
build: cargo build --example kvstore
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.05s
peer_ports=[47183, 59013, 51567]
client_ports=[35797, 35607, 50543]
Level 0: all replicas running; 4MiB SET via node 0
level0 send_seconds=0.001 response_wait_seconds=0.324 response=b'+OK\r\n'
Level 1: SIGSTOP replica 1 so its established TCP receive side stops draining; issue the same public SET via node 0
level1 before_resume send_seconds=0.001 wait_seconds=0.800 response=b''
resume replica 1 after the 800ms no-reply observation
level1 after_resume additional_wait_seconds=6.928 total_wait_after_send_seconds=7.728 response=b'+OK\r\n'
BUG_TRIGGERED: one stalled peer delayed the client-visible commit past the 500ms failure-detector budget; the reply arrived only after the peer resumed.
node0_returncode=-15
node0_stdout_tail='node 0 of 3: replicas on 127.0.0.1:47183, clients on 127.0.0.1:35797, primary is node 0\nview 1: primary is node 1\nview 2: primary is node 2\nview 3: primary is node 0 (this node)\nview 4: primary is node 1\nview 5: primary is node 2\n'
node0_stderr_tail=''
node1_returncode=-15
node1_stdout_tail='node 1 of 3: replicas on 127.0.0.1:59013, clients on 127.0.0.1:35607, primary is node 0\nview 1: primary is node 1 (this node)\nview 2: primary is node 2\nview 3: primary is node 0\nview 4: primary is node 1 (this node)\nview 5: primary is node 2\n'
node1_stderr_tail=''
node2_returncode=-15
node2_stdout_tail='node 2 of 3: replicas on 127.0.0.1:51567, clients on 127.0.0.1:50543, primary is node 0\nview 1: primary is node 1\nview 2: primary is node 2 (this node)\nview 3: primary is node 0\nview 4: primary is node 1\nview 5: primary is node 2 (this node)\n'
node2_stderr_tail=''
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 was the healthy baseline; Level 1 triggered it with only timing/fault assistance against real kvstore processes and a public client request.
2. Level 2/3 state injection or source patch? **not used**.
3. Real consumer/caller observing wrong outcome: the kvstore client path in `examples/kvstore/main.rs:469` waits for the replicated response and `examples/kvstore/main.rs:472` writes it to the client. The test client observed no response for 800 ms, then `+OK` only after the stalled peer resumed.
4. Permanent or masked? The bad state was not masked during the observation window. The operation missed the 500 ms failure-detector budget, caused view changes, and was resolved only after the stalled peer resumed 7.728 s after send.

## Recommendation
Give each peer destination independent backpressure isolation, or set a bounded write timeout/nonblocking write path and drop/reconnect only the affected peer when its socket stops draining. A single destination’s connected write should not block delivery to other replicas.

---

## Entry 4: View file rename is released without durable directory publication

- **Finding ID**: CR-4
- **Status**: ENV_LIMITED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: examples/kvstore/main.rs:569

## Description
`persist_view` syncs the temporary view file and then renames it over `kvstore-node-N.view`, but never syncs the parent directory. The kvstore event loop treats that rename as durable by flushing replica/client outputs immediately afterward. Under a filesystem crash model where an unsynced directory entry can be lost, restart may observe the old or missing view file even though messages for the newer view were already released.

## Trigger scenario
A three-node kvstore cluster reaches view 1 after node 0 is killed. Node 1 persists `kvstore-node-1.view`, renames the temp file, and releases view-change outputs. If the host/filesystem crashes before the parent directory entry is durable, node 1 can later restart from an older/missing view file through `examples/kvstore/main.rs:687-699`.

## Developer intent
The library requires owners to persist `Replica::view_number()` after every step and before delivering outputs (`lib.rs:14-21`, `README.md:69-72`). The kvstore README says only the view number survives disk and restarted nodes recover the rest (`examples/kvstore/README.md:38-39`). I found no upstream issue/PR reporting this exact parent-directory fsync gap; issue #9 and PR #10 cover other kvstore issues.

## Reproduction result
Reproducer written and executed:

`/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-4_view_rename_dirsync.py`

Command:

```console
$ timeout 10m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-4_view_rename_dirsync.py
CR-4 reproducer: view-file rename without parent-directory fsync
=== Artifact/bootstrap preflight ===
$ git rev-parse HEAD
3ac0104a567092139534c9022205d02281a2da41
[exit 0]
$ git status --short
 M Cargo.toml
 M lib.rs
?? tla_trace/
[exit 0]
$ cargo build --example kvstore
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.02s
[exit 0]
=== Level 0: black-box three-node view change plus syscall trace ===
node1_view_reached_1=True
node1_view_file_value_after_view_change=1
rename_syscalls=2
tmp_file_fsync_syscalls=2
all_sync_syscalls=2
directory_open_syscalls=0
parent_directory_fsync_observed=False
fsync(6</home/ubuntu/tmp/cr4-l0-k6h8lp88/kvstore-node-1.view.tmp>) = 0
rename("kvstore-node-1.view.tmp", "kvstore-node-1.view") = 0
fsync(8</home/ubuntu/tmp/cr4-l0-k6h8lp88/kvstore-node-1.view.tmp>) = 0
rename("kvstore-node-1.view.tmp", "kvstore-node-1.view") = 0
level0_live_harm=not_triggered_by_normal_process_stop
=== Level 1: timing-assisted process kill immediately after view publication ===
attempt=1 reached_view1=True value_before_kill=1 value_after_kill=1 value_after_restart=1
attempt=2 reached_view1=True value_before_kill=1 value_after_kill=1 value_after_restart=1
attempt=3 reached_view1=True value_before_kill=1 value_after_kill=1 value_after_restart=1
level1_live_harm=not_triggered; process kill does not replay an unsynced directory
=== Level 2: state injection assessment ===
uid=1000
has_dev_loop_control=False
has_dev_fuse=True
has_strace=True
state_injection_performed=no
=== Level 3: timing-only source delay after flush in a temporary copy ===
level3_reached_view1=True
level3_value_before_kill=1
level3_value_after_process_kill=1
level3_value_after_restart=1
level3_live_harm=not_triggered; source delay cannot emulate power-loss journal replay
=== Final test assessment ===
mechanism_confirmed=yes: traced temp-file fsync plus rename, with no parent directory fsync
live_bad_restart_observed=no
environment_limit=requires crash-capable filesystem/block-device fault injection or real power loss between rename and directory durability
```

The syscall mechanism is confirmed, but a live stale/missing restart was not triggered because normal process termination and timing/source delays do not replay an unsynced directory. This environment lacks a crash-capable block-device setup (`/dev/loop-control` absent), so the production consequence remains environment-limited rather than reproduced live.

## Recommendation
After `rename(&tmp, path)` succeeds, open the parent directory and call `sync_all()`/`fsync` on that directory before updating `persisted` and before `flush(...)` can release outputs. Also consider documenting the required durable-write pattern for integrations that implement the library’s persisted-view obligation.

---

## Entry 5: Wall-clock recovery tokens lack guaranteed freshness

- **Finding ID**: CR-5
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: examples/kvstore/main.rs:692

## Description
The kvstore example derives the `Replica::recover` nonce from wall-clock nanoseconds, with `unwrap_or(0)` on clock error, but `lib.rs:523-524` requires the nonce to differ from every earlier recovery of the same replica. If the example reuses a recovery nonce, delayed `RecoveryResponse` messages from the prior recovery pass the library filter and can make the replica leave recovery with stale state.

This is a real recovery-token defect, but the reproduced stale state is currently masked by the normal commit/state-transfer path.

## Trigger scenario
Replica 1 begins recovery in view 0 with nonce `N`; peers 0 and 2 generate valid `RecoveryResponse` messages, but those responses are delayed. Replica 1 crashes again, peers 0 and 2 commit another operation, then replica 1 restarts and receives nonce `N` again. The delayed old responses are accepted as current responses.

## Developer intent
The library explicitly documents the freshness requirement at `lib.rs:519-524`. The kvstore startup code at `examples/kvstore/main.rs:683-699` does not persist a monotonic recovery counter and relies on `SystemTime`. Upstream duplicate search found no exact prior report: issue #9 reports sender backoff, disconnect cleanup, and client ID reuse; PR #10 addresses only issue #9 items (1) and (2). `gh search issues` for recovery/nonce/SystemTime/RECOVERYRESPONSE returned no matching open or closed issue/PR.

## Reproduction result
Repro file written and executed:
`/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-5_recovery_nonce.sh`

Output:
```text
CR-5 recovery nonce confirmation
worktree=/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-5/worktree
source_head=3ac0104a567092139534c9022205d02281a2da41
command=timeout 5m cargo test --test cr5_recovery_nonce -- --nocapture
    Updating crates.io index
     Locking 102 packages to latest compatible versions
      Adding env_logger v0.9.3 (available: v0.11.11)
      Adding rand v0.8.8 (available: v0.10.2)
      Adding rand_chacha v0.3.1 (available: v0.10.0)
      Adding ratatui v0.29.0 (available: v0.30.2)
      Adding unicode-width v0.2.0 (available: v0.2.2)
   Compiling libc v0.2.189
   Compiling memchr v2.8.3
   Compiling regex-syntax v0.8.11
   Compiling log v0.4.34
   Compiling humantime v2.4.0
   Compiling termcolor v1.4.1
   Compiling vsr-rs v0.1.0 (/home/ubuntu/tmp/tmp.ntJZrp85JX)
   Compiling aho-corasick v1.1.5
   Compiling atty v0.2.14
   Compiling regex-automata v0.4.18
   Compiling regex v1.13.1
   Compiling env_logger v0.9.3
    Finished `test` profile [unoptimized + debuginfo] target(s) in 3.09s
     Running tests/cr5_recovery_nonce.rs (target/debug/deps/cr5_recovery_nonce-6ca915e80f1e0cef)

running 1 test
Level 0: use normal public Replica/Client APIs and message delivery.
initial cluster committed Add(10) on all replicas
captured 2 stale RecoveryResponse messages for nonce 4242 before second crash
while replica 1 is down, replicas 0 and 2 commit Add(20)
fresh nonce control: stale responses are rejected and recovery continues
Level 1: delayed-message ordering already models the timing window; no source changes.
Level 2: instantiate the reachable same-nonce precondition and replay real peer responses.
same nonce fault: replica 1 left recovery with stale value=10, op_number=1, commit_number=1
mask: delivering current Commit(view=0, commit=2) to stale backup
mask: stale backup requested GetState(op_number=1)
mask: delivering NewState(start=1,end=2,commit=2)
after mask: replica 1 caught up to value=30, op_number=2, commit_number=2
Level 3: not needed; Level 2 already proves the stale-response path and the mask.
test stale_same_nonce_recovery_response_is_accepted_but_caught_up ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

The stale response path is real: `same nonce fault` shows replica 1 left recovery with stale value `10` after the cluster had committed value `30`. The live consequence is masked: the next primary `Commit(view=0, commit=2)` makes replica 1 enter state transfer, request `GetState(op_number=1)`, and catch up to value `30`.

## Recommendation
Do not derive recovery nonces from wall-clock time. Persist a per-replica monotonic recovery counter alongside the view state, increment it before each recovery, and pass that durable counter as the nonce. At minimum, remove the `unwrap_or(0)` fallback and add a regression test proving stale same-nonce `RecoveryResponse` messages cannot complete a later recovery.

---

## Entry 6: Test observers omit important state and transport histories

- **Finding ID**: CR-6
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-6/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: simulator/properties.rs:89

## Description
CR-6 is a real assurance boundary in the simulator/proof evidence, but I did not confirm it as a current bug. The simulator properties intentionally use incremental cursors and receive only post-tick state; replies are also delivered outside the simulated network. However, reproducing a live wrong outcome would require mutating private state or patching the library to introduce a hypothetical regression.

## Trigger scenario
Normal simulator execution reaches the cited observer paths through `Simulator::run` / `run_script` -> `step_run` -> `tick` -> `tick_network` -> `check_properties`. No public API sequence in the pinned source produced a state where these observer omissions caused a wrong result.

## Developer intent
The comments document the optimization: committed prefixes are assumed append-only and checked once per replica. README/Lean docs also describe these as simulator/proof/coverage boundaries, not complete proofs. Upstream issue/PR search found no exact prior report for this observer-history mechanism; issue #9 and PR #10 are kvstore-specific and not duplicates.

## Reproduction result
Executed: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/repro/test_bugCR-6_observer_coverage.sh`

```text
repo_head=3ac0104a567092139534c9022205d02281a2da41
Level 0: run the public library/simulator test suite with no failpoints or source changes
test result: ok. 16 passed; 0 failed
test result: ok. 5 passed; 0 failed
Level 0 result: public tests completed without an observable safety/liveness failure.

Level 1: run a deterministic simulator command with normal fault/timing knobs
messages: sent=293 delivered=311 lost=9 replayed=27 delayed=0
requests: sent=50 replied=50
replicas: crashes=0 restarts=0 reboots=0 core=[0, 1, 2] up=[0, 1, 2]
PASSED (281 ticks)
Level 1 result: fault/timing-assisted simulator run completed without an observable failure.

Observer-surface audit: static checks for the cited omissions
PASS: SimContext exposes tick, replicas, replies, and core, but no transport history
PASS: Property has check/finalize/on_reboot callbacks only
PASS: Committed-prefix properties skip already verified committed indices
PASS: Simulator checks properties after request/crash/heartbeat/network phases
PASS: tick_network batches delivery and has no property check inside the delivery loop
PASS: Replica replies are delivered directly to clients and appended to replies, not passed through Network::send
PASS: Snapshot exposes in-flight messages and aggregate counters, not full past transport history
PASS: MessageSummary is aggregate counters only
PASS: Retained Lean invariant branch explicitly assumes at least two replicas
PASS: Retained Lean safety theorem is still a sorry
PASS: Retained Lean liveness theorem is still a sorry
Level 2 result: no legal state injection used; exposing the suspected false-negative requires private state mutation or a hypothetical regression.
Level 3 result: no source patch used; patching library logic would create the symptom rather than reproduce a current bug.
Overall: the observer omissions are real coverage boundaries, but this test did not reproduce a current reachable wrong outcome through the public simulator/library paths.
```

## Recommendation
Do not report this as a vsr-rs protocol bug. If the maintainer wants stronger assurance, split this into concrete test-improvement tasks: add history-aware simulator observers or mutation tests for committed-prefix rewrites, model replies through the same transport layer if that is in scope, and document simulator-vs-Lean coverage boundaries.

---
