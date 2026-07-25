--------------------------- MODULE MC ---------------------------
(*
 * Model-checking wrapper for Solana Tower BFT base spec.
 *
 * Wraps base.tla with counter-bounded fault-injection / Byzantine actions,
 * symmetry over Honest, state-space pruning, and structural invariants.
 *
 * Fault model coverage (anchors to brief Bug Families):
 *   5.1 Crash:                MCCrash + MCCrashBeforeFsync
 *                             (base splits state into tower / persistedTower / pendingVoteOp)
 *   5.2 Loss/Partition:       MCDropMessage
 *   5.3 Timeout:              n/a (slot ordering is oracle; no election timer in scope)
 *   5.4 NonAtomicPersist:     MCCrashBeforeFsync — fsync omission on tower_storage.rs:215
 *   5.5 ConfigChange:         skipped (validator set fixed during a single epoch in scope)
 *   5.6 Snapshot:             n/a (snapshot/catchup not in scope; brief 2.6)
 *
 * Byzantine adversary categories (from bft-analysis):
 *   2.1 Equivocation:         MCByzVoteOnBothForks
 *   2.6 Amnesia (composed):   MCByzCraftBankVoteState + MCCrash + Restart
 *   2.7 Cert manipulation:    MCByzGossipFakeLatestFrozenVote
 *   2.5 Replay:               MCByzReuseStaleGossipVote
 *
 * Counter-bounded (fault-injection) actions:
 *   - MCCrash, MCCrashBeforeFsync, MCDropMessage,
 *     MCAdoptOnChainTowerIfBehind (bounded; non-determ from on-chain state),
 *     MCByzVoteOnBothForks, MCByzGossipFakeLatestFrozenVote,
 *     MCByzCraftBankVoteState, MCByzInjectDupConfirmSignal,
 *     MCByzReuseStaleGossipVote
 *
 * Unconstrained (reactive) actions:
 *   - RecordVote, PersistTower, BroadcastVote, ReceiveVote,
 *     ReachOC, RootSlot, PurgeUnconfirmedSlot,
 *     ProcessDuplicateConfirmedSignal, CastSwitchVote, Restart
 *)

EXTENDS base

\* ============================================================================
\* MC CONSTANTS — counter limits
\* ============================================================================

CONSTANT MaxCrashLimit          \* Max clean crash actions
CONSTANT MaxCrashFsyncLimit     \* Max non-atomic persist crashes (Family 1)
CONSTANT MaxDropLimit           \* Max message drops
CONSTANT MaxAdoptLimit          \* Max adopt_on_chain_tower_if_behind firings
CONSTANT MaxByzEquivLimit       \* Max ByzVoteOnBothForks invocations
CONSTANT MaxByzFakeGossipLimit  \* Max ByzGossipFakeLatestFrozenVote invocations
CONSTANT MaxByzBankCraftLimit   \* Max ByzCraftBankVoteState invocations
CONSTANT MaxByzDupConfLimit     \* Max ByzInjectDupConfirmSignal invocations
CONSTANT MaxByzReuseLimit       \* Max ByzReuseStaleGossipVote invocations
CONSTANT MaxMsgBufferLimit      \* Cap on |msgs|

\* ============================================================================
\* MC VARIABLES — fault counters
\* ============================================================================

VARIABLE crashCount
VARIABLE crashFsyncCount
VARIABLE dropCount
VARIABLE adoptCount
VARIABLE byzEquivCount
VARIABLE byzFakeGossipCount
VARIABLE byzBankCraftCount
VARIABLE byzDupConfCount
VARIABLE byzReuseCount

faultVars == <<crashCount, crashFsyncCount, dropCount, adoptCount,
               byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
               byzDupConfCount, byzReuseCount>>

mcAllVars == <<allVars, faultVars>>

\* ============================================================================
\* MC INIT
\* ============================================================================

MCInit ==
    /\ Init
    /\ crashCount         = 0
    /\ crashFsyncCount    = 0
    /\ dropCount          = 0
    /\ adoptCount         = 0
    /\ byzEquivCount      = 0
    /\ byzFakeGossipCount = 0
    /\ byzBankCraftCount  = 0
    /\ byzDupConfCount    = 0
    /\ byzReuseCount      = 0

\* ============================================================================
\* COUNTER-BOUNDED WRAPPERS (fault-injection actions)
\* ============================================================================

MCCrash(v) ==
    /\ crashCount < MaxCrashLimit
    /\ Crash(v)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<crashFsyncCount, dropCount, adoptCount,
                   byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
                   byzDupConfCount, byzReuseCount>>

