# CometBFT round-3 Instrumentation Guide

Guide for Phase 3 to adjust instrumentation and trace generation when
trace validation surfaces issues.

---

## 1. Layout

The harness adds a tiny package under `artifact/cometbft/libs/tla_trace/` and
sprinkles single-line emit calls into existing source files. Everything except
the patch itself lives in the artifact tree post-apply.

| Path (relative to `artifact/cometbft/`) | Purpose |
|---|---|
| `libs/tla_trace/trace.go`                | Thread-safe NDJSON writer; envelope formatting; `MarkPeerByz`. |
| `libs/tla_trace/helpers.go`              | Builder types `State`, `Msg`, `Peer`. |
| `blocksync/tracehooks.go`                | Helpers for `SetPeerRange`, `AdvancePoolHeight`, `*PeerDeliverBlock`. |
| `blocksync/tlatrace_init_test.go`        | `init()` that opens `TLA_TRACE_FILE` for test binaries. |
| `blocksync/trace_scenario_test.go`       | Scenario tests `TestScenarioBlockPoolBasic` and `…Ban`. |
| `consensus/tracehooks.go`                | Helpers for `EnterPrevote/Precommit/Commit`, `SwitchToConsensus_*`, `EventVote_*`, `EventNewRoundStep_Update`. |
| `consensus/tlatrace_init_test.go`        | `init()` shim. |
| `node/tracehooks.go`                     | Helpers for `PerformStateSync_*`, `ClearOfflineMarker`, `MempoolEnable`. |
| `statesync/tracehooks.go`                | Helpers for `OfferSnapshot`, `ApplyChunk`/`ByzCorruptChunk`, `VerifyAppFails`, `ByzOfferBogusSnapshot`. |
| `statesync/tlatrace_init_test.go`        | `init()` shim. |
| `types/tracehooks.go`                    | Helpers for `VerifyCommit_*`, `ByzCommitFlood`, `IncrementProposerPriority_Clip`. |
| `types/tlatrace_init_test.go`            | `init()` shim. |

The full patch (new files + edits) is `harness/patches/instrumentation.patch`.
`apply.sh` reverts the artifact (`git checkout -- .`) and reapplies the patch
idempotently.

---

## 2. Instrumentation points (file:line after `apply.sh`)

> Line numbers below are approximate — they shift when nearby code changes.
> Search the file for the emit-helper call (e.g., `emitDeliverBlock`) to find
> the current location.

### F1 — BlockSync (`blocksync/pool.go`)

| Spec action | Emit call site |
|---|---|
| `SetPeerRange` / `ByzPeerAdvertiseRange` | After `pool.updateMaxPeerHeight()` in `SetPeerRange` (line ~445). |
| `HonestPeerDeliverBlock` / `ByzPeerDeliverBlock` | After `bpr.gotBlockCh <-` in `bpRequester.setBlock` (line ~750). |
| `AdvancePoolHeight` | After `pool.height++` + `updateMaxPeerHeight()` in `PopRequest` (line ~287). |

### F1.7 — Consensus mode switch (`consensus/reactor.go`)

| Spec action | Emit call site |
|---|---|
| `SwitchToConsensus_AcquireAndReset` | Inside the inner anonymous func after `updateToState`. |
| `SwitchToConsensus_ReleaseCSMtx` | After the inner anonymous func returns. |
| `SwitchToConsensus_ClearWaitSync` | After `conR.waitSync.Store(false)`. |
| `SwitchToConsensus_Start` | After `conR.conS.Start()` returns. |

### F3 — Reactor cached round-state (`consensus/reactor.go`)

| Spec action | Emit call site |
|---|---|
| `EventVote_Broadcast` | Inside the EventVote listener, right after `broadcastHasVoteMessage`. |
| `EventVote_UpdateCachedRS` | Same listener, after `updateRoundState(&rs)`. |
| `EventNewRoundStep_Update` | Inside the EventNewRoundStep listener, after `broadcastNewRoundStepMessage`. |

`ApplyHasVoteMessage`, `ByzClaimHasVote`, `ByzClaimHasAllBlockParts`,
`ByzVoteSetBitsCrossHeight`, `ByzVoteSetMaj23` are **not yet wired** — see
"Coverage gaps" below.

### Consensus core (`consensus/state.go`)

`EnterPrevote`, `EnterPrecommit`, `EnterCommit` emit at the end of the
respective `defer func()` block — after `cs.newStep()` so the post-state
snapshot reflects the new step. The emit call is `cs.emitEnter("EnterXxx")`.

### F2 — StateSync / persistence (`node/setup.go`, `node/node.go`, `statesync/syncer.go`)

