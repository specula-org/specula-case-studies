------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category A: a causally ordered NDJSON trace, not concurrent-thread timeboxes.
\* Every modeled semantic boundary is instrumented, including environmental steps.
\* No unconstrained silent actions and no bypass of the original action predicates.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
TraceTag == "cnpg-primary-failover"
RawTrace == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTrace,LAMBDA row: "tag"\in DOMAIN row /\ row.tag=TraceTag)
Boot == TraceLog[1]
TraceServers == SeqSet(Boot.nodes)
TraceMaxWAL == Boot.settings.maxWAL
TraceSyncNumber == Boot.settings.syncNumber
TraceLeaseProfiles == [g\in {1,2} |-> Boot.settings.leaseProfiles[g]]
TraceManagerGrace == Boot.settings.managerGrace
TraceSmartDelay == Boot.settings.smartDelay
TraceFastDelay == Boot.settings.fastDelay
TraceTimerCap == Boot.settings.timerCap
TraceQuorumEnabled == Boot.settings.failoverQuorum
TraceArchiveEnabled == Boot.settings.archiveEnabled

VARIABLE l
traceVars == <<s,l>>
logline == TraceLog[l]

\* JSON arrays are sequences. Convert ONLY fields modeled as sets; preserve all
\* record keys so an extra/unvalidated captured field causes equality to fail.
\* These conversions are representation mappings, not replacement model logic.
DecodeAck(a) == [a EXCEPT !.members=SeqSet(@), !.witnesses=SeqSet(@)]
DecodeAcks(xs) == {DecodeAck(xs[k]):k\in 1..Len(xs)}
DecodeSync(c) == [c EXCEPT !.members=SeqSet(@)]
DecodeCluster(c) == [c EXCEPT !.syncMembers=SeqSet(@)]
DecodeLease(r) == [r EXCEPT !.cleanAcks=DecodeAcks(@)]
DecodeQuorum(q) == [q EXCEPT !.members=SeqSet(@)]
DecodeInst(i) == [i EXCEPT !.snapshot=DecodeCluster(@), !.qread=DecodeQuorum(@), !.metadata=DecodeQuorum(@)]
DecodeElect(e) == [e EXCEPT !.read=DecodeLease(@), !.observation=DecodeLease(@), !.takeoverObservation=DecodeLease(@), !.cleanAcks=DecodeAcks(@)]
DecodeLife(c) == [c EXCEPT !.releaseRead=DecodeLease(@)]
DecodeData(d) == [d EXCEPT !.fileConfig=DecodeSync(@), !.runtimeConfig=DecodeSync(@)]
DecodeOperator(o) == [o EXCEPT !.cluster=DecodeCluster(@), !.cache=DecodeCluster(@), !.phaseRead=DecodeCluster(@),
                         !.active=SeqSet(@), !.ready=SeqSet(@), !.collected=SeqSet(@),
                         !.quorum=DecodeQuorum(@), !.qcache=DecodeQuorum(@)]
DecodeEnv(e) == [e EXCEPT !.survivors=SeqSet(@), !.restartAllowed=SeqSet(@)]
DecodeHistory(h) == [h EXCEPT !.acks=DecodeAcks(@), !.cleanAcks=DecodeAcks(@)]
DecodePost(j) == [f\in DOMAIN j |->
    CASE f="cluster" -> DecodeCluster(j[f])
      [] f="lease" -> DecodeLease(j[f])
      [] f="quorum" -> DecodeQuorum(j[f])
      [] f="cache" -> [n\in DOMAIN j[f] |-> DecodeCluster(j[f][n])]
      [] f="inst" -> [n\in DOMAIN j[f] |-> DecodeInst(j[f][n])]
      [] f="elect" -> [n\in DOMAIN j[f] |-> DecodeElect(j[f][n])]
      [] f="life" -> [n\in DOMAIN j[f] |-> DecodeLife(j[f][n])]
      [] f="data" -> [n\in DOMAIN j[f] |-> DecodeData(j[f][n])]
      [] f="op" -> DecodeOperator(j[f])
      [] f="env" -> DecodeEnv(j[f])
      [] f="archive" -> SeqSet(j[f])
      [] f="acks" -> DecodeAcks(j[f])
      [] f="history" -> {DecodeHistory(j[f][k]):k\in 1..Len(j[f])}
      [] f="usedWAL" -> SeqSet(j[f])
      [] OTHER -> j[f]]

\* Bootstrap is checked against base Init, never arbitrary supplied state.
TraceInit ==
    /\ Assert(Len(TraceLog)>0,"Trace must contain a Bootstrap event")
    /\ Boot.event="Bootstrap" /\ Boot.seq=0
    /\ DOMAIN Boot={"tag","event","seq","nodes","settings","post"}
    /\ DOMAIN Boot.settings={"maxWAL","syncNumber","leaseProfiles","managerGrace","smartDelay","fastDelay","timerCap","failoverQuorum","archiveEnabled"}
    /\ DOMAIN Boot.settings.leaseProfiles=1..2
    /\ (\A g\in {1,2}:DOMAIN Boot.settings.leaseProfiles[g]={"duration","renew","retry","released"})
    /\ Init
    /\ Boot.nodes=s.order
    /\ DOMAIN Boot.post=DOMAIN s
    /\ s=DecodePost(Boot.post)
    /\ l=2

IsEvent(e,name) ==
    /\ l<=Len(TraceLog)
    /\ DOMAIN e={"tag","event","seq","params","post"}
    /\ e.tag=TraceTag /\ e.event=name /\ e.seq=l-1


