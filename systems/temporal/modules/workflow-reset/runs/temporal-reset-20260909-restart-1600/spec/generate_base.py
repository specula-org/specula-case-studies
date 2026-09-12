from pathlib import Path
import json
O=Path(__file__).parent
A=[]
parts=[r'''------------------------------- MODULE base -------------------------------
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
EmptyRun == [exists |-> FALSE, status |-> "absent", ver |-> 0, n |-> 0,
    create |-> None, start |-> None, requestIds |-> {}, callback |-> None,
    link |-> None, can |-> None, base |-> None, cut |-> 0, resetReq |-> None]
NewRun(id, b, cut, q, n) == [exists |-> TRUE, status |-> "running", ver |-> 1, n |-> n,
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
    /\ rt = [state |-> "acquired", leases |-> [r \in Runs |-> None],
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
ReapplyGood(p) == IF op[p].kind /= "reset" \/ op[p].dedup \/ op[p].result \in audit.deleted THEN TRUE ELSE
    /\ op[p].reapplied = ReappliedSeq(op[p].expected)
    /\ SubSeq(History(op[p].result),op[p].cut+2,Len(op[p].built)) = op[p].reapplied
\* A registered branch protects all its own nodes and exact ancestor intervals.
\* history_manager.go:141-202. One event per abstract node; see model-notes.md.
ProtectedBy(r) == ({r} \X (1..HistoryLimit)) \cup SeqSet(db.cells[r])
DeletePlan(r) ==
    LET candidates == ({r} \X (1..HistoryLimit)) \cup SeqSet(db.cells[r])
        protected == UNION {ProtectedBy(b) : b \in db.branches \ {r}}
    IN candidates \ protected
''']

def act(name,args,source,guard,updates,lets='',fault=None):
    head=name+('('+args+')' if args else '')
    text='\n\\* '+source+'\n'+head+' ==\n'
    if lets: text+='    \\* Snapshot/derived values: '+source+'\n    LET '+lets+' IN\n'
    for line in guard.strip().splitlines():
        text+='    \\* Control-flow condition: '+source+'\n    /\\ '+line.strip()+'\n'
    changed=set()
    for var,value in updates.items():
        changed.add(var)
        text+='    \\* State effect: '+source+'\n    /\\ '+var+"' = "+'('+value.replace('\n','\n        ')+')\n'
    same=[v for v in ['db','op','pending','rt','audit','deletion','used'] if v not in changed]
    if same: text+='    /\\ UNCHANGED <<'+', '.join(same)+'>>\n'
    parts.append(text)
    A.append(dict(name=name,args=args,source=source,fault=fault))

act('StartWorkflowExecution','p, r, id','service/history/api/startworkflow/api.go:195-253; Scenario 3',
    r'''Free(p)
r \in FreshRuns
Serving /\ rt.currentLock = None''',{
'op':r'''[op EXCEPT ![p] = [EmptyOp EXCEPT !.pc = "start-history", !.kind = "start",
        !.candidate = r, !.create = id, !.built = InitialHistory(r,id)]]''',
'rt':r'''[rt EXCEPT !.currentLock = p]''','used':r'used \cup {r}'},fault='start')
act('ResetWorkflowExecution','p, q, b, cut, ex','service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5',
    r'''Free(p)
Live(b)
cut \in 2..db.runs[b].n /\ db.hist[b][cut].kind = "WFT"''',{
'op':r'''[op EXCEPT ![p] = [EmptyOp EXCEPT !.pc = "base-lease", !.kind = "reset",
        !.req = q, !.base = b, !.cut = cut, !.exclude = ex]]''',
'audit':r'[audit EXCEPT !.wanted = @ \cup {q}]'},fault='reset')
act('GetWorkflowLease_Base','p','service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388',
    r'''op[p].pc = "base-lease" /\ Serving
Unlocked(op[p].base)''',{
'op':r'''[op EXCEPT ![p].pc = IF Live(b) THEN "lookup" ELSE "release-error",
    ![p].err = IF Live(b) THEN None ELSE "NotFound", ![p].bv = db.runs[b].ver,
    ![p].baseN = db.runs[b].n, ![p].originalToken = b]''',
'rt':r'[rt EXCEPT !.leases[b] = p]'},lets='b == op[p].base')
act('GetCurrentWorkflowRunID','p','service/history/api/resetworkflow/api.go:86-122; workflow/cache/cache.go:465-490',
    r'''op[p].pc = "lookup" /\ Serving
rt.currentLock = None''',{'op':r'[op EXCEPT ![p].seen = db.current, ![p].pc = "current-lease"]'})
act('GetWorkflowLease_Current','p','service/history/api/resetworkflow/api.go:101-126',
    r'''op[p].pc = "current-lease" /\ Serving
IF c = None THEN TRUE ELSE rt.leases[c] \in {None,p}''',{
'op':r'''[op EXCEPT ![p].pc = IF c = None \/ Live(c) THEN "dedup" ELSE "release-error",
    ![p].err = IF c = None \/ Live(c) THEN None ELSE "NotFound",
    ![p].cv = IF c = None THEN 0 ELSE db.runs[c].ver,
    ![p].curN = IF c = None THEN 0 ELSE db.runs[c].n]''',
'rt':r'IF c = None THEN rt ELSE [rt EXCEPT !.leases[c] = p]'},lets='c == op[p].seen')
act('Invoke_Deduplicate','p','service/history/api/resetworkflow/api.go:124-136; Scenario 1',
    r'''op[p].pc = "dedup"''',{
'op':r'''[op EXCEPT ![p].dedup = hit, ![p].result = IF hit THEN c ELSE None,
    ![p].pc = IF hit THEN "server-success" ELSE "allocate"]'''},
lets=r'''c == op[p].seen
        hit == IF c = None THEN FALSE ELSE db.runs[c].create = op[p].req''')
