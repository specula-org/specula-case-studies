# Instrumentation Spec: Algorand BA*

Mapping from `Trace.tla` action wrappers to source code locations in
`agreement/` (`v4.7.0-stable`). One trace event per spec action.

---

## Section 1: Trace Event Schema

### Event envelope (every event)

```json
{
  "tag": "trace",
  "event": {
    "name":  "<spec action name>",
    "nid":   "<validator ID, e.g., n1>",
    "state": { ... },
    "vote":  { ... },          // optional, see per-action notes
    "msg":   { ... }           // optional, for Receive* events
  }
}
```

### State fields (captured at every event)

| Trace field | Implementation source | TLA+ variable |
|---|---|---|
| `state.round`           | `p.Round`           | `round[i]` |
| `state.period`          | `p.Period`          | `period[i]` |
| `state.step`            | `int(p.Step)`       | `step[i]` (after `StepFromInt` mapping) |
| `state.lastConcluding`  | `int(p.LastConcluding)` | `lastConcluding[i]` |
| `state.persistedRound`  | shadow field; see special considerations | `persistedRound[i]` |
| `state.persistedPeriod` | shadow field | `persistedPeriod[i]` |
| `state.persistedStep`   | shadow field | `persistedStep[i]` |
| `state.fastRecovery`    | `p.FastRecoveryDeadline > 0` -> integer counter (1 + N fires) | `fastRecovery[i]` |
| `state.partitioned`     | `p.partitioned()` boolean | (derived) |
| `state.decision`        | last `ensureAction.Payload.value()` recorded per round | `decision[i][r]` |

### Vote fields (on Issue*Vote, BroadcastVote)

| Trace field | Implementation source | TLA+ field |
|---|---|---|
| `vote.sender` | `a.Sender` / `vote.R.Sender` (pseudonode address) | `vt.sender` |
| `vote.round`  | `a.Round` / `vote.R.Round`                | `vt.round` |
| `vote.period` | `a.Period` / `vote.R.Period`              | `vt.period` |
| `vote.step`   | `int(a.Step)` / `int(vote.R.Step)`        | `vt.step` (after `StepFromInt`) |
| `vote.value`  | `a.Proposal.BlockDigest` (or `"Bottom"`)  | `vt.value` |
| `vote.origPeriod` | `a.Proposal.OriginalPeriod`           | `vt.origPeriod` |

### Threshold fields (on UpdateNextThresholdCache/UpdateFreshest/UpdateStaging/Handle*Threshold/EnterPeriod*)

| Trace field | Source | TLA+ |
|---|---|---|
| `state.thresholdType` | `e.t().String()` (`"softThreshold"`, etc.) | `et` (after `ThresholdTFromStr`) |
| `state.thresholdPeriod` | `e.Period` of the threshold event | `ep` |
| `state.thresholdValue`  | `e.Proposal.BlockDigest` or `"Bottom"` | `ev` |

### Catchup fields (on CatchupInstall)

| Trace field | Source | TLA+ |
|---|---|---|
| `state.round` | `cert.Round` | `r` |
| `state.installedValue` | `cert.Proposal.BlockDigest` | `v` |

### Message fields (on Receive*)

| Trace field | Source | TLA+ |
|---|---|---|
| `msg.broadcaster` | `vote.R.Sender` or bundle sender | `m.broadcaster` |
| `msg.round`  | `msg.Round` | `m.round` |
| `msg.period` | `msg.Period` | `m.period` |
| `msg.value`  | `msg.Proposal.BlockDigest` | `m.value` |

---

## Section 2: Action-to-Code Mapping

### IssueSoftVote

| Field | Value |
|---|---|
| Spec action | `IssueSoftVote(i)` (base.tla) |
| Code location | `agreement/player.go:170-206` (`player.issueSoftVote`) |
| Trigger point | After `return append(actions, a)` / before `return nil` — i.e., right at each return path. Capture the resulting action list (`actions`) — emit an event ONLY if a soft-vote pseudonodeAction was appended. |
| Trace event name | `"IssueSoftVote"` |
| Fields | envelope `state` + `vote` (only if a vote is signed; otherwise emit with `vote=null` and `outcome="abstain"`) |
| Notes | Five return paths: Path A (line 188), Path B (line 193 no vote), Path C (line 199 vote / line 201 reject), Path D (line 205). The spec uses LET branches; the trace event differentiates by `vote != null`. |

### IssueCertVote

| Field | Value |
|---|---|
| Spec action | `IssueCertVote(i)` |
| Code location | `agreement/player.go:209-212` (`player.issueCertVote`) |
| Trigger point | At the start of the function (cert vote action is built immediately). |
| Trace event name | `"IssueCertVote"` |
| Fields | envelope + `vote` |