\* Complete changed state groups, mechanically derived from every EXCEPT update.
RequiredPost(event) ==
    CASE
        event="Reconcile_GetCluster" -> {"op"}
        [] event="GetManagedResources" -> {"op"}
        [] event="UpdateResourceStatus" -> {"cluster", "op"}
        [] event="UpdateResourceStatus_Conflict" -> {"op"}
        [] event="Reconcile_TransitionGuard" -> {"op"}
        [] event="MarkOldPrimaryAsUnhealthy" -> {"op", "pods"}
        [] event="GetReplicaStatusFromPodViaHTTP" -> {"op"}
        [] event="EvaluatePodReadinessGuards" -> {"op"}
        [] event="ReconcileTargetPrimaryForNonReplicaCluster" -> {"op"}
        [] event="EvaluateQuorumCheck_Get" -> {"op"}
        [] event="DeliverFailoverQuorum" -> {"op"}
        [] event="EvaluateQuorumCheckWithStatus" -> {"op"}
        [] event="UpdatePrimaryPod_Select" -> {"op"}
        [] event="UpdatePrimaryPod_Wait" -> {"op"}
        [] event="RegisterPhase_Get" -> {"op"}
        [] event="RegisterPhase_Patch" -> {"cluster", "op"}
        [] event="RegisterPhase_Conflict" -> {"op"}
        [] event="SetPrimaryInstance_Pending" -> {"cluster", "op"}
        [] event="AreWalReceiversDown" -> {"op"}
        [] event="SetPrimaryInstance_Target" -> {"cluster", "op"}
        [] event="DeliverCluster" -> {"cache"}
        [] event="InstanceReconcile_GetCluster" -> {"inst"}
        [] event="RefreshConfigurationFiles" -> {"data", "inst"}
        [] event="VerifyPgDataCoherenceForPrimary" -> {"inst"}
        [] event="VerifyPgDataCoherenceForPrimary_Wait" -> {"inst"}
        [] event="VerifyPgDataCoherenceForPrimary_Archive" -> {"archive", "inst"}
        [] event="Rewind_Demote" -> {"data", "inst"}
        [] event="RunPostgresAndWait" -> {"data", "life"}
        [] event="InstanceIsReady" -> {"inst"}
        [] event="ReconcilePrimary" -> {"inst"}
        [] event="Acquire" -> {"elect", "inst"}
        [] event="Acquire_Return" -> {"inst"}
        [] event="Acquire_Deadline" -> {"inst"}
        [] event="WaitForWalReceiverDown" -> {"inst"}
        [] event="PromoteAndWait_Request" -> {"data", "inst"}
        [] event="PromoteAndWait_Complete" -> {"data", "history"}
        [] event="PromoteAndWait_Return" -> {"inst"}
        [] event="ReconcilePrimary_CompleteStatus" -> {"cluster", "inst"}
        [] event="ReconcileOldPrimary" -> {"inst", "life"}
        [] event="ReconcileConfiguration" -> {"inst"}
        [] event="ResetFailoverQuorumObject_Get" -> {"inst"}
        [] event="ResetFailoverQuorumObject_Update" -> {"inst", "quorum"}
        [] event="FailoverQuorum_Conflict" -> {"inst"}
        [] event="Reload" -> {"inst"}
        [] event="ProcessConfigReloadAndManageRestart" -> {"data", "inst"}
        [] event="GetSynchronousReplicationMetadata" -> {"inst"}
        [] event="UpdateFailoverQuorumObject_Get" -> {"inst"}
        [] event="UpdateFailoverQuorumObject_Update" -> {"inst", "quorum"}
        [] event="TryTakeOver_Get" -> {"elect"}
        [] event="TryTakeOver_ReadError" -> {"elect"}
        [] event="TryTakeOver_OwnHolder" -> {"elect"}
        [] event="TryTakeOver_EmptyHolder" -> {"elect"}
        [] event="TryTakeOver_ForeignHolder" -> {"elect"}
        [] event="PreAcquire_Retry" -> {"elect"}
        [] event="Claim" -> {"elect", "lease"}
        [] event="Claim_ConflictOrError" -> {"elect"}
        [] event="RunLeaderElection_FirstAcquired" -> {"elect"}
        [] event="LeaderElection_Retry" -> {"elect"}
        [] event="LeaderElection_RenewFast" -> {"elect", "lease"}
        [] event="LeaderElection_Fallback" -> {"elect"}
        [] event="LeaderElection_Get" -> {"elect"}
        [] event="LeaderElection_GetError" -> {"elect"}
        [] event="LeaderElection_Check" -> {"elect"}
        [] event="LeaderElection_Update" -> {"elect", "lease"}
        [] event="LeaderElection_UpdateError" -> {"elect"}
        [] event="RunLeaderElection_RenewDeadline" -> {"elect"}
        [] event="ClassifyLeaseAfterRun_Get" -> {"elect"}
        [] event="ClassifyLeaseAfterRun_Unverifiable" -> {"elect"}
        [] event="ClassifyLeaseAfterRun_Held" -> {"elect"}
        [] event="ClassifyLeaseAfterRun_Preempted" -> {"elect", "life"}
        [] event="PostgresLifecycle_Cancelled" -> {"elect", "life"}
        [] event="TryShuttingDownSmartFast_Checkpoint" -> {"life"}
        [] event="Shutdown_StopRequest" -> {"data", "life"}
        [] event="TryShuttingDownSmartFast_Fallback" -> {"data", "life"}
        [] event="Shutdown_ClientsFinished" -> {"data", "life"}
        [] event="Shutdown_ArchiveComplete" -> {"archive", "life"}
        [] event="RunPostgresAndWait_Exit" -> {"data", "life"}
        [] event="PostgresLifecycle_Return" -> {"elect", "life"}
        [] event="EngageStopProcedure_GraceExpired" -> {"life"}
        [] event="ManagerStart_Return" -> {"elect", "life"}
        [] event="Release_UpgradeSkip" -> {"life"}
        [] event="Release_Get" -> {"life"}
        [] event="Release_Check" -> {"life"}
        [] event="Release_Update" -> {"lease", "life"}
        [] event="Release_Error" -> {"life"}
        [] event="Run_ContainerExit" -> {"data", "elect", "inst", "life"}
        [] event="IsHealthy_GetCluster" -> {"life"}
        [] event="IsHealthy_Ping" -> {"life"}
        [] event="IsHealthy_IsolationProbe" -> {"life"}
        [] event="TryShuttingDownFastImmediate_Immediate" -> {"data", "life"}
        [] event="TryShuttingDownSmartFast_StopTimeout" -> {"life"}
        [] event="GenerateWAL" -> {"data", "usedWAL"}
        [] event="FlushWAL" -> {"data"}
        [] event="SendWAL" -> {"sent"}
        [] event="ReceiveWAL" -> {"data"}
        [] event="ReplayWAL" -> {"data"}
        [] event="AcknowledgeCommit" -> {"acks"}
        [] event="ArchiveWAL" -> {"archive"}
        [] event="RestoreArchiveWAL" -> {"data"}
        [] event="WalReceiverDown" -> {"data", "sent"}
        [] event="WalReceiverConnect" -> {"data", "sent"}
        [] event="ReadinessProbe" -> {"pods"}
        [] event="ReconcileMetadata" -> {"pods"}
        [] event="RequestPlannedSwitchover" -> {"op"}
        [] event="ManagerCancellation" -> {"life"}
        [] event="TerminationSignal" -> {"life"}
        [] event="OnlineUpgrade" -> {"life"}
        [] event="OnlineUpgrade_Exec" -> {"elect", "inst", "life"}
        [] event="PodCrash" -> {"data", "elect", "env", "inst", "life"}
        [] event="PodRestart" -> {"cache", "data", "elect", "inst", "life"}
        [] event="PermitPodRestart" -> {"env"}
        [] event="PodEviction" -> {"pods"}
        [] event="APIFailure" -> {"env"}
        [] event="APIFailure_Recover" -> {"env"}
        [] event="HTTPFailure" -> {"env"}
        [] event="HTTPFailure_Recover" -> {"env"}
        [] event="ProbeFailure" -> {"env"}
        [] event="ProbeFailure_Recover" -> {"env"}
        [] event="ReplicationDisconnect" -> {"env"}
        [] event="ReplicationDisconnect_Recover" -> {"env"}
        [] event="PeerFailure" -> {"env"}
        [] event="PeerFailure_Recover" -> {"env"}
        [] event="StorageStall" -> {"env"}
        [] event="StorageStall_Recover" -> {"env"}
        [] event="SQLUnavailable" -> {"env"}
        [] event="SQLUnavailable_Recover" -> {"env"}
        [] event="OperatorCrash" -> {"env", "op"}
        [] event="OperatorRecover" -> {"env"}
        [] event="OperatorAPIFailure" -> {"env"}
        [] event="OperatorAPIRecover" -> {"env"}
        [] event="UpdateLeaseConfiguration" -> {"cluster"}
        [] event="UpdateSynchronousConfiguration" -> {"cluster"}
        [] event="RecoverEnvironment" -> {"env"}
        [] event="ClockTick" -> {"elect", "inst", "life"}
        [] event="DeliverOperatorCluster" -> {"op"}
        [] event="Reconcile_APIError" -> {"op"}
        [] event="MarkOldPrimaryAsUnhealthy_Error" -> {"op"}
        [] event="InstanceReconcile_APIError" -> {"inst"}
        [] event="GetSynchronousReplicationMetadata_Error" -> {"inst"}
        [] OTHER -> {}

\* MANDATORY: no conditional/optional field skipping. A no-op branch still reports
\* the named groups; every captured state field participates in record equality.
ValidatePostState(e) ==
    /\ DOMAIN e.post=RequiredPost(e.event)
    /\ LET observed==DecodePost(e.post) IN
          \A f\in RequiredPost(e.event) : observed[f]=s'[f]


