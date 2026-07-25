--------------------------- MODULE base ---------------------------------
(**************************************************************************)
(* Model of distributed, cross-shard transactions in MongoDB.             *)
(*                                                                        *)
(* Extended from vldb25-dist-txns/MultiShardTxn.tla with:                 *)
(*   - Coordinator doc lifecycle (Family 1)                               *)
(*   - Coordinator failover + recovery (Family 1)                         *)
(*   - Abort decision path (Family 6)                                     *)
(*   - Session reaper vs. prepared txn (Family 2)                         *)
(*   - MoveKey with stale router cache (Family 4)                         *)
(*   - Single-write-shard optimization (Family 1)                         *)
(**************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, Util, TLC

CONSTANTS Keys, TxId

CONSTANT Router, Shard

CONSTANT NoValue

\* Global read concern setting for all transactions.
CONSTANTS RC

\* Set of all timestamps that can be used for starting a transaction.
CONSTANT Timestamps

CONSTANT IgnorePrepareBlocking
CONSTANT IgnoreWriteConflicts

\* Instantiating ClientCentric enables us to check transaction isolation guarantees
\* https://muratbuffalo.blogspot.com/2022/07/automated-validation-of-state-based.html
CC == INSTANCE ClientCentric WITH Keys <- Keys, Values <- TxId \union {NoValue}

\* for instantiating the ClientCentric module
wOp(k,v) == CC!w(k,v)
rOp(k,v) == CC!r(k,v)
InitialState == [k \in Keys |-> NoValue]

(**************************************************************************)
(* Router state                                                           *)
(**************************************************************************)

\* Tracks count of transaction statements processed on a router.
VARIABLE rtxn

\* The read timestamp being used for each running transaction on the router.
VARIABLE rTxnReadTs

\* Tracks whether a transaction at the router has initiated commit.
VARIABLE rInCommit

\* For each transaction, the router tracks a list of shards that are participants in that
\* transaction. The router forwards this information to the coordinator when ready to commit.
\* By default, the first participant in this list is designated as the coordinator.
VARIABLE rParticipants

\* Routers' cached view of the catalog, which maps keys to shards.
VARIABLE rCatalog

(**************************************************************************)
(* Shard state                                                            *)
(**************************************************************************)

\* The router writes transaction operations for a shard to 'shardTxnReqs',
\* and shards scan this log to learn transaction ops that have been routed to them.
VARIABLE shardTxnReqs

\* Set of in-progress transactions on each shard.
VARIABLES shardTxns

\* Set of prepared transactions on a shard.
VARIABLE shardPreparedTxns

\* Set of commit votes recorded by each coordinator shard, for each transaction.
VARIABLE coordCommitVotes

\* For each shard and transaction, keeps track of whether that transaction aborted e.g.
\* due to a write conflict.
VARIABLE aborted

\* Each shard, for each transaction, maintains a record of whether it has been designated as
\* the 2PC coordinator for that transaction.
VARIABLE coordInfo

(**************************************************************************)
(* Network and global state                                               *)
(**************************************************************************)

VARIABLE msgsPrepare
VARIABLE msgsVoteCommit
VARIABLE msgsAbort
VARIABLE msgsCommit

\* History of all operations per transaction on each shard.
VARIABLE shardOps

\* Global history of all operations per transaction.
VARIABLE ops

\* Stores a fixed mapping from keys to shards, for routing purposes.
VARIABLE catalog

(**************************************************************************)
(* Storage layer variables, for each shard.                               *)
(**************************************************************************)

\* We maintain a MongoDB "log" (i.e. a replica set/oplog abstraction) for each shard.
VARIABLE log
VARIABLE commitIndex

\* Snapshot of data store for each transaction on each shard.
VARIABLE txnSnapshots

VARIABLE txnStatus
VARIABLE stableTs, oldestTs, allDurableTs

(**************************************************************************)
(* Extension: Coordinator doc lifecycle [Family 1]                        *)
(*                                                                        *)
(* Models the persistent coordinator document written to                   *)
(* config.transaction_coordinators during 2PC. This document survives     *)
(* failover and enables the new primary to recover and re-drive the       *)
(* commit/abort decision.                                                 *)
(*                                                                        *)
(* States: "none" -> "participants" -> "commit"/"abort" -> "done"         *)
(* transaction_coordinator_util.cpp: persistParticipantsList (~line 700), *)
(* persistDecision (~line 800), sendCommit/sendAbort (~line 850)          *)
(**************************************************************************)
VARIABLE coordDoc

(**************************************************************************)
(* Variable groups                                                        *)
(**************************************************************************)

vars == << shardTxns, rInCommit, shardTxnReqs, aborted, log, commitIndex,
           rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
           msgsPrepare, msgsVoteCommit, msgsAbort, coordCommitVotes,
           catalog, msgsCommit, rTxnReadTs, shardPreparedTxns, rCatalog,
           txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

varsRouter == << rtxn, rInCommit, rTxnReadTs, rParticipants, rCatalog >>
varsNetwork == << msgsPrepare, msgsVoteCommit, msgsAbort, msgsCommit >>
varsStorage == << txnStatus, stableTs, oldestTs, allDurableTs >>

\* Instance of a MongoDB replica set log for a given shard, that
\* supports abstracted snapshot KV store.
Storage(s) == INSTANCE Storage WITH
                    mlog <- log,
                    mcommitIndex <- commitIndex,
                    mtxnSnapshots <- txnSnapshots,
                    txnStatus <- txnStatus,
                    stableTs <- stableTs,
                    oldestTs <- oldestTs,
                    allDurableTs <- allDurableTs,
                    MTxId <- TxId,
                    NoValue <- NoValue,
                    Node <- Shard,
                    Timestamps <- Timestamps

Ops == {"read", "write", "coordCommit"}
Entry == [k: Keys, op: Ops]
CreateEntry(k, op, s, coord, start, ts) == [
    k |-> k,
    op |-> op,
    shard |-> s,
    coord |-> coord,
    start |-> start,
    readTs |-> ts,
    rc |-> RC \* fixed, global read concern for now.
]
CreateCoordCommitEntry(op, s, p) == [op |-> op, shard |-> s, participants |-> p]

\* Initial coordinator doc entry.
InitCoordDocEntry == [state |-> "none", participants |-> <<>>, commitTs |-> NoValue]

(**************************************************************************)
(* Init                                                                   *)
(**************************************************************************)

Init ==
    /\ catalog \in [Keys -> Shard]
    /\ ops = [s \in TxId |-> <<>>]
    \* Router state.
    /\ rtxn = [r \in Router |-> [t \in TxId |-> 0]]
    /\ rParticipants = [r \in Router |-> [t \in TxId |-> <<>>]]
    /\ rTxnReadTs = [r \in Router |-> [t \in TxId |-> NoValue]]
    /\ rInCommit = [r \in Router |-> [t \in TxId |-> FALSE]]
    \* All routers start with same global catalog view.
    /\ rCatalog = [r \in Router |-> catalog]
    \* Shard state.
    /\ shardTxnReqs = [s \in Shard |-> [t \in TxId |-> <<>>]]
    /\ shardTxns = [s \in Shard |-> {}]
    /\ shardPreparedTxns = [s \in Shard |-> {}]
    /\ coordInfo = [s \in Shard |-> [t \in TxId |-> [self |-> FALSE, participants |-> <<>>, committing |-> FALSE]]]
    /\ coordCommitVotes = [s \in Shard |-> [t \in TxId |-> {}]]
    /\ shardOps = [s \in Shard |-> [t \in TxId |-> <<>>]]
    /\ aborted = [s \in Shard |-> [t \in TxId |-> FALSE]]
    \* 2PC related messages.
    /\ msgsPrepare = {}
    /\ msgsVoteCommit = {}
    /\ msgsAbort = {}
    /\ msgsCommit = {}
    \* MongoDB replica set log state.
    /\ log = [s \in Shard |-> Storage(s)!Init_mlog]
    /\ commitIndex = [s \in Shard |-> Storage(s)!Init_mcommitIndex]
    /\ txnSnapshots = [s \in Shard |-> Storage(s)!Init_mtxnSnapshots]
    /\ txnStatus = [s \in Shard |-> [t \in TxId |-> Storage(s)!STATUS_OK]]
    /\ stableTs = [s \in Shard |-> 0]
    /\ oldestTs = [s \in Shard |-> 0]
    /\ allDurableTs = [s \in Shard |-> 0]
    \* Extension: Coordinator doc [Family 1]
    /\ coordDoc = [s \in Shard |-> [t \in TxId |-> InitCoordDocEntry]]

(**************************************************************************)
(* Shard Restart (crash + recovery)                                       *)
(* [Family 1] TransactionCoordinatorService::_scheduleRecoveryTask()      *)
(*                                                                        *)
(* A shard crashes, erasing all in-memory data. Majority-committed data   *)
(* (log, prepared txn snapshots) and coordinator docs survive.            *)
(**************************************************************************)

Restart(s) ==
    /\ shardTxns' = [shardTxns EXCEPT ![s] = {}]
    /\ shardPreparedTxns' = [shardPreparedTxns EXCEPT ![s] = {}]
    \* Clear in-memory transaction snapshots on crashed shard.
    \* Prepared txns are preserved (majority committed to oplog); unprepared are lost.
    \* Uses storage-level "prepared" field (durable state) rather than in-memory
    \* shardPreparedTxns to correctly handle multiple consecutive restarts.
    \* [Family 1] transaction_coordinator.cpp: step-up recovery preserves prepared state
    /\ txnSnapshots' = [txnSnapshots EXCEPT ![s] =
            [t \in TxId |-> IF "prepared" \in DOMAIN txnSnapshots[s][t] /\ txnSnapshots[s][t].prepared
                            THEN txnSnapshots[s][t]
                            ELSE [active |-> FALSE, committed |-> FALSE, aborted |-> FALSE]]]
    /\ aborted' = [aborted EXCEPT ![s] = [t \in TxId |-> FALSE]]
    /\ coordInfo' = [coordInfo EXCEPT ![s] = [t \in TxId |-> [self |-> FALSE, participants |-> <<>>, committing |-> FALSE]]]
    /\ coordCommitVotes' = [coordCommitVotes EXCEPT ![s] = [t \in TxId |-> {}]]
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s] = [t \in TxId |-> <<>>]]
    \* Clear shard-local ops for unprepared txns (they are lost on crash).
    /\ shardOps' = [shardOps EXCEPT ![s] = [t \in TxId |->
                IF "prepared" \in DOMAIN txnSnapshots[s][t] /\ txnSnapshots[s][t].prepared
                THEN shardOps[s][t] ELSE <<>>]]
    \* All in-progress transactions on this shard will be aborted, so clear out ops
    \* on this shard from unprepared txns.
    /\ ops' = [tid \in TxId |->
                LET isPrepared == "prepared" \in DOMAIN txnSnapshots[s][tid] /\ txnSnapshots[s][tid].prepared
                IN IF tid \in shardTxns[s] /\ ~isPrepared
                    THEN SelectSeq(ops[tid], LAMBDA op : catalog[op.key] # s)
                    ELSE ops[tid]]
    \* Reset txnStatus for crashed shard.
    /\ txnStatus' = [txnStatus EXCEPT ![s] = [t \in TxId |-> Storage(s)!STATUS_OK]]
    \* Log, stableTs, oldestTs persist (replicated/on-disk state).
    \* [Family 1] coordDoc persists — this is the key recovery mechanism.
    /\ UNCHANGED << rtxn, rInCommit, log, commitIndex, rParticipants, rTxnReadTs,
                    rCatalog, catalog, msgsPrepare, msgsVoteCommit, msgsAbort,
                    msgsCommit, stableTs, oldestTs, allDurableTs, coordDoc >>

