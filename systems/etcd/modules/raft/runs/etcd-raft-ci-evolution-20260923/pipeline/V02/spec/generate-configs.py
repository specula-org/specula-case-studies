"""Regenerate checking inputs. This does not run checks or modify any CI verdict."""
from pathlib import Path
out=Path(__file__).resolve().parent
base=dict(Server='{s1, s2, s3, s4}',Joining='{s4}',RawNodes='{s1, s2, s3, s4}',
    PreVoteNodes='{s1, s2, s3, s4}',CheckQuorumNodes='{s1, s2, s3, s4}',NoForwardNodes='{}',
    RequestId='{1, 2, 3, 4}',PayloadWeights='{0, 1, 3}',EncodedWeights='{1, 2}',
    ElectionTick='3',HeartbeatTick='1',MaxInflight='2',MaxMsgSize='2',MaxReadySize='2',
    MaxUncommitted='2',SendPolicy='"Strict"',PersistPolicy='"Atomic"',EarlyAdvance='TRUE',
    ReadFence='"Inclusive"',CancelChanges='{}',CancelUnknownRemovals='TRUE',RecoveryMode='"Replay"')
limits=dict(TickLimit=6,CampaignLimit=4,RequestLimit=4,CrashLimit=2,LossLimit=2,
    DuplicateLimit=1,TransferLimit=2,SnapshotLimit=2,CompactLimit=2,AvailabilityLimit=2,
    CancelLimit=1,ReportLimit=3,QuiesceLimit=0,MaxTermLimit=5,MaxLogLimit=14,MaxMsgBufferLimit=20,
    WorkloadKinds='{"Normal", "AddVoter", "AddLearner", "Remove", "Update", "Read"}',AllowEmptyContext='FALSE')
core=['ElectionSafety','LogMatching','LeaderCompleteness','CommittedHistory','AppliedAgreement']
extra=['VoteRecovery','RecoveryBacking','PromiseBacking','ConfigurationOrigin','ConfigurationTransitionSafety',
    'LearnerEligibility','QuorumAccounting','ReplicationEvidence','SnapshotBacking','AckPreservation',
    'ReadyAccounting','QuotaIntegrity','OutcomeSoundness','ReadBasis','ReadApplication','ReadCorrelation','NoUnexpectedFatal']
progress=['ElectionProgress','CatchupProgress','ManagementProgress','TransferSettlement','ReadProgress']
def config(name,values,enabled,mc=True,structural=False,comment=''):
    text='\\* '+comment+'\nSPECIFICATION '+('MCSpec' if mc else 'Spec')+'\nCONSTANTS\n'
    text+='    BootPeers <- DefaultBootPeers\n'
    for k,v in values.items(): text+=f'    {k} = {v}\n'
    text+='\n\\* Standard safety contracts\nINVARIANTS\n'
    text+=''.join('    '+p+'\n' for p in core)
    if structural:text+='\n\\* Structural checks\nINVARIANTS\n    '+('MCTypeOK' if mc else 'TypeOK')+'\n    LogStructure\n'
    if enabled:text+='\n\\* Scenario targets (enabled)\nINVARIANTS\n'+''.join('    '+p+'\n' for p in enabled)
    for p in extra:
        if p not in enabled:text+='\\* INVARIANT '+p+'\n'
    if mc:
        text+='\nCONSTRAINT StateConstraint\nSYMMETRY Symmetry\n'
        text+='\\* MCView is diagnostic only; fingerprinting retains fault counters.\n'
        text+='\\* Progress needs an unbounded service driver, not exhausted fault budgets.\n'
        text+=''.join('\\* PROPERTY '+p+'\n' for p in progress)
    text+='CHECK_DEADLOCK FALSE\n'
    (out/name).write_text(text)
