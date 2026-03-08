------------------------------ MODULE base ------------------------------
\* TLA+ specification of hyperledger/besu QBFT consensus protocol.
\*
\* Models the QBFT (Istanbul BFT) 4-phase consensus with implementation-specific
\* behaviors from the Besu codebase:
\*   1. Block identity includes round+proposer — hash changes on re-proposal (Family 1)
\*   2. Event queue with timer interleaving — race between timer and block import (Family 2)
\*   3. Dual round-change tracking — roundChangeCache vs roundSummary (Family 3)
\*   4. Dynamic validator sets — off-by-one at height boundaries (Family 4)
\*   5. Committed latch — import failure (Family 5, reclassified as Case A spec-impl mismatch)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs (validators)

CONSTANTS Proposing,         \* Server phases within a round
          Prepared,
          Committed

CONSTANT Nil                 \* Null value

CONSTANTS ProposalMsg,       \* Message types
          PrepareMsg,
          CommitMsg,
          RoundChangeMsg

\* Proposer selection: maps (height, round) to proposer.
\* In Besu: proposer = validators[(height + round) % n]
\* We model this as a constant function for model checking.
CONSTANT Proposer(_,_)

----
\* Variables
----

\* --- Per-server consensus state ---
VARIABLE currentHeight       \* [Server -> Nat] — block height being decided
VARIABLE currentRound        \* [Server -> Nat \cup {Nil}] — current round (Nil = no round)
VARIABLE phase               \* [Server -> {Proposing, Prepared, Committed}]

\* --- Per-server per-round message tracking ---
\* Extension 1 (Family 1): Block identity = <<content, round, proposer>>
\* proposedBlock[s] = block record or Nil
VARIABLE proposedBlock       \* [Server -> block record \cup {Nil}]
VARIABLE prepareMessages     \* [Server -> set of {sender, blockHash}]
VARIABLE commitMessages      \* [Server -> set of {sender, blockHash, seal}]

\* Extension 3 (Family 3): Round change tracking
\* roundChangeCache[s][r] = set of round change messages targeting round r
\* roundSummary[s] = [validator -> latest round] (put-overwrites)
\* actioned[s][r] = boolean — one-shot flag per round
VARIABLE roundChangeMessages \* [Server -> [Nat -> set of RC messages]]
VARIABLE roundSummary        \* [Server -> [Server -> Int]]
VARIABLE actioned            \* [Server -> [Nat -> BOOLEAN]]
VARIABLE latestPrepCert      \* [Server -> prepared certificate or Nil]

\* Extension 2 (Family 2): Event queue / height tracking
\* blockchainHeight[s] = confirmed chain height (updated on block import)
\* heightManagerHeight[s] = height the consensus manager is working on
VARIABLE blockchainHeight    \* [Server -> Nat]

\* Extension 5 (Family 5): Committed latch and block import
VARIABLE committed           \* [Server -> BOOLEAN] — one-way latch
VARIABLE blockImported       \* [Server -> BOOLEAN] — whether block actually persisted

\* Extension 4 (Family 4): Dynamic validator set
\* validators[h] = set of validators for height h
\* For simplicity we model a fixed set with optional changes.
VARIABLE validators          \* [Nat -> SUBSET Server]

\* --- Network ---
VARIABLE messages            \* Bag of message records

\* --- Crash/recovery ---
VARIABLE alive               \* [Server -> BOOLEAN]

----
\* Variable groups
----

serverVars    == <<currentHeight, currentRound, phase>>
roundVars     == <<proposedBlock, prepareMessages, commitMessages>>
rcVars        == <<roundChangeMessages, roundSummary, actioned, latestPrepCert>>
heightVars    == <<blockchainHeight>>
latchVars     == <<committed, blockImported>>
validatorVars == <<validators>>
crashVars     == <<alive>>

vars == <<serverVars, roundVars, rcVars, heightVars, latchVars,
          validatorVars, messages, crashVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

\* QBFT quorum: ceil(2n/3)
\* Reference: BftHelpers.java:42-44
Quorum(valSet) == LET n == Cardinality(valSet)
                      twon == 2 * n
                  IN (twon \div 3) + (IF (twon % 3) = 0 THEN 0 ELSE 1)

\* f+1 for early round change
\* Reference: BftHelpers.java:52-54
FPlus1(valSet) == (Cardinality(valSet) - 1) \div 3 + 1

\* Prepare message count for quorum (quorum - 1, since proposer counts)
\* Reference: BftHelpers.java:62-64
PrepareQuorum(valSet) == Quorum(valSet) - 1

\* Current validator set for a height
ValidatorsAt(h) == validators[h]

\* Block identity — models hash as <<content, round, proposer>>
\* Family 1: hash changes when round or proposer changes
\* Reference: QbftRound.java:170-172 — replaceRoundAndProposerForProposalBlock
BlockHash(content, round, proposer) == <<content, round, proposer>>

