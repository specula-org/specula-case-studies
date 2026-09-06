# vsr-rs trace instrumentation

Pinned revision: `3ac0104a567092139534c9022205d02281a2da41`. Category A; fixed membership, actual integer accumulator, one ordered NDJSON file per Rust `#[test]`. The patch changes no protocol decision. Its observers are enabled only under `cfg(all(test, feature = "trace-harness"))`.

## Reproduce

From `.specula-output/`:

```sh
bash harness/run.sh
```

This applies the idempotent patch, copies the three `src/*.rs` modules, builds with the retained `Cargo.lock`, executes four real-library scenarios, checks JSON/event/native-callback coverage, replays every trace using the full `Trace.cfg`, and writes `harness/manifest.json` with source/spec/harness/trace hashes. Build and Rust tests have outer limits of 600 and 180 seconds; TLC has 180 seconds per file. A timeout is a failure, with no automatic retry.

`SOURCE_DIR`, `TRACE_DIR`, and `CARGO_TARGET_DIR` can override locations. `TLA_TOOLS_JAR` and `COMMUNITY_MODULES_JAR` select replay dependencies. The default jars and L2 details are documented in `VALIDATION.md`. `bash harness/clean.sh` reverses only this patch and removes the three unchanged copied modules; it preserves unrelated edits, `.codex/`, generated traces, and build outputs. The source remains instrumented after a successful run.

## Files and capture boundaries

Canonical editable sources are `harness/src/tla_trace.rs`, `owner.rs`, and `scenarios.rs`; `apply.sh` copies them to `source/tla_trace/`. The following locations refer to the source after applying the current patch. Harness copies use the same module line numbers.

| Observation | Location and timing |
|---|---|
| Module wiring | `lib.rs:25`, test/feature gated |
| Eleven message variants, including recovery-firewall early returns | Native call marker `lib.rs:544`; the owner calls `on_message` exactly once at `tla_trace/owner.rs:194` |
| `OnIdle` | Native marker `lib.rs:1251`; one actual idle call in `owner.rs:170` |
| `ClientOnRequest`, `ClientOnIdle`, `ClientOnReply` | Native markers `lib.rs:318`, `363`, `342`; captured after the corresponding owner call and client drain |
| `applied` execution observer | `lib.rs:1383` inside the actual `commit_op`, immediately before actual application execution; contains full request identity and operation |
| Successful persistence and output publication | `owner.rs:96`: retain actual view, drain messages then replies in their native vector order, enqueue authentic payloads before snapshot |
| `Init` | `owner.rs:31` after all actual fresh constructors, before any callback |
| `Crash`, `Recover` | `owner.rs:257`, `263`: drop real object/application; recover with separately retained view and supplied raw nonce; drain before capture |
| `Lose`, `Duplicate` | `owner.rs:235`, `244`: remove/add exactly one existing authentic queue element, then capture |
| Full global snapshot | `owner.rs:74` and `tla_trace.rs:163`; all live private fields are read directly with exclusive single-owner access |
| JSON/timestamp/write | `tla_trace.rs:81`: global mutex writer, real epoch nanos and elapsed monotonic nanos as strings, newline and flush per event |

The eleven dynamically named `On*` events all share the dispatch boundary above. Their actual specialized handlers are:

| Event | Handler after apply |
|---|---|
| `OnRequest` | `lib.rs:662` |
| `OnPrepare` | `lib.rs:717` |
| `OnPrepareOk` | `lib.rs:753` |
| `OnCommit` | `lib.rs:792` |
| `OnGetState` | `lib.rs:834` |
| `OnNewState` | `lib.rs:858` |
| `OnStartViewChange` | `lib.rs:922` |
| `OnDoViewChange` | `lib.rs:942` |
| `OnStartView` | `lib.rs:964` |
| `OnRecovery` | `lib.rs:1147` |
| `OnRecoveryResponse` | `lib.rs:1175` |

Nested helpers do not emit extra events: there is no externally visible interleaving inside a synchronous handler. Every snapshot follows the complete call, including ignored/no-op calls, successful owner persistence, both drains, and queue insertion. No callback or delivery batch is collapsed into one event.

## Schema and observation fidelity

Every event has `tag: "trace"`, a flat `event` name and the exact full snapshot in `spec/instrumentation-spec.md`. The generated input used `tag: "vsr"`; only that filter literal and its two documentation mentions were aligned with the skill. `base.tla` and `Trace.cfg` are unchanged. Historical synthetic fixtures remain in `spec/validation/`, separate from implementation traces; see `VALIDATION.md` before reusing them.

There are no weak captures. All 20 replica fields, complete client state, actual owner membership/durable views/incarnations/nonce history, exact newly drained output sequence, and the complete network multiset are validated. `app` is read from the actual accumulator; `applied` is recorded at execution rather than reconstructed from `log`. Down replicas have the documented canonical absence state while owner identity/durable history survives.

