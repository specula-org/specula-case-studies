from pathlib import Path
import json
O=Path(__file__).parent; acts=json.loads((O/'action-manifest.json').read_text())
faults=sorted({a['fault'] for a in acts if a['fault']})
limits={f:f.title()+'Limit' for f in faults}
text=r'''------------------------------- MODULE MC ---------------------------------
EXTENDS base
Original == INSTANCE base
CONSTANTS Scenario, MaxPending,
'''+', '.join(limits.values())+r'''
VARIABLE faultCounts
mcvars == <<vars, faultCounts>>
FaultLimits == ['''+', '.join(f'{f} |-> {limits[f]}' for f in faults)+r''']
MCInit == Init /\ faultCounts = [k \in DOMAIN FaultLimits |-> 0]

\* Only external inputs and injected faults consume counters. Backend replies,
\* reapplication steps, cleanup work, recovery, UUID allocation and server retry
\* all remain unbounded reactive actions. Scenario guards restrict input schedules.
InputStart(p) ==
    CASE Scenario = "convergence" -> TRUE
      [] Scenario = "race" -> faultCounts.start = 0 \/
             (\E t \in Ops : op[t].kind = "reset" /\ op[t].seen = None /\
                  op[t].pc \in {"prepare","fork","rebuild","submit-base","write-wait","submit-create"})
      [] OTHER -> faultCounts.start = 0
InputReset(b) ==
    CASE Scenario = "missing" -> db.current = None /\ faultCounts.delete > 0
      [] Scenario = "race" -> faultCounts.can >= 2 /\ faultCounts.delete > 0
      [] Scenario = "reapply" -> faultCounts.can > 0
      [] OTHER -> TRUE
InputDelete(r) ==
    IF Scenario \in {"missing","race"} THEN db.current = r /\ faultCounts.can > 0
    ELSE TRUE
'''
domains={'p':'Ops','r':'Runs','s':'Runs','q':'ResetIDs','b':'Runs','cut':'2..HistoryLimit','ex':'SUBSET {"Signal","Update"}','payload':'Payloads'}
quant=[]; reactive=[]
for a in acts:
    name,args,kind=a['name'],a['args'],a['fault']
    sig=name+('('+args+')' if args else '')
    guard=''
    if name=='StartWorkflowExecution':guard='    /\\ InputStart(p)\n'
    elif name=='ResetWorkflowExecution':guard='    /\\ q \\notin audit.wanted /\\ InputReset(b)\n'
    elif name=='DeleteWorkflowExecution':guard='    /\\ InputDelete(r)\n'
    elif name=='ReplayResetRequest' :guard='    /\\ op[p].req \\in ResetIDs\n'
    text+='\nMC'+sig+' ==\n'+guard
    if kind:text+='    /\\ faultCounts.'+kind+' < '+limits[kind]+'\n'
    text+='    /\\ Original!'+sig+'\n'
    if kind:text+='    /\\ faultCounts\' = [faultCounts EXCEPT !.'+kind+' = @+1]\n'
    else:text+='    /\\ UNCHANGED faultCounts\n'
    aa=[x.strip() for x in args.split(',')] if args else []
    d={**domains,'id':'StartIDs' if name in {'StartWorkflowExecution','ContinueAsNew'} else 'UpdateIDs'}
    q=('\\E '+', '.join(x+' \\in '+d[x] for x in aa)+' : ') if aa else ''
    quant.append(q+'MC'+sig)
    if not kind:reactive.append(q+'MC'+sig)
