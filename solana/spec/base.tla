--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for Solana Tower BFT (anza-xyz/agave).
 *
 * Derived from: anza-xyz/agave/core/src/
 *   - consensus.rs (Tower struct, lockout, switch-threshold)
 *   - consensus/tower_storage.rs (FileTowerStorage, no fsync)
 *   - consensus/vote_stake_tracker.rs (per-(slot,hash) OC stake)
 *   - consensus/latest_validator_votes_for_frozen_banks.rs (gossip vote map)
 *   - optimistic_confirmation_verifier.rs (unchecked OC slots)
 *   - cluster_info_vote_listener.rs (OC accounting)
 *   - replay_stage.rs (adopt_on_chain_tower_if_behind, purge_unconfirmed_slot,
 *                      process_duplicate_confirmed_slots)
 *   - voting_service.rs (record -> store -> broadcast pipeline)
 *
 * Category A (Distributed, Byzantine).  Sub-category: vote-lockout BFT.
 *
 * Bug Families (from modeling-brief.md):
 *   1 - Tower Adoption & Crash-Recovery Hazards
 *   2 - Switch-Threshold Manipulability via Gossip-Originated Latest Votes
 *   3 - Optimistic Confirmation Equivocation Accounting
 *   4 - Duplicate-Slot Reconciliation & Fork-Choice State Hazards
 *   5 - Lockout Defense-in-Depth Gaps
 *
 * Family 6 (Migration / Identity-Swap) is explicitly out of scope per brief 2.6.
 *
 * Modeling principle: model the implementation's actual control flow.
 * Deviations from the Tower BFT paper are where bugs live.
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server             \* Set of validator IDs (e.g. {v1, v2, v3, v4})
CONSTANT Byzantine          \* Subset of Server that is Byzantine
CONSTANT MaxSlot            \* Max slot to explore
CONSTANT Nil                \* Sentinel value for "none"
CONSTANT Hashes             \* Set of abstract bank-hash values per slot
\* Per-validator stake is modeled as uniform = 1 per validator.
\* This is sufficient for stake-fraction threshold checks given that the brief
\* (§5) defines all thresholds as fractions of total stake.  Asymmetric stake
\* can be added later as a refinement.
Stake(v) == 1

\* Fork tree: a model parameter overridden in cfg with a constant operator.
\* Default (this file): two siblings off slot 1 -- minimal two-fork shape.
\*   slot 1: root, hash hA
\*   slot 2: child of 1, hash hA  (main fork)
\*   slot 3: child of 1, hash hB  (alt fork)
\* MaxSlot >= 4 scenarios can override these via the cfg's CONSTANTS section
\* using the operator-override syntax (CanonicalSlotHash <- AltCanonicalSlotHash).
CONSTANT TwoForkRoot          \* a Hash; the hash of slot 1
CONSTANT MainForkHash         \* the hash assigned to the main fork branch
CONSTANT AltForkHash          \* the hash assigned to the alternative fork branch

\* Default fork tree (override in MC.cfg via operator override if needed).
ParentOfSlot ==
    [s \in 1..MaxSlot |->
        IF s = 1 THEN 0
        ELSE IF s = 2 \/ s = 3 THEN 1
        ELSE 1]   \* further slots default to parent = 1 (sibling branches)

CanonicalSlotHash ==
    [s \in 1..MaxSlot |->
        IF s = 1 THEN TwoForkRoot
        ELSE IF s = 2 THEN MainForkHash
        ELSE IF s = 3 THEN AltForkHash
        ELSE MainForkHash]

\* Threshold constants (exact fractions modeled as numerator/denominator pair).
\* core/src/consensus.rs SWITCH_FORK_THRESHOLD = 0.38, VOTE_THRESHOLD_SIZE = 2/3
\* core/src/consensus.rs DUPLICATE_THRESHOLD = 0.52 (replay_stage / cluster_info)
CONSTANT SwitchNumer        \* e.g. 38
CONSTANT SwitchDenom        \* e.g. 100
CONSTANT OCNumer            \* e.g. 2
CONSTANT OCDenom            \* e.g. 3
CONSTANT DupNumer           \* e.g. 52
CONSTANT DupDenom           \* e.g. 100

\* Lockout depth set: pairs (depth, threshold_kind).  Brief 5.5 / family 5.
\* core/src/consensus.rs:1382-1390 - vote_thresholds_and_depths
CONSTANT LockoutThresholdDepths   \* set of Nat (e.g. {4, 5, 8})

\* Forks are modeled as a fork tree, where each slot's hash determines its fork.
\* Slots are 1..MaxSlot.  Each slot has a parent.  Slots agree on a parent (root).

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Tower BFT in-memory tower (core/src/consensus.rs:69-118 Tower struct) ---
\* tower[v] = record:
\*   votes        : sequence of Lockout records {slot, conf_count}
\*   root_slot    : Slot   (None modeled as 0)
\*   last_voted_slot : Slot (0 if no vote)
\*   last_voted_hash : Hash
\*   stray_restored_slot : Slot  (Family 1; consensus.rs:761)
VARIABLE tower

\* --- On-disk persistent tower (core/src/consensus/tower_storage.rs:205) ---
\* Stored without fsync ("file.sync_all() hurts performance", line 215).
\* On crash, this may regress to any previously-persisted state.
VARIABLE persistedTower

\* --- Pending tower-store + broadcast (core/src/voting_service.rs:107-165) ---
\* The voting service receives a (tower, vote_tx) channel message,
\* stores tower, then broadcasts vote_tx.  Either step can be interrupted by crash.
\* pendingVoteOp[v] = record {savedTower, voteTx, stored : BOOLEAN} | Nil
VARIABLE pendingVoteOp

\* --- Per-(server, fork) bank vote state visible at each replayed bank.   ---
\* Family 1: adopt_on_chain_tower_if_behind reads this.
\* onChainVoteState[v][slot] = record {votes : seq, root_slot, last_voted_slot}
\* Modeled as a function from (v, slot) to vote-state record or Nil.
VARIABLE onChainVoteState

