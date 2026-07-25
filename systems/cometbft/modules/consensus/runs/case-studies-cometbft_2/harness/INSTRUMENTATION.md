# CometBFT Round-2 (BFT) Instrumentation Guide

Phase 3 reference for adjusting the round-2 trace harness when validation
surfaces mismatches.

## File layout

The harness writes four files into `artifact/cometbft/consensus/` on
`apply.sh`:

| File | Purpose |
|------|---------|
| `trace_emit.go` | `TraceLogger`, `TraceEvent`, `TraceStateSnap`, `TraceByzVote`, `captureState`, `traceNodeID`, `blockHashStr`, `stepString` |
| `bft_trace_emit.go` | Byzantine-helper emit methods (`EmitByzEquivocate`, `EmitByzAmnesia`, …) |
| `byz_state.go` | Shadow state on `*State`: `byzClock`, `byzSignedVotes`, `byzAdvanceClock`, `byzAddSignedVote` |
| `scenario_bft_trace_test.go` | 10 test scenarios that exercise honest + Byzantine paths |

`patch_state.py` rewrites `consensus/state.go` to insert 14 honest emit
points plus a `DetectEquivocation` emit inside `tryAddVote`.

## Trace event schema

Every line follows:

```json
{"tag":"trace","ts":"<RFC3339>","event":{
  "name":"<ActionName>", "nid":"<sN>",
  "state":{ "height", "round", "step",
            "lockedRound", "lockedValue",
            "validRound", "validValue",
            "validatorClock" },
  "msg":  { "source", "dest", "type", "value", "round",
            "polRound", "ve", "evtype", "lateAdd" },
  "byzVote": { "vtype", "height", "round", "oldRound",
               "newRound", "value", "ve" },
  "k": <int>
}}
```

`tag`, `name`, `nid`, `state.{height,round,step}` are present on every
event. `msg`/`byzVote`/`k` are present only on events that need them.

## Instrumentation points (after `apply.sh`)

Honest events emit from `consensus/state.go` (line numbers refer to the
patched file). Byzantine / harness-driven events are emitted directly from
the test scenarios via the `Emit*` helpers in `bft_trace_emit.go`.

### Honest emit sites in state.go (after patching)

Locations are approximate; grep `TLA+ trace:` to find them.

| Approx line | Event | Trigger |
|-------------|-------|---------|
| ~1058 | `HandleTimeoutPropose` | `case RoundStepPropose` in `handleTimeout` |
| ~1072 | `HandleTimeoutPrevote` | `case RoundStepPrevoteWait` in `handleTimeout` |
| ~1086 | `HandleTimeoutPrecommit` | `case RoundStepPrecommitWait` in `handleTimeout` |
| ~1190 | `EnterNewRound` | After `eventBus.PublishEventNewRound` |
| ~1255 | `EnterPropose` | `defer` block, after `updateRoundStep(Propose)` |
| ~1439 | `EnterPrevote` | `defer` block, after `updateRoundStep(Prevote)` |
| ~1542 | `EnterPrevoteWait` | `defer` block, after `updateRoundStep(PrevoteWait)` |
| ~1578 | `EnterPrecommit` | `defer` block, after `updateRoundStep(Precommit)` |
| ~1715 | `EnterPrecommitWait` | `defer` block, after `TriggeredTimeoutPrecommit = true` |
| ~1749 | `EnterCommit` | `defer` block, after `updateRoundStep(Commit)` |
| ~1934 | `FinalizeCommit` | After `updateToState(stateCopy)` |
| ~2096 | `ReceiveProposal` | After `cs.Proposal = proposal` in `defaultSetProposal` |
| ~2271 | `DetectEquivocation` | After `evpool.ReportConflictingVotes` in `tryAddVote` |
| ~2434 | `ReceivePrevote` / `ReceivePrecommit` | After `evsw.FireEvent(EventVote)` in `addVote` |

### Byzantine emit sites (in scenario_bft_trace_test.go)

Byzantine events are emitted via `cs.Emit<Name>(...)` helpers from
`bft_trace_emit.go`. Each helper signature documents the spec-side action
arguments. Helper methods do not alter consensus state; they only:

1. Optionally update shadow state (`byzSignedVotes`, `byzClock`)
2. Write one NDJSON event line via `cs.traceLogger.Emit(...)`

## Scenarios and event coverage

Each scenario writes to `traces/<name>.ndjson`; `run.sh` post-processes to
`<name>_mapped.ndjson`. Coverage matrix (35 distinct event types observed):

- **BasicConsensus** (15 events) — `EnterNewRound`, `EnterPropose`,
  `ReceiveProposal`, `EnterPrevote`, `ReceivePrevote`, `EnterPrecommit`,
  `ReceivePrecommit`, `EnterCommit`, `FinalizeCommit`
- **TimeoutPropose** (15 events) — adds `HandleTimeoutPropose`,
  `HandleTimeoutPrecommit`, `EnterPrecommitWait`
- **LockAndRelock** (28 events) — adds the lock/relock state captures
- **Equivocation** (17 events) — `ByzEquivocate`, `ByzSelectiveDisseminate`,
  `DetectEquivocation`
