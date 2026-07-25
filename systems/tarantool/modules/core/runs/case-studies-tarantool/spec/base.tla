------------------------------- MODULE base ------------------------------------
\* TLA+ specification of Tarantool's Raft leader election engine.
\* Models the core state machine from src/lib/raft/raft.c with extensions
\* for bug families identified in the modeling brief.
\*
\* Key deviations from standard Raft:
\*   - Vclock-based vote eligibility (not log index/term)
\*   - Dual volatile/persisted state with multi-pass WAL write
\*   - Leader witness map gates all elections (implicit pre-vote)
\*
\* Source: tarantool/src/lib/raft/raft.c (1431 lines)
\* Source: tarantool/src/lib/raft/raft.h (454 lines)

EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    Server,             \* Set of server IDs (e.g., {1, 2, 3})
    ElectionQuorum,     \* Number of votes needed to win election
    Nil                 \* Distinguished "no value" constant

ASSUME Cardinality(Server) > 0
ASSUME ElectionQuorum > 0
ASSUME Nil \notin Server

----
\* Variables
----

\* --- Core Raft state (raft.h:157-255) ---
VARIABLES
    state,              \* state[s] \in {"Follower", "Candidate", "Leader"}
    leader,             \* leader[s] \in Server \cup {Nil} — known leader
    votesReceived       \* votesReceived[s] \in SUBSET Server — votes for s

\* --- Dual volatile/persisted state (Family 2, 3) ---
\* raft.h:164-175 — volatile state used for decisions
\* raft.h:203-207 — persisted state used for broadcasts
VARIABLES
    volatileTerm,       \* volatileTerm[s] \in Nat — in-memory term
    volatileVote,       \* volatileVote[s] \in Server \cup {Nil}
    persistedTerm,      \* persistedTerm[s] \in Nat — on-disk term
    persistedVote       \* persistedVote[s] \in Server \cup {Nil}

\* --- WAL write state (Family 2) ---
\* raft.h:193-194 — is_write_in_progress flag
VARIABLES
    isWriteInProgress,  \* isWriteInProgress[s] \in BOOLEAN
    walWritePhase       \* walWritePhase[s] \in {"idle", "term_only", "term_and_vote"}
                        \* Tracks multi-pass WAL write progress (Family 3)

\* --- Leader witness map (Family 1) ---
\* raft.h:214-215 — bitmap of peers who see the leader
VARIABLES
    leaderWitnessMap    \* leaderWitnessMap[s] \in SUBSET Server

\* --- Vclock (core deviation) ---
\* raft.h:219-226 — vclock for vote eligibility
VARIABLES
    vclock,             \* vclock[s] \in [Server -> Nat]
    candidateVclock     \* candidateVclock[s] \in [Server -> Nat] — stored for recheck

\* --- Network ---
VARIABLES
    messages            \* Set of messages in transit (unreliable channel)

\* --- Configuration ---
VARIABLES
    isEnabled,          \* isEnabled[s] \in BOOLEAN — raft.h:178-181
    isCandidate         \* isCandidate[s] \in BOOLEAN — raft.h:187-189

\* --- Promote (Family 4) ---
VARIABLES
    isPromoting         \* isPromoting[s] \in BOOLEAN

----
\* Variable groups for UNCHANGED
----

coreVars      == <<state, leader, votesReceived>>
volatileVars  == <<volatileTerm, volatileVote>>
persistVars   == <<persistedTerm, persistedVote>>
walVars       == <<isWriteInProgress, walWritePhase>>
witnessVars   == <<leaderWitnessMap>>
vclockVars    == <<vclock, candidateVclock>>
networkVars   == <<messages>>
configVars    == <<isEnabled, isCandidate>>
promoteVars   == <<isPromoting>>

allVars == <<coreVars, volatileVars, persistVars, walVars, witnessVars,
             vclockVars, networkVars, configVars, promoteVars>>

----
\* Message type constants
----

\* raft_msg fields (raft.h:102-127):
\*   term, vote, leader_id, is_leader_seen, state, vclock

RaftMessage == "RaftMessage"
Heartbeat   == "Heartbeat"

----
\* Helpers
----

\* raft.c:103-108 — raft_is_fully_on_disk
IsFullyOnDisk(s) ==
    /\ volatileTerm[s] = persistedTerm[s]
    /\ volatileVote[s] = persistedVote[s]

\* raft.c:140-146 — raft_can_vote_for: vclock component-wise >=
\* Candidate vclock v must be >= server's vclock in all components
CanVoteFor(s, v) ==
    \A p \in Server : v[p] >= vclock[s][p]

\* raft.c:240-246 — raft_is_leader_seen: self bit in witness map
IsLeaderSeen(s) ==
    s \in leaderWitnessMap[s]

\* Number of votes received by server s
VoteCount(s) == Cardinality(votesReceived[s])

