# N2Paxos Modeling Brief (Code-Level, Implementation-Faithful)

## 1. System Overview

- **System**: `artifact/n2paxos/n2paxos` (Go), ~1.3 KLOC in core protocol package (`n2paxos.go`, `defs.go`, `batcher.go`, `trace_helpers.go`).
- **Protocol shape**: single-decree-per-slot Multi-Paxos style with `M2A` (begin ballot / proposal), `M2B` (vote), and local commit transition when a quorum of `M2B` is observed (`artifact/n2paxos/n2paxos/n2paxos.go:214`, `artifact/n2paxos/n2paxos/n2paxos.go:245`, `artifact/n2paxos/n2paxos/n2paxos.go:269`).
- **Implementation-specific structure**: per-slot descriptor objects (`commandDesc`) with asynchronous handlers and callback-style delayed delivery (`afterPayload` + `MsgSet`) instead of a monolithic Paxos state machine (`artifact/n2paxos/n2paxos/n2paxos.go:49`, `artifact/n2paxos/n2paxos/n2paxos.go:386`, `artifact/n2paxos/n2paxos/n2paxos.go:390`).
- **Concurrency model**: one main event loop (`run`), one batching goroutine, one sender goroutine, and optional per-slot goroutines for descriptors (`artifact/n2paxos/n2paxos/n2paxos.go:138`, `artifact/n2paxos/n2paxos/batcher.go:22`, `artifact/n2paxos/replica/sender.go:35`, `artifact/n2paxos/n2paxos/n2paxos.go:356`).
- **Atomicity boundaries**: key steps are split across async channels (`ProposeChan`, `twoAChan`, `twoBChan`, `twosChan`, `deliverChan`) and callback gates (`artifact/n2paxos/n2paxos/n2paxos.go:152`, `artifact/n2paxos/n2paxos/n2paxos.go:283`).
- **Notable deviation from textbook Multi-Paxos**: leader-side execution path can run before `COMMIT` due a special guard in `deliver` (`artifact/n2paxos/n2paxos/n2paxos.go:289`).

## 2. Bug Families

### Family 1: Speculative Execution Coupled to Local Delivery Chain

**Mechanism**: leader delivery can execute slot `s+1` based on local sequencing (`deliverChan`) even when slot `s+1` has not reached quorum commit.

**Evidence**:
- Historical: no fix commits were found for this package (`git log -- n2paxos/n2paxos.go` returns only initial import commit `4783302`).
- Code analysis:
  - Delivery guard allows non-committed execution when `isLeader == true` (`artifact/n2paxos/n2paxos/n2paxos.go:289`).
  - Slot `s` execution enqueues `s+1` for immediate delivery attempt (`artifact/n2paxos/n2paxos/n2paxos.go:308`).
  - Main loop consumes `deliverChan` and triggers `deliver` for the next slot (`artifact/n2paxos/n2paxos/n2paxos.go:153`, `artifact/n2paxos/n2paxos/n2paxos.go:436`).
  - Commit phase is only set inside the quorum callback (`artifact/n2paxos/n2paxos/n2paxos.go:271`).

**Affected code paths**:
- `deliver`, `get2BsHandler`, `handleMsg` (`"deliver"` path), `run` (`deliverChan` case).

**Suggested modeling approach**:
- Variables: `phase[slot]`, `executed[slot]`, `isLeader`, `delivered[slot]`, `votes[slot]`.
- Actions:
  - Split `Deliver` into `SpecDeliverLeader` (phase may be `START`) vs `CommitDeliver` (phase `COMMIT`).
  - Model `NextSlotTrigger` as a separate action that nondeterministically schedules `deliver(slot+1)` after execution.
- Granularity: at least 3-step split: `CollectVote -> MaybeCommit -> DeliverAttempt`.

**Priority**: High  
**Rationale**: directly affects safety/liveness semantics and is an implementation-level behavior absent from canonical Paxos specs.

### Family 2: Client-Visibility Dependency for Execution Progress

**Mechanism**: delivery requires a local `propose` pointer, so replicas that learned a value via `M2A/M2B` but never received client `GPropose` can stall delivery.

**Evidence**:
- Historical: no targeted fixes found in this package history.
- Code analysis:
  - `deliver` returns if `desc.propose == nil` (`artifact/n2paxos/n2paxos/n2paxos.go:301`).
  - Follower path stores proposal only when local `ProposeChan` receives it (`artifact/n2paxos/n2paxos/n2paxos.go:167`).
  - Default client mode sends proposal to one destination when `fast == false` (`artifact/n2paxos/client/client.go:196`, `artifact/n2paxos/client/client.go:203`).
  - Config exemplar has `fast: false` (`artifact/n2paxos/n2paxos.conf:26`).

**Affected code paths**:
- `run` propose branch (non-leader), `deliver`, client `SendProposal` mode choice.