act('Invoke_NewRunID','p, r','service/history/api/resetworkflow/api.go:136-148; Scenario 1',
    r'''op[p].pc = "allocate"
r \in FreshRuns''',{'op':r'[op EXCEPT ![p].candidate = r, ![p].pc = "prepare"]','used':r'used \cup {r}'})
act('ResetWorkflow_UpdateResetRunID','p','service/history/ndc/workflow_resetter.go:132-228,230-247',
    r'''op[p].pc = "prepare"''',{'op':r'''[op EXCEPT ![p].localLink = op[p].candidate,
    ![p].terminate = IF c = None THEN FALSE ELSE db.runs[c].status = "running",
    ![p].create = FindStart(op[p].base), ![p].callback = FindStart(op[p].base),
    ![p].pc = "fork"]'''},lets='c == op[p].seen')
act('ForkHistoryBranch','p','service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120',
    r'''op[p].pc = "fork" /\ Serving''',{
'db':r'''[db EXCEPT !.branches = @ \cup {r},
    !.cells[r] = Prefix(db.cells[op[p].base],op[p].cut)]''',
'op':r'[op EXCEPT ![p].prefixToken = r, ![p].pc = "rebuild"]'},lets='r == op[p].candidate')
act('Rebuild','p','service/history/ndc/workflow_resetter.go:545-565; state_rebuilder.go:402-410; workflow/mutable_state_impl.go:3106-3123',
    r'''op[p].pc = "rebuild"''',{'op':r'''[op EXCEPT ![p].prefix = pre,
    ![p].built = Append(pre,BlankEvent(op[p].candidate,op[p].cut+1,"ResetWFT")),
    ![p].updateIds = EventIDs(pre), ![p].scan = op[p].base,
    ![p].index = op[p].cut+1, ![p].end = op[p].baseN,
    ![p].visited = <<op[p].base>>,
    ![p].pc = IF ok THEN "read-branch" ELSE "release-error",
    ![p].err = IF ok THEN None ELSE "DataLoss"]'''},
lets=r'''pre == Prefix(db.hist[op[p].base],op[p].cut)
        ok == Readable(op[p].base,op[p].cut)''')
act('ReadHistoryBranch','p','service/history/ndc/workflow_resetter.go:139-142,749-768,865-882; Scenario 4',
    r'''op[p].pc = "read-branch"''',{'op':r'''[op EXCEPT
    ![p].batch = suffix, ![p].input = @ \o suffix,
    ![p].expected = @ \o FilterEligible(suffix,op[p].exclude),
    ![p].frontier = Append(@,[run |-> r, first |-> op[p].index, last |-> op[p].end]),
    ![p].index = 1,
    ![p].pc = IF allExcluded THEN "schedule" ELSE IF ok THEN "reapply" ELSE "release-error",
    ![p].err = IF ok \/ allExcluded THEN None ELSE "DataLoss"]'''},
lets=r'''r == op[p].scan
        allExcluded == op[p].exclude = {"Signal","Update"}
        suffix == IF allExcluded THEN <<>> ELSE SubSeq(db.hist[r],op[p].index,op[p].end)
        ok == Readable(r,op[p].end)''')
