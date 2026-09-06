# Confirmation Report — vsr-rs

## Final Result

Reproduced bugs: 0 = 0 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 3
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 4
Dispositions: 4 total = 0 reproduced + 0 env-limited + 0 masked + 3 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | FALSE POSITIVE | no |
| 2 | CR-2 | FALSE POSITIVE | no |
| 3 | CR-3 | FALSE POSITIVE | no |
| 4 | CR-4 | DROPPED | no |

## Entry 1: Historical protocol promises across state replacement and recovery

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:1346

## Description
CR-1 does not reproduce as a bug under the library’s documented contract. The audited paths allow replacement of uncommitted suffixes, but preserve committed prefixes through quorum selection, catch-up from `commit_number`, and recovery from the latest primary state. The one plausible reply-cache concern in `install_log` requires a same client to have a later uncommitted request while still needing the earlier committed reply, which violates the documented one-outstanding-request client discipline.

Prior-report search covered upstream issues/PRs and recent closed/merged PRs. Issue #9 / PR #10 cover kvstore example connection lifecycle and client identity reuse, not this mechanism; narrow searches for `install_log`, `client_table`, and `"committed prefix"` returned no same-site report.

## Trigger scenario
The repro exercised normal public API schedules only: same-view `NewState` after a missed `Prepare`, retained old-primary catch-up that replaces `[10,20]` with `[10,30]` and then commits the pending retry, and reboot recovery that reconstructs committed history from `RecoveryResponse`.

## Developer intent
Docs require persisting only `view_number` and using one outstanding request per client; tests and simulator properties already check committed-prefix agreement, durability, reply consistency, duplicate execution, state transfer, view change, and reboot recovery. Upstream tracker evidence: https://github.com/penberg/vsr-rs/issues/9 and https://github.com/penberg/vsr-rs/pull/10 are adjacent example issues, not this protocol mechanism.

## Reproduction result
Repro written and executed: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/repro/test_bugCR-1_historical_promises.sh`

```text
command: timeout 120s cargo run --quiet --manifest-path /home/ubuntu/tmp/tmp.CmVplC8GId/Cargo.toml
CR-1 reproduction attempt against public vsr-rs APIs
level0 same-view NewState: ok; replicas=[60, 60, 60]
level0 retained catch-up: ok; old primary replaced [10,20] with [10, 30, 20] and pending retry committed
level0 recovery: ok; rebooted replica reconstructed committed log [10, 20, 30]
Level 0 result: no committed-prefix divergence, wrong reply, crash, or lost pending request was observed.
Level 1 result: not escalated; deterministic message loss/reorder/replay scheduling already controls timing without source changes.
Level 2 result: not used; injecting a broken committed prefix or forged peer state would bypass the real producer paths exercised above.
Level 3 result: not used; source patching was unnecessary and would not be sound for this code-review candidate.
```

Cross-checks: `timeout 5m cargo test --workspace` passed; `cargo test --features tla-trace trace_` passed 4 trace scenarios.

## Recommendation
No protocol fix for CR-1. Keep the existing documented client discipline explicit, especially one outstanding request per client and new identity after restart.

---

## Entry 2: Logical request identity, application replay, and reply reconstruction

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:1349

## Description
CR-2 is not confirmed as a defect under the documented public contract. `install_log`, `commit_up_to`, and `commit_op` rebuild state and cached replies consistently for the latest request per client; the stale-cache scenarios require violating the client contract: unique client identities and at most one outstanding request per client.

## Trigger scenario
I tested a real public-API sequence: lost client reply, duplicate resend, replica reboot through `Replica::recover`, view change to the recovered replica, and resend of the still-pending request. The recovered new primary returned the reconstructed cached reply without reapplying the operation.

## Developer intent
The docs require one request at a time and fresh client identity after restart. Upstream search covered issues and PRs, including https://github.com/penberg/vsr-rs/issues/9 and https://github.com/penberg/vsr-rs/pull/10; those cover kvstore example connection/client-id concerns, not this library recovery/reply-reconstruction mechanism.

## Reproduction result
Repro written and executed: `repro/test_bugCR-2_request_recovery_reconstruction.sh`

Command:
```text
timeout 5m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/repro/test_bugCR-2_request_recovery_reconstruction.sh
```

Output:
```text
Level 0 public API duplicate request: cached retry reply result=10, primary_applied=1
Level 1 timed recovery/view-change: recovered primary reply result=7, view=1, applied_before=1, applied_after=1
Level 2 state injection: not used; the remaining suspicious stale-client-table preconditions require violating the documented one-outstanding-request/client-identity contract.
Level 3 source patch: not used; no public-API timing window produced a wrong reply, duplicate application, or permanent bad state.
CR-2 RESULT: no wrong client-visible reply and no duplicate application under the documented public contract
```

## Recommendation
No CR-2 protocol fix is indicated. Optional hardening would be to make `Client::on_request` reject a second outstanding request and make `Replica::recover` docs explicitly say the supplied state machine must be fresh recovery state.

---

## Entry 3: Service and recovery progress under suitable timing

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:1166

## Description

CR-3 does not confirm as a live bug. The cited retry, recovery-response, view-change backoff, and simulator liveness paths are reachable through public APIs, but the CR-3 reproducer found the expected progress behavior: pending client requests complete, recovering replicas rejoin, future-view recovery does not deadlock, and simulator liveness converges.

## Trigger scenario

Executed `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/repro/test_bugCR-3_service_progress.sh`.

The reproducer used clean `git archive HEAD` at `3ac0104a567092139534c9022205d02281a2da41`, then added temporary integration tests for:

- public API request/recovery progress after transient `Recovery` loss
- persisted-future-view recovery with adversarial timing
- synchronized one-tick idle/delivery view-change scheduling
- simulator safety/liveness after crash, restart, reboot, partition, and heal

## Developer intent

Issue search covered open and closed issues/PRs. Issue #4 reports an older missing-retransmission stall and says it was fixed by idle-period resends, including `Recovery`; issue #7 records `on_idle` as the caller-driven tick with timeout/backoff behavior. I found no already-filed current defect for this combined CR-3 mechanism.

## Reproduction result

```text
CR-3 reproduction test
source_commit=3ac0104a567092139534c9022205d02281a2da41
LEVEL 0: pure public Client/Replica APIs with transient message loss and stable timing
LEVEL 1: public APIs with adversarial timing schedules for future-view recovery and synchronized delivery
LEVEL 2: not used; the relevant recovery preconditions are produced through public API sequences in the tests
LEVEL 3: not used; no source patch was needed or applied