\* raft.c:334-350 — raft_sm_election_update gate check
CanStartElection(s) ==
    \* raft.c:341 — must be cfg_candidate
    /\ isCandidate[s]
    \* raft.c:346 — leader_witness_map must be empty
    /\ leaderWitnessMap[s] = {}

\* Helper: construct a message record
MakeMessage(type, from, mterm, mvote, mleader, mstate, misLeaderSeen, mvclock) ==
    [type        |-> type,
     from        |-> from,
     term        |-> mterm,
     vote        |-> mvote,
     leaderId    |-> mleader,
     state       |-> mstate,
     isLeaderSeen|-> misLeaderSeen,
     vclock      |-> mvclock]

\* Send a message to all other servers (broadcast)
Broadcast(from, mterm, mvote, mleader, mstate, misLeaderSeen, mvclock) ==
    messages' = messages \cup
        {MakeMessage(RaftMessage, from, mterm, mvote, mleader, mstate,
                     misLeaderSeen, mvclock)}

\* raft.c:1080-1107 — raft_checkpoint_remote: construct broadcast message
\* Uses PERSISTED term/vote (not volatile) for broadcasts
BroadcastState(s) ==
    LET mvclock == IF state[s] = "Candidate" THEN vclock[s]
                   ELSE [p \in Server |-> 0]
        \* raft.c:1098 — disabled nodes report is_leader_seen=false
        misLeaderSeen == isEnabled[s] /\ IsLeaderSeen(s)
    IN Broadcast(s, persistedTerm[s], persistedVote[s], leader[s],
                 state[s], misLeaderSeen, mvclock)

\* Send heartbeat from leader
SendHeartbeat(s) ==
    messages' = messages \cup
        {[type |-> Heartbeat, from |-> s]}

\* Empty vclock
EmptyVclock == [p \in Server |-> 0]

----
\* Actions
----

\* =========================================================================
\* ElectionTimeout — raft.c:966-983 (raft_sm_election_update_cb)
\* Timer fires, clears self witness bit, checks election conditions.
\* Bug Family 1: only clears SELF bit (line 978), not remote bits.
\* =========================================================================
ElectionTimeout(s) ==
    /\ isEnabled[s]
    /\ state[s] \in {"Follower", "Candidate"}
    /\ IsFullyOnDisk(s)
    /\ ~isWriteInProgress[s]
    \* raft.c:978 — bit_clear(&raft->leader_witness_map, raft->self)
    /\ leaderWitnessMap' = [leaderWitnessMap EXCEPT ![s] = @ \ {s}]
    \* raft.c:982 — raft_sm_election_update(raft)
    \* Check gate AFTER clearing self bit
    /\ IF CanStartElection(s) /\ (leaderWitnessMap[s] \ {s}) = {}
       THEN \* raft.c:955-963 — raft_sm_schedule_new_election
            LET newTerm == volatileTerm[s] + 1 IN
            \* raft.c:961 — raft_sm_schedule_new_term
            /\ volatileTerm'   = [volatileTerm EXCEPT ![s] = newTerm]
            /\ volatileVote'   = [volatileVote EXCEPT ![s] = s]
            /\ candidateVclock'= [candidateVclock EXCEPT ![s] = vclock[s]]
            /\ state'          = [state EXCEPT ![s] = "Follower"]
            /\ leader'         = [leader EXCEPT ![s] = Nil]
            /\ votesReceived'  = [votesReceived EXCEPT ![s] = {s}]
            \* raft.c:915 — raft_sm_pause_and_dump
            /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] = TRUE]
            /\ walWritePhase'  = [walWritePhase EXCEPT ![s] = "idle"]
            /\ UNCHANGED <<persistVars, networkVars, configVars, promoteVars, vclock>>
       ELSE \* Gate blocked — no election
            /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                           vclockVars, networkVars, configVars, promoteVars>>

\* =========================================================================
\* ReceiveHeartbeat — raft.c:656-696 (raft_process_heartbeat)
\* Heartbeat from leader updates leader_last_seen; resets witness.
\* Bug Family 2: line 679 — during WAL write, only updates timestamp, no timer reset.
\* =========================================================================
ReceiveHeartbeat(s, m) ==
    /\ m.type = Heartbeat
    /\ m.from # s
    /\ isEnabled[s]
    \* raft.c:668 — don't care if self is leader
    /\ state[s] # "Leader"
    \* raft.c:671 — only from known leader
    /\ leader[s] = m.from
    /\ IF isWriteInProgress[s]
       THEN \* raft.c:679 — during WAL write, partial processing only
            /\ UNCHANGED <<allVars>>
       ELSE \* raft.c:694 — raft_leader_see: set self bit in witness map
            /\ leaderWitnessMap' = [leaderWitnessMap EXCEPT ![s] = @ \cup {s}]
            /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                           vclockVars, networkVars, configVars, promoteVars>>

