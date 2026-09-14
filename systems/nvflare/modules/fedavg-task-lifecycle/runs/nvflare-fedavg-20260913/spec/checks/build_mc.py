from pathlib import Path
import json
D=Path(__file__).resolve().parent.parent
actions=json.loads((D/'checks/action-map.json').read_text())
faults=[a for a in actions if a['fault']]
normal=[a for a in actions if not a['fault']]
dom={'c':'Clients','id':'Ids','n':'1..Len(s.net[id[1]][id[2]])','kind':'{"params","empty"}','mk':'MetricKinds','t':'Tasks'}
def sig(a,prefix=''):
 return prefix+a['name']+('('+', '.join(a['args'])+')' if a['args'] else '')
def quant(a,expr):
 for arg in reversed(a['args']): expr='\\E '+arg+' \\in '+dom[arg]+' : '+expr
 return expr
keys=[a['fault'] for a in faults]
text=r'''------------------------------- MODULE MC -------------------------------
EXTENDS base
B == INSTANCE base

\* Scenario-derived ordinary failures/retries only. Never revert existing guards.
CONSTANTS FaultLimits, MaxMessages, FilterAfterContribution, CancelAfterContribution
VARIABLE faults
mcvars == <<s, faults>>
FaultNames == {'''+', '.join('"'+k+'"' for k in keys)+r'''}
ASSUME /\ FaultLimits \in [FaultNames -> Nat]
       /\ MaxMessages \in Nat \ {0}
       /\ FilterAfterContribution \in BOOLEAN /\ CancelAfterContribution \in BOOLEAN
MCInit == /\ B!Init /\ faults = [k \in FaultNames |-> 0]
'''
for a in faults:
 text+='\n\\* '+a['source']+'; Scenario mechanism budget, never a reactive-step budget.\n'
 text+=sig(a,'MC')+' ==\n    /\\ faults.'+a['fault']+' < FaultLimits.'+a['fault']+'\n'
 if a['fault']=='filter':text+='    /\\ (~FilterAfterContribution \\/ s.aggr.receivedCount > 0)\n'
 if a['fault'] in {'cancel','before'}:text+='    /\\ (~CancelAfterContribution \\/ s.aggr.receivedCount > 0)\n'
 text+='    /\\ '+sig(a,'B!')+'\n    /\\ faults\' = [faults EXCEPT !.'+a['fault']+' = @+1]\n'
text+='\n\\* Every normal implementation/environment reaction passes through in full.\nNormalNext ==\n    \\/ '+'\n    \\/ '.join(quant(a,sig(a,'B!')) for a in normal)+'\n'
text+='\nMCNext ==\n    \\/ /\\ NormalNext\n       /\\ UNCHANGED faults\n    \\/ '+'\n    \\/ '.join(quant(a,sig(a,'MC')) for a in faults)+'\n'
text+=r'''
MCSpec == MCInit /\ [][MCNext]_mcvars

\* Finite queue constraint; ACK/lost/gone entries are historical observations.
\* Bounds in configs fit all initial responses plus permitted retries.
BufferedMessages == UNION {
    {<<id,n>> : n \in {j \in 1..Len(s.net[id[1]][id[2]]) :
                         s.net[id[1]][id[2]][j] \in {"queued","handled"}}} : id \in Ids}
MessageBufferBound == Cardinality(BufferedMessages) <= MaxMessages

\* Symmetry must preserve selection and required-sites policy. Model-value
\* clients in MC configs; Trace derives actual string client IDs instead.
ClientSymmetry == {p \in Permutations(Clients) :
    /\ {p[c] : c \in Selected} = Selected
    /\ {p[c] : c \in RequiredSites} = RequiredSites}
MCView == s
\* Counter-free view is available for diagnostics, but not applied as TLC VIEW:
\* merging different remaining fault budgets needs a dominance argument first.
MCTypeOK == TypeOK /\ faults \in [FaultNames -> Nat]
                     /\ \A k \in FaultNames : faults[k] <= FaultLimits[k]
DynamicErrorSignalsAbort == ErrorMode = "dynamic" /\ s.aggr.failedClients /= {} => s.wf.abort

\* Only internal request/callback completion and monitor/round scheduling are
\* fair. No fairness promises a permanently missing client's result or delivery.
\* Strong fairness on communicator acquisition supplies fair monitor admission
\* under contention; other internal stages use weak fairness.
'''
fairnames=[a for a in normal if not a['args'] and a['name'] not in {'ClockAdvance','WFCommMonitorAcquire'}]
# This includes all internal no-arg comm steps and round progression. MonitorSelect/dead reads are parameterized below.
text+='ProgressFairness ==\n    /\\ SF_mcvars(B!WFCommMonitorAcquire /\\ UNCHANGED faults)\n    /\\ WF_mcvars(B!ClockAdvance /\\ UNCHANGED faults)\n'
text+='\n'.join('    /\\ WF_mcvars('+sig(a,'B!')+' /\\ UNCHANGED faults)' for a in fairnames)+'\n'
for name in ['WFCommCheckDeadClient','WFCommReadPolicyClient','WFCommReadTaskDeadClient','WFCommMonitorSelect','WFCommProcessTaskRequest','WFCommResendTask']:
 a=next(a for a in actions if a['name']==name);v=a['args'][0]
 text+='    /\\ \\A '+v+' \\in '+dom[v]+' : SF_mcvars('+sig(a,'B!')+' /\\ UNCHANGED faults)\n'
