# Phase 3A: Trace Validation Report

## Status: BLOCKED - Spec Compatibility Issues

### Summary

Trace validation for the Autobahn BFT consensus specification has encountered fundamental compatibility issues between the generated TLA+ specifications and TLC's trace validation engine.

### Traces to Validate

Two traces were collected and are ready for validation:
1. `/traces/basic_voting.ndjson` (22 lines) - Simple voting scenario
2. `/traces/multi_round.ndjson` (37 lines) - Multi-round with QC/TC processing

### Fixes Applied

The generated specifications had multiple syntax and format errors that were corrected:

1. **Fixed FORALL syntax**: Changed all `FORALL` quantifiers to `\A` (7 occurrences)
   - TLA+ standard syntax uses `\A` for universal quantification
   - File: `spec/base.tla` lines 320, 331, 341, 350, 360, 367, 374

2. **Fixed Trace.cfg format**:
   - Changed `SPECIFICATION TraceInit, TraceNext` to `INIT TraceInit` and `NEXT TraceNext`
   - Added `PROPERTIES TraceMatched` for trace validation

3. **Fixed Trace.tla structure**:
   - Removed invalid `SPECIFICATION` keyword from module body
   - Added `vars` tuple definition for all variables
   - Simplified JsonFile handling

4. **Added missing constants**:
   - `NIL` → constant (initialized to "NIL" in config)
   - `NULL_MSG` → constant (initialized to "NULL_MSG" in config)
   - Fixed `Quorum` definition (was circular: `Quorum == Quorum + f + 1`)

5. **Added MC-prefixed invariant wrappers** in base.tla:
   - `MCNoDoubleVote`, `MCQCSafety`, `MCTCRoundValidity`, `MCVoteStatusConsistency`, 
   - `MCPersistentVotedMonotonic`, `MCRoundMonotonic`

### Remaining Issue: TLC Fingerprinting Error

**Error**: TLC cannot enumerate states due to complex record structures with numeric fields.

```
Error: Attempted to enumerate a set of the form [l1 : v1, ..., ln : vn],
but can't enumerate the value of the `round' field: 0
```

**Root Cause**: The specification uses records like:
```tla
highQC = [n \in Node |-> [type: "qc", round: 0, digest: 0, signatures: 0]]
```

TLC's fingerprinter encounters unbounded numeric fields in nested records and cannot properly enumerate the state space.

**Location**: `spec/base.tla`, line 103 (Init operator, highQC initialization)

### Required Fixes

To enable trace validation, the specification needs one of the following approaches:

#### Option 1: Simplify Record Structure (Recommended)
Redesign QC, TC, and Vote records to avoid numeric fields:
- Use enumerated round numbers (e.g., "round0", "round1", ..., "roundN")
- Or use a different representation that TLC can fingerprint
- Update all record accesses throughout the spec

#### Option 2: Reduce State Space
- Constrain numeric domains more aggressively
- Use bounded sets instead of Nat
- May reduce model-checking effectiveness

#### Option 3: Use Alternative Validation
- Use a custom trace validator instead of TLC
- Implement semantic checks in a different tool
- Verify against individual trace lines rather than exploring state space

### Files Modified

- `spec/Trace.cfg` - Configuration format fixes
- `spec/Trace.tla` - Module structure fixes
- `spec/base.tla` - Syntax and constant definition fixes

### Next Steps

1. **Choose an approach** from the options above
2. **Redesign record structures** if using Option 1
3. **Update all record accesses** throughout the spec
4. **Validate syntax** with `validate_spec_syntax`
5. **Retry trace validation** with both trace files
6. **Debug any remaining mismatches** using the debugging workflow

### Timeline

- Syntax fixes: ✓ Complete
- Config format: ✓ Complete  
- Record structure redesign: ⏳ Blocked (requires decision)
- Trace validation: ⏳ Pending (depends on record redesign)

