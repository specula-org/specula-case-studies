--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for Algorand BA* consensus.
 *
 * Derived from: algorand/go-algorand v4.7.0-stable, agreement/ package
 * System category: Category A (Distributed/Message-Passing) + BFT overlay
 *
 * Bug Families (from modeling-brief.md §2):
 *   F1: Catchup vs Live Agreement Race        (HIGH)
 *   F2: Period 0->P carryover + reproposal guard asymmetry (HIGH)
 *   F3: Dynamic Filter Timeout cross-round divergence (MEDIUM)
 *   F4: Freshest bundle / fresherThan partial order edge cases (MEDIUM)
 *   F5: VRF seed lookback forks (LOW safety / MEDIUM liveness)
 *   F6: Crash recovery state coverage (LOW)
 *
 * Modeling principles:
 *   - Abstract VRF as a committee oracle (committee[R,P,S] subset of Server)
 *   - Stake-weighted threshold simplified to majority of committee
 *   - Honest validators follow protocol; Byzantine may equivocate
 *   - Split Sign/Broadcast at the persist boundary to expose Family 1
 *   - Per-server caches faithfully reproduce nextThresholdCache / freshest /
 *     staging so Family 2 and Family 4 are reachable
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server          \* Set of validator IDs
CONSTANT ByzServer       \* Subset of Server that may equivocate
CONSTANT MaxRound        \* Maximum round to explore
CONSTANT MaxPeriod       \* Maximum period per round
CONSTANT MaxStep         \* Maximum next-vote step index (>= partitionStep+1)
CONSTANT Values          \* Set of legitimate block values (proposals)
CONSTANT Bottom          \* "bottom" / no-value sentinel
CONSTANT Nil             \* Generic absence sentinel

\* Step constants — mirror agreement/types.go:90-101
CONSTANTS
    StepPropose,         \* propose = 0
    StepSoft,            \* soft = 1
    StepCert,            \* cert = 2
    StepNext,            \* next = 3 (first next-vote step)
    StepLate,            \* late = 253 (fast-recovery)
    StepRedo,            \* redo = 254 (fast-recovery)
    StepDown             \* down = 255 (fast-recovery)

\* partitionStep = next + 3 (agreement/types.go:54)
\* We pass it as a constant since steps are abstracted to symbolic names.
CONSTANT PartitionStepNum  \* integer >= StepNext+3

\* Threshold event types — mirror agreement/events.go threshold types
CONSTANTS
    SoftThresholdT,      \* softThreshold
    CertThresholdT,      \* certThreshold
    NextThresholdT,      \* nextThreshold
    NoneThresholdT       \* none / unset

\* Message types
CONSTANTS
    ProposalMsg,         \* compoundMessage with payload + proposal-vote
    VoteMsg,             \* attest vote (soft/cert/next/late/redo/down)
    BundleMsg            \* threshold bundle (rebroadcast by partitionPolicy)

\* Vote step variants
\* OriginalPeriod attaches to a vote's proposal value (agreement/proposal.go).
\* Used by issueSoftVote reproposer guard.

\* Filter-timeout buckets (Family 3) — abstract, not numeric.
CONSTANTS
    FT_Short,            \* dynamic short timeout (<= 2500ms in code)
    FT_Default           \* default filter timeout

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-server player state (agreement/player.go:28-70) ---
VARIABLE round              \* [Server -> Nat]  player.Round
VARIABLE period             \* [Server -> Nat]  player.Period
VARIABLE step               \* [Server -> Step] player.Step
VARIABLE lastConcluding     \* [Server -> Step] player.LastConcluding
VARIABLE napping            \* [Server -> BOOLEAN] player.Napping
VARIABLE fastRecovery       \* [Server -> Nat] player.FastRecoveryDeadline counter (0=first fire)

playerVars == <<round, period, step, lastConcluding, napping, fastRecovery>>

\* --- Vote tracking (per server) ---
\* votesSeen[i][r][p][s] = SUBSET of (Server, Value-or-Bottom, OriginalPeriod)
\* Captures the votes server i has accepted into its vote tracker for (r,p,s).
VARIABLE votesSeen          \* [Server -> [R -> [P -> [S -> SUBSET Vote]]]]

voteTrackingVars == <<votesSeen>>

\* --- voteTrackerPeriod cache: next-threshold status per (R,P) ---
\* Mirrors agreement/voteAuxiliary.go:21-85 (voteTrackerPeriod.Cached).
\* Two FIELDS that are populated INDEPENDENTLY (the bug-family-2 vector).
VARIABLE ntcBottom          \* [Server -> [R -> [P -> BOOLEAN]]] Cached.Bottom
VARIABLE ntcProposal        \* [Server -> [R -> [P -> Value \cup {Bottom}]]] Cached.Proposal

\* --- voteTrackerRound freshest bundle: per (R) ---
\* Mirrors agreement/voteAuxiliary.go:103-157 (voteTrackerRound.Freshest, Ok).
VARIABLE freshestT          \* [Server -> [R -> ThresholdEventType]]
VARIABLE freshestPeriod     \* [Server -> [R -> Nat]]
VARIABLE freshestValue      \* [Server -> [R -> Value \cup {Bottom}]]
VARIABLE freshestOk         \* [Server -> [R -> BOOLEAN]]

\* --- proposalTracker.Staging per (R, P) ---
\* Mirrors agreement/proposalTracker.go:99-105 and proposalStore.go:323-346.
VARIABLE staging            \* [Server -> [R -> [P -> Value \cup {Bottom}]]]

\* --- proposalSeeker.lowestIncludingLate per (R, P) ---
\* Mirrors agreement/proposalTracker.go:37-71 — used for Family 3 even after freeze.
VARIABLE pinnedLowest       \* [Server -> [R -> [P -> Value \cup {Bottom}]]]

cacheVars == <<ntcBottom, ntcProposal, freshestT, freshestPeriod,
               freshestValue, freshestOk, staging, pinnedLowest>>

\* --- In-flight votes (Family 1: persist-then-broadcast window) ---
\* Mirrors actions.go:438-446 + pseudonode.go:454-499.
\* A vote enters inFlight at attest do(); leaves on broadcast or crash.
VARIABLE inFlight           \* [Server -> SUBSET Vote] votes signed but not yet broadcast

\* --- External ledger (Family 1: catchup install) ---
\* Mirrors abstractions.go EnsureBlock contract + catchup/service.go fetchRound.
VARIABLE ledgerCertified    \* [Round -> Value \cup {Bottom, Nil}]
VARIABLE ledgerCertSource   \* [Round -> "local" | "catchup"] who installed it

ledgerVars == <<ledgerCertified, ledgerCertSource>>

\* --- Persisted vs volatile player state (Family 6) ---
\* Mirrors persistence.go:74-294 — what is encoded vs volatile.
\* Note: lowestCredentialArrivals (history for dynamic filter timeout) is NOT
\* persisted (persistence.go:246,262); model that as filterTimeoutValid.
VARIABLE persistedRound     \* [Server -> Nat]
VARIABLE persistedPeriod    \* [Server -> Nat]
VARIABLE persistedStep      \* [Server -> Step]

