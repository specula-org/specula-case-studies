# Confirmation Report — HashiCorp memberlist

## Final Result

Reproduced bugs: 3 = 2 NEW + 1 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 4
Dispositions: 4 total = 3 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | MASKED | no |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | CR-2 | REPRODUCED | yes |

## Entry 1: Higher terminal incarnation is discarded by an already-dead record

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: state.go:1294

## Description

[`deadNode`](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/MC-1/worktree/state.go:1294) returns for an already-terminal record before retaining a higher terminal incarnation. Consequently, delayed `Alive(2)` can pass the guard against retained `Dead(1)`, resurrect a crashed node, emit `NotifyJoin`, and expose it through `Members()`.

## Trigger scenario

1. A victim emits a legitimate `Alive(2)` through public `UpdateNode`.
2. The victim calls public `Shutdown`, which sends no leave message.
3. One observer holds `Dead(1)`.
4. Another observer produces `Dead(2)`.
5. `Dead(2)` reaches the first observer while it is already dead. This is exact counterexample State 17.
6. After all bounded `Dead(2)` retransmissions arrive, delayed `Alive(2)` is delivered.
7. Because the retained incarnation remains 1, the crashed victim transitions to `Alive(2)`.

## Developer intent

Commit `96f530f` moved the incarnation update after the already-dead check, apparently intending duplicate dead messages to do nothing. However, `TestMemberList_DeadNode_AliveReplay` explicitly requires terminal state to dominate an alive replay at the same incarnation.

Upstream [issue #311](https://github.com/hashicorp/memberlist/issues/311) and [PR #345](https://github.com/hashicorp/memberlist/pull/345) concern stale-alive re-gossip and unknown-node drops; closed, unmerged [PR #359](https://github.com/hashicorp/memberlist/pull/359) concerns incarnation overflow. Searches of issues, recently closed/merged PRs, and git history found no report of MC-1’s already-terminal ordering mechanism.

## Reproduction result

Test: [test_bugMC-1_terminal_incarnation.go](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/repro/test_bugMC-1_terminal_incarnation.go)

Command:

```text
timeout 5m go test -overlay=/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/MC-1/repro-overlay.json -run '^TestBugMC1TerminalIncarnation$' -count=1 -v .
```

Actual output:

```text
=== RUN   TestBugMC1TerminalIncarnation
LEVEL 0: public Create/Join/Shutdown/Members handled a simple crash; no higher-terminal ordering, no trigger
LEVEL 1: public UpdateNode + immediate Shutdown + sleeps did not trigger on localhost; selective packet ordering was not obtained
LEVEL 2: CE State 17 delivered Dead(2) four times to retained Dead(1); stored state=2 incarnation=1
BUG: delayed Alive(2) resurrected the crashed victim; Members() contains victim=true, NotifyJoin=1, NotifyLeave=1
PERMANENCE: after 250ms the crashed victim remains in Members(); probe/gossip/push-pull are legally disabled and all Dead(2) copies preceded Alive(2)
--- PASS: TestBugMC1TerminalIncarnation (0.68s)
PASS
ok  	github.com/hashicorp/memberlist	0.687s
```

A three-run repeat also passed.

## Recommendation

Before the already-terminal return, retain `d.Incarnation` when it is higher, while preserving the terminal state and avoiding duplicate notification/rebroadcast. Add regression coverage proving `Dead(1) → Dead(2) → Alive(2)` remains terminal.

## REPRODUCED checklist

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 precondition: exact counterexample State 17 delivers `Dead(n1,2)` to `n2`, whose view remains `Dead(n1,1)`. The reproduction additionally uses `Create → UpdateNode(0) → Shutdown`, retaining the actual encoded `Alive(2)` for delayed delivery.
3. Real consumers observing the wrong outcome: public `Members()` at `memberlist.go:609` returns the crashed victim, and `EventDelegate.NotifyJoin` at `state.go:1154` receives a spurious rejoin.
4. The bad state is **permanent in the tested supported configuration until new external membership input**. Probe, gossip, and push/pull are legally disabled, and all bounded `Dead(2)` copies were delivered before `Alive(2)`; no downstream mechanism corrected it. Optional periodic sync is therefore not a guaranteed mask.

---

## Entry 2: Delayed pre-restart Alive claims ownership of the old address

- **Finding ID**: MC-2
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/hashicorp/memberlist/issues/312; fix-status: unfixed)
- **Location**: state.go:1005

