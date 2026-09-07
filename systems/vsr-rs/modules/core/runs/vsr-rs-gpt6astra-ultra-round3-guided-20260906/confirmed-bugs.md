# Confirmation Report — vsr-rs

## Final Result

Reproduced bugs: 1 = 1 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 3
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 1 reproduced + 0 env-limited + 1 masked + 3 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | REPRODUCED | yes |
| 2 | CR-2 | FALSE POSITIVE | no |
| 3 | CR-3 | MASKED | no |
| 4 | CR-4 | FALSE POSITIVE | no |
| 5 | CR-5 | FALSE POSITIVE | no |

## Entry 1: EOF turns a valid frame prefix into different operation content

- **Finding ID**: CR-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: examples/kvstore/main.rs:401

## Description
Confirmed. `run_peer_acceptor` reads peer TCP input with `BufReader::lines()`, which accepts a final nonempty unterminated line at clean EOF. Because `decode()` treats whitespace tokens as complete frame fields, an exact prefix of a real `PREPARE ... PUT key value` frame can be decoded as a different `PUT` value and then committed.

Prior-report search covered upstream issues/PRs and git history. Existing upstream issue #9 and PR #10 cover kvstore connection lifecycle/backoff/cleanup, not this same frame-prefix mechanism: https://github.com/penberg/vsr-rs/issues/9 and https://github.com/penberg/vsr-rs/pull/10.

## Trigger scenario
The repro starts three unmodified `kvstore` processes. Node 0 receives a real client `SET cr1key FULLVALUE_...`, emits real encoded `PREPARE` frames, and two TCP relays forward exact non-newline prefixes of those frames to nodes 1 and 2 before clean EOF. Node 0 is stopped before replying. Nodes 1 and 2 elect node 1 as primary, then a fresh client `GET cr1key` commits and observes the shortened value.

## Developer intent
The kvstore comments document “one message per line” peer encoding and single-word keys/values. I found no comment, test, commit, issue, or merged PR saying clean EOF should complete a peer frame or that truncated frame content is tolerated.

## Reproduction result
Test written and executed:

`timeout 90s /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-1_peer_eof_prefix.py`

