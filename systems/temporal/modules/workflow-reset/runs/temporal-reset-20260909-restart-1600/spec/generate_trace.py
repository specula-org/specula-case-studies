from pathlib import Path
import json
O=Path(__file__).parent;A=json.loads((O/'action-manifest.json').read_text())
t=r'''------------------------------ MODULE Trace -------------------------------
EXTENDS base, Json, IOUtils

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
RawTrace == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTrace, LAMBDA e : IF "tag" \in DOMAIN e
                                           THEN e.tag = "temporal-reset" ELSE FALSE)
TraceConfig == TraceLog[1].config
TraceRuns == SeqSet(TraceConfig.runs)
TraceOps == SeqSet(TraceConfig.ops)
TraceResetIDs == SeqSet(TraceConfig.resetIDs)
TraceStartIDs == SeqSet(TraceConfig.startIDs)
TraceUpdateIDs == SeqSet(TraceConfig.updateIDs)
TracePayloads == SeqSet(TraceConfig.payloads)
TraceBackend == TraceConfig.backend
TraceIOConcurrency == TraceConfig.ioConcurrency
TraceHistoryLimit == TraceConfig.historyLimit
TraceStartMapPresent == TraceConfig.startMapPresent
TraceScannerAfterRequestDeadline == TraceConfig.scannerAfterRequestDeadline

\* JSON arrays represent both sequences and sets. Only declared set-valued
\* fields are converted; order is preserved for histories, frontiers and events.
DecodeRun(s) == [s EXCEPT !.requestIds = SeqSet(@)]
DecodeDB(s) == [s EXCEPT
    !.runs = [r \in Runs |-> DecodeRun(s.runs[r])],
    !.branches = SeqSet(@), !.nodes = SeqSet(@)]
DecodeOp(s) == [s EXCEPT !.exclude = SeqSet(@), !.updateIds = SeqSet(@)]
DecodeOps(s) == [p \in Ops |-> DecodeOp(s[p])]
DecodeRT(s) == [s EXCEPT !.io = SeqSet(@)]
DecodeAudit(s) == [s EXCEPT !.acks = SeqSet(@), !.receipts = SeqSet(@),
    !.commits = SeqSet(@), !.deleted = SeqSet(@), !.wanted = SeqSet(@),
    !.terminal = SeqSet(@)]
DecodeDeletion(s) == [r \in Runs |-> [s[r] EXCEPT !.plan = SeqSet(@)]]

VARIABLE l
tracevars == <<vars, l>>
logline == TraceLog[l]
IsEvent(name) == l <= Len(TraceLog) /\ logline.event = name
\* Strong post-state checks: mandatory fields, no conditional presence checks.
\* instrumentation-spec.md section 1 defines every captured field in these records.
ValidatePostState(s) ==
    /\ db' = DecodeDB(s.db)
    /\ op' = DecodeOps(s.op)
    /\ pending' = s.pending
    /\ rt' = DecodeRT(s.rt)
    /\ audit' = DecodeAudit(s.audit)
    /\ deletion' = DecodeDeletion(s.deletion)
    /\ used' = SeqSet(s.used)
ValidateInitialState(s) ==
    /\ db = DecodeDB(s.db)
    /\ op = DecodeOps(s.op)
    /\ pending = s.pending
    /\ rt = DecodeRT(s.rt)
    /\ audit = DecodeAudit(s.audit)
    /\ deletion = DecodeDeletion(s.deletion)
    /\ used = SeqSet(s.used)
TraceInit ==
    /\ Len(TraceLog) >= 1
    /\ TraceLog[1].event = "Bootstrap"
    /\ TraceConfig.revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
    /\ Init
    /\ ValidateInitialState(TraceLog[1].state)
    /\ l = 2
'''
for a in A:
    name=a['name'];args=[x.strip() for x in a['args'].split(',')] if a['args'] else []
    params=[('SeqSet(logline.args.ex)' if x=='ex' else 'logline.args.'+x) for x in args]
    call=name+('('+', '.join(params)+')' if args else '')
    t+='\n\\* '+a['source']+'\nTrace'+name+' ==\n'
    t+='    /\\ IsEvent("'+name+'")\n    /\\ '+call+'\n'
    t+='    /\\ ValidatePostState(logline.state)\n    /\\ l\' = l+1\n'
t+='\nAdvance ==\n    \\/ '+'\n    \\/ '.join('Trace'+a['name'] for a in A)+'\n'
t+=r'''
\* No silent actions: every represented semantic boundary has its own event.
TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ Advance
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED tracevars
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(Advance)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
'''
(O/'Trace.tla').write_text(t)
(O/'Trace.cfg').write_text('''SPECIFICATION TraceSpec
CONSTANTS
 Runs <- TraceRuns
 Ops <- TraceOps
 ResetIDs <- TraceResetIDs
 StartIDs <- TraceStartIDs
 UpdateIDs <- TraceUpdateIDs
 Payloads <- TracePayloads
 Backend <- TraceBackend
 IOConcurrency <- TraceIOConcurrency
 HistoryLimit <- TraceHistoryLimit
 StartMapPresent <- TraceStartMapPresent
 ScannerAfterRequestDeadline <- TraceScannerAfterRequestDeadline
INVARIANTS TypeOK CurrentExecutionConsistency CallbackSourceIdentity IOCapacity
PROPERTIES TraceMatched
CHECK_DEADLOCK FALSE
''')