act('ReapplyEvents','p','service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748',
    r'''op[p].pc = "reapply"
op[p].index <= Len(op[p].batch)''',{'op':r'''[op EXCEPT ![p].index = @+1,
    ![p].built = IF take /\ ~collision THEN Append(@,Reapplied(e)) ELSE @,
    ![p].reapplied = IF take /\ ~collision THEN Append(@,Reapplied(e)) ELSE @,
    ![p].updateIds = IF take /\ isUpdate /\ ~collision THEN @ \cup {e.id} ELSE @,
    ![p].pc = IF collision THEN "release-error" ELSE @,
    ![p].err = IF collision THEN "InternalUpdateCollision" ELSE @]'''},
lets=r'''e == op[p].batch[op[p].index]
        take == Eligible(e,op[p].exclude)
        isUpdate == e.kind \in {"Accepted","Admitted"}
        collision == take /\ isUpdate /\ e.id \in op[p].updateIds''')
act('ReapplyEventsFromBranch_NextRun','p','service/history/ndc/workflow_resetter.go:904-910',
    r'''op[p].pc = "reapply"
op[p].index > Len(op[p].batch)''',{'op':r'''[op EXCEPT ![p].scan = next,
    ![p].pc = IF next = None THEN "schedule" ELSE "successor"]'''},
lets=r'''s == op[p].batch
        next == IF s /= <<>> /\ s[Len(s)].kind = "CAN" THEN s[Len(s)].next ELSE None''')
act('GetNextEventIDBranchToken','p','service/history/ndc/workflow_resetter.go:771-828; Scenario 4',
    r'''op[p].pc = "successor" /\ Serving
rt.leases[r] \in {None,p}''',{'op':r'''[op EXCEPT ![p].pc = IF Live(r) THEN "read-branch" ELSE "schedule",
    ![p].index = 1, ![p].end = db.runs[r].n,
    ![p].visited = IF Live(r) THEN Append(@,r) ELSE @]'''},lets='r == op[p].scan')
act('ScheduleWorkflowTask','p','service/history/ndc/workflow_resetter.go:258-280,376-425',
    r'''op[p].pc = "schedule"''',{'op':r'''[op EXCEPT ![p].pc = IF op[p].seen = None THEN "submit-base" ELSE "submit-atomic"]'''})
for name,pc,mode,src in [
('UpdateWorkflowExecution_BypassCurrent','submit-base','base','399-412'),
('CreateWorkflowExecution_BrandNew','submit-create','create','413-424'),
('UpdateWorkflowExecution_WithNew','submit-atomic','same','430-459'),
('ConflictResolveWorkflowExecution','submit-atomic','distinct','463-503'),
('CreateWorkflowExecution_Start','start-history','start','413-424')]:
    extra=''
    if mode=='same': extra='\nop[p].seen = op[p].base'
    if mode=='distinct': extra='\nop[p].seen /= op[p].base'
    act(name,'p',f'service/history/ndc/workflow_resetter.go:{src}; service/history/shard/context_impl.go:552-594,610-656',
        f'op[p].pc = "{pc}" /\\ Serving\nCardinality(rt.io) < Slots'+extra,{
        'pending':f'[pending EXCEPT ![r] = WriteFor(p,"{mode}")]',
        'rt':r'[rt EXCEPT !.io = @ \cup {r}]',
        'op':r'[op EXCEPT ![p].pc = "write-wait"]'},lets='r == op[p].candidate')
act('AppendHistoryNodes_Current','r','common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2',
    r'''pending[r].state = "submitted"
pending[r].terminate /\ pending[r].mode \in {"same","distinct"}''',{
'db':r'''[db EXCEPT !.hist[w.seen] = Append(Prefix(db.hist[w.seen],w.curN),
    BlankEvent(w.seen,w.curN+1,"Terminated")),
    !.cells[w.seen] = currentCells, !.nodes = @ \cup SeqSet(currentCells)]''',
'pending':r'[pending EXCEPT ![r].state = "current-appended"]'},
lets=r'''w == pending[r]
        currentCells == Prefix(db.cells[w.seen],w.curN) \o << <<w.seen,w.curN+1>> >>''')