```text
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.02s
CR-1 reproduction: clean EOF after a real PREPARE prefix
original_client_reply_before_primary_stop=b''
primary_exit_code=-15
node1_full_prepare=PREPARE 0 1 0 44266260824850433 0 PUT cr1key FULLVALUE_ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ
node1_forwarded_prefix=PREPARE 0 1 0 44266260824850433 0 PUT cr1key FULLVALUE_ABCDEF
node1_prefix_is_full_prepare_prefix=True
node2_full_prepare=PREPARE 0 1 0 44266260824850433 0 PUT cr1key FULLVALUE_ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ
node2_forwarded_prefix=PREPARE 0 1 0 44266260824850433 0 PUT cr1key FULLVALUE_ABCDEF
node2_prefix_is_full_prepare_prefix=True
fresh_client_get_response='$16\r\nFULLVALUE_ABCDEF\r\n'
expected_full_value=FULLVALUE_ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ
truncated_prefix_value=FULLVALUE_ABCDEF
node1_interesting_log=node 1 of 3: replicas on 127.0.0.1:37629, clients on 127.0.0.1:60601, primary is node 0 | view 1: primary is node 1 (this node)
node2_interesting_log=node 2 of 3: replicas on 127.0.0.1:54541, clients on 127.0.0.1:44391, primary is node 0 | view 1: primary is node 1
BUG_TRIGGERED: fresh client observed committed truncated value from an unterminated PREPARE prefix
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes. The binaries were unmodified; trigger used real client commands and real TCP peer input with clean EOF after exact primary-generated frame prefixes.
2. Level 2/3 precondition: not used.
3. Real consumer/caller observing wrong outcome: `run_client_connection` returns the `GET` result to the fresh client via `format_reply()` at `examples/kvstore/main.rs:594-599`.
4. Permanent or masked: permanent for the surviving view. No resend/state-transfer corrected it; node 1 committed and served the shortened value.

## Recommendation
Use a peer framing format that can reject incomplete frames: for example length-prefix each encoded frame, or keep newline framing but require an actual delimiter before decoding. Also reject extra/truncated token forms and treat EOF with buffered non-delimited bytes as a bad peer frame, not as a complete message.

---

## Entry 2: Quorum-selected history across view changes and rolling recovery

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:1062

## Description
CR-2 is not confirmed as a bug. The suspected mechanism is reachable: new primary 1 can start view 1 from `DoViewChange` messages sent by replicas 0 and 2, excluding its own state. But under the real API and documented failure model, that does not lose or reorder a committed/client-completed operation: the committed quorum intersects the view-change quorum, and recovering replicas cannot participate until recovery installs latest-primary state.

## Trigger scenario
The repro commits client operation A on primary 0 and backup 1, with replica 2 missing the prepare. It then forces view 1 using only real `StartViewChange`/`DoViewChange` messages from replicas 0 and 2, excluding primary 1’s own `DoViewChange`. A second run reboots replica 1 before the excluding-primary view change and reboots replicas 0 and 2 after it.

## Developer intent
The code and docs explicitly rely on this contract: committed indexes never change (`lib.rs:39-40`), view-change selection relies on quorum intersection (`lib.rs:1060-1061`), recovery waits for quorum plus latest primary state (`lib.rs:1180-1242`), and README documents volatile recovery with only persisted `view_number` (`README.md:69-72`). Public tracker search found no prior exact report; #9/#10 cover kvstore connection lifecycle, not this core mechanism.

## Reproduction result
Test written and executed:
`/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-2_view_recovery.sh`

Command:
```console
timeout 6m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-2_view_recovery.sh
```

Output:
```console
CR-2 reproduction attempt against public vsr-rs APIs
level0: PASS - real public API schedule reached view1 from DoViewChange senders [0, 2], excluding new primary 1; client-completed A stayed at index 0 and B committed after it
level1: PASS - with normal recovery of replica 1 before the excluding-primary view change and rolling recovery of replicas 0 and 2 after it, committed/client-observed A stayed recoverable and ordered before B
level2: NOT USED - making the selected DoViewChange log omit committed A would require an inadmissible hand-built state; all DoViewChange messages above were generated by real replicas through on_idle/on_message
level3: NOT USED - no race-only source delay is implicated after Level 0/1 reached the suspected mechanism through normal scheduling
result: no client-visible loss, reorder, panic, or permanent bad state observed
```

Additional bounded check: `timeout 5m cargo test` passed all 16 existing cluster tests.

## Recommendation
No code change for CR-2 as stated. Keep or add a regression test for the excluding-primary `DoViewChange` quorum plus rolling recovery schedule, since it documents an important safety boundary.

---

## Entry 3: Arrival-order recovery responses during changing views

- **Finding ID**: CR-3
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `lib.rs:1204`

## Description
CR-3’s overwrite mechanism is real: `on_recovery_response` stores responses by `replica_id`, so an older authentic `RecoveryResponse` from the same sender and nonce can overwrite a newer one. In the reproduction, replica 2 first receives replica 1’s view-1 primary state at commit 2, then receives replica 1’s older view-0 non-state response, and finally recovers from replica 0’s stale view-0 primary state at commit 1.

This did not become a reproduced live bug because the downstream view guard and state-transfer path repaired the stale recovery before any client-visible inconsistency.

## Trigger scenario
Public API / normal-message sequence only:

1. View 0 commits `Put(A)`.
2. Replica 2 crashes and recovers from persisted view 0.
3. Replicas 0 and 1 generate old view-0 recovery responses.
4. Replicas 0 and 1 move to view 1 while replica 2 is still recovering.
5. View 1 commits `Put(B)`.
6. Replica 1 sends a newer view-1 recovery response with commit 2.
7. The old replica-1 view-0 response arrives later and overwrites it.
8. Replica 0’s old view-0 state response completes recovery into stale view 0 commit 1.
9. A real view-1 `Commit` then triggers catch-up through `GetState`/`NewState`, restoring replica 2 to view 1 commit 2.

## Developer intent
The comments at `lib.rs:1180-1186` say recovery should use a quorum including the primary of the latest stored view, and reject recovery below the persisted view. The README says transport may reorder/duplicate messages and callers persist only `view_number`. I found no upstream issue or PR reporting this exact recovery-response overwrite mechanism; issue #9 / PR #10 are kvstore connection/client-ID issues, not this site.

## Reproduction result
Repro written and executed:

`/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-3_recovery_response_overwrite.sh`

Command:

```console
timeout 6m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-3_recovery_response_overwrite.sh
```

Key output:

```console
OBSERVED: r2 recovered into stale view0 commit1 after receiving r1's newer view1 commit2 response
MASK: higher-view Commit plus GetState/NewState catch-up repaired r2 to view1 commit2
RESULT: no client-visible inconsistency; final Get returned B and committed prefixes agree
LEVEL 1: not needed for triggering; Level 0 already reached the overwrite and the mask deterministically
LEVEL 2: not used; no state injection
LEVEL 3: not used; no source patch
```

Checklist before `REPRODUCED`:

1. Did Level 0 or Level 1 alone trigger it? **yes**, Level 0 triggered the overwrite and stale recovery state.
2. Level 2/3 used? **no**.
3. Which real consumer/caller observes a wrong outcome? **None**; client 100 later observes the correct `Get -> B` reply from the real primary path.
4. Is the bad state permanent? **No**. A higher-view `Commit` triggers `catch_up_with_view`, then `GetState`/`NewState` repairs replica 2.

## Recommendation
Treat this as a masked correctness risk, not a confirmed client-visible bug. The robust fix is to make stored recovery evidence monotonic per sender/view, e.g. ignore lower-view responses from a sender once a higher-view response for the same nonce has been observed, or keep enough per-sender history so delayed older responses cannot reduce `latest_view`.

---

## Entry 4: Durable view with only some output published before a crash

- **Finding ID**: CR-4
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:1468

## Description
CR-4’s partial-output boundary is reachable, but I could not confirm it as a defect. The published prefix behaves like ordinary message/reply loss, which the documented API allows, and recovery/view-change plus client resend preserved committed order and regenerated lost replies.

## Trigger scenario
The repro used real `Client`/`Replica` public APIs: two clients submit requests, old primary commits them while replies are lost, replicas enter a real view change, new primary emits `StartView` messages and two regenerated replies, then only a prefix is published before the new primary reboots with persisted `view_number = 1`.

Two subcases were tested: only one `StartView` published, and all `StartView`s plus only the first reply published before crash.

## Developer intent
README/library docs require persisting `view_number()` before output delivery and state that transport may lose, duplicate, or reorder messages. Recovery explicitly refuses stale/normal traffic while recovering, view-change/recovery messages are resent on idle, and clients resend pending requests. Upstream issue/PR search covered open and closed issues/PRs, including #9/#10; those report kvstore connection lifecycle bugs, not this durable-view partial-publication mechanism.

## Reproduction result
Test written and executed:
`/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-4_partial_publication.sh`

Command:
```console
timeout 6m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-4_partial_publication.sh
```

Output:
```console
CR-4 reproduction attempt: Level 0 public API schedule with real Client/Replica calls, message loss, partial publication, and Replica::recover.
case startview-prefix-only: PASS; published 1/2 StartView messages and 0/2 new-primary replies, rebooted replica 1 with durable_view=1, then all replicas settled in view 2 at commit=2 value=30; observed replies=[(0, 0, 2, 10), (1, 0, 2, 30)]
case reply-suffix-lost-then-later-request: PASS; published both StartView messages and only the first of two replies, rebooted replica 1 with durable_view=1, then client 1's reply was regenerated and client 0's later request returned 35; observed replies=[(0, 0, 1, 10), (1, 0, 2, 30), (0, 1, 2, 35)]
Level 1 timing assistance: not needed for nondeterminism; the exact crash window is exposed deterministically by draining only a prefix after the required durable view write.
Level 2 state injection: not used; the precondition was reached by real requests, Prepare/PrepareOk, StartViewChange, DoViewChange, StartView, and Recovery messages.
Level 3 source patch: not used; no source delay or logic patch is required to hit the publication boundary.
RESULT: no safety or client-linearizability violation observed; recovery/view-change plus client resend regenerated lost suffix replies and preserved committed order.
```

Existing tests also passed: `cargo test --quiet` ran 16 integration tests successfully.

## Recommendation
No correctness fix is indicated for CR-4 as stated. A useful hardening step would be to add this partial-publication crash schedule as a regression/assurance test and clarify in docs that drained-but-unpublished output after a process crash is treated as transport loss.

---

## Entry 5: Continued requests with a permanently unavailable minority

- **Finding ID**: CR-5
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: lib.rs:1270

## Description
CR-5 is not confirmed. The implementation does use round-robin primaries, so an unavailable replica can be named primary for a view, but the public client retry and replica view-change timers skip that view after a finite delay. I found no upstream issue/closed PR reporting this exact mechanism.

## Trigger scenario
Three replicas, one permanently unavailable minority replica. A finite fault prefix leaves healthy replicas 0 and 2 in view 1, whose primary is down replica 1. A client request issued during that stalled view is retried while healthy replicas continue receiving fair `on_idle` calls and message delivery.

## Developer intent
The code comments explicitly describe the intended safeguards: clients resend pending requests to every replica (`lib.rs:355-357`), non-primary/non-normal replicas drop requests until a retry finds the primary (`lib.rs:663-667`), and `on_idle` drives view-change retry/backoff (`lib.rs:1254-1269`). Upstream issues #4/#7/#8 discuss retry, timer, and client-view behavior, but not this exact defect; #9/#10 are kvstore connection lifecycle items, not this core-library mechanism.

## Reproduction result
Command:
```bash
timeout 5m /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-5_permanent_minority.sh
```

Output:
```text
CR-5 reproduction test using public vsr-rs Client/Replica APIs
Level 0: pure public API with one permanently unavailable replica and fair delivery among a healthy majority
level0 initial-primary-down: request 0 first targets unavailable primary 0
request 0 completed after 4 fair rounds in view 1 with result 7
level0 initial-primary-down: healthy nodes settled, commits=[1, 1], values=[7, 7], r0=down, r1=view:1 status:Normal commit:1 value:7 primary:1, r2=view:1 status:Normal commit:1 value:7 primary:1; queue=0
request 0 completed after 1 fair rounds in view 0 with result 10
finite prefix reached view 1 with unavailable primary 1; r0=view:1 status:ViewChange commit:1 value:10 primary:1, r1=down, r2=view:1 status:ViewChange commit:1 value:10 primary:1; queue=0
level0 skipped-primary: request 1 issued while healthy replicas are in view-change for dead primary 1
request 1 completed after 3 fair rounds in view 2 with result 10
request 2 completed after 1 fair rounds in view 2 with result 15
request 3 completed after 1 fair rounds in view 2 with result 15
level0 skipped-primary: follow-up service continued, commits=[4, 4], values=[15, 15], r0=view:2 status:Normal commit:4 value:15 primary:2, r1=down, r2=view:2 status:Normal commit:4 value:15 primary:2; queue=0
Level 1: timing-assisted one-tick delivery/retry schedule, no source changes
request 0 completed after 3 fair rounds in view 0 with result 11
finite prefix reached view 1 with unavailable primary 1; r0=view:1 status:ViewChange commit:1 value:11 primary:1, r1=down, r2=view:1 status:ViewChange commit:1 value:11 primary:1; queue=0
level1 delayed-delivery: request 1 waits through the unavailable-primary view
request 1 completed after 5 fair rounds in view 2 with result 11
level1 delayed-delivery: completed under one-tick delivery, commits=[2, 2], values=[11, 11], r0=view:2 status:Normal commit:2 value:11 primary:2, r1=down, r2=view:2 status:Normal commit:2 value:11 primary:2; queue=0
Level 2: not used; public API scenarios reached the alleged precondition and observed completion, so state injection would only manufacture non-progress
Level 3: not used; no source patch is needed or sound after Level 0/1 reachability and completion
CR-5 reproduction result: no permanent non-progress observed; pending client requests completed after healthy-majority timers and retries
```

The test was written and executed at `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-5_permanent_minority.sh`.

## Recommendation
No code change for CR-5. Keep the existing retry/view-change tests or add this reproduction as regression coverage for the intended stable-majority progress behavior.

---