-------------------------------------------------

(**************************************************************************)
(* Router transaction operations.                                         *)
(* MultiShardTxn.tla:204-350                                              *)
(**************************************************************************)

\* Update router shard participant list for a transaction, while also
\* recording the type of ops done on each shard, and maintaining order when
\* shards joined the transaction.
\* MultiShardTxn.tla:222-228
UpdateParticipants(r, tid, snew, op) ==
    (IF (\E el \in Range(rParticipants[r][tid]) : el[1] = snew)
        THEN [ind \in DOMAIN rParticipants[r][tid] |->
                (IF rParticipants[r][tid][ind][1] = snew
                    THEN <<snew, rParticipants[r][tid][ind][2] \cup {op}>>
                    ELSE rParticipants[r][tid][ind])]
        ELSE Append(rParticipants[r][tid], <<snew, {op}>>))

AllLogTimestamps == UNION {0..Len(log[sh]) : sh \in Shard}
GlobalTimestamps == AllLogTimestamps \cup {max(AllLogTimestamps) + 1}

\* Represents the "start" of a transaction at the router as a separate operation,
\* which simply consists of picking a read timestamp.
\* MultiShardTxn.tla:235-243
RouterTxnStart(r, tid, readTs) ==
    /\ rTxnReadTs[r][tid] = NoValue
    /\ rTxnReadTs' = [rTxnReadTs EXCEPT ![r][tid] = IF RC = "snapshot" THEN readTs ELSE 0]
    /\ UNCHANGED << rCatalog, shardTxns, rParticipants, shardTxnReqs, rtxn, aborted,
                    log, commitIndex, txnSnapshots, ops, coordInfo, coordCommitVotes,
                    catalog, shardPreparedTxns, rInCommit, shardOps, varsNetwork,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* Router handles a new transaction operation that is routed to the appropriate shard.