text+='\nMCNext ==\n    \\/ '+'\n    \\/ '.join(quant)+'\n'
text+='\nReactiveNext ==\n    \\/ '+'\n    \\/ '.join(reactive)+'\n'
text+=r'''
MCSpec == MCInit /\ [][MCNext]_mcvars
MCTypeOK == TypeOK /\ \A k \in DOMAIN FaultLimits : faultCounts[k] \in 0..FaultLimits[k]
PendingBuffer == Cardinality({r \in Runs : pending[r].state \in {"submitted","current-appended","precheck","ready"}}) <= MaxPending
MCConstraint == HistoryBound /\ PendingBuffer
\* Never put counters into a VIEW used for state fingerprinting: those counters
\* determine enabled behavior. This diagnostic view is intentionally not configured.
MCView == vars
Symmetry == Permutations(Runs) \cup Permutations(Ops)
\* Liveness uses action-instance fairness, not the weak fairness of one giant OR.
RecoveryFairness ==
    /\ WF_mcvars(MCAcquireShard)
    /\ \A p \in Ops :
          /\ WF_mcvars(MCRetryResetWorkflowExecution(p))
          /\ WF_mcvars(MCGetWorkflowLease_Base(p))
          /\ WF_mcvars(MCGetCurrentWorkflowRunID(p))
          /\ WF_mcvars(MCGetWorkflowLease_Current(p))
          /\ WF_mcvars(MCInvoke_Deduplicate(p))
          /\ WF_mcvars(\E r \in Runs : MCInvoke_NewRunID(p,r))
          /\ WF_mcvars(MCResetWorkflow_UpdateResetRunID(p))
          /\ WF_mcvars(MCForkHistoryBranch(p))
          /\ WF_mcvars(MCRebuild(p))
          /\ WF_mcvars(MCReadHistoryBranch(p))
          /\ WF_mcvars(MCReapplyEvents(p))
          /\ WF_mcvars(MCReapplyEventsFromBranch_NextRun(p))
          /\ WF_mcvars(MCGetNextEventIDBranchToken(p))
          /\ WF_mcvars(MCScheduleWorkflowTask(p))
          /\ WF_mcvars(MCUpdateWorkflowExecution_BypassCurrent(p))
          /\ WF_mcvars(MCCreateWorkflowExecution_BrandNew(p))
          /\ WF_mcvars(MCUpdateWorkflowExecution_WithNew(p))
          /\ WF_mcvars(MCConflictResolveWorkflowExecution(p))
          /\ WF_mcvars(MCCreateWorkflowExecution_Start(p))
          /\ WF_mcvars(MCInvoke_ReturnSuccess(p))
          /\ WF_mcvars(MCReleaseWorkflowLease_Success(p))
          /\ WF_mcvars(MCReceiveResetResponse(p))
          /\ WF_mcvars(MCReleaseWorkflowLease_Error(p))
    /\ \A r \in Runs :
          /\ WF_mcvars(MCAppendHistoryNodes_Current(r))
          /\ WF_mcvars(MCAppendHistoryNodes(r))
          /\ WF_mcvars(MCAssertNotCurrentExecution(r))
          /\ WF_mcvars(MCCommitWorkflowExecution(r))
          /\ WF_mcvars(MCRejectWorkflowExecution(r))
          /\ WF_mcvars(MCPersistenceReturn(r))
          /\ WF_mcvars(MCDeleteExecutionTask(r))
          /\ WF_mcvars(MCDeleteWorkflowExecution_AcquireIO(r))
          /\ WF_mcvars(MCDeleteCurrentWorkflowExecution(r))
          /\ WF_mcvars(MCDeleteWorkflowMutableState(r))
          /\ WF_mcvars(MCGetHistoryTreeContainingBranch(r))
          /\ WF_mcvars(MCDeleteHistoryBranch_SQL(r))
          /\ WF_mcvars(MCDeleteHistoryBranch_CassandraRow(r))
          /\ WF_mcvars(MCDeleteHistoryBranch_CassandraRanges(r))
          /\ WF_mcvars(MCAddWorkflowTaskStartedEvent(r))
          /\ WF_mcvars(MCCompleteWorkflowExecution(r))
RecoverySpec == MCSpec /\ RecoveryFairness
\* An unfulfilled valid request with exhausted symbols is an incomplete bound,
\* never a recovery success. Liveness cfg enables this invariant as a tripwire.
FreshRunCapacity == ~RunIDExhausted
=============================================================================
'''
(O/'MC.tla').write_text(text)
basevals=dict(timeout=0,append=0,start=1,reset=1,can=1,delete=1,update=0,signal=0,age=0,crash=0,uncertain=0,reject=0,response=0,replay=0,read=0)
core=['CurrentExecutionConsistency','CallbackSourceIdentity']
scenarioInv=['AcknowledgedResetExists','ImmediateRetryIdentity','FencedOldAttempt','ReapplyProvenance','ReachableHistoryRetained']
def cfg(name,scenario,backend='SQL',io=1,runs=5,ops=1, inv=(),vals=None, structural=False,live=False,shortage=False):
    vv=basevals| (vals or {})
    c=('SPECIFICATION RecoverySpec\n' if live else 'INIT MCInit\nNEXT MCNext\n')+'CONSTANTS\n'
    c+=' Runs = {'+', '.join('abcdefg'[:runs])+'}\n Ops = {'+', '.join(['p','q'][:ops])+'}\n'
    c+=' ResetIDs = {"reset1", "reset2"}\n StartIDs = {"start1"}\n UpdateIDs = {"u1", "u2"}\n Payloads = {"x", "y"}\n'
    c+=f' Backend = "{backend}"\n IOConcurrency = {io}\n HistoryLimit = 16\n StartMapPresent = TRUE\n ScannerAfterRequestDeadline = {str(not shortage).upper()}\n Scenario = "{scenario}"\n MaxPending = {runs}\n'
    c+=''.join(' '+limits[k]+' = '+str(vv[k])+'\n' for k in faults)
    c+='CONSTRAINT MCConstraint\n'
    if not live:c+='SYMMETRY Symmetry\n'
    c+='CHECK_DEADLOCK FALSE\n\\* Core safety\nINVARIANTS\n '+ '\n '.join(core)+'\n'
    if structural:c+='\\* Structural convergence checks\n MCTypeOK\n IOCapacity\n LeaseOwnership\n'
    if inv:c+='\\* Targeted brief properties\n '+ '\n '.join(inv)+'\n'
    if structural:c+='\\* Scenario checks are enabled only in hunt configurations.\n'+''.join('\\* INVARIANT '+x+'\n' for x in scenarioInv)
    if live:c+=' FreshRunCapacity\nPROPERTY HealthyRetryRecovers\n'
    (O/name).write_text(c)
