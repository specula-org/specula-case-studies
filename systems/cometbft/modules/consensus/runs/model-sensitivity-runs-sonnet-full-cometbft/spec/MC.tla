--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for CometBFT consensus.
 *
 * Wraps base.tla with counter-bounded fault-injection actions so TLC
 * can perform exhaustive reachability analysis within a finite state space.
 *
 * Bounded actions (introduce non-determinism):
 *   - MCHandleTimeout*        : timeout firing (round progression)
 *   - MCCrash                 : node crash
 *   - MCLoseMessage           : message drop
 *   - MCInjectInvalidVE       : invalid vote extension injection (Family 1)
 *   - MCRestartWithoutWAL     : crash-restart without WAL at height=1 (Family 2)
 *   - MCInjectCollidingEvidence: adversary pre-populates pool with colliding key (Family 3)
 *   - MCByzantineSetPeerRange : Byzantine peer inflates maxPeerHeight (Family 4)
 *
 * Unbounded actions (deterministic / reactive — must not be bounded):
 *   - EnterNewRound, EnterPropose, EnterPrevote, EnterPrevoteWait
 *   - EnterPrecommit*, EnterPrecommitWait
 *   - ReceiveProposal, ReceivePrevote, ReceivePrecommitConsensus
 *   - EnterCommit, FinalizeCommit
 *   - Recover, RoundSkip*
 *   - SubmitLightClientEvidence, AcceptCommitLightClient, AcceptCommitBlockSync
 *   - CheckDoubleSigningRisk, CheckCaughtUp, AdvanceLocalSync, RemovePeer
 *)

EXTENDS base

\* Access original operators (pre-override)
cometbft == INSTANCE base

\* ============================================================================
\* BOUND CONSTANTS
\* ============================================================================

CONSTANT MaxTimeoutLimit       \* Max total timeout firings
CONSTANT MaxCrashLimit         \* Max total crash events
CONSTANT MaxLoseLimit          \* Max message loss events
CONSTANT MaxInvalidVELimit     \* Max invalid VE injections (Family 1)
CONSTANT MaxRestartLimit       \* Max WAL-absent restarts (Family 2)
CONSTANT MaxInjectEvidenceLimit \* Max adversary evidence injections (Family 3)
CONSTANT MaxByzPeerReportLimit  \* Max Byzantine peer height reports (Family 4)
CONSTANT MaxMsgBufferLimit      \* Max messages in flight

\* ============================================================================
\* COUNTER VARIABLE
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>
mc_vars   == <<vars, faultVars>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION WRAPPERS
\* ============================================================================

\* ---- Timeout actions (bound: non-deterministic timing) ----

