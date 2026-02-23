# EPaxos Modeling Brief: Implementation vs Invariants

## 1. System Overview

- **System**: EPaxos implementation in Go (`artifact/epaxos/epaxos`), core protocol/execution logic concentrated in `epaxos.go` and `exec.go`.
- **Spec target**: Invariants in `invariants/invariants.md:1` through `invariants/invariants.md:9` (nontriviality, stability, consistency, execution consistency, execution linearizability).
- **Protocol shape**: PreAccept fast path, Accept slow path, Commit broadcast, plus explicit recovery (`Prepare`/`TryPreAccept`) (`artifact/epaxos/epaxos/epaxos.go:803`, `artifact/epaxos/epaxos/epaxos.go:1006`, `artifact/epaxos/epaxos/epaxos.go:1104`, `artifact/epaxos/epaxos/epaxos.go:1216`, `artifact/epaxos/epaxos/epaxos.go:1375`).
- **Concurrency model**: Single event-loop goroutine for protocol message handling (`artifact/epaxos/epaxos/epaxos.go:303`) and a separate execution goroutine (`artifact/epaxos/epaxos/epaxos.go:385`), sharing replica state.
- **Notable deviation noted in code comments**: “TLA spec is wrong” and additional recovery/metadata behaviors (`artifact/epaxos/epaxos/epaxos.go:31` to `artifact/epaxos/epaxos/epaxos.go:38`), so direct mismatch risk is expected.

## 2. Bug Families

### Family 1: Recovery Can Introduce Non-Client Commands

**Mechanism**: Recovery fallback path can synthesize and commit `NOOP` without a client proposal.

**Evidence**:
- **Code analysis**:
  - Recovery subcases 5/6 call `startPhase1` with `state.NOOP()` when no command is known (`artifact/epaxos/epaxos/epaxos.go:1367` to `artifact/epaxos/epaxos/epaxos.go:1372`).
  - `startPhase1` creates a normal instance and enters PreAccept/Accept/Commit flow (`artifact/epaxos/epaxos/epaxos.go:773` to `artifact/epaxos/epaxos/epaxos.go:801`).
  - Invariant states all committed commands must come from a client (`invariants/invariants.md:1`).

**Affected code paths**: `handlePrepareReply -> startPhase1 -> bcastPreAccept -> ... -> bcastCommit`.

**Suggested modeling approach**:
- **Variables**: Track `origin[iid] ∈ {client, recovery_noop, recovery_reproposal}`.
- **Actions**: Split recovery fallback into explicit “recover-with-noop” action.
- **Granularity**: Keep commit as separate step from recovery decision to expose origin at commit time.

**Priority**: High  
**Rationale**: Directly targets stated nontriviality invariant; currently likely violated unless spec explicitly exempts NOOP.

### Family 2: Instance Slot Confusion Can Corrupt Per-Instance Command Identity

**Mechanism**: PreAccept handler writes command into a different row (`LeaderId`) rather than target instance row (`Replica`).

**Evidence**:
- **Code analysis**:
  - In `handlePreAccept`, when `inst.Status >= ACCEPTED && inst.Cmds == nil`, code writes `r.InstanceSpace[preAccept.LeaderId][preAccept.Instance].Cmds = preAccept.Command` (`artifact/epaxos/epaxos/epaxos.go:829` to `artifact/epaxos/epaxos/epaxos.go:833`).
  - The active instance is indexed by `preAccept.Replica` earlier in the same function (`artifact/epaxos/epaxos/epaxos.go:804`).
  - Invariant requires no two replicas commit different commands for same instance (`invariants/invariants.md:5`).

**Affected code paths**: `handlePreAccept`, downstream `handlePrepareReply`/`handleCommit` for affected slots.

**Suggested modeling approach**:
- **Variables**: Explicitly model `inst[replica][instance].cmd` and require message target index matches write index.
- **Actions**: Add a fault-injection branch for “misindexed command write” in PreAccept handling.
- **Granularity**: Model this as a local state-transition bug (single action mutation), not network nondeterminism.

**Priority**: High  
**Rationale**: Concrete wrong-index write can induce cross-instance contamination and consistency failure.

### Family 3: Recovery Classification Diverges from Stated Corrected Spec

**Mechanism**: Recovery subcase logic and TryPreAccept conflict reporting are internally inconsistent.