\* --- Dynamic filter timeout state (Family 3) ---
\* Per-server filter timeout for the current round period-0 entry.
\* Abstract to {FT_Short, FT_Default}.
VARIABLE filterTimeout      \* [Server -> [R -> FT_Short | FT_Default]]
\* Whether the 40-sample window is "full" (-> may use FT_Short).  Reset on
\* enterPeriod(target /= 0) (player.go:419-423) and on crash (persistence.go).
VARIABLE filterHistoryFull  \* [Server -> BOOLEAN]

filterVars == <<filterTimeout, filterHistoryFull>>

\* --- Crash state ---
VARIABLE crashed            \* [Server -> BOOLEAN]

persistVars == <<persistedRound, persistedPeriod, persistedStep, crashed>>

\* --- Committee oracle (abstract VRF) ---
\* Per (R, P, S) the committee is a non-deterministic subset of Server,
\* fixed at initialization (per modeling brief: "committee oracle").
\* Stake-weighting simplified to: stake(i)=1, so |committee| is the weight.
VARIABLE committee          \* [R x P x S -> SUBSET Server]
\* Family 5: per-server committee view (only diverges if a fork exists at R-2)
\* For honest validators with the same ledger, committee views agree.
VARIABLE committeeView      \* [Server -> [R x P x S -> SUBSET Server]]

committeeVars == <<committee, committeeView>>

\* --- Network: bag of messages ---
VARIABLE messages           \* Bag of message records

\* --- Decisions ---
\* A server "decides" round R when it sees a cert threshold for some value
\* and stagedValue.Committable. Tracked per server.
VARIABLE decision           \* [Server -> [Round -> Value \cup {Bottom, Nil}]]

decisionVars == <<decision>>

vars == <<playerVars, voteTrackingVars, cacheVars, inFlight, ledgerVars,
          persistVars, filterVars, committeeVars, messages, decisionVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Vote record format
\* OriginalPeriod records the period in which a value was first proposed —
\* used by issueSoftVote reproposer guard (player.go:196-202).
Vote(s, r, p, st, v, op) ==
    [sender |-> s, round |-> r, period |-> p, step |-> st,
     value |-> v, origPeriod |-> op]

\* Message constructors
SendVoteMsg(v) ==
    [mtype |-> VoteMsg, vote |-> v]

SendBundleMsg(et, r, p, st, v, broadcaster) ==
    [mtype |-> BundleMsg, etype |-> et, round |-> r,
     period |-> p, step |-> st, value |-> v, broadcaster |-> broadcaster]

SendProposalMsg(r, p, v, proposer, origPeriod) ==
    [mtype |-> ProposalMsg, round |-> r, period |-> p,
     value |-> v, proposer |-> proposer, origPeriod |-> origPeriod]

Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) (IF ms = {} THEN EmptyBag ELSE SetToBag(ms))
Discard(m) == messages' = messages (-) SetToBag({m})

\* Threshold reaches: server i sees enough votes from committee[r,p,st]
\* to form a threshold for value v at step st.
\* Reaches majority of committee  (stake-weighted abstraction).
\* Reference: agreement/voteTracker.go:189 and types.go:122-140 (reachesQuorum).
HasThreshold(i, r, p, st, v) ==
    LET voters == { vt \in votesSeen[i][r][p][st] : vt.value = v }
        senders == { vt.sender : vt \in voters }
        cmt == committeeView[i][r][p][st]
    IN /\ cmt /= {}
       /\ 2 * Cardinality(senders \cap cmt) > Cardinality(cmt)

\* StagedValue: the value the proposalTracker has "staged" — set by
\* softThreshold/certThreshold handlers (proposalTracker.go:203-211).
StagedValue(i, r, p) == staging[i][r][p]

\* nextThresholdStatusEvent reply (voteAuxiliary.go:79-80) —
\* what issueSoftVote / issueNextVote / issueFastVote read.
NextStatusBottom(i, r, p)   == ntcBottom[i][r][p]
NextStatusProposal(i, r, p) == ntcProposal[i][r][p]

\* fresherThan partial order (agreement/events.go:744-801).
\* IMPORTANT: this includes the cert-cert short-circuit at line 777 (Family 4).
FresherThan(eT, eP, eV, oT, oP, oV, rr) ==
    \* Both none -> true (reflexive on the unset cache; events.go:746-748)
    \/ (eT = NoneThresholdT /\ oT = NoneThresholdT)
    \/ (eT = NoneThresholdT /\ FALSE)             \* e none, o not none -> false
    \/ (oT = NoneThresholdT /\ eT /= NoneThresholdT) \* o none, e not none -> true
    \/ /\ eT /= NoneThresholdT
       /\ oT /= NoneThresholdT
       \* o is certThreshold and e is anything (including certThreshold):
       \* short-circuit at events.go:777 — return false.
       \* This is the Family 4 cert-cert short-circuit.
       /\ \/ /\ oT = CertThresholdT
             /\ FALSE
          \/ /\ oT /= CertThresholdT
             /\ \/ /\ eT = SoftThresholdT
                   /\ eP > oP                              \* events.go:782
                \/ /\ eT = CertThresholdT
                   /\ TRUE                                 \* events.go:784
                \/ /\ eT = NextThresholdT
                   /\ \/ eP > oP                           \* events.go:786-788
                      \/ /\ eP = oP
                         /\ \/ oT = SoftThresholdT          \* events.go:793-794
                            \/ /\ oT = NextThresholdT
                               /\ eV = Bottom
                               /\ oV /= Bottom              \* events.go:797

\* partitioned() — player.go:570-572.
Partitioned(i) == step[i] >= PartitionStepNum \/ period[i] >= 3

\* Is server i an honest validator (not Byzantine)?
IsHonest(i) == i \notin ByzServer

\* What value would a server pin at (R, P)? Used by partitionPolicy compound rebroadcast.
PinnedValue(i, r, p) == pinnedLowest[i][r][p]

\* Empty vote sets initializer
EmptyVoteSet == {}

\* Empty grids for nested functions
EmptyRPS == [r \in 0..MaxRound |->
              [p \in 0..MaxPeriod |->
                [s \in {StepPropose, StepSoft, StepCert, StepNext,
                        StepLate, StepRedo, StepDown} |-> EmptyVoteSet]]]

EmptyRP == [r \in 0..MaxRound |-> [p \in 0..MaxPeriod |-> Bottom]]
EmptyRPBool == [r \in 0..MaxRound |-> [p \in 0..MaxPeriod |-> FALSE]]
EmptyR == [r \in 0..MaxRound |-> Bottom]
EmptyRBool == [r \in 0..MaxRound |-> FALSE]
EmptyRNat == [r \in 0..MaxRound |-> 0]
EmptyRThr == [r \in 0..MaxRound |-> NoneThresholdT]

\* ============================================================================
\* ACTIONS
\* ============================================================================

