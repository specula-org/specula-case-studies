--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for CometBFT v0.38.19 consensus engine.
 * Source: github.com/cometbft/cometbft
 *
 * Bug Families modeled (per modeling-brief.md):
 *   Family 1 [HIGH]  Vote extension verification asymmetry
 *                    consensus/state.go:2303-2334 (self-vote bypass)
 *                    light/verifier.go:57-128 (no extension verification)
 *                    blocksync/reactor.go:531,548-554 (presence-only check)
 *   Family 2 [MED]   Double-sign protection off-by-one at height=1
 *                    consensus/state.go:2647 (loop: i < bound, not i <= bound)
 *   Family 3 [HIGH]  Evidence hash collision (31-byte truncation)
 *                    types/evidence.go:326 (copies tmhash.Size-1 = 31 bytes)
 *   Family 4 [MED]   Blocksync maxPeerHeight inflation from Byzantine peer
 *                    blocksync/pool.go:411-413 (unconditional update)
 *                    blocksync/pool.go:449-451 (conditional recalc on disconnect)
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server          \* Set of all validator node IDs
CONSTANT Faulty          \* Byzantine subset; Faulty \subseteq Server
CONSTANT MaxHeight       \* Maximum height to model-check (bound)
CONSTANT MaxRound        \* Maximum round per height (bound)
CONSTANT Nil             \* Sentinel: no value / absent

\* Block values (abstract)
CONSTANT Values          \* Set of possible block values

\* Message types
CONSTANTS
    ProposalMsg,         \* Proposal message type
    PrevoteMsg,          \* Prevote message type
    PrecommitMsg         \* Precommit message type

\* Step constants (RoundStepType from consensus/types/roundstate.go)
CONSTANTS
    StepNewHeight,       \* RoundStepNewHeight
    StepNewRound,        \* RoundStepNewRound
    StepPropose,         \* RoundStepPropose
    StepPrevote,         \* RoundStepPrevote
    StepPrevoteWait,     \* RoundStepPrevoteWait
    StepPrecommit,       \* RoundStepPrecommit
    StepPrecommitWait,   \* RoundStepPrecommitWait
    StepCommit           \* RoundStepCommit

\* Nil vote sentinel (distinct from Nil to distinguish "voted nil" vs "not voted")
CONSTANT NilVote

\* ---- Family 1 constants: Vote extension data ----
CONSTANTS
    ValidExt,            \* Extension data that passes VerifyVoteExtension
    InvalidExt,          \* Extension data that fails VerifyVoteExtension
    NoExt                \* No extension (nil precommit or extensions disabled)

\* ---- Family 2 constant: double-sign check configuration ----
CONSTANT DoubleSignCheckHeight  \* cs.config.DoubleSignCheckHeight (> 0 triggers the check)

\* ---- Family 3 constants: evidence hash ----
CONSTANT BlockHash              \* Abstract set of 32-byte block hash values
CONSTANT HashAliases            \* [BlockHash -> key] — the truncated (buggy) pool key
                                \* Two hashes bh1, bh2 collide iff HashAliases[bh1] = HashAliases[bh2]
CONSTANT NoEvidence             \* Sentinel for "no evidence at this pool slot"

\* ---- Family 4 constants: blocksync ----
CONSTANT SyncPeers              \* Set of peers visible in blocksync (includes Faulty)
CONSTANT AbsentPeer             \* Sentinel for "peer not connected" in peerRecords

\* ============================================================================
\* ASSUMPTIONS
\* ============================================================================

ASSUME Faulty \subseteq Server
ASSUME Faulty \subseteq SyncPeers
ASSUME DoubleSignCheckHeight >= 0
ASSUME DOMAIN HashAliases = BlockHash

Honest == Server \ Faulty

\* ============================================================================
\* QUORUM HELPERS
\* ============================================================================

\* More than 2/3 of voting power (simplified: equal weights)
IsStrongQuorum(S) == 3 * Cardinality(S) > 2 * Cardinality(Server)

IsWeakQuorum(S) == 3 * Cardinality(S) > Cardinality(Server)

\* ============================================================================
\* STEP AND SYNC-MODE CONSTANTS (defined as operators)
\* ============================================================================

BLOCKSYNC  == "blocksync"
CONSENSUS  == "consensus"

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* ---- Standard consensus state (consensus/state.go RoundState) ----

VARIABLE height         \* [Server -> Int] current consensus height
VARIABLE round          \* [Server -> Int] current round (0-based)
VARIABLE step           \* [Server -> Step] current step in the round

VARIABLE proposal       \* [Server -> record or Nil] current proposal
VARIABLE proposalBlock  \* [Server -> value or Nil] proposed block value

\* Locking state (consensus/state.go:1459-1578)
VARIABLE lockedRound    \* [Server -> Int] round at which locked (-1 = none)
VARIABLE lockedValue    \* [Server -> value or Nil] locked block value
VARIABLE validRound     \* [Server -> Int] round of last valid block (-1 = none)
VARIABLE validValue     \* [Server -> value or Nil] last valid block value

\* Vote tracking
VARIABLE prevotes       \* [Server -> [Round -> [Server -> value or NilVote or Nil]]]
VARIABLE precommits     \* [Server -> [Round -> [Server -> value or NilVote or Nil]]]
                        \*   Nil = not yet received; NilVote = voted nil; value = voted for block

VARIABLE decision       \* [Server -> [Height -> value or Nil]] committed block per height
VARIABLE messages       \* Bag of in-flight messages

\* ---- Family 1: Vote extension verification (consensus/state.go:2296-2334) ----

VARIABLE voteExt        \* [Server -> ExtData] extension data each validator attaches to precommits
                        \*   ValidExt = passes VerifyVoteExtension; InvalidExt = fails

\* Whether node i performed ABCI VerifyVoteExtension for voter j's precommit at height h.
\* extABCIVerified[i][j][h] = TRUE means i called VerifyVoteExtension and it succeeded.
\* Models: consensus/state.go:2329 (VerifyVoteExtension call)
VARIABLE extABCIVerified  \* [Server -> [Server -> [Height -> Bool]]]

\* Whether node i bypassed its own ABCI extension check at height h.
\* selfExtBypassed[i][h] = TRUE means the self-vote guard fired at state.go:2310.
\* Models: consensus/state.go:2303-2310 (!bytes.Equal(vote.ValidatorAddress, myAddr))
VARIABLE selfExtBypassed  \* [Server -> [Height -> Bool]]

\* Whether node i accepted a commit at height h via the light client path (no ext verification).
\* Models: light/verifier.go:57-128 (VerifyAdjacent/VerifyNonAdjacent/Verify)
VARIABLE lightClientAccepted  \* [Server -> [Height -> Bool]]

\* Whether node i accepted a commit at height h via the blocksync path (no ext verification).
\* Models: blocksync/reactor.go:531,548-554 (EnsureExtensions, no sig check)
VARIABLE blocksyncAccepted  \* [Server -> [Height -> Bool]]

\* ---- Family 2: Double-sign protection (consensus/state.go:2638-2661) ----

\* Whether WAL is present when a validator starts/restarts.
\* walPresent[v] = FALSE triggers double-sign check on restart.
VARIABLE walPresent  \* [Server -> Bool]

\* Whether checkDoubleSigningRisk ran ≥1 loop iteration for validator v at height h.
\* lookbackChecked[v][h] = TRUE iff min(DoubleSignCheckHeight, h) > 1.
\* Models the loop bug: for i := int64(1); i < doubleSignCheckHeight; i++ (state.go:2647)
VARIABLE lookbackChecked  \* [Server -> [Height -> Bool]]