\* MultiShardTxn.tla:246-264
RouterTxnOp(r, s, tid, k, op) ==
    /\ op \in {"read", "write"}
    \* If a shard of this transaction has aborted, don't continue the transaction.
    /\ ~\E as \in Shard : aborted[as][tid]
    \* Transaction has not already initiated commit at the router, and timestamp was chosen.
    /\ rInCommit[r][tid] = FALSE
    /\ rTxnReadTs[r][tid] # NoValue
    \* Route to the shard that owns this key (per router's cached catalog).
    /\ rCatalog[r][k] = s
    \* Assume that the router interacts with shards over a request-response RPC mechanism.
    /\ shardTxnReqs[s][tid] = <<>>
    \* Update participants list if new participant joined the transaction.
    /\ rParticipants' = [rParticipants EXCEPT ![r][tid] = UpdateParticipants(r, tid, s, op)]
    /\ LET firstShardOp == ~\E el \in Range(rParticipants[r][tid]) : el[1] = s IN
           shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = Append(shardTxnReqs[s][tid], CreateEntry(k, op, s, rtxn[r][tid] = 0, firstShardOp, rTxnReadTs[r][tid]))]
    /\ rtxn' = [rtxn EXCEPT ![r][tid] = rtxn[r][tid]+1]
    /\ UNCHANGED << rCatalog, shardTxns, rTxnReadTs, aborted, log, commitIndex,
                    txnSnapshots, ops, coordInfo, coordCommitVotes, catalog,
                    shardPreparedTxns, rInCommit, shardOps, varsNetwork,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* Router handles a transaction commit operation, which it forwards to the appropriate
\* shard to initiate 2PC to commit the transaction.
\* MultiShardTxn.tla:268-281
RouterTxnCoordinateCommit(r, s, tid, op) ==
    /\ op = "coordCommit"
    /\ shardTxnReqs[s][tid] = <<>>
    \* Transaction has started and has targeted multiple shards.
    /\ Len(rParticipants[r][tid]) > 1
    /\ ~rInCommit[r][tid]
    \* No shard of this transaction has aborted.
    /\ ~\E as \in Shard : aborted[as][tid]
    /\ s = rParticipants[r][tid][1][1] \* Coordinator shard is the first participant.
    \* Send coordinate commit message to the coordinator shard.
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = Append(shardTxnReqs[s][tid], CreateCoordCommitEntry(op, s, [i \in DOMAIN rParticipants[r][tid] |-> rParticipants[r][tid][i][1]]))]
    /\ rInCommit' = [rInCommit EXCEPT ![r][tid] = TRUE]
    /\ UNCHANGED << rCatalog, shardTxns, rtxn, aborted, log, commitIndex,
                    txnSnapshots, ops, rParticipants, coordInfo, coordCommitVotes,
                    catalog, rTxnReadTs, shardPreparedTxns, shardOps, varsNetwork,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* If a transaction only executed reads, even against multiple shards, then the
\* router can bypass 2PC and send commits directly to shards.
\* MultiShardTxn.tla:285-298
RouterTxnCommitReadOnly(r, s, tid) ==
    /\ Len(rParticipants[r][tid]) > 1
    /\ \A p \in Range(rParticipants[r][tid]) : p[2] = {"read"}
    /\ shardTxnReqs[s][tid] = <<>>
    /\ ~rInCommit[r][tid]
    /\ ~aborted[s][tid]
    /\ msgsCommit' = msgsCommit \cup { [shard |-> sp[1], tid |-> tid, commitTs |-> NoValue] : sp \in Range(rParticipants[r][tid])}
    /\ rInCommit' = [rInCommit EXCEPT ![r][tid] = TRUE]
    /\ UNCHANGED << rCatalog, shardTxns, aborted, shardTxnReqs, rtxn, log,
                    commitIndex, txnSnapshots, ops, rParticipants, coordInfo,
                    msgsVoteCommit, coordCommitVotes, catalog, msgsAbort,
                    msgsPrepare, rTxnReadTs, shardPreparedTxns, shardOps,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* If a transaction only targeted a single shard, then the router can commit the
\* transaction without going through a full 2PC.
\* MultiShardTxn.tla:303-314
RouterTxnCommitSingleShard(r, s, tid) ==
    /\ Len(rParticipants[r][tid]) = 1 /\ rParticipants[r][tid][1][1] = s
    /\ shardTxnReqs[s][tid] = <<>>
    /\ ~aborted[s][tid]
    /\ ~rInCommit[r][tid]
    /\ msgsCommit' = msgsCommit \cup { [shard |-> s, tid |-> tid, commitTs |-> NoValue] }
    /\ rInCommit' = [rInCommit EXCEPT ![r][tid] = TRUE]
    /\ UNCHANGED << rCatalog, shardTxns, aborted, shardTxnReqs, rtxn, log,
                    commitIndex, txnSnapshots, ops, rParticipants, coordInfo,
                    msgsVoteCommit, coordCommitVotes, catalog, msgsAbort,
                    msgsPrepare, rTxnReadTs, shardPreparedTxns, shardOps,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* The set of shard participants for a transaction that were written to.
\* Uses router-side tracking (rParticipants), not shard-side state (shardTxnReqs).
\* The router's commit-strategy decision is based on what ops it SENT to each shard,
\* not whether the shards have consumed them yet.
\* MultiShardTxn.tla:317 (fixed: was using shardTxnReqs which races with ShardTxnWrite)
RouterWriteParticipants(r, tid) ==
    {p[1] : p \in {q \in Range(rParticipants[r][tid]) : "write" \in q[2]}}

\* Single-write-shard optimization: transaction touched multiple shards but only
\* wrote to one. Router sends commits directly to all participants.
\* [Family 1] SERVER-48307: retry logic bug in this optimization.
\* MultiShardTxn.tla:324-334 (previously commented out)
RouterTxnCommitSingleWriteShard(r, tid) ==
    /\ Len(rParticipants[r][tid]) > 1
    /\ Cardinality(RouterWriteParticipants(r, tid)) = 1
    /\ ~\E as \in Shard : aborted[as][tid]
    /\ ~rInCommit[r][tid]
    \* Send commit message directly to all participants (bypass 2PC).
    \* In practice, read-only shards commit first, then write shard.
    \* We model as atomic for simplicity.
    /\ msgsCommit' = msgsCommit \cup
        { [shard |-> rParticipants[r][tid][i][1], tid |-> tid, commitTs |-> NoValue] :
          i \in DOMAIN rParticipants[r][tid] }
    /\ rInCommit' = [rInCommit EXCEPT ![r][tid] = TRUE]
    /\ UNCHANGED << rCatalog, shardTxns, aborted, shardTxnReqs, rtxn, log,
                    commitIndex, txnSnapshots, ops, rParticipants, coordInfo,
                    msgsVoteCommit, coordCommitVotes, catalog, msgsAbort,
                    msgsPrepare, rTxnReadTs, shardPreparedTxns, shardOps,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* Router aborts the transaction, which it can do at any point.
