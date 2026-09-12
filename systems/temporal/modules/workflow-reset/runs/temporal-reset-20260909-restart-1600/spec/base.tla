------------------------------- MODULE base -------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

\* temporal-reset; Category A; temporalio/temporal at
\* 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
\* One namespace/workflow/shard. See model-notes.md for abstraction boundaries.
CONSTANTS Runs, Ops, ResetIDs, StartIDs, UpdateIDs, Payloads,
          Backend, IOConcurrency, HistoryLimit, StartMapPresent, ScannerAfterRequestDeadline
None == "none"
Kinds == {"Start", "WFT", "Signal", "Accepted", "Admitted", "Completed",
          "CAN", "Terminated", "ResetWFT"}
SeqSet(s) == {s[i] : i \in 1..Len(s)}
Prefix(s, n) == SubSeq(s, 1, n)
Evt(r, n, k, id, payload, hasRequest, next) ==
    [origin |-> r, number |-> n, kind |-> k, id |-> id,
     payload |-> payload, hasRequest |-> hasRequest, next |-> next, version |-> 1]
BlankEvent(r, n, k) == Evt(r, n, k, None, None, FALSE, None)
InitialHistory(r, id) == <<Evt(r,1,"Start",id,None,FALSE,None)>>
OwnCells(r, lo, hi) == [i \in 1..(hi-lo+1) |-> <<r,lo+i-1>>]
EventIDs(s) == {e.id : e \in {x \in SeqSet(s) : x.kind \in {"Accepted","Admitted"}}}
Eligible(e, ex) ==
    \/ (e.kind = "Signal" /\ "Signal" \notin ex)
    \/ (e.kind = "Admitted" /\ "Update" \notin ex)
    \/ (e.kind = "Accepted" /\ e.hasRequest /\ "Update" \notin ex)
RECURSIVE FilterEligible(_, _)
FilterEligible(s, ex) ==
    IF s = <<>> THEN <<>> ELSE
       (IF Eligible(Head(s),ex) THEN <<Head(s)>> ELSE <<>>) \o FilterEligible(Tail(s),ex)
\* Source identities persist; accepted events become admissions on the new run.
\* service/history/ndc/workflow_resetter.go:996-1021
Reapplied(e) == IF e.kind = "Accepted" THEN [e EXCEPT !.kind = "Admitted"] ELSE e
ReappliedSeq(s) == [i \in 1..Len(s) |-> Reapplied(s[i])]
EmptyRun == [exists |-> FALSE, status |-> "absent", ver |-> 0, n |-> 0, firstTaskScheduled |-> FALSE,
    create |-> None, start |-> None, requestIds |-> {}, callback |-> None,
    link |-> None, can |-> None, base |-> None, cut |-> 0, resetReq |-> None]
\* mutable_state_impl.go:357,7897-7901; state_rebuilder.go:130;
\* workflow_resetter.go:380: creation closes once, reset rebuild closes twice.
NewRun(id, b, cut, q, n) == [exists |-> TRUE, status |-> "running",
    ver |-> IF b = None THEN 2 ELSE 3, n |-> n, firstTaskScheduled |-> TRUE,
    create |-> id, start |-> id, requestIds |-> IF StartMapPresent THEN {id} ELSE {},
    callback |-> id, link |-> None, can |-> None, base |-> b, cut |-> cut, resetReq |-> q]
EmptyOp == [pc |-> "idle", kind |-> None, req |-> None, base |-> None, cut |-> 0,
    exclude |-> {}, candidate |-> None, seen |-> None, bv |-> 0, cv |-> 0,
    baseN |-> 0, curN |-> 0, create |-> None, callback |-> None,
    originalToken |-> None, prefixToken |-> None, localLink |-> None,
    terminate |-> FALSE, scan |-> None, end |-> 0, index |-> 1,
    batch |-> <<>>, input |-> <<>>, prefix |-> <<>>, built |-> <<>>,
    expected |-> <<>>, reapplied |-> <<>>, updateIds |-> {},
    visited |-> <<>>, frontier |-> <<>>, err |-> None, result |-> None,
    immediate |-> None, adminEpoch |-> 0, dedup |-> FALSE]
EmptyWrite == [state |-> "empty", mode |-> None, owner |-> None, epoch |-> 0,
    base |-> None, seen |-> None, bv |-> 0, cv |-> 0, curN |-> 0,
    create |-> None, req |-> None, cut |-> 0, terminate |-> FALSE,
    events |-> <<>>, prefix |-> <<>>, expected |-> <<>>, reapplied |-> <<>>,
    prechecked |-> FALSE, reply |-> "waiting", result |-> None,
    immediate |-> None, adminEpoch |-> 0]
EmptyDelete == [stage |-> "none", epoch |-> 0, plan |-> {}, aged |-> FALSE,
    scanner |-> FALSE]

\* Scenarios 2/3: execution metadata, append-only branch storage and ownership.
VARIABLES db, op, pending, rt, audit, deletion, used
vars == <<db, op, pending, rt, audit, deletion, used>>
Init ==
    /\ db = [runs |-> [r \in Runs |-> EmptyRun], current |-> None, range |-> 1,
              hist |-> [r \in Runs |-> <<>>], cells |-> [r \in Runs |-> <<>>],
              branches |-> {}, nodes |-> {}]
    /\ op = [p \in Ops |-> EmptyOp]
    /\ pending = [r \in Runs |-> EmptyWrite]
    /\ rt = [state |-> "acquired", epoch |-> 1, leases |-> [r \in Runs |-> None],
              currentLock |-> None, io |-> {}]
    /\ audit = [acks |-> {}, receipts |-> {}, commits |-> {}, deleted |-> {},
                 retryBad |-> FALSE, wanted |-> {}, terminal |-> {},
                 admin |-> [q \in ResetIDs |-> 0], availableBad |-> FALSE, reapplyBad |-> FALSE]
    /\ deletion = [r \in Runs |-> EmptyDelete]
    /\ used = {}
FreshRuns == Runs \ used
Live(r) == r \in Runs /\ db.runs[r].exists
Serving == rt.state = "acquired"
Slots == IF Backend = "Cassandra" THEN 1 ELSE IOConcurrency
History(r) == Prefix(db.hist[r], db.runs[r].n)
Readable(r, n) == SeqSet(Prefix(db.cells[r], n)) \subseteq db.nodes
Unlocked(r) == rt.leases[r] = None
Free(p) == op[p].pc \in {"idle", "done"}
Active(p) == op[p].pc \notin {"idle", "done", "retry"}
ChangedRun(r, q) == [db.runs[r] EXCEPT !.ver = @+1, !.link = q]
\* source: state_rebuilder.go:402-410; the map is restricted to its Start entry.
FindStart(r) == IF db.runs[r].requestIds /= {}
                THEN CHOOSE id \in db.runs[r].requestIds : TRUE
                ELSE db.runs[r].create
ReleaseLeases(p) == [r \in Runs |-> IF rt.leases[r] = p THEN None ELSE rt.leases[r]]
WriteFor(p, mode) == [EmptyWrite EXCEPT
    !.state = "submitted", !.mode = mode, !.owner = p, !.epoch = db.range,
    !.base = op[p].base, !.seen = op[p].seen, !.bv = op[p].bv,
    !.cv = op[p].cv, !.curN = op[p].curN, !.create = op[p].create,
    !.req = op[p].req, !.cut = op[p].cut, !.terminate = op[p].terminate,
    !.events = op[p].built, !.prefix = op[p].prefix,
    !.expected = op[p].expected, !.reapplied = op[p].reapplied,
    !.immediate = op[p].immediate, !.adminEpoch = op[p].adminEpoch]
\* SQL evaluates bypass with the transaction. Cassandra does the read before CAS.
\* sql/execution.go:375-443,492-575; cassandra/mutable_state_store.go:619-740,885-918
MetadataConditions(r) ==
    LET w == pending[r] IN
    /\ w.epoch = db.range
    /\ CASE w.mode \in {"create","start"} ->
                 db.current = None /\ ~Live(r)
          [] w.mode = "base" ->
                 /\ Live(w.base) /\ db.runs[w.base].ver = w.bv
                 /\ IF Backend = "SQL" THEN db.current /= w.base ELSE w.prechecked
          [] OTHER ->
                 /\ Live(w.base) /\ Live(w.seen) /\ ~Live(r)
                 /\ db.current = w.seen
                 /\ db.runs[w.base].ver = w.bv /\ db.runs[w.seen].ver = w.cv