- **ByzAmnesia** — `ByzAmnesia`, `WALTailTruncate`
- **VEReuse** — `ByzAttachSameVEToBoth`, `ByzLateAddPrecommitWithBadVE`,
  `ByzReplaySelfVE`
- **LunaticFork** — `ByzLunaticForkHeader`, `LightClientVerify`
- **ProposerExclude** — `ProposerExcludeEvidence`,
  `ProcessConsensusBuffer`
- **EvidenceRace** — `AdvanceClock`, `Crash`, `Recover`,
  `CrashDuringConsensusBuffer`, `EvidenceExpiryRace`,
  `ByzInjectInvalidEvidence`, `ByzFloodEvidence`, `CommitEvidence`
- **ByzProposer** — `ByzProposeAlternating`, `ByzPolkaForUnknownBlock`,
  `ByzPOLRoundGtRound`

The three honest events not yet observed in any scenario
(`EnterPrevoteWait`, `HandleTimeoutPrevote`, `RoundSkip`) are covered by
`SilentReceivePrevote` and similar silent action wrappers in
`Trace.tla` — same as the round-1 harness. To force them to fire,
construct a scenario where prevotes arrive piecewise so that 2/3-any
holds before 2/3-quorum.

## Spec-side patches applied during harness work

`base.tla` had two TLA+ syntax errors that blocked TLC parsing. Both have
been fixed in-place — keep them in mind if you re-roll the spec:

1. `ProcessConsensusBuffer(i)` (line ~983): `buf'` is a reserved name
   (TLA+ prime operator) — renamed to `bufRest`.
2. `Next` clause (line ~1538): `\E s1, s2 \in Honest, ev \in pendingEvidence[s1]`
   collided with the constant `s1 = "s1"` from `Trace.cfg`; refactored to
   `\E s1' \in Honest : \E s2' \in Honest : \E ev \in pendingEvidence[s1'] : …`
   using `e1`/`e2` placeholders.

## Post-processing rules

`preprocess_trace.py` makes two passes:

- Pass 1: scan for `event.name` starting with `"Byz"` — those nids map to
  `s4` (the Faulty validator declared in `Trace.cfg`).
- Pass 2: assign `s1`, `s2`, `s3` to remaining nids in
  first-appearance order (skipping `s4`). LightClient IDs (`c1`, `c2`,
  …) pass through unchanged.

Block-hash strings (≥16 hex chars, all-hex) are mapped to `v1`, `v2`, …
on first appearance. Sentinels like `"nil"`, `"NilVote"`, `"NoVE"`,
`"ValidVE"`, `"InvalidVE"`, `"DuplicateVoteEv"`, `"LightClientAttackEv"`,
`"InvalidEv"` and any `vN` shorthand pass through unchanged.

If a scenario uses `Trace.cfg`'s constant `Values = {"v1", "v2"}`
directly (e.g., `ByzAmnesia` test emits `"v1"`/`"v2"`), the preprocessor
leaves them alone — they're already in spec form.

## How to add a new event

1. If the event is a new honest path, declare it in `Trace.tla` and
   `base.tla`, then add an `Emit` call to `state.go` near the relevant
   step transition. Insert the marker comment `// TLA+ trace:` and the
   `cs.traceLogger.Emit(...)` call manually OR extend `patch_state.py`.
2. If the event is harness-injected (Byzantine), add a method to
   `bft_trace_emit.go` following the pattern of `EmitByzEquivocate`,
   and call it from a test scenario.

## How to move a capture point (before → after)

Each emit site captures state via `cs.captureState()` which reads the
current `cs.RoundState`. To capture pre-state, move the emit BEFORE the
mutation; to capture post-state, after. Key mutations to be aware of:

- `cs.updateRoundStep(...)` changes `cs.Step` and `cs.Round`.
- `cs.LockedRound = ...` / `cs.LockedBlock = ...` change locking state
  (touched inside `enterPrecommit`).
- `cs.ValidRound = ...` / `cs.ValidBlock = ...` are set in
  `addVote` when a polka arrives.
- `cs.updateToState(...)` (inside `finalizeCommit`) advances height and
  resets per-height variables.

## How to add a new field

1. Add to `TraceStateSnap` / `TraceMsgFields` / `TraceByzVote` in
   `trace_emit.go`.
2. Populate at the emit site, or thread it into `captureState()` if it's
   universally captured.
3. Rebuild + rerun the trace; the JSON marshaller writes new fields
   automatically.

## Rebuild & rerun

```bash
cd .specula-output
bash harness/run.sh
```

Or for a single scenario:

```bash
cd artifact/cometbft
export TRACE_DIR=$PWD/../../.specula-output/traces
go test -v -run "TestScenarioEquivocation$" -timeout 60s ./consensus/
python3 ../../.specula-output/harness/preprocess_trace.py \
    "$TRACE_DIR/equivocation.ndjson" \
    "$TRACE_DIR/equivocation_mapped.ndjson"
```

## How to revert

`apply.sh` first runs `git checkout -- consensus/state.go` and removes
the four harness files; running it on a clean tree is idempotent. To do
it manually:

```bash
cd artifact/cometbft
git checkout -- consensus/state.go
rm -f consensus/{trace_emit,bft_trace_emit,byz_state,scenario_bft_trace_test}.go
```