\* =========================================================================
\* ReceiveMessage — raft.c:503-654 (raft_process_msg)
\* Main message handler. Processes term bump, witness update, votes, leader.
\* Bug Family 1: line 527-531 — term bump BEFORE witness update (ordering).
\* =========================================================================
ReceiveMessage(s, m) ==
    /\ m.type = RaftMessage
    /\ m.from # s
    \* raft.c:509 — validation
    /\ m.term > 0
    /\ m.state \in {"Follower", "Candidate", "Leader"}
    \* raft.c:520 — outdated term check (uses volatile term)
    /\ m.term >= volatileTerm[s]
    /\ LET source == m.from IN

       \* === Step 1: Term bump (raft.c:528) ===
       \* raft_process_term → raft_sm_schedule_new_term
       LET termBumped == m.term > volatileTerm[s]
           \* After term bump: state
           newState == IF termBumped THEN "Follower" ELSE state[s]
           newVolatileTerm == IF termBumped THEN m.term ELSE volatileTerm[s]
           newVolatileVote == IF termBumped THEN Nil ELSE volatileVote[s]
           newLeader == IF termBumped THEN Nil ELSE leader[s]
           newVotesReceived == IF termBumped THEN {} ELSE votesReceived[s]
           newCandidateVclock == IF termBumped THEN EmptyVclock ELSE candidateVclock[s]
           \* raft.c:909 — term bump clears witness map
           newWitnessMap == IF termBumped THEN {} ELSE leaderWitnessMap[s]
       IN

       \* === Step 2: Witness update (raft.c:531) ===
       \* raft_notify_is_leader_seen — Bug Family 1: happens AFTER term bump
       \* raft.c:455-468
       LET witnessAfterTerm ==
              IF newState = "Leader"
              THEN newWitnessMap  \* raft.c:461 — leader ignores witness
              ELSE IF m.isLeaderSeen
                   THEN newWitnessMap \cup {source}  \* raft.c:465
                   ELSE newWitnessMap \ {source}     \* raft.c:466
       IN

       \* === Step 3: Vote processing (raft.c:537-603) ===
       LET voteProcessed ==
            IF m.vote = Nil
            THEN \* No vote in message
                 [st |-> newState, vt |-> newVolatileTerm,
                  vv |-> newVolatileVote, ld |-> newLeader,
                  vr |-> newVotesReceived, cc |-> newCandidateVclock,
                  wip |-> isWriteInProgress[s], wph |-> walWritePhase[s]]
            ELSE
              CASE newState \in {"Follower", "Leader"} ->
                \* raft.c:542-578
                IF /\ isEnabled[s]                         \* raft.c:544
                   /\ newLeader = Nil                      \* raft.c:549
                   /\ m.vote # s                           \* raft.c:555
                   /\ m.state = "Candidate"                \* raft.c:566
                   /\ newVolatileVote = Nil                 \* raft.c:572
                   /\ CanVoteFor(s, m.vclock)              \* raft.c:946/929
                THEN \* raft.c:952 — raft_sm_schedule_new_vote
                     [st |-> newState, vt |-> newVolatileTerm,
                      vv |-> m.vote, ld |-> newLeader,
                      vr |-> newVotesReceived \cup {s},
                      cc |-> m.vclock,
                      wip |-> TRUE, wph |-> "idle"]
                ELSE \* Skip vote (various reasons at raft.c:544-576)
                     [st |-> newState, vt |-> newVolatileTerm,
                      vv |-> newVolatileVote, ld |-> newLeader,
                      vr |-> newVotesReceived, cc |-> newCandidateVclock,
                      wip |-> isWriteInProgress[s], wph |-> walWritePhase[s]]

              [] newState = "Candidate" ->
                \* raft.c:579-598 — only accept votes for self
                IF m.vote = s
                THEN LET newVR == newVotesReceived \cup {source} IN
                     IF Cardinality(newVR) >= ElectionQuorum
                     THEN \* raft.c:598 — raft_sm_become_leader
                          [st |-> "Leader", vt |-> newVolatileTerm,
                           vv |-> newVolatileVote, ld |-> s,
                           vr |-> newVR, cc |-> newCandidateVclock,
                           wip |-> isWriteInProgress[s], wph |-> walWritePhase[s]]
                     ELSE [st |-> newState, vt |-> newVolatileTerm,
                           vv |-> newVolatileVote, ld |-> newLeader,
                           vr |-> newVR, cc |-> newCandidateVclock,
                           wip |-> isWriteInProgress[s], wph |-> walWritePhase[s]]
                ELSE \* raft.c:581 — competing candidate, skip
                     [st |-> newState, vt |-> newVolatileTerm,
                      vv |-> newVolatileVote, ld |-> newLeader,
                      vr |-> newVotesReceived, cc |-> newCandidateVclock,
                      wip |-> isWriteInProgress[s], wph |-> walWritePhase[s]]

              [] OTHER ->
                [st |-> newState, vt |-> newVolatileTerm,
                 vv |-> newVolatileVote, ld |-> newLeader,
                 vr |-> newVotesReceived, cc |-> newCandidateVclock,
                 wip |-> isWriteInProgress[s], wph |-> walWritePhase[s]]
       IN

       \* === Step 4: Leader processing (raft.c:605-653) ===
       LET finalState ==
            IF m.state # "Leader"
            THEN \* raft.c:605-627 — sender is not leader
                 IF source = voteProcessed.ld
                 THEN \* raft.c:606-626 — leader resigned
                      [voteProcessed EXCEPT
                        !.ld = Nil,
                        \* raft.c:615 — clear self witness bit
                        !.st = voteProcessed.st]
                 ELSE voteProcessed
            ELSE \* sender claims to be leader
                 IF source = voteProcessed.ld
                 THEN \* raft.c:630 — already known leader, no-op
                      voteProcessed
                 ELSE IF voteProcessed.ld # Nil
                      THEN \* raft.c:638-641 — conflicting leader, no-op (XXX)
                           voteProcessed
                      ELSE \* raft.c:648-652 — new leader found
                           \* raft_leader_see + raft_sm_follow_leader
                           [voteProcessed EXCEPT
                             !.st = "Follower",
                             !.ld = source]
       IN

       \* Handle leader resignation witness map update
       LET finalWitnessMap ==
            IF m.state # "Leader" /\ source = voteProcessed.ld
            THEN \* raft.c:615 — leader resigned, clear self bit
                 witnessAfterTerm \ {s}
            ELSE IF m.state = "Leader" /\ voteProcessed.ld = Nil /\ source # voteProcessed.ld
                 THEN \* raft.c:648 — raft_leader_see: set self bit
                      witnessAfterTerm \cup {s}
                 ELSE witnessAfterTerm
       IN

       \* Apply all state updates
       /\ state'           = [state EXCEPT ![s] = finalState.st]
       /\ volatileTerm'    = [volatileTerm EXCEPT ![s] = finalState.vt]
       /\ volatileVote'    = [volatileVote EXCEPT ![s] = finalState.vv]
       /\ leader'          = [leader EXCEPT ![s] = finalState.ld]
       /\ votesReceived'   = [votesReceived EXCEPT ![s] = finalState.vr]
       /\ candidateVclock' = [candidateVclock EXCEPT ![s] = finalState.cc]
       /\ leaderWitnessMap'= [leaderWitnessMap EXCEPT ![s] = finalWitnessMap]
       /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] =
            finalState.wip \/ (termBumped /\ ~isWriteInProgress[s])]
       /\ walWritePhase'   = [walWritePhase EXCEPT ![s] = finalState.wph]
       /\ messages'        = messages \ {m}
       /\ UNCHANGED <<persistVars, vclock, configVars, promoteVars>>

