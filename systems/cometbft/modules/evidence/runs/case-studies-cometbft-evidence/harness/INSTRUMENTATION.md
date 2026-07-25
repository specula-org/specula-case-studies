# Instrumentation Guide — cometbft-evidence

Quick-reference for the Phase 3 (trace-validation) agent. Tells you where each
instrumentation point lives, how to extend it, and how to rebuild + re-run.

## Layout

```
.specula-output/harness/
├── apply.sh                              # Copies harness sources into artifact, patches pool.go
├── clean.sh                              # (not present — apply.sh first runs `git checkout -- evidence/`)
├── patch_pool.py                         # Python helper that patches evidence/pool.go in place
├── run.sh                                # End-to-end: apply + build + test + report
├── src/
│   ├── trace_tla.go                      # Trace emission module (lives in evidence/ after apply)
│   └── trace_tla_scenarios_test.go       # Test scenarios that exercise the protocol
└── INSTRUMENTATION.md                    # This file
```

After `apply.sh` runs, the artifact has:
* `cometbft/evidence/trace_tla.go` (copied verbatim from `harness/src/`)
* `cometbft/evidence/trace_tla_scenarios_test.go` (copied verbatim)
* `cometbft/evidence/pool.go` (patched in place — see "Where each event fires")

The artifact path is shared with case-studies/cometbft/ and case-studies/cometbft-pbts/
(per the modeling brief). `apply.sh` only resets `cometbft/evidence/*.go` — it
preserves Pass-1 / Pass-2 instrumentation outside the evidence/ package.

## Where each event fires

Each emit call is tagged with `// TLA_TRACE_PATCH:` in pool.go so you can `grep -n
TLA_TRACE_PATCH evidence/pool.go` after apply.

| Spec action                | Emit site (after apply)                                            |
|----------------------------|--------------------------------------------------------------------|
| `ReportConflictingVotes`   | `pool.go` — after `evpool.consensusBuffer = append(...)`           |
| `ProcessConsensusBuffer`   | `pool.go` — one emit per outcome (added/already_pending/already_committed/dropped_above_state) inside `processConsensusBuffer` |
| `AddEvidence`              | `pool.go` `AddEvidence` — one emit per branch (already_pending / already_committed / verify_failed / added). The trace module walks the goroutine stack and renames to `AddEvidenceDirect` unless `evidence.(*Reactor).Receive` is on the stack |
| `ProposeBlock_Honest`      | NOT instrumented in real code — emitted by test scenarios via `TLATestEmitProposeBlockHonest` |
| `ApplyBlock_Reactor_Start` | NOT instrumented in real code — emitted by test scenarios via `TLATestEmitApplyBlockReactorStart` |
| `ApplyBlock_RemovePending` | `pool.go::markEvidenceAsCommitted` — at the top of each loop iteration (captures `wasPending`) |
| `ApplyBlock_WriteCommitted`| `pool.go::markEvidenceAsCommitted` — after `evidenceStore.Set(keyCommitted, ...)` |
| `ApplyBlock_ABCI`          | NOT instrumented in pool.go (it lives in `state/execution.go::applyBlock` which our pool-level tests do not exercise). Emitted by test scenarios via `TLATestEmitApplyBlockABCI(isLast)` |
| `ApplyBlock_Finish`        | NOT instrumented in pool.go for the same reason. Emitted by test scenarios via `TLATestEmitApplyBlockFinish` |
| `ApplyBlock_Blocksync`     | NOT instrumented (handled by Handshaker in consensus/replay.go). Emitted by test scenarios |
| `Crash`                    | Emitted by test scenarios via `TLATestEmitCrash` (the harness has no way to instrument an `os.Exit` cleanly; tests synthesize a controlled crash by dropping the volatile pool) |
| `Recover`                  | Emitted by test scenarios via `TLATestEmitRecover` after creating a fresh pool over the same persistent DB |
| `GossipForward`            | NOT instrumented in reactor.go (would need a real `p2p.Peer` mock to exercise `broadcastEvidenceRoutine`). Emitted by test scenarios via `TLATestEmitGossipForward` |

### Why so many events are "emitted by scenarios"

