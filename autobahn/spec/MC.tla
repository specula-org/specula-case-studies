--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for Autobahn BFT consensus.
 *
 * Wraps the base spec with counter-bounded fault-injection actions.
 * Deterministic/reactive actions pass through unbounded.
 *
 * Counter-bounded actions (fault injection):
 *   - ByzantinePrepare (equivocation)
 *   - ByzantineConfirm
 *   - ByzantineCommit
 *   - SendTimeout (view change trigger)
 *   - LoseMessage (network unreliability)
 *
 * Unbounded actions (deterministic/reactive):
 *   - SendPrepare, SendConfirm, SendCommit, SendFastCommit
 *   - ReceivePrepare, ReceiveConfirm, ReceiveCommit
 *   - AdvanceView, GeneratePrepareFromTC, EnterSlot
 *)

EXTENDS base

\* Access original (un-overridden) operator definitions.
autobahn == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxByzantineLimit     \* Max total Byzantine message sends
CONSTANT MaxTimeoutLimit       \* Max total timeout sends
CONSTANT MaxLoseLimit          \* Max message loss events
CONSTANT MaxMsgBufferLimit     \* Max messages in flight

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

\* --- Byzantine actions (Family 1, 3: equivocation and unauthorized proposals) ---

MCByzantinePrepare(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ autobahn!ByzantinePrepare(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

MCByzantineConfirm(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ autobahn!ByzantineConfirm(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

MCByzantineCommit(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ autobahn!ByzantineCommit(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

\* --- Timeout actions (Family 2: bound view change triggering) ---

MCSendTimeout(s, sl) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ autobahn!SendTimeout(s, sl)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

\* --- Message loss (network unreliability) ---

MCLoseMessage(m) ==
    /\ faultCounters.lose < MaxLoseLimit
    /\ autobahn!LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

\* ============================================================================
\* UNBOUNDED (DETERMINISTIC/REACTIVE) ACTIONS
\* ============================================================================

MCSendPrepare(s, sl, v, val) ==
    /\ autobahn!SendPrepare(s, sl, v, val)
    /\ UNCHANGED faultVars

MCSendConfirm(s, sl, v, val) ==
    /\ autobahn!SendConfirm(s, sl, v, val)
    /\ UNCHANGED faultVars

MCSendCommit(s, sl, v, val) ==
    /\ autobahn!SendCommit(s, sl, v, val)
    /\ UNCHANGED faultVars

MCSendFastCommit(s, sl, v, val) ==
    /\ autobahn!SendFastCommit(s, sl, v, val)
    /\ UNCHANGED faultVars

MCReceivePrepare(s, sl, v) ==
    /\ autobahn!ReceivePrepare(s, sl, v)
    /\ UNCHANGED faultVars

MCReceiveConfirm(s, sl, v) ==
    /\ autobahn!ReceiveConfirm(s, sl, v)
    /\ UNCHANGED faultVars

MCReceiveCommit(s, sl, v) ==
    /\ autobahn!ReceiveCommit(s, sl, v)
    /\ UNCHANGED faultVars

MCAdvanceView(s, sl, v) ==
    /\ autobahn!AdvanceView(s, sl, v)
    /\ UNCHANGED faultVars

MCGeneratePrepareFromTC(s, sl, v) ==
    /\ autobahn!GeneratePrepareFromTC(s, sl, v)
    /\ UNCHANGED faultVars

MCEnterSlot(s, sl) ==
    /\ autobahn!EnterSlot(s, sl)
    /\ UNCHANGED faultVars

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
         byzantine |-> 0,
         timeout   |-> 0,
         lose      |-> 0]

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

MCNextAsync(s) ==
    \/ \E sl \in Slot, v \in View, val \in Values :
        \/ MCSendPrepare(s, sl, v, val)
        \/ MCSendConfirm(s, sl, v, val)
        \/ MCSendCommit(s, sl, v, val)
        \/ MCSendFastCommit(s, sl, v, val)
    \/ \E sl \in Slot, v \in View :
        \/ MCReceivePrepare(s, sl, v)
        \/ MCReceiveConfirm(s, sl, v)
        \/ MCReceiveCommit(s, sl, v)
        \/ MCAdvanceView(s, sl, v)
        \/ MCGeneratePrepareFromTC(s, sl, v)
    \/ \E sl \in Slot :
        \/ MCEnterSlot(s, sl)
        \/ MCSendTimeout(s, sl)

MCNextByzantine ==
    \E s \in Byzantine, sl \in Slot, v \in View, val \in Values :
        \/ MCByzantinePrepare(s, sl, v, val)
        \/ MCByzantineConfirm(s, sl, v, val)
        \/ MCByzantineCommit(s, sl, v, val)

MCNextLose ==
    \E m \in messages :
        MCLoseMessage(m)

MCNext ==
    \/ \E s \in Server : MCNextAsync(s)
    \/ MCNextByzantine
    \/ MCNextLose

\* ============================================================================
\* SPECIFICATIONS
\* ============================================================================

mc_vars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW DEFINITIONS
\* ============================================================================

\* Symmetry reduction: honest servers are interchangeable
\* Note: Byzantine server is NOT included in symmetry
HonestSymmetry == Permutations(Honest)

\* Exclude fault counters from view (they don't affect protocol behavior)
ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE CONSTRAINTS
\* ============================================================================

\* Bound the message buffer size
MsgBufferConstraint == Cardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* INVARIANTS (for MC.cfg)
\* ============================================================================

\* Standard safety
MCAgreementSafety == autobahn!AgreementSafety
MCCommitValidity == autobahn!CommitValidity
MCTypeOK == autobahn!TypeOK

\* Structural
MCViewBound == autobahn!ViewBound

\* Bug-family-specific (commented out in MC.cfg, used in hunt configs)
MCViewChangeSafety == autobahn!ViewChangeSafety
MCFastPathCorrectness == autobahn!FastPathCorrectness

====