MetadataDB(r) ==
    LET w == pending[r]
        baseRuns == IF w.mode \in {"base","same","distinct"}
                    THEN [db.runs EXCEPT ![w.base] = ChangedRun(w.base,r)] ELSE db.runs
        terminatedRuns == IF w.mode \in {"same","distinct"}
                    THEN [baseRuns EXCEPT ![w.seen].ver = db.runs[w.seen].ver+1,
                          ![w.seen].status = IF w.terminate THEN "terminated" ELSE @,
                          ![w.seen].n = w.curN + (IF w.terminate THEN 1 ELSE 0)] ELSE baseRuns
        newRuns == IF w.mode = "base" THEN terminatedRuns
                   ELSE [terminatedRuns EXCEPT ![r] = NewRun(w.create,w.base,w.cut,w.req,Len(w.events))]
    IN [db EXCEPT !.runs = newRuns,
           !.current = IF w.mode = "base" THEN @ ELSE r]
\* Ghost observers below record actual outcomes; they do not guard implementation actions.
AckGood(p) ==
    LET r == op[p].result IN
    /\ (r \in audit.deleted \/ Live(r))
    /\ (r \in audit.deleted \/ Readable(r,db.runs[r].n))
    /\ IF op[p].kind = "reset" /\ ~op[p].dedup /\ r \notin audit.deleted THEN
           /\ db.runs[r].base = op[p].base /\ db.runs[r].cut = op[p].cut
           /\ Prefix(History(r),op[p].cut) = op[p].prefix
       ELSE TRUE
\* Independent completeness oracle: derive the CAN chain from durable source
\* histories at captured frontiers, not from the batch/expected/reapplied outputs.
OracleEligible(e, ex) ==
    (e.kind = "Signal" /\ "Signal" \notin ex) \/
    (e.kind = "Admitted" /\ "Update" \notin ex) \/
    (e.kind = "Accepted" /\ e.hasRequest /\ "Update" \notin ex)
OracleEnd(p,r) ==
    IF r = op[p].base THEN op[p].baseN
    ELSE LET f == {x \in SeqSet(op[p].frontier) : x.run = r} IN
         IF f /= {} THEN (CHOOSE x \in f : TRUE).last ELSE db.runs[r].n
RECURSIVE OracleChain(_,_,_,_)
OracleChain(p,r,first,seen) ==
    IF r = None \/ r \in seen THEN <<>>
    ELSE LET last == OracleEnd(p,r)
             events == SubSeq(db.hist[r],first,last)
             required == SelectSeq(events,LAMBDA e : OracleEligible(e,op[p].exclude))
             next == IF last > 0 /\ db.hist[r][last].kind = "CAN"
                     THEN db.hist[r][last].next ELSE None
             observed == {f.run : f \in SeqSet(op[p].frontier)}
         IN required \o
            IF next /= None /\ (Live(next) \/ next \in observed)
            THEN OracleChain(p,next,1,seen \cup {r}) ELSE <<>>
ReapplyGood(p) == IF op[p].kind /= "reset" \/ op[p].dedup \/ op[p].result \in audit.deleted THEN TRUE ELSE
    /\ op[p].reapplied = ReappliedSeq(OracleChain(p,op[p].base,op[p].cut+1,{}))
    /\ op[p].reapplied = ReappliedSeq(op[p].expected)
    /\ SubSeq(History(op[p].result),op[p].cut+2,Len(op[p].built)) = op[p].reapplied
\* A registered branch protects all its own nodes and exact ancestor intervals.
\* history_manager.go:141-202. One event per abstract node; see model-notes.md.
ProtectedBy(r) == ({r} \X (1..HistoryLimit)) \cup SeqSet(db.cells[r])
DeletePlan(r) ==
    LET candidates == ({r} \X (1..HistoryLimit)) \cup SeqSet(db.cells[r])
        protected == UNION {ProtectedBy(b) : b \in db.branches \ {r}}
    IN candidates \ protected

\* service/history/api/startworkflow/api.go:195-253; Scenario 3
StartWorkflowExecution(p, r, id) ==
    \* Control-flow condition: service/history/api/startworkflow/api.go:195-253; Scenario 3
    /\ Free(p)
    \* Control-flow condition: service/history/api/startworkflow/api.go:195-253; Scenario 3
    /\ r \in FreshRuns
    \* Control-flow condition: service/history/api/startworkflow/api.go:195-253; Scenario 3
    /\ Serving /\ rt.currentLock = None
    \* State effect: service/history/api/startworkflow/api.go:195-253; Scenario 3
    /\ op' = ([op EXCEPT ![p] = [EmptyOp EXCEPT !.pc = "start-history", !.kind = "start",
                !.candidate = r, !.create = id, !.built = InitialHistory(r,id)]])
    \* State effect: service/history/api/startworkflow/api.go:195-253; Scenario 3
    /\ rt' = ([rt EXCEPT !.currentLock = p])
    \* State effect: service/history/api/startworkflow/api.go:195-253; Scenario 3
    /\ used' = (used \cup {r})
    /\ UNCHANGED <<db, pending, audit, deletion>>

\* service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
ResetWorkflowExecution(p, q, b, cut, ex) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
    /\ Free(p)
    \* Control-flow condition: service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
    /\ Live(b)
    \* Control-flow condition: service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
    /\ cut \in 2..db.runs[b].n /\ db.hist[b][cut].kind = "WFT"
    \* State effect: service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
    /\ op' = ([op EXCEPT ![p] = [EmptyOp EXCEPT !.pc = "base-lease", !.kind = "reset",
                !.req = q, !.base = b, !.cut = cut, !.exclude = ex]])
    \* State effect: service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
    /\ audit' = ([audit EXCEPT !.wanted = @ \cup {q}])
    /\ UNCHANGED <<db, pending, rt, deletion, used>>

\* service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
GetWorkflowLease_Base(p) ==
    \* Snapshot/derived values: service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
    LET b == op[p].base IN
    \* Control-flow condition: service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
    /\ op[p].pc = "base-lease" /\ Serving
    \* Control-flow condition: service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
    /\ Unlocked(op[p].base)
    \* State effect: service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
    /\ op' = ([op EXCEPT ![p].pc = IF Live(b) THEN "lookup" ELSE "release-error",
            ![p].err = IF Live(b) THEN None ELSE "NotFound", ![p].bv = db.runs[b].ver,
            ![p].baseN = db.runs[b].n, ![p].originalToken = b])
    \* State effect: service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
    /\ rt' = ([rt EXCEPT !.leases[b] = p])
    /\ UNCHANGED <<db, pending, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:86-122; workflow/cache/cache.go:465-490
GetCurrentWorkflowRunID(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:86-122; workflow/cache/cache.go:465-490
    /\ op[p].pc = "lookup" /\ Serving
    \* Control-flow condition: service/history/api/resetworkflow/api.go:86-122; workflow/cache/cache.go:465-490
    /\ rt.currentLock = None
    \* State effect: service/history/api/resetworkflow/api.go:86-122; workflow/cache/cache.go:465-490
    /\ op' = ([op EXCEPT ![p].seen = db.current, ![p].pc = "current-lease"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:101-126
GetWorkflowLease_Current(p) ==
    \* Snapshot/derived values: service/history/api/resetworkflow/api.go:101-126
    LET c == op[p].seen IN
    \* Control-flow condition: service/history/api/resetworkflow/api.go:101-126
    /\ op[p].pc = "current-lease" /\ Serving
    \* Control-flow condition: service/history/api/resetworkflow/api.go:101-126
    /\ IF c = None THEN TRUE ELSE rt.leases[c] \in {None,p}
    \* State effect: service/history/api/resetworkflow/api.go:101-126
    /\ op' = ([op EXCEPT ![p].pc = IF c = None \/ Live(c) THEN "dedup" ELSE "release-error",
            ![p].err = IF c = None \/ Live(c) THEN None ELSE "NotFound",
            ![p].cv = IF c = None THEN 0 ELSE db.runs[c].ver,
            ![p].curN = IF c = None THEN 0 ELSE db.runs[c].n])
    \* State effect: service/history/api/resetworkflow/api.go:101-126
    /\ rt' = (IF c = None THEN rt ELSE [rt EXCEPT !.leases[c] = p])
    /\ UNCHANGED <<db, pending, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:124-136; Scenario 1
