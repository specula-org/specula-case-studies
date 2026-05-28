# Babylon Trace Harness — Instrumentation Guide

This document is for Phase 3 (Spec Validation) agents who need to adjust
instrumentation when trace validation reveals issues.

---

## TL;DR

- Trace emission lives in **`x/tlatrace/tlatrace.go`** (mutex-guarded NDJSON
  writer, enabled via `BABYLON_TLA_TRACE_FILE`).
- Trace scenarios live in **`x/tlatrace_scenarios/scenarios_test.go`**
  (Go test framework, mock-based keepers from `testutil/keeper`).
- Instrumentation is inserted into real keeper files by
  **`harness/patches/apply.py`** (idempotent, anchor-based).
- One-shot: `bash harness/run.sh` → produces `traces/*.ndjson`.
- Revert: `bash harness/clean.sh` (uses `git checkout -- .`).

---

## Instrumentation Point Map

Each entry lists: spec action → file → trigger anchor → captured fields.

| Spec action | Source file | Trigger anchor | Captured `state.*` |
|---|---|---|---|
| `CommitPubRand` | `x/finality/keeper/msg_server.go` | After both `SetPubRandCommit` returns (right before each `return &types.MsgCommitPubRandListResponse{}, nil`) | `currentHeight` |
| `AddFinalitySigCanonical` | `x/finality/keeper/msg_server.go` | After `IncentiveKeeper.IndexRefundableMsg(...)` (canonical branch end) | `sigStoreAt`, `fpSlashed`, `fpJailed`, `fpHighestVoted`, `currentHeight` |
| `AddFinalitySigFork` | `x/finality/keeper/msg_server.go` | After `ms.SetEvidence(ctx, evidence)` (fork branch) | `sigStoreAt`, `fpSlashed`, `currentHeight` |
| `UnjailFp` | `x/finality/keeper/msg_server.go` | After `BTCStakingKeeper.UnjailFinalityProvider(...)` | `fpJailed`, `currentHeight` |
| `HandleLivenessAtHeight` | `x/finality/keeper/liveness.go` | Right before `if updated { Set(...) }` at end of `HandleFinalityProviderLiveness` | `missedCounter`, `fpJailed`, `currentHeight` |
| `ActivateFp` | `x/finality/keeper/power_dist_change.go` | Right before the final `return k.FinalityProviderSigningTracker.Set(...)` of `HandleActivatedFinalityProvider` | `fpActive`, `startHeight`, `missedCounter` |
| `DeactivateFp` | `x/finality/keeper/power_dist_change.go` | After `Logger(ctx).Info("a new finality provider becomes inactive", ...)` in `processInactiveFp` | `fpActive` |
| `ProcessPowerDistAtHeight` | `x/finality/keeper/power_dist_change.go` | After `k.processEventsAtHeight(sdkCtx, btcHeight, state)` (once per btcHeight) | `pendingLen`, `slashedFps` |
| `CreateBtcDelegation` | `x/btcstaking/keeper/msg_server.go` | Right before `return &types.MsgCreateBTCDelegationResponse{}, nil` | `delStatus` |
| `ActivateBtcDelegation` | `x/btcstaking/keeper/msg_server.go` | Right before `return &types.MsgAddBTCDelegationInclusionProofResponse{}, nil` | `delStatus` |
| `UnbondBtcDelegation_Intent` | `x/btcstaking/keeper/msg_server.go` | Right before `return &types.MsgBTCUndelegateResponse{}, nil` | `delStatus` |
| `BtcReorgDeep` | `x/btcstaking/keeper/btc_reorg.go` | Inside `HaltIfBtcReorgLargerThanConfirmationDepth`, right before the `panic(...)` | `chainHalted`, `msg.depth` |
| `CheckCheckpointsLoop` | `x/btccheckpoint/keeper/keeper.go` | `defer` at entry of `checkCheckpoints` (fires on return) | `lastFinalizedEpoch` |
| `SubmitBTCProof` | `x/btccheckpoint/keeper/msg_server.go` | Right before `return &types.MsgInsertBTCSpvProofResponse{}, nil` | `btcEpochStatus`, `localCkptStatus` |
| `AdvanceHeight` | `x/finality/keeper/indexed_blocks.go` | After `types.RecordLastHeight(...)` in `IndexBlock` | `currentHeight` |
| `TallyBlock` | `x/finality/keeper/tallying.go` | After `block.Finalized = true` | `finalized` |

Each insertion is bracketed with `// SPECULA_TRACE <TAG>_BEGIN ... END` so
the patch is **idempotent** — re-running `apply.sh` is a no-op.