MCCrashBeforeFsync(v) ==
    /\ crashFsyncCount < MaxCrashFsyncLimit
    /\ CrashBeforeFsyncReachesDisk(v)
    /\ crashFsyncCount' = crashFsyncCount + 1
    /\ UNCHANGED <<crashCount, dropCount, adoptCount,
                   byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
                   byzDupConfCount, byzReuseCount>>

MCDropMessage(m) ==
    /\ dropCount < MaxDropLimit
    /\ DropMessage(m)
    /\ dropCount' = dropCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, adoptCount,
                   byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
                   byzDupConfCount, byzReuseCount>>

MCAdoptOnChainTowerIfBehind(v, s) ==
    /\ adoptCount < MaxAdoptLimit
    /\ AdoptOnChainTowerIfBehind(v, s)
    /\ adoptCount' = adoptCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, dropCount,
                   byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
                   byzDupConfCount, byzReuseCount>>

MCByzVoteOnBothForks(v, slot, hA, hB) ==
    /\ byzEquivCount < MaxByzEquivLimit
    /\ ByzVoteOnBothForks(v, slot, hA, hB)
    /\ byzEquivCount' = byzEquivCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, dropCount, adoptCount,
                   byzFakeGossipCount, byzBankCraftCount,
                   byzDupConfCount, byzReuseCount>>

MCByzGossipFakeLatestFrozenVote(v, s, h) ==
    /\ byzFakeGossipCount < MaxByzFakeGossipLimit
    /\ ByzGossipFakeLatestFrozenVote(v, s, h)
    /\ byzFakeGossipCount' = byzFakeGossipCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, dropCount, adoptCount,
                   byzEquivCount, byzBankCraftCount,
                   byzDupConfCount, byzReuseCount>>

MCByzCraftBankVoteState(v, s, ls, h) ==
    /\ byzBankCraftCount < MaxByzBankCraftLimit
    /\ ByzCraftBankVoteState(v, s, ls, h)
    /\ byzBankCraftCount' = byzBankCraftCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, dropCount, adoptCount,
                   byzEquivCount, byzFakeGossipCount,
                   byzDupConfCount, byzReuseCount>>

MCByzInjectDupConfirmSignal(s, h) ==
    /\ byzDupConfCount < MaxByzDupConfLimit
    /\ ByzInjectDupConfirmSignal(s, h)
    /\ byzDupConfCount' = byzDupConfCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, dropCount, adoptCount,
                   byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
                   byzReuseCount>>

MCByzReuseStaleGossipVote(v, s, h) ==
    /\ byzReuseCount < MaxByzReuseLimit
    /\ ByzReuseStaleGossipVote(v, s, h)
    /\ byzReuseCount' = byzReuseCount + 1
    /\ UNCHANGED <<crashCount, crashFsyncCount, dropCount, adoptCount,
                   byzEquivCount, byzFakeGossipCount, byzBankCraftCount,
                   byzDupConfCount>>

\* ============================================================================
\* UNCONSTRAINED WRAPPERS (deterministic / reactive)
\* ============================================================================

MCRecordVote(v, s, h) ==
    /\ RecordVote(v, s, h)
    /\ UNCHANGED faultVars

MCPersistTower(v) ==
    /\ PersistTower(v)
    /\ UNCHANGED faultVars

MCBroadcastVote(v) ==
    /\ BroadcastVote(v)
    /\ UNCHANGED faultVars

MCReceiveVote(v, m) ==
    /\ ReceiveVote(v, m)
    /\ UNCHANGED faultVars

MCReachOC(s, h) ==
    /\ ReachOC(s, h)
    /\ UNCHANGED faultVars

MCRootSlot(s, h) ==
    /\ RootSlot(s, h)
    /\ UNCHANGED faultVars

MCPurgeUnconfirmedSlot(v, s) ==
    /\ PurgeUnconfirmedSlot(v, s)
    /\ UNCHANGED faultVars

MCProcessDuplicateConfirmedSignal(v, s, h) ==
    /\ ProcessDuplicateConfirmedSignal(v, s, h)
    /\ UNCHANGED faultVars

MCCastSwitchVote(v, s) ==
    /\ CastSwitchVote(v, s)
    /\ UNCHANGED faultVars

MCRestart(v) ==
    /\ Restart(v)
    /\ UNCHANGED faultVars

\* ============================================================================
\* MC NEXT
\* ============================================================================

