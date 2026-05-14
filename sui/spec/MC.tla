--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for Sui Mysticeti consensus.
 *
 * Wraps base spec actions with counter-bounded fault injection so TLC
 * can exhaustively explore state space.
 *
 * Fault model coverage (mapped to brief §2 Bug Families):
 *   F1 Equivocation:           MCByzPropose (multiple distinct digests/slot)
 *   F2 Amnesia recovery:       MCCrash + MCRecoverAmnesia + signedHistory durability
 *   F3 GC × commit interactions: per-validator gcRound divergence under DeliverBlock
 *   F4 Threshold clock / proposer: MCAddCertifiedCommit + MCForcePropose
 *   F5 (commit-vote equivocation): out of scope at protocol-spec level
 *)

EXTENDS base

base_inst == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxByzProposeLimit       \* Total Byzantine proposals
CONSTANT MaxCrashLimit            \* Total crash events
CONSTANT MaxRecoverLimit          \* Total recovery events
CONSTANT MaxCertCommitLimit       \* Total certified-commit fast-sync events
CONSTANT MaxForceProposeLimit     \* Total force-propose firings
CONSTANT MaxDagSizeLimit          \* Bound on |Messages|

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

\* --- F1: Byzantine block production (bounded) ---

MCByzPropose(s, r, d) ==
    /\ faultCounters.byzPropose < MaxByzProposeLimit
    /\ base_inst!ByzPropose(s, r, d)
    /\ faultCounters' = [faultCounters EXCEPT !.byzPropose = @ + 1]

\* --- F2: Crash (bounded) ---

MCCrash(s) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ base_inst!Crash(s)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

\* --- F2: Amnesia recovery (bounded) ---

MCRecoverAmnesia(s) ==
    /\ faultCounters.recover < MaxRecoverLimit
    /\ base_inst!RecoverAmnesia(s)
    /\ faultCounters' = [faultCounters EXCEPT !.recover = @ + 1]

\* --- F4: Certified-commit fast-sync (bounded) ---

MCAddCertifiedCommit(s, r) ==
    /\ faultCounters.certCommit < MaxCertCommitLimit
    /\ base_inst!AddCertifiedCommit(s, r)
    /\ faultCounters' = [faultCounters EXCEPT !.certCommit = @ + 1]

\* --- F4: Force-propose (bounded) ---

MCForcePropose(s) ==
    /\ faultCounters.forcePropose < MaxForceProposeLimit
    /\ base_inst!ForcePropose(s)
    /\ faultCounters' = [faultCounters EXCEPT !.forcePropose = @ + 1]

\* ============================================================================
\* UNBOUNDED (DETERMINISTIC / REACTIVE) ACTIONS
\* ============================================================================

MCHonestPropose(s) ==
    /\ base_inst!HonestPropose(s)
    /\ UNCHANGED faultVars

MCDeliverBlock(s, b) ==
    /\ base_inst!DeliverBlock(s, b)
    /\ UNCHANGED faultVars

MCTryDirectDecide(s, slot) ==
    /\ base_inst!TryDirectDecide(s, slot)
    /\ UNCHANGED faultVars

MCTryIndirectDecide(s, slot, anchorRef) ==
    /\ base_inst!TryIndirectDecide(s, slot, anchorRef)
    /\ UNCHANGED faultVars

MCLinearize(s, leaderRef) ==
    /\ base_inst!Linearize(s, leaderRef)
    /\ UNCHANGED faultVars

\* ============================================================================
\* INIT / NEXT
\* ============================================================================

MCInit ==
    /\ base_inst!Init
    /\ faultCounters = [
         byzPropose   |-> 0,
         crash        |-> 0,
         recover      |-> 0,
         certCommit   |-> 0,
         forcePropose |-> 0]