Invoke_Deduplicate(p) ==
    \* Snapshot/derived values: service/history/api/resetworkflow/api.go:124-136; Scenario 1
    LET c == op[p].seen
        hit == IF c = None THEN FALSE ELSE db.runs[c].create = op[p].req IN
    \* Control-flow condition: service/history/api/resetworkflow/api.go:124-136; Scenario 1
    /\ op[p].pc = "dedup"
    \* State effect: service/history/api/resetworkflow/api.go:124-136; Scenario 1
    /\ op' = ([op EXCEPT ![p].dedup = hit, ![p].result = IF hit THEN c ELSE None,
            ![p].pc = IF hit THEN "server-success" ELSE "allocate"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:136-148; Scenario 1
Invoke_NewRunID(p, r) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:136-148; Scenario 1
    /\ op[p].pc = "allocate"
    \* Control-flow condition: service/history/api/resetworkflow/api.go:136-148; Scenario 1
    /\ r \in FreshRuns
    \* State effect: service/history/api/resetworkflow/api.go:136-148; Scenario 1
    /\ op' = ([op EXCEPT ![p].candidate = r, ![p].pc = "prepare"])
    \* State effect: service/history/api/resetworkflow/api.go:136-148; Scenario 1
    /\ used' = (used \cup {r})
    /\ UNCHANGED <<db, pending, rt, audit, deletion>>

\* service/history/ndc/workflow_resetter.go:132-228,230-247
ResetWorkflow_UpdateResetRunID(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:132-228,230-247
    LET c == op[p].seen IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:132-228,230-247
    /\ op[p].pc = "prepare"
    \* State effect: service/history/ndc/workflow_resetter.go:132-228,230-247
    /\ op' = ([op EXCEPT ![p].localLink = op[p].candidate,
            ![p].terminate = IF c = None THEN FALSE ELSE db.runs[c].status = "running",
            ![p].create = FindStart(op[p].base), ![p].callback = FindStart(op[p].base),
            ![p].pc = "fork"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120
ForkHistoryBranch(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120
    LET r == op[p].candidate IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120
    /\ op[p].pc = "fork" /\ Serving
    \* State effect: service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120
    /\ db' = ([db EXCEPT !.branches = @ \cup {r},
            !.hist[r] = Prefix(db.hist[op[p].base],op[p].cut),
            !.cells[r] = Prefix(db.cells[op[p].base],op[p].cut)])
    \* State effect: service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120
    /\ op' = ([op EXCEPT ![p].prefixToken = r, ![p].pc = "rebuild"])
    /\ UNCHANGED <<pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:545-565; state_rebuilder.go:402-410; workflow/mutable_state_impl.go:3106-3123
Rebuild(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:545-565; state_rebuilder.go:402-410; workflow/mutable_state_impl.go:3106-3123
    LET pre == Prefix(db.hist[op[p].base],op[p].cut)
        ok == Readable(op[p].base,op[p].cut) IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:545-565; state_rebuilder.go:402-410; workflow/mutable_state_impl.go:3106-3123
    /\ op[p].pc = "rebuild"
    \* State effect: service/history/ndc/workflow_resetter.go:545-565; state_rebuilder.go:402-410; workflow/mutable_state_impl.go:3106-3123
    /\ op' = ([op EXCEPT ![p].prefix = pre,
            ![p].built = Append(pre,BlankEvent(op[p].candidate,op[p].cut+1,"ResetWFT")),
            ![p].updateIds = EventIDs(pre), ![p].scan = op[p].base,
            ![p].index = op[p].cut+1, ![p].end = op[p].baseN,
            ![p].visited = <<op[p].base>>,
            ![p].pc = IF ok THEN "read-branch" ELSE "release-error",
            ![p].err = IF ok THEN None ELSE "DataLoss"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:139-142,749-768,865-882; Scenario 4
ReadHistoryBranch(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:139-142,749-768,865-882; Scenario 4
    LET r == op[p].scan
        allExcluded == op[p].exclude = {"Signal","Update"}
        suffix == IF allExcluded THEN <<>> ELSE SubSeq(db.hist[r],op[p].index,op[p].end)
        ok == Readable(r,op[p].end) IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:139-142,749-768,865-882; Scenario 4
    /\ op[p].pc = "read-branch"
    \* State effect: service/history/ndc/workflow_resetter.go:139-142,749-768,865-882; Scenario 4
    /\ op' = ([op EXCEPT
            ![p].batch = suffix, ![p].input = @ \o suffix,
            ![p].expected = @ \o FilterEligible(suffix,op[p].exclude),
            ![p].frontier = Append(@,[run |-> r, first |-> op[p].index, last |-> op[p].end]),
            ![p].index = 1,
            ![p].pc = IF allExcluded THEN "schedule" ELSE IF ok THEN "reapply" ELSE "release-error",
            ![p].err = IF ok \/ allExcluded THEN None ELSE "DataLoss"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748
ReapplyEvents(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748
    LET e == op[p].batch[op[p].index]
        take == Eligible(e,op[p].exclude)
        isUpdate == e.kind \in {"Accepted","Admitted"}
        collision == take /\ isUpdate /\ e.id \in op[p].updateIds IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748
    /\ op[p].pc = "reapply"
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748
    /\ op[p].index <= Len(op[p].batch)
    \* State effect: service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748
    /\ op' = ([op EXCEPT ![p].index = @+1,
            ![p].built = IF take /\ ~collision THEN Append(@,Reapplied(e)) ELSE @,
            ![p].reapplied = IF take /\ ~collision THEN Append(@,Reapplied(e)) ELSE @,
            ![p].updateIds = IF take /\ isUpdate /\ ~collision THEN @ \cup {e.id} ELSE @,
            ![p].pc = IF collision THEN "release-error" ELSE @,
            ![p].err = IF collision THEN "InternalUpdateCollision" ELSE @])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:904-910
ReapplyEventsFromBranch_NextRun(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:904-910
    LET s == op[p].batch
        next == IF s /= <<>> /\ s[Len(s)].kind = "CAN" THEN s[Len(s)].next ELSE None IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:904-910
    /\ op[p].pc = "reapply"
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:904-910
    /\ op[p].index > Len(op[p].batch)
    \* State effect: service/history/ndc/workflow_resetter.go:904-910
    /\ op' = ([op EXCEPT ![p].scan = next,
            ![p].pc = IF next = None THEN "schedule" ELSE "successor"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:771-828; Scenario 4
GetNextEventIDBranchToken(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:771-828; Scenario 4
    LET r == op[p].scan IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:771-828; Scenario 4
    /\ op[p].pc = "successor" /\ Serving
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:771-828; Scenario 4
    /\ rt.leases[r] \in {None,p}
    \* State effect: service/history/ndc/workflow_resetter.go:771-828; Scenario 4
    /\ op' = ([op EXCEPT ![p].pc = IF Live(r) THEN "read-branch" ELSE "schedule",
            ![p].index = 1, ![p].end = IF Live(r) THEN db.runs[r].n ELSE 0,
            ![p].visited = IF Live(r) THEN Append(@,r) ELSE @])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:258-280,376-425
ScheduleWorkflowTask(p) ==
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:258-280,376-425
    /\ op[p].pc = "schedule"
    \* State effect: service/history/ndc/workflow_resetter.go:258-280,376-425
    /\ op' = ([op EXCEPT ![p].pc = IF op[p].seen = None THEN "submit-base" ELSE "submit-atomic"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
UpdateWorkflowExecution_BypassCurrent(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
    LET r == op[p].candidate IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].pc = "submit-base" /\ Serving
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
    /\ pending' = ([pending EXCEPT ![r] = WriteFor(p,"base")])
    \* State effect: service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
    /\ rt' = ([rt EXCEPT !.io = @ \cup {r}])
    \* State effect: service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
    /\ op' = ([op EXCEPT ![p].pc = "write-wait"])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
CreateWorkflowExecution_BrandNew(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    LET r == op[p].candidate IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].pc = "submit-create" /\ Serving
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ pending' = ([pending EXCEPT ![r] = WriteFor(p,"create")])
    \* State effect: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ rt' = ([rt EXCEPT !.io = @ \cup {r}])
    \* State effect: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ op' = ([op EXCEPT ![p].pc = "write-wait"])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
UpdateWorkflowExecution_WithNew(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    LET r == op[p].candidate IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].pc = "submit-atomic" /\ Serving
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    /\ Cardinality(rt.io) < Slots
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].seen = op[p].base
    \* State effect: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    /\ pending' = ([pending EXCEPT ![r] = WriteFor(p,"same")])
    \* State effect: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    /\ rt' = ([rt EXCEPT !.io = @ \cup {r}])
    \* State effect: service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
    /\ op' = ([op EXCEPT ![p].pc = "write-wait"])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