act('AppendHistoryNodes','r','common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2',
    r'''pending[r].state \in {"submitted","current-appended"}
IF pending[r].terminate /\ pending[r].mode \in {"same","distinct"} THEN pending[r].state = "current-appended" ELSE TRUE''',{
'db':r'''IF w.mode = "base" THEN db ELSE
    [db EXCEPT !.branches = @ \cup {r}, !.hist[r] = w.events,
       !.cells[r] = newCells, !.nodes = @ \cup SeqSet(newCells)]''',
'pending':r'''[pending EXCEPT ![r].state = IF Backend = "Cassandra" /\ w.mode = "base"
                                             THEN "precheck" ELSE "ready"]'''},
lets=r'''w == pending[r]
        newCells == IF w.mode = "start" THEN OwnCells(r,1,Len(w.events))
                    ELSE db.cells[r] \o OwnCells(r,w.cut+1,Len(w.events))''')
act('PersistenceAppendTimeout','r','service/history/shard/context_impl.go:1518-1520; Scenario 2 history append uncertain, metadata unattempted',
    r'''pending[r].state \in {"submitted","current-appended","ready"}
pending[r].reply = "waiting"''',{
'pending':r'[pending EXCEPT ![r].state = "rejected", ![r].result = "AppendHistoryTimeout"]'},fault='append')
act('AssertNotCurrentExecution','r','common/persistence/cassandra/mutable_state_store.go:619-630,885-918',
    r'''pending[r].state = "precheck"''',{
'pending':r'''[pending EXCEPT ![r].prechecked = db.current /= pending[r].base,
    ![r].state = IF db.current /= pending[r].base THEN "ready" ELSE "rejected",
    ![r].result = IF db.current /= pending[r].base THEN None ELSE "Condition"]'''})
act('CommitWorkflowExecution','r','common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740',
    r'''pending[r].state = "ready"
MetadataConditions(r)''',{
'db':r'MetadataDB(r)',
'pending':r'[pending EXCEPT ![r].state = "committed", ![r].result = "OK"]',
'audit':r'''[audit EXCEPT !.commits = @ \cup {
    [run |-> r, mode |-> w.mode, epoch |-> w.epoch, durableEpoch |-> db.range,
     seen |-> w.seen, prior |-> db.current, base |-> w.base]},
    !.retryBad = @ \/ (w.mode /= "base" /\ w.req /= None /\
                       w.immediate /= None /\ w.immediate /= r /\
                       w.adminEpoch = audit.admin[w.req]),
    !.admin = [q \in ResetIDs |-> IF w.mode /= "base" /\ q /= w.req
                                    THEN audit.admin[q]+1 ELSE audit.admin[q]]]'''},lets='w == pending[r]')
act('RejectWorkflowExecution','r','common/persistence/sql/execution.go:106-124,426-440; sql/execution_util.go:640-661; cassandra/mutable_state_store.go:474-489',
    r'''pending[r].state = "ready"
~MetadataConditions(r)''',{'pending':r'''[pending EXCEPT ![r].state = "rejected",
    ![r].result = IF pending[r].epoch /= db.range THEN "OwnershipLost" ELSE "Condition"]'''})
act('PersistenceDefiniteRejection','r','service/history/shard/context_impl.go:1522-1532; Scenario 2 fault, ResourceExhausted before metadata',
    r'''pending[r].state \in {"submitted","current-appended","precheck","ready"}
pending[r].reply = "waiting"''',{'pending':r'''[pending EXCEPT ![r].state = "rejected", ![r].result = "ResourceExhausted"]'''},fault='reject')
act('PersistenceUncertainReturn','r','service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result',
    r'''pending[r].state \in {"ready","committed"}
pending[r].reply = "waiting"
r \in rt.io''',{
'pending':r'[pending EXCEPT ![r].reply = "lost"]',
'rt':r'[rt EXCEPT !.io = @ \ {r}, !.state = "acquiring"]',
'op':r'''[op EXCEPT ![p].pc = "release-error", ![p].err = "Unavailable"]'''},lets='p == pending[r].owner',fault='uncertain')
act('PersistenceReturn','r','service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548',
    r'''pending[r].state \in {"committed","rejected"}
pending[r].reply = "waiting"''',{
'pending':r'[pending EXCEPT ![r].reply = "returned"]',
'rt':r'''[rt EXCEPT !.io = @ \ {r},
    !.state = IF pending[r].result = "OwnershipLost" THEN "acquiring" ELSE @]''',
'op':r'''[op EXCEPT ![p].pc = IF pending[r].result /= "OK" THEN "release-error"
        ELSE IF pending[r].mode = "base" THEN "submit-create" ELSE "server-success",
    ![p].result = IF pending[r].result = "OK" THEN r ELSE None,
    ![p].err = IF pending[r].result = "OK" THEN None ELSE pending[r].result]'''},lets='p == pending[r].owner')
