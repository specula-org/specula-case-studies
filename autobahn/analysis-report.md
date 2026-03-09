# Analysis Report: Autobahn BFT

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits across all branches | 1,172 |
| Total commits on autobahn branch | 336 |
| Bug/fix commits touching *.rs (all branches) | 202 |
| Bug/fix commits on autobahn branch (primary/src/) | 30 |
| GitHub issues read (upstream asonnino/hotstuff) | 31 |
| GitHub PRs read (upstream asonnino/hotstuff) | 51 |
| GitHub issues on neilgiri/autobahn-artifact | 0 |
| TODO/FIXME/HACK annotations found | 101 |
| Core files deeply analyzed | 9 (core.rs, messages.rs, aggregators.rs, committer.rs, proposer.rs, leader.rs, timer.rs, synchronizer.rs, primary.rs) |
| Total core LOC read | ~5,100 |

## Phase 1: Reconnaissance

### Codebase Structure

Total Rust LOC: ~20,300 across 95 files in 8 crates. Core consensus logic in `primary/src/` (~4,500 LOC).

| File | LOC | Role |
|------|-----|------|
| primary/src/core.rs | 2,202 | Protocol engine (select! event loop) |
| primary/src/messages.rs | 1,589 | Message types, verification, digest |
| primary/src/header_waiter.rs | 443 | Sync pending requests |
| primary/src/primary.rs | 348 | Component orchestration |
| primary/src/committer.rs | 307 | Commit ordering |
| primary/src/synchronizer.rs | 305 | Data sync |
| primary/src/proposer.rs | 267 | Header creation |
| primary/src/aggregators.rs | 211 | QC/TC vote aggregation |
| primary/src/timer.rs | 106 | Timer futures |
| primary/src/leader.rs | 48 | Leader election |

### Concurrency Model

- Core: single Tokio task with `tokio::select!` loop — ALL protocol processing serialized
- Proposer: separate Tokio task, receives certs + consensus instances from Core
- Committer: separate Tokio task, receives commit messages from Core
- HeaderWaiter: separate Tokio task, manages sync with retry timers
- No Mutex/RwLock anywhere — all sync via mpsc channels (capacity 1000)
- Shared state: only `consensus_round: Arc<AtomicU64>` (Core ↔ GarbageCollector)

### Protocol Architecture

**Data Dissemination**: Per-validator "lanes" (chains of Headers). Each Header is a "car" carrying batch digests + optional consensus messages. Certificate = f+1 votes on a Header (availability proof).

**Consensus**: 3-phase per slot: Prepare → Confirm → Commit.
- Fast path: 3f+1 PrepareQC skips Confirm, goes directly to Commit
- View change: 2f+1 Timeouts form TC; TC selects winning proposal
- Pipelining: up to k slots open concurrently (default k=4)
- Leader: round-robin by (slot + view) % n

## Phase 2: Bug Archaeology

### Bug Hotspots

| File | Fix Commits |
|------|------------|
| primary/src/core.rs | 68 |
| primary/src/header_waiter.rs | 21 |
| primary/src/messages.rs | 19 |
| sailfish/src/core.rs | 16 |
| primary/src/proposer.rs | 15 |
| primary/src/synchronizer.rs | 12 |
| primary/src/aggregators.rs | 10 |

### Key Historical Bugs

| Commit | Severity | Description |
|--------|----------|-------------|
| `33ab623` | Critical | TC forced adoption — node could ignore TC's winning proposal |
| `65a9fff` | Critical | 2-chain safety rule too permissive — allowed conflicting votes |
| `cea81f4` | High | Inverted boolean in timer check — committed slots triggered timeouts |
| `3baa668` | High | 3 bugs: GC type mismatch, missing prepare vote guard, TC view validation |
| `46b612d` | High | Instance bounding inverted — unlimited open slots |
| `376d7fe` | High | Commit order reversal — push_front vs push_back |
| `f6d1a89` | High | State update after vote send — crash between = double vote |
| `795c3f7` | Medium | Synchronizer race condition — oneshot channel race |
| `1953ece` | Medium | QCMaker completed flag mixed up fast/slow path |
| `d771743` | Medium | Sanitization bypass — stale messages processed |

### Open Upstream Issues (asonnino/hotstuff)

- **#7**: DoS via unbounded vote aggregator memory (OPEN)
- **#15**: `last_voted_round` and `preferred_round` not persisted to storage (OPEN)
- **#44**: Loopback channel spoofing — bypass validation (OPEN)

### Developer Signals (FIXME/TODO)

| Location | Signal |
|----------|--------|
| messages.rs:128,194,246 | FIXME: proposal digest not included in consensus message hash |
| messages.rs:587-590 | TODO: consensus messages not signed in header digest |
| messages.rs:987 | TODO/FIXME: special_valids not part of cert hash |
| messages.rs:1486 | FIXME: should use f+1st smallest view for TC |
| core.rs:259 | WARNING/FIXME: QC maker GC timing unsafe |
| core.rs:1830-1847 | TC broadcast entirely commented out |
| leader.rs:41 | TODO: keys.sort() commented out for testing |

## Phase 3: Deep Analysis Findings

### CRITICAL Severity