**Suggested modeling approach**:
- Variables: `proposalKnown[replica][slot]`, `chosen[slot]`, `executed[replica][slot]`.
- Actions:
  - Add distinct actions for `ReplicaLearnVia2A` vs `ReplicaReceivesClientProposal`.
  - Gate `Deliver` on both predecessor delivery and `proposalKnown` to reproduce current behavior.
- Granularity: explicit interleaving between message-learn and proposal-learn events.

**Priority**: High  
**Rationale**: can produce persistent non-delivery on some replicas under realistic config/client modes.

### Family 3: Quorum Accounting vs Replica Identity Validation

**Mechanism**: vote aggregation counts by `repId` without explicit bounded-membership validation under the default quorum type.

**Evidence**:
- Historical: no fix commits in package history.
- Code analysis:
  - N2Paxos sets `AQ = NewMajorityOf(r.N)` by default (`artifact/n2paxos/n2paxos/n2paxos.go:117`).
  - `Majority.Contains` always returns true (`artifact/n2paxos/replica/quorum.go:26`).
  - `MsgSet.Add` accepts any `repId` that `q.Contains`, and quorum decision depends on `len(msgs)` (`artifact/n2paxos/replica/mset.go:45`, `artifact/n2paxos/replica/mset.go:75`).

**Affected code paths**:
- `handle2B` -> `MsgSet.Add` -> commit callback.

**Suggested modeling approach**:
- Variables: `votes[slot]` as a set/map keyed by sender id, `membership`.
- Actions:
  - Parameterize environment sender IDs (in-range vs out-of-range).
  - Compare two models: strict-membership counting vs implementation counting.
- Granularity: keep as single `Receive2B` action with sender-id nondeterminism.

**Priority**: Medium  
**Rationale**: high relevance for robustness modeling; severity depends on network/auth assumptions.

### Family 4: Partial Recovery/Epoch Machinery Left Unused in Main Loop

**Mechanism**: phase-1/recovery message types and `RECOVERING` state are defined/registered but never consumed by the N2Paxos run loop.

**Evidence**:
- Historical: package added in one import commit; no follow-up fixes.
- Code analysis:
  - Recovery-related types exist (`M1A`, `M1B`, `MPaxosSync`, `RECOVERING`) (`artifact/n2paxos/n2paxos/defs.go:19`, `artifact/n2paxos/n2paxos/defs.go:60`, `artifact/n2paxos/n2paxos/defs.go:72`).
  - Channels/RPC ids are registered for these messages (`artifact/n2paxos/n2paxos/defs.go:130`, `artifact/n2paxos/n2paxos/defs.go:135`).
  - `run` only handles proposals, `M2A`, `M2B`, and batched `M2s` (`artifact/n2paxos/n2paxos/n2paxos.go:156`, `artifact/n2paxos/n2paxos/n2paxos.go:174`, `artifact/n2paxos/n2paxos/n2paxos.go:182`).

**Affected code paths**:
- `initCs`, `run` receive select, leader/bootstrap initialization.

**Suggested modeling approach**:
- Variables: `status`, `ballot`, `cballot`.
- Actions:
  - Model current implementation as fixed-epoch (no recovery actions).
  - Add explicit “out-of-scope recovery” stub to avoid accidental assumptions.
- Granularity: no need to split further unless recovery is later implemented.

**Priority**: Medium  
**Rationale**: critical for defining model scope and preventing spec drift toward unimplemented recovery semantics.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

1. **Per-slot descriptor lifecycle (`START -> COMMIT -> delivered`)**  
Why: central mechanism for all four families (`artifact/n2paxos/n2paxos/n2paxos.go:53`, `artifact/n2paxos/n2paxos/n2paxos.go:271`, `artifact/n2paxos/n2paxos/n2paxos.go:305`).  
How: represent each slot as a record with `cmd`, `cmdId`, `phase`, `votes`, `proposalKnown`, `delivered`.

2. **Asynchronous message batching (`M2s`)**  
Why: ordering/visibility differs from individual `M2A`/`M2B` delivery (`artifact/n2paxos/n2paxos/batcher.go:28`, `artifact/n2paxos/n2paxos/batcher.go:55`, `artifact/n2paxos/n2paxos/n2paxos.go:183`).  
How: model both individual and batched receive actions.

3. **Leader speculative delivery path**  
Why: implementation-specific and safety-relevant (Family 1).  
How: separate `DeliverEligible` predicate from `Committed`; include leader exception branch.

4. **Client dissemination mode as an environment parameter** (`fast` single-target vs all-target)  
Why: directly impacts `proposalKnown` and delivery liveness (Family 2).  
How: environment action decides whether proposal is visible at one replica or all replicas.

