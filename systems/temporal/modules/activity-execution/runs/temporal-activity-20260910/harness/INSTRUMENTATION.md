# Temporal Activity trace harness

The ordinary core has 21 complete real execution replays. The final end-to-end harness run is `evidence/run-20260911T031548Z-D6wqTn/`; current model-checking results are in `../spec/validation-report.md`. Older incomplete runs remain under their original directories.

## Run

From `.specula-output/`, run `timeout 30m bash harness/run.sh`. It applies only the owned instrumentation patch, builds the real Temporal functional binary with `-tags test_dep`, runs isolated SQLite testcore clusters, audits raw observations, projects complete NDJSON, then checks full replay with TLC. Errors propagate; a failed projection never supplies missing state from a model successor. `HARNESS_TEST_PATTERN` selects named tests for targeted recollection and is recorded in provenance.

Source is `source-activity` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Every scenario uses its own file-backed SQLite database, WAL, synchronous=NORMAL. Requests are ordinary non-eager Workflow Activities; worker-control cancellation, administrative operations and routing extensions are disabled. Both retry-stamp settings have real scenarios. Frontend-normalized timeout values are taken from actual ActivityInfo and checked on later snapshots; requested options remain in raw configuration.

`project.py` is the independent projector. It does not import or evaluate TLA+ and never requests a desired successor. Its inputs are the immutable raw JSONL, actual SQL snapshots, decoded messages, recorded worker History and source-boundary metadata. `collect.py` retains raw consistency controls and projector provenance; `validate.py` invokes the full Trace specification. Raw null/empty/default encodings are decoded according to protobuf semantics, not filled from expected model behavior.

## Observation and projection contract

- Mutable State: frozen in the Workflow lease at callback, transaction close and release. The History builder exposes both tentative and persisted buffers. CloseTransaction's complete MutableState buffer is authoritative; NewBufferedEvents is only the submitted delta.
- Persistence: SubmitWorkflowMutation is recorded above the fault wrapper, including the immutable serialized request, unencoded mutation and History batches. The projector independently audits its version, AI updates/deletions, buffer delta, WFT state and generated tasks against the captured mutation. Actual DB state comes from SQL transaction readback below injected errors, emitted only after commit. The ordinary returned DB version must equal the independent read-transaction version; loaded cache versions must match too.
- History: committed Activity-event prefixes are selected only by confirmed execution commits. Raw append receipts remain separate. The final independently retrieved History must equal the projected committed sequence. Buffer flushing follows the actual stable partition of Started events before terminal events; duplicates are not deduplicated by kind.
- Identity: ScheduledEventIDs are ranked in their actual order. Canonical task IDs are allocated at observed key assignment, retaining original IDs/categories and prior descriptor identity. Request IDs come from actual Matching start UUIDs or harness sends. Retries retain the original immutable request payload.
- Task timing: logical pre-allocation visibility and physical assigned visibility are distinct. Immediate descriptors are unset before allocation. The exact allocation clock, minimum scheduled time and configured reader shift are captured under the shard lock. `audit_key_allocation.py` checks nanosecond-accurate pre/post key transformations and rejects corruption.
- Matching: asynchronous acceptance is observed at successful AddTask return; synchronous acceptance is observed at the receiver before its History start request. The matching state represents accepted dispatch responsibility until start issuance. TaskInfo creation/expiry and actual expiry disposition are retained. Priority-reader reprocessing without an issued History call does not create an extra modeled message. A lost History reply followed by retained work has its own RetryMatchingActivityTask event, distinct from a child-deadline expiry.
- Responses: durable start acceptance, History return, Matching reception and worker token receipt are separate. The live-child same-UUID retry captures the actual duplicate response, including omitted metadata. The History server interceptor retry is separately recorded; an internal condition failure is not treated as a caller acknowledgement.
- Ownership: ReacquireShard records the successful durable RangeID write. ShardReady records subsequent local context readiness. The old invocation remains identifiable across timeout and fencing. Cache reload and shard reacquisition are the recovery operations actually tested.
- Workflow responsibility: worker History is indexed by its accepted WFT start identity. A terminal is consumed only by a WFT which received that input and completed. Rejected close clears/reloads under the held lease, fails/renews WFT work, then preserves the terminal result for a later completed WFT.

The projector carries immutable observations and protocol-observer ledgers between these boundaries. It retains raw sequence anchors and an explicit role for source/receipt duplicates. All 45 top-level state fields and their nested values are compared by Trace.ValidatePostState. TraceMatched and the full FinishTrace endpoint remain enabled. No silent protocol action or passing-prefix acceptance was introduced.

## Included tasks and bootstrap

The model includes Activity transfer, retry and all four timeout task types, plus normal WFT transfer tasks generated after Bootstrap. Visibility indexing, WFT timeout internals and pre-bootstrap WFT task rows remain in raw observations but are outside the Activity task projection. WFT pending/started/consumed responsibility is modeled explicitly. Bootstrap is the independently reloaded first normal WFT, before any Activity schedule command; the initial Activity/message/transaction ledgers are empty. Full traces end only after terminal WFT consumption, independent reload and completion of relevant in-flight messages. Scheduled cancellation/timeout tests drain obsolete Matching work through a valid long poll before the final readback.

## Adjustment and ownership

`src/` mirrors harness-owned source files; `patches/instrumentation.patch` covers edits to existing files. `apply.py` checks the pinned revision and every owned destination, and supports repeated application. `clean.sh` reverses only this patch and removes only byte-identical owned files. Preserve unrelated worktree changes.

After editing an owned source file, copy it to `src/` and refresh its SHA-256 in `owned-files.json`. After editing hooks, rebuild the patch from only its declared paths. Recollect the affected scenarios and retain the previous run. Current hook anchors are in `evidence/hook-locations-20260911.json`.

## Validated core and limits

The corpus includes healthy buffered completion/reload; retry and all four stale-token operations under both stamp settings; all four timeout types; a real two-Activity atomic timeout scan; heartbeat extension and duplicate timer delivery after a lost acknowledgement; scheduled/running/backoff cancellation; lost start response and same-request start retry; rejected pre-write, committed-but-lost, internal-retry and delayed fenced writes; and rejected Workflow close with terminal consumption afterward.

Four selective TLA+ corruption controls per real scenario reject wrong attempt identity, wrong durable state, omitted state and omitted endpoint. Five separately labeled generated controls test only specification plumbing and are not real execution evidence.

No process restart, database restart, power-loss test, pause/unpause, ResetActivity, ByID, replication or routing extension is claimed by this validation corpus. Raw source clocks are preserved with nanosecond precision; the formal timer arithmetic uses the implementation's millisecond observation boundaries. Bounded safety, conditional progress and incomplete larger searches are reported separately.
