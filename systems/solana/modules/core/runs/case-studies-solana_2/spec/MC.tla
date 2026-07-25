--------------------------- MODULE MC ---------------------------
(***************************************************************************)
(* Model checking spec for Solana Tower BFT (anza-xyz/agave).              *)
(*                                                                         *)
(* Bounds non-deterministic / fault-injection actions with explicit        *)
(* counters so TLC can exhaustively explore the bug families enumerated    *)
(* in modeling-brief.md §2.                                                *)
(*                                                                         *)
(* Fault model coverage:                                                   *)
(*   5.1 Crash:               MCCrash + MCRecover (in-mem vs persistent)   *)
(*   5.2 Network:             gossip vs replay split is the network model; *)
(*                            MCByzGossipFakeVote injects adversarial votes*)
(*   5.3 Timeout:             n/a (PoH treated as oracle; slot ordering    *)
(*                            given by ExtendBlock + FreezeBank)           *)
(*   5.4 NonAtomicPersist:    SetBlockstoreRoot vs VotingServiceStore are  *)
(*                            split actions; Crash between them = Family 3 *)
(*   5.5 ConfigChange:        out of scope (validator set static)          *)
(*   5.6 Snapshot:            out of scope (not in modeling brief)         *)
(*                                                                         *)
(* BFT-specific wrappers:                                                  *)
(*   * MCByzantineEquivocate     — Family 4 (per-hash OC tracker abuse)    *)
(*   * MCByzGossipFakeVote       — Family 5 (gossip-only vote injection)   *)
(*   * MCAdoptOnChainVoteState   — Family 1 (bifurcation seed)             *)
(***************************************************************************)

EXTENDS base, TLC

\* === Counter variables ===
\* One counter per fault-injection action.
VARIABLES counters

mcVars == <<vars, counters>>

CONSTANTS
    MaxBlocks,                  \* total ExtendBlock invocations
    MaxAdopt,                   \* AdoptOnChainVoteState invocations (Family 1)
    MaxStraySet,                \* SetStrayLastVote invocations
    MaxSwitchNormal,            \* CheckSwitchNormal calls
    MaxSwitchStray,             \* CheckSwitchStrayEmpty calls (Family 2)
    MaxSwitchDup,               \* CheckSwitchDuplicateFreebie calls (Family 2)
    MaxCrash,                   \* Crash + Recover pairs (Family 3)
    MaxByzGossip,               \* ByzGossipFakeVote (Family 5)
    MaxByzEquivocate,           \* ByzantineEquivocate (Family 4)
    MaxOCNotify                 \* EmitOCNotification (Family 4)

CounterRec ==
    [extendBlock:    Nat,
     adopt:          Nat,
     straySet:       Nat,
     switchNormal:   Nat,
     switchStray:    Nat,
     switchDup:      Nat,
     crash:          Nat,
     byzGossip:      Nat,
     byzEquivocate:  Nat,
     ocNotify:       Nat]

InitCounters ==
    [extendBlock    |-> 0,
     adopt          |-> 0,
     straySet       |-> 0,
     switchNormal   |-> 0,
     switchStray    |-> 0,
     switchDup      |-> 0,
     crash          |-> 0,
     byzGossip      |-> 0,
     byzEquivocate  |-> 0,
     ocNotify       |-> 0]

(***************************************************************************)
(* Counter-bounded wrappers                                                *)
(***************************************************************************)

MCExtendBlock(slot, h, par) ==
    /\ counters.extendBlock < MaxBlocks
    /\ ExtendBlock(slot, h, par)
    /\ counters' = [counters EXCEPT !.extendBlock = @ + 1]

MCAdoptOnChainVoteState(v, b, s) ==
    /\ counters.adopt < MaxAdopt
    /\ AdoptOnChainVoteState(v, b, s)
    /\ counters' = [counters EXCEPT !.adopt = @ + 1]

MCSetStrayLastVote(v) ==
    /\ counters.straySet < MaxStraySet
    /\ SetStrayLastVote(v)
    /\ counters' = [counters EXCEPT !.straySet = @ + 1]

MCCheckSwitchNormal(v, s) ==
    /\ counters.switchNormal < MaxSwitchNormal
    /\ CheckSwitchNormal(v, s)
    /\ counters' = [counters EXCEPT !.switchNormal = @ + 1]

MCCheckSwitchStrayEmpty(v, s) ==
    /\ counters.switchStray < MaxSwitchStray
    /\ CheckSwitchStrayEmpty(v, s)
    /\ counters' = [counters EXCEPT !.switchStray = @ + 1]

MCCheckSwitchDuplicateFreebie(v, s) ==
    /\ counters.switchDup < MaxSwitchDup
    /\ CheckSwitchDuplicateFreebie(v, s)
    /\ counters' = [counters EXCEPT !.switchDup = @ + 1]

MCCrash(v) ==
    /\ counters.crash < MaxCrash
    /\ Crash(v)
    /\ counters' = [counters EXCEPT !.crash = @ + 1]

\* Recover does NOT consume budget — it must always be reachable to close
\* the crash window. Multiple recoveries-per-crash bounded by Crash budget.
MCRecover(v) ==
    /\ Recover(v)
    /\ UNCHANGED counters

MCByzGossipFakeVote(byz, obs, s, h) ==
    /\ counters.byzGossip < MaxByzGossip
    /\ ByzGossipFakeVote(byz, obs, s, h)
    /\ counters' = [counters EXCEPT !.byzGossip = @ + 1]

MCByzantineEquivocate(byz, s, hA, hB) ==
    /\ counters.byzEquivocate < MaxByzEquivocate
    /\ ByzantineEquivocate(byz, s, hA, hB)
    /\ counters' = [counters EXCEPT !.byzEquivocate = @ + 1]