\* Last vote signed by each validator's privval (survives crash/restart).
\* privvalLastSigned[v] = {height, round, voteType} or Nil (never signed yet).
\* Models: privval/file.go LastSignState persistence
VARIABLE privvalLastSigned  \* [Server -> record or Nil]

\* ---- Family 3: Evidence hash collision (types/evidence.go:322-329) ----

\* Per-node evidence pool using truncated hash as key.
\* evidencePool[v] : [EvidenceKey -> Evidence record or NoEvidence]
\* EvidenceKey = <<commonHeight, HashAliases[conflictingBlockHash]>>
\* Models: evidence/pool.go:224-228 (keyPending / keyCommitted DB keys)
VARIABLE evidencePool  \* [Server -> (EvidenceKey -> evidence or NoEvidence)]

\* Set to TRUE when two distinct LightClientAttackEvidence records with different
\* conflicting block hashes produce the same pool key.
\* Models: types/evidence.go:326 (off-by-one produces collision)
VARIABLE hashCollision  \* Bool

\* ---- Family 4: Blocksync peer state (blocksync/pool.go) ----

\* Whether node v is in blocksync mode or has joined consensus.
VARIABLE syncMode  \* [Server -> "blocksync" | "consensus"]

\* Pool's stored maximum peer height; raised unconditionally on peer status report.
\* Never decreased when a peer reports a lower height.
\* Models: blocksync/pool.go:411-413 (if height > pool.maxPeerHeight { pool.maxPeerHeight = height })
VARIABLE maxPeerHeight  \* [Server -> Int]

\* Per-peer stored height in the node's block pool.
\* peerRecords[v][p] = h means pool.peers[p].height = h
\* peerRecords[v][p] = AbsentPeer means peer p is not connected to node v
\* Models: blocksync/pool.go:SetPeerRange peer struct
VARIABLE peerRecords  \* [Server -> [SyncPeers -> Int or AbsentPeer]]

\* Local chain height during blocksync (how far the node has synced).
\* IsCaughtUp() returns true when localSyncHeight >= maxPeerHeight - 1.
\* Models: blocksync/pool.go IsCaughtUp()
VARIABLE localSyncHeight  \* [Server -> Int]

\* ---- WAL / crash recovery (used by Family 2 and Family 3 evidence) ----
VARIABLE walEntries         \* [Server -> Seq(entry)] WAL log
VARIABLE crashed            \* [Server -> Bool] whether server is currently crashed

\* ============================================================================
\* VARIABLE GROUPINGS (for UNCHANGED clauses)
\* ============================================================================

consensusVars == <<height, round, step>>
proposalVars  == <<proposal, proposalBlock>>
lockVars      == <<lockedRound, lockedValue, validRound, validValue>>
voteVars      == <<prevotes, precommits>>
decisionVars  == <<decision>>

extVerifyVars  == <<voteExt, extABCIVerified, selfExtBypassed,
                    lightClientAccepted, blocksyncAccepted>>
doubleSignVars == <<walPresent, lookbackChecked, privvalLastSigned>>
evidenceVars   == <<evidencePool, hashCollision>>
blocksyncVars  == <<syncMode, maxPeerHeight, peerRecords, localSyncHeight>>
walVars        == <<walEntries, crashed>>

vars == <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
          extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Message bag helpers
Send(m)    == messages' = messages (+) SetToBag({m})
SendAll(S) == messages' = messages (+) SetToBag(S)
Discard(m) == messages' = messages (-) SetToBag({m})

\* Empty vote map for one round
EmptyVoteMap == [j \in Server |-> Nil]

\* Quorum checks over the vote tracking maps
HasPrevoteQuorum(i, r, v) ==
    IsStrongQuorum({j \in Server : prevotes[i][r][j] = v})

HasPrevoteTwoThirdsAny(i, r) ==
    IsStrongQuorum({j \in Server : prevotes[i][r][j] /= Nil})

HasPrecommitQuorum(i, r, v) ==
    IsStrongQuorum({j \in Server : precommits[i][r][j] = v})

HasPrecommitTwoThirdsAny(i, r) ==
    IsStrongQuorum({j \in Server : precommits[i][r][j] /= Nil})

\* Round-robin proposer selection (simplified; real impl uses validator power)
Proposer(h, r) ==
    LET servers == CHOOSE seq \in [1..Cardinality(Server) -> Server] :
                       \A i, j \in 1..Cardinality(Server) : i /= j => seq[i] /= seq[j]
        idx == ((h - 1 + r) % Cardinality(Server)) + 1
    IN servers[idx]

\* Default value selection for proposal (deterministic CHOOSE)
ChooseValue(i) == CHOOSE val \in Values : TRUE

\* Evidence pool key for a LightClientAttackEvidence record.
\* Mirrors types/evidence.go:322-329 (buggy: copies only tmhash.Size-1 bytes)
\* HashAliases[conflictingBlockHash] models the truncated 31-byte prefix.
EvidencePoolKey(commonHeight, conflictingBlockHash) ==
    <<commonHeight, HashAliases[conflictingBlockHash]>>

\* Whether two distinct hashes produce the same pool key (hash collision).
HashesCollide(bh1, bh2) ==
    /\ bh1 /= bh2
    /\ HashAliases[bh1] = HashAliases[bh2]

\* Max value of a set of integers (returns 0 on empty set)
MaxSet(S) == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : x >= y

\* Set of connected peers for node v
ConnectedPeers(v) ==
    {p \in SyncPeers : peerRecords[v][p] /= AbsentPeer}

\* ============================================================================
\* ACTIONS: STANDARD CONSENSUS
\* ============================================================================

\* --------------------------------------------------------------------------
\* EnterNewRound: Server i enters a new round.
\* Reference: consensus/state.go:1066-1131 (enterNewRound)
\* --------------------------------------------------------------------------
EnterNewRound(i, r) ==
    /\ ~crashed[i]
    /\ r >= round[i]
    /\ step[i] \in {StepNewHeight, StepNewRound, StepCommit} \/ r > round[i]
    /\ round' = [round EXCEPT ![i] = r]
    /\ step'  = [step  EXCEPT ![i] = StepNewRound]
    \* Clear proposal when advancing rounds (state.go:1098-1102)
    /\ IF r > 0
       THEN proposal'      = [proposal      EXCEPT ![i] = Nil]
            /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
       ELSE UNCHANGED proposalVars
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* EnterPropose: Server i enters the propose step.
\* Reference: consensus/state.go:1157-1266 (enterPropose + defaultDecideProposal)
\* --------------------------------------------------------------------------
EnterPropose(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepNewRound
    /\ step' = [step EXCEPT ![i] = StepPropose]
    /\ IF Proposer(height[i], round[i]) = i
       THEN \* Proposer: build and broadcast proposal (state.go:1221-1271)
            LET v       == IF validValue[i] /= Nil THEN validValue[i] ELSE ChooseValue(i)
                polRound == IF validValue[i] /= Nil THEN validRound[i] ELSE -1
            IN
            /\ proposal'      = [proposal      EXCEPT ![i] = [height   |-> height[i],
                                                               round    |-> round[i],
                                                               value    |-> v,
                                                               polRound |-> polRound,
                                                               source   |-> i]]
            /\ proposalBlock' = [proposalBlock EXCEPT ![i] = v]
            /\ SendAll({[mtype    |-> ProposalMsg,
                         height   |-> height[i],
                         round    |-> round[i],
                         value    |-> v,
                         polRound |-> polRound,
                         source   |-> i,
                         dest     |-> j] : j \in Server \ {i}})
       ELSE UNCHANGED <<proposalVars, messages>>
    /\ UNCHANGED <<height, round, lockVars, voteVars, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* ReceiveProposal: Server i receives and validates a proposal.
