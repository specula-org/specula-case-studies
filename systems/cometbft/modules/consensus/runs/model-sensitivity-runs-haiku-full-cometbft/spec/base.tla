---- MODULE base ----
\* CometBFT Consensus Specification
\* Tendermint PBFT-based consensus with proposer-based timestamps, vote extensions,
\* and Proof-of-Lock (POL) logic. Models core consensus state machine and Byzantine behavior.
\*
\* Category: A (Distributed / Message-Passing)
\* Reference: Modeling Brief v1.0 (6 bug families, 14k lines analyzed)

EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Validators  \* Set of validator identities
CONSTANT MaxHeight   \* Upper bound on block height (model parameter)
CONSTANT MaxRound    \* Upper bound on round number (model parameter)
CONSTANT Faulty      \* Set of Byzantine (faulty) validators, |Faulty| <= |Validators|/3

CONSTANT NULL_BLOCK  \* Special value representing no block
CONSTANT NULL_PROOF  \* Special value representing no proof

ASSUME Cardinality(Faulty) * 3 < Cardinality(Validators)
\* Threshold: quorum = ceil(2n/3), BFT requires n >= 3f+1

ASSUME MaxHeight >= 1 /\ MaxRound >= 1

\* ============================================================================
\* VOTE TYPES AND CONSTANTS
\* ============================================================================

CONSTANT PrevoteType, PrecommitType  \* Vote types
CONSTANT RoundStepNewHeight, RoundStepPropose, RoundStepPrevote, RoundStepPrecommit

\* ============================================================================
\* STATE MACHINE VARIABLES
\* ============================================================================

\* Per-validator state (core consensus state machine)
VARIABLE heightRound    \* heightRound[v] = [height |-> h, round |-> r]
VARIABLE step           \* step[v] \in {RoundStepNewHeight, RoundStepPropose, RoundStepPrevote, RoundStepPrecommit}
VARIABLE proposedBlock  \* proposedBlock[v] = block proposed for current (h,r)
VARIABLE lockedBlock    \* lockedBlock[v] = block locked on (nil if unlocked)
VARIABLE lockedRound    \* lockedRound[v] = round of locked block (-1 if unlocked)
VARIABLE validBlock     \* validBlock[v] = block with valid POL (nil if none)
VARIABLE validRound     \* validRound[v] = round of valid POL (-1 if none)

\* Vote extension state (Family 7: Vote Extension Feature)
VARIABLE extensionEnabled  \* extensionEnabled[h] = TRUE if vote extensions required at height h
VARIABLE extensionValid    \* extensionValid[v][h] = set of blocks with valid extensions

\* Votes and quorum state
VARIABLE votes          \* votes[h][r][t] = set of (voter, vote) pairs for height h, round r, type t
VARIABLE allVotes      \* allVotes[v] = set of all votes cast by v (for history tracking)

\* Proposal state (Family 3: Non-atomic proposal and block assembly)
VARIABLE proposalReceived  \* proposalReceived[v][h][r] = proposal block received (or NULL_BLOCK)
VARIABLE blockAssembled    \* blockAssembled[v][h][r] = TRUE if block parts fully assembled

\* Lock/Unlock state (Family 2: Lock/Unlock logic)
VARIABLE lockValid      \* lockValid[v] = TRUE if LockedRound <= currentRound (invariant tracking)

\* Recovery state (Family 4: Recovery and state reconstruction)
VARIABLE recoveryMode   \* recoveryMode[v] = "none" | "statesync" | "recovered"
VARIABLE lastCommit     \* lastCommit[v][h] = commit (2/3+ votes) for block at height h-1
VARIABLE offlineHeight  \* offlineHeight[v] = height at which recovery started (-1 if none)

\* Byzantine behavior (Family 5: Byzantine behavior under message loss/asynchrony)
VARIABLE byzantineState \* byzantineState[v] = Byzantine proposer state (proposals sent)
VARIABLE equivocations  \* equivocations[v] = set of (h,r) where v sent conflicting proposals/votes

\* Message delivery (network model)
VARIABLE pendingMessages  \* Bag of messages in flight: {msg1, msg2, ...}

\* Control flow (Family 6: Independent control loops and timing)
VARIABLE timeoutPending   \* timeoutPending[v][step] = TRUE if timeout pending for (h,r,step)

\* Vote acceptance phases (Family 1: Code Path Inconsistency)
VARIABLE votePhase      \* votePhase[v] = "none" | "checked" | "added" for each pending vote

