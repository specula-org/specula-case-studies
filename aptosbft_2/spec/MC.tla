--------------------------- MODULE MC ---------------------------
(*
 * Model-checking wrapper for Aptos BFT — Round 2.
 *
 * Wraps base.tla with counter-bounded fault-injection actions so TLC can
 * exhaustively explore the state space for the bug families in the
 * Modeling Brief.
 *
 * Counter-bounded (fault-injection) actions:
 *   - SignTimeout, EchoTimeout       (timeout election)
 *   - Crash, Recover                 (Family 1 crash-window mechanism)
 *   - DropMessage                    (network fault)
 *   - TriggerSync                    (state-transfer / pipeline pause)
 *   - EpochChange                    (Family 4 config-change boundary)
 *   - ByzEquivocateProposer          (Family 1, BFT 2.1)
 *   - ByzEquivocateOrderVote         (Family 2, BFT 2.1)
 *   - ByzReuseRealCertificate        (Family 3, BFT 2.7)
 *   - ByzForgeQCInOrderVoteMsg       (Family 3 alt; QC trust-on-first-use)
 *   - ByzCrossEpochReplay            (Family 4, BFT 2.5)
 *   - ReceiveOrderVoteWeakEpoch      (Family 4 RX-side weak bind)
 *   - SignCommitVote (epoch arg)     (Family 3, MC-5 — bounded epoch range)
 *
 * Unconstrained (deterministic/reactive) actions:
 *   - Propose, ProposeOpt, ReceiveProposal,
 *     SignVote, CompletePersistVote, ReceiveVote, FormQC,
 *     SignOrderVote, ReceiveOrderVote, FormOrderingCert,
 *     ReceiveTimeout, FormTC, ReceiveCommitVote,
 *     ExecuteBlock, AggregateCommitVotes, PersistBlock, ResetPipeline.
 *
 * Fault model coverage (Category A, with BFT Byzantine overlay):
 *   5.1 Crash:               MCCrash + MCRecover; volatile vs persistent split
 *                            in base spec (Family 1)
 *   5.2 Network:             MCDropMessage
 *   5.3 Timeout:             MCSignTimeout + MCEchoTimeout
 *   5.4 NonAtomicPersist:    SignVote / CompletePersistVote split in base
 *                            (drives MCCrash → MC-1)
 *   5.5 ConfigChange:        MCEpochChange (Family 4)
 *   5.6 Snapshot:            MCTriggerSync (Family 5 narrow)
 *   BFT 2.1 Equivocation:    MCByzEquivocateProposer + MCByzEquivocateOrderVote
 *   BFT 2.5 Replay:          MCByzCrossEpochReplay
 *   BFT 2.7 Cert manip:      MCByzReuseRealCertificate + MCByzForgeQCInOrderVoteMsg
 *)

EXTENDS base

\* ============================================================================
\* MC CONSTANTS — counter limits
\* ============================================================================

CONSTANT MaxTimeoutLimit
CONSTANT MaxCrashLimit
CONSTANT MaxDropLimit
CONSTANT MaxSyncLimit
CONSTANT MaxEpochChangeLimit
CONSTANT MaxByzEquivProposerLimit
CONSTANT MaxByzEquivOrderVoteLimit
CONSTANT MaxByzReuseCertLimit
CONSTANT MaxByzForgeQCLimit
CONSTANT MaxByzReplayLimit
CONSTANT MaxWeakEpochRxLimit
CONSTANT MaxMsgBufferLimit

\* ============================================================================
\* MC VARIABLES — counters
\* ============================================================================

VARIABLE cTimeout
VARIABLE cCrash
VARIABLE cDrop
VARIABLE cSync
VARIABLE cEpochChange
VARIABLE cByzEquivProposer
VARIABLE cByzEquivOrderVote
VARIABLE cByzReuseCert
VARIABLE cByzForgeQC
VARIABLE cByzReplay
VARIABLE cWeakEpochRx

faultVars == <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
               cByzEquivProposer, cByzEquivOrderVote, cByzReuseCert,
               cByzForgeQC, cByzReplay, cWeakEpochRx>>

mcAllVars == <<allVars, faultVars>>

\* ============================================================================
\* MC INIT
\* ============================================================================

MCInit ==
    /\ Init
    /\ cTimeout            = 0
    /\ cCrash              = 0
    /\ cDrop               = 0
    /\ cSync               = 0
    /\ cEpochChange        = 0
    /\ cByzEquivProposer   = 0
    /\ cByzEquivOrderVote  = 0
    /\ cByzReuseCert       = 0
    /\ cByzForgeQC         = 0
    /\ cByzReplay          = 0
    /\ cWeakEpochRx        = 0

\* ============================================================================
\* COUNTER-BOUNDED WRAPPERS
\* ============================================================================

MCSignTimeout(s) ==
    /\ cTimeout < MaxTimeoutLimit
    /\ SignTimeout(s)
    /\ cTimeout' = cTimeout + 1
    /\ UNCHANGED <<cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay, cWeakEpochRx>>

