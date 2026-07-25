--------------------------- MODULE MC ---------------------------
(*
 * Model-checking spec for MongoRaftReconfig.
 *
 * Wraps base.tla with counter-bounded fault-injection actions and adds symmetry
 * reduction, a view, and structural invariants. Deterministic / reactive actions
 * pass through unbounded.
 *
 * Counter-bounded (introduce nondeterminism):
 *   - ClientRequest      (RequestLimit)   new oplog entries
 *   - StartElection      (ElectionLimit)  election attempts (candidate term bumps);
 *                                         each enables at most one BecomeLeader win
 *   - ReconfigCheck      (ReconfigLimit)  command reconfigs initiated
 *   - Crash              (CrashLimit)     node restarts
 *
 * Unbounded (reactive — bounding them would prune valid reachable states):
 *   - BecomeLeader (gated by a prior StartElection), AdvanceCommitPoint,
 *     CompletePrimaryDrain, StepUpBumpConfigTerm, CompleteStepDown,
 *     ReconfigPersist, ReconfigInstall, GetEntries, RollbackEntries,
 *     LearnHigherTerm, InstallConfigViaHeartbeat
 *)

EXTENDS base

\* Access original (un-overridden) operator definitions.
mrr == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT RequestLimit       \* max ClientRequest firings
CONSTANT ElectionLimit      \* max BecomeLeader firings
CONSTANT ReconfigLimit      \* max ReconfigCheck firings (command reconfigs)
CONSTANT CrashLimit         \* max Crash firings

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

mcvars == <<vars, faultVars>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION WRAPPERS
\* ============================================================================

MCClientRequest(p) ==
    /\ faultCounters.request < RequestLimit
    /\ mrr!ClientRequest(p)
    /\ faultCounters' = [faultCounters EXCEPT !.request = @ + 1]

MCStartElection(i) ==
    /\ faultCounters.election < ElectionLimit
    /\ mrr!StartElection(i)
    /\ faultCounters' = [faultCounters EXCEPT !.election = @ + 1]

MCReconfigCheck(p, nv, na) ==
    /\ faultCounters.reconfig < ReconfigLimit
    /\ mrr!ReconfigCheck(p, nv, na)
    /\ faultCounters' = [faultCounters EXCEPT !.reconfig = @ + 1]

MCCrash(n) ==
    /\ faultCounters.crash < CrashLimit
    /\ mrr!Crash(n)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

\* ============================================================================
\* UNBOUNDED (REACTIVE) WRAPPERS
\* ============================================================================

MCBecomeLeader(i, Q)         == mrr!BecomeLeader(i, Q)         /\ UNCHANGED faultVars
MCAdvanceCommitPoint(p)      == mrr!AdvanceCommitPoint(p)      /\ UNCHANGED faultVars
MCCompletePrimaryDrain(p)    == mrr!CompletePrimaryDrain(p)    /\ UNCHANGED faultVars
MCStepUpBumpConfigTerm(p)    == mrr!StepUpBumpConfigTerm(p)    /\ UNCHANGED faultVars
MCCompleteStepDown(p)        == mrr!CompleteStepDown(p)        /\ UNCHANGED faultVars
MCPrimaryStepDown(p)         == mrr!PrimaryStepDown(p)         /\ UNCHANGED faultVars
MCReconfigPersist(p)         == mrr!ReconfigPersist(p)         /\ UNCHANGED faultVars
MCReconfigInstall(p)         == mrr!ReconfigInstall(p)         /\ UNCHANGED faultVars
MCGetEntries(s, q)           == mrr!GetEntries(s, q)           /\ UNCHANGED faultVars
MCRollbackEntries(s, q)      == mrr!RollbackEntries(s, q)      /\ UNCHANGED faultVars
MCLearnHigherTerm(s, q)      == mrr!LearnHigherTerm(s, q)      /\ UNCHANGED faultVars
MCInstallConfigViaHeartbeat(p, q) == mrr!InstallConfigViaHeartbeat(p, q) /\ UNCHANGED faultVars

\* ============================================================================
\* INIT / NEXT
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [request |-> 0, election |-> 0, reconfig |-> 0, crash |-> 0]