\* ============================================================================
\* STATE GROUPING FOR UNCHANGED
\* ============================================================================

serverVars == <<heightRound, step, proposedBlock, lockedBlock, lockedRound, validBlock, validRound>>
voteVars == <<votes, allVotes, votePhase>>
blockVars == <<proposalReceived, blockAssembled>>
lockVars == <<lockValid>>
recoveryVars == <<recoveryMode, lastCommit, offlineHeight>>
byzantineVars == <<byzantineState, equivocations>>
extensionVars == <<extensionEnabled, extensionValid>>
messageVars == <<pendingMessages>>
timerVars == <<timeoutPending>>

\* ============================================================================
\* HELPER FUNCTIONS
\* ============================================================================

\* Check if a validator is correct (not Byzantine)
IsCorrect(v) == v \notin Faulty

\* Quorum size (2f+1 for BFT with 3f+1 replicas)
Quorum == Cardinality(Validators) - Cardinality(Faulty)

\* Check if a set of votes forms a quorum
HasQuorum(voteSet) == Cardinality(voteSet) >= Quorum

\* Extract votes for a specific round and type
VotesForRound(h, r, t) == votes[h][r][t]

\* Check if there's a 2/3 majority for a block in a round
HasPolka(h, r, block) ==
    LET voteSet == { v \in Validators : \E vote \in VotesForRound(h, r, PrevoteType) :
                                          vote.voter = v /\ vote.blockID = block }
    IN HasQuorum(voteSet)

\* Check if votes for nil form a 2/3 majority
HasNilPolka(h, r) ==
    LET voteSet == { v \in Validators : \E vote \in VotesForRound(h, r, PrevoteType) :
                                          vote.voter = v /\ vote.blockID = NULL_BLOCK }
    IN HasQuorum(voteSet)

\* Construct vote set for a round
ConstructVoteSet(h, r, t) == votes[h][r][t]

\* ============================================================================
\* PROTOCOL ACTIONS: INITIALIZATION
\* ============================================================================

Init ==
    /\ heightRound = [v \in Validators |-> [height |-> 1, round |-> 0]]
    /\ step = [v \in Validators |-> RoundStepNewHeight]
    /\ proposedBlock = [v \in Validators |-> NULL_BLOCK]
    /\ lockedBlock = [v \in Validators |-> NULL_BLOCK]
    /\ lockedRound = [v \in Validators |-> -1]
    /\ validBlock = [v \in Validators |-> NULL_BLOCK]
    /\ validRound = [v \in Validators |-> -1]
    /\ extensionEnabled = [h \in 1..MaxHeight |-> FALSE]
    /\ extensionValid = [v \in Validators |-> [h \in 1..MaxHeight |-> {}]]
    /\ votes = [h \in 1..MaxHeight |-> [r \in 0..MaxRound |->
                    [t \in {PrevoteType, PrecommitType} |-> {}]]]
    /\ allVotes = [v \in Validators |-> {}]
    /\ proposalReceived = [v \in Validators |-> [h \in 1..MaxHeight |->
                              [r \in 0..MaxRound |-> NULL_BLOCK]]]
    /\ blockAssembled = [v \in Validators |-> [h \in 1..MaxHeight |->
                            [r \in 0..MaxRound |-> FALSE]]]
    /\ lockValid = [v \in Validators |-> TRUE]
    /\ recoveryMode = [v \in Validators |-> "none"]
    /\ lastCommit = [v \in Validators |-> [h \in 0..MaxHeight |-> {}]]
    /\ offlineHeight = [v \in Validators |-> -1]
    /\ byzantineState = [v \in Validators |-> <<>>]
    /\ equivocations = [v \in Validators |-> {}]
    /\ pendingMessages = {}
    /\ timeoutPending = [v \in Validators |-> [s \in
        {RoundStepPropose, RoundStepPrevote, RoundStepPrecommit} |-> FALSE]]
    /\ votePhase = [v \in Validators |-> "none"]

\* ============================================================================
\* ACTIONS: ENTER ROUND (State Transitions)
\* ============================================================================

\* consensus/state.go:1428-1462 (enterNewRound)
EnterNewRound(v) ==
    /\ heightRound[v].height < MaxHeight
    /\ step[v] = RoundStepNewHeight
    /\ step' = [step EXCEPT ![v] = RoundStepPropose]
    /\ proposedBlock' = [proposedBlock EXCEPT ![v] = NULL_BLOCK]
    /\ UNCHANGED <<heightRound, lockedBlock, lockedRound, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* consensus/state.go:1464-1515 (enterPrevote)
