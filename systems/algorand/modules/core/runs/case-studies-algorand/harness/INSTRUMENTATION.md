# Algorand BA* Instrumentation Guide

This document is for the Phase 3 (trace validation) agent. It explains how
the harness is laid out, what each instrumentation point captures, what is
currently *not* captured, and how to adjust things when trace validation
points at a mismatch.

---

## 1. File map after `apply.sh`

After running `bash harness/apply.sh`, the artifact looks like this (only
modified or added files are listed):

| File | Source of change | What it does |
|---|---|---|
| `agreement/tla_trace.go` | new (copied from `harness/src/agreement/tla_trace.go`) | The trace emitter (envelope writer, server-ID map, emit-per-action helpers). |
| `agreement/agreementtest/spec_trace_test.go` | new (copied from `harness/src/agreementtest/spec_trace_test.go`) | Test scenarios. Each `TestTrace_*` runs the Simulate driver under trace emission and writes to `$SPECULA_TRACE_DIR/<scenario>.ndjson`. |
| `agreement/player.go` | patched by `patches/instrumentation.patch` | `IssueSoftVote`, `IssueCertVote`, `IssueNextVote`, `IssueFastVote`, `HandleFastTimeoutPrimer`, `EnterPeriod*`, `EnterRound`, `HandleSoftThresholdSamePeriod`, `HandleCertThresholdLocal`, `PartitionPolicyRebroadcast`, `CalculateFilterTimeout*`, `RecordCredentialArrival` |
| `agreement/pseudonode.go` | patched | `BroadcastVote` (line ~482 in patched file) and `ProposeBlock` (line ~589) |
| `agreement/actions.go` | patched | `PersistState` (inside `checkpointAction.do`) |
| `agreement/voteAuxiliary.go` | patched | `UpdateNextThresholdCache`, `UpdateFreshest` |
| `agreement/proposalTracker.go` | patched | `UpdateStaging` |
| `agreement/voteAggregator.go` | patched | `ReceiveVote` |
| `agreement/proposalManager.go` | patched | `ReceiveProposal` |

To revert: `git -C artifact/go-algorand checkout -- agreement/` and then
remove `agreement/tla_trace.go` and `agreement/agreementtest/spec_trace_test.go`.

`apply.sh` is idempotent — running it again first reverts, then re-applies.

## 2. Envelope and field reference

Every line in a trace is one NDJSON envelope:

```json
{ "tag": "trace",
  "ts":  <int64 nanoseconds>,
  "event": {
    "name":  "<spec action name>",
    "nid":   "<server id>",
    "state": { ... },
    "vote":  { ... }      // optional
    "msg":   { ... }      // optional
  } }
```

`state` always carries `round, period, step, lastConcluding, persistedRound,
persistedPeriod, persistedStep, fastRecovery, partitioned`. Threshold-related
events also carry `thresholdType, thresholdPeriod, thresholdValue`.
`HandleCertThresholdLocal` additionally carries `decision`. `CatchupInstall`
carries `installedValue`.

`vote` carries `sender, round, period, step, value, origPeriod` (Issue*Vote,
BroadcastVote, ProposeBlock, ReceiveVote). `msg` carries `broadcaster (optional),
round, period, value` (ReceiveProposal, ReceiveBundle).

The TLA+ spec maps these via `StepFromInt` and `ThresholdTFromStr` in
`Trace.tla` — match those mappings if you change field encodings.

## 3. Server ID mapping

`SpecTraceRegisterServer(addr, id)` lets the test setup pre-register each
participation address with a chosen ID (`n1`, `n2`, ...). On unknown addresses,
`specTraceNidLocked` assigns sequential IDs in arrival order. The test
scenarios all pre-register, so traces have predictable sender IDs.

The synthetic ID `"local"` is used for `nid` on events that represent player-
level decisions (`IssueSoftVote`, `EnterRound`, threshold handlers, etc.).
This is because the agreement service is a single pseudonode managing
multiple participation keys; a player-level action doesn't have a single
"sender" until the per-key votes are produced later in `pseudonode.makeVotes`.
`BroadcastVote` and `ProposeBlock` are per-vote — they use `vote.R.Sender`
as `nid`.

If the spec validator complains that `"local"` is not in `Server`, the
quickest fix is to either:

- Add `"local"` to the `Server` set in `Trace.cfg`, or
- Update the trace module to use `"n1"` (or the first registered ID) for
  player-level events instead of `"local"`. Edit `specLocalNid` in
  `agreement/tla_trace.go`.

## 4. Adjusting an instrumentation point

