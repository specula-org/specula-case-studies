# TLA+ Specifications for SPDM Chunking

This directory contains the complete TLA+ specification suite for the libspdm large-message chunking/reassembly protocol, generated from the modeling brief in Phase 2.

## Quick Start

### 1. Understand the System
- Read [`../modeling-brief.md`](../modeling-brief.md) for the 5 bug families and analysis findings
- Read [`GENERATION_SUMMARY.md`](GENERATION_SUMMARY.md) for overview of generated artifacts

### 2. Inspect the Base Spec
```bash
# Core protocol logic
less base.tla

# Configuration for base spec
less base.cfg
```

Key sections:
- **Variables** (lines 25–35): chunk_context, large_message, messages, responses
- **Extensions** (lines 38–43): interruption_allowed, seq_no_wrap_error, chunk_phase, large_message_capacity, large_message_valid
- **Actions** (lines 150–270): ChunkSendInit, ChunkSendContinuation, ReceiveInterruption, ErrorDuringReassembly, message handlers
- **Invariants** (lines 285–359): Safety + extension (bug-family specific)

### 3. Run Model Checking

#### Standard Convergence (baseline safety check)
```bash
tlc -config MC.cfg base.tla
```
Checks core safety invariants; extension invariants commented out.

#### Bug Hunting (per-family focus)
```bash
# Family 1: Interruption Handling
tlc -config MC_hunt_family1.cfg base.tla

# Family 2: Sequence Number Wrap
tlc -config MC_hunt_family2.cfg base.tla

# Family 3: Size Calculation Asymmetry
tlc -config MC_hunt_family3.cfg base.tla

# Family 4: Buffer Capacity Overflow
tlc -config MC_hunt_family4.cfg base.tla

# Family 5: Cleanup on Error
tlc -config MC_hunt_family5.cfg base.tla
```

Each hunting config has tight bounds and targets a single bug family's invariant.

### 4. Trace Validation (after instrumentation)

After collecting traces from instrumented code:
```bash
tlc -config Trace.cfg base.tla \
  -DIOenv.JSON=../traces/trace.ndjson
```

Validates that implementation traces match base spec logic.

## File Guide

| File | Purpose | Size |
|------|---------|------|
| `base.tla` | Core TLA+ spec with bug-family extensions | 16 KB |
| `base.cfg` | Configuration for base spec | 382 B |
| `MC.tla` | Model checking wrapper with fault injection | 4.9 KB |
| `MC.cfg` | Standard safety config (convergence check) | 1.4 KB |
| `MC_hunt_family*.cfg` | 5 configs for family-specific bug hunting | 1.8 KB each |
| `Trace.tla` | Trace validation spec | 6.1 KB |
| `Trace.cfg` | Trace validation config | 963 B |
| `instrumentation-spec.md` | Action-to-code mapping for harness generation | 15 KB |
| `brief-coverage.md` | Phase 2.5: self-audit of brief-to-spec coverage | 8.7 KB |
| `GENERATION_SUMMARY.md` | Overview of all generated files | — |

## Bug Families & Invariants

| Family | Priority | Mechanism | Spec Target | Hunt Config |
|--------|----------|-----------|---|---|
| F1 | HIGH | Improper interruption handling | `ChunkTransferPreservation` | `MC_hunt_family1.cfg` |
| F2 | MEDIUM | Sequence number wrap asymmetry | `SeqNoContinuity` | `MC_hunt_family2.cfg` |
| F3 | MEDIUM | First-chunk vs. continuation size | `FirstChunkBoundary`, `ContinuationChunkBoundary` | `MC_hunt_family3.cfg` |
| F4 | MEDIUM-HIGH | Unverified buffer capacity | `ReassemblyCapacity`, `ReassemblyComplete` | `MC_hunt_family4.cfg` |
| F5 | LOW-MEDIUM | Cleanup on error path | `BufferValidityAfterError`, `StateCleanupAfterInterruption` | `MC_hunt_family5.cfg` |