MCNext ==
    \/ \E s \in Server : MCHonestPropose(s)
    \/ \E s \in Server, r \in 1..MaxRound, d \in Digest :
         MCByzPropose(s, r, d)
    \/ \E s \in Server, b \in Messages : MCDeliverBlock(s, b)
    \/ \E s \in Server, slot \in [round: 1..MaxRound, author: Server] :
         MCTryDirectDecide(s, slot)
    \/ \E s \in Server,
          slot \in [round: 1..MaxRound, author: Server],
          aRef \in [round: 1..MaxRound, author: Server, digest: Digest] :
            MCTryIndirectDecide(s, slot, aRef)
    \/ \E s \in Server,
          lref \in [round: 1..MaxRound, author: Server, digest: Digest] :
            MCLinearize(s, lref)
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRecoverAmnesia(s)
    \/ \E s \in Server, r \in 1..MaxRound : MCAddCertifiedCommit(s, r)
    \/ \E s \in Server : MCForcePropose(s)

mc_vars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Symmetry: only honest validators are interchangeable. Byzantine has a
\* fixed identity for state-space stability. (Cannot use Permutations(Server)
\* if Byzantine is a singleton constant — TLC would equate s1..s4. We
\* permute Honest only via HonestPerm.)
HonestPerm == Permutations(Honest)
Symmetry == HonestPerm

\* Exclude faultCounters from view (they don't affect protocol behavior).
ModelView == <<vars>>

\* ============================================================================
\* STATE-SPACE PRUNING
\* ============================================================================

\* Bound the size of Messages to stop pathological Byzantine flooding.
DagSizeConstraint ==
    \/ MaxDagSizeLimit = 0
    \/ Cardinality(Messages) <= MaxDagSizeLimit

\* ============================================================================
\* MULTI-LEADER LATENT PATH (Family 4 / MC5)
\* ============================================================================
\*
\* Production: num_leaders_per_round = Some(1). Multi-leader is disabled and
\* contains a latent break-out bug (universal_committer.rs:48-57). To hunt
\* MC5, override LeaderOf to elect MORE than one leader per round by
\* defining a separate leader function. We do not enable this in MCInit;
\* a dedicated MC config provides MultiLeader_LeaderOf and uses it.

\* Up to two leaders per round (offsets 0 and 1). For MC5 hunt only.
MultiLeaderOf(r, offset) ==
    LET base_leader == ServerSeq[(r % N) + 1]
        offset_leader == ServerSeq[((r + offset) % N) + 1]
    IN IF offset = 0 THEN base_leader ELSE offset_leader

\* MultiLeaderCommitOrdering invariant (MC5): for every round R with
\* committed leader at offset k, all leaders at offsets j < k that are
\* decided must also be committed (no break-out skip).
\* This is referenced by MC_hunt_family4_multileader.cfg.
MultiLeaderCommitOrdering ==
    \A s \in Honest :
        \A r \in 1..MaxRound :
            \A offsetHigh \in 1..1 :  \* 0..1 with high = 1
                LET leaderLow == [round |-> r, author |-> MultiLeaderOf(r, 0)]
                    leaderHigh == [round |-> r, author |-> MultiLeaderOf(r, 1)]
                IN (\E i \in 1..Len(committedSeq[s]) :
                       SlotOfRef(committedSeq[s][i].leader) = leaderHigh) =>
                       (   leaderLow \in DOMAIN decided[s]
                        => decided[s][leaderLow].tag /= Commit_
                        \/ \E j \in 1..Len(committedSeq[s]) :
                              SlotOfRef(committedSeq[s][j].leader) = leaderLow)

\* ============================================================================
\* TEMPORAL PROPERTIES (MC layer)
\* ============================================================================

\* Decision permanence: once a slot is decided to Commit, the decision sticks.
DecisionPermanence ==
    [][
        \A s \in Server :
            \A slot \in DOMAIN decided[s] :
                slot \in DOMAIN decided'[s]
                /\ decided[s][slot].tag = Commit_ =>
                    decided'[s][slot] = decided[s][slot]
    ]_mc_vars

\* Monotonic commit sequence: committedSeq only grows (or remains) for
\* non-crashed validators.
MonotonicCommitSeq ==
    [][
        \A s \in Server :
            (~crashed[s] /\ ~crashed'[s]) =>
                Len(committedSeq'[s]) >= Len(committedSeq[s])
    ]_mc_vars

====
