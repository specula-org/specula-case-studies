# TLA+ Specifications: libspdm-version-cap-algo

Quick reference guide to the generated TLA+ specifications and their usage.

## File Organization

### Core Specifications (Phases 1-3)

| Phase | Files | Purpose |
|-------|-------|---------|
| **1: Base Spec** | `base.tla`, `base.cfg` | Core protocol model with bug-family extensions |
| **2: Model Checking** | `MC.tla`, `MC.cfg`, `MC_hunt_*.cfg` | Exhaustive state space exploration with fault injection |
| **2.5: Audit** | `brief-coverage.md` | Verification that all bug families are covered |
| **3: Trace Validation** | `Trace.tla`, `Trace.cfg` | Replay implementation traces against spec |

### Documentation

| Document | Purpose |
|----------|---------|
| `instrumentation-spec.md` | How to instrument source code for trace collection |
| `GENERATION_SUMMARY.md` | Detailed overview of spec generation (this is the main doc) |
| `README.md` | This file |

---

## Quick Start

### 1. Understand the System

Read the brief section of `GENERATION_SUMMARY.md`:
- 5 bug families identified in Phase 1
- 4 are modeled, 1 intentionally out-of-scope
- Category A (message-passing), single-threaded event loop

### 2. Review the Base Spec

Read `base.tla` sections in order:
1. **Constants** — Algorithm identifiers (opaque values)
2. **Variables** — Standard protocol + extension variables for each bug family
3. **Actions** — 12 actions: 6 requester path, 6 responder path
4. **Invariants** — 8 properties: 6 safety, 2 structural

Key files to cross-reference:
- `libspdm_req_get_version.c` (requester VERSION exchange)
- `libspdm_req_negotiate_algorithms.c` (requester ALGORITHMS validation)
- `libspdm_rsp_version.c` (responder VERSION handling)
- `libspdm_rsp_algorithms.c` (responder ALGORITHMS negotiation)

### 3. Run Model Checking

After trace validation passes:

```bash
# Standard convergence check
tlc MC.cfg

# Hunt each bug family
tlc MC_hunt_family1.cfg   # Algorithm validation gap
tlc MC_hunt_family2.cfg   # Prioritization failure
tlc MC_hunt_family4.cfg   # Version reset mid-handshake
tlc MC_hunt_family5.cfg   # Conditional validation
```

### 4. Validate Against Traces

Generate traces using `instrumentation-spec.md`, then run:

```bash
tlc Trace.cfg
```

Critical: `TraceMatched` property must pass (entire trace consumed).

---

## Bug Families at a Glance

### Family 1: Asymmetric Algorithm Validation Gap
- **Risk**: HIGH
- **Mechanism**: Responder accepts algorithm without checking local support
- **Spec**: `ResponderHandlesAlgorithms` action (lines 494-551)
- **Hunt**: `MC_hunt_family1.cfg`
- **Invariants**: `AlgorithmIntersectionNonEmpty`, `ResponderAlgoInLocalSupport`

### Family 2: Prioritization Silent Failure
- **Risk**: HIGH
- **Mechanism**: `prioritize_algorithm` returns 0; callers don't check
- **Spec**: `PrioritizeAlgorithm` helper (line 182) + action handling
- **Hunt**: `MC_hunt_family2.cfg`
- **Invariant**: `PrioritizationSucceeds`

### Family 4: Version Reset Mid-Handshake
- **Risk**: MEDIUM
- **Mechanism**: GET_VERSION can arrive after CAPABILITIES, losing state
- **Spec**: `ResponderHandlesVersion` (lines 449-463) + fault action
- **Hunt**: `MC_hunt_family4.cfg`
- **Invariants**: `VersionNegotiatedBeforeCapabilities`, `VersionNegotiatedBeforeAlgorithms`

### Family 5: Conditional Validation
- **Risk**: MEDIUM
- **Mechanism**: Requester validation only if capabilities enabled
- **Spec**: `ShouldValidateAlgorithms` helper + `RequesterValidatesAlgorithms` action
- **Hunt**: `MC_hunt_family5.cfg`
- **Invariant**: `RequesterValidatesIfCapabilitiesEnabled`

### Family 3: Capability Flags
- **Status**: OUT OF SCOPE (per modeling brief)
- **Reason**: Too detailed for TLA+ model; let code review handle
- **Abstract Model**: `enabledCapabilities` set

---

## Key Design Decisions

1. **Separate Requester and Responder**: Different state machines, asymmetric validation
2. **Separate Algorithm Assignment and Response**: Family 2 happens between actions
3. **Conditional Validation**: `ShouldValidateAlgorithms` predicate captures Family 5 mechanism
4. **Fault Injection via Normal + Faulty Paths**: Counter-bounded actions in MC.tla
5. **Mandatory Post-State Validation**: Trace.tla ValidatePostState functions (not stubs)

---

## Code Cross-Reference

All actions annotated with source file:line. Key locations:

| Code Path | Family | Lines |
|-----------|--------|-------|
| libspdm_rsp_algorithms.c | 1 | 565-566 (direct assignment), 42-56 (prioritize), 724-747 (response) |
| libspdm_req_negotiate_algorithms.c | 5 | 474-541 (conditional validation) |
| libspdm_rsp_version.c | 4 | 81 (reset context), 54-127 (overall handler) |
| libspdm_rsp_capabilities.c | 4 | 165-380 (capabilities handler) |

---

## Verification Checklist

Before proceeding to harness generation:

- [ ] Read `GENERATION_SUMMARY.md` (detailed overview)
- [ ] Review `base.tla` (understand actions)
- [ ] Check `brief-coverage.md` (verify coverage claims)
- [ ] Read `instrumentation-spec.md` (prepare to instrument code)
- [ ] Understand `MC_hunt_*.cfg` patterns (1 per bug family)

---

## Next Steps (Harness Generation)

See `instrumentation-spec.md` for:
- 12 instrumentation points (action-to-code mapping)
- Exact code locations to patch
- Fields to capture in traces
- NDJSON format specification

After instrumentation + trace collection → run Trace validation → model checking.

---

## FAQ

**Q: Why is Family 3 (Capability Flags) out of scope?**  
A: The brief identified 20+ version-specific flag rules. Modeling all combinations would explode state space. The abstract `enabledCapabilities` set captures the semantic essence without all details. Flag composition is better handled via code review (CR2 in brief).

**Q: Why are actions split (e.g., HandleAlgorithms + SendAlgorithms)?**  
A: The implementation has these as separate operations (lines 557-695 vs 724-747). Family 2 (prioritization) happens during handling; response construction happens later. Splitting enables precise bug modeling.

**Q: Do I need to run all 4 hunting configs?**  
A: Yes. Each config targets a different bug family. Running all 4 ensures comprehensive coverage of the identified mechanisms. They're independent (no prerequisites).

**Q: What if trace validation fails?**  
A: Check `ValidatePostState` errors in TLC output. Likely causes:
1. Instrumentation timing (capture before/after state mismatch)
2. Field mapping error (trace field ≠ spec variable)
3. Spec bug (rare; check action preconditions)

**Q: Can I model extended algorithms?**  
A: No; the brief marks them as "currently unsupported" (line 10 of libspdm_rsp_algorithms.c). Only fixed algorithms are modeled.

---

## Contact / Support

- **Spec Generation Guide**: `/home/ubuntu/Specula/.claude/skills/spec_generation/guide.md`
- **Modeling Brief**: `../modeling-brief.md`
- **SPDM Specification**: DSP0274 (Distributed Management Task Force)

---

**Generated**: 2026-06-04  
**Ready for Phase 2.5**: Harness Generation