\* --- Gossip-originated latest-vote map ---
\* core/src/consensus/latest_validator_votes_for_frozen_banks.rs (Family 2).
\* gossipFrozenVotes[v] = record {slot, hash} representing the *claimed*
\* latest gossip vote of v.  Byzantine can fabricate; map is never pruned.
VARIABLE gossipFrozenVotes

\* --- Replay-originated latest votes (the "truth" track) ---
VARIABLE replayFrozenVotes

\* --- Per-(slot, hash) OC stake tracker ---
\* core/src/consensus/vote_stake_tracker.rs:14-38 (Family 3).
\* Per (slot, hash) we track the set of pubkeys whose votes have been counted.
\* ocStake[s][h] = SUBSET Server.
VARIABLE ocStake

\* --- Set of (slot, hash) that have reached the 2/3 OC threshold ---
\* core/src/optimistic_confirmation_verifier.rs:11-86 (Family 3).
VARIABLE ocConfirmed

\* --- Set of slots that have been rooted (32-deep lockout chain) ---
\* core/src/consensus.rs:1652  initialize_lockouts_from_bank establishes root.
VARIABLE rooted

\* --- For rooted slots, which hash rooted ---
VARIABLE rootedHash

\* --- Duplicate-confirmed observations (Family 4) ---
\* core/src/replay_stage.rs:2205 - process_duplicate_confirmed_slots.
\* duplicateConfirmed[slot] = SUBSET Hashes (Byzantine can drive size >= 2).
VARIABLE duplicateConfirmed

\* --- Per-validator local-view of purged slots (Family 4) ---
\* core/src/replay_stage.rs:2019-2124 purge_unconfirmed_slot.
\* purgedView[v] = SUBSET Slot.
VARIABLE purgedView

\* --- Server liveness flags ---
VARIABLE alive       \* [Server -> BOOLEAN] - whether process is running

\* --- Panic / liveness halt flag (Family 4) ---
\* Set when an assert_eq!/panic! site fires; once set, that server is dead.
VARIABLE panicked    \* [Server -> BOOLEAN]

\* --- Network: bag of in-flight messages ---
\* Messages: Vote(src, last_slot, last_hash, tower_slots, source_kind ∈ {replay, gossip})
\*           DuplicateConfirmSignal(slot, hash) - notification observed from cluster
VARIABLE msgs

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED)
\* ============================================================================

towerVars     == <<tower, persistedTower, pendingVoteOp>>
chainVars     == <<onChainVoteState, replayFrozenVotes, gossipFrozenVotes>>
ocVars        == <<ocStake, ocConfirmed>>
finalityVars  == <<rooted, rootedHash, duplicateConfirmed, purgedView>>
nodeVars      == <<alive, panicked>>
netVars       == <<msgs>>

allVars == <<towerVars, chainVars, ocVars, finalityVars,
             nodeVars, netVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

Honest == Server \ Byzantine

\* Total stake
TotalStake == LET sum[S \in SUBSET Server] ==
                 IF S = {} THEN 0
                 ELSE LET v == CHOOSE x \in S : TRUE IN Stake(v) + sum[S \ {v}]
              IN sum[Server]

\* Sum of stake over a set of validators
StakeOf(SS) == LET sum[S \in SUBSET Server] ==
                  IF S = {} THEN 0
                  ELSE LET v == CHOOSE x \in S : TRUE IN Stake(v) + sum[S \ {v}]
               IN sum[SS]

\* Stake-fraction comparisons - exact integer arithmetic, no f64.
\* SwitchProofReached: locked_out_stake > 0.38 * total_stake.
\* core/src/consensus.rs:1210, 1263
StakeExceedsSwitch(s) == s * SwitchDenom > SwitchNumer * TotalStake
StakeExceedsOC(s)     == s * OCDenom    > OCNumer    * TotalStake
StakeExceedsDup(s)    == s * DupDenom   > DupNumer   * TotalStake

\* Fork tree predicates.
\* Slot ancestor relation: a is ancestor of d iff a is on the parent-chain of d.
\* We compute the ancestor set recursively.  ParentOfSlot[1] = 0 by Init.
RECURSIVE AncestorsOf(_)
AncestorsOf(s) ==
    IF s = 0 THEN {}
    ELSE IF ParentOfSlot[s] = 0 THEN {0}
    ELSE {ParentOfSlot[s]} \cup AncestorsOf(ParentOfSlot[s])

\* Is `a` an ancestor of `d`?
IsAncestor(a, d) == a \in AncestorsOf(d)

\* Greatest common ancestor (max slot in intersection)
\* core/src/consensus.rs:947 greatest_common_ancestor
GCA(a, b) ==
    LET common == AncestorsOf(a) \cap AncestorsOf(b)
    IN IF common = {} THEN 0
       ELSE CHOOSE c \in common : \A o \in common : c >= o

\* "Same fork" = ancestor/descendant relation
SameFork(a, b) == IsAncestor(a, b) \/ IsAncestor(b, a) \/ a = b

\* Empty tower record
EmptyTower ==
    [votes |-> <<>>, root_slot |-> 0, last_voted_slot |-> 0,
     last_voted_hash |-> Nil, stray_restored_slot |-> 0]

\* Empty vote-state record (matches consensus.rs Tower::vote_state)
EmptyVoteState ==
    [votes |-> <<>>, root_slot |-> 0, last_voted_slot |-> 0,
     last_voted_hash |-> Nil]

\* Construct a vote-state record from primitives
MakeVoteState(votes, rootSlot, lastSlot, lastHash) ==
    [votes |-> votes, root_slot |-> rootSlot,
     last_voted_slot |-> lastSlot, last_voted_hash |-> lastHash]

\* Lockout depth at position i in the tower votes sequence.
\* core/src/consensus.rs - process_next_vote_slot uses 2^(confirmation_count).
\* For modeling, lockout depth = 2 ^ conf_count is too big; we use confirmation_count
\* directly and the safety check is that distinct-fork votes within tower must be
\* on the same fork as a future vote.
Lockout(slot, confCount) == [slot |-> slot, confirmation_count |-> confCount]

