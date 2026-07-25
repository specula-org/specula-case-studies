# CometBFT TLA+ Specification Suite

## Overview

This directory contains a complete TLA+ specification of the CometBFT consensus algorithm, generated from Phase 1 (code analysis) and covering all 7 bug families identified in the modeling brief.

**Phase**: 2 (Spec Generation) completed
**Status**: Ready for Phase 3 (Trace Validation & Model Checking)
**Last Updated**: 2026-06-04

---

## File Structure

### Core Specification

| File | Purpose | Lines |
|------|---------|-------|
| `base.tla` | Core consensus spec with bug-family extensions | 670 |
| `base.cfg` | Base config with standard parameters | 40 |

### Model Checking Layer

| File | Purpose |
|------|---------|
| `MC.tla` | MC spec wrapper with counter-bounded fault injection | 180 |
| `MC.cfg` | Standard MC config (convergence testing) | 45 |
| `MC_hunt_family1_votehandling.cfg` | Hunting config targeting Family 1 (vote handling) |
| `MC_hunt_family2_lock.cfg` | Hunting config targeting Family 2 (lock/unlock) |
| `MC_hunt_family3_blockassembly.cfg` | Hunting config targeting Family 3 (block assembly) |
| `MC_hunt_family4_recovery.cfg` | Hunting config targeting Family 4 (recovery) |
| `MC_hunt_family5_byzantine.cfg` | Hunting config targeting Family 5 (Byzantine behavior) |
| `MC_hunt_family6_timing.cfg` | Hunting config targeting Family 6 (timeouts) |
| `MC_hunt_family7_extensions.cfg` | Hunting config targeting Family 7 (vote extensions) |

### Trace Validation Layer

| File | Purpose |
|------|---------|
| `Trace.tla` | Trace spec for replaying implementation traces | 350 |
| `Trace.cfg` | Trace validation config | 35 |

### Documentation

| File | Purpose |
|------|---------|
| `instrumentation-spec.md` | Action-to-code mapping for harness generation (Phase 2.5) | ~500 lines |
| `brief-coverage.md` | Self-audit verifying coverage of modeling brief (Phase 2.5) | ~200 lines |
| `README.md` | This file |

---

## Bug Families Covered

All 7 bug families from the modeling brief are modeled with dedicated hunting configs:

1. **Family 1: Code Path Inconsistency in Vote Handling** (High priority)
   - Spec actions: `CheckVote`, `AddVote`
   - Invariants: `NoDuplicateVotes`, `ElectionSafety`
   - Config: `MC_hunt_family1_votehandling.cfg`

2. **Family 2: Lock/Unlock Logic Consistency** (High priority)
   - Spec actions: `EnterPrevote`, `EnterPrecommit`, `UnlockOnPol`, `UpdateValidBlock`
   - Invariants: `LockedSafety`, `ValidBlockConsistency`
   - Config: `MC_hunt_family2_lock.cfg`

3. **Family 3: Non-Atomic Proposal and Block Assembly** (Medium priority)
   - Spec actions: `ReceiveProposal`, `ReceiveBlockPart`, `HandleCompleteProposal`
   - Invariants: `ProposalBlockIntegrity`, `ElectionSafety`
   - Config: `MC_hunt_family3_blockassembly.cfg`

4. **Family 4: Recovery and State Reconstruction** (Medium priority)
   - Spec actions: `CrashAndRecover`
   - Invariants: `CommitConsistency`, `ElectionSafety`
   - Config: `MC_hunt_family4_recovery.cfg`

5. **Family 5: Byzantine Behavior** (High priority)
   - Spec actions: `ByzantineEquivocateProposal`, `ByzantineEquivocateVote`
   - Invariants: `NoForkingWithQuorum`, `ElectionSafety`
   - Config: `MC_hunt_family5_byzantine.cfg`

6. **Family 6: Independent Control Loops and Timing** (Low-medium priority)
   - Spec actions: `HandleTimeout`
   - Invariants: `ElectionSafety`, structural consistency
   - Config: `MC_hunt_family6_timing.cfg`

7. **Family 7: Vote Extension Feature Interactions** (Medium priority)
   - Spec actions: `CheckVoteExtension`
   - Invariants: `VoteExtensionPresence`, `CommitConsistency`
   - Config: `MC_hunt_family7_extensions.cfg`

---

## Safety Invariants

The spec defines 8 safety invariants:

| Invariant | Type | Brief Target | Enabled In |
|-----------|------|--------------|-----------|
| `ElectionSafety` | Core | All families | MC.cfg + all hunt cfgs |
| `NoForkingWithQuorum` | Core | Family 5 | MC.cfg + hunt_family5 |
| `NoDuplicateVotes` | Core | Family 1 | MC.cfg + hunt_family1 |
| `LockedSafety` | Extension | Family 2 | hunt_family2 |
| `ValidBlockConsistency` | Extension | Family 2 | hunt_family2 |
| `VoteExtensionPresence` | Extension | Family 7 | hunt_family7 |
| `ProposalBlockIntegrity` | Extension | Family 3 | hunt_family3 |
| `CommitConsistency` | Extension | Family 4, 7 | hunt_family4, hunt_family7 |

**Note**: Extension invariants are **commented out** in `MC.cfg` (general convergence testing) and **enabled** in their corresponding hunting configs. This prevents "weakening" the general spec while focusing specific hunts on target bugs.

---

## Category and Scope

**Category**: A (Distributed / Message-Passing)
- Network RPC model with message-passing between validators
- Single-threaded state machine (`receiveRoutine`) with external timeouts and gossip
- Modeled at consensus state machine level (consensus/state.go)