\* OC:300-329,382-390; same boundary as base.
Trace_Reconcile_GetCluster(e) ==
    /\ IsEvent(e,"Reconcile_GetCluster")
    /\ DOMAIN e.params={}
    /\ Reconcile_GetCluster
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:383-390; OS:298-323; pkg/reconciler/persistentvolumeclaim/status.go:233-235; same boundary as base.
Trace_GetManagedResources(e) ==
    /\ IsEvent(e,"GetManagedResources")
    /\ DOMAIN e.params={}
    /\ GetManagedResources
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235; same boundary as base.
Trace_UpdateResourceStatus(e) ==
    /\ IsEvent(e,"UpdateResourceStatus")
    /\ DOMAIN e.params={}
    /\ UpdateResourceStatus
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:389-398; OS:401-404; same boundary as base.
Trace_UpdateResourceStatus_Conflict(e) ==
    /\ IsEvent(e,"UpdateResourceStatus_Conflict")
    /\ DOMAIN e.params={}
    /\ UpdateResourceStatus_Conflict
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:408-428,454-455; same boundary as base.
Trace_Reconcile_TransitionGuard(e) ==
    /\ IsEvent(e,"Reconcile_TransitionGuard")
    /\ DOMAIN e.params={}
    /\ Reconcile_TransitionGuard
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:413-427; OR:144-158,202-229; same boundary as base.
Trace_MarkOldPrimaryAsUnhealthy(e) ==
    /\ IsEvent(e,"MarkOldPrimaryAsUnhealthy")
    /\ DOMAIN e.params={}
    /\ MarkOldPrimaryAsUnhealthy
    /\ ValidatePostState(e)
    /\ l'=l+1