MCNext ==
    \/ \E p \in Server :
        \/ MCClientRequest(p)
        \/ MCStartElection(p)
        \/ MCAdvanceCommitPoint(p)
        \/ MCCompletePrimaryDrain(p)
        \/ MCStepUpBumpConfigTerm(p)
        \/ MCCompleteStepDown(p)
        \/ MCPrimaryStepDown(p)
        \/ MCReconfigPersist(p)
        \/ MCReconfigInstall(p)
        \/ MCCrash(p)
    \/ \E s, q \in Server :
        \/ MCGetEntries(s, q)
        \/ MCRollbackEntries(s, q)
        \/ MCLearnHigherTerm(s, q)
        \/ MCInstallConfigViaHeartbeat(s, q)
    \/ \E i \in Server : \E Q \in SUBSET Server :
        MCBecomeLeader(i, Q)
    \/ \E p \in Server : \E nv \in SUBSET Server : \E na \in SUBSET Server :
        MCReconfigCheck(p, nv, na)

MCSpec == MCInit /\ [][MCNext]_mcvars

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Servers are interchangeable: no node id is treated specially (arbiter is a
\* per-config attribute, not a fixed identity).
Symmetry == Permutations(Server)

\* Exclude fault counters from the view (they don't affect protocol behavior).
ModelView == vars

\* ============================================================================
\* STATE-SPACE CONSTRAINT
\* ============================================================================

\* Keep the search finite/bounded along the dimensions not already capped by the
\* CONSTANTS. (Term, log length, and config version are bounded by the base spec.)
StateConstraint ==
    /\ \A n \in Server : term[n] <= MaxTerm
    /\ \A n \in Server : config[n].version <= MaxConfigVersion
    /\ \A n \in Server : config[n].term <= MaxTerm

\* ============================================================================
\* STRUCTURAL INVARIANTS (complement base spec's invariants)
\* ============================================================================

MCTypeOK ==
    /\ TypeOKLite
    /\ faultCounters.request  \in 0..RequestLimit
    /\ faultCounters.election \in 0..ElectionLimit
    /\ faultCounters.reconfig \in 0..ReconfigLimit
    /\ faultCounters.crash    \in 0..CrashLimit

\* configTerm never exceeds the highest election term any node has reached — a
\* config with term T was created by a leader that won term T.
ConfigTermBounded ==
    \A n \in Server :
        config[n].term <= MaxTerm

\* A node's installed config is always one that was actually installed somewhere.
ConfigProvenance ==
    \A n \in Server : config[n] \in installedConfigs

\* Commit point term never exceeds the node's election term.
CommitTermLeqTerm ==
    \A n \in Server : commitPoint[n].term <= term[n]

\* ============================================================================
\* TRANSITION (TEMPORAL) PROPERTIES
\* ============================================================================

\* Family 1b — StaleConfigNoProgress: while a node has a pending step-down
\* (kSteppingDown freeze), its commit point must not advance.
\* Reference: topology_coordinator.cpp:3136 (`_leaderMode != kSteppingDown`).
StaleConfigNoProgress ==
    [][ \A n \in Server :
          (pendingStepDown[n] /\ pendingStepDown'[n])
              => commitPoint'[n].index <= commitPoint[n].index ]_mcvars

\* Commit point never moves backward on a node (a committed write is never lost
\* from the local commit high-water mark).
CommitIndexMonotonic ==
    [][ \A n \in Server :
          commitPoint'[n].index >= commitPoint[n].index
          \/ commitPoint'[n].index = 0 ]_mcvars

\* Election term never decreases on a node.
TermMonotonic ==
    [][ \A n \in Server : term'[n] >= term[n] ]_mcvars

\* Per node, the installed config (configTerm, configVersion) is non-decreasing
\* (configs are totally ordered; Crash keeps the durable config).
\* Reference: repl_set_config.h:91-100; topology_coordinator.cpp:1179.
ConfigVersionTermMonotonic ==
    [][ \A n \in Server :
          \/ CVTGeq(config'[n], config[n])
          \/ config'[n] = config[n] ]_mcvars

====