The pool exposes a Go-level API. The full Apply pipeline lives one layer up in
`state/execution.go::applyBlock`, which depends on a `BlockExecutor`, a real
`proxyApp`, a `Mempool`, and so on. Wiring that up in a unit test is heavy and
fragile, and it doesn't add coverage for the pool-level bugs that the modeling
brief targets. Instead, the harness exposes per-action `TLATestEmit*`
helpers that the scenarios call at the right place. The emit calls are
exactly the same as if the production code had been instrumented — they walk
the same code paths and observe the same pool state.

If you need higher-fidelity instrumentation (e.g., to catch a bug that only
shows up when the *real* `applyBlock` runs), patch `state/execution.go` to
call the corresponding `emitApplyBlock*` helpers from `evidence`. The helpers
are unexported but the `evidence` package exports `TLATestEmit*` wrappers
that you can call from outside the package.

## State snapshot

Every event embeds a `state` field with the post-action snapshot:

| Field             | Source                                                                                  |
|-------------------|-----------------------------------------------------------------------------------------|
| `appliedHeight`   | shadow var (per-node); advanced only on `ApplyBlock_Finish` / `ApplyBlock_Blocksync`    |
| `chainHeight`     | shadow var (global); advanced only on `ProposeBlock_Honest`                             |
| `evidenceSize`    | `atomic.LoadUint32(&p.evidenceSize)` — direct read of the pool's atomic counter         |
| `pendingHashes`   | iterate `p.evidenceStore` with `baseKeyPending` prefix, emit spec-shaped hash records   |
| `committedHashes` | iterate `p.evidenceStore` with `baseKeyCommitted` prefix                                |
| `clistHashes`     | walk `p.evidenceList` front-to-back, emit spec-shaped hash records                      |
| `crashed`         | shadow var (per-node); set TRUE on `Crash`, FALSE on `Recover`                          |
| `applyingPhase`   | shadow var (per-node); transitions remove → write → abci → done → none per emit helper  |
| `slashedSet`      | shadow var (global); flipped TRUE on each ABCI Misbehavior forwarded                    |
| `slashCountSum`   | shadow var (global); incremented per Misbehavior                                        |

**Why shadow `appliedHeight` instead of `p.State().LastBlockHeight`?** Inside
`pool.Update`, `updateState` advances `p.state.LastBlockHeight` *before* the
per-evidence `markEvidenceAsCommitted` iteration completes. The TLA spec only
advances `appliedHeight` on `ApplyBlock_Finish`, so reading `p.state.LBH`
directly would mis-report the post-state of `RemovePending` / `WriteCommitted`
events. The shadow var fixes this.

## Hash records

The trace emits *spec-shaped* hash records, not the impl's `tmhash.Sum` output.
This is intentional — the LCAE hash function intentionally collapses some
permutations (the TODO at `types/evidence.go:314-321`); replaying the impl's
hex hash against the spec would lose that collision structure.

Hash record format (`map[string]any` in Go, `JSON object` in NDJSON):

```json
// DVE:
{"kind": "DVE", "k1": "<voteA.blockID>", "k2": <voteA.round>,
 "k3": "<validator-label>", "k4": <voteA.height>,
 "k5": "Prevote"|"Precommit", "k6": "<voteB.blockID>"}
// LCAE:
{"kind": "LCAE", "k1": "<conflictingBlock.hash>", "k2": <commonHeight>,
 "k3": "Nil", "k4": 0, "k5": "Nil", "k6": "nil_blk"}
```

## Label translation

The trace module maps impl IDs (byte addresses, hex block hashes) to spec
labels (`v1`/`v2`, `b1`/`b2`, `s1`/`s2`/`s3`). Three mechanisms:

1. **Per-pool node label**: tests call `evidence.TraceTLABindPool(p, "s1")`.
2. **Explicit binding** (preferred for known validators): tests call
   `evidence.TraceTLABindValidator(addr, "v2")`. The default test setup binds
   the first validator to `"v2"` (Byzantine).
3. **Auto-assignment by first-seen**: if `blockIDLabel(b)` sees a hash it
   doesn't know, it assigns `b1` (or `b2`) in order. Limited to
   `autoLabelLimitB = 2` to match `Trace.cfg`'s `BlockID = {"b1", "b2"}`.
   Beyond that, the label becomes `"b?<hex>"` and trace validation will reject
   it — surface the over-capacity setup as a harness bug.

## How to make small adjustments

### Add a new field to an existing event

Edit `trace_tla.go`'s `emit*` helper. The `data` map is the action-specific
payload; add a key/value.