**Model Parameters** (from `base.cfg`):
- `Validators`: {v1, v2, v3, v4} (4 validators in base config)
- `Faulty`: {v4} (1 Byzantine validator, 3f+1 = 4 threshold met)
- `MaxHeight`: 3 (heights 1-3)
- `MaxRound`: 2 (rounds 0-2 per height)

**Excluded from Scope** (intentional, per brief §3.2):
- Gossip propagation details (handled by reactor, not consensus state machine)
- Network delays and message reordering (partial synchrony implicit; TLC explores orderings)
- Vote extension content validation (application-specific; model only presence/signature)
- Mempool, block proposal creation (orthogonal to consensus safety)
- WAL internals (mechanism for recovery, covered by crash/recovery actions)

---

## Code References

Every action in the spec annotates its source code location with `file:line` references:

**Key locations**:
- Core state machine: `consensus/state.go:67-2650`
- Vote handling: `consensus/state.go:2238-2348` (Family 1)
- Lock/unlock logic: `consensus/state.go:1464-2432` (Family 2)
- Proposal/block assembly: `consensus/state.go:2006-2184` (Family 3)
- Recovery: `consensus/state.go:186-192, 592-631` (Family 4)
- Reactor receive: `consensus/reactor.go:247` (Family 5)
- Timeouts: `consensus/ticker.go` (Family 6)
- Vote extensions: `consensus/state.go:2296-2345` (Family 7)

---

## How to Use

### Step 1: Verify Spec Syntax (Optional)

Check that TLA+ syntax is correct before model checking:

```bash
cd /home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/cometbft/spec
tlc -config base.cfg -deadlock base.tla  # Syntax check only
```

### Step 2: Run General Model Checking (Convergence)

Start with `MC.cfg` to verify the spec is consistent:

```bash
tlc -config MC.cfg MC.tla
```

Expected: No invariant violations, converges in < 1 minute (small bounds).

### Step 3: Run Bug-Family Hunting (After Trace Collection)

After traces are collected (harness-generation phase), run each hunt config:

```bash
# Run all hunts
for cfg in MC_hunt_*.cfg; do
  echo "Running $cfg"
  tlc -config "$cfg" MC.tla
done
```

Each hunt config is designed to:
- Minimize irrelevant actions (tight bounds)
- Enable only the target family's invariants
- Be solvable in < 5 minutes per config

### Step 4: Trace Validation

After instrumentation and trace collection, validate traces:

```bash
tlc -config Trace.cfg Trace.tla
```

**Important**: Set `JSON` environment variable to trace file path:
```bash
TLC_JSON="../traces/trace.ndjson" tlc -config Trace.cfg Trace.tla
```

---

## Instrumentation and Trace Collection (Phase 2.5)

The `instrumentation-spec.md` document provides detailed mappings for every spec action:

**For each action**:
1. Code location in Go source
2. Trigger point (which line to insert hook)
3. State fields to capture
4. Edge cases and serialization rules

**Next**: Use harness-generation skill to:
1. Insert instrumentation hooks in CometBFT source
2. Collect execution traces (NDJSON format)
3. Validate traces against Trace.tla

---

## Modeling Methodology

This spec follows the **bug-family-driven, code-faithful** approach:

- **Scope** (what to model): Driven by bug families from modeling brief
- **Logic** (how to model): Faithful to implementation code paths
  - Every action follows consensus/state.go control flow
  - Every logic block is annotated with `file:line`
  - Actions are split at atomic boundaries (load → check → CAS)
- **Verification** (confidence): Multi-phase
  - Phase 1: Code analysis (identify bugs) ✓
  - Phase 2: Spec generation (current)
  - Phase 3: Trace validation (real executions)
  - Phase 4: Model checking (exhaustive search)

---

## Known Limitations

1. **Liveness (LivenessUnderGST)**: Commented out in hunt configs
   - Reason: Requires fairness constraints and unbounded runs
   - Workaround: Test liveness via integration tests, not model checking

2. **Message Ordering**: Simplified model (Bag of messages)
   - Assumption: Partial synchrony (post-GST, eventually reliable)
   - Justification: Network layer is orthogonal to consensus safety

3. **Byzantine Threshold**: Static corruption only
   - Assumption: 1/3 validators Byzantine (static, no Sybil)
   - Justification: CometBFT threat model (BFT consensus)

4. **Block Assembly Timing**: Modeled as separate actions
   - Reality: Streaming block parts over time
   - Assumption: All parts eventually arrive; spec checks ordering consistency

---

## Next Steps

1. **Phase 2.5 (Harness Generation)**
   - Instrument source code using `instrumentation-spec.md`
   - Collect execution traces
   - Verify traces are valid JSON

2. **Phase 3 (Trace Validation)**
   - Run Trace.tla against collected traces
   - Identify and fix state mismatches
   - Iterate until all traces validate

3. **Phase 4 (Model Checking)**
   - Run MC_hunt_* configs against spec
   - Identify and analyze counterexamples
   - Categorize as real bugs, spec issues, or false positives

4. **Bug Triage and Reporting**
   - Document findings per bug family
   - Cross-reference with implementation
   - Recommend fixes or verify as "working as designed"

---

## References

- **Modeling Brief**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/cometbft/artifact/cometbft/modeling-brief.md`
- **Source Code**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/cometbft/artifact/cometbft/`
- **Spec Generation Guide**: `/home/ubuntu/Specula/.claude/skills/spec_generation/guide.md`
- **Base Spec Methodology**: `/home/ubuntu/Specula/.claude/skills/spec_generation/references/base-spec-methodology.md`

---

**Generated**: 2026-06-04
**Status**: Phase 2 Complete, Ready for Phase 2.5 (Harness Generation)