\* The set of (slot, hash) pairs visible from v's tower as "still locked out".
\* core/src/consensus.rs:827-856 - is_locked_out.
\* A vote at slot s with confirmation count c locks out until slot s + 2^c.
\* We use confirmation_count >= 0 as the lockout chain depth.  For TLC bounds,
\* we don't model exponential expiry; instead we require that all tower slots
\* lie on the same fork as any candidate vote.
TowerSlots(twr) ==
    { twr.votes[i].slot : i \in DOMAIN twr.votes }

\* ============================================================================
\* INIT
\* ============================================================================

\* The fork tree (ParentOfSlot, CanonicalSlotHash) is a model parameter, fixed
\* at boot.  PoH oracle assumption: all validators agree on slot lineage and
\* the canonical hash chosen by the slot leader.  Byzantine equivocation is
\* modeled by allowing Byzantine to inject votes on alternate hashes.

Init ==
    /\ tower            = [v \in Server |-> EmptyTower]
    /\ persistedTower   = [v \in Server |-> EmptyTower]
    /\ pendingVoteOp    = [v \in Server |-> Nil]
    /\ onChainVoteState = [v \in Server |->
                             [s \in 0..MaxSlot |-> EmptyVoteState]]
    /\ gossipFrozenVotes = [v \in Server |-> Nil]
    /\ replayFrozenVotes = [v \in Server |-> Nil]
    /\ ocStake          = [s \in 0..MaxSlot |->
                             [h \in Hashes |-> {}]]
    /\ ocConfirmed      = {}
    /\ rooted           = {0}
    /\ rootedHash       = [s \in 0..MaxSlot |-> Nil]
    /\ duplicateConfirmed = [s \in 0..MaxSlot |-> {}]
    /\ purgedView       = [v \in Server |-> {}]
    /\ alive            = [v \in Server |-> TRUE]
    /\ panicked         = [v \in Server |-> FALSE]
    /\ msgs = EmptyBag

\* ============================================================================
\* MESSAGE HELPERS
\* ============================================================================

\* A vote message broadcast by a validator (replay or refresh).
\* Fields:
\*   src         : sender validator
\*   last_slot   : slot of the last vote
\*   last_hash   : hash of the last vote
\*   tower_slots : sequence of slots in the tower (for receipt-checking)
\*   source_kind : "replay" (signed valid vote-tx) or "gossip" (gossip CrdsValue)
VoteMsg(src, lastSlot, lastHash, towerSlots, kind) ==
    [mtype |-> "Vote", msrc |-> src,
     last_slot |-> lastSlot, last_hash |-> lastHash,
     tower_slots |-> towerSlots, source_kind |-> kind]

\* Duplicate-confirm signal (cluster-wide observation a slot was duplicate-confirmed).
\* core/src/replay_stage.rs:2205
DupConfMsg(slot, hash) ==
    [mtype |-> "DupConf", slot |-> slot, hash |-> hash]

Send(m)    == msgs' = msgs (+) SetToBag({m})
Discard(m) == msgs' = msgs (-) SetToBag({m})

\* ============================================================================
\* ACTION: RecordVote
\* (core/src/consensus.rs:700-735 - record_bank_vote_and_update_lockouts)
\*
\* In-memory tower update only.  Family 1: this is step 1 of the 3-step pipeline
\* (record -> store -> broadcast).  Crash before PersistTower loses durable record.
\* Family 5 (latent footgun): consensus.rs:707 only checks `vote_slot <= last_voted_slot`,
\* not is_locked_out — could panic with VoteTooOld but not lockout violation.
\* ============================================================================

RecordVote(v, voteSlot, voteHash) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ voteSlot \in 1..MaxSlot
    /\ voteHash \in Hashes
    \* consensus.rs:707-713 — panic on vote_slot <= last_voted_slot.
    /\ tower[v].last_voted_slot = 0 \/ voteSlot > tower[v].last_voted_slot
    \* The slot's hash must match (we model the leader-frozen-hash assumption).
    \* The voter has already committed to the cluster's choice of hash for this slot.
    /\ voteHash = CanonicalSlotHash[voteSlot]
    \* Cannot vote on a slot whose bank was purged (replay_stage.rs:2019).
    \* purge_unconfirmed_slot removes the bank from bank_forks; the replay
    \* loop's select_vote_and_reset_forks picks the heaviest bank, which
    \* cannot include a slot that has been purged.  Without this guard, the
    \* spec admits purge-then-vote sequences that the implementation prevents.
    /\ voteSlot \notin purgedView[v]
    \* No pending op (one vote at a time per validator)
    /\ pendingVoteOp[v] = Nil
    \* Honest validators check is_locked_out before voting (cache_tower_stats path).
    \* Brief 6.1 MC-2 wants to find paths where this is bypassed.
    \* We model the honest path here; Byzantine can bypass via ByzRecordVoteUnlocked.
    /\ v \in Honest =>
         \A i \in DOMAIN tower[v].votes :
             LET ts == tower[v].votes[i].slot
             IN ts = voteSlot \/ SameFork(ts, voteSlot)
    \* Update in-memory tower: append new lockout, then collapse expired ones.
    \* Modeled abstractly: append one lockout with conf_count = Len(votes)+1.
    /\ LET newVotes ==
              Append(tower[v].votes, Lockout(voteSlot, Len(tower[v].votes) + 1))
       IN tower' = [tower EXCEPT
              ![v].votes           = newVotes,
              ![v].last_voted_slot = voteSlot,
              ![v].last_voted_hash = voteHash]
    \* Enqueue for store+broadcast: voting_service.rs handle_vote receives
    /\ pendingVoteOp' = [pendingVoteOp EXCEPT ![v] =
          [savedTower |-> [tower[v] EXCEPT
                              !.votes = Append(tower[v].votes,
                                              Lockout(voteSlot, Len(tower[v].votes) + 1)),
                              !.last_voted_slot = voteSlot,
                              !.last_voted_hash = voteHash],
           voteSlot   |-> voteSlot,
           voteHash   |-> voteHash,
           stored     |-> FALSE]]
    /\ UNCHANGED <<persistedTower, chainVars, ocVars, finalityVars,
                   nodeVars, netVars>>