### IssueNextVote

| Field | Value |
|---|---|
| Spec action | `IssueNextVote(i)` |
| Code location | `agreement/player.go:214-242` (`player.issueNextVote`) |
| Trigger point | Just before `return actions` at line 241. Skip the `partitionPolicy` action's wrapping; the partition rebroadcast is captured separately by `PartitionPolicyRebroadcast`. |
| Trace event name | `"IssueNextVote"` |
| Fields | envelope + `vote` (Proposal may be `Bottom`) |

### IssueFastVote

| Field | Value |
|---|---|
| Spec action | `IssueFastVote(i)` |
| Code location | `agreement/player.go:244-274` (`player.issueFastVote`) |
| Trigger point | Just before `return append(actions, a)` at line 273. |
| Trace event name | `"IssueFastVote"` |
| Fields | envelope + `vote` (step in {late, redo, down}) |

### HandleFastTimeoutPrimer

| Field | Value |
|---|---|
| Spec action | `HandleFastTimeoutPrimer(i)` |
| Code location | `agreement/player.go:150-168` (`player.handleFastTimeout`), specifically lines 160-164 (first-fire branch) |
| Trigger point | After `p.FastRecoveryDeadline = lower + delta + lambda` is set on first fire. |
| Trace event name | `"HandleFastTimeoutPrimer"` |
| Fields | envelope only |

### PersistState

| Field | Value |
|---|---|
| Spec action | `PersistState(i)` |
| Code location | `agreement/actions.go:443` (`s.persistState(persistStateDone)`) and `agreement/service.go:281-284` |
| Trigger point | After the persistence write completes (i.e., when `persistStateDone` is closed without error). |
| Trace event name | `"PersistState"` |
| Fields | envelope (with persisted* fields capturing the just-persisted snapshot) |
| Notes | Shadow fields `persistedRound/Period/Step` need to be added to a struct in `service.go` and updated on successful persist. |

### BroadcastVote

| Field | Value |
|---|---|
| Spec action | `BroadcastVote(i)` |
| Code location | `agreement/pseudonode.go:484` (the `t.out <- messageEvent{T: voteVerified, ...}` send) |
| Trigger point | Right BEFORE the send to `t.out`. |
| Trace event name | `"BroadcastVote"` |
| Fields | envelope + `vote` |
| Notes | One trace event per vote broadcast. Self-injection through the demux is the same wire emission; one event covers both wire send and self-receive. |

### ProposeBlock

| Field | Value |
|---|---|
| Spec action | `ProposeBlock(i)` |
| Code location | `agreement/pseudonode.go:380-440` (`pseudonodeProposalsTask.execute`) — at the point a verified proposal is sent on `t.out` (similar to vote broadcast around line 484). |
| Trigger point | When the proposal-vote (Step = propose) is sent. |
| Trace event name | `"ProposeBlock"` |
| Fields | envelope + `vote` (step=propose) |

### PartitionPolicyRebroadcast

| Field | Value |
|---|---|
| Spec action | `PartitionPolicyRebroadcast(i)` |
| Code location | `agreement/player.go:512-568` (`player.partitionPolicy`), specifically lines 519-525 (bundle rebroadcast). |
| Trigger point | After `a0 := broadcastBundleAction(b); actions = append(actions, a0)` at line 524. |
| Trace event name | `"PartitionPolicyRebroadcast"` |
| Fields | envelope + threshold fields capturing the rebroadcast bundle's `etype/period/value` |

### EnterPeriodViaSoftThreshold / EnterPeriodViaNextThreshold

| Field | Value |
|---|---|
| Spec action | `EnterPeriodViaSoftThreshold(i, t, v)` / `EnterPeriodViaNextThreshold(i, t, v)` |
| Code location | `agreement/player.go:405-446` (`player.enterPeriod`) |
| Trigger point | At line 414 (just after `p.Period = target`). Differentiate by `source.t()`: `softThreshold` -> `EnterPeriodViaSoftThreshold`, `nextThreshold` -> `EnterPeriodViaNextThreshold`. |
| Trace event name | `"EnterPeriodViaSoftThreshold"` or `"EnterPeriodViaNextThreshold"` |
| Fields | envelope + threshold fields (source.Period / source.Proposal) |
| Notes | At line 422 the `lowestCredentialArrivals.reset()` happens for non-zero target — the trace event should fire AFTER this reset so the state snapshot reflects `filterHistoryFull = false`. |

### EnterRound