\* --------------------------------------------------------------------------
\* IssueSoftVote(i)
\* Reference: agreement/player.go:170-206
\*
\* Path A (line 182-189): "did not see bottom in p-1, vote starting value"
\*   if p > 0 AND !nextStatus.Bottom AND nextStatus.Proposal != bottom
\* Path B (line 191-194): "did not see anything"
\*   if a.Proposal == bottom
\* Path C (line 196-202): REPROPOSER GUARD
\*   if period > a.Proposal.OriginalPeriod
\*     if nextStatus.Proposal != bottom AND nextStatus.Proposal == a.Proposal
\*       vote
\*     else reject
\* Path D (line 204-205): original proposal — vote
\*
\* The reproposer guard at lines 196-202 is the asymmetric guard described
\* by Family 2. It is present ONLY on the soft-vote path.
\* --------------------------------------------------------------------------
IssueSoftVote(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ step[i] = StepSoft
    /\ i \in committeeView[i][round[i]][period[i]][StepSoft]
    /\ LET frozen == staging[i][round[i]][period[i]]   \* proposalFrozenEvent result
           nsBot  == NextStatusBottom(i, round[i],
                                       IF period[i] > 0 THEN period[i] - 1 ELSE 0)
           nsPrp  == NextStatusProposal(i, round[i],
                                       IF period[i] > 0 THEN period[i] - 1 ELSE 0)
           candidate == frozen
       IN
       \/ \* Path A (player.go:182-189): use starting value, not the frozen one
          /\ period[i] > 0
          /\ ~nsBot
          /\ nsPrp /= Bottom
          /\ LET v == nsPrp
                 vote == Vote(i, round[i], period[i], StepSoft, v, period[i])
             IN /\ inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
                /\ step' = [step EXCEPT ![i] = StepCert]
                /\ UNCHANGED messages
       \/ \* Path B (player.go:191-194): no proposal, do not vote
          /\ candidate = Bottom
          \* "Did not see anything" — still advance step but do not sign
          /\ step' = [step EXCEPT ![i] = StepCert]
          /\ UNCHANGED <<inFlight, messages>>
       \/ \* Path C (player.go:196-202): reproposer guard
          /\ candidate /= Bottom
          \* Reproposal: candidate.OriginalPeriod < period[i].
          \* This branch fires when period > OriginalPeriod.
          /\ \E origP \in 0..period[i] :
                /\ origP < period[i]                   \* reproposal
                /\ \/ /\ nsPrp /= Bottom
                      /\ nsPrp = candidate
                      /\ LET vote == Vote(i, round[i], period[i], StepSoft,
                                          candidate, origP)
                         IN /\ inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
                            /\ step' = [step EXCEPT ![i] = StepCert]
                            /\ UNCHANGED messages
                   \/ \* Guard rejects — no vote
                      /\ \/ nsPrp = Bottom
                         \/ nsPrp /= candidate
                      /\ step' = [step EXCEPT ![i] = StepCert]
                      /\ UNCHANGED <<inFlight, messages>>
       \/ \* Path D (player.go:204-205): original proposal — vote
          /\ candidate /= Bottom
          /\ LET vote == Vote(i, round[i], period[i], StepSoft, candidate, period[i])
             IN /\ inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
                /\ step' = [step EXCEPT ![i] = StepCert]
                /\ UNCHANGED messages
    /\ UNCHANGED <<round, period, lastConcluding, napping, fastRecovery,
                   voteTrackingVars, cacheVars, ledgerVars, persistVars,
                   filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* IssueCertVote(i, v)
\* Reference: agreement/player.go:209-212
\*
\* Triggered by committableEvent, which is reached when proposalStore observes
\* both softThreshold AND has the payload (proposalStore.go:330-336).
\* NO reproposer guard.  Family 2: this is the cert-vote path that trusts
\* the upstream Staging.
\* --------------------------------------------------------------------------
IssueCertVote(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ step[i] = StepCert
    /\ i \in committeeView[i][round[i]][period[i]][StepCert]
    /\ LET v == staging[i][round[i]][period[i]] IN
       /\ v /= Bottom
       \* committableEvent precondition: softThreshold for v has formed
       \* and the proposalStore has the payload. We elide payload check
       \* (abstract value, no payload arrival modelled).
       /\ HasThreshold(i, round[i], period[i], StepSoft, v)
       /\ LET vote == Vote(i, round[i], period[i], StepCert, v, period[i]) IN
          inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
    \* IssueCertVote is invoked from the softThreshold handler (player.go:405).
    \* It does NOT transition p.Step — the player remains at StepCert. The next
    \* step transition happens at enterRound (when the cert threshold forms).
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, messages,
                   ledgerVars, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* IssueNextVote(i)
\* Reference: agreement/player.go:214-242
\*
\* Two paths:
\*   answer.Committable (=staging committable): vote for staged value
\*   else: read nextStatus from p-1
\*     if !nextStatus.Bottom: a.Proposal = nextStatus.Proposal (may be bottom)
\*     else: a.Proposal stays bottom (next-vote bottom)
\* NO reproposer guard.  Family 2: trusts upstream caches.
\* Calls partitionPolicy first (line 215).
\* --------------------------------------------------------------------------
IssueNextVote(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ step[i] >= StepNext
    /\ step[i] < PartitionStepNum + 5     \* bound step
    /\ i \in committeeView[i][round[i]][period[i]][step[i]]
    /\ LET stagedV == staging[i][round[i]][period[i]]
           nsBot   == NextStatusBottom(i, round[i],
                                       IF period[i] > 0 THEN period[i] - 1 ELSE 0)
           nsPrp   == NextStatusProposal(i, round[i],
                                       IF period[i] > 0 THEN period[i] - 1 ELSE 0)
           voteVal ==
                IF stagedV /= Bottom THEN stagedV
                ELSE IF ~nsBot THEN nsPrp
                ELSE Bottom
       IN
       LET vote == Vote(i, round[i], period[i], step[i], voteVal, period[i]) IN
       inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
    /\ step' = [step EXCEPT ![i] = step[i] + 1]
    /\ napping' = [napping EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<round, period, lastConcluding, fastRecovery,
                   voteTrackingVars, cacheVars, messages, ledgerVars,
                   persistVars, filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* HandleFastTimeout(i)
\* Reference: agreement/player.go:150-168
\*
\* Sets/advances FastRecoveryDeadline. First call sets the deadline and
\* returns no votes (line 160-164). Subsequent calls invoke issueFastVote.
\* --------------------------------------------------------------------------
HandleFastTimeoutPrimer(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ fastRecovery[i] = 0
    /\ Partitioned(i)        \* fast recovery only relevant in partition
    /\ fastRecovery' = [fastRecovery EXCEPT ![i] = 1]
    /\ UNCHANGED <<round, period, step, lastConcluding, napping,
                   voteTrackingVars, cacheVars, inFlight, messages,
                   ledgerVars, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* IssueFastVote(i)
\* Reference: agreement/player.go:244-274
\*
\* Calls partitionPolicy. Then writes a vote with Step in {late, redo, down}.
\* NO reproposer guard. Family 2: separate step labels disjoint from regular.
\* --------------------------------------------------------------------------
IssueFastVote(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ Partitioned(i)
    /\ fastRecovery[i] >= 1
    /\ LET stagedV == staging[i][round[i]][period[i]]
           nsBot   == NextStatusBottom(i, round[i],
                                       IF period[i] > 0 THEN period[i] - 1 ELSE 0)
           nsPrp   == NextStatusProposal(i, round[i],
                                       IF period[i] > 0 THEN period[i] - 1 ELSE 0)
       IN
       \/ \* answer.Committable -> Step=late (player.go:256-258)
          /\ stagedV /= Bottom
          /\ i \in committeeView[i][round[i]][period[i]][StepLate]
          /\ LET vote == Vote(i, round[i], period[i], StepLate, stagedV, period[i])
             IN inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
       \/ \* !nextStatus.Bottom -> Step=redo (player.go:259-266)
          /\ stagedV = Bottom
          /\ ~nsBot
          /\ nsPrp /= Bottom
          /\ i \in committeeView[i][round[i]][period[i]][StepRedo]
          /\ LET vote == Vote(i, round[i], period[i], StepRedo, nsPrp, period[i])
             IN inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
       \/ \* else Step=down with bottom proposal (player.go:268-271)
          /\ stagedV = Bottom
          /\ \/ nsBot
             \/ nsPrp = Bottom
          /\ i \in committeeView[i][round[i]][period[i]][StepDown]
          /\ LET vote == Vote(i, round[i], period[i], StepDown, Bottom, period[i])
             IN inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
    /\ fastRecovery' = [fastRecovery EXCEPT ![i] = fastRecovery[i] + 1]
    /\ UNCHANGED <<round, period, step, lastConcluding, napping,
                   voteTrackingVars, cacheVars, messages, ledgerVars,
                   persistVars, filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* PersistState(i)
\* Reference: actions.go:443 — persistCompleteEvents enqueued before voteEvents.
\*            pseudonode.go:454-469 — votes blocked on <-persistStateDone.
\*
\* This is the moment in-memory player state is durably on disk.
\* Bug Family 6: persistedRound/Period/Step are the only state that survives
\* a crash. Note: lowestCredentialArrivals is NOT persisted (persistence.go:246,262).
\* --------------------------------------------------------------------------
PersistState(i) ==
    /\ ~crashed[i]
    \* persistState in the implementation can fire even when the on-disk
    \* snapshot already matches the in-memory state (e.g., redundant flush
    \* on action-handler boundary). No precondition on state divergence.
    /\ persistedRound'  = [persistedRound  EXCEPT ![i] = round[i]]
    /\ persistedPeriod' = [persistedPeriod EXCEPT ![i] = period[i]]
    /\ persistedStep'   = [persistedStep   EXCEPT ![i] = step[i]]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, crashed, filterVars,
                   committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* BroadcastVote(i, vote)
\* Reference: pseudonode.go:471-499 (verifiedVotesLoop pushing to t.out)
\*
\* This is the actual network broadcast. Requires persistStateDone.
\* Family 1: this is the action that races with CatchupInstall and EnterRound.
\* --------------------------------------------------------------------------
BroadcastVote(i) ==
    /\ ~crashed[i]
    /\ \E vote \in inFlight[i] :
        /\ \* persistStateDone gating (pseudonode.go:457-469)
           /\ persistedRound[i] >= vote.round
           /\ persistedRound[i] = vote.round =>
              persistedPeriod[i] >= vote.period
        /\ Send(SendVoteMsg(vote))
        /\ inFlight' = [inFlight EXCEPT ![i] = @ \ {vote}]
        \* Self-injection: pseudonode.go:484 pushes voteVerified back into
        \* the player. We model this by also recording the vote in own votesSeen.
        /\ votesSeen' = [votesSeen EXCEPT
              ![i][vote.round][vote.period][vote.step] = @ \cup {vote}]
    /\ UNCHANGED <<playerVars, cacheVars, ledgerVars, persistVars,
                   filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* ReceiveVote(i, m)
\* Reference: agreement/voteAggregator.go + voteTracker.go (vote acceptance)
\*
\* On receipt, record the vote in our votesSeen. Subsequent actions check
\* HasThreshold to detect threshold formation (handled by HandleSoftThreshold,
\* HandleCertThreshold, HandleNextThreshold actions, mirroring voteAuxiliary
\* dispatch chain).
\* Filters: voteFresh/voteStepFresh (voteAggregator.go:252-278).
\* --------------------------------------------------------------------------
ReceiveVote(i, m) ==
    /\ m.mtype = VoteMsg
    /\ ~crashed[i]
    /\ LET v == m.vote IN
       /\ \* Freshness filter — voteFresh (voteAggregator.go:252-278)
          \/ v.round = round[i]
          \/ v.round = round[i] + 1
          \* Allow next-vote messages from previous period (voteStepFresh:240-249)
          \/ /\ v.round = round[i]
             /\ v.period = period[i] - 1
             /\ v.step \in {StepNext, StepLate, StepRedo, StepDown}
       /\ votesSeen' = [votesSeen EXCEPT
              ![i][v.round][v.period][v.step] = @ \cup {v}]
       /\ Discard(m)
    /\ UNCHANGED <<playerVars, cacheVars, inFlight, ledgerVars,
                   persistVars, filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* UpdateNextThresholdCache(i, r, p, v)
\* Reference: voteAuxiliary.go:71-77 (voteTrackerPeriod.handle for nextThreshold)
\*
\* Family 2: Cached.Bottom and Cached.Proposal accumulate independently.
\* The cache NEVER invalidates — so it can show
\* (Bottom=false, Proposal=bottom) if the period was entered via fast-forward
\* on a softThreshold without ever seeing a real next-vote bundle.
\* --------------------------------------------------------------------------
UpdateNextThresholdCache(i, r, p, v) ==
    /\ ~crashed[i]
    /\ HasThreshold(i, r, p, StepNext, v)   \* threshold formed
    /\ \* voteAuxiliary.go:73-77 dispatch
       IF v = Bottom
       THEN /\ ~ntcBottom[i][r][p]            \* idempotent on Bottom=true
            /\ ntcBottom'   = [ntcBottom   EXCEPT ![i][r][p] = TRUE]
            /\ UNCHANGED ntcProposal
       ELSE /\ ntcProposal[i][r][p] /= v
            /\ ntcProposal' = [ntcProposal EXCEPT ![i][r][p] = v]
            /\ UNCHANGED ntcBottom
    /\ UNCHANGED <<playerVars, voteTrackingVars, freshestT, freshestPeriod,
                   freshestValue, freshestOk, staging, pinnedLowest, inFlight,
                   messages, ledgerVars, persistVars, filterVars,
                   committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* UpdateFreshest(i, r, etype, ep, ev)
\* Reference: voteAuxiliary.go:144-150 (voteTrackerRound.handle for thresholds)
\*
\* Family 4: faithfully encodes fresherThan including cert-cert short-circuit.
\* --------------------------------------------------------------------------
UpdateFreshest(i, r, etype, ep, ev) ==
    /\ ~crashed[i]
    /\ etype \in {SoftThresholdT, CertThresholdT, NextThresholdT}
    /\ \* Implementation precondition: actually have the threshold
       \/ /\ etype = SoftThresholdT
          /\ HasThreshold(i, r, ep, StepSoft, ev)
       \/ /\ etype = CertThresholdT
          /\ HasThreshold(i, r, ep, StepCert, ev)
       \/ /\ etype = NextThresholdT
          /\ \E s \in {StepNext, StepLate, StepRedo, StepDown} :
                HasThreshold(i, r, ep, s, ev)
    /\ FresherThan(etype, ep, ev,
                   freshestT[i][r], freshestPeriod[i][r], freshestValue[i][r], r)
    /\ freshestT'      = [freshestT      EXCEPT ![i][r] = etype]
    /\ freshestPeriod' = [freshestPeriod EXCEPT ![i][r] = ep]
    /\ freshestValue'  = [freshestValue  EXCEPT ![i][r] = ev]
    /\ freshestOk'     = [freshestOk     EXCEPT ![i][r] = TRUE]
    /\ UNCHANGED <<playerVars, voteTrackingVars, ntcBottom, ntcProposal,
                   staging, pinnedLowest, inFlight, messages, ledgerVars,
                   persistVars, filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* UpdateStaging(i, r, p, v)
\* Reference: proposalTracker.go:203-211 (softThreshold/certThreshold handler)
\*
\* Family 2 & 4: Staging is set unconditionally; t.Staging != bottom guard at
\* proposalTracker.go:172 prevents resets but the first soft/cert threshold
\* observed wins (CR-6 in brief).
\* --------------------------------------------------------------------------
UpdateStaging(i, r, p, v) ==
    /\ ~crashed[i]
    /\ \/ HasThreshold(i, r, p, StepSoft, v)   \* softThreshold
       \/ HasThreshold(i, r, p, StepCert, v)   \* certThreshold
    /\ staging[i][r][p] = Bottom                \* per proposalTracker.go:172
    /\ v /= Bottom
    /\ staging' = [staging EXCEPT ![i][r][p] = v]
    /\ UNCHANGED <<playerVars, voteTrackingVars, ntcBottom, ntcProposal,
                   freshestT, freshestPeriod, freshestValue, freshestOk,
                   pinnedLowest, inFlight, messages, ledgerVars,
                   persistVars, filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* UpdatePinnedLowest(i, r, p, v)
\* Reference: proposalTracker.go:50-71 (proposalSeeker.accept w/ frozen branch)
\*
\* lowestIncludingLate continues recording lower credentials even after freeze.
\* Used by partitionPolicy compoundMessage rebroadcast.
\* --------------------------------------------------------------------------
UpdatePinnedLowest(i, r, p, v) ==
    /\ ~crashed[i]
    /\ v /= Bottom
    /\ v \in Values
    /\ pinnedLowest' = [pinnedLowest EXCEPT ![i][r][p] = v]
    /\ UNCHANGED <<playerVars, voteTrackingVars, ntcBottom, ntcProposal,
                   freshestT, freshestPeriod, freshestValue, freshestOk,
                   staging, inFlight, messages, ledgerVars, persistVars,
                   filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* HandleSoftThreshold(i, p, v)
\* Reference: agreement/player.go:377-390
\*
\* If p.Period > e.Period: drop (line 380-382).
\* If p.Period < e.Period: enterPeriod (line 383-385) - dispatched separately.
\* Else: if proposalCommittable AND step <= cert: issueCertVote.
\* --------------------------------------------------------------------------
HandleSoftThresholdSamePeriod(i, p, v) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ period[i] = p
    /\ HasThreshold(i, round[i], p, StepSoft, v)
    /\ v /= Bottom
    /\ staging[i][round[i]][p] = v       \* proposalCommittable
    /\ step[i] <= StepCert
    /\ LET vote == Vote(i, round[i], p, StepCert, v, p) IN
       /\ i \in committeeView[i][round[i]][p][StepCert]
       /\ inFlight' = [inFlight EXCEPT ![i] = @ \cup {vote}]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, messages,
                   ledgerVars, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* HandleCertThreshold(i, p, v)
\* Reference: agreement/player.go:354-375
\*
\* If stagedValue committable: install cert + enterRound(round+1).
\* Else: stageDigest + if period < e.Period: enterPeriod.
\* --------------------------------------------------------------------------
HandleCertThresholdLocal(i, p, v) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ HasThreshold(i, round[i], p, StepCert, v)
    /\ v /= Bottom
    \* stagedValue committable: have the payload (abstract: assume yes)
    /\ staging[i][round[i]][p] = v
    \* a0 := ensureAction (player.go:362) — locally certify
    /\ \/ ledgerCertified[round[i]] = Nil
       \/ ledgerCertified[round[i]] = v             \* idempotent
    /\ ledgerCertified'  = [ledgerCertified  EXCEPT ![round[i]] = v]
    /\ ledgerCertSource' = [ledgerCertSource EXCEPT ![round[i]] = "local"]
    /\ decision' = [decision EXCEPT ![i][round[i]] = v]
    \* enterRound(p.Round + 1) — handled as a separate side-effect; we just
    \* signal the round must advance. EnterRound action will fire.
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, persistVars, filterVars, committeeVars>>

\* --------------------------------------------------------------------------
\* EnterPeriod(i, target)
\* Reference: agreement/player.go:405-446
\*
\* p.LastConcluding = p.Step (line 413)
\* p.Period = target              (line 414)
\* p.Step = soft                  (line 415)
\* p.Napping = false              (line 416)
\* p.FastRecoveryDeadline = 0     (line 417)
\* if target != 0: lowestCredentialArrivals.reset() (line 419-423)
\*   — Family 3 / 6: this resets the dynamic filter timeout history.
\* p.Deadline = calculateFilterTimeout(...)   (line 424)
\* If source.t == softThreshold AND committable: issueCertVote (line 431-432)
\* If source.t == nextThreshold: rebroadcast (line 434-443)
\* --------------------------------------------------------------------------
EnterPeriodViaNextThreshold(i, target, v) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ target > period[i]
    /\ target <= MaxPeriod
    /\ \E sourceP \in 0..(target-1) :
        \E s \in {StepNext, StepLate, StepRedo, StepDown} :
            HasThreshold(i, round[i], sourceP, s, v)
    /\ lastConcluding' = [lastConcluding EXCEPT ![i] = step[i]]
    /\ period' = [period EXCEPT ![i] = target]
    /\ step' = [step EXCEPT ![i] = StepSoft]
    /\ napping' = [napping EXCEPT ![i] = FALSE]
    /\ fastRecovery' = [fastRecovery EXCEPT ![i] = 0]
    \* Family 3/6: history reset on non-zero period entry (player.go:419-423)
    /\ filterHistoryFull' = [filterHistoryFull EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<round, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, persistVars, filterTimeout,
                   committeeVars, decisionVars>>

EnterPeriodViaSoftThreshold(i, target, v) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ target > period[i]
    /\ target <= MaxPeriod
    /\ HasThreshold(i, round[i], target, StepSoft, v)
    /\ v /= Bottom
    /\ lastConcluding' = [lastConcluding EXCEPT ![i] = step[i]]
    /\ period' = [period EXCEPT ![i] = target]
    /\ step' = [step EXCEPT ![i] = StepSoft]
    /\ napping' = [napping EXCEPT ![i] = FALSE]
    /\ fastRecovery' = [fastRecovery EXCEPT ![i] = 0]
    /\ filterHistoryFull' = [filterHistoryFull EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<round, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, persistVars, filterTimeout,
                   committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* EnterRound(i, target)
\* Reference: agreement/player.go:448-502
\*
\* p.LastConcluding = p.Step      (line 463)
\* p.Round = target                (line 464)
\* p.Period = 0                    (line 465)
\* p.Step = soft                   (line 466)
\* p.Napping = false               (line 467)
\* p.FastRecoveryDeadline = 0      (line 468)
\* Filter timeout calculated       (line 470-477)
\* --------------------------------------------------------------------------
EnterRound(i, target) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ target > round[i]
    /\ target <= MaxRound
    \* Triggered by certThreshold (player.go:366) or payloadVerified path
    /\ \/ ledgerCertified[round[i]] /= Nil
       \/ \E p \in 0..MaxPeriod, v \in Values :
            HasThreshold(i, round[i], p, StepCert, v)
    /\ lastConcluding' = [lastConcluding EXCEPT ![i] = step[i]]
    /\ round'  = [round  EXCEPT ![i] = target]
    /\ period' = [period EXCEPT ![i] = 0]
    /\ step'   = [step   EXCEPT ![i] = StepSoft]
    /\ napping' = [napping EXCEPT ![i] = FALSE]
    /\ fastRecovery' = [fastRecovery EXCEPT ![i] = 0]
    /\ UNCHANGED <<voteTrackingVars, cacheVars, inFlight, messages,
                   ledgerVars, persistVars, filterVars,
                   committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* PartitionPolicy(i)
\* Reference: agreement/player.go:512-568
\*
\* Family 4: rebroadcasts the freshest bundle — including a stale cached
\* certThreshold (cert-cert short-circuit means it never updates).
\* --------------------------------------------------------------------------
PartitionPolicyRebroadcast(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ Partitioned(i)
    /\ freshestOk[i][round[i]]
    /\ LET et == freshestT[i][round[i]]
           ep == freshestPeriod[i][round[i]]
           ev == freshestValue[i][round[i]]
           bundleMsg ==
                CASE et = SoftThresholdT ->
                        SendBundleMsg(SoftThresholdT, round[i], ep, StepSoft, ev, i)
                  [] et = CertThresholdT ->
                        SendBundleMsg(CertThresholdT, round[i], ep, StepCert, ev, i)
                  [] et = NextThresholdT ->
                        SendBundleMsg(NextThresholdT, round[i], ep, StepNext, ev, i)
       IN Send(bundleMsg)
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   ledgerVars, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* ReceiveBundle(i, m)
\* Reference: agreement/voteAuxiliary.go (bundleVerified handling) and
\*            player.go:747-763 (handleMessageEvent bundlePresent).
\* When a server receives a rebroadcast bundle, it adds the constituent
\* votes to its tracker (abstracted as immediate threshold registration).
\* --------------------------------------------------------------------------
ReceiveBundle(i, m) ==
    /\ m.mtype = BundleMsg
    /\ ~crashed[i]
    /\ m.broadcaster /= i
    \* Abstract: the bundle provides the threshold's component votes.
    \* We synthesize a single "committee member" vote-set to materialize
    \* the threshold for honest tracker consumption.
    /\ LET fakeVote == Vote(m.broadcaster, m.round, m.period, m.step,
                            m.value, m.period) IN
       votesSeen' = [votesSeen EXCEPT
                       ![i][m.round][m.period][m.step] = @ \cup {fakeVote}]
    /\ Discard(m)
    /\ UNCHANGED <<playerVars, cacheVars, inFlight, ledgerVars,
                   persistVars, filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* AssemblerNewProposal(i, v)
\* Reference: agreement/pseudonode.go and proposal.go (block assembly).
\*
\* If i is in the propose committee for (round, period, step=propose),
\* it proposes a value. We model that the value is then "staged"
\* by the proposalStore once tracked.
\* --------------------------------------------------------------------------
ProposeBlock(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ i \in committeeView[i][round[i]][period[i]][StepPropose]
    /\ step[i] = StepSoft         \* enterPeriod sets step=soft, then we propose
    /\ \E v \in Values :
        /\ v /= Bottom
        /\ Send(SendProposalMsg(round[i], period[i], v, i, period[i]))
        \* In-flight propose-vote is also created
        /\ LET pvote == Vote(i, round[i], period[i], StepPropose, v, period[i])
           IN inFlight' = [inFlight EXCEPT ![i] = @ \cup {pvote}]
        /\ pinnedLowest' = [pinnedLowest EXCEPT ![i][round[i]][period[i]] = v]
    /\ UNCHANGED <<playerVars, voteTrackingVars, ntcBottom, ntcProposal,
                   freshestT, freshestPeriod, freshestValue, freshestOk,
                   staging, ledgerVars, persistVars, filterVars,
                   committeeVars, decisionVars>>

\* Receiver of a proposal: stages it for the period (lowest-cred wins, but
\* with multiple proposers we abstract this to: first proposal received per
\* period sets staging if staging is bottom).
ReceiveProposal(i, m) ==
    /\ m.mtype = ProposalMsg
    /\ ~crashed[i]
    /\ m.round = round[i]
    /\ m.period = period[i]
    /\ m.value /= Bottom
    /\ m.value \in Values
    \* "Staging" set lazily — only on softThreshold (proposalStore.go:323-346).
    \* Here we just track the proposal as a "pending lowest credential" so
    \* later softThresholds can stage it.
    /\ pinnedLowest' = [pinnedLowest EXCEPT ![i][m.round][m.period] = m.value]
    /\ Discard(m)
    /\ UNCHANGED <<playerVars, voteTrackingVars, ntcBottom, ntcProposal,
                   freshestT, freshestPeriod, freshestValue, freshestOk,
                   staging, inFlight, ledgerVars, persistVars,
                   filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* CatchupInstall(R, V)
\* Reference: catchup/service.go:744-841 (fetchRound)
\*
\* Family 1: Catchup externally installs the certified block for round R
\* INDEPENDENTLY of the player's state. The player may still be in round R,
\* period P>0, with in-flight votes that will broadcast AFTER the install.
\* --------------------------------------------------------------------------
CatchupInstall(r, v) ==
    /\ r >= 0 /\ r <= MaxRound
    /\ v \in Values
    \* Fork-detection branch (catchup/service.go:819-840) is LOG-ONLY.
    \* So this action does not block if a conflicting cert is already there
    \* — we model both safe and conflicting installs and check invariants.
    /\ \/ ledgerCertified[r] = Nil
       \/ ledgerCertified[r] = v        \* idempotent
    /\ ledgerCertified'  = [ledgerCertified  EXCEPT ![r] = v]
    /\ ledgerCertSource' = [ledgerCertSource EXCEPT ![r] =
            IF @ = Nil THEN "catchup" ELSE @]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* CalculateFilterTimeout(i)
\* Reference: agreement/player.go:317-347
\*
\* Two possible outcomes (Family 3):
\*   - dynamic-disabled OR period > 0 OR history not full -> FT_Default
\*   - else -> clamped dynamic -> FT_Short (if observed lower-arrival samples)
\* --------------------------------------------------------------------------
CalculateFilterTimeoutShort(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ period[i] = 0
    /\ filterHistoryFull[i]
    /\ filterTimeout' = [filterTimeout EXCEPT ![i][round[i]] = FT_Short]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, persistVars, filterHistoryFull,
                   committeeVars, decisionVars>>

CalculateFilterTimeoutDefault(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ filterTimeout' = [filterTimeout EXCEPT ![i][round[i]] = FT_Default]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, persistVars, filterHistoryFull,
                   committeeVars, decisionVars>>

\* History-full transition: server has accumulated 40 samples. We abstract
\* the count to a single boolean flag.
RecordCredentialArrival(i) ==
    /\ ~crashed[i]
    /\ IsHonest(i)
    /\ period[i] = 0
    /\ ~filterHistoryFull[i]
    /\ filterHistoryFull' = [filterHistoryFull EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, persistVars, filterTimeout,
                   committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* Crash(i)
\* Reference: persistence.go:74-294, service.go:281-284 (persistState)
\*
\* Family 6: Volatile state reverts to persisted snapshot.
\* In-flight votes are LOST (they had not yet broadcast — pseudonode.go:457
\* gates votes on <-persistStateDone, which means persistedRound/Period/Step
\* >= vote.round/period/step before broadcast).
\*
\* The lowestCredentialArrivals history is NOT persisted (Family 3/6).
\* --------------------------------------------------------------------------
Crash(i) ==
    /\ ~crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = TRUE]
    \* In-flight votes are dropped (they hadn't broadcast)
    /\ inFlight' = [inFlight EXCEPT ![i] = {}]
    \* Volatile state reverts to persisted on recovery (Recover below)
    \* Filter history is lost (persistence.go:246,262)
    /\ filterHistoryFull' = [filterHistoryFull EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, messages,
                   ledgerVars, persistedRound, persistedPeriod, persistedStep,
                   filterTimeout, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* Recover(i)
\* Reference: persistence.go restore() — applied at process start.
\* --------------------------------------------------------------------------
Recover(i) ==
    /\ crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = FALSE]
    \* Volatile state restored from persisted (the canonical state at last persist)
    /\ round'  = [round  EXCEPT ![i] = persistedRound[i]]
    /\ period' = [period EXCEPT ![i] = persistedPeriod[i]]
    /\ step'   = [step   EXCEPT ![i] = persistedStep[i]]
    /\ napping' = [napping EXCEPT ![i] = FALSE]
    /\ fastRecovery' = [fastRecovery EXCEPT ![i] = 0]
    /\ lastConcluding' = [lastConcluding EXCEPT ![i] = StepSoft]
    \* Vote trackers are persisted in agreement/persistence.go — so votesSeen
    \* is conceptually retained. Caches (ntc, freshest, staging) are also
    \* persisted as part of voteTracker* state.
    /\ UNCHANGED <<voteTrackingVars, cacheVars, inFlight, messages,
                   ledgerVars, persistedRound, persistedPeriod, persistedStep,
                   filterVars, committeeVars, decisionVars>>

\* --------------------------------------------------------------------------
\* LoseMessage(m)
\* Models network unreliability.
\* --------------------------------------------------------------------------
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   ledgerVars, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* ByzantineVote(b, r, p, st, v, origP)
\* A Byzantine validator emits an arbitrary vote (possibly equivocating).
\* Constrained to: b \in ByzServer, b \in committee[r,p,st].
\* --------------------------------------------------------------------------
ByzantineVote(b, r, p, st, v, origP) ==
    /\ b \in ByzServer
    /\ r >= 0 /\ r <= MaxRound
    /\ p >= 0 /\ p <= MaxPeriod
    /\ st \in {StepPropose, StepSoft, StepCert, StepNext,
               StepLate, StepRedo, StepDown}
    /\ v \in Values \cup {Bottom}
    /\ origP >= 0 /\ origP <= p
    /\ b \in committee[r][p][st]
    /\ LET vote == Vote(b, r, p, st, v, origP) IN
       Send(SendVoteMsg(vote))
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   ledgerVars, persistVars, filterVars, committeeVars,
                   decisionVars>>

\* --------------------------------------------------------------------------
\* ForkCommitteeView(i)
\* Family 5: An honest server's committee view for round R diverges from the
\* "true" committee oracle when a fork at R-2 produces a different seed.
\* Only the seed used for sortition differs; we model this by allowing the
\* committeeView to be replaced non-deterministically with a different subset.
\* --------------------------------------------------------------------------
ForkCommitteeView(i, r, p, st, newCmt) ==
    /\ r >= 2
    /\ r <= MaxRound
    /\ p >= 0 /\ p <= MaxPeriod
    /\ newCmt \subseteq Server
    \* Server's local ledger view at R-2 differs from committee's expected seed
    /\ ledgerCertified[r-2] /= Nil
    /\ committeeView' = [committeeView EXCEPT ![i][r][p][st] = newCmt]
    /\ UNCHANGED <<playerVars, voteTrackingVars, cacheVars, inFlight,
                   messages, ledgerVars, persistVars, filterVars,
                   committee, decisionVars>>

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

\* Initial committee oracle: every server is in every committee.
\* MC will refine this via constants.
InitialCommittee == [r \in 0..MaxRound |->
                      [p \in 0..MaxPeriod |->
                        [s \in {StepPropose, StepSoft, StepCert, StepNext,
                                StepLate, StepRedo, StepDown} |-> Server]]]

\* The test's testLedger initializes nextRound = 1 so the agreement service
\* starts at round 1. Spec Init mirrors this by setting round = 1 for all
\* servers (no need to model round 0 — it is pre-genesis).
Init ==
    /\ round         = [s \in Server |-> 1]
    /\ period        = [s \in Server |-> 0]
    /\ step          = [s \in Server |-> StepSoft]   \* enterRound sets step=soft
    /\ lastConcluding = [s \in Server |-> StepSoft]
    /\ napping       = [s \in Server |-> FALSE]
    /\ fastRecovery  = [s \in Server |-> 0]
    /\ votesSeen     = [s \in Server |-> EmptyRPS]
    /\ ntcBottom     = [s \in Server |-> EmptyRPBool]
    /\ ntcProposal   = [s \in Server |-> EmptyRP]
    /\ freshestT     = [s \in Server |-> EmptyRThr]
    /\ freshestPeriod = [s \in Server |-> EmptyRNat]
    /\ freshestValue = [s \in Server |-> EmptyR]
    /\ freshestOk    = [s \in Server |-> EmptyRBool]
    /\ staging       = [s \in Server |-> EmptyRP]
    /\ pinnedLowest  = [s \in Server |-> EmptyRP]
    /\ inFlight      = [s \in Server |-> {}]
    /\ ledgerCertified  = [r \in 0..MaxRound |-> Nil]
    /\ ledgerCertSource = [r \in 0..MaxRound |-> Nil]
    /\ persistedRound  = [s \in Server |-> 0]
    /\ persistedPeriod = [s \in Server |-> 0]
    /\ persistedStep   = [s \in Server |-> StepSoft]
    /\ crashed         = [s \in Server |-> FALSE]
    /\ filterTimeout   = [s \in Server |->
                            [r \in 0..MaxRound |-> FT_Default]]
    /\ filterHistoryFull = [s \in Server |-> FALSE]
    /\ committee     = InitialCommittee
    /\ committeeView = [s \in Server |-> InitialCommittee]
    /\ messages      = EmptyBag
    /\ decision      = [s \in Server |->
                          [r \in 0..MaxRound |-> Nil]]

Next ==
    \/ \E i \in Server :
        \/ IssueSoftVote(i)
        \/ IssueCertVote(i)
        \/ IssueNextVote(i)
        \/ HandleFastTimeoutPrimer(i)
        \/ IssueFastVote(i)
        \/ PersistState(i)
        \/ BroadcastVote(i)
        \/ ProposeBlock(i)
        \/ PartitionPolicyRebroadcast(i)
        \/ Crash(i)
        \/ Recover(i)
        \/ CalculateFilterTimeoutShort(i)
        \/ CalculateFilterTimeoutDefault(i)
        \/ RecordCredentialArrival(i)
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values \cup {Bottom} :
        \/ UpdateNextThresholdCache(i, round[i], p, v)
    \/ \E i \in Server, et \in {SoftThresholdT, CertThresholdT, NextThresholdT},
                       ep \in 0..MaxPeriod, ev \in Values \cup {Bottom} :
        UpdateFreshest(i, round[i], et, ep, ev)
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values :
        UpdateStaging(i, round[i], p, v)
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values :
        HandleSoftThresholdSamePeriod(i, p, v)
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values :
        HandleCertThresholdLocal(i, p, v)
    \/ \E i \in Server, target \in 1..MaxPeriod, v \in Values \cup {Bottom} :
        EnterPeriodViaNextThreshold(i, target, v)
    \/ \E i \in Server, target \in 1..MaxPeriod, v \in Values :
        EnterPeriodViaSoftThreshold(i, target, v)
    \/ \E i \in Server, target \in 1..MaxRound :
        EnterRound(i, target)
    \/ \E r \in 0..MaxRound, v \in Values :
        CatchupInstall(r, v)
    \/ \E b \in ByzServer, r \in 0..MaxRound, p \in 0..MaxPeriod,
         st \in {StepSoft, StepCert, StepNext},
         v \in Values \cup {Bottom}, origP \in 0..MaxPeriod :
        ByzantineVote(b, r, p, st, v, origP)
    \/ \E i \in Server, r \in 0..MaxRound, p \in 0..MaxPeriod,
         st \in {StepSoft, StepCert, StepNext}, newCmt \in SUBSET Server :
        ForkCommitteeView(i, r, p, st, newCmt)
    \/ \E m \in DOMAIN messages :
        \/ ReceiveVote(m.vote.sender, m)
        \/ ReceiveBundle(m.broadcaster, m)
        \/ LoseMessage(m)
        \/ \E i \in Server : ReceiveProposal(i, m)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard safety (Brief §5) ---

\* AgreementSafety (Brief §5): At most one block can be certified per round
\* across all periods. The certified value in ledgerCertified[r] is unique,
\* but the safety property is that no DIFFERENT cert threshold ever forms.
AgreementSafety ==
    \A r \in 0..MaxRound :
        \A v1, v2 \in Values :
            (\E i \in Server, p \in 0..MaxPeriod : HasThreshold(i, r, p, StepCert, v1))
            /\ (\E j \in Server, q \in 0..MaxPeriod : HasThreshold(j, r, q, StepCert, v2))
            => v1 = v2

\* LedgerConsistency (Brief §5): If EnsureBlock(R, B1) and EnsureBlock(R, B2)
\* installed via different sources, B1 = B2.
\* Reference: abstractions.go:197-212.
LedgerConsistency ==
    \A r \in 0..MaxRound :
        \A i \in Server :
            (decision[i][r] /= Nil /\ ledgerCertified[r] /= Nil)
            => decision[i][r] = ledgerCertified[r]

\* StagingMatchesFreshest (Brief §5): if freshest.Period == P then
\* staging[i][r][p] == freshest.Proposal (or bottom).
\* Family 4.
StagingMatchesFreshest ==
    \A i \in Server, r \in 0..MaxRound :
        freshestOk[i][r] /\ freshestT[i][r] \in {SoftThresholdT, CertThresholdT}
            => \/ staging[i][r][freshestPeriod[i][r]] = freshestValue[i][r]
               \/ staging[i][r][freshestPeriod[i][r]] = Bottom

\* ReproposalGuardEnforced (Brief §5): if server S issues softVote(R,P,V)
\* with OriginalPeriod(V) < P, then S has seen nextThreshold(R,P-1,V).
\* Family 2.
ReproposalGuardEnforced ==
    \A i \in Server, r \in 0..MaxRound, p \in 1..MaxPeriod :
        \A vt \in votesSeen[i][r][p][StepSoft] :
            (vt.sender = i /\ IsHonest(i) /\ vt.origPeriod < p /\ vt.value /= Bottom)
                => /\ ntcProposal[i][r][p-1] /= Bottom
                   /\ ntcProposal[i][r][p-1] = vt.value

\* CertImpliesStartingValue (Brief §5): if certThreshold(R,P,V) formed,
\* then for all P' > P, any soft threshold in (R, P') is for V.
\* Family 1, 2.
CertImpliesStartingValue ==
    \A r \in 0..MaxRound :
        \A p \in 0..MaxPeriod :
            \A v \in Values :
                (\E i \in Server : HasThreshold(i, r, p, StepCert, v))
                => \A pPrime \in (p+1)..MaxPeriod :
                    \A vPrime \in Values :
                        (\E j \in Server : HasThreshold(j, r, pPrime, StepSoft, vPrime))
                        => vPrime = v

\* NoCrossRoundEquivocation (Brief §5): if server S broadcasts vote v1 in
\* (R,P,S) and local player advanced to R+1, S does not broadcast vote v2
\* in (R,P,S) with different value.
\* Family 1, 6.
NoCrossRoundEquivocation ==
    \A i \in Server, r \in 0..MaxRound, p \in 0..MaxPeriod,
       st \in {StepSoft, StepCert, StepNext} :
        IsHonest(i) =>
            ~ \E vt1, vt2 \in votesSeen[i][r][p][st] :
                /\ vt1.sender = i /\ vt2.sender = i
                /\ vt1.value /= vt2.value
                /\ vt1.value \in Values
                /\ vt2.value \in Values

\* PersistedBeforeBroadcast (Brief §5): if attest action observable from
\* server S, then S has persisted player.Round=R,Period=P,Step=S.
\* Family 6 / pseudonode.go:457-469 contract.
PersistedBeforeBroadcast ==
    \A i \in Server :
        \A j \in Server, r \in 0..MaxRound, p \in 0..MaxPeriod,
           st \in {StepSoft, StepCert, StepNext} :
            \A vt \in {x \in votesSeen[j][r][p][st] : x.sender = i} :
                IsHonest(i) =>
                    \/ persistedRound[i] > vt.round
                    \/ /\ persistedRound[i] = vt.round
                       /\ \/ persistedPeriod[i] > vt.period
                          \/ persistedPeriod[i] = vt.period

\* FilterTimeoutWithinBounds (Brief §5, Family 3): filter timeout always in
\* the valid bucket set.
FilterTimeoutWithinBounds ==
    \A i \in Server, r \in 0..MaxRound :
        filterTimeout[i][r] \in {FT_Short, FT_Default}

\* --- Structural invariants ---

RoundBound ==
    \A i \in Server : round[i] >= 0 /\ round[i] <= MaxRound

PeriodBound ==
    \A i \in Server : period[i] >= 0 /\ period[i] <= MaxPeriod

PersistedNotAhead ==
    \A i \in Server :
        \/ persistedRound[i] < round[i]
        \/ /\ persistedRound[i] = round[i]
           /\ \/ persistedPeriod[i] < period[i]
              \/ persistedPeriod[i] = period[i]

CommitteeViewSubset ==
    \A i \in Server, r \in 0..MaxRound, p \in 0..MaxPeriod,
       s \in {StepPropose, StepSoft, StepCert, StepNext,
              StepLate, StepRedo, StepDown} :
        committeeView[i][r][p][s] \subseteq Server

LedgerSourceValid ==
    \A r \in 0..MaxRound :
        \/ ledgerCertSource[r] = Nil
        \/ ledgerCertSource[r] \in {"local", "catchup"}

\* --- Liveness (informal, used in MC.cfg only) ---

\* EventuallyConverge (Brief §5, Family 3, standard BA*): after GST, all
\* honest servers eventually reach the same round.
\* Stated weakly here; the MC spec will refine with fairness assumptions.
EventuallyConverge ==
    \A i, j \in Server :
        (IsHonest(i) /\ IsHonest(j)) ~> round[i] = round[j]

====