\* [Family 6] Previously commented out. Enabled to model abort path.
\* transaction_router.cpp: TransactionRouter::implicitAbort()
\* SERVER-66067: best-effort abort interferes with coordinator's 2PC commit.
RouterTxnAbort(r, tid) ==
    /\ rParticipants[r][tid] # <<>>
    \* Didn't already initiate commit.
    /\ ~rInCommit[r][tid]
    /\ msgsAbort' = msgsAbort \cup {[tid |-> tid, shard |-> s[1]] : s \in Range(rParticipants[r][tid])}
    /\ UNCHANGED << rCatalog, shardTxns, aborted, log, commitIndex, txnSnapshots,
                    ops, shardTxnReqs, rtxn, coordInfo, msgsPrepare, msgsVoteCommit,
                    coordCommitVotes, catalog, rParticipants, msgsCommit, rTxnReadTs,
                    shardPreparedTxns, rInCommit, shardOps,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>


(**************************************************************************)
(* Shard transaction operations.                                          *)
(* MultiShardTxn.tla:356-530                                              *)
(**************************************************************************)

\* Shard starts a new transaction.
\* MultiShardTxn.tla:357-369
ShardTxnStart(s, tid) ==
    /\ shardTxnReqs[s][tid] # <<>>
    /\ Head(shardTxnReqs[s][tid]).op \in {"read", "write"}
    /\ Head(shardTxnReqs[s][tid]).start
    /\ tid \notin shardTxns[s]
    /\ shardTxns' = [shardTxns EXCEPT ![s] = shardTxns[s] \union {tid}]
    /\ coordInfo' = [coordInfo EXCEPT ![s][tid] = [self |-> Head(shardTxnReqs[s][tid]).coord, participants |-> <<s>>, committing |-> FALSE]]
    /\ Storage(s)!StartTransaction(s, tid, Head(shardTxnReqs[s][tid]).readTs, Head(shardTxnReqs[s][tid]).rc, IgnorePrepareBlocking)
    /\ UNCHANGED << rCatalog, shardTxnReqs, aborted, log, commitIndex, ops,
                    msgsPrepare, msgsVoteCommit, coordCommitVotes, catalog,
                    msgsAbort, msgsCommit, shardPreparedTxns, shardOps,
                    varsRouter, coordDoc >>

\* Shard processes a transaction read operation.
\* MultiShardTxn.tla:372-389
ShardTxnRead(s, tid, k, v) ==
    /\ shardTxnReqs[s][tid] # <<>>
    /\ tid \in shardTxns[s]
    /\ tid \notin shardPreparedTxns[s]
    /\ Head(shardTxnReqs[s][tid]).op = "read"
    /\ Head(shardTxnReqs[s][tid]).k = k
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = Tail(shardTxnReqs[s][tid])]
    /\ shardOps' = [shardOps EXCEPT ![s][tid] = shardOps[s][tid] \o <<rOp(k, v)>>]
    /\ Storage(s)!TransactionRead(s, tid, k, v)
    /\ Storage(s)!TransactionPostOpStatus(s, tid) # Storage(s)!STATUS_PREPARE_CONFLICT
    /\ UNCHANGED << rCatalog, shardTxns, aborted, coordInfo, msgsPrepare,
                    msgsVoteCommit, coordCommitVotes, catalog, msgsAbort,
                    msgsCommit, shardPreparedTxns, ops, varsRouter, log,
                    commitIndex, coordDoc >>

\* Shard processes a transaction write operation.
\* MultiShardTxn.tla:392-404
ShardTxnWrite(s, tid, k) ==
    /\ tid \in shardTxns[s]
    /\ tid \notin shardPreparedTxns[s]
    /\ shardTxnReqs[s][tid] # <<>>
    /\ Head(shardTxnReqs[s][tid]).op = "write"
    /\ Head(shardTxnReqs[s][tid]).k = k
    /\ shardOps' = [shardOps EXCEPT ![s][tid] = Append( shardOps[s][tid], wOp(k, tid) )]
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = Tail(shardTxnReqs[s][tid])]
    /\ Storage(s)!TransactionWrite(s, tid, k, tid, IgnoreWriteConflicts)
    /\ UNCHANGED << rCatalog, shardTxns, log, commitIndex, aborted, coordInfo,
                    msgsPrepare, msgsVoteCommit, coordCommitVotes, catalog,
                    msgsAbort, msgsCommit, shardPreparedTxns, ops, varsRouter,
                    coordDoc >>

\* Shard spontaneously aborts a transaction.
\* [MODIFIED] Added guard: cannot abort prepared transactions (they require
\* coordinator-directed abort or session reaper).
\* MultiShardTxn.tla:520-530
ShardTxnAbort(s, tid) ==
    /\ tid \in shardTxns[s]
    \* [Family 2] Prepared transactions cannot be spontaneously aborted.
    \* Only coordinator-directed abort (ShardTxnRecvAbort) or reaper
    \* (ReapPreparedSession) can abort a prepared transaction.
    /\ tid \notin shardPreparedTxns[s]
    /\ aborted' = [aborted EXCEPT ![s][tid] = TRUE]
    /\ shardTxns' = [shardTxns EXCEPT ![s] = shardTxns[s] \ {tid}]
    /\ shardOps' = [shardOps EXCEPT ![s][tid] = <<>>]
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = <<>>]
    /\ Storage(s)!AbortTransaction(s, tid)
    /\ UNCHANGED << rCatalog, msgsAbort, log, commitIndex, coordInfo,
                    msgsPrepare, msgsVoteCommit, coordCommitVotes, catalog,
                    msgsCommit, shardPreparedTxns, ops, varsRouter, coordDoc >>


(**************************************************************************)
(* Shard 2PC actions.                                                     *)
(* MultiShardTxn.tla:433-509                                              *)
(**************************************************************************)

\* Transaction coordinator shard receives a message from router to start
\* coordinating commit for a transaction. Writes participant list to
\* coordinator doc (persistent).
\* [MODIFIED for Family 1] Now writes coordDoc to enable failover recovery.
\* transaction_coordinator_util.cpp:~700 (persistParticipantsList)
ShardTxnCoordinateCommit(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ shardTxnReqs[s][tid] # <<>>
    /\ Head(shardTxnReqs[s][tid]).op = "coordCommit"
    /\ coordInfo[s][tid].self
    /\ LET pList == Head(shardTxnReqs[s][tid]).participants IN
        \* Record participant list in-memory and persistently.
        /\ coordInfo' = [coordInfo EXCEPT ![s][tid] = [self |-> TRUE, participants |-> pList, committing |-> TRUE]]
        \* [Family 1] Persist participant list to coordinator doc (majority write).
        /\ coordDoc' = [coordDoc EXCEPT ![s][tid] =
                [state |-> "participants", participants |-> pList, commitTs |-> NoValue]]
        /\ coordCommitVotes' = [coordCommitVotes EXCEPT ![s][tid] = {}]
        \* Send prepare messages to all participant shards.
        /\ msgsPrepare' = msgsPrepare \cup {[shard |-> p, tid |-> tid, coordinator |-> s] : p \in Range(pList)}
        /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = Tail(shardTxnReqs[s][tid])]
    /\ UNCHANGED << rCatalog, shardTxns, log, commitIndex, aborted, txnSnapshots,
                    msgsVoteCommit, ops, catalog, msgsAbort, msgsCommit,
                    shardPreparedTxns, shardOps, varsRouter,
                    txnStatus, stableTs, oldestTs, allDurableTs >>