# Small, convergent standard safety configuration; larger faults are in hunts.
cfg('MC.cfg','convergence',runs=3,structural=True)
for backend,io,suffix in [('SQL',1,'sql'),('Cassandra',1,'cassandra')]:
    cfg(f'MC_hunt_scenario2_{suffix}.cfg','missing',backend,io,runs=7,
        inv=['AcknowledgedResetExists','FencedOldAttempt'],vals=dict(append=1,crash=1,uncertain=2,reject=1))
    # S1 is deliberately merged into recovery, rather than a standalone identity rediscovery.
    cfg(f'MC_hunt_scenario1_2_replay_{suffix}.cfg','missing',backend,io,runs=7,
        inv=['AcknowledgedResetExists','ImmediateRetryIdentity','FencedOldAttempt'],
        vals=dict(crash=1,uncertain=1,response=1,replay=1))
    cfg(f'MC_hunt_scenario3_{suffix}.cfg','race',backend,io if backend=='Cassandra' else 2,runs=7,ops=2,
        inv=['FencedOldAttempt','AcknowledgedResetExists'],vals=dict(start=2,reset=2,can=2,crash=1,uncertain=1))
    cfg(f'MC_hunt_scenario4_{suffix}.cfg','reapply',backend,io,runs=7,
        inv=['ReapplyProvenance','AcknowledgedResetExists'],vals=dict(can=2,update=2,signal=1,read=1,crash=1))
    cfg(f'MC_hunt_scenario5_{suffix}.cfg','cleanup',backend,io,runs=7,
        inv=['ReachableHistoryRetained','AcknowledgedResetExists','ReapplyProvenance'],
        vals=dict(can=2,delete=2,signal=1,age=2,timeout=1,append=1,crash=1,uncertain=1))
cfg('MC_hunt_scenario3_sql_io1.cfg','race','SQL',1,runs=7,ops=2,
    inv=['FencedOldAttempt','AcknowledgedResetExists'],vals=dict(start=2,reset=2,can=2,crash=1,uncertain=1))
# Retained source, no further deletion once the initial missing-current setup ends,
# no Update collision, and enough symbols for the configured fault schedule.
cfg('MC_hunt_scenario2_liveness.cfg','missing',runs=7,
    inv=['AcknowledgedResetExists','FencedOldAttempt'],vals=dict(crash=1,uncertain=1,reject=1),live=True)

# Explicit sensitivity experiment: scanner age shorter than an active RPC deadline.
cfg('MC_hunt_scenario5_short_age_sql.cfg','cleanup','SQL',1,runs=7,
    inv=['ReachableHistoryRetained','AcknowledgedResetExists','ReapplyProvenance'],
    vals=dict(can=2,delete=2,signal=1,age=2,append=1,crash=1,uncertain=1),shortage=True)