ConflictResolveWorkflowExecution(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    LET r == op[p].candidate IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].pc = "submit-atomic" /\ Serving
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    /\ Cardinality(rt.io) < Slots
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].seen /= op[p].base
    \* State effect: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    /\ pending' = ([pending EXCEPT ![r] = WriteFor(p,"distinct")])
    \* State effect: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    /\ rt' = ([rt EXCEPT !.io = @ \cup {r}])
    \* State effect: service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
    /\ op' = ([op EXCEPT ![p].pc = "write-wait"])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
CreateWorkflowExecution_Start(p) ==
    \* Snapshot/derived values: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    LET r == op[p].candidate IN
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ op[p].pc = "start-history" /\ Serving
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ pending' = ([pending EXCEPT ![r] = WriteFor(p,"start")])
    \* State effect: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ rt' = ([rt EXCEPT !.io = @ \cup {r}])
    \* State effect: service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
    /\ op' = ([op EXCEPT ![p].pc = "write-wait"])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
\* Issuance runs in the live caller; only issued datastore work survives a crash.
\* sql/execution.go:68-85,350-376,474-510; cassandra/execution_store.go:114-148.
CallerPresent(r) ==
    LET p == pending[r].owner IN
    p \in Ops /\ op[p].pc = "write-wait" /\ op[p].candidate = r /\
    pending[r].reply = "waiting"
IssueCurrentHistory(r) ==
    /\ CallerPresent(r) /\ pending[r].state = "submitted"
    /\ pending[r].terminate /\ pending[r].mode \in {"same","distinct"}
    /\ pending' = [pending EXCEPT ![r].state = "current-issued"]
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>
IssueCandidateHistory(r) ==
    /\ CallerPresent(r) /\ pending[r].state \in {"submitted","current-appended"}
    /\ IF pending[r].terminate /\ pending[r].mode \in {"same","distinct"}
       THEN pending[r].state = "current-appended" ELSE TRUE
    /\ pending' = [pending EXCEPT ![r].state = "candidate-issued"]
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>
IssueCurrentRead(r) ==
    /\ CallerPresent(r) /\ pending[r].state = "precheck"
    /\ pending' = [pending EXCEPT ![r].state = "precheck-issued"]
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>
IssueMetadata(r) ==
    /\ CallerPresent(r) /\ pending[r].state = "ready"
    /\ IF Backend = "SQL" THEN MetadataConditions(r) ELSE TRUE
    /\ pending' = [pending EXCEPT ![r].state = "metadata-issued"]
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>

AppendHistoryNodes_Current(r) ==
    \* Snapshot/derived values: common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
    LET w == pending[r]
        currentCells == Prefix(db.cells[w.seen],w.curN) \o << <<w.seen,w.curN+1>> >> IN
    \* Control-flow condition: common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
    /\ pending[r].state = "current-issued"
    \* Control-flow condition: common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
    /\ pending[r].terminate /\ pending[r].mode \in {"same","distinct"}
    \* State effect: common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
    \* A later committed extension has a later transaction ID and wins selection;
    \* appending an older batch never truncates those rows (history_manager.go:1040-1075).
    /\ db' = ([db EXCEPT
            !.hist[w.seen] = IF db.runs[w.seen].n > w.curN THEN @ ELSE
                Append(Prefix(@,w.curN),BlankEvent(w.seen,w.curN+1,"Terminated")),
            !.cells[w.seen] = IF db.runs[w.seen].n > w.curN THEN @ ELSE currentCells,
            !.nodes = @ \cup {<<w.seen,w.curN+1>>}])
    \* State effect: common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
    /\ pending' = ([pending EXCEPT ![r].state = "current-appended"])
    /\ UNCHANGED <<op, rt, audit, deletion, used>>

\* common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
AppendHistoryNodes(r) ==
    \* Snapshot/derived values: common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
    LET w == pending[r]
        newCells == IF w.mode = "start" THEN OwnCells(r,1,Len(w.events))
                    ELSE db.cells[r] \o OwnCells(r,w.cut+1,Len(w.events)) IN
    \* Control-flow condition: common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
    /\ pending[r].state = "candidate-issued"
    \* Control-flow condition: common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
    \* State effect: common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
    /\ db' = (IF w.mode = "base" THEN db ELSE
            [db EXCEPT !.branches = @ \cup {r}, !.hist[r] = w.events,
               !.cells[r] = newCells, !.nodes = @ \cup SeqSet(IF w.mode = "start" THEN newCells ELSE OwnCells(r,w.cut+1,Len(w.events)))])
    \* State effect: common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
    /\ pending' = ([pending EXCEPT ![r].state = IF Backend = "Cassandra" /\ w.mode = "base"
                                                     THEN "precheck" ELSE "ready"])
    /\ UNCHANGED <<op, rt, audit, deletion, used>>

\* service/history/shard/context_impl.go:1518-1520; Scenario 2 history append uncertain, metadata unattempted
PersistenceAppendTimeout(r) ==
    \* Control-flow condition: service/history/shard/context_impl.go:1518-1520; Scenario 2 history append uncertain, metadata unattempted
    /\ pending[r].state \in {"current-issued","candidate-issued","current-appended","ready"}
    \* Control-flow condition: service/history/shard/context_impl.go:1518-1520; Scenario 2 history append uncertain, metadata unattempted
    /\ pending[r].reply = "waiting"
    \* State effect: service/history/shard/context_impl.go:1518-1520; Scenario 2 history append uncertain, metadata unattempted
    /\ pending' = ([pending EXCEPT ![r].state = "rejected", ![r].result = "AppendHistoryTimeout"])
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>

\* common/persistence/cassandra/mutable_state_store.go:619-630,885-918
AssertNotCurrentExecution(r) ==
    \* Control-flow condition: common/persistence/cassandra/mutable_state_store.go:619-630,885-918
    /\ pending[r].state = "precheck-issued"
    \* State effect: common/persistence/cassandra/mutable_state_store.go:619-630,885-918
    /\ pending' = ([pending EXCEPT ![r].prechecked = db.current /= pending[r].base,
            ![r].state = IF db.current /= pending[r].base THEN "ready" ELSE "rejected",
            ![r].result = IF db.current /= pending[r].base THEN None ELSE "Condition"])
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>

\* common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
CommitWorkflowExecution(r) ==
    \* Snapshot/derived values: common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
    LET w == pending[r] IN
    \* Control-flow condition: common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
    /\ pending[r].state = "metadata-issued"
    \* Control-flow condition: common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
    /\ MetadataConditions(r)
    \* State effect: common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
    /\ db' = (MetadataDB(r))
    \* State effect: common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
    /\ pending' = ([pending EXCEPT ![r].state = "committed", ![r].result = "OK"])
    \* State effect: common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
    /\ audit' = ([audit EXCEPT !.commits = @ \cup {
            [run |-> r, mode |-> w.mode, epoch |-> w.epoch, durableEpoch |-> db.range,
             seen |-> w.seen, prior |-> db.current, base |-> w.base]},
            !.retryBad = @ \/ (w.mode /= "base" /\ w.req /= None /\
                               w.immediate /= None /\ w.immediate /= r /\
                               w.adminEpoch = audit.admin[w.req]),
            !.admin = [q \in ResetIDs |-> IF w.mode /= "base" /\ q /= w.req
                                            THEN audit.admin[q]+1 ELSE audit.admin[q]]])
    /\ UNCHANGED <<op, rt, deletion, used>>

\* common/persistence/sql/execution.go:106-124,426-440; sql/execution_util.go:640-661; cassandra/mutable_state_store.go:474-489
RejectWorkflowExecution(r) ==
    \* Control-flow condition: common/persistence/sql/execution.go:106-124,426-440; sql/execution_util.go:640-661; cassandra/mutable_state_store.go:474-489
    /\ pending[r].state = "metadata-issued" \/
       (Backend = "SQL" /\ pending[r].state = "ready" /\ CallerPresent(r))
    \* Control-flow condition: common/persistence/sql/execution.go:106-124,426-440; sql/execution_util.go:640-661; cassandra/mutable_state_store.go:474-489
    /\ ~MetadataConditions(r)
    \* State effect: common/persistence/sql/execution.go:106-124,426-440; sql/execution_util.go:640-661; cassandra/mutable_state_store.go:474-489
    /\ pending' = ([pending EXCEPT ![r].state = "rejected",
            ![r].result = IF pending[r].epoch /= db.range THEN "OwnershipLost" ELSE "Condition"])
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>

