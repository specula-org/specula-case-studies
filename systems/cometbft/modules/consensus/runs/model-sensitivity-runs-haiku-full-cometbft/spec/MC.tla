---- MODULE MC ----
\* Model Checking wrapper for base spec with counter-bounded fault injection
\* Exhaustive state-space exploration with bounds on non-deterministic actions

EXTENDS base, Naturals, Sequences

\* ============================================================================
\* MODEL CHECKING CONSTANTS AND COUNTERS
\* ============================================================================

CONSTANT MCTimeoutLimit     \* Max number of timeouts before constraint
CONSTANT MCCrashLimit       \* Max number of crashes
CONSTANT MCMessageLossLimit \* Max message loss events
CONSTANT MCBlockAssemblyLimit  \* Max block assembly race events
CONSTANT MCByzantineEquivocationLimit  \* Max Byzantine equivocations

\* Counter state
VARIABLE mcCounters

mcVars == mcCounters

\* ============================================================================
\* COUNTER-BOUNDED ACTION WRAPPERS
\* ============================================================================

\* Wrap timeout action with counter
MCHandleTimeout(v) ==
    /\ mcCounters.timeouts < MCTimeoutLimit
    /\ HandleTimeout(v)
    /\ mcCounters' = [mcCounters EXCEPT !.timeouts = @ + 1]

\* Wrap crash/recovery action with counter
MCCrashAndRecover(v) ==
    /\ mcCounters.crashes < MCCrashLimit
    /\ CrashAndRecover(v)
    /\ mcCounters' = [mcCounters EXCEPT !.crashes = @ + 1]

\* Wrap Byzantine proposal equivocation with counter
MCByzantineEquivocateProposal(v, proposal1, proposal2) ==
    /\ mcCounters.byzEquivocations < MCByzantineEquivocationLimit
    /\ ByzantineEquivocateProposal(v, proposal1, proposal2)
    /\ mcCounters' = [mcCounters EXCEPT !.byzEquivocations = @ + 1]

\* Wrap Byzantine vote equivocation with counter
MCByzantineEquivocateVote(v, vote1, vote2) ==
    /\ mcCounters.byzEquivocations < MCByzantineEquivocationLimit
    /\ ByzantineEquivocateVote(v, vote1, vote2)
    /\ mcCounters' = [mcCounters EXCEPT !.byzEquivocations = @ + 1]

\* Unbounded (reactive) actions pass through with counter unchanged
MCEnterNewRound(v) ==
    /\ EnterNewRound(v)
    /\ UNCHANGED mcCounters

MCEnterPrevote(v) ==
    /\ EnterPrevote(v)
    /\ UNCHANGED mcCounters

MCEnterPrecommit(v) ==
    /\ EnterPrecommit(v)
    /\ UNCHANGED mcCounters

MCUnlockOnPol(v) ==
    /\ UnlockOnPol(v)
    /\ UNCHANGED mcCounters

MCUpdateValidBlock(v) ==
    /\ UpdateValidBlock(v)
    /\ UNCHANGED mcCounters

MCReceiveProposal(v, proposal) ==
    /\ ReceiveProposal(v, proposal)
    /\ UNCHANGED mcCounters

MCReceiveBlockPart(v, h, r) ==
    /\ ReceiveBlockPart(v, h, r)
    /\ UNCHANGED mcCounters

MCHandleCompleteProposal(v) ==
    /\ HandleCompleteProposal(v)
    /\ UNCHANGED mcCounters

MCCheckVote(v, incomingVote) ==
    /\ CheckVote(v, incomingVote)
    /\ UNCHANGED mcCounters

MCAddVote(v, incomingVote) ==
    /\ AddVote(v, incomingVote)
    /\ UNCHANGED mcCounters

MCCheckVoteExtension(v, incomingVote) ==
    /\ CheckVoteExtension(v, incomingVote)
    /\ UNCHANGED mcCounters

\* ============================================================================
\* MODEL CHECKING INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ mcCounters = [timeouts |-> 0, crashes |-> 0, byzEquivocations |-> 0]

