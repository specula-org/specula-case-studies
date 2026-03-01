---- MODULE base ----
EXTENDS Integers, Naturals, Sequences, FiniteSets, TLC

(***************************************************************************)
(* Code-level N2Paxos model for artifact/n2paxos/n2paxos                  *)
(* This models implementation handlers/actions, not idealized Paxos rules. *)
(***************************************************************************)

CONSTANTS Servers, Leader0

ASSUME Servers # {}
ASSUME Leader0 \in Servers

ModelSlots == 0..8
BallotType == (-1)..16
SlotType == (-1)..64
CmdType == [client : (-1)..2, seq : (-42)..1]
SenderType == Servers
ModelCmds == CmdType
ExecEnabled == [s \in Servers |-> TRUE]

NORMAL == "NORMAL"
RECOVERING == "RECOVERING"
START == "START"
COMMIT == "COMMIT"

Majority == (Cardinality(Servers) \div 2) + 1

RS(rep, slot) == [rep |-> rep, slot |-> slot]
RC(rep, slot, cmd) == [rep |-> rep, slot |-> slot, cmd |-> cmd]
RV(rep, slot, from) == [rep |-> rep, slot |-> slot, from |-> from]
RCS(cmd, slot) == [cmd |-> cmd, slot |-> slot]
RSeen(rep, cmd) == [rep |-> rep, cmd |-> cmd]

VARIABLES
    ballot,
    cballot,
    status,
    isLeader,
    lastCmdSlot,
    phases,
    cmdAt,
    slotOfCmd,
    clientSeen,
    proposalSeen,
    beginBallots,
    votedSends,
    votes,
    delivered,
    receiveSuccesses,
    proposalFromClient,
    proposalFromLearned,
    descMeta,
    successEmits,
    deliverQueued,
    batch2ASeen,
    batch2BSeen

vars == <<
    ballot,
    cballot,
    status,
    isLeader,
    lastCmdSlot,
    phases,
    cmdAt,
    slotOfCmd,
    clientSeen,
    proposalSeen,
    beginBallots,
    votedSends,
    votes,
    delivered,
    receiveSuccesses,
    proposalFromClient,
    proposalFromLearned,
    descMeta,
    successEmits,
    deliverQueued,
    batch2ASeen,
    batch2BSeen
>>

HasProposal(rep, slot) == RS(rep, slot) \in proposalSeen
HasDelivered(rep, slot) == RS(rep, slot) \in delivered
HasClientSeen(rep, cmd) == RSeen(rep, cmd) \in clientSeen

CmdAtSlot(rep, slot) ==
    IF \E r \in cmdAt : r.rep = rep /\ r.slot = slot
    THEN CHOOSE r \in cmdAt : r.rep = rep /\ r.slot = slot
    ELSE [rep |-> rep, slot |-> slot, cmd |-> [client |-> -1, seq |-> -42]]

HasCmdAt(rep, slot) == \E r \in cmdAt : r.rep = rep /\ r.slot = slot

HasDeliverPayload(rep, slot) ==
    HasProposal(rep, slot)
    \/ (HasCmdAt(rep, slot) /\ HasClientSeen(rep, CmdAtSlot(rep, slot).cmd))

PhaseAt(rep, slot) ==
    IF \E r \in phases : r.rep = rep /\ r.slot = slot
    THEN (CHOOSE r \in phases : r.rep = rep /\ r.slot = slot).phase
    ELSE START

VotesAt(rep, slot) == Cardinality({v \in votes : v.rep = rep /\ v.slot = slot})
MemberVotesAt(rep, slot) ==
    Cardinality({v \in votes : v.rep = rep /\ v.slot = slot /\ v.from \in Servers})

SetPhase(rep, slot, phaseValue) ==
    (phases \ {r \in phases : r.rep = rep /\ r.slot = slot}) \cup {[rep |-> rep, slot |-> slot, phase |-> phaseValue]}

SetCmdAt(rep, slot, cmd) ==
    (cmdAt \ {r \in cmdAt : r.rep = rep /\ r.slot = slot}) \cup {RC(rep, slot, cmd)}