\* Type-safe Nil check for record-valued variables.
\* Model value Nil can be safely compared with any type (records, integers, strings).
IsNil(x) == x = Nil

\* Best prepared certificate selection from round change messages.
\* Selects the RC message with the highest preparedRound.
\* Can be overridden for MC-6 (broken comparator) testing.
\* Reference: RoundChangeArtifacts.java:70-104
BestPrepared(preparedMsgs) ==
    CHOOSE msg \in preparedMsgs :
        \A other \in preparedMsgs :
            msg.preparedRound >= other.preparedRound

\* Message bag helpers
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
DiscardAndSendAll(discard, sends) ==
    messages' = (messages (-) SetToBag({discard})) (+) SetToBag(sends)
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})

----
\* Init
----

\* Initial validator set: all servers are validators at height 1
InitValidators == [h \in 0..3 |-> Server]

Init ==
    /\ currentHeight       = [s \in Server |-> 1]
    /\ currentRound        = [s \in Server |-> Nil]  \* no round yet (block timer pending)
    /\ phase               = [s \in Server |-> Proposing]
    /\ proposedBlock       = [s \in Server |-> Nil]
    /\ prepareMessages     = [s \in Server |-> {}]
    /\ commitMessages      = [s \in Server |-> {}]
    /\ roundChangeMessages = [s \in Server |-> [r \in 0..10 |-> {}]]
    /\ roundSummary        = [s \in Server |-> [v \in Server |-> Nil]]
    /\ actioned            = [s \in Server |-> [r \in 0..10 |-> FALSE]]
    /\ latestPrepCert      = [s \in Server |-> Nil]
    /\ blockchainHeight    = [s \in Server |-> 0]
    /\ committed           = [s \in Server |-> FALSE]
    /\ blockImported       = [s \in Server |-> FALSE]
    /\ validators          = InitValidators
    /\ messages            = EmptyBag
    /\ alive               = [s \in Server |-> TRUE]

----
\* Block Timer Expiry — starts round 0
\* Reference: QbftBlockHeightManager.java:164-187 (handleBlockTimerExpiry)
\* Reference: QbftController.java:261-271 (handleBlockTimerExpiry)
\*
\* Family 2: Block timer expiry lacks the blockchain-head guard that round
\* expiry has. Only checks heightManagerHeight (isMsgForCurrentHeight).
\* MC-1: Can a stale block timer cause a duplicate proposal?
----

BlockTimerExpiry(s) ==
    /\ alive[s]
    /\ currentRound[s] = Nil   \* no round active yet (QbftBlockHeightManager.java:165)
    \* Family 2: Only checks height manager height, NOT blockchain height
    \* QbftController.java:263 — isMsgForCurrentHeight checks getCurrentChainHeight()
    \* which returns currentHeightManager.getChainHeight() = parentHeader.getNumber() + 1
    /\ LET h == currentHeight[s]
           valSet == ValidatorsAt(h)
           proposer == Proposer(h, 0)
       IN
       \* Start round 0 (QbftBlockHeightManager.java:173 — startNewRound(0))
       /\ currentRound' = [currentRound EXCEPT ![s] = 0]
       /\ phase' = [phase EXCEPT ![s] = Proposing]
       \* If this node is proposer, create and propose block
       \* QbftBlockHeightManager.java:193-194 — isLocalNodeProposerForRound
       /\ IF s = proposer
          THEN \* Proposer creates new block and broadcasts proposal
               \* QbftBlockHeightManager.java:211-212 — updateStateWithProposalAndTransmit
               \* QbftRound.java:193-217 — updateStateWithProposalAndTransmit
               LET content == <<h, s>>  \* unique block content
                   blockHash == BlockHash(content, 0, s)
                   block == [content |-> content, round |-> 0,
                             proposer |-> s, hash |-> blockHash]
               IN
               /\ proposedBlock' = [proposedBlock EXCEPT ![s] = block]
               \* Proposer adds own commit seal immediately
               \* QbftRound.java:308-311 — addCommitMessage (local)
               /\ commitMessages' = [commitMessages EXCEPT ![s] =
                    {[sender |-> s, blockHash |-> blockHash]}]
               /\ prepareMessages' = prepareMessages  \* proposer doesn't prepare own block
               /\ SendAll({[mtype |-> ProposalMsg,
                            msource |-> s,
                            mdest |-> d,
                            mheight |-> h,
                            mround |-> 0,
                            mblock |-> block,
                            mroundChanges |-> {},
                            mprepares |-> {}] : d \in valSet \ {s}})
          ELSE \* Not proposer: just start round, wait for proposal
               /\ UNCHANGED <<proposedBlock, prepareMessages, commitMessages, messages>>
    /\ UNCHANGED <<currentHeight, rcVars, heightVars, latchVars,
                   validatorVars, crashVars>>