\* Check lock state, enter prevote round
EnterPrevote(v) ==
    /\ step[v] = RoundStepPropose
    /\ lockValid[v] = TRUE  \* Family 2: Invariant check before prevote
    /\ step' = [step EXCEPT ![v] = RoundStepPrevote]
    /\ IF validBlock[v] /= NULL_BLOCK
       THEN proposedBlock' = [proposedBlock EXCEPT ![v] = validBlock[v]]
       ELSE IF lockedBlock[v] /= NULL_BLOCK
            THEN proposedBlock' = [proposedBlock EXCEPT ![v] = lockedBlock[v]]
            ELSE proposedBlock' = [proposedBlock EXCEPT ![v] = NULL_BLOCK]
    /\ UNCHANGED <<heightRound, lockedBlock, lockedRound, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* consensus/state.go:1517-1607 (enterPrecommit)
\* Family 2: Lock/Unlock logic - complex POL-based transitions
EnterPrecommit(v) ==
    /\ step[v] = RoundStepPrevote
    /\ step' = [step EXCEPT ![v] = RoundStepPrecommit]
    /\ LET h == heightRound[v].height
           r == heightRound[v].round
           polkaBlock == IF HasPolka(h, r, lockedBlock[v])
                        THEN lockedBlock[v]
                        ELSE IF HasPolka(h, r, NULL_BLOCK)
                             THEN NULL_BLOCK
                             ELSE proposedBlock[v]
       IN
       /\ lockedBlock' = [lockedBlock EXCEPT ![v] = polkaBlock]
       /\ lockedRound' = [lockedRound EXCEPT ![v] = r]
       /\ lockValid' = [lockValid EXCEPT ![v] = (r <= heightRound[v].round)]
    /\ UNCHANGED <<heightRound, proposedBlock, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* ============================================================================
\* ACTIONS: VOTE HANDLING (Family 1: Code Path Inconsistency)
\* ============================================================================

\* consensus/state.go:2238-2269 (addVote) Phase 1: Signature/consistency checks
\* Family 1: Split into CheckVote and AddVote to expose ordering vulnerabilities
CheckVote(v, incomingVote) ==
    /\ incomingVote.height \in 1..MaxHeight
    /\ incomingVote.round \in 0..MaxRound
    /\ incomingVote.type \in {PrevoteType, PrecommitType}
    /\ votePhase[v] = "none"
    /\ votePhase' = [votePhase EXCEPT ![v] = "checked"]
    /\ UNCHANGED <<serverVars, extensionEnabled, extensionValid, votes, allVotes,
                   blockVars, lockVars, recoveryVars, byzantineVars, messageVars, timerVars>>

\* consensus/state.go:2270-2348 (addVote) Phase 2: Actual vote set addition
\* Family 1: Separate action to expose race between check and add
AddVote(v, incomingVote) ==
    /\ votePhase[v] = "checked"
    /\ incomingVote.height \in 1..MaxHeight
    /\ incomingVote.round \in 0..MaxRound
    /\ LET h == incomingVote.height
           r == incomingVote.round
           t == incomingVote.type
       IN
       /\ votes' = [votes EXCEPT ![h][r][t] = @ \cup {incomingVote}]
       /\ allVotes' = [allVotes EXCEPT ![incomingVote.voter] = @ \cup {incomingVote}]
    /\ votePhase' = [votePhase EXCEPT ![v] = "none"]
    /\ UNCHANGED <<serverVars, extensionEnabled, extensionValid, proposalReceived,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, timerVars>>

\* ============================================================================
\* ACTIONS: LOCK/UNLOCK (Family 2: Lock/Unlock Logic Consistency)
\* ============================================================================

\* consensus/state.go:2396-2423 (POL-based unlock)
\* When 2/3 prevotes for a block B in round R where ValidRound <= R < LockedRound
UnlockOnPol(v) ==
    /\ step[v] = RoundStepPrecommit
    /\ lockedBlock[v] /= NULL_BLOCK  \* Currently locked
    /\ LET h == heightRound[v].height
           r == heightRound[v].round
           polRound == lockedRound[v]
       IN
       /\ polRound >= 0
       /\ polRound < r
       /\ \E block \in 1..MaxHeight : \* Some block with polka in a round > polRound
           /\ \E polR \in polRound+1..r : HasPolka(h, polR, block) /\ block /= lockedBlock[v]
           /\ lockedBlock' = [lockedBlock EXCEPT ![v] = NULL_BLOCK]
           /\ lockedRound' = [lockedRound EXCEPT ![v] = -1]
           /\ lockValid' = [lockValid EXCEPT ![v] = TRUE]
    /\ UNCHANGED <<heightRound, step, proposedBlock, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* consensus/state.go:2427-2432 (ValidBlock update)
