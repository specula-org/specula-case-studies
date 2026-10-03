# Harness instrumentation notes

The adopted patch adds an opt-in `internal/speculatrace` package, hooks the
block-application and handshake/replay boundaries below, and adds two focused
state-package scenarios. It changes no behavior when `SPECULA_TRACE_FILE` is
unset. The one-command runner applies the patch only to a disposable clone of
the sibling `source/` checkout; it does not modify that checkout.

## Hook locations after applying the patch

| Events | Instrumented code |
|---|---|
| `BlockStored`, `ApplyBlockStart` | `internal/state/execution.go:216-226` |
| `FinalizeBlock` | `internal/state/execution.go:248-258` |
| `SaveFinalizeBlockResponse` | `internal/state/execution.go:281-289` |
| `UpdateStateRejected`, `UpdateStateAccepted` | `internal/state/execution.go:314-329` |
| `CommitApp`, `SaveState` | `internal/state/execution.go:340-365` |
| `HandshakeStart`, `HandshakeComplete` | `internal/consensus/replay.go:254-303` |
| `ReplayAppBlock` | `internal/consensus/replay.go:523-529` |
| `ReplayStateBlockStart` | `internal/consensus/replay.go:448`, `467`, and `570-578` |

`internal/speculatrace/trace.go` owns the mutex-protected NDJSON writer, real
Unix-nanosecond timestamps, state shadows, and complete consensus-parameter
fingerprints. `../spec/instrumentation-spec.md` is the authoritative field and
action mapping.

## Small Phase 3 adjustments

- Add a state field in `speculatrace.LifecycleState`, populate it in the two
  `speculaLifecycleState` helpers, and add the corresponding equality to
  `ValidatePostState` in `../spec/Trace.tla`.
- Add an event by copying a nearby `speculatrace.Emit` call at the real
  operation boundary, then add a matching logged-action wrapper to
  `../spec/Trace.tla` and wire it into `TraceStep`.
- Move a capture point by moving its `Emit` call across the underlying
  operation. Keep the existing post-action snapshot convention and do not
  turn a trace-write error into a production error path.
- Preserve complete parameter fingerprints rather than sampled subfields.
  Keep fixture setup out of recovery traces by resetting only after `Info` at
  the real `Handshake` entry. Do not emit `BlockStored` from replayed
  `ApplyBlock`, because that block was durable before restart.

To rebuild and recollect all six scenarios, run this from `.specula-output/`:

```bash
bash harness/run.sh
```

For an existing writable checkout, set `SPECULA_WORK_SOURCE=/path/to/checkout`.
The runner accepts `SPECULA_TRACE_DIR` and `SPECULA_HARNESS_LOG_DIR` overrides
when fresh diagnostics must not replace the retained traces or normal logs.