----
\* Handle Proposal Message
\* Reference: QbftRound.java:224-233 (handleProposalMessage)
\* Reference: QbftBlockHeightManager.java:323-339 (handleProposalPayload)
\*
\* Family 1: Validator must reconstruct block hash correctly.
\* ProposalValidator.java:167-189 verifies the block hash.
----

HandleProposal(s, m) ==
    /\ alive[s]
    /\ m.mtype = ProposalMsg
    /\ m.mdest = s
    /\ m.mheight = currentHeight[s]
    /\ LET h == m.mheight
           r == m.mround
           block == m.mblock
           valSet == ValidatorsAt(h)
           expectedProposer == Proposer(h, r)
       IN
       \* Message age check (QbftBlockHeightManager.java:326-327)
       \* Accept if no round yet, or message round >= current round
       /\ IF currentRound[s] = Nil THEN TRUE
          ELSE r >= currentRound[s]
       \* Proposal must come from the correct proposer
       /\ block.proposer = expectedProposer
       \* Family 1: Validate block hash reconstruction
       \* ProposalValidator.java:167-189 — hash must match (content, round, proposer)
       /\ block.hash = BlockHash(block.content, r, expectedProposer)
       \* No existing proposal for this round
       \* RoundState.java:99 — proposalMessage.isEmpty()
       /\ proposedBlock[s] = Nil
       \* If future round, advance (QbftBlockHeightManager.java:336)
       /\ currentRound' = [currentRound EXCEPT ![s] = r]
       /\ proposedBlock' = [proposedBlock EXCEPT ![s] = block]
       \* RoundState.java:100-105 — setProposedBlock validates and updates state
       \* Send prepare message (QbftRound.java:230-232)
       /\ prepareMessages' = [prepareMessages EXCEPT ![s] = @ \cup
            {[sender |-> s, blockHash |-> block.hash]}]
       \* Add own commit seal (QbftRound.java:308-311)
       /\ commitMessages' = [commitMessages EXCEPT ![s] = @ \cup
            {[sender |-> s, blockHash |-> block.hash]}]
       \* Broadcast prepare (QbftRound.java:241-242) and discard incoming proposal
       /\ DiscardAndSendAll(m, {[mtype |-> PrepareMsg,
                    msource |-> s,
                    mdest |-> d,
                    mheight |-> h,
                    mround |-> r,
                    mblockHash |-> block.hash] : d \in valSet \ {s}})
       /\ phase' = [phase EXCEPT ![s] = Proposing]
    /\ UNCHANGED <<currentHeight, rcVars, heightVars, latchVars,
                   validatorVars, crashVars>>

----
\* Handle Prepare Message
\* Reference: QbftRound.java:253-259 (handlePrepareMessage)
\* Reference: QbftRound.java:326-339 (peerIsPrepared)
\* Reference: RoundState.java:117-123 (addPrepareMessage)
\*
\* When prepare quorum reached (quorum-1 prepares + proposal), transition to Prepared
\* and broadcast commit.
----

HandlePrepare(s, m) ==
    /\ alive[s]
    /\ m.mtype = PrepareMsg
    /\ m.mdest = s
    /\ m.mheight = currentHeight[s]
    /\ m.mround = currentRound[s]
    /\ ~IsNil(proposedBlock[s])
    /\ m.mblockHash = proposedBlock[s].hash
    /\ LET h == m.mheight
           r == m.mround
           valSet == ValidatorsAt(h)
           \* Add prepare to set (RoundState.java:119 — putIfAbsent)
           newPrepares == prepareMessages[s] \cup
                          {[sender |-> m.msource, blockHash |-> m.mblockHash]}
           wasPrepared == phase[s] \in {Prepared, Committed}
           \* RoundState.java:140 — prepared = prepareMessages.size() >= quorum && proposal present
           isPrepared == Cardinality(newPrepares) >= PrepareQuorum(valSet)
       IN
       /\ prepareMessages' = [prepareMessages EXCEPT ![s] = newPrepares]
       \* If newly prepared, broadcast commit (QbftRound.java:329-338)
       /\ IF ~wasPrepared /\ isPrepared
          THEN /\ phase' = [phase EXCEPT ![s] = Prepared]
               /\ DiscardAndSendAll(m, {[mtype |-> CommitMsg,
                            msource |-> s,
                            mdest |-> d,
                            mheight |-> h,
                            mround |-> r,
                            mblockHash |-> proposedBlock[s].hash,
                            mseal |-> s] : d \in valSet \ {s}})
          ELSE /\ UNCHANGED phase
               /\ Discard(m)
    /\ UNCHANGED <<currentHeight, currentRound, proposedBlock, commitMessages,
                   rcVars, heightVars, latchVars, validatorVars, crashVars>>

----
\* Handle Commit Message
\* Reference: QbftRound.java:266-272 (handleCommitMessage)
\* Reference: QbftRound.java:342-348 (peerIsCommitted)
\* Reference: RoundState.java:130-137 (addCommitMessage)
\*
\* When commit quorum reached, import block.
\* Family 5: committed latch prevents retry on import failure.
----

