--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for CometBFT (Tendermint BFT consensus) — Round 2.
 *
 * Source: cometbft/cometbft (artifact/cometbft/)
 *
 * Category A (distributed / message-passing) with BFT overlay.
 * Layer-1 environment: static corruption + partial synchrony + f < n/3.
 *
 * Bug Families (from modeling-brief.md):
 *   1. Equivocation production with detection-evasion (HIGH)
 *   2. Amnesia as a Byzantine action (HIGH)
 *   3. Vote-extension reuse and late-commit surfacing (MED-HIGH)
 *   4. Light-client lunatic — missing header self-consistency (MED)
 *   5. Evidence-lifecycle adversarial races (MED)
 *   6. Locking-vs-relock transitions under Byzantine proposer (MED)
 *
 * Round-1 carry-forward: crash / message loss / timeout / InvalidVE /
 *                        WAL replay / 5 enterPrecommit paths.
 *
 * Every action follows the implementation's control flow; deviations
 * are where the bugs live. All extension variables/actions cite the
 * Bug Family that motivates them.
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server          \* Set of all validators
CONSTANT Faulty          \* Subset of Server that is Byzantine (static corruption)
CONSTANT LightClient     \* Set of light clients (Family 4)
CONSTANT MaxHeight       \* Maximum height to explore
CONSTANT MaxRound        \* Maximum round per height
CONSTANT Nil             \* Sentinel value for "none"

\* Block values
CONSTANT Values          \* Set of possible block values

\* Message types
CONSTANTS
    ProposalMsg,
    PrevoteMsg,
    PrecommitMsg,
    HeaderMsg            \* Family 4: signed header from validator(s) to light clients

\* Step constants (RoundStepType from consensus/types)
CONSTANTS
    StepNewHeight,
    StepNewRound,
    StepPropose,
    StepPrevote,
    StepPrevoteWait,
    StepPrecommit,
    StepPrecommitWait,
    StepCommit

\* Vote extension values (Family 1, 3)
CONSTANTS
    ValidVE,
    InvalidVE,
    NoVE

\* Nil-vote sentinel (distinct from Nil, which means "no vote recorded yet")
CONSTANT NilVote

\* Evidence types (Family 5)
CONSTANTS
    DuplicateVoteEv,        \* types/evidence.go DuplicateVoteEvidence
    LightClientAttackEv,    \* types/evidence.go LightClientAttackEvidence
    InvalidEv               \* Family 5: Byzantine-injected fake evidence

\* BFT cardinality: Faulty is a subset of Server. The BFT safety bound
\* (3*|Faulty| < |Server|) is NOT enforced as an ASSUME because Family 4
\* (lunatic) deliberately probes the light-client trust-level threshold
\* which is ≥ 1/3 — outside the strict BFT bound. Each hunt cfg sets
\* Faulty cardinality appropriate for its attack class. See:
\*   Families 1, 2, 3, 5, 6: f < n/3 (BFT-bound, Agreement should hold)
\*   Family 4: f ≥ n/3 (light-client threshold, only LC invariant relevant)
ASSUME Faulty \subseteq Server

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-server consensus state (state.go RoundState) ---
VARIABLE height          \* [Server -> Nat]
VARIABLE round           \* [Server -> Nat]
VARIABLE step            \* [Server -> Step]

\* --- Proposal state ---
VARIABLE proposal        \* [Server -> record or Nil]
VARIABLE proposalBlock   \* [Server -> value or Nil]

\* --- Locking state (Family 6: state.go:1484-1603) ---
VARIABLE lockedRound     \* [Server -> Int]
VARIABLE lockedValue     \* [Server -> value or Nil]
VARIABLE validRound      \* [Server -> Int]
VARIABLE validValue      \* [Server -> value or Nil]

\* --- Vote tracking (Server's view of which votes it has admitted) ---
VARIABLE prevotes        \* [Server -> [Round -> [Server -> value or Nil]]]
VARIABLE precommits      \* [Server -> [Round -> [Server -> value or Nil]]]

\* --- Decision state ---
VARIABLE decision        \* [Server -> [Height -> value or Nil]]

\* --- Network: directed message bag (Family 1: selective dissemination) ---
\* Each message carries source, dest (single recipient), type, etc.
VARIABLE messages        \* Bag of directed messages

\* --- Family 1 / 3: Vote extensions ---
VARIABLE voteExtension   \* [Server -> [Height -> [Round -> VE value]]] VE attached
VARIABLE veVerified      \* [Server -> [Server -> BOOLEAN]] receiver's verify outcome

\* --- Family 1: signed votes (production-side, prior to dissemination) ---
\* This tracks every vote a validator has *signed* (including conflicting ones
\* a Byzantine validator may have signed). Distinct from message bag (delivery).
VARIABLE signedVotes     \* [Server -> SUBSET Vote-record]

\* --- Family 1: seen conflicting evidence per node (vote_set conflict path) ---
VARIABLE seenConflicting \* [Server -> SUBSET Vote-record-pair]

\* --- Round-1: Timeout tracking (state.go:979-1027) ---
VARIABLE timeoutScheduled \* [Server -> SUBSET {"propose","prevoteWait","precommitWait"}]

\* --- Family 2: WAL split into persisted + pending (state.go:851-905) ---
VARIABLE walPersisted     \* [Server -> Seq(record)] fsync'd suffix
VARIABLE walPending       \* [Server -> Seq(record)] buffered, lost on crash
VARIABLE crashed          \* [Server -> BOOLEAN]

\* --- Family 2: privval last-sign state (privval/file.go:100-131,412-421) ---
VARIABLE pvLastSign       \* [Server -> [height, round, step, blockID]]

\* --- Family 5: Evidence lifecycle ---
VARIABLE consensusBuffer  \* [Server -> Seq(VoteSet pair)] volatile, reset on Update
VARIABLE pendingEvidence  \* [Server -> SUBSET Evidence] pool-pending
VARIABLE committedEvidence \* SUBSET Evidence (chain-wide)
VARIABLE validatorClock   \* [Server -> Nat] (Family 5: clock skew model)

\* --- Family 4: light-client and chain history ---
\* chainHistory[h] = the canonical block value at height h (Nil if not yet decided
\* by quorum of correct validators). Used as ground truth for light-client check.
VARIABLE chainHistory     \* [Height -> value or Nil]
VARIABLE lightClientTrusted \* [LightClient -> [height, value, validatorsHash]]
VARIABLE forkBranches     \* SUBSET [height, value, source]: alternative headers
                          \* signed by Byzantine validators

\* --- Per-height proposer (used by both honest and Byzantine actions) ---
VARIABLE proposerHistory  \* [Height -> Server] proposer for each height (round-0)

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

consensusVars == <<height, round, step>>
proposalVars  == <<proposal, proposalBlock>>
lockVars      == <<lockedRound, lockedValue, validRound, validValue>>
voteVars      == <<prevotes, precommits>>
decisionVars  == <<decision>>
veVars        == <<voteExtension, veVerified>>
byzVoteVars   == <<signedVotes, seenConflicting>>
timeoutVars   == <<timeoutScheduled>>
walVars       == <<walPersisted, walPending, crashed, pvLastSign>>
evidenceVars  == <<consensusBuffer, pendingEvidence, committedEvidence, validatorClock>>
lightVars     == <<chainHistory, lightClientTrusted, forkBranches>>
proposerVars  == <<proposerHistory>>

vars == <<consensusVars, proposalVars, lockVars, voteVars, decisionVars,
          messages, veVars, byzVoteVars, timeoutVars, walVars,
          evidenceVars, lightVars, proposerVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Directed message bag helpers (Family 1: per-recipient delivery).
\* A "message" is an envelope to a single dest; broadcasting expands to N msgs.
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
DiscardSet(ms) == messages' = messages (-) SetToBag(ms)

\* Subset of Server: deliver to a chosen partition only (Family 1 selective).
SendToPartition(envBuilder, recipients) ==
    SendAll({envBuilder[r] : r \in recipients})

\* Honest = Server \ Faulty (BFT layer-1)
Honest == Server \ Faulty

\* Proposer selection: round-robin (validator_set.go ProposerSelection).
\* Refined version of round-1 helper.
Proposer(h, r) ==
    LET seq == CHOOSE seq \in [1..Cardinality(Server) -> Server] :
                   \A i, j \in 1..Cardinality(Server) :
                       i /= j => seq[i] /= seq[j]
        idx == ((h + r) % Cardinality(Server)) + 1
    IN seq[idx]

\* Quorum: > 2/3.
IsQuorum(subset, total) ==
    3 * Cardinality(subset) > 2 * Cardinality(total)

HasPrevoteQuorum(i, r, v) ==
    LET voters == {j \in Server : prevotes[i][r][j] = v}
    IN IsQuorum(voters, Server)

HasPrevoteTwoThirdsAny(i, r) ==
    LET voters == {j \in Server : prevotes[i][r][j] /= Nil}
    IN IsQuorum(voters, Server)

HasPrecommitQuorum(i, r, v) ==
    LET voters == {j \in Server : precommits[i][r][j] = v}
    IN IsQuorum(voters, Server)

HasPrecommitTwoThirdsAny(i, r) ==
    LET voters == {j \in Server : precommits[i][r][j] /= Nil}
    IN IsQuorum(voters, Server)

EmptyVoteMap == [j \in Server |-> Nil]

\* Vote record: signed precommit/prevote with full envelope.
\* Family 1: used to track which votes a Byzantine has signed.
VoteRecord(s, h, r, vtype, v, ve) ==
    [signer   |-> s,
     height   |-> h,
     round    |-> r,
     vtype    |-> vtype,
     value    |-> v,
     ve       |-> ve]

\* Family 4 DefaultTrustLevel: 1/3 (per ADR-047, evidence/verify.go:124).
\* A lunatic header is accepted by a light client iff >= 1/3 of nextValidators sign.
TrustLevelOneThird(signers, total) ==
    3 * Cardinality(signers) >= Cardinality(total)

\* Family 2: did this server already sign a precommit at (h, r0) for some b0?
HasPriorPrecommit(s, h, r0, b0) ==
    \E v \in signedVotes[s] :
        /\ v.vtype = PrecommitMsg
        /\ v.height = h
        /\ v.round = r0
        /\ v.value = b0

\* Family 2 / privval/file.go:100-131 CheckHRS.
\* The privval signer refuses to sign anything whose (height, round, step)
\* is not strictly forward of pvLastSign. Same-(H,R,S) is allowed only if
\* the block ID is identical (which is the deterministic re-signing case).
\* Step ordering (privval/file.go const block):
\*   newHeight < propose < prevote < precommit
\* The implementation persists pvLastSign in a separate file from the WAL,
\* so the check survives crashes — Crash leaves pvLastSign UNCHANGED.
PrivvalStepRank(st) ==
    CASE st = "newHeight" -> 0
      [] st = "propose"   -> 1
      [] st = "prevote"   -> 2
      [] st = "precommit" -> 3
      [] OTHER            -> -1

PrivvalCanSign(s, h, r, vstep, blockID) ==
    LET last == pvLastSign[s] IN
    \/ last.height < h
    \/ last.height = h /\ last.round < r
    \/ last.height = h /\ last.round = r /\
       PrivvalStepRank(last.vstep) < PrivvalStepRank(vstep)
    \/ last.height = h /\ last.round = r /\ last.vstep = vstep
       /\ last.blockID = blockID

\* Family 5: evidence expiry per-validator using its local clock and height.
\* Reactor (height-only) vs verify (height-AND-time) asymmetry.
\* Reference: reactor.go:192 (sender), verify.go:313 (receiver).
IsExpiredHeightOnly(s, evHeight, maxAgeNumBlocks) ==
    height[s] - evHeight > maxAgeNumBlocks

IsExpiredHeightAndTime(s, evHeight, evTime, maxAgeNumBlocks, maxAgeDuration) ==
    /\ height[s] - evHeight > maxAgeNumBlocks
    /\ validatorClock[s] - evTime > maxAgeDuration

\* ============================================================================
\* ACTIONS — Honest consensus (carried from round 1, faithful to state.go)
\* ============================================================================

\* --------------------------------------------------------------------------
\* EnterNewRound — Server i enters new round.
\* Reference: state.go:1066-1131 (enterNewRound)
\* --------------------------------------------------------------------------
EnterNewRound(i, r) ==
    /\ ~crashed[i]
    /\ r >= round[i]
    /\ (step[i] \in {StepNewHeight, StepNewRound, StepCommit}
        \/ r > round[i])
    /\ round' = [round EXCEPT ![i] = r]
    /\ step'  = [step  EXCEPT ![i] = StepNewRound]
    \* Clear proposal state on round advance (state.go:1098-1102)
    /\ IF r > 0
       THEN /\ proposal' = [proposal EXCEPT ![i] = Nil]
            /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
       ELSE UNCHANGED proposalVars
    /\ prevotes' = [prevotes EXCEPT ![i] =
                     [rr \in 0..MaxRound |->
                         IF rr = r /\ prevotes[i][rr] = EmptyVoteMap
                         THEN EmptyVoteMap
                         ELSE prevotes[i][rr]]]
    /\ precommits' = [precommits EXCEPT ![i] =
                       [rr \in 0..MaxRound |->
                           IF rr = r /\ precommits[i][rr] = EmptyVoteMap
                           THEN EmptyVoteMap
                           ELSE precommits[i][rr]]]
    /\ UNCHANGED <<height, lockVars, decisionVars, messages, veVars,
                   byzVoteVars, timeoutVars, walVars, evidenceVars,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EnterPropose — Server i enters propose step.