### Adding a new field to an event

1. Add the field to `specPlayerState`, `specVote`, or `specMsg` in
   `harness/src/agreement/tla_trace.go`. Use a JSON tag with `omitempty` if
   it is event-specific.
2. Populate the field in the appropriate `SpecTrace…` emitter.
3. Re-run `bash harness/run.sh`.

### Adding a new event type

1. Define a new `SpecTrace<EventName>(...)` function in
   `harness/src/agreement/tla_trace.go` following the existing pattern.
2. Add a call site in the artifact source. Edit the file in `artifact/`
   directly (it will be re-patched on next `apply.sh`).
3. Capture the diff: from `artifact/go-algorand/`, run

   ```bash
   git diff agreement/ > /path/to/harness/patches/instrumentation.patch
   ```
4. Add the new event name + wrapper to `Trace.tla` and `Trace.cfg` if it
   should be validated.

### Moving a capture point (before → after)

The instrumentation spec is strict about whether state is snapshotted before
or after a mutation. Search for the relevant `SpecTrace…` call in
`artifact/go-algorand/agreement/`, move it to the desired side of the
mutation, regenerate the patch (see "Adding a new event type" above), and
re-run.

### Rebuilding and re-running

```bash
# from .specula-output/
bash harness/run.sh
```

If you only changed test scenarios (no patch changes), you can iterate
faster with:

```bash
cd ../artifact/go-algorand
export PATH=/usr/local/go/bin:$PATH
SPECULA_TRACE_DIR=$PWD/../../.specula-output/traces \
  go test -count=1 -timeout 200s -run TestTrace_NormalAgreement \
  ./agreement/agreementtest/
```

## 5. What is *not* captured (caveats for Phase 3)

### Event types absent from current traces

The four scenarios run a single agreement service in `Simulate` (a
single-pseudonode driver) for 3–6 rounds with no fault injection. As a
result the trace contains the happy-path event types only:

| Event | Captured? |
|---|---|
| `ProposeBlock` | ✓ |
| `IssueSoftVote` | ✓ |
| `IssueCertVote` | ✓ |
| `IssueNextVote` | ✗ — only fires when a period 0 fails the soft step. Trigger with a partition scenario. |
| `IssueFastVote` | ✗ — requires `Partitioned(i)` to hold, i.e. step ≥ 6 or period ≥ 3. |
| `HandleFastTimeoutPrimer` | ✗ — same as above. |
| `PersistState` | ✓ |
| `BroadcastVote` | ✓ |
| `EnterPeriodViaSoftThreshold` | ✗ — happy path advances by `EnterRound`. |
| `EnterPeriodViaNextThreshold` | ✗ — same. |
| `EnterRound` | ✓ |
| `HandleSoftThresholdSamePeriod` | ✓ |
| `HandleCertThresholdLocal` | ✓ |
| `UpdateNextThresholdCache` | ✗ — only happens on next-threshold formation, which is not reached on the happy path. |
| `UpdateFreshest` | ✓ |
| `UpdateStaging` | ✓ |
| `PartitionPolicyRebroadcast` | ✗ — requires `Partitioned(i)`. |
| `CalculateFilterTimeoutShort` | ✗ — requires `filterHistoryFull && period==0`, which needs > 40 rounds of history. |
| `CalculateFilterTimeoutDefault` | ✓ |
| `RecordCredentialArrival` | ✗ — also needs many rounds for the history window. |
| `CatchupInstall` | ✗ — no catchup service runs in Simulate. |
| `Crash` / `Recover` | ✗ — no fault injection in the current scenarios. |
| `ReceiveVote` | ✓ |
| `ReceiveProposal` | ✓ |
| `ReceiveBundle` | ✗ — no bundles are produced on the happy path. |

To exercise the missing types you need new scenarios. The instrumentation
itself is in place — instructions:

- **Partition / next-vote / fast-recovery events**: write a scenario that
  drops a fraction of proposal-votes between specific accounts so the soft
  step fails to reach quorum. The existing `fuzzer/` infrastructure
  (filter chain) is the right tool — adapt `nodeCrashFilter` or build a new
  drop filter.
- **Catchup events**: instrument `catchup/service.go:812` (the call to
  `s.ledger.EnsureBlock(block, cert)` inside `fetchRound`) with a call to
  `agreement.SpecTraceCatchupInstall(uint64(cert.Round), cert.Proposal.BlockDigest.String())`.
  Then drive a node behind on its ledger so that catchup runs.