HandleCommit(s, m) ==
    /\ alive[s]
    /\ m.mtype = CommitMsg
    /\ m.mdest = s
    /\ m.mheight = currentHeight[s]
    /\ m.mround = currentRound[s]
    /\ ~IsNil(proposedBlock[s])
    /\ m.mblockHash = proposedBlock[s].hash
    /\ LET h == m.mheight
           valSet == ValidatorsAt(h)
           newCommits == commitMessages[s] \cup
                         {[sender |-> m.msource, blockHash |-> m.mblockHash]}
           wasCommitted == committed[s]
           \* RoundState.java:141 — committed = commitMessages.size() >= quorum && proposal present
           isCommitted == Cardinality(newCommits) >= Quorum(valSet)
       IN
       /\ commitMessages' = [commitMessages EXCEPT ![s] = newCommits]
       \* If newly committed, set latch and attempt import
       \* Family 5: committed is a one-way latch (RoundState.java:141)
       /\ IF ~wasCommitted /\ isCommitted
          THEN /\ committed' = [committed EXCEPT ![s] = TRUE]
               /\ phase' = [phase EXCEPT ![s] = Committed]
               \* Block import: non-deterministic success/failure (Family 5)
               \* QbftRound.java:350-383 — importBlockToChain
               /\ \/ \* Import succeeds
                     /\ blockImported' = [blockImported EXCEPT ![s] = TRUE]
                     /\ blockchainHeight' = [blockchainHeight EXCEPT ![s] = h]
                  \/ \* Import fails — committed latch prevents retry
                     \* QbftRound.java:375-379 — logs error, no retry
                     /\ UNCHANGED <<blockImported, blockchainHeight>>
          ELSE /\ UNCHANGED <<phase, committed, blockImported, blockchainHeight>>
    /\ Discard(m)
    /\ UNCHANGED <<currentHeight, currentRound, proposedBlock, prepareMessages,
                   rcVars, validatorVars, crashVars>>

----
\* Round Expiry — triggers round change
\* Reference: QbftBlockHeightManager.java:265-282 (roundExpired)
\* Reference: QbftBlockHeightManager.java:284-320 (doRoundChange)
\* Reference: QbftController.java:274-290 (handleRoundExpiry)
\*
\* Family 2: Round expiry has DUAL guard:
\*   1. blockchain head check (QbftController.java:277)
\*   2. height manager check (QbftController.java:282)
\* This is stronger than block timer expiry (Family 2, MC-1).
----

RoundExpiry(s) ==
    /\ alive[s]
    /\ currentRound[s] /= Nil  \* must have an active round
    \* NOTE: Implementation does NOT check committed state here.
    \* QbftBlockHeightManager.java:268-288 — roundExpired() has no isCommitted() guard.
    \* A committed node with failed import CAN round-change (losing collected seals).
    \* Family 2: Dual guard — check blockchain height AND height manager height
    \* QbftController.java:277 — roundExpiry.getView().getSequenceNumber() <= blockchain.getChainHeadBlockNumber()
    /\ blockchainHeight[s] < currentHeight[s]
    /\ LET h == currentHeight[s]
           oldRound == currentRound[s]
           newRound == oldRound + 1
           valSet == ValidatorsAt(h)
           \* Construct prepared certificate if prepared
           \* QbftBlockHeightManager.java:293-294
           hasPrepCert == phase[s] \in {Prepared, Committed} /\ ~IsNil(proposedBlock[s])
           prepCert == IF hasPrepCert
                       THEN [block |-> proposedBlock[s],
                             prepares |-> prepareMessages[s],
                             round |-> oldRound]
                       ELSE Nil
           effectivePrepCert == IF ~IsNil(prepCert) THEN prepCert
                                ELSE latestPrepCert[s]
       IN
       \* Start new round (QbftBlockHeightManager.java:300)
       /\ currentRound' = [currentRound EXCEPT ![s] = newRound]
       /\ phase' = [phase EXCEPT ![s] = Proposing]
       \* Reset round state
       /\ proposedBlock' = [proposedBlock EXCEPT ![s] = Nil]
       /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
       /\ commitMessages' = [commitMessages EXCEPT ![s] = {}]
       /\ committed' = [committed EXCEPT ![s] = FALSE]
       /\ blockImported' = [blockImported EXCEPT ![s] = FALSE]
       \* Update latest prepared certificate (QbftBlockHeightManager.java:296-298)
       /\ latestPrepCert' = [latestPrepCert EXCEPT ![s] =
            IF ~IsNil(prepCert) THEN prepCert ELSE @]
       \* Create and send round change message
       \* QbftBlockHeightManager.java:308-310
       /\ SendAll({[mtype |-> RoundChangeMsg,
                    msource |-> s,
                    mdest |-> d,
                    mheight |-> h,
                    mround |-> newRound,
                    mpreparedRound |-> IF ~IsNil(effectivePrepCert)
                                       THEN effectivePrepCert.round
                                       ELSE Nil,
                    mpreparedBlock |-> IF ~IsNil(effectivePrepCert)
                                       THEN effectivePrepCert.block
                                       ELSE Nil,
                    mprepares |-> IF ~IsNil(effectivePrepCert)
                                  THEN effectivePrepCert.prepares
                                  ELSE {}] : d \in valSet})
       \* Also handle own round change (QbftBlockHeightManager.java:314)
       /\ roundChangeMessages' = [roundChangeMessages EXCEPT
            ![s] = [roundChangeMessages[s] EXCEPT
              ![newRound] = @ \cup {[sender |-> s,
                                     targetRound |-> newRound,
                                     preparedRound |-> IF ~IsNil(effectivePrepCert)
                                                       THEN effectivePrepCert.round ELSE Nil,
                                     preparedBlock |-> IF ~IsNil(effectivePrepCert)
                                                       THEN effectivePrepCert.block ELSE Nil]}]]
       \* Family 3: roundSummary uses put (overwrites) — QbftController line would update
       /\ roundSummary' = [roundSummary EXCEPT ![s] = [@ EXCEPT ![s] = newRound]]
       /\ actioned' = actioned
    /\ UNCHANGED <<currentHeight, blockchainHeight, validatorVars, crashVars>>