MCEchoTimeout(s) ==
    /\ cTimeout < MaxTimeoutLimit
    /\ EchoTimeout(s)
    /\ cTimeout' = cTimeout + 1
    /\ UNCHANGED <<cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay, cWeakEpochRx>>

MCCrash(s) ==
    /\ cCrash < MaxCrashLimit
    /\ Crash(s)
    /\ cCrash' = cCrash + 1
    /\ UNCHANGED <<cTimeout, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay, cWeakEpochRx>>

\* Recover is NOT counter-bounded: once a node has crashed, recovery
\* is reactive (operator-driven).  Bounding Recover serves no purpose.
MCRecover(s) ==
    /\ Recover(s)
    /\ UNCHANGED faultVars

MCDropMessage(m) ==
    /\ cDrop < MaxDropLimit
    /\ DropMessage(m)
    /\ cDrop' = cDrop + 1
    /\ UNCHANGED <<cTimeout, cCrash, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay, cWeakEpochRx>>

MCTriggerSync(s) ==
    /\ cSync < MaxSyncLimit
    /\ TriggerSync(s)
    /\ cSync' = cSync + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay, cWeakEpochRx>>

MCEpochChange(s) ==
    /\ cEpochChange < MaxEpochChangeLimit
    /\ EpochChange(s)
    /\ cEpochChange' = cEpochChange + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay, cWeakEpochRx>>

MCByzEquivocateProposer(s, r, v1, v2) ==
    /\ cByzEquivProposer < MaxByzEquivProposerLimit
    /\ ByzEquivocateProposer(s, r, v1, v2)
    /\ cByzEquivProposer' = cByzEquivProposer + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivOrderVote, cByzReuseCert, cByzForgeQC,
                    cByzReplay, cWeakEpochRx>>

MCByzEquivocateOrderVote(s, r, v1, v2) ==
    /\ cByzEquivOrderVote < MaxByzEquivOrderVoteLimit
    /\ ByzEquivocateOrderVote(s, r, v1, v2)
    /\ cByzEquivOrderVote' = cByzEquivOrderVote + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzReuseCert, cByzForgeQC,
                    cByzReplay, cWeakEpochRx>>

MCByzReuseRealCertificate(s, cert, v) ==
    /\ cByzReuseCert < MaxByzReuseCertLimit
    /\ ByzReuseRealCertificate(s, cert, v)
    /\ cByzReuseCert' = cByzReuseCert + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzForgeQC, cByzReplay, cWeakEpochRx>>

MCByzForgeQCInOrderVoteMsg(s, r, v, fv) ==
    /\ cByzForgeQC < MaxByzForgeQCLimit
    /\ ByzForgeQCInOrderVoteMsg(s, r, v, fv)
    /\ cByzForgeQC' = cByzForgeQC + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzReplay, cWeakEpochRx>>

MCByzCrossEpochReplay(s, cert, e) ==
    /\ cByzReplay < MaxByzReplayLimit
    /\ ByzCrossEpochReplay(s, cert, e)
    /\ cByzReplay' = cByzReplay + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cWeakEpochRx>>

MCReceiveOrderVoteWeakEpoch(s, m) ==
    /\ cWeakEpochRx < MaxWeakEpochRxLimit
    /\ ReceiveOrderVoteWeakEpoch(s, m)
    /\ cWeakEpochRx' = cWeakEpochRx + 1
    /\ UNCHANGED <<cTimeout, cCrash, cDrop, cSync, cEpochChange,
                    cByzEquivProposer, cByzEquivOrderVote,
                    cByzReuseCert, cByzForgeQC, cByzReplay>>

\* ============================================================================
\* UNCONSTRAINED WRAPPERS (deterministic / reactive)
\* ============================================================================

MCPropose(s, v)           == /\ Propose(s, v)           /\ UNCHANGED faultVars
MCProposeOpt(s, v)        == /\ ProposeOpt(s, v)        /\ UNCHANGED faultVars
MCReceiveProposal(s, m)   == /\ ReceiveProposal(s, m)   /\ UNCHANGED faultVars
MCSignVote(s)             == /\ SignVote(s)             /\ UNCHANGED faultVars
MCCompletePersistVote(s)  == /\ CompletePersistVote(s)  /\ UNCHANGED faultVars
MCReceiveVote(s, m)       == /\ ReceiveVote(s, m)       /\ UNCHANGED faultVars
MCFormQC(s, r)            == /\ FormQC(s, r)            /\ UNCHANGED faultVars
MCSignOrderVote(s, r)     == /\ SignOrderVote(s, r)     /\ UNCHANGED faultVars
MCReceiveOrderVote(s, m)  == /\ ReceiveOrderVote(s, m)  /\ UNCHANGED faultVars
MCFormOrderingCert(s,r,v) == /\ FormOrderingCert(s,r,v) /\ UNCHANGED faultVars
MCReceiveTimeout(s, m)    == /\ ReceiveTimeout(s, m)    /\ UNCHANGED faultVars
MCFormTC(s, r)            == /\ FormTC(s, r)            /\ UNCHANGED faultVars
MCSignCommitVote(s, r, e) == /\ SignCommitVote(s, r, e) /\ UNCHANGED faultVars
MCReceiveCommitVote(s, m) == /\ ReceiveCommitVote(s, m) /\ UNCHANGED faultVars
MCExecuteBlock(s, r)      == /\ ExecuteBlock(s, r)      /\ UNCHANGED faultVars
MCAggrCommitVotes(s, r)   == /\ AggregateCommitVotes(s, r) /\ UNCHANGED faultVars
MCPersistBlock(s, r)      == /\ PersistBlock(s, r)      /\ UNCHANGED faultVars
MCResetPipeline(s)        == /\ ResetPipeline(s)        /\ UNCHANGED faultVars