\* Update ValidBlock/ValidRound when we see a higher polka
UpdateValidBlock(v) ==
    /\ step[v] = RoundStepPrecommit
    /\ LET h == heightRound[v].height
           r == heightRound[v].round
       IN
       /\ \E block \in 1..MaxHeight :
           /\ HasPolka(h, r, block)
           /\ block /= validBlock[v]
           /\ validBlock' = [validBlock EXCEPT ![v] = block]
           /\ validRound' = [validRound EXCEPT ![v] = r]
    /\ UNCHANGED <<heightRound, step, proposedBlock, lockedBlock, lockedRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* ============================================================================
\* ACTIONS: PROPOSAL AND BLOCK ASSEMBLY (Family 3: Non-Atomic Operations)
\* ============================================================================

\* consensus/state.go:2006-2068 (defaultSetProposal)
\* Family 3: Receive proposal (separate from block assembly)
ReceiveProposal(v, proposal) ==
    /\ step[v] = RoundStepPropose
    /\ proposal.height = heightRound[v].height
    /\ proposal.round = heightRound[v].round
    /\ proposalReceived' = [proposalReceived EXCEPT ![v][proposal.height][proposal.round] = proposal.block]
    /\ UNCHANGED <<serverVars, extensionEnabled, extensionValid, votes, allVotes,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* consensus/state.go:2073-2149 (addProposalBlockPart)
\* Family 3: Block assembly completion (separate from proposal receipt)
ReceiveBlockPart(v, h, r) ==
    /\ h = heightRound[v].height
    /\ r = heightRound[v].round
    /\ proposalReceived[v][h][r] /= NULL_BLOCK
    /\ blockAssembled' = [blockAssembled EXCEPT ![v][h][r] = TRUE]
    /\ UNCHANGED <<serverVars, extensionEnabled, extensionValid, votes, allVotes,
                   proposalReceived, lockValid, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* consensus/state.go:2151-2184 (handleCompleteProposal)
\* Family 3: Transition to prevote after full block assembly
HandleCompleteProposal(v) ==
    /\ step[v] = RoundStepPropose \/ step[v] = RoundStepPrevote
    /\ LET h == heightRound[v].height
           r == heightRound[v].round
       IN
       /\ blockAssembled[v][h][r] = TRUE
       /\ proposedBlock' = [proposedBlock EXCEPT ![v] = proposalReceived[v][h][r]]
    /\ UNCHANGED <<heightRound, step, lockedBlock, lockedRound, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* ============================================================================
\* ACTIONS: VOTE EXTENSIONS (Family 7: Vote Extension Feature Interactions)
\* ============================================================================

\* consensus/state.go:2296-2345 (addVote with extension checks)
\* Family 7: Extension validation as separate phase
CheckVoteExtension(v, incomingVote) ==
    /\ incomingVote.type = PrecommitType
    /\ incomingVote.height \in 1..MaxHeight
    /\ incomingVote.blockID /= NULL_BLOCK
    /\ LET h == incomingVote.height
       IN
       /\ extensionEnabled[h] = TRUE
       /\ incomingVote.extension /= NULL_PROOF  \* Must have extension
       /\ extensionValid' = [extensionValid EXCEPT ![v][h] =
           @ \cup IF incomingVote.extension /= NULL_PROOF
                  THEN {incomingVote.blockID}
                  ELSE {}]
    /\ UNCHANGED <<serverVars, votes, allVotes, blockVars, lockVars,
                   extensionEnabled, recoveryVars, byzantineVars, messageVars, timerVars, votePhase>>

\* ============================================================================
\* ACTIONS: BYZANTINE BEHAVIOR (Family 5: Byzantine Behavior)
\* ============================================================================