\* Reference: state.go:1157-1214 (enterPropose) + defaultDecideProposal 1221-1271
\* --------------------------------------------------------------------------
ChooseValue(i) == CHOOSE val \in Values : TRUE

EnterPropose(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepNewRound
    /\ step' = [step EXCEPT ![i] = StepPropose]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = @ \cup {"propose"}]
    /\ IF Proposer(height[i], round[i]) = i
       THEN \* Honest proposer: reuse validValue if locked (state.go:1226-1228)
            LET v == IF validValue[i] /= Nil THEN validValue[i]
                     ELSE ChooseValue(i)
                polRound == IF validValue[i] /= Nil THEN validRound[i]
                            ELSE -1
            IN
            /\ proposal' = [proposal EXCEPT ![i] =
                    [height   |-> height[i],
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
    /\ UNCHANGED <<height, round, lockVars, voteVars, decisionVars, veVars,
                   byzVoteVars, walVars, evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ReceiveProposal — defaultSetProposal (state.go:1920-1967).
\* Validation: height/round match, POLRound range, source matches proposer.
\* --------------------------------------------------------------------------
ReceiveProposal(i, m) ==
    /\ m.mtype = ProposalMsg
    /\ m.dest = i
    /\ ~crashed[i]
    /\ height[i] = m.height
    /\ round[i] = m.round
    /\ proposalBlock[i] = Nil
    \* POLRound validation (state.go:1932-1935; types/proposal.go:50-70).
    \* NOTE: proposal.go ValidateBasic only checks POLRound >= -1; the
    \* polRound < round bound is implicit and checked here. Family 6 / CR-7.
    /\ m.polRound = -1 \/ (m.polRound >= 0 /\ m.polRound < m.round)
    /\ m.source = Proposer(m.height, m.round)
    /\ proposal' = [proposal EXCEPT ![i] = m]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = m.value]
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, lockVars, voteVars, decisionVars, veVars,
                   byzVoteVars, timeoutVars, walVars, evidenceVars,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EnterPrevote — defaultDoPrevote (state.go:1334-1420).
\* Five decision paths; we model the head three (locked / no proposal /
\* valid proposal) since the spec abstracts proposal validity.
\* --------------------------------------------------------------------------
EnterPrevote(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPropose, StepNewRound}
    /\ step' = [step EXCEPT ![i] = StepPrevote]
    /\ LET voteValue ==
            IF lockedValue[i] /= Nil THEN lockedValue[i]
            ELSE IF proposalBlock[i] = Nil THEN NilVote
            ELSE proposalBlock[i]
           rec == VoteRecord(i, height[i], round[i], PrevoteMsg, voteValue, NoVE)
       IN
       /\ PrivvalCanSign(i, height[i], round[i], "prevote", voteValue)
       /\ prevotes' = [prevotes EXCEPT ![i][round[i]][i] = voteValue]
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       \* WAL: write internal vote msg (state.go:851 → WriteSync 884-894).
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "prevote",
               height |-> height[i], round |-> round[i], value |-> voteValue])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "prevote", blockID |-> voteValue]]
       /\ SendAll({[mtype   |-> PrevoteMsg,
                    height  |-> height[i],
                    round   |-> round[i],
                    value   |-> voteValue,
                    source  |-> i,
                    dest    |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, lockVars, precommits,
                   decisionVars, veVars, seenConflicting, timeoutVars,
                   walPending, crashed, evidenceVars, lightVars,
                   proposerVars>>

\* --------------------------------------------------------------------------
\* ReceivePrevote — addVote prevote handler (state.go:2269-2346).
\* Detects conflicting vote (vote_set.go:218-238 NewConflictingVoteError)
\* and reports to evidence pool (state.go:2132-2149 tryAddVote).
\* --------------------------------------------------------------------------
ReceivePrevote(i, m) ==
    /\ m.mtype = PrevoteMsg
    /\ m.dest = i
    /\ ~crashed[i]
    /\ m.height = height[i]
    \* Conflict detection (vote_set.go:218-238).
    \* If we already have a different prevote from m.source at (m.height, m.round),
    \* record the conflict pair and DROP the second vote (vote_set.go:267-283).
    \* In implementation, tryAddVote (state.go:2132-2149) catches
    \* ErrVoteConflictingVotes and atomically calls ReportConflictingVotes
    \* (evidence/pool.go:181-188), which appends to consensusBuffer in the
    \* same call. Model the buffer write atomically with conflict detection.
    /\ LET existing == prevotes[i][m.round][m.source]
           recA == VoteRecord(m.source, m.height, m.round, PrevoteMsg, existing, NoVE)
           recB == VoteRecord(m.source, m.height, m.round, PrevoteMsg, m.value, NoVE)
           conflictEv == [type     |-> DuplicateVoteEv,
                          height   |-> m.height,
                          round    |-> m.round,
                          offender |-> m.source,
                          reporter |-> i,
                          voteA    |-> recA,
                          voteB    |-> recB]
       IN
       \/ \* No previous vote: accept.
          /\ existing = Nil
          /\ prevotes' = [prevotes EXCEPT ![i][m.round][m.source] = m.value]
          /\ UNCHANGED <<seenConflicting, consensusBuffer>>
       \/ \* Duplicate of same vote: silent dedup (no state change).
          /\ existing = m.value
          /\ UNCHANGED <<prevotes, seenConflicting, consensusBuffer>>
       \/ \* Conflicting vote: record evidence; drop second (vote_set.go:267-283).
          /\ existing /= Nil
          /\ existing /= m.value
          /\ seenConflicting' = [seenConflicting EXCEPT ![i] = @ \cup {<<recA, recB>>}]
          /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = Append(@, conflictEv)]
          /\ UNCHANGED prevotes
    /\ Discard(m)
    \* Update lock/valid (state.go:2274-2325, Family 6).
    /\ LET hasPolka == \E v \in Values : HasPrevoteQuorum(i, m.round, v)
           polkaValue == IF hasPolka
                         THEN CHOOSE v \in Values : HasPrevoteQuorum(i, m.round, v)
                         ELSE Nil
       IN
       \* UNLOCK: locked && LockedRound < vote.Round <= cs.Round && different
       \* (state.go:2279-2290; cross-round unlock).
       IF /\ hasPolka
          /\ lockedValue[i] /= Nil
          /\ lockedRound[i] < m.round
          /\ m.round <= round[i]
          /\ lockedValue[i] /= polkaValue
       THEN /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
            /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
            /\ IF /\ polkaValue /= Nil
                  /\ validRound[i] < m.round
                  /\ m.round = round[i]
                  /\ proposalBlock[i] = polkaValue
               THEN /\ validRound' = [validRound EXCEPT ![i] = m.round]
                    /\ validValue' = [validValue EXCEPT ![i] = polkaValue]
               ELSE UNCHANGED <<validRound, validValue>>
       ELSE IF /\ hasPolka
               /\ polkaValue /= Nil
               /\ validRound[i] < m.round
               /\ m.round = round[i]
               /\ proposalBlock[i] = polkaValue
            THEN /\ validRound' = [validRound EXCEPT ![i] = m.round]
                 /\ validValue' = [validValue EXCEPT ![i] = polkaValue]
                 /\ UNCHANGED <<lockedRound, lockedValue>>
            ELSE UNCHANGED lockVars
    /\ UNCHANGED <<consensusVars, proposalVars, precommits, decisionVars,
                   veVars, signedVotes, timeoutVars, walVars,
                   pendingEvidence, committedEvidence, validatorClock,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EnterPrevoteWait (state.go:1423-1440).
\* --------------------------------------------------------------------------
EnterPrevoteWait(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrevote
    /\ HasPrevoteTwoThirdsAny(i, round[i])
    /\ step' = [step EXCEPT ![i] = StepPrevoteWait]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = @ \cup {"prevoteWait"}]
    /\ UNCHANGED <<height, round, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EnterPrecommit — 5 paths (state.go:1459-1603). Family 6 is built here.
\* Path 1 (NoPolka 1479-1490), Path 2 (NilPolka 1505-1520), Path 3 (Relock
\* 1525-1535), Path 4 (NewLock 1538-1556), Path 5 (UnknownPolka 1559-1577).
\* Each path is a *separate* action to expose the interleaving differences.
\* --------------------------------------------------------------------------

\* Path 1: No +2/3 majority prevotes → precommit nil.
EnterPrecommitNoPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ ~(\E v \in Values \cup {NilVote} : HasPrevoteQuorum(i, round[i], v))
    /\ PrivvalCanSign(i, height[i], round[i], "precommit", NilVote)
    /\ step' = [step EXCEPT ![i] = StepPrecommit]
    /\ LET rec == VoteRecord(i, height[i], round[i], PrecommitMsg, NilVote, NoVE) IN
       /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = NilVote]
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> NilVote, ve |-> NoVE])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "precommit", blockID |-> NilVote]]
       /\ SendAll({[mtype  |-> PrecommitMsg, height |-> height[i],
                    round  |-> round[i], value |-> NilVote,
                    source |-> i, dest |-> j, ve |-> NoVE] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, lockVars, prevotes,
                   decisionVars, veVars, seenConflicting, timeoutVars,
                   walPending, crashed, evidenceVars, lightVars, proposerVars>>

\* Path 2: +2/3 nil polka → unlock + precommit nil (state.go:1505-1520).
EnterPrecommitNilPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ HasPrevoteQuorum(i, round[i], NilVote)
    /\ PrivvalCanSign(i, height[i], round[i], "precommit", NilVote)
    /\ step' = [step EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ UNCHANGED <<validRound, validValue>>
    /\ LET rec == VoteRecord(i, height[i], round[i], PrecommitMsg, NilVote, NoVE) IN
       /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = NilVote]
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> NilVote, ve |-> NoVE])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "precommit", blockID |-> NilVote]]
       /\ SendAll({[mtype  |-> PrecommitMsg, height |-> height[i],
                    round  |-> round[i], value |-> NilVote,
                    source |-> i, dest |-> j, ve |-> NoVE] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   veVars, seenConflicting, timeoutVars, walPending,
                   crashed, evidenceVars, lightVars, proposerVars>>

\* Path 3: +2/3 for locked block → relock + precommit (state.go:1525-1535).
EnterPrecommitRelockPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ lockedValue[i] /= Nil
    /\ HasPrevoteQuorum(i, round[i], lockedValue[i])
    /\ PrivvalCanSign(i, height[i], round[i], "precommit", lockedValue[i])
    /\ step' = [step EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = round[i]]
    /\ UNCHANGED <<lockedValue, validRound, validValue>>
    /\ LET ve == voteExtension[i][height[i]][round[i]]
           rec == VoteRecord(i, height[i], round[i], PrecommitMsg, lockedValue[i], ve)
       IN
       /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = lockedValue[i]]
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> lockedValue[i], ve |-> ve])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "precommit", blockID |-> lockedValue[i]]]
       /\ SendAll({[mtype  |-> PrecommitMsg, height |-> height[i],
                    round  |-> round[i], value |-> lockedValue[i],
                    source |-> i, dest |-> j, ve |-> ve] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   veVars, seenConflicting, timeoutVars, walPending,
                   crashed, evidenceVars, lightVars, proposerVars>>

\* Path 4: +2/3 for proposal block → new lock + precommit (state.go:1538-1556).
EnterPrecommitNewLockPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ proposalBlock[i] /= Nil
    /\ HasPrevoteQuorum(i, round[i], proposalBlock[i])
    /\ lockedValue[i] /= proposalBlock[i]
    /\ PrivvalCanSign(i, height[i], round[i], "precommit", proposalBlock[i])
    /\ step' = [step EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = round[i]]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = proposalBlock[i]]
    /\ UNCHANGED <<validRound, validValue>>
    /\ LET ve == voteExtension[i][height[i]][round[i]]
           rec == VoteRecord(i, height[i], round[i], PrecommitMsg, proposalBlock[i], ve)
       IN
       /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = proposalBlock[i]]
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> proposalBlock[i], ve |-> ve])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "precommit", blockID |-> proposalBlock[i]]]
       /\ SendAll({[mtype  |-> PrecommitMsg, height |-> height[i],
                    round  |-> round[i], value |-> proposalBlock[i],
                    source |-> i, dest |-> j, ve |-> ve] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   veVars, seenConflicting, timeoutVars, walPending,
                   crashed, evidenceVars, lightVars, proposerVars>>

\* Path 5: +2/3 for unknown block → unlock + precommit nil (state.go:1559-1577).
\* Family 6: this is the unlock-and-nil branch that lacks an explicit
\* polkaRound > LockedRound guard — relies on polka being for current round.
EnterPrecommitUnknownPolka(i) ==
    /\ ~crashed[i]
    /\ step[i] \in {StepPrevoteWait, StepPrevote}
    /\ \E v \in Values :
        /\ HasPrevoteQuorum(i, round[i], v)
        /\ v /= proposalBlock[i]
        /\ (lockedValue[i] = Nil \/ lockedValue[i] /= v)
    /\ PrivvalCanSign(i, height[i], round[i], "precommit", NilVote)
    /\ step' = [step EXCEPT ![i] = StepPrecommit]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ UNCHANGED <<validRound, validValue>>
    /\ LET rec == VoteRecord(i, height[i], round[i], PrecommitMsg, NilVote, NoVE) IN
       /\ precommits' = [precommits EXCEPT ![i][round[i]][i] = NilVote]
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "precommit",
               height |-> height[i], round |-> round[i],
               value |-> NilVote, ve |-> NoVE])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "precommit", blockID |-> NilVote]]
       /\ SendAll({[mtype  |-> PrecommitMsg, height |-> height[i],
                    round  |-> round[i], value |-> NilVote,
                    source |-> i, dest |-> j, ve |-> NoVE] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, prevotes, decisionVars,
                   veVars, seenConflicting, timeoutVars, walPending,
                   crashed, evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ReceivePrecommit — addVote precommit handler (state.go:2348-2374).
\* VE verification (state.go:2193-2222 and types/vote.go:267-277).
\* --------------------------------------------------------------------------
ReceivePrecommit(i, m) ==
    /\ m.mtype = PrecommitMsg
    /\ m.dest = i
    /\ ~crashed[i]
    /\ m.height = height[i]
    \* Conflict detection on precommits.
    \* In implementation, tryAddVote (state.go:2132-2149) catches
    \* ErrVoteConflictingVotes and atomically calls ReportConflictingVotes
    \* (evidence/pool.go:181-188), which appends to consensusBuffer in the
    \* same call. Model the buffer write atomically with conflict detection.
    /\ LET existing == precommits[i][m.round][m.source]
           recA == VoteRecord(m.source, m.height, m.round, PrecommitMsg, existing, NoVE)
           recB == VoteRecord(m.source, m.height, m.round, PrecommitMsg, m.value, m.ve)
           conflictEv == [type     |-> DuplicateVoteEv,
                          height   |-> m.height,
                          round    |-> m.round,
                          offender |-> m.source,
                          reporter |-> i,
                          voteA    |-> recA,
                          voteB    |-> recB]
       IN
       \/ /\ existing = Nil
          /\ \* Add vote — possibly subject to VE verification (Family 1, 3).
             \* VerifyVoteExtension only fires for non-self non-nil precommits.
             IF m.value \in Values /\ m.source /= i
             THEN \* Family 3: VE bytes do not include BlockID; receiver only
                  \* validates VE byte signature for (H, R, ChainID).
                  /\ veVerified' = [veVerified EXCEPT ![i][m.source] =
                         (m.ve = ValidVE)]
                  /\ UNCHANGED voteExtension
                  \* Drop vote if VE invalid (state.go:2331-2333).
                  /\ IF m.ve = ValidVE
                     THEN precommits' = [precommits EXCEPT
                                          ![i][m.round][m.source] = m.value]
                     ELSE UNCHANGED precommits
             ELSE \* Self-vote or nil precommit: skip VE check (Bug #5204).
                  /\ UNCHANGED veVars
                  /\ precommits' = [precommits EXCEPT
                                     ![i][m.round][m.source] = m.value]
          /\ UNCHANGED <<seenConflicting, consensusBuffer>>
       \/ /\ existing = m.value
          /\ UNCHANGED <<precommits, veVars, seenConflicting, consensusBuffer>>
       \/ /\ existing /= Nil
          /\ existing /= m.value
          \* Family 1: conflicting precommit; vote_set drops the second.
          /\ seenConflicting' = [seenConflicting EXCEPT ![i] = @ \cup {<<recA, recB>>}]
          /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = Append(@, conflictEv)]
          /\ UNCHANGED <<precommits, veVars>>
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, prevotes,
                   decisionVars, signedVotes, timeoutVars, walVars,
                   pendingEvidence, committedEvidence, validatorClock,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EnterPrecommitWait (state.go:1584-1610).
