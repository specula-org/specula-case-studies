from pathlib import Path
import json
D=Path(__file__).resolve().parent.parent
actions=json.loads((D/'checks/action-map.json').read_text())
constants=['Clients','Selected','NumRounds','NumKeys','HistoryLimit','ErrorMode','OutboundFilter','LazyOffload',
 'AllocationFailure','ConversionFailure','BeforeSendFailure','AllowEmpty','MetricKinds','MinSites',
 'RequiredSites','AllowPartialCompletion']
text=r'''------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category A: totally ordered lifecycle trace, using real boundary hooks.
\* Instrument each internal step; no unconstrained or hidden silent actions.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
RawTrace == TLCEval(ndJsonDeserialize(JsonFile))
MetaLines == SelectSeq(RawTrace, LAMBDA x :
    IF "tag" \in DOMAIN x THEN x.tag = "specula-meta" ELSE FALSE)
ASSUME Len(MetaLines) = 1
Meta == MetaLines[1]
ASSUME /\ Meta.schema = 1
       /\ Meta.sourceHead = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
       /\ Meta.origin \in {"implementation", "synthetic-test"}
TraceLog == TLCEval(SelectSeq(RawTrace, LAMBDA x :
    IF "tag" \in DOMAIN x THEN x.tag = "trace" ELSE FALSE))
ASSUME Len(TraceLog) > 0
\* Only explicit trace records are replayed. Unknown/malformed trace event names
\* remain in TraceLog and fail; they are not filtered out as harmless noise.
'''
for c in constants:
 text+='Trace'+c+' == '+('SeqSet(Meta.config.'+c+')' if c in {'Clients','Selected','MetricKinds','RequiredSites'} else 'Meta.config.'+c)+'\n'
text+=r'''
ASSUME /\ IsFiniteSet(TraceClients) /\ TraceClients /= {}
       /\ "server" \notin TraceClients /\ "clock" \notin TraceClients
       /\ "transport" \notin TraceClients

VARIABLE l
tracevars == <<s,l>>
logline == TraceLog[l].event
Unique(q) == Len(q) = Cardinality(SeqSet(q))

\* JSON arrays encode sequences, including task-indexed functions. Set-valued
\* observation fields use arrays without duplicates; normalize only those.
TraceStateShape(r) ==
    /\ Len(r.task) = NumRounds /\ Len(r.ct) = NumRounds /\ Len(r.net) = NumRounds
    /\ Len(r.used) = NumRounds
    /\ Unique(r.wf.started) /\ Unique(r.requested) /\ Unique(r.committed)
    /\ Unique(r.saved) /\ Unique(r.unknownSeen) /\ Unique(r.aggr.failedClients)
    /\ Unique(r.comm.pending) /\ Unique(r.comm.deadView)
    /\ Unique(r.mon.pending) /\ Unique(r.mon.deadView)
    /\ \A t \in Tasks : Unique(r.task[t].retiredOutstanding)
DecodeState(r) == [r EXCEPT
    !.wf.started = SeqSet(@), !.requested = SeqSet(@),
    !.task = [t \in Tasks |-> [r.task[t] EXCEPT !.retiredOutstanding = SeqSet(@)]],
    !.aggr.failedClients = SeqSet(@),
    !.comm.pending = SeqSet(@), !.comm.deadView = SeqSet(@),
    !.mon.pending = SeqSet(@), !.mon.deadView = SeqSet(@),
    !.committed = SeqSet(@), !.saved = SeqSet(@), !.unknownSeen = SeqSet(@)]

\* Mandatory strong post-state check: every event supplies the complete state.
\* Equality checks changed AND unchanged fields, actual stats and ghost PCs.
\* Missing fields cause a failed replay; no optional/vacuous field guards.
ValidatePostState == /\ TraceStateShape(logline.state)
                     /\ s' = DecodeState(logline.state)
EventIs(name, node, argc) ==
    /\ l <= Len(TraceLog)
    /\ DOMAIN logline = {"name","nid","args","state","seq"}
    /\ logline.name = name /\ logline.nid = node /\ logline.seq = l
    /\ Len(logline.args) = argc
TraceInit == /\ Init /\ l = 1
             /\ TraceStateShape(Meta.initial)
             /\ s = DecodeState(Meta.initial)
'''
client_nodes={'ClientProcessTask','ClientExecutionError','ClientReceiveTask','ClientRetryResult','ClientLoseDispatchAck','ServerCommandDispatchAck'}
for a in actions:
 name=a['name'];args=a['args'];exp_args=['logline.args['+str(i+1)+']' for i in range(len(args))]
 argmap=dict(zip(args,exp_args))
 nid='"clock"' if name=='ClockAdvance' else ('"transport"' if name=='TaskDeliveryFailure' else (argmap['id']+'[2]' if name in client_nodes else '"server"'))
 a['traceNode']=nid
 text+='\n\\* '+a['source']+'\nTrace_'+name+' ==\n'
 # Match name/arity before dereferencing arguments used to derive node ID.
 text+='    /\\ l <= Len(TraceLog) /\\ logline.name = "'+name+'"\n'
 text+='    /\\ Len(logline.args) = '+str(len(args))+'\n'
 for arg in args:
  dom={'id':'Ids','c':'Clients','t':'Tasks','kind':'{"params","empty"}','mk':'MetricKinds'}.get(arg)
  if arg=='n':dom='1..Len(s.net['+argmap['id']+'[1]]['+argmap['id']+'[2]])'
  text+='    /\\ '+argmap[arg]+' \\in '+dom+'\n'
 text+='    /\\ EventIs("'+name+'", '+nid+', '+str(len(args))+')\n'
 text+='    /\\ '+name+('('+', '.join(exp_args)+')' if args else '')+'\n'
 text+='    /\\ ValidatePostState\n    /\\ l\' = l+1\n'
text+='\nMatchedAction ==\n    \\/ '+'\n    \\/ '.join('Trace_'+a['name'] for a in actions)+'\n'
text+=r'''
TraceNext ==
    \/ /\ l <= Len(TraceLog) /\ MatchedAction
    \/ /\ l > Len(TraceLog) /\ UNCHANGED tracevars

\* Fair cursor progression rules out arbitrary stuttering at a matchable event.
\* An unmatchable event has no enabled progression and cannot satisfy this goal.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
TraceCursorType == l \in 1..(Len(TraceLog)+1)
=============================================================================
'''
(D/'Trace.tla').write_text(text)
cfg='''SPECIFICATION TraceSpec
CHECK_DEADLOCK TRUE
CONSTANTS
'''+''.join('    '+c+' <- Trace'+c+'\n' for c in constants)+'''
INVARIANTS
    TypeOK
    TraceCursorType
    ProtectedBroadcastInput
    AtMostOneConsumer
    ReceiptAfterDecision
    CommittedRoundProvenance
    OneStandingTask
    CompletedHistoryBound
    CallbackRoundIsolation
    CallerLockDiscipline
    SavedWasCommitted
    CountMatchesSuccessfulReturns
PROPERTIES
    TraceMatched
\\* Candidate semantic assertions belong to hunt cfgs, not trace conformance.
\\* A real faulty execution must be able to conform to the source-faithful base.
'''
(D/'Trace.cfg').write_text(cfg)
(D/'checks/action-map.json').write_text(json.dumps(actions,indent=2)+'\n')
print('Wrote Trace.tla/Trace.cfg:',len(actions),'full base-action wrappers; no silent actions')