Not currently instrumented (see "Open gaps" below):
- `ExtendVoteHonest`, `ByzantineExtendVote`, `HonestPropose`,
  `ByzantineProposeDropValid`, `ProcessProposal_ConflictDetect`,
  `BtcLightClientAdvance`, `BtcReorgShallow`, `BtcStakeExpand`.

These require setting up the checkpointing + BTC-light-client stack,
which the current keeper-test scenarios do not exercise.  Add them by
hooking into `x/checkpointing/...` and `x/btclightclient/keeper/msg_server.go`
following the same anchor pattern.

---

## Adding a New Field to an Event

1. Open `harness/patches/apply.py`.
2. Find the `insert_after(...)` (or hand-rolled `text.replace(...)`) call
   for the target event.
3. Add the new key to the `Msg` or `State` map literal.  Use only Go
   expressions reachable in the surrounding scope; the patch is inserted
   verbatim into the keeper function body.
4. Re-run `harness/clean.sh && harness/apply.sh` and re-build.
5. If the new field is meant to be validated, add a matching check in
   `Trace.tla`'s `ValidatePostState*` predicate.

For block-hash-valued fields, wrap with `tlatrace.Hash(...)` so the value
is mapped into the abstract `{h1, h2, h3}` set the spec expects.

For finality-provider hex strings, wrap with `tlatrace.Fp(...)`.

For validator addresses, wrap with `tlatrace.Val(...)`.

---

## Adding a New Event Type

1. Pick a real keeper function whose post-condition matches the spec
   action.  The function MUST be called by both the production code path
   *and* a test scenario you can drive.
2. Add a new `patch_*` function in `apply.py` following the existing
   pattern (`insert_after` for simple insertions; the `text.replace`
   pattern for "insert before return" cases).
3. Wire it up in `main()` between the existing patch calls.
4. Add a wrapper in `Trace.tla` (`<Action>IfLogged`) and reference it
   from `TraceNext`.

---

## Moving a Capture Point