act('Invoke_ReturnSuccess','p','service/history/api/resetworkflow/api.go:131-134,213-215; service/history/api/startworkflow/api.go:230-236',
    r'''op[p].pc = "server-success"''',{
'audit':r'''[audit EXCEPT !.acks = @ \cup {[request |-> op[p].req, run |-> op[p].result,
        base |-> op[p].base, kind |-> op[p].kind]},
    !.availableBad = @ \/ ~AckGood(p), !.reapplyBad = @ \/ ~ReapplyGood(p)]''',
'op':r'[op EXCEPT ![p].pc = "release-success"]'})
act('ReleaseWorkflowLease_Success','p','service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:390-409',
    r'''op[p].pc = "release-success"''',{
'rt':r'''[rt EXCEPT !.leases = ReleaseLeases(p),
    !.currentLock = IF @ = p THEN None ELSE @]''',
'op':r'[op EXCEPT ![p].pc = "response"]'})
act('ReceiveResetResponse','p','service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC client receipt boundary',
    r'''op[p].pc = "response"''',{
'audit':r'''[audit EXCEPT !.receipts = @ \cup {[request |-> op[p].req, run |-> op[p].result]}]''',
'op':r'[op EXCEPT ![p].pc = "done"]'})
act('LoseResetResponse','p','service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC transport fault after success',
    r'''op[p].pc = "response"''',{'op':r'[op EXCEPT ![p].pc = "retry", ![p].err = "ResponseLost"]'},fault='response')
act('ReplayResetRequest','p','service/history/api/resetworkflow/api.go:43,124-136; Scenario 1 explicit identical client replay',
    r'''op[p].pc = "done" /\ op[p].kind = "reset"''',{'op':r'[op EXCEPT ![p].pc = "retry"]'},fault='replay')
act('ReleaseWorkflowLease_Error','p','service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298',
    r'''op[p].pc = "release-error"''',{
'rt':r'''[rt EXCEPT !.leases = ReleaseLeases(p),
    !.currentLock = IF @ = p THEN None ELSE @]''',
'op':r'''[op EXCEPT ![p].pc = IF op[p].kind = "start" \/ op[p].err \in {"NotFound","DataLoss","InternalUpdateCollision","RequestTimeout"}
                                    THEN "done" ELSE "retry"]''',
'audit':r'''[audit EXCEPT !.terminal = IF op[p].err = "NotFound" THEN @ \cup {op[p].req} ELSE @]'''})
act('RetryResetWorkflowExecution','p','common/rpc/interceptor/retry.go:36-44; service/history/handler.go:2291-2298; Scenarios 1-3',
    r'''op[p].pc = "retry" /\ op[p].kind = "reset" /\ Serving''',{
'op':r'''[op EXCEPT ![p] = [EmptyOp EXCEPT !.pc = "base-lease", !.kind = "reset",
    !.req = old.req, !.base = old.base, !.cut = old.cut, !.exclude = old.exclude,
    !.immediate = IF db.current /= None /\ Live(db.current) /\
                       db.runs[db.current].resetReq = old.req
                 THEN db.current ELSE None, !.adminEpoch = audit.admin[old.req]]]'''},lets='old == op[p]')
act('CrashHistoryService','','service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss',
    r'''rt.state /= "stopped"''',{
'rt':r'''[rt EXCEPT !.state = "stopped", !.leases = [r \in Runs |-> None],
    !.currentLock = None, !.io = {}]''',
'op':r'''[p \in Ops |-> IF Active(p) THEN [op[p] EXCEPT
    !.pc = IF op[p].kind = "reset" THEN "retry" ELSE "done", !.err = "ProcessLost"] ELSE op[p]]''',
'pending':r'''[r \in Runs |-> IF pending[r].reply = "waiting"
    THEN [pending[r] EXCEPT !.reply = "lost"] ELSE pending[r]]''',
'deletion':r'''[r \in Runs |-> IF deletion[r].stage \in {"admit","current","mutable","plan","delete"}
    THEN [deletion[r] EXCEPT !.stage = IF Live(r) THEN "queued" ELSE "orphan"] ELSE deletion[r]]'''},fault='crash')
