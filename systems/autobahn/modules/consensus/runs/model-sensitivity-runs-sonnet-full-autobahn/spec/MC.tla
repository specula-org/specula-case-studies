---------------------------- MODULE MC ----------------------------
(*
 * MC.tla — Model Checking wrapper for the Autobahn base spec.
 *
 * Bounds non-deterministic (fault-injection) actions with counters.
 * Deterministic/reactive actions pass through unchanged.
 *
 * MC constants (set in MC.cfg):
 *   MaxByzEquivocate  — F1: how many times a Byz leader may equivocate
 *   MaxByzTimeout     — F2: how many forged Timeout msgs Byzantine nodes may send
 *   MaxTimeoutPerView — honest timeout actions per (slot,view)
 *   MaxFormTC         — how many TCs may form (all views combined)
 *   MaxHSCrash        — F4: crash events per node
 *   MaxViewAdvance    — total ProcessTC actions (caps view inflation)
 *)

EXTENDS autobahn

CONSTANTS
    MaxByzEquivocate,   \* F1 fault bound
    MaxByzTimeout,      \* F2 fault bound
    MaxTimeoutPerView,  \* honest timeout bound
    MaxFormTC,          \* TC formation bound
    MaxHSCrash,         \* F4 crash bound
    MaxViewAdvance      \* view advance bound

VARIABLES
    faultCounters  \* record of fault counts

MCInit ==
    /\ Init
    /\ faultCounters = [byzEquivocate |-> 0,
                        byzTimeout    |-> 0,
                        hscrash       |-> 0,
                        tcFormed_cnt  |-> 0,
                        viewAdvance   |-> 0,
                        timeout_cnt   |-> 0]

\* --- Bounded fault wrappers ---

\* F1: Byzantine equivocation at Prepare.
\* Bounded to prevent infinite equivocation loops.
MCByzEquivocatePrepare(n, s, v, P1, P2) ==
    /\ faultCounters.byzEquivocate < MaxByzEquivocate
    /\ ByzEquivocatePrepare(n, s, v, P1, P2)
    /\ faultCounters' = [faultCounters EXCEPT !.byzEquivocate = @ + 1]

\* F2: Byzantine forged Timeout.
MCByzSendTimeout(n, s, v, w) ==
    /\ faultCounters.byzTimeout < MaxByzTimeout
    /\ ByzSendTimeout(n, s, v, w)
    /\ faultCounters' = [faultCounters EXCEPT !.byzTimeout = @ + 1]

\* F4: HotStuff crash.
MCHSCrash(n) ==
    /\ faultCounters.hscrash < MaxHSCrash
    /\ HSCrash(n)
    /\ faultCounters' = [faultCounters EXCEPT !.hscrash = @ + 1]

\* F2/3: TC formation — bound to limit view-change explosion.
MCFormTC(s, v) ==
    /\ faultCounters.tcFormed_cnt < MaxFormTC
    /\ FormTC(s, v)
    /\ faultCounters' = [faultCounters EXCEPT !.tcFormed_cnt = @ + 1]

\* Bound view advance to prevent unbounded view number growth.
MCProcessTC(n, s, v) ==
    /\ faultCounters.viewAdvance < MaxViewAdvance
    /\ ProcessTC(n, s, v)
    /\ faultCounters' = [faultCounters EXCEPT !.viewAdvance = @ + 1]

\* Bound honest timeouts per (slot,view) to prevent explosion.
MCSendTimeout(n, s, v) ==
    /\ faultCounters.timeout_cnt < MaxTimeoutPerView * Cardinality(Slots) * Cardinality(Views)
    /\ SendTimeout(n, s, v)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout_cnt = @ + 1]

\* --- Passthrough wrappers (reactive; not bounded) ---

MCSendPrepare(n, s, v, P) ==
    /\ SendPrepare(n, s, v, P)
    /\ UNCHANGED faultCounters

MCCastPrepareVote(n, s, v) ==
    /\ CastPrepareVote(n, s, v)
    /\ UNCHANGED faultCounters