\* Reference: consensus/state.go:1920-1967 (defaultSetProposal)
\* --------------------------------------------------------------------------
ReceiveProposal(i, m) ==
    /\ m.mtype = ProposalMsg
    /\ m.dest  = i
    /\ ~crashed[i]
    /\ height[i] = m.height
    /\ round[i]  = m.round
    /\ proposalBlock[i] = Nil                              \* no duplicate (state.go:1923)
    /\ m.polRound = -1 \/ (m.polRound >= 0 /\ m.polRound < m.round)  \* state.go:1932
    /\ m.source = Proposer(m.height, m.round)              \* must be from proposer
    /\ proposal'      = [proposal      EXCEPT ![i] = m]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = m.value]
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, lockVars, voteVars, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* EnterPrevote: Server i enters prevote step.
\* Reference: consensus/state.go:1334-1420 (enterPrevote + defaultDoPrevote)
\*
\* Five decision paths (defaultDoPrevote):
\*   1. Locked block   → prevote locked value (state.go:1366-1369)
\*   2. No proposal    → prevote nil (state.go:1373-1376)
\*   3-5. Have proposal → prevote proposal value (abstracted here)
\* --------------------------------------------------------------------------
EnterPrevote(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPropose, StepNewRound}
    /\ step' = [step EXCEPT ![i] = StepPrevote]
    /\ LET voteValue ==
            IF lockedValue[i] /= Nil    THEN lockedValue[i]  \* path 1
            ELSE IF proposalBlock[i] = Nil THEN NilVote      \* path 2
            ELSE proposalBlock[i]                            \* paths 3-5
       IN
       /\ prevotes' = [prevotes EXCEPT ![i][round[i]][i] = voteValue]
       /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
              [type |-> "vote", voteType |-> "prevote",
               height |-> height[i], round |-> round[i], value |-> voteValue])]
       /\ SendAll({[mtype  |-> PrevoteMsg,
                    height |-> height[i],
                    round  |-> round[i],
                    value  |-> voteValue,
                    source |-> i,
                    dest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, lockVars, precommits, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

\* --------------------------------------------------------------------------
\* ReceivePrevote: Server i receives a prevote message from server j.
\* Reference: consensus/state.go:2269-2346 (addVote prevote handler)
\* --------------------------------------------------------------------------
ReceivePrevote(i, m) ==
    /\ m.mtype  = PrevoteMsg
    /\ m.dest   = i
    /\ ~crashed[i]
    /\ m.height = height[i]
    /\ prevotes[i][m.round][m.source] = Nil               \* no duplicate (state.go:2246)
    /\ prevotes' = [prevotes EXCEPT ![i][m.round][m.source] = m.value]
    /\ Discard(m)
    \* Unlock on conflicting polka (state.go:2279-2290)
    /\ LET hasPolka  == \E v \in Values : HasPrevoteQuorum(i, m.round, v)
           polkaVal  == IF hasPolka
                        THEN CHOOSE v \in Values : HasPrevoteQuorum(i, m.round, v)
                        ELSE Nil
       IN
       IF /\ hasPolka
          /\ lockedValue[i] /= Nil
          /\ lockedRound[i] < m.round
          /\ m.round <= round[i]
          /\ lockedValue[i] /= polkaVal
       THEN /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
            /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
            /\ IF polkaVal /= Nil /\ validRound[i] < m.round /\ m.round = round[i]
                  /\ proposalBlock[i] = polkaVal
               THEN /\ validRound' = [validRound EXCEPT ![i] = m.round]
                    /\ validValue' = [validValue EXCEPT ![i] = polkaVal]
               ELSE UNCHANGED <<validRound, validValue>>
       ELSE IF hasPolka /\ polkaVal /= Nil /\ validRound[i] < m.round
               /\ m.round = round[i] /\ proposalBlock[i] = polkaVal
            THEN /\ validRound' = [validRound EXCEPT ![i] = m.round]
                 /\ validValue' = [validValue EXCEPT ![i] = polkaVal]
                 /\ UNCHANGED <<lockedRound, lockedValue>>
            ELSE UNCHANGED lockVars
    /\ UNCHANGED <<consensusVars, proposalVars, precommits, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* EnterPrevoteWait: Server i starts the prevote timeout.
\* Reference: consensus/state.go:1423-1440 (enterPrevoteWait)
\* --------------------------------------------------------------------------
EnterPrevoteWait(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrevote
    /\ HasPrevoteTwoThirdsAny(i, round[i])
    /\ step' = [step EXCEPT ![i] = StepPrevoteWait]
    /\ UNCHANGED <<height, round, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* EnterPrecommit (5 paths): Server i enters precommit step.
\* Reference: consensus/state.go:1459-1578 (enterPrecommit)
\* --------------------------------------------------------------------------

\* Path 1: No polka → precommit nil (state.go:1479-1490)
EnterPrecommitNoPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ ~(\E v \in Values \cup {NilVote} : HasPrevoteQuorum(i, round[i], v))
    /\ step'       = [step       EXCEPT ![i] = StepPrecommit]
    /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = NilVote]
    /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
           [type |-> "vote", voteType |-> "precommit",
            height |-> height[i], round |-> round[i], value |-> NilVote])]
    /\ SendAll({[mtype  |-> PrecommitMsg,
                 height |-> height[i], round |-> round[i],
                 value  |-> NilVote,   source |-> i,
                 ve     |-> NoExt,     dest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, lockVars, prevotes, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

\* Path 2: +2/3 prevoted nil → unlock + precommit nil (state.go:1505-1520)
EnterPrecommitNilPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ HasPrevoteQuorum(i, round[i], NilVote)
    /\ step'       = [step       EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ UNCHANGED <<validRound, validValue>>
    /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = NilVote]
    /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
           [type |-> "vote", voteType |-> "precommit",
            height |-> height[i], round |-> round[i], value |-> NilVote])]
    /\ SendAll({[mtype  |-> PrecommitMsg,
                 height |-> height[i], round |-> round[i],
                 value  |-> NilVote,   source |-> i,
                 ve     |-> NoExt,     dest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

\* Path 3: +2/3 for locked block → relock + precommit (state.go:1525-1535)
EnterPrecommitRelockPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ lockedValue[i] /= Nil
    /\ HasPrevoteQuorum(i, round[i], lockedValue[i])
    /\ step'       = [step       EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = round[i]]
    /\ UNCHANGED <<lockedValue, validRound, validValue>>
    /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = lockedValue[i]]
    /\ LET ve == voteExt[i] IN  \* ExtendVote ABCI call (state.go:2413-2423)
       /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
              [type |-> "vote", voteType |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> lockedValue[i], ve |-> ve])]
       /\ SendAll({[mtype  |-> PrecommitMsg,
                    height |-> height[i], round |-> round[i],
                    value  |-> lockedValue[i], source |-> i,
                    ve     |-> ve,             dest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

\* Path 4: +2/3 for proposal block → new lock + precommit (state.go:1538-1556)
EnterPrecommitNewLockPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ proposalBlock[i] /= Nil
    /\ HasPrevoteQuorum(i, round[i], proposalBlock[i])
    /\ lockedValue[i] /= proposalBlock[i]
    /\ step'       = [step       EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = round[i]]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = proposalBlock[i]]
    /\ UNCHANGED <<validRound, validValue>>
    /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = proposalBlock[i]]
    /\ LET ve == voteExt[i] IN  \* ExtendVote ABCI call (state.go:2413-2423)
       /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
              [type |-> "vote", voteType |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> proposalBlock[i], ve |-> ve])]
       /\ SendAll({[mtype  |-> PrecommitMsg,
                    height |-> height[i], round |-> round[i],
                    value  |-> proposalBlock[i], source |-> i,
                    ve     |-> ve,               dest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

\* Path 5: +2/3 for unknown block → unlock + precommit nil (state.go:1559-1577)
EnterPrecommitUnknownPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ \E v \in Values :
        /\ HasPrevoteQuorum(i, round[i], v)
        /\ v /= proposalBlock[i]
        /\ (lockedValue[i] = Nil \/ lockedValue[i] /= v)
    /\ step'       = [step       EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ UNCHANGED <<validRound, validValue>>
    /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = NilVote]
    /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
           [type |-> "vote", voteType |-> "precommit",
            height |-> height[i], round |-> round[i], value |-> NilVote])]
    /\ SendAll({[mtype  |-> PrecommitMsg,
                 height |-> height[i], round |-> round[i],
                 value  |-> NilVote,   source |-> i,
                 ve     |-> NoExt,     dest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

\* --------------------------------------------------------------------------
\* ReceivePrecommitConsensus: Server i receives a PRECOMMIT in the consensus path.
\* Reference: consensus/state.go:2296-2334 (addVote, extension verification block)
\*
\* FAMILY 1 BUG (Issues #5204, #2523):
\*   If the vote's ValidatorAddress equals myAddr (i.e., m.source = i), the
\*   VerifyVoteExtension ABCI call is skipped entirely (state.go:2303-2310).
\*   This is modeled as:
\*     - m.source = i: bypass ABCI check, record selfExtBypassed
\*     - m.source ≠ i: call VerifyVoteExtension; accept only if ext is valid
\* --------------------------------------------------------------------------
ReceivePrecommitConsensus(i, m) ==
    /\ m.mtype  = PrecommitMsg
    /\ m.dest   = i
    /\ ~crashed[i]
    /\ m.height = height[i]
    /\ precommits[i][m.round][m.source] = Nil              \* no duplicate
    /\ LET extEnabled == TRUE                              \* simplified: extensions always enabled
       IN
       IF /\ extEnabled
          /\ m.value /= NilVote                           \* non-nil precommit
          /\ m.source /= i                                \* NOT self-vote (would bypass at state.go:2310)
       THEN \* Full verification path: crypto + ABCI check (state.go:2309-2333)
            /\ LET veValid == (m.ve = ValidExt)           \* models VerifyVoteExtension ABCI call
               IN
               /\ extABCIVerified' = [extABCIVerified EXCEPT ![i][m.source][m.height] = veValid]
               /\ IF veValid
                  THEN precommits' = [precommits EXCEPT ![i][m.round][m.source] = m.value]
                  ELSE UNCHANGED precommits                \* vote rejected on ABCI failure
            /\ UNCHANGED selfExtBypassed
       ELSE IF /\ extEnabled
               /\ m.value /= NilVote
               /\ m.source = i                            \* self-vote bypass (BUG: state.go:2310)
            THEN \* Self-vote path: skip VerifyVoteExtension (state.go:2310 guard)
                 /\ precommits'      = [precommits      EXCEPT ![i][m.round][m.source] = m.value]
                 /\ selfExtBypassed' = [selfExtBypassed EXCEPT ![i][m.height] = TRUE]
                 /\ UNCHANGED extABCIVerified
            ELSE \* Nil precommit or extensions disabled: accept without VE check
                 /\ precommits'  = [precommits EXCEPT ![i][m.round][m.source] = m.value]
                 /\ UNCHANGED <<extABCIVerified, selfExtBypassed>>
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, prevotes, decisionVars,
                   voteExt, lightClientAccepted, blocksyncAccepted,
                   doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* EnterPrecommitWait: Server i starts the precommit timeout.
\* Reference: consensus/state.go:1584-1610 (enterPrecommitWait)
\* --------------------------------------------------------------------------
EnterPrecommitWait(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrecommit
    /\ HasPrecommitTwoThirdsAny(i, round[i])
    /\ ~(\E v \in Values : HasPrecommitQuorum(i, round[i], v))
    /\ step' = [step EXCEPT ![i] = StepPrecommitWait]
    /\ UNCHANGED <<height, round, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* Timeout actions (bound these in MC spec)
\* Reference: consensus/state.go:979-1027 (handleTimeout)
\* --------------------------------------------------------------------------
HandleTimeoutPropose(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPropose
    /\ step' = [step EXCEPT ![i] = StepPrevote]
    /\ prevotes' = [prevotes EXCEPT ![i][round[i]][i] = NilVote]
    /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
           [type |-> "vote", voteType |-> "prevote",
            height |-> height[i], round |-> round[i], value |-> NilVote])]
    /\ SendAll({[mtype  |-> PrevoteMsg,
                 height |-> height[i], round |-> round[i],
                 value  |-> NilVote,   source |-> i, dest |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, lockVars, precommits, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, crashed>>

HandleTimeoutPrevote(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrevoteWait
    /\ step' = [step EXCEPT ![i] = StepPrevote]
    /\ UNCHANGED <<height, round, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

HandleTimeoutPrecommit(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrecommit, StepPrecommitWait}
    /\ round[i] + 1 <= MaxRound
    /\ round' = [round EXCEPT ![i] = round[i] + 1]
    /\ step'  = [step  EXCEPT ![i] = StepNewRound]
    /\ proposal'      = [proposal      EXCEPT ![i] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* RoundSkip: Server i skips to a higher round on receiving f+1 votes.
\* Reference: consensus/state.go:2329-2373 (addVote round-skip triggers)
\* --------------------------------------------------------------------------
RoundSkipPrevote(i) ==
    /\ ~crashed[i]
    /\ \E r \in (round[i]+1)..MaxRound :
        /\ HasPrevoteTwoThirdsAny(i, r)
        /\ round' = [round EXCEPT ![i] = r]
        /\ step'  = [step  EXCEPT ![i] = StepNewRound]
        /\ proposal'      = [proposal      EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

RoundSkipPrecommit(i) ==
    /\ ~crashed[i]
    /\ \E r \in (round[i]+1)..MaxRound :
        /\ HasPrecommitTwoThirdsAny(i, r)
        /\ round' = [round EXCEPT ![i] = r]
        /\ step'  = [step  EXCEPT ![i] = StepNewRound]
        /\ proposal'      = [proposal      EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* EnterCommit: Server i commits a block after +2/3 precommits.
\* Reference: consensus/state.go:1620-1673 (enterCommit)
\* --------------------------------------------------------------------------
EnterCommit(i) ==
    /\ ~crashed[i]
    /\ step[i] /= StepCommit
    /\ \E r \in 0..MaxRound :
        \E v \in Values :
            /\ HasPrecommitQuorum(i, r, v)
            /\ step'     = [step     EXCEPT ![i] = StepCommit]
            /\ decision' = [decision EXCEPT ![i][height[i]] = v]
            /\ walEntries' = [walEntries EXCEPT ![i] = Append(@,
                   [type |-> "endHeight", height |-> height[i]])]
            /\ UNCHANGED <<height, round, proposalVars, lockVars, voteVars,
                            messages, extVerifyVars, doubleSignVars,
                            evidenceVars, blocksyncVars, crashed>>

\* --------------------------------------------------------------------------
\* FinalizeCommit: Server i finalizes commit and advances to next height.
\* Reference: consensus/state.go:1704-1827 (finalizeCommit)
\* --------------------------------------------------------------------------
FinalizeCommit(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepCommit
    /\ decision[i][height[i]] /= Nil
    /\ height[i] + 1 <= MaxHeight
    /\ height' = [height EXCEPT ![i] = height[i] + 1]
    /\ round'  = [round  EXCEPT ![i] = 0]
    /\ step'   = [step   EXCEPT ![i] = StepNewHeight]
    /\ proposal'      = [proposal      EXCEPT ![i] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ validRound'  = [validRound  EXCEPT ![i] = -1]
    /\ validValue'  = [validValue  EXCEPT ![i] = Nil]
    /\ prevotes'   = [prevotes   EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ precommits' = [precommits EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
    \* Update privval last signed (survives crash) — Family 2
    /\ privvalLastSigned' = [privvalLastSigned EXCEPT ![i] =
           [height |-> height[i], round |-> round[i]]]
    /\ UNCHANGED <<decisionVars, messages, extVerifyVars,
                   walPresent, lookbackChecked, evidenceVars, blocksyncVars, walEntries, crashed>>

\* --------------------------------------------------------------------------
\* LoseMessage: A message is dropped by the network.
\* --------------------------------------------------------------------------
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* Crash + Recover: Server i crashes (loses volatile state) and recovers via WAL.
\* Reference: consensus/state.go:764-870 (receiveRoutine), replay.go (Recover)
\* --------------------------------------------------------------------------
Crash(i) ==
    /\ ~crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = TRUE]
    /\ step'   = [step EXCEPT ![i] = StepNewHeight]
    /\ proposal'      = [proposal      EXCEPT ![i] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    \* WAL may lose last async entry (state.go:838 non-fsync peer messages)
    /\ \/ walEntries' = [walEntries EXCEPT ![i] =
              IF Len(@) > 0 THEN SubSeq(@, 1, Len(@) - 1) ELSE @]
       \/ UNCHANGED walEntries
    /\ UNCHANGED <<height, round, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars>>

Recover(i) ==
    /\ crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = FALSE]
    \* Replay WAL to last EndHeightMessage (replay.go:93-170)
    /\ LET lastCommittedH ==
            IF \E k \in 1..Len(walEntries[i]) : walEntries[i][k].type = "endHeight"
            THEN LET maxK == CHOOSE k \in 1..Len(walEntries[i]) :
                     /\ walEntries[i][k].type = "endHeight"
                     /\ \A k2 \in 1..Len(walEntries[i]) :
                         walEntries[i][k2].type = "endHeight" => k2 <= k
                 IN walEntries[i][maxK].height
            ELSE height[i] - 1
       IN
       /\ height' = [height EXCEPT ![i] = lastCommittedH + 1]
       /\ round'  = [round  EXCEPT ![i] = 0]
       /\ step'   = [step   EXCEPT ![i] = StepNewHeight]
    /\ UNCHANGED <<proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, blocksyncVars, walEntries>>

\* ============================================================================
\* ACTIONS: FAMILY 1 — VOTE EXTENSION VERIFICATION ASYMMETRY
\* ============================================================================

\* --------------------------------------------------------------------------
\* AcceptCommitLightClient: A light client node i accepts a commit at height h
\* from a trusted provider WITHOUT calling VerifyVoteExtension on any precommit.
\*
\* Reference: light/verifier.go:57-128 (VerifyAdjacent/VerifyNonAdjacent/Verify)
\*   All three code paths call VerifyCommitLight* which never touches
\*   ExtensionSignature fields in CommitSig (confirmed: state/validation.go:92-95).
\*
\* Issue #2523: "Ensure that all vote extensions in the commit info are verified"
\* --------------------------------------------------------------------------
AcceptCommitLightClient(i, h) ==
    /\ h \in 1..MaxHeight
    /\ syncMode[i] = BLOCKSYNC     \* only light clients in sync mode use this path
    /\ lightClientAccepted[i][h] = FALSE
    \* Light client accepts the commit without VerifyVoteExtension on any vote
    /\ lightClientAccepted' = [lightClientAccepted EXCEPT ![i][h] = TRUE]
    \* extABCIVerified remains FALSE for all voters — no ABCI check performed
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   voteExt, extABCIVerified, selfExtBypassed, blocksyncAccepted,
                   doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* AcceptCommitBlockSync: A blocksync reactor accepts a commit for a downloaded
\* block. Only presence of extensions is checked (EnsureExtensions); individual
\* extension signatures are NOT verified cryptographically.
\*
\* Reference: blocksync/reactor.go:531 (TODO comment about missing verification)
\*            blocksync/reactor.go:548-554 (EnsureExtensions presence check only)
\* --------------------------------------------------------------------------
AcceptCommitBlockSync(i, h) ==
    /\ h \in 1..MaxHeight
    /\ syncMode[i] = BLOCKSYNC
    /\ blocksyncAccepted[i][h] = FALSE
    /\ blocksyncAccepted' = [blocksyncAccepted EXCEPT ![i][h] = TRUE]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   voteExt, extABCIVerified, selfExtBypassed, lightClientAccepted,
                   doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* InjectInvalidVoteExtension: Adversary injects an invalid extension for
\* a Byzantine validator. This models a Byzantine validator whose ExtendVote
\* ABCI callback returns invalid extension data.
\*
\* When the Byzantine validator submits a precommit via EnterPrecommit*, its
\* ve = InvalidExt. Other validators calling VerifyVoteExtension will reject
\* it. But the Byzantine validator itself (via self-bypass) accepts its own
\* precommit without ABCI check.
\* --------------------------------------------------------------------------
InjectInvalidVoteExtension(i) ==
    /\ i \in Faulty
    /\ voteExt[i] = ValidExt
    /\ voteExt' = [voteExt EXCEPT ![i] = InvalidExt]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extABCIVerified, selfExtBypassed, lightClientAccepted, blocksyncAccepted,
                   doubleSignVars, evidenceVars, blocksyncVars, walVars>>

\* ============================================================================
\* ACTIONS: FAMILY 2 — DOUBLE-SIGN PROTECTION OFF-BY-ONE
\* ============================================================================

\* --------------------------------------------------------------------------
\* CheckDoubleSigningRisk: Model the checkDoubleSigningRisk function.
\* Reference: consensus/state.go:2638-2661 (checkDoubleSigningRisk)
\*
\* BUG: The loop is `for i := int64(1); i < doubleSignCheckHeight; i++`
\*      where doubleSignCheckHeight = min(config.DoubleSignCheckHeight, height).
\*      At height=1: doubleSignCheckHeight = min(cfg, 1) = 1 (assuming cfg >= 1).
\*      Loop: for i:=1; i<1 → NEVER EXECUTES (zero iterations).
\*
\* This function is called from receiveRoutine startup (state.go:399).
\* If WAL is absent AND privvalLastSigned has prior state AND loop doesn't
\* check → double-sign window exists.
\* --------------------------------------------------------------------------
CheckDoubleSigningRisk(i, h) ==
    /\ ~crashed[i]
    /\ height[i] = h
    /\ DoubleSignCheckHeight > 0                           \* config enables the check
    \* Model the off-by-one: loop runs 0 iterations at h=1
    \* lookbackChecked[i][h] = TRUE iff min(DoubleSignCheckHeight, h) > 1
    /\ LET doubleSignCheckH == IF DoubleSignCheckHeight > h
                               THEN h
                               ELSE DoubleSignCheckHeight  \* min(cfg, h) — state.go:2643-2645
           loopRuns == doubleSignCheckH > 1               \* for i:=1; i<bound (state.go:2647)
       IN
       /\ lookbackChecked' = [lookbackChecked EXCEPT ![i][h] = loopRuns]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, walPresent, privvalLastSigned, evidenceVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* RestartWithoutWAL: Validator i restarts at height h without WAL available.
\* Reference: consensus/state.go:399 (receiveRoutine start, checkDoubleSigningRisk call)
\*
\* If privvalLastSigned[i] records a prior sign at height h, and the lookback
\* check doesn't run (h=1 off-by-one), the validator may sign again at h
\* conflicting with its prior vote.
\*
\* BUG: At h=1, checkDoubleSigningRisk loop runs 0 iterations, providing
\* zero protection even when configured.
\* --------------------------------------------------------------------------
RestartWithoutWAL(i, h) ==
    /\ h = 1                                               \* height=1 triggers the bug
    /\ DoubleSignCheckHeight > 0                           \* check is enabled but fails
    /\ ~walPresent[i]                                      \* WAL absent (crash scenario)
    /\ ~crashed[i]
    /\ height[i] = h
    /\ walPresent' = [walPresent EXCEPT ![i] = FALSE]      \* WAL still absent
    \* checkDoubleSigningRisk called (state.go:399) but loop runs 0 iterations
    /\ lookbackChecked' = [lookbackChecked EXCEPT ![i][h] = FALSE]  \* BUG: no check
    \* Validator can sign — double-sign window if privvalLastSigned has h=1 state
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, privvalLastSigned, evidenceVars, blocksyncVars, walVars>>

\* ============================================================================
\* ACTIONS: FAMILY 3 — EVIDENCE HASH COLLISION
\* ============================================================================

\* --------------------------------------------------------------------------
\* SubmitLightClientEvidence: A node adds LightClientAttackEvidence to the pool.
\* Reference: evidence/pool.go:AddEvidence (pool.go:181-188, addToCache)
\*            types/evidence.go:322-329 (Hash() — off-by-one copies 31 bytes)
\*
\* The pool key is EvidencePoolKey(ev) = <<commonHeight, HashAliases[conflictingBlockHash]>>
\* where HashAliases models the buggy 31-byte truncation.
\* If a different evidence with the same key is already present, this one is silently dropped.
\* --------------------------------------------------------------------------
SubmitLightClientEvidence(v, commonH, conflictingBH) ==
    /\ conflictingBH \in BlockHash
    /\ commonH \in 1..MaxHeight
    /\ ~crashed[v]
    /\ LET key == EvidencePoolKey(commonH, conflictingBH)
           ev  == [commonHeight |-> commonH, conflictingBlockHash |-> conflictingBH]
       IN
       LET existing == evidencePool[v][key] IN
       \* hashCollision: set if slot occupied by evidence with different hash (collision)
       /\ hashCollision' = (hashCollision \/
              (existing /= NoEvidence /\ existing.conflictingBlockHash /= conflictingBH))
       \* Pool slot: add if empty, suppress (silently drop) if already occupied
       /\ evidencePool' = IF existing = NoEvidence
                          THEN [evidencePool EXCEPT ![v][key] = ev]
                          ELSE evidencePool
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, blocksyncVars, walVars>>

\* --------------------------------------------------------------------------
\* InjectCollidingEvidence: Byzantine adversary pre-populates the evidence pool
\* with evidence whose pool key collides with a (future) honest submission.
\*
\* Scenario: Byzantine node submits evidence with conflictingBlockHash = bh_a.
\* Later, honest node tries to submit evidence with conflictingBlockHash = bh_b
\* where HashAliases[bh_a] = HashAliases[bh_b] (collision).
\* The honest evidence is silently dropped by SubmitLightClientEvidence.
\*
\* Reference: types/evidence.go:326 (off-by-one creates collision)
\* --------------------------------------------------------------------------
InjectCollidingEvidence(v, commonH, bzBlockHash, honestBlockHash) ==
    /\ v \in Faulty
    /\ bzBlockHash \in BlockHash
    /\ honestBlockHash \in BlockHash
    /\ HashesCollide(bzBlockHash, honestBlockHash)         \* same truncated key
    /\ commonH \in 1..MaxHeight
    /\ ~crashed[v]
    /\ LET key == EvidencePoolKey(commonH, bzBlockHash)
           ev  == [commonHeight          |-> commonH,
                   conflictingBlockHash  |-> bzBlockHash]
       IN
       /\ evidencePool' = [evidencePool EXCEPT ![v][key] = ev]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, hashCollision, blocksyncVars, walVars>>

\* ============================================================================
\* ACTIONS: FAMILY 4 — BLOCKSYNC PEER STATE MANIPULATION
\* ============================================================================

\* --------------------------------------------------------------------------
\* SetPeerRange: Update a peer's recorded height in node v's block pool.
\* Reference: blocksync/pool.go:SetPeerRange (lines ~391-413)
\*
\* BUG: maxPeerHeight is raised unconditionally if height > pool.maxPeerHeight.
\*      It is NEVER lowered when a peer re-reports a lower height.
\*      pool.go:411-413: if height > pool.maxPeerHeight { pool.maxPeerHeight = height }
\*
\* This allows a Byzantine peer to inflate maxPeerHeight by first reporting
\* a large height, then updating to a lower one.
\* --------------------------------------------------------------------------
SetPeerRange(v, p, h) ==
    /\ syncMode[v] = BLOCKSYNC
    /\ ~crashed[v]
    /\ h >= 0
    \* Update peer record (pool.go:SetPeerRange updates peer.height)
    /\ peerRecords' = [peerRecords EXCEPT ![v][p] = h]
    \* Unconditionally update maxPeerHeight if h is larger (pool.go:411-413)
    /\ IF h > maxPeerHeight[v]
       THEN maxPeerHeight' = [maxPeerHeight EXCEPT ![v] = h]
       ELSE UNCHANGED maxPeerHeight                        \* BUG: no downward update
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, syncMode, localSyncHeight, walVars>>

\* --------------------------------------------------------------------------
\* RemovePeer: Disconnect a peer from node v's block pool.
\* Reference: blocksync/pool.go:removePeer (lines 426-452)
\*
\* BUG: maxPeerHeight is only recalculated if peer.height == pool.maxPeerHeight.
\*      pool.go:449-451: if peer.height == pool.maxPeerHeight { updateMaxPeerHeight() }
\*
\* Scenario: Byzantine peer first sets peerRecords[v][byz] = 1000 (maxPeerHeight=1000),
\*           then calls SetPeerRange again with h=5 (peerRecords[v][byz]=5, maxPeerHeight stays 1000).
\*           On RemovePeer: peerRecords[v][byz]=5 != maxPeerHeight=1000 → updateMaxPeerHeight NOT called.
\*           maxPeerHeight remains 1000 even after Byzantine peer disconnects.
\* --------------------------------------------------------------------------
RemovePeer(v, p) ==
    /\ syncMode[v] = BLOCKSYNC
    /\ ~crashed[v]
    /\ peerRecords[v][p] /= AbsentPeer                    \* peer must be connected
    /\ LET storedHeight == peerRecords[v][p] IN
       \* Conditional recalculation (pool.go:449-451) — BUG: only recalculates if exact match
       IF storedHeight = maxPeerHeight[v]
       THEN \* Recalculate: find max over remaining peers (pool.go:updateMaxPeerHeight)
            LET remainingPeers == {q \in SyncPeers : q /= p /\ peerRecords[v][q] /= AbsentPeer}
                newMax == MaxSet({peerRecords[v][q] : q \in remainingPeers})
            IN
            /\ maxPeerHeight' = [maxPeerHeight EXCEPT ![v] = newMax]
       ELSE \* BUG: stored height != maxPeerHeight → no recalculation → maxPeerHeight stays stale
            UNCHANGED maxPeerHeight
    /\ peerRecords' = [peerRecords EXCEPT ![v][p] = AbsentPeer]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, syncMode, localSyncHeight, walVars>>

\* --------------------------------------------------------------------------
\* CheckCaughtUp: Check if node v has caught up to the network.
\* Reference: blocksync/pool.go:IsCaughtUp() + reactor.go:poolRoutine()
\*
\* If localSyncHeight >= maxPeerHeight - 1 AND maxPeerHeight > 0, transitions
\* from blocksync to consensus mode.
\* A stale (inflated) maxPeerHeight prevents this transition indefinitely.
\* --------------------------------------------------------------------------
CheckCaughtUp(v) ==
    /\ syncMode[v] = BLOCKSYNC
    /\ ~crashed[v]
    /\ maxPeerHeight[v] > 0                                \* at least one peer known
    /\ localSyncHeight[v] >= maxPeerHeight[v] - 1          \* IsCaughtUp condition
    /\ syncMode' = [syncMode EXCEPT ![v] = CONSENSUS]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, maxPeerHeight, peerRecords,
                   localSyncHeight, walVars>>

\* --------------------------------------------------------------------------
\* AdvanceLocalSync: Node v downloads and applies the next block during blocksync.
\* Reference: blocksync/reactor.go:poolRoutine
\* --------------------------------------------------------------------------
AdvanceLocalSync(v) ==
    /\ syncMode[v] = BLOCKSYNC
    /\ ~crashed[v]
    /\ localSyncHeight[v] + 1 <= MaxHeight
    /\ localSyncHeight' = [localSyncHeight EXCEPT ![v] = localSyncHeight[v] + 1]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars, decisionVars, messages,
                   extVerifyVars, doubleSignVars, evidenceVars, syncMode, maxPeerHeight, peerRecords, walVars>>

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

\* Initial evidence pool: all keys map to NoEvidence
HashAliasRange == {HashAliases[bh] : bh \in BlockHash}

InitEvidencePool(v) ==
    [key \in ((1..MaxHeight) \X HashAliasRange) |-> NoEvidence]

Init ==
    \* Standard consensus state
    /\ height        = [s \in Server |-> 1]
    /\ round         = [s \in Server |-> 0]
    /\ step          = [s \in Server |-> StepNewHeight]
    /\ proposal      = [s \in Server |-> Nil]
    /\ proposalBlock = [s \in Server |-> Nil]
    /\ lockedRound   = [s \in Server |-> -1]
    /\ lockedValue   = [s \in Server |-> Nil]
    /\ validRound    = [s \in Server |-> -1]
    /\ validValue    = [s \in Server |-> Nil]
    /\ prevotes      = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ precommits    = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ decision      = [s \in Server |-> [h \in 1..MaxHeight |-> Nil]]
    /\ messages      = EmptyBag
    \* Family 1: Vote extension vars
    /\ voteExt            = [s \in Server |-> ValidExt]
    /\ extABCIVerified    = [s \in Server |-> [j \in Server |-> [h \in 1..MaxHeight |-> FALSE]]]
    /\ selfExtBypassed    = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ lightClientAccepted = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ blocksyncAccepted   = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    \* Family 2: Double-sign protection vars
    /\ walPresent         = [s \in Server |-> TRUE]
    /\ lookbackChecked    = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ privvalLastSigned  = [s \in Server |-> Nil]
    \* Family 3: Evidence pool vars
    /\ evidencePool  = [s \in Server |-> InitEvidencePool(s)]
    /\ hashCollision = FALSE
    \* Family 4: Blocksync vars
    /\ syncMode       = [s \in Server |-> CONSENSUS]   \* start in consensus for most
    /\ maxPeerHeight  = [s \in Server |-> 0]
    /\ peerRecords    = [s \in Server |-> [p \in SyncPeers |-> AbsentPeer]]
    /\ localSyncHeight = [s \in Server |-> 0]
    \* WAL / crash
    /\ walEntries = [s \in Server |-> <<>>]
    /\ crashed    = [s \in Server |-> FALSE]

Next ==
    \/ \E i \in Server :
        \* Round progression
        \/ EnterNewRound(i, round[i])
        \/ EnterPropose(i)
        \/ EnterPrevote(i)
        \/ EnterPrevoteWait(i)
        \* Precommit (5 paths)
        \/ EnterPrecommitNoPolka(i)
        \/ EnterPrecommitNilPolka(i)
        \/ EnterPrecommitRelockPolka(i)
        \/ EnterPrecommitNewLockPolka(i)
        \/ EnterPrecommitUnknownPolka(i)
        \/ EnterPrecommitWait(i)
        \* Commit + finalize
        \/ EnterCommit(i)
        \/ FinalizeCommit(i)
        \* Timeouts (bound in MC spec)
        \/ HandleTimeoutPropose(i)
        \/ HandleTimeoutPrevote(i)
        \/ HandleTimeoutPrecommit(i)
        \* Round-skip
        \/ RoundSkipPrevote(i)
        \/ RoundSkipPrecommit(i)
        \* Crash / recovery
        \/ Crash(i)
        \/ Recover(i)
        \* Family 1: extension verification paths
        \/ \E h \in 1..MaxHeight :
            \/ AcceptCommitLightClient(i, h)
            \/ AcceptCommitBlockSync(i, h)
        \/ InjectInvalidVoteExtension(i)
        \* Family 2: double-sign protection
        \/ \E h \in 1..MaxHeight :
            \/ CheckDoubleSigningRisk(i, h)
            \/ RestartWithoutWAL(i, h)
        \* Family 3: evidence hash
        \/ \E ch \in 1..MaxHeight, bh \in BlockHash :
            SubmitLightClientEvidence(i, ch, bh)
        \/ \E ch \in 1..MaxHeight, bzBH \in BlockHash, honBH \in BlockHash :
            InjectCollidingEvidence(i, ch, bzBH, honBH)
        \* Family 4: blocksync
        \/ \E p \in SyncPeers, h \in 0..MaxHeight :
            SetPeerRange(i, p, h)
        \/ \E p \in SyncPeers :
            RemovePeer(i, p)
        \/ CheckCaughtUp(i)
        \/ AdvanceLocalSync(i)
    \/ \E m \in DOMAIN messages :
        \* Message handlers
        \/ ReceiveProposal(m.dest, m)
        \/ ReceivePrevote(m.dest, m)
        \/ ReceivePrecommitConsensus(m.dest, m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* ---- Standard safety ----

\* ConsensusAgreement: No two honest nodes commit different blocks at same height.
\* (Standard Tendermint safety property)
ConsensusAgreement ==
    \A s1, s2 \in Server :
        \A h \in 1..MaxHeight :
            (decision[s1][h] /= Nil /\ decision[s2][h] /= Nil) =>
                decision[s1][h] = decision[s2][h]

\* Validity: Only proposed values can be committed.
Validity ==
    \A s \in Server :
        \A h \in 1..MaxHeight :
            decision[s][h] /= Nil => decision[s][h] \in Values

\* LockSafety: A locked node only precommits its locked value
\* (unless polka unlocks it at a higher round).
\* Reference: consensus/state.go:1459-1578
LockSafety ==
    \A s \in Server :
        (lockedValue[s] /= Nil /\ step[s] = StepPrecommit) =>
            \/ precommits[s][round[s]][s] = lockedValue[s]
            \/ precommits[s][round[s]][s] = NilVote
            \/ precommits[s][round[s]][s] = Nil
            \/ \E r \in (lockedRound[s]+1)..round[s] :
                   \E v \in Values :
                       v /= lockedValue[s] /\ HasPrevoteQuorum(s, r, v)

\* POLRoundValidity: polRound < round for all proposals.
POLRoundValidity ==
    \A s \in Server :
        proposal[s] /= Nil =>
            \/ proposal[s].polRound = -1
            \/ proposal[s].polRound < proposal[s].round

\* ---- Family 1: Vote Extension Verification Asymmetry ----

\* ExtensionInCommitVerified: Every precommit vote included in a committed
\* ExtendedCommit was ABCI-verified (via VerifyVoteExtension) by the committing
\* node before inclusion.
\*
\* This invariant is VIOLATED by the self-vote bypass (Issue #5204, MC1):
\* the proposer's precommit bypasses VerifyVoteExtension via the
\* !bytes.Equal(vote.ValidatorAddress, myAddr) guard (state.go:2310).
\* If the proposer's extension is application-invalid, the commit still forms
\* at the proposer's node but contains an unverified extension.
\*
\* Target: MC_hunt_family1.cfg
ExtensionInCommitVerified ==
    \A i \in Server :
        \A h \in 1..MaxHeight :
            decision[i][h] /= Nil =>                       \* node i committed at h
                \* For every validator j whose non-nil precommit was accepted at h:
                \A j \in Server :
                    \A r \in 0..MaxRound :
                        (precommits[i][r][j] = decision[i][h]) =>
                            extABCIVerified[i][j][h]       \* j's ext was ABCI-verified by i

\* LightClientExtensionConsistency: If a light client accepts a commit at height h,
\* all extension signatures that were skipped must belong to honest validators whose
\* extensions are application-valid.
\*
\* This invariant is VIOLATED because the light client never calls VerifyVoteExtension
\* (light/verifier.go:57-128), so it cannot distinguish valid from invalid extensions.
\* A commit containing an application-invalid extension is accepted unconditionally.
\*
\* Target: MC_hunt_family1.cfg
LightClientExtensionConsistency ==
    \A i \in Server :
        \A h \in 1..MaxHeight :
            lightClientAccepted[i][h] =>
                \* No honest validator should have a known invalid extension
                \* that ends up in the accepted commit without being checked
                \A j \in Honest :
                    voteExt[j] = InvalidExt => ~selfExtBypassed[j][h]

\* ---- Family 2: Double-Sign Protection Off-by-One ----

\* NoDoubleSignAtHeight1: A validator restarting without WAL at height=1
\* with DoubleSignCheckHeight > 0 must not sign conflicting votes.
\*
\* This invariant is VIOLATED by the loop off-by-one (Issue #5435, MC3):
\* at height=1, min(DoubleSignCheckHeight, 1) = 1, so the loop
\* `for i:=1; i<1` never executes, providing zero protection.
\* If privvalLastSigned already has a vote at height=1 (prior run),
\* the validator may sign again with a different value.
\*
\* Target: MC_hunt_family2.cfg
NoDoubleSignAtHeight1 ==
    \A i \in Server :
        (\* Scenario: restart without WAL at height=1, double-sign check enabled *)
        /\ ~walPresent[i]
        /\ DoubleSignCheckHeight > 0
        /\ lookbackChecked[i][1] = FALSE          \* loop didn't run (the bug)
        /\ privvalLastSigned[i] /= Nil            \* had a prior signing session
        /\ privvalLastSigned[i].height = 1        \* prior session was also at h=1
        ) =>
            \* No conflicting precommit for height=1 (both sign at same height = double-sign)
            \A r1, r2 \in 0..MaxRound :
                (r1 /= r2 /\ precommits[i][r1][i] /= Nil /\ precommits[i][r2][i] /= Nil) =>
                    precommits[i][r1][i] = precommits[i][r2][i]

\* ---- Family 3: Evidence Hash Collision ----

\* EvidenceDeduplicationSound: Two distinct LightClientAttackEvidence records
\* with different conflicting block hashes must never be assigned the same pool key.
\*
\* This invariant is VIOLATED by the off-by-one in LightClientAttackEvidence.Hash()
\* (Issue #5902, MC4): copy(bz[:tmhash.Size-1], ...) copies only 31 bytes, causing
\* hash collisions between evidences that differ only in the 32nd byte.
\*
\* Target: MC_hunt_family3.cfg
EvidenceDeduplicationSound ==
    ~hashCollision

\* ---- Family 4: Blocksync Peer State ----

\* MaxPeerHeightBoundedOnDisconnect: After a peer disconnects, pool.maxPeerHeight
\* must equal the maximum height of remaining connected peers (0 if no peers).
\*
\* This invariant is VIOLATED by the removePeer bug (Issue #5801, MC5):
\* if the disconnecting peer's stored height (peer.height) does not equal
\* pool.maxPeerHeight, updateMaxPeerHeight() is not called.
\* pool.go:449-451: if peer.height == pool.maxPeerHeight { updateMaxPeerHeight() }
\*
\* Target: MC_hunt_family4.cfg
MaxPeerHeightBoundedOnDisconnect ==
    \A v \in Server :
        LET peers == ConnectedPeers(v) IN
        maxPeerHeight[v] <= MaxSet({peerRecords[v][p] : p \in peers} \cup {0})

\* BlockSyncCatchupLiveness (checked as temporal property in MC spec):
\* A node with all honest peers at height H eventually transitions to consensus.
\* Formally: <>([](syncMode[v] = CONSENSUS)) for honest v with honest peers.

\* ---- Structural invariants ----

RoundBound  == \A s \in Server : round[s] >= 0  /\ round[s] <= MaxRound
HeightBound == \A s \in Server : height[s] >= 1 /\ height[s] <= MaxHeight

LockedRoundBound ==
    \A s \in Server : lockedRound[s] >= -1 /\ lockedRound[s] <= round[s]

LockConsistency ==
    \A s \in Server : (lockedRound[s] = -1) <=> (lockedValue[s] = Nil)

ValidConsistency ==
    \A s \in Server : (validRound[s] = -1) <=> (validValue[s] = Nil)

VoteCountBound ==
    \A s \in Server :
        \A r \in 0..MaxRound :
            /\ Cardinality({j \in Server : prevotes[s][r][j] /= Nil}) <= Cardinality(Server)
            /\ Cardinality({j \in Server : precommits[s][r][j] /= Nil}) <= Cardinality(Server)

DecisionStability ==
    \A s \in Server :
        \A h \in 1..MaxHeight :
            decision[s][h] /= Nil => decision[s][h] \in Values

MaxPeerHeightNonNegative ==
    \A v \in Server : maxPeerHeight[v] >= 0

EvidencePoolKeyBound ==
    \A v \in Server :
        DOMAIN evidencePool[v] = (1..MaxHeight) \X HashAliasRange

LocalSyncHeightNonNegative ==
    \A v \in Server : localSyncHeight[v] >= 0

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* DecisionPermanence: Once decided, a decision is never changed.
DecisionPermanence ==
    [][
        \A s \in Server :
            \A h \in 1..MaxHeight :
                decision[s][h] /= Nil => decision'[s][h] = decision[s][h]
    ]_vars

\* MonotonicHeight: Non-crashed servers never decrease height.
MonotonicHeight ==
    [][
        \A s \in Server :
            (~crashed[s] /\ ~crashed'[s]) => height'[s] >= height[s]
    ]_vars

====