act('AcquireShard','','service/history/shard/context_impl.go:1164-1207,2074-2097; Scenario 2 RangeID fence',
    r'''rt.state \in {"acquiring","stopped"}
{r \in rt.io : rt.leases[r] /= "deletion"} = {}''',{
'db':r'[db EXCEPT !.range = @+1]',
'rt':r'[rt EXCEPT !.state = "acquired"]'})
act('ExpireResetRequest','p','client/history/client_gen.go:1049-1055; client/history/client.go:33-34,290-291; service/history/shard/context_impl.go:2414-2427; Scenario 5',
    r'''op[p].kind = "reset"
op[p].pc \in {"allocate","prepare","fork","rebuild","read-branch","reapply","successor","schedule","submit-base","submit-create","submit-atomic"}''',{
'op':r'[op EXCEPT ![p].pc = "release-error", ![p].err = "RequestTimeout"]'},fault='timeout')
act('ReadTransientFailure','p','service/history/ndc/workflow_resetter.go:796-819,875-882; Scenario 4 read error must not truncate',
    r'''op[p].pc \in {"lookup","successor","read-branch","rebuild","fork"}''',{
'op':r'[op EXCEPT ![p].pc = "release-error", ![p].err = "Unavailable"]'},fault='read')

# Supported setup and worker actions. Successful environment transactions are atomic
# at their metadata point; Reset's write/fault boundaries remain explicit above.
act('AddWorkflowTaskStartedEvent','r','service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary',
    r'''Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
Cardinality(rt.io) < Slots
(~\E e \in SeqSet(History(r)) : e.kind = "WFT") \/ (\E i \in 1..db.runs[r].n : db.hist[r][i].kind = "Completed" /\ \A j \in (i+1)..db.runs[r].n : db.hist[r][j].kind /= "WFT")''',{
'db':r'''[db EXCEPT !.hist[r] = Append(History(r),BlankEvent(r,n,"WFT")),
    !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>),
    !.nodes = @ \cup {<<r,n>>}, !.runs[r].n = n, !.runs[r].ver = @+1]'''},lets='n == db.runs[r].n+1')
act('AddWorkflowExecutionUpdateAcceptedEvent','r, id, payload','service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace',
    r'''Serving /\ Live(r) /\ db.current = r /\ Unlocked(r)
db.runs[r].status = "running"
id \notin EventIDs(History(r))
Cardinality(rt.io) < Slots
\E priorEvent \in SeqSet(History(r)) : priorEvent.kind \in {"WFT","ResetWFT"}''',{
'db':r'''[db EXCEPT !.hist[r] = Append(History(r),e),
    !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>), !.nodes = @ \cup {<<r,n>>},
    !.runs[r].n = n, !.runs[r].ver = @+1]'''},
lets='n == db.runs[r].n+1\n        e == Evt(r,n,"Accepted",id,payload,TRUE,None)',fault='update')
act('AddWorkflowExecutionUpdateCompletedEvent','r, id','service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control',
    r'''Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
id \in EventIDs(History(r))
~\E e \in SeqSet(History(r)) : e.kind = "Completed" /\ e.id = id
Cardinality(rt.io) < Slots''',{
'db':r'''[db EXCEPT !.hist[r] = History(r) \o
       <<Evt(r,n,"Completed",id,None,FALSE,None)>>,
    !.cells[r] = Prefix(@,db.runs[r].n) \o << <<r,n>> >>,
    !.nodes = @ \cup {<<r,n>>}, !.runs[r].n = n, !.runs[r].ver = @+1]'''},lets='n == db.runs[r].n+1')
act('AddWorkflowExecutionSignaled','r, id, payload','service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4',
    r'''Serving /\ Live(r) /\ db.current = r /\ Unlocked(r) /\ db.runs[r].status = "running"
Cardinality(rt.io) < Slots''',{
'db':r'''[db EXCEPT !.hist[r] = Append(History(r),Evt(r,n,"Signal",id,payload,TRUE,None)),
    !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>),
    !.nodes = @ \cup {<<r,n>>}, !.runs[r].n = n, !.runs[r].ver = @+1]'''},lets='n == db.runs[r].n+1',fault='signal')