- **Crash / Recover events**: extend a scenario to call
  `agreement.SpecTracePersistState(...)` and then crash the service via
  `Shutdown()` and reconstruct it from disk. The current trace module has
  no `SpecTraceCrash` / `SpecTraceRecover` helpers — add them following
  the `SpecTracePersistState` pattern.

### Known spec issue blocking trace validation

The generated `spec/base.tla` has a TLC parse error at **line 1182**, inside
the `PersistedBeforeBroadcast` invariant:

```tla
\A i \in Server, vt \in (UNION { {x \in votesSeen[j][r][p][st] : x.sender = i}
                                 : j \in Server, ... }) :
```

TLC rejects this with `Unknown operator: i.` because it does not support
multi-binding quantifiers where a later binder's range depends on an
earlier-bound variable. The fix is to nest the quantifiers:

```tla
PersistedBeforeBroadcast ==
    \A i \in Server :
        \A vt \in (UNION { {x \in votesSeen[j][r][p][st] : x.sender = i}
                           : j \in Server, r \in 0..MaxRound,
                             p \in 0..MaxPeriod,
                             st \in {StepSoft, StepCert, StepNext} }) :
            IsHonest(i) =>
                \/ persistedRound[i] > vt.round
                \/ /\ persistedRound[i] = vt.round
                   /\ \/ persistedPeriod[i] > vt.period
                      \/ persistedPeriod[i] = vt.period
```

Apply this small edit to `spec/base.tla` to unblock `run_trace_validation`.
This is a syntactic fix; the semantics of the invariant are unchanged.

### `"local"` nid vs `Server` set

`Trace.cfg` sets `Server = {n1, n2, n3, n4}`, but events from player-level
actions (e.g. `EnterRound`) carry `"nid": "local"`. The spec wrappers say
`\E i \in Server : IsNodeEvent(name, i) /\ ...`, which will reject
`nid = "local"` because `"local" \notin Server`.

**Two ways to handle this in Phase 3**:

1. Expand `Server` in `Trace.cfg` to include `"local"`:
   `Server = {n1, n2, n3, n4, local}`. The spec's `IsHonest` predicate
   considers anything not in `ByzServer` (`= {}`) honest, so this is safe.
2. Re-target player-level events to a real per-key sender. Edit
   `harness/src/agreement/tla_trace.go` and replace `specLocalNid` with the
   first registered address's ID (e.g. `"n1"`) in `SpecTraceIssueSoftVote`
   et al. Run `apply.sh` again. This collapses the "local" pseudonode to
   one specific server identity.

Option 1 is the lowest-effort path forward. Use it unless you specifically
need per-key player events.

### State capture levels (Trace.tla validator hints)

Most events use the **Full** state capture (`round, period, step,
persistedRound, persistedPeriod, persistedStep, lastConcluding,
fastRecovery, partitioned`). Exceptions:

- `BroadcastVote` and `ProposeBlock` capture `round/period/step` from the
  vote itself (these run in pseudonode goroutines that don't hold the player
  struct). `lastConcluding` and `partitioned` are set to defaults (0 / false).
  If the spec validator complains about post-state mismatches for these
  actions, switch to the `ValidatePostStateWeak` validator variant in
  `Trace.tla`.
- `PersistState` captures only the persist snapshot, not the player's
  current volatile state.

### `state.decision` (HandleCertThresholdLocal only)

The TLA+ spec models a per-round `decision[i]` map. `Trace.tla.ValidateDecision`
reads `logline.event.state.decision`. We populate this string only on
`HandleCertThresholdLocal`; other events leave it empty (omitted via
`omitempty`). If the validator needs `decision` on `EnterRound` or other
events, extend the relevant `SpecTrace…` function to thread `decision` from
the caller.

### Bundle messages (`ReceiveBundle`)

We don't instrument bundles. The happy path doesn't produce them. If a
partition scenario fires `PartitionPolicyRebroadcast`, the receiving side
will need a `SpecTraceReceiveBundle` emitter — pattern off `SpecTraceReceiveVote`.
The right hook is in `agreement/voteAggregator.go` inside the `bundleVerified`
case (`agg.handle`).

### Validation-time issues observed during harness generation

A first pass of `run_trace_validation` (after the `PersistedBeforeBroadcast`
parse fix above is applied) parses cleanly but stops at cursor `l = 1`: no
action wrapper matches the first trace event. The root cause is a triple
mismatch between the trace's initial event and the spec's `Init` state.

#### Issue A: trace starts at round 1, spec `Init` at round 0

