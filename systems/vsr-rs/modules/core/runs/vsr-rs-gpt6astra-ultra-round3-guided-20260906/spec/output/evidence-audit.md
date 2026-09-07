# Phase 2.5 evidence audit

Audited on 2026-09-06 against source revision `3ac0104a567092139534c9022205d02281a2da41`. This was a read-only inspection of capture code and retained evidence; no network experiments, trace replay, model checking, or trace regeneration were performed by this audit.

**Conclusion:** no concrete source drift, byte-provenance mismatch, or capture defect requires regenerating the seven retained traces. They remain suitable inputs for fresh validation. This audit does not substitute for that validation or establish general correctness.

## Integrity and validation checks

- Independently recomputed all 53 checked revision/hash/length assertions from `harness/results/manifest.json` and frame metadata: all passed. All seven trace hashes, ten canonical harness/script hashes, source and retained Cargo.lock hashes, and the recorded instrumentation patch hash match. The current tracked source diff is byte-for-byte the recorded patch; all four copied observer/harness modules equal their canonical files.
- Extracted `encode`, `decode`, `run_sender`, and `persist_view` from both the current file and `git show HEAD:examples/kvstore/main.rs`; every function matches its recorded SHA-256 and the pinned original. The source hashes in `spec/input-provenance.json` correctly name the original Git blobs before instrumentation.
- Reused `audit_traces.py`'s per-file read-only audit routine without rewriting its reports: all 884 records in seven files pass complete snapshot schema and timestamp checks. Event coverage is 33/33 including Init; this is event coverage, not branch or schedule coverage.
- Examined every wrapper independently: all 32 call `Advance(e)`, which calls the active `ValidatePostState(p) == ModelSnapshot'=NormSnapshot(p)` (`Trace.tla:66-68`). Init also compares the full normalized initial state (`Trace.tla:138-141`); `Trace.cfg` enables `PROPERTIES TraceMatched`. There are no silent action branches before exhaustion.
- Full equality is at the documented abstraction: network/maps/sets normalize keyed rows, retry attempts saturate at 10, stable time saturates at the primary timeout, and actual long/prefix values map to distinct `AA`/`A` symbols. It is not literal byte equality inside the finite TLA+ state; bytes are retained separately.

`spec/artifact-manifest.json` predates the Phase 2.5 tag adaptation. Its only mismatches are `Trace.tla` and `instrumentation-spec.md`; retained originals match the old hashes, and current differences are exactly the recorded `harness/patches/trace-tag.patch`. Current `Trace.tla` SHA-256 is `98968d997f58db7caf2992df11ab0409706144deda5fa282fb112712623516a9`. This is explained provenance, not a trace-regeneration trigger. The final validation manifest should bind the current spec separately. Frame sidecars have internally verified hashes in their provenance/receiver records; the harness manifest hashes NDJSON, not the complete sidecar tree. These are content-integrity records, not an external attestation of execution.

## Capture semantics

The feature-gated `lib.rs` diff only adds observer fields, cloned DVC/RecoveryResponse provenance, corresponding shadow-map clearing, and execution records after the actual application call. No original protocol branch, map update, log operation, or application input changes. Snapshot accessors read real fields and cross-check shadow map contents against real maps (`harness/src/observe.rs:267-354`). Application state comes from `Store.map` (`harness/src/harness.rs:36-40`), and committed history retains actual execution-hook records across crashes (`harness.rs:196-200`), rather than reconstructing execution from installed logs.

The deterministic owner invokes actual `Replica`/`Client` APIs, captures outer-handler state before persistence, invokes unchanged `persist_view` and rereads the file, and releases one pending output at a time. Crash drops volatile replicas and unpublished queues while preserving durable views and already published transport. These are explicit environment schedules; the harness is not a reimplementation of VSR. The two acceptor hooks inspect `lines()` results and signal loop completion without changing decode/dispatch decisions (`source/examples/kvstore/main.rs:403-419`).

## Retained frame evidence

| Case | Independently verified bytes | Recorded acceptor outcome |
|---|---|---|
| Complete, destinations 1 and 2 | Each received file is exactly `encode(frame)` plus newline: 29 bytes | `Ok(28)`, dispatch true; forwarding used seven-byte application writes |
| Clean EOF | 1,794,048 surviving bytes are a strict prefix of the 33,554,458-byte encoded body; no newline; initial 4,096-byte read is a prefix of all surviving bytes | `Ok(1794048)`, dispatch true, receive loop completed |
| Reset | Same verified prefix relation and lengths; receiver forwarded hash equals surviving-file hash | `Error(ConnectionReset)`, dispatch false, receive loop completed |

For EOF/reset, encoded SHA-256 is `85509deb3b7e2bd38ff24ca9d7ab20108073b15179b325846cace1a5fe121573`; surviving/forwarded SHA-256 is `af95503c34270956abe3ce13a1236586f495a02e7fefaaccb91fe04a9c21c141`. The valid encoder header is `PREPARE 0 1 0 100 0 PUT k `; the original 33,554,432-byte value becomes the actual 1,794,022-byte nonempty final token.

The inspected harness creates bytes with unchanged `encode`, calls unchanged `run_sender` in a child, kills the live child before its returned marker, then retains every byte through successful `read_to_end` EOF (`frame_probe.rs:119-235`). It forwards that complete surviving buffer to the real acceptor on a second connection (`frame_probe.rs:237-338`). Metadata records SIGKILL and no returned marker. Thus the evidence is a composed two-connection byte-preserving proxy experiment. Reset is separately injected on the destination connection. Seven-byte writes establish application fragmentation, not a measured TCP-read fragmentation pattern. No broader cut-position or frame-variant coverage is inferred.

The hashed EOF trace preserves the original `Put(AA)` invocation at line 2, admits `Put(A)` at line 10, records the successful original client's completion at line 44 after `A` committed at position 1, invokes another client's Get at line 52, and records result `A` at line 68. Recovery begins at line 69. The existing test asserts the recovered real Store retains the measured prefix (`frame_probe.rs:368-409`). These are retained implementation observations; final bug classification and independent confirmation belong to the parent validation workflow.
