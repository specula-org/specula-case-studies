# MC-7 investigation evidence

## Scope and provenance

- Source checkout: `f53422a4b5f0de372714fd309d1975ce34445633` (`master` and `origin/master` both resolve to this commit).
- Counterexample: `spec/output/MC_hunt_scenario7_retry_postfix_bfs.out`, a real TLC violation of `RetryIsolation`. State 2 executes `MCNpuHandleSwitchoverRst("n1")`, changing `sharedRetry[n1]` from 0 to 1 while `retryByProtocol[n1].Switchover` becomes 1. State 3 executes `MCNpuHandleVoteRequestFinal("n1")`, changing only `sharedRetry[n1]` back to 0 and setting `retryIsolationBroken[n1]` to `TRUE` while the protocol-specific switchover count remains 1.
- The checkout has pre-existing Specula trace instrumentation. `git diff` shows the MC-7 sites retain the production counter mutations; the additions expose test visibility and emit trace observations. The uninstrumented `HEAD` has the same `retry_count` field and mutations at original lines 52, 878-880, 936, 944-954, and 1947-1979.

## Step 1: code audit

### Relevant code

- `crates/hamgrd/src/actors/ha_scope/npu.rs:47-79` gives every NPU HA-scope actor exactly one `retry_count` field, initialized to zero.
- `npu.rs:152-171` dispatches both `VoteRequest` and `SwitchoverRequest` messages on the same actor instance.
- `npu.rs:865-948` handles an incoming vote. A final response is selected by state, term, or desired-state comparisons, and every response other than `RetryLater` unconditionally assigns `self.retry_count = 0` at lines 926-929.
- `npu.rs:986-1029` handles an incoming switchover response. Each `Rst` schedules another `Syn` and increments that same field while it is below 3; only a later `Rst` observed with the field already equal to 3 returns `HaEvent::SwitchoverFailed`.
- `npu.rs:1892-1905` is the consumer of that event: while `SwitchingToActive`, `SwitchoverFailed` transitions the HA scope back to `Standby`.
- `npu.rs:2060-2117` also increments and resets the same field for peer-connection maintenance, establishing that the field is actor-wide rather than owned by a vote or switchover operation.
- `npu.rs:2446-2485` persists the externally reported switchover lifecycle, including `in_progress`, `completed`, and `failed`, in `NpuDashHaScopeState`.
- `crates/hamgrd/src/actors/ha_scope/base.rs:125-137` only deserializes peer actor messages. `crates/hamgrd/src/ha_actor_messages.rs:320-365` and `:441-485` define valid wire-level vote and switchover messages. There is no source-peer, current-state, active-operation, or switchover-ID ownership check before either counter mutation.

### Call chain and reachability

1. A normal upstream HA-scope config changes a standby's desired state to Active and later approves its pending `switchover` operation. The existing `ha_scope_npu_planned_switchover` actor-runtime test reaches this path through the config bridge, persists `switchover_state=in_progress`, transitions to `SwitchingToActive`, and sends `SwitchoverRequest(Syn)` to the peer (`crates/hamgrd/src/actors/ha_scope/mod.rs:1555-1658`).
2. If the peer is not Active, the normal peer handler rejects that SYN with a valid `SwitchoverRequest(Rst)` (`npu.rs:1032-1041`). SWBus passes the valid actor message through `Incoming::handle_request`, `ActorDriver::handle_actor_message`, `HaScopeActor::handle_message`, and `NpuHaScopeActor::handle_message_inner` to `handle_switchover_request`. The initiator schedules a delayed SYN retry and changes the shared count 0 -> 1.
3. A reconnecting peer normally enters `Connected` and sends `VoteRequest` to start primary election, as required by `npu.rs:1446-1449` and `send_vote_request_to_peer` at `npu.rs:2136-2185`. The actor is sequential, but SWBUS messages from the two workflows may be ordered RST then VoteRequest.
4. With the initiator still `SwitchingToActive`, desired Active, and a higher term than the reconnecting peer, the vote handler returns the final `BecomeStandby` response at `npu.rs:905-912` and resets the shared field 1 -> 0 at `npu.rs:926-929`.
5. Three more valid RST responses to the resulting switchover SYN retries are then treated as retry numbers 1, 2, and 3. On the fourth rejection overall, the actor therefore schedules a fourth delayed SYN and remains `SwitchingToActive`/`in_progress`; without the unrelated reset, that rejection returns `SwitchoverFailed` and the real state-machine consumer moves the scope to `Standby`.