\* ============================================================================
\* ACTION: PersistTower
\* (core/src/voting_service.rs:115-122 - tower_storage.store(saved_tower);
\*  core/src/consensus/tower_storage.rs:205-220 - FileTowerStorage::store)
\*
\* Family 1: PERSISTENCE WITHOUT FSYNC (explicit comment in code at line 215).
\* After this action, persistedTower equals the in-memory pending tower.  But
\* on crash before fsync, persistedTower may revert nondeterministically.
\* ============================================================================

PersistTower(v) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ pendingVoteOp[v] /= Nil
    /\ pendingVoteOp[v].stored = FALSE
    \* tower_storage.rs:205-220 write+rename (NO fsync).
    /\ persistedTower' = [persistedTower EXCEPT ![v] = pendingVoteOp[v].savedTower]
    /\ pendingVoteOp' = [pendingVoteOp EXCEPT ![v].stored = TRUE]
    /\ UNCHANGED <<tower, chainVars, ocVars, finalityVars,
                   nodeVars, netVars>>

\* ============================================================================
\* ACTION: BroadcastVote
\* (core/src/voting_service.rs:124-165 - send to TPU + cluster_info.push_vote)
\*
\* Vote-tx goes on the wire.  Family 1: this can happen BEFORE persist completes
\* if reordered, but the code path is store-then-broadcast (line 116-156).
\* We model store-before-broadcast strictly; the failure mode is crash *between*.
\* ============================================================================

BroadcastVote(v) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ pendingVoteOp[v] /= Nil
    /\ pendingVoteOp[v].stored = TRUE
    \* voting_service.rs:156 cluster_info.push_vote — broadcast.
    /\ LET op == pendingVoteOp[v]
           towerSeq == op.savedTower.votes
           towerSlotSeq == [i \in DOMAIN towerSeq |-> towerSeq[i].slot]
       IN /\ Send(VoteMsg(v, op.voteSlot, op.voteHash, towerSlotSeq, "replay"))
          \* Update the on-chain vote-state for v at the frozen slot:
          /\ onChainVoteState' = [onChainVoteState EXCEPT
                ![v][op.voteSlot] =
                    MakeVoteState(op.savedTower.votes,
                                  op.savedTower.root_slot,
                                  op.voteSlot,
                                  op.voteHash)]
          /\ replayFrozenVotes' = [replayFrozenVotes EXCEPT ![v] =
                [slot |-> op.voteSlot, hash |-> op.voteHash]]
    /\ pendingVoteOp' = [pendingVoteOp EXCEPT ![v] = Nil]
    /\ UNCHANGED <<tower, persistedTower, gossipFrozenVotes,
                   ocVars, finalityVars, nodeVars>>

\* ============================================================================
\* ACTION: ReceiveVote and OC accounting
\* (core/src/cluster_info_vote_listener.rs:680-754 - process_last_vote_for_oc;
\*  consensus/vote_stake_tracker.rs:14-38 - add_vote_pubkey)
\*
\* Family 3: per-(slot, hash) OC stake accumulates.  CROSS-HASH DEDUP IS ABSENT.
\* If v has voted on (s, h1) and later on (s, h2), both buckets accumulate.
\* ============================================================================

ReceiveVote(receiver, m) ==
    /\ alive[receiver] = TRUE
    /\ panicked[receiver] = FALSE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = "Vote"
    /\ m.last_slot \in 1..MaxSlot
    /\ m.last_hash \in Hashes
    \* cluster_info_vote_listener.rs:940-955 — add to OC tracker.
    \* No cross-hash dedup: m.msrc may already be in ocStake[m.last_slot][h']
    \* for some other h' — that does NOT prevent us from adding here.
    /\ ocStake' = [ocStake EXCEPT
          ![m.last_slot][m.last_hash] =
              ocStake[m.last_slot][m.last_hash] \cup {m.msrc}]
    \* Discard the message (consumed by the listener).
    /\ Discard(m)
    \* Update gossip-frozen-votes map if source is gossip.
    /\ IF m.source_kind = "gossip"
       THEN gossipFrozenVotes' = [gossipFrozenVotes EXCEPT ![m.msrc] =
              [slot |-> m.last_slot, hash |-> m.last_hash]]
       ELSE UNCHANGED gossipFrozenVotes
    /\ UNCHANGED <<towerVars, onChainVoteState, replayFrozenVotes,
                   ocConfirmed, finalityVars, nodeVars>>

\* ============================================================================
\* ACTION: ReachOC
\* (core/src/optimistic_confirmation_verifier.rs:57-86 -
\*  add_new_optimistic_confirmed_slots adds (slot, hash) to unchecked_slots
\*  once 2/3 threshold reached.)
\*
\* Family 3: (slot, hash) becomes OC-confirmed.  Multiple hashes per slot can
\* be confirmed (no NoDualHashOC invariant in code) under Byzantine equivocation.
\* ============================================================================

ReachOC(slot, hash) ==
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    /\ <<slot, hash>> \notin ocConfirmed
    /\ StakeExceedsOC(StakeOf(ocStake[slot][hash]))
    /\ ocConfirmed' = ocConfirmed \cup {<<slot, hash>>}
    /\ UNCHANGED <<towerVars, chainVars, ocStake, rooted, rootedHash,
                   duplicateConfirmed, purgedView, nodeVars, netVars>>

\* ============================================================================
\* ACTION: RootSlot
\* (core/src/consensus.rs - root advances when a tower vote is 32-deep.)
\*
\* When a vote at slot s is buried under enough subsequent votes, its slot s
\* becomes the new tower root.  In implementation: 32-vote tower triggers this.
\* For modeling we let the action fire when at least one validator has voted on
\* slot s on this hash and 2/3 stake has voted on a descendant.  This captures
\* the "rooted" notion at a tractable abstraction level.
\* ============================================================================

RootSlot(slot, hash) ==
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    /\ slot \notin rooted
    \* Some validator has accumulated 2/3 stake-weighted descendants.
    \* Simplification: require that (slot, hash) has reached OC and a strict
    \* descendant has also been OC'd by 2/3 stake.
    /\ <<slot, hash>> \in ocConfirmed
    /\ \E s2 \in 1..MaxSlot, h2 \in Hashes :
         /\ s2 > slot
         /\ IsAncestor(slot, s2)
         /\ <<s2, h2>> \in ocConfirmed
    /\ rooted' = rooted \cup {slot}
    /\ rootedHash' = [rootedHash EXCEPT ![slot] = hash]
    /\ UNCHANGED <<towerVars, chainVars, ocVars, duplicateConfirmed,
                   purgedView, nodeVars, netVars>>