\* Transaction coordinator shard receives a vote from a participant shard.
\* MultiShardTxn.tla:449-459
ShardTxnCoordinatorRecvCommitVote(s, tid, from) ==
    /\ tid \in shardTxns[s]
    /\ coordInfo[s][tid].self
    /\ coordInfo[s][tid].committing
    /\ \E m \in msgsVoteCommit :
        /\ m.shard = from
        /\ m.tid = tid
        /\ msgsVoteCommit' = msgsVoteCommit \ {m}
        /\ coordCommitVotes' = [coordCommitVotes EXCEPT ![s][tid] = coordCommitVotes[s][tid] \union {<<from,m.prepareTs>>}]
    /\ UNCHANGED << rCatalog, shardTxns, log, commitIndex, shardTxnReqs, rtxn,
                    aborted, txnSnapshots, coordInfo, msgsPrepare, ops, catalog,
                    msgsAbort, msgsCommit, shardPreparedTxns, shardOps, varsRouter,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* Shard processes a transaction prepare message.
\* MultiShardTxn.tla:472-489
ShardTxnPrepare(s, tid) ==
    \E m \in msgsPrepare :
        /\ m.shard = s /\ m.tid = tid
        /\ tid \in shardTxns[s]
        /\ tid \notin shardPreparedTxns[s]
        /\ ~aborted[s][tid]
        /\ shardPreparedTxns' = [shardPreparedTxns EXCEPT ![s] = shardPreparedTxns[s] \union {tid}]
        /\ LET prepareTs == Storage(s)!NextTs(s) IN
            /\ msgsVoteCommit' = msgsVoteCommit \cup { [shard |-> s, tid |-> tid, to |-> m.coordinator, prepareTs |-> prepareTs] }
            /\ Storage(s)!PrepareTransaction(s, tid, prepareTs)
        /\ UNCHANGED << rCatalog, shardTxns, shardTxnReqs, aborted, coordInfo,
                        msgsPrepare, ops, coordCommitVotes, catalog, msgsAbort,
                        msgsCommit, shardOps, varsRouter, commitIndex, coordDoc >>

\* Shard receives a re-prepare message for an already-prepared transaction.
\* [NEW, Family 1] After coordinator failover, recovery re-sends prepare messages.
\* Participants that already prepared just re-send their vote.
\* transaction_coordinator_util.cpp: recoverCommit on step-up
ShardTxnRePrepare(s, tid) ==
    \E m \in msgsPrepare :
        /\ m.shard = s /\ m.tid = tid
        /\ tid \in shardTxns[s]
        \* Already prepared in storage layer (durable state survives restarts).
        /\ "prepared" \in DOMAIN txnSnapshots[s][tid]
        /\ txnSnapshots[s][tid].prepared
        \* Re-send the same vote to the (possibly new) coordinator.
        /\ msgsVoteCommit' = msgsVoteCommit \cup
            {[shard |-> s, tid |-> tid, to |-> m.coordinator,
              prepareTs |-> txnSnapshots[s][tid].prepareTs]}
        \* Re-add to shardPreparedTxns if lost during restart.
        /\ shardPreparedTxns' = [shardPreparedTxns EXCEPT ![s] = shardPreparedTxns[s] \cup {tid}]
    /\ UNCHANGED << rCatalog, shardTxns, shardTxnReqs, aborted, log, commitIndex,
                    txnSnapshots, coordInfo, msgsPrepare, ops, coordCommitVotes,
                    catalog, msgsAbort, msgsCommit, shardOps, varsRouter,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>

\* Shard receives a commit message for transaction, and commits.
\* MultiShardTxn.tla:492-509
ShardTxnCommit(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ \E m \in msgsCommit :
        /\ m.shard = s
        /\ m.tid = tid
        /\ msgsCommit' = msgsCommit \ {m}
        /\ shardTxns' = [shardTxns EXCEPT ![s] = shardTxns[s] \ {tid}]
        /\ shardPreparedTxns' = [shardPreparedTxns EXCEPT ![s] = shardPreparedTxns[s] \ {tid}]
        /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = <<>>]
        /\ ops' = [ops EXCEPT ![tid] = ops[tid] \o shardOps[s][tid]]
        /\  \* Commit prepared or unprepared transaction.
            \/ /\ m.commitTs = NoValue
               /\ Storage(s)!CommitTransaction(s, tid, Storage(s)!NextTs(s))
            \/ /\ m.commitTs # NoValue
               /\ Storage(s)!CommitPreparedTransaction(s, tid, m.commitTs, m.commitTs)
    /\ UNCHANGED << rCatalog, coordInfo, msgsPrepare, msgsVoteCommit,
                    coordCommitVotes, catalog, msgsAbort, aborted, shardOps,
                    varsRouter, commitIndex, coordDoc >>

\* Commit message arrives for a transaction that is not active on this shard.
\* [NEW, Family 2] This models the coordinator treating NoSuchTransaction as success.
\* When the session reaper destroys a prepared session, the subsequent commit
\* message is consumed as a no-op — the transaction's operations are lost.
\* transaction_coordinator_util.cpp:~951 (error classification)
\* SERVER-105751: reaper destroys TransactionParticipant with prepared txn.
ShardTxnCommitNoOp(s, tid) ==
    /\ tid \notin shardTxns[s]
    /\ \E m \in msgsCommit :
        /\ m.shard = s /\ m.tid = tid
        /\ msgsCommit' = msgsCommit \ {m}
    \* Operations are lost — torn commit possible.
    /\ UNCHANGED << rCatalog, shardTxns, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
                    msgsPrepare, msgsVoteCommit, msgsAbort, coordCommitVotes,
                    catalog, rTxnReadTs, shardPreparedTxns, rInCommit,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>


(**************************************************************************)
(* Coordinator doc lifecycle [Family 1]                                   *)
(*                                                                        *)
(* The original ShardTxnCoordinatorDecideCommit is split into two steps:  *)
(*   1. CoordinatorWriteCommitDecision — persist decision to coordDoc     *)
(*   2. CoordinatorSendCommit — broadcast commit to participants          *)
(* This exposes the crash window between persist and send.                *)
(*                                                                        *)
(* transaction_coordinator_util.cpp:~800 (persistDecision)                *)
(* transaction_coordinator_util.cpp:~850 (sendCommit/sendAbort)           *)
(**************************************************************************)

\* Coordinator persists commit decision to coordinator doc.
\* This is the durable commit point — after this, recovery will re-drive commit.
\* [Family 1] transaction_coordinator_util.cpp:~800 (persistDecision)
CoordinatorWriteCommitDecision(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ coordInfo[s][tid].self
    /\ coordDoc[s][tid].state = "participants"
    \* All participant shards have voted to commit.
    /\ {v[1] : v \in coordCommitVotes[s][tid]} = Range(coordInfo[s][tid].participants)
    /\ LET commitTs == max({v[2] : v \in coordCommitVotes[s][tid]}) IN
        coordDoc' = [coordDoc EXCEPT ![s][tid] =
            [state |-> "commit",
             participants |-> coordDoc[s][tid].participants,
             commitTs |-> commitTs]]
    /\ UNCHANGED << shardTxns, rInCommit, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
                    msgsPrepare, msgsVoteCommit, msgsAbort, coordCommitVotes,
                    catalog, msgsCommit, rTxnReadTs, shardPreparedTxns, rCatalog,
                    txnStatus, stableTs, oldestTs, allDurableTs >>

