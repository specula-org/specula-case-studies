--------------------------- MODULE base ---------------------------
(***************************************************************************)
(* Solana Tower BFT — anza-xyz/agave                                       *)
(*                                                                         *)
(* Category A (Distributed / Message-Passing) with Byzantine threat model. *)
(* Sub-category: vote-lockout BFT (PoH-ordered slots + per-validator       *)
(* lockout towers + 38% switching threshold + 2/3 supermajority +          *)
(* equivocation-prone optimistic confirmation).                            *)
(*                                                                         *)
(* Scope (modeling-brief.md §7): consensus subsystem under core/src/ —     *)
(* `consensus.rs`, `consensus/tower_vote_state.rs`, `voting_service.rs`,   *)
(* `cluster_info_vote_listener.rs`,                                        *)
(* `optimistic_confirmation_verifier.rs`,                                  *)
(* `consensus/latest_validator_votes_for_frozen_banks.rs`,                 *)
(* `consensus/vote_stake_tracker.rs`. PoH/SVM/network/RPC out of scope.    *)
(*                                                                         *)
(* Bug families this spec is shaped around (modeling-brief.md §2):         *)
(*   F1  Tower State Bifurcation (vote_state vs last_vote)                 *)
(*   F2  Switch-Threshold Soundness Under Stray / Duplicate-Rolled-Back   *)
(*   F3  Crash-Window Across Tower File / Blockstore / Voting Channel     *)
(*   F4  Optimistic Confirmation Under Byzantine Equivocation             *)
(*   F5  Gossip-Claimed vs Replay-Verified Vote Inconsistency             *)
(***************************************************************************)

EXTENDS Naturals, Integers, FiniteSets, Sequences, TLC

CONSTANTS
    Honest,                 \* Set of honest validator pubkeys
    Byzantine,              \* Set of Byzantine validator pubkeys
    NullSlot,               \* Sentinel for "no slot" / Option::None
    NullHash,               \* Sentinel for Hash::default()
    Hashes,                 \* Set of distinct block hashes (excludes NullHash)
    MaxSlot,                \* Bound on slot numbers explored
    MaxLockoutHistory,      \* MAX_LOCKOUT_HISTORY (real constant = 31; small for MC)
    SwitchThresholdNum,     \* Numerator of 38% switch threshold
    SwitchThresholdDen,     \* Denominator
    SuperMajorityNum,       \* 2/3 numerator (vote stake threshold)
    SuperMajorityDen,
    OptimisticThresholdNum, \* 2/3 numerator (optimistic confirmation)
    OptimisticThresholdDen,
    Stake                   \* Function [Validator -> Nat]; per-pubkey stake

ASSUME
    /\ Honest \cap Byzantine = {}
    /\ MaxLockoutHistory \in Nat /\ MaxLockoutHistory >= 1
    /\ MaxSlot \in Nat /\ MaxSlot >= 1
    /\ NullSlot \notin 0..MaxSlot
    /\ NullHash \notin Hashes

Validators == Honest \cup Byzantine

(***************************************************************************)
(* Helper definitions                                                      *)
(***************************************************************************)

Slots      == 0..MaxSlot
SlotsOpt   == Slots \cup {NullSlot}
HashesOpt  == Hashes \cup {NullHash}

\* Total stake sum over a set
RECURSIVE SumOver(_, _)
SumOver(f, S) ==
    IF S = {} THEN 0
    ELSE LET v == CHOOSE x \in S : TRUE
         IN  f[v] + SumOver(f, S \ {v})

TotalStake == SumOver(Stake, Validators)
StakeOf(S) == SumOver(Stake, S)

\* Stake operators referenced from cfgs via `CONSTANT Stake <- MCStake*`.
\* TLC's config-file parser cannot consume function records inline.
MCStakeAllOne == [v \in Validators |-> 1]
MCStakeByz2   == [v \in Validators |-> IF v \in Byzantine THEN 2 ELSE 1]

\* Optional Min/Max
Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(S) == CHOOSE x \in S : \A y \in S : y >= x

\* 2^n for the lockout function
RECURSIVE Pow2(_)
Pow2(n) == IF n <= 0 THEN 1 ELSE 2 * Pow2(n - 1)