----
\* Handle Round Change Message
\* Reference: QbftBlockHeightManager.java:378-450 (handleRoundChangePayload)
\* Reference: RoundChangeManager.java:213-227 (appendRoundChangeMessage)
\*
\* Two paths:
\*   A. Standard 2f+1 quorum path (QbftBlockHeightManager.java:401-419)
\*   B. Early f+1 path (QbftBlockHeightManager.java:420-449)
\*
\* Family 3: roundSummary (put-overwrites) vs roundChangeCache (putIfAbsent)
\* MC-3: Can f+1 early round change use stale data?
----

HandleRoundChange(s, m) ==
    /\ alive[s]
    /\ m.mtype = RoundChangeMsg
    /\ m.mdest = s
    /\ m.mheight = currentHeight[s]
    /\ LET h == m.mheight
           targetRound == m.mround
           valSet == ValidatorsAt(h)
           rcMsg == [sender |-> m.msource,
                     targetRound |-> targetRound,
                     preparedRound |-> m.mpreparedRound,
                     preparedBlock |-> m.mpreparedBlock]
       IN
       \* Message age: not prior round
       \* QbftBlockHeightManager.java:391-394
       /\ IF currentRound[s] = Nil THEN TRUE
          ELSE targetRound >= currentRound[s]
       \* Family 3: Update roundSummary with put (overwrites)
       \* RoundChangeManager.java:156 — roundSummary.put(author, roundIdentifier)
       /\ roundSummary' = [roundSummary EXCEPT ![s] =
            [@ EXCEPT ![m.msource] = targetRound]]
       \* Store in roundChangeCache (putIfAbsent per validator per round)
       \* RoundChangeManager.java:69-71 — addMessage: putIfAbsent if !actioned
       /\ IF ~actioned[s][targetRound]
          THEN roundChangeMessages' = [roundChangeMessages EXCEPT
                ![s] = [@ EXCEPT ![targetRound] =
                  IF \E msg \in @ : msg.sender = m.msource
                  THEN @  \* putIfAbsent — keep first
                  ELSE @ \cup {rcMsg}]]
          ELSE UNCHANGED roundChangeMessages
       \* Check 2f+1 quorum for targetRound
       \* RoundChangeManager.java:79-80 — roundChangeQuorumReceived
       /\ LET rcMsgs == IF ~actioned[s][targetRound]
                         THEN (IF \E msg \in roundChangeMessages[s][targetRound] : msg.sender = m.msource
                               THEN roundChangeMessages[s][targetRound]
                               ELSE roundChangeMessages[s][targetRound] \cup {rcMsg})
                         ELSE roundChangeMessages[s][targetRound]
              hasQuorum == Cardinality(rcMsgs) >= Quorum(valSet)
              \* If quorum reached and this node is proposer for targetRound
              isProposer == Proposer(h, targetRound) = s
          IN
          IF hasQuorum /\ ~actioned[s][targetRound]
          THEN \* 2f+1 quorum path (QbftBlockHeightManager.java:401-419)
               /\ actioned' = [actioned EXCEPT ![s] =
                    [@ EXCEPT ![targetRound] = TRUE]]
               \* Start new round if future (QbftBlockHeightManager.java:405-407)
               /\ currentRound' = [currentRound EXCEPT ![s] =
                    IF @ = Nil THEN targetRound ELSE Max(@, targetRound)]
               /\ IF isProposer
                  THEN \* Proposer creates proposal from round change certificate
                       \* Family 1: Re-proposal must update block identity
                       \* QbftRound.java:153-183 (startRoundWith)
                       \* RoundChangeArtifacts.java:70-104 (create)
                       LET \* Find best prepared certificate from RC messages
                           preparedMsgs == {msg \in rcMsgs : msg.preparedRound /= Nil}
                           hasPrepared == preparedMsgs /= {}
                           bestPrepared == IF hasPrepared
                                           THEN BestPrepared(preparedMsgs)
                                           ELSE Nil
                       IN
                       IF hasPrepared /\ ~IsNil(bestPrepared)
                       THEN \* Re-propose from prepared certificate
                            \* Family 1: replaceRoundAndProposerForProposalBlock
                            \* QbftRound.java:169-172
                            LET oldBlock == bestPrepared.preparedBlock
                                newHash == BlockHash(oldBlock.content, targetRound, s)
                                newBlock == [content |-> oldBlock.content,
                                             round |-> targetRound,
                                             proposer |-> s,
                                             hash |-> newHash]
                            IN
                            /\ proposedBlock' = [proposedBlock EXCEPT ![s] = newBlock]
                            /\ commitMessages' = [commitMessages EXCEPT ![s] =
                                 {[sender |-> s, blockHash |-> newHash]}]
                            /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
                            /\ DiscardAndSendAll(m, {[mtype |-> ProposalMsg,
                                         msource |-> s,
                                         mdest |-> d,
                                         mheight |-> h,
                                         mround |-> targetRound,
                                         mblock |-> newBlock,
                                         mroundChanges |-> rcMsgs,
                                         mprepares |-> bestPrepared.preparedBlock] : d \in valSet \ {s}})
                       ELSE \* No prepared cert — propose new block
                            LET content == <<h, s, targetRound>>
                                blockHash == BlockHash(content, targetRound, s)
                                newBlock == [content |-> content,
                                             round |-> targetRound,
                                             proposer |-> s,
                                             hash |-> blockHash]
                            IN
                            /\ proposedBlock' = [proposedBlock EXCEPT ![s] = newBlock]
                            /\ commitMessages' = [commitMessages EXCEPT ![s] =
                                 {[sender |-> s, blockHash |-> blockHash]}]
                            /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
                            /\ DiscardAndSendAll(m, {[mtype |-> ProposalMsg,
                                         msource |-> s,
                                         mdest |-> d,
                                         mheight |-> h,
                                         mround |-> targetRound,
                                         mblock |-> newBlock,
                                         mroundChanges |-> rcMsgs,
                                         mprepares |-> {}] : d \in valSet \ {s}})
                  ELSE \* Not proposer: reset round state
                       /\ proposedBlock' = [proposedBlock EXCEPT ![s] = Nil]
                       /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
                       /\ commitMessages' = [commitMessages EXCEPT ![s] = {}]
                       /\ Discard(m)
               /\ phase' = [phase EXCEPT ![s] = Proposing]
               /\ committed' = [committed EXCEPT ![s] = FALSE]
               /\ blockImported' = [blockImported EXCEPT ![s] = FALSE]
               /\ UNCHANGED latestPrepCert
          ELSE \* No 2f+1 quorum yet — check f+1 early path
               \* QbftBlockHeightManager.java:439-448
               LET curRound == IF currentRound[s] = Nil THEN 0 ELSE currentRound[s]
                   \* Count validators at rounds higher than current
                   futureCount == Cardinality(
                     {v \in valSet :
                       LET r == IF v = m.msource THEN targetRound
                                ELSE roundSummary[s][v]
                       IN IF r = Nil THEN FALSE ELSE r > curRound})
               IN
               IF futureCount >= FPlus1(valSet)
               THEN \* Early round change: jump to min future round
                    \* QbftBlockHeightManager.java:447 — doRoundChange(nextHigherRound.get())
                    LET futureRounds == {IF v = m.msource THEN targetRound
                                         ELSE roundSummary[s][v] :
                                         v \in {v2 \in valSet :
                                           LET rv == IF v2 = m.msource THEN targetRound
                                                     ELSE roundSummary[s][v2]
                                           IN IF rv = Nil THEN FALSE ELSE rv > curRound}}
                        minFutureRound == CHOOSE r \in futureRounds :
                                            \A r2 \in futureRounds : r <= r2
                    IN
                    /\ currentRound' = [currentRound EXCEPT ![s] = minFutureRound]
                    /\ phase' = [phase EXCEPT ![s] = Proposing]
                    /\ proposedBlock' = [proposedBlock EXCEPT ![s] = Nil]
                    /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
                    /\ commitMessages' = [commitMessages EXCEPT ![s] = {}]
                    /\ committed' = [committed EXCEPT ![s] = FALSE]
                    /\ blockImported' = [blockImported EXCEPT ![s] = FALSE]
                    \* Send own round change and discard incoming
                    /\ DiscardAndSendAll(m, {[mtype |-> RoundChangeMsg,
                                 msource |-> s,
                                 mdest |-> d,
                                 mheight |-> h,
                                 mround |-> minFutureRound,
                                 mpreparedRound |-> IF ~IsNil(latestPrepCert[s])
                                                    THEN latestPrepCert[s].round ELSE Nil,
                                 mpreparedBlock |-> IF ~IsNil(latestPrepCert[s])
                                                    THEN latestPrepCert[s].block ELSE Nil,
                                 mprepares |-> IF ~IsNil(latestPrepCert[s])
                                               THEN latestPrepCert[s].prepares ELSE {}]
                                 : d \in valSet})
                    /\ UNCHANGED <<actioned, latestPrepCert>>
               ELSE \* Neither quorum met
                    /\ UNCHANGED <<currentRound, phase, proposedBlock, prepareMessages,
                                   commitMessages, committed, blockImported,
                                   actioned, latestPrepCert>>
                    /\ Discard(m)
    /\ UNCHANGED <<currentHeight, blockchainHeight, validatorVars, crashVars>>

