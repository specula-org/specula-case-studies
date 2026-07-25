# Phase 3B: Model Checking Bug Report
## Autobahn BFT Consensus System

**Run Date**: 2026-06-04  
**System**: Autobahn (Narwhal DAG + HotStuff 3-phase)  
**Spec Files**: MC.tla, base.tla  
**Config Files**: MC.cfg, MC_hunt_family*.cfg  

---

## Executive Summary

Phase 3B model checking was conducted with TLC to verify the Autobahn BFT consensus protocol specification. The verification workflow encountered **spec compatibility issues** that prevented successful state space exploration. These issues were identified and partially corrected, but deeper testing revealed TLC internal state representation challenges.

**Status**: INCOMPLETE - Spec configuration issues require resolution  
**Violations Found**: 0 (incomplete run)  
**False Positives**: 0 (incomplete run)  

---

## Issues Identified and Resolved

### Issue 1: Configuration Syntax Error (CRITICAL - FIXED)
- **File**: MC.cfg, MC_hunt_family*.cfg
- **Problem**: Invalid `SPECIFICATION MCInit, MCNext` syntax
- **Root Cause**: TLA+ config files require `INIT` and `NEXT` declarations separately, not comma-separated
- **Fix**: Changed to:
  ```
  INIT MCInit
  NEXT MCNext
  ```
- **Status**: FIXED ✓

### Issue 2: Undefined Constants (CRITICAL - FIXED)
- **File**: MC.cfg, MC_hunt_family*.cfg
- **Problem**: TLC reported "NULL_MSG and NIL are not assigned a value"
- **Root Cause**: Constants declared in spec but not assigned in config
- **Fix**: Added to all config files:
  ```
  CONSTANT NIL = NIL
  CONSTANT NULL_MSG = NULL_MSG
  ```
- **Status**: FIXED ✓

### Issue 3: TLA+ Syntax - Universal Quantification (CRITICAL - FIXED)
- **File**: MC.tla
- **Problem**: Used `FORALL` instead of TLA+ standard `\A`
- **Root Cause**: Spec used non-standard quantification syntax
- **Example Error**: "Was expecting '====' or more Module body, Encountered 'n' at line 125"
- **Fix**: Replaced all instances: `FORALL n \in Node` → `\A n \in Node`
- **Status**: FIXED ✓

### Issue 4: Duplicate Invariant Definitions (MAJOR - FIXED)
- **Files**: MC.tla and base.tla
- **Problem**: Same invariants (MCNoDoubleVote, MCVoteStatusConsistency, etc.) defined in both modules
- **Error**: "Operator MCNoDoubleVote already defined or declared at line 381"
- **Fix**: Removed duplicate definitions from MC.tla; kept single definitions in base.tla
- **Status**: FIXED ✓

### Issue 5: Incomplete Action Variable Specifications (MAJOR - FIXED)
- **File**: MC.tla, fault injection actions
- **Problem**: Actions like `MCAddTimeoutToTC` modified counter but didn't specify what happens to other counters
- **Error**: "Successor state is not completely specified by action MCAddTimeoutToTC... The following variables are not defined: crashCounter, lossCounter, proposeCounter"
- **Fix**: Added `UNCHANGED` clauses to all fault injection actions:
  ```tla
  MCAddTimeoutToTC(...) ==
      /\ timeoutCounter < 5
      /\ AddTimeoutToTC(...)
      /\ timeoutCounter' = timeoutCounter + 1
      /\ UNCHANGED <<crashCounter, lossCounter, proposeCounter>>
  ```
- **Status**: FIXED ✓

### Issue 6: QC/TC Record Type Mismatch (MAJOR - FIXED)
- **File**: base.tla, Init operator and CheckVoteSafety action
- **Problem**: 
  - highQC initialized as string "QC_INIT" but accessed as record with `.round` field
  - Error: "Attempted to select field 'round' from a non-record value 'QC_INIT'"
- **Fix**: Changed initialization:
  ```tla
  highQC = [n \in Node |-> [round |-> 0, data |-> NIL]]
  ```
- **Status**: FIXED ✓

### Issue 7: Negative Number Syntax (SYNTAX - FIXED)
- **File**: base.tla
- **Problem**: Used `-1` for initial QC round, which TLA+ interprets as prefix operator
- **Error**: "Could not find declaration or definition of symbol '-'"
- **Fix**: Used `0` instead as a valid initialization value
- **Status**: FIXED ✓

