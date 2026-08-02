# iccpd trace instrumentation

This is a Category-A harness. It runs two real `struct CSM` instances in one
controller process, uses real UNIX `socketpair` writes and the production epoll
receive path, and serializes events through one mutex-protected NDJSON writer.
The controller's frame ledger and epoch/generation fields are trace-only; they
never enter ICCP or mclagsyncd packets and never affect an iccpd guard.

## Applied source hooks

Line numbers below are after `harness/apply.sh` at revision
`9df8ccbf72c31948741b5554d09c38ac6c1ec6e9`.

| Source location | Events/capture boundary |
|---|---|
| `src/iccpd/src/scheduler.c:171,242,261` | Partial header, corrupt body retry, and blocked-read error |
| `src/iccpd/src/scheduler.c:435-440` | Warmboot buffer prepared, then caller-visible full/partial/failed result |
| `src/iccpd/src/scheduler.c:864-870` | External disconnect detection, peer handler, then status reset |
| `src/iccpd/src/iccp_csm.c:270` | Test-selectable write shim; normal mode calls the real `write(2)` unchanged |
| `src/iccpd/src/iccp_netlink.c:2236` | Complete frame after heartbeat refresh |
| `src/iccpd/src/mlacp_sync_update.c:1349` | Warmboot marker after `time()` mutation |
| `src/iccpd/src/mlacp_link_handler.c:2093` | LAG generation/local state/dirty post-state before traffic application |
| `src/iccpd/src/mlacp_link_handler.c:2391,2445` | Warm grace return and ordinary cleanup tail |
| `src/iccpd/src/mlacp_link_handler.c:3619-3655` | Disable/enable success or failure after the real syncd result |

The writer is `harness/src/tla_trace.c`. `refresh_actual` reads CSM/LAG fields,
`apply_event` maintains monitor-only state, and `emit_event` writes every
mandatory field checked by `Trace.tla::ValidatePostState`. This is full capture,
not a weak validator variant.

## First-batch coverage

The four scenarios cover 16 of the 18 currently applied event types:

- warmboot prepare, full/partial/failed send, full delivery, and warm update;
- external disconnect, warm grace, ordinary cleanup, and status reset;
- corrupt-body retry, partial-header blocking, and their read-error releases;
- PortChannel down with both successful and real EPIPE traffic-disable results.

The structurally verified but currently uncovered hooks are documented gaps:

- `mlacp_link_enable_traffic_distribution_Success` and `..._Fail`: need a
  delivered IF_UP_ACK after a prior down/up cycle; this first batch stops at
  the independently modeled down-side effect.

Actions involving process restart, privileged kernel reconstruction, the full
sync transaction, isolation across all configured LAGs, unsupported APP-frame
streams, and syncd EOF are not yet hooked in the portable scenario artifact.
They require a SONiC namespace/syncd supervisor or additional configured-peer
fixtures. No synthetic event is emitted in their place. The warm-timeout action
is also unreachable behind the implementation's disconnected-session early
return, as noted in `base.tla`.

## Adjusting capture

To add a field, add it to `struct tla_node_state`, initialize it in `init_node`,
read implementation state in `refresh_actual` or update ghost state in
`apply_event`, then serialize it in `emit_event`. Keep the field mandatory and
update `validate_traces.py`; do not add conditional validation.

To add an event type, place `tla_trace_event`, `tla_trace_event_bool`, or
`tla_trace_prepare_event` at the instrumentation spec's exact post-state
boundary. Add its ghost transition to `apply_event`, list it in
`INSTRUMENTED_ACTIONS`, and add a real-code scenario that reaches the hook.
Preparation must precede the real write; send-result emission must remain after
the caller's immediate bookkeeping.

To move a capture from before to after a mutation, move only the trace hook in
the artifact source, then refresh `patches/instrumentation.patch` from the Git
diff. Do not move or duplicate the production mutation.

Rebuild, run, structurally check, and replay every trace with:

```bash
cd /users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output
bash harness/run.sh
```

`apply.sh` is idempotent and refuses a source revision mismatch or overlapping
patch. `run.sh` rebuilds the full daemon, links the scenario driver against the
same production objects (excluding only `iccp_main.o`), regenerates all four
trace files, validates their complete schema, reports coverage, and runs TLC
replay for each trace.