MCFormPrepareQC(s, v, voters, P) ==
    /\ FormPrepareQC(s, v, voters, P)
    /\ UNCHANGED faultCounters

MCSendConfirm(n, s, v) ==
    /\ SendConfirm(n, s, v)
    /\ UNCHANGED faultCounters

MCCastConfirmVote(n, s, v) ==
    /\ CastConfirmVote(n, s, v)
    /\ UNCHANGED faultCounters

MCFormConfirmQC(s, v, voters) ==
    /\ FormConfirmQC(s, v, voters)
    /\ UNCHANGED faultCounters

MCSendCommit(n, s, v) ==
    /\ SendCommit(n, s, v)
    /\ UNCHANGED faultCounters

MCProcessCommit(n, s, v) ==
    /\ ProcessCommit(n, s, v)
    /\ UNCHANGED faultCounters

MCCleanSlotPeriods(s) ==
    /\ CleanSlotPeriods(s)
    /\ UNCHANGED faultCounters

MCHSPublishBlock(r, pr, P) ==
    /\ HSPublishBlock(r, pr, P)
    /\ UNCHANGED faultCounters

MCHSMakeVote(n, r) ==
    /\ HSMakeVote(n, r)
    /\ UNCHANGED faultCounters

MCHSProcessBlock(n, r) ==
    /\ HSProcessBlock(n, r)
    /\ UNCHANGED faultCounters

MCHSCrashRecover(n) ==
    /\ HSCrashRecover(n)
    /\ UNCHANGED faultCounters

MCNext ==
    \* --- Autobahn 3-phase ---
    \/ \E n \in HonestNodes, s \in Slots, v \in Views, P \in Proposals :
           MCSendPrepare(n, s, v, P)
    \/ \E n \in ByzNodes, s \in Slots, v \in Views, P1, P2 \in Proposals :
           MCByzEquivocatePrepare(n, s, v, P1, P2)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           MCCastPrepareVote(n, s, v)
    \/ \E s \in Slots, v \in Views, voters \in SUBSET Nodes, P \in Proposals :
           MCFormPrepareQC(s, v, voters, P)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           MCSendConfirm(n, s, v)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           MCCastConfirmVote(n, s, v)
    \/ \E s \in Slots, v \in Views, voters \in SUBSET Nodes :
           MCFormConfirmQC(s, v, voters)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           MCSendCommit(n, s, v)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           MCProcessCommit(n, s, v)
    \/ \E s \in Slots : MCCleanSlotPeriods(s)
    \* --- View change ---
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           MCSendTimeout(n, s, v)
    \/ \E n \in ByzNodes, s \in Slots, v \in Views, w \in Views \cup {None} :
           MCByzSendTimeout(n, s, v, w)
    \/ \E s \in Slots, v \in Views : MCFormTC(s, v)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views : MCProcessTC(n, s, v)
    \* --- HotStuff ---
    \/ \E r \in HSRounds, pr \in HSRounds \cup {0}, P \in Proposals :
           MCHSPublishBlock(r, pr, P)
    \/ \E n \in HonestNodes, r \in HSRounds : MCHSMakeVote(n, r)
    \/ \E n \in HonestNodes, r \in HSRounds : MCHSProcessBlock(n, r)
    \/ \E n \in HonestNodes : MCHSCrash(n)
    \/ \E n \in HonestNodes : MCHSCrashRecover(n)

MCSpec == MCInit /\ [][MCNext]_<<allVars, faultCounters>>

\* --- Symmetry ---
\* Nodes are symmetric; exploit for state-space reduction.
\* Do NOT include faultCounters in the symmetry set (it's a record, not a set function).
Perms == Permutations(HonestNodes)

\* --- Message buffer pruning ---
\* Bound the total number of messages to prevent state explosion.
CONSTANT MaxMsgBuf
MsgBufOK == Cardinality(msgs) <= MaxMsgBuf

=============================================================================