\* service/history/shard/context_impl.go:1522-1532; Scenario 2 fault, ResourceExhausted before metadata
PersistenceDefiniteRejection(r) ==
    \* Control-flow condition: service/history/shard/context_impl.go:1522-1532; Scenario 2 fault, ResourceExhausted before metadata
    /\ pending[r].state \in {"submitted","current-appended","precheck","ready"}
    \* Control-flow condition: service/history/shard/context_impl.go:1522-1532; Scenario 2 fault, ResourceExhausted before metadata
    /\ pending[r].reply = "waiting"
    \* State effect: service/history/shard/context_impl.go:1522-1532; Scenario 2 fault, ResourceExhausted before metadata
    /\ pending' = ([pending EXCEPT ![r].state = "rejected", ![r].result = "ResourceExhausted"])
    /\ UNCHANGED <<db, op, rt, audit, deletion, used>>

\* service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
PersistenceUncertainReturn(r) ==
    \* Snapshot/derived values: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    LET p == pending[r].owner IN
    \* Control-flow condition: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    /\ pending[r].state \in {"metadata-issued","committed"}
    \* Control-flow condition: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    /\ pending[r].reply = "waiting"
    \* Control-flow condition: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    /\ r \in rt.io
    \* State effect: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    /\ pending' = ([pending EXCEPT ![r].reply = "lost"])
    \* State effect: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    /\ rt' = ([rt EXCEPT !.io = @ \ {r}, !.state = IF rt.state = "acquired" /\ db.range = pending[r].epoch THEN "acquiring" ELSE @])
    \* State effect: service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
    /\ op' = ([op EXCEPT ![p].pc = "release-error", ![p].err = "Unavailable"])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
PersistenceReturn(r) ==
    \* Snapshot/derived values: service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
    LET p == pending[r].owner IN
    \* Control-flow condition: service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
    /\ pending[r].state \in {"committed","rejected"}
    \* Control-flow condition: service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
    /\ pending[r].reply = "waiting"
    \* State effect: service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
    /\ pending' = ([pending EXCEPT ![r].reply = "returned"])
    \* State effect: service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
    /\ rt' = ([rt EXCEPT !.io = @ \ {r},
            !.state = IF pending[r].result = "OwnershipLost" THEN "acquiring" ELSE @])
    \* State effect: service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
    /\ op' = ([op EXCEPT ![p].pc = IF pending[r].result /= "OK" THEN "release-error"
                ELSE IF pending[r].mode = "base" THEN "submit-create" ELSE "server-success",
            ![p].result = IF pending[r].result = "OK" THEN r ELSE None,
            ![p].err = IF pending[r].result = "OK" THEN None ELSE pending[r].result])
    /\ UNCHANGED <<db, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:131-134,213-215; service/history/api/startworkflow/api.go:230-236
Invoke_ReturnSuccess(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:131-134,213-215; service/history/api/startworkflow/api.go:230-236
    /\ op[p].pc = "server-success"
    \* State effect: service/history/api/resetworkflow/api.go:131-134,213-215; service/history/api/startworkflow/api.go:230-236
    /\ audit' = ([audit EXCEPT !.acks = @ \cup {[request |-> op[p].req, run |-> op[p].result,
                base |-> op[p].base, kind |-> op[p].kind]},
            !.availableBad = @ \/ ~AckGood(p), !.reapplyBad = @ \/ ~ReapplyGood(p)])
    \* State effect: service/history/api/resetworkflow/api.go:131-134,213-215; service/history/api/startworkflow/api.go:230-236
    /\ op' = ([op EXCEPT ![p].pc = "release-success"])
    /\ UNCHANGED <<db, pending, rt, deletion, used>>

\* service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:390-409
ReleaseWorkflowLease_Success(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:390-409
    /\ op[p].pc = "release-success"
    \* State effect: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:390-409
    /\ rt' = ([rt EXCEPT !.leases = ReleaseLeases(p),
            !.currentLock = IF @ = p THEN None ELSE @])
    \* State effect: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:390-409
    /\ op' = ([op EXCEPT ![p].pc = "response"])
    /\ UNCHANGED <<db, pending, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC client receipt boundary
ReceiveResetResponse(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC client receipt boundary
    /\ op[p].pc = "response"
    \* State effect: service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC client receipt boundary
    /\ audit' = ([audit EXCEPT !.receipts = @ \cup {[request |-> op[p].req, run |-> op[p].result]}])
    \* State effect: service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC client receipt boundary
    /\ op' = ([op EXCEPT ![p].pc = "done"])
    /\ UNCHANGED <<db, pending, rt, deletion, used>>

\* service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC transport fault after success
LoseResetResponse(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC transport fault after success
    /\ op[p].pc = "response"
    \* State effect: service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC transport fault after success
    /\ op' = ([op EXCEPT ![p].pc = "retry", ![p].err = "ResponseLost"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:43,124-136; Scenario 1 explicit identical client replay
ReplayResetRequest(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:43,124-136; Scenario 1 explicit identical client replay
    /\ op[p].pc = "done" /\ op[p].kind = "reset"
    \* State effect: service/history/api/resetworkflow/api.go:43,124-136; Scenario 1 explicit identical client replay
    /\ op' = ([op EXCEPT ![p].pc = "retry"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298
ReleaseWorkflowLease_Error(p) ==
    \* Control-flow condition: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298
    /\ op[p].pc = "release-error"
    \* State effect: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298
    /\ rt' = ([rt EXCEPT !.leases = ReleaseLeases(p),
            !.currentLock = IF @ = p THEN None ELSE @])
    \* State effect: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298
    /\ op' = ([op EXCEPT ![p].pc = IF op[p].kind = "start" \/ op[p].err \in {"NotFound","DataLoss","InternalUpdateCollision","RequestTimeout"}
                                            THEN "done" ELSE "retry"])
    \* State effect: service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298
    /\ audit' = ([audit EXCEPT !.terminal = IF op[p].err = "NotFound" THEN @ \cup {op[p].req} ELSE @])
    /\ UNCHANGED <<db, pending, deletion, used>>

\* common/rpc/interceptor/retry.go:36-44; service/history/handler.go:2291-2298; Scenarios 1-3
RetryResetWorkflowExecution(p) ==
    \* Snapshot/derived values: common/rpc/interceptor/retry.go:36-44; service/history/handler.go:2291-2298; Scenarios 1-3
    LET old == op[p] IN
    \* Control-flow condition: common/rpc/interceptor/retry.go:36-44; service/history/handler.go:2291-2298; Scenarios 1-3
    /\ op[p].pc = "retry" /\ op[p].kind = "reset" /\ Serving
    \* State effect: common/rpc/interceptor/retry.go:36-44; service/history/handler.go:2291-2298; Scenarios 1-3
    /\ op' = ([op EXCEPT ![p] = [EmptyOp EXCEPT !.pc = "base-lease", !.kind = "reset",
            !.req = old.req, !.base = old.base, !.cut = old.cut, !.exclude = old.exclude,
            !.immediate = IF db.current /= None /\ Live(db.current) /\
                               db.runs[db.current].resetReq = old.req
                         THEN db.current ELSE None, !.adminEpoch = audit.admin[old.req]]])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
CrashHistoryService ==
    \* Control-flow condition: service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
    /\ rt.state /= "stopped"
    \* State effect: service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
    /\ rt' = ([rt EXCEPT !.state = "stopped", !.leases = [r \in Runs |-> None],
            !.currentLock = None, !.io = {}])
    \* State effect: service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
    /\ op' = ([p \in Ops |-> IF Active(p) THEN [op[p] EXCEPT
            !.pc = IF op[p].kind = "reset" THEN "retry" ELSE "done", !.err = "ProcessLost"] ELSE op[p]])
    \* State effect: service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
    /\ pending' = ([r \in Runs |-> IF pending[r].state /= "empty" /\ pending[r].reply = "waiting"
            THEN [pending[r] EXCEPT !.reply = "lost"] ELSE pending[r]])
    \* State effect: service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
    /\ deletion' = ([r \in Runs |-> IF deletion[r].stage \in {"admit","current","mutable","plan","delete"}
            THEN [deletion[r] EXCEPT !.stage = IF Live(r) THEN "queued" ELSE "orphan"] ELSE deletion[r]])
    /\ UNCHANGED <<db, audit, used>>