\* Family 5: Faulty proposer sends conflicting proposals
ByzantineEquivocateProposal(v, proposal1, proposal2) ==
    /\ v \in Faulty
    /\ proposal1.height = proposal2.height
    /\ proposal1.round = proposal2.round
    /\ proposal1.block /= proposal2.block
    /\ byzantineState' = [byzantineState EXCEPT ![v] =
        Append(byzantineState[v], <<proposal1, proposal2>>)]
    /\ equivocations' = [equivocations EXCEPT ![v] =
        @ \cup {[height |-> proposal1.height, round |-> proposal1.round]}]
    /\ pendingMessages' = (pendingMessages \cup
        {[type |-> "proposal", sender |-> v, proposal |-> proposal1],
         [type |-> "proposal", sender |-> v, proposal |-> proposal2]})
    /\ UNCHANGED <<serverVars, extensionEnabled, extensionValid, votes, allVotes,
                   blockVars, lockVars, recoveryVars, timerVars, votePhase>>

\* Family 5: Faulty validator sends conflicting votes
ByzantineEquivocateVote(v, vote1, vote2) ==
    /\ v \in Faulty
    /\ vote1.height = vote2.height
    /\ vote1.round = vote2.round
    /\ vote1.type = vote2.type
    /\ vote1.blockID /= vote2.blockID
    /\ equivocations' = [equivocations EXCEPT ![v] =
        @ \cup {[height |-> vote1.height, round |-> vote1.round]}]
    /\ pendingMessages' = (pendingMessages \cup
        {[type |-> "vote", sender |-> v, vote |-> vote1],
         [type |-> "vote", sender |-> v, vote |-> vote2]})
    /\ UNCHANGED <<serverVars, extensionEnabled, extensionValid, votes, allVotes,
                   blockVars, lockVars, recoveryVars, byzantineState, timerVars, votePhase>>

\* ============================================================================
\* ACTIONS: RECOVERY (Family 4: Recovery and State Reconstruction)
\* ============================================================================

\* consensus/state.go:186-192 (NewState with recovery)
\* Family 4: Crash and recovery with state reconstruction
CrashAndRecover(v) ==
    /\ recoveryMode[v] = "none"
    /\ recoveryMode' = [recoveryMode EXCEPT ![v] = "recovered"]
    /\ \* Reconstruct LastCommit from either SeenCommit or ExtendedCommit
       \* (simplified: just ensure LastCommit has 2/3 majority)
       \E h \in 1..MaxHeight-1 :
           /\ lastCommit' = [lastCommit EXCEPT ![v][h] =
               {vote \in votes[h][MaxRound][PrecommitType] : HasQuorum({vote})}]
    /\ heightRound' = heightRound  \* Keep current height/round after recovery
    /\ UNCHANGED <<step, proposedBlock, lockedBlock, lockedRound, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, lockValid, byzantineVars, messageVars, timerVars, votePhase>>

\* ============================================================================
\* ACTIONS: TIMEOUTS (Family 6: Independent Control Loops)
\* ============================================================================

\* consensus/state.go:798-860 (receiveRoutine with timeout handling)
\* Family 6: Timeout-driven round advancement
HandleTimeout(v) ==
    /\ step[v] \in {RoundStepPropose, RoundStepPrevote, RoundStepPrecommit}
    /\ timeoutPending[v][step[v]] = TRUE
    /\ LET nextStep == IF step[v] = RoundStepPropose THEN RoundStepPrevote
                      ELSE IF step[v] = RoundStepPrevote THEN RoundStepPrecommit
                      ELSE RoundStepNewHeight
       IN
       /\ IF nextStep = RoundStepNewHeight
          THEN heightRound' = [heightRound EXCEPT ![v].round = 0]
          ELSE heightRound' = [heightRound EXCEPT ![v].round = @ + 1]
       /\ step' = [step EXCEPT ![v] = nextStep]
       /\ timeoutPending' = [timeoutPending EXCEPT ![v][step[v]] = FALSE]
    /\ UNCHANGED <<proposedBlock, lockedBlock, lockedRound, validBlock, validRound,
                   extensionEnabled, extensionValid, votes, allVotes, proposalReceived,
                   blockAssembled, lockValid, recoveryVars, byzantineVars, messageVars, votePhase>>

\* ============================================================================
\* PROTOCOL NEXT-STATE RELATION
\* ============================================================================