SetCmdSlot(cmd, slot) ==
    (slotOfCmd \ {r \in slotOfCmd : r.cmd = cmd}) \cup {RCS(cmd, slot)}

DescAt(rep, slot) ==
    IF \E d \in descMeta : d.rep = rep /\ d.slot = slot
    THEN CHOOSE d \in descMeta : d.rep = rep /\ d.slot = slot
    ELSE [rep |-> rep, slot |-> slot, active |-> FALSE, seq |-> FALSE, hasCmd |-> FALSE, afterReady |-> FALSE]

SetDesc(rep, slot, activeV, seqV, hasCmdV, afterReadyV) ==
    (descMeta \ {d \in descMeta : d.rep = rep /\ d.slot = slot})
    \cup {[rep |-> rep, slot |-> slot, active |-> activeV, seq |-> seqV, hasCmd |-> hasCmdV, afterReady |-> afterReadyV]}

CanDeliver(rep, slot) ==
    /\ ~HasDelivered(rep, slot)
    /\ ExecEnabled[rep]
    /\ (PhaseAt(rep, slot) = COMMIT \/ isLeader[rep])
    /\ (slot = 0 \/ HasDelivered(rep, slot - 1))
    /\ HasDeliverPayload(rep, slot)

Init ==
    /\ ballot = [i \in Servers |-> 0]
    /\ cballot = [i \in Servers |-> 0]
    /\ status = [i \in Servers |-> NORMAL]
    /\ isLeader = [i \in Servers |-> i = Leader0]
    /\ lastCmdSlot = [i \in Servers |-> 0]
    /\ phases = {}
    /\ cmdAt = {}
    /\ slotOfCmd = {}
    /\ clientSeen = {}
    /\ proposalSeen = {}
    /\ beginBallots = {}
    /\ votedSends = {}
    /\ votes = {}
    /\ delivered = {}
    /\ receiveSuccesses = {}
    /\ proposalFromClient = {}
    /\ proposalFromLearned = {}
    /\ descMeta = {}
    /\ successEmits = {}
    /\ deliverQueued = {}
    /\ batch2ASeen = {}
    /\ batch2BSeen = {}

(***************************************************************************)
(* HandleClientRequestBatch models request buffering into r.proposes map.  *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:165-171, 297-300            *)
(***************************************************************************)
HandleClientRequestBatch(targets, cmd) ==
    /\ clientSeen' = clientSeen \cup {RSeen(targets[k], cmd) : k \in 1..Len(targets)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, proposalSeen,
                  beginBallots, votedSends, votes, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, descMeta, successEmits,
                  deliverQueued, batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* handlePropose                                                           *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:196-224                     *)
(***************************************************************************)
HandlePropose(rep, slot, cmd) ==
    /\ status[rep] = NORMAL
    /\ isLeader[rep]
    /\ ~HasProposal(rep, slot)
    /\ proposalSeen' = proposalSeen \cup {RS(rep, slot)}
    /\ proposalFromClient' = proposalFromClient \cup {RS(rep, slot)}
    /\ proposalFromLearned' = proposalFromLearned
    /\ cmdAt' = SetCmdAt(rep, slot, cmd)
    /\ slotOfCmd' = SetCmdSlot(cmd, slot)
    /\ descMeta' = SetDesc(rep, slot, TRUE, FALSE, TRUE, TRUE)
    /\ lastCmdSlot' = [lastCmdSlot EXCEPT ![rep] = IF slot >= @ THEN slot + 1 ELSE @]
    /\ UNCHANGED <<ballot, cballot, status, isLeader,
                  phases, clientSeen, beginBallots, votedSends,
                  votes, delivered, receiveSuccesses, successEmits,
                  deliverQueued, batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* SendBeginBallot (batcher enqueue + sender send)                          *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:210-223, batcher.go:47       *)
(***************************************************************************)
SendBeginBallot(rep, slot, cmd) ==
    /\ status[rep] = NORMAL
    /\ HasCmdAt(rep, slot)
    /\ beginBallots' = beginBallots \cup {RC(rep, slot, cmd)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  votedSends, votes, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, descMeta,
                  successEmits, deliverQueued, batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* handle2A                                                                 *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:226-256                      *)