\* ============================================================================
\* MODEL CHECKING NEXT-STATE RELATION
\* ============================================================================

MCNext ==
    \E v \in Validators :
        \/ MCEnterNewRound(v)
        \/ MCEnterPrevote(v)
        \/ MCEnterPrecommit(v)
        \/ MCUnlockOnPol(v)
        \/ MCUpdateValidBlock(v)
        \/ MCHandleTimeout(v)
        \/ \E h \in 1..MaxHeight, r \in 0..MaxRound :
            \/ MCReceiveProposal(v, [height |-> h, round |-> r, block |-> 1..MaxHeight])
            \/ MCReceiveBlockPart(v, h, r)
            \/ MCHandleCompleteProposal(v)
        \/ \E vote \in [height: 1..MaxHeight, round: 0..MaxRound,
                        type: {PrevoteType, PrecommitType},
                        voter: Validators, blockID: 1..MaxHeight \cup {NULL_BLOCK},
                        extension: {NULL_PROOF, 1..MaxHeight}] :
            \/ MCCheckVote(v, vote)
            \/ MCAddVote(v, vote)
            \/ MCCheckVoteExtension(v, vote)
        \/ \E proposal1, proposal2 \in [height: 1..MaxHeight, round: 0..MaxRound, block: 1..MaxHeight] :
            MCByzantineEquivocateProposal(v, proposal1, proposal2)
        \/ \E vote1, vote2 \in [height: 1..MaxHeight, round: 0..MaxRound,
                                type: {PrevoteType, PrecommitType},
                                blockID: 1..MaxHeight \cup {NULL_BLOCK},
                                extension: {NULL_PROOF, 1..MaxHeight}] :
            MCByzantineEquivocateVote(v, vote1, vote2)
        \/ MCCrashAndRecover(v)

\* ============================================================================
\* TYPE CORRECTNESS
\* ============================================================================

MCTypeOK ==
    /\ Validators /= {}
    /\ Faulty \subseteq Validators
    /\ \A v \in Validators :
        /\ heightRound[v].height \in 1..MaxHeight
        /\ heightRound[v].round \in 0..MaxRound
        /\ step[v] \in {RoundStepNewHeight, RoundStepPropose, RoundStepPrevote, RoundStepPrecommit}
        /\ proposedBlock[v] \in 1..MaxHeight \cup {NULL_BLOCK}
        /\ lockedBlock[v] \in 1..MaxHeight \cup {NULL_BLOCK}
        /\ lockedRound[v] \in -1..MaxRound
        /\ validBlock[v] \in 1..MaxHeight \cup {NULL_BLOCK}
        /\ validRound[v] \in -1..MaxRound

\* ============================================================================
\* STRUCTURAL INVARIANTS (Sanity Checks)
\* ============================================================================

MCStructural ==
    /\ \A v \in Validators :
        /\ lockedRound[v] = -1 <=> lockedBlock[v] = NULL_BLOCK
        /\ validRound[v] = -1 <=> validBlock[v] = NULL_BLOCK
        /\ lockValid[v] \in {TRUE, FALSE}
    /\ \A h \in 1..MaxHeight, r \in 0..MaxRound :
        /\ Cardinality(votes[h][r][PrevoteType]) <= Cardinality(Validators)
        /\ Cardinality(votes[h][r][PrecommitType]) <= Cardinality(Validators)

\* ============================================================================
\* SYMMETRY REDUCTION
\* ============================================================================

Permute(s, perm) == [i \in DOMAIN perm |-> s[perm[i]]]

Symmetry == Permutations(Validators)

\* ============================================================================
\* STATE SPACE CONSTRAINTS
\* ============================================================================

\* Limit message buffer to prevent explosion
MaxMessages == Cardinality(pendingMessages) <= 8

\* ============================================================================
\* MODEL CHECKING SPECIFICATION
\* ============================================================================

Spec == MCInit /\ [][MCNext]_<<serverVars, voteVars, blockVars, lockVars,
                                 recoveryVars, byzantineVars, extensionVars,
                                 messageVars, timerVars, mcVars>>

====