----
\* New Chain Head — advance to next height
\* Reference: QbftController.java:228-258 (handleNewBlockEvent)
\*
\* Family 2: This is triggered by block import, which updates blockchainHeight.
\* The height manager is recreated for the new height.
----

NewChainHead(s) ==
    /\ alive[s]
    /\ blockImported[s]
    /\ blockchainHeight[s] >= currentHeight[s]
    \* Advance height manager to next height
    \* QbftController.java:257 — startNewHeightManager(newBlockHeader)
    /\ LET newHeight == blockchainHeight[s] + 1
       IN
       /\ currentHeight' = [currentHeight EXCEPT ![s] = newHeight]
       /\ currentRound' = [currentRound EXCEPT ![s] = Nil]
       /\ phase' = [phase EXCEPT ![s] = Proposing]
       /\ proposedBlock' = [proposedBlock EXCEPT ![s] = Nil]
       /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
       /\ commitMessages' = [commitMessages EXCEPT ![s] = {}]
       /\ committed' = [committed EXCEPT ![s] = FALSE]
       /\ blockImported' = [blockImported EXCEPT ![s] = FALSE]
       \* Reset round change state
       /\ roundChangeMessages' = [roundChangeMessages EXCEPT
            ![s] = [r \in 0..10 |-> {}]]
       /\ roundSummary' = [roundSummary EXCEPT
            ![s] = [v \in Server |-> Nil]]
       /\ actioned' = [actioned EXCEPT
            ![s] = [r \in 0..10 |-> FALSE]]
       /\ latestPrepCert' = [latestPrepCert EXCEPT ![s] = Nil]
    /\ UNCHANGED <<blockchainHeight, validatorVars, messages, crashVars>>