\* Coordinator sends commit messages to all participants.
\* [Family 1] transaction_coordinator_util.cpp:~850 (sendCommit)
CoordinatorSendCommit(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ coordInfo[s][tid].self
    /\ coordDoc[s][tid].state = "commit"
    /\ msgsCommit' = msgsCommit \cup
        { [shard |-> p, tid |-> tid, commitTs |-> coordDoc[s][tid].commitTs] :
          p \in Range(coordDoc[s][tid].participants) }
    /\ coordDoc' = [coordDoc EXCEPT ![s][tid] =
        [state |-> "done",
         participants |-> coordDoc[s][tid].participants,
         commitTs |-> coordDoc[s][tid].commitTs]]
    /\ UNCHANGED << shardTxns, rInCommit, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
                    msgsPrepare, msgsVoteCommit, msgsAbort, coordCommitVotes,
                    catalog, rTxnReadTs, shardPreparedTxns, rCatalog,
                    txnStatus, stableTs, oldestTs, allDurableTs >>

\* Coordinator persists abort decision to coordinator doc.
\* [Family 6] Fires when a participant has aborted/failed to prepare.
\* transaction_coordinator_util.cpp: persistDecision (abort branch)
\* SERVER-66067: abort interferes with coordinator's 2PC commit.
CoordinatorWriteAbortDecision(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ coordInfo[s][tid].self
    /\ coordDoc[s][tid].state = "participants"
    \* At least one participant has aborted (couldn't prepare).
    \* The coordinator detects this through timeout or abort response.
    /\ \E p \in Range(coordInfo[s][tid].participants) : aborted[p][tid]
    /\ coordDoc' = [coordDoc EXCEPT ![s][tid] =
        [state |-> "abort",
         participants |-> coordDoc[s][tid].participants,
         commitTs |-> NoValue]]
    /\ UNCHANGED << shardTxns, rInCommit, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
                    msgsPrepare, msgsVoteCommit, msgsAbort, coordCommitVotes,
                    catalog, msgsCommit, rTxnReadTs, shardPreparedTxns, rCatalog,
                    txnStatus, stableTs, oldestTs, allDurableTs >>

\* Coordinator sends abort messages to all participants.
\* [Family 6] transaction_coordinator_util.cpp: sendAbort
CoordinatorSendAbort(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ coordInfo[s][tid].self
    /\ coordDoc[s][tid].state = "abort"
    /\ msgsAbort' = msgsAbort \cup
        { [tid |-> tid, shard |-> p] :
          p \in Range(coordDoc[s][tid].participants) }
    /\ coordDoc' = [coordDoc EXCEPT ![s][tid] =
        [state |-> "done",
         participants |-> coordDoc[s][tid].participants,
         commitTs |-> NoValue]]
    /\ UNCHANGED << shardTxns, rInCommit, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
                    msgsPrepare, msgsVoteCommit, msgsCommit, coordCommitVotes,
                    catalog, rTxnReadTs, shardPreparedTxns, rCatalog,
                    txnStatus, stableTs, oldestTs, allDurableTs >>

\* Coordinator recovers from coordinator doc after shard restart.
\* [Family 1] TransactionCoordinatorService::_scheduleRecoveryTask()
\* On step-up, the new primary reads coordinator docs and resumes from
\* the persisted state. This handles three recovery scenarios:
\*   - "participants": re-send prepare messages, re-collect votes
\*   - "commit": re-send commit messages (decision already persisted)
\*   - "abort": re-send abort messages (decision already persisted)
CoordinatorRecover(s, tid) ==
    \* Coordinator was restarted (not in shardTxns, but coordDoc exists).
    /\ tid \notin shardTxns[s]
    /\ coordDoc[s][tid].state \in {"participants", "commit", "abort"}
    \* Re-add transaction to shard's active set.
    /\ shardTxns' = [shardTxns EXCEPT ![s] = shardTxns[s] \cup {tid}]
    \* Restore in-memory coordinator state from coordDoc.
    /\ coordInfo' = [coordInfo EXCEPT ![s][tid] =
            [self |-> TRUE,
             participants |-> coordDoc[s][tid].participants,
             committing |-> TRUE]]
    /\ \/ \* Recovery from "participants" state: re-send prepares, re-collect votes.
          /\ coordDoc[s][tid].state = "participants"
          /\ msgsPrepare' = msgsPrepare \cup
                {[shard |-> p, tid |-> tid, coordinator |-> s] :
                 p \in Range(coordDoc[s][tid].participants)}
          /\ coordCommitVotes' = [coordCommitVotes EXCEPT ![s][tid] = {}]
          /\ UNCHANGED << msgsCommit, msgsAbort, coordDoc >>
       \/ \* Recovery from "commit" state: re-send commit messages.
          /\ coordDoc[s][tid].state = "commit"
          /\ msgsCommit' = msgsCommit \cup
                {[shard |-> p, tid |-> tid, commitTs |-> coordDoc[s][tid].commitTs] :
                 p \in Range(coordDoc[s][tid].participants)}
          /\ coordDoc' = [coordDoc EXCEPT ![s][tid] =
                [state |-> "done",
                 participants |-> coordDoc[s][tid].participants,
                 commitTs |-> coordDoc[s][tid].commitTs]]
          /\ UNCHANGED << msgsPrepare, msgsAbort, coordCommitVotes >>
       \/ \* Recovery from "abort" state: re-send abort messages.
          /\ coordDoc[s][tid].state = "abort"
          /\ msgsAbort' = msgsAbort \cup
                {[tid |-> tid, shard |-> p] :
                 p \in Range(coordDoc[s][tid].participants)}
          /\ coordDoc' = [coordDoc EXCEPT ![s][tid] =
                [state |-> "done",
                 participants |-> coordDoc[s][tid].participants,
                 commitTs |-> NoValue]]
          /\ UNCHANGED << msgsPrepare, msgsCommit, coordCommitVotes >>
    /\ UNCHANGED << rCatalog, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants,
                    msgsVoteCommit, catalog, rTxnReadTs, shardPreparedTxns,
                    rInCommit, txnStatus, stableTs, oldestTs, allDurableTs >>


(**************************************************************************)
(* Abort message handling [Family 6]                                      *)
(*                                                                        *)
(* msgsAbort was previously a dead variable. Now used for:                *)
(*   - Router-initiated abort (RouterTxnAbort)                            *)
(*   - Coordinator-initiated abort (CoordinatorSendAbort)                 *)
(*                                                                        *)
(* SERVER-116284: sender destructed before commit reaches all shards.     *)
(* SERVER-116340: abortTransaction on different connection finds stale    *)
(* txn number.                                                            *)
(**************************************************************************)