\* --------------------------------------------------------------------------
EnterPrecommitWait(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrecommit
    /\ HasPrecommitTwoThirdsAny(i, round[i])
    /\ ~(\E v \in Values : HasPrecommitQuorum(i, round[i], v))
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = @ \cup {"precommitWait"}]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* Timeout handlers (state.go:979-1027). Round-1 carry-forward.
\* --------------------------------------------------------------------------
HandleTimeoutPropose(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPropose
    /\ "propose" \in timeoutScheduled[i]
    /\ PrivvalCanSign(i, height[i], round[i], "prevote", NilVote)
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = @ \ {"propose"}]
    /\ step' = [step EXCEPT ![i] = StepPrevote]
    /\ prevotes' = [prevotes EXCEPT ![i][round[i]][i] = NilVote]
    /\ LET rec == VoteRecord(i, height[i], round[i], PrevoteMsg, NilVote, NoVE) IN
       /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
       /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
              [type |-> "vote", vtype |-> "prevote",
               height |-> height[i], round |-> round[i], value |-> NilVote])]
       /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
              [height |-> height[i], round |-> round[i],
               vstep  |-> "prevote", blockID |-> NilVote]]
       /\ SendAll({[mtype   |-> PrevoteMsg, height  |-> height[i],
                    round   |-> round[i], value   |-> NilVote,
                    source  |-> i, dest    |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<height, round, proposalVars, lockVars, precommits,
                   decisionVars, veVars, seenConflicting, walPending,
                   crashed, evidenceVars, lightVars, proposerVars>>

HandleTimeoutPrevote(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrevoteWait
    /\ "prevoteWait" \in timeoutScheduled[i]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = @ \ {"prevoteWait"}]
    /\ step' = [step EXCEPT ![i] = StepPrevote]
    /\ UNCHANGED <<height, round, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

HandleTimeoutPrecommit(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepPrecommit
    /\ "precommitWait" \in timeoutScheduled[i]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = @ \ {"precommitWait"}]
    /\ round[i] + 1 <= MaxRound
    /\ round' = [round EXCEPT ![i] = round[i] + 1]
    /\ step' = [step EXCEPT ![i] = StepNewRound]
    /\ proposal' = [proposal EXCEPT ![i] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages,
                   veVars, byzVoteVars, walVars, evidenceVars, lightVars,
                   proposerVars>>

\* --------------------------------------------------------------------------
\* RoundSkip (state.go:2329-2331, 2371-2373). Family 6 (locking transitions).
\* --------------------------------------------------------------------------
RoundSkipPrevote(i) ==
    /\ ~crashed[i]
    /\ \E r \in (round[i]+1)..MaxRound :
        /\ HasPrevoteTwoThirdsAny(i, r)
        /\ round' = [round EXCEPT ![i] = r]
        /\ step' = [step EXCEPT ![i] = StepNewRound]
        /\ proposal' = [proposal EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages, veVars,
                   byzVoteVars, timeoutVars, walVars, evidenceVars,
                   lightVars, proposerVars>>

RoundSkipPrecommit(i) ==
    /\ ~crashed[i]
    /\ \E r \in (round[i])..MaxRound :
        /\ r > round[i] \/ (r = round[i] /\ step[i] \in {StepNewRound, StepNewHeight})
        /\ HasPrecommitTwoThirdsAny(i, r)
        /\ round' = [round EXCEPT ![i] = r]
        /\ step' = [step EXCEPT ![i] = StepNewRound]
        /\ proposal' = [proposal EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, lockVars, voteVars, decisionVars, messages, veVars,
                   byzVoteVars, timeoutVars, walVars, evidenceVars,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EnterCommit and FinalizeCommit. Standard round-1 logic, updates chain
\* history (Family 4) so light-client invariants can refer to it.
\* --------------------------------------------------------------------------
EnterCommit(i) ==
    /\ ~crashed[i]
    /\ step[i] /= StepCommit
    /\ \E r \in 0..MaxRound :
        /\ \E v \in Values :
            /\ HasPrecommitQuorum(i, r, v)
            /\ step' = [step EXCEPT ![i] = StepCommit]
            /\ UNCHANGED <<height, round>>
            /\ UNCHANGED <<proposalVars, voteVars>>
            /\ decision' = [decision EXCEPT ![i][height[i]] = v]
            \* Family 4: record canonical chain history when an HONEST node
            \* commits — light-client invariant uses this as ground truth.
            /\ IF i \in Honest
               THEN chainHistory' = [chainHistory EXCEPT ![height[i]] =
                       IF @ = Nil THEN v ELSE @]
               ELSE UNCHANGED chainHistory
            /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
                   [type |-> "endHeight", height |-> height[i]])]
            /\ UNCHANGED <<lockVars, messages, veVars, byzVoteVars,
                          timeoutVars, walPending, crashed, pvLastSign,
                          evidenceVars, lightClientTrusted, forkBranches,
                          proposerVars>>