(***************************************************************************)
Handle2A(rep, from, slot, cmd, b) ==
    /\ status[rep] = NORMAL
    /\ ballot[rep] = b
    /\ cmdAt' = SetCmdAt(rep, slot, cmd)
    /\ slotOfCmd' = SetCmdSlot(cmd, slot)
    /\ descMeta' = SetDesc(rep, slot, TRUE, DescAt(rep, slot).seq, TRUE, TRUE)
    /\ proposalSeen' =
        IF HasClientSeen(rep, cmd)
        THEN proposalSeen \cup {RS(rep, slot)}
        ELSE proposalSeen
    /\ proposalFromClient' =
        IF HasClientSeen(rep, cmd)
        THEN proposalFromClient \cup {RS(rep, slot)}
        ELSE proposalFromClient
    /\ proposalFromLearned' =
        IF HasClientSeen(rep, cmd)
        THEN proposalFromLearned
        ELSE proposalFromLearned \cup {RS(rep, slot)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, clientSeen, beginBallots, votedSends,
                  votes, delivered, receiveSuccesses, successEmits,
                  deliverQueued, batch2ASeen, batch2BSeen>>

Handle2AFromBatch(rep, from, slot, cmd, b) ==
    /\ status[rep] = NORMAL
    /\ ballot[rep] = b
    /\ cmdAt' = SetCmdAt(rep, slot, cmd)
    /\ slotOfCmd' = SetCmdSlot(cmd, slot)
    /\ descMeta' = SetDesc(rep, slot, TRUE, DescAt(rep, slot).seq, TRUE, TRUE)
    /\ proposalSeen' =
        IF HasClientSeen(rep, cmd)
        THEN proposalSeen \cup {RS(rep, slot)}
        ELSE proposalSeen
    /\ proposalFromClient' =
        IF HasClientSeen(rep, cmd)
        THEN proposalFromClient \cup {RS(rep, slot)}
        ELSE proposalFromClient
    /\ proposalFromLearned' =
        IF HasClientSeen(rep, cmd)
        THEN proposalFromLearned
        ELSE proposalFromLearned \cup {RS(rep, slot)}
    /\ batch2ASeen' = batch2ASeen \cup {RC(rep, slot, cmd)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, clientSeen, beginBallots, votedSends,
                  votes, delivered, receiveSuccesses, successEmits,
                  deliverQueued, batch2BSeen>>

(***************************************************************************)
(* SendVoted                                                                *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:245-255, batcher.go:74       *)
(***************************************************************************)
SendVoted(rep, slot, cmd, b) ==
    /\ status[rep] = NORMAL
    /\ ballot[rep] = b
    /\ HasCmdAt(rep, slot)
    /\ votedSends' = votedSends \cup {RC(rep, slot, cmd)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votes, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, descMeta,
                  successEmits, deliverQueued, batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* handle2B                                                                 *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:258-267                      *)
(***************************************************************************)
Handle2B(rep, from, slot, b) ==
    /\ status[rep] = NORMAL
    /\ ballot[rep] = b
    /\ votes' = votes \cup {RV(rep, slot, from)}
    /\ descMeta' =
        SetDesc(rep, slot, TRUE, DescAt(rep, slot).seq, DescAt(rep, slot).hasCmd, DescAt(rep, slot).afterReady)
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votedSends, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, successEmits,
                  deliverQueued, batch2ASeen, batch2BSeen>>

Handle2BFromBatch(rep, from, slot, b) ==
    /\ status[rep] = NORMAL
    /\ ballot[rep] = b
    /\ votes' = votes \cup {RV(rep, slot, from)}
    /\ descMeta' =
        SetDesc(rep, slot, TRUE, DescAt(rep, slot).seq, DescAt(rep, slot).hasCmd, DescAt(rep, slot).afterReady)
    /\ batch2BSeen' = batch2BSeen \cup {RV(rep, slot, from)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votedSends, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned,
                  successEmits, deliverQueued, batch2ASeen>>

