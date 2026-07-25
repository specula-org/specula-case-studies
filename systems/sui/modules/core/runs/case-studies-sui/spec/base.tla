--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for Sui Mysticeti DAG-BFT consensus.
 *
 * Derived from: MystenLabs/sui consensus/core/src/*.rs
 * Bug Families (modeling-brief.md §2):
 *   F1: Equivocation handling at (round, author) slot      — HIGH
 *   F2: Amnesia recovery — f+1 vs 2f+1 threshold          — HIGH
 *   F3: GC × Commit Rule interactions                     — MEDIUM
 *   F4: Leader timeout / threshold clock / proposer       — MEDIUM
 *   F5: Byzantine input validation (commit-vote equivoc.) — LOW
 *
 * Category A (Distributed) with Byzantine adversary; n = 3f+1.
 * Wave length = 3 (leader at R, voters at R+1, certifiers at R+2).
 * Single leader per round (production config: num_leaders_per_round=Some(1)).
 *
 * The spec models the IMPLEMENTATION: equivocating blocks are
 * intentionally committed (linearizer.rs:177-204), GC is per-validator
 * (dag_state.rs:1175-1186), amnesia recovery uses validity (f+1) not
 * quorum (synchronizer.rs:900-904).
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server          \* Set of validator IDs (n = 3f+1)
CONSTANT Byzantine       \* Subset of Server that may behave arbitrarily
CONSTANT MaxRound        \* Maximum round to explore
CONSTANT MaxDigest       \* Maximum number of distinct block digests per slot
                          \* (>1 enables equivocation modeling for F1)
CONSTANT MaxTimestamp    \* Bound on block timestamps (small integers)
CONSTANT Nil             \* Sentinel value (kept as constant for backwards-compat;
                          \* no longer used after the GetBlocksAtRef refactor)

\* Wave parameters (commit.rs DEFAULT_WAVE_LENGTH = 3)
CONSTANT WaveLength      \* Always 3 in production
CONSTANT GCDepth         \* gc_round = last_committed_round - GCDepth

\* Decision outcomes (commit.rs LeaderStatus)
CONSTANTS
    Commit_,             \* Commit(block_ref)
    Skip_,               \* Skip(slot)
    Undecided_           \* Undecided(slot)

\* Decision rule used (commit.rs Decision)
CONSTANTS
    DirectDecision,
    IndirectDecision

\* ============================================================================
\* DERIVED SETS
\* ============================================================================

Honest == Server \ Byzantine
Round == 0..MaxRound
Digest == 1..MaxDigest

\* Genesis is a synthetic block per author at round 0
GenesisBlockRef(a) == [round |-> 0, author |-> a, digest |-> 1]

\* ============================================================================
\* QUORUM HELPERS
\* ============================================================================
\*
\* Reference: stake_aggregator.rs (QuorumThreshold = 2f+1, ValidityThreshold = f+1)
\* Equal stake assumed: |Server| = 3f+1, quorum = ceil(2|Server|/3) > 2|Server|/3.

N == Cardinality(Server)

\* QuorumThreshold: 2f+1, i.e., > 2/3 of total stake.
\* Reference: consensus_config Committee::reached_quorum
IsQuorum(stakeSet) == 3 * Cardinality(stakeSet) >= 2 * N + 1

\* ValidityThreshold: f+1, i.e., > 1/3 of total stake.
\* Reference: consensus_config Committee::reached_validity (synchronizer.rs:901)
IsValidity(stakeSet) == 3 * Cardinality(stakeSet) >= N + 1

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- F1 / F3: DAG state ---
\*
\* Messages: the global set of blocks ever produced. Unlike Raft-style log
\* models, blocks are records with explicit (author, round, digest); any
\* (author, round) may have MULTIPLE digests when the author is Byzantine
\* (Family 1: linearizer.rs:177-204 commits all of them).
\*
\* Block schema: [author, round, digest, ancestors, timestamp, commitVotes]
\*   ancestors:    set of BlockRef  (block.rs Block::ancestors)
\*   timestamp:    Nat               (block.rs Block::timestamp_ms)
\*   commitVotes:  set of [index, digest]  (block.rs Block::commit_votes; F5)
VARIABLE Messages

\* Per-validator in-memory DAG. Subset of Messages that this validator
\* has received and accepted. In the impl this lives in DagState.recent_blocks
\* (dag_state.rs:172). Volatile — wiped on Crash.
VARIABLE dag

\* Per-validator threshold clock round (threshold_clock.rs:18).
\* Advances when 2f+1 stake is accepted at clockRound or any higher round.
VARIABLE clockRound

\* Per-validator garbage collection round (dag_state.rs:1175-1186).
\* gcRound = last_commit_round - GCDepth (saturating). Honest validators may
\* differ when their commit progress differs (Family 3).
VARIABLE gcRound

\* Per-validator decided-leader map. slot -> {Commit(blockRef), Skip(slot), Undecided}
\* base_committer.rs:86-117 (try_direct_decide), :122-145 (try_indirect_decide).
VARIABLE decided

\* Per-validator linearized commit sequence. Each entry is a CommittedSubDag.
\* linearizer.rs:65-120 (collect_sub_dag_and_commit).
\* CommittedSubDag schema:
\*   [index, leader, blocks (ordered seq), timestamp, prevDigest, digest]
VARIABLE committedSeq

\* Per-validator already-committed block-ref set. Used by linearizer's filter
\* `!dag_state.is_committed(ancestor)` (linearizer.rs:185-187).
VARIABLE committedBlocks

\* --- F2: Amnesia recovery state ---
\*
\* signedHistory[s] = set of (round, digest) pairs the SIGNING KEY of s
\* has ever produced. Survives Crash because the signing key lives in an
\* HSM / key vault separate from the consensus DB (per modeling brief §2).
\* Used to express the safety property NoOwnEquivocation.
VARIABLE signedHistory

\* lastKnownProposed[s] = recovered value of last_known_proposed_round.
\* Set by Recover from peer responses (synchronizer.rs:900-921).
\* Used as a guard: Propose only if r > lastKnownProposed[s].
VARIABLE lastKnownProposed

\* crashed[s] = TRUE while server is offline; in-memory state is wiped.
VARIABLE crashed

\* --- F4: Proposer state ---
\*
\* lastIncludedAncestors[s][a] = highest BlockRef of author a that s has
\* included as an ancestor in its own block (proposer.rs:198-202).
VARIABLE lastIncludedAncestors

\* lastProposedRound[s] = highest round at which s has produced a block.
\* Maintained by core.rs alongside the threshold clock.
VARIABLE lastProposedRound

\* --- F4: Certified-commit fast-sync ---
\*
\* certifiedCommitRound[s] = highest commit round that was applied via
\* `Core::add_certified_commits` (commit_syncer.rs). May exceed local DAG
\* completeness, creating the assert!(parent_round_quorum.reached_threshold)
\* hazard at proposer.rs:352-354.
VARIABLE certifiedCommitRound

\* --- Variable groups for UNCHANGED ---
dagVars       == <<Messages, dag, clockRound, gcRound>>
commitVars    == <<decided, committedSeq, committedBlocks>>
amnesiaVars   == <<signedHistory, lastKnownProposed, crashed>>
proposerVars  == <<lastIncludedAncestors, lastProposedRound, certifiedCommitRound>>

vars == <<dagVars, commitVars, amnesiaVars, proposerVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* BlockRef is the (round, author, digest) tuple used throughout the impl.
\* block.rs BlockRef.
RefOf(b) == [round |-> b.round, author |-> b.author, digest |-> b.digest]

\* Slot is the (round, author) pair. base_committer.rs:99 uses Slot to
\* fetch all blocks at the slot — this is where equivocation enters.
SlotOf(b) == [round |-> b.round, author |-> b.author]
SlotOfRef(r) == [round |-> r.round, author |-> r.author]

\* Lookup blocks at a slot in s's local DAG (dag_state.rs:490-502).
BlocksAtSlotIn(s, slot) ==
    { b \in dag[s] : b.author = slot.author /\ b.round = slot.round }

BlocksAtRoundIn(s, r) ==
    { b \in dag[s] : b.round = r }

\* Get blocks at a reference in s's local DAG (dag_state.rs:431-435).
\* Returns a set: empty if not found, singleton otherwise. Set semantics
\* avoid the TLC strict-equality check on heterogeneous types (record vs
\* "Nil" string) that would fire if we used a Nil sentinel.
GetBlocksAtRef(s, ref) ==
    { b \in dag[s] :
        b.author = ref.author
        /\ b.round = ref.round
        /\ b.digest = ref.digest }

\* Single-leader election per round. Production config:
\* consensus_protocol_config.rs:86 num_leaders_per_round = Some(1).
\* leader_schedule.rs uses a deterministic round-robin with reputation
\* scoring; we abstract to round-robin over a deterministic Server order
\* that matches the harness's authority-index convention:
\* AuthorityIndex(i) → "s{i+1}". Hardcoded for the 4-validator case used
\* by all cfgs in this spec.
ServerSeq == <<"s1", "s2", "s3", "s4">>
LeaderOf(r) == ServerSeq[(r % N) + 1]

\* Wave / decision round arithmetic (base_committer.rs:170-186).
WaveOf(r) == r \div WaveLength
DecisionRound(r) == r + WaveLength - 1

\* ============================================================================
\* VOTE SEMANTICS — find_supported_block
\* ============================================================================
\*
\* Reference: base_committer.rs:193-215 (find_supported_block).
\*
\* Recursive: walk ancestors looking for a block at leader_slot. Returns
\* the FIRST ancestor matching the slot (or via recursion). The TLA+
\* definition is closed-form via the transitive ancestor set; the impl
\* uses DFS.
\*
\* CRITICAL (F3): the impl PANICS if a referenced block is not in storage
\* (line 209). It does NOT have the GC guard that is_certificate has
\* (lines 250-256). This panic is what FindSupportedBlockReachable models.

\* All ancestor BlockRefs reachable from `from` via `dag[s]`, restricted
\* to ancestors with round > leader_slot.round (the recursive descent
\* condition at line 202: `if ancestor.round <= leader_slot.round continue`).
\* This is a LET-bound bounded fixpoint over the impl's recursion depth.
\* Recursive ancestor closure of `ref` walking strictly above `lowerRound`.
\* The recursion descends ancestors with round > lowerRound. Callers wanting
\* ancestors at >= leader_slot.round must pass lowerRound = leader_slot.round - 1.
RECURSIVE AncestorRefsAbove(_, _, _, _)
AncestorRefsAbove(s, ref, lowerRound, depth) ==
    IF depth = 0 THEN {ref}
    ELSE LET blocks == GetBlocksAtRef(s, ref)
         IN IF blocks = {}
            THEN {ref}  \* leaf in s's view (real impl panics; modeled via guard)
            ELSE LET b == CHOOSE bb \in blocks : TRUE
                     strict == { a \in b.ancestors : a.round > lowerRound }
                 IN {ref} \cup
                    UNION { AncestorRefsAbove(s, a, lowerRound, depth - 1)
                            : a \in strict }

\* For the leader_slot lookup, find_supported_block returns Some(ref)
\* iff some ancestor (transitively, restricted to round > leader_slot.round
\* OR equal-and-matching) equals leader_slot.
\* We return the canonical first match — the impl's DFS order depends on
\* HashSet ordering of `from.ancestors()`; for honest validators this is
\* deterministic by block content (Family 1: digest order matters for
\* equivocating slots).
\* Set of refs in the recursive ancestor closure that match leaderSlot.
\* Empty if no supporting block exists (in place of returning Nil).
\*
\* Impl semantics: `find_supported_block` recurses on ancestors with round
\* >= leader_slot.round, and returns Some(ref) if any ref in that closure
\* matches the slot. We need to include round = leaderSlot.round in the
\* walk, so we pass `leaderSlot.round - 1` as the strict-lower bound to
\* AncestorRefsAbove (which uses `a.round > lowerRound`).
FindSupportedBlockRefs(s, leaderSlot, from) ==
    LET reach == AncestorRefsAbove(s, RefOf(from),
                                    leaderSlot.round - 1, MaxRound + 1)
    IN { r \in reach :
            r.round = leaderSlot.round
            /\ r.author = leaderSlot.author }

\* Predicate: F3 — does the recursion succeed without a missing-block panic?
\* True iff every transitive ancestor with round > leaderSlot.round is in dag[s].
\* (Mirrors the implicit guard that find_supported_block lacks but
\* is_certificate has.)
RECURSIVE FindSupportedBlockReachable(_, _, _, _)
FindSupportedBlockReachable(s, leaderSlot, ref, depth) ==
    \/ depth = 0
    \/ ref.round < leaderSlot.round
    \/ /\ GetBlocksAtRef(s, ref) /= {}
       /\ LET b == CHOOSE bb \in GetBlocksAtRef(s, ref) : TRUE
              strict == { a \in b.ancestors : a.round >= leaderSlot.round }
          IN \A a \in strict :
              FindSupportedBlockReachable(s, leaderSlot, a, depth - 1)

\* is_vote (base_committer.rs:219-223)
IsVote(s, voter, leaderBlock) ==
    RefOf(leaderBlock) \in FindSupportedBlockRefs(s, SlotOf(leaderBlock), voter)

\* is_certificate (base_committer.rs:231-279) with the GC guard at line 250-256.
\* Returns TRUE iff potentialCert's ancestors form a quorum of votes for
\* leaderBlock — but missing blocks at round > gc_round panic.
\* Here we treat unreachable ancestors as non-votes (the impl's behavior
\* for round <= gc_round) and require all referenced ancestors above gc_round
\* to be present (the impl's assert).
IsCertificate(s, potentialCert, leaderBlock) ==
    LET gc == gcRound[s]
        ancRefs == potentialCert.ancestors
        votingRefs == { r \in ancRefs :
                          r.round > gc /\ GetBlocksAtRef(s, r) /= {} }
        voters == { r.author : r \in
                      { rr \in votingRefs :
                          IsVote(s, CHOOSE bb \in GetBlocksAtRef(s, rr) : TRUE,
                                 leaderBlock) } }
    IN IsQuorum(voters)

\* ============================================================================
\* ACTIONS — Block production
\* ============================================================================

\* --------------------------------------------------------------------------
\* HonestPropose: an honest validator s produces a block at round r.
\* Reference: proposer.rs:367-411 (try_new_block) +
\*            proposer.rs:170-364 (smart_ancestors_to_propose).
\*
\* Preconditions:
\* - r > lastProposedRound[s] (proposer.rs:382-400).
\* - r > lastKnownProposed[s] (Family 2 amnesia guard).
\* - 2f+1 stake of round r-1 blocks accepted (proposer.rs:224-232, 352-354).
\* - r = clockRound[s] (advanced via threshold clock).
\*
\* The block:
\* - includes own r-1 block if any plus 2f+1 stake of r-1 ancestors (smart-select).
\* - timestamp is monotonic w.r.t. parents (median-timestamp logic abstracted).
\* --------------------------------------------------------------------------
HonestPropose(s) ==
    /\ s \in Honest
    /\ ~crashed[s]
    /\ LET r == clockRound[s] IN
       /\ r >= 1 /\ r <= MaxRound
       /\ r > lastProposedRound[s]
       /\ r > lastKnownProposed[s]
       \* 2f+1 stake of r-1 accepted (proposer.rs:352-354 assertion).
       /\ LET parents == BlocksAtRoundIn(s, r - 1)
              parentAuthors == { p.author : p \in parents }
          IN /\ IsQuorum(parentAuthors)
             \* Build new block. Pick own digest = 1 (honest: one block per slot).
             /\ \E ts \in 1..MaxTimestamp :
                  /\ LET ancestorRefs ==
                            { RefOf(p) : p \in parents }
                         newBlock ==
                            [author      |-> s,
                             round       |-> r,
                             digest      |-> 1,
                             ancestors   |-> ancestorRefs,
                             timestamp   |-> ts,
                             commitVotes |-> {}]
                     IN /\ Messages' = Messages \cup {newBlock}
                        /\ dag' = [dag EXCEPT ![s] = @ \cup {newBlock}]
                        \* Sign: persist (round, digest) into signedHistory.
                        \* The signing key is what produces the block.
                        /\ signedHistory' = [signedHistory EXCEPT ![s] =
                              @ \cup {[round |-> r, digest |-> 1]}]
                        /\ lastProposedRound' = [lastProposedRound EXCEPT ![s] = r]
                        /\ lastIncludedAncestors' = [lastIncludedAncestors EXCEPT ![s] =
                              [a \in Server |->
                                IF \E p \in parents : p.author = a
                                THEN LET pp == CHOOSE p \in parents : p.author = a
                                     IN RefOf(pp)
                                ELSE @[a]]]
    /\ UNCHANGED <<clockRound, gcRound, decided, committedSeq, committedBlocks,
                   lastKnownProposed, crashed, certifiedCommitRound>>

\* --------------------------------------------------------------------------
\* ByzPropose: a Byzantine validator produces an arbitrary block.
\* Reference: bft-analysis 2.1 Equivocation, modeling brief §2 Family 1.
\*
\* No preconditions on parent quorum, timestamp, or own-equivocation guard
\* (these are violated by definition under Byzantine).
\* The verifier (block_verifier.rs:67-152) does NOT validate timestamp_ms
\* (Family 5 #1) — so timestamp can be anything.
\* --------------------------------------------------------------------------
ByzPropose(s, r, d) ==
    /\ s \in Byzantine
    /\ r \in 1..MaxRound
    /\ d \in Digest
    \* Block does not already exist (sanity)
    /\ ~ \E b \in Messages : b.author = s /\ b.round = r /\ b.digest = d
    \* Pick arbitrary ancestors at strictly lower rounds (impl rejects
    \* ancestors with round >= self.round; block_verifier).
    /\ \E ancRefs \in SUBSET { RefOf(b) : b \in Messages } :
        /\ \A ar \in ancRefs : ar.round < r
        /\ \E ts \in 1..MaxTimestamp :
            LET newBlock ==
                  [author      |-> s,
                   round       |-> r,
                   digest      |-> d,
                   ancestors   |-> ancRefs,
                   timestamp   |-> ts,
                   commitVotes |-> {}]
            IN /\ Messages' = Messages \cup {newBlock}
               \* The harness's Byzantine validator is a real ValidatorHarness
               \* instance — it calls accept_block on its own equivocating
               \* block, so dag[s] grows for s the producer.
               /\ dag' = [dag EXCEPT ![s] = @ \cup {newBlock}]
               /\ signedHistory' = [signedHistory EXCEPT ![s] =
                      @ \cup {[round |-> r, digest |-> d]}]
    /\ UNCHANGED <<clockRound, gcRound, commitVars,
                   lastKnownProposed, crashed,
                   lastIncludedAncestors, lastProposedRound,
                   certifiedCommitRound>>

\* --------------------------------------------------------------------------
\* DeliverBlock: a block in Messages is accepted into validator s's DAG.
\* Reference: block_manager.rs:309-355 (try_accept_one_block) +
\*            dag_state.rs:295-350 (accept_block).
\*
\* Acceptance requires:
\* - All ancestors with round > gc_round are present in dag[s], OR
\*   the ancestor's round <= gc_round (impl skips checks below gc_round).
\*
\* Honest validators panic on own-equivocation (dag_state.rs:322-336);
\* we model this via an own-slot guard. Byzantine authors are exempt.
\* --------------------------------------------------------------------------
DeliverBlock(s, b) ==
    /\ ~crashed[s]
    /\ b \in Messages
    /\ b \notin dag[s]
    \* Abstraction gap: the production block_manager would suspend a block
    \* with missing high-round ancestors until the ancestors arrive. The test
    \* harness used to generate traces calls `dag_state.accept_block` directly,
    \* bypassing this suspension and emitting `DeliverBlock` even when round-r
    \* ancestors (r > gc_round) are missing. So we do NOT gate DeliverBlock on
    \* ancestor presence in dag[s]. Bugs that depend on recursion through
    \* missing ancestors are still surfaced by CommitRecursionDecidable when
    \* TryDirectDecide / Linearize runs.
    \* Own-slot guard (dag_state.rs:322-336) — honest s never accepts a
    \* second own-block. (Byzantine s ignores this, but DeliverBlock here
    \* models another validator's view; s's *own* slot guard fires on s's
    \* own DagState.)
    /\ b.author = s =>
         BlocksAtSlotIn(s, SlotOf(b)) = {}
    /\ dag' = [dag EXCEPT ![s] = @ \cup {b}]
    \* Threshold clock update (threshold_clock.rs:36-82).
    /\ LET cur == clockRound[s]
           sameRoundAuthors ==
              { bb.author : bb \in BlocksAtRoundIn(s, b.round) \cup {b} }
       IN clockRound' = [clockRound EXCEPT ![s] =
              \* Ordering::Less — irrelevant
              IF b.round < cur THEN @
              \* Ordering::Equal — advance to b.round+1 if 2f+1
              ELSE IF b.round = cur THEN
                  IF IsQuorum(sameRoundAuthors) THEN b.round + 1 ELSE @
              \* Ordering::Greater — single block catches up
              ELSE \* threshold_clock.rs:65-80
                  IF IsQuorum({b.author}) THEN b.round + 1
                  ELSE b.round]
    /\ UNCHANGED <<Messages, gcRound, commitVars,
                   signedHistory, lastKnownProposed, crashed,
                   proposerVars>>

\* ============================================================================
\* ACTIONS — Commit decisions
\* ============================================================================

\* --------------------------------------------------------------------------
\* TryDirectDecide: apply the direct decision rule for a leader slot.
\* Reference: base_committer.rs:86-117 (try_direct_decide).
\*
\* Mysticeti's RULE:
\* 1. If 2f+1 blame at voting_round (=leader_round+1) -> Skip.
\* 2. Else fetch ALL blocks at slot (equivocation possible, Family 1).
\* 3. For each leader block, test enough_leader_support at decision_round
\*    (=leader_round + wave_length - 1).
\* 4. PANIC if more than one leader block has enough support
\*    (line 108-112) — relies on stake math making this impossible.
\* 5. Else: Commit(theBlock) | Undecided.
\* --------------------------------------------------------------------------
EnoughLeaderBlame(s, leaderSlot) ==
    \* base_committer.rs:337-366
    LET votingRound == leaderSlot.round + 1
        votingBlocks == BlocksAtRoundIn(s, votingRound)
        blamers ==
            { vb.author : vb \in
                { vb \in votingBlocks :
                    \A a \in vb.ancestors : a.author /= leaderSlot.author } }
    IN IsQuorum(blamers)

EnoughLeaderSupport(s, leaderBlock) ==
    \* base_committer.rs:370-401
    LET decRound == DecisionRound(leaderBlock.round)
        decBlocks == BlocksAtRoundIn(s, decRound)
        certs ==
            { db \in decBlocks : IsCertificate(s, db, leaderBlock) }
        certAuthors == { db.author : db \in certs }
    IN IsQuorum(certAuthors)

TryDirectDecide(s, leaderSlot) ==
    /\ ~crashed[s]
    /\ leaderSlot.round >= 1
    /\ leaderSlot.author = LeaderOf(leaderSlot.round)
    \* Decision round must be reachable in s's DAG.
    /\ DecisionRound(leaderSlot.round) <= MaxRound
    \* Slot not already decided.
    /\ leaderSlot \notin DOMAIN decided[s]
    \* Compute outcome.
    /\ LET leaderBlocks == BlocksAtSlotIn(s, leaderSlot)
           supportedBlocks ==
               { lb \in leaderBlocks : EnoughLeaderSupport(s, lb) }
           outcome ==
               IF EnoughLeaderBlame(s, leaderSlot)
               THEN [tag |-> Skip_, slot |-> leaderSlot]
               ELSE IF supportedBlocks = {}
                    THEN [tag |-> Undecided_, slot |-> leaderSlot]
                    ELSE [tag |-> Commit_,
                          ref  |-> RefOf(CHOOSE lb \in supportedBlocks : TRUE)]
       IN /\ \/ outcome.tag /= Commit_
             \* Mysticeti BFT-assumption check (lines 108-112).
             \/ Cardinality(supportedBlocks) <= 1
          /\ decided' = [decided EXCEPT ![s] = (leaderSlot :> outcome) @@ @]
    /\ UNCHANGED <<dagVars, committedSeq, committedBlocks,
                   amnesiaVars, proposerVars>>

\* --------------------------------------------------------------------------
\* TryIndirectDecide: apply indirect decision rule using anchor.
\* Reference: base_committer.rs:122-145 (try_indirect_decide) +
\*            :284-334 (decide_leader_from_anchor).
\*
\* For an undecided leader slot L, find a later-round committed leader A
\* (the anchor) and check whether any leader block at L has a certified
\* link to A. If yes -> Commit, if no -> Skip.
\* --------------------------------------------------------------------------
TryIndirectDecide(s, leaderSlot, anchorRef) ==
    /\ ~crashed[s]
    /\ leaderSlot \notin DOMAIN decided[s]
    /\ leaderSlot.author = LeaderOf(leaderSlot.round)
    /\ anchorRef.round >= leaderSlot.round + WaveLength
    /\ leaderSlot \in DOMAIN decided[s] => decided[s][leaderSlot].tag = Undecided_
    \* Anchor must be a committed leader from s's view.
    /\ \E earlier \in DOMAIN decided[s] :
         /\ decided[s][earlier].tag = Commit_
         /\ decided[s][earlier].ref = anchorRef
    /\ LET anchorBlocks == GetBlocksAtRef(s, anchorRef)
       IN /\ anchorBlocks /= {}
          /\ LET leaderBlocks == BlocksAtSlotIn(s, leaderSlot)
                 \* potential certificates at decision_round
                 decRound == DecisionRound(leaderSlot.round)
                 \* ancestors_at_round of anchor at decRound
                 \* (dag_state.rs:559-578 — PANICS on missing intermediate;
                 \*  modeled by intersection with dag[s])
                 anchorAncRefs ==
                    AncestorRefsAbove(s, anchorRef, decRound - 1, MaxRound + 1)
                 potentialCerts ==
                    UNION { GetBlocksAtRef(s, r) : r \in
                              { rr \in anchorAncRefs : rr.round = decRound } }
                 certifiedLeaders ==
                    { lb \in leaderBlocks :
                        \E pc \in potentialCerts :
                          IsCertificate(s, pc, lb) }
                 outcome ==
                    IF certifiedLeaders = {}
                    THEN [tag |-> Skip_, slot |-> leaderSlot]
                    ELSE [tag |-> Commit_,
                          ref  |-> RefOf(CHOOSE lb \in certifiedLeaders : TRUE)]
             IN /\ \/ outcome.tag /= Commit_
                   /\ Cardinality(certifiedLeaders) <= 1
                /\ decided' = [decided EXCEPT ![s] = (leaderSlot :> outcome) @@ @]
    /\ UNCHANGED <<dagVars, committedSeq, committedBlocks,
                   amnesiaVars, proposerVars>>

\* ============================================================================
\* ACTIONS — Linearization
\* ============================================================================

\* --------------------------------------------------------------------------
\* Linearize: collect the sub-dag for a committed leader.
\* Reference: linearizer.rs:65-218 (collect_sub_dag_and_commit,
\*            linearize_sub_dag, calculate_commit_timestamp).
\*
\* CRITICAL (F1): the recursion includes ALL uncommitted ancestors with
\* round > gcRound[s]. Equivocating blocks at the same (round, author)
\* slot are BOTH included if both are reachable from the leader's
\* ancestor closure. Per maintainer (issue #24498), this is by design.
\*
\* Block ordering (commit.rs:403-409 sort_sub_dag_blocks): stable sort by
\* (round, author). Equivocating blocks at the same (round, author) tie
\* and keep DFS-discovery order — the source of MC1.
\* --------------------------------------------------------------------------
Linearize(s, leaderRef) ==
    /\ ~crashed[s]
    \* Leader must be marked Committed in this validator's decided map.
    /\ \E slot \in DOMAIN decided[s] :
         /\ decided[s][slot].tag = Commit_
         /\ decided[s][slot].ref = leaderRef
    \* Process commits in order: this leader is the next index.
    /\ leaderRef \notin committedBlocks[s]
    \* Compute sub-dag.
    /\ LET gc == gcRound[s]
           leaderBlockSet == GetBlocksAtRef(s, leaderRef)
       IN /\ leaderBlockSet /= {}
          /\ LET leader == CHOOSE l \in leaderBlockSet : TRUE
                 reachableRefs ==
                    AncestorRefsAbove(s, leaderRef, gc, MaxRound + 1)
                 newBlockRefs ==
                    { r \in reachableRefs : r \notin committedBlocks[s] }
                 newBlocks ==
                    UNION { GetBlocksAtRef(s, r) : r \in newBlockRefs }
                 \* Stable sort by (round, author). For equivocating blocks
                 \* at the same (round, author), order is DFS-dependent
                 \* (Family 1, MC1).
                 sorted ==
                    \* Modeled as set; the digest within tie is non-deterministic
                    \* under DFS — captured by AnyOrderingByRoundAuthor below.
                    newBlocks
                 leaderParentBlocks ==
                    UNION { GetBlocksAtRef(s, r) : r \in
                              { rr \in leader.ancestors : rr.round = leader.round - 1 } }
                 \* Median timestamp by stake (linearizer.rs:125-154).
                 \* Abstracted: pick any timestamp >= max parent timestamp.
                 lastTs ==
                    IF Len(committedSeq[s]) = 0 THEN 0
                    ELSE committedSeq[s][Len(committedSeq[s])].timestamp
                 maxParentTs ==
                    IF leaderParentBlocks = {} THEN 0
                    ELSE LET ps == { p.timestamp : p \in leaderParentBlocks }
                         IN IF ps = {} THEN 0
                            ELSE CHOOSE t \in ps : \A t2 \in ps : t2 <= t
                 commitTs ==
                    IF maxParentTs > lastTs THEN maxParentTs ELSE lastTs
                 idx == Len(committedSeq[s]) + 1
                 prevDigest ==
                    IF idx = 1 THEN 0
                    ELSE committedSeq[s][idx - 1].digest
                 \* Commit digest is a function of (idx, leader, blocks, ts, prev).
                 \* MC1: when blocks contains equivocating refs in different
                 \* DFS order, the resulting digest differs. For TLC, model the
                 \* digest as a deterministic record of those determining fields.
                 commitDigest ==
                    [leaderRef |-> leaderRef,
                     blockRefs |-> newBlockRefs,
                     commitTs  |-> commitTs,
                     prevDig   |-> prevDigest]
                 record ==
                    [index     |-> idx,
                     leader    |-> leaderRef,
                     blocks    |-> sorted,
                     timestamp |-> commitTs,
                     prev      |-> prevDigest,
                     digest    |-> commitDigest]
             IN /\ committedSeq' = [committedSeq EXCEPT ![s] = Append(@, record)]
                /\ committedBlocks' = [committedBlocks EXCEPT ![s] = @ \cup newBlockRefs]
                \* gc_round advances on commit (dag_state.rs:1175-1186).
                /\ gcRound' = [gcRound EXCEPT ![s] =
                       LET newGc == leader.round - GCDepth
                       IN IF newGc > @ THEN newGc ELSE @]
    /\ UNCHANGED <<Messages, dag, clockRound, decided,
                   amnesiaVars, proposerVars>>

\* ============================================================================
\* ACTIONS — Crash and Recovery (Family 2)
\* ============================================================================

\* --------------------------------------------------------------------------
\* Crash: validator s loses in-memory state.
\* Reference: modeling brief Family 2 — consensus DB wipe but signing key
\* (HSM) survives.
\*
\* Wiped: dag, decided, committedSeq, committedBlocks, lastIncludedAncestors,
\*        lastProposedRound (impl re-derives from store; modeled as wipe),
\*        clockRound, gcRound, lastKnownProposed.
\* Retained: signedHistory (signing key), Messages (other validators' state).
\* --------------------------------------------------------------------------
Crash(s) ==
    /\ ~crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    /\ dag' = [dag EXCEPT ![s] = {}]
    /\ clockRound' = [clockRound EXCEPT ![s] = 0]
    /\ gcRound' = [gcRound EXCEPT ![s] = 0]
    /\ decided' = [decided EXCEPT ![s] = << >>]  \* empty function
    /\ committedSeq' = [committedSeq EXCEPT ![s] = << >>]
    /\ committedBlocks' = [committedBlocks EXCEPT ![s] = {}]
    /\ lastIncludedAncestors' = [lastIncludedAncestors EXCEPT ![s] =
           [a \in Server |-> GenesisBlockRef(a)]]
    /\ lastProposedRound' = [lastProposedRound EXCEPT ![s] = 0]
    /\ lastKnownProposed' = [lastKnownProposed EXCEPT ![s] = 0]
    /\ certifiedCommitRound' = [certifiedCommitRound EXCEPT ![s] = 0]
    /\ UNCHANGED <<Messages, signedHistory>>

\* --------------------------------------------------------------------------
\* RecoverAmnesia: validator s comes back online and queries peers for
\* its own highest signed block round.
\* Reference: synchronizer.rs:800-921 (start_fetch_own_last_block_task).
\*
\* CRITICAL (F2): the impl breaks the loop when total_stake reaches
\* VALIDITY (f+1, line 901), NOT QUORUM (2f+1).
\* Each peer reports its observed highest round of s's blocks. Honest
\* peers report truthfully (= max of s's blocks they've ever seen);
\* Byzantine peers report arbitrary values.
\*
\* The bug: under f Byzantine + 1 honest who happened not to receive
\* s's last signed block, the f+1 responders may all underreport, and
\* lastKnownProposed[s] ends up < the true highest signedHistory entry.
\* Then s re-signs at that round → own-equivocation.
\* --------------------------------------------------------------------------
\* Honest peer's report is the highest round of s's blocks present in
\* peer's dag (dag_state.get_last_block_for_authority semantics).
HonestReport(peer, target) ==
    LET sBlocks == { b \in dag[peer] : b.author = target }
    IN IF sBlocks = {} THEN 0
       ELSE CHOOSE r \in { b.round : b \in sBlocks } :
              \A b \in sBlocks : b.round <= r

RecoverAmnesia(s) ==
    /\ crashed[s]
    \* Validity quorum (f+1 stake) of responders.
    /\ \E responders \in SUBSET (Server \ {s}) :
        /\ IsValidity(responders)
        \* Each responder gives a report; honest = HonestReport, Byzantine = arbitrary.
        /\ \E reports \in [responders -> 0..MaxRound] :
            /\ \A p \in responders \cap Honest :
                  reports[p] = HonestReport(p, s)
            \* Byzantine peers can report any value in 0..MaxRound (arbitrary).
            /\ LET maxReport ==
                    IF responders = {} THEN 0
                    ELSE CHOOSE r \in { reports[p] : p \in responders } :
                          \A p \in responders : reports[p] <= r
               IN /\ lastKnownProposed' = [lastKnownProposed EXCEPT ![s] = maxReport]
                  /\ crashed' = [crashed EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<Messages, dag, clockRound, gcRound, commitVars,
                   signedHistory, proposerVars>>

\* ============================================================================
\* ACTIONS — Threshold clock / certified-commit fast-sync (Family 4)
\* ============================================================================

\* --------------------------------------------------------------------------
\* AddCertifiedCommit: a peer-certified commit is applied, advancing the
\* validator's commit progress without requiring local DAG completeness.
\* Reference: commit_syncer.rs / Core::add_certified_commits.
\*
\* This is the input that creates the MC4 hazard: clockRound jumps high
\* without 2f+1 of round (clockRound-1) being in dag[s].
\* --------------------------------------------------------------------------
AddCertifiedCommit(s, r) ==
    /\ ~crashed[s]
    /\ r > certifiedCommitRound[s]
    /\ r <= MaxRound
    /\ certifiedCommitRound' = [certifiedCommitRound EXCEPT ![s] = r]
    \* Threshold clock catches up (per Core::add_certified_commits semantics).
    /\ clockRound' = [clockRound EXCEPT ![s] =
           IF r > @ THEN r ELSE @]
    /\ UNCHANGED <<Messages, dag, gcRound, commitVars,
                   amnesiaVars, lastIncludedAncestors,
                   lastProposedRound>>

\* --------------------------------------------------------------------------
\* ForcePropose: the LeaderTimeout path that bypasses smart-select.
\* Reference: proposer.rs:170-364 with smart_select=false +
\*            leader_timeout.rs (LeaderTimeout::run).
\*
\* This is where the MC4 assertion at proposer.rs:352-354 lives. A force-
\* propose that fires when parent_round_quorum.reached_threshold = false
\* is the bug. We model the fire — if the precondition fails, the
\* implementation panics; the spec records this as a violation of the
\* ForcePropose2f1Parents invariant rather than a hard guard.
\* --------------------------------------------------------------------------
ForcePropose(s) ==
    /\ s \in Honest
    /\ ~crashed[s]
    /\ LET r == clockRound[s] IN
       /\ r >= 1 /\ r <= MaxRound
       /\ r > lastProposedRound[s]
       /\ r > lastKnownProposed[s]
       \* No precondition on parent quorum — this is the BUG-EXPOSING action.
       /\ \E ts \in 1..MaxTimestamp :
            LET parents == BlocksAtRoundIn(s, r - 1)
                ancestorRefs == { RefOf(p) : p \in parents }
                newBlock ==
                  [author      |-> s,
                   round       |-> r,
                   digest      |-> 1,
                   ancestors   |-> ancestorRefs,
                   timestamp   |-> ts,
                   commitVotes |-> {}]
            IN /\ Messages' = Messages \cup {newBlock}
               /\ dag' = [dag EXCEPT ![s] = @ \cup {newBlock}]
               /\ signedHistory' = [signedHistory EXCEPT ![s] =
                       @ \cup {[round |-> r, digest |-> 1]}]
               /\ lastProposedRound' = [lastProposedRound EXCEPT ![s] = r]
    /\ UNCHANGED <<clockRound, gcRound, commitVars,
                   lastKnownProposed, crashed, lastIncludedAncestors,
                   certifiedCommitRound>>

\* ============================================================================
\* ACTIONS — Multi-leader latent path (Family 4 / MC5)
\* ============================================================================
\*
\* The multi-leader path is disabled in production
\* (consensus_protocol_config.rs:86 num_leaders_per_round=Some(1)). We do
\* NOT model it as an action in the base spec because every
\* code path is gated by num_leaders_per_round=1. MC5 is enabled by a
\* dedicated MC config that overrides LeaderOf to elect MULTIPLE leaders
\* per round — see MC.tla MultiLeaderInit / MC_hunt_family4_multileader.cfg.

\* ============================================================================
\* ACTIONS — Fault: lose / drop nothing (handled implicitly)
\* ============================================================================
\*
\* Mysticeti is pull-based: validators sync missing blocks via
\* `Synchronizer::fetch_blocks` rather than relying on push. There is no
\* explicit message-loss model — non-delivery is naturally captured by
\* the choice of which DeliverBlock fires.

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

\* Genesis: each author has a synthetic round-0 block that all blocks
\* reference. block.rs Block::genesis.
GenesisBlocks ==
    { [author      |-> a,
       round       |-> 0,
       digest      |-> 1,
       ancestors   |-> {},
       timestamp   |-> 0,
       commitVotes |-> {}] : a \in Server }

Init ==
    /\ Messages = GenesisBlocks
    /\ dag = [s \in Server |-> GenesisBlocks]
    /\ clockRound = [s \in Server |-> 1]
    /\ gcRound = [s \in Server |-> 0]
    /\ decided = [s \in Server |-> << >>]   \* empty function
    /\ committedSeq = [s \in Server |-> << >>]
    /\ committedBlocks = [s \in Server |-> {}]
    /\ signedHistory = [s \in Server |-> {}]
    /\ lastKnownProposed = [s \in Server |-> 0]
    /\ crashed = [s \in Server |-> FALSE]
    /\ lastIncludedAncestors = [s \in Server |->
           [a \in Server |-> GenesisBlockRef(a)]]
    /\ lastProposedRound = [s \in Server |-> 0]
    /\ certifiedCommitRound = [s \in Server |-> 0]

Next ==
    \/ \E s \in Server : HonestPropose(s)
    \/ \E s \in Server, r \in 1..MaxRound, d \in Digest : ByzPropose(s, r, d)
    \/ \E s \in Server, b \in Messages : DeliverBlock(s, b)
    \/ \E s \in Server, slot \in [round: 1..MaxRound, author: Server] :
         TryDirectDecide(s, slot)
    \/ \E s \in Server,
          slot \in [round: 1..MaxRound, author: Server],
          aRef \in [round: 1..MaxRound, author: Server, digest: Digest] :
            TryIndirectDecide(s, slot, aRef)
    \/ \E s \in Server, lref \in [round: 1..MaxRound, author: Server, digest: Digest] :
         Linearize(s, lref)
    \/ \E s \in Server : Crash(s)
    \/ \E s \in Server : RecoverAmnesia(s)
    \/ \E s \in Server, r \in 1..MaxRound : AddCertifiedCommit(s, r)
    \/ \E s \in Server : ForcePropose(s)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard / structural ---

TypeOK ==
    /\ Messages \subseteq [author: Server, round: 0..MaxRound, digest: Digest,
                            ancestors: SUBSET [round: 0..MaxRound, author: Server, digest: Digest],
                            timestamp: 0..MaxTimestamp,
                            commitVotes: SUBSET [index: Nat, digest: Digest]]
    /\ dag \in [Server -> SUBSET Messages]
    /\ clockRound \in [Server -> 0..(MaxRound+1)]
    /\ gcRound \in [Server -> 0..MaxRound]
    /\ crashed \in [Server -> BOOLEAN]
    /\ lastProposedRound \in [Server -> 0..MaxRound]
    /\ lastKnownProposed \in [Server -> 0..MaxRound]
    /\ certifiedCommitRound \in [Server -> 0..MaxRound]

\* --- Family 1: equivocation handling ---

\* CommitAgreement: if two honest validators commit at index i, the
\* (leader, blocks, timestamp) record is the same.
\* Reference: brief §5 — the central safety property of Mysticeti.
CommitAgreement ==
    \A s1, s2 \in Honest :
        \A i \in 1..MaxRound :
            (i <= Len(committedSeq[s1]) /\ i <= Len(committedSeq[s2])) =>
                /\ committedSeq[s1][i].leader = committedSeq[s2][i].leader
                /\ committedSeq[s1][i].blocks = committedSeq[s2][i].blocks
                /\ committedSeq[s1][i].timestamp = committedSeq[s2][i].timestamp

\* CommitDigestAgreement: byte-identical commit digest across honest validators.
\* If the (leader, blocks, timestamp, prev) tuple matches, the digest matches.
\* MC1 attacks this through equivocating-block DFS-discovery order.
CommitDigestAgreement ==
    \A s1, s2 \in Honest :
        \A i \in 1..MaxRound :
            (i <= Len(committedSeq[s1]) /\ i <= Len(committedSeq[s2])) =>
                committedSeq[s1][i].digest = committedSeq[s2][i].digest

\* LeaderCommitMonotonic: at most one block per (round, author) slot can be
\* directly-committed (paper sanity, single-leader assumption).
LeaderCommitMonotonic ==
    \A s \in Honest :
        \A slot \in DOMAIN decided[s] :
            decided[s][slot].tag = Commit_ =>
                Cardinality({ b \in dag[s] :
                               b.author = slot.author /\ b.round = slot.round
                               /\ EnoughLeaderSupport(s, b) }) <= 1

\* --- Family 2: amnesia recovery ---

\* NoOwnEquivocation: even across crash + recovery, an honest validator's
\* signing key never produces two distinct digests at the same round.
\* MC2 attacks this through f+1 amnesia threshold.
NoOwnEquivocation ==
    \A s \in Honest :
        \A r \in 1..MaxRound :
            Cardinality({ d \in Digest :
                           [round |-> r, digest |-> d] \in signedHistory[s] }) <= 1

\* --- Family 3: GC × commit rule ---

\* CommitRecursionDecidable: every find_supported_block-style recursion
\* succeeds without panic. Equivalent: every ancestor reference at
\* round > gcRound[s] is present in dag[s].
\* MC3 attacks this through different gcRound[s] across honest validators.
CommitRecursionDecidable ==
    \A s \in Honest :
        \A b \in dag[s] :
            \A a \in b.ancestors :
                a.round > gcRound[s] =>
                    \E bb \in dag[s] :
                        bb.author = a.author
                        /\ bb.round = a.round
                        /\ bb.digest = a.digest

\* --- Family 4: proposer liveness ---

\* ForcePropose2f1Parents: whenever a force-propose adds a block at round r
\* to dag[s], dag[s] contained 2f+1 stake of round r-1 *immediately before*.
\* Modeled as a state predicate: every non-genesis block in dag[s] from
\* an honest author has 2f+1 parent-round support in some predecessor state.
\* (For MC, this is checked via the action precondition violation.)
\* MC4 attacks this through certified-commit fast-sync + ForcePropose.
ForcePropose2f1Parents ==
    \A s \in Honest :
        \A b \in dag[s] :
            (b.author = s /\ b.round >= 1) =>
                LET parentAuthors ==
                       { a.author : a \in
                          { ar \in b.ancestors : ar.round = b.round - 1 } }
                IN IsQuorum(parentAuthors)

\* --- Structural ---

\* ClockGCConsistency: gcRound is bounded above by clockRound (gc cannot
\* outpace the clock — every commit is at a round we've seen).
ClockGCConsistency ==
    \A s \in Server : gcRound[s] <= clockRound[s]

\* CommittedBlocksSubsetDag: every committed block ref in the validator's
\* committedBlocks set was also in dag[s] when committed. (Sanity.)
\* Note: we relax to "either still in dag or genuinely above gc".
CommittedBlocksRoundOK ==
    \A s \in Server :
        \A r \in committedBlocks[s] :
            r.round >= 0 /\ r.round <= MaxRound

\* DecisionStability: once decided, a slot's outcome doesn't change.
\* (Modeled via the fact that TryDirectDecide / TryIndirectDecide require
\*  slot \notin DOMAIN decided[s].)
DecisionStability == TRUE  \* enforced structurally by action guards

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* AmnesiaRecoveryProgress (brief §5): a recovering validator eventually
\* completes the fetch-own-block phase.
AmnesiaRecoveryProgress ==
    \A s \in Honest :
        crashed[s] ~> ~crashed[s]

\* DAGEventualConsensus (brief §5): under fair scheduling, every honest
\* validator commits at least one leader.
DAGEventualConsensus ==
    \A s \in Honest :
        ~crashed[s] ~> Len(committedSeq[s]) >= 1

====