5. **Quorum identity assumptions**  
Why: commit condition currently based on cardinality of observed sender IDs (Family 3).  
How: include switchable assumption `StrictMembership` for comparative checking.

### 3.2 Do Not Model (with rationale)

1. **Wire encoding/marshal caches in `defs.go`**  
Why: byte-level serialization correctness is better covered by tests/fuzzing, not protocol model checking (`artifact/n2paxos/n2paxos/defs.go:143`, `artifact/n2paxos/n2paxos/defs.go:636`).

2. **Low-level sender lock choreography and transport timing internals**  
Why: these are implementation/runtime concerns; model as nondeterministic message delay/reordering instead (`artifact/n2paxos/replica/sender.go:149`, `artifact/n2paxos/replica/replica.go:459`).

3. **`trace_helpers` formatting details**  
Why: telemetry naming is not protocol state transition logic (`artifact/n2paxos/n2paxos/trace_helpers.go:55`).

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| SpeculativeDelivery | `phase`, `executed`, `delivered`, `isLeader` | Capture leader pre-commit execution path | Family 1 |
| ProposalVisibility | `proposalKnown[replica][slot]` | Capture need for local proposal object before execution | Family 2 |
| MembershipAwareVotes | `votes[slot]`, `membership`, `strictMembership` | Check robustness of quorum counting assumptions | Family 3 |
| FixedEpochScope | `status`, `ballot`, `cballot`, `recoveryEnabled` | Prevent accidental modeling of unimplemented recovery | Family 4 |
| BatchReceiveInterleavings | `netQueue`, `batchQueue` | Capture `M2s` reorder/coalescing effects | Families 1,2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ChosenUniquePerSlot | Safety | No two different commands are chosen for same slot | Families 1,3 |
| CommitImpliesQuorum | Safety | `phase=COMMIT` requires quorum-count condition in implementation model | Families 1,3 |
| NoExecuteWithoutProposal | Safety | If executed at replica/slot, that replica had `proposalKnown` (matches code) | Family 2 |
| PrefixDelivery | Safety | Delivery at slot `s` implies delivery at `s-1` | Families 1,2 |
| NonLeaderNeedsCommitToDeliver | Safety | Non-leader cannot execute while `phase!=COMMIT` | Family 1 |
| EventualDeliveryUnderBroadcastClients | Liveness | With fair network + broadcast proposals, committed slots eventually deliver | Family 2 |
| RecoveryMessagesNoEffect | Safety | `M1A/M1B/Sync` events do not change modeled state in current scope | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Leader executes slot before commit due `deliverChan` trigger | Violates `ExecuteOnlyAfterCommit` (if strict invariant used) | Family 1 |
| MC-2 | Single-target client dissemination leaves some replicas unable to deliver | Violates liveness `EventualDeliveryUnderBroadcastClients` when broadcast disabled | Family 2 |
| MC-3 | Out-of-range sender IDs can satisfy quorum in non-strict model | Violates strengthened `CommitUsesMembersOnly` invariant | Family 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Data race risk on `routineCount` increment/decrement across goroutines (`artifact/n2paxos/n2paxos/n2paxos.go:357`, `artifact/n2paxos/n2paxos/n2paxos.go:413`) | Run with `-race` under high load and many slots |
| TV-2 | Batcher `Send2AClient/Send2BClient` can drop client-send intent for non-head batched ops (`artifact/n2paxos/n2paxos/batcher.go:47`, `artifact/n2paxos/n2paxos/batcher.go:74`) | Unit test enqueueing mixed client/non-client ops in one batch |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Clarify intended semantics of leader pre-commit execution in docs/comments | Document whether this is speculative optimization or unintended behavior |
| CR-2 | Clarify whether N2Paxos requires `fast=true` clients for correctness/liveness | Add explicit config guard or startup warning |
| CR-3 | Clarify scope of unused recovery structures (`M1A/M1B/Sync`, `RECOVERING`) | Remove dead path or complete recovery implementation |

## 7. Reference Pointers

- Core implementation:
  - `artifact/n2paxos/n2paxos/n2paxos.go`
  - `artifact/n2paxos/n2paxos/batcher.go`
  - `artifact/n2paxos/n2paxos/defs.go`
  - `artifact/n2paxos/n2paxos/trace_helpers.go`
- Supporting primitives used by N2Paxos:
  - `artifact/n2paxos/replica/mset.go`
  - `artifact/n2paxos/replica/quorum.go`
  - `artifact/n2paxos/hook/cond.go`
  - `artifact/n2paxos/replica/sender.go`
  - `artifact/n2paxos/replica/replica.go`
- Client/config behaviors relevant to assumptions:
  - `artifact/n2paxos/client/client.go`
  - `artifact/n2paxos/n2paxos.conf`
- Git archaeology:
  - `artifact/n2paxos` package path history shows only initial import commit `4783302` for `n2paxos/*` files.
