# CR-2 Investigation

## Code Audit

Finding source: Code Review. The finding has no model-checking counterexample.

Relevant implementation facts:

- `README.md:50-70` defines the public owner contract: owners step `Replica` with `on_message`, step `Client` with `on_reply`/`on_idle`, drain outputs, provide transport, and persist only `view_number` before delivered outputs.
- `lib.rs:32-34` requires distinct client identities and a new identity after restart. `lib.rs:283-286` documents that a client sends one request at a time and waits for the reply.
- `lib.rs:666-715` handles client `Request` messages on the primary. Requests below the latest request number for a client are dropped; an equal request number is answered from `client_table` only if a cached reply exists; a larger request appends a log entry and records the client request as pending.
- `lib.rs:760-789` commits through `PrepareOk` quorum and calls `commit_up_to(..., true)`, so normal-primary commitment emits a reply.
- `lib.rs:1065-1102` starts a new view from a quorum of `DoViewChange` state and calls `commit_up_to(..., true)`, so the new primary emits replies for committed entries it has not yet executed.
- `lib.rs:1181-1228` accepts recovery only after a quorum of `RecoveryResponse`s including the primary for the latest view, installs the primary log, and calls `commit_up_to(..., false)`, so recovery reconstructs application state and cached client-table replies without emitting client replies during recovery.
- `lib.rs:1330-1367` appends log entries and rebuilds the client table from an installed log. `lib.rs:1380-1410` applies committed entries in log order and caches the result only if that entry remains the latest request for that client.
- `simulator/state_machine.rs:26-33` gives each simulator operation a unique id. `simulator/properties.rs:250-285` checks no committed duplicate op id per replica, and `simulator/properties.rs:291-362` checks replies match committed requests and final committed requests receive replies.
- `examples/kvstore/main.rs:444-472` serves one client command at a time by waiting for the response channel before reading the next command. `examples/kvstore/main.rs:528-539` only forwards a reply to the waiting command if `Client::on_reply` accepts the request number. `examples/kvstore/main.rs:683-701` recovers with `Store::default()`.

Reachability assessment:

- Under the documented client discipline, the primary can have at most one outstanding request per client. The client table only needs to cache the latest request for each client because a correct client cannot need an older lost reply after it has issued a later request.
- Recovery replay through `Replica::recover(..., StateMachine::default(), persisted_view, fresh_nonce)` is reachable through the public API and is required because only the view number is durable. The recovered replica replays the committed log into a fresh application state machine and caches the latest reply for each client; it does not emit recovery replies.
- A suspicious stale-cache case requires either reusing a client identity after restart or issuing a later request before the earlier request is answered. Those states are outside the public contract cited above. The shipped example separately tries to generate restart-distinct client ids and processes one command at a time.

Trigger scenario carried to reproduction:

1. A correct client submits request 0, the primary commits it, and the network loses the client reply. The client resends request 0; the primary should answer from the cached reply without reapplying the operation.
2. The same committed request is present in the cluster, a backup reboots with no memory and recovers from the primary's log. Recovery should reconstruct application state and the cached reply but should not emit a client reply during recovery.
3. The old primary is then unavailable, the recovered backup becomes the new primary via view change, and the still-pending client resends request 0. The new primary should answer from its reconstructed cached reply, with the same result and without reapplying the operation.

Safeguards / masks to test:

- The documented client contract is the primary guard against needing non-latest cached replies.
- `Client::on_idle` resends a pending request to all replicas; backups ignore requests, and the current primary answers duplicates from the cache.
- Recovery replay uses a fresh state machine in the documented path and suppresses client replies during recovery; later duplicate requests are answered only after the replica is normal and primary.

## Developer Knowledge Search

Local comments and docs:

- `lib.rs:32-34` explicitly warns that client id reuse after restart makes the primary's client table misclassify a new request as an old resend.
- `lib.rs:283-286` explicitly states the one-request-at-a-time client discipline.
- `README.md:69-72` states that only `view_number` persists across crash recovery, so log/application reconstruction is expected.
- `README.md:179-182` describes simulator safety checks for committed-prefix agreement, committed-operation durability, reply/commit matching, and no double execution.

Local tests:

- `tests/cluster.rs:405-431` tests duplicate delivery of the same request: one execution before commit, then a cached reply for a duplicate after commit.
- `tests/cluster.rs:460-527` tests a view change after primary crash and checks that the new primary replies for the recovered committed operation.
- `tests/cluster.rs:570-620` tests reboot recovery with `Accumulator::default()`, confirms the recovering replica ignores normal work until recovered, catches up to the committed state, and later participates in new commits.

Git history / blame:

- `git blame` shows the request/client-table, recovery, install-log, and commit paths came from the initial implementation, with view-change naming cleanup at commit `3ac0104a` and trace-only local uncommitted instrumentation around `commit_op`.
- `git log --grep='client|reply|recover|view|duplicate|request|table|commit' --regexp-ignore-case` found commits for simulator, duplicate-message handling, kvstore example, Lean/conformance work, and a known liveness/backoff fix, but no commit message reporting the CR-2 mechanism as a defect.

Upstream issue / PR search:

- `gh issue list --repo penberg/vsr-rs --state all --limit 100` found issues #1, #4, #5, #7, #8, and #9. Issue #9 reports kvstore connection backoff, disconnect cleanup, and example client-id reuse; it does not report recovery replay or library cached-reply reconstruction at the CR-2 sites.
- `gh pr list --repo penberg/vsr-rs --state all --limit 100` found PRs #2, #3, #6, and #10. PR #10 is open and explicitly fixes #9 items (1) and (2), leaving the example client-id issue alone; it does not report or fix the CR-2 recovery/client-table mechanism.
- Targeted searches for `client table`, `recovery reply`, `duplicate request`, and `request identity` over open and closed issues/PRs found no exact report of this mechanism. Only #9 matched `client table`, at the example client-id-generation site.

Known-status result:

- Novelty for the CR-2 mechanism is `NEW`: upstream tracker and local git history search did not find an existing issue/PR/CVE/advisory reporting the same recovery/client-table/reply-reconstruction mechanism at the library sites. Issue #9 is related identity background, not the same defect at the same site.