| Spec action | Emit call site |
|---|---|
| `PerformStateSync_Bootstrap`     | `node/setup.go` after `n.stateStore.Bootstrap(state)`. |
| `PerformStateSync_SaveSeenCommit`| `node/setup.go` after `n.blockStore.SaveSeenCommit`. |
| `PerformStateSync_EnableBlockSync`| `node/setup.go` after `blockSyncReactor.Enable(state)`. |
| `MempoolEnable`                  | `node/setup.go` after `mempoolReactor.EnableInOutTxs()`. |
| `ClearOfflineMarker`             | `node/node.go` after `SetOfflineStateSyncHeight(0)`. |
| `OfferSnapshot`                  | `statesync/syncer.go` ACCEPT branch in `offerSnapshot`. |
| `ApplyChunk` / `ByzCorruptChunk` | `statesync/syncer.go` after each `ApplySnapshotChunk` in `applyChunks`. |
| `VerifyAppFails`                 | `statesync/syncer.go` two err-return sites in `verifyApp`. |
| `ByzOfferBogusSnapshot`          | `statesync/snapshots.go` end of `Add`, only when peer is Byz-tagged. |

### F4 — Verification (`types/validation.go`, `types/validator_set.go`)

| Spec action | Emit call site |
|---|---|
| `VerifyCommit_TrustingEarly`     | `verifyCommitLightTrustingInternal` after the inner verify returns nil with `countAllSignatures=false`. |
| `VerifyCommit_AllSignatures`     | Same place with `countAllSignatures=true`. |
| `ByzCommitFlood`                 | Entry of `verifyCommitLightTrustingInternal` when `len(Signatures) > 2*len(Validators)`. |
| `IncrementProposerPriority_Clip` | `incrementProposerPriority` after `safeAddClip`/`safeSubClip` when result equals `MaxInt64` / `MinInt64`. |

`ByzValidatorSetOverflow` is not yet wired (no recover handler around the
panicking `TotalVotingPower`); see "Coverage gaps" below.

---

## 3. State capture levels

