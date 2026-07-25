# Brief Coverage Self-Audit

**Target**: libspdm large-message chunking / reassembly  
**Spec files**: base.tla, MC.tla, MC.cfg, MC_hunt_family1-5.cfg  
**Audit date**: 2026-06-08

---

## Bug Families (brief §2)

| Family | Mechanism | Hunt cfg | Status |
|--------|-----------|----------|--------|
| Family 1: TransferTerminationConditionIncompleteness | Loop exits on byte-count alone; LAST_CHUNK flag not required | MC_hunt_family1.cfg | Covered — `MCTransferCompleteImpliesLastChunk` enabled |
| Family 2: ControlFlowOrderingSeqNoMismatch | Seq-no check is standalone `if`, does not short-circuit copy/advance | MC_hunt_family2.cfg | Covered — `MCNoStateAdvanceOnSeqNoMismatch` enabled |
| Family 3: ReassemblyOutputValidityAfterCompletion | Missing else branch: buffer overflow silently returns SUCCESS without writing output | MC_hunt_family3.cfg | Covered — `MCSuccessImpliesOutputWritten` enabled; `ResponseCapacity=8 < MaxLargeSize=12` makes path reachable |
| Family 4: SourceLengthUnboundedInReassemblyCopy | `chunk_size` used as source-length in `libspdm_copy_mem` without bound against received buffer | MC_hunt_family4.cfg | Covered — `MCSourceBoundedness` enabled; `RequesterProcessChunkResponseSourceUnbounded` action models the over-read |
| Family 5: MutualExclusionAsymmetry | CHUNK_RESPONSE handler lacks `send_in_use` check; CHUNK_GET accepted mid-SEND | MC_hunt_family5.cfg | Covered — `MCSingleDirectionAtATime` enabled; `ResponderServesChunkGetWhileSendInProgress` is the trigger action |

All five families have dedicated hunt configs. No mergers.

---

## Invariants (brief §5)

| Invariant | Type | Defined in | Wired in MC.tla | Enabled in hunt cfg |
|-----------|------|-----------|-----------------|---------------------|
| `TransferCompleteImpliesLastChunk` | Safety | base.tla | Yes (`MCTransferCompleteImpliesLastChunk`) | MC_hunt_family1.cfg |
| `NoStateAdvanceOnSeqNoMismatch` | Safety | base.tla | Yes (`MCNoStateAdvanceOnSeqNoMismatch`) | MC_hunt_family2.cfg |
| `SuccessImpliesOutputWritten` | Safety | base.tla | Yes (`MCSuccessImpliesOutputWritten`) | MC_hunt_family3.cfg |
| `SourceBoundedness` | Safety | base.tla | Yes (`MCSourceBoundedness`) | MC_hunt_family4.cfg |
| `SingleDirectionAtATime` | Safety | base.tla | Yes (`MCSingleDirectionAtATime`) | MC_hunt_family5.cfg |
| `SeqNoMonotone` | Safety | base.tla | — | Not in any hunt cfg (structural; enforced by action preconditions) |
| `LargeMessageSizeConsistent` | Safety | base.tla | `MCLargeMessageSizeConsistent` | MC.cfg (structural) |

Notes:
- `SeqNoMonotone` is declared in base.tla but not enabled in a hunt cfg because it is enforced by the action preconditions themselves (only `ResponderChunkSendReceivedValidSeqNo` advances `send_seq_no` and it requires `msg.seq_no = send_seq_no + 1`). Enabling it as a standalone hunt cfg would not find new bugs beyond what Family 2 already covers. This is an intentional decision.
- `LargeMessageSizeConsistent` is enabled in the base MC.cfg as a structural check rather than a bug-hunt invariant, which is correct: it would be violated only by a spec modeling error, not by a protocol bug.

---

## Model-Checkable Findings (brief §6.1)

| Finding | Expected violation | Trigger mechanism | Hunt cfg | Reachable? |
|---------|--------------------|-------------------|----------|-----------|
| MC1: CHUNK_GET returns SUCCESS with bytes satisfied but LAST_CHUNK never set | `TransferCompleteImpliesLastChunk` | `RequesterTransferCompleteSuccess` fires while `last_chunk_received=FALSE` | MC_hunt_family1.cfg | Yes — `ResponderServesChunkGet` can non-deterministically set `is_last=FALSE` on the final fragment |
| MC2: CHUNK_SEND with wrong seq_no advances `chunk_bytes_transferred` | `NoStateAdvanceOnSeqNoMismatch` | `ResponderChunkSendReceivedInvalidSeqNo` bug-path sub-case | MC_hunt_family2.cfg | Yes — the action has two sub-cases; TLC explores the state-advance path |
| MC3: CHUNK_GET returns SUCCESS with output not written (buffer too small) | `SuccessImpliesOutputWritten` | `RequesterTransferCompleteBufferOverflow` fires with `output_written=FALSE` | MC_hunt_family3.cfg | Yes — `ResponseCapacity=8 < MaxLargeSize=12`, so large_response_size > capacity is reachable |
| MC4: Responder-controlled `chunk_size` exceeds received buffer, `libspdm_copy_mem` reads past end | `SourceBoundedness` | `RequesterProcessChunkResponseSourceUnbounded` fires | MC_hunt_family4.cfg | Yes — action explicitly models `chunk_size > received_msg_size - HeaderOverhead` |
| MC5: CHUNK_GET completes while `send_in_use=TRUE` | `SingleDirectionAtATime` | `ResponderServesChunkGetWhileSendInProgress` fires | MC_hunt_family5.cfg | Yes — action accepts CHUNK_GET without checking `send_in_use` |

All five §6.1 findings are targeted by a hunt cfg with a reachable trigger.

---

## Gaps and Deliberate Exclusions

- **§6.2 test-verifiable findings** (TV1–TV3): not covered by TLA+ spec per brief §3.2 guidance (implementation-level bugs better addressed by unit tests or sanitizers).
- **§6.3 code-review findings** (CR1–CR4): not modeled; these are coding-style and version-consistency issues without protocol reachability implications.
- **`chunk_handle` double-increment**, **`large_message_capacity` not set for GET context**, **uninitialized `message`/`message_size`**, **seq_no type mismatch**, **transport padding overflow**: explicitly excluded in brief §3.2; not modeled.