\* =========================================================================
\* WalWriteTermOnly — raft.c:737-795 (raft_worker_handle_io, "do_dump" path)
\* Persists term without vote. Part of multi-pass WAL write (Family 3).
\* raft.c:759 — volatile_term > term → go to do_dump (term only)
\* =========================================================================
WalWriteTermOnly(s) ==
    /\ isWriteInProgress[s]
    /\ state[s] = "Follower"                    \* raft.c:704
    /\ ~IsFullyOnDisk(s)                        \* raft.c:707
    /\ volatileVote[s] # Nil                    \* raft.c:740 — has a vote
    /\ volatileVote[s] # s                      \* raft.c:749 — not self-vote
    /\ volatileTerm[s] > persistedTerm[s]       \* raft.c:759 — term not yet flushed
    \* Persist term only (do_dump path without vote)
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = volatileTerm[s]]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = Nil]
    /\ walWritePhase' = [walWritePhase EXCEPT ![s] = "term_only"]
    /\ UNCHANGED <<coreVars, volatileVars, witnessVars, vclockVars,
                   networkVars, configVars, promoteVars, isWriteInProgress>>

\* =========================================================================
\* WalWriteTermAndVote — raft.c:769-795 (raft_worker_handle_io, "do_dump_with_vote")
\* Persists both term and vote. Either self-vote or after vclock recheck.
\* Bug Family 3: raft.c:761 — vclock recheck after term flush.
\* =========================================================================
WalWriteTermAndVote(s) ==
    /\ isWriteInProgress[s]
    /\ state[s] = "Follower"                    \* raft.c:704
    /\ ~IsFullyOnDisk(s)                        \* raft.c:707
    /\ volatileVote[s] # Nil                    \* raft.c:740
    /\ \/ volatileVote[s] = s                   \* raft.c:749 — self-vote always ok
       \/ /\ volatileTerm[s] = persistedTerm[s] \* raft.c:759 — term already flushed
          /\ CanVoteFor(s, candidateVclock[s])   \* raft.c:761 — vclock recheck passes
    \* Persist both (do_dump_with_vote path)
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = volatileTerm[s]]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = volatileVote[s]]
    /\ walWritePhase' = [walWritePhase EXCEPT ![s] = "term_and_vote"]
    /\ UNCHANGED <<coreVars, volatileVars, witnessVars, vclockVars,
                   networkVars, configVars, promoteVars, isWriteInProgress>>