**Evidence**:
- **Code analysis**:
  - Subcase 3 and subcase 4 branch conditions are identical (`artifact/epaxos/epaxos/epaxos.go:1325` and `artifact/epaxos/epaxos/epaxos.go:1327`), making subcase 4 unreachable.
  - `handleTryPreAccept` initializes `confStatus := NONE` and never updates it from conflicting instance (`artifact/epaxos/epaxos/epaxos.go:1391` to `artifact/epaxos/epaxos/epaxos.go:1408`).
  - `handleTryPreAcceptReply` uses `ConflictStatus >= ACCEPTED` to decide `tpaAccepted` (`artifact/epaxos/epaxos/epaxos.go:1511`), but current replies cannot carry that information.

**Affected code paths**: `handlePrepareReply`, `handleTryPreAccept`, `handleTryPreAcceptReply`.

**Suggested modeling approach**:
- **Variables**: Add `recoverySubcase`, `conflictStatusSeen`.
- **Actions**: Represent recovery case selection and TryPreAccept reply processing as separate actions.
- **Granularity**: Include both intended and implemented branch variants to compare invariant preservation.

**Priority**: High  
**Rationale**: Recovery is where safety regressions often surface; these defects can alter chosen recovery phase under contention.

### Family 4: Accept-Phase State Recording Is Incomplete

**Mechanism**: Accept handler persists ballots/deps/seq but does not set local status to `ACCEPTED`.

**Evidence**:
- **Code analysis**:
  - In `handleAccept`, fields are updated (`Deps`, `Seq`, `bal`, `vbal`) but `inst.Status` is not set to `ACCEPTED` in the success branch (`artifact/epaxos/epaxos/epaxos.go:1027` to `artifact/epaxos/epaxos/epaxos.go:1032`).
  - Recovery logic relies on statuses (`NONE`, `PREACCEPTED`, `ACCEPTED`, `COMMITTED`) to pick subcases (`artifact/epaxos/epaxos/epaxos.go:1311` to `artifact/epaxos/epaxos/epaxos.go:1336`).

**Affected code paths**: `handleAccept`, `handlePrepare`, `handlePrepareReply`.

**Suggested modeling approach**:
- **Variables**: Separate `acceptedMetadata` from `status` to model mismatch explicitly.
- **Actions**: Accept-receive action that can either update full state (intended) or partial state (implemented).
- **Granularity**: One-step local transition bug with recovery-observable consequences.

**Priority**: Medium  
**Rationale**: Likely impacts recovery correctness and may lead to inconsistent reconstruction after failures.

### Family 5: Durable Metadata Encoding Overwrites `bal` With `vbal`

**Mechanism**: Metadata serialization writes both `bal` and `vbal` to the same byte range.

**Evidence**:
- **Code analysis**:
  - `recordInstanceMetadata` writes `inst.bal` to `b[0:4]`, then immediately writes `inst.vbal` to `b[0:4]` again (`artifact/epaxos/epaxos/epaxos.go:205` to `artifact/epaxos/epaxos/epaxos.go:206`).
  - Recovery behavior depends on ballot fields and persisted status/deps (`artifact/epaxos/epaxos/epaxos.go:1187` to `artifact/epaxos/epaxos/epaxos.go:1205`).

**Affected code paths**: `recordInstanceMetadata`, crash/restart recovery reconstruction.

**Suggested modeling approach**:
- **Variables**: Persistent store abstraction `stable[iid]`.
- **Actions**: Add crash/restart action where loaded metadata can reflect overwritten ballot information.
- **Granularity**: Coarse-grained crash fault model is sufficient.

**Priority**: Medium  
**Rationale**: Primarily crash-path inconsistency risk, but can cascade into safety via incorrect recovery ballots.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Recovery-origin tagging for committed commands**  
Why: Family 1; directly tied to nontriviality (`invariants/invariants.md:1`).  
How: Add per-instance origin label and assert commit origin constraints.

- **Per-instance command identity with index discipline**  
Why: Family 2; potential consistency violation (`invariants/invariants.md:5`).  
How: Make command assignment action explicit on `(replica,instance)` pair; inject misindexed write transition.

- **Recovery decision lattice and TryPreAccept signaling**  
Why: Family 3; branch-selection defects could alter safety-relevant behavior.  
How: Model subcase selection and conflict-status propagation as first-class state.