----
\* Crash and Recovery
\* In-memory only consensus state; crash = full state loss.
\* Reference: modeling-brief.md §3.1
----

Crash(s) ==
    /\ alive[s]
    /\ alive' = [alive EXCEPT ![s] = FALSE]
    \* All volatile state is lost
    /\ currentRound' = [currentRound EXCEPT ![s] = Nil]
    /\ phase' = [phase EXCEPT ![s] = Proposing]
    /\ proposedBlock' = [proposedBlock EXCEPT ![s] = Nil]
    /\ prepareMessages' = [prepareMessages EXCEPT ![s] = {}]
    /\ commitMessages' = [commitMessages EXCEPT ![s] = {}]
    /\ committed' = [committed EXCEPT ![s] = FALSE]
    /\ blockImported' = [blockImported EXCEPT ![s] = FALSE]
    /\ roundChangeMessages' = [roundChangeMessages EXCEPT
         ![s] = [r \in 0..10 |-> {}]]
    /\ roundSummary' = [roundSummary EXCEPT
         ![s] = [v \in Server |-> Nil]]
    /\ actioned' = [actioned EXCEPT
         ![s] = [r \in 0..10 |-> FALSE]]
    /\ latestPrepCert' = [latestPrepCert EXCEPT ![s] = Nil]
    \* blockchainHeight persists (on disk)
    /\ UNCHANGED <<currentHeight, blockchainHeight, validatorVars, messages>>

Recover(s) ==
    /\ ~alive[s]
    /\ alive' = [alive EXCEPT ![s] = TRUE]
    \* Recovery: height from blockchain, round change required to rejoin
    /\ currentHeight' = [currentHeight EXCEPT ![s] = blockchainHeight[s] + 1]
    /\ UNCHANGED <<currentRound, phase, proposedBlock, prepareMessages, commitMessages,
                   rcVars, heightVars, latchVars, validatorVars, messages>>

----
\* Network failures
----

\* Message is lost
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, roundVars, rcVars, heightVars, latchVars,
                   validatorVars, crashVars>>