text+='\nMCLiveSpec == MCSpec /\\ ProgressFairness /\\ CallbacksTerminate\n=============================================================================\n'
(D/'MC.tla').write_text(text)
# Explicit source configuration and mechanism budgets. Only constants / budgets vary.
base=dict(Clients='{c1, c2}',Selected='{c1, c2}',NumRounds='2',NumKeys='2',HistoryLimit='4',
 ErrorMode='"dynamic"',OutboundFilter='FALSE',LazyOffload='FALSE',AllocationFailure='FALSE',
 ConversionFailure='FALSE',BeforeSendFailure='FALSE',AllowEmpty='TRUE',MetricKinds='{"present"}',
 MinSites='2',RequiredSites='{}',AllowPartialCompletion='FALSE',MaxMessages='6',
 FilterAfterContribution='FALSE',CancelAfterContribution='FALSE')
core=['TypeOK','CommittedRoundProvenance']
struct=['MCTypeOK','ProtectedBroadcastInput','AtMostOneConsumer','ReceiptAfterDecision','CommittedRoundProvenance',
 'OneStandingTask','CompletedHistoryBound','CallbackRoundIsolation','CallerLockDiscipline','SavedWasCommitted','CountMatchesSuccessfulReturns']
manifest={}
def config(name,description,overrides,budget,inv,live=False,standard=False):
 opts=base|overrides
 limits={k:budget.get(k,0) for k in keys}
 cfg='\\* '+description+'\n'
 cfg+= 'SPECIFICATION MCLiveSpec\n' if live else 'INIT MCInit\nNEXT MCNext\n'
 cfg+='CHECK_DEADLOCK FALSE\nCONSTRAINT MessageBufferBound\n'
 if not live:cfg+='SYMMETRY ClientSymmetry\n'
 cfg+='CONSTANTS\n'+''.join('    '+k+' = '+v+'\n' for k,v in opts.items())
 # Config grammar does not accept records: override constant with an MC operator.
 opname='Limits_'+name.removesuffix('.cfg').replace('MC_hunt_','').replace('MC','standard')
 global text
 pos=text.rfind('=============================================================================')
 op='\n'+opname+' == ['+', '.join(k+' |-> '+str(v) for k,v in limits.items())+']\n'
 text=text[:pos]+op+text[pos:]
 cfg+='    FaultLimits <- '+opname+'\n\n'
 cfg+='\\* Standard core safety'+(' and structural checks' if standard else '; targeted Scenario assertions follow')+'.\n'
 cfg+='INVARIANTS\n'+''.join('    '+i+'\n' for i in inv)
 if standard:
  cfg+='\\* Candidate assertions disabled during convergence; enabled in hunting cfgs.\n\\* CommittedAcceptanceConsistency\n\\* AbnormalTerminationVisible\n'
 if live:cfg+='PROPERTY EligibleTaskEventuallyDrains\n'
 (D/name).write_text(cfg)
 manifest[name]=dict(description=description,constants=opts,faults=limits,invariants=inv,live=live)
