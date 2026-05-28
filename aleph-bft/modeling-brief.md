# Modeling Brief: Cardinal-Cryptography/AlephBFT

## 1. System Overview

- **System**: AlephBFT — Rust BFT DAG consensus library used by the Aleph Zero blockchain for finalization.
- **Language**: Rust, ~10 kLOC core consensus logic (`consensus/src/`), plus ~1 kLOC RMC and ~1 kLOC crypto.
- **System category**: **Category A (Distributed / Message-Passing)**, **Byzantine threat model** (`n=3f+1` members, adversary controls scheduling and ≤ f members). Network is **fully asynchronous** — this is the distinctive trait vs. partial-synchronous DAG BFTs like Mysticeti/Bullshark.
- **Protocol**: AlephBFT / QuickAleph (Gągol et al., AFT'19, §A1). DAG of `Unit`s, deterministic head election + monotone extension rule, fork-alert subprotocol with reliable multicast (RMC) to recover from equivocation.
- **Key architectural choices that deviate from the paper**:
  - QuickAleph (alerts + RMC) instead of paper's main Reliable-Broadcast-for-every-unit (`docs/src/differences.md` §1).
  - **Deterministic** common-vote / head ordering — paper §2.4 uses random common-vote for Asynchronous Liveness; implementation sacrifices that property for simplicity (safety remains).
  - **Control hashes** (compressed parent representation): a `NodeMap<Round>` plus a `combined_hash` over `(parent_hash, parent_round)`. Recovery via on-demand `Request::ParentsOf`.
  - **Ancient parents** (PRs #506/#514/#528, 2024): a unit at round r can include parents at any round r' < r; election still uses only `direct_parents` (r-1). Liveness improvement only.
  - **Alerter + backup chain** (PRs #197/#311): backup persists ALL units in the local ch-DAG; broadcast strictly gated on backup save; on restart, the initial unit collection compares backup vs peers' view to detect "different node with same keys".
- **Concurrency model**: Single-threaded synchronous core (`Consensus`), surrounded by independent async tasks (`creator`, `backup saver`, `alerter service`, `network hub`, `initial unit collection`) coordinated via `futures::mpsc` unbounded channels and a hierarchical `Terminator`. The consensus core is fully synchronous after the 2024 refactors (PRs #431, #436, #558).
- **Threshold**: `consensus_threshold = (n*2)/3 + 1 = 2f+1 = n-f` (`crypto/src/node.rs:87-89`). Used uniformly for parent counts, voting decisions, and initial-collection completeness.

## 2. Bug Families

### Family 1: Alerter accept-then-verify split — bogus-commitment griefing (MEDIUM)

**Mechanism**: `verify_commitment` runs only at `alert_confirmed` time, *after* the RMC has multi-signed the alert hash. `verify_fork` is the only check at `on_network_alert`. A Byzantine alert sender can produce a valid `proof` (the forker really did equivocate) but a deliberately invalid `legit_units` commitment. Honest nodes sign the alert hash for RMC because the proof checks out; commitment validation only happens later.

**Evidence**:
- Code analysis: `consensus/src/alerts/handler.rs:204-207` — duplicate alerts insert into `known_alerts` unconditionally; no size cap.
- Code analysis: `consensus/src/alerts/handler.rs:267-275` — `alert_confirmed` inserts `(sender, forker)` into `known_rmcs` at line 272 **before** calling `verify_commitment` at line 273. If verification fails, the dedup slot is still occupied.
- Code analysis: `consensus/src/alerts/service.rs:158-165` — `handle_multisigned` logs and drops on `alert_confirmed` error; no propagation to consensus.
- Historical: PR #65 (`c97e253`) — earlier alerter had different but related verification gaps.
- Historical: PR #102 (`60102f2`, TOB-ALEPH-004) — forker unit count not decremented after fork detection; a related "alerter state drift" bug from the audit.

**Affected code paths**:
- `Handler::on_network_alert` (`alerts/handler.rs:190-221`)
- `Handler::verify_commitment` (`alerts/handler.rs:113-130`)
- `Handler::verify_fork` (`alerts/handler.rs:132-158`)
- `Handler::alert_confirmed` (`alerts/handler.rs:263-275`)
- `Service::handle_multisigned` (`alerts/service.rs:158-165`)

**Suggested modeling approach**:
- Variables: `knownAlerts[Node -> SUBSET AlertHash]`, `knownRmcs[Node -> [(Sender, Forker) -> AlertHash]]`, `knownForkersAlerter[Node -> [Forker -> Proof]]`.
- Split alert processing into two TLA+ actions:
  1. `ReceiveAlert(n, alert)` — verifies `proof` only; populates `knownAlerts`/`knownForkers`; may start RMC.
  2. `ConfirmAlert(n, alertHash)` — fires when multisig is complete; populates `knownRmcs`; only on `verify_commitment` success, emits the `legit_units` notification to the DAG.
- Add a Byzantine action `ByzantineSendAlertWithBadCommitment(byzNode, forker)` that constructs an alert with valid proof but invalid legit_units (e.g., units of differing rounds).
- Invariant: if at least one honest detector exists for any genuinely-forked author, eventually every honest node has the legit_units list for that author (liveness, not safety).
- Invariant: `verify_commitment` failure for one alert sender does not block other senders' valid alerts (different (sender, forker) keys).

**Priority**: Medium
**Rationale**: Real protocol-level mechanism gap that hasn't been audited externally beyond the 2021 ToB review. The honest-detector recovery path is non-obvious and merits formal verification. Bug class is **a check ordering inconsistency between receive-time and confirm-time** — exactly the kind of bug TLA+ can systematically exercise.

---

### Family 2: Local fork-detection divergence — per-honest-node DAG variance (MEDIUM)

**Mechanism**: Each honest node maintains a *local* "first-seen variant wins" canonical store. Two honest nodes can pick different canonical variants of the same forker's round-r unit (because the forker delivers selectively). Each raises its own alert with its own `legit_units` commitment. Both alerts go through RMC. Both honest nodes' DAGs end up containing *both* commitments' units, but with different *canonical* selections. The extender consumes from the local store, so the candidate set at round r can differ momentarily across honest nodes.

**Evidence**:
- Code analysis: `consensus/src/units/store.rs:70-85` — `maybe_set_canonical` is first-write-wins.
- Code analysis: `consensus/src/dag/validation.rs:88-106` — `mark_forker` collects `canonical_units(forker)` (the local first-seen set) into the local alert's commitment.
- Code analysis: `consensus/src/dag/validation.rs:99-102` — comment explicitly acknowledges: "in principle we can have 'canonical' processing units that are forks of store canonical units ... This is somewhat confusing, but not a problem for any theoretical guarantees."
- Code analysis: `consensus/src/dag/mod.rs:188-200` — `process_forking_notification` admits all units from all confirmed alerts via `validate_committed` (no uniqueness check on (creator, round)).
- Historical: PR #130 (`e5d0096`) — earlier version of this race actually froze the network ~1/50 in the byzantine test; current synchronous refactor + `parent_hashes` plumbing was the fix.

**Affected code paths**:
- `UnitStore::insert` / `maybe_set_canonical` (`consensus/src/units/store.rs:70-92`)
- `Validator::mark_forker` (`consensus/src/dag/validation.rs:88-106`)
- `Validator::validate_committed` (`consensus/src/dag/validation.rs:151-163`)
- `Dag::process_forking_notification` (`consensus/src/dag/mod.rs:180-204`)
- `Extender::add_unit` (`consensus/src/extension/extender.rs:43-68`) — no retraction
- `RoundElection::for_round` candidate sort (`consensus/src/extension/election.rs:163-171`) — deterministic, hash-sorted

**Suggested modeling approach**:
- Variables: `localDag[Node -> [Coord -> SUBSET Unit]]` (multi-variant), `canonical[Node -> [Coord -> Unit]]` (first-seen per node).
- Distinct actions for "local fork detection" vs "alert-driven fork inclusion":
  - `DetectFork(n, forker, u1, u2)` — n locally observes two variants; updates canonical (first wins); marks forker; emits alert with commitment = current canonical of forker.
  - `ApplyConfirmedAlert(n, alert)` — admits alert's `legit_units` into local DAG without changing canonical.
- Invariant (the load-bearing one): for any honest node n and round r, if `Extender(n)` decides a head at round r, then *all* honest nodes that decide round r decide the same head. Equivalently: the deterministic hash-sorted candidate set restricted to "units descended from quorum of honest parents" is identical across honest nodes.
- Adversary action: Byzantine `forker` sends variant U1 to half the honest nodes and U2 to the other half, then never participates in alerts.

**Priority**: High
**Rationale**: This is the **central safety mechanism** of AlephBFT against equivocation. The implementation's correctness argument relies on a subtle property (deterministic election + ancestry through honest units = unique head). The argument is not formalized anywhere in the repo, and the "different honest detectors commit to different legit_units lists" creates the most concrete scenario where the argument could fail. **The right MC question**: under asynchronous delivery + a forker that selectively delivers variants, can two honest nodes finalize different rounds at any moment? The expected answer is no, but a TLA+ run would either confirm it or surface a concrete counterexample.

---

### Family 3: Restart equivocation chain — backup save before broadcast (MEDIUM)

**Mechanism**: A multi-step persistence/broadcast pipeline must hold the invariant *"no signed unit reaches the wire before it is durable on disk"* across (a) the consensus service → backup saver → consensus service → dissemination flow, and (b) the initial-unit-collection vs backup reconciliation at startup. Both halves are individually correct in the current code, but the chain is long and the dependencies subtle.

**Evidence**:
- Code analysis: `consensus/src/consensus/service.rs:168-186` — `on_unit_reconstructed` sends to saver; `on_unit_backup_saved` is the only place that calls `task_manager.add_unit` (which emits the broadcast envelope, `dissemination/task.rs:379-384`).
- Code analysis: `consensus/src/backup/saver.rs:36-40` — `save_unit` does `write_all + flush` then sends the response back to consensus. **Note**: `flush` is not `fsync` — durability is the embedder's responsibility (Finding F9 in analysis-report).
- Code analysis: `consensus/src/backup/loader.rs:124-138` — `load_backup` computes `next_round = max(round of own units in backup) + 1`.
- Code analysis: `consensus/src/collection/service.rs:202-225` — `starting_round` returns `None` when `round_from_backup < round_from_collection` (refuse to participate; "different node running with same pair of keys"); proceeds from `round_from_backup` otherwise.
- Code analysis: `consensus/src/collection/mod.rs:107-122` — `initial_unit_collection` is feature-gated on `initial_unit_collection`; the fallback skips collection entirely and trusts backup alone.
- Historical: PR #311 (`978f41c`, A0-1720) — flipped save-before-broadcast order and switched from own-units-only to full ch-DAG backup.
- Historical: PRs #195/#197 — the equivocation-guard chain across restart.
- Historical: PR #549 (A0-4569) — made initial unit collection more independent (refactor).

**Affected code paths**:
- `BackupLoader::load_backup` (`consensus/src/backup/loader.rs:124-138`)
- `BackupLoader::verify_units` (`consensus/src/backup/loader.rs:96-122`)
- `BackupSaver::save_unit` (`consensus/src/backup/saver.rs:36-40`)
- `Service::on_unit_reconstructed` / `on_unit_backup_saved` (`consensus/src/consensus/service.rs:168-186`)
- `Handler::on_unit_backup_saved` (`consensus/src/consensus/handler.rs:188-198`)
- `IO::starting_round` (`consensus/src/collection/service.rs:202-225`)
- `IO::run` (`consensus/src/collection/service.rs:252-311`)
- `Collection::on_newest_response` (`consensus/src/collection/service.rs:97-127`)
- `Manager::add_unit` (`consensus/src/dissemination/task.rs:357-385`)

**Suggested modeling approach**:
- Variables: `persistedUnits[Node -> SUBSET Unit]`, `broadcastUnits[Node -> SUBSET Unit]`, `lastSignedRound[Node -> Round]`, `peerNewestUnit[Node -> [Node -> Maybe Unit]]`.
- Split unit creation across multiple atomic transitions:
  1. `Sign(n, round)` — increments `lastSignedRound[n]`; creates an in-memory unit; sends to internal saver queue.
  2. `PersistUnit(n, unit)` — moves unit from in-memory queue to `persistedUnits[n]`.
  3. `BroadcastUnit(n, unit)` — moves unit from `persistedUnits[n]` to `broadcastUnits[n]`; enabled only if `unit ∈ persistedUnits[n]`.
  4. `Crash(n)` — clears in-memory state; preserves `persistedUnits[n]`.
  5. `Restart(n)` — runs `load_backup` (computes `nextRound = max(round) + 1` from `persistedUnits[n]`); runs collection vs peers (returns `round_from_collection = max over peers of (peer.peerNewestUnit[n].round + 1)`).
  6. `RestartStartingRound(n)` — applies the branching: refuse / use backup.
- Invariants:
  - `NoEquivocationAcrossRestart`: for any honest n and round r, `Cardinality({u ∈ broadcastUnits[n] : u.round = r}) <= 1`.
  - `BackupBeforeBroadcast`: `broadcastUnits[n] ⊆ persistedUnits[n]`.
  - `RefuseSafety`: if `round_from_collection > round_from_backup`, the node refuses (no new signatures).
- Adversary actions:
  - `ByzantineFakeNewestResponse(byz, target, round)` — Byzantine peer claims to have seen a round-`R` unit by `target` (signed correctly — but Byzantine can't forge; so this action is restricted to `round <= max round target ever signed`). Tests the trust model of `NewestUnitResponse`.
  - `WithholdResponse(byz, target)` — Byzantine peer refuses to respond to `target`'s initial collection; tests F6 liveness gap.

**Priority**: High
**Rationale**: This is the **second-most-load-bearing safety mechanism** after fork detection. Multiple production-grade BFTs (Diem, Tendermint, others) have had unit-equivocation-on-restart bugs (e.g., cometbft #3089). AlephBFT's chain is more elaborate than most because of the initial-unit-collection branch. The branches and their `None` / `Some(round_from_backup)` outcomes need explicit modeling; reasoning about all 3 cases by hand is error-prone.

---

### Family 4: Deterministic-election ↔ asynchronous-delivery composition (MEDIUM)

**Mechanism**: AlephBFT's safety argument relies on a deterministic common-vote schedule + deterministic candidate ordering (sort by hash) so that all honest nodes elect the same head for the same round given the same DAG. Under asynchrony, two honest nodes see the DAG grow in different orders. The election cannot run until 3 rounds of voters are present; once it runs, it must produce the same outcome at every honest node. The implementation's argument is that monotonicity + threshold ensures this.

**Evidence**:
- Code analysis: `consensus/src/extension/election.rs:9-19` — `common_vote(relative_round)` is purely a function of `relative_round`. Deterministic.
- Code analysis: `consensus/src/extension/election.rs:163-171` — candidates sorted by `Hash::Ord`. Deterministic.
- Code analysis: `consensus/src/extension/election.rs:73-92` — `vote_from_parents` uses `direct_parents` only (post-ancient-parents refactor).
- Code analysis: `consensus/src/extension/extender.rs:43-68` — no retraction; once a unit enters, it stays.
- Historical: PR #65 — the only safety bug found in election was a threshold off-by-one (fixed 2021).
- Historical: PR #506/#528 — ancient parents added; election explicitly uses `direct_parents` (not `parents()`).
- Reference: paper §2.3 (deterministic ordering + FCC lemma) — the implementation's safety argument is the paper's argument, transported to the deterministic-CV setting.

**Affected code paths**:
- `Extender::add_unit` (`consensus/src/extension/extender.rs:43-68`)
- `RoundElection::for_round` / `add_voter` (`consensus/src/extension/election.rs:151-213`)
- `CandidateElection::vote`, `vote_from_parents`, `compute_votes` (`consensus/src/extension/election.rs:64-127`)
- `Units` (`consensus/src/extension/units.rs`)

**Suggested modeling approach**:
- Variables: `dag[Node -> SUBSET ReconstructedUnit]`, `headDecision[Node -> [Round -> Maybe UnitHash]]`.
- Action `DeliverUnit(sender, receiver, unit)` — asynchronous delivery; arbitrary reordering.
- Action `RunElection(n, round)` — guarded by "all round-r candidate units known + at least one round-(r+3) descendant for each"; deterministically computes head.
- Invariant: `AgreementOnHeads`: for any two honest n1, n2 and round r, if both have `headDecision[n][r] != None`, they are equal.
- Invariant: `Monotonicity`: if `headDecision[n][r] = h` at any state, then `headDecision[n][r] = h` at all subsequent states (no rewriting).
- Adversary actions: arbitrary message reordering, Byzantine `forker` raising forks that DO reach the extender via `validate_committed`. Compose with Family 2 to test the joint property.

**Priority**: Medium-High
**Rationale**: This is the foundation of safety. The threshold bug in PR #65 is direct evidence the area is hard to get right. The deterministic-CV variant is a *non-standard* AlephBFT regime (the paper version uses random CV); the safety argument transfers but has not been formally verified for this variant. **Strong candidate for TLA+ verification** — the model is small (one election rule, two thresholds, one sorting predicate) and the property is a clean agreement statement.

---

### Family 5: Async-channel lifecycle (LOW — for TLA+)

**Mechanism**: Independent async tasks (creator, saver, alerter, network hub, consensus service) connected via unbounded mpsc channels. Channels closing in the wrong order, tasks dying independently, or `select!` arms blocking other arms produce cascading failures.

**Evidence**:
- Historical: PR #108 (TOB-ALEPH-009), PR #109 (TOB-ALEPH-007), PR #234 (A0-1057 nested awaits), PR #235 (A0-847 cascade), PR #314 (A0-2846 graceful exit + FusedStream).
- Code analysis: 5+ "crucial channel closed" exit paths in `consensus/service.rs` (lines 83-86, 98-101, 170-172, 180-182, 196-200).
- Code analysis: `Terminator` tree (`consensus/src/terminator.rs`) coordinates shutdown.

**Affected code paths**:
- `Service::run` `select!` (`consensus/src/consensus/service.rs:220-280`)
- `consensus::run_session` `select!` (`consensus/src/consensus/mod.rs:221-251`)
- `Terminator::terminate_sync` (`consensus/src/terminator.rs`)

**Priority**: Low (for TLA+ modeling)
**Rationale**: Better validated by Rust unit tests / Loom. Not a protocol-level property.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Two-phase alert pipeline (receive vs. confirm) | Family 1: `verify_commitment` runs at confirm-time only, not receive-time | Split `Alert` handling into `ReceiveAlert` (verify_fork only) + `ConfirmAlert` (verify_commitment); track per-node `knownRmcs` and `knownAlerts` |
| Per-node DAG state (`canonical` + `allVariants`) | Family 2: each honest node has its own "first-seen wins" canonical map; different honest nodes commit to different `legit_units` | Two NodeMap-indexed variables: `canonicalUnit[n][coord]` (first-seen, mutable in fork-detection) and `dagUnits[n]` (set of all admitted units) |
| Save-then-broadcast split | Family 3: broadcast strictly gated on backup save (PR #311) | Split unit emission into `SignUnit` → `PersistUnit` → `BroadcastUnit`; `Crash` action preserves `persistedUnits`, clears in-memory; `Restart` runs `load_backup` + `Collection.starting_round` |
| Initial unit collection branching | Family 3: 3-branch logic at `collection/service.rs:202-225` is the equivocation guard | `Restart` action computes `roundFromBackup`, `roundFromCollection`; branches into refuse/proceed |
| Asynchronous message delivery | Foundational: AlephBFT's distinguishing trait | Standard message-bag variable; deliver in arbitrary order; no FIFO assumption |
| Deterministic election rule | Family 4: safety relies on it | Pure `Head(r, dag)` function computed by the spec, asserted to agree across honest nodes |
| Byzantine forker | All families: the only Byzantine behavior that exercises the alerter | `ByzantineFork(byz, round, variant1, variant2)` action; selective delivery via the message bag |
| Byzantine alert sender with bad commitment | Family 1: triggers the F1 finding | `ByzantineRaiseBadAlert(byz, forker)` constructs alert with valid proof + invalid `legit_units` |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| RMC scheduler delay schedule | Implementation detail; RMC completion is what matters, not its timing. Model RMC as a black-box action `CompleteRMC(alertHash)` enabled when `>=n-f` honest signatures exist on the alert hash. |
| Dissemination request-response amplification | DoS concern, not safety; explicitly delegated to embedder (`types/src/network.rs:14`). Better verified by Rust tests with mock peers. |
| `AsyncWrite::flush` vs `fsync` | Documentation hazard, not a code defect. **Should be addressed by a docs PR**, not TLA+. |
| `known_alerts` unbounded growth | DoS concern, not safety; bounded by network rate limit in production. |
| Salt entropy in `generate_salt` | Hardening issue; current usage is safe. Worth a PR to switch to a CSPRNG, not worth modeling. |
| Ancient parents detailed mechanics | Liveness feature; safety properties don't change. Model only `direct_parents` for elections. |
| RMC's internal `SignedHash` → `MultisignedHash` state machine | Treat as black-box: RMC produces `Multisigned` once `>=n-f` distinct signatures exist on a hash. The internal state machine is well-tested (`rmc/src/handler.rs`) and orthogonal to AlephBFT safety. |
| Dissemination task scheduling | Local scheduling decision; treat retransmission as nondeterministic message duplication in the bag. |
| Backup file format / SCALE encoding | Codec correctness; not a model-checkable property. |
| Initial unit collection's "delay_passed" liveness gap (F6) | Documented "not quite BFT"; liveness-only; not exploitable into safety. **Worth a maintainer note**, not TLA+. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Two-phase alert lifecycle | `knownAlerts[Node -> SUBSET Alert]`, `knownRmcs[Node -> [(Sender,Forker) -> AlertHash]]`, `knownForkersAlerter[Node -> [Forker -> Proof]]`, `confirmedAlerts[Node -> SUBSET Alert]` | Model verify-on-receive vs verify-on-confirm split | 1 |
| Local fork detection | `canonicalUnit[Node -> [Coord -> Unit]]`, `localForkers[Node -> SUBSET Node]`, `committedUnits[Node -> SUBSET Unit]` | Per-node first-seen variant rule + per-detector commitment | 2 |
| Persistent vs in-memory unit state | `persistedUnits[Node -> SUBSET Unit]`, `inFlightUnits[Node -> SUBSET Unit]`, `broadcastUnits[Node -> SUBSET Unit]`, `lastSignedRound[Node -> Round]` | Save-before-broadcast chain; crash/restart preserves persisted only | 3 |
| Peer newest-unit knowledge | `peerNewestUnit[Node -> [Node -> Maybe Unit]]` | Backs initial unit collection; needed for `starting_round` decision | 3 |
| Deterministic head election | derived function `Head(r, dag) ∈ Maybe UnitHash`; `decided[Node -> [Round -> Maybe UnitHash]]` | Model the consistent-across-honest-nodes election | 4 |
| Asynchronous message bag | `msgs ⊆ Message`; `Deliver(m)` action removes `m` and applies to receiver | Standard async substrate; no FIFO assumption | foundational |
| Byzantine adversary action set | `byzantineForkers ⊆ Server` (CONSTANT), action `ByzantineFork(byz, round, v1, v2)`, action `ByzantineRaiseBadAlert(byz, forker)` | Two distinct Byzantine actions exercising Families 1 and 2 | 1, 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `AgreementOnFinalizedOrder` | Safety | For any two honest n1, n2 and any round r, if both have decided a batch at round r, the batches are equal. | Family 2, 4 |
| `MonotonicityOfOrder` | Safety | `decided[n][r]` never changes once set. | Family 4 |
| `LegitUnitsInvariant` | Safety | For any honest n, any forker f, any round r at which n has a unit `u` from f in its DAG: either f is not yet locally marked as forker at n, or `u ∈ legitUnits` for some confirmed alert against f at n. | Family 2 |
| `NoEquivocationAcrossRestart` | Safety | For any honest n and round r, `Cardinality({u ∈ broadcastUnits[n] : u.round = r}) <= 1`. | Family 3 |
| `BackupBeforeBroadcast` | Safety | `broadcastUnits[n] ⊆ persistedUnits[n]`. | Family 3 |
| `RefuseImpliesGapDetected` | Safety | If `Restart` decides `starting_round = None` for n, then there exists some honest peer p with `peerNewestUnit[p][n].round + 1 > load_backup(n).nextRound`. | Family 3 |
| `AlerterDedupNeverBlocksHonest` | Liveness (eventually) | For any forker f genuinely equivocating, if at least one honest detector exists, eventually every honest node has a valid `legit_units` list for f. | Family 1 |
| `ForkerOnceAlertedRejected` | Safety | After `ForkingNotification::Forker(f)` is delivered to n, any subsequent unit from f arriving via the normal path (not `Units` notification) is rejected by `Validator::validate` as `Uncommitted`. | Family 2 |
| `HeadElectionDeterminism` | Safety (derived) | `Head(r, dag1) = Head(r, dag2)` whenever both heads are defined and `dag1`, `dag2` contain the same r..r+3 units. | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Under arbitrary message reordering + a Byzantine forker that selectively delivers two round-r variants to half-and-half honest groups, can two honest nodes finalize different heads at round r? | `AgreementOnFinalizedOrder` | 2, 4 |
| MC2 | A Byzantine alert sender raises an alert against forker f with valid proof but invalid `legit_units` (units of differing rounds, or units not by f). The honest detector for f independently raises a valid alert. Does every honest node eventually receive a valid `legit_units` list for f? | `AlerterDedupNeverBlocksHonest` (liveness) | 1 |
| MC3 | A node n persists round-R unit but crashes before broadcasting. After restart, the initial unit collection contacts peers. Peers may report different `newest_unit` for n depending on which subset received the unit before crash. Under all delivery orderings, does n choose a `starting_round` that prevents creating a *new* round-R unit with different data? | `NoEquivocationAcrossRestart` | 3 |
| MC4 | Under asynchronous delivery, after a forker emits round-r variants V1, V2 to disjoint honest subsets H1, H2: do all honest nodes' DAGs eventually contain both V1 and V2 (admitted via confirmed alerts from any detector)? Then does `decided[n][r]` converge for all n? | `LegitUnitsInvariant` + `AgreementOnFinalizedOrder` | 1, 2 |
| MC5 | The Byzantine sender of MC2 broadcasts the bad alert, then *waits* until honest nodes' RMC has completed and `known_rmcs` has the bad-hash entry, *then* tries to broadcast a *good* alert for the same forker. Is the good alert handled correctly? (Expected: rejected as `RepeatedAlert` but `known_alerts` updated; other honest detectors' alerts are unaffected.) | Combined Family 1 + 2 | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| T1 | `Manager::trigger_tasks` retransmits `ParentsOf` requests until the unit is reconstructed, even after a Byzantine `add_parents` response with wrong hashes (F5). | Mock dissemination layer that intercepts requests; record retransmissions over time. |
| T2 | `known_alerts` grows unboundedly under repeated Byzantine alert spam (F2). | Loom or simple stress test counting `known_alerts.len()` while feeding crafted distinct alerts. |
| T3 | `BackupSaver::save_unit` durability with non-fsync'd `AsyncWrite` (F9). | Integration test wrapping a controllable async write that drops bytes on simulated power loss. |
| T4 | Initial unit collection liveness gap (F6): single honest peer unreachable + f Byzantine silent → node stalls in Pending forever. | Spawn honest n with one peer "offline" hook; assert it never proceeds. |
| T5 | `generate_salt` entropy: per-process, the salt should not be predictable from process startup time alone (F7). | Statistical test or replace with CSPRNG. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| R1 | F1: `alert_confirmed` populates `known_rmcs` *before* `verify_commitment`. Reorder to populate only after success, or add an explicit "occupied with bad commitment" sentinel so that other valid alerts from a different sender are not blocked. | Submit a PR or discuss with maintainers; minimal patch. |
| R2 | F2: the comment at `validation.rs:99-102` acknowledges the multi-canonical situation. Document the actual invariant explicitly (which is: "each honest node's DAG content can differ in *forker* units, but final extender order agrees"). | Documentation PR. |
| R3 | F9: `AsyncWrite::flush` is not necessarily durable. Document that user-supplied `unit_saver` MUST be backed by an fsync'd persistence layer for the safety argument to hold. | Documentation PR (`docs/src/internals.md`). |
| R4 | F7: `generate_salt` uses non-cryptographic randomness. Even though current usage is safe, harden by switching to `rand::random::<u64>()` (already a dependency). | Trivial PR. |
| R5 | F5: `Reconstruction::add_parents` silently retains the orphan on hash mismatch. Add an explicit `Request::ParentsOf(unit_hash)` re-emit for the second attempt (with a different peer). | Discuss with maintainers; risk of unbounded request loops if naive. |
| R6 | F8 / Family 2: extender lacks retraction. This is by-design but the rationale (honest+ancestry guarantees) should be documented explicitly in `docs/src/internals.md`. | Documentation PR. |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/aleph-bft/.specula-output/analysis-report.md`
- **Key source files** (line ranges of interest):
  - `consensus/src/alerts/handler.rs` (lines 113-275: verification + alert lifecycle)
  - `consensus/src/alerts/service.rs` (lines 108-165: alert-side RMC integration)
  - `consensus/src/dag/validation.rs` (lines 88-163: fork detection + mark_forker)
  - `consensus/src/dag/mod.rs` (lines 180-204: forking notification handling)
  - `consensus/src/units/store.rs` (lines 70-129: canonical-unit semantics)
  - `consensus/src/extension/election.rs` (entire 390 lines: head election rule)
  - `consensus/src/extension/extender.rs` (entire 129 lines: extender + batch emission)
  - `consensus/src/backup/loader.rs` (lines 85-138: load_backup + next_round computation)
  - `consensus/src/backup/saver.rs` (lines 36-75: save_unit + ordering)
  - `consensus/src/collection/service.rs` (lines 97-225: collection + starting_round)
  - `consensus/src/consensus/service.rs` (lines 168-280: orchestration + select! loop)
  - `consensus/src/creation/creator.rs` (lines 9-65: creator state) + `creation/mod.rs:177-199`
  - `crypto/src/node.rs:87-89` (`consensus_threshold`)
- **Relevant GitHub PRs** (all merged on `main`):
  - Alerter / fork handling: #65, #76, #80, #81, #102 (TOB-ALEPH-004), #130, #315, #335, #362
  - Safety threshold + extender: #65, #406, #431, #436, #506, #514, #528
  - Backup / restart: #137, #195, #197, #311, #338, #399, #549, #556
  - Async lifecycle (ToB audit): #108 (TOB-ALEPH-009), #109 (TOB-ALEPH-007), #234, #235, #314
- **Reference paper**: Gągol, Leśniak, Straszak, Świętek — *Aleph: Efficient Atomic Broadcast in Asynchronous Networks with Byzantine Nodes* (AFT'19). https://arxiv.org/abs/1908.05156
- **In-tree protocol docs**: `docs/src/how_alephbft_does_it.md`, `docs/src/internals.md`, `docs/src/differences.md`, `docs/src/reliable_broadcast.md`
- **Related case studies** in `case-studies/`:
  - **`sui/`** (Mysticeti) — partial-synchronous DAG BFT; AlephBFT is the asynchronous-regime sibling. Cross-implementation comparison: equivocation handling patterns should be checked against both; AlephBFT's alerter is a distinct mechanism (no equivalent in Mysticeti, which relies on slot-leader honesty + 2-message wave).
  - Other BFT case studies in the repo for vocabulary alignment.