\* RC:134-137,143-178,181-201; PS:282-325; same boundary as base.
Trace_GetReplicaStatusFromPodViaHTTP(e) ==
    /\ IsEvent(e,"GetReplicaStatusFromPodViaHTTP")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ GetReplicaStatusFromPodViaHTTP(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:476-485,636-685; PS:282-325; same boundary as base.
Trace_EvaluatePodReadinessGuards(e) ==
    /\ IsEvent(e,"EvaluatePodReadinessGuards")
    /\ DOMAIN e.params={}
    /\ EvaluatePodReadinessGuards
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OR:99-139; OC:545-547; same boundary as base.
Trace_ReconcileTargetPrimaryForNonReplicaCluster(e) ==
    /\ IsEvent(e,"ReconcileTargetPrimaryForNonReplicaCluster")
    /\ DOMAIN e.params={}
    /\ ReconcileTargetPrimaryForNonReplicaCluster
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OQ:48-60; OQ:76-117; same boundary as base.
Trace_EvaluateQuorumCheck_Get(e) ==
    /\ IsEvent(e,"EvaluateQuorumCheck_Get")
    /\ DOMAIN e.params={}
    /\ EvaluateQuorumCheck_Get
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OQ:48-60; OC:120-135 (cached client); same boundary as base.
Trace_DeliverFailoverQuorum(e) ==
    /\ IsEvent(e,"DeliverFailoverQuorum")
    /\ DOMAIN e.params={}
    /\ DeliverFailoverQuorum
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OQ:76-117; OR:114-139; same boundary as base.
Trace_EvaluateQuorumCheckWithStatus(e) ==
    /\ IsEvent(e,"EvaluateQuorumCheckWithStatus")
    /\ DOMAIN e.params={}
    /\ EvaluateQuorumCheckWithStatus
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OU:229-264; OR:298-329; same boundary as base.
Trace_UpdatePrimaryPod_Select(e) ==
    /\ IsEvent(e,"UpdatePrimaryPod_Select")
    /\ DOMAIN e.params={}
    /\ UpdatePrimaryPod_Select
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OU:242-255; OR:299-312; same boundary as base.
Trace_UpdatePrimaryPod_Wait(e) ==
    /\ IsEvent(e,"UpdatePrimaryPod_Wait")
    /\ DOMAIN e.params={}
    /\ UpdatePrimaryPod_Wait
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OS:765-776; SP:52-61; same boundary as base.
Trace_RegisterPhase_Get(e) ==
    /\ IsEvent(e,"RegisterPhase_Get")
    /\ DOMAIN e.params={}
    /\ RegisterPhase_Get
    /\ ValidatePostState(e)
    /\ l'=l+1

\* SP:63-75; OR:135-139,176-196; OU:170-174; same boundary as base.
Trace_RegisterPhase_Patch(e) ==
    /\ IsEvent(e,"RegisterPhase_Patch")
    /\ DOMAIN e.params={}
    /\ RegisterPhase_Patch
    /\ ValidatePostState(e)
    /\ l'=l+1

\* SP:52-75; same boundary as base.
Trace_RegisterPhase_Conflict(e) ==
    /\ IsEvent(e,"RegisterPhase_Conflict")
    /\ DOMAIN e.params={}
    /\ RegisterPhase_Conflict
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OR:129-159; OS:752-760; same boundary as base.
Trace_SetPrimaryInstance_Pending(e) ==
    /\ IsEvent(e,"SetPrimaryInstance_Pending")
    /\ DOMAIN e.params={}
    /\ SetPrimaryInstance_Pending
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OR:161-196; PS:331-341; same boundary as base.
Trace_AreWalReceiversDown(e) ==
    /\ IsEvent(e,"AreWalReceiversDown")
    /\ DOMAIN e.params={}
    /\ AreWalReceiversDown
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OR:196,329; OS:752-760; OU:170-174; same boundary as base.
Trace_SetPrimaryInstance_Target(e) ==
    /\ IsEvent(e,"SetPrimaryInstance_Target")
    /\ DOMAIN e.params={}
    /\ SetPrimaryInstance_Target
    /\ ValidatePostState(e)
    /\ l'=l+1

\* CMD:185-215; IC:136-164; same boundary as base.
Trace_DeliverCluster(e) ==
    /\ IsEvent(e,"DeliverCluster")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ DeliverCluster(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:136-164,206-217; same boundary as base.
Trace_InstanceReconcile_GetCluster(e) ==
    /\ IsEvent(e,"InstanceReconcile_GetCluster")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ InstanceReconcile_GetCluster(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:206-217,417-453; pkg/management/postgres/configuration.go:69-99; SY:45-79; same boundary as base.
Trace_RefreshConfigurationFiles(e) ==
    /\ IsEvent(e,"RefreshConfigurationFiles")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ RefreshConfigurationFiles(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IS:41-49,72-85; IC:212-227; same boundary as base.
Trace_VerifyPgDataCoherenceForPrimary(e) ==
    /\ IsEvent(e,"VerifyPgDataCoherenceForPrimary")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ VerifyPgDataCoherenceForPrimary(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IS:87-110; same boundary as base.
Trace_VerifyPgDataCoherenceForPrimary_Wait(e) ==
    /\ IsEvent(e,"VerifyPgDataCoherenceForPrimary_Wait")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ VerifyPgDataCoherenceForPrimary_Wait(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IS:108-146; same boundary as base.
Trace_VerifyPgDataCoherenceForPrimary_Archive(e) ==
    /\ IsEvent(e,"VerifyPgDataCoherenceForPrimary_Archive")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ VerifyPgDataCoherenceForPrimary_Archive(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IS:146-152; PG:1011-1028; same boundary as base.
Trace_Rewind_Demote(e) ==
    /\ IsEvent(e,"Rewind_Demote")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Rewind_Demote(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LP:62-103,129-140; same boundary as base.
Trace_RunPostgresAndWait(e) ==
    /\ IsEvent(e,"RunPostgresAndWait")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ RunPostgresAndWait(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:229-246; same boundary as base.
Trace_InstanceIsReady(e) ==
    /\ IsEvent(e,"InstanceIsReady")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ InstanceIsReady(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1203-1226; same boundary as base.
Trace_ReconcilePrimary(e) ==
    /\ IsEvent(e,"ReconcilePrimary")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReconcilePrimary(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:147-162; IC:1215-1234; same boundary as base.
Trace_Acquire(e) ==
    /\ IsEvent(e,"Acquire")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Acquire(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:158-162; IC:1237-1259; same boundary as base.
Trace_Acquire_Return(e) ==
    /\ IsEvent(e,"Acquire_Return")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Acquire_Return(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1215-1234; LR:150-162; same boundary as base.
Trace_Acquire_Deadline(e) ==
    /\ IsEvent(e,"Acquire_Deadline")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Acquire_Deadline(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1295-1306,1343-1359; same boundary as base.
Trace_WaitForWalReceiverDown(e) ==
    /\ IsEvent(e,"WaitForWalReceiverDown")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ WaitForWalReceiverDown(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PR:35-56; IC:1304-1309; same boundary as base.
Trace_PromoteAndWait_Request(e) ==
    /\ IsEvent(e,"PromoteAndWait_Request")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PromoteAndWait_Request(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PR:58-93; FD:68-86; IC:1255-1268; same boundary as base.
Trace_PromoteAndWait_Complete(e) ==
    /\ IsEvent(e,"PromoteAndWait_Complete")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PromoteAndWait_Complete(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PR:66-93; IC:1256-1266; same boundary as base.
Trace_PromoteAndWait_Return(e) ==
    /\ IsEvent(e,"PromoteAndWait_Return")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PromoteAndWait_Return(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1237,1262-1268; same boundary as base.
Trace_ReconcilePrimary_CompleteStatus(e) ==
    /\ IsEvent(e,"ReconcilePrimary_CompleteStatus")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReconcilePrimary_CompleteStatus(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:614-639; same boundary as base.
Trace_ReconcileOldPrimary(e) ==
    /\ IsEvent(e,"ReconcileOldPrimary")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReconcileOldPrimary(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:277-299; IQ:98-109; same boundary as base.
Trace_ReconcileConfiguration(e) ==
    /\ IsEvent(e,"ReconcileConfiguration")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReconcileConfiguration(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IQ:34-49; CMD:219-230; same boundary as base.
Trace_ResetFailoverQuorumObject_Get(e) ==
    /\ IsEvent(e,"ResetFailoverQuorumObject_Get")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ResetFailoverQuorumObject_Get(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IQ:39-49; IC:288-291; same boundary as base.
Trace_ResetFailoverQuorumObject_Update(e) ==
    /\ IsEvent(e,"ResetFailoverQuorumObject_Update")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ResetFailoverQuorumObject_Update(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IQ:39-49,80-95; same boundary as base.
Trace_FailoverQuorum_Conflict(e) ==
    /\ IsEvent(e,"FailoverQuorum_Conflict")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ FailoverQuorum_Conflict(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:288-295; PG:727-756; same boundary as base.
Trace_Reload(e) ==
    /\ IsEvent(e,"Reload")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Reload(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:291-299; PG:1100-1115,1120-1150; same boundary as base.
Trace_ProcessConfigReloadAndManageRestart(e) ==
    /\ IsEvent(e,"ProcessConfigReloadAndManageRestart")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ProcessConfigReloadAndManageRestart(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IQ:54-78; PG:1156-1181; same boundary as base.
Trace_GetSynchronousReplicationMetadata(e) ==
    /\ IsEvent(e,"GetSynchronousReplicationMetadata")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ GetSynchronousReplicationMetadata(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IQ:80-89; CMD:219-230; same boundary as base.
Trace_UpdateFailoverQuorumObject_Get(e) ==
    /\ IsEvent(e,"UpdateFailoverQuorumObject_Get")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ UpdateFailoverQuorumObject_Get(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IQ:88-95; same boundary as base.
Trace_UpdateFailoverQuorumObject_Update(e) ==
    /\ IsEvent(e,"UpdateFailoverQuorumObject_Update")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ UpdateFailoverQuorumObject_Update(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:295-310; LL:42-53; same boundary as base.
Trace_TryTakeOver_Get(e) ==
    /\ IsEvent(e,"TryTakeOver_Get")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryTakeOver_Get(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:302-304,383-397; same boundary as base.
Trace_TryTakeOver_ReadError(e) ==
    /\ IsEvent(e,"TryTakeOver_ReadError")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryTakeOver_ReadError(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:308-310,443-450; same boundary as base.
Trace_TryTakeOver_OwnHolder(e) ==
    /\ IsEvent(e,"TryTakeOver_OwnHolder")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryTakeOver_OwnHolder(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:313-318; same boundary as base.
Trace_TryTakeOver_EmptyHolder(e) ==
    /\ IsEvent(e,"TryTakeOver_EmptyHolder")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryTakeOver_EmptyHolder(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:320-334,340-342; same boundary as base.
Trace_TryTakeOver_ForeignHolder(e) ==
    /\ IsEvent(e,"TryTakeOver_ForeignHolder")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryTakeOver_ForeignHolder(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:370-398; same boundary as base.
Trace_PreAcquire_Retry(e) ==
    /\ IsEvent(e,"PreAcquire_Retry")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PreAcquire_Retry(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:344-360; LL:73-95; same boundary as base.
Trace_Claim(e) ==
    /\ IsEvent(e,"Claim")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Claim(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:348-357,383-397; same boundary as base.
Trace_Claim_ConflictOrError(e) ==
    /\ IsEvent(e,"Claim_ConflictOrError")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Claim_ConflictOrError(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:443-450; same boundary as base.
Trace_RunLeaderElection_FirstAcquired(e) ==
    /\ IsEvent(e,"RunLeaderElection_FirstAcquired")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ RunLeaderElection_FirstAcquired(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:253-275,284-306; same boundary as base.
Trace_LeaderElection_Retry(e) ==
    /\ IsEvent(e,"LeaderElection_Retry")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_Retry(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:454-466; LL:73-95; same boundary as base.
Trace_LeaderElection_RenewFast(e) ==
    /\ IsEvent(e,"LeaderElection_RenewFast")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_RenewFast(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:454-470; same boundary as base.
Trace_LeaderElection_Fallback(e) ==
    /\ IsEvent(e,"LeaderElection_Fallback")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_Fallback(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:470-490; LL:42-53; same boundary as base.
Trace_LeaderElection_Get(e) ==
    /\ IsEvent(e,"LeaderElection_Get")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_Get(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:470-474,284-306; same boundary as base.
Trace_LeaderElection_GetError(e) ==
    /\ IsEvent(e,"LeaderElection_GetError")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_GetError(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:486-508; same boundary as base.
Trace_LeaderElection_Check(e) ==
    /\ IsEvent(e,"LeaderElection_Check")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_Check(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:497-514; LL:73-95; same boundary as base.
Trace_LeaderElection_Update(e) ==
    /\ IsEvent(e,"LeaderElection_Update")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_Update(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:508-511,284-306; same boundary as base.
Trace_LeaderElection_UpdateError(e) ==
    /\ IsEvent(e,"LeaderElection_UpdateError")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ LeaderElection_UpdateError(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LE:284-306; LR:479-490; same boundary as base.
Trace_RunLeaderElection_RenewDeadline(e) ==
    /\ IsEvent(e,"RunLeaderElection_RenewDeadline")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ RunLeaderElection_RenewDeadline(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:489-493; same boundary as base.
Trace_ClassifyLeaseAfterRun_Get(e) ==
    /\ IsEvent(e,"ClassifyLeaseAfterRun_Get")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ClassifyLeaseAfterRun_Get(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:269-270,489-503; same boundary as base.
Trace_ClassifyLeaseAfterRun_Unverifiable(e) ==
    /\ IsEvent(e,"ClassifyLeaseAfterRun_Unverifiable")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ClassifyLeaseAfterRun_Unverifiable(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:273-276,493-515; same boundary as base.
Trace_ClassifyLeaseAfterRun_Held(e) ==
    /\ IsEvent(e,"ClassifyLeaseAfterRun_Held")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ClassifyLeaseAfterRun_Held(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:273-274,504-512; CM:530-532; same boundary as base.
Trace_ClassifyLeaseAfterRun_Preempted(e) ==
    /\ IsEvent(e,"ClassifyLeaseAfterRun_Preempted")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ClassifyLeaseAfterRun_Preempted(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:122-135; same boundary as base.
Trace_PostgresLifecycle_Cancelled(e) ==
    /\ IsEvent(e,"PostgresLifecycle_Cancelled")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PostgresLifecycle_Cancelled(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:132-149; PG:581-590,1635-1667; same boundary as base.
Trace_TryShuttingDownSmartFast_Checkpoint(e) ==
    /\ IsEvent(e,"TryShuttingDownSmartFast_Checkpoint")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryShuttingDownSmartFast_Checkpoint(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:589-618,645-673,690-709; same boundary as base.
Trace_Shutdown_StopRequest(e) ==
    /\ IsEvent(e,"Shutdown_StopRequest")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Shutdown_StopRequest(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:645-673; same boundary as base.
Trace_TryShuttingDownSmartFast_Fallback(e) ==
    /\ IsEvent(e,"TryShuttingDownSmartFast_Fallback")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryShuttingDownSmartFast_Fallback(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:626-680; FD:40-53; same boundary as base.
Trace_Shutdown_ClientsFinished(e) ==
    /\ IsEvent(e,"Shutdown_ClientsFinished")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Shutdown_ClientsFinished(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:581-623; LP:134-140; FD:40-46,78-86; same boundary as base.
Trace_Shutdown_ArchiveComplete(e) ==
    /\ IsEvent(e,"Shutdown_ArchiveComplete")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Shutdown_ArchiveComplete(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LP:134-140; LC:116-120,132-149; same boundary as base.
Trace_RunPostgresAndWait_Exit(e) ==
    /\ IsEvent(e,"RunPostgresAndWait_Exit")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ RunPostgresAndWait_Exit(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:73-75,116-149; CMD:379-385; same boundary as base.
Trace_PostgresLifecycle_Return(e) ==
    /\ IsEvent(e,"PostgresLifecycle_Return")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PostgresLifecycle_Return(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* CM:57,513-518,602-606; same boundary as base.
Trace_EngageStopProcedure_GraceExpired(e) ==
    /\ IsEvent(e,"EngageStopProcedure_GraceExpired")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ EngageStopProcedure_GraceExpired(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* CM:602-614; CMD:450-460; same boundary as base.
Trace_ManagerStart_Return(e) ==
    /\ IsEvent(e,"ManagerStart_Return")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ManagerStart_Return(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:188-194; CMD:392-399; same boundary as base.
Trace_Release_UpgradeSkip(e) ==
    /\ IsEvent(e,"Release_UpgradeSkip")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Release_UpgradeSkip(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:196-208; same boundary as base.
Trace_Release_Get(e) ==
    /\ IsEvent(e,"Release_Get")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Release_Get(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:204-208,216-221; same boundary as base.
Trace_Release_Check(e) ==
    /\ IsEvent(e,"Release_Check")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Release_Check(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:210-221; LL:73-95; CMD:392-399; same boundary as base.
Trace_Release_Update(e) ==
    /\ IsEvent(e,"Release_Update")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Release_Update(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:196-203,216-221; CMD:396-398; same boundary as base.
Trace_Release_Error(e) ==
    /\ IsEvent(e,"Release_Error")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Release_Error(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* CMD:450-475; LC:102-104; FD:82-86; same boundary as base.
Trace_Run_ContainerExit(e) ==
    /\ IsEvent(e,"Run_ContainerExit")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ Run_ContainerExit(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LV:56-88; same boundary as base.
Trace_IsHealthy_GetCluster(e) ==
    /\ IsEvent(e,"IsHealthy_GetCluster")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ IsHealthy_GetCluster(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LV:79-87,108-122; pkg/management/postgres/webserver/probes/pinger.go:104-113; same boundary as base.
Trace_IsHealthy_Ping(e) ==
    /\ IsEvent(e,"IsHealthy_Ping")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ IsHealthy_Ping(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LV:72-88,108-115; LC:137-149; same boundary as base.
Trace_IsHealthy_IsolationProbe(e) ==
    /\ IsEvent(e,"IsHealthy_IsolationProbe")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ IsHealthy_IsolationProbe(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:687-709; FD:40-53; same boundary as base.
Trace_TryShuttingDownFastImmediate_Immediate(e) ==
    /\ IsEvent(e,"TryShuttingDownFastImmediate_Immediate")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryShuttingDownFastImmediate_Immediate(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:660-677; LC:132-149; same boundary as base.
Trace_TryShuttingDownSmartFast_StopTimeout(e) ==
    /\ IsEvent(e,"TryShuttingDownSmartFast_StopTimeout")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TryShuttingDownSmartFast_StopTimeout(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:291-307,399-405; SY:45-79; same boundary as base.
Trace_GenerateWAL(e) ==
    /\ IsEvent(e,"GenerateWAL")
    /\ DOMAIN e.params={"n", "w"}
    /\ LET n == e.params.n
           w == e.params.w IN
         /\ n \in Server
         /\ w \in WAL
         /\ GenerateWAL(n,w)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:291-294,399-405; PG:1156-1181 (metadata observation); same boundary as base.
Trace_FlushWAL(e) ==
    /\ IsEvent(e,"FlushWAL")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ FlushWAL(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:24-29,291-294; PS:305-312; same boundary as base.
Trace_SendWAL(e) ==
    /\ IsEvent(e,"SendWAL")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ SendWAL(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:24-29,291-294; PS:305-312; same boundary as base.
Trace_ReceiveWAL(e) ==
    /\ IsEvent(e,"ReceiveWAL")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReceiveWAL(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1304-1309; PR:35-66; FD:68-86; same boundary as base.
Trace_ReplayWAL(e) ==
    /\ IsEvent(e,"ReplayWAL")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReplayWAL(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:291-307,399-405; SY:45-79; same boundary as base.
Trace_AcknowledgeCommit(e) ==
    /\ IsEvent(e,"AcknowledgeCommit")
    /\ DOMAIN e.params={"n", "witnesses"}
    /\ LET n == e.params.n
           witnesses == SeqSet(e.params.witnesses) IN
         /\ n \in Server
         /\ witnesses \in SUBSET Server
         /\ AcknowledgeCommit(n,witnesses)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:68-86; IS:135-143; same boundary as base.
Trace_ArchiveWAL(e) ==
    /\ IsEvent(e,"ArchiveWAL")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ArchiveWAL(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:68-86; IC:1304-1309; same boundary as base.
Trace_RestoreArchiveWAL(e) ==
    /\ IsEvent(e,"RestoreArchiveWAL")
    /\ DOMAIN e.params={"n", "a"}
    /\ LET n == e.params.n
           a == e.params.a IN
         /\ n \in Server
         /\ a \in s.archive
         /\ RestoreArchiveWAL(n,a)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1343-1359; PS:331-341; FD:24-29; same boundary as base.
Trace_WalReceiverDown(e) ==
    /\ IsEvent(e,"WalReceiverDown")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ WalReceiverDown(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OR:144-147,202-229; IC:448-451; FD:24-37; same boundary as base.
Trace_WalReceiverConnect(e) ==
    /\ IsEvent(e,"WalReceiverConnect")
    /\ DOMAIN e.params={"n", "p"}
    /\ LET n == e.params.n
           p == e.params.p IN
         /\ n \in Server
         /\ p \in Server
         /\ WalReceiverConnect(n,p)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:239-242; pkg/utils/pod_conditions.go:35-64; same boundary as base.
Trace_ReadinessProbe(e) ==
    /\ IsEvent(e,"ReadinessProbe")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReadinessProbe(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:410-427; OR:199-229 (retry fix); FD:29-31; same boundary as base.
Trace_ReconcileMetadata(e) ==
    /\ IsEvent(e,"ReconcileMetadata")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReconcileMetadata(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OU:157-174,212-264; OR:65-78,262-329; same boundary as base.
Trace_RequestPlannedSwitchover(e) ==
    /\ IsEvent(e,"RequestPlannedSwitchover")
    /\ DOMAIN e.params={}
    /\ RequestPlannedSwitchover
    /\ ValidatePostState(e)
    /\ l'=l+1

\* CM:530-532; LC:122-135; same boundary as base.
Trace_ManagerCancellation(e) ==
    /\ IsEvent(e,"ManagerCancellation")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ManagerCancellation(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:137-149; same boundary as base.
Trace_TerminationSignal(e) ==
    /\ IsEvent(e,"TerminationSignal")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ TerminationSignal(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:175-194; LC:126-129; CMD:379-385; same boundary as base.
Trace_OnlineUpgrade(e) ==
    /\ IsEvent(e,"OnlineUpgrade")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ OnlineUpgrade(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:179-186; LC:126-129; same boundary as base.
Trace_OnlineUpgrade_Exec(e) ==
    /\ IsEvent(e,"OnlineUpgrade_Exec")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ OnlineUpgrade_Exec(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:95-120; LP:134-140; FD:82-86; same boundary as base.
Trace_PodCrash(e) ==
    /\ IsEvent(e,"PodCrash")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PodCrash(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:102-104; IS:41-152; LR:291-294; same boundary as base.
Trace_PodRestart(e) ==
    /\ IsEvent(e,"PodRestart")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PodRestart(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LC:102-104; FD:30-31; same boundary as base.
Trace_PermitPodRestart(e) ==
    /\ IsEvent(e,"PermitPodRestart")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PermitPodRestart(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* pkg/utils/pod_conditions.go:74-78; OS:298-323; same boundary as base.
Trace_PodEviction(e) ==
    /\ IsEvent(e,"PodEviction")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PodEviction(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:302-304,489-503; same boundary as base.
Trace_APIFailure(e) ==
    /\ IsEvent(e,"APIFailure")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ APIFailure(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:302-304,489-503; same boundary as base.
Trace_APIFailure_Recover(e) ==
    /\ IsEvent(e,"APIFailure_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ APIFailure_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* RC:143-178; OC:663-685; same boundary as base.
Trace_HTTPFailure(e) ==
    /\ IsEvent(e,"HTTPFailure")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ HTTPFailure(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* RC:143-178; OC:663-685; same boundary as base.
Trace_HTTPFailure_Recover(e) ==
    /\ IsEvent(e,"HTTPFailure_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ HTTPFailure_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* pkg/utils/pod_conditions.go:35-64; OC:663-685; same boundary as base.
Trace_ProbeFailure(e) ==
    /\ IsEvent(e,"ProbeFailure")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ProbeFailure(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* pkg/utils/pod_conditions.go:35-64; OC:663-685; same boundary as base.
Trace_ProbeFailure_Recover(e) ==
    /\ IsEvent(e,"ProbeFailure_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ProbeFailure_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1343-1359; FD:24-29; same boundary as base.
Trace_ReplicationDisconnect(e) ==
    /\ IsEvent(e,"ReplicationDisconnect")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReplicationDisconnect(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:1343-1359; FD:24-29; same boundary as base.
Trace_ReplicationDisconnect_Recover(e) ==
    /\ IsEvent(e,"ReplicationDisconnect_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ ReplicationDisconnect_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LV:72-88,108-115; same boundary as base.
Trace_PeerFailure(e) ==
    /\ IsEvent(e,"PeerFailure")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PeerFailure(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LV:72-88,108-115; same boundary as base.
Trace_PeerFailure_Recover(e) ==
    /\ IsEvent(e,"PeerFailure_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ PeerFailure_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:239-242; PG:581-618; PR:35-66; same boundary as base.
Trace_StorageStall(e) ==
    /\ IsEvent(e,"StorageStall")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ StorageStall(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:239-242; PG:581-618; PR:35-66; same boundary as base.
Trace_StorageStall_Recover(e) ==
    /\ IsEvent(e,"StorageStall_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ StorageStall_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:239-242; RC:134-137; same boundary as base.
Trace_SQLUnavailable(e) ==
    /\ IsEvent(e,"SQLUnavailable")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ SQLUnavailable(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:239-242; RC:134-137; same boundary as base.
Trace_SQLUnavailable_Recover(e) ==
    /\ IsEvent(e,"SQLUnavailable_Recover")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ SQLUnavailable_Recover(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:300-428; OS:752-776; same boundary as base.
Trace_OperatorCrash(e) ==
    /\ IsEvent(e,"OperatorCrash")
    /\ DOMAIN e.params={}
    /\ OperatorCrash
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:300-428; same boundary as base.
Trace_OperatorRecover(e) ==
    /\ IsEvent(e,"OperatorRecover")
    /\ DOMAIN e.params={}
    /\ OperatorRecover
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:383-398; OQ:48-58; same boundary as base.
Trace_OperatorAPIFailure(e) ==
    /\ IsEvent(e,"OperatorAPIFailure")
    /\ DOMAIN e.params={}
    /\ OperatorAPIFailure
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:383-398; OQ:48-58; same boundary as base.
Trace_OperatorAPIRecover(e) ==
    /\ IsEvent(e,"OperatorAPIRecover")
    /\ DOMAIN e.params={}
    /\ OperatorAPIRecover
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:61-76,143-156; IC:1215-1224; FD:153-180; same boundary as base.
Trace_UpdateLeaseConfiguration(e) ==
    /\ IsEvent(e,"UpdateLeaseConfiguration")
    /\ DOMAIN e.params={}
    /\ UpdateLeaseConfiguration
    /\ ValidatePostState(e)
    /\ l'=l+1

\* SY:45-79,129-147; IC:206-210,277-299; same boundary as base.
Trace_UpdateSynchronousConfiguration(e) ==
    /\ IsEvent(e,"UpdateSynchronousConfiguration")
    /\ DOMAIN e.params={"members", "number"}
    /\ LET members == SeqSet(e.params.members)
           number == e.params.number IN
         /\ members \in SUBSET Server
         /\ number \in 1..(Cardinality(Server)-1)
         /\ UpdateSynchronousConfiguration(members,number)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* FD:20-31,350-371; OC:389-455; IC:239-299; same boundary as base.
Trace_RecoverEnvironment(e) ==
    /\ IsEvent(e,"RecoverEnvironment")
    /\ DOMAIN e.params={"survivors"}
    /\ LET survivors == SeqSet(e.params.survivors) IN
         /\ survivors \in SUBSET Server
         /\ RecoverEnvironment(survivors)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* LR:325-333,373-397; LE:284-306; CM:513-518; PG:635-673; same boundary as base.
Trace_ClockTick(e) ==
    /\ IsEvent(e,"ClockTick")
    /\ DOMAIN e.params={}
    /\ ClockTick
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:300-329; SP:52-55 (controller-runtime cached client); same boundary as base.
Trace_DeliverOperatorCluster(e) ==
    /\ IsEvent(e,"DeliverOperatorCluster")
    /\ DOMAIN e.params={}
    /\ DeliverOperatorCluster
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:389-398; OR:135-142,176-196; SP:54-55,67-79; same boundary as base.
Trace_Reconcile_APIError(e) ==
    /\ IsEvent(e,"Reconcile_APIError")
    /\ DOMAIN e.params={}
    /\ Reconcile_APIError
    /\ ValidatePostState(e)
    /\ l'=l+1

\* OC:413-427; OR:151-159; same boundary as base.
Trace_MarkOldPrimaryAsUnhealthy_Error(e) ==
    /\ IsEvent(e,"MarkOldPrimaryAsUnhealthy_Error")
    /\ DOMAIN e.params={}
    /\ MarkOldPrimaryAsUnhealthy_Error
    /\ ValidatePostState(e)
    /\ l'=l+1

\* IC:288-300,1266-1268; IQ:42-48,83-94; same boundary as base.
Trace_InstanceReconcile_APIError(e) ==
    /\ IsEvent(e,"InstanceReconcile_APIError")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ InstanceReconcile_APIError(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

\* PG:1164-1169; IQ:59-62; IC:299-300; same boundary as base.
Trace_GetSynchronousReplicationMetadata_Error(e) ==
    /\ IsEvent(e,"GetSynchronousReplicationMetadata_Error")
    /\ DOMAIN e.params={"n"}
    /\ LET n == e.params.n IN
         /\ n \in Server
         /\ GetSynchronousReplicationMetadata_Error(n)
    /\ ValidatePostState(e)
    /\ l'=l+1

TraceAdvance ==
    /\ l<=Len(TraceLog)
    /\ LET e==logline IN
          CASE 
             e.event="Reconcile_GetCluster" -> Trace_Reconcile_GetCluster(e)
             [] e.event="GetManagedResources" -> Trace_GetManagedResources(e)
             [] e.event="UpdateResourceStatus" -> Trace_UpdateResourceStatus(e)
             [] e.event="UpdateResourceStatus_Conflict" -> Trace_UpdateResourceStatus_Conflict(e)
             [] e.event="Reconcile_TransitionGuard" -> Trace_Reconcile_TransitionGuard(e)
             [] e.event="MarkOldPrimaryAsUnhealthy" -> Trace_MarkOldPrimaryAsUnhealthy(e)
             [] e.event="GetReplicaStatusFromPodViaHTTP" -> Trace_GetReplicaStatusFromPodViaHTTP(e)
             [] e.event="EvaluatePodReadinessGuards" -> Trace_EvaluatePodReadinessGuards(e)
             [] e.event="ReconcileTargetPrimaryForNonReplicaCluster" -> Trace_ReconcileTargetPrimaryForNonReplicaCluster(e)
             [] e.event="EvaluateQuorumCheck_Get" -> Trace_EvaluateQuorumCheck_Get(e)
             [] e.event="DeliverFailoverQuorum" -> Trace_DeliverFailoverQuorum(e)
             [] e.event="EvaluateQuorumCheckWithStatus" -> Trace_EvaluateQuorumCheckWithStatus(e)
             [] e.event="UpdatePrimaryPod_Select" -> Trace_UpdatePrimaryPod_Select(e)
             [] e.event="UpdatePrimaryPod_Wait" -> Trace_UpdatePrimaryPod_Wait(e)
             [] e.event="RegisterPhase_Get" -> Trace_RegisterPhase_Get(e)
             [] e.event="RegisterPhase_Patch" -> Trace_RegisterPhase_Patch(e)
             [] e.event="RegisterPhase_Conflict" -> Trace_RegisterPhase_Conflict(e)
             [] e.event="SetPrimaryInstance_Pending" -> Trace_SetPrimaryInstance_Pending(e)
             [] e.event="AreWalReceiversDown" -> Trace_AreWalReceiversDown(e)
             [] e.event="SetPrimaryInstance_Target" -> Trace_SetPrimaryInstance_Target(e)
             [] e.event="DeliverCluster" -> Trace_DeliverCluster(e)
             [] e.event="InstanceReconcile_GetCluster" -> Trace_InstanceReconcile_GetCluster(e)
             [] e.event="RefreshConfigurationFiles" -> Trace_RefreshConfigurationFiles(e)
             [] e.event="VerifyPgDataCoherenceForPrimary" -> Trace_VerifyPgDataCoherenceForPrimary(e)
             [] e.event="VerifyPgDataCoherenceForPrimary_Wait" -> Trace_VerifyPgDataCoherenceForPrimary_Wait(e)
             [] e.event="VerifyPgDataCoherenceForPrimary_Archive" -> Trace_VerifyPgDataCoherenceForPrimary_Archive(e)
             [] e.event="Rewind_Demote" -> Trace_Rewind_Demote(e)
             [] e.event="RunPostgresAndWait" -> Trace_RunPostgresAndWait(e)
             [] e.event="InstanceIsReady" -> Trace_InstanceIsReady(e)
             [] e.event="ReconcilePrimary" -> Trace_ReconcilePrimary(e)
             [] e.event="Acquire" -> Trace_Acquire(e)
             [] e.event="Acquire_Return" -> Trace_Acquire_Return(e)
             [] e.event="Acquire_Deadline" -> Trace_Acquire_Deadline(e)
             [] e.event="WaitForWalReceiverDown" -> Trace_WaitForWalReceiverDown(e)
             [] e.event="PromoteAndWait_Request" -> Trace_PromoteAndWait_Request(e)
             [] e.event="PromoteAndWait_Complete" -> Trace_PromoteAndWait_Complete(e)
             [] e.event="PromoteAndWait_Return" -> Trace_PromoteAndWait_Return(e)
             [] e.event="ReconcilePrimary_CompleteStatus" -> Trace_ReconcilePrimary_CompleteStatus(e)
             [] e.event="ReconcileOldPrimary" -> Trace_ReconcileOldPrimary(e)
             [] e.event="ReconcileConfiguration" -> Trace_ReconcileConfiguration(e)
             [] e.event="ResetFailoverQuorumObject_Get" -> Trace_ResetFailoverQuorumObject_Get(e)
             [] e.event="ResetFailoverQuorumObject_Update" -> Trace_ResetFailoverQuorumObject_Update(e)
             [] e.event="FailoverQuorum_Conflict" -> Trace_FailoverQuorum_Conflict(e)
             [] e.event="Reload" -> Trace_Reload(e)
             [] e.event="ProcessConfigReloadAndManageRestart" -> Trace_ProcessConfigReloadAndManageRestart(e)
             [] e.event="GetSynchronousReplicationMetadata" -> Trace_GetSynchronousReplicationMetadata(e)
             [] e.event="UpdateFailoverQuorumObject_Get" -> Trace_UpdateFailoverQuorumObject_Get(e)
             [] e.event="UpdateFailoverQuorumObject_Update" -> Trace_UpdateFailoverQuorumObject_Update(e)
             [] e.event="TryTakeOver_Get" -> Trace_TryTakeOver_Get(e)
             [] e.event="TryTakeOver_ReadError" -> Trace_TryTakeOver_ReadError(e)
             [] e.event="TryTakeOver_OwnHolder" -> Trace_TryTakeOver_OwnHolder(e)
             [] e.event="TryTakeOver_EmptyHolder" -> Trace_TryTakeOver_EmptyHolder(e)
             [] e.event="TryTakeOver_ForeignHolder" -> Trace_TryTakeOver_ForeignHolder(e)
             [] e.event="PreAcquire_Retry" -> Trace_PreAcquire_Retry(e)
             [] e.event="Claim" -> Trace_Claim(e)
             [] e.event="Claim_ConflictOrError" -> Trace_Claim_ConflictOrError(e)
             [] e.event="RunLeaderElection_FirstAcquired" -> Trace_RunLeaderElection_FirstAcquired(e)
             [] e.event="LeaderElection_Retry" -> Trace_LeaderElection_Retry(e)
             [] e.event="LeaderElection_RenewFast" -> Trace_LeaderElection_RenewFast(e)
             [] e.event="LeaderElection_Fallback" -> Trace_LeaderElection_Fallback(e)
             [] e.event="LeaderElection_Get" -> Trace_LeaderElection_Get(e)
             [] e.event="LeaderElection_GetError" -> Trace_LeaderElection_GetError(e)
             [] e.event="LeaderElection_Check" -> Trace_LeaderElection_Check(e)
             [] e.event="LeaderElection_Update" -> Trace_LeaderElection_Update(e)
             [] e.event="LeaderElection_UpdateError" -> Trace_LeaderElection_UpdateError(e)
             [] e.event="RunLeaderElection_RenewDeadline" -> Trace_RunLeaderElection_RenewDeadline(e)
             [] e.event="ClassifyLeaseAfterRun_Get" -> Trace_ClassifyLeaseAfterRun_Get(e)
             [] e.event="ClassifyLeaseAfterRun_Unverifiable" -> Trace_ClassifyLeaseAfterRun_Unverifiable(e)
             [] e.event="ClassifyLeaseAfterRun_Held" -> Trace_ClassifyLeaseAfterRun_Held(e)
             [] e.event="ClassifyLeaseAfterRun_Preempted" -> Trace_ClassifyLeaseAfterRun_Preempted(e)
             [] e.event="PostgresLifecycle_Cancelled" -> Trace_PostgresLifecycle_Cancelled(e)
             [] e.event="TryShuttingDownSmartFast_Checkpoint" -> Trace_TryShuttingDownSmartFast_Checkpoint(e)
             [] e.event="Shutdown_StopRequest" -> Trace_Shutdown_StopRequest(e)
             [] e.event="TryShuttingDownSmartFast_Fallback" -> Trace_TryShuttingDownSmartFast_Fallback(e)
             [] e.event="Shutdown_ClientsFinished" -> Trace_Shutdown_ClientsFinished(e)
             [] e.event="Shutdown_ArchiveComplete" -> Trace_Shutdown_ArchiveComplete(e)
             [] e.event="RunPostgresAndWait_Exit" -> Trace_RunPostgresAndWait_Exit(e)
             [] e.event="PostgresLifecycle_Return" -> Trace_PostgresLifecycle_Return(e)
             [] e.event="EngageStopProcedure_GraceExpired" -> Trace_EngageStopProcedure_GraceExpired(e)
             [] e.event="ManagerStart_Return" -> Trace_ManagerStart_Return(e)
             [] e.event="Release_UpgradeSkip" -> Trace_Release_UpgradeSkip(e)
             [] e.event="Release_Get" -> Trace_Release_Get(e)
             [] e.event="Release_Check" -> Trace_Release_Check(e)
             [] e.event="Release_Update" -> Trace_Release_Update(e)
             [] e.event="Release_Error" -> Trace_Release_Error(e)
             [] e.event="Run_ContainerExit" -> Trace_Run_ContainerExit(e)
             [] e.event="IsHealthy_GetCluster" -> Trace_IsHealthy_GetCluster(e)
             [] e.event="IsHealthy_Ping" -> Trace_IsHealthy_Ping(e)
             [] e.event="IsHealthy_IsolationProbe" -> Trace_IsHealthy_IsolationProbe(e)
             [] e.event="TryShuttingDownFastImmediate_Immediate" -> Trace_TryShuttingDownFastImmediate_Immediate(e)
             [] e.event="TryShuttingDownSmartFast_StopTimeout" -> Trace_TryShuttingDownSmartFast_StopTimeout(e)
             [] e.event="GenerateWAL" -> Trace_GenerateWAL(e)
             [] e.event="FlushWAL" -> Trace_FlushWAL(e)
             [] e.event="SendWAL" -> Trace_SendWAL(e)
             [] e.event="ReceiveWAL" -> Trace_ReceiveWAL(e)
             [] e.event="ReplayWAL" -> Trace_ReplayWAL(e)
             [] e.event="AcknowledgeCommit" -> Trace_AcknowledgeCommit(e)
             [] e.event="ArchiveWAL" -> Trace_ArchiveWAL(e)
             [] e.event="RestoreArchiveWAL" -> Trace_RestoreArchiveWAL(e)
             [] e.event="WalReceiverDown" -> Trace_WalReceiverDown(e)
             [] e.event="WalReceiverConnect" -> Trace_WalReceiverConnect(e)
             [] e.event="ReadinessProbe" -> Trace_ReadinessProbe(e)
             [] e.event="ReconcileMetadata" -> Trace_ReconcileMetadata(e)
             [] e.event="RequestPlannedSwitchover" -> Trace_RequestPlannedSwitchover(e)
             [] e.event="ManagerCancellation" -> Trace_ManagerCancellation(e)
             [] e.event="TerminationSignal" -> Trace_TerminationSignal(e)
             [] e.event="OnlineUpgrade" -> Trace_OnlineUpgrade(e)
             [] e.event="OnlineUpgrade_Exec" -> Trace_OnlineUpgrade_Exec(e)
             [] e.event="PodCrash" -> Trace_PodCrash(e)
             [] e.event="PodRestart" -> Trace_PodRestart(e)
             [] e.event="PermitPodRestart" -> Trace_PermitPodRestart(e)
             [] e.event="PodEviction" -> Trace_PodEviction(e)
             [] e.event="APIFailure" -> Trace_APIFailure(e)
             [] e.event="APIFailure_Recover" -> Trace_APIFailure_Recover(e)
             [] e.event="HTTPFailure" -> Trace_HTTPFailure(e)
             [] e.event="HTTPFailure_Recover" -> Trace_HTTPFailure_Recover(e)
             [] e.event="ProbeFailure" -> Trace_ProbeFailure(e)
             [] e.event="ProbeFailure_Recover" -> Trace_ProbeFailure_Recover(e)
             [] e.event="ReplicationDisconnect" -> Trace_ReplicationDisconnect(e)
             [] e.event="ReplicationDisconnect_Recover" -> Trace_ReplicationDisconnect_Recover(e)
             [] e.event="PeerFailure" -> Trace_PeerFailure(e)
             [] e.event="PeerFailure_Recover" -> Trace_PeerFailure_Recover(e)
             [] e.event="StorageStall" -> Trace_StorageStall(e)
             [] e.event="StorageStall_Recover" -> Trace_StorageStall_Recover(e)
             [] e.event="SQLUnavailable" -> Trace_SQLUnavailable(e)
             [] e.event="SQLUnavailable_Recover" -> Trace_SQLUnavailable_Recover(e)
             [] e.event="OperatorCrash" -> Trace_OperatorCrash(e)
             [] e.event="OperatorRecover" -> Trace_OperatorRecover(e)
             [] e.event="OperatorAPIFailure" -> Trace_OperatorAPIFailure(e)
             [] e.event="OperatorAPIRecover" -> Trace_OperatorAPIRecover(e)
             [] e.event="UpdateLeaseConfiguration" -> Trace_UpdateLeaseConfiguration(e)
             [] e.event="UpdateSynchronousConfiguration" -> Trace_UpdateSynchronousConfiguration(e)
             [] e.event="RecoverEnvironment" -> Trace_RecoverEnvironment(e)
             [] e.event="ClockTick" -> Trace_ClockTick(e)
             [] e.event="DeliverOperatorCluster" -> Trace_DeliverOperatorCluster(e)
             [] e.event="Reconcile_APIError" -> Trace_Reconcile_APIError(e)
             [] e.event="MarkOldPrimaryAsUnhealthy_Error" -> Trace_MarkOldPrimaryAsUnhealthy_Error(e)
             [] e.event="InstanceReconcile_APIError" -> Trace_InstanceReconcile_APIError(e)
             [] e.event="GetSynchronousReplicationMetadata_Error" -> Trace_GetSynchronousReplicationMetadata_Error(e)
             [] OTHER -> FALSE
TraceDone == l>Len(TraceLog) /\ UNCHANGED traceVars
TraceNext == TraceAdvance \/ TraceDone
\* Fair advance eliminates arbitrary stuttering of a matchable event. An
\* unmatchable event remains stuck and violates TraceMatched.
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceAdvance)
TraceMatched == <>(l>Len(TraceLog))
=============================================================================
