# Warmreboot instrumentation guide

This Category A harness instruments the real `sonic-utilities/scripts/fast-reboot` control path. Probes synchronously send raw observations to one Unix-socket sequencer; the sequencer owns the instrumentation-only shadow state and flushes one ordered NDJSON line per accepted event. The target `Trace.tla` explicitly selects `"tag":"warmreboot"`, so that target-specific tag is used instead of the generic harness example's `trace` tag.

## Applied source points

Line numbers below are after `bash harness/apply.sh` on the pinned source revision.

| Event | Applied source point |
|---|---|
| `FastReboot_Request` | `src/sonic-utilities/scripts/fast-reboot:1090` |
| `CheckWarmRestartInProgress_Admit` | `fast-reboot:1097,1105,1120` (one aggregate point per request kind) |
| `CheckWarmRestartInProgress_Reject` | `fast-reboot:985`, synchronously before exit |
| `EnableWarmRestart` | `fast-reboot:1131`, after flag writes and read-back |
| `ClearBoot` | `fast-reboot:464`, after disable/rename and read-back |
| `FastReboot_ContinueAfterSignal` | first resumed mainline point in the focused signal-injection path at `fast-reboot:1142` |
| `PauseOrchagent_IgnoreFailure` | `fast-reboot:1009`, in the FORCE branch |
| `FastReboot_PauseOrchagentComplete` | `fast-reboot:1296` (focused scenario equivalent at `1151`) |
| `FastReboot_BeginIrreversibleWork` | `fast-reboot:1307` (focused scenario equivalent at `1156`) |
| `StopSystemdService_Success` | `fast-reboot:268`, after `systemctl` plus process-state probe |
| `StopSystemdService_MaskedFailure` | `fast-reboot:272`, after suppressed failure plus process-state probe |

All 11 instrumented event types occur in the generated traces. C++ daemon actions, Redis checkpoint/APPLY fragments, and finalizer actions are intentionally not claimed as instrumented by this first batch: executing those real paths requires a built SONiC VS image and its daemon/SAI dependencies. Their absence is explicit rather than covered with a simulator or hand-authored events.

## Trace module and capture levels

- `harness/src/warmreboot_trace.py:54` contains `ShadowState`, including owner normalization, epochs, phases, pause results, snapshot metadata, and stop outcomes.
- `harness/src/warmreboot_trace.py:267` is the mutex-equivalent single-thread sequencer. It assigns `seq`, records real epoch-nanosecond time, appends atomically, flushes, and fsyncs before acknowledging the source process.
- Flags, dump existence, ASIC namespace, systemd return status, and writer process state are implementation read-backs from the instrumented script. Owner/epoch/phase fields do not exist in SONiC and therefore come from collector shadow state, as required by the instrumentation spec.
- Every covered event supplies its complete `Trace.tla` post-state schema; no weak validator is used. `harness/src/verify_traces.py:11` rejects missing fields and dead/unvalidated extra fields.
- Run-local owner identities are mapped from `(pid, /proc start-time)` to `owner_1`/`owner_2`; each trace has an adjacent `.ids.json` sidecar with the concrete mapping.

## Adjusting instrumentation

To add a field, pass a new `key=value` argument at the source probe, update the matching transition in `ShadowState.transition()`, then add the exact validated field to `POST_FIELDS` in `verify_traces.py`. Also add the corresponding non-vacuous check to `Trace.tla` before retaining the field.

To add an event type, copy a nearby `specula_trace_emit` call at the exact real-code boundary, add its shadow transition and normalized identifiers, extend `POST_FIELDS`, and add a real scenario that reaches it. The coverage checker intentionally fails until the new event appears in at least one trace.

To move a capture point, move only the `specula_trace_emit` call across the relevant real mutation. Keep read-back after the operation: flag reads after `config`, dump checks after rename/copy, and `systemctl is-active` after stop.

After changing the instrumented artifact, refresh `harness/patches/sonic-utilities-warmreboot-trace.patch` from the pinned `sonic-utilities` diff. Then run from `.specula-output/`:

```bash
bash harness/run.sh
```

That command idempotently applies the patch, syntax-checks the source and harness, runs all four real-code scenarios with outer timeouts, checks NDJSON/event coverage, and replays every trace through TLC. `bash harness/clean.sh` reverses only this harness patch.