(***************************************************************************)
(* Block tree                                                              *)
(*                                                                         *)
(* PoH provides total order on slots; we model the slot lattice as a       *)
(* global block tree with `parent` links and `frozen` flag.  The Byzantine *)
(* leader may equivocate (publish two blocks for the same slot) so we key  *)
(* blocks by `(slot, hash)` (modeling-brief.md §1, last bullet of "Key     *)
(* architectural choices").                                                *)
(***************************************************************************)

BlockId      == [slot: Slots, hash: HashesOpt]
NullBlock    == [slot |-> NullSlot, hash |-> NullHash]
GenesisBlock == [slot |-> 0, hash |-> NullHash]

\* Lockout = [slot, confirmation_count]
Lockout == [slot: Slots, conf: 1..MaxLockoutHistory]

\* Vote record: a (slot, hash) annotation
VoteRecord       == [slot: SlotsOpt, hash: HashesOpt]
EmptyVoteRecord  == [slot |-> NullSlot, hash |-> NullHash]

\* Persisted tower fields (subset of SavedTower) we track on disk
DiskTower == [slot: SlotsOpt, hash: HashesOpt, root: SlotsOpt]

\* In-memory pending VoteOp::PushVote (voting_service.rs:23-28)
VotePushOp == [tx_slot:    SlotsOpt,
               tx_hash:    HashesOpt,
               saved_slot: SlotsOpt]

\* Default zero-state tower
EmptyTowerVoteState == [votes |-> <<>>, root |-> 0]

VARIABLES
    \* === Block tree ===
    blocks,                 \* SUBSET BlockId
    parent,                 \* [BlockId -> BlockId] — parent map
    frozen,                 \* [BlockId -> BOOLEAN]

    \* === Per-validator tower (Family 1) ===
    \* (consensus.rs:217-258, consensus/tower_vote_state.rs:11-14)
    tower_vote_state,       \* [Validator -> [votes: Seq(Lockout), root: SlotsOpt]]
    tower_last_vote,        \* [Validator -> VoteRecord]    (consensus.rs:223)
    stray_restored_slot,    \* [Validator -> SlotsOpt]      (consensus.rs:237)
    last_switch_threshold_check, \* [Validator -> SlotsOpt] (consensus.rs:238)

    \* === Persistence pipeline (Family 3) ===
    tower_on_disk,          \* [Validator -> DiskTower]
    blockstore_root,        \* [Validator -> SlotsOpt] — synchronously written
    voting_channel,         \* [Validator -> Seq(VotePushOp)] — VoteOp::PushVote queue
    tx_broadcasted,         \* [Validator -> SUBSET (Slots \X HashesOpt)] — TPU sends attempted
    crashed,                \* [Validator -> BOOLEAN]

    \* === Dual vote sources (Family 5) ===
    replay_votes,           \* [observer -> [voter -> VoteRecord]]
    gossip_votes,           \* [observer -> [voter -> VoteRecord]]

    \* === Optimistic confirmation per-(slot, hash) tracker (Family 4) ===
    oc_votes,               \* [<<slot, hash>> -> SUBSET Validators]
    oc_notifications,       \* SUBSET (Slots \X HashesOpt)
    oc_rollbacks            \* SUBSET (Slots \X HashesOpt)

blockVars      == <<blocks, parent, frozen>>
towerVars      == <<tower_vote_state, tower_last_vote, stray_restored_slot,
                    last_switch_threshold_check>>
persistVars    == <<tower_on_disk, blockstore_root, voting_channel,
                    tx_broadcasted, crashed>>
voteSourceVars == <<replay_votes, gossip_votes>>
ocVars         == <<oc_votes, oc_notifications, oc_rollbacks>>

vars == <<blockVars, towerVars, persistVars, voteSourceVars, ocVars>>

(***************************************************************************)
(* Initial state                                                           *)
(***************************************************************************)

Init ==
    /\ blocks = {GenesisBlock}
    /\ parent = (GenesisBlock :> NullBlock)
    /\ frozen = (GenesisBlock :> TRUE)
    /\ tower_vote_state            = [v \in Validators |-> EmptyTowerVoteState]
    /\ tower_last_vote             = [v \in Validators |-> EmptyVoteRecord]
    /\ stray_restored_slot         = [v \in Validators |-> NullSlot]
    /\ last_switch_threshold_check = [v \in Validators |-> NullSlot]
    /\ tower_on_disk               = [v \in Validators |->
                                        [slot |-> NullSlot, hash |-> NullHash, root |-> 0]]
    /\ blockstore_root             = [v \in Validators |-> 0]
    /\ voting_channel              = [v \in Validators |-> <<>>]
    /\ tx_broadcasted              = [v \in Validators |-> {}]
    /\ crashed                     = [v \in Validators |-> FALSE]
    /\ replay_votes = [obs \in Validators |->
                          [voter \in Validators |-> EmptyVoteRecord]]
    /\ gossip_votes = [obs \in Validators |->
                          [voter \in Validators |-> EmptyVoteRecord]]
    /\ oc_votes         = << >>            \* empty function (no entries yet)
    /\ oc_notifications = {}
    /\ oc_rollbacks     = {}

(***************************************************************************)
(* Block tree predicates                                                   *)
(***************************************************************************)

\* Bounded ancestor walk via parent chain
RECURSIVE IsAncestor(_, _, _)
IsAncestor(anc, b, depth) ==
    IF depth = 0 THEN FALSE
    ELSE IF b = NullBlock THEN FALSE
    ELSE IF parent[b] = NullBlock THEN FALSE
    ELSE IF parent[b] = anc THEN TRUE
    ELSE IsAncestor(anc, parent[b], depth - 1)

StrictAncestor(anc, b) ==
    /\ anc \in blocks
    /\ b \in blocks
    /\ IsAncestor(anc, b, MaxSlot + 1)

Descendant(d, anc)     == StrictAncestor(anc, d)
SameOrDescendant(a, b) == a = b \/ Descendant(a, b)

\* Set of blocks on the same fork as `b` (b plus its ancestors)
RECURSIVE AncestorChain(_, _)
AncestorChain(b, depth) ==
    IF depth = 0 \/ b = NullBlock THEN {}
    ELSE IF b \notin blocks THEN {}
    ELSE {b} \cup
         (IF parent[b] = NullBlock THEN {}
          ELSE AncestorChain(parent[b], depth - 1))

(***************************************************************************)
(* TowerVoteState helpers — modeling tower_vote_state.rs                   *)
(***************************************************************************)

\* last_voted_slot of vote_state.votes (tower_vote_state.rs:25-27)
LastVotedSlotVS(vs) ==
    IF vs.votes = <<>> THEN NullSlot ELSE vs.votes[Len(vs.votes)].slot

\* last_voted_slot of last_vote (consensus.rs:749-755)
LastVotedSlotLV(lv) == lv.slot

\* Lockout end (lockout = 2^conf -> end = slot + 2^conf)
LockoutEnd(lo) == lo.slot + Pow2(lo.conf)

\* Predicate: lockout still active for next_slot
IsLockedOutAtSlot(lo, next_slot) == next_slot <= LockoutEnd(lo)

\* pop_expired_votes loop (tower_vote_state.rs:60-68)
RECURSIVE PopExpired(_, _)
PopExpired(votes, next_slot) ==
    IF votes = <<>> THEN <<>>
    ELSE LET back == votes[Len(votes)] IN
         IF IsLockedOutAtSlot(back, next_slot)
         THEN votes
         ELSE PopExpired(SubSeq(votes, 1, Len(votes) - 1), next_slot)

\* double_lockouts (tower_vote_state.rs:70-84)
DoubleLockouts(votes) ==
    LET d == Len(votes) IN
    [i \in 1..d |->
        IF d > (i - 1) + votes[i].conf
        THEN [votes[i] EXCEPT !.conf = @ + 1]
        ELSE votes[i]]

\* process_next_vote_slot (tower_vote_state.rs:36-54)
ProcessNextVoteSlot(vs, next_slot) ==
    LET last == LastVotedSlotVS(vs) IN
    IF last /= NullSlot /\ next_slot <= last
    THEN vs
    ELSE LET popped == PopExpired(vs.votes, next_slot) IN
         LET full == (Len(popped) = MaxLockoutHistory) IN
         LET new_root == IF full THEN popped[1].slot ELSE vs.root IN
         LET trimmed == IF full THEN SubSeq(popped, 2, Len(popped)) ELSE popped IN
         LET new_lo == [slot |-> next_slot, conf |-> 1] IN
         LET stacked == Append(trimmed, new_lo) IN
         [votes |-> DoubleLockouts(stacked), root |-> new_root]

(***************************************************************************)
(* is_locked_out (consensus.rs:827-856)                                    *)
(***************************************************************************)

IsRecentVS(vs, slot) ==
    LET lvs == LastVotedSlotVS(vs) IN
    IF lvs /= NullSlot
    THEN slot > lvs                              \* line 805-809
    ELSE IF vs.root /= NullSlot
         THEN slot > vs.root
         ELSE TRUE

IsLockedOut(v, slotCand, ancSlots) ==
    LET vs == tower_vote_state[v] IN
    IF ~ IsRecentVS(vs, slotCand) THEN TRUE
    ELSE LET sim == ProcessNextVoteSlot(vs, slotCand) IN
         \E i \in 1..Len(sim.votes) :
             /\ slotCand /= sim.votes[i].slot
             /\ sim.votes[i].slot \notin ancSlots

(***************************************************************************)
(* Switch threshold check (consensus.rs:959-1273) — split per branch      *)
(*                                                                         *)
(* NormalLockedOutStake captures the locked-out-stake accounting           *)
(* combining replay (line 1117-1216) and optionally gossip (1218-1268).   *)
(***************************************************************************)

\* Returns set of validator pubkeys whose votes count toward locked-out stake.
ReplayContribs(observer, switch_slot, last_voted_slot) ==
    { voter \in Validators :
        LET rv == replay_votes[observer][voter] IN
        /\ rv.slot /= NullSlot
        /\ \E vb \in blocks :
             /\ vb.slot = rv.slot
             /\ \E lb \in blocks :
                  /\ lb.slot = last_voted_slot
                  /\ ~ Descendant(vb, lb)             \* candidate not on last_vote fork
                  /\ \E sb \in blocks :
                       /\ sb.slot = switch_slot
                       /\ ~ Descendant(sb, vb)         \* switch_slot not below candidate
    }

GossipContribs(observer, switch_slot, last_voted_slot) ==
    { voter \in Validators :
        LET gv == gossip_votes[observer][voter] IN
        /\ gv.slot /= NullSlot
        /\ gv.slot > last_voted_slot                \* line 1228 filter
        /\ \E vb \in blocks :
             /\ vb.slot = gv.slot
             /\ \E lb \in blocks :
                  /\ lb.slot = last_voted_slot
                  /\ ~ Descendant(vb, lb)
    }

NormalLockedOutStake(observer, switch_slot, last_voted_slot, includeGossip) ==
    LET R == ReplayContribs(observer, switch_slot, last_voted_slot)
        G == IF includeGossip
             THEN GossipContribs(observer, switch_slot, last_voted_slot)
             ELSE {}
    IN  StakeOf(R \cup G)

NormalSwitchProof(observer, switch_slot, last_voted_slot, includeGossip) ==
    NormalLockedOutStake(observer, switch_slot, last_voted_slot, includeGossip)
        * SwitchThresholdDen
        > TotalStake * SwitchThresholdNum

(***************************************************************************)
(* OC threshold predicate                                                  *)
(***************************************************************************)

OCThresholdReached(slot, hash) ==
    LET sh == <<slot, hash>> IN
    /\ sh \in DOMAIN oc_votes
    /\ StakeOf(oc_votes[sh]) * OptimisticThresholdDen
       > TotalStake * OptimisticThresholdNum

(***************************************************************************)
(* Actions — annotated with code locations                                *)
(***************************************************************************)

\* === Block production ===

\* extend_block: leader for slot s appends a new block whose parent is some
\* existing block. Models PoH-ordered slot production with possible
\* equivocation (Byzantine leader emits two blocks for same slot,
\* different hash). Used by Family 4 baseline.
ExtendBlock(slot, h, par) ==
    /\ slot \in 1..MaxSlot
    /\ h \in Hashes
    /\ par \in blocks
    /\ par.slot < slot
    /\ LET nb == [slot |-> slot, hash |-> h] IN
        /\ nb \notin blocks
        /\ blocks' = blocks \cup {nb}
        /\ parent' = parent @@ (nb :> par)
        /\ frozen' = frozen @@ (nb :> FALSE)
    /\ UNCHANGED <<towerVars, persistVars, voteSourceVars, ocVars>>

\* freeze_bank: replay finishes for a block.
FreezeBank(b) ==
    /\ b \in blocks
    /\ b.slot > 0
    /\ ~ frozen[b]
    /\ frozen' = [frozen EXCEPT ![b] = TRUE]
    /\ UNCHANGED <<blocks, parent, towerVars, persistVars, voteSourceVars,
                  ocVars>>

(***************************************************************************)
(* Family 1: tower mutation actions                                        *)
(***************************************************************************)

\* RecordBankVote (consensus.rs:700-735): in-memory vote.
\* Updates BOTH vote_state and last_vote (line 720-721).
RecordBankVote(v, b) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ b \in blocks
    /\ frozen[b]
    /\ b.slot > 0
    /\ LET vs == tower_vote_state[v]
           ancSlots == { a.slot : a \in AncestorChain(b, MaxSlot + 1) }
       IN  /\ ~ IsLockedOut(v, b.slot, ancSlots)               \* consensus.rs:827
           /\ LET old_last == LastVotedSlotVS(vs) IN
              /\ \/ old_last = NullSlot
                 \/ b.slot > old_last                          \* line 706-714
              /\ LET new_vs == ProcessNextVoteSlot(vs, b.slot) \* line 720
                 IN  /\ tower_vote_state' = [tower_vote_state EXCEPT ![v] = new_vs]
                     /\ tower_last_vote' =
                          [tower_last_vote EXCEPT
                             ![v] = [slot |-> b.slot, hash |-> b.hash]]  \* line 721
    /\ UNCHANGED <<blockVars, stray_restored_slot, last_switch_threshold_check,
                  persistVars, voteSourceVars, ocVars>>

\* AdoptOnChainVoteState — overwrites vote_state with on-chain VoteState.
\* (initialize_lockouts_from_bank consensus.rs:1652-1670 +
\* compute_bank_stats post-#33341.) Crucially does NOT touch tower_last_vote
\* (line 1659 only writes vote_state). Models the #32944 latent bifurcation.
\*
\* `adopted_slot` is the most-recent slot in the adopted vote_state — the
\* adversary may select any frozen block (including those Byzantine-included).
AdoptOnChainVoteState(v, b, adopted_slot) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ b \in blocks
    /\ frozen[b]
    /\ adopted_slot \in 1..MaxSlot
    /\ adopted_slot >= tower_vote_state[v].root
    /\ tower_vote_state' =
         [tower_vote_state EXCEPT
            ![v] = [votes |-> <<[slot |-> adopted_slot, conf |-> 1]>>,
                    root  |-> @.root]]
    \* IMPORTANT: tower_last_vote NOT updated — bifurcation seed.
    /\ UNCHANGED <<blockVars, tower_last_vote, stray_restored_slot,
                  last_switch_threshold_check, persistVars, voteSourceVars,
                  ocVars>>

\* UpdateLastVoteFromVoteState (consensus.rs:686-698): #32944 fix —
\* re-derive last_vote.slot from current vote_state.last_voted_slot.
\* Exposed as separate action so the scheduler may interleave it (or omit
\* it, recreating the bug).
UpdateLastVoteFromVoteState(v) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ LET vs == tower_vote_state[v]
           lv_slot == LastVotedSlotVS(vs)
       IN  tower_last_vote' =
              [tower_last_vote EXCEPT
                 ![v] = [slot |-> lv_slot,
                         hash |-> tower_last_vote[v].hash]]
    /\ UNCHANGED <<blockVars, tower_vote_state, stray_restored_slot,
                  last_switch_threshold_check, persistVars, voteSourceVars,
                  ocVars>>

\* SetStrayLastVote: models adjust_lockouts_after_replay path
\* (consensus.rs:1646) where a restored last vote becomes "stray".
SetStrayLastVote(v) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ LET last == LastVotedSlotLV(tower_last_vote[v]) IN
       /\ last /= NullSlot
       /\ stray_restored_slot[v] = NullSlot
       /\ stray_restored_slot' = [stray_restored_slot EXCEPT ![v] = last]
    /\ UNCHANGED <<blockVars, tower_vote_state, tower_last_vote,
                  last_switch_threshold_check, persistVars, voteSourceVars,
                  ocVars>>

(***************************************************************************)
(* Family 2: switch-threshold decision actions, split by relaxation branch*)
(***************************************************************************)

\* CheckSwitch_Normal (consensus.rs:1117-1273)
CheckSwitchNormal(v, switch_slot) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ LET last_slot == LastVotedSlotLV(tower_last_vote[v])
       IN  /\ last_slot /= NullSlot                \* line 970-972: not short-circuited
           /\ stray_restored_slot[v] /= last_slot  \* line 1077: not stray branch
           /\ \E b \in blocks : b.slot = switch_slot
           /\ NormalSwitchProof(v, switch_slot, last_slot, TRUE)
           /\ last_switch_threshold_check' =
                 [last_switch_threshold_check EXCEPT ![v] = switch_slot]
    /\ UNCHANGED <<blockVars, tower_vote_state, tower_last_vote,
                  stray_restored_slot, persistVars, voteSourceVars,
                  ocVars>>

\* CheckSwitch_StrayEmpty (consensus.rs:881-898 stray branch +
\* 1076-1090 empty_ancestors_due_to_minor_unsynced_ledger fallback).
CheckSwitchStrayEmpty(v, switch_slot) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ LET last_slot == LastVotedSlotLV(tower_last_vote[v]) IN
       /\ last_slot /= NullSlot
       /\ stray_restored_slot[v] = last_slot       \* is_stray_last_vote() = TRUE
       /\ \E b \in blocks : b.slot = switch_slot
       /\ \* Adversary-friendly: any (slot > last) gossip claim contributes.
          \* Faithfully matches line 881-898 "always Some(true)" branch.
          LET StrayGossipContrib ==
                { voter \in Validators :
                    /\ gossip_votes[v][voter].slot /= NullSlot
                    /\ gossip_votes[v][voter].slot > last_slot }
              stake == StakeOf(StrayGossipContrib)
          IN  stake * SwitchThresholdDen > TotalStake * SwitchThresholdNum
       /\ last_switch_threshold_check' =
              [last_switch_threshold_check EXCEPT ![v] = switch_slot]
    /\ UNCHANGED <<blockVars, tower_vote_state, tower_last_vote,
                  stray_restored_slot, persistVars, voteSourceVars,
                  ocVars>>

\* CheckSwitch_DuplicateFreebie (consensus.rs:1058-1073)
\* Returns SwitchProof(Hash::default()) with ZERO stake locked out when
\* progress.get_hash(last_voted_slot) is None or differs.  Misfires when
\* the validator's last vote was rooted normally (slot <= blockstore_root).
CheckSwitchDuplicateFreebie(v, switch_slot) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ LET last_slot == LastVotedSlotLV(tower_last_vote[v]) IN
       /\ last_slot /= NullSlot
       /\ last_slot <= blockstore_root[v]          \* triggers unwrap_or(true) branch
       /\ \E b \in blocks : b.slot = switch_slot
       /\ last_switch_threshold_check' =
              [last_switch_threshold_check EXCEPT ![v] = switch_slot]
    /\ UNCHANGED <<blockVars, tower_vote_state, tower_last_vote,
                  stray_restored_slot, persistVars, voteSourceVars,
                  ocVars>>

(***************************************************************************)
(* Family 3: persistence pipeline split into the four steps                *)
(***************************************************************************)

\* SetBlockstoreRoot — synchronous (consensus.rs:1748-1752).
\* check_and_handle_new_root → blockstore.set_roots + bank_forks.set_root.
SetBlockstoreRoot(v) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ tower_vote_state[v].root /= NullSlot
    /\ tower_vote_state[v].root > blockstore_root[v]
    /\ blockstore_root' = [blockstore_root EXCEPT ![v] = tower_vote_state[v].root]
    /\ UNCHANGED <<blockVars, towerVars, tower_on_disk, voting_channel,
                  tx_broadcasted, crashed, voteSourceVars, ocVars>>

\* EnqueueVoteOp (replay_stage push_vote): push VoteOp::PushVote.
EnqueueVoteOp(v) ==
    /\ ~ crashed[v]
    /\ v \in Honest
    /\ LET lv == tower_last_vote[v] IN
       /\ lv.slot /= NullSlot
       /\ voting_channel' =
            [voting_channel EXCEPT
               ![v] = Append(@,
                       [tx_slot    |-> lv.slot,
                        tx_hash    |-> lv.hash,
                        saved_slot |-> lv.slot])]
    /\ UNCHANGED <<blockVars, towerVars, tower_on_disk, blockstore_root,
                  tx_broadcasted, crashed, voteSourceVars, ocVars>>

\* VotingServiceStore (voting_service.rs:114-122): tower_storage.store
\* writes the current in-memory tower (tower_last_vote + vote_state.root)
\* to disk.  This is independent of voting_channel because the production
\* code writes the SavedTower argument passed in, not the queue head;
\* the queue head is what the VotingService thread *just popped* but the
\* persistence target is the current tower snapshot.  Modeling Store
\* independently of the queue lets the scheduler interleave it with
\* SendTx in either order (matches both the per-slot ordering of the
\* VotingService thread and the harness's batched end-of-scenario save).
VotingServiceStore(v) ==
    /\ ~ crashed[v]
    /\ tower_last_vote[v].slot /= NullSlot
    /\ tower_on_disk' =
         [tower_on_disk EXCEPT
            ![v] = [slot |-> tower_last_vote[v].slot,
                    hash |-> tower_last_vote[v].hash,
                    root |-> tower_vote_state[v].root]]
    /\ UNCHANGED <<blockVars, towerVars, blockstore_root, voting_channel,
                  tx_broadcasted, crashed, voteSourceVars, ocVars>>

\* VotingServiceSendTx (voting_service.rs:131-150): broadcasts the vote
\* transaction to upcoming leaders. After sending we POP the queue head.
VotingServiceSendTx(v) ==
    /\ ~ crashed[v]
    /\ voting_channel[v] /= <<>>
    /\ LET op == voting_channel[v][1] IN
       /\ tx_broadcasted' =
            [tx_broadcasted EXCEPT
               ![v] = @ \cup {<<op.tx_slot, op.tx_hash>>}]
       /\ voting_channel' = [voting_channel EXCEPT ![v] = Tail(@)]
    /\ UNCHANGED <<blockVars, towerVars, tower_on_disk, blockstore_root,
                  crashed, voteSourceVars, ocVars>>

\* Crash(v): in-memory state lost; persisted state retained.
Crash(v) ==
    /\ v \in Honest
    /\ ~ crashed[v]
    /\ crashed' = [crashed EXCEPT ![v] = TRUE]
    /\ tower_vote_state' = [tower_vote_state EXCEPT ![v] = EmptyTowerVoteState]
    /\ tower_last_vote'  = [tower_last_vote EXCEPT ![v] = EmptyVoteRecord]
    /\ stray_restored_slot' = [stray_restored_slot EXCEPT ![v] = NullSlot]
    /\ last_switch_threshold_check' =
        [last_switch_threshold_check EXCEPT ![v] = NullSlot]
    /\ voting_channel' = [voting_channel EXCEPT ![v] = <<>>]
    /\ UNCHANGED <<blockVars, tower_on_disk, blockstore_root,
                  tx_broadcasted, voteSourceVars, ocVars>>

\* Recover(v): reload from disk. Models replay_stage::load_tower
\* (replay_stage.rs:1246-1274) + Tower::restore (consensus.rs:1688-1690).
Recover(v) ==
    /\ v \in Honest
    /\ crashed[v]
    /\ crashed' = [crashed EXCEPT ![v] = FALSE]
    /\ LET disk == tower_on_disk[v] IN
       /\ tower_vote_state' =
            [tower_vote_state EXCEPT
               ![v] =
                  IF disk.slot = NullSlot THEN EmptyTowerVoteState
                  ELSE [votes |-> <<[slot |-> disk.slot, conf |-> 1]>>,
                        root |-> disk.root]]
       /\ tower_last_vote' =
            [tower_last_vote EXCEPT
               ![v] = [slot |-> disk.slot, hash |-> disk.hash]]
    /\ stray_restored_slot' =
        [stray_restored_slot EXCEPT
           ![v] = IF tower_on_disk[v].slot = NullSlot THEN NullSlot
                  ELSE tower_on_disk[v].slot]
    /\ last_switch_threshold_check' =
        [last_switch_threshold_check EXCEPT ![v] = NullSlot]
    /\ UNCHANGED <<blockVars, tower_on_disk, blockstore_root, voting_channel,
                  tx_broadcasted, voteSourceVars, ocVars>>

(***************************************************************************)
(* Family 5: gossip / replay vote propagation                              *)
(***************************************************************************)

\* ReplayLandedVote — observer replays a block containing a TowerSync.
\* Updates max_replay_frozen_votes (latest_validator_votes_for_frozen_banks.rs:22-95).
\* Note: the production system relies on signature verification, not on
\* tracking which validators have explicitly broadcast.  The spec follows
\* suit and does not require the voter's broadcast to be observed first;
\* honest broadcasts happen upstream via the leader pipeline that this
\* model abstracts as a fair network.
ReplayLandedVote(observer, voter, slot, hash) ==
    /\ ~ crashed[observer]
    /\ observer \in Honest
    /\ voter \in Validators
    /\ \E b \in blocks : b.slot = slot /\ b.hash = hash /\ frozen[b]
    /\ LET prev == replay_votes[observer][voter].slot IN
       prev = NullSlot \/ slot > prev
    /\ replay_votes' =
         [replay_votes EXCEPT
            ![observer] =
               [@ EXCEPT ![voter] = [slot |-> slot, hash |-> hash]]]
    /\ UNCHANGED <<blockVars, towerVars, persistVars, gossip_votes, ocVars>>

\* GossipReceivedVote — observer ingests a (slot, hash) gossip claim.
\* Same rationale as ReplayLandedVote: signature verification (modeled
\* implicitly as unforgeable signatures) is what authorises the vote.
GossipReceivedVote(observer, voter, slot, hash) ==
    /\ ~ crashed[observer]
    /\ observer \in Honest
    /\ voter \in Validators
    /\ slot \in 1..MaxSlot
    /\ LET prev == gossip_votes[observer][voter].slot IN
       prev = NullSlot \/ slot > prev
    /\ gossip_votes' =
         [gossip_votes EXCEPT
            ![observer] =
               [@ EXCEPT ![voter] = [slot |-> slot, hash |-> hash]]]
    /\ UNCHANGED <<blockVars, towerVars, persistVars, replay_votes, ocVars>>

\* ByzGossipFakeVote — Byzantine validator gossips a (slot, hash) claim
\* that never lands as a transaction. Models brief §6.1 MC2/MC6 attack.
ByzGossipFakeVote(byz, observer, slot, hash) ==
    /\ ~ crashed[observer]
    /\ byz \in Byzantine
    /\ observer \in Honest
    /\ slot \in 1..MaxSlot
    /\ LET prev == gossip_votes[observer][byz].slot IN
       prev = NullSlot \/ slot > prev
    /\ gossip_votes' =
         [gossip_votes EXCEPT
            ![observer] =
               [@ EXCEPT ![byz] = [slot |-> slot, hash |-> hash]]]
    /\ UNCHANGED <<blockVars, towerVars, persistVars, replay_votes, ocVars>>

(***************************************************************************)
(* Family 4: optimistic confirmation                                       *)
(***************************************************************************)

\* TrackOptimisticVote — voter contributes its full stake to per-hash bucket.
\* Per-hash bucket means a Byzantine equivocator counts in BOTH (slot, h_A) and (slot, h_B).
\* Broadcast/observation is not tracked per-voter: any signed vote that
\* reaches the listener thread contributes, regardless of who originated it.
TrackOptimisticVote(voter, slot, hash) ==
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    /\ voter \in Validators
    /\ LET sh == <<slot, hash>>
           cur == IF sh \in DOMAIN oc_votes THEN oc_votes[sh] ELSE {}
       IN  /\ voter \notin cur
           /\ oc_votes' =
                IF sh \in DOMAIN oc_votes
                THEN [oc_votes EXCEPT ![sh] = cur \cup {voter}]
                ELSE oc_votes @@ (sh :> {voter})
    /\ UNCHANGED <<blockVars, towerVars, persistVars, voteSourceVars,
                  oc_notifications, oc_rollbacks>>

\* EmitOCNotification — bucket has crossed 2/3 threshold.
EmitOCNotification(slot, hash) ==
    /\ slot \in 1..MaxSlot
    /\ hash \in Hashes
    /\ <<slot, hash>> \in DOMAIN oc_votes
    /\ <<slot, hash>> \notin oc_notifications
    /\ OCThresholdReached(slot, hash)
    /\ oc_notifications' = oc_notifications \cup {<<slot, hash>>}
    /\ UNCHANGED <<blockVars, towerVars, persistVars, voteSourceVars,
                  oc_votes, oc_rollbacks>>

\* RollbackOC — observer notes that a different (slot, h') OC fired,
\* implying this hash's OC was rolled back. Faithfully models verifier's
\* observation-only behaviour (optimistic_confirmation_verifier.rs:88-135).
RollbackOC(slot, hash) ==
    /\ <<slot, hash>> \in oc_notifications
    /\ \E sh2 \in oc_notifications :
         sh2[1] = slot /\ sh2[2] /= hash
    /\ <<slot, hash>> \notin oc_rollbacks
    /\ oc_rollbacks' = oc_rollbacks \cup {<<slot, hash>>}
    /\ UNCHANGED <<blockVars, towerVars, persistVars, voteSourceVars,
                  oc_votes, oc_notifications>>

(***************************************************************************)
(* Byzantine voting actions                                                *)
(***************************************************************************)

\* ByzantineEquivocate — Byzantine validator signs two (slot, h_A), (slot, h_B)
\* tower-syncs. Both txs are broadcast.
ByzantineEquivocate(byz, slot, hA, hB) ==
    /\ byz \in Byzantine
    /\ slot \in 1..MaxSlot
    /\ hA \in Hashes /\ hB \in Hashes
    /\ hA /= hB
    /\ tx_broadcasted' =
         [tx_broadcasted EXCEPT
            ![byz] = @ \cup {<<slot, hA>>, <<slot, hB>>}]
    /\ UNCHANGED <<blockVars, towerVars, tower_on_disk, blockstore_root,
                  voting_channel, crashed, voteSourceVars, ocVars>>

(***************************************************************************)
(* Next                                                                    *)
(***************************************************************************)

Next ==
    \/ \E slot \in 1..MaxSlot, h \in Hashes, par \in blocks :
           ExtendBlock(slot, h, par)
    \/ \E b \in blocks : FreezeBank(b)
    \/ \E v \in Honest, b \in blocks : RecordBankVote(v, b)
    \/ \E v \in Honest, b \in blocks, s \in 1..MaxSlot :
           AdoptOnChainVoteState(v, b, s)
    \/ \E v \in Honest : UpdateLastVoteFromVoteState(v)
    \/ \E v \in Honest : SetStrayLastVote(v)
    \/ \E v \in Honest, s \in 1..MaxSlot : CheckSwitchNormal(v, s)
    \/ \E v \in Honest, s \in 1..MaxSlot : CheckSwitchStrayEmpty(v, s)
    \/ \E v \in Honest, s \in 1..MaxSlot : CheckSwitchDuplicateFreebie(v, s)
    \/ \E v \in Honest : SetBlockstoreRoot(v)
    \/ \E v \in Honest : EnqueueVoteOp(v)
    \/ \E v \in Honest : VotingServiceStore(v)
    \/ \E v \in Honest : VotingServiceSendTx(v)
    \/ \E v \in Honest : Crash(v)
    \/ \E v \in Honest : Recover(v)
    \/ \E obs \in Honest, voter \in Validators, s \in 1..MaxSlot, h \in Hashes :
          ReplayLandedVote(obs, voter, s, h)
    \/ \E obs \in Honest, voter \in Validators, s \in 1..MaxSlot, h \in Hashes :
          GossipReceivedVote(obs, voter, s, h)
    \/ \E byz \in Byzantine, obs \in Honest, s \in 1..MaxSlot, h \in Hashes :
          ByzGossipFakeVote(byz, obs, s, h)
    \/ \E voter \in Validators, s \in 1..MaxSlot, h \in Hashes :
          TrackOptimisticVote(voter, s, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : EmitOCNotification(s, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : RollbackOC(s, h)
    \/ \E byz \in Byzantine, s \in 1..MaxSlot :
          \E hA \in Hashes : \E hB \in Hashes :
              ByzantineEquivocate(byz, s, hA, hB)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Invariants                                                              *)
(***************************************************************************)

\* === 1. Type / structural ===

TypeOK ==
    /\ blocks \subseteq BlockId
    /\ DOMAIN parent = blocks
    /\ DOMAIN frozen = blocks
    /\ DOMAIN tower_vote_state = Validators
    /\ DOMAIN tower_last_vote = Validators
    /\ DOMAIN crashed = Validators
    /\ DOMAIN blockstore_root = Validators

BlockstoreRootMonotonic ==
    \A v \in Validators : blockstore_root[v] \in Slots

\* Each in-blocks block has a parent recorded; non-genesis parent strict.
FrozenBlocksHaveValidParents ==
    \A b \in blocks :
       b /= GenesisBlock => parent[b] \in blocks /\ parent[b].slot < b.slot

\* === 2. Standard Tower BFT safety ===

\* LockoutSafety (brief §5)
\* For any two votes by honest v at slots s1 < s2, either s2 > s1 + 2^c1 OR
\* s2's fork contains s1.  We check the current vote_state stack pairwise.
\* The newer vote b2 must be a same-or-descendant of the older vote b1
\* (i.e., on the same fork going downward).
LockoutSafety ==
    \A v \in Honest :
        LET vs == tower_vote_state[v].votes IN
        \A i, j \in DOMAIN vs :
            i < j =>
              \/ vs[j].slot > LockoutEnd(vs[i])
              \/ \E b1 \in blocks, b2 \in blocks :
                   /\ b1.slot = vs[i].slot
                   /\ b2.slot = vs[j].slot
                   /\ SameOrDescendant(b2, b1)

\* === 3. Bug-family invariants ===

\* F1 — TowerSyncConsistency (brief §5)
TowerSyncConsistency ==
    \A v \in Honest :
        ~ crashed[v] =>
            LastVotedSlotLV(tower_last_vote[v])
              = LastVotedSlotVS(tower_vote_state[v])

\* F2 — SwitchProofSoundness (brief §5)
SwitchProofSoundness ==
    \A v \in Honest :
        last_switch_threshold_check[v] /= NullSlot =>
          LET sw == last_switch_threshold_check[v]
              lv == LastVotedSlotLV(tower_last_vote[v]) IN
          \/ lv = NullSlot
          \/ stray_restored_slot[v] = lv          \* stray branch — handled separately
          \/ \E b \in blocks :
               b.slot = sw
               /\ \E lb \in blocks :
                    lb.slot = lv
                    /\ SameOrDescendant(b, lb)
          \/ NormalLockedOutStake(v, sw, lv, FALSE) * SwitchThresholdDen
                > TotalStake * SwitchThresholdNum

\* F2 — StrayBranchSwitchProofGuard (brief §5)
StrayBranchSwitchProofGuard ==
    \A v \in Honest :
        (last_switch_threshold_check[v] /= NullSlot
         /\ stray_restored_slot[v] /= NullSlot
         /\ stray_restored_slot[v]
            = LastVotedSlotLV(tower_last_vote[v])) =>
           \A voter \in Validators :
              gossip_votes[v][voter].slot
                > LastVotedSlotLV(tower_last_vote[v]) =>
              ~ \E vb \in blocks, sb \in blocks :
                  /\ vb.slot = gossip_votes[v][voter].slot
                  /\ sb.slot = last_switch_threshold_check[v]
                  /\ SameOrDescendant(vb, sb)

\* F3 — PostCrashNoDoubleVote (brief §5)
PostCrashNoDoubleVote ==
    \A v \in Honest :
        ~ crashed[v] =>
            LET broadcast == tx_broadcasted[v]
                last == LastVotedSlotLV(tower_last_vote[v]) IN
            broadcast = {} \/ last = NullSlot
              \/ last >= Max({pair[1] : pair \in broadcast})

\* F3 — RPCRootIntegrity (brief §5)
RPCRootIntegrity ==
    \A v \in Honest :
        blockstore_root[v] > 0 =>
          \E pair \in tx_broadcasted[v] : pair[1] >= blockstore_root[v]

\* F4 — OCSingleHash (brief §5)
OCSingleHash ==
    LET ByzantineStake == StakeOf(Byzantine) IN
    \A s \in 1..MaxSlot :
       Cardinality({ pair \in oc_notifications : pair[1] = s }) <= 1
       \/ ByzantineStake * 3 >= TotalStake

\* F4 — OCImpliesNoRollback (brief §5)
OCImpliesNoRollback ==
    LET ByzantineStake == StakeOf(Byzantine) IN
    oc_rollbacks = {} \/ ByzantineStake * 3 >= TotalStake

\* F5 — GossipReplayConsistency (brief §5, weakened to model-checkable form)
GossipReplayConsistency ==
    \A v \in Honest :
        last_switch_threshold_check[v] /= NullSlot =>
          LET sw == last_switch_threshold_check[v]
              lv == LastVotedSlotLV(tower_last_vote[v]) IN
          \/ lv = NullSlot
          \/ NormalSwitchProof(v, sw, lv, FALSE)        \* replay alone justifies
          \/ stray_restored_slot[v] = lv                \* stray branch covered separately
          \/ \E byz \in Byzantine : gossip_votes[v][byz].slot > lv

\* F3 — ReconcileNonPanic (brief §5)
ReconcileNonPanic ==
    \A v \in Honest :
        tower_on_disk[v].root /= NullSlot
        /\ tower_on_disk[v].root > blockstore_root[v] =>
          \E b \in blocks : b.slot = tower_on_disk[v].root

============================================================================
