# FDB trace harness

This is a Category-A harness for SONiC `fdb`. It instruments the real
`FdbOrch` implementation and runs the repository's production-linked GTest
binary at source revision `4f3dda156e52ed7647b1dbf900d54d87efaea455`.
The trace module is passive: source hooks drive every transition, trace errors
are swallowed, and no trace value is returned to production control flow.

## Run it

From `.specula-output/`:

```bash
bash harness/run.sh
```

The runner applies the patch idempotently, bootstraps missing SONiC build
packages into `harness/.deps/` without a root install, builds
`tests/mock_tests/tests`, runs four isolated GTest processes, checks every
NDJSON line, and replays each trace through `spec/Trace.tla` with TLC.

Useful overrides are `FDB_SOURCE_DIR`, `FDB_DEPS_PREFIX`,
`FDB_DEPS_CACHE_DIR`, `FDB_BUILD_JOBS`, `TLA2TOOLS_JAR`, and
`COMMUNITY_JAR`. `FDB_SKIP_TLC=1` skips only the final replay and is intended
for edit/compile iteration, not acceptance.

## Files and identity policy

- `src/fdb_trace.{h,cpp}` is copied to `orchagent/`. It contains the mutexed
  NDJSON collector and the spec-required FDB/flush shadow fields.
- `patches/instrumentation.patch` adds the real-code hooks, compile gate, and
  fault-injection test.
- `src/scenarios.tsv` is the scenario-to-GTest manifest.
- `src/swss_file_redirect.cpp` redirects swsscommon's packaged
  `/usr/share/swss` Lua lookup to the isolated package prefix. It is linked
  only into the test binary.
- `src/validate_traces.py` performs structural and sequence checks before TLC.

Because `Trace.cfg` has `Keys={"k1"}` and `Ports={"p1","p2"}`, the collector
maps the first accepted real `(BV,MAC)` to `k1` and the first two distinct
`Port.m_alias` values to `p1` and `p2`. Later unrelated keys and a third port
are deliberately not captured. Each GTest runs in a fresh process, so the
dictionary, `ev1..ev3`, generations, and flush epochs start from `Init`.
Timestamps are epoch nanoseconds from `system_clock`; `seq` is assigned under
the same writer mutex and therefore preserves program order.

## Applied hook locations

Line numbers below are after applying the patch.

| Source point | Events / boundary |
|---|---|
| `orchagent/fdborch.cpp:427-429` | `SaiLearnEvent`, then `FdbOrchUpdateStart`, before LEARN mutation |
| `orchagent/fdborch.cpp:594-603` | counter, cache/STATE_DB/CRM, and observer post-states for LEARN |
| `orchagent/fdborch.cpp:632-647` | `SaiAgeEvent`, handler start, and missing-cache `FdbOrchIgnoreAgedEvent` |
| `orchagent/fdborch.cpp:810-827` | counter, destructive store, and observer post-states for AGE |
| `orchagent/fdborch.cpp:844-846` | `SaiMoveEvent`, then handler start, before MOVE mutation |
| `orchagent/fdborch.cpp:926-937` | counter, store, and observer post-states for MOVE |
| `orchagent/fdborch.cpp:1552,1573` | standard flush request immediately before SAI; result after pending markers |
| `orchagent/fdborch.cpp:1750,1765` | VLAN flush request immediately before SAI; result after classification |
| `tests/mock_tests/fdborch/fdborch_vxlan_ut.cpp:3268` | real SAI failure injection scenario |
| `tests/mock_tests/Makefile.am:216-243` | trace sources and `FDB_TLA_TRACE` compile gate |

The shadow transition implementations are in `src/fdb_trace.cpp`: notification
production at line 150, handler start at 215, counters at 262, store at 295,
observer delivery at 338, flush request/result at 350/385, mandatory bundle
serialization at 497/521, and envelope emission at 541.

## Current coverage

The generated traces cover every event type reached by the four scenarios:

- `learn_age.ndjson` (10): LEARN production plus split commit, then AGE plus
  split cleanup.
- `mac_move.ndjson` (10): LEARN plus split commit, then native MOVE from `p1`
  to `p2` plus split commit.
- `vlan_flush.ndjson` (7): LEARN plus split commit, VLAN flush request, and
  successful SAI completion.
- `flush_failure.ndjson` (2): standard port+VLAN flush request and injected SAI
  failure.

`FdbOrchIgnoreAgedEvent` is instrumented but not present in this batch. The VS
helper invokes notification receipt and `FdbOrch::update` synchronously, so it
cannot naturally create the model's ASIC-present/cache-absent delivery window.
Trigger it only with a real queued-notification fixture; do not call the trace
API directly.

The following instrumentation-spec families are not wired in this focused
first batch: duplicate notification/ack delivery, syncd flush acknowledgements
and cleanup, bridge-port topology lifecycle, saved-intent replay, L2-NHG graph
replacement, notification repair ownership, and `fdbsyncd` restart
reconstruction. They require hooks in `handleSyncdFlushNotif`, `portsorch.cpp`,
the saved-entry paths, `l2nhgorch.cpp`, and `fdbsyncd` respectively. Until
those hooks and real tests are added, those `Trace.tla` branches are untested
by these traces.

All emitted bundles use the strong validators in `Trace.tla`; no weak or stub
validator is selected. The four checked-in traces pass `TraceMatched`, the
configured invariants, and structural validation.

## Adjusting the instrumentation

To add a state field, update the appropriate state struct/transition and
`fdbStateJson()` or `flushStateJson()` in `src/fdb_trace.cpp`, then make the
same field mandatory in the corresponding `Trace.tla` validator. Avoid
capturing fields the validator does not check.

To add an event type, copy an existing collector method, apply the exact base
action to the shadow first, and call `emit()` only at the post-action source
boundary named by `instrumentation-spec.md`. Add the real source hook to
`patches/instrumentation.patch` and add a real GTest filter to `scenarios.tsv`.
Never emit a model action solely from test code.

To move a capture point, move the guarded `fdb_trace::...` call in the source
patch. Counter hooks belong after all real `m_fdb_count` writes; store hooks
belong after `storeFdbEntryState`; observer hooks belong after `notify`; flush
success belongs after the pending-marker loop. Preserve those ownership
boundaries when refactoring.

When changing copied trace sources, edit the harness copy first and
intentionally synchronize the target copy before rebuilding; `apply.sh`
refuses to overwrite a differing existing file to protect local work. Keep
the patch applicable to the pinned clean revision and verify it with:

```bash
git -C /users/Pial/targets/sonic-swss-fdb apply --check \
  /path/to/harness/patches/instrumentation.patch
bash harness/run.sh
```

For an already instrumented checkout, use `git apply --reverse --check` to
audit patch identity. Do not reset the checkout: generated build files are
ignored, while source modifications may belong to the Phase 3 agent.
