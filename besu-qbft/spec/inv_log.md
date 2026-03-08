# Besu QBFT — Invariant Checking Log

Records model checking results and counterexample analysis for the besu QBFT specification.

---

## Model Checking Configuration

**Spec**: `MC.tla` (extends `base.tla`)
**Config**: `MC.cfg` / `MC_med.cfg`
**Servers**: 4 (s1, s2, s3, s4) with round-robin proposer
**No symmetry reduction** (proposer function breaks server symmetry)

### Constraint Limits (proven tractable for BFS)

| Parameter | Small (MC_small) | Medium (MC_med/MC) | Large (MC_sim) |
|-----------|-----|--------|-------|
| MaxRoundLimit | 1 | 2 | 3 |
| MaxRoundExpiryLimit | 2 | 3 | 6 |
| CrashLimit | 1 | 1 | 1 |
| LoseLimit | 1 | 1 | 2 |
| BlockTimerLimit | 4 | 4 | 5 |
| MaxMsgBufferLimit | 6 | 6 | 12 |

---

## Checked Properties

### Safety Invariants (from base.tla)

| Invariant | Description | Result |
|-----------|-------------|--------|
| **Agreement** | No two honest nodes commit different blocks at same height | PASS |
| **Validity** | Committed block was proposed by legitimate proposer | PASS |
| **PreparedBlockIntegrity** | Block hash matches content+round+proposer after re-proposal | PASS |
| **CommitLatchConsistency** | Committed+imported implies blockchain height updated | PASS |
| **CommittedMonotonic** | Committed implies proposedBlock is not Nil | PASS |

### Structural Invariants (from MC.tla)

| Invariant | Description | Result |
|-----------|-------------|--------|
| **RoundBoundInv** | Round is Nil or bounded natural [0, MaxRoundLimit+1] | PASS |
| **ImportImpliesHeightInv** | Imported block implies blockchain height >= current height | PASS |
| **CommittedImpliesProposalInv** | Committed implies proposedBlock exists | PASS |

### Temporal Properties (from MC.tla)

| Property | Description | Result |
|----------|-------------|--------|
| **MonotonicRoundProp** | Round never decreases within a height (except crash) | PASS |
| **MonotonicBlockchainHeightProp** | Blockchain height never decreases | PASS |

---

## Model Checking Runs

### Run #1 — Small BFS (MaxRound=1, no round changes)
- **Date**: 2026-02-27
- **Mode**: BFS, 24 workers
- **States generated**: 26,830,495
- **Distinct states**: 6,081,000
- **Search depth**: 33
- **Time**: 1 min 15s
- **Result**: No error found
- **Coverage**: Basic proposal flow, commit, crash/recovery, message loss, new chain head

### Run #2 — Simulation (MaxRound=3, full feature coverage)
- **Date**: 2026-02-27
- **Mode**: Simulation, 24 workers, depth 40
- **States checked**: 240,178,667
- **Traces generated**: 1,005,206
- **Mean trace length**: 9 (sd=30)
- **Time**: ~10 min (killed after convergence, no violations)
- **Result**: No invariant violations found
- **Coverage**: Round changes, re-proposals, crash/recovery, message loss, all interleaving families

### Run #3 — Medium BFS (MaxRound=2, round change coverage)
- **Date**: 2026-02-27
- **Mode**: BFS, 24 workers
- **States generated**: 227,205,940
- **Distinct states**: 51,673,162
- **Search depth**: 38
- **Time**: 10 min 41s
- **Result**: No error found
- **Fingerprint collision probability**: 1.0E-4 (acceptable)
- **Coverage**: Full round change protocol including:
  - Round 0 proposal + prepare + commit flow
  - Round expiry and round change messaging (2f+1 and f+1 paths)
  - Re-proposal with hash reconstruction (Family 1)
  - Timer/import race conditions (Family 2)
  - Crash/recovery with state loss
  - Message loss and stale message dropping
  - Block import and height advancement

---

## Counterexample Analysis

No counterexamples found for core safety invariants. All 8 invariants and 2 temporal properties hold across:
- 51.7M exhaustively explored states (BFS, MaxRound=2)
- 6.08M exhaustively explored states (BFS, MaxRound=1)
- 240M+ simulation-checked states (MaxRound=3, 1M+ random traces)