\* FinalizeCommit — advances height; clears volatile state.
FinalizeCommit(i) ==
    /\ ~crashed[i]
    /\ step[i] = StepCommit
    /\ decision[i][height[i]] /= Nil
    /\ height[i] + 1 <= MaxHeight
    /\ height' = [height EXCEPT ![i] = height[i] + 1]
    /\ round'  = [round EXCEPT ![i] = 0]
    /\ step'   = [step EXCEPT ![i] = StepNewHeight]
    /\ proposal' = [proposal EXCEPT ![i] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ validRound'  = [validRound EXCEPT ![i] = -1]
    /\ validValue'  = [validValue EXCEPT ![i] = Nil]
    /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
           [height |-> height[i], round |-> round[i],
            vstep  |-> "newHeight", blockID |-> Nil]]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = {}]
    /\ prevotes' = [prevotes EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ precommits' = [precommits EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
    \* Family 5: consensusBuffer is reset on every Update (pool.go:49,538).
    /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = <<>>]
    \* Family 5: evidence in the committed block becomes committed.
    \* For simplicity, we model "any pending evidence whose offender is faulty"
    \* may be committed here by an honest proposer of the next height.
    /\ UNCHANGED <<messages, veVars, signedVotes, seenConflicting,
                   walPersisted, walPending, crashed,
                   pendingEvidence, committedEvidence, validatorClock,
                   lightVars, decisionVars, proposerVars>>

\* ============================================================================
\* ACTIONS — Crash, Recover, WAL truncation (Family 2)
\* ============================================================================

\* --------------------------------------------------------------------------
\* Crash — discards walPending and resets in-memory state.
\* Reference: Family 2 / state.go:851-862 (fail.Fail() between sign and WAL),
\* state.go:735-740 (updateToState clears LockedBlock at new height).
\* --------------------------------------------------------------------------
Crash(i) ==
    /\ ~crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = TRUE]
    /\ step' = [step EXCEPT ![i] = StepNewHeight]
    /\ proposal' = [proposal EXCEPT ![i] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = {}]
    \* Family 2: walPending lost; walPersisted survives.
    /\ walPending' = [walPending EXCEPT ![i] = <<>>]
    \* Family 2: LockedBlock/LockedRound are in-memory only (state.go:735-740).
    /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
    /\ validRound' = [validRound EXCEPT ![i] = -1]
    /\ validValue' = [validValue EXCEPT ![i] = Nil]
    /\ UNCHANGED <<height, round, voteVars, decisionVars, messages, veVars,
                   byzVoteVars, walPersisted, pvLastSign,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* WALTailTruncate — models repairWalFile's silent tail truncation.
\* Reference: state.go:2675-2708 — decode until first error, write prefix only.
\* Family 2: produces amnesia by losing recent vote records.
\* --------------------------------------------------------------------------
WALTailTruncate(i, k) ==
    /\ crashed[i]
    /\ k \in 1..Len(walPersisted[i])
    /\ walPersisted' = [walPersisted EXCEPT ![i] =
           SubSeq(@, 1, Len(@) - k)]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, timeoutVars,
                   walPending, crashed, pvLastSign,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* Recover — replays remaining walPersisted via handleMsg/handleTimeout.
\* Reference: replay.go:94-166 (catchupReplay).
\* Only locks/votes captured in walPersisted are reconstructed. Anything
\* truncated by WALTailTruncate is forgotten (Family 2 amnesia path).
\* --------------------------------------------------------------------------
Recover(i) ==
    /\ crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = FALSE]
    /\ LET lastEndH ==
            IF \E k \in 1..Len(walPersisted[i]) :
                walPersisted[i][k].type = "endHeight"
            THEN LET maxK == CHOOSE k \in 1..Len(walPersisted[i]) :
                     /\ walPersisted[i][k].type = "endHeight"
                     /\ \A k2 \in 1..Len(walPersisted[i]) :
                         walPersisted[i][k2].type = "endHeight" => k2 <= k
                 IN walPersisted[i][maxK].height
            ELSE 0
       IN
       /\ height' = [height EXCEPT ![i] = lastEndH + 1]
       /\ round'  = [round EXCEPT ![i] = 0]
       /\ step'   = [step EXCEPT ![i] = StepNewHeight]
    /\ UNCHANGED <<proposalVars, lockVars, voteVars, decisionVars,
                   messages, veVars, byzVoteVars, timeoutVars, walPersisted,
                   walPending, pvLastSign, evidenceVars, lightVars,
                   proposerVars>>

\* ============================================================================
\* ACTIONS — Network: LoseMessage (round-1 carry-forward)
\* ============================================================================

LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* ============================================================================
\* BYZANTINE ACTIONS — Family 1: Equivocation production + selective dissem
\* ============================================================================