act('ContinueAsNew','r, s, id','service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN',
    r'''Serving /\ Live(r) /\ db.current = r /\ Unlocked(r)
s \in FreshRuns /\ db.runs[r].status = "running"
Cardinality(rt.io) < Slots
\E priorEvent \in SeqSet(History(r)) : priorEvent.kind \in {"WFT","ResetWFT"}''',{
'db':r'''[db EXCEPT !.runs[r].status = "can", !.runs[r].can = s,
    !.runs[r].ver = @+1, !.runs[r].n = n,
    !.hist[r] = Append(History(r),Evt(r,n,"CAN",None,None,FALSE,s)),
    !.cells[r] = Append(Prefix(@,db.runs[r].n),<<r,n>>),
    !.runs[s] = NewRun(id,None,0,None,1), !.hist[s] = InitialHistory(s,id),
    !.cells[s] = OwnCells(s,1,1), !.branches = @ \cup {s},
    !.nodes = @ \cup {<<r,n>>,<<s,1>>}, !.current = s]''',
'used':r'used \cup {s}',
'audit':r'[audit EXCEPT !.admin = [q \in ResetIDs |-> audit.admin[q]+1]]'},lets='n == db.runs[r].n+1',fault='can')
act('CompleteWorkflowExecution','r','service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability',
    r'''Serving /\ Live(r) /\ Unlocked(r) /\ db.runs[r].status = "running"
Readable(r,db.runs[r].n) /\ Cardinality(rt.io) < Slots
\E priorEvent \in SeqSet(History(r)) : priorEvent.kind \in {"WFT","ResetWFT"}''',{
'db':r'[db EXCEPT !.runs[r].status = "completed", !.runs[r].ver = @+1]'})
act('DeleteWorkflowExecution','r','service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup',
    r'''Serving /\ Live(r) /\ Unlocked(r)
deletion[r].stage = "none"
Cardinality(rt.io) < Slots''',{
'db':r'''[db EXCEPT !.runs[r].status = IF @ = "running" THEN "terminated" ELSE @,
    !.runs[r].ver = @+1]''',
'deletion':r'[deletion EXCEPT ![r].stage = "queued"]',
'audit':r'[audit EXCEPT !.deleted = @ \cup {r}, !.admin = [q \in ResetIDs |-> audit.admin[q]+1]]'},fault='delete')
act('DeleteExecutionTask','r','service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937',
    r'''Serving /\ deletion[r].stage = "queued" /\ Live(r) /\ Unlocked(r)
db.runs[r].status /= "running"''',{
'rt':r'[rt EXCEPT !.leases[r] = "deletion"]',
'deletion':r'[deletion EXCEPT ![r].stage = "admit"]'})
act('DeleteWorkflowExecution_AcquireIO','r','service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3',
    r'''Serving /\ deletion[r].stage = "admit" /\ rt.leases[r] = "deletion"
Cardinality(rt.io) < Slots''',{
'rt':r'[rt EXCEPT !.io = @ \cup {r}]',
'deletion':r'[deletion EXCEPT ![r].stage = "current", ![r].epoch = db.range]'})
act('DeleteCurrentWorkflowExecution','r','service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955',
    r'''Serving /\ deletion[r].stage = "current"
rt.leases[r] = "deletion" /\ r \in rt.io''',{
'db':r'[db EXCEPT !.current = IF @ = r THEN None ELSE @]',
'deletion':r'[deletion EXCEPT ![r].stage = "mutable"]'})
act('DeleteWorkflowMutableState','r','service/history/shard/context_impl.go:1063-1083',
    r'''Serving /\ deletion[r].stage = "mutable"
rt.leases[r] = "deletion" /\ r \in rt.io''',{
'db':r'[db EXCEPT !.runs[r].exists = FALSE]',
'deletion':r'[deletion EXCEPT ![r].stage = "plan"]',
'rt':r'[rt EXCEPT !.io = @ \ {r}]'})
act('GetHistoryTreeContainingBranch','r','common/persistence/history_manager.go:150-208; Scenario 5 reference snapshot separate from deletion',
    r'''deletion[r].stage = "plan"''',{
'deletion':r'[deletion EXCEPT ![r].plan = DeletePlan(r), ![r].stage = "delete"]'})
act('DeleteHistoryBranch_SQL','r','common/persistence/sql/history_store.go:347-376',
    r'''Backend = "SQL" /\ deletion[r].stage = "delete"''',{
'db':r'[db EXCEPT !.branches = @ \ {r}, !.nodes = @ \ deletion[r].plan]',
'deletion':r'[deletion EXCEPT ![r].stage = "done"]',
'rt':r'[rt EXCEPT !.leases[r] = IF @ = "deletion" THEN None ELSE @]'})
act('DeleteHistoryBranch_CassandraRow','r','common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility',
    r'''Backend = "Cassandra" /\ deletion[r].stage \in {"delete","ranges-first"}''',{
'db':r'[db EXCEPT !.branches = @ \ {r}]',
'deletion':r'[deletion EXCEPT ![r].stage = IF @ = "ranges-first" THEN "done" ELSE "row-first"]',
'rt':r'[rt EXCEPT !.leases[r] = IF deletion[r].stage = "ranges-first" /\ @ = "deletion" THEN None ELSE @]'})
act('DeleteHistoryBranch_CassandraRanges','r','common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges',
    r'''Backend = "Cassandra" /\ deletion[r].stage \in {"delete","row-first"}''',{
'db':r'[db EXCEPT !.nodes = @ \ deletion[r].plan]',
'deletion':r'[deletion EXCEPT ![r].stage = IF @ = "row-first" THEN "done" ELSE "ranges-first"]',
'rt':r'[rt EXCEPT !.leases[r] = IF deletion[r].stage = "row-first" /\ @ = "deletion" THEN None ELSE @]'})
act('HistoryScannerAge','r','service/worker/scanner/history/scavenger.go:202-211; common/dynamicconfig/constants.go:3549-3553; client/history/client.go:33-34,290-291',
    r'''r \in db.branches /\ ~deletion[r].aged
~ScannerAfterRequestDeadline \/ (\A p \in Ops : op[p].candidate = r => ~Active(p))''',{
'deletion':r'[deletion EXCEPT ![r].aged = TRUE]'},fault='age')
act('HistoryScavengerVerify','r','service/worker/scanner/history/scavenger.go:252-286; Scenario 5 NotFound only, not temporary error',
    r'''Serving /\ r \in db.branches /\ deletion[r].aged
~Live(r) /\ deletion[r].stage \in {"none","orphan"}''',{
'deletion':r'[deletion EXCEPT ![r].stage = "plan", ![r].scanner = TRUE]'})