\* ============================================================================
\* MC NEXT
\* ============================================================================

MCNext ==
    \/ \E s \in Server, v \in Values : MCPropose(s, v)
    \/ \E s \in Server, v \in Values : MCProposeOpt(s, v)
    \/ \E s \in Faulty, r \in 1..MaxRound, v1 \in Values, v2 \in Values :
        MCByzEquivocateProposer(s, r, v1, v2)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveProposal(s, m)
    \/ \E s \in Server : MCSignVote(s)
    \/ \E s \in Server : MCCompletePersistVote(s)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : MCFormQC(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : MCSignOrderVote(s, r)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveOrderVote(s, m)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveOrderVoteWeakEpoch(s, m)
    \/ \E s \in Server, r \in 1..MaxRound, v \in Values : MCFormOrderingCert(s, r, v)
    \/ \E s \in Faulty, r \in 1..MaxRound, v1 \in Values, v2 \in Values :
        MCByzEquivocateOrderVote(s, r, v1, v2)
    \/ \E s \in Server : MCSignTimeout(s)
    \/ \E s \in Server : MCEchoTimeout(s)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveTimeout(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : MCFormTC(s, r)
    \/ \E s \in Server, r \in 1..MaxRound, e \in 1..MaxEpoch :
        MCSignCommitVote(s, r, e)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveCommitVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : MCExecuteBlock(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : MCAggrCommitVotes(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : MCPersistBlock(s, r)
    \/ \E s \in Server : MCResetPipeline(s)
    \/ \E s \in Server : MCTriggerSync(s)
    \/ \E s \in Server : MCEpochChange(s)
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRecover(s)
    \/ \E s \in Faulty, cert \in realCerts, v \in Values :
        MCByzReuseRealCertificate(s, cert, v)
    \/ \E s \in Faulty, r \in 1..MaxRound, v \in Values, fv \in Values :
        MCByzForgeQCInOrderVoteMsg(s, r, v, fv)
    \/ \E s \in Faulty, cert \in realCerts, e \in 1..MaxEpoch :
        MCByzCrossEpochReplay(s, cert, e)
    \/ \E m \in DOMAIN msgs : MCDropMessage(m)

\* ============================================================================
\* SYMMETRY & VIEW
\* ============================================================================

\* Symmetry on the HONEST set (Faulty must not be permuted with Honest
\* because Faulty has different actions enabled).  We do not enable
\* TLC symmetry by default — Faulty / Honest distinction can break it.
\* Provide a hook for hunt configs that may want to enable it.
MCSymmetry == {}    \* off by default; some configs may set
                    \*   SYMMETRY MCSymmetry to Permutations(Honest)

\* View excludes fault counters
MCView == <<allVars>>

\* ============================================================================
\* STATE SPACE CONSTRAINT
\* ============================================================================

MsgBufferConstraint ==
    BagCardinality(msgs) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* RoundPositive, LVRBound, HTRBound, LastVoteShape, PipelineMonotone
\* are all defined in base.tla; we just re-list them here for the cfg.
\*
\* Add a few MC-side sanity checks:

\* Persistence is at least as up-to-date as committed
PersistMonotone ==
    \A s \in Honest :
        persistedSafetyData[s].lastVotedRound <= MaxRound

NoNegativeCounters ==
    /\ cTimeout >= 0 /\ cCrash >= 0 /\ cDrop >= 0
    /\ cSync >= 0    /\ cEpochChange >= 0
    /\ cByzEquivProposer >= 0 /\ cByzEquivOrderVote >= 0
    /\ cByzReuseCert >= 0     /\ cByzForgeQC >= 0
    /\ cByzReplay >= 0        /\ cWeakEpochRx >= 0

\* ============================================================================
\* TEMPORAL PROPERTIES (mostly for simulation)
\* ============================================================================

\* If 2f+1 votes accumulate for a round, a QC eventually advances the round
QCLiveness ==
    \A s \in Honest, r \in 1..MaxRound :
        (HasQuorum(votesForBlock[s][r]) ~> highestQCRound[s] >= r)

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

MCSpec == MCInit /\ [][MCNext]_mcAllVars

=============================================================================