(***************************************************************************)
(* get2BsHandler callback => phase COMMIT                                   *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:269-279                      *)
(***************************************************************************)
Succeed(rep, slot) ==
    /\ status[rep] = NORMAL
    /\ VotesAt(rep, slot) >= Majority
    /\ phases' = SetPhase(rep, slot, COMMIT)
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votedSends, votes, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, descMeta,
                  successEmits, deliverQueued, batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* SendSuccess emission, then delivery is modeled in EnterDeliver/MarkDelivered *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:275-279, 282-335             *)
(***************************************************************************)
EmitSuccess(rep, slot) ==
    /\ status[rep] = NORMAL
    /\ PhaseAt(rep, slot) = COMMIT
    /\ successEmits' = successEmits \cup {RS(rep, slot)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen,
                  beginBallots, votedSends, votes, receiveSuccesses, delivered,
                  proposalSeen, proposalFromClient, proposalFromLearned,
                  descMeta, deliverQueued, batch2ASeen, batch2BSeen>>

EnterDeliver(rep, slot) ==
    /\ status[rep] = NORMAL
    /\ RS(rep, slot) \in successEmits
    /\ RS(rep, slot) \notin deliverQueued
    /\ DescAt(rep, slot).afterReady
    /\ deliverQueued' = deliverQueued \cup {RS(rep, slot)}
    /\ successEmits' = successEmits \ {RS(rep, slot)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votedSends, votes, receiveSuccesses, delivered,
                  proposalFromClient, proposalFromLearned, descMeta,
                  batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* deliverChan-triggered delivery attempt for next slot                     *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:153-154, 308-310, 436-438    *)
(***************************************************************************)
DeliverChainStep(rep, slot) ==
    /\ CanDeliver(rep, slot)
    /\ (RS(rep, slot) \in deliverQueued \/ RS(rep, slot) \in successEmits)
    /\ delivered' = delivered \cup {RS(rep, slot)}
    /\ proposalSeen' = proposalSeen \cup {RS(rep, slot)}
    /\ deliverQueued' = (deliverQueued \ {RS(rep, slot)}) \cup {RS(rep, slot + 1)}
    /\ descMeta' = SetDesc(rep, slot, FALSE, DescAt(rep, slot).seq, DescAt(rep, slot).hasCmd, DescAt(rep, slot).afterReady)
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen,
                  beginBallots, votedSends, votes, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, successEmits,
                  batch2ASeen, batch2BSeen>>

(***************************************************************************)
(* receive success reply side-effect                                        *)
(* Source: artifact/n2paxos/n2paxos/n2paxos.go:313-324                      *)
(***************************************************************************)
ReceiveSuccess(rep, slot, cmd) ==
    /\ HasDelivered(rep, slot)
    /\ RS(rep, slot) \in proposalFromClient
       \/ (RS(rep, slot) \in proposalFromLearned /\ HasClientSeen(rep, cmd))
    /\ receiveSuccesses' = receiveSuccesses \cup {RC(rep, slot, cmd)}
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  phases, cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votedSends, votes, delivered,
                  proposalFromClient, proposalFromLearned, descMeta,
                  successEmits, deliverQueued, batch2ASeen, batch2BSeen>>

SendSuccess(rep, slot) == EmitSuccess(rep, slot)

NoOp ==
    UNCHANGED vars