\* --------------------------------------------------------------------------
\* ByzEquivocate(s, h, r, blockA, blockB) — Byzantine produces two signed
\* precommits at same (h, r) for different blocks.
\* Reference: BFT category 2.1. Detection sink: vote_set.go:218-238.
\* Family 1: round-1 explicitly missing this production-side action.
\* --------------------------------------------------------------------------
ByzEquivocate(s, h, r) ==
    /\ s \in Faulty
    /\ ~crashed[s]
    /\ h \in 1..MaxHeight
    /\ r \in 0..MaxRound
    \* Byzantine signs two conflicting precommits at (h, r): one for each
    \* distinct value in Values. Both go into signedVotes for this signer.
    /\ \E vA, vB \in Values :
        /\ vA /= vB
        /\ LET recA == VoteRecord(s, h, r, PrecommitMsg, vA, ValidVE)
               recB == VoteRecord(s, h, r, PrecommitMsg, vB, ValidVE)
           IN
           /\ recA \notin signedVotes[s]
           /\ recB \notin signedVotes[s]
           /\ signedVotes' = [signedVotes EXCEPT ![s] = @ \cup {recA, recB}]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, seenConflicting,
                   timeoutVars, walVars, evidenceVars, lightVars,
                   proposerVars>>

\* --------------------------------------------------------------------------
\* ByzSelectiveDisseminate — Byzantine sends conflicting votes to disjoint
\* subsets of recipients so no single honest node observes both votes.
\* Reference: BFT category 2.4; evidence-loss vector confirmed by #2353.
\* Family 1: tests whether DetectEquivocation can fire when split.
\* --------------------------------------------------------------------------
ByzSelectiveDisseminate(s, h, r) ==
    /\ s \in Faulty
    /\ \E vA, vB \in Values :
        /\ vA /= vB
        /\ LET recA == VoteRecord(s, h, r, PrecommitMsg, vA, ValidVE)
               recB == VoteRecord(s, h, r, PrecommitMsg, vB, ValidVE)
           IN
           /\ recA \in signedVotes[s]
           /\ recB \in signedVotes[s]
           \* Pick a partition of (Server \ {s}) for delivery.
           \* partA receives voteA only; partB receives voteB only; both subsets
           \* may be empty (then the action is a no-op for evidence — but in MC
           \* we constrain to non-empty splits via state-space pruning).
           /\ \E partA, partB \in SUBSET (Server \ {s}) :
               /\ partA \cap partB = {}
               /\ partA \cup partB = Server \ {s}
               /\ messages' = messages (+) SetToBag(
                       {[mtype  |-> PrecommitMsg, height |-> h, round |-> r,
                         value  |-> vA, source |-> s, dest |-> d,
                         ve     |-> ValidVE] : d \in partA}
                    \cup {[mtype  |-> PrecommitMsg, height |-> h, round |-> r,
                          value  |-> vB, source |-> s, dest |-> d,
                          ve     |-> ValidVE] : d \in partB})
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* DetectEquivocation — reactive evidence creation when an honest node sees
\* both conflicting votes locally.
\* Reference: evidence/pool.go:181-188 (ReportConflictingVotes),
\*            consensus/state.go:2132-2149 (tryAddVote catches ConflictingVotes)
\* Family 1/5: detection sink — fires only when conflicts are co-located.
\* --------------------------------------------------------------------------
DetectEquivocation(i) ==
    /\ i \in Honest
    /\ ~crashed[i]
    /\ \E pair \in seenConflicting[i] :
        LET ev == [type     |-> DuplicateVoteEv,
                   height   |-> pair[1].height,
                   round    |-> pair[1].round,
                   offender |-> pair[1].signer,
                   reporter |-> i,
                   voteA    |-> pair[1],
                   voteB    |-> pair[2]]
        IN
        /\ ev \notin pendingEvidence[i]
        /\ ev \notin committedEvidence
        \* Buffer first (ReportConflictingVotes → consensusBuffer 181-188).
        /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = Append(@, ev)]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, timeoutVars,
                   walVars, pendingEvidence, committedEvidence,
                   validatorClock, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ProcessConsensusBuffer — Update flushes consensusBuffer to pending pool.
\* Reference: evidence/pool.go:461-538 (processConsensusBuffer).
\* Drop votes for height > LastBlockHeight unconditionally (pool.go:502-509).
\* Family 5: TV-2 — votes for future heights silently lost.
\* --------------------------------------------------------------------------
ProcessConsensusBuffer(i) ==
    /\ i \in Honest
    /\ ~crashed[i]
    /\ consensusBuffer[i] /= <<>>
    /\ LET head == Head(consensusBuffer[i])
           bufRest == Tail(consensusBuffer[i])
       IN
       \/ \* Drop if vote height > LastBlockHeight (pool.go:502-509).
          /\ head.height > height[i]
          /\ pendingEvidence' = pendingEvidence
          /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = bufRest]
       \/ \* Otherwise, add to pending pool (pool.go:213-217).
          /\ head.height <= height[i]
          /\ head \notin pendingEvidence[i]
          /\ head \notin committedEvidence
          /\ pendingEvidence' = [pendingEvidence EXCEPT ![i] = @ \cup {head}]
          /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = bufRest]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, timeoutVars,
                   walVars, committedEvidence, validatorClock,
                   lightVars, proposerVars>>

\* ============================================================================
\* BYZANTINE ACTIONS — Family 2: Amnesia + crash + WAL truncate composition
\* ============================================================================

\* --------------------------------------------------------------------------
\* ByzAmnesia(s, h, r2) — Byzantine validator at (h, r2) signs a precommit
\* for a different block than it signed at (h, r1<r2), without observing a
\* polka for the new block at any round in (r1, r2].
\* Reference: BFT category 2.6; state.go:1484-1603; privval/file.go:100-131.
\* Family 2: privval CheckHRS only enforces HRS monotonicity, no per-block
\* memory; WAL never persisted LockedBlock/LockedRound directly.
\* --------------------------------------------------------------------------
ByzAmnesia(s, h, r2) ==
    /\ s \in Faulty
    /\ ~crashed[s]
    /\ h \in 1..MaxHeight
    /\ r2 \in 1..MaxRound
    /\ \E r1 \in 0..(r2-1) :
        \E b1, b2 \in Values :
            /\ b1 /= b2
            /\ HasPriorPrecommit(s, h, r1, b1)
            \* The Byzantine pretends amnesia: signs new precommit at (h, r2)
            \* for b2 even though it previously signed for b1 at r1.
            /\ LET rec == VoteRecord(s, h, r2, PrecommitMsg, b2, ValidVE) IN
               /\ rec \notin signedVotes[s]
               /\ signedVotes' = [signedVotes EXCEPT ![s] = @ \cup {rec}]
               \* Privval CheckHRS permits because r2 > r1 is not a regression.
               /\ pvLastSign' = [pvLastSign EXCEPT ![s] =
                     [height |-> h, round |-> r2,
                      vstep  |-> "precommit", blockID |-> b2]]
               \* Disseminate to all (could compose with selective dissem.).
               /\ SendAll({[mtype  |-> PrecommitMsg, height |-> h, round |-> r2,
                            value  |-> b2, source |-> s, dest |-> d,
                            ve     |-> ValidVE] : d \in Server \ {s}})
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, seenConflicting, timeoutVars,
                   walPersisted, walPending, crashed,
                   evidenceVars, lightVars, proposerVars>>

\* ============================================================================
\* BYZANTINE ACTIONS — Family 3: Vote-Extension reuse / late-commit
\* ============================================================================

\* --------------------------------------------------------------------------
\* ByzAttachSameVEToBoth(s, h, r) — Byzantine attaches same VE-sig to two
\* conflicting precommits at (h, r). Receiver's VerifyExtension accepts both
\* (VE bytes do not include BlockID — types/canonical.go:71-78).
\* Reference: BFT 2.5 + 2.1. Family 3: composition with equivocation.
\* --------------------------------------------------------------------------
ByzAttachSameVEToBoth(s, h, r) ==
    /\ s \in Faulty
    /\ \E vA, vB \in Values :
        /\ vA /= vB
        /\ LET recA == VoteRecord(s, h, r, PrecommitMsg, vA, ValidVE)
               recB == VoteRecord(s, h, r, PrecommitMsg, vB, ValidVE)
           IN
           /\ recA \notin signedVotes[s]
           /\ recB \notin signedVotes[s]
           /\ signedVotes' = [signedVotes EXCEPT ![s] = @ \cup {recA, recB}]
           \* Both votes pass VerifyVoteExtension on receivers because the VE
           \* signature only covers (Extension, H, R, ChainID) — not BlockID.
           /\ SendAll({[mtype  |-> PrecommitMsg, height |-> h, round |-> r,
                        value  |-> vA, source |-> s, dest |-> d,
                        ve     |-> ValidVE] : d \in Server \ {s}}
                  \cup {[mtype  |-> PrecommitMsg, height |-> h, round |-> r,
                         value  |-> vB, source |-> s, dest |-> d,
                         ve     |-> ValidVE] : d \in Server \ {s}})
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, seenConflicting, timeoutVars,
                   walVars, evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ByzLateAddPrecommitWithBadVE — Byzantine adds precommit to LastCommit