parts.append(r'''
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
CallbackSourceIdentity == \A r \in Runs : Live(r) => db.runs[r].create = db.runs[r].callback
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
''')
# Record descriptors feed trace wrappers and action-to-code documentation in later phases.
(O/'action-manifest.json').write_text(json.dumps(A,indent=2)+'\n')
quant=[]
for a in A:
    args=a['args']; name=a['name']
    domains={'p':'Ops','r':'Runs','s':'Runs','id':'StartIDs' if name in {'StartWorkflowExecution','ContinueAsNew'} else 'UpdateIDs',
             'q':'ResetIDs','b':'Runs','cut':'2..HistoryLimit','ex':'SUBSET {"Signal","Update"}','payload':'Payloads'}
    if args:
        aa=[x.strip() for x in args.split(',')]
        quant.append('\\E '+', '.join(x+' \\in '+domains[x] for x in aa)+' : '+name+'('+args+')')
    else: quant.append(name)
parts.append('\nNext ==\n    \\/ '+ '\n    \\/ '.join(quant)+'\n\nSpec == Init /\\ [][Next]_vars\n=============================================================================\n')
(O/'base.tla').write_text(''.join(parts))
(O/'base.cfg').write_text('''INIT Init
NEXT Next
CONSTANTS
 Runs = {"a", "b", "c", "d", "e", "f", "g"}
 Ops = {"p", "q"}
 ResetIDs = {"reset1", "reset2"}
 StartIDs = {"start1", "start2"}
 UpdateIDs = {"u1", "u2"}
 Payloads = {"x", "y"}
 Backend = "SQL"
 IOConcurrency = 1
 HistoryLimit = 16
 StartMapPresent = TRUE
 ScannerAfterRequestDeadline = TRUE
CONSTRAINT HistoryBound
INVARIANTS TypeOK CurrentExecutionConsistency CallbackSourceIdentity IOCapacity
CHECK_DEADLOCK FALSE
''')