\* Drop stale messages (from old heights)
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ m.mheight < currentHeight[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, roundVars, rcVars, heightVars, latchVars,
                   validatorVars, crashVars>>

----
\* Peer Sync — blockchain advances via block from peer (not through consensus)
\* Reference: QbftController.java:228-258 (handleNewBlockEvent)
\*
\* MC-1: Models the scenario where a node receives a block from a peer,
\* advancing its blockchain height. This creates the race condition where
\* BlockTimerExpiry (which lacks the blockchain-head guard) could fire
\* for a height that already has a block on the blockchain.
\* Not included in the standard Next — used only in bug hunting configs.
----

PeerSync(s) ==
    /\ alive[s]
    /\ blockchainHeight[s] < currentHeight[s]
    /\ blockchainHeight' = [blockchainHeight EXCEPT ![s] = currentHeight[s]]
    /\ blockImported' = [blockImported EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<currentHeight, currentRound, phase, proposedBlock, prepareMessages,
                   commitMessages, rcVars, committed, validatorVars, messages, crashVars>>

----
\* Spec
----

Next ==
    \/ \E s \in Server :
        \/ BlockTimerExpiry(s)
        \/ RoundExpiry(s)
        \/ NewChainHead(s)
        \/ Crash(s)
        \/ Recover(s)
    \/ \E m \in DOMAIN messages :
        \/ HandleProposal(m.mdest, m)
        \/ HandlePrepare(m.mdest, m)
        \/ HandleCommit(m.mdest, m)
        \/ HandleRoundChange(m.mdest, m)
        \/ LoseMessage(m)
        \/ DropStaleMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* Standard: At most one block committed at the same height.
\* No two honest nodes commit different blocks at the same height.
Agreement ==
    \A s1, s2 \in Server :
        /\ alive[s1] /\ alive[s2]
        /\ committed[s1] /\ committed[s2]
        /\ currentHeight[s1] = currentHeight[s2]
        /\ ~IsNil(proposedBlock[s1]) /\ ~IsNil(proposedBlock[s2])
        => proposedBlock[s1].content = proposedBlock[s2].content

\* Standard: A committed block was proposed by the legitimate proposer.
Validity ==
    \A s \in Server :
        (alive[s] /\ committed[s] /\ ~IsNil(proposedBlock[s])) =>
            LET h == currentHeight[s]
                r == currentRound[s]
            IN proposedBlock[s].proposer = Proposer(h, r)

\* Family 1: PreparedBlockIntegrity
\* If a proposal carries a prepared certificate, the block hash matches
\* after round/proposer substitution.
PreparedBlockIntegrity ==
    \A s \in Server :
        (alive[s] /\ ~IsNil(proposedBlock[s])) =>
            proposedBlock[s].hash = BlockHash(proposedBlock[s].content,
                                              proposedBlock[s].round,
                                              proposedBlock[s].proposer)

\* Family 3: RoundChangeSafety
\* A round change requires 2f+1 messages from distinct validators.
\* The actioned flag ensures one-shot behavior.
RoundChangeSafety ==
    \A s \in Server :
        \A r \in 0..10 :
            actioned[s][r] => Cardinality(roundChangeMessages[s][r]) >= Quorum(ValidatorsAt(currentHeight[s]))

\* Family 4: QuorumConsistency
\* All quorum calculations at a given height use the same validator set.
\* (Trivially true in our model since ValidatorsAt is a function of height.)

\* Family 5: CommitLatchConsistency
\* If committed and imported, blockchain height is updated.
CommitLatchConsistency ==
    \A s \in Server :
        (alive[s] /\ committed[s] /\ blockImported[s]) =>
            blockchainHeight[s] >= currentHeight[s]

\* Structural: committed latch is monotonic within a round
CommittedMonotonic ==
    \A s \in Server :
        (committed[s] /\ IsNil(proposedBlock[s])) => FALSE

\* Structural: phase consistency
PhaseConsistency ==
    \A s \in Server :
        (phase[s] = Committed) => committed[s]

\* MC-1: No active round when blockchain already has this height's block.
\* Tests whether BlockTimerExpiry's missing blockchain-head guard allows
\* consensus to start for an already-decided height.
\* Only meaningful when PeerSync is included in the Next relation.
NoConsensusAfterImport ==
    \A s \in Server :
        (alive[s] /\ ~IsNil(currentRound[s])) =>
            blockchainHeight[s] < currentHeight[s]

\* MC-5 (reclassified): Committed-but-not-imported node detector.
\* Originally hypothesized as liveness bug (node permanently stuck).
\* Investigation found implementation has NO ~committed guard on roundExpired(),
\* so the node CAN escape via round change (losing committed seals).
\* The spec's original ~committed guard was stricter than the implementation (Case A).
\* Kept as a detector for analysis — may or may not be violated after spec fix.
CommittedStuckDetector ==
    \A s \in Server :
        ~(alive[s] /\ committed[s] /\ ~blockImported[s])

=============================================================================