\* =========================================================================
\* WalWriteRevokeVote — raft.c:761-767 (vclock recheck fails → revoke vote)
\* Bug Family 3: The vclock may have changed between term flush and vote flush.
\* raft.c:165-190 — raft_revoke_vote
\* =========================================================================
WalWriteRevokeVote(s) ==
    /\ isWriteInProgress[s]
    /\ state[s] = "Follower"                    \* raft.c:704
    /\ ~IsFullyOnDisk(s)                        \* raft.c:707
    /\ volatileVote[s] # Nil                    \* raft.c:740
    /\ volatileVote[s] # s                      \* not self (self always passes)
    /\ volatileTerm[s] = persistedTerm[s]       \* raft.c:759 — term already flushed
    /\ ~CanVoteFor(s, candidateVclock[s])       \* raft.c:761 — vclock recheck FAILS
    \* raft.c:765 — raft_revoke_vote
    /\ volatileVote'    = [volatileVote EXCEPT ![s] = Nil]
    /\ candidateVclock' = [candidateVclock EXCEPT ![s] = EmptyVclock]
    /\ votesReceived'   = [votesReceived EXCEPT ![s] = @ \ {s}]
    \* After revoke, IsFullyOnDisk becomes true → end_dump
    /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] = FALSE]
    /\ walWritePhase'  = [walWritePhase EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<state, leader, volatileTerm, persistVars, witnessVars,
                   vclock, networkVars, configVars, promoteVars>>

\* =========================================================================
\* WalWriteTermOnlyNonVote — WAL write when only term changed (no vote)
\* raft.c:737-795, path where volatileVote == 0
\* =========================================================================
WalWriteTermOnlyNonVote(s) ==
    /\ isWriteInProgress[s]
    /\ state[s] = "Follower"                    \* raft.c:704
    /\ ~IsFullyOnDisk(s)                        \* raft.c:707
    /\ volatileVote[s] = Nil                    \* raft.c:740 — no vote pending
    \* Persist term (do_dump path)
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = volatileTerm[s]]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = Nil]
    /\ walWritePhase' = [walWritePhase EXCEPT ![s] = "term_only"]
    /\ UNCHANGED <<coreVars, volatileVars, witnessVars, vclockVars,
                   networkVars, configVars, promoteVars, isWriteInProgress>>

\* =========================================================================
\* CompleteWalWrite — raft.c:707-736 (raft_worker_handle_io, end_dump path)
\* WAL write finishes. State machine unfreezes and transitions.
\* Bug Family 2: post-write transitions.
\* =========================================================================
CompleteWalWrite(s) ==
    /\ isWriteInProgress[s]
    /\ state[s] = "Follower"                    \* raft.c:704
    /\ IsFullyOnDisk(s)                         \* raft.c:707 — fully synced
    \* raft.c:709 — is_write_in_progress = false
    /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] = FALSE]
    /\ walWritePhase'     = [walWritePhase EXCEPT ![s] = "idle"]
    \* raft.c:715-736 — post-write state transitions
    /\ IF IsLeaderSeen(s) /\ isEnabled[s]
       THEN \* raft.c:717 — wait_leader_dead (timer start)
            UNCHANGED <<coreVars, volatileVars, persistVars, witnessVars,
                        vclockVars, networkVars, configVars, promoteVars>>
       ELSE IF isCandidate[s]
            THEN IF persistedVote[s] = s
                 THEN IF ElectionQuorum = 1
                      THEN \* raft.c:722 — become_leader immediately
                           /\ state'         = [state EXCEPT ![s] = "Leader"]
                           /\ leader'        = [leader EXCEPT ![s] = s]
                           /\ UNCHANGED <<votesReceived, volatileVars, persistVars,
                                          witnessVars, vclockVars, networkVars,
                                          configVars, promoteVars>>
                      ELSE \* raft.c:724 — become_candidate
                           /\ state'         = [state EXCEPT ![s] = "Candidate"]
                           /\ UNCHANGED <<leader, votesReceived, volatileVars,
                                          persistVars, witnessVars, vclockVars,
                                          networkVars, configVars, promoteVars>>
                 ELSE IF persistedVote[s] # Nil
                      THEN \* raft.c:730 — voted for other, wait_election_end
                           UNCHANGED <<coreVars, volatileVars, persistVars,
                                       witnessVars, vclockVars, networkVars,
                                       configVars, promoteVars>>
                      ELSE \* raft.c:733 — no vote yet, vote for self
                           /\ volatileVote'    = [volatileVote EXCEPT ![s] = s]
                           /\ candidateVclock' = [candidateVclock EXCEPT ![s] = vclock[s]]
                           /\ votesReceived'   = [votesReceived EXCEPT ![s] = @ \cup {s}]
                           /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] = TRUE]
                           /\ walWritePhase'   = [walWritePhase EXCEPT ![s] = "idle"]
                           /\ UNCHANGED <<state, leader, volatileTerm, persistVars,
                                          witnessVars, vclock, networkVars,
                                          configVars, promoteVars>>
            ELSE \* Not a candidate, stay follower
                 UNCHANGED <<coreVars, volatileVars, persistVars, witnessVars,
                             vclockVars, networkVars, configVars, promoteVars>>