\* service/history/shard/context_impl.go:1164-1207,2074-2097; Scenario 2 RangeID fence
\* handleWriteErrorLocked can begin reacquisition before releasing its I/O slot.
BeginAcquireShard ==
    /\ rt.state = "stopped" \/
       (rt.state = "acquired" /\ \E r \in rt.io :
          pending[r].state \in {"metadata-issued","committed"} /\ pending[r].epoch = db.range)
    /\ rt' = [rt EXCEPT !.state = "acquiring"]
    /\ UNCHANGED <<db, op, pending, audit, deletion, used>>

\* renewRangeLocked drains task requests, not ioSemaphore, then commits UpdateShard.
RenewShardRange ==
    /\ rt.state = "acquiring" /\ db.range = rt.epoch
    /\ db' = [db EXCEPT !.range = @+1]
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

AcquireShard ==
    /\ rt.state = "acquiring" /\ db.range > rt.epoch
    /\ rt' = [rt EXCEPT !.state = "acquired", !.epoch = db.range]
    /\ UNCHANGED <<db, op, pending, audit, deletion, used>>

\* client/history/client_gen.go:1049-1055; client/history/client.go:33-34,290-291; service/history/shard/context_impl.go:2414-2427; Scenario 5
ExpireResetRequest(p) ==
    \* Control-flow condition: client/history/client_gen.go:1049-1055; client/history/client.go:33-34,290-291; service/history/shard/context_impl.go:2414-2427; Scenario 5
    /\ op[p].kind = "reset"
    \* Control-flow condition: client/history/client_gen.go:1049-1055; client/history/client.go:33-34,290-291; service/history/shard/context_impl.go:2414-2427; Scenario 5
    /\ op[p].pc \in {"allocate","prepare","fork","rebuild","read-branch","reapply","successor","schedule","submit-base","submit-create","submit-atomic"}
    \* State effect: client/history/client_gen.go:1049-1055; client/history/client.go:33-34,290-291; service/history/shard/context_impl.go:2414-2427; Scenario 5
    /\ op' = ([op EXCEPT ![p].pc = "release-error", ![p].err = "RequestTimeout"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/ndc/workflow_resetter.go:796-819,875-882; Scenario 4 read error must not truncate
ReadTransientFailure(p) ==
    \* Control-flow condition: service/history/ndc/workflow_resetter.go:796-819,875-882; Scenario 4 read error must not truncate
    /\ op[p].pc \in {"lookup","successor","read-branch","rebuild","fork"}
    \* State effect: service/history/ndc/workflow_resetter.go:796-819,875-882; Scenario 4 read error must not truncate
    /\ op' = ([op EXCEPT ![p].pc = "release-error", ![p].err = "Unavailable"])
    /\ UNCHANGED <<db, pending, rt, audit, deletion, used>>

\* service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
\* First CAN task backoff: timer_queue_active_task_executor.go:530-537.
\* The scheduled event is outside the history projection; its metadata commit
\* changes the record version and makes the first task available exactly once.
PersistFirstWorkflowTaskSchedule(r) ==
    /\ Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
    /\ ~db.runs[r].firstTaskScheduled /\ Cardinality(rt.io) < Slots
    /\ db' = [db EXCEPT !.runs[r].ver = @+1, !.runs[r].firstTaskScheduled = TRUE]
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

AddWorkflowTaskStartedEvent(r) ==
    \* Snapshot/derived values: service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
    LET n == db.runs[r].n+1 IN
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
    /\ Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
    /\ Cardinality(rt.io) < Slots
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
    /\ db.runs[r].firstTaskScheduled
    /\ (~\E e \in SeqSet(History(r)) : e.kind = "WFT") \/ (\E i \in 1..db.runs[r].n : db.hist[r][i].kind \in {"Completed","ResetWFT"} /\ \A j \in (i+1)..db.runs[r].n : db.hist[r][j].kind /= "WFT")
    \* State effect: service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
    /\ db' = ([db EXCEPT !.hist[r] = Append(History(r),BlankEvent(r,n,"WFT")),
            !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>),
            !.nodes = @ \cup {<<r,n>>}, !.runs[r].n = n, !.runs[r].ver = @+1])
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

\* service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
AddWorkflowExecutionUpdateAcceptedEvent(r, id, payload) ==
    \* Snapshot/derived values: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    LET n == db.runs[r].n+1
        e == Evt(r,n,"Accepted",id,payload,TRUE,None) IN
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    /\ Serving /\ Live(r) /\ db.current = r /\ Unlocked(r)
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    /\ db.runs[r].status = "running"
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    /\ id \notin EventIDs(History(r))
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    /\ Cardinality(rt.io) < Slots
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    /\ \E priorEvent \in SeqSet(History(r)) : priorEvent.kind \in {"WFT","ResetWFT"}
    \* State effect: service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
    /\ db' = ([db EXCEPT !.hist[r] = Append(History(r),e),
            !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>), !.nodes = @ \cup {<<r,n>>},
            !.runs[r].n = n, !.runs[r].ver = @+1])
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

\* service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
AddWorkflowExecutionUpdateCompletedEvent(r, id) ==
    \* Snapshot/derived values: service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
    LET n == db.runs[r].n+1 IN
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
    /\ Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
    /\ id \in EventIDs(History(r))
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
    /\ ~\E e \in SeqSet(History(r)) : e.kind = "Completed" /\ e.id = id
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
    /\ db' = ([db EXCEPT !.hist[r] = History(r) \o
               <<Evt(r,n,"Completed",id,None,FALSE,None)>>,
            !.cells[r] = Prefix(@,db.runs[r].n) \o << <<r,n>> >>,
            !.nodes = @ \cup {<<r,n>>}, !.runs[r].n = n, !.runs[r].ver = @+1])
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

\* service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4
AddWorkflowExecutionSignaled(r, id, payload) ==
    \* Snapshot/derived values: service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4
    LET n == db.runs[r].n+1 IN
    \* Control-flow condition: service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4
    /\ Serving /\ Live(r) /\ db.current = r /\ Unlocked(r) /\ db.runs[r].status = "running"
    \* Control-flow condition: service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4
    /\ db' = ([db EXCEPT !.hist[r] = Append(History(r),Evt(r,n,"Signal",id,payload,TRUE,None)),
            !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>),
            !.nodes = @ \cup {<<r,n>>}, !.runs[r].n = n, !.runs[r].ver = @+1])
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

\* service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
ContinueAsNew(r, s, id) ==
    \* Snapshot/derived values: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    LET n == db.runs[r].n+1 IN
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ Serving /\ Live(r) /\ db.current = r /\ Unlocked(r)
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ s \in FreshRuns /\ db.runs[r].status = "running"
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ Cardinality(rt.io) < Slots
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ \E priorEvent \in SeqSet(History(r)) : priorEvent.kind \in {"WFT","ResetWFT"}
    \* State effect: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ db' = ([db EXCEPT !.runs[r].status = "can", !.runs[r].can = s,
            !.runs[r].ver = @+1, !.runs[r].n = n,
            !.hist[r] = Append(History(r),Evt(r,n,"CAN",None,None,FALSE,s)),
            !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>),
            !.runs[s] = [NewRun(id,None,0,None,1) EXCEPT !.firstTaskScheduled = FALSE], !.hist[s] = InitialHistory(s,id),
            !.cells[s] = OwnCells(s,1,1), !.branches = @ \cup {s},
            !.nodes = @ \cup {<<r,n>>,<<s,1>>}, !.current = s])
    \* State effect: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ used' = (used \cup {s})
    \* State effect: service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
    /\ audit' = ([audit EXCEPT !.admin = [q \in ResetIDs |-> audit.admin[q]+1]])
    /\ UNCHANGED <<op, pending, rt, deletion>>

\* service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability
CompleteWorkflowExecution(r) ==
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability
    /\ Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability
    /\ Readable(r,db.runs[r].n) /\ Cardinality(rt.io) < Slots
    \* Control-flow condition: service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability
    /\ \E priorEvent \in SeqSet(History(r)) : priorEvent.kind \in {"WFT","ResetWFT"}
    \* State effect: service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability
    /\ db' = ([db EXCEPT !.runs[r].status = "completed", !.runs[r].ver = @+1])
    /\ UNCHANGED <<op, pending, rt, audit, deletion, used>>