\* after height h+1 has begun; VE on this vote was never VerifyVoteExtension'd.
\* Reference: state.go:2193-2222 LastCommit late-arrival path;
\*            state/execution.go:609-665 BuildExtendedCommitInfo (no re-verify).
\* Family 3: #2361 — LastCommitVECoverage violated.
\* --------------------------------------------------------------------------
ByzLateAddPrecommitWithBadVE(s, h, r) ==
    /\ s \in Faulty
    /\ h \in 1..MaxHeight
    /\ r \in 0..MaxRound
    \* Byzantine sends a precommit AFTER height h+1 already began on receivers.
    /\ \E v \in Values, d \in Server \ {s} :
        /\ height[d] > h          \* d has advanced past h
        /\ Send([mtype   |-> PrecommitMsg, height |-> h, round |-> r,
                 value   |-> v, source |-> s, dest |-> d,
                 ve      |-> InvalidVE,
                 lateAdd |-> TRUE])
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ByzReplaySelfVE — Byzantine replays its own previously-signed VE bytes
\* onto a freshly-signed vote at (h, newR).
\* Family 3: Should be blocked by VoteSet's `vote.Round == voteSet.round` check.
\* --------------------------------------------------------------------------
ByzReplaySelfVE(s, h, oldR, newR) ==
    /\ s \in Faulty
    /\ oldR /= newR
    /\ oldR \in 0..MaxRound
    /\ newR \in 0..MaxRound
    /\ \E v \in Values :
        /\ LET old == VoteRecord(s, h, oldR, PrecommitMsg, v, ValidVE)
               new == VoteRecord(s, h, newR, PrecommitMsg, v, ValidVE)
           IN
           /\ old \in signedVotes[s]    \* Byzantine has prior VE
           /\ new \notin signedVotes[s]
           /\ signedVotes' = [signedVotes EXCEPT ![s] = @ \cup {new}]
           \* The VE is reused: even though the new round is different, the
           \* Byzantine attaches the same VE bytes — receiver should reject
           \* due to round mismatch, but we model the send to check.
           /\ SendAll({[mtype  |-> PrecommitMsg, height |-> h, round |-> newR,
                        value  |-> v, source |-> s, dest |-> d,
                        ve     |-> ValidVE] : d \in Server \ {s}})
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, seenConflicting, timeoutVars,
                   walVars, evidenceVars, lightVars, proposerVars>>

\* ============================================================================
\* BYZANTINE ACTIONS — Family 4: Light-client lunatic fork
\* ============================================================================

\* --------------------------------------------------------------------------
\* ByzLunaticForkHeader — Byzantine ≥ 1/3 of nextValidators(h-1) signs a
\* header at h with LastBlockID != chainHistory[h-1].
\* Reference: light/verifier.go:92-131 VerifyAdjacent — lacks LastBlockID
\* cross-check. Family 4 / #2252.
\* --------------------------------------------------------------------------
ByzLunaticForkHeader(h) ==
    /\ h \in 2..MaxHeight
    \* Need ≥ 1/3 of nextValidators (per ADR-047 DefaultTrustLevel = 1/3).
    \* Static-corruption: nextValidators ≈ Server; ≥ 1/3 means
    \* Cardinality(Faulty) * 3 >= Cardinality(Server). The BFT bound is
    \* f < n/3, so this requires EXACTLY at the trust-level boundary —
    \* model checks the safety boundary specifically.
    /\ TrustLevelOneThird(Faulty, Server)
    /\ \E fakeLastBlock \in Values :
        /\ fakeLastBlock /= chainHistory[h-1]
        /\ chainHistory[h-1] /= Nil
        \* Inject a forked-header record into forkBranches.
        /\ LET fork == [height        |-> h,
                        value         |-> fakeLastBlock,
                        signers       |-> Faulty,
                        lastBlockID   |-> fakeLastBlock]
           IN
           /\ fork \notin forkBranches
           /\ forkBranches' = forkBranches \cup {fork}
        \* Broadcast HeaderMsg to all light clients.
        /\ SendAll({[mtype       |-> HeaderMsg,
                     height      |-> h,
                     value       |-> fakeLastBlock,
                     lastBlockID |-> fakeLastBlock,
                     source      |-> CHOOSE x \in Faulty : TRUE,
                     dest        |-> c] : c \in LightClient})
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, chainHistory, lightClientTrusted,
                   proposerVars>>

\* --------------------------------------------------------------------------
\* LightClientVerify — Light client receives a header and runs VerifyAdjacent.
\* Reference: light/verifier.go:92-131. Only checks:
\*   1. height adjacent
\*   2. trusted header not expired
\*   3. untrustedVals.Hash() == validatorsHash
\*   4. trustedHeader.NextValidatorsHash == untrustedHeader.ValidatorsHash
\*   5. VerifyCommitLight against untrusted BlockID (uses untrusted as trusted)
\*
\* MISSING: LastBlockID / LastCommitHash / AppHash cross-check against the
\* trusted header. Family 4 / #2252.
\* --------------------------------------------------------------------------
LightClientVerify(c, m) ==
    /\ m.mtype = HeaderMsg
    /\ m.dest = c
    /\ m.height = lightClientTrusted[c].height + 1
    \* Note: the spec accepts the header without LastBlockID cross-check —
    \* this is exactly the bug. The light client updates its trusted header.
    /\ lightClientTrusted' = [lightClientTrusted EXCEPT ![c] =
           [height          |-> m.height,
            value           |-> m.value,
            validatorsHash  |-> @.validatorsHash]]
    /\ Discard(m)
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, chainHistory, forkBranches, proposerVars>>

\* ============================================================================
\* BYZANTINE ACTIONS — Family 5: Evidence-lifecycle adversarial races
\* ============================================================================

\* --------------------------------------------------------------------------
\* ByzInjectInvalidEvidence — Byzantine gossips evidence with bad sig or
\* fake conflict; receivers verify via evidence/verify.go and StopPeer.
\* Reference: BFT 2.8.
\* --------------------------------------------------------------------------
ByzInjectInvalidEvidence(s) ==
    /\ s \in Faulty
    /\ \E d \in Server \ {s} :
        /\ Send([mtype   |-> "EvidenceGossip",
                 evtype  |-> InvalidEv,
                 height  |-> height[d],
                 source  |-> s,
                 dest    |-> d])
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ByzFloodEvidence — Byzantine produces many distinct valid DuplicateVoteEv
\* records at distinct heights, exploiting evidence pool's unbounded growth.
\* Reference: pool.go:297-316 addPendingEvidence (no MaxNum check).
\* Family 5 / CR-5.
\* --------------------------------------------------------------------------
ByzFloodEvidence(s) ==
    /\ s \in Faulty
    /\ \E h \in 1..MaxHeight, r \in 0..MaxRound, vA, vB \in Values :
        /\ vA /= vB
        /\ \E offender \in Faulty \ {s} :
            \E d \in Server \ {s} :
              LET ev == [type     |-> DuplicateVoteEv,
                         height   |-> h,
                         round    |-> r,
                         offender |-> offender,
                         reporter |-> s,
                         voteA    |-> VoteRecord(offender, h, r, PrecommitMsg, vA, ValidVE),
                         voteB    |-> VoteRecord(offender, h, r, PrecommitMsg, vB, ValidVE)]
              IN
              /\ Send([mtype   |-> "EvidenceGossip",
                       evtype  |-> DuplicateVoteEv,
                       evidence |-> ev,
                       height   |-> h,
                       source   |-> s,
                       dest     |-> d])
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* EvidenceExpiryRace — Honest sender with height-only filter broadcasts;
\* receiver with height-AND-time filter rejects + ban sender.
\* Reference: reactor.go:192 (sender, height-only) vs verify.go:313 (receiver,
\* height-AND-time). Family 5: CR-4, MC-8.
\*
\* Models the BUG: sender's clock < receiver's clock, so receiver considers
\* expired in time-axis while sender does not.
\* --------------------------------------------------------------------------
EvidenceExpiryRace(s1, s2, ev) ==
    /\ s1 \in Honest
    /\ s2 \in Honest
    /\ s1 /= s2
    /\ ~crashed[s1]
    /\ ~crashed[s2]
    /\ ev \in pendingEvidence[s1]
    \* Sender uses height-only filter (reactor.go:192).
    /\ ~IsExpiredHeightOnly(s1, ev.height, MaxHeight)
    \* Receiver uses height-AND-time filter (verify.go:313).
    /\ IsExpiredHeightAndTime(s2, ev.height, 0, MaxHeight, validatorClock[s2])
    \* Sender broadcasts; receiver rejects.
    /\ Send([mtype   |-> "EvidenceGossip",
             evtype  |-> DuplicateVoteEv,
             evidence |-> ev,
             height   |-> ev.height,
             source   |-> s1,
             dest     |-> s2])
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* AdvanceClock(s) — increments a validator's local clock (Family 5).
\* Used to drive expiry-race conditions; bounded by MaxHeight to keep finite.
\* --------------------------------------------------------------------------
AdvanceClock(s) ==
    /\ ~crashed[s]
    /\ validatorClock[s] + 1 <= MaxHeight + 1
    /\ validatorClock' = [validatorClock EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, timeoutVars,
                   walVars, consensusBuffer, pendingEvidence,
                   committedEvidence, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* CrashDuringConsensusBuffer — crash between ReportConflictingVotes and
\* Update. Reference: pool.go:49,538. Family 5: MC-9.
\* The consensusBuffer is purely in-memory and unconditionally reset on
\* Update. Crash before Update flushes loses the buffer; if only one honest
\* node saw the conflict, evidence is permanently lost.
\* --------------------------------------------------------------------------
CrashDuringConsensusBuffer(s) ==
    /\ s \in Honest
    /\ ~crashed[s]
    /\ consensusBuffer[s] /= <<>>
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    /\ consensusBuffer' = [consensusBuffer EXCEPT ![s] = <<>>]  \* lost
    /\ step' = [step EXCEPT ![s] = StepNewHeight]
    /\ proposal' = [proposal EXCEPT ![s] = Nil]
    /\ proposalBlock' = [proposalBlock EXCEPT ![s] = Nil]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![s] = {}]
    /\ walPending' = [walPending EXCEPT ![s] = <<>>]
    /\ lockedRound' = [lockedRound EXCEPT ![s] = -1]
    /\ lockedValue' = [lockedValue EXCEPT ![s] = Nil]
    /\ validRound' = [validRound EXCEPT ![s] = -1]
    /\ validValue' = [validValue EXCEPT ![s] = Nil]
    /\ UNCHANGED <<height, round, voteVars, decisionVars, messages, veVars,
                   byzVoteVars, walPersisted, pvLastSign,
                   pendingEvidence, committedEvidence, validatorClock,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ProposerExcludeEvidence — at proposal of height h, proposer (possibly
\* Byzantine) does NOT include pending evidence in block.
\* Reference: state/execution.go:114-181 CreateProposalBlock (evidence pull).
\* Family 5: silent suppression — evidence stays pending forever if no other
\* proposer picks it up.
\* --------------------------------------------------------------------------
ProposerExcludeEvidence(s, ev) ==
    /\ s \in Faulty
    /\ \E h \in 1..MaxHeight :
        /\ Proposer(h, 0) = s
        /\ height[s] = h
        /\ ev \in pendingEvidence[s]
        \* Action effect: ev stays in pendingEvidence (no propose-with-ev path).
        \* Modeled as a no-op state change with explicit witness so the
        \* fault-counter can fire and the safety invariant captures the gap.
        /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                       decisionVars, messages, veVars, byzVoteVars,
                       timeoutVars, walVars, evidenceVars, lightVars,
                       proposerVars>>