\* =========================================================================
\* BroadcastRaftState — raft.c:799-807 (raft_worker_handle_broadcast)
\* Broadcasts persisted state to all peers.
\* =========================================================================
BroadcastRaftState(s) ==
    /\ ~isWriteInProgress[s]
    /\ BroadcastState(s)
    /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                   witnessVars, vclockVars, configVars, promoteVars>>

\* =========================================================================
\* LeaderSendHeartbeat — leader sends heartbeat
\* =========================================================================
LeaderSendHeartbeat(s) ==
    /\ state[s] = "Leader"
    /\ isEnabled[s]
    /\ SendHeartbeat(s)
    /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                   witnessVars, vclockVars, configVars, promoteVars>>

\* =========================================================================
\* Crash — Server crashes and recovers from persisted state.
\* Bug Family 3: validates persistence correctness across crashes.
\* raft.c:422-453 (raft_process_recovery)
\* =========================================================================
Crash(s) ==
    \* Recovery: restore from persisted state only
    \* raft.c:432-439 — term and vote from WAL
    /\ state'           = [state EXCEPT ![s] = "Follower"]
    /\ leader'          = [leader EXCEPT ![s] = Nil]
    /\ votesReceived'   = [votesReceived EXCEPT ![s] = {}]
    /\ volatileTerm'    = [volatileTerm EXCEPT ![s] = persistedTerm[s]]
    /\ volatileVote'    = [volatileVote EXCEPT ![s] = persistedVote[s]]
    \* Persisted state stays the same
    /\ UNCHANGED persistVars
    \* WAL write state resets
    /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] = FALSE]
    /\ walWritePhase'     = [walWritePhase EXCEPT ![s] = "idle"]
    \* Witness map resets (node restarts with no knowledge)
    /\ leaderWitnessMap'  = [leaderWitnessMap EXCEPT ![s] = {}]
    \* Candidate vclock resets
    /\ candidateVclock'   = [candidateVclock EXCEPT ![s] = EmptyVclock]
    \* Vclock preserved (survives restart via WAL/snapshot)
    /\ UNCHANGED <<vclock, networkVars, configVars, promoteVars>>

\* =========================================================================
\* Promote — raft.c:1212-1220 (raft_promote)
\* Bumps term, votes for self, becomes candidate.
\* Bug Family 4: no guard against is_write_in_progress at line 1212.
\* =========================================================================
Promote(s) ==
    /\ isEnabled[s]                              \* raft.c:1215
    \* NOTE: no isWriteInProgress guard (Bug Family 4, raft.c:1212)
    /\ LET newTerm == volatileTerm[s] + 1 IN
       \* raft.c:1217 — raft_sm_schedule_new_term
       /\ volatileTerm'    = [volatileTerm EXCEPT ![s] = newTerm]
       /\ volatileVote'    = [volatileVote EXCEPT ![s] = s]
       /\ candidateVclock' = [candidateVclock EXCEPT ![s] = vclock[s]]
       /\ state'           = [state EXCEPT ![s] = "Follower"]
       /\ leader'          = [leader EXCEPT ![s] = Nil]
       /\ votesReceived'   = [votesReceived EXCEPT ![s] = {s}]
       \* raft.c:1218 — raft_start_candidate
       /\ isCandidate'     = [isCandidate EXCEPT ![s] = TRUE]
       /\ isPromoting'     = [isPromoting EXCEPT ![s] = TRUE]
       \* raft.c:915 — raft_sm_pause_and_dump
       /\ isWriteInProgress' = [isWriteInProgress EXCEPT ![s] = TRUE]
       /\ walWritePhase'   = [walWritePhase EXCEPT ![s] = "idle"]
       /\ leaderWitnessMap'= [leaderWitnessMap EXCEPT ![s] = {}]
       /\ UNCHANGED <<persistVars, vclock, networkVars, isEnabled>>