\* service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
DeleteWorkflowExecution(r) ==
    \* Control-flow condition: service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
    /\ Serving /\ Live(r) /\ Unlocked(r)
    \* Control-flow condition: service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
    /\ deletion[r].stage = "none"
    \* Control-flow condition: service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
    /\ db' = (IF db.runs[r].status /= "running" THEN db ELSE
            [db EXCEPT !.runs[r].status = "terminated", !.runs[r].ver = @+1,
             !.hist[r] = Append(History(r),BlankEvent(r,db.runs[r].n+1,"Terminated")),
             !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,db.runs[r].n+1>>),
             !.nodes = @ \cup {<<r,db.runs[r].n+1>>}, !.runs[r].n = @+1])
    \* State effect: service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
    /\ deletion' = ([deletion EXCEPT ![r].stage = "queued"])
    \* State effect: service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
    /\ audit' = ([audit EXCEPT !.deleted = @ \cup {r}, !.admin = [q \in ResetIDs |-> audit.admin[q]+1]])
    /\ UNCHANGED <<op, pending, rt, used>>

\* service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937
DeleteExecutionTask(r) ==
    \* Control-flow condition: service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937
    /\ Serving /\ deletion[r].stage = "queued" /\ Live(r) /\ Unlocked(r)
    \* Control-flow condition: service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937
    /\ db.runs[r].status /= "running"
    \* State effect: service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937
    /\ rt' = ([rt EXCEPT !.leases[r] = "deletion"])
    \* State effect: service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937
    /\ deletion' = ([deletion EXCEPT ![r].stage = "admit"])
    /\ UNCHANGED <<db, op, pending, audit, used>>

\* service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3
DeleteWorkflowExecution_AcquireIO(r) ==
    \* Control-flow condition: service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3
    /\ Serving /\ deletion[r].stage = "admit" /\ rt.leases[r] = "deletion"
    \* Control-flow condition: service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3
    /\ Cardinality(rt.io) < Slots
    \* State effect: service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3
    /\ rt' = ([rt EXCEPT !.io = @ \cup {r}])
    \* State effect: service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3
    /\ deletion' = ([deletion EXCEPT ![r].stage = "current", ![r].epoch = db.range])
    /\ UNCHANGED <<db, op, pending, audit, used>>

\* service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955
DeleteCurrentWorkflowExecution(r) ==
    \* Control-flow condition: service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955
    /\ Serving /\ deletion[r].stage = "current"
    \* Control-flow condition: service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955
    /\ rt.leases[r] = "deletion" /\ r \in rt.io
    \* State effect: service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955
    /\ db' = ([db EXCEPT !.current = IF @ = r THEN None ELSE @])
    \* State effect: service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955
    /\ deletion' = ([deletion EXCEPT ![r].stage = "mutable"])
    /\ UNCHANGED <<op, pending, rt, audit, used>>

\* service/history/shard/context_impl.go:1063-1083
DeleteWorkflowMutableState(r) ==
    \* Control-flow condition: service/history/shard/context_impl.go:1063-1083
    /\ Serving /\ deletion[r].stage = "mutable"
    \* Control-flow condition: service/history/shard/context_impl.go:1063-1083
    /\ rt.leases[r] = "deletion" /\ r \in rt.io
    \* State effect: service/history/shard/context_impl.go:1063-1083
    /\ db' = ([db EXCEPT !.runs[r].exists = FALSE])
    \* State effect: service/history/shard/context_impl.go:1063-1083
    /\ deletion' = ([deletion EXCEPT ![r].stage = "plan"])
    \* State effect: service/history/shard/context_impl.go:1063-1083
    /\ rt' = ([rt EXCEPT !.io = @ \ {r}])
    /\ UNCHANGED <<op, pending, audit, used>>

\* common/persistence/history_manager.go:150-208; Scenario 5 reference snapshot separate from deletion
GetHistoryTreeContainingBranch(r) ==
    \* Control-flow condition: common/persistence/history_manager.go:150-208; Scenario 5 reference snapshot separate from deletion
    /\ deletion[r].stage = "plan"
    \* State effect: common/persistence/history_manager.go:150-208; Scenario 5 reference snapshot separate from deletion
    /\ deletion' = ([deletion EXCEPT ![r].plan = DeletePlan(r), ![r].stage = "delete"])
    /\ UNCHANGED <<db, op, pending, rt, audit, used>>

\* common/persistence/sql/history_store.go:347-376
DeleteHistoryBranch_SQL(r) ==
    \* Control-flow condition: common/persistence/sql/history_store.go:347-376
    /\ Backend = "SQL" /\ deletion[r].stage = "delete"
    \* State effect: common/persistence/sql/history_store.go:347-376
    /\ db' = ([db EXCEPT !.branches = @ \ {r}, !.nodes = @ \ deletion[r].plan])
    \* State effect: common/persistence/sql/history_store.go:347-376
    /\ deletion' = ([deletion EXCEPT ![r].stage = "done"])
    \* State effect: common/persistence/sql/history_store.go:347-376
    /\ rt' = ([rt EXCEPT !.leases[r] = IF @ = "deletion" THEN None ELSE @])
    /\ UNCHANGED <<op, pending, audit, used>>

\* common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility
DeleteHistoryBranch_CassandraRow(r) ==
    \* Control-flow condition: common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility
    /\ Backend = "Cassandra" /\ deletion[r].stage \in {"delete","ranges-first"}
    \* State effect: common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility
    /\ db' = ([db EXCEPT !.branches = @ \ {r}])
    \* State effect: common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility
    /\ deletion' = ([deletion EXCEPT ![r].stage = IF @ = "ranges-first" THEN "done" ELSE "row-first"])
    \* State effect: common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility
    /\ rt' = ([rt EXCEPT !.leases[r] = IF deletion[r].stage = "ranges-first" /\ @ = "deletion" THEN None ELSE @])
    /\ UNCHANGED <<op, pending, audit, used>>

\* common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges
DeleteHistoryBranch_CassandraRanges(r) ==
    \* Control-flow condition: common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges
    /\ Backend = "Cassandra" /\ deletion[r].stage \in {"delete","row-first"}
    \* State effect: common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges
    /\ db' = ([db EXCEPT !.nodes = @ \ deletion[r].plan])
    \* State effect: common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges
    /\ deletion' = ([deletion EXCEPT ![r].stage = IF @ = "row-first" THEN "done" ELSE "ranges-first"])
    \* State effect: common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges
    /\ rt' = ([rt EXCEPT !.leases[r] = IF deletion[r].stage = "row-first" /\ @ = "deletion" THEN None ELSE @])
    /\ UNCHANGED <<op, pending, audit, used>>

\* service/worker/scanner/history/scavenger.go:202-211; common/dynamicconfig/constants.go:3549-3553; client/history/client.go:33-34,290-291
HistoryScannerAge(r) ==
    \* Control-flow condition: service/worker/scanner/history/scavenger.go:202-211; common/dynamicconfig/constants.go:3549-3553; client/history/client.go:33-34,290-291
    /\ r \in db.branches /\ ~deletion[r].aged
    \* Control-flow condition: service/worker/scanner/history/scavenger.go:202-211; common/dynamicconfig/constants.go:3549-3553; client/history/client.go:33-34,290-291
    /\ ~ScannerAfterRequestDeadline \/ (\A p \in Ops : op[p].candidate = r => ~Active(p))
    \* State effect: service/worker/scanner/history/scavenger.go:202-211; common/dynamicconfig/constants.go:3549-3553; client/history/client.go:33-34,290-291
    /\ deletion' = ([deletion EXCEPT ![r].aged = TRUE])
    /\ UNCHANGED <<db, op, pending, rt, audit, used>>