| Field | Value |
|---|---|
| Spec action | `EnterRound(i, target)` |
| Code location | `agreement/player.go:448-502` (`player.enterRound`) |
| Trigger point | At line 464 (just after `p.Round = target`). |
| Trace event name | `"EnterRound"` |
| Fields | envelope + `state.round = target` |

### HandleSoftThresholdSamePeriod

| Field | Value |
|---|---|
| Spec action | `HandleSoftThresholdSamePeriod(i, p, v)` |
| Code location | `agreement/player.go:377-390`, lines 387-389 (the `actions = append(actions, p.issueCertVote(r, ec.(committableEvent)))` branch). |
| Trigger point | At line 388. |
| Trace event name | `"HandleSoftThresholdSamePeriod"` |
| Fields | envelope + threshold fields |

### HandleCertThresholdLocal

| Field | Value |
|---|---|
| Spec action | `HandleCertThresholdLocal(i, p, v)` |
| Code location | `agreement/player.go:354-375`, specifically lines 360-368 (`stagedValue committable -> ensureAction -> enterRound`). |
| Trigger point | After line 365 (`actions = append(actions, a0)`) but BEFORE the `enterRound` call. |
| Trace event name | `"HandleCertThresholdLocal"` |
| Fields | envelope + threshold fields + `state.decision` |

### UpdateNextThresholdCache

| Field | Value |
|---|---|
| Spec action | `UpdateNextThresholdCache(i, r, p, v)` |
| Code location | `agreement/voteAuxiliary.go:71-77` (`voteTrackerPeriod.handle` nextThreshold case). |
| Trigger point | After lines 74 (`t.Cached.Bottom = true`) or 76 (`t.Cached.Proposal = ...`). One event per cache mutation. |
| Trace event name | `"UpdateNextThresholdCache"` |
| Fields | envelope + threshold fields. `state.thresholdValue = "Bottom"` if the bottom branch fired; else the proposal value. |

### UpdateFreshest

| Field | Value |
|---|---|
| Spec action | `UpdateFreshest(i, r, et, ep, ev)` |
| Code location | `agreement/voteAuxiliary.go:144-150` (`voteTrackerRound.handle` threshold case). |
| Trigger point | After line 146 (`t.Freshest = e.(thresholdEvent)`). |
| Trace event name | `"UpdateFreshest"` |
| Fields | envelope + threshold fields |
| Notes | When `fresherThan` returns false, no state change — DO NOT emit an event in that branch. |

### UpdateStaging

| Field | Value |
|---|---|
| Spec action | `UpdateStaging(i, r, p, v)` |
| Code location | `agreement/proposalTracker.go:203-211` (softThreshold / certThreshold cases). Also `agreement/proposalStore.go:323-346` for the proposalStore-level dispatch. |
| Trigger point | After line 205 (`t.Staging = e.Proposal`). Skip if `t.Staging != bottom` before the assignment (the per-tracker.go:172 guard already filtered duplicates in the verified-vote path; staging is only re-set via threshold events which we capture here). |
| Trace event name | `"UpdateStaging"` |
| Fields | envelope + threshold fields |

### CatchupInstall

| Field | Value |
|---|---|
| Spec action | `CatchupInstall(r, v)` |
| Code location | `catchup/service.go:812` (`s.ledger.EnsureBlock(block, cert)` in `fetchRound`). |
| Trigger point | Immediately AFTER `EnsureBlock` returns. |
| Trace event name | `"CatchupInstall"` |
| Fields | envelope (`nid` = local node) + `state.round = cert.Round` + `state.installedValue = cert.Proposal.BlockDigest` |
| Notes | Per Family 1, this is the action that races with `BroadcastVote`. |

### Crash / Recover

| Field | Value |
|---|---|
| Spec action | `Crash(i)` / `Recover(i)` |
| Code location | Crash: no in-process site — fault injected externally (e.g., by harness `SIGKILL` or test framework). Recover: `agreement/persistence.go` `restore()` invoked at `agreement/service.go:200` during startup. |
| Trigger point | Crash: the harness emits a synthetic `"Crash"` event before killing the process. Recover: at the end of `restore()` after volatile state has been re-initialized from disk. |
| Trace event name | `"Crash"` / `"Recover"` |
| Fields | envelope (state reflects pre-crash / post-restore snapshot) |

### ReceiveVote / ReceiveBundle / ReceiveProposal

