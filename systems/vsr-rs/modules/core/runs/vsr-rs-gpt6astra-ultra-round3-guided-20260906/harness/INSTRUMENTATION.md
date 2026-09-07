# vsr-rs trace harness

Pinned source: `3ac0104a567092139534c9022205d02281a2da41`. Category A; seven coordinated Rust `#[test]` scenarios run the actual `Replica`, `Client`, and shipped kvstore `Store`. The owner extends the delivery pattern in `tests/cluster.rs`; it does not implement VSR transitions. No simulator seed is involved: the schedules are explicit Rust code. The socket prefix length is measured on each run and may vary.

From `.specula-output/`:

```bash
bash harness/run.sh
```

This applies instrumentation, builds, runs all scenarios serially, audits NDJSON and state coverage, replays every trace with TLC, and records hashes. Build/test/TLC commands have outer timeouts. Logs and summaries are in `harness/results/`; seven traces are in `traces/`. Prerequisites: Rust/Cargo, Python 3, Java, Linux TCP sockets, `timeout`, `sha256sum`, and TLC/CommunityModules jars. `SPECULA_TLA_LIB_DIR` defaults to `/home/ubuntu/Specula/lib`. `SPECULA_SOURCE_DIR`, `SPECULA_TRACE_DIR`, and `CARGO_TARGET_DIR` override the source, trace, and build paths.

The feature is `specula-trace`; normal builds do not allocate observers. `harness/src/` contains canonical editable files. `apply.sh` copies them into the source and adds exact-anchor hooks with the two Python patchers. `patches/instrumentation.patch` records the source diff. `clean.sh` reverses that diff and removes only generated files whose contents still match the harness; it preserves unrelated edits, traces, and the pre-existing ignored Cargo.lock.

## Trace format and coverage

Every line uses `tag: "trace"`, a real epoch-nanosecond `ts`, the input spec's flat string `event`, event inputs, and the required complete `post`. The installed skill requires the trace tag, whereas the input reader originally selected `vsr`; `patches/trace-tag.patch` changes that filter and its documentation only. Original inputs are retained in `patches/originals/`. `base.tla`, the 32 action wrappers, full `ValidatePostState`, and `TraceMatched` are unchanged.

The final run produced **884 records in seven files**, covering **33/33 event types including Init**. Every file passed TLC with `TraceMatched` and all four configured invariants enabled. There are no weak snapshots, optional state fields, silent actions, or unobserved event types. Coverage by event is not coverage of every branch or schedule. Detailed per-file counts and field audit are in `results/coverage.json`; replay results are in `results/validation.json`.

| Trace | Records | Paths exercised |
|---|---:|---|
| specula_normal_transfer | 177 | Normal work, lost reply, client retry, cached reply, duplicate Prepare, gap/rejected Prepare, state transfer, late ignored NewState, new-view catch-up |
| specula_rolling_recovery | 258 | Recovery during view change, authentic newer-to-older response overwrite, sequential recovery of all three replicas, persisted view with only one output published before crash |
| specula_stable_minority | 212 | Fixed healthy set [0,2], permanently down replica 1, skipped view-1 primary, repeated successful cross-client work |
| specula_two_replica | 101 | Two-member quorum, retries and view change, zero crash budget |
| specula_frame_complete | 45 | Real sender frame completed; seven-byte forwarding writes; unchanged admitted Put and Get result |
| specula_frame_eof | 82 | Actual interrupted sender, clean EOF admission of shortened Put, view change, commitment, successful client reply, Get of shortened value, recovery |
| specula_frame_reset | 9 | Actual partial sender bytes followed by injected TCP reset at acceptor; observed ConnectionReset and completed receive loop with zero dispatch |

The four existing-cluster extensions each complete four operations with results `nil, AA, nil, B`, retaining six happens-before edges, including four across clients. The original 16 cluster regression tests also pass with instrumentation enabled; see `results/existing-tests.log`.

## Applied hook locations

Paths below are relative to `source/` after apply. Re-run `rg -n` after editing to refresh anchors.

| Location | Capture |
|---|---|
| `lib.rs:1406` | `commit_op` records the original entry before actual apply, then position/result/view after apply; history is retained across crashes |
| `lib.rs:1064` | Actual DVC map insertion retains typed immutable payload and destination provenance, including self insertion |
| `lib.rs:1198` | Actual RecoveryResponse insertion retains view/nonce/state provenance, including overwrites; shadow maps clear with real maps |
| `specula_observe.rs` | Full private replica/client snapshots and uniform message/reply serialization; accessors cross-check shadow rows against real maps |
| `examples/kvstore/specula_harness.rs:354` | Outer `on_message` return, before persistence; classifies Prepare/NewState by pre-state and records exact incoming envelope plus duplicate `keep` |
| `examples/kvstore/specula_harness.rs:344` | Exactly one real `on_idle`, then full post-state |
| `examples/kvstore/specula_harness.rs:236` | Calls unchanged kvstore `persist_view`, rereads the file, captures successful persistence or same-view no-op |
| `examples/kvstore/specula_harness.rs:260` | Publishes one drained message or reply; messages precede replies; unpublished remainder stays in owner queues |
| `examples/kvstore/specula_harness.rs:301` | Real client invocation and original operation, outbox transfer, historical real-time edges |
| `examples/kvstore/specula_harness.rs:328` | Real pending-client retry and outbox transfer |
| `examples/kvstore/specula_harness.rs:354` | Also handles real `Client::on_reply`; records completion only when accepted |
| `examples/kvstore/specula_harness.rs:458` | Drops real volatile replica and unpublished queues; retains durable view and published transport |
| `examples/kvstore/specula_harness.rs:483` | Real `Replica::recover` with file-backed durable floor, fresh per-replica incarnation nonce, new Store |
| `examples/kvstore/specula_harness.rs:507` | Fault-schedule stabilization; loss/down-delivery boundaries are nearby |
| `examples/kvstore/specula_harness.rs:520` | Frame event methods, called only after corresponding real socket observations |
| `examples/kvstore/main.rs:403` | Observation-only inspect of actual `lines()` success or error before unchanged `map_while(Result::ok)` |
| `examples/kvstore/main.rs:418` | Signals receive-loop completion after all possible dispatches, enabling a synchronized reset/no-dispatch assertion |