If a trace event must be captured at a different anchor (e.g., the post-
state in the current location doesn't reflect what the spec checks):

1. In `apply.py`, change the `anchor` string and (if needed) the inserted
   payload to refer to the new variables in scope.
2. Increment / rename the `MARKER` tag so the idempotency guard doesn't
   skip the new insertion (e.g., `CANONICAL_V2_BEGIN`).
3. Re-run `clean.sh && apply.sh` and re-build.

---

## How to Run

```bash
# from .specula-output/
bash harness/run.sh
```

`run.sh` does, in order:
1. Applies instrumentation (`apply.sh`).
2. Ensures Go 1.25.8 is downloaded via `GOTOOLCHAIN=auto` (Babylon's
   `go.mod` pin).
3. Runs each scenario with a fresh `BABYLON_TLA_TRACE_FILE` env.
4. Prints line counts under `traces/`.

Override Go binary with `GO_BIN=/path/to/go bash harness/run.sh`.

To clean: `bash harness/clean.sh` (calls `git checkout -- x/` in the
artifact and removes the copied `x/tlatrace`, `x/tlatrace_scenarios`
packages).

---

## Open gaps / known calibrations

These items surfaced during initial trace-validation runs; Phase 3 may
need to revisit them.

### 1. `Trace.cfg` constant types

`Validators`, `FinalityProviders`, `BlockHashes` are declared as **string
sets** (`{"v1", "v2", ...}`) in `Trace.cfg` because the NDJSON trace
deserializes node-IDs as strings.  Other case studies (e.g., `cometbft`)
follow the same convention.  Do not revert to bare `{v1, v2}` model
values without also adjusting the JSON encoding.

### 2. `base.tla` defensive disjunction for empty pub-rand commits

`base.tla`'s `CommitPubRand` action originally used:

```
\/ Len(pubRandCommits[fp]) = 0
\/ startH > CommitEndHeight(pubRandCommits[fp][Len(pubRandCommits[fp])])
```

TLC eagerly evaluates the index even when the first disjunct holds (with
`Len = 0`, `seq[0]` is out of bounds).  Rewritten as `IF/THEN/ELSE`.  If
you regenerate the base spec from Phase 2, re-apply this fix.

### 3. Bounds calibration

`Trace.cfg` uses `MaxBlockHeight=8`, `SignedBlocksWindow=3`,
`MaxBtcHeight=8`, `MaxEpoch=4`.  Scenarios must keep their
height/epoch/window numbers under these bounds.  The current liveness
scenario sets `params.SignedBlocksWindow = 3` explicitly.  If you bump
the cfg bounds, you can use default Babylon params (`SignedBlocksWindow
= 100`) but the model-checking state space will grow accordingly.

### 4. `CommitPubRand` retroactive scenario

`TestTraceScenarioCommitPubRandRetroactive` uses `startHeight = 10`, which
exceeds `MaxBlockHeight = 8` in the cfg.  The spec's upper-bound guard
`startH < currentHeight + (MaxBlockHeight - currentHeight + 1)` rejects
the trace as not enabled.  This is the spec faithfully modeling the bug
hypothesis (the upper bound IS checked; only the lower bound is missing).
To validate this trace fully, drop `startHeight` to 3 OR raise
`MaxBlockHeight` in `Trace.cfg`.

### 5. Mock-driven post-state under fork branch

`TestTraceScenarioFinality` configures the mock `BTCStakingKeeper.
SlashFinalityProvider` to mutate the in-memory `fp.SlashedBabylonHeight`
so subsequent `GetFinalityProvider` calls return `IsSlashed() == true`.
Without this `DoAndReturn`, the trace would report `fpSlashed:false`
even though the spec sets `fpSlashed' = TRUE` on the fork-slash path.

### 6. `UnjailFp` scenario lacks a prior jail event

`TestTraceScenarioUnjail` directly sets `fp.Jailed = true` in the mock
without going through `HandleFinalityProviderLiveness`.  The trace
contains only the `UnjailFp` event with no preceding `HandleLivenessAtHeight`-
induced jailing.  The spec requires `fpJailed[fp] = TRUE` as a
precondition for `UnjailFp`, so this trace will not match unless the
scenario is extended to actually drive the FP to jail first (similar
to what the liveness scenario already does).

### 7. End-of-trace "deadlock"

After the last trace line is consumed, TLC reports `Error: Deadlock
reached` because no `TraceNext` action can fire (the wrappers all
require `IsEvent(...)` which checks `l <= Len(TraceLog)`).  This is the
expected end-of-replay signal — the `TraceMatched` property
(`<>(l > Len(TraceLog))`) is satisfied at that moment.  Some tooling
reports this as `error`/`trace_mismatch`; inspect the state output to
confirm the trace was actually consumed (`l = Len(TraceLog) + 1`).

### 8. Coverage of bug families

| Family | Spec area | Trace coverage today |
|---|---|---|
| F1 EOTS double-sign | `AddFinalitySig*`, `evidenceMap`, `pubRandCommits` | **Covered** by `TestTraceScenarioFinality` + `TestTraceScenarioCommitPubRandRetroactive` |
| F2 Liveness/jailing bypass | `HandleLivenessAtHeight`, `ActivateFp` | **Covered** by `TestTraceScenarioLiveness` |
| F3 Checkpoint FSM + BTC reorg | `SubmitBTCProof`, `CheckCheckpointsLoop`, `BtcReorgDeep` | Instrumented but **no scenario**; add one driving the full checkpoint FSM |
| F4 Vote-extension aggregation | `ExtendVote*`, `HonestPropose`, `ByzantineProposeDropValid` | **NOT instrumented** — needs `x/checkpointing/vote_extensions/` instrumentation + a scenario |
| F5 Power-dist ordering | `ProcessPowerDistAtHeight`, `BtcStakeExpand` | Partially — `ProcessPowerDistAtHeight` is instrumented; `BtcStakeExpand` is not |

---

## File layout

```
.specula-output/
├── harness/
│   ├── apply.sh           # Wraps patches/apply.py
│   ├── clean.sh           # Reverts via git checkout
│   ├── run.sh             # Apply + build + run all scenarios + summary
│   ├── INSTRUMENTATION.md # This file
│   ├── patches/
│   │   └── apply.py       # Anchor-based source patching
│   └── src/
│       ├── tlatrace/      # Trace emission package (Go)
│       └── scenarios/     # Test scenarios (Go)
├── spec/
│   ├── base.tla
│   ├── Trace.tla
│   ├── Trace.cfg
│   └── instrumentation-spec.md
└── traces/
    ├── finality.ndjson
    ├── commitpubrand_retroactive.ndjson
    ├── liveness.ndjson
    └── unjail.ndjson
```

Post-apply (inside the artifact):

```
artifact/babylon/x/
├── tlatrace/              # Copied from harness/src/tlatrace/
│   └── tlatrace.go
├── tlatrace_scenarios/    # Copied from harness/src/scenarios/
│   └── scenarios_test.go
├── finality/keeper/       # Instrumented in-place
├── btcstaking/keeper/     # Instrumented in-place
└── btccheckpoint/keeper/  # Instrumented in-place
```