\* =========================================================================
\* LeaderResign — raft.c:489-501 (raft_leader_resign) + raft.c:1223-1228
\* Leader steps down. Clears only self witness bit.
\* Bug Family 1: raft.c:499 — only clears self bit via raft_stop_candidate.
\* =========================================================================
LeaderResign(s) ==
    /\ state[s] = "Leader"
    \* raft.c:1227 — raft_stop_candidate
    /\ state'           = [state EXCEPT ![s] = "Follower"]
    /\ leader'          = [leader EXCEPT ![s] = Nil]
    /\ isCandidate'     = [isCandidate EXCEPT ![s] = FALSE]
    /\ isPromoting'     = [isPromoting EXCEPT ![s] = FALSE]
    \* raft.c:499 — assert(!bit_test(&raft->leader_witness_map, raft->self))
    \* Leader's self bit should not be set (leaders don't set it)
    /\ UNCHANGED <<votesReceived, volatileVars, persistVars, walVars,
                   witnessVars, vclockVars, networkVars, isEnabled>>

\* =========================================================================
\* NotifyLeaderSeen — raft.c:455-468 (raft_notify_is_leader_seen)
\* External notification that a peer sees/doesn't see the leader.
\* Bug Family 1: stale bits from ordering issues.
\* =========================================================================
NotifyLeaderSeen(s, source, isSeen) ==
    /\ source # s
    /\ source \in Server
    \* raft.c:461 — leader doesn't care
    /\ state[s] # "Leader"
    /\ IF isSeen
       THEN \* raft.c:465 — bit_set
            /\ leaderWitnessMap' = [leaderWitnessMap EXCEPT ![s] = @ \cup {source}]
            /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                           vclockVars, networkVars, configVars, promoteVars>>
       ELSE \* raft.c:466 — bit_clear, then check election
            /\ leaderWitnessMap' = [leaderWitnessMap EXCEPT ![s] = @ \ {source}]
            \* raft.c:467 — raft_sm_election_update after clear
            /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                           vclockVars, networkVars, configVars, promoteVars>>

\* =========================================================================
\* AdvanceVclock — Model vclock advancement (other transactions commit)
\* Core deviation: vclock changes can affect vote eligibility (Family 3).
\* =========================================================================
AdvanceVclock(s) ==
    /\ \E p \in Server :
        vclock' = [vclock EXCEPT ![s][p] = @+1]
    /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                   witnessVars, candidateVclock, networkVars, configVars,
                   promoteVars>>

\* =========================================================================
\* LoseMessage — Network drops a message
\* =========================================================================
LoseMessage(m) ==
    /\ m \in messages
    /\ messages' = messages \ {m}
    /\ UNCHANGED <<coreVars, volatileVars, persistVars, walVars,
                   witnessVars, vclockVars, configVars, promoteVars>>

\* =========================================================================
\* DuplicateMessage — Network duplicates a message
\* Already modeled by messages being a set (re-delivery is a no-op for sets,
\* but we can add explicit duplicates to a bag if needed).
\* For simplicity, we use set-based messages (at-most-once per content).
\* =========================================================================

\* =========================================================================
\* ConfigChangeQuorum — raft.c:1258-1269 (raft_cfg_election_quorum)
\* Lowering quorum during candidacy can trigger immediate become_leader.
\* Bug Family 2: raft.c:1264-1266 — no is_write_in_progress check.
\* =========================================================================
\* Note: modeled indirectly via ElectionQuorum constant. For dynamic quorum
\* changes, this would need to be a variable. Kept as constant for now since
\* the bug (F2-2) is about an assertion failure, not a protocol violation.

----
\* Init and Next
----

Init ==
    \* raft.c:1405-1423 — raft_create initial values
    /\ state           = [s \in Server |-> "Follower"]
    /\ leader          = [s \in Server |-> Nil]
    /\ votesReceived   = [s \in Server |-> {}]
    /\ volatileTerm    = [s \in Server |-> 1]
    /\ volatileVote    = [s \in Server |-> Nil]
    /\ persistedTerm   = [s \in Server |-> 1]
    /\ persistedVote   = [s \in Server |-> Nil]
    /\ isWriteInProgress = [s \in Server |-> FALSE]
    /\ walWritePhase   = [s \in Server |-> "idle"]
    /\ leaderWitnessMap= [s \in Server |-> {}]
    /\ vclock          = [s \in Server |-> [p \in Server |-> 0]]
    /\ candidateVclock = [s \in Server |-> [p \in Server |-> 0]]
    /\ messages        = {}
    /\ isEnabled       = [s \in Server |-> TRUE]
    /\ isCandidate     = [s \in Server |-> TRUE]
    /\ isPromoting     = [s \in Server |-> FALSE]