- **Accept metadata/status consistency**  
Why: Family 4; partial accept state may mislead later prepares/recovery.  
How: Split accept receive into `set_metadata` and `set_status` components and allow buggy interleaving.

- **Crash/restart persistence abstraction**  
Why: Family 5; overwritten ballot encoding can perturb post-crash safety.  
How: Add nondeterministic restart from persisted metadata snapshot.

### 3.2 Do Not Model (with rationale)

- **Tracing/statistics paths** (`traceInstanceEvent`, `Stats`)  
Why: Observability only; not protocol semantics (`artifact/epaxos/epaxos/trace_helpers.go:62`).

- **Beacon ordering/adaptation heuristics**  
Why: Peer ordering optimization; not directly tied to target invariants (`artifact/epaxos/epaxos/epaxos.go:254` to `artifact/epaxos/epaxos/epaxos.go:272`).

- **Batch-size accounting metrics**  
Why: Throughput instrumentation, not safety behavior (`artifact/epaxos/epaxos/epaxos.go:745` to `artifact/epaxos/epaxos/epaxos.go:749`).

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| CommitOrigin | `origin[iid]` | Distinguish client vs recovery-introduced commands at commit | Family 1 |
| IndexedCommandStore | `cmd[iid]`, `writeTarget` | Catch misindexed command writes | Family 2 |
| RecoveryCaseMachine | `recoverySubcase`, `conflictStatusSeen`, `tpaState` | Model implemented recovery branch behavior | Family 3 |
| AcceptStateSplit | `acceptMeta[iid]`, `status[iid]` | Capture partial accept updates | Family 4 |
| StableStoreCrashModel | `stable[iid]`, `crashed` | Model persistence corruption across restart | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NontrivialityNoSyntheticCommit | Safety | Committed non-NOOP command must originate from client proposal | Family 1 |
| SlotConsistency | Safety | For each `(replica,instance)`, committed command payload is identical across replicas | Family 2 |
| CommitImmutability | Safety | Once committed in a slot, command/seq/deps never change | Families 2, 4 |
| RecoveryRefinementSafety | Safety | Recovery branch choices preserve committed outcome equivalence | Family 3 |
| ExecOrderInterference | Safety | Interfering committed commands execute in same order on all replicas | Families 3, 4 |
| ClientOrderLinearizabilityLite | Safety | If client serializes conflicting ops, execute order respects that serialization | Families 1, 3 |
| CrashRecoveryBallotMonotonicity | Safety | Restart does not decrease effective ballot used for future decisions | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Recovery commits `NOOP` without client proposal | NontrivialityNoSyntheticCommit | Family 1 |
| MC-2 | Misindexed write causes different command for same slot | SlotConsistency, CommitImmutability | Family 2 |
| MC-3 | Unreachable subcase 4 + missing conflict status changes recovery path | RecoveryRefinementSafety, ExecOrderInterference | Family 3 |
| MC-4 | Accept metadata without ACCEPTED status affects later prepare decisions | RecoveryRefinementSafety, CommitImmutability | Family 4 |
| MC-5 | Corrupted persisted ballot perturbs post-crash recovery | CrashRecoveryBallotMonotonicity | Family 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `handlePreAccept` wrong index write (`LeaderId` vs `Replica`) | Unit test with crafted PreAccept where `LeaderId != Replica`, assert only target slot mutates |
| TV-2 | `handleAccept` missing status update | Unit test asserting status transitions to `ACCEPTED` on valid Accept |
| TV-3 | Metadata encoding overlap | Round-trip encode/decode test for `bal`/`vbal` persistence fields |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Clarify whether nontriviality intentionally excludes protocol NOOPs | Align `invariants/invariants.md` wording with intended semantics |
| CR-2 | Confirm corrected recovery subcase conditions from EPaxos paper/TLA baseline | Review and reconcile `handlePrepareReply` branching logic |

## 7. Reference Pointers

- Invariants source: `invariants/invariants.md:1`
- Main protocol logic: `artifact/epaxos/epaxos/epaxos.go:742`
- Recovery logic: `artifact/epaxos/epaxos/epaxos.go:1169`
- Execution ordering logic: `artifact/epaxos/epaxos/exec.go:46`
- Trace/event utilities (excluded from modeling): `artifact/epaxos/epaxos/trace_helpers.go:62`