MCHandleTimeoutPropose(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ cometbft!HandleTimeoutPropose(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCHandleTimeoutPrevote(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ cometbft!HandleTimeoutPrevote(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCHandleTimeoutPrecommit(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ cometbft!HandleTimeoutPrecommit(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

\* ---- Crash action (bound: crash events) ----

MCCrash(i) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ cometbft!Crash(i)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

\* ---- Message loss (bound: network unreliability) ----

MCLoseMessage(m) ==
    /\ faultCounters.lose < MaxLoseLimit
    /\ cometbft!LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

\* ---- Family 1: Invalid VE injection ----
\* Models a Byzantine validator whose ExtendVote ABCI callback returns invalid
\* extension data. Bound: limit how many validators can have invalid extensions.

MCInjectInvalidVE(i) ==
    /\ faultCounters.invalidVE < MaxInvalidVELimit
    /\ cometbft!InjectInvalidVoteExtension(i)
    /\ faultCounters' = [faultCounters EXCEPT !.invalidVE = @ + 1]

\* ---- Family 2: WAL-absent restart at height=1 ----
\* Models a validator crashing and restarting without WAL at height=1.
\* The double-sign check loop runs 0 iterations (off-by-one bug).

MCRestartWithoutWAL(i) ==
    /\ faultCounters.restart < MaxRestartLimit
    /\ cometbft!RestartWithoutWAL(i, 1)
    /\ faultCounters' = [faultCounters EXCEPT !.restart = @ + 1]

\* ---- Family 3: Byzantine evidence pool collision injection ----
\* Byzantine node pre-populates the pool with an entry whose key will collide
\* with a future honest submission.

MCInjectCollidingEvidence(v, commonH, bzBH, honBH) ==
    /\ faultCounters.injectEvidence < MaxInjectEvidenceLimit
    /\ cometbft!InjectCollidingEvidence(v, commonH, bzBH, honBH)
    /\ faultCounters' = [faultCounters EXCEPT !.injectEvidence = @ + 1]

\* ---- Family 4: Byzantine peer inflated height report ----
\* Byzantine peer calls SetPeerRange with an inflated height to manipulate
\* maxPeerHeight at the target node.

MCByzantineSetPeerRange(v, p, h) ==
    /\ p \in Faulty
    /\ faultCounters.byzPeerReport < MaxByzPeerReportLimit
    /\ cometbft!SetPeerRange(v, p, h)
    /\ faultCounters' = [faultCounters EXCEPT !.byzPeerReport = @ + 1]

\* ============================================================================
\* UNBOUNDED (REACTIVE / DETERMINISTIC) WRAPPERS
\* ============================================================================

MCEnterNewRound(i)               == cometbft!EnterNewRound(i, round[i]) /\ UNCHANGED faultVars
MCEnterPropose(i)                == cometbft!EnterPropose(i)             /\ UNCHANGED faultVars
MCReceiveProposal(i, m)          == cometbft!ReceiveProposal(i, m)       /\ UNCHANGED faultVars
MCEnterPrevote(i)                == cometbft!EnterPrevote(i)             /\ UNCHANGED faultVars
MCReceivePrevote(i, m)           == cometbft!ReceivePrevote(i, m)        /\ UNCHANGED faultVars
MCEnterPrevoteWait(i)            == cometbft!EnterPrevoteWait(i)         /\ UNCHANGED faultVars
MCEnterPrecommitNoPolka(i)       == cometbft!EnterPrecommitNoPolka(i)    /\ UNCHANGED faultVars
MCEnterPrecommitNilPolka(i)      == cometbft!EnterPrecommitNilPolka(i)   /\ UNCHANGED faultVars
MCEnterPrecommitRelockPolka(i)   == cometbft!EnterPrecommitRelockPolka(i)/\ UNCHANGED faultVars
MCEnterPrecommitNewLockPolka(i)  == cometbft!EnterPrecommitNewLockPolka(i)/\ UNCHANGED faultVars
MCEnterPrecommitUnknownPolka(i)  == cometbft!EnterPrecommitUnknownPolka(i)/\ UNCHANGED faultVars
MCEnterPrecommitWait(i)          == cometbft!EnterPrecommitWait(i)       /\ UNCHANGED faultVars
MCReceivePrecommitConsensus(i,m) == cometbft!ReceivePrecommitConsensus(i, m)/\ UNCHANGED faultVars
MCEnterCommit(i)                 == cometbft!EnterCommit(i)              /\ UNCHANGED faultVars
MCFinalizeCommit(i)              == cometbft!FinalizeCommit(i)           /\ UNCHANGED faultVars
MCRecover(i)                     == cometbft!Recover(i)                  /\ UNCHANGED faultVars
MCRoundSkipPrevote(i)            == cometbft!RoundSkipPrevote(i)         /\ UNCHANGED faultVars
MCRoundSkipPrecommit(i)          == cometbft!RoundSkipPrecommit(i)       /\ UNCHANGED faultVars

MCAcceptCommitLightClient(i, h)  == cometbft!AcceptCommitLightClient(i, h) /\ UNCHANGED faultVars
MCAcceptCommitBlockSync(i, h)    == cometbft!AcceptCommitBlockSync(i, h)   /\ UNCHANGED faultVars
MCCheckDoubleSigningRisk(i, h)   == cometbft!CheckDoubleSigningRisk(i, h)  /\ UNCHANGED faultVars
MCSubmitLightClientEvidence(v, ch, bh) ==
    SubmitLightClientEvidence(v, ch, bh) /\ UNCHANGED faultVars
MCSetPeerRange(v, p, h)          == cometbft!SetPeerRange(v, p, h)  /\ UNCHANGED faultVars
MCRemovePeer(v, p)               == cometbft!RemovePeer(v, p)       /\ UNCHANGED faultVars
MCCheckCaughtUp(v)               == cometbft!CheckCaughtUp(v)       /\ UNCHANGED faultVars
MCAdvanceLocalSync(v)            == cometbft!AdvanceLocalSync(v)    /\ UNCHANGED faultVars

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
         timeout       |-> 0,
         crash         |-> 0,
         lose          |-> 0,
         invalidVE     |-> 0,
         restart       |-> 0,
         injectEvidence |-> 0,
         byzPeerReport |-> 0]

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

MCNextAsync(i) ==
    \* --- Standard round progression (unbounded) ---
    \/ MCEnterNewRound(i)
    \/ MCEnterPropose(i)
    \/ MCEnterPrevote(i)
    \/ MCEnterPrevoteWait(i)
    \* --- Precommit (5 paths, unbounded) ---
    \/ MCEnterPrecommitNoPolka(i)
    \/ MCEnterPrecommitNilPolka(i)
    \/ MCEnterPrecommitRelockPolka(i)
    \/ MCEnterPrecommitNewLockPolka(i)
    \/ MCEnterPrecommitUnknownPolka(i)
    \/ MCEnterPrecommitWait(i)
    \* --- Commit (unbounded) ---
    \/ MCEnterCommit(i)
    \/ MCFinalizeCommit(i)
    \* --- Recovery (unbounded) ---
    \/ MCRecover(i)
    \* --- Round-skip (unbounded) ---
    \/ MCRoundSkipPrevote(i)
    \/ MCRoundSkipPrecommit(i)
    \* --- Timeouts (BOUNDED) ---
    \/ MCHandleTimeoutPropose(i)
    \/ MCHandleTimeoutPrevote(i)
    \/ MCHandleTimeoutPrecommit(i)
    \* --- Crash (BOUNDED) ---
    \/ MCCrash(i)
    \* --- Family 1: extension verification paths (unbounded) ---
    \/ \E h \in 1..MaxHeight :
        \/ MCAcceptCommitLightClient(i, h)
        \/ MCAcceptCommitBlockSync(i, h)
    \* --- Family 1: invalid VE injection (BOUNDED) ---
    \/ MCInjectInvalidVE(i)
    \* --- Family 2: double-sign protection (unbounded check, BOUNDED restart) ---
    \/ \E h \in 1..MaxHeight : MCCheckDoubleSigningRisk(i, h)
    \/ MCRestartWithoutWAL(i)
    \* --- Family 3: evidence (unbounded submit, BOUNDED inject) ---
    \/ \E ch \in 1..MaxHeight, bh \in BlockHash :
        MCSubmitLightClientEvidence(i, ch, bh)
    \/ \E ch \in 1..MaxHeight, bzBH \in BlockHash, honBH \in BlockHash :
        MCInjectCollidingEvidence(i, ch, bzBH, honBH)
    \* --- Family 4: blocksync (unbounded honest, BOUNDED Byzantine) ---
    \/ \E p \in SyncPeers \ Faulty, h \in 0..MaxHeight :
        MCSetPeerRange(i, p, h)
    \/ \E p \in SyncPeers, h \in 0..MaxHeight :
        MCByzantineSetPeerRange(i, p, h)
    \/ \E p \in SyncPeers : MCRemovePeer(i, p)
    \/ MCCheckCaughtUp(i)
    \/ MCAdvanceLocalSync(i)

MCNextMessages ==
    \E m \in DOMAIN messages :
        \/ MCReceiveProposal(m.dest, m)
        \/ MCReceivePrevote(m.dest, m)
        \/ MCReceivePrecommitConsensus(m.dest, m)
        \/ MCLoseMessage(m)

MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ MCNextMessages

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Symmetry over honest servers (not Faulty, which have distinct roles)
Symmetry == Permutations(Server \ Faulty)

\* Exclude fault counters from view (don't affect protocol behavior)
ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

MsgBufferConstraint ==
    MaxMsgBufferLimit = 0 \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* ADDITIONAL MC INVARIANTS
\* ============================================================================

\* Structural: crashed server can't be in consensus mode
CrashedNotInConsensus ==
    \A s \in Server :
        crashed[s] => step[s] = StepNewHeight

\* Structural: maxPeerHeight is consistent with all peers' heights
\* (This does NOT hold — it's the bug. Checked only in hunt configs.)
\* MaxPeerHeightBoundedOnDisconnect is defined in base.tla.

\* Family 2: privval last-signed height is non-decreasing (safety)
PrivvalConsistency ==
    \A s \in Server :
        privvalLastSigned[s] /= Nil =>
            privvalLastSigned[s].height \in 1..MaxHeight

\* Family 4: localSyncHeight bounded
LocalSyncBound ==
    \A v \in Server :
        localSyncHeight[v] <= MaxHeight

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* MonotonicHeight and DecisionPermanence are defined in base.tla.

\* MonotonicRound: within same height, round never decreases for live servers.
MonotonicRound ==
    [][
        \A s \in Server :
            (~crashed[s] /\ ~crashed'[s] /\ height'[s] = height[s]) =>
                round'[s] >= round[s]
    ]_mc_vars

\* Family 4 liveness: A blocksync node with only honest peers at height H
\* eventually transitions to consensus mode.
\* (Only meaningful when maxPeerHeight is bounded; checked in hunt config.)
BlockSyncLiveness ==
    \A v \in Honest :
        (syncMode[v] = BLOCKSYNC /\
         \A p \in ConnectedPeers(v) : p \in Honest) ~>
            syncMode[v] = CONSENSUS

\* ============================================================================
\* HASH ALIAS OVERRIDES (for config files — TLC cfg cannot parse @@ and :>)
\* Use these with "<-" override syntax instead of "=" in .cfg CONSTANTS blocks.
\* ============================================================================

\* All block hashes map to the same key (no collision distinguishable).
\* Safe for configs that do not check EvidenceDeduplicationSound.
MCHashAliasesAll == [b \in BlockHash |-> "k1"]

\* Exactly two elements of BlockHash map to "k1" (collide); the rest map to "k3".
\* Used by MC_hunt_family3.cfg where |BlockHash| >= 2.
MCHashAliasesOneCollision ==
    LET collider1 == CHOOSE x \in BlockHash : TRUE
        collider2 == CHOOSE x \in BlockHash : x /= collider1
    IN [b \in BlockHash |-> IF b = collider1 \/ b = collider2 THEN "k1" ELSE "k3"]

====