### Issue 8: Symmetry Function Domain Requirement (MAJOR - DISABLED)
- **File**: MC.cfg
- **Problem**: TLC symmetry reduction requires model values as domain/range, but used Node = 1..NumNodes (range)
- **Error**: "Symmetry function must have model values as domain and range"
- **Fix**: Disabled symmetry reduction in all config files (can be re-enabled with model values)
  ```
  (* SYMMETRY Symmetry *)
  ```
- **Status**: DISABLED ✓

### Issue 9: TLC Internal State Fingerprint Error (BLOCKING)
- **File**: MC.tla / base.tla
- **Problem**: After multiple fixes, TLC reports "Failed to recover the initial state from its fingerprint"
- **Root Cause**: TLC internal state representation issue, possibly related to:
  - Record structures in message set (`msgs` containing complex record types)
  - Large state space with tuple arrays
  - Hash consistency in TLC fingerprinting
- **Symptoms**:
  - Appears after exploring ~5-6 states
  - Occurs when GenerateProposal adds messages with record structure `[round: 0, qcRound: 0, type: "proposal", leader: 4]`
  - Persists across minimal test cases (NumNodes=3, MaxRound=2)
- **Status**: UNRESOLVED - Requires further investigation

---

## Model Checking Attempts

### Run 1: MC_base.out (Full Config)
- **NumNodes**: 4, **MaxRound**: 4, **MaxView**: 3
- **Invariants**: MCNoDoubleVote, MCVoteStatusConsistency, MCPersistentVotedMonotonic, MCRoundMonotonic
- **Result**: TLC fingerprint error after 6 seconds
- **States Explored**: ~5-6 states before error

### Run 2: MC_test_minimal.out (Minimal Config)
- **NumNodes**: 3, **MaxRound**: 2, **MaxView**: 2
- **Invariants**: MCNoDoubleVote, MCVoteStatusConsistency, MCPersistentVotedMonotonic, MCRoundMonotonic
- **Result**: TLC fingerprint error after 2 seconds
- **States Explored**: ~5-6 states before error

---

## Recommended Actions

### Short-term (Critical Path)
1. **Investigate TLC Fingerprinting**
   - Test with TLC version compatibility
   - Try alternative message representation (simpler records or sequences)
   - Check if issue is specific to record-in-set combinations

2. **Simplify Message Representation**
   - Replace complex record messages with simpler structure
   - Consider using message IDs + separate data store
   - Example: Instead of `msgs` as set of records, use message queue with indices

3. **Disable Non-Essential Actions**
   - Reduce to minimal Next relation (just CheckVoteSafety + PersistVoteRound)
   - Add back actions incrementally to isolate the problematic action

### Medium-term
1. **Enable Proper Symmetry Reduction**
   - Define Node as model values {n1, n2, n3, n4} instead of 1..NumNodes
   - Reduce state space significantly

2. **Run Hunting Configs**
   - Once basic model checking works, activate hunt configs for specific bug families
   - Focus on Family 1 (vote safety), Family 3 (TC handling)

3. **Counterexample Analysis**
   - Once violations are found, use get_tlc_summary, get_tlc_state tools
   - Cross-reference against implementation in artifact/autobahn/

---

## Conclusion

Phase 3B encountered significant **spec configuration issues** that have been systematically resolved. The spec now parses correctly and initiates model checking, but hits a TLC-internal state representation issue preventing full convergence.

**All identified bugs are in the spec/config, not the implementation being modeled.**

Next steps require either:
1. Deeper investigation of TLC state representation
2. Redesign of spec to use simpler state structure
3. Consultation with TLC documentation on record-in-set limitations

**No real implementation bugs found yet** - insufficient state space coverage.

---

## Phase 4: Bug Confirmation

**Status**: COMPLETE - No implementation bugs to confirm

**Finding**: Phase 3B model checking did not discover any violations or bugs in the Autobahn implementation. All issues identified during that phase were TLA+ specification and configuration problems (Issues 1-9), not implementation bugs.

**Implementation Audit**: Code in `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/autobahn/artifact/autobahn` was not examined for bug confirmation because no counterexamples or violation traces were produced by model checking.

**Conclusion**: With no implementation bugs identified by model checking, Phase 4 bug confirmation is not required. The verification workflow would need either:
- Successful completion of Phase 3B model checking with actual counterexamples to analyze
- Or a separate source of bug hypotheses (issues, PRs, production incidents) to investigate

**Next Steps**: Return to Phase 3B and resolve the TLC fingerprinting issue to enable full state space exploration and potentially discover protocol violations.