\* ============================================================================
\* ACTION: PurgeUnconfirmedSlot
\* (core/src/replay_stage.rs:2019-2124 - purge_unconfirmed_slot)
\*
\* Family 4: clears bank_forks/ancestors/descendants/progress but NOT tower.
\* Tower retains a vote on the purged slot — TowerVotesAreOnExistingForks may break.
\* ============================================================================

PurgeUnconfirmedSlot(v, slot) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ slot \in 1..MaxSlot
    /\ slot \notin purgedView[v]
    \* replay_stage.rs:1809 dump_then_repair_correct_slots only purges when
    \* the validator's local bank for the slot disagrees with the cluster's
    \* duplicate-confirmed hash.  In this spec, honest validators' local
    \* bank for slot s is at CanonicalSlotHash[s], so purge fires only when
    \* duplicateConfirmed[slot] contains a hash != CanonicalSlotHash[slot]
    \* (Byzantine-injected dup-conf or honest-split dup-conf on a divergent
    \*  hash).  Without this filter the spec admits impl-impossible purges.
    /\ \E h \in duplicateConfirmed[slot] : h /= CanonicalSlotHash[slot]
    /\ purgedView' = [purgedView EXCEPT ![v] = purgedView[v] \cup {slot}]
    /\ UNCHANGED <<towerVars, chainVars, ocVars, rooted, rootedHash,
                   duplicateConfirmed, nodeVars, netVars>>

\* ============================================================================
\* ACTION: ProcessDuplicateConfirmedSlots
\* (core/src/replay_stage.rs:2205-2254 - process_duplicate_confirmed_slots)
\*
\* Family 4: assert_eq!(prev_hash, duplicate_confirmed_hash) — process death
\* if two distinct hashes are duplicate-confirmed for the same slot.
\* ============================================================================

ProcessDuplicateConfirmedSignal(v, slot, hash) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    \* Look for a matching DupConf message in flight (or a fresh signal).
    /\ \E m \in DOMAIN msgs : msgs[m] > 0 /\ m.mtype = "DupConf"
         /\ m.slot = slot /\ m.hash = hash
         /\ Discard(m)
    \* replay_stage.rs:2223-2233 — if slot already had an entry with a different
    \* hash, panic.  Otherwise record.
    /\ IF duplicateConfirmed[slot] /= {} /\ hash \notin duplicateConfirmed[slot]
       THEN /\ panicked' = [panicked EXCEPT ![v] = TRUE]
            /\ alive' = [alive EXCEPT ![v] = FALSE]
            /\ duplicateConfirmed' = [duplicateConfirmed EXCEPT ![slot] =
                   duplicateConfirmed[slot] \cup {hash}]
       ELSE /\ duplicateConfirmed' = [duplicateConfirmed EXCEPT ![slot] =
                   duplicateConfirmed[slot] \cup {hash}]
            /\ UNCHANGED <<alive, panicked>>
    /\ UNCHANGED <<towerVars, chainVars, ocVars, rooted, rootedHash,
                   purgedView>>

\* ============================================================================
\* ACTION: MakeCheckSwitchThresholdDecision (Family 2)
\* (core/src/consensus.rs:959-1273 - make_check_switch_threshold_decision)
\*
\* Computes a SwitchProof when locked_out_stake > 38% of total_stake.
\* The locked_out_stake comes from TWO sources:
\*   (a) on-chain locked-out votes (consensus.rs:1117-1216), and
\*   (b) gossip-claimed latest-vote stakes (consensus.rs:1218-1268).
\* The (b) path admits Byzantine fake gossip-votes — Family 2.
\*
\* The action records that v would "decide to switch to switch_slot" and updates
\* nothing else; the actual vote happens via CastSwitchVote.
\* ============================================================================

\* "Real" locked-out stake (on-chain): for each validator u, if its on-chain
\* last-vote on its tower is on a fork incompatible with switch_slot and
\* strictly later than v's last_voted_slot, count u's stake once.
RealLockedOutStake(v, switchSlot) ==
    LET lastVoted == tower[v].last_voted_slot
        candidates ==
          { u \in Server :
              /\ replayFrozenVotes[u] /= Nil
              /\ replayFrozenVotes[u].slot > lastVoted
              /\ ~ IsAncestor(lastVoted, replayFrozenVotes[u].slot)
              /\ ~ SameFork(replayFrozenVotes[u].slot, switchSlot) }
    IN StakeOf(candidates)

\* "Gossip-claimed" locked-out stake: includes Byzantine-fabricated entries
\* per consensus.rs:1218-1268.  is_valid_switching_proof_vote only does
\* graph-shape filtering on `ancestors` (Family 2).
GossipLockedOutStake(v, switchSlot) ==
    LET lastVoted == tower[v].last_voted_slot
        gossipCandidates ==
          { u \in Server :
              /\ gossipFrozenVotes[u] /= Nil
              /\ gossipFrozenVotes[u].slot > lastVoted
              /\ ~ IsAncestor(lastVoted, gossipFrozenVotes[u].slot)
              /\ ~ SameFork(gossipFrozenVotes[u].slot, switchSlot) }
    IN StakeOf(gossipCandidates)

\* Total stake counted toward switch threshold (gossip + replay, with cross-source
\* dedup of the validator pubkey set, which the code does at consensus.rs:1190-1192).
CombinedLockedOutStake(v, switchSlot) ==
    LET lastVoted == tower[v].last_voted_slot
        realCands ==
          { u \in Server :
              /\ replayFrozenVotes[u] /= Nil
              /\ replayFrozenVotes[u].slot > lastVoted
              /\ ~ IsAncestor(lastVoted, replayFrozenVotes[u].slot)
              /\ ~ SameFork(replayFrozenVotes[u].slot, switchSlot) }
        gossipCands ==
          { u \in Server :
              /\ gossipFrozenVotes[u] /= Nil
              /\ gossipFrozenVotes[u].slot > lastVoted
              /\ ~ IsAncestor(lastVoted, gossipFrozenVotes[u].slot)
              /\ ~ SameFork(gossipFrozenVotes[u].slot, switchSlot) }
    IN StakeOf(realCands \cup gossipCands)

