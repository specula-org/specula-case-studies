# vsr-rs trace harness

Source revision: `3ac0104a567092139534c9022205d02281a2da41`. Category A;
three real `Replica<Register>` instances and real `Client<Input>` instances.
The controller adapts `tests/cluster.rs`'s public-method delivery loop. It owns
transport/fault scheduling and durable view storage, and contains no replica
protocol implementation. All four schedules use separate Rust `#[test]` cases.

## Run and adjust

From `.specula-output/`:

```sh
bash harness/run.sh
```

The script applies the patch, builds with `tla-trace`, runs all four scenarios,
reports line counts, audits JSON/L2 coverage, runs TLC positive and negative
checks, and records SHA-256 provenance. Build/test timeouts are 300/180 seconds;
TLC has a 180-second timeout per invocation, two parallel workers across runs.
Timeouts fail the command without retry. Set `TLA_JAR` and `COMMUNITY_JAR` if
the local default tool paths in `validate.py` are unavailable. Java, Rust/Cargo,
Python 3 and GNU `timeout` are required. `Cargo.lock` records this run's resolved
dependencies; the source's existing ignored lockfile is not replaced by apply.

Canonical editable files are in `harness/src/`. `apply.sh` copies the observer
to `source/tla_trace.rs` and the integration modules to
`source/tests/specula_trace.rs` and `source/tests/specula_harness/`.
It applies `patches/instrumentation.patch` to `Cargo.toml` and `lib.rs`.
Repeated apply is supported; unexpected edits to copied files are preserved
with an error. Edit canonical copies, then rerun. For a new `lib.rs` hook,
update the working source and regenerate the patch with
`git diff -- Cargo.toml lib.rs > ../.specula-output/harness/patches/instrumentation.patch`
after checking that the diff contains only harness work.

`bash harness/clean.sh` reverses only the owned patch and copies. It preserves
unrelated files (including the pre-existing `.codex/`), traces, evidence, and
Cargo's build/lock artifacts. `VSR_SOURCE_DIR` selects another checkout of the
pinned revision. No commit or simulator seed is created: schedules are explicit
integration tests, not randomized simulator bug reproductions.

## Instrumentation locations after apply

Paths below are relative to `source/`; line numbers refer to the shipped copies.
`C` denotes `tests/specula_harness/controller.rs`; `O` denotes `tla_trace.rs`.

| Event / observation | Location | Capture boundary |
|---|---|---|
| `Init` and NDJSON writer | C:75, C:110 | Real constructors, globally mutex-protected writer; epoch nanoseconds in `ts` |
| `ReplicaOnMessage` | C:285; `lib.rs:550` | Pre-branch from O:319; real `on_message`; stage observations; full post-state before persistence |
| `ReplicaOnIdle` | C:274; `lib.rs:1255` | Pre-branch from O:394; real `on_idle`; full post-state before persistence |
| Ordered application calls | `lib.rs:1384`; O:236 | Entry/one-based slot and real app value around `StateMachine::apply`; actual result retained |
| PrepareOk prefix | `lib.rs:1415`; O:218 | Exact log prefix when ack is buffered; metadata drained with its packet |
| Full replica / client snapshots | O:254, O:405 | Every required private field plus caller staging; raw attempts/stable retained |
| `PersistView` | C:207 | `write_view` writes and `sync_all`s the real per-node file, then records completion |
| `ReleaseMessage`, `ReleaseReply` | C:222, C:232 | One FIFO head enters its transport bag; remaining output stays volatile |
| `ClientOnRequest`, `ClientOnIdle`, `ClientDrain` | C:247, C:257, C:265 | Real client method then snapshot; each publication is a separate event |
| `ClientOnReply`, `ClientRetire` | C:308, C:371 | Route by actual reply client ID; retain returned acceptance boolean; retirement destroys client object |
| `Pause`, `Resume`, `Crash`, `Recover` | C:336, C:341, C:346, C:354 | Retained scheduling suspension versus dropped object/application/staging; recovery reads durable view |
| `LoseMessage`, `LoseReply` | C:381, C:388 | Remove one real queued packet occurrence |
| `ReplayMessage`, `ReplayReply` | C:395, C:396 | Clone an exact previously released packet, including original epoch/proof |