---

## Bug Hunting Phase (2026-02-28)

### Run #4 — RoundChangeSafety + PhaseConsistency (MC-3 target)
- **Date**: 2026-02-27
- **Config**: MC_hunt_rc.cfg (adds RoundChangeSafety, PhaseConsistency to baseline)
- **Mode**: BFS, 24 workers
- **States**: 51.7M distinct, depth 38
- **Time**: 10m49s
- **Result**: No error found. RoundChangeSafety and PhaseConsistency both PASS.

### Run #5 — MC-1 NoConsensusAfterImport (PeerSync detector)
- **Date**: 2026-02-28
- **Config**: MC_bughunt_mc1.cfg (PeerSync action + NoConsensusAfterImport invariant)
- **Mode**: BFS, 24 workers
- **States**: 3 (stopped at first violation)
- **Time**: <1s
- **Result**: **NoConsensusAfterImport VIOLATED**
- **Trace**: Init → PeerSync(s1) → BlockTimerExpiry(s1)
- **Classification**: Implementation race condition confirmed. Block timer lacks blockchain-head guard.

### Run #6 — MC-1 Safety Check (Agreement with PeerSync)
- **Date**: 2026-02-28
- **Config**: MC_bughunt_mc1_safety.cfg (PeerSync, safety invariants only)
- **Mode**: BFS, 24 workers (killed at disk full) + Simulation
- **BFS States**: 114.9M distinct (incomplete due to disk, no violations in 726M generated)
- **Sim States**: 345M checked, 5.5M traces
- **Result**: No safety violation. Agreement holds even with PeerSync.
- **Conclusion**: MC-1 race is wasted-work issue, not safety bug.

### Run #7 — MC-6 Broken Comparator
- **Date**: 2026-02-28
- **Config**: MC_bughunt_mc6.cfg (BestPrepared overridden with wrong selection)
- **Mode**: BFS, 12 workers
- **States**: 51.7M distinct, depth 38
- **Time**: 17m57s
- **Result**: No error found. Agreement holds with broken comparator.
- **Conclusion**: Comparator bug in RoundChangeArtifacts.java:72-85 is benign for safety.

### Run #8 — MC-5 CommittedStuckDetector
- **Date**: 2026-02-28
- **Config**: MC_hunt_mc5.cfg (CommittedStuckDetector invariant, simulation)
- **Mode**: Simulation, 8 workers, depth 60
- **States**: 1K states, 9 traces
- **Time**: <1s
- **Result**: **CommittedStuckDetector VIOLATED**
- **Trace**: 22 states — s3 commits but import fails, becomes stuck.
- **Classification**: Liveness concern. Implementation allows round-change (spec is too restrictive).

---

## Key Findings

1. **No safety violations detected**: Agreement, Validity, and PreparedBlockIntegrity all hold
   across all checked configurations including PeerSync and broken comparator extensions.
   This provides high confidence that the QBFT protocol preserves safety under crash
   failures, message loss, round changes, peer sync, and even comparator bugs.

2. **Family 1 (hash reconstruction) is safe**: PreparedBlockIntegrity confirms that
   `BlockHash(content, round, proposer)` correctly preserves block identity through
   re-proposals across rounds with different proposers.

3. **Family 2 (timer/import races)**: Block timer expiry lacks the blockchain-head guard
   that round expiry has (MC-1 confirmed). This causes wasted work but NOT safety violations.

4. **Family 3 (round change data structures)**: RoundChangeSafety PASS confirms the dual
   data structure (roundSummary put vs roundChangeCache putIfAbsent) is safe.

5. **Family 5 (commit latch)**: CommitLatchConsistency is safe, but the committed-stuck
   state is reachable (MC-5 liveness concern). The spec models this too conservatively.

6. **Family 1 comparator (MC-6)**: The broken comparator in RoundChangeArtifacts.java is
   benign for safety due to quorum intersection preventing conflicting commits.

7. **State space tractability**: With MaxRound=2 and MsgBuffer=6, exhaustive BFS completes in
   ~11 minutes on 24 cores. PeerSync adds ~2x state space. Larger configs require simulation.