## Description

A delayed, legitimate pre-restart `Alive` message can recreate a reaped membership record and associate a node name with its retired address. The public `Members()` API and `NotifyJoin` callback expose that incorrect address, but normal failure detection subsequently marks the unreachable address dead and removes it.

## Trigger scenario

1. `subject` and `observer` join normally.
2. The real gossip loop emits an incarnation-1 `Alive`; Level 1 retains that datagram as timing assistance.
3. `subject` shuts down.
4. The observer’s normal probe, suspicion, and reap cycle removes its record.
5. A new process named `subject` starts at a different address with volatile incarnation reset.
6. The exact captured datagram is released through the observer’s normal UDP decoder.
7. `NotifyJoin` and `Members()` report the retired address.
8. Subsequent probing emits `NotifyLeave` and removes the stale member.

This is the implementation-reachable refinement of counterexample states 2–6.

## Developer intent

`state.go:1106-1115` recognizes restart/same-incarnation conflicts only when a node receives an Alive about itself. `SECURITY.md:164-168` explicitly states that memberlist has no replay cache and that incarnation filtering provides only incidental replay resistance.

Upstream [issue #312](https://github.com/hashicorp/memberlist/issues/312) reports the same stale-Alive resurrection mechanism at the same merge path. [Issue #311](https://github.com/hashicorp/memberlist/issues/311) separately documents volatile incarnation problems during restarts.

## Reproduction result

Test: [test_bugMC-2_delayed_alive.go](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/repro/test_bugMC-2_delayed_alive.go)

Command:

```text
timeout 5m go test -run '^TestBugMC2DelayedPreRestartAlive$' -count=1 -v .
```

The test also passed five consecutive runs with `-count=5`.

Actual output:

```text
=== RUN   TestBugMC2DelayedPreRestartAlive
LEVEL=0 standard loopback Create/Join/Shutdown/Create: trigger_not_observed (no packet-delay control)
LEVEL=1 timing-only delayed datagram; public Create/Join/Shutdown/Create APIs
CAPTURED pre-restart gossip bytes=153 destination=127.0.0.1:36973 old_address=127.0.0.1:39105
RESTART current_process_address=127.0.0.2:34843
OBSERVER NotifyJoin name=subject accepted_address=127.0.0.1:39105
BUG Members() name=subject address=127.0.0.1:39105 expected_current=127.0.0.2:34843
MASK probe/suspicion emitted NotifyLeave and Members() removed stale address=127.0.0.1:39105
--- PASS: TestBugMC2DelayedPreRestartAlive (1.66s)
PASS
ok  	github.com/hashicorp/memberlist	1.661s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 1**, using public `Create`, `Join`, `Shutdown`, and `Members` operations with timing assistance only.
2. Level 2/3 reachability justification: **not applicable**; no state injection or source patch was used.
3. Real consumer observing the wrong outcome: public `Memberlist.Members()` at `memberlist.go:609`, plus `EventDelegate.NotifyJoin` invoked from `state.go:1157`.
4. Permanent or later resolved: **transient and resolved**. The normal probe/suspicion path at `state.go:232-273` and `state.go:517-521` marks the retired address dead; `Members()` then stops exposing it. The reproduction explicitly proves this mask fires.

## Recommendation

Carry a durable boot/identity epoch in membership messages, or persist incarnation state across restarts, so receivers can reject packets from retired lifetimes. Until protocol compatibility permits that, applications should treat join/address observations as weakly consistent and avoid acting on them before reachability confirmation.

---

## Entry 3: Rejected join state leaks through the accepting initiator

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: [hashicorp/memberlist#132](https://github.com/hashicorp/memberlist/issues/132); fix-status: unfixed)
- **Location**: [net.go:325](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/MC-3/worktree/net.go:325)
- **Severity**: Medium
- **Reproduction test**: [test_bugMC-3_rejected_join_leak.go](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/repro/test_bugMC-3_rejected_join_leak.go)

## Description

The responder sends its membership state at `net.go:325` before its merge delegate validates the initiator at `net.go:1329`. When the responder rejects but the initiator accepts, `aliveNode` commits and queues the responder’s Alive record for gossip, allowing it to reach an existing third member.

## Trigger scenario

Using only public APIs:

1. Create `n1`, `n2`, and `n3`.
2. Form a normal `n2`/`n3` cluster with `Join`.
3. Configure `n1`’s public `MergeDelegate` to reject the offered cluster.
4. Call `n2.Join(n1)`.
5. `n1` sends its state and then rejects; `n2` nevertheless returns success and gossips `n1` to `n3`.

This matches counterexample states 4, 6, 7, and 8: response sent, initiator accepted, responder rejected, state escaped.

## Developer intent

`MergeDelegate` documents that a non-nil result cancels the merge, while `Join` documents that failed admission returns an error. Upstream issue [#132](https://github.com/hashicorp/memberlist/issues/132) explicitly says the responder’s error should propagate to the initiator.

The source notes that an optional `AliveDelegate` can prevent passive merging, but no default guard rolls back or quarantines the already accepted state.

## Reproduction result

Level 0 succeeded; Levels 1–3 were unnecessary. Exact command:

```text
timeout 2m go run /home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/repro/test_bugMC-3_rejected_join_leak.go
```

Actual output:

```text
LEVEL=0 public APIs and normal gossip; no timing hooks, injection, or source patch
PRECONDITION n2=[n2-initiator:Alive,n3-observer:Alive] n3=[n2-initiator:Alive,n3-observer:Alive]
2026/07/27 20:26:36 [ERR] memberlist: Failed push/pull merge: n1 policy rejects cluster merge from=127.0.0.1:40090
RESPONDER_REJECTED=true delegate_calls=1
INITIATOR_JOIN_RETURN success=1 error=<nil>
INITIATOR_VIEW n2=[n1-rejector:Alive,n2-initiator:Alive,n3-observer:Alive]
THIRD_NODE_EVENT observer=n3 NotifyJoin(n1)=true
THIRD_NODE_VIEW n3=[n1-rejector:Alive,n2-initiator:Alive,n3-observer:Alive] contains_n1_alive=true
AFTER_SETTLE n1=[n1-rejector:Alive,n2-initiator:Alive,n3-observer:Alive] n2=[n1-rejector:Alive,n2-initiator:Alive,n3-observer:Alive] n3=[n1-rejector:Alive,n2-initiator:Alive,n3-observer:Alive]
PERSISTENT initiator_has_n1_alive=true third_has_n1_alive=true
BUG_TRIGGERED: responder rejected the join, but Join returned success and n1's Alive state reached and persisted at n3
EXPECTED: responder rejection is returned to the initiator, and rejected response state is not committed or gossiped
```

Three additional consecutive executions produced the same trigger.

Confirmation checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**.
2. Level 2/3 reachability evidence: **not applicable**.
3. Real consumer: `n3`’s application `EventDelegate.NotifyJoin` at `state.go:1157`; `Memberlist.Members` at `memberlist.go:609` also exposes `n1` as Alive.
4. Permanent or masked: **persistent, not masked**. After multiple gossip and probe rounds, both `n2` and `n3` retained `n1` as Alive. Gossip also caused `n1` eventually to admit the peers it had rejected, amplifying rather than repairing the admission failure.

## Recommendation

Validate the responder’s protocol and merge policy before sending usable local state, returning an `errMsg` on rejection. For fully mutual admission, keep received state provisional until both endpoints commit; only then merge it and enqueue Alive broadcasts.

---

## Entry 4: Suspicion evidence crosses incarnation and provenance boundaries

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Severity**: High
- **Location**: `state.go:1192`, `suspicion.go:106`, `state.go:1362`
- **Reproduction test**: [test_bugCR-2_cross_incarnation_test.go](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/repro/test_bugCR-2_cross_incarnation_test.go)
- **Investigation**: [investigation.md](/home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/confirmation/CR-2/investigation.md)

## Description

Suspicion timers are indexed only by node name. A legitimate higher-incarnation suspicion therefore confirms and can immediately expire an older incarnation’s timer without advancing the observer’s stored incarnation.

Push/pull also omits accusation provenance and reconstructs suspect/dead snapshots with the receiver as `From`, allowing synthetic confirmation across provenance boundaries.

## Trigger scenario

1. Three instances join normally.
2. The subject calls public `UpdateNode`, advancing its incarnation.
3. Packet loss lets the confirmer learn the update while the observer retains the old epoch.
4. A normal failed observer probe starts an old-epoch timer.
5. After that timer ages beyond the fresh-epoch minimum, a failed confirmer probe emits a legitimate higher-incarnation suspicion.
6. The observer treats it as confirmation of the old timer and delivers `NodeLeave` about 22 microseconds later, rather than beginning a fresh 2.079-second suspicion period.

## Developer intent

The original implementation describes evidence as independent corroboration. Commit [59781de](https://github.com/hashicorp/memberlist/commit/59781de9b055ff205675a4f07ed1498ce6b4d862) explicitly tracks the timer’s originating peer to prevent loopback evidence, while [51c744a](https://github.com/hashicorp/memberlist/commit/51c744a1ec702431a0588f272b7e35822329f9c4) re-gossips only independent confirmations.

Upstream issue searches and recently closed/merged PRs were checked. Results involving incarnation overflow, stale accusation propagation, and confirmation races concern different mechanisms; no prior report for this name-keyed cross-incarnation/provenance mechanism was found.

## Reproduction result

Command:

```text
timeout 5m go test -count=1 -v /home/munim/Specula/Specula/runs/memberlist-v030-study/memberlist/.specula-output/repro/test_bugCR-2_cross_incarnation_test.go
```

Actual output:

```text
=== RUN   TestBugCR2CrossIncarnationEvidenceAcceleratesOldTimer
LEVEL 0: exported MockNetwork transport + Join + UpdateNode + normal probes
observer view before trigger: state=suspect meta=epoch-1
confirmer view before trigger: state=suspect meta=epoch-2
minimum timeout for a fresh epoch: 2.079441541s
old timer age at epoch-2 suspicion: 2.422124069s
observer leave delay after epoch-2 suspicion: 22.561µs
consumer event: type=leave node=subject state=dead meta=epoch-1
subject local state at leave: state=alive meta=epoch-2
BUG: higher-incarnation evidence expired the old epoch before a fresh epoch's minimum timeout
downstream convergence: automatic_after_heal=true eventual_join=true; prior leave event remains delivered
--- PASS: TestBugCR2CrossIncarnationEvidenceAcceleratesOldTimer (4.15s)
PASS
ok  	command-line-arguments	4.156s
```

The test also passed three consecutive runs and against a clean archive of revision `1d81b5c`.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**. It uses exported transport configuration, `Join`, `UpdateNode`, normal probes, and whole-datagram loss; it injects no protocol messages or internal state.
2. Level 2/3 reachability justification: **not applicable**.
3. Real consumer: `state.go:1333` calls `EventDelegate.NotifyLeave`; `event_delegate.go:59` copies and forwards the wrong, prematurely generated leave event to the application.
4. Permanence/masking: the membership snapshot later converges after healing, but the application’s `NodeLeave` event has already been synchronously delivered and is never retracted. The later join does not mask that permanent consumer-visible event history.

## Recommendation

Bind each timer and confirmation set to `(node name, incarnation)`. A newer-incarnation suspicion should cancel the old timer, update state, and start a fresh epoch; only evidence for the exact same incarnation should shorten it.

Push/pull should preserve the original accusation root/provenance, or treat suspect/dead snapshots as state hints that cannot count as independent confirmation.

---