running 3 tests
test level0_client_request_and_recovery_complete_after_stabilization ... LEVEL 0 PASS: public Client/Replica APIs completed a pending request and reboot recovery after transient Recovery loss
ok
test level1_persisted_future_view_recovery_does_not_deadlock ... LEVEL 1 PASS: timing-assisted future-view recovery advanced through view change and completed a later request
ok
test level1_synchronized_idle_delivery_schedule_settles ... LEVEL 1 PASS: synchronized one-tick idle/delivery schedule settled instead of livelocking
ok

test result: ok. 3 passed; 0 failed

running 1 test
test simulator_liveness_replies_and_converges_after_reboot_and_partition ... SIMULATOR PASS: requests=200/200 reboots=1 final_view=0 final_commit=200 value=8230817423
ok

test result: ok. 1 passed; 0 failed

CR-3 result: no service/recovery progress failure was observed by the CR-3 reproducer
```

## Recommendation

Do not report CR-3 as a bug. Keep the existing retry/backoff/recovery regression coverage; a future liveness claim should be framed as missing proof or coverage unless it comes with a reachable schedule where a real client or recovering replica remains permanently stuck.

---

## Entry 4: Example obligations at the library boundary

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/penberg/vsr-rs/issues/9; fix-status: unfixed)
- **Location**: examples/kvstore/main.rs:491

## Description
CR-4 resolves to the kvstore example’s client-identity boundary obligation. The example derives client IDs from `node_id`, a 24-bit wall-clock seconds value, and a per-process accept counter; if a node restarts within the same second, the first accepted client can reuse the previous `ClientID` and request number 0. Upstream issue #9 already reports this exact mechanism at this site, and PR #10 is still open while explicitly leaving the client-ID issue unfixed.

## Trigger scenario
Start the kvstore example, connect the first client to a node, and commit `SET k old`. Restart that node within the same wall-clock second, then connect the first client again and issue `GET k`. The restarted connection can reuse the same client ID and request number, so the primary’s client table treats the new `GET` as a resend of the old `SET`.

## Developer intent
The library documents that every client must have its own identity and that restarted clients must not reuse one (`lib.rs:32`). The example’s own comment says repeated client IDs make the primary answer a new connection’s first request from the cache (`examples/kvstore/main.rs:479`). Issue #9 reports the same defect, and PR #10 says it fixes #9 items 1 and 2 while leaving the client-ID issue alone.

## Reproduction result
Repro artifact written and executed:
`/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/repro/test_bugCR-4_client_id_reuse.sh`

Command:
```bash
timeout 5m bash /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/repro/test_bugCR-4_client_id_reuse.sh
```

Output:
```text
kvstore restart-within-one-second id: first=48358647398400000 restarted_first=48358647398400000
first command SET k old: reply client=48358647398400000 request=0 result=None
restarted first command GET k: reply client=48358647398400000 request=0 result=None
expected GET k result after committed SET: Some("old")
BUG OBSERVED: duplicate client id/request number was answered from the old SET cache; the kvstore connection code would format this GET reply as $-1 instead of returning old
```

Because this is code-review sourced and already reported upstream as the same mechanism at the same site, the skill’s known-duplicate rule applies.

## Recommendation
Do not count CR-4 as a new finding. Track it against upstream issue #9; the durable fix is to generate restart-unique client IDs, e.g. with a persisted incarnation/epoch or sufficiently strong random/monotonic identity source rather than seconds plus a per-process counter.

---