All emit helpers capture state at L2 (full state for the relevant spec
variables) — the helpers read fields under the same lock held by the calling
code (Reactor's evsw listener, BlockPool's mtx, ConsensusState's mtx, etc.).

One known L2 caveat:
- `bpr.emitDeliverBlock` reads `bpr.pool.height` / `.maxPeerHeight`
  **without** taking `pool.mtx`. The caller (`pool.AddBlock`) already holds
  `pool.mtx`, so re-acquisition would deadlock. The values are consistent
  because the caller's lock guarantees no concurrent writer.

---

## 4. Trace shape

Each emit produces NDJSON with envelope:

```json
{"tag":"trace","ts":<unix_nanos>,"event":{"name":"<Action>","nid":"s1",
 "state":{...},"msg":{...},"peer":{...}}}
```

`event.state`, `event.msg`, `event.peer` are present only when populated.

### Byzantine peer tagging

Byzantine peers are flagged out-of-band via
`tlatrace.MarkPeerByz(string(id))` in scenario tests. The helpers consult
`tlatrace.IsPeerByz` to switch between honest and Byz event variants
(`SetPeerRange` ↔ `ByzPeerAdvertiseRange`, `HonestPeerDeliverBlock` ↔
`ByzPeerDeliverBlock`, `ApplyChunk` ↔ `ByzCorruptChunk`).

### Server ID strategy

Production code paths see hex/p2p IDs the test framework hands them. The
harness keeps a **single local server slot** per test process (`TLA_TRACE_LOCAL_NID`,
defaults to `s1`). Remote peer IDs (raw strings) survive into the trace and
are remapped to `s2`, `s3`, … (or `b1`, `b2`, …) by
`harness/preprocess_trace.py` in a post-processing pass.

---

## 5. Trace files

`run.sh` produces, per scenario, two files in `traces/`:

- `traces/<scenario>.ndjson` — raw events, IDs untouched.
- `traces/<scenario>.mapped.ndjson` — Server / Byz / value remapping applied.

Phase 3 should validate against the `.mapped.ndjson` files.

Scenarios:

| Scenario file | Go test selector | Covered events |
|---|---|---|
| `blocksync_basic.ndjson`      | `TestScenarioBlockPoolBasic`               | SetPeerRange, ByzPeerAdvertiseRange, HonestPeerDeliverBlock, ByzPeerDeliverBlock, AdvancePoolHeight |
| `blocksync_ban.ndjson`        | `TestScenarioBlockPoolBan`                 | SetPeerRange (ban branch with `bannedCount` > 0) |
| `consensus_full_round.ndjson` | `TestStateFullRound1`                      | EnterPrevote, EnterPrecommit, EnterCommit (height 1→2) |
| `consensus_lock_relock.ndjson`| `TestStateLockPOLRelock`                   | EnterPrevote, EnterPrecommit, EnterCommit across multiple rounds |
| `types_verify_commit.ndjson`  | `TestValidatorSet_VerifyCommit_All` etc.   | VerifyCommit_TrustingEarly, VerifyCommit_AllSignatures |
| `types_verify_trusting.ndjson`| `TestValidatorSet_VerifyCommitLightTrusting` | VerifyCommit_TrustingEarly |

---

## 6. Known validation friction (for Phase 3)

### A. Server constants are model values, traces are strings

`Trace.cfg` declares:

```
Server  = {s1, s2, s3}
ByzPeer = {b1}
```

These are model values; trace events have `"nid":"s1"` (a JSON string).
TLC distinguishes the two — `ASSUME TraceServer \subseteq Server` fails.

Fix in Phase 3: change to string literals.

```
Server  = {"s1", "s2", "s3"}
ByzPeer = {"b1"}
```

(Other case studies in this repo — besu-qbft, substrate, ratis — already
use the string form.)

### B. Initial poolHeight mismatch

Spec `Init` has `poolHeight = [s |-> 0]` but `bpRequester` starts at height 1
(real-world height numbering). Trace's first `SetPeerRange` already has
`state.poolHeight = 1`, so `ValidatePoolState` fails at step 1.

Two ways to fix in Phase 3:
- Adjust the wrapper to skip `poolHeight` check on the very first event, or
  derive the starting height from a config event.
- Have the trace start with a `BlockPoolInit` (or `Recover`) event that
  primes `poolHeight'[i] = 1`. The harness can emit this on the first call
  if needed (see `blocksync/tracehooks.go` → `emitSetPeerRange`).

### C. Consensus actions deadlock without a SwitchToConsensus prefix

`EnterPrevote/Precommit/Commit` require `mode[i] = ModeConsensus` and
`consensusStarted[i] = TRUE`. `Init` sets `mode = ModeBlockSync` and
`consensusStarted = FALSE`, so a trace consisting only of `EnterPrevote …`
deadlocks at state 1.

Fix in Phase 3:
- Have the consensus scenario tests emit an explicit
  `SwitchToConsensus_Start` (or `Recover`) before the first `EnterPrevote`.
  The instrumentation points exist; just add a one-line call in the test
  setup (e.g., `consensus/trace_scenario_test.go` if you add one).
- OR weaken the spec wrappers to allow `EnterPrevote` from `ModeBlockSync`
  during trace replay.

### D. Coverage gaps (not yet instrumented)

These spec actions have no emit point yet — Phase 3 can either add
instrumentation (see section 2 for the file:line targets in
`instrumentation-spec.md`) or wrap them as Silent in Trace.tla:

- `ApplyHasVoteMessage`, `ByzClaimHasVote` — `consensus/reactor.go:1599-1609`.
- `ByzClaimHasAllBlockParts` — `consensus/reactor.go:1566-1580`.
- `ByzVoteSetBitsCrossHeight` — `consensus/reactor.go:1611-1630`.
- `ByzVoteSetMaj23` — `consensus/reactor.go:289-324`.
- `VerifyCommitChainFails` — `consensus/reactor.go` poolRoutine.
- `ByzValidatorSetOverflow` — needs a `recover()` around `TotalVotingPower`.
- `Crash` / `Recover` — harness-driven; the existing `MempoolEnable` helper
  shows the pattern.

To add an emit call:

```go
// In <pkg>/tracehooks.go:
func (<recv>) emitMyEvent(<args>) {
    if !tlatrace.IsEnabled() {
        return
    }
    msg := tlatrace.NewMsg().Set("height", h).Set("round", int(r))
    st  := tlatrace.NewState().Set("...", ...)
    tlatrace.EmitMsg("MyEvent", localServerID, st, msg)
}

// At the call site in <pkg>/<file>.go:
<recv>.emitMyEvent(...)
```

Then regenerate the patch:

```bash
cd artifact/cometbft
git add -N <new files>
git diff --binary > ../../.specula-output/harness/patches/instrumentation.patch
git reset HEAD -- .
```

---

## 7. Rebuilding and re-running

```bash
cd /home/ubuntu/Specula/case-studies/cometbft_3/.specula-output
bash harness/run.sh               # full pipeline
```

Or finer-grained, after editing one package:

```bash
cd /home/ubuntu/Specula/case-studies/cometbft_3/artifact/cometbft
TLA_TRACE_FILE=/tmp/foo.ndjson \
TLA_TRACE_LOCAL_NID=s1 \
  /usr/local/go/bin/go test -count=1 -run "TestScenarioBlockPoolBasic" ./blocksync/
python3 ../../.specula-output/harness/preprocess_trace.py /tmp/foo.ndjson /tmp/foo.mapped.ndjson
```

---

## 8. Adding a new scenario

1. Pick the package whose code path needs coverage (e.g. `consensus/`).
2. Add a `TestScenarioXxx` function to the package's `trace_scenario_test.go`
   (create the file if missing — model on `blocksync/trace_scenario_test.go`).
3. Register the scenario in `harness/run.sh`:

   ```bash
   run_scenario "$TRACE_DIR/xxx.ndjson" ./pkg/ "TestScenarioXxx$"
   ```

4. Re-run `bash harness/run.sh` to verify it produces non-empty trace output.
5. Regenerate the patch (see step 6.D above) so the new file is part of
   `instrumentation.patch`.

---

## 9. Environment

- Go: `/usr/local/go/bin/go` (1.23.5). `go.mod` requests 1.25 but 1.23.5
  builds fine; export `GOFLAGS=-mod=readonly` to suppress automatic
  dependency updates.
- Python 3 (any recent) for `preprocess_trace.py`.
- TLA+ tools: `lib/tla2tools.jar` and `lib/CommunityModules-deps.jar` from
  the Specula root (used by `mcp__tla-trace-debugger__*` tools).