Next ==
    \/ \E rep \in Servers, cmd \in ModelCmds :
        HandleClientRequestBatch(<<rep>>, cmd)
    \/ \E rep \in Servers, slot \in ModelSlots, cmd \in ModelCmds :
        HandlePropose(rep, slot, cmd)
    \/ \E rep \in Servers, slot \in ModelSlots, cmd \in ModelCmds :
        SendBeginBallot(rep, slot, cmd)
    \/ \E rep \in Servers, from \in Servers, slot \in ModelSlots, cmd \in ModelCmds :
        Handle2A(rep, from, slot, cmd, ballot[rep])
    \/ \E rep \in Servers, from \in Servers, slot \in ModelSlots, cmd \in ModelCmds :
        Handle2AFromBatch(rep, from, slot, cmd, ballot[rep])
    \/ \E rep \in Servers, slot \in ModelSlots, cmd \in ModelCmds :
        SendVoted(rep, slot, cmd, ballot[rep])
    \/ \E rep \in Servers, from \in Servers, slot \in ModelSlots :
        Handle2B(rep, from, slot, ballot[rep])
    \/ \E rep \in Servers, from \in Servers, slot \in ModelSlots :
        Handle2BFromBatch(rep, from, slot, ballot[rep])
    \/ \E rep \in Servers, slot \in ModelSlots :
        Succeed(rep, slot)
    \/ \E rep \in Servers, slot \in ModelSlots :
        SendSuccess(rep, slot)
    \/ \E rep \in Servers, slot \in ModelSlots :
        EnterDeliver(rep, slot)
    \/ \E rep \in Servers, slot \in ModelSlots :
        DeliverChainStep(rep, slot)
    \/ \E rep \in Servers, slot \in ModelSlots, cmd \in ModelCmds :
        ReceiveSuccess(rep, slot, cmd)
    \/ NoOp

TypeOK ==
    /\ ballot \in [Servers -> BallotType]
    /\ cballot \in [Servers -> BallotType]
    /\ status \in [Servers -> {NORMAL, RECOVERING}]
    /\ isLeader \in [Servers -> BOOLEAN]
    /\ lastCmdSlot \in [Servers -> SlotType]
    /\ phases \subseteq {[rep : Servers, slot : SlotType, phase : {START, COMMIT}]}
    /\ cmdAt \subseteq {[rep : Servers, slot : SlotType, cmd : CmdType]}
    /\ slotOfCmd \subseteq {[cmd : CmdType, slot : SlotType]}
    /\ clientSeen \subseteq {[rep : Servers, cmd : CmdType]}
    /\ proposalSeen \subseteq {[rep : Servers, slot : SlotType]}
    /\ beginBallots \subseteq {[rep : Servers, slot : SlotType, cmd : CmdType]}
    /\ votedSends \subseteq {[rep : Servers, slot : SlotType, cmd : CmdType]}
    /\ votes \subseteq {[rep : Servers, slot : SlotType, from : SenderType]}
    /\ delivered \subseteq {[rep : Servers, slot : SlotType]}
    /\ receiveSuccesses \subseteq {[rep : Servers, slot : SlotType, cmd : CmdType]}
    /\ proposalFromClient \subseteq {[rep : Servers, slot : SlotType]}
    /\ proposalFromLearned \subseteq {[rep : Servers, slot : SlotType]}
    /\ descMeta \subseteq {[rep : Servers, slot : SlotType, active : BOOLEAN, seq : BOOLEAN, hasCmd : BOOLEAN, afterReady : BOOLEAN]}
    /\ successEmits \subseteq {[rep : Servers, slot : SlotType]}
    /\ deliverQueued \subseteq {[rep : Servers, slot : SlotType]}
    /\ batch2ASeen \subseteq {[rep : Servers, slot : SlotType, cmd : CmdType]}
    /\ batch2BSeen \subseteq {[rep : Servers, slot : SlotType, from : SenderType]}

OnlyProposedValuesLearned ==
    \A d \in delivered : HasProposal(d.rep, d.slot)

AtMostOneValuePerSlot ==
    \A x, y \in cmdAt :
        (x.rep = y.rep /\ x.slot = y.slot) => x.cmd = y.cmd

CommitImpliesQuorum ==
    \A p \in phases : p.phase = COMMIT => VotesAt(p.rep, p.slot) >= Majority

CommitUsesMembersOnly ==
    \A p \in phases : p.phase = COMMIT => MemberVotesAt(p.rep, p.slot) >= Majority

PrefixDelivery ==
    \A d \in delivered : d.slot > 0 => HasDelivered(d.rep, d.slot - 1)

NonLeaderNeedsCommitToDeliver ==
    \A d \in delivered : (~isLeader[d.rep]) => PhaseAt(d.rep, d.slot) = COMMIT

Spec == Init /\ [][Next]_vars

=============================================================================
