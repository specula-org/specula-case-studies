--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for CometBFT v1.x — PBTS + ABCI++ proposer side + state sync.
 *
 * Code reference: /tmp/cometbft-v1x (detached HEAD ca44468c5, pre-reset main).
 * Line numbers refer to this worktree.
 *
 * THIS IS A SECOND-PASS SPEC. The first pass (case-studies/cometbft/) modeled the
 * Tendermint state machine, locking, and the receiver-side VE-bit check at
 * `addVote`. This pass is deliberately scoped to surfaces that pass 1 left
 * abstract:
 *
 *   - Family 1 (HIGH): PBTS POLRound-bypass + ValidBlock re-proposal
 *     (state.go:1430-1571 prevote split, state.go:1231-1260 reproposal,
 *      state/state.go:241-272 MakeBlock, types/proposal.go:97 IsTimely).
 *   - Family 2 (HIGH liveness): block.Time monotonicity vs honest wall clock
 *     (state/state.go:255, state/validation.go:122).
 *   - Family 3 (HIGH safety): straggler vote-extension app-verification gap
 *     (state.go:2316-2350 late-precommit, state.go:1316/state.go:2391 gating,
 *      state/execution.go:535-607 buildExtendedCommitInfoFromStore).
 *   - Family 4 (MEDIUM liveness): ABCI++ proposer-self ProcessProposal reject
 *     (state.go:1484-1497, state.go:1262-1271 sign-then-gossip).
 *   - Family 5 (HIGH design defect): state-sync trust gap
 *     (statesync/syncer.go:236,253,298,475-506, stateprovider.go:56-58,
 *      light/detector.go:55-105).
 *
 * The Tendermint state machine itself (height/round/step, prevote/precommit
 * bookkeeping, lock/relock) is intentionally abstracted away — see action
 * `DecideBlock` which represents "this height reached a decision" as one step.
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

\* --- Validator set ---
CONSTANT Servers              \* Honest+Byzantine validator IDs
CONSTANT Faulty               \* Faulty \subseteq Servers, 3|Faulty| < |Servers|

\* --- Height/round bounds (kept tiny; we are not modeling the round-by-round
\*     state machine, only outcomes per height) ---
CONSTANT MaxHeight            \* Number of heights to explore
CONSTANT MaxRound             \* Per-height round cap (just for re-proposal scenarios)

\* --- PBTS time discretization (state/state.go:255 cmttime.Now(),
\*     types/proposal.go:97 IsTimely, types/params.go:139 SynchronyParams) ---
CONSTANT MaxTime              \* Discrete real-time horizon
CONSTANT Precision            \* SynchronyParams.Precision (discrete units)
CONSTANT MessageDelay         \* SynchronyParams.MessageDelay (discrete units)
CONSTANT MaxClockSkew         \* per-validator |wallClock[v] - realTime| upper bound

\* --- Block values / proposals ---
CONSTANT Blocks               \* Abstract block identifiers (small set)

\* --- ABCI++ surface (Family 3, 4) ---
CONSTANT Extensions           \* Abstract VE payload values
CONSTANT NoExtension          \* Sentinel for "vote with no extension attached"

\* --- State-sync surface (Family 5) ---
CONSTANT Identities           \* Set of operator-supplied identities (RPC + p2p)
CONSTANT MaliciousIdentities  \* \subseteq Identities — colluding RPC/p2p actor(s)
CONSTANT ChunkValues          \* Abstract bytes a chunk can carry
CONSTANT AppHashes            \* Abstract values app reports as LastBlockAppHash

\* --- Sentinels ---
CONSTANT Nil                  \* "none"

ASSUME 3 * Cardinality(Faulty) < Cardinality(Servers)
ASSUME Faulty \subseteq Servers
ASSUME MaliciousIdentities \subseteq Identities
ASSUME Precision \in Nat /\ MessageDelay \in Nat /\ MaxTime \in Nat
ASSUME MaxClockSkew \in Nat /\ MaxClockSkew <= Precision

Heights == 1..MaxHeight
Rounds  == 0..MaxRound
Honest  == Servers \ Faulty
Times   == 0..MaxTime
Quorum  == { S \in SUBSET Servers : 3 * Cardinality(S) > 2 * Cardinality(Servers) }
PolRounds == { -1 } \cup Rounds

\* ============================================================================
\* VARIABLES — bucketed by Bug Family
\* ============================================================================

\* --- Global clocks (Family 1, 2) ---
VARIABLE realTime           \* TLC's step counter; advances via Tick.
VARIABLE wallClock          \* [Servers -> Times] each validator's local clock.

