# Modeling Brief v2: Autobahn BFT — Commit Ordering Extension

Incremental modeling brief for the second iteration of the Specula pipeline.
Builds on the original `modeling-brief.md` (Families 1–5).

## 1. Motivation

The Autobahn author confirmed Bugs DA-1 and DA-5 and challenged us to
discover a known bug: proposals should use BTreeMap instead of HashMap,
otherwise replicas derive different total orders for committed headers.

We identified this issue in Phase 1 code analysis (DA-12 in analysis-report.md)
but classified it as test-verifiable rather than model-checkable.
This brief describes how to extend the spec to catch it via MC.

## 2. New Bug Family

### Family 6: Commit Ordering Determinism (HIGH)

**Mechanism**: When a slot is committed, the Committer processes proposals
by iterating over `HashMap<PublicKey, Proposal>`. Each (PublicKey, Proposal)
represents one validator's "lane" — a chain of headers to deliver to the
application layer. The iteration order determines the **total order** of
committed headers sent to the application. HashMap iteration is
non-deterministic, so different replicas produce different total orders.

**Evidence**:
- Code: `committer.rs:132-133`:
  ```rust
  ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
      for (pk, proposal) in proposals {  // HashMap — non-deterministic!
  ```
- Each iteration body (lines 134-164) fetches all headers for that lane
  and sends them to `tx_output` **in the order lanes are visited**.
- The proposals type is `HashMap<PublicKey, Proposal>` (messages.rs:101,107,113).
- Author confirmed this is a known bug: "proposals should be a BTreeMap
  instead of a HashMap (otherwise replicas may derive different total orders)."

**Affected code paths**:
- `committer.rs:117-175` (`process_commit_message`) — commit execution
- `messages.rs:96-115` (ConsensusMessage enum) — proposals field type
- `messages.rs:210-231` (`proposal_digest`) — iterates HashMap for hashing
- `messages.rs:1436-1499` (`get_winning_proposals`) — clones HashMap

**Impact**: State Machine Replication requires all replicas to execute
operations in the same total order. If replicas commit the same SET of
headers but in different ORDER, application state diverges. This is an
agreement violation at the application layer, even though consensus layer
"agrees" on the proposal set.

### Subsection: Latent Bug in proposal_digest (Compounds with DA-1 Fix)

If the DA-1 fix is applied (uncomment `proposal_digest()` calls in
messages.rs:128,194,246), the `proposal_digest()` function itself iterates
over `HashMap<PublicKey, Proposal>` (messages.rs:214,219,225):
```rust
for (_, proposal) in proposals {
    hasher.update(proposal.header_digest.0);
}
```
This means that **even after fixing DA-1**, the digest computation would
be non-deterministic across replicas. Different replicas would compute
different digests for the same proposal set, causing QC verification to
fail and potentially breaking liveness.

**Fix for both**: Replace `HashMap<PublicKey, Proposal>` with
`BTreeMap<PublicKey, Proposal>` in the `ConsensusMessage` enum. BTreeMap
iterates in key order (deterministic).

## 3. Modeling Approach

### 3.1 Key Insight

The current spec uses atomic values (`Values = {v1, v2}`) for proposals.
To catch the ordering bug, we need to model proposals as a **set of
per-lane entries** and track the **execution order** separately.

The ordering bug is independent of Byzantine behavior — it occurs even
with all-honest configurations because HashMap iteration is inherently
non-deterministic.

### 3.2 New Variables

```
\* Each proposal is a set of lane entries (one per proposing server)
\* e.g., {s1, s2, s3} means "proposals from lanes s1, s2, s3"
\* The VALUE committed is the set; the ORDER is chosen independently.

\* Execution order chosen by each server when committing
VARIABLE commitOrder     \* [Server -> [Slot -> Seq(Server) \cup {<<>>}]]
                         \* e.g., commitOrder[s1][1] = <<s3, s1, s2>>
                         \* Empty sequence <<>> means not yet committed
```

### 3.3 Modified Actions

**ReceiveCommit** — when an honest server commits, it chooses an
arbitrary permutation of the proposal lanes:

```
ReceiveCommitOrdered(s, sl, v) ==
    /\ s \in Honest
    /\ \E m \in messages :
        /\ m.mtype = CommitMsg
        /\ m.mslot = sl
        /\ m.mview = v
        /\ committed' = [committed EXCEPT ![s][sl] = m.mvalue]
        \* Non-deterministically choose an execution order
        \* This models HashMap's non-deterministic iteration
        /\ \E perm \in Permutations(m.mvalue) :
             commitOrder' = [commitOrder EXCEPT ![s][sl] = perm]
    /\ UNCHANGED <<serverVars, evidenceVars, voteVars,
                   timeoutVars, proposalVars, messages>>
```

Here, `m.mvalue` is a SET of lane identifiers (e.g., `{s1, s2, s3}`),
and `Permutations(S)` generates all possible orderings (sequences) of
elements in S.

### 3.4 Proposal Value Representation

Change the `Values` constant from abstract atoms to sets of lanes:

```
\* Old: Values = {v1, v2}  (atomic)
\* New: Values = nonempty subsets of Server (lane sets)
\*       e.g., {{s1,s2,s3}, {s1,s2,s3,s4}} represents two possible
\*       proposal configurations
```

For minimal model checking, we can use:
- `Values = {SUBSET Honest}` — proposals are sets of honest server lanes
- Or more simply: fix one canonical proposal value (a set) and focus
  purely on the ordering bug

### 3.5 New Invariant

```
\* ExecutionOrderAgreement: All honest servers that commit the same
\* slot must produce the same execution order.
ExecutionOrderAgreement ==
    \A s1, s2 \in Honest : \A sl \in Slot :
        (commitOrder[s1][sl] /= <<>> /\ commitOrder[s2][sl] /= <<>>)
        => commitOrder[s1][sl] = commitOrder[s2][sl]
```

This invariant WILL be violated because different servers independently
choose arbitrary permutations of the HashMap iteration order.

### 3.6 State Space Estimate

With 4 servers and 3 honest lanes per proposal:
- 3! = 6 possible orderings per server per slot
- 3 honest servers × 6 orderings = very small additional state space
- Total state space increase: ~6× per committed state (manageable)

For the hunting config, we can even use an all-honest configuration
(Byzantine = {}) since this bug doesn't require Byzantine behavior.

## 4. Hunting Configuration

```
\* MC_hunt_ordering.cfg
SPECIFICATION MCSpec

CONSTANTS
    Server = {s1, s2, s3, s4}
    MaxSlot = 1
    MaxView = 1
    K = 1
    Nil = Nil
    Values = ...          \* See 3.4
    Byzantine = {}        \* No Byzantine needed!

    PrepareMsg = "PrepareMsg"
    ConfirmMsg = "ConfirmMsg"
    CommitMsg = "CommitMsg"
    TimeoutMsg = "TimeoutMsg"

    MaxByzantineLimit = 0
    MaxTimeoutLimit = 0
    MaxLoseLimit = 0
    MaxMsgBufferLimit = 8

SYMMETRY HonestSymmetry
VIEW ModelView
CONSTRAINT MsgBufferConstraint

INVARIANTS
    ExecutionOrderAgreement
```

Since Byzantine = {} and no timeouts/message loss, the state space
should be very small. TLC should find the violation quickly.

## 5. QCMaker Analysis (Family 4 Update)

Deep analysis of `aggregators.rs:84-163` reveals the QCMaker state
machine is **mostly correct** for the intended fast/slow path flow:

1. `try_fast=true`: votes go through `check_fast_qc()`
2. At 2f+1: returns `(first=true, None)` — starts timer
3. At 3f+1: returns `(true, Some(QC))` — fast path success
4. Timer fires: `get_qc()` returns slow QC if `completed_fast=false`

**No independent safety violation found.** The `weight=0` reset after QC
formation is intentional (prevents duplicate QC creation). The `first`
flag correctly ensures only one timer start.

**Minor issue**: `QC { id: vote.0, ... }` (line 129) uses the LAST
vote's digest as QC id. With Bug DA-1 (digest doesn't include proposals),
all votes have the same digest, so this is benign. But if DA-1 were
fixed, this could pick the wrong vote's digest. Low priority — address
when DA-1 is fixed.

**Recommendation**: Do NOT model QCMaker state machine in detail. The
return on investment is low — no safety bug, and the modeling complexity
is high. Keep the current abstract vote-counting model.

## 6. Summary of Spec Changes Needed

| Change | Purpose | Complexity |
|--------|---------|------------|
| Add `commitOrder` variable | Track per-server execution order | Low |
| Modify `ReceiveCommit` | Non-deterministic permutation choice | Low |
| Change `Values` representation | Model proposals as lane sets | Medium |
| Add `ExecutionOrderAgreement` invariant | Detect ordering divergence | Low |
| New hunting config (`MC_hunt_ordering.cfg`) | Target the bug | Low |

**Do NOT change**:
- QCMaker modeling (no new bug found)
- Existing invariants (AgreementSafety etc. still valid)
- Existing actions (SendPrepare, SendConfirm, etc.)

## 7. Implementation Strategy

Two options for the spec extension:

**Option A: Minimal — add ordering on top of existing spec**
- Keep existing `committed` variable (atomic value)
- Add `commitOrder` as an ADDITIONAL variable
- Modify only `ReceiveCommit` action
- Pro: minimal diff, all existing configs still work
- Con: `Values` still atomic, ordering is "bolted on"

**Option B: Richer — model proposals as lane sets**
- Change `Values` to `SUBSET Server` (proposal = set of lanes)
- `committed[s][sl]` becomes a set of lanes
- `commitOrder[s][sl]` is a sequence of those lanes
- Pro: cleaner model, catches more variants of the bug
- Con: larger diff, need to update all existing actions

**Recommendation**: Option A for speed. We can always refine later.
The key insight is that the ordering bug is in `ReceiveCommit`, not in
the voting/QC formation logic. So we only need to extend the commit path.