Replica IDs retain native integers. Native clients `0`, `1`, ... map bijectively to `c0`, `c1`, ... everywhere. Replies recover their operation only from the original issued-request registry. Native messages are retained in the queue and passed to the real API without reconstruction from JSON. Reply loss, duplication, delay and delivery use that same queue. Producer-ID assertions validate harness metadata and do not add protocol acceptance guards.

Each replica has a whole-run nonce bijection, with raw zero mapped to zero and successive previously unseen raw values mapped to small integers. Repeated raw tokens retain their old label; the observer does not fix or reject reuse. Old responses use the recipient's original namespace. The scenarios supply fresh tokens `101` and `202`, canonicalized to `1` and `2`.

Native entry hooks maintain an independent cumulative callback count and a per-call `(event,id)` receipt, checked after the call. Shutdown checks emitted native-event count against this total, flushes/syncs/closes the trace, and creates `<scenario>.complete.json`. The audit requires the marker and verifies both event and native-callback counts. Environment-step count records owner emissions; these records do not prove that an arbitrary external execution or an uninstrumented terminal suffix was captured.

## Scenarios and retained results

The scenarios adapt `tests/cluster.rs`'s real queued Client/Replica structure and the specific existing tests named in `src/scenarios.rs`. The adaptation is necessary because the old tick path batches collection, bypasses client reply delivery, and some old tests issue several requests without awaiting replies. The new owner preserves the caller's single-outstanding-request precondition.

| Trace | Events | Main observations |
|---|---:|---|
| `normal_retry_duplicates.ndjson` | 54 | Four members, two clients, lost request/prepare/reply, duplicate acknowledgement below quorum, cached and duplicate replies, ignored backup requests |
| `state_transfer_reordering.ndjson` | 49 | Gap, ignored prepare during transfer, GetState retry, delayed authentic earlier GetState returning an overlapping suffix |
| `view_change_after_crash.ndjson` | 36 | Actual primary destruction with in-flight acknowledgements, exact timeout calls, view installation, uncommitted suffix completion, stale equal-view StartView |
| `recovery_stale_responses.ndjson` | 47 | Two recoveries, actual state loss, recovery firewall, old-nonce rejection, retransmission, repeated responder not forming quorum |

All four Rust tests and all four full TLC replays passed: 186 events, all 20 event names (Init plus 19 transitions), zero missing event types. `validation/audit.json` contains exact counts by file/type; `validation/results.tsv` and four `.log` files retain TLC evidence. The unchanged existing `cargo test --locked -p vsr-rs --test cluster` suite also passed all 16 tests on this patched checkout. Coverage is at the event-type level, with selected branches, not exhaustive behavior coverage or a proof of protocol correctness.

## Adjust for Phase 3

- Add a replica/client state field in `replica_snapshot`/`client_snapshot` in `src/tla_trace.rs`, reading its actual source field. Add the matching model field and full equality validation before collecting it. For message fields, update `canonical` or the reply encoder in `Owner::publish_replica`, together with the canonical model record.
- Add an event at a real API/environment boundary in `src/owner.rs`, following `idle` or `deliver_index`; use `record` only after publication. Add a native entry marker for a new callback API, a strict Trace wrapper invoking the actual base action, its schema-audit vocabulary, and a scenario that reaches it.
- To investigate capture timing, locate the `check_call` / `publish_replica` / `record` sequence. Keep the input packet before consumption and capture after full dispatch. Moving a snapshot before a mutation requires an explicit corresponding pre-state trace contract; do not weaken post-state checks to conceal a mismatch.
- Edit canonical `harness/src/` files, then rerun `bash harness/run.sh`. For changes to the core hook locations, update `patches/instrumentation.patch`; `apply.sh` refuses unrelated tracked edits. To move an existing patch safely, run `clean.sh` while the old patch is still available, then edit/reapply it.

## Preserved scope boundaries

This harness assumes successful owner persistence in memory outside the destroyed replica; it does not test `kvstore` name publication, sockets, startup or wall-clock policy. The independent handoff candidates remain separate: EX-START startup fallback, LIB-SINGLE accepted singleton progress, EX-WRITER shared blocking sender, EX-FSYNC parent-directory publication, EX-NONCE freshness policy, and AS-01..AS-06/AS-LEAN assurance gaps. Exact source anchors and verification routes remain in `../modeling-brief.md` and `../spec/brief-coverage.md`. Singleton is excluded by the supplied `N >= 2` baseline; it has not been silently declared unsupported by the Rust API.

No stock simulator/DST bug reproduction was performed and no new bug claim or seed is asserted. These are deterministic real-library tests with explicit schedules. If Phase 4 reproduces a bug using the simulator, add the required integration regression under `tests` and record its seed and the pinned revision according to the supplied AGENTS instructions.