\* Shard receives abort message and aborts an active transaction.
\* Handles both prepared and unprepared transactions.
ShardTxnRecvAbort(s, tid) ==
    /\ tid \in shardTxns[s]
    /\ \E m \in msgsAbort :
        /\ m.shard = s /\ m.tid = tid
        /\ msgsAbort' = msgsAbort \ {m}
    /\ aborted' = [aborted EXCEPT ![s][tid] = TRUE]
    /\ shardTxns' = [shardTxns EXCEPT ![s] = shardTxns[s] \ {tid}]
    /\ shardPreparedTxns' = [shardPreparedTxns EXCEPT ![s] = shardPreparedTxns[s] \ {tid}]
    /\ shardOps' = [shardOps EXCEPT ![s][tid] = <<>>]
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = <<>>]
    /\ Storage(s)!AbortTransaction(s, tid)
    /\ UNCHANGED << rCatalog, log, commitIndex, coordInfo, coordDoc,
                    msgsPrepare, msgsVoteCommit, coordCommitVotes, catalog,
                    msgsCommit, ops, varsRouter >>

\* Shard receives abort message for a transaction that is not active (already
\* committed, aborted, or unknown). Consume message as no-op.
ShardTxnRecvAbortNoOp(s, tid) ==
    /\ tid \notin shardTxns[s]
    /\ \E m \in msgsAbort :
        /\ m.shard = s /\ m.tid = tid
        /\ msgsAbort' = msgsAbort \ {m}
    /\ UNCHANGED << rCatalog, shardTxns, shardTxnReqs, aborted, log, commitIndex,
                    rtxn, txnSnapshots, ops, shardOps, rParticipants, coordInfo,
                    msgsPrepare, msgsVoteCommit, coordCommitVotes, catalog,
                    msgsCommit, rTxnReadTs, shardPreparedTxns, rInCommit,
                    txnStatus, stableTs, oldestTs, allDurableTs, coordDoc >>


(**************************************************************************)
(* Session reaper [Family 2]                                              *)
(*                                                                        *)
(* Timer-based session cleanup (reaper) destroys sessions that hold       *)
(* prepared transactions, causing torn commits.                           *)
(*                                                                        *)
(* SERVER-105751 (CRITICAL): Router-mode session reaper destroys          *)
(* TransactionParticipant with prepared transaction. Destructor aborts    *)
(* the prepared write; coordinator treats NoSuchTransaction as success    *)
(* -> torn cross-shard commit.                                            *)
(*                                                                        *)
(* Modeled as non-deterministic action (not timer-based).                 *)
(**************************************************************************)

\* Session reaper destroys a session with a prepared transaction.
\* This is the BUG scenario: the reaper should NOT be able to do this,
\* but the missing guard allows it.
\* SESSION: session catalog reaping callback
\* TransactionParticipant destructor (implicit abort on destroy)
ReapPreparedSession(s, tid) ==
    /\ tid \in shardPreparedTxns[s]
    /\ tid \in shardTxns[s]
    \* Reaper fires: destroys session, implicitly aborts prepared transaction.
    /\ aborted' = [aborted EXCEPT ![s][tid] = TRUE]
    /\ shardTxns' = [shardTxns EXCEPT ![s] = shardTxns[s] \ {tid}]
    /\ shardPreparedTxns' = [shardPreparedTxns EXCEPT ![s] = shardPreparedTxns[s] \ {tid}]
    /\ shardOps' = [shardOps EXCEPT ![s][tid] = <<>>]
    /\ shardTxnReqs' = [shardTxnReqs EXCEPT ![s][tid] = <<>>]
    /\ Storage(s)!AbortTransaction(s, tid)
    /\ UNCHANGED << rCatalog, log, commitIndex, coordInfo, coordDoc,
                    msgsPrepare, msgsVoteCommit, msgsAbort, coordCommitVotes,
                    catalog, msgsCommit, ops, varsRouter >>


