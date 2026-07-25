------------------------------ MODULE MC_bughunt ------------------------------
\* Bug Hunting Model Checking Spec for besu QBFT.
\*
\* Extends MC with targeted extensions for MC-1 through MC-6 hypotheses:
\*   - MC-1: PeerSync action (blockchain advances via peer, tests block timer guard)
\*   - MC-6: Broken comparator (wrong best-prepared selection)
\*
\* Each extension can be independently enabled via config file.

EXTENDS MC

\* ============================================================================
\* MC-1: PeerSync (block timer guard asymmetry)
\* ============================================================================

\* Counter limit for PeerSync events
CONSTANT PeerSyncLimit
ASSUME PeerSyncLimit \in Nat

MCPeerSync(s) ==
    /\ constraintCounters.peerSync < PeerSyncLimit
    /\ qbft!PeerSync(s)
    /\ constraintCounters' = [constraintCounters EXCEPT !.peerSync = @ + 1]

\* ============================================================================
\* MC-6: Broken comparator (wrong best-prepared selection)
\* ============================================================================

\* Models RoundChangeArtifacts.java:72-85 comparator bug.
\* The real comparator violates the antisymmetric contract when both operands
\* have empty PreparedRoundMetadata. This models the worst case: selecting
\* the RC message with the LOWEST prepared round instead of the highest.
MCBestPreparedWrong(preparedMsgs) ==
    CHOOSE msg \in preparedMsgs :
        \A other \in preparedMsgs :
            msg.preparedRound <= other.preparedRound

\* ============================================================================
\* Bug Hunting Initialization
\* ============================================================================

MCBughuntInit ==
    /\ Init
    /\ constraintCounters = [
         blockTimer  |-> 0,
         roundExpiry |-> 0,
         crash       |-> 0,
         lose        |-> 0,
         peerSync    |-> 0]

\* ============================================================================
\* Bug Hunting Next State Relations
\* ============================================================================

\* Async actions for a server, including PeerSync
MCBughuntAsync(s) ==
    \/ MCBlockTimerExpiry(s)
    \/ MCRoundExpiry(s)
    \/ /\ qbft!NewChainHead(s)
       /\ UNCHANGED faultVars
    \/ /\ qbft!Recover(s)
       /\ UNCHANGED faultVars
    \/ MCPeerSync(s)

MCBughuntNext ==
    \/ \E s \in Server : MCBughuntAsync(s)
    \/ MCNextCrash
    \/ MCNextMessages
    \/ MCNextUnreliable

\* ============================================================================
\* Bug Hunting Specifications
\* ============================================================================

MCBughuntSpec ==
    /\ MCBughuntInit
    /\ [][MCBughuntNext]_mc_vars

=============================================================================