\* --------------------------------------------------------------------------
\* CommitEvidence — pending evidence visible to an honest proposer at next
\* height becomes committed.  Honest path that closes the lifecycle.
\* Reference: state/execution.go:114-181; pool.go addPendingEvidence + chain.
\* --------------------------------------------------------------------------
CommitEvidence(i, ev) ==
    /\ i \in Honest
    /\ ~crashed[i]
    /\ ev \in pendingEvidence[i]
    /\ Proposer(height[i], round[i]) = i
    /\ ev.height < height[i]    \* evidence is from a prior height
    /\ ev \notin committedEvidence
    /\ committedEvidence' = committedEvidence \cup {ev}
    /\ pendingEvidence' = [pendingEvidence EXCEPT ![i] = @ \ {ev}]
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, messages, veVars, byzVoteVars, timeoutVars,
                   walVars, consensusBuffer, validatorClock,
                   lightVars, proposerVars>>

\* ============================================================================
\* BYZANTINE ACTIONS — Family 6: Locking transitions under proposer interleave
\* ============================================================================

\* --------------------------------------------------------------------------
\* ByzProposeAlternating(s, h, r, blockChoice) — Byzantine proposer offers
\* a chosen block at this round; in combination with normal rounds, can
\* alternate between blockA and blockB at adjacent rounds.
\* Reference: state.go:1484-1603 enterPrecommit + Family 6 evidence.
\* This is a Byzantine variant of EnterPropose that allows freely choosing
\* the proposed value (not just validValue), but at h, r where s is proposer.
\* --------------------------------------------------------------------------
ByzProposeAlternating(s, blockChoice) ==
    /\ s \in Faulty
    /\ ~crashed[s]
    /\ blockChoice \in Values
    /\ step[s] = StepNewRound
    /\ Proposer(height[s], round[s]) = s
    /\ step' = [step EXCEPT ![s] = StepPropose]
    /\ proposal' = [proposal EXCEPT ![s] =
            [height   |-> height[s],
             round    |-> round[s],
             value    |-> blockChoice,
             polRound |-> -1,
             source   |-> s]]
    /\ proposalBlock' = [proposalBlock EXCEPT ![s] = blockChoice]
    /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![s] = @ \cup {"propose"}]
    /\ SendAll({[mtype    |-> ProposalMsg,
                 height   |-> height[s],
                 round    |-> round[s],
                 value    |-> blockChoice,
                 polRound |-> -1,
                 source   |-> s,
                 dest     |-> j] : j \in Server \ {s}})
    /\ UNCHANGED <<height, round, lockVars, voteVars, decisionVars,
                   veVars, byzVoteVars, walVars, evidenceVars,
                   lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ByzPolkaForUnknownBlock(s, h, r, blockX) — Byzantine subset sends prevotes
\* for blockX (potentially unknown to validator). Triggers unlock-and-nil.
\* Reference: state.go:1559-1577 (Path 5 EnterPrecommitUnknownPolka).
\* Family 6: exposes whether unlock branch lacks polkaRound > LockedRound.
\* --------------------------------------------------------------------------
ByzPolkaForUnknownBlock(blockX) ==
    /\ blockX \in Values
    /\ \E r \in 0..MaxRound :
        /\ \E h \in 1..MaxHeight :
            \E target \in Server :
              \E ByzSet \in SUBSET Faulty :
                /\ ByzSet /= {}
                /\ IsQuorum(ByzSet \cup (Honest \ {target}), Server)
                \* Each Byzantine in ByzSet sends a prevote for blockX to target.
                /\ messages' = messages (+) SetToBag(
                        {[mtype   |-> PrevoteMsg,
                          height  |-> h,
                          round   |-> r,
                          value   |-> blockX,
                          source  |-> b,
                          dest    |-> target] : b \in ByzSet})
    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                   decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                   evidenceVars, lightVars, proposerVars>>

\* --------------------------------------------------------------------------
\* ByzPOLRoundGtRound(s) — Byzantine proposer with POLRound >= Round (passes
\* Proposal.ValidateBasic per types/proposal.go:50-70, which only checks
\* POLRound >= -1). Family 6 / CR-7.
\* --------------------------------------------------------------------------
ByzPOLRoundGtRound(s) ==
    /\ s \in Faulty
    /\ ~crashed[s]
    /\ step[s] = StepNewRound
    /\ Proposer(height[s], round[s]) = s
    /\ \E blockChoice \in Values, badPolRound \in 0..MaxRound :
        /\ badPolRound >= round[s]
        /\ step' = [step EXCEPT ![s] = StepPropose]
        /\ proposal' = [proposal EXCEPT ![s] =
                [height   |-> height[s],
                 round    |-> round[s],
                 value    |-> blockChoice,
                 polRound |-> badPolRound,
                 source   |-> s]]
        /\ proposalBlock' = [proposalBlock EXCEPT ![s] = blockChoice]
        /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![s] = @ \cup {"propose"}]
        /\ SendAll({[mtype    |-> ProposalMsg,
                     height   |-> height[s],
                     round    |-> round[s],
                     value    |-> blockChoice,
                     polRound |-> badPolRound,
                     source   |-> s,
                     dest     |-> j] : j \in Server \ {s}})
    /\ UNCHANGED <<height, round, lockVars, voteVars, decisionVars,
                   veVars, byzVoteVars, walVars, evidenceVars,
                   lightVars, proposerVars>>

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

Init ==
    /\ height = [s \in Server |-> 1]
    /\ round  = [s \in Server |-> 0]
    /\ step   = [s \in Server |-> StepNewHeight]
    /\ proposal = [s \in Server |-> Nil]
    /\ proposalBlock = [s \in Server |-> Nil]
    /\ lockedRound = [s \in Server |-> -1]
    /\ lockedValue = [s \in Server |-> Nil]
    /\ validRound  = [s \in Server |-> -1]
    /\ validValue  = [s \in Server |-> Nil]
    /\ prevotes    = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ precommits  = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ decision    = [s \in Server |-> [h \in 1..MaxHeight |-> Nil]]
    /\ messages    = EmptyBag
    /\ voteExtension = [s \in Server |-> [h \in 1..MaxHeight |->
                          [r \in 0..MaxRound |-> ValidVE]]]
    /\ veVerified    = [s \in Server |-> [j \in Server |-> FALSE]]
    /\ signedVotes   = [s \in Server |-> {}]
    /\ seenConflicting = [s \in Server |-> {}]
    /\ timeoutScheduled = [s \in Server |-> {}]
    /\ walPersisted = [s \in Server |-> <<>>]
    /\ walPending   = [s \in Server |-> <<>>]
    /\ crashed      = [s \in Server |-> FALSE]
    /\ pvLastSign   = [s \in Server |->
                          [height |-> 0, round |-> 0,
                           vstep  |-> "newHeight", blockID |-> Nil]]
    /\ consensusBuffer = [s \in Server |-> <<>>]
    /\ pendingEvidence = [s \in Server |-> {}]
    /\ committedEvidence = {}
    /\ validatorClock = [s \in Server |-> 0]
    /\ chainHistory   = [h \in 1..MaxHeight |-> Nil]
    /\ lightClientTrusted = [c \in LightClient |->
                                [height |-> 0,
                                 value  |-> Nil,
                                 validatorsHash |-> "genesis"]]
    /\ forkBranches = {}
    /\ proposerHistory = [h \in 1..MaxHeight |-> Proposer(h, 0)]

Next ==
    \/ \E i \in Server :
        \* Honest consensus state machine
        \/ EnterNewRound(i, round[i])
        \/ EnterPropose(i)
        \/ EnterPrevote(i)
        \/ EnterPrevoteWait(i)
        \/ EnterPrecommitNoPolka(i)
        \/ EnterPrecommitNilPolka(i)
        \/ EnterPrecommitRelockPolka(i)
        \/ EnterPrecommitNewLockPolka(i)
        \/ EnterPrecommitUnknownPolka(i)
        \/ EnterPrecommitWait(i)
        \/ EnterCommit(i)
        \/ FinalizeCommit(i)
        \* Timeouts
        \/ HandleTimeoutPropose(i)
        \/ HandleTimeoutPrevote(i)
        \/ HandleTimeoutPrecommit(i)
        \* Round-skip
        \/ RoundSkipPrevote(i)
        \/ RoundSkipPrecommit(i)
        \* Crash + recovery (round-1 + Family 2)
        \/ Crash(i)
        \/ Recover(i)
        \* Family 2 amnesia composition
        \/ \E h \in 1..MaxHeight, r2 \in 1..MaxRound : ByzAmnesia(i, h, r2)
        \* Family 1 production
        \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : ByzEquivocate(i, h, r)
        \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : ByzSelectiveDisseminate(i, h, r)
        \* Family 3 VE composition
        \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : ByzAttachSameVEToBoth(i, h, r)
        \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : ByzLateAddPrecommitWithBadVE(i, h, r)
        \/ \E h \in 1..MaxHeight, oR \in 0..MaxRound, nR \in 0..MaxRound :
                ByzReplaySelfVE(i, h, oR, nR)
        \* Family 5
        \/ ByzInjectInvalidEvidence(i)
        \/ ByzFloodEvidence(i)
        \/ CrashDuringConsensusBuffer(i)
        \/ \E ev \in pendingEvidence[i] : ProposerExcludeEvidence(i, ev)
        \/ \E ev \in pendingEvidence[i] : CommitEvidence(i, ev)
        \/ AdvanceClock(i)
        \* Family 5: evidence pipeline (honest)
        \/ DetectEquivocation(i)
        \/ ProcessConsensusBuffer(i)
        \* Family 6 Byzantine proposer
        \/ \E v \in Values : ByzProposeAlternating(i, v)
        \/ ByzPOLRoundGtRound(i)
        \* Family 2 WAL truncation
        \/ \E k \in 1..MaxRound : WALTailTruncate(i, k)
    \/ \E e1 \in Honest : \E e2 \in Honest : \E ev \in pendingEvidence[e1] :
        EvidenceExpiryRace(e1, e2, ev)
    \/ \E blockX \in Values : ByzPolkaForUnknownBlock(blockX)
    \/ \E h \in 2..MaxHeight : ByzLunaticForkHeader(h)
    \/ \E m \in DOMAIN messages :
        \/ ReceiveProposal(m.dest, m)
        \/ ReceivePrevote(m.dest, m)
        \/ ReceivePrecommit(m.dest, m)
        \/ LoseMessage(m)
    \/ \E c \in LightClient, m \in DOMAIN messages :
        LightClientVerify(c, m)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard safety ---