(**************************************************************************)
(* Chunk migration [Family 4]                                             *)
(*                                                                        *)
(* Migrate a key from one shard to another. The router's cached catalog   *)
(* (rCatalog) is NOT updated, modeling stale cache routing.               *)
(*                                                                        *)
(* SERVER-71219: Migration callback lost on failover -> data loss.        *)
(* SERVER-78050: Migration pins stale snapshot -> misses writes.          *)
(* SERVER-89529: Resharding namespace filter -> loses retryability.       *)
(**************************************************************************)

MoveKey(k, sfrom, sto) ==
    /\ sfrom # sto
    /\ catalog[k] = sfrom
    /\ catalog' = [catalog EXCEPT ![k] = sto]
    \* Router catalog is NOT updated — models stale cache (real-world scenario).
    /\ UNCHANGED << rCatalog, shardTxns, shardTxnReqs, rtxn, txnSnapshots, ops,
                    rParticipants, coordInfo, msgsPrepare, msgsVoteCommit,
                    coordCommitVotes, msgsAbort, msgsCommit, rTxnReadTs,
                    shardPreparedTxns, rInCommit, aborted, log, commitIndex,
                    shardOps, txnStatus, stableTs, oldestTs, allDurableTs,
                    coordDoc >>


(**************************************************************************)
(* Next state relation                                                    *)
(**************************************************************************)

Next ==
    \* Router actions.
    \/ \E r \in Router, t \in TxId, ts \in Timestamps : RouterTxnStart(r, t, ts)
    \/ \E r \in Router, s \in Shard, t \in TxId, k \in Keys, op \in Ops : RouterTxnOp(r, s, t, k, op)
    \/ \E r \in Router, s \in Shard, t \in TxId, op \in Ops : RouterTxnCoordinateCommit(r, s, t, op)
    \/ \E r \in Router, s \in Shard, t \in TxId : RouterTxnCommitReadOnly(r, s, t)
    \/ \E r \in Router, s \in Shard, t \in TxId : RouterTxnCommitSingleShard(r, s, t)
    \* [Family 1] Single-write-shard optimization (previously commented out).
    \/ \E r \in Router, t \in TxId : RouterTxnCommitSingleWriteShard(r, t)
    \* [Family 6] Router-initiated abort (previously commented out).
    \/ \E r \in Router, t \in TxId : RouterTxnAbort(r, t)
    \* Shard transaction actions.
    \/ \E s \in Shard, tid \in TxId : ShardTxnStart(s, tid)
    \/ \E s \in Shard, tid \in TxId, k \in Keys, v \in TxId \cup {NoValue} : ShardTxnRead(s, tid, k, v)
    \/ \E s \in Shard, tid \in TxId, k \in Keys : ShardTxnWrite(s, tid, k)
    \/ \E s \in Shard, tid \in TxId : ShardTxnAbort(s, tid)
    \* Shard 2PC actions.
    \/ \E s \in Shard, tid \in TxId : ShardTxnCoordinateCommit(s, tid)
    \/ \E s, from \in Shard, tid \in TxId : ShardTxnCoordinatorRecvCommitVote(s, tid, from)
    \/ \E s \in Shard, tid \in TxId : ShardTxnPrepare(s, tid)
    \/ \E s \in Shard, tid \in TxId : ShardTxnRePrepare(s, tid)
    \/ \E s \in Shard, tid \in TxId : ShardTxnCommit(s, tid)
    \/ \E s \in Shard, tid \in TxId : ShardTxnCommitNoOp(s, tid)
    \* Coordinator doc lifecycle [Family 1].
    \/ \E s \in Shard, tid \in TxId : CoordinatorWriteCommitDecision(s, tid)
    \/ \E s \in Shard, tid \in TxId : CoordinatorSendCommit(s, tid)
    \/ \E s \in Shard, tid \in TxId : CoordinatorRecover(s, tid)
    \* Abort path [Family 6].
    \/ \E s \in Shard, tid \in TxId : CoordinatorWriteAbortDecision(s, tid)
    \/ \E s \in Shard, tid \in TxId : CoordinatorSendAbort(s, tid)
    \/ \E s \in Shard, tid \in TxId : ShardTxnRecvAbort(s, tid)
    \/ \E s \in Shard, tid \in TxId : ShardTxnRecvAbortNoOp(s, tid)
    \* Session reaper [Family 2].
    \/ \E s \in Shard, tid \in TxId : ReapPreparedSession(s, tid)
    \* Chunk migration [Family 4].
    \/ \E k \in Keys, sfrom, sto \in Shard : MoveKey(k, sfrom, sto)
    \* Shard restart [Family 1].
    \/ \E s \in Shard : Restart(s)

Fairness == TRUE
    /\ WF_vars(\E r \in Router, s \in Shard, t \in TxId, k \in Keys, op \in Ops : RouterTxnOp(r, s, t, k, op))
    /\ WF_vars(\E r \in Router, s \in Shard, t \in TxId, op \in Ops : RouterTxnCoordinateCommit(r, s, t, op))
    /\ WF_vars(\E r \in Router, s \in Shard, t \in TxId : RouterTxnCommitSingleShard(r, s, t))
    /\ WF_vars(\E r \in Router, t \in TxId : RouterTxnCommitSingleWriteShard(r, t))
    /\ WF_vars(\E s \in Shard, tid \in TxId : ShardTxnStart(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId, k \in Keys, v \in TxId \cup {NoValue} : ShardTxnRead(s, tid, k, v))
    /\ WF_vars(\E s \in Shard, tid \in TxId, k \in Keys : ShardTxnWrite(s, tid, k))
    /\ WF_vars(\E s \in Shard, tid \in TxId : ShardTxnPrepare(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : ShardTxnRePrepare(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : ShardTxnCoordinateCommit(s, tid))
    /\ WF_vars(\E s, from \in Shard, tid \in TxId : ShardTxnCoordinatorRecvCommitVote(s, tid, from))
    /\ WF_vars(\E s \in Shard, tid \in TxId : CoordinatorWriteCommitDecision(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : CoordinatorSendCommit(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : CoordinatorWriteAbortDecision(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : CoordinatorSendAbort(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : ShardTxnCommit(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : ShardTxnRecvAbort(s, tid))
    /\ WF_vars(\E s \in Shard, tid \in TxId : CoordinatorRecover(s, tid))

Spec == Init /\ [][Next]_vars

-----------------------------------------

(**************************************************************************)
(* Isolation properties (existing).                                       *)
(**************************************************************************)

ReadUncommittedIsolation == CC!ReadUncommitted(InitialState, Range(ops))
ReadCommittedIsolation == CC!ReadCommitted(InitialState, Range(ops))
RepeatableReadIsolation == CC!RepeatableRead(InitialState, Range(ops))
SnapshotIsolation == CC!SnapshotIsolation(InitialState, Range(ops))
SerializableIsolation == CC!Serializability(InitialState, Range(ops))

SnapshotAnomaly == SnapshotIsolation /\ ~SerializableIsolation
SnapshotAnomalyBait == ~SnapshotAnomaly

(**************************************************************************)
(* Extension invariants (bug-family driven).                              *)
(**************************************************************************)

\* [Family 1+2+6] 2PC Atomicity: if coordinator decided commit, no
\* participant should have its transaction aborted.
\* Targets: torn commits from reaper (Family 2), abort path gaps (Family 6),
\* coordinator crash windows (Family 1).
TwoPCAtomicity ==
    \A tid \in TxId :
        \A s \in Shard :
            \* If coordinator for this txn decided to COMMIT (not abort)...
            \* Distinguish commit-done from abort-done via commitTs.
            /\ coordDoc[s][tid].state \in {"commit", "done"}
            /\ coordDoc[s][tid].commitTs # NoValue
            =>
                \* ...then no participant should have aborted it
                \A p \in Range(coordDoc[s][tid].participants) :
                    ~aborted[p][tid]

\* [Family 1] No orphaned prepared transactions.
\* Every prepared transaction must have a coordinator doc so recovery can complete.
\* Targets: coordinator crash before decision write, broken Restart.
NoOrphanedPrepared ==
    \A s \in Shard :
        \A tid \in shardPreparedTxns[s] :
            \* If prepared, the coordinator doc must exist (state != "none")
            \* so that recovery can drive the transaction to completion.
            \E cs \in Shard :
                coordDoc[cs][tid].state \in {"participants", "commit", "abort", "done"}

\* [Family 1] Coordinator doc consistency.
\* If coordinator doc says "commit", no abort messages should exist for participants.
CoordinatorDocConsistency ==
    \A tid \in TxId :
        \A s \in Shard :
            \* If coordinator decided COMMIT (commitTs present), no abort msgs.
            /\ coordDoc[s][tid].state \in {"commit", "done"}
            /\ coordDoc[s][tid].commitTs # NoValue
            =>
                ~\E m \in msgsAbort :
                    /\ m.tid = tid
                    /\ m.shard \in Range(coordDoc[s][tid].participants)

\* [Family 2] Reaper safety (detection invariant).
\* This SHOULD be violated when ReapPreparedSession fires — that's the bug.
\* In a correct system, the reaper would never destroy a prepared session.
ReaperSafety ==
    \A s \in Shard :
        \A tid \in TxId :
            (tid \in shardPreparedTxns[s]) => ~aborted[s][tid]

\* [Family 4] Routing consistency for active transactions.
\* When a transaction has committed writes on a shard, those keys should
\* still be owned by that shard per the ground-truth catalog.
\* Targets: stale router cache after MoveKey.
RoutingConsistency ==
    \A s \in Shard :
        \A tid \in TxId :
            txnSnapshots[s][tid].committed =>
                \A k \in Keys :
                    (k \in txnSnapshots[s][tid].writeSet) => catalog[k] = s

\* [Structural] Message buffer constraint (for state space bounding).
MsgBufferConstraint(limit) ==
    /\ Cardinality(msgsPrepare) <= limit
    /\ Cardinality(msgsVoteCommit) <= limit
    /\ Cardinality(msgsAbort) <= limit
    /\ Cardinality(msgsCommit) <= limit

===========================================================================