The `testLedger` in `agreementtest/simulate_test.go` initializes
`nextRound = 1`, so the Algorand agreement service starts producing votes
for round 1. The TLA+ `Init` has `round = [s \in Server |-> 0]`, and the
`ProposeBlock(i)` action requires `i \in committeeView[i][round[i]]...`
which means the player must be at round 1 before `ProposeBlock` can fire.

There is no `EnterRound(i, 1)` event in the trace because the test never
transitions through round 0 → 1; it starts directly at round 1.

**Fix options** (pick one):

1. **Adjust `Init`**: replace `round = [s \in Server |-> 0]` with
   `round = [s \in Server |-> 1]` in `base.tla`. Also bump
   `ledgerCertified` initialization to mark round 0 as a genesis block
   (e.g. `ledgerCertified = [r \in 0..MaxRound |-> IF r = 0 THEN "genesis" ELSE Nil]`).
2. **Bootstrap silent action**: add a `SilentBootstrapEnterRound` action to
   `Trace.tla` that consumes no trace event and bumps round from 0 to 1
   for all servers. Constrain it to fire only when `l = 1`.
3. **Emit synthetic EnterRound at startup**: edit
   `harness/src/agreement/tla_trace.go` to add a `SpecTraceBootstrap()`
   function that emits one `EnterRound` event per registered server with
   `state.round = 1`. Call it from each test scenario before `Simulate(...)`.

Option 1 is the smallest change to the spec; option 3 is the smallest
change to the harness.

#### Issue B: BroadcastVote/ProposeBlock state mirrors the vote, not the player

The instrumentation for `BroadcastVote` and `ProposeBlock` lives in
`agreement/pseudonode.go`, inside `pseudonodeVotesTask.execute` and
`pseudonodeProposalsTask.execute`. Those tasks run in their own goroutines
and **do not have access to the player struct** — by the time they reach
the `t.out <- voteVerified` send, the player has already advanced past the
attest action. So `SpecTraceBroadcastVote` and `SpecTraceProposeBlock`
fill `state.round/period/step` from the vote's `R.Round/R.Period/R.Step`
rather than the player's instantaneous state.

For the spec's `ValidatePostState(i)` predicate (which compares against
`round'[i]/period'[i]/step'[i]`), this means:

- For `BroadcastVote`: `state.round/period/step` equal the vote's
  coordinates. After `BroadcastVote(i)` the spec's `step'[i]` is unchanged
  from before. So the trace's `state.step` will match the spec's `step[i]`
  only if the player was at that step when it created the vote — which is
  not guaranteed by the time the broadcast goroutine runs.
- For `ProposeBlock`: the vote's step is `propose` (= 0), but the player
  is at step `soft` (= 1) the entire time. So `state.step = 0` while the
  spec's `step'[i] = StepSoft = 1`. **This always mismatches.**

**Fix options**:

1. **Weaken validation for these events**: in `Trace.tla`, change
   `BroadcastVoteIfLogged` and `ProposeBlockIfLogged` to omit
   `ValidatePostState(i)` (or only check `round`, not step). The
   instrumentation spec calls this the "Weak" capture level.
2. **Capture player state at the attest point**: in `tla_trace.go`, add a
   global `playerSnapshot map[voteKey]playerState`. Populate it at each
   `SpecTraceIssueXxx`/at the `pseudonodeAction{T: attest}` creation site
   in `actions.go`. Read it in `SpecTraceBroadcastVote` instead of using
   `v.R.*`. This is the more faithful capture but requires more harness
   plumbing.

Option 1 is the cheaper fix and matches the instrumentation-spec note
that says "ProposeBlock / BroadcastVote use a specialized capture level."

#### Issue C: `nid = "local"` not in Server set

See section 5 above. The first events emitted by the trace ARE
`ProposeBlock` events with `nid = "n1"` (per-key), so this issue does not
block validation of the first event — but every player-level event
afterwards (e.g. `EnterRound`, `IssueSoftVote`) carries `nid = "local"`.
Apply the section-5 fix to make these validate.

---

## 6. Running an isolated debug iteration

After `apply.sh` has been run, you can run a single scenario without
re-applying:

```bash
cd ../artifact/go-algorand
export PATH=/usr/local/go/bin:$PATH
SPECULA_TRACE_DIR=/tmp/dbg \
  go test -count=1 -timeout 60s -run TestTrace_ShortRun -v ./agreement/agreementtest/
head -5 /tmp/dbg/short_run.ndjson | python3 -m json.tool
```

If you edit `tla_trace.go` (in the harness src OR in the artifact), copy
both directions to keep them in sync, then re-run `go test`. `apply.sh`
copies from harness → artifact; doing the reverse copy is up to you.