Next ==
    \E v \in Validators :
        \/ EnterNewRound(v)
        \/ EnterPrevote(v)
        \/ EnterPrecommit(v)
        \/ UnlockOnPol(v)
        \/ UpdateValidBlock(v)
        \/ HandleTimeout(v)
        \/ \E h \in 1..MaxHeight, r \in 0..MaxRound :
            \/ ReceiveProposal(v, [height |-> h, round |-> r, block |-> 1..MaxHeight])
            \/ ReceiveBlockPart(v, h, r)
            \/ HandleCompleteProposal(v)
        \/ \E vote \in [height: 1..MaxHeight, round: 0..MaxRound,
                        type: {PrevoteType, PrecommitType},
                        voter: Validators, blockID: 1..MaxHeight \cup {NULL_BLOCK},
                        extension: {NULL_PROOF, 1..MaxHeight}] :
            \/ CheckVote(v, vote)
            \/ AddVote(v, vote)
            \/ CheckVoteExtension(v, vote)
        \/ \E proposal1, proposal2 \in [height: 1..MaxHeight, round: 0..MaxRound, block: 1..MaxHeight] :
            ByzantineEquivocateProposal(v, proposal1, proposal2)
        \/ \E vote1, vote2 \in [height: 1..MaxHeight, round: 0..MaxRound,
                                type: {PrevoteType, PrecommitType},
                                blockID: 1..MaxHeight \cup {NULL_BLOCK},
                                extension: {NULL_PROOF, 1..MaxHeight}] :
            ByzantineEquivocateVote(v, vote1, vote2)
        \/ CrashAndRecover(v)

\* ============================================================================
\* SAFETY INVARIANTS
\* ============================================================================

\* Core election safety: at most one block committed per height
ElectionSafety ==
    \A h \in 1..MaxHeight :
        LET commits == { block \in 1..MaxHeight :
                         \E v \in Validators : lastCommit[v][h-1] /= {} }
        IN Cardinality(commits) <= 1

\* Family 2: Lock safety - validator precommits only block it locked on or nil with POL > lock
LockedSafety ==
    \A v \in Validators :
        /\ lockedBlock[v] /= NULL_BLOCK =>
           \A r \in lockedRound[v]+1..MaxRound :
               \E vote \in votes[heightRound[v].height][r][PrecommitType] :
                   vote.voter = v =>
                   vote.blockID = lockedBlock[v] \/ vote.blockID = NULL_BLOCK

\* Family 2: If ValidBlock set, must match a polka
ValidBlockConsistency ==
    \A v \in Validators :
        validBlock[v] /= NULL_BLOCK =>
            HasPolka(heightRound[v].height, validRound[v], validBlock[v])

\* Family 7: Extension presence and validity
VoteExtensionPresence ==
    \A h \in 1..MaxHeight :
        extensionEnabled[h] = TRUE =>
            \A v \in Validators :
                \A vote \in votes[h][MaxRound][PrecommitType] :
                    vote.voter = v /\ vote.blockID /= NULL_BLOCK =>
                    vote.extension /= NULL_PROOF

\* Family 3: Block integrity after assembly
ProposalBlockIntegrity ==
    \A v \in Validators :
        blockAssembled[v][heightRound[v].height][heightRound[v].round] = TRUE =>
            proposedBlock[v] /= NULL_BLOCK

\* Family 4: LastCommit consistency after recovery
CommitConsistency ==
    \A v \in Validators :
        recoveryMode[v] = "recovered" =>
            \A h \in 1..MaxHeight-1 :
                lastCommit[v][h] /= {} =>
                    HasQuorum(lastCommit[v][h])

\* Core Byzantine safety: no fork with quorum
NoForkingWithQuorum ==
    \A h \in 1..MaxHeight :
        \A block1, block2 \in 1..MaxHeight :
            block1 /= block2 =>
                ~(\E certif1, certif2 :
                    HasQuorum(certif1) /\ HasQuorum(certif2) /\
                    (\E v \in Validators : v \in Faulty =>
                        \E vote \in certif1 \cup certif2 : vote.voter = v))

\* Family 1: No duplicate votes from same validator
NoDuplicateVotes ==
    \A v \in Validators :
        \A h \in 1..MaxHeight, r \in 0..MaxRound, t \in {PrevoteType, PrecommitType} :
            Cardinality({vote \in votes[h][r][t] : vote.voter = v}) <= 1

\* ============================================================================
\* TEMPORAL PROPERTIES (Liveness)
\* ============================================================================

\* Eventually, if 2/3+ correct validators propose valid blocks, they commit
LivenessUnderGST ==
    <> (
        \E h \in 1..MaxHeight :
            \E block \in 1..MaxHeight :
                \A v \in Validators \ Faulty :
                    lastCommit[v][h-1] /= {} =>
                        \E vote \in lastCommit[v][h-1] : vote.blockID = block
    )

====