All transition records are serialized through one mutex-protected writer per scenario, immediately flushed, and closed on `finish`. Atomic ordering is the deterministic owner schedule, not timestamp sorting. Replica fields come from the real objects; Store values are read directly, never reconstructed from installed logs. Execution entries come from the commit hook. Global history is the deduplicated union of those actual observations.

Replica IDs remain 0..N-1 and clients retain unique IDs 100/101. Request numbers remain zero-based while op numbers are naturally one-based. Nonces are fresh monotonic per-replica incarnation integers, retained on delayed message snapshots. Equal queued envelopes are coalesced only in the abstract snapshot; real multiplicities determine `keep`. Dropping a non-last equal copy changes no abstract state.

## Socket evidence and scope

`src/frame_probe.rs` invokes the unchanged real `encode`, `decode`, `run_sender`, and `run_peer_acceptor`. An ignored child-test entry point only runs when explicitly launched by the parent. A 32 MiB ASCII value forces an ordinary blocking sender write to remain incomplete. The test waits for a syntactically valid nonempty prefix, kills that sender process, and retains **every byte** still received until measured clean EOF. It does not choose a shorter substring. The retained bytes are a strict prefix of real encoder output and have no newline.

The local transport is an explicit **two-connection byte-preserving store-and-forward proxy**: the source connection measures sender interruption and EOF; the destination connection forwards all surviving bytes unchanged to the real acceptor. Clean FIN preserves the measured source outcome. The reset case separately injects SO_LINGER reset on the destination connection and requires both the actual `ConnectionReset` observation and receive-loop completion before asserting no dispatch. This is a composed sender/acceptor experiment, not a full three-process kvstore deployment. The clients remain in the stable owner environment as the input abstraction requires. Acceptor listener threads are confined to the test executable and end when it exits; connection workers are synchronized individually.

Complete-frame forwarding uses seven-byte writes; TCP may coalesce them, so the evidence establishes application write fragmentation, not a measured number of receiver reads. Incomplete unsupported frame variants and every possible EOF cut position are outside these scenarios.

`traces/frame-evidence/` retains original encoder bytes, first received prefix, all surviving bytes, lengths, SHA-256 hashes, sender PID/exit status, sender-entered/returned markers, and actual receiver outcomes. `results/manifest.json` verifies that encode/decode/run_sender/persist_view function bodies equal the pinned Git originals. `harness/Cargo.lock` records resolved build dependencies.

The long original value maps to `AA`; the actual nonempty received value maps to `A`. Raw bytes remain in sidecars. The EOF trace preserves the original `AA` invocation, then shows real backups accepting and committing `A`, the original client completing, a later Get returning `A`, and the recovered replica retaining `A`. This is integration-defect evidence; successful TraceMatched replay means the supplied model reproduces that behavior, not that it satisfies linearizability. Other core scenarios are finite conformance and progress coverage, not proofs of absence of bugs. No external issue or commit is created.

## Adjusting instrumentation

1. Edit canonical `src/observe.rs` to add a field to `replica_snapshot`, `client_snapshot`, or normalization. Capture real state or explicit reception metadata. Add the corresponding exact check in Trace's normalization/model snapshot; the audit rejects extra or missing replica fields. Extend `audit_traces.py` schema alongside it. Add new raw values with `register_value`, preserving equality within each scenario; unsupported keys/values fail explicitly.
2. To add an outer event, follow `receive` or `idle_raw`: invoke the real API, classify using pre-state when required, then call `emit` with exact action inputs and full post-state. Add the matching Trace wrapper and a scenario. Internal helpers update the same outer event and must not emit extra transitions.
3. To change capture timing, move the emit relative to the actual API boundary in `harness.rs`; move execution/map hooks in `patch_observe.py` only when the observation itself belongs at another real source point. Never reconstruct application execution from a new log.
4. Re-run `bash harness/run.sh`. For one replay: `bash harness/validate.sh traces/specula_rolling_recovery.ndjson`. For source-hook changes, first use `clean.sh`, edit the patcher, and apply again; regenerate `patches/instrumentation.patch` from the resulting source diff. Copied module-only changes simply need apply/run.

TLC logs include the failing cursor on mismatch. Inspect that incoming event and its previous post-state before changing capture points. Keep `TraceMatched` and full equality enabled. Legacy generation fixtures under `spec/validation/` used the old `vsr` tag; normalize their tag if reusing those synthetic engine tests, and keep them separate from implementation traces.