## Capture rules for Phase 3

- All events use **full** post-state validation. No weak/silent wrappers exist.
  Each handler's `applies` is the ordered list of actual nested application calls;
  these are not separately interleavable events. `ValidatePostState` checks the
  entire snapshot; `ValidateApplies` checks slot, entry, before, result and after.
- To add a state field, update O's `trace_snapshot` (or C's global `snapshot`),
  `Trace.tla`'s `Snapshot`/normalization, and the required-key lists in `validate.py`.
  Add its semantic variable/check when necessary; do not add unvalidated data.
  For wire fields use O's `wire`/`reply_wire` and `ExportWire`/`ImportEnvelope`.
- To add an event, follow C's `receive_where`: determine branch from pre-state,
  call the real method, collect actual observations, then emit the post-state.
  Add the corresponding exact Trace wrapper; never manufacture a model step.
  To move a capture point, move the relevant hook in `lib.rs` or C; keep branch
  reads before the call and the snapshot after it. Never split `commit_op` loops.
- Draining a Rust Vec is representation-only. C:171/C:190 move everything into
  unpublished FIFO staging before a snapshot. Publication removes one head.
  `receive_where` stops before persistence; `deliver_where` additionally persists
  and publishes, allowing scenarios to select exact failure windows.
- Replica IDs remain 0,1,2; clients use 3 and above. Put/Get both return the old
  register value, initial 0. One outstanding request per live identity is enforced.
  A retired identity remains observable and is never reused.
- Raw fresh nonces come from `SystemTime`; reuse is rejected before per-node
  normalization. RecoveryResponse nonces resolve against the destination's map.
  Packet metadata is fixed at emission/staging and survives authentic replay.
  The controller retains actual application histories for every incarnation,
  including empty failed recovery incarnations. No canonical history is supplied.
- Persistence is a controlled caller implementation, not the shipped TCP example:
  files are initialized and the directory synced before Init, subsequent view
  writes are synced before publication, and modeled crashes occur between calls.
  This does not establish example fsync, identity or transport obligations.

## Schema alignment and observed coverage

The supplied parser selected `tag: "vsr"`, conflicting with the installed skill's
mandatory `tag: "trace"`. Only that selector and instrumentation-spec tag prose
were aligned. The supplied flat `event` string and full state schema remain;
`base.tla`, `Trace.cfg`, all field checks and invariants are unchanged. See
`validation/schema-delta.md`. Every line has a real epoch-nanosecond timestamp.

| Scenario | NDJSON lines | Transitions | Actual applies | Focus |
|---|---:|---:|---:|---|
| requests_replies_and_lifetimes | 110 | 109 | 12 | Lost request/reply, retries, duplicates, stale replies, Put/Get results, retirement |
| reordered_state_transfer | 110 | 109 | 15 | Reordered Prepare, same-view transfer, old authentic offset request, overlapping NewState |
| view_change_and_retained_resume | 138 | 137 | 9 | Paused primary, uncommitted suffix, view change, retained resume and catch-up |
| recovery_epochs_and_reconstruction | 120 | 119 | 14 | Crash before persist/publication, recovery retries, reconstruction, old ack and stale nonce response |

All **18/18 transition event types** are observed, along with all 11 incoming
protocol message variants and Reply delivery. No instrumented event is uncovered.
All four replica idle branches occur. Some finer dispatch alternatives are not
covered: `old-request`, `old-view`, `catch-up-same-view`, `different-view`, and
NewState `ignore-status`. Coverage is recorded explicitly in
`validation/coverage.json`; complete event coverage is not branch exhaustiveness.

All four implementation traces pass TLC with the supplied semantic invariants
and `TraceMatched`. Four negative copies change a commit, an application result,
a NewState offset, or omit persistence; each must fail `TraceMatched` specifically.
Corrupted controls are kept only under `validation/negative/`. The 16 original
cluster tests pass with and without the feature; the additional observer regression
checks creation-time ack prefixes and real ordered results. Evidence and exact
commands/hashes are in `validation/results.json`, `l2-audit.json`, regression
logs, and `provenance.json`. These checks establish agreement for the recorded
schedules, not exhaustive protocol correctness or general service liveness.
