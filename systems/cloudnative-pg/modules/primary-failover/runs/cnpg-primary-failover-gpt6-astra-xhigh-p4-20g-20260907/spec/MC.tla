------------------------------- MODULE MC -------------------------------
EXTENDS base
\* Preserve the original definitions when cfg overrides the exported actions.
cnpg == INSTANCE base
CONSTANTS ApiLimit, CancellationLimit, CrashesLimit, EvictionsLimit, HttpLimit, IoLimit, LeaseUpdatesLimit, OperatorAPILimit, OperatorCrashesLimit, PeerLimit, PlannedLimit, ProbeLimit, RequestsLimit, SignalsLimit, SqlLimit, SyncUpdatesLimit, UpgradesLimit, WalLimit, MaxMsgBuffer
VARIABLE faultCounters, fairIndex, fairRound
mcvars == <<s,faultCounters,fairIndex,fairRound>>
FaultKeys == {"api", "cancellation", "crashes", "evictions", "http", "io", "leaseUpdates", "operatorAPI", "operatorCrashes", "peer", "planned", "probe", "requests", "signals", "sql", "syncUpdates", "upgrades", "wal"}
Limits == [api |-> ApiLimit, cancellation |-> CancellationLimit, crashes |-> CrashesLimit, evictions |-> EvictionsLimit, http |-> HttpLimit, io |-> IoLimit, leaseUpdates |-> LeaseUpdatesLimit, operatorAPI |-> OperatorAPILimit, operatorCrashes |-> OperatorCrashesLimit, peer |-> PeerLimit, planned |-> PlannedLimit, probe |-> ProbeLimit, requests |-> RequestsLimit, signals |-> SignalsLimit, sql |-> SqlLimit, syncUpdates |-> SyncUpdatesLimit, upgrades |-> UpgradesLimit, wal |-> WalLimit]
\* Raw counters are omitted from this optional diagnostic projection.
\* Do not enable VIEW in exhaustive cfgs: remaining budgets distinguish states.
ModelView == s
Symmetry == Permutations(Server)
\* One ordered WAL buffer per receiver; HTTP/API calls use bounded PC snapshots.
MsgBufferConstraint == Cardinality({n\in Server:s.sent[n]#s.data[n].received})<=MaxMsgBuffer
MCTypeOK == TypeOK /\ faultCounters\in [FaultKeys->Nat] /\ (\A k\in FaultKeys:faultCounters[k]<=Limits[k])
MCInit == cnpg!Init /\ faultCounters=[k\in FaultKeys |-> 0] /\ fairIndex=1 /\ fairRound=FALSE

\* OC:300-329,382-390; reactive, no counter bound.
MCReconcile_GetCluster ==
    /\ cnpg!Reconcile_GetCluster
    /\ UNCHANGED faultCounters

\* OC:383-390; OS:298-323; pkg/reconciler/persistentvolumeclaim/status.go:233-235; reactive, no counter bound.
MCGetManagedResources ==
    /\ cnpg!GetManagedResources
    /\ UNCHANGED faultCounters

\* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235; reactive, no counter bound.
MCUpdateResourceStatus ==
    /\ cnpg!UpdateResourceStatus
    /\ UNCHANGED faultCounters

\* OC:389-398; OS:401-404; reactive, no counter bound.
MCUpdateResourceStatus_Conflict ==
    /\ cnpg!UpdateResourceStatus_Conflict
    /\ UNCHANGED faultCounters

\* OC:408-428,454-455; reactive, no counter bound.
MCReconcile_TransitionGuard ==
    /\ cnpg!Reconcile_TransitionGuard
    /\ UNCHANGED faultCounters

\* OC:413-427; OR:144-158,202-229; reactive, no counter bound.
MCMarkOldPrimaryAsUnhealthy ==
    /\ cnpg!MarkOldPrimaryAsUnhealthy
    /\ UNCHANGED faultCounters

\* RC:134-137,143-178,181-201; PS:282-325; reactive, no counter bound.
MCGetReplicaStatusFromPodViaHTTP(n) ==
    /\ cnpg!GetReplicaStatusFromPodViaHTTP(n)
    /\ UNCHANGED faultCounters

\* OC:476-485,636-685; PS:282-325; reactive, no counter bound.
MCEvaluatePodReadinessGuards ==
    /\ cnpg!EvaluatePodReadinessGuards
    /\ UNCHANGED faultCounters

\* OR:99-139; OC:545-547; reactive, no counter bound.
MCReconcileTargetPrimaryForNonReplicaCluster ==
    /\ cnpg!ReconcileTargetPrimaryForNonReplicaCluster
    /\ UNCHANGED faultCounters

\* OQ:48-60; OQ:76-117; reactive, no counter bound.
MCEvaluateQuorumCheck_Get ==
    /\ cnpg!EvaluateQuorumCheck_Get
    /\ UNCHANGED faultCounters

\* OQ:48-60; OC:120-135 (cached client); reactive, no counter bound.
MCDeliverFailoverQuorum ==
    /\ cnpg!DeliverFailoverQuorum
    /\ UNCHANGED faultCounters

\* OQ:76-117; OR:114-139; reactive, no counter bound.
MCEvaluateQuorumCheckWithStatus ==
    /\ cnpg!EvaluateQuorumCheckWithStatus
    /\ UNCHANGED faultCounters

\* OU:229-264; OR:298-329; reactive, no counter bound.
MCUpdatePrimaryPod_Select ==
    /\ cnpg!UpdatePrimaryPod_Select
    /\ UNCHANGED faultCounters

\* OU:242-255; OR:299-312; reactive, no counter bound.
MCUpdatePrimaryPod_Wait ==
    /\ cnpg!UpdatePrimaryPod_Wait
    /\ UNCHANGED faultCounters

\* OS:765-776; SP:52-61; reactive, no counter bound.
MCRegisterPhase_Get ==
    /\ cnpg!RegisterPhase_Get
    /\ UNCHANGED faultCounters

\* SP:63-75; OR:135-139,176-196; OU:170-174; reactive, no counter bound.
MCRegisterPhase_Patch ==
    /\ cnpg!RegisterPhase_Patch
    /\ UNCHANGED faultCounters

\* SP:52-75; reactive, no counter bound.
MCRegisterPhase_Conflict ==
    /\ cnpg!RegisterPhase_Conflict
    /\ UNCHANGED faultCounters

\* OR:129-159; OS:752-760; reactive, no counter bound.
MCSetPrimaryInstance_Pending ==
    /\ cnpg!SetPrimaryInstance_Pending
    /\ UNCHANGED faultCounters

\* OR:161-196; PS:331-341; reactive, no counter bound.
MCAreWalReceiversDown ==
    /\ cnpg!AreWalReceiversDown
    /\ UNCHANGED faultCounters

\* OR:196,329; OS:752-760; OU:170-174; reactive, no counter bound.
MCSetPrimaryInstance_Target ==
    /\ cnpg!SetPrimaryInstance_Target
    /\ UNCHANGED faultCounters

\* CMD:185-215; IC:136-164; reactive, no counter bound.
MCDeliverCluster(n) ==
    /\ cnpg!DeliverCluster(n)
    /\ UNCHANGED faultCounters

\* IC:136-164,206-217; reactive, no counter bound.
MCInstanceReconcile_GetCluster(n) ==
    /\ cnpg!InstanceReconcile_GetCluster(n)
    /\ UNCHANGED faultCounters

\* IC:206-217,417-453; pkg/management/postgres/configuration.go:69-99; SY:45-79; reactive, no counter bound.
MCRefreshConfigurationFiles(n) ==
    /\ cnpg!RefreshConfigurationFiles(n)
    /\ UNCHANGED faultCounters

\* IS:41-49,72-85; IC:212-227; reactive, no counter bound.
MCVerifyPgDataCoherenceForPrimary(n) ==
    /\ cnpg!VerifyPgDataCoherenceForPrimary(n)
    /\ UNCHANGED faultCounters

\* IS:87-110; reactive, no counter bound.
MCVerifyPgDataCoherenceForPrimary_Wait(n) ==
    /\ cnpg!VerifyPgDataCoherenceForPrimary_Wait(n)
    /\ UNCHANGED faultCounters

\* IS:108-146; reactive, no counter bound.
MCVerifyPgDataCoherenceForPrimary_Archive(n) ==
    /\ cnpg!VerifyPgDataCoherenceForPrimary_Archive(n)
    /\ UNCHANGED faultCounters

\* IS:146-152; PG:1011-1028; reactive, no counter bound.
MCRewind_Demote(n) ==
    /\ cnpg!Rewind_Demote(n)
    /\ UNCHANGED faultCounters

\* LP:62-103,129-140; reactive, no counter bound.
MCRunPostgresAndWait(n) ==
    /\ cnpg!RunPostgresAndWait(n)
    /\ UNCHANGED faultCounters

\* IC:229-246; reactive, no counter bound.
MCInstanceIsReady(n) ==
    /\ cnpg!InstanceIsReady(n)
    /\ UNCHANGED faultCounters

\* IC:1203-1226; reactive, no counter bound.
MCReconcilePrimary(n) ==
    /\ cnpg!ReconcilePrimary(n)
    /\ UNCHANGED faultCounters

\* LR:147-162; IC:1215-1234; reactive, no counter bound.
MCAcquire(n) ==
    /\ cnpg!Acquire(n)
    /\ UNCHANGED faultCounters

\* LR:158-162; IC:1237-1259; reactive, no counter bound.
MCAcquire_Return(n) ==
    /\ cnpg!Acquire_Return(n)
    /\ UNCHANGED faultCounters

\* IC:1215-1234; LR:150-162; reactive, no counter bound.
MCAcquire_Deadline(n) ==
    /\ cnpg!Acquire_Deadline(n)
    /\ UNCHANGED faultCounters

\* IC:1295-1306,1343-1359; reactive, no counter bound.
MCWaitForWalReceiverDown(n) ==
    /\ cnpg!WaitForWalReceiverDown(n)
    /\ UNCHANGED faultCounters

\* PR:35-56; IC:1304-1309; reactive, no counter bound.
MCPromoteAndWait_Request(n) ==
    /\ cnpg!PromoteAndWait_Request(n)
    /\ UNCHANGED faultCounters

\* PR:58-93; FD:68-86; IC:1255-1268; reactive, no counter bound.
MCPromoteAndWait_Complete(n) ==
    /\ cnpg!PromoteAndWait_Complete(n)
    /\ UNCHANGED faultCounters

\* PR:66-93; IC:1256-1266; reactive, no counter bound.
MCPromoteAndWait_Return(n) ==
    /\ cnpg!PromoteAndWait_Return(n)
    /\ UNCHANGED faultCounters

\* IC:1237,1262-1268; reactive, no counter bound.
MCReconcilePrimary_CompleteStatus(n) ==
    /\ cnpg!ReconcilePrimary_CompleteStatus(n)
    /\ UNCHANGED faultCounters

\* IC:614-639; reactive, no counter bound.
MCReconcileOldPrimary(n) ==
    /\ cnpg!ReconcileOldPrimary(n)
    /\ UNCHANGED faultCounters

\* IC:277-299; IQ:98-109; reactive, no counter bound.
MCReconcileConfiguration(n) ==
    /\ cnpg!ReconcileConfiguration(n)
    /\ UNCHANGED faultCounters

\* IQ:34-49; CMD:219-230; reactive, no counter bound.
MCResetFailoverQuorumObject_Get(n) ==
    /\ cnpg!ResetFailoverQuorumObject_Get(n)
    /\ UNCHANGED faultCounters

\* IQ:39-49; IC:288-291; reactive, no counter bound.
MCResetFailoverQuorumObject_Update(n) ==
    /\ cnpg!ResetFailoverQuorumObject_Update(n)
    /\ UNCHANGED faultCounters

\* IQ:39-49,80-95; reactive, no counter bound.
MCFailoverQuorum_Conflict(n) ==
    /\ cnpg!FailoverQuorum_Conflict(n)
    /\ UNCHANGED faultCounters

\* IC:288-295; PG:727-756; reactive, no counter bound.
MCReload(n) ==
    /\ cnpg!Reload(n)
    /\ UNCHANGED faultCounters

\* IC:291-299; PG:1100-1115,1120-1150; reactive, no counter bound.
MCProcessConfigReloadAndManageRestart(n) ==
    /\ cnpg!ProcessConfigReloadAndManageRestart(n)
    /\ UNCHANGED faultCounters

\* IQ:54-78; PG:1156-1181; reactive, no counter bound.
MCGetSynchronousReplicationMetadata(n) ==
    /\ cnpg!GetSynchronousReplicationMetadata(n)
    /\ UNCHANGED faultCounters

\* IQ:80-89; CMD:219-230; reactive, no counter bound.
MCUpdateFailoverQuorumObject_Get(n) ==
    /\ cnpg!UpdateFailoverQuorumObject_Get(n)
    /\ UNCHANGED faultCounters

\* IQ:88-95; reactive, no counter bound.
MCUpdateFailoverQuorumObject_Update(n) ==
    /\ cnpg!UpdateFailoverQuorumObject_Update(n)
    /\ UNCHANGED faultCounters

\* LR:295-310; LL:42-53; reactive, no counter bound.
MCTryTakeOver_Get(n) ==
    /\ cnpg!TryTakeOver_Get(n)
    /\ UNCHANGED faultCounters

\* LR:302-304,383-397; reactive, no counter bound.
MCTryTakeOver_ReadError(n) ==
    /\ cnpg!TryTakeOver_ReadError(n)
    /\ UNCHANGED faultCounters

\* LR:308-310,443-450; reactive, no counter bound.
MCTryTakeOver_OwnHolder(n) ==
    /\ cnpg!TryTakeOver_OwnHolder(n)
    /\ UNCHANGED faultCounters

\* LR:313-318; reactive, no counter bound.
MCTryTakeOver_EmptyHolder(n) ==
    /\ cnpg!TryTakeOver_EmptyHolder(n)
    /\ UNCHANGED faultCounters

\* LR:320-334,340-342; reactive, no counter bound.
MCTryTakeOver_ForeignHolder(n) ==
    /\ cnpg!TryTakeOver_ForeignHolder(n)
    /\ UNCHANGED faultCounters

\* LR:370-398; reactive, no counter bound.
MCPreAcquire_Retry(n) ==
    /\ cnpg!PreAcquire_Retry(n)
    /\ UNCHANGED faultCounters

\* LR:344-360; LL:73-95; reactive, no counter bound.
MCClaim(n) ==
    /\ cnpg!Claim(n)
    /\ UNCHANGED faultCounters

\* LR:348-357,383-397; reactive, no counter bound.
MCClaim_ConflictOrError(n) ==
    /\ cnpg!Claim_ConflictOrError(n)
    /\ UNCHANGED faultCounters

\* LR:443-450; reactive, no counter bound.
MCRunLeaderElection_FirstAcquired(n) ==
    /\ cnpg!RunLeaderElection_FirstAcquired(n)
    /\ UNCHANGED faultCounters

\* LE:253-275,284-306; reactive, no counter bound.
MCLeaderElection_Retry(n) ==
    /\ cnpg!LeaderElection_Retry(n)
    /\ UNCHANGED faultCounters

\* LE:454-466; LL:73-95; reactive, no counter bound.
MCLeaderElection_RenewFast(n) ==
    /\ cnpg!LeaderElection_RenewFast(n)
    /\ UNCHANGED faultCounters

\* LE:454-470; reactive, no counter bound.
MCLeaderElection_Fallback(n) ==
    /\ cnpg!LeaderElection_Fallback(n)
    /\ UNCHANGED faultCounters

\* LE:470-490; LL:42-53; reactive, no counter bound.
MCLeaderElection_Get(n) ==
    /\ cnpg!LeaderElection_Get(n)
    /\ UNCHANGED faultCounters

\* LE:470-474,284-306; reactive, no counter bound.
MCLeaderElection_GetError(n) ==
    /\ cnpg!LeaderElection_GetError(n)
    /\ UNCHANGED faultCounters

\* LE:486-508; reactive, no counter bound.
MCLeaderElection_Check(n) ==
    /\ cnpg!LeaderElection_Check(n)
    /\ UNCHANGED faultCounters

\* LE:497-514; LL:73-95; reactive, no counter bound.
MCLeaderElection_Update(n) ==
    /\ cnpg!LeaderElection_Update(n)
    /\ UNCHANGED faultCounters

\* LE:508-511,284-306; reactive, no counter bound.
MCLeaderElection_UpdateError(n) ==
    /\ cnpg!LeaderElection_UpdateError(n)
    /\ UNCHANGED faultCounters

\* LE:284-306; LR:479-490; reactive, no counter bound.
MCRunLeaderElection_RenewDeadline(n) ==
    /\ cnpg!RunLeaderElection_RenewDeadline(n)
    /\ UNCHANGED faultCounters

\* LR:489-493; reactive, no counter bound.
MCClassifyLeaseAfterRun_Get(n) ==
    /\ cnpg!ClassifyLeaseAfterRun_Get(n)
    /\ UNCHANGED faultCounters

\* LR:269-270,489-503; reactive, no counter bound.
MCClassifyLeaseAfterRun_Unverifiable(n) ==
    /\ cnpg!ClassifyLeaseAfterRun_Unverifiable(n)
    /\ UNCHANGED faultCounters

\* LR:273-276,493-515; reactive, no counter bound.
MCClassifyLeaseAfterRun_Held(n) ==
    /\ cnpg!ClassifyLeaseAfterRun_Held(n)
    /\ UNCHANGED faultCounters

\* LR:273-274,504-512; CM:530-532; reactive, no counter bound.
MCClassifyLeaseAfterRun_Preempted(n) ==
    /\ cnpg!ClassifyLeaseAfterRun_Preempted(n)
    /\ UNCHANGED faultCounters

\* LC:122-135; reactive, no counter bound.
MCPostgresLifecycle_Cancelled(n) ==
    /\ cnpg!PostgresLifecycle_Cancelled(n)
    /\ UNCHANGED faultCounters

\* LC:132-149; PG:581-590,1635-1667; reactive, no counter bound.
MCTryShuttingDownSmartFast_Checkpoint(n) ==
    /\ cnpg!TryShuttingDownSmartFast_Checkpoint(n)
    /\ UNCHANGED faultCounters

\* PG:589-618,645-673,690-709; reactive, no counter bound.
MCShutdown_StopRequest(n) ==
    /\ cnpg!Shutdown_StopRequest(n)
    /\ UNCHANGED faultCounters

\* PG:645-673; reactive, no counter bound.
MCTryShuttingDownSmartFast_Fallback(n) ==
    /\ cnpg!TryShuttingDownSmartFast_Fallback(n)
    /\ UNCHANGED faultCounters

\* PG:626-680; FD:40-53; reactive, no counter bound.
MCShutdown_ClientsFinished(n) ==
    /\ cnpg!Shutdown_ClientsFinished(n)
    /\ UNCHANGED faultCounters

\* PG:581-623; LP:134-140; FD:40-46,78-86; reactive, no counter bound.
MCShutdown_ArchiveComplete(n) ==
    /\ cnpg!Shutdown_ArchiveComplete(n)
    /\ UNCHANGED faultCounters

\* LP:134-140; LC:116-120,132-149; reactive, no counter bound.
MCRunPostgresAndWait_Exit(n) ==
    /\ cnpg!RunPostgresAndWait_Exit(n)
    /\ UNCHANGED faultCounters

\* LC:73-75,116-149; CMD:379-385; reactive, no counter bound.
MCPostgresLifecycle_Return(n) ==
    /\ cnpg!PostgresLifecycle_Return(n)
    /\ UNCHANGED faultCounters

\* CM:57,513-518,602-606; reactive, no counter bound.
MCEngageStopProcedure_GraceExpired(n) ==
    /\ cnpg!EngageStopProcedure_GraceExpired(n)
    /\ UNCHANGED faultCounters

\* CM:602-614; CMD:450-460; reactive, no counter bound.
MCManagerStart_Return(n) ==
    /\ cnpg!ManagerStart_Return(n)
    /\ UNCHANGED faultCounters

\* LR:188-194; CMD:392-399; reactive, no counter bound.
MCRelease_UpgradeSkip(n) ==
    /\ cnpg!Release_UpgradeSkip(n)
    /\ UNCHANGED faultCounters

\* LR:196-208; reactive, no counter bound.
MCRelease_Get(n) ==
    /\ cnpg!Release_Get(n)
    /\ UNCHANGED faultCounters

\* LR:204-208,216-221; reactive, no counter bound.
MCRelease_Check(n) ==
    /\ cnpg!Release_Check(n)
    /\ UNCHANGED faultCounters

\* LR:210-221; LL:73-95; CMD:392-399; reactive, no counter bound.
MCRelease_Update(n) ==
    /\ cnpg!Release_Update(n)
    /\ UNCHANGED faultCounters

\* LR:196-203,216-221; CMD:396-398; reactive, no counter bound.
MCRelease_Error(n) ==
    /\ cnpg!Release_Error(n)
    /\ UNCHANGED faultCounters

\* CMD:450-475; LC:102-104; FD:82-86; reactive, no counter bound.
MCRun_ContainerExit(n) ==
    /\ cnpg!Run_ContainerExit(n)
    /\ UNCHANGED faultCounters

\* LV:56-88; reactive, no counter bound.
MCIsHealthy_GetCluster(n) ==
    /\ cnpg!IsHealthy_GetCluster(n)
    /\ UNCHANGED faultCounters

\* LV:79-87,108-122; pkg/management/postgres/webserver/probes/pinger.go:104-113; reactive, no counter bound.
MCIsHealthy_Ping(n) ==
    /\ cnpg!IsHealthy_Ping(n)
    /\ UNCHANGED faultCounters

\* LV:72-88,108-115; LC:137-149; reactive, no counter bound.
MCIsHealthy_IsolationProbe(n) ==
    /\ cnpg!IsHealthy_IsolationProbe(n)
    /\ UNCHANGED faultCounters

\* PG:687-709; FD:40-53; reactive, no counter bound.
MCTryShuttingDownFastImmediate_Immediate(n) ==
    /\ cnpg!TryShuttingDownFastImmediate_Immediate(n)
    /\ UNCHANGED faultCounters

\* PG:660-677; LC:132-149; reactive, no counter bound.
MCTryShuttingDownSmartFast_StopTimeout(n) ==
    /\ cnpg!TryShuttingDownSmartFast_StopTimeout(n)
    /\ UNCHANGED faultCounters

\* FD:291-307,399-405; SY:45-79; fault/workload stimulus requests.
MCGenerateWAL(n,w) ==
    /\ faultCounters.requests<RequestsLimit
    /\ cnpg!GenerateWAL(n,w)
    /\ faultCounters'=[faultCounters EXCEPT !.requests=@+1]

\* FD:291-294,399-405; PG:1156-1181 (metadata observation); reactive, no counter bound.
MCFlushWAL(n) ==
    /\ cnpg!FlushWAL(n)
    /\ UNCHANGED faultCounters

\* FD:24-29,291-294; PS:305-312; reactive, no counter bound.
MCSendWAL(n) ==
    /\ cnpg!SendWAL(n)
    /\ UNCHANGED faultCounters

\* FD:24-29,291-294; PS:305-312; reactive, no counter bound.
MCReceiveWAL(n) ==
    /\ cnpg!ReceiveWAL(n)
    /\ UNCHANGED faultCounters

\* IC:1304-1309; PR:35-66; FD:68-86; reactive, no counter bound.
MCReplayWAL(n) ==
    /\ cnpg!ReplayWAL(n)
    /\ UNCHANGED faultCounters

\* FD:291-307,399-405; SY:45-79; reactive, no counter bound.
MCAcknowledgeCommit(n,witnesses) ==
    /\ cnpg!AcknowledgeCommit(n,witnesses)
    /\ UNCHANGED faultCounters

\* FD:68-86; IS:135-143; reactive, no counter bound.
MCArchiveWAL(n) ==
    /\ cnpg!ArchiveWAL(n)
    /\ UNCHANGED faultCounters

\* FD:68-86; IC:1304-1309; reactive, no counter bound.
MCRestoreArchiveWAL(n,a) ==
    /\ cnpg!RestoreArchiveWAL(n,a)
    /\ UNCHANGED faultCounters

\* IC:1343-1359; PS:331-341; FD:24-29; reactive, no counter bound.
MCWalReceiverDown(n) ==
    /\ cnpg!WalReceiverDown(n)
    /\ UNCHANGED faultCounters

\* OR:144-147,202-229; IC:448-451; FD:24-37; reactive, no counter bound.
MCWalReceiverConnect(n,p) ==
    /\ cnpg!WalReceiverConnect(n,p)
    /\ UNCHANGED faultCounters

\* IC:239-242; pkg/utils/pod_conditions.go:35-64; reactive, no counter bound.
MCReadinessProbe(n) ==
    /\ cnpg!ReadinessProbe(n)
    /\ UNCHANGED faultCounters

\* OC:410-427; OR:199-229 (retry fix); FD:29-31; reactive, no counter bound.
MCReconcileMetadata(n) ==
    /\ cnpg!ReconcileMetadata(n)
    /\ UNCHANGED faultCounters

\* OU:157-174,212-264; OR:65-78,262-329; fault/workload stimulus planned.
MCRequestPlannedSwitchover ==
    /\ ~s.env.stable
    /\ faultCounters.planned<PlannedLimit
    /\ cnpg!RequestPlannedSwitchover
    /\ faultCounters'=[faultCounters EXCEPT !.planned=@+1]

\* CM:530-532; LC:122-135; fault/workload stimulus cancellation.
MCManagerCancellation(n) ==
    /\ ~s.env.stable
    /\ faultCounters.cancellation<CancellationLimit
    /\ cnpg!ManagerCancellation(n)
    /\ faultCounters'=[faultCounters EXCEPT !.cancellation=@+1]

\* LC:137-149; fault/workload stimulus signals.
MCTerminationSignal(n) ==
    /\ ~s.env.stable
    /\ faultCounters.signals<SignalsLimit
    /\ cnpg!TerminationSignal(n)
    /\ faultCounters'=[faultCounters EXCEPT !.signals=@+1]

\* LR:175-194; LC:126-129; CMD:379-385; fault/workload stimulus upgrades.
MCOnlineUpgrade(n) ==
    /\ ~s.env.stable
    /\ faultCounters.upgrades<UpgradesLimit
    /\ cnpg!OnlineUpgrade(n)
    /\ faultCounters'=[faultCounters EXCEPT !.upgrades=@+1]

\* LR:179-186; LC:126-129; reactive, no counter bound.
MCOnlineUpgrade_Exec(n) ==
    /\ cnpg!OnlineUpgrade_Exec(n)
    /\ UNCHANGED faultCounters

\* LC:95-120; LP:134-140; FD:82-86; fault/workload stimulus crashes.
MCPodCrash(n) ==
    /\ ~s.env.stable
    /\ faultCounters.crashes<CrashesLimit
    /\ cnpg!PodCrash(n)
    /\ faultCounters'=[faultCounters EXCEPT !.crashes=@+1]

\* LC:102-104; IS:41-152; LR:291-294; reactive, no counter bound.
MCPodRestart(n) ==
    /\ cnpg!PodRestart(n)
    /\ UNCHANGED faultCounters

\* LC:102-104; FD:30-31; reactive, no counter bound.
MCPermitPodRestart(n) ==
    /\ cnpg!PermitPodRestart(n)
    /\ UNCHANGED faultCounters

\* pkg/utils/pod_conditions.go:74-78; OS:298-323; fault/workload stimulus evictions.
MCPodEviction(n) ==
    /\ ~s.env.stable
    /\ faultCounters.evictions<EvictionsLimit
    /\ cnpg!PodEviction(n)
    /\ faultCounters'=[faultCounters EXCEPT !.evictions=@+1]

\* LR:302-304,489-503; fault/workload stimulus api.
MCAPIFailure(n) ==
    /\ ~s.env.stable
    /\ faultCounters.api<ApiLimit
    /\ cnpg!APIFailure(n)
    /\ faultCounters'=[faultCounters EXCEPT !.api=@+1]

\* LR:302-304,489-503; reactive, no counter bound.
MCAPIFailure_Recover(n) ==
    /\ cnpg!APIFailure_Recover(n)
    /\ UNCHANGED faultCounters

\* RC:143-178; OC:663-685; fault/workload stimulus http.
MCHTTPFailure(n) ==
    /\ ~s.env.stable
    /\ faultCounters.http<HttpLimit
    /\ cnpg!HTTPFailure(n)
    /\ faultCounters'=[faultCounters EXCEPT !.http=@+1]

\* RC:143-178; OC:663-685; reactive, no counter bound.
MCHTTPFailure_Recover(n) ==
    /\ cnpg!HTTPFailure_Recover(n)
    /\ UNCHANGED faultCounters

\* pkg/utils/pod_conditions.go:35-64; OC:663-685; fault/workload stimulus probe.
MCProbeFailure(n) ==
    /\ ~s.env.stable
    /\ faultCounters.probe<ProbeLimit
    /\ cnpg!ProbeFailure(n)
    /\ faultCounters'=[faultCounters EXCEPT !.probe=@+1]

\* pkg/utils/pod_conditions.go:35-64; OC:663-685; reactive, no counter bound.
MCProbeFailure_Recover(n) ==
    /\ cnpg!ProbeFailure_Recover(n)
    /\ UNCHANGED faultCounters

\* IC:1343-1359; FD:24-29; fault/workload stimulus wal.
MCReplicationDisconnect(n) ==
    /\ ~s.env.stable
    /\ faultCounters.wal<WalLimit
    /\ cnpg!ReplicationDisconnect(n)
    /\ faultCounters'=[faultCounters EXCEPT !.wal=@+1]

\* IC:1343-1359; FD:24-29; reactive, no counter bound.
MCReplicationDisconnect_Recover(n) ==
    /\ cnpg!ReplicationDisconnect_Recover(n)
    /\ UNCHANGED faultCounters

\* LV:72-88,108-115; fault/workload stimulus peer.
MCPeerFailure(n) ==
    /\ ~s.env.stable
    /\ faultCounters.peer<PeerLimit
    /\ cnpg!PeerFailure(n)
    /\ faultCounters'=[faultCounters EXCEPT !.peer=@+1]

\* LV:72-88,108-115; reactive, no counter bound.
MCPeerFailure_Recover(n) ==
    /\ cnpg!PeerFailure_Recover(n)
    /\ UNCHANGED faultCounters

\* IC:239-242; PG:581-618; PR:35-66; fault/workload stimulus io.
MCStorageStall(n) ==
    /\ ~s.env.stable
    /\ faultCounters.io<IoLimit
    /\ cnpg!StorageStall(n)
    /\ faultCounters'=[faultCounters EXCEPT !.io=@+1]

\* IC:239-242; PG:581-618; PR:35-66; reactive, no counter bound.
MCStorageStall_Recover(n) ==
    /\ cnpg!StorageStall_Recover(n)
    /\ UNCHANGED faultCounters

\* IC:239-242; RC:134-137; fault/workload stimulus sql.
MCSQLUnavailable(n) ==
    /\ ~s.env.stable
    /\ faultCounters.sql<SqlLimit
    /\ cnpg!SQLUnavailable(n)
    /\ faultCounters'=[faultCounters EXCEPT !.sql=@+1]

\* IC:239-242; RC:134-137; reactive, no counter bound.
MCSQLUnavailable_Recover(n) ==
    /\ cnpg!SQLUnavailable_Recover(n)
    /\ UNCHANGED faultCounters

\* OC:300-428; OS:752-776; fault/workload stimulus operatorCrashes.
MCOperatorCrash ==
    /\ ~s.env.stable
    /\ faultCounters.operatorCrashes<OperatorCrashesLimit
    /\ cnpg!OperatorCrash
    /\ faultCounters'=[faultCounters EXCEPT !.operatorCrashes=@+1]

\* OC:300-428; reactive, no counter bound.
MCOperatorRecover ==
    /\ cnpg!OperatorRecover
    /\ UNCHANGED faultCounters

\* OC:383-398; OQ:48-58; fault/workload stimulus operatorAPI.
MCOperatorAPIFailure ==
    /\ ~s.env.stable
    /\ faultCounters.operatorAPI<OperatorAPILimit
    /\ cnpg!OperatorAPIFailure
    /\ faultCounters'=[faultCounters EXCEPT !.operatorAPI=@+1]

\* OC:383-398; OQ:48-58; reactive, no counter bound.
MCOperatorAPIRecover ==
    /\ cnpg!OperatorAPIRecover
    /\ UNCHANGED faultCounters

\* LR:61-76,143-156; IC:1215-1224; FD:153-180; fault/workload stimulus leaseUpdates.
MCUpdateLeaseConfiguration ==
    /\ ~s.env.stable
    /\ faultCounters.leaseUpdates<LeaseUpdatesLimit
    /\ cnpg!UpdateLeaseConfiguration
    /\ faultCounters'=[faultCounters EXCEPT !.leaseUpdates=@+1]

\* SY:45-79,129-147; IC:206-210,277-299; fault/workload stimulus syncUpdates.
MCUpdateSynchronousConfiguration(members,number) ==
    /\ ~s.env.stable
    /\ faultCounters.syncUpdates<SyncUpdatesLimit
    /\ cnpg!UpdateSynchronousConfiguration(members,number)
    /\ faultCounters'=[faultCounters EXCEPT !.syncUpdates=@+1]

\* FD:20-31,350-371; OC:389-455; IC:239-299; reactive, no counter bound.
MCRecoverEnvironment(survivors) ==
    /\ cnpg!RecoverEnvironment(survivors)
    /\ UNCHANGED faultCounters

\* LR:325-333,373-397; LE:284-306; CM:513-518; PG:635-673; reactive, no counter bound.
MCClockTick ==
    /\ cnpg!ClockTick
    /\ UNCHANGED faultCounters

\* OC:300-329; SP:52-55 (controller-runtime cached client); reactive, no counter bound.
MCDeliverOperatorCluster ==
    /\ cnpg!DeliverOperatorCluster
    /\ UNCHANGED faultCounters

\* OC:389-398; OR:135-142,176-196; SP:54-55,67-79; reactive, no counter bound.
MCReconcile_APIError ==
    /\ cnpg!Reconcile_APIError
    /\ UNCHANGED faultCounters

\* OC:413-427; OR:151-159; reactive, no counter bound.
MCMarkOldPrimaryAsUnhealthy_Error ==
    /\ cnpg!MarkOldPrimaryAsUnhealthy_Error
    /\ UNCHANGED faultCounters

\* IC:288-300,1266-1268; IQ:42-48,83-94; reactive, no counter bound.
MCInstanceReconcile_APIError(n) ==
    /\ cnpg!InstanceReconcile_APIError(n)
    /\ UNCHANGED faultCounters

\* PG:1164-1169; IQ:59-62; IC:299-300; reactive, no counter bound.
MCGetSynchronousReplicationMetadata_Error(n) ==
    /\ cnpg!GetSynchronousReplicationMetadata_Error(n)
    /\ UNCHANGED faultCounters

MCStep ==
    \/ (MCReconcile_GetCluster)
    \/ (MCGetManagedResources)
    \/ (MCUpdateResourceStatus)
    \/ (MCUpdateResourceStatus_Conflict)
    \/ (MCReconcile_TransitionGuard)
    \/ (MCMarkOldPrimaryAsUnhealthy)
    \/ (\E n \in Server : MCGetReplicaStatusFromPodViaHTTP(n))
    \/ (MCEvaluatePodReadinessGuards)
    \/ (MCReconcileTargetPrimaryForNonReplicaCluster)
    \/ (MCEvaluateQuorumCheck_Get)
    \/ (MCDeliverFailoverQuorum)
    \/ (MCEvaluateQuorumCheckWithStatus)
    \/ (MCUpdatePrimaryPod_Select)
    \/ (MCUpdatePrimaryPod_Wait)
    \/ (MCRegisterPhase_Get)
    \/ (MCRegisterPhase_Patch)
    \/ (MCRegisterPhase_Conflict)
    \/ (MCSetPrimaryInstance_Pending)
    \/ (MCAreWalReceiversDown)
    \/ (MCSetPrimaryInstance_Target)
    \/ (\E n \in Server : MCDeliverCluster(n))
    \/ (\E n \in Server : MCInstanceReconcile_GetCluster(n))
    \/ (\E n \in Server : MCRefreshConfigurationFiles(n))
    \/ (\E n \in Server : MCVerifyPgDataCoherenceForPrimary(n))
    \/ (\E n \in Server : MCVerifyPgDataCoherenceForPrimary_Wait(n))
    \/ (\E n \in Server : MCVerifyPgDataCoherenceForPrimary_Archive(n))
    \/ (\E n \in Server : MCRewind_Demote(n))
    \/ (\E n \in Server : MCRunPostgresAndWait(n))
    \/ (\E n \in Server : MCInstanceIsReady(n))
    \/ (\E n \in Server : MCReconcilePrimary(n))
    \/ (\E n \in Server : MCAcquire(n))
    \/ (\E n \in Server : MCAcquire_Return(n))
    \/ (\E n \in Server : MCAcquire_Deadline(n))
    \/ (\E n \in Server : MCWaitForWalReceiverDown(n))
    \/ (\E n \in Server : MCPromoteAndWait_Request(n))
    \/ (\E n \in Server : MCPromoteAndWait_Complete(n))
    \/ (\E n \in Server : MCPromoteAndWait_Return(n))
    \/ (\E n \in Server : MCReconcilePrimary_CompleteStatus(n))
    \/ (\E n \in Server : MCReconcileOldPrimary(n))
    \/ (\E n \in Server : MCReconcileConfiguration(n))
    \/ (\E n \in Server : MCResetFailoverQuorumObject_Get(n))
    \/ (\E n \in Server : MCResetFailoverQuorumObject_Update(n))
    \/ (\E n \in Server : MCFailoverQuorum_Conflict(n))
    \/ (\E n \in Server : MCReload(n))
    \/ (\E n \in Server : MCProcessConfigReloadAndManageRestart(n))
    \/ (\E n \in Server : MCGetSynchronousReplicationMetadata(n))
    \/ (\E n \in Server : MCUpdateFailoverQuorumObject_Get(n))
    \/ (\E n \in Server : MCUpdateFailoverQuorumObject_Update(n))
    \/ (\E n \in Server : MCTryTakeOver_Get(n))
    \/ (\E n \in Server : MCTryTakeOver_ReadError(n))
    \/ (\E n \in Server : MCTryTakeOver_OwnHolder(n))
    \/ (\E n \in Server : MCTryTakeOver_EmptyHolder(n))
    \/ (\E n \in Server : MCTryTakeOver_ForeignHolder(n))
    \/ (\E n \in Server : MCPreAcquire_Retry(n))
    \/ (\E n \in Server : MCClaim(n))
    \/ (\E n \in Server : MCClaim_ConflictOrError(n))
    \/ (\E n \in Server : MCRunLeaderElection_FirstAcquired(n))
    \/ (\E n \in Server : MCLeaderElection_Retry(n))
    \/ (\E n \in Server : MCLeaderElection_RenewFast(n))
    \/ (\E n \in Server : MCLeaderElection_Fallback(n))
    \/ (\E n \in Server : MCLeaderElection_Get(n))
    \/ (\E n \in Server : MCLeaderElection_GetError(n))
    \/ (\E n \in Server : MCLeaderElection_Check(n))
    \/ (\E n \in Server : MCLeaderElection_Update(n))
    \/ (\E n \in Server : MCLeaderElection_UpdateError(n))
    \/ (\E n \in Server : MCRunLeaderElection_RenewDeadline(n))
    \/ (\E n \in Server : MCClassifyLeaseAfterRun_Get(n))
    \/ (\E n \in Server : MCClassifyLeaseAfterRun_Unverifiable(n))
    \/ (\E n \in Server : MCClassifyLeaseAfterRun_Held(n))
    \/ (\E n \in Server : MCClassifyLeaseAfterRun_Preempted(n))
    \/ (\E n \in Server : MCPostgresLifecycle_Cancelled(n))
    \/ (\E n \in Server : MCTryShuttingDownSmartFast_Checkpoint(n))
    \/ (\E n \in Server : MCShutdown_StopRequest(n))
    \/ (\E n \in Server : MCTryShuttingDownSmartFast_Fallback(n))
    \/ (\E n \in Server : MCShutdown_ClientsFinished(n))
    \/ (\E n \in Server : MCShutdown_ArchiveComplete(n))
    \/ (\E n \in Server : MCRunPostgresAndWait_Exit(n))
    \/ (\E n \in Server : MCPostgresLifecycle_Return(n))
    \/ (\E n \in Server : MCEngageStopProcedure_GraceExpired(n))
    \/ (\E n \in Server : MCManagerStart_Return(n))
    \/ (\E n \in Server : MCRelease_UpgradeSkip(n))
    \/ (\E n \in Server : MCRelease_Get(n))
    \/ (\E n \in Server : MCRelease_Check(n))
    \/ (\E n \in Server : MCRelease_Update(n))
    \/ (\E n \in Server : MCRelease_Error(n))
    \/ (\E n \in Server : MCRun_ContainerExit(n))
    \/ (\E n \in Server : MCIsHealthy_GetCluster(n))
    \/ (\E n \in Server : MCIsHealthy_Ping(n))
    \/ (\E n \in Server : MCIsHealthy_IsolationProbe(n))
    \/ (\E n \in Server : MCTryShuttingDownFastImmediate_Immediate(n))
    \/ (\E n \in Server : MCTryShuttingDownSmartFast_StopTimeout(n))
    \/ (\E n \in Server, w \in WAL : MCGenerateWAL(n,w))
    \/ (\E n \in Server : MCFlushWAL(n))
    \/ (\E n \in Server : MCSendWAL(n))
    \/ (\E n \in Server : MCReceiveWAL(n))
    \/ (\E n \in Server : MCReplayWAL(n))
    \/ (\E n \in Server, witnesses \in SUBSET Server : MCAcknowledgeCommit(n,witnesses))
    \/ (\E n \in Server : MCArchiveWAL(n))
    \/ (\E n \in Server, a \in s.archive : MCRestoreArchiveWAL(n,a))
    \/ (\E n \in Server : MCWalReceiverDown(n))
    \/ (\E n \in Server, p \in Server : MCWalReceiverConnect(n,p))
    \/ (\E n \in Server : MCReadinessProbe(n))
    \/ (\E n \in Server : MCReconcileMetadata(n))
    \/ (MCRequestPlannedSwitchover)
    \/ (\E n \in Server : MCManagerCancellation(n))
    \/ (\E n \in Server : MCTerminationSignal(n))
    \/ (\E n \in Server : MCOnlineUpgrade(n))
    \/ (\E n \in Server : MCOnlineUpgrade_Exec(n))
    \/ (\E n \in Server : MCPodCrash(n))
    \/ (\E n \in Server : MCPodRestart(n))
    \/ (\E n \in Server : MCPermitPodRestart(n))
    \/ (\E n \in Server : MCPodEviction(n))
    \/ (\E n \in Server : MCAPIFailure(n))
    \/ (\E n \in Server : MCAPIFailure_Recover(n))
    \/ (\E n \in Server : MCHTTPFailure(n))
    \/ (\E n \in Server : MCHTTPFailure_Recover(n))
    \/ (\E n \in Server : MCProbeFailure(n))
    \/ (\E n \in Server : MCProbeFailure_Recover(n))
    \/ (\E n \in Server : MCReplicationDisconnect(n))
    \/ (\E n \in Server : MCReplicationDisconnect_Recover(n))
    \/ (\E n \in Server : MCPeerFailure(n))
    \/ (\E n \in Server : MCPeerFailure_Recover(n))
    \/ (\E n \in Server : MCStorageStall(n))
    \/ (\E n \in Server : MCStorageStall_Recover(n))
    \/ (\E n \in Server : MCSQLUnavailable(n))
    \/ (\E n \in Server : MCSQLUnavailable_Recover(n))
    \/ (MCOperatorCrash)
    \/ (MCOperatorRecover)
    \/ (MCOperatorAPIFailure)
    \/ (MCOperatorAPIRecover)
    \/ (MCUpdateLeaseConfiguration)
    \/ (\E members \in SUBSET Server, number \in 1..(Cardinality(Server)-1) : MCUpdateSynchronousConfiguration(members,number))
    \/ (\E survivors \in SUBSET Server : MCRecoverEnvironment(survivors))
    \/ (MCClockTick)
    \/ (MCDeliverOperatorCluster)
    \/ (MCReconcile_APIError)
    \/ (MCMarkOldPrimaryAsUnhealthy_Error)
    \/ (\E n \in Server : MCInstanceReconcile_APIError(n))
    \/ (\E n \in Server : MCGetSynchronousReplicationMetadata_Error(n))
MCNext == MCStep /\ UNCHANGED <<fairIndex,fairRound>>
MCSpec == MCInit /\ [][MCNext]_mcvars

\* Scenario 5: explicit weak fairness without an exponential temporal DNF.
\* Every normal actor step runs or is observed disabled in each completed
\* round. No fairness on new faults or old-primary resurrection.
NodeTaskNames == <<"GetReplicaStatusFromPodViaHTTP", "DeliverCluster", "InstanceReconcile_GetCluster", "RefreshConfigurationFiles", "VerifyPgDataCoherenceForPrimary", "VerifyPgDataCoherenceForPrimary_Wait", "VerifyPgDataCoherenceForPrimary_Archive", "Rewind_Demote", "RunPostgresAndWait", "InstanceIsReady", "ReconcilePrimary", "Acquire", "Acquire_Return", "Acquire_Deadline", "WaitForWalReceiverDown", "PromoteAndWait_Request", "PromoteAndWait_Complete", "PromoteAndWait_Return", "ReconcilePrimary_CompleteStatus", "ReconcileOldPrimary", "ReconcileConfiguration", "ResetFailoverQuorumObject_Get", "ResetFailoverQuorumObject_Update", "FailoverQuorum_Conflict", "Reload", "ProcessConfigReloadAndManageRestart", "GetSynchronousReplicationMetadata", "UpdateFailoverQuorumObject_Get", "UpdateFailoverQuorumObject_Update", "TryTakeOver_Get", "TryTakeOver_ReadError", "TryTakeOver_OwnHolder", "TryTakeOver_EmptyHolder", "TryTakeOver_ForeignHolder", "PreAcquire_Retry", "Claim", "Claim_ConflictOrError", "RunLeaderElection_FirstAcquired", "LeaderElection_Retry", "LeaderElection_RenewFast", "LeaderElection_Fallback", "LeaderElection_Get", "LeaderElection_GetError", "LeaderElection_Check", "LeaderElection_Update", "LeaderElection_UpdateError", "RunLeaderElection_RenewDeadline", "ClassifyLeaseAfterRun_Get", "ClassifyLeaseAfterRun_Unverifiable", "ClassifyLeaseAfterRun_Held", "ClassifyLeaseAfterRun_Preempted", "PostgresLifecycle_Cancelled", "TryShuttingDownSmartFast_Checkpoint", "Shutdown_StopRequest", "TryShuttingDownSmartFast_Fallback", "Shutdown_ClientsFinished", "Shutdown_ArchiveComplete", "RunPostgresAndWait_Exit", "PostgresLifecycle_Return", "EngageStopProcedure_GraceExpired", "ManagerStart_Return", "Release_UpgradeSkip", "Release_Get", "Release_Check", "Release_Update", "Release_Error", "Run_ContainerExit", "IsHealthy_GetCluster", "IsHealthy_Ping", "IsHealthy_IsolationProbe", "TryShuttingDownFastImmediate_Immediate", "TryShuttingDownSmartFast_StopTimeout", "FlushWAL", "SendWAL", "ReceiveWAL", "ReplayWAL", "AcknowledgeCommit", "ArchiveWAL", "RestoreArchiveWAL", "WalReceiverDown", "WalReceiverConnect", "ReadinessProbe", "ReconcileMetadata", "OnlineUpgrade_Exec", "PodRestart", "APIFailure_Recover", "HTTPFailure_Recover", "ProbeFailure_Recover", "ReplicationDisconnect_Recover", "PeerFailure_Recover", "StorageStall_Recover", "SQLUnavailable_Recover", "InstanceReconcile_APIError", "GetSynchronousReplicationMetadata_Error">>
GlobalTaskNames == <<"Reconcile_GetCluster", "GetManagedResources", "UpdateResourceStatus", "UpdateResourceStatus_Conflict", "Reconcile_TransitionGuard", "MarkOldPrimaryAsUnhealthy", "EvaluatePodReadinessGuards", "ReconcileTargetPrimaryForNonReplicaCluster", "EvaluateQuorumCheck_Get", "DeliverFailoverQuorum", "EvaluateQuorumCheckWithStatus", "UpdatePrimaryPod_Select", "UpdatePrimaryPod_Wait", "RegisterPhase_Get", "RegisterPhase_Patch", "RegisterPhase_Conflict", "SetPrimaryInstance_Pending", "AreWalReceiversDown", "SetPrimaryInstance_Target", "OperatorRecover", "OperatorAPIRecover", "ClockTick", "DeliverOperatorCluster", "Reconcile_APIError", "MarkOldPrimaryAsUnhealthy_Error">>
NodeTaskCount == Len(NodeTaskNames)*Cardinality(Server)
FairTasks == [k\in 1..(NodeTaskCount+Len(GlobalTaskNames)) |-> IF k<=NodeTaskCount THEN <<NodeTaskNames[1+(k-1)\div Cardinality(Server)],s.order[1+(k-1)-Cardinality(Server)*((k-1)\div Cardinality(Server))]>> ELSE <<GlobalTaskNames[k-NodeTaskCount],None>>]
CurrentFairTask == FairTasks[fairIndex]
AdvanceFairMonitor == /\ fairIndex'=(IF fairIndex=Len(FairTasks) THEN 1 ELSE fairIndex+1) /\ fairRound'=(IF fairIndex=Len(FairTasks) THEN ~fairRound ELSE fairRound)
FairAction(t) == CASE
    t[1]="Reconcile_GetCluster" -> MCReconcile_GetCluster
    [] t[1]="GetManagedResources" -> MCGetManagedResources
    [] t[1]="UpdateResourceStatus" -> MCUpdateResourceStatus
    [] t[1]="UpdateResourceStatus_Conflict" -> MCUpdateResourceStatus_Conflict
    [] t[1]="Reconcile_TransitionGuard" -> MCReconcile_TransitionGuard
    [] t[1]="MarkOldPrimaryAsUnhealthy" -> MCMarkOldPrimaryAsUnhealthy
    [] t[1]="GetReplicaStatusFromPodViaHTTP" -> MCGetReplicaStatusFromPodViaHTTP(t[2])
    [] t[1]="EvaluatePodReadinessGuards" -> MCEvaluatePodReadinessGuards
    [] t[1]="ReconcileTargetPrimaryForNonReplicaCluster" -> MCReconcileTargetPrimaryForNonReplicaCluster
    [] t[1]="EvaluateQuorumCheck_Get" -> MCEvaluateQuorumCheck_Get
    [] t[1]="DeliverFailoverQuorum" -> MCDeliverFailoverQuorum
    [] t[1]="EvaluateQuorumCheckWithStatus" -> MCEvaluateQuorumCheckWithStatus
    [] t[1]="UpdatePrimaryPod_Select" -> MCUpdatePrimaryPod_Select
    [] t[1]="UpdatePrimaryPod_Wait" -> MCUpdatePrimaryPod_Wait
    [] t[1]="RegisterPhase_Get" -> MCRegisterPhase_Get
    [] t[1]="RegisterPhase_Patch" -> MCRegisterPhase_Patch
    [] t[1]="RegisterPhase_Conflict" -> MCRegisterPhase_Conflict
    [] t[1]="SetPrimaryInstance_Pending" -> MCSetPrimaryInstance_Pending
    [] t[1]="AreWalReceiversDown" -> MCAreWalReceiversDown
    [] t[1]="SetPrimaryInstance_Target" -> MCSetPrimaryInstance_Target
    [] t[1]="DeliverCluster" -> MCDeliverCluster(t[2])
    [] t[1]="InstanceReconcile_GetCluster" -> MCInstanceReconcile_GetCluster(t[2])
    [] t[1]="RefreshConfigurationFiles" -> MCRefreshConfigurationFiles(t[2])
    [] t[1]="VerifyPgDataCoherenceForPrimary" -> MCVerifyPgDataCoherenceForPrimary(t[2])
    [] t[1]="VerifyPgDataCoherenceForPrimary_Wait" -> MCVerifyPgDataCoherenceForPrimary_Wait(t[2])
    [] t[1]="VerifyPgDataCoherenceForPrimary_Archive" -> MCVerifyPgDataCoherenceForPrimary_Archive(t[2])
    [] t[1]="Rewind_Demote" -> MCRewind_Demote(t[2])
    [] t[1]="RunPostgresAndWait" -> MCRunPostgresAndWait(t[2])
    [] t[1]="InstanceIsReady" -> MCInstanceIsReady(t[2])
    [] t[1]="ReconcilePrimary" -> MCReconcilePrimary(t[2])
    [] t[1]="Acquire" -> MCAcquire(t[2])
    [] t[1]="Acquire_Return" -> MCAcquire_Return(t[2])
    [] t[1]="Acquire_Deadline" -> MCAcquire_Deadline(t[2])
    [] t[1]="WaitForWalReceiverDown" -> MCWaitForWalReceiverDown(t[2])
    [] t[1]="PromoteAndWait_Request" -> MCPromoteAndWait_Request(t[2])
    [] t[1]="PromoteAndWait_Complete" -> MCPromoteAndWait_Complete(t[2])
    [] t[1]="PromoteAndWait_Return" -> MCPromoteAndWait_Return(t[2])
    [] t[1]="ReconcilePrimary_CompleteStatus" -> MCReconcilePrimary_CompleteStatus(t[2])
    [] t[1]="ReconcileOldPrimary" -> MCReconcileOldPrimary(t[2])
    [] t[1]="ReconcileConfiguration" -> MCReconcileConfiguration(t[2])
    [] t[1]="ResetFailoverQuorumObject_Get" -> MCResetFailoverQuorumObject_Get(t[2])
    [] t[1]="ResetFailoverQuorumObject_Update" -> MCResetFailoverQuorumObject_Update(t[2])
    [] t[1]="FailoverQuorum_Conflict" -> MCFailoverQuorum_Conflict(t[2])
    [] t[1]="Reload" -> MCReload(t[2])
    [] t[1]="ProcessConfigReloadAndManageRestart" -> MCProcessConfigReloadAndManageRestart(t[2])
    [] t[1]="GetSynchronousReplicationMetadata" -> MCGetSynchronousReplicationMetadata(t[2])
    [] t[1]="UpdateFailoverQuorumObject_Get" -> MCUpdateFailoverQuorumObject_Get(t[2])
    [] t[1]="UpdateFailoverQuorumObject_Update" -> MCUpdateFailoverQuorumObject_Update(t[2])
    [] t[1]="TryTakeOver_Get" -> MCTryTakeOver_Get(t[2])
    [] t[1]="TryTakeOver_ReadError" -> MCTryTakeOver_ReadError(t[2])
    [] t[1]="TryTakeOver_OwnHolder" -> MCTryTakeOver_OwnHolder(t[2])
    [] t[1]="TryTakeOver_EmptyHolder" -> MCTryTakeOver_EmptyHolder(t[2])
    [] t[1]="TryTakeOver_ForeignHolder" -> MCTryTakeOver_ForeignHolder(t[2])
    [] t[1]="PreAcquire_Retry" -> MCPreAcquire_Retry(t[2])
    [] t[1]="Claim" -> MCClaim(t[2])
    [] t[1]="Claim_ConflictOrError" -> MCClaim_ConflictOrError(t[2])
    [] t[1]="RunLeaderElection_FirstAcquired" -> MCRunLeaderElection_FirstAcquired(t[2])
    [] t[1]="LeaderElection_Retry" -> MCLeaderElection_Retry(t[2])
    [] t[1]="LeaderElection_RenewFast" -> MCLeaderElection_RenewFast(t[2])
    [] t[1]="LeaderElection_Fallback" -> MCLeaderElection_Fallback(t[2])
    [] t[1]="LeaderElection_Get" -> MCLeaderElection_Get(t[2])
    [] t[1]="LeaderElection_GetError" -> MCLeaderElection_GetError(t[2])
    [] t[1]="LeaderElection_Check" -> MCLeaderElection_Check(t[2])
    [] t[1]="LeaderElection_Update" -> MCLeaderElection_Update(t[2])
    [] t[1]="LeaderElection_UpdateError" -> MCLeaderElection_UpdateError(t[2])
    [] t[1]="RunLeaderElection_RenewDeadline" -> MCRunLeaderElection_RenewDeadline(t[2])
    [] t[1]="ClassifyLeaseAfterRun_Get" -> MCClassifyLeaseAfterRun_Get(t[2])
    [] t[1]="ClassifyLeaseAfterRun_Unverifiable" -> MCClassifyLeaseAfterRun_Unverifiable(t[2])
    [] t[1]="ClassifyLeaseAfterRun_Held" -> MCClassifyLeaseAfterRun_Held(t[2])
    [] t[1]="ClassifyLeaseAfterRun_Preempted" -> MCClassifyLeaseAfterRun_Preempted(t[2])
    [] t[1]="PostgresLifecycle_Cancelled" -> MCPostgresLifecycle_Cancelled(t[2])
    [] t[1]="TryShuttingDownSmartFast_Checkpoint" -> MCTryShuttingDownSmartFast_Checkpoint(t[2])
    [] t[1]="Shutdown_StopRequest" -> MCShutdown_StopRequest(t[2])
    [] t[1]="TryShuttingDownSmartFast_Fallback" -> MCTryShuttingDownSmartFast_Fallback(t[2])
    [] t[1]="Shutdown_ClientsFinished" -> MCShutdown_ClientsFinished(t[2])
    [] t[1]="Shutdown_ArchiveComplete" -> MCShutdown_ArchiveComplete(t[2])
    [] t[1]="RunPostgresAndWait_Exit" -> MCRunPostgresAndWait_Exit(t[2])
    [] t[1]="PostgresLifecycle_Return" -> MCPostgresLifecycle_Return(t[2])
    [] t[1]="EngageStopProcedure_GraceExpired" -> MCEngageStopProcedure_GraceExpired(t[2])
    [] t[1]="ManagerStart_Return" -> MCManagerStart_Return(t[2])
    [] t[1]="Release_UpgradeSkip" -> MCRelease_UpgradeSkip(t[2])
    [] t[1]="Release_Get" -> MCRelease_Get(t[2])
    [] t[1]="Release_Check" -> MCRelease_Check(t[2])
    [] t[1]="Release_Update" -> MCRelease_Update(t[2])
    [] t[1]="Release_Error" -> MCRelease_Error(t[2])
    [] t[1]="Run_ContainerExit" -> MCRun_ContainerExit(t[2])
    [] t[1]="IsHealthy_GetCluster" -> MCIsHealthy_GetCluster(t[2])
    [] t[1]="IsHealthy_Ping" -> MCIsHealthy_Ping(t[2])
    [] t[1]="IsHealthy_IsolationProbe" -> MCIsHealthy_IsolationProbe(t[2])
    [] t[1]="TryShuttingDownFastImmediate_Immediate" -> MCTryShuttingDownFastImmediate_Immediate(t[2])
    [] t[1]="TryShuttingDownSmartFast_StopTimeout" -> MCTryShuttingDownSmartFast_StopTimeout(t[2])
    [] t[1]="FlushWAL" -> MCFlushWAL(t[2])
    [] t[1]="SendWAL" -> MCSendWAL(t[2])
    [] t[1]="ReceiveWAL" -> MCReceiveWAL(t[2])
    [] t[1]="ReplayWAL" -> MCReplayWAL(t[2])
    [] t[1]="AcknowledgeCommit" -> (\E witnesses \in SUBSET Server : MCAcknowledgeCommit(t[2],witnesses))
    [] t[1]="ArchiveWAL" -> MCArchiveWAL(t[2])
    [] t[1]="RestoreArchiveWAL" -> (\E a \in s.archive : MCRestoreArchiveWAL(t[2],a))
    [] t[1]="WalReceiverDown" -> MCWalReceiverDown(t[2])
    [] t[1]="WalReceiverConnect" -> (\E p \in Server : MCWalReceiverConnect(t[2],p))
    [] t[1]="ReadinessProbe" -> MCReadinessProbe(t[2])
    [] t[1]="ReconcileMetadata" -> MCReconcileMetadata(t[2])
    [] t[1]="OnlineUpgrade_Exec" -> MCOnlineUpgrade_Exec(t[2])
    [] t[1]="PodRestart" -> MCPodRestart(t[2])
    [] t[1]="APIFailure_Recover" -> MCAPIFailure_Recover(t[2])
    [] t[1]="HTTPFailure_Recover" -> MCHTTPFailure_Recover(t[2])
    [] t[1]="ProbeFailure_Recover" -> MCProbeFailure_Recover(t[2])
    [] t[1]="ReplicationDisconnect_Recover" -> MCReplicationDisconnect_Recover(t[2])
    [] t[1]="PeerFailure_Recover" -> MCPeerFailure_Recover(t[2])
    [] t[1]="StorageStall_Recover" -> MCStorageStall_Recover(t[2])
    [] t[1]="SQLUnavailable_Recover" -> MCSQLUnavailable_Recover(t[2])
    [] t[1]="OperatorRecover" -> MCOperatorRecover
    [] t[1]="OperatorAPIRecover" -> MCOperatorAPIRecover
    [] t[1]="ClockTick" -> MCClockTick
    [] t[1]="DeliverOperatorCluster" -> MCDeliverOperatorCluster
    [] t[1]="Reconcile_APIError" -> MCReconcile_APIError
    [] t[1]="MarkOldPrimaryAsUnhealthy_Error" -> MCMarkOldPrimaryAsUnhealthy_Error
    [] t[1]="InstanceReconcile_APIError" -> MCInstanceReconcile_APIError(t[2])
    [] t[1]="GetSynchronousReplicationMetadata_Error" -> MCGetSynchronousReplicationMetadata_Error(t[2])
    [] OTHER -> FALSE
MCRecoveryInit == cnpg!Init /\ faultCounters=[k\in FaultKeys |-> 0] /\ fairIndex=1 /\ fairRound=FALSE
FairSourceStep ==
    \/ ((MCReconcile_GetCluster /\ (IF CurrentFairTask = <<"Reconcile_GetCluster",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCGetManagedResources /\ (IF CurrentFairTask = <<"GetManagedResources",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCUpdateResourceStatus /\ (IF CurrentFairTask = <<"UpdateResourceStatus",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCUpdateResourceStatus_Conflict /\ (IF CurrentFairTask = <<"UpdateResourceStatus_Conflict",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCReconcile_TransitionGuard /\ (IF CurrentFairTask = <<"Reconcile_TransitionGuard",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCMarkOldPrimaryAsUnhealthy /\ (IF CurrentFairTask = <<"MarkOldPrimaryAsUnhealthy",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCGetReplicaStatusFromPodViaHTTP(n) /\ (IF CurrentFairTask = <<"GetReplicaStatusFromPodViaHTTP",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCEvaluatePodReadinessGuards /\ (IF CurrentFairTask = <<"EvaluatePodReadinessGuards",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCReconcileTargetPrimaryForNonReplicaCluster /\ (IF CurrentFairTask = <<"ReconcileTargetPrimaryForNonReplicaCluster",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCEvaluateQuorumCheck_Get /\ (IF CurrentFairTask = <<"EvaluateQuorumCheck_Get",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCDeliverFailoverQuorum /\ (IF CurrentFairTask = <<"DeliverFailoverQuorum",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCEvaluateQuorumCheckWithStatus /\ (IF CurrentFairTask = <<"EvaluateQuorumCheckWithStatus",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCUpdatePrimaryPod_Select /\ (IF CurrentFairTask = <<"UpdatePrimaryPod_Select",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCUpdatePrimaryPod_Wait /\ (IF CurrentFairTask = <<"UpdatePrimaryPod_Wait",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCRegisterPhase_Get /\ (IF CurrentFairTask = <<"RegisterPhase_Get",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCRegisterPhase_Patch /\ (IF CurrentFairTask = <<"RegisterPhase_Patch",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCRegisterPhase_Conflict /\ (IF CurrentFairTask = <<"RegisterPhase_Conflict",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCSetPrimaryInstance_Pending /\ (IF CurrentFairTask = <<"SetPrimaryInstance_Pending",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCAreWalReceiversDown /\ (IF CurrentFairTask = <<"AreWalReceiversDown",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCSetPrimaryInstance_Target /\ (IF CurrentFairTask = <<"SetPrimaryInstance_Target",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCDeliverCluster(n) /\ (IF CurrentFairTask = <<"DeliverCluster",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCInstanceReconcile_GetCluster(n) /\ (IF CurrentFairTask = <<"InstanceReconcile_GetCluster",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRefreshConfigurationFiles(n) /\ (IF CurrentFairTask = <<"RefreshConfigurationFiles",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCVerifyPgDataCoherenceForPrimary(n) /\ (IF CurrentFairTask = <<"VerifyPgDataCoherenceForPrimary",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCVerifyPgDataCoherenceForPrimary_Wait(n) /\ (IF CurrentFairTask = <<"VerifyPgDataCoherenceForPrimary_Wait",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCVerifyPgDataCoherenceForPrimary_Archive(n) /\ (IF CurrentFairTask = <<"VerifyPgDataCoherenceForPrimary_Archive",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRewind_Demote(n) /\ (IF CurrentFairTask = <<"Rewind_Demote",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRunPostgresAndWait(n) /\ (IF CurrentFairTask = <<"RunPostgresAndWait",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCInstanceIsReady(n) /\ (IF CurrentFairTask = <<"InstanceIsReady",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReconcilePrimary(n) /\ (IF CurrentFairTask = <<"ReconcilePrimary",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCAcquire(n) /\ (IF CurrentFairTask = <<"Acquire",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCAcquire_Return(n) /\ (IF CurrentFairTask = <<"Acquire_Return",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCAcquire_Deadline(n) /\ (IF CurrentFairTask = <<"Acquire_Deadline",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCWaitForWalReceiverDown(n) /\ (IF CurrentFairTask = <<"WaitForWalReceiverDown",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPromoteAndWait_Request(n) /\ (IF CurrentFairTask = <<"PromoteAndWait_Request",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPromoteAndWait_Complete(n) /\ (IF CurrentFairTask = <<"PromoteAndWait_Complete",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPromoteAndWait_Return(n) /\ (IF CurrentFairTask = <<"PromoteAndWait_Return",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReconcilePrimary_CompleteStatus(n) /\ (IF CurrentFairTask = <<"ReconcilePrimary_CompleteStatus",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReconcileOldPrimary(n) /\ (IF CurrentFairTask = <<"ReconcileOldPrimary",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReconcileConfiguration(n) /\ (IF CurrentFairTask = <<"ReconcileConfiguration",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCResetFailoverQuorumObject_Get(n) /\ (IF CurrentFairTask = <<"ResetFailoverQuorumObject_Get",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCResetFailoverQuorumObject_Update(n) /\ (IF CurrentFairTask = <<"ResetFailoverQuorumObject_Update",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCFailoverQuorum_Conflict(n) /\ (IF CurrentFairTask = <<"FailoverQuorum_Conflict",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReload(n) /\ (IF CurrentFairTask = <<"Reload",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCProcessConfigReloadAndManageRestart(n) /\ (IF CurrentFairTask = <<"ProcessConfigReloadAndManageRestart",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCGetSynchronousReplicationMetadata(n) /\ (IF CurrentFairTask = <<"GetSynchronousReplicationMetadata",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCUpdateFailoverQuorumObject_Get(n) /\ (IF CurrentFairTask = <<"UpdateFailoverQuorumObject_Get",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCUpdateFailoverQuorumObject_Update(n) /\ (IF CurrentFairTask = <<"UpdateFailoverQuorumObject_Update",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryTakeOver_Get(n) /\ (IF CurrentFairTask = <<"TryTakeOver_Get",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryTakeOver_ReadError(n) /\ (IF CurrentFairTask = <<"TryTakeOver_ReadError",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryTakeOver_OwnHolder(n) /\ (IF CurrentFairTask = <<"TryTakeOver_OwnHolder",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryTakeOver_EmptyHolder(n) /\ (IF CurrentFairTask = <<"TryTakeOver_EmptyHolder",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryTakeOver_ForeignHolder(n) /\ (IF CurrentFairTask = <<"TryTakeOver_ForeignHolder",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPreAcquire_Retry(n) /\ (IF CurrentFairTask = <<"PreAcquire_Retry",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCClaim(n) /\ (IF CurrentFairTask = <<"Claim",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCClaim_ConflictOrError(n) /\ (IF CurrentFairTask = <<"Claim_ConflictOrError",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRunLeaderElection_FirstAcquired(n) /\ (IF CurrentFairTask = <<"RunLeaderElection_FirstAcquired",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_Retry(n) /\ (IF CurrentFairTask = <<"LeaderElection_Retry",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_RenewFast(n) /\ (IF CurrentFairTask = <<"LeaderElection_RenewFast",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_Fallback(n) /\ (IF CurrentFairTask = <<"LeaderElection_Fallback",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_Get(n) /\ (IF CurrentFairTask = <<"LeaderElection_Get",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_GetError(n) /\ (IF CurrentFairTask = <<"LeaderElection_GetError",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_Check(n) /\ (IF CurrentFairTask = <<"LeaderElection_Check",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_Update(n) /\ (IF CurrentFairTask = <<"LeaderElection_Update",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCLeaderElection_UpdateError(n) /\ (IF CurrentFairTask = <<"LeaderElection_UpdateError",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRunLeaderElection_RenewDeadline(n) /\ (IF CurrentFairTask = <<"RunLeaderElection_RenewDeadline",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCClassifyLeaseAfterRun_Get(n) /\ (IF CurrentFairTask = <<"ClassifyLeaseAfterRun_Get",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCClassifyLeaseAfterRun_Unverifiable(n) /\ (IF CurrentFairTask = <<"ClassifyLeaseAfterRun_Unverifiable",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCClassifyLeaseAfterRun_Held(n) /\ (IF CurrentFairTask = <<"ClassifyLeaseAfterRun_Held",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCClassifyLeaseAfterRun_Preempted(n) /\ (IF CurrentFairTask = <<"ClassifyLeaseAfterRun_Preempted",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPostgresLifecycle_Cancelled(n) /\ (IF CurrentFairTask = <<"PostgresLifecycle_Cancelled",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryShuttingDownSmartFast_Checkpoint(n) /\ (IF CurrentFairTask = <<"TryShuttingDownSmartFast_Checkpoint",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCShutdown_StopRequest(n) /\ (IF CurrentFairTask = <<"Shutdown_StopRequest",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryShuttingDownSmartFast_Fallback(n) /\ (IF CurrentFairTask = <<"TryShuttingDownSmartFast_Fallback",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCShutdown_ClientsFinished(n) /\ (IF CurrentFairTask = <<"Shutdown_ClientsFinished",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCShutdown_ArchiveComplete(n) /\ (IF CurrentFairTask = <<"Shutdown_ArchiveComplete",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRunPostgresAndWait_Exit(n) /\ (IF CurrentFairTask = <<"RunPostgresAndWait_Exit",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPostgresLifecycle_Return(n) /\ (IF CurrentFairTask = <<"PostgresLifecycle_Return",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCEngageStopProcedure_GraceExpired(n) /\ (IF CurrentFairTask = <<"EngageStopProcedure_GraceExpired",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCManagerStart_Return(n) /\ (IF CurrentFairTask = <<"ManagerStart_Return",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRelease_UpgradeSkip(n) /\ (IF CurrentFairTask = <<"Release_UpgradeSkip",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRelease_Get(n) /\ (IF CurrentFairTask = <<"Release_Get",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRelease_Check(n) /\ (IF CurrentFairTask = <<"Release_Check",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRelease_Update(n) /\ (IF CurrentFairTask = <<"Release_Update",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRelease_Error(n) /\ (IF CurrentFairTask = <<"Release_Error",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCRun_ContainerExit(n) /\ (IF CurrentFairTask = <<"Run_ContainerExit",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCIsHealthy_GetCluster(n) /\ (IF CurrentFairTask = <<"IsHealthy_GetCluster",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCIsHealthy_Ping(n) /\ (IF CurrentFairTask = <<"IsHealthy_Ping",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCIsHealthy_IsolationProbe(n) /\ (IF CurrentFairTask = <<"IsHealthy_IsolationProbe",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryShuttingDownFastImmediate_Immediate(n) /\ (IF CurrentFairTask = <<"TryShuttingDownFastImmediate_Immediate",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCTryShuttingDownSmartFast_StopTimeout(n) /\ (IF CurrentFairTask = <<"TryShuttingDownSmartFast_StopTimeout",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server, w \in WAL : (MCGenerateWAL(n,w) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCFlushWAL(n) /\ (IF CurrentFairTask = <<"FlushWAL",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCSendWAL(n) /\ (IF CurrentFairTask = <<"SendWAL",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReceiveWAL(n) /\ (IF CurrentFairTask = <<"ReceiveWAL",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReplayWAL(n) /\ (IF CurrentFairTask = <<"ReplayWAL",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server, witnesses \in SUBSET Server : (MCAcknowledgeCommit(n,witnesses) /\ (IF CurrentFairTask = <<"AcknowledgeCommit",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCArchiveWAL(n) /\ (IF CurrentFairTask = <<"ArchiveWAL",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server, a \in s.archive : (MCRestoreArchiveWAL(n,a) /\ (IF CurrentFairTask = <<"RestoreArchiveWAL",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCWalReceiverDown(n) /\ (IF CurrentFairTask = <<"WalReceiverDown",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server, p \in Server : (MCWalReceiverConnect(n,p) /\ (IF CurrentFairTask = <<"WalReceiverConnect",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReadinessProbe(n) /\ (IF CurrentFairTask = <<"ReadinessProbe",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReconcileMetadata(n) /\ (IF CurrentFairTask = <<"ReconcileMetadata",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCRequestPlannedSwitchover /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCManagerCancellation(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCTerminationSignal(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCOnlineUpgrade(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCOnlineUpgrade_Exec(n) /\ (IF CurrentFairTask = <<"OnlineUpgrade_Exec",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPodCrash(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCPodRestart(n) /\ (IF CurrentFairTask = <<"PodRestart",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPermitPodRestart(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCPodEviction(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCAPIFailure(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCAPIFailure_Recover(n) /\ (IF CurrentFairTask = <<"APIFailure_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCHTTPFailure(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCHTTPFailure_Recover(n) /\ (IF CurrentFairTask = <<"HTTPFailure_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCProbeFailure(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCProbeFailure_Recover(n) /\ (IF CurrentFairTask = <<"ProbeFailure_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCReplicationDisconnect(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCReplicationDisconnect_Recover(n) /\ (IF CurrentFairTask = <<"ReplicationDisconnect_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCPeerFailure(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCPeerFailure_Recover(n) /\ (IF CurrentFairTask = <<"PeerFailure_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCStorageStall(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCStorageStall_Recover(n) /\ (IF CurrentFairTask = <<"StorageStall_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCSQLUnavailable(n) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E n \in Server : (MCSQLUnavailable_Recover(n) /\ (IF CurrentFairTask = <<"SQLUnavailable_Recover",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCOperatorCrash /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ ((MCOperatorRecover /\ (IF CurrentFairTask = <<"OperatorRecover",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCOperatorAPIFailure /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ ((MCOperatorAPIRecover /\ (IF CurrentFairTask = <<"OperatorAPIRecover",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCUpdateLeaseConfiguration /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E members \in SUBSET Server, number \in 1..(Cardinality(Server)-1) : (MCUpdateSynchronousConfiguration(members,number) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ (\E survivors \in SUBSET Server : (MCRecoverEnvironment(survivors) /\ UNCHANGED <<fairIndex,fairRound>>))
    \/ ((MCClockTick /\ (IF CurrentFairTask = <<"ClockTick",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCDeliverOperatorCluster /\ (IF CurrentFairTask = <<"DeliverOperatorCluster",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCReconcile_APIError /\ (IF CurrentFairTask = <<"Reconcile_APIError",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ ((MCMarkOldPrimaryAsUnhealthy_Error /\ (IF CurrentFairTask = <<"MarkOldPrimaryAsUnhealthy_Error",None>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCInstanceReconcile_APIError(n) /\ (IF CurrentFairTask = <<"InstanceReconcile_APIError",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))
    \/ (\E n \in Server : (MCGetSynchronousReplicationMetadata_Error(n) /\ (IF CurrentFairTask = <<"GetSynchronousReplicationMetadata_Error",n>> THEN AdvanceFairMonitor ELSE UNCHANGED <<fairIndex,fairRound>>)))

FairDiscard ==
    /\ ~ENABLED FairAction(CurrentFairTask)
    /\ AdvanceFairMonitor
    /\ UNCHANGED <<s,faultCounters>>
MCRecoveryNext == FairSourceStep \/ FairDiscard
\* Infinitely many completed rounds is the weak-fairness assumption. It does
\* not require RecoverEnvironment, or restarting an unavailable old primary.
MCRecoverySpec == MCRecoveryInit /\ [][MCRecoveryNext]_mcvars /\ []<>fairRound /\ []<>~fairRound
FairMonitorTypeOK == fairIndex\in 1..Len(FairTasks) /\ fairRound\in BOOLEAN
\* EXTENDS base exposes all five brief properties to the actual hunt cfgs.
=============================================================================