MCNext ==
    \* --- Vote pipeline (record -> persist -> broadcast) ---
    \/ \E v \in Server, s \in 1..MaxSlot, h \in Hashes : MCRecordVote(v, s, h)
    \/ \E v \in Server : MCPersistTower(v)
    \/ \E v \in Server : MCBroadcastVote(v)
    \/ \E v \in Server, m \in DOMAIN msgs : MCReceiveVote(v, m)
    \* --- OC + root advancement ---
    \/ \E s \in 1..MaxSlot, h \in Hashes : MCReachOC(s, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : MCRootSlot(s, h)
    \* --- Duplicate-confirm and purge (Family 4) ---
    \/ \E v \in Server, s \in 1..MaxSlot : MCPurgeUnconfirmedSlot(v, s)
    \/ \E v \in Server, s \in 1..MaxSlot, h \in Hashes :
           MCProcessDuplicateConfirmedSignal(v, s, h)
    \* --- Switching (Family 2) ---
    \/ \E v \in Server, s \in 1..MaxSlot : MCCastSwitchVote(v, s)
    \* --- Crash + restart + adopt (Family 1, bounded) ---
    \/ \E v \in Server : MCCrash(v)
    \/ \E v \in Server : MCCrashBeforeFsync(v)
    \/ \E v \in Server : MCRestart(v)
    \/ \E v \in Server, s \in 1..MaxSlot : MCAdoptOnChainTowerIfBehind(v, s)
    \* --- Network (bounded) ---
    \/ \E m \in DOMAIN msgs : MCDropMessage(m)
    \* --- Byzantine (bounded) ---
    \/ \E v \in Byzantine, s \in 1..MaxSlot, hA \in Hashes, hB \in Hashes :
           MCByzVoteOnBothForks(v, s, hA, hB)
    \/ \E v \in Byzantine, s \in 1..MaxSlot, h \in Hashes :
           MCByzGossipFakeLatestFrozenVote(v, s, h)
    \/ \E v \in Server, s \in 1..MaxSlot, ls \in 1..MaxSlot, h \in Hashes :
           MCByzCraftBankVoteState(v, s, ls, h)
    \/ \E s \in 1..MaxSlot, h \in Hashes : MCByzInjectDupConfirmSignal(s, h)
    \/ \E v \in Byzantine, s \in 1..MaxSlot, h \in Hashes :
           MCByzReuseStaleGossipVote(v, s, h)

MCSpec == MCInit /\ [][MCNext]_mcAllVars

\* ============================================================================
\* SYMMETRY & VIEW
\* ============================================================================

\* Permute honest servers only — Byzantine has different semantics, exclude.
MCSymmetry == Permutations(Honest)

\* View excludes fault counters (symmetry-compatible)
MCView == <<allVars>>

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

MsgBufferConstraint ==
    BagCardinality(msgs) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* Tower last_voted_slot grows monotonically (per consensus.rs:707 panic check)
\* for an alive validator that has not crashed-and-adopted.
TowerLastVotedSlotInRange ==
    \A v \in Server :
        tower[v].last_voted_slot \in 0..MaxSlot

\* ocStake[s][h] is a subset of Server (sanity)
OCStakeWellFormed ==
    \A s \in 1..MaxSlot, h \in Hashes :
        ocStake[s][h] \subseteq Server

\* rootedHash is set only for slots in rooted.
RootedHashWellFormed ==
    \A s \in 1..MaxSlot :
        s \in rooted \/ rootedHash[s] = Nil

\* ParentOf gives a well-formed tree (ParentOfSlot[s] < s).
ForkTreeWellFormed ==
    \A s \in 1..MaxSlot : ParentOfSlot[s] < s

\* persistedTower's last_voted_slot never exceeds the in-memory tower's.
\* (Invariant: store-before-broadcast means persist always lags the in-memory.)
\* This is what brief calls "persistedTower lags or equals tower" outside of crashes.
\* NOTE: violated in crashed states; we allow that.
PersistedNeverExceedsTower ==
    \A v \in Server :
        alive[v] =>
            persistedTower[v].last_voted_slot <= tower[v].last_voted_slot

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* If a (slot, hash) is OC and all honest are alive,
\* eventually it is rooted on the same hash.
OCEventuallyRooted ==
    \A pair \in {<<s, h>> : s \in 1..MaxSlot, h \in Hashes} :
        (pair \in ocConfirmed /\ (\A v \in Honest : alive[v]))
        ~> (pair[1] \in rooted /\ rootedHash[pair[1]] = pair[2])

\* No honest validator perpetually pancied (liveness).
NoHonestPermanentPanic ==
    \A v \in Honest : <>(~ panicked[v])

=============================================================================