| Field | Value |
|---|---|
| Spec action | `ReceiveVote(i, m)` / `ReceiveBundle(i, m)` / `ReceiveProposal(i, m)` |
| Code location | `agreement/voteAggregator.go:130-200` (voteAccepted dispatch). For proposals: `agreement/proposalManager.go:251-290` (`filterProposalVote`). For bundles: `agreement/player.go:747-763` (bundleVerified case). |
| Trigger point | After the receive path has accepted the message (i.e., `voteAccepted` event has been dispatched to `voteTrackerRound`). |
| Trace event name | `"ReceiveVote"` / `"ReceiveBundle"` / `"ReceiveProposal"` |
| Fields | envelope + `vote` (for ReceiveVote) or `msg` (for ReceiveBundle/ReceiveProposal) |

### CalculateFilterTimeoutShort / CalculateFilterTimeoutDefault

| Field | Value |
|---|---|
| Spec action | `CalculateFilterTimeoutShort(i)` / `CalculateFilterTimeoutDefault(i)` |
| Code location | `agreement/player.go:317-347` (`player.calculateFilterTimeout`). Short = clamped dynamic branch (line 346); Default = static (lines 322-324 or line 343). |
| Trigger point | Just before return. |
| Trace event name | `"CalculateFilterTimeoutShort"` or `"CalculateFilterTimeoutDefault"` |
| Fields | envelope |

### RecordCredentialArrival

| Field | Value |
|---|---|
| Spec action | `RecordCredentialArrival(i)` |
| Code location | `agreement/player.go:287-315` (`player.updateCredentialArrivalHistory`), specifically line 313 (`p.lowestCredentialArrivals.store(...)`). |
| Trigger point | After line 313. |
| Trace event name | `"RecordCredentialArrival"` |
| Fields | envelope (capture `filterHistoryFull` derived from `p.lowestCredentialArrivals.isFull()`) |

---

## Section 3: Special Considerations

### Shadow persisted fields

The implementation does not expose `persistedRound/Period/Step` directly. Add
shadow fields on `agreement.Service` (or on the player snapshot used by
`persistState`) and update them inside `Service.persistState` after the
encoded buffer has been flushed. The shadow fields drive the trace event's
`state.persistedRound/Period/Step` fields.

### Pseudonode multi-key

A pseudonode may carry multiple participation keys; each key is modeled in the
spec as a distinct `Server`. The instrumentation should emit one
`IssueSoftVote`/`IssueCertVote`/etc. event per key, with the corresponding
`nid` derived from `vote.R.Sender`.

### Self-injected votes

`pseudonode.go:484` pushes `voteVerified` back into the player. This means a
single broadcast produces both a wire send AND a self-receive. The trace
should emit ONLY `BroadcastVote` here — the spec models the self-injection
inside `BroadcastVote` (`votesSeen` is updated atomically). Do NOT emit a
separate `ReceiveVote` for the sender's own vote.

### Compound messages

`broadcastCompoundAction` packages a proposal-payload with a proposal-vote.
The spec models these as TWO actions: `ProposeBlock` (the propose-vote) and a
silent payload arrival modelled implicitly. Emit `ProposeBlock` once per
proposal; do not emit a separate "compound message" event.

### Pre-/post-action snapshot timing

For Issue* actions, the `state` snapshot must reflect the player state AFTER
the step transition (e.g., after `p.Step = cert` at player.go:116). For
EnterPeriod/EnterRound, snapshot AFTER all field assignments at the top of
the function (lines 414-417 / 463-468). For threshold cache updates, snapshot
AFTER the cache mutation.

### Trace event ordering

`Service.persistState` enqueues `persistCompleteEvents` BEFORE `voteEvents` to
the demux (actions.go:444-446). The trace must preserve this ordering:
`PersistState` event MUST appear before any `BroadcastVote` event for the same
(round, period, step). The Trace.tla wrapper enforces this via the
`persistedRound[i] >= vote.round` precondition.

### Threshold caches across periods

`UpdateNextThresholdCache` events should fire for the period referenced in the
threshold event, NOT the player's current period. The `state.round` and
`state.thresholdPeriod` fields are independent — `state.round = p.Round`
(player's current round) but `state.thresholdPeriod = e.Period` (event's
period).

### Catchup events emitted from a different goroutine

`fetchRound` runs on the catchup goroutine, not on `mainLoop`. The trace will
have `CatchupInstall` events interleaved arbitrarily with player events. The
Trace.tla cursor model assumes a single linear sequence; the harness MUST
serialize events through a single trace-writer goroutine to preserve a total
order.

### Byzantine / fork events

`ByzantineVote` and `ForkCommitteeView` are MC-only fault wrappers — they have
no corresponding source code, only model-injection. The trace will not contain
these events from a real execution; trace validation only covers honest
behavior.