\* service/worker/scanner/history/scavenger.go:252-286; Scenario 5 NotFound only, not temporary error
HistoryScavengerVerify(r) ==
    \* Control-flow condition: service/worker/scanner/history/scavenger.go:252-286; Scenario 5 NotFound only, not temporary error
    /\ Serving /\ r \in db.branches /\ deletion[r].aged
    \* Control-flow condition: service/worker/scanner/history/scavenger.go:252-286; Scenario 5 NotFound only, not temporary error
    /\ ~Live(r) /\ deletion[r].stage \in {"none","orphan"}
    \* State effect: service/worker/scanner/history/scavenger.go:252-286; Scenario 5 NotFound only, not temporary error
    /\ deletion' = ([deletion EXCEPT ![r].stage = "plan", ![r].scanner = TRUE])
    /\ UNCHANGED <<db, op, pending, rt, audit, used>>

\* Core/structural invariants. No resetLink -> existingRun assertion is present.
CurrentExecutionConsistency ==
    /\ (db.current = None \/ Live(db.current))
    /\ \A c \in audit.commits : c.mode \in {"base","create","start"} \/ c.prior = c.seen
FencedOldAttempt == \A c \in audit.commits : c.epoch = c.durableEpoch
AcknowledgedResetExists == ~audit.availableBad /\ ~audit.reapplyBad
ImmediateRetryIdentity == ~audit.retryBad
ReapplyProvenance == ~audit.reapplyBad
ReachableHistoryRetained ==
    \A a \in audit.acks : (a.kind = "reset" /\ Live(a.run) /\ a.run \notin audit.deleted)
                           => Readable(a.run,db.runs[a.run].n)
CallbackSourceIdentity == \A r \in Runs : Live(r) =>
    /\ db.runs[r].create = db.runs[r].callback
    /\ db.runs[r].callback = db.hist[r][1].id
TypeOK ==
    /\ DOMAIN db.runs = Runs /\ DOMAIN op = Ops /\ DOMAIN pending = Runs
    /\ db.current \in Runs \cup {None} /\ db.range \in Nat \ {0}
    /\ db.branches \subseteq Runs /\ used \subseteq Runs
    /\ rt.state \in {"acquired","acquiring","stopped"} /\ rt.io \subseteq Runs
    /\ \A r \in Runs :
          /\ db.runs[r].exists \in BOOLEAN /\ db.runs[r].ver \in Nat
          /\ db.runs[r].n \in 0..Len(db.hist[r])
          /\ db.runs[r].link \in Runs \cup {None}
          /\ db.runs[r].can \in Runs \cup {None}
          /\ rt.leases[r] \in Ops \cup {None,"deletion"}
          /\ db.hist[r] \in Seq([origin : Runs, number : Nat, kind : Kinds,
               id : StartIDs \cup ResetIDs \cup UpdateIDs \cup {None},
               payload : Payloads \cup {None}, hasRequest : BOOLEAN,
               next : Runs \cup {None}, version : {1}])
          /\ Len(db.cells[r]) >= db.runs[r].n
IOCapacity == Cardinality(rt.io) <= Slots
LeaseOwnership == \A p \in Ops : op[p].pc = "dedup" => rt.leases[op[p].base] = p
HistoryBound == \A r \in Runs : Len(db.hist[r]) <= HistoryLimit
RunIDExhausted == FreshRuns = {} /\ \E p \in Ops : op[p].pc = "allocate"
\* The property must not classify repeated unexplained Internal as a terminal rejection.
\* Fairness/retention/healthy-database assumptions belong in the MC liveness spec.
HealthyRetryRecovers == \A q \in ResetIDs :
    (q \in audit.wanted) ~> (q \in audit.terminal \/
       \E a \in audit.acks : a.request = q /\ a.kind = "reset")

Next ==
    \/ \E r \in Runs : IssueCurrentHistory(r)
    \/ \E r \in Runs : IssueCandidateHistory(r)
    \/ \E r \in Runs : IssueCurrentRead(r)
    \/ \E r \in Runs : IssueMetadata(r)
    \/ BeginAcquireShard
    \/ RenewShardRange
    \/ \E r \in Runs : PersistFirstWorkflowTaskSchedule(r)
    \/ \E p \in Ops, r \in Runs, id \in StartIDs : StartWorkflowExecution(p, r, id)
    \/ \E p \in Ops, q \in ResetIDs, b \in Runs, cut \in 2..HistoryLimit, ex \in SUBSET {"Signal","Update"} : ResetWorkflowExecution(p, q, b, cut, ex)
    \/ \E p \in Ops : GetWorkflowLease_Base(p)
    \/ \E p \in Ops : GetCurrentWorkflowRunID(p)
    \/ \E p \in Ops : GetWorkflowLease_Current(p)
    \/ \E p \in Ops : Invoke_Deduplicate(p)
    \/ \E p \in Ops, r \in Runs : Invoke_NewRunID(p, r)
    \/ \E p \in Ops : ResetWorkflow_UpdateResetRunID(p)
    \/ \E p \in Ops : ForkHistoryBranch(p)
    \/ \E p \in Ops : Rebuild(p)
    \/ \E p \in Ops : ReadHistoryBranch(p)
    \/ \E p \in Ops : ReapplyEvents(p)
    \/ \E p \in Ops : ReapplyEventsFromBranch_NextRun(p)
    \/ \E p \in Ops : GetNextEventIDBranchToken(p)
    \/ \E p \in Ops : ScheduleWorkflowTask(p)
    \/ \E p \in Ops : UpdateWorkflowExecution_BypassCurrent(p)
    \/ \E p \in Ops : CreateWorkflowExecution_BrandNew(p)
    \/ \E p \in Ops : UpdateWorkflowExecution_WithNew(p)
    \/ \E p \in Ops : ConflictResolveWorkflowExecution(p)
    \/ \E p \in Ops : CreateWorkflowExecution_Start(p)
    \/ \E r \in Runs : AppendHistoryNodes_Current(r)
    \/ \E r \in Runs : AppendHistoryNodes(r)
    \/ \E r \in Runs : PersistenceAppendTimeout(r)
    \/ \E r \in Runs : AssertNotCurrentExecution(r)
    \/ \E r \in Runs : CommitWorkflowExecution(r)
    \/ \E r \in Runs : RejectWorkflowExecution(r)
    \/ \E r \in Runs : PersistenceDefiniteRejection(r)
    \/ \E r \in Runs : PersistenceUncertainReturn(r)
    \/ \E r \in Runs : PersistenceReturn(r)
    \/ \E p \in Ops : Invoke_ReturnSuccess(p)
    \/ \E p \in Ops : ReleaseWorkflowLease_Success(p)
    \/ \E p \in Ops : ReceiveResetResponse(p)
    \/ \E p \in Ops : LoseResetResponse(p)
    \/ \E p \in Ops : ReplayResetRequest(p)
    \/ \E p \in Ops : ReleaseWorkflowLease_Error(p)
    \/ \E p \in Ops : RetryResetWorkflowExecution(p)
    \/ CrashHistoryService
    \/ AcquireShard
    \/ \E p \in Ops : ExpireResetRequest(p)
    \/ \E p \in Ops : ReadTransientFailure(p)
    \/ \E r \in Runs : AddWorkflowTaskStartedEvent(r)
    \/ \E r \in Runs, id \in UpdateIDs, payload \in Payloads : AddWorkflowExecutionUpdateAcceptedEvent(r, id, payload)
    \/ \E r \in Runs, id \in UpdateIDs : AddWorkflowExecutionUpdateCompletedEvent(r, id)
    \/ \E r \in Runs, id \in UpdateIDs, payload \in Payloads : AddWorkflowExecutionSignaled(r, id, payload)
    \/ \E r \in Runs, s \in Runs, id \in StartIDs : ContinueAsNew(r, s, id)
    \/ \E r \in Runs : CompleteWorkflowExecution(r)
    \/ \E r \in Runs : DeleteWorkflowExecution(r)
    \/ \E r \in Runs : DeleteExecutionTask(r)
    \/ \E r \in Runs : DeleteWorkflowExecution_AcquireIO(r)
    \/ \E r \in Runs : DeleteCurrentWorkflowExecution(r)
    \/ \E r \in Runs : DeleteWorkflowMutableState(r)
    \/ \E r \in Runs : GetHistoryTreeContainingBranch(r)
    \/ \E r \in Runs : DeleteHistoryBranch_SQL(r)
    \/ \E r \in Runs : DeleteHistoryBranch_CassandraRow(r)
    \/ \E r \in Runs : DeleteHistoryBranch_CassandraRanges(r)
    \/ \E r \in Runs : HistoryScannerAge(r)
    \/ \E r \in Runs : HistoryScavengerVerify(r)

Spec == Init /\ [][Next]_vars
=============================================================================