\* Switch decision: returns "SwitchProof" or "FailedSwitchThreshold" or "SameFork".
SwitchDecisionReached(v, switchSlot) ==
    \/ \* SameFork branch (consensus.rs:1094-1098)
       SameFork(switchSlot, tower[v].last_voted_slot)
    \/ \* SwitchProof branch (consensus.rs:1210-1212 or 1263-1265)
       StakeExceedsSwitch(CombinedLockedOutStake(v, switchSlot))
    \/ \* empty_ancestors_due_to_minor_unsynced_ledger short-circuit:
       \* if stray, is_valid_switching_proof_vote returns Some(true) for any
       \* candidate that isn't a descendant of last_voted_slot.  consensus.rs:881-897
       /\ tower[v].stray_restored_slot = tower[v].last_voted_slot
       /\ tower[v].stray_restored_slot /= 0

\* CastSwitchVote: actually casts a vote on switchSlot if the decision allows.
\* This is the bridge from make_check_switch_threshold_decision (consensus.rs:959)
\* into record_bank_vote_and_update_lockouts (consensus.rs:700).
CastSwitchVote(v, switchSlot) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ switchSlot \in 1..MaxSlot
    /\ tower[v].last_voted_slot /= 0
    /\ ~ SameFork(switchSlot, tower[v].last_voted_slot)
    /\ SwitchDecisionReached(v, switchSlot)
    /\ pendingVoteOp[v] = Nil
    /\ switchSlot > tower[v].last_voted_slot
    /\ CanonicalSlotHash[switchSlot] \in Hashes
    \* Treat as a "vote on switchSlot with switchSlot's canonical hash"
    /\ RecordVote(v, switchSlot, CanonicalSlotHash[switchSlot])

\* ============================================================================
\* ACTION: Crash
\* (Family 1: amnesia + non-atomic persist)
\*
\* In-memory state lost: tower[v] := persistedTower[v].  Since persistedTower
\* is NOT fsync'd, on crash we ALSO nondeterministically revert persistedTower
\* to one of its prior values.  We model the "lost write" case by clearing
\* the pending op AND by allowing persistedTower to nondeterministically revert
\* to a tower without the pending vote (only if pendingVoteOp[v].stored = TRUE
\* but the OS hadn't flushed the page yet).
\* ============================================================================

Crash(v) ==
    /\ alive[v] = TRUE
    \* Lose in-memory state.
    /\ tower' = [tower EXCEPT ![v] = persistedTower[v]]
    \* Lose any pending vote-op.
    /\ pendingVoteOp' = [pendingVoteOp EXCEPT ![v] = Nil]
    /\ alive' = [alive EXCEPT ![v] = FALSE]
    /\ UNCHANGED <<persistedTower, chainVars, ocVars, finalityVars,
                   panicked, netVars>>

\* Variant: crash AFTER store but BEFORE fsync was flushed by OS.
\* persistedTower regresses to its prior state.  Family 1, brief §5.1+5.4.
\* core/src/consensus/tower_storage.rs:215 — "file.sync_all() hurts performance"
CrashBeforeFsyncReachesDisk(v) ==
    /\ alive[v] = TRUE
    /\ pendingVoteOp[v] /= Nil
    /\ pendingVoteOp[v].stored = TRUE
    \* In-memory tower lost.
    /\ tower' = [tower EXCEPT ![v] = EmptyTower]
    \* persistedTower regresses (the write hadn't reached the platter).
    /\ persistedTower' = [persistedTower EXCEPT ![v] = EmptyTower]
    /\ pendingVoteOp' = [pendingVoteOp EXCEPT ![v] = Nil]
    /\ alive' = [alive EXCEPT ![v] = FALSE]
    /\ UNCHANGED <<chainVars, ocVars, finalityVars,
                   panicked, netVars>>

\* ============================================================================
\* ACTION: Restart
\* (core/src/replay_stage.rs:1587 - load_tower; consensus.rs:1462-1535 -
\*  adjust_lockouts_after_replay)
\*
\* On restart: load persistedTower; pass through adjust_lockouts_after_replay.
\* If the persisted tower is "stray" (slots not in local DAG) we record
\* stray_restored_slot — Family 1 brief 6.1 MC-2.
\* ============================================================================

Restart(v) ==
    /\ alive[v] = FALSE
    /\ panicked[v] = FALSE
    /\ alive' = [alive EXCEPT ![v] = TRUE]
    \* tower <- persistedTower (consensus.rs:1462 / 1546).
    \* The tower-restore code in adjust_lockouts_after_replay may set
    \* stray_restored_slot = last_voted_slot if the persisted vote is
    \* not in the replayed slot history.  We model this nondeterministically:
    /\ \/ \* normal-case restore (consensus.rs:1462-1487)
          /\ tower' = [tower EXCEPT ![v] = persistedTower[v]]
       \/ \* stray-vote case (consensus.rs:881-897 empty_ancestors_due_to_minor_unsynced_ledger)
          /\ persistedTower[v].last_voted_slot /= 0
          /\ tower' = [tower EXCEPT ![v] =
                [persistedTower[v] EXCEPT
                    !.stray_restored_slot = persistedTower[v].last_voted_slot]]
    /\ pendingVoteOp' = [pendingVoteOp EXCEPT ![v] = Nil]
    /\ UNCHANGED <<persistedTower, chainVars, ocVars, finalityVars,
                   panicked, netVars>>

\* ============================================================================
\* ACTION: AdoptOnChainTowerIfBehind
\* (core/src/replay_stage.rs:4046-4166 - adopt_on_chain_tower_if_behind)
\*
\* Family 1: THE unique-to-Tower-BFT amnesia mechanism.  Overwrite tower with
\* bank-derived state when bank.last_voted_slot > local last_voted_slot.
\* No per-vote provenance audit — Byzantine-influenced bank can poison.
\* ============================================================================

AdoptOnChainTowerIfBehind(v, bankSlot) ==
    /\ alive[v] = TRUE
    /\ panicked[v] = FALSE
    /\ bankSlot \in 1..MaxSlot
    /\ onChainVoteState[v][bankSlot].last_voted_slot >
       tower[v].last_voted_slot
    \* replay_stage.rs:4055-4061 — if bank.get_vote_account(my_vote_pubkey) is Some
    \* and bank_vote_state.last_voted_slot > tower.last_voted_slot, overwrite.
    /\ tower' = [tower EXCEPT ![v] =
          [votes              |-> onChainVoteState[v][bankSlot].votes,
           root_slot          |-> onChainVoteState[v][bankSlot].root_slot,
           last_voted_slot    |-> onChainVoteState[v][bankSlot].last_voted_slot,
           last_voted_hash    |-> onChainVoteState[v][bankSlot].last_voted_hash,
           stray_restored_slot |-> 0]]
    /\ UNCHANGED <<persistedTower, pendingVoteOp, chainVars, ocVars,
                   finalityVars, nodeVars, netVars>>