### Add a new event type

1. Add an `emit<EventName>` function in `trace_tla.go`, following the existing
   pattern (set shadow phase if needed, call `emit(p, "<EventName>", nid, data)`).
2. Add a `TLATestEmit<EventName>` exported wrapper if the event should be
   driven from outside the evidence package.
3. Insert the call from the appropriate code path:
   * If it's inside pool.go, add an anchor and the helper insert call in
     `patch_pool.py`.
   * If it's outside pool.go, patch directly (small `Edit`s) or extend the
     instrumentation patch script.

### Move a capture point (before → after a side effect)

Edit `patch_pool.py`'s anchor for the call. `insert_before_line` vs
`insert_after_line` controls whether the emit fires pre- or post-mutation.
After editing, run `bash apply.sh` to re-patch (it discards previous patches
first).

### Rebuild + re-run

```
cd .specula-output && bash harness/run.sh
```

`run.sh` does: apply patches → build evidence package → run trace scenarios
→ report event coverage. Tests take ~5s; total runtime under 30s.

### Inspect a specific trace

```
cat .specula-output/traces/scenario_<name>.ndjson \
  | python3 -c "import sys,json; [print(json.dumps(json.loads(l), indent=2)) for l in sys.stdin]"
```

## Known issues / Phase 3 work items

### 1. `Trace.cfg` couldn't express `ValidatorPower`

The original cfg had `ValidatorPower = (v1 :> 1) @@ (v2 :> 1)`, which TLC's
config-file parser does not accept (it doesn't evaluate TLA+ operators). The
harness redirected to an auxiliary operator:

```
\* In Trace.tla:
TraceValidatorPower == [v \in Validator |-> 1]

\* In Trace.cfg:
CONSTANT
    ValidatorPower <- TraceValidatorPower
```

The redirect makes all validators have power 1. Phase 3 may want a different
mapping; the operator definition is the place to change it.

### 2. `Nat` fields in DVE / LCAE / ByzVal had to be bounded

TLC cannot enumerate `Nat`. The spec originally had:

```
validatorPower:   Nat
totalVotingPower: Nat
votingPower:      Nat
```

These were replaced with bounded integer ranges in `base.tla`:

```
votingPower: 0..(MaxByzVals * 10 + 10)
validatorPower: 0..10
totalVotingPower: 0..(MaxByzVals * 10 + 20)
```

The bounds are crude. Trace validation still fails the next enumeration step
(`Evidence == DVE \cup LCAE` is enormous even at small bounds). Phase 3 will
likely need to:

* Tighten the type constraints further (e.g., `validator: Validator` with
  small `|Validator|`), OR
* Restrict the action wrappers to enumerate only evidence values actually in
  the trace, rather than `\E ev \in Evidence`. Replace the `\E ev \in Evidence`
  in each `TraceAddEvidence*` / `TraceGossipForward` wrapper with a
  pattern-match against `logline.event.data.evHash`.

### 3. ABCI / Finish / Reactor_Start / Blocksync are emitted from tests, not pool code

The scenarios drive these events by calling `TLATestEmit*` directly. This is
spec-compliant (the trace observes the same state the production pipeline
would) but it does mean Phase 3 cannot probe the spec by re-running the
production `applyBlock`. If Phase 3 needs to verify the impl's `applyBlock`
matches the spec, add instrumentation in `state/execution.go::applyBlock`
that calls the same `emitApplyBlock*` helpers from the evidence package. The
helpers are unexported but `evidence.TLATestEmit*` wrappers are exported for
exactly this purpose.

### 4. Validator labelling defaults to v2

`traceSetup` binds the first validator to `v2` (Byzantine) by default, because
the only spec action that restricts validator identity (`ReportConflictingVotes`)
requires the validator to be in `ByzValidator = {v2}`. Tests that want the
first validator to be `v1` should rebind manually after `traceSetup`.

## Reproducibility

```
cd /home/ubuntu/Specula/case-studies/cometbft-evidence/.specula-output
bash harness/run.sh
```

Expected output:
- 5 trace files in `.specula-output/traces/` (one per scenario)
- 13 distinct event types observed (one missing: `AddEvidence` from gossip —
  requires the reactor.go path with a real p2p.Peer mock, which the harness
  does not provide)
- All scenarios PASS (no Go test failures)
