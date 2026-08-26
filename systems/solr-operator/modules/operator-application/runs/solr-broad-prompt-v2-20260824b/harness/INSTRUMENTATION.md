# Solr Operator trace instrumentation

This is a Category A harness. `internal/speculatrace` owns one mutex-protected
NDJSON writer per scenario and flushes every event with a real RFC3339Nano
timestamp. It logs only bounded role IDs and equality-class labels; it never
logs Secret data, usernames, passwords, or `security.json` content.

## Applied files and capture points

`apply.sh` copies `src/speculatrace/trace.go` to
`source/internal/speculatrace/trace.go`, copies
`src/trace_scenarios_test.go` to `source/controllers/`, and applies
`patches/instrumentation.patch` idempotently.

Production-path probes after apply:

| File:line | Completed boundary |
|---|---|
| `controllers/util/solr_update_util.go:145,195` | successful CLUSTERSTATUS/OVERSEER aggregation; actual pod selection result |
| `controllers/solr_pod_lifecycle_util.go:127,160` | successful/NotFound Pod delete; successful readiness status patch |
| `controllers/util/solr_scale_util.go:47,50,76,78,103` | REQUESTSTATUS error/notfound, submit success/failure, completed task cleanup |
| `controllers/solrbackup_controller.go:302,322` | local submitted state; local terminal state before DELETESTATUS |
| `controllers/util/backup_util.go:76,130,147,219,234` | aggregate status, notfound observation, DELETESTATUS, recurrence schedule, LIST |
| `controllers/util/solr_security_util.go:101,115,118,121,151` | missing lookup, first Secret durable, second create failure/success, existing lookup |
| `controllers/util/solr_util.go:1338,1342` | generated setup-zk template with or without bootstrap data |

The scenario file records boundaries owned by another participant or spanning
multiple controller calls: StatefulSet recreation, Solr task completion,
controller-runtime delivery/timer, dispatcher completion, status-patch
conflict, ZK readback, Pod readiness, and external collection/security
changes. Each such event is emitted only after its fake-Kubernetes or HTTP
consumer operation succeeds and the test asserts the real return tuple.

## Adjusting events

- Add a field to the relevant state struct in
  `internal/speculatrace/trace.go`, initialize it in `initial*`, and update it
  from the real observation in `applyMU`, `applyOP`, `applyBK`, or `applyAU`.
  Add the matching check to `Trace.tla`; do not leave captured data unchecked.
- Add an event by adding its transition to `recorder.apply`, placing
  `speculatrace.Record` after the exact real-code boundary, and adding a real
  scenario assertion. Event names and IDs must match `Trace.tla`/`Trace.cfg`.
- To move a capture point, move only the `Record` call. Keep it after the API
  result or local mutation named in `instrumentation-spec.md`; handler-return
  and dispatcher events must remain separate.
- Set-valued arrays are sorted before encoding. Keep the fixed role mapping:
  `update-pod`, `pull-pod`, `nrt-replica`, `pull-replica`,
  `collection1|shard1`, `collection-a`, `collection-b`, `rolling`, `balance`.

## Run and validate

From `.specula-output/`:

```bash
bash harness/run.sh
```

The command applies the patch, compiles the packages, runs only the real trace
scenarios under an outer timeout, recreates `traces/*.ndjson`, and prints line
counts. TLC logs from the initial validation are in `harness/validation/`.

Coverage is 48 of 49 `Trace.tla` event types. `RetryNextQueuedClusterOp` is
not emitted: `base.tla` requires `opQueue` to be populated at `opAge > 1`, but
defines no action that advances `opAge`; therefore that wrapper is unreachable
from `TraceInit`. Emitting it would create a hand-written, unreplayable event.

All 13 traces replay completely under `Trace.cfg`, including full family
post-state validation and `TraceMatched`. Scenario bug oracles are intentionally
enabled only in `MC_hunt_*.cfg`, so candidate-bearing implementation traces are
accepted as real behaviors before the hunting phase evaluates whether those
behaviors violate a contract. `CheckAsyncRequestNotFound` records the observed
Solr post-state (`taskRecord=false`, `taskState=none`) while preserving the
controller's submitted CR status.