MCEmitOCNotification(s, h) ==
    /\ counters.ocNotify < MaxOCNotify
    /\ EmitOCNotification(s, h)
    /\ counters' = [counters EXCEPT !.ocNotify = @ + 1]

(***************************************************************************)
(* Pass-through wrappers for reactive / deterministic actions              *)
(***************************************************************************)

MCFreezeBank(b) ==
    /\ FreezeBank(b)
    /\ UNCHANGED counters

MCRecordBankVote(v, b) ==
    /\ RecordBankVote(v, b)
    /\ UNCHANGED counters

MCUpdateLastVoteFromVoteState(v) ==
    /\ UpdateLastVoteFromVoteState(v)
    /\ UNCHANGED counters

MCSetBlockstoreRoot(v) ==
    /\ SetBlockstoreRoot(v)
    /\ UNCHANGED counters

MCEnqueueVoteOp(v) ==
    /\ EnqueueVoteOp(v)
    /\ UNCHANGED counters

MCVotingServiceStore(v) ==
    /\ VotingServiceStore(v)
    /\ UNCHANGED counters

MCVotingServiceSendTx(v) ==
    /\ VotingServiceSendTx(v)
    /\ UNCHANGED counters

MCReplayLandedVote(obs, voter, s, h) ==
    /\ ReplayLandedVote(obs, voter, s, h)
    /\ UNCHANGED counters

MCGossipReceivedVote(obs, voter, s, h) ==
    /\ GossipReceivedVote(obs, voter, s, h)
    /\ UNCHANGED counters

MCTrackOptimisticVote(voter, s, h) ==
    /\ TrackOptimisticVote(voter, s, h)
    /\ UNCHANGED counters

MCRollbackOC(s, h) ==
    /\ RollbackOC(s, h)
    /\ UNCHANGED counters

(***************************************************************************)
(* Init / Next                                                             *)
(***************************************************************************)

MCInit ==
    /\ Init
    /\ counters = InitCounters

MCNext ==
    \/ \E slot \in 1..MaxSlot, h \in Hashes, par \in blocks :
           MCExtendBlock(slot, h, par)
    \/ \E b \in blocks : MCFreezeBank(b)
    \/ \E v \in Honest, b \in blocks : MCRecordBankVote(v, b)
    \/ \E v \in Honest, b \in blocks, s \in 1..MaxSlot :
           MCAdoptOnChainVoteState(v, b, s)
    \/ \E v \in Honest : MCUpdateLastVoteFromVoteState(v)
    \/ \E v \in Honest : MCSetStrayLastVote(v)
    \/ \E v \in Honest, s \in 1..MaxSlot : MCCheckSwitchNormal(v, s)
    \/ \E v \in Honest, s \in 1..MaxSlot : MCCheckSwitchStrayEmpty(v, s)
    \/ \E v \in Honest, s \in 1..MaxSlot : MCCheckSwitchDuplicateFreebie(v, s)
    \/ \E v \in Honest : MCSetBlockstoreRoot(v)
    \/ \E v \in Honest : MCEnqueueVoteOp(v)
    \/ \E v \in Honest : MCVotingServiceStore(v)
    \/ \E v \in Honest : MCVotingServiceSendTx(v)
    \/ \E v \in Honest : MCCrash(v)
    \/ \E v \in Honest : MCRecover(v)
    \/ \E obs \in Honest, voter \in Validators, s \in 1..MaxSlot, h \in Hashes :
          MCReplayLandedVote(obs, voter, s, h)
    \/ \E obs \in Honest, voter \in Validators, s \in 1..MaxSlot, h \in Hashes :
          MCGossipReceivedVote(obs, voter, s, h)
    \/ \E byz \in Byzantine, obs \in Honest, s \in 1..MaxSlot, h \in Hashes :
          MCByzGossipFakeVote(byz, obs, s, h)
    \/ \E voter \in Validators, s \in 1..MaxSlot, h \in Hashes :
          MCTrackOptimisticVote(voter, s, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : MCEmitOCNotification(s, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : MCRollbackOC(s, h)
    \/ \E byz \in Byzantine, s \in 1..MaxSlot :
          \E hA \in Hashes : \E hB \in Hashes :
              MCByzantineEquivocate(byz, s, hA, hB)

MCSpec == MCInit /\ [][MCNext]_mcVars

(***************************************************************************)
(* Symmetry, view, and state-space pruning                                 *)
(***************************************************************************)

\* Honest validators are interchangeable for fault analysis.
\* (Byzantine validators may have differing stakes / roles — keep distinct.)
SymmetryHonest == Permutations(Honest)

\* View hides counters so equivalent search states aren't kept apart by
\* counter values alone.
View == <<vars>>

\* Bound the in-flight voting channel queue to prevent unbounded growth.
StateConstraint ==
    /\ \A v \in Honest : Len(voting_channel[v]) <= 3
    /\ Cardinality(blocks) <= MaxBlocks + 1
    /\ Cardinality(oc_notifications) <= MaxOCNotify + 2

(***************************************************************************)
(* Counter-only structural invariants                                      *)
(***************************************************************************)

CountersOK ==
    /\ counters \in CounterRec
    /\ counters.extendBlock <= MaxBlocks
    /\ counters.adopt <= MaxAdopt
    /\ counters.straySet <= MaxStraySet
    /\ counters.switchNormal <= MaxSwitchNormal
    /\ counters.switchStray <= MaxSwitchStray
    /\ counters.switchDup <= MaxSwitchDup
    /\ counters.crash <= MaxCrash
    /\ counters.byzGossip <= MaxByzGossip
    /\ counters.byzEquivocate <= MaxByzEquivocate
    /\ counters.ocNotify <= MaxOCNotify

============================================================================
