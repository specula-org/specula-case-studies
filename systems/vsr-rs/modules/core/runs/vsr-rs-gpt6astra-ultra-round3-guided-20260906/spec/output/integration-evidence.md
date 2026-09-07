# Finding draft: clean EOF can turn a peer PREPARE into a successful altered write

**Classification:** kvstore integration data-integrity defect supported by retained implementation experiments and current source inspection. This document makes no model-checking Case C claim: MC convergence and hunting are owned by the parent validation workflow. No experiment was rerun for this draft.

**Affected revision:** `3ac0104a567092139534c9022205d02281a2da41`. All source anchors below refer to the original files extracted with `git show HEAD:<path>`, before the observation-only instrumentation shifts line numbers.

The peer acceptor can dispatch a nonempty, unterminated final line at clean EOF. If transmission stopped inside a PUT's final value token, the remaining bytes form a syntactically valid PREPARE for a shorter value with the original view, operation position, client ID, and request number. The affected backup can carry that value into the next view, commit it, and cause the original SET to receive success. A GET invoked afterwards by another client returns the shorter value. With one SET and no intervening write, that history has no legal sequential explanation.

## Reachable sequence and source anchors

1. In a three-replica cluster, a client submits `Put(k, full)` to primary 0. It appends the original operation and emits PREPAREs (`lib.rs:675-693`). A value consisting of one long ASCII word satisfies the example's documented command domain (`examples/kvstore/README.md:37`; parser `main.rs:424-440`).
2. The unchanged sender starts the PREPARE to replica 1 and primary 0 crashes during the payload write. A nonempty strict prefix ending inside the final value arrives, followed by clean EOF. The acceptor decodes it as `Put(k, prefix)` and dispatches it.
3. Replica 1 appends that operation at position 1. Replica 2 has not received the original PREPARE. After the primary crash, replica 1's longer log is selected for the new view and installed on replica 2. Replica 2 acknowledges, the new primary commits, and the original client completes successfully.
4. A second client's later Get returns `prefix`. The Phase 2.5 continuation also recovers replica 0 and checks its actual Store retains the prefix.

| Mechanism | Exact pinned source anchors |
|---|---|
| PUT value is the final encoded token | `examples/kvstore/main.rs:79-82`, PREPARE construction `99-117` |
| Encoded payload and newline are written separately | `examples/kvstore/main.rs:383-386` |
| EOF line loses framing information and is dispatched after decoding | `examples/kvstore/main.rs:397-411` |
| Parser accepts any nonempty final value token | `examples/kvstore/main.rs:204-219`, PREPARE parser `237-254`, successful return `334` |
| Backup appends the next slot; duplicate PREPARE keeps its existing payload and acknowledges again | `lib.rs:708-730` |
| New primary chooses and installs the latest-normal/longest candidate log, then sends StartView | `lib.rs:1043-1080`; backup installation/acknowledgement `948-967` |
| A quorum commits the installed entry; Store applies the actual operation | `lib.rs:737-768`, `1349-1377`; `examples/kvstore/main.rs:56-62` |
| Original identity survives; a retried request can receive its cached result without comparing operation content | `lib.rs:658-674`, `1324-1344` |
| Client accepts its request-number reply; SET becomes +OK and Get returns the actual result | `lib.rs:334-344`; `examples/kvstore/main.rs:528-537`, `587-592` |

Retransmission is not an unconditional repair: an already-filled same-view slot is neither compared nor replaced by duplicate PREPARE (`lib.rs:716-730`). A matching commit executes that existing slot (`776-785`). The demonstrated view-change continuation instead propagates the altered slot and commits it before the later read. This locates the root cause in peer frame completion in the shipped example; the core library receives the already-altered typed message. It does not establish a core-library defect under intact-message delivery.

## Evidence and its limits

**Measured sender/acceptor composition.** `harness/src/frame_probe.rs:119-235` creates the body with real `encode`, invokes unchanged `run_sender` in a child, kills the live child before its returned marker, and retains every byte through successful `read_to_end` EOF. All 1,794,048 surviving bytes are a strict no-newline prefix of the 33,554,458-byte encoded body; the actual value shrinks from 33,554,432 to 1,794,022 bytes. The complete surviving buffer is forwarded unchanged over a second connection to the real acceptor (`frame_probe.rs:237-338`). Sidecar lengths and original/surviving/forwarded hashes independently match; see [evidence-audit.md](evidence-audit.md). This is a two-connection byte-preserving proxy experiment, not the three-binary run below.

The synchronized receiver outcomes distinguish complete-frame application fragmentation (`Ok(28)`, unchanged dispatch after seven-byte writes), clean EOF (`Ok(1794048)`, altered dispatch), and injected destination reset (`Error(ConnectionReset)`, loop completed with no dispatch). Ordinary fragmentation alone does not expose an incomplete line. EOF after the entire payload but before its newline also preserves content. Missing required tokens or a read error reject the affected input; only a parseable strict prefix demonstrates this corruption mechanism.

**Finite trace conformance and application harm.** The hashed `traces/specula_frame_eof.ndjson` records original `Put(AA)` at line 2, altered `Put(A)` appended at line 10, original client completion at line 44 with `A` committed at position 1, a different client's Get invocation at line 52, and result `A` at line 68. Recovery begins at line 69; the real Store assertion is in `frame_probe.rs:406-408`. `AA` and `A` name the distinct measured byte strings. Retained Phase 2.5 replay results report TraceMatched with full normalized post-state checks. That is finite conformance with the supplied model, whose trace configuration intentionally permits this integration failure; it is neither a safety proof nor an MC-discovered finding.

**Independent three-process route.** `evidence/kvstore-process-check-2.py:25-64` starts three shipped example processes, sends a real 16 MiB SET through an ordinary client connection to node 2, briefly SIGSTOPs node 1, observes primary 0's nonempty socket send queue, SIGKILLs primary 0, and resumes node 1. It waits for the original `+OK\r\n` before opening a fresh client connection and issuing Get. `evidence/kvstore-process-check-2/result.json` records a 2,623,764-byte strict prefix of the 16,777,216-byte value. No protocol bytes are invented or replaced by this driver. This is independent of the deterministic owner and the two-connection proxy; after the brief receiver scheduling pause, only one replica remains down.

The driver, result, all three process logs, and currently retained binary each still match `evidence/artifact-manifest.json`. The binary SHA-256 is `c8f4ffd174f3c4b4f1582cb83591e41fbdd5df972142708b84922690d024aea1`; the manifest records the pinned source and empty tracked diff at capture. The recorded original/result value hashes also match the corresponding lengths of repeated `v`. No fresh build or execution was performed here. This run retains client results and process logs but no raw peer capture, per-handler state, or explicit receiver EOF observation; the separately audited byte-level experiment supplies that part of the mechanism. Its logs show multiple view changes, so no exact view-1-only schedule or liveness conclusion is attributed to this process run.

## Suggested repair direction

Require a complete peer frame before calling `decode`. For the existing line protocol, read while retaining the delimiter and discard a nonempty buffer that reaches EOF without its terminating newline. Combining the sender's two writes into one `write_all` does not provide frame atomicity: a process can still fail after a partial write. Preserve regression cases for fragmented complete input, actual interrupted-sender clean EOF, read-error/reset rejection, and the successful-SET/later-Get result. No source repair is included in this draft.