The trigger uses ordinary config updates and peer actor messages emitted by the real workflows. No inconsistent structure or otherwise impossible peer value is required. A peer restart/reconnect during an approved switchover naturally supplies both prerequisites: it is no longer Active and rejects the switchover, while its Connected launch workflow initiates primary election.

### Safeguards and downstream behavior recorded for reproduction

- Actor serialization prevents simultaneous mutation but does not prevent the legal RST/VoteRequest ordering.
- Neither message handler checks that its retry count belongs to its protocol or operation ID.
- A peer-lost event can move `SwitchingToActive` toward standalone, and a successful FIN/peer-role acknowledgement can complete the switchover. Those require different peer outcomes and do not fire while a connected peer continues returning RST.
- If no further unrelated reset occurs, a later fifth RST will eventually return `SwitchoverFailed`. That does not erase the already-sent fourth retry or its extra 30-second transition/policy-pause interval. Repeated final vote or connection-maintenance resets can prolong the budget further.
- Phase 2 must observe the fourth wire-level SYN and the persisted `in_progress`/`SwitchingToActive` outcome after four RSTs; observing only the transient private counter is insufficient.

## Step 2: developer-knowledge evidence

- The behavior was introduced as one unit by commit `6b5884cf259b76d3a6155a37d85c65d2817e82cd` / PR #145, “NPU Driven hamgrd infrastructure.” Its description says it implemented the NPU HA state machine, peer messages, and planned-switchover unit tests, but the “How I verified it” section is empty: <https://github.com/sonic-net/sonic-dash-ha/pull/145>.
- An inline review on that PR explicitly states that `retry_count` is shared by independent voting and peer-connection workflows, can cause one workflow's retries to affect the other, and recommends separate counters: <https://github.com/sonic-net/sonic-dash-ha/pull/145#discussion_r2854609406>. The comment is on the same `NpuHaScopeActor.retry_count` field; it names vote/connection examples rather than the vote/switchover interleaving in this counterexample. There is no reply on the review thread.
- The same PR added all three uses. `git log -S'retry_count' -- npu.rs` finds only commit `6b5884cf`; no later commit has separated or otherwise changed the counter through current `origin/master`.
- The code's only nearby developer note is the vote branch TODO at `npu.rs:921-923` to alert the SDN controller after too many retry-later results. It does not describe cross-protocol ownership or tolerance of resets.
- The SmartSwitch HA HLD defines primary-election `RetryCount` as the number of times “we have retried,” specifically to avoid retrying forever, and separately says a rejected planned switchover moves the initiator back to Standby so it can retry the operation later: <https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#73-primary-election> and <https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#821-workflow>.
- Existing production actor-runtime coverage (`ha_scope_npu_planned_switchover`) tests only the accepted FIN path. The pre-existing Specula-focused tests exercise isolated vote and switchover resets independently; none asserts the interleaving or the fourth-retry consequence.

## Step 3: known-status and precedent

- Tracker searches covered open and closed issues and PRs using `retry`, `retry_count`, `retry counter`, `vote`, `switchover`, both handler names, and `SwitchoverFailed`. Searches were sorted/rechecked against recently updated/merged PRs; local `origin/master` includes commits through 2026-07-28.
- No dedicated issue or fixing PR describes the vote/switchover trace. The same-field, same-site defect class was nevertheless explicitly reported in PR #145's inline review: one actor-wide counter couples independent retry workflows and should be split. This is recorded as `Novelty: KNOWN (cite: https://github.com/sonic-net/sonic-dash-ha/pull/145#discussion_r2854609406; fix-status: unfixed)`.
- Related search matches (#155, #157, #159, #193/#198, #201/#202, #205, and #209) concern launch, re-pairing, rehydration, ASIC-role gating, prerequisite programming, or SWBUS reconnect behavior; none changes the counter. The only issue matching `retry` is unrelated ZMQ reconnect issue #75.
- Because this finding has an actual TLC violation trace, it proceeds to Phase 2 even though the mechanism is already reported.