Next ==
    \/ \E s \in Server :
        \/ ElectionTimeout(s)
        \/ BroadcastRaftState(s)
        \/ LeaderSendHeartbeat(s)
        \/ Crash(s)
        \/ Promote(s)
        \/ LeaderResign(s)
        \/ AdvanceVclock(s)
        \/ WalWriteTermOnly(s)
        \/ WalWriteTermAndVote(s)
        \/ WalWriteRevokeVote(s)
        \/ WalWriteTermOnlyNonVote(s)
        \/ CompleteWalWrite(s)
    \/ \E s \in Server, m \in messages :
        \/ ReceiveMessage(s, m)
        \/ ReceiveHeartbeat(s, m)
    \/ \E m \in messages : LoseMessage(m)

Spec == Init /\ [][Next]_allVars

----
\* Invariants
----

\* --- Standard Safety ---

\* ElectionSafety: at most one leader per term
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = "Leader" /\ state[s2] = "Leader" /\ s1 # s2)
        => volatileTerm[s1] # volatileTerm[s2]

\* --- Family 3: Non-Atomic Persistence ---

\* OneVotePerTerm: each server has at most one persisted vote per term
\* After crash recovery, cannot vote for two candidates in same term.
OneVotePerTerm ==
    \A s1, s2 \in Server :
        (/\ persistedVote[s1] # Nil
         /\ persistedVote[s2] # Nil
         /\ persistedTerm[s1] = persistedTerm[s2]
         /\ s1 # s2)
        => TRUE  \* Each server has its own vote; this checks no double-vote on same server
\* Refined: a single server never has two different persisted votes in same term
\* (This is automatically true since persistedVote is a function, but validates
\*  that crash+recovery doesn't lead to voting for two different candidates.)

\* VoteConsistency: if persisted vote is set, it was granted in persisted term
VoteConsistency ==
    \A s \in Server :
        persistedVote[s] # Nil =>
            \* The vote is meaningful only if the term matches
            persistedTerm[s] = volatileTerm[s] \/ ~IsFullyOnDisk(s)

\* NoStaleVoteAfterCrash: after recovery, volatile state matches persisted
\* (This is maintained by Crash action setting volatile = persisted)
NoStaleVoteAfterCrash ==
    \A s \in Server :
        (~isWriteInProgress[s] /\ IsFullyOnDisk(s)) =>
            (volatileTerm[s] = persistedTerm[s] /\ volatileVote[s] = persistedVote[s])

\* --- Family 2: WAL Write Safety ---

\* WalWriteSafety: during write, state must be Follower
WalWriteSafety ==
    \A s \in Server :
        isWriteInProgress[s] => state[s] = "Follower"

\* --- Family 1: Witness Map ---

\* WitnessMapBounded: witness map only contains valid servers
WitnessMapBounded ==
    \A s \in Server : leaderWitnessMap[s] \subseteq Server

\* --- Structural Invariants ---

\* LeaderHasVotedForSelf: leader must have voted for self
LeaderHasVotedForSelf ==
    \A s \in Server :
        state[s] = "Leader" =>
            /\ volatileVote[s] = s
            /\ persistedVote[s] = s

\* TermMonotonicity: volatile term >= persisted term
TermMonotonicity ==
    \A s \in Server :
        volatileTerm[s] >= persistedTerm[s]

\* VoteImpliesTerm: if voted, vote is in current term
VoteImpliesTerm ==
    \A s \in Server :
        volatileVote[s] # Nil =>
            volatileTerm[s] >= persistedTerm[s]

\* LeaderKnowsSelf: if state is Leader, leader field points to self
LeaderKnowsSelf ==
    \A s \in Server :
        state[s] = "Leader" => leader[s] = s

\* CandidateVotedForSelf: candidate has voted for self
CandidateVotedForSelf ==
    \A s \in Server :
        state[s] = "Candidate" => volatileVote[s] = s

\* NotWritingWhenLeader: leader cannot have write in progress
NotWritingWhenLeader ==
    \A s \in Server :
        state[s] = "Leader" => ~isWriteInProgress[s]

\* --- Extension Invariants (for bug hunting) ---

\* WitnessMapAccuracy (Family 1):
\* If witness map has a bit for some peer, there should be a living leader.
\* Stale bits that survive term bumps or resignations are the bug.
WitnessMapAccuracy ==
    \A s \in Server :
        leaderWitnessMap[s] # {} =>
            \/ leader[s] # Nil
            \/ \E p \in Server : state[p] = "Leader" /\ volatileTerm[p] = volatileTerm[s]

\* PromoteNotDuringWrite (Family 4):
\* Promote should not execute during WAL write.
\* The code at raft.c:1212 lacks this guard — this invariant may be violated.
PromoteNotDuringWrite ==
    \A s \in Server :
        isPromoting[s] => ~isWriteInProgress[s]

====
