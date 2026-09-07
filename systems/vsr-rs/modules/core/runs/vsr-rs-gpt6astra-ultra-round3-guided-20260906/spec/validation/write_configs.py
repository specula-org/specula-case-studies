from pathlib import Path
root=Path(__file__).resolve().parent.parent
common='''SPECIFICATION MCSpec
CONSTANTS
  Server = {0,1,2}
  Clients = {c0,c1}
  Values = {"A","AA","B"}
  FullValue = "AA"
  PrefixValue = "A"
  PrimaryTimeout = 3
  FailureBudget = 1
'''
def write(name, *, ticks=12, requests=3, crashes=1, losses=1, duplicates=1,retries=3,partial=0,errors=0,views=4,logs=4,network=16,integration=False,live=False,healthy='{0,1,2}',invs=(),props=()):
 s=common
 for key,value in dict(IntegrationMode=integration,TickLimit=ticks,RequestLimit=requests,CrashLimit=crashes,LossLimit=losses,DuplicateLimit=duplicates,RetryLimit=retries,PartialLimit=partial,ReadErrorLimit=errors,MaxView=views,MaxLog=logs,MaxNetwork=network,LiveMode=live,StableHealthy=healthy).items():
  if isinstance(value,bool): value=str(value).upper()
  s+=f'  {key} = {value}\n'
 s+='''\nOnIdle <- MCOnIdle
Crash <- MCCrash
LoseMessage <- MCLoseMessage
ClientOnRequest <- MCClientOnRequest
ClientOnIdle <- MCClientOnIdle
RunSenderBeginPartial <- MCPartial
RunPeerAcceptorReadError <- MCReadError
CONSTRAINT StateConstraint
VIEW MCView
CHECK_DEADLOCK FALSE
'''
 if not live:s+='SYMMETRY Symmetry\n'
 s+='\nINVARIANTS\n'+''.join(f'  {i}\n' for i in invs)
 if props:s+='\nPROPERTIES\n'+''.join(f'  {p}\n' for p in props)
 if name=='MC.cfg':s+='''
\\* Standard safety and structural invariants above; extension hunts below.
\\* INVARIANT CommittedHistorySurvives
\\* INVARIANT PreparedPrefixAgreement
\\* INVARIANT ClientLinearizability
\\* INVARIANT NoDuplicateExecution
\\* INVARIANT DurableViewFloor
\\* PROPERTY RecoveryCompletesUnderStability
\\* PROPERTY StableMajorityServesNewWork
'''
 (root/name).write_text(s)
core=('CommittedPrefixAgreement','DistinctQuorumAndPrimary','NoAssertionFailure')
write('MC.cfg',ticks=8,requests=2,crashes=1,invs=core+('MCTypeOK',))
# Scenario 1: only the real encoder-derived Prepare.Put prefix, after sender crash.
write('MC_hunt_s1_eof_prefix.cfg',ticks=12,requests=2,crashes=1,losses=0,duplicates=0,retries=2,partial=1,integration=True,invs=core+('ClientLinearizability',))
# A companion defers the early original-operation alarm to reach SET->GET harm.
write('MC_hunt_s1_eof_client_result.cfg',ticks=16,requests=2,crashes=1,losses=0,duplicates=0,retries=3,partial=1,integration=True,invs=('DistinctQuorumAndPrimary','NoAssertionFailure','ClientLinearizability'))
# Three crash/recovery cycles, with recovery completion required before another
# healthy replica can fail. Each cycle has multiple recovery retry opportunities.
write('MC_hunt_s2_rolling_history.cfg',ticks=30,requests=3,crashes=3,losses=1,duplicates=1,retries=4,views=6,network=20,invs=core+('CommittedHistorySurvives','PreparedPrefixAgreement','ClientLinearizability','NoDuplicateExecution'))
# Two recovery cycles plus enough idle calls for old/new response snapshots.
write('MC_hunt_s3_recovery_views.cfg',ticks=26,requests=3,crashes=2,losses=1,duplicates=2,retries=4,views=6,network=22,invs=core+('CommittedHistorySurvives','PreparedPrefixAgreement','ClientLinearizability','DurableViewFloor'))
# Persistence and individual publication are unbounded reactive steps.
write('MC_hunt_s4_partial_publication.cfg',ticks=22,requests=3,crashes=2,losses=0,duplicates=1,retries=4,views=5,network=20,invs=core+('CommittedHistorySurvives','ClientLinearizability','DurableViewFloor','NoDuplicateExecution'))
# Live mode removes finite tick/retry counters after stabilization. Primary 0
# becomes permanently unavailable; fresh requests continue up to RequestLimit.
write('MC_hunt_s5_stable_minority.cfg',ticks=0,requests=3,crashes=1,losses=0,duplicates=0,retries=0,views=6,logs=5,network=24,live=True,healthy='{1,2}',invs=core+('LivenessBoundsNotReached',),props=('StableMajorityServesNewWork','RecoveryCompletesUnderStability','BoundedNewWorkIsAdmitted'))
# Scenario 3/5 composition: one recovering node may rejoin after finite faults.
write('MC_hunt_s5_stable_recovery.cfg',ticks=12,requests=3,crashes=1,losses=1,duplicates=1,retries=2,views=6,logs=5,network=24,live=True,invs=core+('DurableViewFloor','LivenessBoundsNotReached'),props=('RecoveryCompletesUnderStability','StableMajorityServesNewWork','BoundedNewWorkIsAdmitted'))
# Tiny exhaustive assembly check only; not a scenario claim.
write('MC_smoke.cfg',ticks=0,requests=1,crashes=0,losses=0,duplicates=0,retries=0,views=1,logs=2,network=10,invs=core+('MCTypeOK','CommittedHistorySurvives','PreparedPrefixAgreement','ClientLinearizability','NoDuplicateExecution','DurableViewFloor'))