config('MC.cfg','Default Recipe path: no optional filters/offload; ordinary retries, result-code errors and direct cancellation enabled.',{},
       dict(retry=1,ackLoss=1,resultError=1,cancel=1,dead=1,delivery=1,resend=1),struct,standard=True)
config('MC_hunt_s1_protected_input.cfg','S1: staggered retrieval while callback aggregation progresses; existing snapshot/header protection retained.',{}, {},
       core+['ProtectedBroadcastInput'])
config('MC_hunt_s2_identity_history.cfg','S2: lost ACK, checked retry delayed across retirement; capacity 1 explicitly abstracts finite LRU eviction.',
       dict(HistoryLimit='1'),dict(ackLoss=1,retry=1),core+['AtMostOneConsumer','ReceiptAfterDecision'])
config('MC_hunt_s3_partial_parameters.cfg','S3 / MC-1: active-Cell streamed PyTorch disk offload; one per-key materialization failure; no outbound filter or cancellation.',
       dict(LazyOffload='TRUE',AllowEmpty='FALSE'),dict(param=1),core+['CommittedAcceptanceConsistency'])
config('MC_hunt_s3_metric_failure.cfg','S3 / MC-1: ordinary metric preparation allocation failure after completed parameter history; in-memory payloads.',
       dict(AllocationFailure='TRUE',AllowEmpty='FALSE'),dict(metricPrep=1),core+['CommittedAcceptanceConsistency'])
config('MC_hunt_s3_conversion_control.cfg','S3 negative control: conversion fails BEFORE consumer mutation; empty results and absent/empty metrics also supported.',
       dict(ConversionFailure='TRUE',MetricKinds='{"present", "none", "empty"}'),dict(conversion=1),core+['CommittedAcceptanceConsistency'])
config('MC_hunt_s4_filter_retirement.cfg','S4 / MC-2 first hunt: at least one callback counted, then a configured outbound filter fails/cancels another delivery; no run abort injected.',
       dict(OutboundFilter='TRUE',FilterAfterContribution='TRUE',AllowEmpty='FALSE'),dict(filter=1),core+['AbnormalTerminationVisible'])
config('MC_hunt_s4_cancel_overlap.cfg','S4: mark-only direct cancellation may overlap an admitted callback; ordinary save policy remains all-selected.',
       dict(CancelAfterContribution='TRUE',AllowEmpty='FALSE'),dict(cancel=1),core+['AbnormalTerminationVisible'])
config('MC_hunt_s4_prepare_error.cfg','S4: optional before-send event handler fails after an earlier accepted contribution, marking ERROR.',
       dict(BeforeSendFailure='TRUE',CancelAfterContribution='TRUE',AllowEmpty='FALSE'),dict(before=1),core+['AbnormalTerminationVisible'])
config('MC_hunt_s5_dead_policy.cfg','S5 / MC-2: two selected clients plus one unselected live site; min_sites=1 permits monitor to reach CLIENT_DEAD; no filters/cancellation.',
       dict(Clients='{c1, c2, c3}',Selected='{c1, c2}',MinSites='1',AllowEmpty='FALSE'),dict(dead=1),core+['AbnormalTerminationVisible'])
config('MC_hunt_s5_progress.cfg','S5: default all-selected policy; response errors, dead reports and direct cancellation; fair terminating callbacks/monitor; no symmetry in temporal checking.',
       dict(NumRounds='1',NumKeys='1',MetricKinds='{"present", "none", "empty"}'),dict(resultError=1,dead=1,cancel=1),
       core+['ReceiptAfterDecision','DynamicErrorSignalsAbort'],live=True)
config('MC_hunt_s5_resilient.cfg','S5: explicit ignore_result_error=True variant; non-OK result rejected without panic; responses still count toward task drain.',
       dict(ErrorMode='"resilient"'),dict(resultError=1),core+['CommittedAcceptanceConsistency','ReceiptAfterDecision'])
(D/'MC.tla').write_text(text)
(D/'checks/config-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Wrote MC.tla, MC.cfg and',len(manifest)-1,'hunt configs')