config('base.cfg',base,[],False,True,'Unbounded reference; run bounded MC configs for exploration.')
config('MC.cfg',base|limits,[],True,True,'Convergence configuration. Extension properties remain enabled in hunt cfgs.')
hunts={
 '1_durability':(['VoteRecovery','RecoveryBacking','PromiseBacking','AckPreservation','NoUnexpectedFatal'],
                dict(RequestLimit=1,TransferLimit=0,SnapshotLimit=1,CompactLimit=1,CancelLimit=0,QuiesceLimit=0)),
 '2_election_transfer':(['LearnerEligibility','QuorumAccounting','ConfigurationOrigin','NoUnexpectedFatal'],
                dict(CampaignLimit=5,TickLimit=9,RequestLimit=3,TransferLimit=2,CrashLimit=1,SnapshotLimit=0,CompactLimit=0,CancelLimit=0)),
 '3_configuration_application':(['ConfigurationOrigin','ConfigurationTransitionSafety','ReadyAccounting','OutcomeSoundness'],
                dict(RequestLimit=4,CampaignLimit=4,TransferLimit=1,SnapshotLimit=0,CompactLimit=0,LossLimit=1,DuplicateLimit=0,CrashLimit=1,CancelLimit=0)),
 '4_replication_snapshot':(['ReplicationEvidence','SnapshotBacking','AckPreservation','QuotaIntegrity','NoUnexpectedFatal'],
                dict(RequestLimit=3,SnapshotLimit=2,CompactLimit=2,TickLimit=9,CampaignLimit=4,ReportLimit=4,TransferLimit=1,CancelLimit=0)),
 '5_reads':(['ReadBasis','ReadApplication','ReadCorrelation','QuorumAccounting','PromiseBacking'],
                dict(RequestLimit=4,CampaignLimit=3,TickLimit=6,TransferLimit=1,CrashLimit=1,SnapshotLimit=0,CompactLimit=0,CancelLimit=0)),
 '6_outcomes':(['OutcomeSoundness','ReadyAccounting','QuotaIntegrity','ReadCorrelation','NoUnexpectedFatal'],
                dict(RequestLimit=4,CampaignLimit=2,TransferLimit=1,CrashLimit=1,SnapshotLimit=0,CompactLimit=0,AllowEmptyContext='TRUE',QuiesceLimit=1)),
}
for label,(props,changes) in hunts.items():
    config('MC_hunt_'+label+'.cfg',base|limits|changes,props,comment='Brief Scenario '+label.split('_')[0]+'. Candidate questions; reachability not yet established by traces/checking.')
# Caller alternatives are explicit separate inputs; they do not rewrite core semantics.
config('MC_hunt_1_same_batch.cfg',base|limits|hunts['1_durability'][1]|dict(SendPolicy='"SameBatch"',PersistPolicy='"EntriesHSnap"'),
       hunts['1_durability'][0],comment='S1 / MC-4: README 116-118 sequential storage with same-batch publication allowance.')
config('MC_hunt_1_parallel.cfg',base|limits|hunts['1_durability'][1]|dict(SendPolicy='"SameBatch"',PersistPolicy='"Parallel"'),
       hunts['1_durability'][0],comment='S1 / MC-4: alternative parallel-I/O interpretation; caller legality unresolved, not canonical.')
config('MC_hunt_5_singleton.cfg',base|limits|hunts['5_reads'][1]|dict(Server='{s1, s2}',Joining='{s2}',RawNodes='{s1, s2}',PreVoteNodes='{s1, s2}',CheckQuorumNodes='{s1, s2}'),
       hunts['5_reads'][0],comment='S5: singleton, learner promotion, removal and read identity; same coherent model.')
config('MC_hunt_3_node.cfg',base|limits|hunts['3_configuration_application'][1]|dict(RawNodes='{}',RecoveryMode='"AppliedAdapter"'),
       hunts['3_configuration_application'][0],comment='S3: Node wrapper and caller-recovered Config.Applied/InitialState adapter.')
# A genuinely exhaustive tiny developer check; no post-convergence hunting claim.
smoke=base|{k:0 for k in limits if k.endswith('Limit')}|dict(
    Server='{s1}',Joining='{}',RawNodes='{s1}',PreVoteNodes='{s1}',CheckQuorumNodes='{}',
    RequestId='{1}',PayloadWeights='{1}',EncodedWeights='{1}',CampaignLimit=1,
    MaxTermLimit=3,MaxLogLimit=4,MaxMsgBufferLimit=4,WorkloadKinds='{}',AllowEmptyContext='FALSE')
config('MC_smoke.cfg',smoke,extra,structural=True,comment='Developer finite singleton bootstrap/election/Ready smoke. No failures, reads or membership workload.')