| ID | Location | Finding |
|----|----------|---------|
| DA-1 | messages.rs:233-280 | `ConsensusMessage::digest()` excludes proposals. Prepare digest = hash(slot, view, 0u8). Two Prepares with different proposals have the same digest. Equivocation is cryptographically undetectable. |
| DA-2 | messages.rs:1349-1358 | `Timeout::digest()` hashes nothing. All timeouts have the same digest regardless of slot, view, high_qc, high_prop. Timeouts replayable across any context. |
| DA-3 | messages.rs:1405-1411 | `TC::PartialEq` always returns `true`. `TC::verify()` (line 1520) compares against genesis — always matches — returns Ok without checking quorum, signatures, or content. |
| DA-4 | core.rs:1108-1166 | `is_valid()` for Prepare never checks sender == designated leader. Any node can propose Prepare for any (slot, view) and honest nodes vote for it. |

### HIGH Severity

| ID | Location | Finding |
|----|----------|---------|
| DA-5 | messages.rs:1455 | TC `get_winning_proposals()` sets `winning_view = timeout.view` instead of `winning_view = *other_view`. Uses timeout's view (current failed) instead of ConfirmQC's view (past successful). |
| DA-6 | core.rs:1468-1496 | `process_confirm_message()` has no duplicate voting guard. Unlike Prepare (which uses `last_voted_consensus` at line 1448), a node can vote for multiple Confirm messages in the same (slot, view). |
| DA-7 | core.rs:1916-1922 | `handle_tc()` is a near-no-op: no TC verification, no view update, no timer start. Only calls `generate_prepare_from_tc()`. |
| DA-8 | core.rs:1108-1166 | `is_valid()` for Prepare does not check if slot is already committed. Nodes vote on Prepares for committed slots. |
| DA-9 | messages.rs:587-590 | `Header::digest()` excludes `consensus_messages`. Byzantine proposer can embed different consensus payloads in same-digest headers. |
| DA-10 | core.rs:1303-1307 | Consensus instances inserted into `consensus_instances` map before validation. Pollutes state with potentially invalid entries. |
| DA-11 | messages.rs:159 | `panic!("ids don't match")` in `verify_commit()` crashes node on ID mismatch instead of returning false. |
| DA-12 | committer.rs:133 | Intra-slot proposal ordering uses HashMap iteration (non-deterministic). Different replicas may commit same headers in different order. |
| DA-13 | messages.rs:1288-1291 | `QC::PartialEq` always returns `false`. Genesis QC bypass in `QC::verify()` (line 1246) is dead code. |

### MEDIUM Severity

| ID | Location | Finding |
|----|----------|---------|
| DA-14 | core.rs:1517-1588 | No duplicate commit guard — `process_commit_message()` doesn't check `committed_slots.contains_key()` at entry. Can overwrite and re-deliver. |
| DA-15 | core.rs:1450 | `high_proposals` only tracked when `use_fast_path` = true. Without fast path, TC carries no Prepare evidence. |
| DA-16 | aggregators.rs:128,138 | `weight = 0` reset allows QC threshold re-crossing. `get_qc()` callable multiple times. |
| DA-17 | core.rs:1612-1617 | `clean_slot_periods()` retain uses `&&` — may prematurely delete future slot entries. |
| DA-18 | core.rs:1167-1183 | Confirm uses `curr_view <= view` (≤) but Prepare uses `== view` (strict). Asymmetric view checking. |
| DA-19 | proposer.rs:141-145 | `is_special` flag never reset after header creation. All subsequent headers marked special. |
| DA-20 | core.rs:1568 | Commit not stored for retry if proposals missing — relies on loopback which could fail. |

### LOW Severity

| ID | Location | Finding |
|----|----------|---------|
| DA-21 | timer.rs / core.rs:1538 | Timers fire-and-forget (not cancelable). Stale timer fires handled by state check. |
| DA-22 | core.rs:2067-2172 | `tokio::select!` bias: network messages > proposer > loopback > timers. Timers starved under load. |
| DA-23 | core.rs:1511 | `enough_coverage()` panics if key missing from proposals HashMap. |
| DA-24 | messages.rs:1271-1278 | `QC::digest()` hashes nothing (constant output). Not used operationally. |
| DA-25 | messages.rs:1514-1516 | `TC::validate_winning_proposal()` and `determine_winning_proposal()` are no-ops. |
| DA-26 | aggregators.rs:189-191 | TCMaker doesn't check all timeouts are for same (slot, view). TC fields from last timeout. |

## Findings Classification

| Category | Count | IDs |
|----------|-------|-----|
| Critical (safety violation) | 4 | DA-1, DA-2, DA-3, DA-4 |
| High (correctness risk) | 9 | DA-5 through DA-13 |
| Medium (potential issue) | 7 | DA-14 through DA-20 |
| Low (robustness) | 7 | DA-21 through DA-26 + DA-11 (code quality) |
| **Total** | **26** | |

## False Positive Exclusions

| Candidate | Why Excluded |
|-----------|-------------|
| leader.rs:41 keys.sort() commented out | BTreeMap already returns sorted keys — safe but fragile. Noted as C5 in modeling brief. |
| consensus/src/lib.rs (Bullshark consensus) | Not used in Autobahn deployment (commented out in main.rs). |
| sailfish/ module issues | Sailfish is a comparison implementation, not the Autobahn protocol. Its bugs don't affect Autobahn. |
| worker/ batch processing | Below consensus abstraction. No protocol safety impact. |
