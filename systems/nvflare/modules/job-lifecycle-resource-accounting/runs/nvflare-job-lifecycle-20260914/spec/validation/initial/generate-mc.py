from pathlib import Path
import importlib.util
P=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('gen',P/'generate.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
A=g.A
faults=sorted({a['fault'] for a in A if a['fault']})
cap=lambda x:x[0].upper()+x[1:]+'Limit'
mc='------------------------------- MODULE MC -------------------------------\nEXTENDS base\nBase == INSTANCE base\n\nCONSTANTS '+', '.join(cap(k) for k in faults)+', MaxMessageBuffer\nVARIABLE faults\nmcvars == <<vars,faults>>\n\nLimits == ['+', '.join(k+' |-> '+cap(k) for k in faults)+']\nMCInit == Base!Init /\\ faults = [k \\in DOMAIN Limits |-> 0]\n\n'
for a in A:
 if not a['fault']:continue
 k=a['fault']
 mc+='\\* '+a['source']+'; Scenario '+a['scenario']+'.\n'
 mc+=g.invocation(a,'MC')+' ==\n    /\\ faults.'+k+' < Limits.'+k+'\n    /\\ '+g.invocation(a,'Base!')+'\n    /\\ faults\' = [faults EXCEPT !.'+k+' = @+1]\n\n'
normal=[a for a in A if not a['fault']]
mc+='NormalNext ==\n'+'\n'.join('    \\/ '+g.quantified(a,g.invocation(a,'Base!')) for a in normal)+'\n\n'
mc+='FaultNext ==\n'+'\n'.join('    \\/ '+g.quantified(a,g.invocation(a,'MC')) for a in A if a['fault'])+'\n\n'
mc+='MCNext == \\/ /\\ NormalNext /\\ UNCHANGED faults\n          \\/ FaultNext\n\nMCSpec == MCInit /\\ [][MCNext]_mcvars\n\n'
mc+='\\* Concrete fairness assumptions for the optional progress configuration.\n\\* Includes normal exit, delivery, cleanup ticks, retries and each service step.\n\\* TV-2/TV-3 service death and permanently unavailable components are outside it.\nNormalFairness ==\n'
domains={'s':'Sites','t':'Tokens','j':'Jobs','m':'AllMessages'}
for a in normal:
 q=(r'\A '+', '.join(p+' \\in '+domains[p] for p in a['params'])+' : ') if a['params'] else ''
 mc+='    /\\ '+q+'WF_mcvars('+g.invocation(a,'Base!')+' /\\ UNCHANGED faults)\n'
mc+='\nMCFairSpec == MCSpec /\\ NormalFairness\n\n'
mc+=r'''\* Preserve the required-site role. MC uses model values for site identities.
\* With two sites and one mandatory site this is identity; a supplied three-site
\* config reduces the two interchangeable optional sites. Disable for liveness.
MCSymmetry == {p \in Permutations(Sites) : \A s \in RequiredSites : p[s]=s}
MessageBound == Cardinality(network) <= MaxMessageBuffer
MCTypeOK == TypeOK /\ DOMAIN faults=DOMAIN Limits /\
            (\A k \in DOMAIN Limits : faults[k] \in 0..Limits[k])
\* Available display projection; deliberately NOT enabled as TLC VIEW because
\* counter values affect future enabled faults and erasing them can prune paths.
MCView == vars
=============================================================================
'''
(P/'MC.tla').write_text(mc)
core=['ResourceConservation','SchedulerCapacity','RetryHistoryMatchesCount','SingleSupportedStart','WaitBeforeNormalFree']
ext=['ProcessBindingMatchesOwnership','NoFreeWhileInUse','CleanupOwnerOrCompleted','AcceptedPreRunAbortPersists','NoTerminalResurrection']
def cfg(name,limits,invs,jobs=2,strict=False,maxjobs=2,minsites=1,attempts=11,temporal=(),three=False,standard=False):
 constants=g.constants(jobs=jobs,strict=strict,maxjobs=maxjobs,minsites=minsites,attempts=attempts)
 constants=constants.replace('Sites = {"site-1", "site-2"}','Sites = {s1, s2, s3}' if three else 'Sites = {s1, s2}').replace('RequiredSites = {"site-1"}','RequiredSites = {s1}')
 out='\\* '+name+'; pinned valid one-unit jobs. Hunt after trace convergence.\n'
 out+='SPECIFICATION '+('MCFairSpec' if temporal else 'MCSpec')+'\n'+constants
 out+=' MaxMessageBuffer = 64\n'+''.join(' '+cap(k)+' = '+str(limits.get(k,0))+'\n' for k in faults)
 out+='\n\\* Fault overrides; wrappers call the original Base instance.\n'
 out+=''.join(a['name']+' <- MC'+a['name']+'\n' for a in A if a['fault'])
 out+='\nINVARIANTS\n'+''.join(' '+i+'\n' for i in invs)
 if standard:
  out+='\n\\* Scenario-specific invariants are intentionally enabled in hunt cfgs.\n'
  out+=''.join('\\* INVARIANT '+i+'\n' for i in ext)
 if temporal:out+='\nPROPERTIES\n'+''.join(' '+i+'\n' for i in temporal)
 else:out+='\nSYMMETRY MCSymmetry\n'
 out+='CONSTRAINT MessageBound\nCHECK_DEADLOCK FALSE\n'
 (P/name).write_text(out)
cfg('MC.cfg',{k:1 for k in faults},['MCTypeOK']+core,standard=True)
cfg('MC_hunt_s1_environment.cfg',{'startTimeout':1},core+['ProcessBindingMatchesOwnership','NoFreeWhileInUse'])
cfg('MC_hunt_s1_optional_symmetry.cfg',{'startTimeout':1},core+['ProcessBindingMatchesOwnership','NoFreeWhileInUse'],three=True)
cfg('MC_hunt_s2_cleanup_handoff.cfg',{'waiterError':1},core+['NoFreeWhileInUse','CleanupOwnerOrCompleted'],jobs=1)
cfg('MC_hunt_s2_partial_start_strict.cfg',{'preLaunchError':1,'spawnError':1,'deployError':1,'startTimeout':1},core+['CleanupOwnerOrCompleted'],strict=True,minsites=2)
cfg('MC_hunt_s3_abort_status.cfg',{'adminAbort':1},core+['AcceptedPreRunAbortPersists'],jobs=1)
cfg('MC_hunt_s3_terminal_status.cfg',{},core+['NoTerminalResurrection'],jobs=1)
cfg('MC_hunt_s4_exit_cleanup.cfg',{'adminAbort':2,'childError':1,'reportError':1,'outcomeTimeout':1,'archiveError':1,'heartbeat':2,'loss':1,'checkTimeout':1,'deployTimeout':1,'startTimeout':1,'cancelTimeout':1},core+['NoFreeWhileInUse','CleanupOwnerOrCompleted'])
cfg('MC_hunt_s5_scheduling_progress.cfg',{'admissionError':1,'storeError':1,'archiveError':1},core+['CleanupOwnerOrCompleted'],maxjobs=1,temporal=['OtherEligibleJobProgress','ReservationEventuallyResolved','CleanupEventuallyReleased'])
print('wrote MC.tla, MC.cfg and',len(list(P.glob('MC_hunt_*.cfg'))),'hunt configurations')