\* ============================================================================
\* ACTION: DropMessage
\* (network message loss; standard distributed fault)
\* ============================================================================

DropMessage(m) ==
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ Discard(m)
    /\ UNCHANGED <<towerVars, chainVars, ocVars, finalityVars,
                   nodeVars>>

\* ============================================================================
\* BYZANTINE ACTIONS
\* (Adversary categories from BFT analysis applied to Tower BFT)
\* ============================================================================

\* --- 2.1 + 2.7 Equivocation: Byzantine validator votes on two forks
\* core/src/cluster_info_vote_listener.rs OC accumulator has no cross-hash dedup.
ByzVoteOnBothForks(v, slot, hashA, hashB) ==
    /\ v \in Byzantine
    /\ alive[v] = TRUE
    /\ slot \in 1..MaxSlot
    /\ hashA \in Hashes
    /\ hashB \in Hashes
    /\ hashA /= hashB
    \* Two votes on the same slot, different hash — directly inject into the bag.
    /\ msgs' = msgs (+) SetToBag({
          VoteMsg(v, slot, hashA, <<slot>>, "replay"),
          VoteMsg(v, slot, hashB, <<slot>>, "replay")})
    /\ UNCHANGED <<towerVars, chainVars, ocVars, finalityVars,
                   nodeVars>>

\* --- 2.7 Cert-manipulation: Byzantine claims a gossip latest-vote that
\* the on-chain vote-state never recorded.  core/src/consensus.rs:1218-1268,
\* latest_validator_votes_for_frozen_banks.rs check_add_vote with is_replay=false.
ByzGossipFakeLatestFrozenVote(v, slot, hash) ==
    /\ v \in Byzantine
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    /\ msgs' = msgs (+) SetToBag({VoteMsg(v, slot, hash, <<slot>>, "gossip")})
    /\ UNCHANGED <<towerVars, chainVars, ocVars, finalityVars,
                   nodeVars>>

\* --- 2.6 Amnesia: Byzantine peer crafts a bank vote-state for our vote-account.
\* This models the threat where v's bank.get_vote_account(my_vote_pubkey) returns
\* a state that v never actually voted with.  core/src/replay_stage.rs:4046-4061.
ByzCraftBankVoteState(v, bankSlot, fakeLastSlot, fakeHash) ==
    /\ v \in Byzantine \/ \E b \in Byzantine : TRUE  \* Byzantine block-builder
    /\ bankSlot \in 1..MaxSlot
    /\ fakeLastSlot \in 1..MaxSlot
    /\ fakeHash \in Hashes
    /\ onChainVoteState' = [onChainVoteState EXCEPT
          ![v][bankSlot] = MakeVoteState(
              <<Lockout(fakeLastSlot, 1)>>,
              0,
              fakeLastSlot,
              fakeHash)]
    /\ UNCHANGED <<towerVars, replayFrozenVotes, gossipFrozenVotes,
                   ocVars, finalityVars, nodeVars, netVars>>

\* --- 2.1 Driving the dual-hash duplicate-confirm panic (Family 4).
\* Byzantine ≥ 0.52 stake (or honest split) signals dup-confirm on two hashes.
ByzInjectDupConfirmSignal(slot, hash) ==
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    /\ Byzantine /= {}
    \* The DupConf signal originates from the cluster's duplicate-confirmed
    \* threshold (DUPLICATE_THRESHOLD = 0.52); model as a direct injection.
    /\ msgs' = msgs (+) SetToBag({DupConfMsg(slot, hash)})
    /\ UNCHANGED <<towerVars, chainVars, ocVars, finalityVars,
                   nodeVars>>

\* --- 2.5 Replay / stale gossip-vote reuse (Family 2, MC-7).
\* Replay a previously-issued gossip vote at a slot that has since been pruned.
ByzReuseStaleGossipVote(v, slot, hash) ==
    /\ v \in Byzantine
    /\ gossipFrozenVotes[v] /= Nil
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    \* Re-inject the (old) gossip vote as if it were fresh.
    /\ msgs' = msgs (+) SetToBag({VoteMsg(v, slot, hash, <<slot>>, "gossip")})
    /\ UNCHANGED <<towerVars, chainVars, ocVars, finalityVars,
                   nodeVars>>

\* ============================================================================
\* NEXT
\* ============================================================================

