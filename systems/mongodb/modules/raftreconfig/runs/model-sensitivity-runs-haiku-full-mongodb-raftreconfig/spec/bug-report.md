# Bug Confirmation Report

## Bug 1: ConfigVersionMonotonicity Violation

### Classification
- **Source**: Model Checking (TLC found counterexample)
- **Status**: FALSE POSITIVE (spec modeling issue, not a real bug)
- **Severity**: N/A (artifact, not a system bug)

### Description
Model checking found a violation of the `ConfigVersionMonotonicity_MC` invariant where a node downgrades its in-memory configuration version from 1 to 0 after calling `FinishInstall` with `newVersion=0`, while the persisted configuration version remains at 1. This violates the requirement that in-memory config >= persisted config.

### Trigger Scenario
1. Node n1 starts with configVersion[n1]=1, persistedConfigVersion[n1]=1
2. Node n1 initiates reconfiguration with `MCDoReplSetReconfig_Initiate(n1, newVersion=2, newTerm=0)`
   - Precondition check: `newVersion > configVersion[s]` (2 > 1) ✓
   - State changes to "kConfigReconfiguring"
3. Node n1 finishes installation with `MCDoReplSetReconfig_FinishInstall(n1, newVersion=0, newTerm=0)`
   - Sets configVersion[n1] = 0 (downgrade!)
   - persistedConfigVersion[n1] remains = 1
   - Violation: in-memory (0) < persisted (1) ❌

**Counterexample path (from MC_base.out)**:
- State 1: Initial state (all configs at version 1)
- State 2: After Initiate action (state transitions to kConfigReconfiguring)
- State 3: After FinishInstall action (version downgrades, violation detected)

### Code Audit Findings

**MongoDB Implementation** (`replication_coordinator_impl.cpp`):
- `_doReplSetReconfig()` (line 3530): Main reconfiguration function
- `validateOldAndNewConfigsCompatible()` (repl_set_config_checks.cpp:166-180): **Critical check**
  ```cpp
  if (oldConfig.getConfigVersionAndTerm() >= newConfig.getConfigVersionAndTerm()) {
      return Status(ErrorCodes::NewReplicaSetConfigurationIncompatible, 
          "New replica set configuration version and term must be greater than old...");
  }
  ```
- This validation ensures: `newConfigVersion > oldConfigVersion` before installation
- The validation happens BEFORE config is persisted (line 3755 in `_doReplSetReconfig`)
- `_finishReplSetReconfig()` (line 3898): Installs the pre-validated config into memory

**Spec Implementation** (`base.tla`):
- `DoReplSetReconfig_Initiate()` (line 139): Requires `newVersion > configVersion[s]`
- `DoReplSetReconfig_FinishInstall()` (line 204): **Missing version guard**
  ```tla
  DoReplSetReconfig_FinishInstall(s, newVersion, newTerm) ==
    /\ configStateEnum[s] = "kConfigReconfiguring"
    /\ ~pendingConfigWrite[s]
    /\ configVersion' = [configVersion EXCEPT ![s] = newVersion]  \* No check that newVersion >= persistedConfigVersion[s]
    /\ UNCHANGED persistedConfigVersion
  ```

### Developer Intent Investigation

From `repl_set_config_checks.cpp` (lines 172-179), the intent is clear:
- New config version/term **must be strictly greater** than old config version/term
- This is enforced before any state changes or persistence
- The error message explicitly states this is a safety requirement

No evidence of intentional downgrades; the check is a deliberate safety invariant.

### Root Cause

**The spec is incomplete:** `DoReplSetReconfig_FinishInstall` action accepts arbitrary `newVersion` and `newTerm` parameters without validating that they are greater than the persisted configuration state. In the real implementation, this validation happens in `validateOldAndNewConfigsCompatible()` before `_finishReplSetReconfig()` is called, preventing this scenario from ever occurring.

The spec's `Initiate` action requires `newVersion > configVersion[s]`, but this only constraints the **in-memory** version at the time of Initiate. The `FinishInstall` action should require:
```
newVersion > persistedConfigVersion[s]
```
to mirror the real implementation's safety guarantee.

### Spec vs. Implementation Gap

| Aspect | Real MongoDB | TLA+ Spec |
|--------|-------------|-----------|
| Version validation | Done in `validateOldAndNewConfigsCompatible()` before persist | Missing in `FinishInstall` |
| Checked value | Must be `> oldConfig.version` | Not checked |
| When enforced | Before state changes (line 3755) | N/A |
| Can downgrade | NO (invariant error) | YES (spec allows it) |

### Recommendation

**Fix the specification** by adding a precondition to `DoReplSetReconfig_FinishInstall`:

```tla
DoReplSetReconfig_FinishInstall(s, newVersion, newTerm) ==
  /\ configStateEnum[s] = "kConfigReconfiguring"
  /\ ~pendingConfigWrite[s]
  /\ newVersion > persistedConfigVersion[s]        \* ADD THIS LINE
  /\ newTerm >= persistedConfigTerm[s]             \* ADD THIS LINE (or =, depending on semantics)
  /\ ... rest of action
```

This will prevent the counterexample from occurring and ensure the spec correctly models MongoDB's behavior.

### Confidence Level
**HIGH** — The counterexample is a clear artifact of incomplete spec modeling. The real system has an explicit safety check that the spec is missing.
