# Analysis Report: cometbft/cometbft

## Coverage Statistics

### Phase 1: Reconnaissance
- **Core files analyzed**: 12 files, ~12,800 LOC total
- **Subagents**: 4 parallel (state machine, reactor/msgs, types/voting, state/execution)

### Phase 2: Bug Archaeology
- **GitHub issues collected (CometBFT)**: ~120 unique issues
- **GitHub issues collected (Tendermint)**: ~115 unique issues
- **GitHub PRs collected**: 146 unique consensus-relevant PRs
- **Issues deeply read (full comments)**: 39 issues across 4 parallel subagents
  - CometBFT batch 1: 9 issues (#5204, #1431, #1253, #3340, #3570, #3195, #3091, #2361, #2353)
  - CometBFT batch 2: 10 issues (#674, #1322, #487, #653, #4461, #4114, #1018, #1172, #1230, #2357)
  - Tendermint batch 1: 10 issues (#1745, #1047, #1551, #1496, #3341, #6009, #8739, #5560, #3089, #573)
  - Tendermint batch 2: 10 issues (#200, #3767, #3721, #5816, #4150, #9995, #9498, #3044, #9251, #7020)
- **Issues confirmed as bugs**: 25
- **Issues excluded (false positive / not a bug)**: 8 (#4461 misconfiguration, #1172 expected behavior, #2357 tmkms bug, #6009 test artifact, #9995 stale, #9498 stale, #3767 stale/p2p, #3721 stale/gossip)
- **Issues excluded (design discussion / enhancement)**: 6 (#1551 optimization, #1230 optimization, #9251 question, #7020 enhancement, #200 tracking, #3044 fixed)

### Phase 3: Deep Analysis
- **Subagents**: 5 parallel (state.go, reactor.go, vote_set.go+types, execution.go+evidence, WAL+replay)
- **Findings total**: ~150 individual findings
- **Model-checkable findings**: ~50
- **Test-verifiable findings**: ~35
- **Code-review-only findings**: ~65

---

## Confirmed Bug Inventory

### Critical Severity

| ID | Repo | Issue | Summary | Status | Model-Checkable |
|----|------|-------|---------|--------|----------------|
| B1 | cometbft | #5204 | Proposer VE self-verification skip → consensus deadlock | OPEN | Yes |
| B2 | tendermint | #1745 | Prevotes before proposal prevent termination | Fixed (PR#2540) | Yes |
| B3 | tendermint | #8739 | Chain halt on WAL replay with PBTS timeliness | Unfixed (path identified) | Partially |
| B4 | cometbft | #4114 | Duplicate evidence committed in consecutive blocks | Closed NOT_PLANNED | Partially |
| B5 | cometbft | #3195 | Batch verify with mixed key types → chain halt | Fixed (PR#3196) | No |

### High Severity

| ID | Repo | Issue | Summary | Status | Model-Checkable |
|----|------|-------|---------|--------|----------------|
| B6 | cometbft | #1431 | +2/3 nil precommits wait for timeout instead of advancing | OPEN | Yes |
| B7 | cometbft | #3340 | Catch-up failure with short block times | OPEN | Partially |
| B8 | cometbft | #3570 | VE enabled for nil precommit → remote signer panic | Fixed (PR#3565) | Partially |
| B9 | cometbft | #1253 | Large VE exceeds WAL size limit → panic | OPEN | No |
| B10 | cometbft | #1322 | gossipVotesRoutine nil dereference crash | Fixed (PR#1323) | No |
| B11 | tendermint | #1496 | Round sync very slow for lagging nodes | Partially fixed | Yes |
| B12 | tendermint | #3089 | Crashed validator needs manual priv_validator edit | Partially fixed (PR#3246) | Partially |
| B13 | tendermint | #5560 | Proposer adds already-committed evidence | Fixed (PR#5574) | No |
| B14 | tendermint | #573 | WAL had no checksums/fsync | Fixed (PR#672) | Partially |

### Medium Severity

| ID | Repo | Issue | Summary | Status | Model-Checkable |
|----|------|-------|---------|--------|----------------|
| B15 | cometbft | #2361 | Unverified VE in LastCommit during timeout_commit | Spec fix (PR#2423) | Yes |
| B16 | cometbft | #3091 | Timeout ticker race → wrong timeout info | Fixed (PR#3092) | Partially |
| B17 | cometbft | #1018 | PrepareProposal/ProcessProposal replay inconsistency | Spec fix (PR#1033) | Yes |
| B18 | cometbft | #2353 | Evidence detection unreliable in tests | OPEN | Partially |
| B19 | cometbft | #674 | gossipVotesRoutine data race on ConsensusParams | Fixed (PR#692) | No |
| B20 | cometbft | #653 | Data race when logging consensus.State during shutdown | OPEN | No |
| B21 | tendermint | #1047 | Livelock with Byzantine validator in spec | Mitigated by gossip | Yes |
| B22 | tendermint | #3341 | Single-validator consensus stops without votes | Unfixed | Yes |
| B23 | tendermint | #4150 | Evidence transmitted with wrong Time | Fixed | No |
| B24 | cometbft | #487 | Data race in consensus.State at startup | Fixed (PR#673) | No |
| B25 | tendermint | #1551 | Miss lock/commit on conflicting votes | Unfixed | Partially |

---

## Deep Analysis Findings (New)

### consensus/state.go

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| S1 | Locking protocol has 5 distinct paths in enterPrecommit: nil polka, nil-polka+lock, polka-for-locked, polka-for-proposal, polka-for-unknown | 1459-1578 | model-checkable |
| S2 | addVote prevote handler: unlock if polka for different block at round > LockedRound, update ValidBlock/ValidRound | 2279-2324 | model-checkable |
| S3 | enterPrevoteWait panics if !HasTwoThirdsAny (assertion, not soft check) | 1434 | test-verifiable |
| S4 | TriggeredTimeoutPrecommit prevents re-entry to PrecommitWait, but round-skip path can bypass | 1584, 2372 | model-checkable |
| S5 | sendInternalMessage spawns goroutine on queue full, enabling out-of-order self-message processing | 575 | model-checkable |
| S6 | handleMsg for BlockPartMessage temporarily unlocks/relocks cs.mtx | 919-921 | test-verifiable |
| S7 | VE verification only for votes at current height, not previous height precommits in LastCommit | 2196-2244 | model-checkable |
| S8 | signVote flushes WAL before signing, but signed vote not in WAL until later WriteSync | 2392, 849 | model-checkable |
| S9 | Proposal completeness check `isProposalComplete` requires POL when POLRound >= 0 | 1276-1293 | model-checkable |
| S10 | handleCompleteProposal can trigger enterPrecommit directly if hasTwoThirds already | 2077 | model-checkable |

### consensus/reactor.go

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| R1 | WaitSync gates DataChannel/VoteChannel but not StateChannel; VoteSetMaj23 accesses rs.Votes during sync | 274, 290-296 | model-checkable |
| R2 | Vote tracking reset to nil on round change in ApplyNewRoundStepMessage | 1528-1537 | model-checkable |
| R3 | Votes only gossipped for peer's round (prs.Round), not our round | 935-991 | model-checkable |
| R4 | ProposalPOL overwritten entirely, losing previously tracked HasVote bits | 1589-1591 | model-checkable |
| R5 | VoteSetBitsMessage missing Round >= 0 in ValidateBasic | 1959-1977 | test-verifiable |
| R6 | RemovePeer is a no-op; no cleanup of goroutines or PeerState | 229-239 | code-review-only |
| R7 | broadcastHasVoteMessage not selective; TODO to filter by round | 554-574 | code-review-only |
| R8 | SwitchToConsensus: window between waitSync=false and conS.Start() where messages queue but aren't drained | 140-147 | model-checkable |
| R9 | queryMaj23 re-reads state 4 times per iteration; inconsistent across reads | 710-793 | code-review-only |
| R10 | ApplyVoteSetBitsMessage trusts peer claims when ourVotes is nil | 1611-1618 | model-checkable |

### types/vote_set.go + types/vote.go + types/proposal.go

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| V1 | Quorum = TotalVotingPower*2/3+1 with >= is consistent with > TotalVotingPower*2/3 | vote_set.go:308, 459 | model-checkable |
| V2 | maj23 set only once (first quorum wins); second quorum for different block silently ignored | vote_set.go:316 | model-checkable |
| V3 | HasTwoThirdsAny vs HasTwoThirdsMajority: different semantics drive different state transitions | vote_set.go:431-460 | model-checkable |
| V4 | Conflicting vote replaces entry in voteSet.votes when it matches maj23 block | vote_set.go:273-276 | model-checkable |
| V5 | voteSet.sum counts each validator exactly once, even with conflicting votes | vote_set.go:282 | model-checkable |
| V6 | PeerMaj23 enables conflicting vote storage; bounded by one-claim-per-peer | vote_set.go:287-289 | model-checkable |
| V7 | Proposal accepts Height == 0 but Vote and VoteSet reject it | proposal.go:53, vote.go:283 | test-verifiable |
| V8 | POLRound not validated against Round (POLRound >= Round passes) | proposal.go:59-61 | model-checkable |

### state/execution.go + evidence/

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| E1 | applyBlock has 4 crash injection points; most dangerous crash is after Commit but before SaveState | execution.go:230-331 | model-checkable |
| E2 | Missing crash point between Commit and evpool.Update | execution.go:298-306 | model-checkable |
| E3 | Validator set rotation +2 height delay; asymmetric with params +1 delay | execution.go:646, 671 | model-checkable |
| E4 | Evidence double-commitment protection depends on timely evpool.Update | pool.go:194-232 | model-checkable |
| E5 | Evidence expiration AND logic (both duration and block count) | verify.go:309-317 | model-checkable |
| E6 | Consensus buffer votes added to pending pool without full verification | pool.go:461-538 | test-verifiable |
| E7 | ExtendVote panics instead of returning error | execution.go:359 | code-review-only |
| E8 | ExtendVote request has rich context; VerifyVoteExtension has minimal context | execution.go:346-370 | model-checkable |
| E9 | Proposer address cannot be fully verified (round unknown) | validation.go:98-111 | model-checkable |
| E10 | ApplyVerifiedBlock skips all validation (used in replay) | execution.go:206-210 | code-review-only |

### WAL + Replay

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| W1 | Async WAL writes (peer messages, timeouts) lost on crash; 2s flush interval | state.go:838,869; wal.go:29 | model-checkable |
| W2 | Internal message WAL WriteSync error causes panic | state.go:851-855 | code-review-only |
| W3 | EndHeightMessage written after block save, before ApplyBlock — recovery boundary | state.go:1763-1782 | model-checkable |
| W4 | WAL repair truncates at first corrupt entry | state.go:2637-2671 | model-checkable |
| W5 | Non-corruption WAL errors: node proceeds anyway ("proceeding to start") | state.go:345-347 | model-checkable |
| W6 | Race between privval signing and WAL WriteSync — window where signed vote not in WAL | state.go:2426 vs 849 | model-checkable |
| W7 | WAL overwritten during replay catchup (TODO acknowledged) | wal.go:74-76 | model-checkable |
| W8 | catchupReplay requires previous height's EndHeightMessage | replay.go:118-136 | model-checkable |
| W9 | Replay re-triggers signing; replayMode only suppresses error logging | replay.go:82-85, state.go:1269 | model-checkable |
| W10 | ABCI Handshake has multiple recovery cases depending on app vs store vs state heights | replay.go:416-470 | model-checkable |

---

## Bug Family Mapping

| Bug Family | Historical Bugs | New Code Findings | Total Evidence |
|------------|----------------|-------------------|---------------|
| Family 1: Vote Extension Lifecycle | B1, B8, B9, B15 | S7, E7, E8 | 7 |
| Family 2: Liveness / Round Progression | B2, B6, B7, B11, B16, B21, B22 | S4, S5, S10, R3 | 11 |
| Family 3: Crash Recovery / WAL | B3, B12, B13, B14 | S8, W1-W10 | 14 |
| Family 4: Evidence Handling | B4, B13, B18, B23 | E2, E4, E5, E6 | 8 |
| Family 5: Locking Protocol | B2, B21, B25 | S1, S2, S9, V8 | 7 |
| Family 6: Block Execution Atomicity | — | E1, E3, E9, E10 | 4 |
| Not grouped (impl-level races) | B10, B19, B20, B24 | R5, R6, V7 | 7 |

---

## Key Observations

1. **Vote extensions are the newest and most bug-prone area.** CometBFT added vote extensions (ABCI++) without fully working through all edge cases. The proposer self-verification gap (#5204) is an unfixed critical bug affecting production chains.

2. **Crash recovery has deep complexity.** The interaction between WAL persistence, privval signing state, and ABCI handshake creates a large state space that is difficult to reason about manually. TLA+ model checking with explicit crash actions would be highly valuable.

3. **The locking protocol is correctly structured but has many paths.** The 5-path `enterPrecommit` and complex `addVote` prevote handler implement the Tendermint BFT locking rules. The code is well-commented and matches the paper, but the sheer number of paths warrants formal verification.

4. **Evidence handling has a critical unfixed bug.** The double-commitment issue (#4114) was closed as NOT_PLANNED despite being confirmed on CometBFT v1.0. The crash window between `Commit` and `evpool.Update` (E2) provides a concrete mechanism.

5. **The gossip layer is a liveness concern, not a safety concern.** Gossip protocol issues (TOCTOU races, peer state resets, vote tracking gaps) affect the efficiency and speed of consensus but should not violate safety properties. They should be modeled as nondeterministic message delivery rather than explicit gossip protocol.

6. **POLRound validation gap (V8) is a potential safety issue.** The proposal's `POLRound` is not validated against `Round` at the type level. If a proposal with `POLRound >= Round` reaches the consensus state machine, it could affect the locking/unlocking logic. This warrants TLA+ investigation.