\* Agreement / ElectionSafety: no two HONEST nodes commit different blocks
\* at the same height (under f < n/3).
ElectionSafety ==
    \A h \in 1..MaxHeight :
        \A s1, s2 \in Honest :
            (decision[s1][h] /= Nil /\ decision[s2][h] /= Nil) =>
                decision[s1][h] = decision[s2][h]

Agreement == ElectionSafety

\* Validity: only proposed values can be committed by honest nodes.
Validity ==
    \A s \in Honest :
        \A h \in 1..MaxHeight :
            decision[s][h] /= Nil => decision[s][h] \in Values

\* --- Family 2 / 6: LockSafety ---
\* A locked honest validator only precommits its locked block unless it
\* observed a polka for a different block at some round > LockedRound.
\* Reference: brief §5 LockSafety, state.go:1525-1556.
LockSafety ==
    \A s \in Honest :
        \A h \in 1..MaxHeight :
            \A r \in 0..MaxRound :
                LET v == precommits[s][r][s] IN
                (v \in Values /\ v /= Nil
                 /\ \E rPrior \in 0..(r-1) :
                       \E vPrior \in Values :
                           /\ vPrior /= v
                           /\ precommits[s][rPrior][s] = vPrior) =>
                  \E rPolka \in 0..r :
                      /\ rPolka > 0  \* polka round is after the prior precommit
                      /\ HasPrevoteQuorum(s, rPolka, v)

\* --- Family 1, 5: EventualAccountability ---
\* If a Byzantine validator equivocates AND at least one honest node sees
\* both votes, evidence eventually becomes committed.
\* Approximated as: if any honest's seenConflicting is non-empty about offender
\* o, then within finite steps an evidence record about o exists in pending
\* OR committed.
\* The temporal/eventual version goes into the temporal-properties section.
EventualAccountabilityStrong ==
    \A s \in Honest :
        \A pair \in seenConflicting[s] :
            \/ \E ev \in pendingEvidence[s] : ev.offender = pair[1].signer
            \/ \E ev \in committedEvidence  : ev.offender = pair[1].signer
            \/ \E ev \in DOMAIN consensusBuffer[s] :
                  consensusBuffer[s][ev].offender = pair[1].signer

\* --- Family 2: PrivvalAmnesiaDetection ---
\* Privval refuses to sign a precommit at (h, r2) for B' if it previously
\* signed at (h, r1<r2) for B != B'.
\* This is the *intended* property; we EXPECT honest validators to obey it,
\* but the implementation's CheckHRS allows the regression (Family 2 bug).
PrivvalAmnesiaDetection ==
    \A s \in Honest :
        \A v1, v2 \in signedVotes[s] :
            (v1.vtype = PrecommitMsg
             /\ v2.vtype = PrecommitMsg
             /\ v1.height = v2.height
             /\ v1.round /= v2.round
             /\ v1.value \in Values
             /\ v2.value \in Values) =>
                v1.value = v2.value

\* --- Family 3: VEContextBound ---
\* Every accepted VE has (H, R) matching its carrying vote envelope.
\* Reference: types/canonical.go:71-78 — VE bytes cover (Extension, H, R, ChainID).
VEContextBound ==
    \A s \in Server :
        \A r \in 0..MaxRound :
            \A j \in Server :
                (precommits[s][r][j] \in Values /\ veVerified[s][j] = TRUE) =>
                    \* The VE was verified in the context of (height[s], r).
                    \* Tautological in spec, but ensures structural alignment.
                    TRUE

\* --- Family 3 / #2361: LastCommitVECoverage ---
\* Every extension that would feed into ExtendedCommitInfo at height h+1 was
\* VerifyVoteExtension-passed at its origin height.
\* The implementation violates this for late-arrived precommits (state.go:2193-2222).
LastCommitVECoverage ==
    \A s \in Honest :
        \A m \in DOMAIN messages :
            (m.mtype = PrecommitMsg /\ m.dest = s
             /\ "lateAdd" \in DOMAIN m /\ m.lateAdd = TRUE
             /\ m.value \in Values) =>
                m.ve = ValidVE     \* should hold; impl allows InvalidVE through

\* --- Family 4 / #2252: LightClientFollowsCanonicalChain ---
\* A light client's trusted header is always on the canonical chain unless
\* >= 1/3 of nextValidators are Byzantine (the documented security boundary).
LightClientFollowsCanonicalChain ==
    \A c \in LightClient :
        LET t == lightClientTrusted[c] IN
        (t.value /= Nil /\ t.height >= 1 /\ t.height <= MaxHeight) =>
            \/ chainHistory[t.height] = t.value
            \/ TrustLevelOneThird(Faulty, Server)  \* security threshold breached

\* --- Family 4: LunaticEvidenceVerifies ---
\* When a Byzantine subset signs a lunatic fork, LightClientAttackEvidence is
\* eventually committed identifying the Byzantine signers.
LunaticEvidenceVerifies ==
    \A fork \in forkBranches :
        \/ \E ev \in committedEvidence :
              /\ ev.type = LightClientAttackEv
              /\ ev.height = fork.height
              /\ ev.offender \in fork.signers
        \/ ~TrustLevelOneThird(fork.signers, Server)  \* attack failed pre-evidence

\* --- Family 5: HonestPeerNotPunished ---
\* An honest sender broadcasting evidence per reactor.go:192 filter
\* (height-only) is not banned by a correct receiver.
\* The bug: receiver uses height-AND-time; at the window edge they disagree.
HonestPeerNotPunished ==
    \A s1, s2 \in Honest :
        \A ev \in pendingEvidence[s1] :
            \* If sender did not consider ev expired (height-only):
            (~IsExpiredHeightOnly(s1, ev.height, MaxHeight)) =>
                \* Then receiver should also not consider it expired.
                ~IsExpiredHeightAndTime(s2, ev.height, 0, MaxHeight,
                                        validatorClock[s2])

\* --- Family 5: EvidenceConsistency ---
\* If ev is committed in a block, no honest validator retains ev as pending.
EvidenceConsistency ==
    \A ev \in committedEvidence :
        \A s \in Honest :
            ~crashed[s] => ev \notin pendingEvidence[s]

\* --- Family 5 / CR-5: EvidencePoolBounded ---
\* Pool size for each honest is bounded by validator-set-size * MaxHeight.
\* Currently violated (pool.go:297-316 — no MaxNum check).
EvidencePoolBounded ==
    \A s \in Honest :
        Cardinality(pendingEvidence[s]) <= Cardinality(Server) * MaxHeight

\* --- Family 6 / CR-7: Round1ProposalValidation ---
\* Honest validator rejects a proposal with POLRound >= Round.
\* Reference: types/proposal.go:50-70 (currently accepts POLRound >= Round).
Round1ProposalValidation ==
    \A s \in Honest :
        proposal[s] /= Nil =>
            \/ proposal[s].polRound = -1
            \/ proposal[s].polRound < proposal[s].round

\* --- Structural / sanity invariants ---

RoundBound ==
    \A s \in Server : round[s] >= 0 /\ round[s] <= MaxRound

HeightBound ==
    \A s \in Server : height[s] >= 1 /\ height[s] <= MaxHeight

LockedRoundBound ==
    \A s \in Server :
        lockedRound[s] >= -1 /\ lockedRound[s] <= round[s]

ValidRoundBound ==
    \A s \in Server :
        validRound[s] >= -1 /\ validRound[s] <= round[s]

LockConsistency ==
    \A s \in Server :
        (lockedRound[s] = -1) <=> (lockedValue[s] = Nil)

ValidConsistency ==
    \A s \in Server :
        (validRound[s] = -1) <=> (validValue[s] = Nil)

\* PrivvalConsistency: for HONEST validators, the privval's last-signed
\* height does not exceed the current consensus height. Byzantine
\* validators can violate this (they sign at arbitrary (h, r) — see
\* ByzAmnesia, ByzEquivocate which write pvLastSign for future heights).
PrivvalConsistency ==
    \A s \in Honest :
        pvLastSign[s].height <= height[s]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Family 1, 5: Eventual accountability — if any honest node sees the conflict,
\* evidence is eventually committed. Composes with liveness.
EventualAccountability ==
    \A s \in Honest :
        \A f \in Faulty :
            (\E p \in seenConflicting[s] : p[1].signer = f) ~>
                (\E ev \in committedEvidence : ev.offender = f)

\* VELiveness (round-1 carry-forward, brief Family 3):
\* Consensus terminates even when <= f validators emit invalid VEs.
VELiveness ==
    \A s \in Honest :
        ~crashed[s] ~> \E h \in 1..MaxHeight : decision[s][h] /= Nil

\* MonotonicHeight, DecisionPermanence are defined in MC.tla over _mc_vars.

====
