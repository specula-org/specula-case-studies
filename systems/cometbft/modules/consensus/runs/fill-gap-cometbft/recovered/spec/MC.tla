--------------------------------- MODULE MC ---------------------------------
(*****************************************************************************)
(* Model-checking wrapper for the PBTS base spec.                            *)
(*                                                                           *)
(* The only nondeterministic *injected* actions are the three BFT-adversary   *)
(* actions (FaultyPropose / FaultyPrevote / FaultyPrecommit).  Each is wrapped *)
(* with a per-action counter so TLC explores a bounded number of Byzantine     *)
(* moves.  Reactive honest actions and the bounded-by-domain clock ticks /     *)
(* round advances are NOT counter-bounded (MaxTime / MaxRound bound them).     *)
(*                                                                           *)
(* Symmetry reduction over the three interchangeable correct validators         *)
(* (MCSymmetry == Permutations(Correct)); sound because the proposer schedule    *)
(* is adversarial (names no correct validator).  Used in the safety configs     *)
(* only — NOT in MC_live.cfg (symmetry + liveness is unsound).                  *)
(*****************************************************************************)
EXTENDS base

CONSTANTS
    FaultyProposeLimit,    \* max Byzantine proposals (faulty future-dating)
    FaultyPrevoteLimit,    \* max Byzantine prevotes
    FaultyPrecommitLimit   \* max Byzantine precommits

VARIABLE faultCount         \* [propose, prevote, precommit] firing counters
faultVars == <<faultCount>>
MCvars    == <<vars, faultCount>>

----------------------------------------------------------------------------
(* Counter-bounded adversary wrappers.                                        *)
MCFaultyPropose ==
    /\ faultCount.propose < FaultyProposeLimit
    /\ FaultyPropose
    /\ faultCount' = [faultCount EXCEPT !.propose = @ + 1]

MCFaultyPrevote ==
    /\ faultCount.prevote < FaultyPrevoteLimit
    /\ FaultyPrevote
    /\ faultCount' = [faultCount EXCEPT !.prevote = @ + 1]

MCFaultyPrecommit ==
    /\ faultCount.precommit < FaultyPrecommitLimit
    /\ FaultyPrecommit
    /\ faultCount' = [faultCount EXCEPT !.precommit = @ + 1]

----------------------------------------------------------------------------
(* Global time passage (uniform clock advance), counter untouched.            *)
GlobalTime ==
    \/ AdvanceRealTime
    \/ ProposerWait

(* Reactive / domain-bounded per-validator honest steps (counter untouched).  *)
HonestNext(s) ==
    \/ StartRound(s)
    \/ Propose(s)
    \/ ReceiveProposal(s)
    \/ PrevoteBlock(s)
    \/ PrevoteNil(s)
    \/ PrecommitBlock(s)
    \/ PrecommitNil(s)
    \/ Decide(s)

MCInit ==
    /\ Init
    /\ faultCount = [propose |-> 0, prevote |-> 0, precommit |-> 0]

MCNext ==
    \/ GlobalTime /\ UNCHANGED faultVars
    \/ (\E s \in Correct : HonestNext(s)) /\ UNCHANGED faultVars
    \/ MCFaultyPropose
    \/ MCFaultyPrevote
    \/ MCFaultyPrecommit

MCSpec == MCInit /\ [][MCNext]_MCvars

(* Symmetry: the three correct validators are interchangeable (the adversarial  *)
(* proposer schedule names none of them); the lone Byzantine s4 is fixed.       *)
(* Sound for SAFETY only — do NOT use with the PBTSProgress liveness check.      *)
MCSymmetry == Permutations(Correct)

(* Fairness variant for the PBTSProgress liveness check (MC_live.cfg).         *)
(* Honest validators make progress; Byzantine actions are NOT required to       *)
(* fire.  Progress also relies on the synchrony assumption baked into the       *)
(* skew-bounded clock model + adaptive MessageDelay back-off.                   *)
MCSpecFair ==
    /\ MCSpec
    /\ WF_MCvars(GlobalTime /\ UNCHANGED faultVars)
    /\ \A s \in Correct : WF_MCvars(HonestNext(s) /\ UNCHANGED faultVars)

----------------------------------------------------------------------------
(* NOTE: we deliberately do NOT use a TLC VIEW that hides faultCount.  The      *)
(* counters gate adversary enabledness, so merging states that differ only in   *)
(* remaining Byzantine budget could skip reachable attack interleavings.  The   *)
(* small per-action limits keep the state space bounded without a VIEW.         *)

(* Type-correctness of the counter record (combine with base TypeOK).         *)
MCTypeOK ==
    /\ TypeOK
    /\ faultCount \in [propose: 0..FaultyProposeLimit,
                       prevote: 0..FaultyPrevoteLimit,
                       precommit: 0..FaultyPrecommitLimit]

=============================================================================