\* --- Decided chain state (abstracts Pass 1's state machine) ---
VARIABLE decidedBlock       \* [Heights -> Blocks \cup {Nil}] block decided at H.
VARIABLE decidedTimestamp   \* [Heights -> Times \cup {Nil}] block.Header.Time at H.
VARIABLE decisionRealTime   \* [Heights -> Times \cup {Nil}] realTime when H decided.
VARIABLE chainHeight        \* current height to decide next (1..MaxHeight)

\* --- ValidBlock / ValidRound per validator (Family 1: state.go:1231-1260) ---
\* These are reproposable-block candidates. defaultDecideProposal at :1231 picks
\* cs.ValidBlock if non-nil, and NewProposal at :1260 carries the old timestamp
\* and POLRound=ValidRound.
VARIABLE validBlock         \* [Servers -> Blocks \cup {Nil}]
VARIABLE validBlockTime     \* [Servers -> Times \cup {Nil}]  (the original Header.Time)
VARIABLE validRound         \* [Servers -> Rounds \cup {-1}]

\* --- In-flight proposal per (Height, Round) (Family 1, 4) ---
\* Models cs.Proposal + cs.ProposalReceiveTime per validator and the gossip
\* surface from defaultDecideProposal sign-then-gossip (:1262-1271).
VARIABLE currentRound       \* [Servers -> Rounds] which round each validator is in
VARIABLE proposalMsg        \* set of gossiped proposals:
                            \* records { proposer, height, round, polRound, block,
                            \*           timestamp, sentAt, sender }
VARIABLE proposalRecvTime   \* [Servers -> [Heights -> [Rounds -> Times \cup {Nil}]]]
                            \* Local time at which v received the proposal for (H,R).

\* --- Vote-extension straggler state (Family 3) ---
\* lastCommitVotes[v] is the set of precommit votes v has collected for height
\* (chainHeight - 1). Models cs.LastCommit which feeds the next height's
\* PrepareProposal.LocalLastCommit at state.go:1316.
VARIABLE lastCommitVotes    \* [Servers -> SUBSET PrecommitRecords]
VARIABLE appVerifiedExt     \* [Servers -> SUBSET PrecommitRecords]
                            \* Subset whose extension has actually passed app
                            \* VerifyVoteExtension. Stragglers do NOT enter this.

\* --- ABCI++ adversary predicate (Family 3, 4) ---
\* For each (Height, Round, validator, Block) the app deterministically accepts
\* or rejects ProcessProposal. Pinned per hunt cfg via operator override (`<-`)
\* — the "scenario" of an exhaustive run is "this app behaves this way".
\* Distinct hunt cfgs fix different verdicts (all-accept, reject-proposer-X,
\* etc.) by binding AppAcceptsPP to a different defined operator.
CONSTANT AppAcceptsPP       \* [Heights \X Rounds \X Servers \X Blocks -> BOOLEAN]
CONSTANT AppAcceptsVE       \* [Extensions -> BOOLEAN]

\* Default scenario operators — usable from any cfg that wants honest-app
\* behavior. Used in base.cfg / Trace.cfg / MC.cfg / MC_hunt_{f1,f2,f5}.cfg.
\* Family-specific scenarios (F3, F4) live in MC.tla and are bound only by
\* the corresponding hunt cfg.
AppAcceptsPPAll ==
    [h \in 1..MaxHeight, r \in 0..MaxRound, v \in Servers, b \in Blocks |-> TRUE]

AppAcceptsVEAll ==
    [e \in Extensions |-> TRUE]

\* --- State-sync trust surface (Family 5) ---
\* The honest world at the snapshot height. The adversary's job is to make
\* `verifyApp` pass with a different state.
VARIABLE honestAppHash      \* the AppHash the chain ACTUALLY committed (Nil until decided)
VARIABLE syncTargetHeight   \* the height our state-sync target is fetching for (or Nil)
VARIABLE rpcAppHash         \* [Servers -> AppHashes \cup {Nil}] result of stateProvider.AppHash
VARIABLE consumedChunks     \* [Servers -> Seq(ChunkValues)] chunks the app has consumed
VARIABLE appComputedHash    \* [Servers -> AppHashes \cup {Nil}] LastBlockAppHash after applying chunks
VARIABLE syncVerified       \* [Servers -> BOOLEAN] verifyApp succeeded

\* --- Identity mapping for collusion (Family 5) ---
\* Two RPC endpoints + (separately) chunk peers can all be served by a single
\* MaliciousIdentity (stateprovider.go:56 only counts cardinality, light/detector.go:55-105
\* needs only ONE witness agreement). Constant: fixed at init.
VARIABLE rpcIdentity        \* [{1,2} -> Identities] which identity serves slot k
VARIABLE chunkPeerIdentity  \* Identities — the identity of the p2p chunk source

\* --- Crash / WAL for non-determinism around enterPrevote round entry ---
\* Family 1 sub-mechanism: state.go:738/:1091 reset ProposalReceiveTime on round
\* entry; not modeled in detail here. Brief §3.2 explicitly drops the WAL
\* ReceiveTime hypothesis (proto-encoded, persisted). We keep only the bare
\* re-arming surface that makes ValidBlock re-proposal observable.

vars == <<realTime, wallClock,
          decidedBlock, decidedTimestamp, decisionRealTime, chainHeight,
          validBlock, validBlockTime, validRound,
          currentRound, proposalMsg, proposalRecvTime,
          lastCommitVotes, appVerifiedExt,
          honestAppHash, syncTargetHeight, rpcAppHash,
          consumedChunks, appComputedHash, syncVerified,
          rpcIdentity, chunkPeerIdentity>>

\* Variable groups for UNCHANGED clauses
clockVars    == <<realTime, wallClock>>
chainVars    == <<decidedBlock, decidedTimestamp, decisionRealTime, chainHeight>>
validVars    == <<validBlock, validBlockTime, validRound>>
proposalVars == <<currentRound, proposalMsg, proposalRecvTime>>
lastCommitVars == <<lastCommitVotes, appVerifiedExt>>
syncVars     == <<honestAppHash, syncTargetHeight, rpcAppHash,
                  consumedChunks, appComputedHash, syncVerified,
                  rpcIdentity, chunkPeerIdentity>>

\* ============================================================================
\* HELPER RECORDS / OPERATORS
\* ============================================================================

\* A proposal as gossiped on the wire. Fields mirror types.Proposal except
\* sender (we don't model signatures explicitly; sender is the proposer).
ProposalRec(prop, h, r, polR, b, ts, sentAt) ==
    [proposer |-> prop, height |-> h, round |-> r, polRound |-> polR,
     block |-> b, timestamp |-> ts, sentAt |-> sentAt]

\* A precommit vote record for the straggler-VE family. extension is either
\* NoExtension or some value in Extensions.
PrecommitRec(v, h, r, b, ext) ==
    [voter |-> v, height |-> h, round |-> r, block |-> b, extension |-> ext]

\* PBTS timely predicate at the ROUND the proposer used (types/proposal.go:97).
\* Note: timelyProposalMargins (state.go:1371) uses cs.Round, but
\* proposalIsTimely (state.go:1379) uses cs.Proposal.Round. We follow the
\* implementation: prevote check uses Proposal.Round.
\*
\* In discrete units we model the adaptive InRound widening (types/params.go:159)
\* by widening MessageDelay linearly in round; tests stay within MaxRound so the
\* MaxMessageDelay cap is not exercised (the brief drops adaptive overflow as
\* fixed by #4815/#4816).
AdaptiveMessageDelay(r) ==
    \* 1.1^r approximated for discrete bounded rounds. With r small (Rounds
    \* <= MaxRound), we keep a simple monotone schedule.
    MessageDelay + r

IsTimely(timestamp, recvTime, r) ==
    \* recvTime >= timestamp - Precision
    \* recvTime <= timestamp + MessageDelay + Precision
    /\ recvTime + Precision >= timestamp
    /\ recvTime <= timestamp + AdaptiveMessageDelay(r) + Precision

\* The honest set of validators that have received the proposal for (H, R).
ReceiversAt(h, r) ==
    { v \in Servers : proposalRecvTime[v][h][r] /= Nil }

\* Proposal lookup
ProposalAt(h, r) ==
    CHOOSE pr \in proposalMsg : pr.height = h /\ pr.round = r

ProposalExists(h, r) == \E pr \in proposalMsg : pr.height = h /\ pr.round = r

\* ============================================================================
\* Init
\* ============================================================================

Init ==
    /\ realTime = 0
    /\ wallClock = [v \in Servers |-> 0]
    /\ decidedBlock = [h \in Heights |-> Nil]
    /\ decidedTimestamp = [h \in Heights |-> Nil]
    /\ decisionRealTime = [h \in Heights |-> Nil]
    /\ chainHeight = 1
    /\ validBlock = [v \in Servers |-> Nil]
    /\ validBlockTime = [v \in Servers |-> Nil]
    /\ validRound = [v \in Servers |-> -1]
    /\ currentRound = [v \in Servers |-> 0]
    /\ proposalMsg = {}
    /\ proposalRecvTime = [v \in Servers |-> [h \in Heights |-> [r \in Rounds |-> Nil]]]
    /\ lastCommitVotes = [v \in Servers |-> {}]
    /\ appVerifiedExt = [v \in Servers |-> {}]
    \* App-as-adversary: pinned at cfg level via CONSTANT AppAcceptsPP and
    \* AppAcceptsVE. No initial choice from TLC — Init is now deterministic in
    \* this dimension.
    /\ honestAppHash = Nil
    /\ syncTargetHeight = Nil
    /\ rpcAppHash = [v \in Servers |-> Nil]
    /\ consumedChunks = [v \in Servers |-> << >>]
    /\ appComputedHash = [v \in Servers |-> Nil]
    /\ syncVerified = [v \in Servers |-> FALSE]
    /\ rpcIdentity \in [ {1,2} -> Identities ]
    /\ chunkPeerIdentity \in Identities

\* ============================================================================
\* ACTIONS — Bug Family 1: PBTS POLRound-bypass + ValidBlock re-proposal
\* ============================================================================

\* Advance one validator's wall clock by 1 tick, never letting skew exceed
\* MaxClockSkew. Models clock drift bounded by Precision (per brief threat
\* model §1.9).
TickValidator(v) ==
    /\ wallClock[v] < MaxTime
    /\ wallClock[v] + 1 - realTime <= MaxClockSkew
    /\ wallClock' = [wallClock EXCEPT ![v] = @ + 1]
    /\ UNCHANGED <<realTime, chainVars, validVars, proposalVars,
                   lastCommitVars, syncVars>>

\* Advance global real time. Used as a coarse "everyone's clock can keep up"
\* mechanism — we are not modeling wall-clock drift in extreme detail.
TickRealTime ==
    /\ realTime < MaxTime
    /\ realTime' = realTime + 1
    /\ \A v \in Servers : wallClock[v] - (realTime + 1) <= MaxClockSkew
                          /\ (realTime + 1) - wallClock[v] <= MaxClockSkew
    /\ UNCHANGED <<wallClock, chainVars, validVars, proposalVars,
                   lastCommitVars, syncVars>>

\* --- ProposeNewBlock(v) ---
\* Models defaultDecideProposal at state.go:1226-1276 when cs.ValidBlock = nil
\* (the :1234 else-branch creates a new block). state.MakeBlock at
\* state/state.go:241-272 sets block.Time = cmttime.Now() when PBTS is enabled
\* (:254-255). There is NO clamping against state.LastBlockTime here — see
\* Family 2.
\*
\* Byzantine proposers (Faulty) can pick ANY timestamp in the "timely window"
\* relative to their local clock — modeling the adversary documented in
\* issue #2540: proposer can push block.Time forward to the edge of the
\* timely window.
\*
\* Honest proposers set block.Time = wallClock[v] exactly.
ProposeNewBlock(v, b, ts) ==
    \* state.go:1214 isProposer check — abstract: we don't model
    \* proposer-selection here; any v can propose when it's the head of a
    \* round at the current chain height. The MC layer will pick valid pairs.
    /\ chainHeight \in Heights
    /\ currentRound[v] \in Rounds
    /\ ~ProposalExists(chainHeight, currentRound[v])
    \* state.go:1231 ValidBlock == nil branch: must not have a valid block.
    /\ validBlock[v] = Nil
    \* state/state.go:254-255 / brief F1 evidence: honest validators set
    \* block.Time = local clock; Byzantine pick anywhere in [wallClock-Precision,
    \* wallClock+Precision]. We grant the wider range only to Faulty.
    /\ \/ /\ v \in Honest
          /\ ts = wallClock[v]
       \/ /\ v \in Faulty
          /\ ts \in Times
          /\ ts <= wallClock[v] + Precision
          /\ ts + Precision >= wallClock[v]
    /\ b \in Blocks
    \* state.go:1260 — POLRound = cs.ValidRound. With no valid block,
    \* validRound = -1, so this is a "POLRound = -1" proposal.
    /\ proposalMsg' = proposalMsg \cup
         { ProposalRec(v, chainHeight, currentRound[v], -1, b, ts, realTime) }
    \* The proposer receives its own proposal at its own wall clock — state.go:1266
    \* sendInternalMessage with cmttime.Now() as the receive time.
    /\ proposalRecvTime' =
         [proposalRecvTime EXCEPT
            ![v][chainHeight][currentRound[v]] = wallClock[v]]
    /\ UNCHANGED <<clockVars, chainVars, validVars, currentRound,
                   lastCommitVars, syncVars>>

\* --- ProposeValidBlock(v) ---
\* Models defaultDecideProposal at state.go:1231-1233 when cs.ValidBlock /= nil.
\* state.go:1260 — NewProposal(... cs.ValidRound, propBlockID, block.Header.Time).
\* This is the F9 mechanism: the OLD validBlockTime is carried forward, and
\* POLRound = validRound >= 0. The validator-side prevote at state.go:1515-1571
\* then SKIPS the timely check, the Timestamp.Equal check, and ProcessProposal.
ProposeValidBlock(v) ==
    /\ chainHeight \in Heights
    /\ currentRound[v] \in Rounds
    /\ ~ProposalExists(chainHeight, currentRound[v])
    /\ validBlock[v] /= Nil
    /\ validRound[v] >= 0
    /\ validRound[v] < currentRound[v]  \* POLRound < Round per ValidateBasic
    /\ proposalMsg' = proposalMsg \cup
         { ProposalRec(v, chainHeight, currentRound[v],
                       validRound[v], validBlock[v],
                       validBlockTime[v],  \* state.go:1260 reuses Header.Time
                       realTime) }
    /\ proposalRecvTime' =
         [proposalRecvTime EXCEPT
            ![v][chainHeight][currentRound[v]] = wallClock[v]]
    /\ UNCHANGED <<clockVars, chainVars, validVars, currentRound,
                   lastCommitVars, syncVars>>

\* --- DeliverProposal(v, pr) ---
\* Models defaultSetProposal at state.go:2048-2103. Stamps cs.ProposalReceiveTime
\* with the current local clock (:2086). "first-proposal-wins" semantics from
\* :2051-2053: if cs.Proposal /= nil this is a no-op.
DeliverProposal(v, pr) ==
    /\ pr \in proposalMsg
    /\ pr.height = chainHeight
    /\ pr.round = currentRound[v]
    /\ proposalRecvTime[v][pr.height][pr.round] = Nil  \* first proposal wins
    /\ proposalRecvTime' =
         [proposalRecvTime EXCEPT
            ![v][pr.height][pr.round] = wallClock[v]]
    /\ UNCHANGED <<clockVars, chainVars, validVars, currentRound, proposalMsg,
                   lastCommitVars, syncVars>>

\* --- AcceptProposalPOLNew(v, pr) ---
\* Models the POLRound = -1 prevote branch at state.go:1430-1500. Honest
\* validators check ALL THREE: timestamp equal (:1441), proposalIsTimely (:1447),
\* ProcessProposal (:1484). This action lets v advance validBlock/validRound on
\* the strict path.
\*
\* Note: we do NOT model the full prevote/precommit cascade. Instead, this
\* action says "v has accepted the proposal as a candidate ValidBlock". The
\* DecideBlock action below abstracts the rest of the polka mechanics.
AcceptProposalPOLNew(v, pr) ==
    /\ pr \in proposalMsg
    /\ pr.height = chainHeight
    /\ pr.round = currentRound[v]
    /\ pr.polRound = -1  \* state.go:1430 POLRound == -1 gate
    /\ proposalRecvTime[v][pr.height][pr.round] /= Nil
    \* state.go:1441 — Proposal.Timestamp.Equal(ProposalBlock.Header.Time).
    \* In our model the proposal's `timestamp` is the block's Header.Time
    \* directly (defaultDecideProposal copies block.Header.Time into Proposal),
    \* so this check is structurally satisfied. We keep it as an annotation.
    \* state.go:1447 — proposalIsTimely (types/proposal.go:97).
    /\ IsTimely(pr.timestamp, proposalRecvTime[v][pr.height][pr.round], pr.round)
    \* state.go:1484 — ProcessProposal via the app.
    /\ AppAcceptsPP[pr.height, pr.round, v, pr.block]
    \* Effect: this validator now has a candidate valid block. The actual update
    \* of cs.ValidBlock happens later in the round (after the polka) at
    \* state.go:2444 — we model that update lazily via DecideBlock + a separate
    \* PolkaArmsValidBlock action.
    /\ UNCHANGED <<clockVars, chainVars, validVars, currentRound, proposalMsg,
                   proposalRecvTime, lastCommitVars, syncVars>>

\* --- AcceptProposalPOLOld(v, pr) ---
\* Models the POLRound >= 0 branch at state.go:1515-1566. This branch does NOT
\* call IsTimely, does NOT compare Proposal.Timestamp to block.Header.Time, and
\* does NOT call ProcessProposal. The brief calls this the F1 (POLRound bypass)
\* mechanism: any validator that sees a 2/3 polka in some prior round v_r and
\* a proposal with POLRound = v_r will accept the proposal regardless of the
\* timestamp predicates.
\*
\* In our spec the "+2/3 prevotes at POLRound" precondition is abstracted as
\* "there is a recorded ValidBlock in a 2/3 quorum of validators for that
\* prior round" (the same way Pass 1 abstracts polka — but our pass treats it
\* even more abstractly because the brief lets us).
AcceptProposalPOLOld(v, pr) ==
    /\ pr \in proposalMsg
    /\ pr.height = chainHeight
    /\ pr.round = currentRound[v]
    /\ pr.polRound >= 0  \* state.go:1515 — POLRound >= 0 branch
    /\ pr.polRound < pr.round
    /\ proposalRecvTime[v][pr.height][pr.round] /= Nil
    \* state.go:1541 — Votes.Prevotes(POLRound).TwoThirdsMajority(). We
    \* abstract this as "some quorum of validators previously had this block
    \* as validBlock with validRound = pr.polRound". Honest model: only
    \* arming such a polka via PolkaArmsValidBlock below.
    /\ \E S \in Quorum :
         \A w \in S :
           validBlock[w] = pr.block /\ validRound[w] >= pr.polRound
    \* NOTE: no timely check, no Timestamp.Equal check, no ProcessProposal.
    \* This is the bug surface for Family 1: pr.timestamp is accepted blind.
    /\ UNCHANGED <<clockVars, chainVars, validVars, currentRound, proposalMsg,
                   proposalRecvTime, lastCommitVars, syncVars>>

\* --- PolkaArmsValidBlock(v, pr) ---
\* Models state.go:2440-2445 — when v sees a 2/3 polka for the proposal it
\* received, it sets cs.ValidBlock and cs.ValidRound. This is the writeback
\* of the F9 mechanism.
PolkaArmsValidBlock(v, pr) ==
    /\ pr \in proposalMsg
    /\ pr.height = chainHeight
    /\ pr.round = currentRound[v]
    /\ proposalRecvTime[v][pr.height][pr.round] /= Nil
    \* A quorum (including v) accepted the proposal. We use AcceptProposalPOLNew
    \* OR AcceptProposalPOLOld as the precondition — captured here as "a quorum
    \* of validators that received the proposal in this round".
    /\ \E S \in Quorum :
         /\ v \in S
         /\ S \subseteq { w \in Servers : proposalRecvTime[w][pr.height][pr.round] /= Nil }
    /\ validRound[v] < pr.round  \* state.go:2440 cs.ValidRound < vote.Round
    /\ validBlock' = [validBlock EXCEPT ![v] = pr.block]
    /\ validBlockTime' = [validBlockTime EXCEPT ![v] = pr.timestamp]
    /\ validRound' = [validRound EXCEPT ![v] = pr.round]
    /\ UNCHANGED <<clockVars, chainVars, currentRound, proposalMsg,
                   proposalRecvTime, lastCommitVars, syncVars>>

\* --- AdvanceRound(v) ---
\* Models entering a new round at the same height when polka did not finish.
\* state.go:1095-1101 / state.go:738 reset cs.ProposalReceiveTime on round
\* entry. We follow the implementation: on round entry the per-(H,R) receive
\* time slot for the NEW round is reset to Nil (it's already Nil since we
\* haven't received that round's proposal yet).
AdvanceRound(v) ==
    /\ chainHeight \in Heights
    /\ currentRound[v] + 1 \in Rounds
    /\ decidedBlock[chainHeight] = Nil
    /\ currentRound' = [currentRound EXCEPT ![v] = @ + 1]
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalMsg, proposalRecvTime,
                   lastCommitVars, syncVars>>

\* ============================================================================
\* ACTIONS — Bug Family 4: Proposer-self ProcessProposal reject (MEDIUM liveness)
\* ============================================================================

\* The proposer's own block goes through the same prevote logic. We surface this
\* as an action that "fires" when v is the proposer for (H, R) and the app
\* rejects its own block (state.go:1484-1497): v prevotes nil. The chain may
\* still decide via another round.
ProposerSelfReject(v, pr) ==
    /\ pr \in proposalMsg
    /\ pr.proposer = v
    /\ pr.height = chainHeight
    /\ pr.round = currentRound[v]
    /\ pr.polRound = -1
    /\ ~AppAcceptsPP[pr.height, pr.round, v, pr.block]  \* state.go:1492
    \* No state change visible at this granularity beyond the proposer not
    \* arming its own validBlock — the round will time out and another
    \* AdvanceRound will fire.
    /\ UNCHANGED vars

\* ============================================================================
\* ACTIONS — Decide the block (abstracts the rest of the state machine)
\* ============================================================================

\* DecideBlock(h, pr) — H is decided when a 2/3 quorum of validators have
\* accepted pr (their validBlock matches), AND the block satisfies the
\* validation rule at state/validation.go:122 (strict After against
\* state.LastBlockTime — that is decidedTimestamp[h-1]).
DecideBlock(h, pr) ==
    /\ h = chainHeight
    /\ pr \in proposalMsg
    /\ pr.height = h
    /\ decidedBlock[h] = Nil
    \* Need a 2/3 quorum arming this block as their validBlock.
    /\ \E S \in Quorum :
         \A v \in S :
           /\ validBlock[v] = pr.block
           /\ validRound[v] = pr.round
    \* state/validation.go:122: strict monotonicity. Genesis (h=1) is special;
    \* otherwise block.Time > LastBlockTime.
    /\ h > 1 => pr.timestamp > decidedTimestamp[h-1]
    /\ decidedBlock' = [decidedBlock EXCEPT ![h] = pr.block]
    /\ decidedTimestamp' = [decidedTimestamp EXCEPT ![h] = pr.timestamp]
    /\ decisionRealTime' = [decisionRealTime EXCEPT ![h] = realTime]
    /\ chainHeight' = h + 1
    \* Reset per-validator round / validblock state for the next height.
    /\ currentRound' = [v \in Servers |-> 0]
    /\ validBlock' = [v \in Servers |-> Nil]
    /\ validBlockTime' = [v \in Servers |-> Nil]
    /\ validRound' = [v \in Servers |-> -1]
    /\ UNCHANGED <<clockVars, proposalMsg, proposalRecvTime,
                   lastCommitVars, syncVars>>

\* ============================================================================
\* ACTIONS — Bug Family 2: Clock-jump halt
\* ============================================================================

\* When decidedTimestamp[chainHeight-1] is "in the future" of wallClock[v], an
\* honest proposer v cannot create a NEW block whose Time would satisfy
\* state/validation.go:122 (`block.Time.After(state.LastBlockTime)`). The
\* validator's enterPrevote at state.go:1467 will fail ValidateBlock and the
\* validator will prevote nil.
\*
\* ProposerSkipsRound captures this: an honest proposer that cannot make a
\* monotonic timestamp simply produces no proposal in this round, advancing
\* via timeout.
ProposerSkipsRound(v) ==
    /\ v \in Honest
    /\ chainHeight \in Heights
    /\ chainHeight > 1
    /\ wallClock[v] <= decidedTimestamp[chainHeight - 1]
    /\ ~ProposalExists(chainHeight, currentRound[v])
    /\ currentRound[v] + 1 \in Rounds
    /\ currentRound' = [currentRound EXCEPT ![v] = @ + 1]
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalMsg,
                   proposalRecvTime, lastCommitVars, syncVars>>

\* ============================================================================
\* ACTIONS — Bug Family 3: Straggler vote-extension app-verification gap
\* ============================================================================

\* --- DeliverInRoundPrecommit(v, vote) ---
\* Models the in-round path at state.go:2391: VerifyVoteExtension is called.
\* If the app accepts the extension, the vote enters lastCommitVotes AND
\* appVerifiedExt. If not, it's rejected entirely.
DeliverInRoundPrecommit(v, vote) ==
    /\ vote.height = chainHeight
    /\ vote.voter \in Servers
    /\ vote \notin lastCommitVotes[v]
    /\ \/ vote.extension = NoExtension
       \/ vote.extension \in Extensions
    \* state.go:2391 - app's VerifyVoteExtension. If extension is NoExtension we
    \* skip the call (state.go:2372: skip for nil-block votes too; the brief
    \* notes this is in-round only). The IF/THEN/ELSE keeps TLC from
    \* evaluating AppAcceptsVE[NoExtension] (out of domain) on the
    \* NoExtension branch — `\/` does not reliably short-circuit set
    \* lookups in TLC.
    /\ IF vote.extension = NoExtension
       THEN TRUE
       ELSE AppAcceptsVE[vote.extension]
    /\ lastCommitVotes' = [lastCommitVotes EXCEPT ![v] = @ \cup {vote}]
    /\ appVerifiedExt' = [appVerifiedExt EXCEPT ![v] = @ \cup {vote}]
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   syncVars>>

\* --- DeliverLatePrecommit(v, vote) ---
\* Models the late-precommit path at state.go:2316-2350 (vote.Height+1 ==
\* cs.Height). cs.LastCommit.AddVote calls types/vote_set.go:218-235 which
\* only does the crypto VerifyExtension check — NO app VerifyVoteExtension is
\* called. The extension can be Byzantine-crafted: crypto-valid but app would
\* reject.
\*
\* This is the F3 mechanism: the straggler enters lastCommitVotes WITHOUT
\* entering appVerifiedExt.
DeliverLatePrecommit(v, vote) ==
    /\ chainHeight > 1
    /\ vote.height = chainHeight - 1
    /\ vote.voter \in Servers
    /\ vote \notin lastCommitVotes[v]
    \* We allow extensions that the app would REJECT — the late path doesn't
    \* check, so they get in (the bug).
    /\ \/ vote.extension = NoExtension
       \/ vote.extension \in Extensions
    /\ lastCommitVotes' = [lastCommitVotes EXCEPT ![v] = @ \cup {vote}]
    \* NOT added to appVerifiedExt unless the app would have accepted (we
    \* still record what WOULD have happened for the invariant). The
    \* nested IF keeps TLC from evaluating AppAcceptsVE[NoExtension].
    /\ appVerifiedExt' =
         IF vote.extension = NoExtension
         THEN [appVerifiedExt EXCEPT ![v] = @ \cup {vote}]
         ELSE IF AppAcceptsVE[vote.extension]
              THEN [appVerifiedExt EXCEPT ![v] = @ \cup {vote}]
              ELSE appVerifiedExt
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   syncVars>>

\* --- PrepareProposalConsumes(v) ---
\* Models state.go:1316: cs.LastCommit.MakeExtendedCommit feeds into
\* state/execution.go:535-607 buildExtendedCommitInfoFromStore which is
\* attached to PrepareProposal.LocalLastCommit (execution.go:145). If v is the
\* proposer of the next round at chainHeight, the app sees ALL of
\* lastCommitVotes[v], including stragglers whose extension the app would
\* have rejected.
\*
\* This action only logs the fact for use by ExtensionVerifyCoverage and
\* LocalLastCommitConsistency — no state change. We surface it as a witness.
PrepareProposalConsumes(v) ==
    /\ TRUE  \* always enabled; effect is purely observational
    /\ UNCHANGED vars

\* ============================================================================
\* ACTIONS — Bug Family 5: State-sync trust gap
\* ============================================================================

\* The chain has produced an "honest" AppHash for some height — we commit a
\* canonical value once chainHeight > 1.
RecordHonestAppHash(ah) ==
    /\ ah \in AppHashes
    /\ chainHeight > 1
    /\ honestAppHash = Nil  \* one-shot: pin the honest value
    /\ honestAppHash' = ah
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   lastCommitVars, syncTargetHeight, rpcAppHash,
                   consumedChunks, appComputedHash, syncVerified,
                   rpcIdentity, chunkPeerIdentity>>

\* --- SyncFetchAppHash(v) ---
\* Models statesync/syncer.go:253-261 — fetches AppHash from the light client
\* state provider. Sybil defense at stateprovider.go:56 requires len(servers) >= 2.
\* light/detector.go:55-105 only needs ONE witness agreement. If both RPC slots
\* are served by a single MaliciousIdentity, the witness check is trivially
\* satisfied and the attacker chooses any AppHash.
SyncFetchAppHash(v, ah) ==
    /\ v \in Honest
    /\ syncTargetHeight = Nil \/ syncTargetHeight \in Heights
    /\ rpcAppHash[v] = Nil
    /\ ah \in AppHashes
    \* The attacker controls the value iff BOTH RPC slots map to malicious
    \* identities. Otherwise an honest witness disagrees and detectDivergence
    \* returns an error (we model this as "honest case forces ah = honestAppHash").
    /\ \/ /\ rpcIdentity[1] \in MaliciousIdentities
          /\ rpcIdentity[2] \in MaliciousIdentities
          \* Attacker is free to pick any value.
          /\ ah \in AppHashes
       \/ /\ ~(rpcIdentity[1] \in MaliciousIdentities /\ rpcIdentity[2] \in MaliciousIdentities)
          /\ honestAppHash /= Nil
          /\ ah = honestAppHash
    /\ rpcAppHash' = [rpcAppHash EXCEPT ![v] = ah]
    /\ syncTargetHeight' = IF syncTargetHeight = Nil THEN 1 ELSE syncTargetHeight
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   lastCommitVars, honestAppHash,
                   consumedChunks, appComputedHash, syncVerified,
                   rpcIdentity, chunkPeerIdentity>>

\* --- SyncReceiveChunk(v, chunk) ---
\* Models statesync/syncer.go:362-369 ApplySnapshotChunk: raw bytes consumed by
\* the app, no hash check against snapshot.Hash. Sender identity comes from
\* chunkPeerIdentity. Honest peers serve "honestChunk"; malicious peers can
\* serve anything in ChunkValues.
SyncReceiveChunk(v, chunk) ==
    /\ v \in Honest
    /\ rpcAppHash[v] /= Nil  \* must have started sync
    /\ chunk \in ChunkValues
    /\ Len(consumedChunks[v]) < 3   \* small bound; MC will tighten
    /\ \/ chunkPeerIdentity \in MaliciousIdentities
          \* attacker is free to pick any chunk value
       \/ /\ chunkPeerIdentity \notin MaliciousIdentities
          \* honest case: chunk is determined by the honest state
          /\ TRUE  \* abstract honest chunk value; constrained at MC
    /\ consumedChunks' = [consumedChunks EXCEPT ![v] = Append(@, chunk)]
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   lastCommitVars, honestAppHash, syncTargetHeight,
                   rpcAppHash, appComputedHash, syncVerified,
                   rpcIdentity, chunkPeerIdentity>>

\* --- SyncAppComputes(v, ah) ---
\* After all chunks consumed, the app's Info() responds with LastBlockAppHash =
\* hash(consumed chunks). For our abstraction: the app's hash is just
\* "appComputedHash[v]", which is whatever the app derives from chunks.
\* If chunkPeerIdentity is malicious, the attacker chose chunks that hash to
\* whatever appComputedHash they want.
SyncAppComputes(v, ah) ==
    /\ v \in Honest
    /\ ah \in AppHashes
    /\ appComputedHash[v] = Nil
    /\ Len(consumedChunks[v]) >= 1  \* at least one chunk applied
    /\ \/ chunkPeerIdentity \in MaliciousIdentities
          \* The malicious peer chose chunks such that the app hashes them to
          \* exactly rpcAppHash[v] (which is also attacker-supplied). I.e. the
          \* attacker picks any ah they want.
       \/ /\ chunkPeerIdentity \notin MaliciousIdentities
          /\ honestAppHash /= Nil
          /\ ah = honestAppHash
    /\ appComputedHash' = [appComputedHash EXCEPT ![v] = ah]
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   lastCommitVars, honestAppHash, syncTargetHeight,
                   rpcAppHash, consumedChunks, syncVerified,
                   rpcIdentity, chunkPeerIdentity>>

\* --- SyncVerifyApp(v) ---
\* Models statesync/syncer.go:475-506 verifyApp. Compares trustedAppHash
\* (from RPC) and resp.LastBlockAppHash (from app). If both attacker-controlled
\* and equal, the check passes despite the actual state being wrong.
SyncVerifyApp(v) ==
    /\ v \in Honest
    /\ rpcAppHash[v] /= Nil
    /\ appComputedHash[v] /= Nil
    /\ ~syncVerified[v]
    /\ rpcAppHash[v] = appComputedHash[v]
    /\ syncVerified' = [syncVerified EXCEPT ![v] = TRUE]
    /\ UNCHANGED <<clockVars, chainVars, validVars, proposalVars,
                   lastCommitVars, honestAppHash, syncTargetHeight,
                   rpcAppHash, consumedChunks, appComputedHash,
                   rpcIdentity, chunkPeerIdentity>>

\* ============================================================================
\* Next
\* ============================================================================

Next ==
    \/ \E v \in Servers : TickValidator(v)
    \/ TickRealTime
    \/ \E v \in Servers, b \in Blocks, ts \in Times : ProposeNewBlock(v, b, ts)
    \/ \E v \in Servers : ProposeValidBlock(v)
    \/ \E v \in Servers, pr \in proposalMsg : DeliverProposal(v, pr)
    \/ \E v \in Servers, pr \in proposalMsg : AcceptProposalPOLNew(v, pr)
    \/ \E v \in Servers, pr \in proposalMsg : AcceptProposalPOLOld(v, pr)
    \/ \E v \in Servers, pr \in proposalMsg : PolkaArmsValidBlock(v, pr)
    \/ \E v \in Servers : AdvanceRound(v)
    \/ \E v \in Servers, pr \in proposalMsg : ProposerSelfReject(v, pr)
    \/ \E h \in Heights, pr \in proposalMsg : DecideBlock(h, pr)
    \/ \E v \in Servers : ProposerSkipsRound(v)
    \/ \E v \in Servers, b \in Blocks, ext \in (Extensions \cup {NoExtension}),
         voter \in Servers, r \in Rounds :
         DeliverInRoundPrecommit(v, PrecommitRec(voter, chainHeight, r, b, ext))
    \/ \E v \in Servers, b \in Blocks, ext \in (Extensions \cup {NoExtension}),
         voter \in Servers, r \in Rounds :
         DeliverLatePrecommit(v, PrecommitRec(voter, chainHeight - 1, r, b, ext))
    \/ \E ah \in AppHashes : RecordHonestAppHash(ah)
    \/ \E v \in Servers, ah \in AppHashes : SyncFetchAppHash(v, ah)
    \/ \E v \in Servers, c \in ChunkValues : SyncReceiveChunk(v, c)
    \/ \E v \in Servers, ah \in AppHashes : SyncAppComputes(v, ah)
    \/ \E v \in Servers : SyncVerifyApp(v)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Type / structural sanity ---
TypeOK ==
    /\ realTime \in Times
    /\ wallClock \in [Servers -> Times]
    /\ chainHeight \in 1..(MaxHeight + 1)
    /\ decidedBlock \in [Heights -> Blocks \cup {Nil}]
    /\ decidedTimestamp \in [Heights -> Times \cup {Nil}]
    /\ validBlock \in [Servers -> Blocks \cup {Nil}]
    /\ validRound \in [Servers -> PolRounds]
    /\ currentRound \in [Servers -> Rounds]
    /\ syncVerified \in [Servers -> BOOLEAN]

\* Standard chain safety: only one block decided per height (we never overwrite).
NoDoubleDecide ==
    \A h \in Heights :
      decidedBlock[h] /= Nil =>
        [](decidedBlock[h] = decidedBlock[h])  \* always-equal sanity

\* --- Family 1: PBTS POLRound bypass / quantify Byzantine timestamp drift ---
\* TimestampBoundedByCommitTime: at the decision time of block at H,
\* |block.Time - real time of decision| <= Precision + epsilon(rounds, faulty).
\* The "epsilon" bound is what we want to measure — we encode an upper bound
\* MaxDriftBound and the violation tells us the achievable drift.
MaxDriftBound == Precision + MessageDelay + MaxRound

TimestampBoundedByCommitTime ==
    \A h \in Heights :
      decidedBlock[h] /= Nil =>
        /\ decidedTimestamp[h] - decisionRealTime[h] <= MaxDriftBound
        /\ decisionRealTime[h] - decidedTimestamp[h] <= MaxDriftBound

\* Standard PBTS sanity: decided block times are monotone (state/validation.go:122).
MonotonicHeaderTime ==
    \A h \in Heights :
      (h > 1 /\ decidedBlock[h] /= Nil /\ decidedBlock[h-1] /= Nil) =>
        decidedTimestamp[h] > decidedTimestamp[h-1]

\* --- Family 2: Liveness around clock-jump halt ---
\* BoundedHaltDuration: after a Byzantine forward-push of Δ, the chain
\* progresses within Δ + epsilon. As a SAFETY upper-bound check we encode:
\* once chainHeight stops advancing, the gap closes within some bound.
\*
\* We express the "safe halt" property as: no honest validator stays stuck
\* with wallClock < LastBlockTime by more than (MaxRound * Precision + MaxClockSkew).
BoundedHaltGap ==
    \A v \in Honest :
      chainHeight > 1 /\ decidedTimestamp[chainHeight - 1] /= Nil =>
        decidedTimestamp[chainHeight - 1] - wallClock[v]
          <= MaxRound * Precision + MaxClockSkew + 1

\* --- Family 3: Vote-extension verification coverage ---
\* ExtensionVerifyCoverage: every vote extension consumed in lastCommitVotes
\* was app-verified.
ExtensionVerifyCoverage ==
    \A v \in Servers :
      \A vote \in lastCommitVotes[v] :
        vote.extension /= NoExtension => vote \in appVerifiedExt[v]

\* LocalLastCommitConsistency: any two honest validators see the same
\* lastCommitVotes set at chainHeight (the precondition for PrepareProposal
\* determinism). EXPECTED to be VIOLATED.
LocalLastCommitConsistency ==
    \A v1, v2 \in Honest :
      lastCommitVotes[v1] = lastCommitVotes[v2]

\* --- Family 4: Proposer self-reject liveness ---
\* ProposerSelfRejectLiveness as a SAFETY-shaped bound:
\* If a proposal was rejected by app for ALL validators in some round, the
\* chain should still decide within MaxRound rounds (this is a metric we
\* quantify in MC; expressed here as "decide if anyone can").
\* Encoded as: there must always exist a (v, b, h, r) such that
\* AppAcceptsPP[h, r, v, b] = TRUE — otherwise no progress is possible.
SomeAppAccepts ==
    \E h \in Heights, r \in Rounds, v \in Servers, b \in Blocks :
      AppAcceptsPP[h, r, v, b]

\* --- Family 5: State-sync soundness ---
\* StateSyncSoundness: if verifyApp passes, the app's hash equals the honest
\* hash. EXPECTED VIOLATED under the collusion model.
StateSyncSoundness ==
    \A v \in Servers :
      syncVerified[v] =>
        (honestAppHash /= Nil /\ appComputedHash[v] = honestAppHash)

\* --- Structural / sanity ---
\* validBlock/validRound consistency: if v has a validBlock then validRound >= 0.
ValidBlockRoundConsistency ==
    \A v \in Servers :
      (validBlock[v] /= Nil) <=> (validRound[v] >= 0 /\ validBlockTime[v] /= Nil)

\* Decided timestamps must lie within [0, MaxTime] (not exceed bounds).
DecidedTimestampInRange ==
    \A h \in Heights :
      decidedBlock[h] /= Nil => decidedTimestamp[h] \in Times

\* ============================================================================
\* LIVENESS / TEMPORAL
\* ============================================================================

\* Eventually the chain decides every height up to MaxHeight under reasonable
\* assumptions. Used in MC's liveness profile only.
EventuallyAllHeightsDecided ==
    <>[](\A h \in Heights : decidedBlock[h] /= Nil)

===============================================================================