Next ==
    \/ \E v \in Server, s \in 1..MaxSlot, h \in Hashes : RecordVote(v, s, h)
    \/ \E v \in Server : PersistTower(v)
    \/ \E v \in Server : BroadcastVote(v)
    \/ \E v \in Server, m \in DOMAIN msgs : ReceiveVote(v, m)
    \/ \E s \in 1..MaxSlot, h \in Hashes : ReachOC(s, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : RootSlot(s, h)
    \/ \E v \in Server, s \in 1..MaxSlot : PurgeUnconfirmedSlot(v, s)
    \/ \E v \in Server, s \in 1..MaxSlot, h \in Hashes :
           ProcessDuplicateConfirmedSignal(v, s, h)
    \/ \E v \in Server, s \in 1..MaxSlot : CastSwitchVote(v, s)
    \/ \E v \in Server : Crash(v)
    \/ \E v \in Server : CrashBeforeFsyncReachesDisk(v)
    \/ \E v \in Server : Restart(v)
    \/ \E v \in Server, s \in 1..MaxSlot : AdoptOnChainTowerIfBehind(v, s)
    \/ \E m \in DOMAIN msgs : DropMessage(m)
    \* Byzantine actions
    \/ \E v \in Byzantine, s \in 1..MaxSlot, hA, hB \in Hashes :
           ByzVoteOnBothForks(v, s, hA, hB)
    \/ \E v \in Byzantine, s \in 1..MaxSlot, h \in Hashes :
           ByzGossipFakeLatestFrozenVote(v, s, h)
    \/ \E v \in Server, s \in 1..MaxSlot, ls \in 1..MaxSlot, h \in Hashes :
           ByzCraftBankVoteState(v, s, ls, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : ByzInjectDupConfirmSignal(s, h)
    \/ \E v \in Byzantine, s \in 1..MaxSlot, h \in Hashes :
           ByzReuseStaleGossipVote(v, s, h)

Spec == Init /\ [][Next]_allVars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard BFT safety: an honest validator never equivocates ---
\* (No honest server has voted on two different hashes at the same slot.)
\* core/src/consensus.rs:700-735 record_bank_vote_and_update_lockouts asserts
\* vote_slot > last_voted_slot, but does not prevent voting on same slot twice
\* with different hashes (which the impl prevents by recording last_voted_slot).
NoEquivocatingVoteFromHonest ==
    \A v \in Honest, s \in 1..MaxSlot :
        Cardinality({ h \in Hashes : v \in ocStake[s][h] }) <= 1

\* --- LockoutSafety: honest tower's lockouts are mutually fork-consistent ---
\* core/src/consensus.rs is_locked_out semantics.
LockoutSafety ==
    \A v \in Honest :
        \A i, j \in DOMAIN tower[v].votes :
            SameFork(tower[v].votes[i].slot, tower[v].votes[j].slot)

\* --- NoDualHashOC: brief §5.  Family 3, MC-1, MC-4.  ---
\* This is the key safety target; not enforced by code under Byzantine equivocation.
NoDualHashOC ==
    \A s \in 1..MaxSlot :
        Cardinality({ h \in Hashes : <<s, h>> \in ocConfirmed }) <= 1

\* --- OCImpliesEventualRoot: liveness; relaxed to "if OC then either rooted
\* on same hash, or accountability evidence exists" for finite-trace check. ---
OCRollbackBounded ==
    \A pair \in ocConfirmed :
        LET s == pair[1]
            h == pair[2]
        IN /\ s \in rooted => rootedHash[s] = h
           \* if rolled back: at least 1/3 stake is Byzantine (model accountability).
           \/ StakeOf(Byzantine) * 3 > TotalStake
           \/ s \notin rooted

\* --- NoDualHashDuplicateConfirm (Family 4) ---
\* Code asserts; should not be violated under f < n/3.
NoDualHashDuplicateConfirm ==
    \A s \in 1..MaxSlot :
        Cardinality(duplicateConfirmed[s]) <= 1

\* --- SwitchProofRequiresRealLockout (Family 2, MC-3) ---
\* If a switch decision is reached on switchSlot at v, the *real* on-chain
\* locked-out stake (excluding gossip-only claims) is >= 38%.
\* Phrased as an invariant on tower[v] after CastSwitchVote: any non-SameFork
\* vote in the tower has 38%+ REAL backing.
SwitchProofRequiresRealLockout ==
    \A v \in Honest :
        \A i \in DOMAIN tower[v].votes :
            LET vs == tower[v].votes[i].slot
            IN \/ i = 1
               \/ LET prev == tower[v].votes[i - 1].slot
                  IN SameFork(prev, vs)
                     \/ StakeExceedsSwitch(RealLockedOutStake(v, vs))

\* --- TowerConsistentWithPersistedAfterCrash ---
\* (Family 1, MC-2): after restart, in-memory tower matches the persisted state.
\* Holds vacuously if the validator hasn't crashed; checked by always-true relation.
TowerConsistentWithPersistedAfterCrash ==
    \A v \in Server :
        ~ alive[v] => tower[v] = persistedTower[v]

\* --- AdoptOnChainTowerNoLossOfDurableVote ---
\* AdoptOnChainTower should not roll back the persisted tower's last_voted_slot.
AdoptOnChainTowerNoLossOfDurableVote ==
    \A v \in Honest :
        persistedTower[v].last_voted_slot <= tower[v].last_voted_slot
        \/ persistedTower[v].last_voted_slot = 0

\* --- TowerVotesAreOnExistingForks (Family 4, MC-6) ---
\* Tower must not contain a slot that v has purged from its local view.
TowerVotesAreOnExistingForks ==
    \A v \in Honest :
        \A i \in DOMAIN tower[v].votes :
            tower[v].votes[i].slot \notin purgedView[v]

\* --- RootedSlotsForkConsistent ---
\* Any two rooted slots are on the same fork.
RootedSlotsForkConsistent ==
    \A s1, s2 \in rooted :
        SameFork(s1, s2)

\* --- Structural invariants ---

\* No validator votes on a slot twice with the same hash (idempotency).
\* This is the dedup property the OC tracker DOES enforce (vote_stake_tracker.rs:22).
OCStakeIdempotent ==
    \A s \in 1..MaxSlot, h \in Hashes :
        ocStake[s][h] \subseteq Server

\* Rooted set always contains genesis.
RootedContainsGenesis ==
    0 \in rooted

\* Tower last_voted_slot is in 0..MaxSlot.
TowerSlotBound ==
    \A v \in Server : tower[v].last_voted_slot \in 0..MaxSlot

\* No process is alive and panicked at the same time.
\* (panicked => not alive; the panic site sets alive := FALSE)
PanicImpliesDead ==
    \A v \in Server :
        panicked[v] => ~ alive[v]

\* --- Liveness halt detector (Family 4, MC-5, MC-6) ---
\* If any honest server panics, model has reached a process-death state.
NoHonestPanic ==
    \A v \in Honest : ~ panicked[v]

=============================================================================