## Key Design Decisions

### Action Splitting
- **`ChunkSendInit`** vs **`ChunkSendContinuation`**: Different code paths with different size calculations → separate actions (Family 3)
- **`ReceiveInterruption`**: Isolated from normal message handling to expose state-clearing bug (Family 1)
- **`ErrorDuringReassembly`**: Separate to model error paths and cleanup (Family 5)

### Extension Variables
- **`interruption_allowed`**: Tracks allowed vs. forbidden interruptions (GET_VERSION, DecryptError) — Family 1
- **`seq_no_wrap_error`**: Version-dependent wrap behavior (SPDM 1.2/1.3 vs. 1.4+) — Family 2
- **`chunk_phase`**: INIT vs. CONTINUATION to enforce code-path-specific constraints — Family 3
- **`large_message_capacity`**: Buffer capacity constraint for overflow detection — Family 4
- **`large_message_valid`**: Buffer validity after error/interruption — Family 5

### State Space Management
- Message buffer limited to 4 messages (prevents explosion)
- Counter bounds on fault injection: timeout (3), loss (3), crash (2), init (4), continuation (4)
- Tight bounds in hunting configs to isolate target bugs

## Coverage Assessment

✅ **All 5 bug families modeled**
- Each has spec actions, extension variables, and extension invariants
- Each has a dedicated hunting config with tight bounds and targeted invariants

✅ **95% brief coverage**
- All model-checkable findings (MC1–MC4) are reachable
- MC5 (Family 5): Spec currently models correct behavior; needs adjustment to expose the stale-buffer bug

⚠️ **Next: Instrumentation**
- Need to add `large_message_valid` shadow flag to source code
- Instrument 6 action points with trace event emission
- See `instrumentation-spec.md` for detailed mapping

## Testing the Spec

### Quick Sanity Check
```bash
# Check that spec converges with reasonable bounds
tlc -config MC.cfg base.tla -maxSetSize 100000 -workers 4
```

### Full Bug Hunting (parallel)
```bash
for f in 1 2 3 4 5; do
  echo "Hunting Family $f..."
  tlc -config MC_hunt_family${f}.cfg base.tla &
done
wait
```

### Inspect Counterexample
```bash
# If invariant violated, check TLC output
less tlc_trace.txt  # Generated by TLC on invariant violation
```

## Reference & Context

- **Modeling Brief**: [`../modeling-brief.md`](../modeling-brief.md)
  - 5 bug families with evidence (code locations, GitHub issues)
  - Proposed variables, actions, and invariants
  - Model-checkable findings (MC1–MC5)

- **SPDM Specification**: DSP0274 v1.3, §23.3 (chunked transfer)
  - Defines expected responder behavior
  - Exception: large-message reassembly (not in requester responsibility)

- **Source Code**: [`../artifact/libspdm/`](../artifact/libspdm/)
  - `libspdm_rsp_chunk_send_ack.c`: Responder chunk-send handler
  - `libspdm_rsp_chunk_response.c`: Responder chunk-get handler
  - `libspdm_rsp_receive_send.c`: Interruption handling, state management

## Known Issues & TODOs

- **MC5 (Family 5)**: Spec models correct cleanup behavior. To expose the bug:
  - Modify `ErrorDuringReassembly` action to NOT set `large_message_valid' = FALSE`
  - Add `StaleBufferAccess` action that reads invalid buffer
  - Update `MC_hunt_family5.cfg` to target both invariants

- **Instrumentation**: Shadow flag `large_message_valid` is new:
  - Must be added to `libspdm_context.chunk_send_context` structure
  - Set to FALSE on error or interruption
  - Captured in trace events

- **Requester-side**: Currently simplified; full message sequencing deferred to later phase

---

**Phase 2 Status**: ✅ Complete  
**Generated**: 2026-06-04  
**Next Phase**: Harness Generation (Phase 2.5) → collect instrumented traces  
**Next**: Trace Validation & Model Checking (Phase 3)

