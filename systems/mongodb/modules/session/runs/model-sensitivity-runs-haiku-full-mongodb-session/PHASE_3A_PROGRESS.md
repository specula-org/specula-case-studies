# Phase 3A: Trace Validation - Progress Report

## Objective
Validate TLA+ specification against 5 collected execution traces from the MongoDB session catalog system.

## Inputs
- Spec files: `base.tla`, `Trace.tla`, `Trace.cfg`
- Traces: 5 NDJSON traces (scenario_1.ndjson through scenario_5.ndjson)
  - scenario_1: 2 events (CheckOut/Release)
  - scenario_2: 5 events (CheckOut/Kill/Release sequence)
  - scenario_3: 5 events (parent-child session lifecycle with reap)
  - scenario_4: 7 events (concurrent multi-session operations)
  - scenario_5: 7 events (concurrent operations with kill handling)

## Completed Work

### 1. Syntax Validation & Fixes
✅ **Fixed Trace.tla**
- Removed invalid `SPECIFICATION` keyword that belongs only in .cfg files
- Removed `INVARIANTS` and `PROPERTIES` keywords from module body
- Added proper `TraceSpec` operator definition

✅ **Fixed base.tla**
- Fixed indentation issues in 10 `UNCHANGED` clauses (reformatted multi-line to single-line)
- Fixed `IF-THEN-ELSE` structure with nested `LET-IN` (removed extra `/\` before `LET`)
- Simplified `GetAllDescendants` helper to avoid recursive definition issue
- Fixed operator precedence in `JobsEventuallyComplete` with leads-to operator

✅ **Fixed Trace.cfg**
- Corrected config file format to match TLC standards
- Defined all required constants: SessionIds, MaxReapCount, MaxRefreshCount, TraceLog
- Set up INVARIANTS and PROPERTIES sections

### 2. Current Status
**Syntax Status**: ✅ Valid TLA+ syntax
- SANY2 parser confirms no syntax errors in Trace.tla and base.tla
- Semantic warnings about unused operators (AllDesc, IOEnv, JsonDeserialize) - these are not used in trace paths

**Trace Validation Status**: ⏸️ Pending
- All 5 traces are ready for validation
- Trace validation tool integration issue: Config file format incompatibility with trace validation tool
- The tool expects a specific configuration format that differs from standard TLC config syntax

## Remaining Issues

### Configuration Parsing Error
The trace validation tool is rejecting the Trace.cfg configuration with:
- Error: "TLC found an error in the configuration file at line X"
- "It was expecting a keyword, but did not find it"

This appears to be a tool-specific limitation or incompatibility. The config file format that works for MC.cfg (standard TLC model checking) doesn't work with the trace validation tool.

**Possible solutions:**
1. Check if the trace validation tool has different config requirements
2. Investigate if the tool auto-generates config files
3. Use a different configuration approach

## Next Steps

1. **Investigate trace validation tool config format**
   - Check tool documentation for specific config requirements
   - Look for examples of successful trace validation configs

2. **Alternative approach: Direct TLC invocation**
   - If tool config doesn't work, consider using TLC directly with trace validation mode
   - May need to preprocess NDJSON traces to TLA+ format

3. **Validate traces once config issue is resolved**
   - Run `run_trace_validation` on each of the 5 traces
   - Debug any mismatches using `run_trace_debugging`
   - Fix spec as needed
   - Re-validate with `run_trace_validation_parallel`

## Files Modified
- `/spec/Trace.tla` - spec structure fixes
- `/spec/base.tla` - syntax and formatting fixes  
- `/spec/Trace.cfg` - configuration setup

## Status Summary
- ✅ Syntax validation: PASSED
- ⏸️ Trace validation: BLOCKED on tool configuration
- 📊 Traces: 5/5 ready, 0/5 validated
- 🎯 Phase completion: ~30% (syntax fixes done, validation blocked on tool integration)
