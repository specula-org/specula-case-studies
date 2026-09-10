------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

(***************************************************************************
 CloudNativePG primary failover; Category A (distributed/message passing).
 Source revision: d5f3426e161076322086b58c886cf8e7435f0e1b.
 Source abbreviations used in annotations:
   IC = internal/management/controller/instance_controller.go
   IS = internal/management/controller/instance_startup.go
   IQ = internal/management/controller/instance_sync.go
   LR = internal/cmd/manager/instance/run/lease/runnable.go
   LC = internal/cmd/manager/instance/run/lifecycle/lifecycle.go
   LP = internal/cmd/manager/instance/run/lifecycle/run.go
   CMD = internal/cmd/manager/instance/run/cmd.go
   OC = internal/controller/cluster_controller.go
   OS = internal/controller/cluster_status.go
   OR = internal/controller/replicas.go
   OQ = internal/controller/replicas_quorum.go
   OU = internal/controller/cluster_upgrade.go
   PS = pkg/postgres/status.go
   PG = pkg/management/postgres/instance.go
   PR = pkg/management/postgres/promote.go
   RC = pkg/management/postgres/webserver/client/remote/instance.go
   LV = pkg/management/postgres/webserver/probes/liveness.go
   SY = pkg/postgres/replication/explicit.go
   SP = pkg/resources/status/patch.go
   LE = k8s.io/client-go@v0.37.0/tools/leaderelection/leaderelection.go
   LL = k8s.io/client-go@v0.37.0/tools/leaderelection/resourcelock/leaselock.go
   CM = sigs.k8s.io/controller-runtime@v0.25.0/pkg/manager/internal.go
 Dependencies are pinned by go.mod:46,50. Environmental PostgreSQL transitions
 cite their call sites and docs/src/failover.md (FD); they are abstractions of
 SQL/WAL/process behavior, not extra operator checks.

 One record variable supplies explicit framing: EXCEPT leaves every unlisted
 field unchanged. Each Cluster/Lease/Quorum call is a separate action. A GET
 response captures the object; its subsequent decision/CAS may run later.
 Delayed cache delivery retains an earlier real object, never invented values.
 No cross-object atomicity, duplicate Pod incarnations, manual promotions,
 external synchronous names, preferred durability, or synchronous_commit
 overrides. All configurations use ANY and durable required acknowledgments.

 Resource versions use fresh recyclable equality tokens (no ABA while a reader
 retains a token); the pool exceeds the number of simultaneous readers. Timeline
 IDs abstract to <<promoting Pod, fork prefix>>; repeated empty/equal forks have
 the same observable history. Time uses saturating local elapsed clocks: this
 permits finite recurring recovery behavior without stopping time at a bound.
***************************************************************************)

CONSTANTS Server, MaxWAL, InitialSyncNumber, LeaseProfiles, ManagerGrace,
          SmartDelay, FastDelay, TimerCap, FailoverQuorumEnabled, ArchiveEnabled
None == "none"
Pending == "pending"
WAL == 1..MaxWAL
VARIABLE s
vars == <<s>>

\* Scenarios 1-5; FD:20-103,276-405: ordered identity-bearing WAL prefixes.
SeqSet(q) == {q[k] : k \in 1..Len(q)}
Prefix(a,b) == Len(a) <= Len(b) /\ a = SubSeq(b,1,Len(a))
Max(a,b) == IF a >= b THEN a ELSE b
Min(a,b) == IF a <= b THEN a ELSE b
Inc(a) == Min(TimerCap,a+1)
Orders == {q \in [1..Cardinality(Server) -> Server] : SeqSet(q)=Server}
Rank(n) == CHOOSE k \in 1..Len(s.order) : s.order[k]=n
ValidLeaseConfig(c) == /\ c.duration > c.renew /\ 5*c.renew > 6*c.retry
                            /\ c.retry > 0 /\ c.released > 0
ASSUME /\ Cardinality(Server) >= 3 /\ MaxWAL \in Nat
       /\ InitialSyncNumber \in 1..(Cardinality(Server)-1)
       /\ DOMAIN LeaseProfiles = {1,2}
       /\ \A g \in {1,2} : ValidLeaseConfig(LeaseProfiles[g])
       /\ TimerCap >= ManagerGrace + SmartDelay + FastDelay
       /\ \A g \in {1,2} : TimerCap > LeaseProfiles[g].duration + 3*LeaseProfiles[g].retry

\* SY:45-79; IQ:64-77. The primary name does not contribute a standby ack.
SyncConfig(c,n) == [members |-> c.syncMembers \ {n}, number |-> c.syncNumber,
                    generation |-> c.generation]
EmptyQuorum == [exists |-> TRUE, primary |-> None, members |-> {}, number |-> 0,
                generation |-> 0, timeline |-> <<None,<<>>>>, rv |-> 0]
EmptyLease == [holder |-> None, duration |-> 1, renew |-> 0, rv |-> 0,
               cleanFrom |-> None, cleanAcks |-> {}]
EmptyHTTP == [ok |-> FALSE, primary |-> FALSE, receiver |-> FALSE,
              received |-> <<>>, replayed |-> <<>>]
\* Scenarios 1-2: pgState/diskRole are distinct from lease and routing labels.
Running(n) == ~s.life[n].containerExited /\ s.data[n].pgState # "down"
Writer(n) == Running(n) /\ s.data[n].diskRole="primary"
             /\ ~s.data[n].stopWrites /\ s.env.sql[n] /\ s.env.io[n]
Manager(n) == ~s.life[n].containerExited /\ ~s.life[n].managerReturned
Reconciler(n) == Manager(n) /\ ~s.life[n].cancelled
DBReady(n) == Running(n) /\ s.env.sql[n] /\ s.env.io[n]
Receiver(n) == s.data[n].receiver # None
Acked == UNION {SeqSet(a.prefix) : a \in s.acks}
AckRecords(n) == {a \in s.acks : a.primary=n /\ a.timeline=s.data[n].timeline}
\* OQ:76-117. No Primary/generation comparison is added to the implementation.
QuorumAllows(q,ready) == q.exists /\ q.number>0 /\ q.members#{}
                         /\ Cardinality(q.members \cap ready)+q.number>Cardinality(q.members)
ObservedReady == {n \in s.op.active : n \in s.op.ready /\ s.op.http[n].ok}
ObservedPrimaries == {n \in s.op.active : s.op.http[n].ok /\ s.op.http[n].primary}
\* PS:282-325. Preserve HTTP errors, role, received/replayed LSN, then name.
Better(a,b) ==
    IF s.op.http[a].ok # s.op.http[b].ok THEN s.op.http[a].ok
    ELSE IF s.op.http[a].primary # s.op.http[b].primary THEN s.op.http[a].primary
    ELSE IF s.op.http[a].primary THEN Rank(a)<Rank(b)
    ELSE IF Len(s.op.http[a].received)#Len(s.op.http[b].received)
         THEN Len(s.op.http[a].received)>Len(s.op.http[b].received)
    ELSE IF Len(s.op.http[a].replayed)#Len(s.op.http[b].replayed)
         THEN Len(s.op.http[a].replayed)>Len(s.op.http[b].replayed)
    ELSE Rank(a)<Rank(b)
Best(ns) == CHOOSE n \in ns : \A m \in ns\{n} : Better(n,m)
AllObservedReceiversDown == \A n \in s.op.active\{s.op.cluster.current} : ~s.op.http[n].receiver
ManageQuorum(n) == FailoverQuorumEnabled /\ s.inst[n].snapshot.current=n
                   /\ s.inst[n].snapshot.target=n

\* LL:42-53,73-95; SP:52-75; IQ:39-49,80-95. Equality-only RV abstraction.
Versions == 0..(8*Cardinality(Server)+12)
Fresh(used) == CHOOSE v \in Versions\used : \A w \in Versions\used : v<=w
ClusterRV == Fresh({s.cluster.rv,s.op.cluster.rv,s.op.phaseRead.rv,s.op.cache.rv}
                    \cup {s.cache[n].rv:n\in Server} \cup {s.inst[n].snapshot.rv:n\in Server})
LeaseRV == Fresh({s.lease.rv,s.lease.renew}
                  \cup {s.elect[n].read.rv:n\in Server}
                  \cup {s.elect[n].observation.rv:n\in Server}
                  \cup {s.elect[n].observation.renew:n\in Server}
                  \cup {s.elect[n].takeoverObservation.rv:n\in Server}
                  \cup {s.elect[n].takeoverObservation.renew:n\in Server}
                  \cup {s.life[n].releaseRead.rv:n\in Server})
QuorumRV == Fresh({s.quorum.rv,s.op.qcache.rv,s.op.quorum.rv}
                   \cup {s.inst[n].qread.rv:n\in Server})

NewElector == [pc |-> "idle", captured |-> 0, firstAcquired |-> FALSE,
               read |-> EmptyLease, observation |-> EmptyLease, observed |-> FALSE,
               takeoverObservation |-> EmptyLease, takeoverObserved |-> FALSE, takeoverAge |-> 0,
               observeAge |-> 0, pollAge |-> 0, renewAge |-> 0,
               mode |-> "acquire", cleanFrom |-> None, cleanAcks |-> {}]
NewLife == [cause |-> "none", phase |-> "none", cancelled |-> FALSE,
            managerReturned |-> FALSE, postgresExited |-> FALSE,
            archiveComplete |-> FALSE, lifecycleDone |-> FALSE,
            containerExited |-> FALSE, upgrade |-> FALSE,
            graceAge |-> 0, stopAge |-> 0, graceExpired |-> FALSE,
            releasePC |-> "idle", releaseRead |-> EmptyLease,
            isolationPC |-> "idle", isolationAPI |-> TRUE, isolationPeers |-> TRUE,
            immediate |-> FALSE]
NewInst(c) == [pc |-> "idle", snapshot |-> c, initialized |-> TRUE,
               reloadNeeded |-> FALSE, qread |-> EmptyQuorum,
               metadata |-> EmptyQuorum, acquireAge |-> 0]
NewOperator(c) == [pc |-> "idle", cluster |-> c, cache |-> c, active |-> {}, ready |-> {},
                   collected |-> {}, http |-> [n \in Server |-> EmptyHTTP],
                   candidate |-> None, purpose |-> "none", phaseRead |-> c,
                   qcache |-> EmptyQuorum, quorum |-> EmptyQuorum,
                   requested |-> FALSE]

\* Established synchronized cluster, before the normalized modeled WAL prefix.
\* FD:20-31,56-64; IQ:54-95; LR:147-160,447-479. Initial primary is Pod -1.
Init == \E order \in Orders :
    LET p == order[1]
        c == [current |-> p, target |-> p, phase |-> "healthy", readyCount |-> Cardinality(Server),
              generation |-> 1, leaseGeneration |-> 1, syncMembers |-> Server,
              syncNumber |-> InitialSyncNumber, rv |-> 0]
        l == [EmptyLease EXCEPT !.holder=p, !.duration=LeaseProfiles[1].duration]
        q == [EmptyQuorum EXCEPT !.primary=p, !.members=Server\{p},
               !.number=InitialSyncNumber, !.generation=1, !.timeline= <<p,<<>>>>]
    IN s = [order |-> order, cluster |-> c, lease |-> l, quorum |-> q,
        pods |-> [n \in Server |-> [active |-> TRUE, ready |-> TRUE,
                                   label |-> IF n=p THEN "primary" ELSE "replica"]],
        cache |-> [n \in Server |-> c],
        op |-> [NewOperator(c) EXCEPT !.qcache=q],
        inst |-> [n \in Server |-> NewInst(c)],
        elect |-> [n \in Server |-> IF n=p THEN
                    [NewElector EXCEPT !.pc="runIdle", !.captured=1,
                      !.firstAcquired=TRUE, !.mode="renew", !.read=l,
                      !.observation=l, !.observed=TRUE] ELSE NewElector],
        life |-> [n \in Server |-> NewLife],
        data |-> [n \in Server |-> [diskRole |-> IF n=p THEN "primary" ELSE "replica",
                 pgState |-> "running", stopWrites |-> FALSE,
                 generated |-> <<>>, received |-> <<>>, durable |-> <<>>, replayed |-> <<>>,
                 receiver |-> IF n=p THEN None ELSE p, timeline |-> <<p,<<>>>>,
                 fileConfig |-> SyncConfig(c,n), runtimeConfig |-> SyncConfig(c,n),
                 promotePC |-> "none"]],
        sent |-> [n \in Server |-> <<>>],
        archive |-> {}, acks |-> {}, history |-> {}, usedWAL |-> {},
        env |-> [api |-> [n \in Server |-> TRUE], http |-> [n \in Server |-> TRUE],
                 probe |-> [n \in Server |-> TRUE], sql |-> [n \in Server |-> TRUE],
                 io |-> [n \in Server |-> TRUE], wal |-> [n \in Server |-> TRUE],
                 peer |-> [n \in Server |-> TRUE], operatorUp |-> TRUE,
                 operatorAPI |-> TRUE, stable |-> FALSE, survivors |-> {},
                 restartAllowed |-> Server]]

\* Admission-valid, deliberately different profiles (Sc.1; FD:153-180).
DefaultLeaseProfiles == [g \in {1,2} |-> IF g=1
    THEN [duration |-> 8, renew |-> 6, retry |-> 2, released |-> 1]
    ELSE [duration |-> 3, renew |-> 2, retry |-> 1, released |-> 1]]

\* Actions are appended below by build_actions.py (Phase 1).

\* Scenarios 1,3,4,5; OC:300-329,382-390.
\* GET response; retain this reconcile snapshot.
Reconcile_GetCluster ==
    \* OC:300-329,382-390 (guard/branch).
    /\ s.env.operatorUp
    \* OC:300-329,382-390 (guard/branch).
    /\ s.op.pc="idle"
    \* OC:300-329,382-390 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.cluster = s.op.cache,
         !.op.pc = "resources"]

\* Scenarios 5; OC:383-390; OS:298-323; pkg/reconciler/persistentvolumeclaim/status.go:233-235.
GetManagedResources ==
    \* OC:383-390; OS:298-323; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (guard/branch).
    /\ s.env.operatorUp
    \* OC:383-390; OS:298-323; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (guard/branch).
    /\ s.op.pc="resources"
    \* OC:383-390; OS:298-323; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.active = {n \in Server:s.pods[n].active},
         !.op.ready = {n \in Server:s.pods[n].active /\ s.pods[n].ready},
         !.op.pc = "resourceStatus"]

\* Scenarios 5; OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235.
\* Ready count is refreshed by EnrichStatus before testing target activity; a no-op does not refresh the caller.
UpdateResourceStatus ==
    \* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (guard/branch).
    /\ s.env.operatorUp
    \* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (guard/branch).
    /\ s.env.operatorAPI
    \* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (guard/branch).
    /\ s.op.pc="resourceStatus"
    \* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (guard/branch).
    /\ LET c == [s.op.cluster EXCEPT !.readyCount=Cardinality(s.op.ready), !.target=IF @#s.op.cluster.current /\ (s.op.ready={} \/ @ \notin s.op.active) THEN s.op.cluster.current ELSE @] IN (c=s.op.cluster \/ s.op.cluster.rv=s.cluster.rv)
    \* OS:257-263,298-323,401-404; pkg/reconciler/persistentvolumeclaim/status.go:233-235 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster = LET c == [s.op.cluster EXCEPT !.readyCount=Cardinality(s.op.ready), !.target=IF @#s.op.cluster.current /\ (s.op.ready={} \/ @ \notin s.op.active) THEN s.op.cluster.current ELSE @] IN IF c=s.op.cluster THEN s.cluster ELSE [c EXCEPT !.rv=ClusterRV],
         !.op.cluster = LET c == [s.op.cluster EXCEPT !.readyCount=Cardinality(s.op.ready), !.target=IF @#s.op.cluster.current /\ (s.op.ready={} \/ @ \notin s.op.active) THEN s.op.cluster.current ELSE @] IN IF c=s.op.cluster THEN c ELSE [c EXCEPT !.rv=ClusterRV],
         !.op.pc = "transitionGuard"]

\* Scenarios 5; OC:389-398; OS:401-404.
\* A conflicting status update retries the reconcile; other legitimate status fields may have changed.
UpdateResourceStatus_Conflict ==
    \* OC:389-398; OS:401-404 (guard/branch).
    /\ s.env.operatorUp
    \* OC:389-398; OS:401-404 (guard/branch).
    /\ s.op.pc="resourceStatus"
    \* OC:389-398; OS:401-404 (guard/branch).
    /\ s.op.cluster.rv#s.cluster.rv
    \* OC:389-398; OS:401-404 (guard/branch).
    /\ s.op.cluster.readyCount#Cardinality(s.op.ready) \/ (s.op.cluster.target#s.op.cluster.current /\ (s.op.ready={} \/ s.op.cluster.target\notin s.op.active))
    \* OC:389-398; OS:401-404 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = "idle"]

\* Scenarios 5; OC:408-428,454-455.
Reconcile_TransitionGuard ==
    \* OC:408-428,454-455 (guard/branch).
    /\ s.env.operatorUp
    \* OC:408-428,454-455 (guard/branch).
    /\ s.op.pc="transitionGuard"
    \* OC:408-428,454-455 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = IF s.op.cluster.current#s.op.cluster.target THEN "guardLabel" ELSE "collect",
         !.op.collected = {},
         !.op.http = [n \in Server |-> EmptyHTTP]]

\* Scenarios 1,2,5; OC:413-427; OR:144-158,202-229.
\* Routing label only. Existing SQL and replication sessions are retained.
MarkOldPrimaryAsUnhealthy ==
    \* OC:413-427; OR:144-158,202-229 (guard/branch).
    /\ s.env.operatorUp
    \* OC:413-427; OR:144-158,202-229 (guard/branch).
    /\ s.env.operatorAPI
    \* OC:413-427; OR:144-158,202-229 (guard/branch).
    /\ s.op.pc \in {"guardLabel","pendingLabel"}
    \* OC:413-427; OR:144-158,202-229 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.pods[s.op.cluster.current].label = "unhealthy",
         !.op.pc = IF s.op.pc="guardLabel" THEN "idle" ELSE "receivers"]

\* Scenarios 3,4,5; RC:134-137,143-178,181-201; PS:282-325.
\* One HTTP observation at a time in Pod-name order; errors have zero receiver/LSN fields.
GetReplicaStatusFromPodViaHTTP(n) ==
    \* RC:134-137,143-178,181-201; PS:282-325 (guard/branch).
    /\ s.env.operatorUp
    \* RC:134-137,143-178,181-201; PS:282-325 (guard/branch).
    /\ s.op.pc="collect"
    \* RC:134-137,143-178,181-201; PS:282-325 (guard/branch).
    /\ n \in s.op.active\s.op.collected
    \* RC:134-137,143-178,181-201; PS:282-325 (guard/branch).
    /\ \A m \in s.op.active\s.op.collected : Rank(n)<=Rank(m)
    \* RC:134-137,143-178,181-201; PS:282-325 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.http[n] = IF s.env.http[n] /\ Manager(n) /\ DBReady(n) THEN [ok |-> TRUE, primary |-> s.data[n].diskRole="primary", receiver |-> Receiver(n), received |-> s.data[n].received, replayed |-> s.data[n].replayed] ELSE EmptyHTTP,
         !.op.collected = s.op.collected \cup {n}]

\* Scenarios 1,3,4,5; OC:476-485,636-685; PS:282-325.
EvaluatePodReadinessGuards ==
    \* OC:476-485,636-685; PS:282-325 (guard/branch).
    /\ s.env.operatorUp
    \* OC:476-485,636-685; PS:282-325 (guard/branch).
    /\ s.op.pc="collect"
    \* OC:476-485,636-685; PS:282-325 (guard/branch).
    /\ s.op.collected=s.op.active
    \* OC:476-485,636-685; PS:282-325 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = IF s.op.active={} THEN "idle" ELSE LET b==Best(s.op.active) IN IF Cardinality(ObservedPrimaries)>1 \/ (s.op.http[b].ok /\ b\notin s.op.ready) \/ (s.op.cluster.current=s.op.cluster.target /\ s.op.cluster.current\in s.op.ready /\ ~s.op.http[s.op.cluster.current].ok) THEN "idle" ELSE "choose"]

\* Scenarios 1,4,5; OR:99-139; OC:545-547.
\* Failover-delay policy is an elapsed precondition of this step; no fixed-latency claim is checked.
ReconcileTargetPrimaryForNonReplicaCluster ==
    \* OR:99-139; OC:545-547 (guard/branch).
    /\ s.env.operatorUp
    \* OR:99-139; OC:545-547 (guard/branch).
    /\ s.op.pc="choose"
    \* OR:99-139; OC:545-547 (guard/branch).
    /\ ~s.op.requested \/ s.op.cluster.current\notin ObservedPrimaries
    \* OR:99-139; OC:545-547 (guard/branch).
    /\ s.op.active#{}
    \* OR:99-139; OC:545-547 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.candidate = Best(s.op.active),
         !.op.purpose = "failover",
         !.op.pc = LET b==Best(s.op.active) IN IF s.op.cluster.target=b \/ ~s.op.http[b].ok THEN "idle" ELSE IF s.op.cluster.current=s.op.cluster.target /\ FailoverQuorumEnabled THEN "quorumGet" ELSE "failoverPhaseGet"]

\* Scenarios 4,5; OQ:48-60; OQ:76-117.
\* Operator informer read; instance-manager quorum reads below are direct API reads.
EvaluateQuorumCheck_Get ==
    \* OQ:48-60; OQ:76-117 (guard/branch).
    /\ s.env.operatorUp
    \* OQ:48-60; OQ:76-117 (guard/branch).
    /\ s.op.pc="quorumGet"
    \* OQ:48-60; OQ:76-117 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.quorum = s.op.qcache,
         !.op.pc = "quorumDecision"]

\* Scenarios 4; OQ:48-60; OC:120-135 (cached client).
\* Deliver latest real object; old observation remains valid until delivery.
DeliverFailoverQuorum ==
    \* OQ:48-60; OC:120-135 (cached client) (guard/branch).
    /\ s.env.operatorUp
    \* OQ:48-60; OC:120-135 (cached client) (guard/branch).
    /\ s.env.operatorAPI
    \* OQ:48-60; OC:120-135 (cached client) (guard/branch).
    /\ s.op.qcache#s.quorum
    \* OQ:48-60; OC:120-135 (cached client) (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.qcache = s.quorum]

\* Scenarios 4,5; OQ:76-117; OR:114-139.
EvaluateQuorumCheckWithStatus ==
    \* OQ:76-117; OR:114-139 (guard/branch).
    /\ s.env.operatorUp
    \* OQ:76-117; OR:114-139 (guard/branch).
    /\ s.op.pc="quorumDecision"
    \* OQ:76-117; OR:114-139 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = IF QuorumAllows(s.op.quorum,ObservedReady) THEN "failoverPhaseGet" ELSE "idle"]

\* Scenarios 1,2,3,5; OU:229-264; OR:298-329.
\* Supported rolling/drain selection; no manual promotion override. Selected receiver must be active.
UpdatePrimaryPod_Select ==
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ s.env.operatorUp
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ s.op.pc="choose"
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ s.op.requested
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ s.op.cluster.current\in ObservedPrimaries
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ s.op.cluster.current=s.op.cluster.target
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ s.op.active\{s.op.cluster.current}#{}
    \* OU:229-264; OR:298-329 (guard/branch).
    /\ LET n==Best(s.op.active\{s.op.cluster.current}) IN n\in ObservedReady /\ s.op.http[n].receiver
    \* OU:229-264; OR:298-329 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.candidate = Best(s.op.active\{s.op.cluster.current}),
         !.op.purpose = "planned",
         !.op.pc = "plannedPhaseGet",
         !.op.requested = FALSE]

\* Scenarios 3,5; OU:242-255; OR:299-312.
UpdatePrimaryPod_Wait ==
    \* OU:242-255; OR:299-312 (guard/branch).
    /\ s.env.operatorUp
    \* OU:242-255; OR:299-312 (guard/branch).
    /\ s.op.pc="choose"
    \* OU:242-255; OR:299-312 (guard/branch).
    /\ s.op.requested
    \* OU:242-255; OR:299-312 (guard/branch).
    /\ s.op.cluster.current\in ObservedPrimaries
    \* OU:242-255; OR:299-312 (guard/branch).
    /\ s.op.active\{s.op.cluster.current}={} \/ (LET n==Best(s.op.active\{s.op.cluster.current}) IN n\notin ObservedReady \/ ~s.op.http[n].receiver)
    \* OU:242-255; OR:299-312 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = "idle"]

\* Scenarios 1,2,3,4,5; OS:765-776; SP:52-61.
RegisterPhase_Get ==
    \* OS:765-776; SP:52-61 (guard/branch).
    /\ s.env.operatorUp
    \* OS:765-776; SP:52-61 (guard/branch).
    /\ s.op.pc \in {"failoverPhaseGet","plannedPhaseGet","selectedPhaseGet"}
    \* OS:765-776; SP:52-61 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.phaseRead = s.op.cache,
         !.op.pc = IF s.op.pc="failoverPhaseGet" THEN "failoverPhasePatch" ELSE IF s.op.pc="plannedPhaseGet" THEN "plannedPhasePatch" ELSE "selectedPhasePatch"]

\* Scenarios 1,2,3,4,5; SP:63-75; OR:135-139,176-196; OU:170-174.
\* Conditional patch refreshes caller status on change; no-op preserves caller snapshot.
RegisterPhase_Patch ==
    \* SP:63-75; OR:135-139,176-196; OU:170-174 (guard/branch).
    /\ s.env.operatorUp
    \* SP:63-75; OR:135-139,176-196; OU:170-174 (guard/branch).
    /\ s.env.operatorAPI
    \* SP:63-75; OR:135-139,176-196; OU:170-174 (guard/branch).
    /\ s.op.pc \in {"failoverPhasePatch","plannedPhasePatch","selectedPhasePatch"}
    \* SP:63-75; OR:135-139,176-196; OU:170-174 (guard/branch).
    /\ s.op.phaseRead.phase=(IF s.op.purpose="planned" THEN "switchover" ELSE "failover") \/ s.op.phaseRead.rv=s.cluster.rv
    \* SP:63-75; OR:135-139,176-196; OU:170-174 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster = IF s.op.phaseRead.phase=(IF s.op.purpose="planned" THEN "switchover" ELSE "failover") THEN s.cluster ELSE [s.cluster EXCEPT !.phase=IF s.op.purpose="planned" THEN "switchover" ELSE "failover", !.rv=ClusterRV],
         !.op.cluster = IF s.op.phaseRead.phase=(IF s.op.purpose="planned" THEN "switchover" ELSE "failover") THEN s.op.cluster ELSE [s.cluster EXCEPT !.phase=IF s.op.purpose="planned" THEN "switchover" ELSE "failover", !.rv=ClusterRV],
         !.op.pc = IF s.op.pc="failoverPhasePatch" THEN "pendingPatch" ELSE "targetPatch"]

\* Scenarios 5; SP:52-75.
RegisterPhase_Conflict ==
    \* SP:52-75 (guard/branch).
    /\ s.env.operatorUp
    \* SP:52-75 (guard/branch).
    /\ s.op.pc \in {"failoverPhasePatch","plannedPhasePatch","selectedPhasePatch"}
    \* SP:52-75 (guard/branch).
    /\ s.op.phaseRead.rv#s.cluster.rv
    \* SP:52-75 (guard/branch).
    /\ s.op.phaseRead.phase#(IF s.op.purpose="planned" THEN "switchover" ELSE "failover")
    \* SP:52-75 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = IF s.op.pc="failoverPhasePatch" THEN "failoverPhaseGet" ELSE IF s.op.pc="plannedPhasePatch" THEN "plannedPhaseGet" ELSE "selectedPhaseGet"]

\* Scenarios 1,4,5; OR:129-159; OS:752-760.
\* Merge patch of target only; no added optimistic precondition.
SetPrimaryInstance_Pending ==
    \* OR:129-159; OS:752-760 (guard/branch).
    /\ s.env.operatorUp
    \* OR:129-159; OS:752-760 (guard/branch).
    /\ s.env.operatorAPI
    \* OR:129-159; OS:752-760 (guard/branch).
    /\ s.op.pc="pendingPatch"
    \* OR:129-159; OS:752-760 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster.target = Pending,
         !.cluster.rv = ClusterRV,
         !.op.cluster.target = Pending,
         !.op.cluster.rv = ClusterRV,
         !.op.pc = "pendingLabel"]

\* Scenarios 1,4,5; OR:161-196; PS:331-341.
\* Uses the already-collected sequential HTTP snapshot, not new reads.
AreWalReceiversDown ==
    \* OR:161-196; PS:331-341 (guard/branch).
    /\ s.env.operatorUp
    \* OR:161-196; PS:331-341 (guard/branch).
    /\ s.op.pc="receivers"
    \* OR:161-196; PS:331-341 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = IF AllObservedReceiversDown THEN "selectedPhaseGet" ELSE "idle"]

\* Scenarios 1,2,3,4,5; OR:196,329; OS:752-760; OU:170-174.
SetPrimaryInstance_Target ==
    \* OR:196,329; OS:752-760; OU:170-174 (guard/branch).
    /\ s.env.operatorUp
    \* OR:196,329; OS:752-760; OU:170-174 (guard/branch).
    /\ s.env.operatorAPI
    \* OR:196,329; OS:752-760; OU:170-174 (guard/branch).
    /\ s.op.pc="targetPatch"
    \* OR:196,329; OS:752-760; OU:170-174 (guard/branch).
    /\ s.op.candidate\in Server
    \* OR:196,329; OS:752-760; OU:170-174 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster.target = s.op.candidate,
         !.cluster.rv = ClusterRV,
         !.op.cluster.target = s.op.candidate,
         !.op.cluster.rv = ClusterRV,
         !.op.pc = "idle"]

\* Scenarios 1,3,4,5; CMD:185-215; IC:136-164.
DeliverCluster(n) ==
    \* CMD:185-215; IC:136-164 (guard/branch).
    /\ Reconciler(n)
    \* CMD:185-215; IC:136-164 (guard/branch).
    /\ s.env.api[n]
    \* CMD:185-215; IC:136-164 (guard/branch).
    /\ s.cache[n]#s.cluster
    \* CMD:185-215; IC:136-164 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cache[n] = s.cluster]

\* Scenarios 1,3,4,5; IC:136-164,206-217.
InstanceReconcile_GetCluster(n) ==
    \* IC:136-164,206-217 (guard/branch).
    /\ Reconciler(n)
    \* IC:136-164,206-217 (guard/branch).
    /\ s.inst[n].pc="idle"
    \* IC:136-164,206-217 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].snapshot = s.cache[n],
         !.inst[n].pc = "files"]

\* Scenarios 1,3,4; IC:206-217,417-453; pkg/management/postgres/configuration.go:69-99; SY:45-79.
RefreshConfigurationFiles(n) ==
    \* IC:206-217,417-453; pkg/management/postgres/configuration.go:69-99; SY:45-79 (guard/branch).
    /\ Reconciler(n)
    \* IC:206-217,417-453; pkg/management/postgres/configuration.go:69-99; SY:45-79 (guard/branch).
    /\ s.inst[n].pc="files"
    \* IC:206-217,417-453; pkg/management/postgres/configuration.go:69-99; SY:45-79 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].fileConfig = SyncConfig(s.inst[n].snapshot,n),
         !.inst[n].reloadNeeded = s.data[n].fileConfig#SyncConfig(s.inst[n].snapshot,n),
         !.inst[n].pc = IF s.inst[n].initialized THEN "ready" ELSE "initialize"]

\* Scenarios 1; IS:41-49,72-85; IC:212-227.
\* Startup permission is not coupled to any lease read or acquisition.
VerifyPgDataCoherenceForPrimary(n) ==
    \* IS:41-49,72-85; IC:212-227 (guard/branch).
    /\ Reconciler(n)
    \* IS:41-49,72-85; IC:212-227 (guard/branch).
    /\ s.inst[n].pc="initialize"
    \* IS:41-49,72-85; IC:212-227 (guard/branch).
    /\ s.data[n].diskRole="replica" \/ s.inst[n].snapshot.target=n
    \* IS:41-49,72-85; IC:212-227 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].initialized = TRUE,
         !.inst[n].pc = "ready"]

\* Scenarios 1,5; IS:87-110.
VerifyPgDataCoherenceForPrimary_Wait(n) ==
    \* IS:87-110 (guard/branch).
    /\ Reconciler(n)
    \* IS:87-110 (guard/branch).
    /\ s.inst[n].pc="initialize"
    \* IS:87-110 (guard/branch).
    /\ s.data[n].diskRole="primary"
    \* IS:87-110 (guard/branch).
    /\ s.inst[n].snapshot.target#n
    \* IS:87-110 (guard/branch).
    /\ s.inst[n].snapshot.current#s.inst[n].snapshot.target \/ ~Writer(s.inst[n].snapshot.current)
    \* IS:87-110 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "idle"]

\* Scenarios 1; IS:108-146.
VerifyPgDataCoherenceForPrimary_Archive(n) ==
    \* IS:108-146 (guard/branch).
    /\ Reconciler(n)
    \* IS:108-146 (guard/branch).
    /\ s.inst[n].pc="initialize"
    \* IS:108-146 (guard/branch).
    /\ s.data[n].diskRole="primary"
    \* IS:108-146 (guard/branch).
    /\ s.inst[n].snapshot.target#n
    \* IS:108-146 (guard/branch).
    /\ s.inst[n].snapshot.current=s.inst[n].snapshot.target
    \* IS:108-146 (guard/branch).
    /\ Writer(s.inst[n].snapshot.current)
    \* IS:108-146 (guard/branch).
    /\ s.env.io[n]
    \* IS:108-146 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.archive = IF ArchiveEnabled THEN s.archive \cup {[timeline |-> s.data[n].timeline, prefix |-> s.data[n].durable]} ELSE s.archive,
         !.inst[n].pc = "rewind"]

\* Scenarios 1,5; IS:146-152; PG:1011-1028.
\* Rewind is completed before any standby start; disk durability is retained across earlier crashes.
Rewind_Demote(n) ==
    \* IS:146-152; PG:1011-1028 (guard/branch).
    /\ Reconciler(n)
    \* IS:146-152; PG:1011-1028 (guard/branch).
    /\ s.inst[n].pc="rewind"
    \* IS:146-152; PG:1011-1028 (guard/branch).
    /\ Writer(s.inst[n].snapshot.current)
    \* IS:146-152; PG:1011-1028 (guard/branch).
    /\ s.env.io[n]
    \* IS:146-152; PG:1011-1028 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].diskRole = "replica",
         !.data[n].generated = s.data[s.inst[n].snapshot.current].durable,
         !.data[n].received = s.data[s.inst[n].snapshot.current].durable,
         !.data[n].durable = s.data[s.inst[n].snapshot.current].durable,
         !.data[n].replayed = s.data[s.inst[n].snapshot.current].durable,
         !.data[n].timeline = s.data[s.inst[n].snapshot.current].timeline,
         !.inst[n].initialized = TRUE,
         !.inst[n].pc = "ready"]

\* Scenarios 1; LP:62-103,129-140.
\* Actual postmaster start occurs after initialization, before reconcilePrimary.
RunPostgresAndWait(n) ==
    \* LP:62-103,129-140 (guard/branch).
    /\ Reconciler(n)
    \* LP:62-103,129-140 (guard/branch).
    /\ s.inst[n].initialized
    \* LP:62-103,129-140 (guard/branch).
    /\ s.data[n].pgState="down"
    \* LP:62-103,129-140 (guard/branch).
    /\ s.env.io[n]
    \* LP:62-103,129-140 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].pgState = "running",
         !.data[n].stopWrites = FALSE,
         !.data[n].runtimeConfig = s.data[n].fileConfig,
         !.life[n].postgresExited = FALSE,
         !.life[n].archiveComplete = FALSE]

\* Scenarios 1,3,4,5; IC:229-246.
\* The readiness guard precedes both promotion and old-primary retirement.
InstanceIsReady(n) ==
    \* IC:229-246 (guard/branch).
    /\ Reconciler(n)
    \* IC:229-246 (guard/branch).
    /\ s.inst[n].pc="ready"
    \* IC:229-246 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = IF DBReady(n) THEN "primary" ELSE "idle"]

\* Scenarios 1,2,3; IC:1203-1226.
ReconcilePrimary(n) ==
    \* IC:1203-1226 (guard/branch).
    /\ Reconciler(n)
    \* IC:1203-1226 (guard/branch).
    /\ s.inst[n].pc="primary"
    \* IC:1203-1226 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = IF s.inst[n].snapshot.target=n THEN "acquire" ELSE "oldPrimary"]

\* Scenarios 1,2,3; LR:147-162; IC:1215-1234.
\* Only the first call captures the lease profile. Caller timeout does not cancel the runnable.
Acquire(n) ==
    \* LR:147-162; IC:1215-1234 (guard/branch).
    /\ Reconciler(n)
    \* LR:147-162; IC:1215-1234 (guard/branch).
    /\ s.inst[n].pc="acquire"
    \* LR:147-162; IC:1215-1234 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n] = IF s.elect[n].captured=0 THEN [s.elect[n] EXCEPT !.captured=s.inst[n].snapshot.leaseGeneration, !.pc="preGet", !.pollAge=0] ELSE s.elect[n],
         !.inst[n].pc = "acquireWait",
         !.inst[n].acquireAge = 0]

\* Scenarios 1,2,3; LR:158-162; IC:1237-1259.
\* Closed heldCh is a one-shot notification, not a fresh ownership predicate.
Acquire_Return(n) ==
    \* LR:158-162; IC:1237-1259 (guard/branch).
    /\ Reconciler(n)
    \* LR:158-162; IC:1237-1259 (guard/branch).
    /\ s.inst[n].pc="acquireWait"
    \* LR:158-162; IC:1237-1259 (guard/branch).
    /\ s.elect[n].firstAcquired
    \* LR:158-162; IC:1237-1259 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = IF s.data[n].diskRole="primary" THEN "completePatch" ELSE "receiverWait"]

\* Scenarios 1; IC:1215-1234; LR:150-162.
\* Caller retry is separate from the background preAcquire goroutine.
Acquire_Deadline(n) ==
    \* IC:1215-1234; LR:150-162 (guard/branch).
    /\ Reconciler(n)
    \* IC:1215-1234; LR:150-162 (guard/branch).
    /\ s.inst[n].pc="acquireWait"
    \* IC:1215-1234; LR:150-162 (guard/branch).
    /\ ~s.elect[n].firstAcquired
    \* IC:1215-1234; LR:150-162 (guard/branch).
    /\ s.inst[n].acquireAge>=LeaseProfiles[s.inst[n].snapshot.leaseGeneration].duration+3*LeaseProfiles[s.inst[n].snapshot.leaseGeneration].retry
    \* IC:1215-1234; LR:150-162 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "idle"]

\* Scenarios 1,2,3; IC:1295-1306,1343-1359.
\* Checks the selected node itself, even if operator HTTP receiver fields were unavailable.
WaitForWalReceiverDown(n) ==
    \* IC:1295-1306,1343-1359 (guard/branch).
    /\ Reconciler(n)
    \* IC:1295-1306,1343-1359 (guard/branch).
    /\ s.inst[n].pc="receiverWait"
    \* IC:1295-1306,1343-1359 (guard/branch).
    /\ s.inst[n].snapshot.current=n \/ ~Receiver(n)
    \* IC:1295-1306,1343-1359 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "promoteRequest"]

\* Scenarios 1,2,3,4; PR:35-56; IC:1304-1309.
\* pg_ctl promotion request; PostgreSQL finishes available WAL before the physical role changes.
PromoteAndWait_Request(n) ==
    \* PR:35-56; IC:1304-1309 (guard/branch).
    /\ Reconciler(n)
    \* PR:35-56; IC:1304-1309 (guard/branch).
    /\ s.inst[n].pc="promoteRequest"
    \* PR:35-56; IC:1304-1309 (guard/branch).
    /\ DBReady(n)
    \* PR:35-56; IC:1304-1309 (guard/branch).
    /\ s.data[n].diskRole="replica"
    \* PR:35-56; IC:1304-1309 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].promotePC = "requested",
         !.inst[n].pc = "promoteWait"]

\* Scenarios 1,2,3,4; PR:58-93; FD:68-86; IC:1255-1268.
\* Missing archive successor is an observed end-of-WAL, not proof the previous primary finished archiving.
PromoteAndWait_Complete(n) ==
    \* PR:58-93; FD:68-86; IC:1255-1268 (guard/branch).
    /\ Running(n)
    \* PR:58-93; FD:68-86; IC:1255-1268 (guard/branch).
    /\ s.env.io[n]
    \* PR:58-93; FD:68-86; IC:1255-1268 (guard/branch).
    /\ s.data[n].promotePC="requested"
    \* PR:58-93; FD:68-86; IC:1255-1268 (guard/branch).
    /\ s.data[n].replayed=s.data[n].durable
    \* PR:58-93; FD:68-86; IC:1255-1268 (guard/branch).
    /\ s.data[n].received=s.data[n].durable
    \* PR:58-93; FD:68-86; IC:1255-1268 (guard/branch).
    /\ \A a \in s.archive : a.timeline=s.data[n].timeline /\ Prefix(s.data[n].durable,a.prefix) => Len(a.prefix)<=Len(s.data[n].durable)
    \* PR:58-93; FD:68-86; IC:1255-1268 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].diskRole = "primary",
         !.data[n].generated = s.data[n].durable,
         !.data[n].receiver = None,
         !.data[n].timeline = <<n,s.data[n].replayed>>,
         !.data[n].promotePC = "done",
         !.history = s.history \cup {[node |-> n, retained |-> s.data[n].durable, fork |-> s.data[n].replayed, acks |-> s.acks, cleanFrom |-> s.elect[n].cleanFrom, cleanAcks |-> s.elect[n].cleanAcks, timeline |-> <<n,s.data[n].replayed>>]}]

\* Scenarios 1,3,4; PR:66-93; IC:1256-1266.
PromoteAndWait_Return(n) ==
    \* PR:66-93; IC:1256-1266 (guard/branch).
    /\ Reconciler(n)
    \* PR:66-93; IC:1256-1266 (guard/branch).
    /\ s.inst[n].pc="promoteWait"
    \* PR:66-93; IC:1256-1266 (guard/branch).
    /\ s.data[n].promotePC="done"
    \* PR:66-93; IC:1256-1266 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "completePatch"]

\* Scenarios 1,3,4,5; IC:1237,1262-1268.
\* Merge patch of currentPrimary; source has no fresh target/version precondition.
ReconcilePrimary_CompleteStatus(n) ==
    \* IC:1237,1262-1268 (guard/branch).
    /\ Reconciler(n)
    \* IC:1237,1262-1268 (guard/branch).
    /\ s.env.api[n]
    \* IC:1237,1262-1268 (guard/branch).
    /\ s.inst[n].pc="completePatch"
    \* IC:1237,1262-1268 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster = IF s.inst[n].snapshot.current=n THEN s.cluster ELSE [s.cluster EXCEPT !.current=n, !.rv=ClusterRV],
         !.inst[n].snapshot.current = n,
         !.inst[n].pc = "oldPrimary"]

\* Scenarios 1,2,3,5; IC:614-639.
\* Send lifecycle command and wait. Demotion never reuses heldCh in the same manager process.
ReconcileOldPrimary(n) ==
    \* IC:614-639 (guard/branch).
    /\ Reconciler(n)
    \* IC:614-639 (guard/branch).
    /\ s.inst[n].pc="oldPrimary"
    \* IC:614-639 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = IF s.inst[n].snapshot.target#n /\ s.data[n].diskRole="primary" THEN "retiring" ELSE "config",
         !.life[n] = IF s.inst[n].snapshot.target#n /\ s.data[n].diskRole="primary" THEN [s.life[n] EXCEPT !.cause="demotion", !.phase="requested", !.stopAge=0] ELSE s.life[n]]

\* Scenarios 3,4; IC:277-299; IQ:98-109.
ReconcileConfiguration(n) ==
    \* IC:277-299; IQ:98-109 (guard/branch).
    /\ Reconciler(n)
    \* IC:277-299; IQ:98-109 (guard/branch).
    /\ s.inst[n].pc="config"
    \* IC:277-299; IQ:98-109 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = IF s.inst[n].reloadNeeded THEN IF ManageQuorum(n) THEN "resetGet" ELSE "reload" ELSE "metadata"]

\* Scenarios 4; IQ:34-49; CMD:219-230.
ResetFailoverQuorumObject_Get(n) ==
    \* IQ:34-49; CMD:219-230 (guard/branch).
    /\ Reconciler(n)
    \* IQ:34-49; CMD:219-230 (guard/branch).
    /\ s.env.api[n]
    \* IQ:34-49; CMD:219-230 (guard/branch).
    /\ s.inst[n].pc="resetGet"
    \* IQ:34-49; CMD:219-230 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].qread = s.quorum,
         !.inst[n].pc = "resetUpdate"]

\* Scenarios 4; IQ:39-49; IC:288-291.
ResetFailoverQuorumObject_Update(n) ==
    \* IQ:39-49; IC:288-291 (guard/branch).
    /\ Reconciler(n)
    \* IQ:39-49; IC:288-291 (guard/branch).
    /\ s.env.api[n]
    \* IQ:39-49; IC:288-291 (guard/branch).
    /\ s.inst[n].pc="resetUpdate"
    \* IQ:39-49; IC:288-291 (guard/branch).
    /\ s.inst[n].qread.rv=s.quorum.rv
    \* IQ:39-49; IC:288-291 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.quorum = [EmptyQuorum EXCEPT !.rv=QuorumRV],
         !.inst[n].pc = "reload"]

\* Scenarios 4; IQ:39-49,80-95.
FailoverQuorum_Conflict(n) ==
    \* IQ:39-49,80-95 (guard/branch).
    /\ Reconciler(n)
    \* IQ:39-49,80-95 (guard/branch).
    /\ s.inst[n].pc\in {"resetUpdate","quorumUpdate"}
    \* IQ:39-49,80-95 (guard/branch).
    /\ s.inst[n].qread.rv#s.quorum.rv
    \* IQ:39-49,80-95 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = IF s.inst[n].pc="resetUpdate" THEN "resetGet" ELSE "quorumRead"]

\* Scenarios 3,4; IC:288-295; PG:727-756.
\* pg_ctl reload request is separate from runtime application.
Reload(n) ==
    \* IC:288-295; PG:727-756 (guard/branch).
    /\ Reconciler(n)
    \* IC:288-295; PG:727-756 (guard/branch).
    /\ s.inst[n].pc="reload"
    \* IC:288-295; PG:727-756 (guard/branch).
    /\ Running(n)
    \* IC:288-295; PG:727-756 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "reloadWait"]

\* Scenarios 3,4; IC:291-299; PG:1100-1115,1120-1150.
\* Successful observed config hash; no historical hash-check regression is modeled.
ProcessConfigReloadAndManageRestart(n) ==
    \* IC:291-299; PG:1100-1115,1120-1150 (guard/branch).
    /\ Reconciler(n)
    \* IC:291-299; PG:1100-1115,1120-1150 (guard/branch).
    /\ s.inst[n].pc="reloadWait"
    \* IC:291-299; PG:1100-1115,1120-1150 (guard/branch).
    /\ DBReady(n)
    \* IC:291-299; PG:1100-1115,1120-1150 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].runtimeConfig = s.data[n].fileConfig,
         !.inst[n].reloadNeeded = FALSE,
         !.inst[n].pc = "metadata"]

\* Scenarios 4; IQ:54-78; PG:1156-1181.
\* Read runtime metadata once before conflict retries; provenance is diagnostic, not an extra guard.
GetSynchronousReplicationMetadata(n) ==
    \* IQ:54-78; PG:1156-1181 (guard/branch).
    /\ Reconciler(n)
    \* IQ:54-78; PG:1156-1181 (guard/branch).
    /\ s.inst[n].pc="metadata"
    \* IQ:54-78; PG:1156-1181 (guard/branch).
    /\ ~ManageQuorum(n) \/ DBReady(n)
    \* IQ:54-78; PG:1156-1181 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].metadata = IF ManageQuorum(n) THEN [EmptyQuorum EXCEPT !.primary=n, !.members=s.data[n].runtimeConfig.members\{n}, !.number=s.data[n].runtimeConfig.number, !.generation=s.data[n].runtimeConfig.generation, !.timeline=s.data[n].timeline] ELSE EmptyQuorum,
         !.inst[n].pc = IF ManageQuorum(n) THEN "quorumRead" ELSE "idle"]

\* Scenarios 4; IQ:80-89; CMD:219-230.
UpdateFailoverQuorumObject_Get(n) ==
    \* IQ:80-89; CMD:219-230 (guard/branch).
    /\ Reconciler(n)
    \* IQ:80-89; CMD:219-230 (guard/branch).
    /\ s.env.api[n]
    \* IQ:80-89; CMD:219-230 (guard/branch).
    /\ s.inst[n].pc="quorumRead"
    \* IQ:80-89; CMD:219-230 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].qread = s.quorum,
         !.inst[n].pc = "quorumUpdate"]

\* Scenarios 4; IQ:88-95.
UpdateFailoverQuorumObject_Update(n) ==
    \* IQ:88-95 (guard/branch).
    /\ Reconciler(n)
    \* IQ:88-95 (guard/branch).
    /\ s.env.api[n]
    \* IQ:88-95 (guard/branch).
    /\ s.inst[n].pc="quorumUpdate"
    \* IQ:88-95 (guard/branch).
    /\ s.inst[n].qread.rv=s.quorum.rv
    \* IQ:88-95 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.quorum = IF [s.quorum EXCEPT !.rv=0]=s.inst[n].metadata THEN s.quorum ELSE [s.inst[n].metadata EXCEPT !.rv=QuorumRV],
         !.inst[n].pc = "idle"]

\* Scenarios 1,2; LR:295-310; LL:42-53.
TryTakeOver_Get(n) ==
    \* LR:295-310; LL:42-53 (guard/branch).
    /\ Reconciler(n)
    \* LR:295-310; LL:42-53 (guard/branch).
    /\ s.elect[n].pc="preGet"
    \* LR:295-310; LL:42-53 (guard/branch).
    /\ s.env.api[n]
    \* LR:295-310; LL:42-53 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].read = s.lease,
         !.elect[n].pc = "preCheck"]

\* Scenarios 1; LR:302-304,383-397.
TryTakeOver_ReadError(n) ==
    \* LR:302-304,383-397 (guard/branch).
    /\ Reconciler(n)
    \* LR:302-304,383-397 (guard/branch).
    /\ s.elect[n].pc="preGet"
    \* LR:302-304,383-397 (guard/branch).
    /\ ~s.env.api[n]
    \* LR:302-304,383-397 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "preWait",
         !.elect[n].pollAge = 0]

\* Scenarios 1; LR:308-310,443-450.
\* Own-holder observation is accepted without first renewing.
TryTakeOver_OwnHolder(n) ==
    \* LR:308-310,443-450 (guard/branch).
    /\ Reconciler(n)
    \* LR:308-310,443-450 (guard/branch).
    /\ s.elect[n].pc="preCheck"
    \* LR:308-310,443-450 (guard/branch).
    /\ s.elect[n].read.holder=n
    \* LR:308-310,443-450 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "signal"]

\* Scenarios 1,2; LR:313-318.
TryTakeOver_EmptyHolder(n) ==
    \* LR:313-318 (guard/branch).
    /\ Reconciler(n)
    \* LR:313-318 (guard/branch).
    /\ s.elect[n].pc="preCheck"
    \* LR:313-318 (guard/branch).
    /\ s.elect[n].read.holder=None
    \* LR:313-318 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "claim"]

\* Scenarios 1; LR:320-334,340-342.
\* Foreign record uses the candidate captured duration. No retirement occurs in this branch, even after a previous acquisition.
TryTakeOver_ForeignHolder(n) ==
    \* LR:320-334,340-342 (guard/branch).
    /\ Reconciler(n)
    \* LR:320-334,340-342 (guard/branch).
    /\ s.elect[n].pc="preCheck"
    \* LR:320-334,340-342 (guard/branch).
    /\ s.elect[n].read.holder\notin {None,n}
    \* LR:320-334,340-342 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = IF s.elect[n].takeoverObserved /\ s.elect[n].takeoverObservation.holder=s.elect[n].read.holder /\ s.elect[n].takeoverObservation.renew=s.elect[n].read.renew /\ s.elect[n].takeoverAge>=LeaseProfiles[s.elect[n].captured].duration THEN "claim" ELSE "preWait",
         !.elect[n].takeoverAge = IF ~s.elect[n].takeoverObserved \/ s.elect[n].takeoverObservation.holder#s.elect[n].read.holder \/ s.elect[n].takeoverObservation.renew#s.elect[n].read.renew THEN 0 ELSE s.elect[n].takeoverAge,
         !.elect[n].takeoverObservation = s.elect[n].read,
         !.elect[n].takeoverObserved = TRUE,
         !.elect[n].pollAge = 0]

\* Scenarios 1; LR:370-398.
PreAcquire_Retry(n) ==
    \* LR:370-398 (guard/branch).
    /\ Reconciler(n)
    \* LR:370-398 (guard/branch).
    /\ s.elect[n].pc="preWait"
    \* LR:370-398 (guard/branch).
    /\ s.elect[n].pollAge>=LeaseProfiles[s.elect[n].captured].retry
    \* LR:370-398 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "preGet"]

\* Scenarios 1,2; LR:344-360; LL:73-95.
\* Conditional API update. Only a matching resourceVersion can succeed.
Claim(n) ==
    \* LR:344-360; LL:73-95 (guard/branch).
    /\ Reconciler(n)
    \* LR:344-360; LL:73-95 (guard/branch).
    /\ s.env.api[n]
    \* LR:344-360; LL:73-95 (guard/branch).
    /\ s.elect[n].pc="claim"
    \* LR:344-360; LL:73-95 (guard/branch).
    /\ s.elect[n].read.rv=s.lease.rv
    \* LR:344-360; LL:73-95 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.lease = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV, !.cleanFrom=None, !.cleanAcks={}],
         !.elect[n].cleanFrom = s.elect[n].read.cleanFrom,
         !.elect[n].cleanAcks = s.elect[n].read.cleanAcks,
         !.elect[n].read = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV, !.cleanFrom=None, !.cleanAcks={}],
         !.elect[n].takeoverObserved = FALSE,
         !.elect[n].pc = "signal"]

\* Scenarios 1; LR:348-357,383-397.
Claim_ConflictOrError(n) ==
    \* LR:348-357,383-397 (guard/branch).
    /\ Reconciler(n)
    \* LR:348-357,383-397 (guard/branch).
    /\ s.elect[n].pc="claim"
    \* LR:348-357,383-397 (guard/branch).
    /\ ~s.env.api[n] \/ s.elect[n].read.rv#s.lease.rv
    \* LR:348-357,383-397 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "preWait",
         !.elect[n].pollAge = 0]

\* Scenarios 1,2; LR:443-450.
\* heldCh closes before le.Run calls its own acquire, and never reopens in this process.
RunLeaderElection_FirstAcquired(n) ==
    \* LR:443-450 (guard/branch).
    /\ Reconciler(n)
    \* LR:443-450 (guard/branch).
    /\ s.elect[n].pc="signal"
    \* LR:443-450 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].firstAcquired = TRUE,
         !.elect[n].pc = "runGet",
         !.elect[n].mode = "acquire",
         !.elect[n].observed = FALSE,
         !.elect[n].renewAge = 0,
         !.elect[n].pollAge = 0]

\* Scenarios 1; LE:253-275,284-306.
LeaderElection_Retry(n) ==
    \* LE:253-275,284-306 (guard/branch).
    /\ Reconciler(n)
    \* LE:253-275,284-306 (guard/branch).
    /\ s.elect[n].pc\in {"runIdle","renewStart"}
    \* LE:253-275,284-306 (guard/branch).
    /\ s.elect[n].pc="renewStart" \/ s.elect[n].pollAge>=LeaseProfiles[s.elect[n].captured].retry
    \* LE:253-275,284-306 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = IF s.elect[n].mode="renew" THEN "renewFast" ELSE "runGet"]

\* Scenarios 1; LE:454-466; LL:73-95.
LeaderElection_RenewFast(n) ==
    \* LE:454-466; LL:73-95 (guard/branch).
    /\ Reconciler(n)
    \* LE:454-466; LL:73-95 (guard/branch).
    /\ s.env.api[n]
    \* LE:454-466; LL:73-95 (guard/branch).
    /\ s.elect[n].pc="renewFast"
    \* LE:454-466; LL:73-95 (guard/branch).
    /\ s.elect[n].read.rv=s.lease.rv
    \* LE:454-466; LL:73-95 (guard/branch).
    /\ s.elect[n].read.holder=n
    \* LE:454-466; LL:73-95 (guard/branch).
    /\ s.elect[n].observeAge<s.elect[n].read.duration
    \* LE:454-466; LL:73-95 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.lease = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV],
         !.elect[n].read = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV],
         !.elect[n].observation = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV],
         !.elect[n].pc = "runIdle",
         !.elect[n].observeAge = 0,
         !.elect[n].renewAge = 0,
         !.elect[n].pollAge = 0]

\* Scenarios 1; LE:454-470.
LeaderElection_Fallback(n) ==
    \* LE:454-470 (guard/branch).
    /\ Reconciler(n)
    \* LE:454-470 (guard/branch).
    /\ s.elect[n].pc="renewFast"
    \* LE:454-470 (guard/branch).
    /\ ~s.env.api[n] \/ s.elect[n].read.rv#s.lease.rv \/ s.elect[n].read.holder#n \/ s.elect[n].observeAge>=s.elect[n].read.duration
    \* LE:454-470 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "runGet"]

\* Scenarios 1; LE:470-490; LL:42-53.
LeaderElection_Get(n) ==
    \* LE:470-490; LL:42-53 (guard/branch).
    /\ Reconciler(n)
    \* LE:470-490; LL:42-53 (guard/branch).
    /\ s.env.api[n]
    \* LE:470-490; LL:42-53 (guard/branch).
    /\ s.elect[n].pc="runGet"
    \* LE:470-490; LL:42-53 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].read = s.lease,
         !.elect[n].pc = "runCheck"]

\* Scenarios 1; LE:470-474,284-306.
LeaderElection_GetError(n) ==
    \* LE:470-474,284-306 (guard/branch).
    /\ Reconciler(n)
    \* LE:470-474,284-306 (guard/branch).
    /\ ~s.env.api[n]
    \* LE:470-474,284-306 (guard/branch).
    /\ s.elect[n].pc="runGet"
    \* LE:470-474,284-306 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "runIdle",
         !.elect[n].pollAge = 0]

\* Scenarios 1; LE:486-508.
\* Unlike tryTakeOver, client-go uses the observed record duration; the fresh first foreign read always starts a new observation window.
LeaderElection_Check(n) ==
    \* LE:486-508 (guard/branch).
    /\ Reconciler(n)
    \* LE:486-508 (guard/branch).
    /\ s.elect[n].pc="runCheck"
    \* LE:486-508 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = IF s.elect[n].read.holder\in {None,n} \/ (s.elect[n].observed /\ s.elect[n].observation.rv=s.elect[n].read.rv /\ s.elect[n].observeAge>=s.elect[n].read.duration) THEN "runUpdate" ELSE "runIdle",
         !.elect[n].observeAge = IF ~s.elect[n].observed \/ s.elect[n].observation.rv#s.elect[n].read.rv THEN 0 ELSE s.elect[n].observeAge,
         !.elect[n].observation = s.elect[n].read,
         !.elect[n].observed = TRUE,
         !.elect[n].pollAge = 0]

\* Scenarios 1; LE:497-514; LL:73-95.
LeaderElection_Update(n) ==
    \* LE:497-514; LL:73-95 (guard/branch).
    /\ Reconciler(n)
    \* LE:497-514; LL:73-95 (guard/branch).
    /\ s.env.api[n]
    \* LE:497-514; LL:73-95 (guard/branch).
    /\ s.elect[n].pc="runUpdate"
    \* LE:497-514; LL:73-95 (guard/branch).
    /\ s.elect[n].read.rv=s.lease.rv
    \* LE:497-514; LL:73-95 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.lease = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV],
         !.elect[n].read = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV],
         !.elect[n].observation = [s.lease EXCEPT !.holder=n, !.duration=LeaseProfiles[s.elect[n].captured].duration, !.renew=LeaseRV, !.rv=LeaseRV],
         !.elect[n].mode = "renew",
         !.elect[n].pc = IF s.elect[n].mode="acquire" THEN "renewStart" ELSE "runIdle",
         !.elect[n].observeAge = 0,
         !.elect[n].renewAge = 0,
         !.elect[n].pollAge = 0]

\* Scenarios 1; LE:508-511,284-306.
LeaderElection_UpdateError(n) ==
    \* LE:508-511,284-306 (guard/branch).
    /\ Reconciler(n)
    \* LE:508-511,284-306 (guard/branch).
    /\ s.elect[n].pc="runUpdate"
    \* LE:508-511,284-306 (guard/branch).
    /\ ~s.env.api[n] \/ s.elect[n].read.rv#s.lease.rv
    \* LE:508-511,284-306 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "runIdle",
         !.elect[n].pollAge = 0]

\* Scenarios 1; LE:284-306; LR:479-490.
\* Expiry of an existing renewal timer is reactive; this is not an injected failed renewal.
RunLeaderElection_RenewDeadline(n) ==
    \* LE:284-306; LR:479-490 (guard/branch).
    /\ Reconciler(n)
    \* LE:284-306; LR:479-490 (guard/branch).
    /\ s.elect[n].mode="renew"
    \* LE:284-306; LR:479-490 (guard/branch).
    /\ s.elect[n].pc\in {"runIdle","renewStart","renewFast","runGet","runCheck","runUpdate"}
    \* LE:284-306; LR:479-490 (guard/branch).
    /\ s.elect[n].renewAge>=LeaseProfiles[s.elect[n].captured].renew+LeaseProfiles[s.elect[n].captured].retry
    \* LE:284-306; LR:479-490 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "verifyGet"]

\* Scenarios 1; LR:489-493.
ClassifyLeaseAfterRun_Get(n) ==
    \* LR:489-493 (guard/branch).
    /\ Reconciler(n)
    \* LR:489-493 (guard/branch).
    /\ s.env.api[n]
    \* LR:489-493 (guard/branch).
    /\ s.elect[n].pc="verifyGet"
    \* LR:489-493 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].read = s.lease,
         !.elect[n].pc = "verifyCheck"]

\* Scenarios 1; LR:269-270,489-503.
\* No evidence of preemption: retry; enabled isolation remains independent.
ClassifyLeaseAfterRun_Unverifiable(n) ==
    \* LR:269-270,489-503 (guard/branch).
    /\ Reconciler(n)
    \* LR:269-270,489-503 (guard/branch).
    /\ ~s.env.api[n]
    \* LR:269-270,489-503 (guard/branch).
    /\ s.elect[n].pc="verifyGet"
    \* LR:269-270,489-503 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "preGet"]

\* Scenarios 1; LR:273-276,493-515.
ClassifyLeaseAfterRun_Held(n) ==
    \* LR:273-276,493-515 (guard/branch).
    /\ Reconciler(n)
    \* LR:273-276,493-515 (guard/branch).
    /\ s.elect[n].pc="verifyCheck"
    \* LR:273-276,493-515 (guard/branch).
    /\ s.elect[n].read.holder=n
    \* LR:273-276,493-515 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "preGet"]

\* Scenarios 1,2; LR:273-274,504-512; CM:530-532.
\* Terminal error cancels the manager; it does not synchronously kill PostgreSQL.
ClassifyLeaseAfterRun_Preempted(n) ==
    \* LR:273-274,504-512; CM:530-532 (guard/branch).
    /\ Reconciler(n)
    \* LR:273-274,504-512; CM:530-532 (guard/branch).
    /\ s.elect[n].pc="verifyCheck"
    \* LR:273-274,504-512; CM:530-532 (guard/branch).
    /\ s.elect[n].read.holder#n
    \* LR:273-274,504-512; CM:530-532 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.elect[n].pc = "stopped",
         !.life[n].cause = "preempted",
         !.life[n].cancelled = TRUE,
         !.life[n].graceAge = 0]

\* Scenarios 1,2; LC:122-135.
PostgresLifecycle_Cancelled(n) ==
    \* LC:122-135 (guard/branch).
    /\ ~s.life[n].containerExited
    \* LC:122-135 (guard/branch).
    /\ s.life[n].cancelled
    \* LC:122-135 (guard/branch).
    /\ s.life[n].phase="none"
    \* LC:122-135 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].phase = IF s.life[n].upgrade THEN "done" ELSE "requested",
         !.life[n].lifecycleDone = s.life[n].upgrade,
         !.life[n].stopAge = 0,
         !.elect[n].pc = "stopped"]

\* Scenarios 1,2,3; LC:132-149; PG:581-590,1635-1667.
\* Request/checkpoint boundary precedes any signal that stops accepting SQL.
TryShuttingDownSmartFast_Checkpoint(n) ==
    \* LC:132-149; PG:581-590,1635-1667 (guard/branch).
    /\ ~s.life[n].containerExited
    \* LC:132-149; PG:581-590,1635-1667 (guard/branch).
    /\ s.life[n].phase="requested"
    \* LC:132-149; PG:581-590,1635-1667 (guard/branch).
    /\ ~s.life[n].upgrade
    \* LC:132-149; PG:581-590,1635-1667 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].phase = "checkpoint"]

\* Scenarios 1,2,3; PG:589-618,645-673,690-709.
\* Fast mode stops existing transactions. Smart mode can leave preexisting sessions writing; a cancelled checkpoint returns without proving SQL retirement.
Shutdown_StopRequest(n) ==
    \* PG:589-618,645-673,690-709 (guard/branch).
    /\ ~s.life[n].containerExited
    \* PG:589-618,645-673,690-709 (guard/branch).
    /\ s.life[n].phase="checkpoint"
    \* PG:589-618,645-673,690-709 (guard/branch).
    /\ s.env.io[n] \/ s.life[n].cancelled
    \* PG:589-618,645-673,690-709 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].phase = IF s.life[n].cause="demotion" THEN "fast" ELSE "smart",
         !.life[n].stopAge = 0,
         !.data[n].pgState = IF Running(n) THEN "stopping" ELSE "down",
         !.data[n].stopWrites = s.life[n].cause="demotion"]

\* Scenarios 2; PG:645-673.
\* Fast fallback retains the configured maxStopDelay; no old implicit 60-second timeout is modeled.
TryShuttingDownSmartFast_Fallback(n) ==
    \* PG:645-673 (guard/branch).
    /\ ~s.life[n].containerExited
    \* PG:645-673 (guard/branch).
    /\ s.life[n].phase="smart"
    \* PG:645-673 (guard/branch).
    /\ s.life[n].stopAge>=SmartDelay
    \* PG:645-673 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].phase = "fast",
         !.life[n].stopAge = 0,
         !.data[n].stopWrites = TRUE]

\* Scenarios 2,3; PG:626-680; FD:40-53.
\* All writers have retired; a clean shutdown now finishes WAL flush/archive.
Shutdown_ClientsFinished(n) ==
    \* PG:626-680; FD:40-53 (guard/branch).
    /\ ~s.life[n].containerExited
    \* PG:626-680; FD:40-53 (guard/branch).
    /\ s.life[n].phase\in {"smart","fast"}
    \* PG:626-680; FD:40-53 (guard/branch).
    /\ s.env.io[n]
    \* PG:626-680; FD:40-53 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].stopWrites = TRUE,
         !.life[n].phase = "archive"]

\* Scenarios 2,3; PG:581-623; LP:134-140; FD:40-46,78-86.
Shutdown_ArchiveComplete(n) ==
    \* PG:581-623; LP:134-140; FD:40-46,78-86 (guard/branch).
    /\ ~s.life[n].containerExited
    \* PG:581-623; LP:134-140; FD:40-46,78-86 (guard/branch).
    /\ s.life[n].phase="archive"
    \* PG:581-623; LP:134-140; FD:40-46,78-86 (guard/branch).
    /\ s.env.io[n]
    \* PG:581-623; LP:134-140; FD:40-46,78-86 (guard/branch).
    /\ s.data[n].diskRole="replica" \/ s.data[n].durable=s.data[n].generated
    \* PG:581-623; LP:134-140; FD:40-46,78-86 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.archive = IF ArchiveEnabled THEN s.archive\cup {[timeline |-> s.data[n].timeline, prefix |-> s.data[n].durable]} ELSE s.archive,
         !.life[n].archiveComplete = TRUE,
         !.life[n].phase = "pgExit"]

\* Scenarios 1,2,3; LP:134-140; LC:116-120,132-149.
RunPostgresAndWait_Exit(n) ==
    \* LP:134-140; LC:116-120,132-149 (guard/branch).
    /\ ~s.life[n].containerExited
    \* LP:134-140; LC:116-120,132-149 (guard/branch).
    /\ s.life[n].phase="pgExit"
    \* LP:134-140; LC:116-120,132-149 (guard/branch).
    /\ s.life[n].immediate \/ (\A r\in Server:Running(r) /\ s.data[r].receiver=n /\ s.env.wal[r] => Prefix(s.data[n].durable,s.sent[r]))
    \* LP:134-140; LC:116-120,132-149 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].pgState = "down",
         !.data[n].stopWrites = TRUE,
         !.data[n].receiver = None,
         !.life[n].postgresExited = TRUE,
         !.life[n].phase = "done"]

\* Scenarios 2,3; LC:73-75,116-149; CMD:379-385.
\* Ordinary SIGTERM and demotion reach manager cancellation only after lifecycle return.
PostgresLifecycle_Return(n) ==
    \* LC:73-75,116-149; CMD:379-385 (guard/branch).
    /\ ~s.life[n].containerExited
    \* LC:73-75,116-149; CMD:379-385 (guard/branch).
    /\ s.life[n].phase="done"
    \* LC:73-75,116-149; CMD:379-385 (guard/branch).
    /\ ~s.life[n].lifecycleDone
    \* LC:73-75,116-149; CMD:379-385 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].lifecycleDone = TRUE,
         !.life[n].cancelled = TRUE,
         !.elect[n].pc = "stopped"]

\* Scenarios 2; CM:57,513-518,602-606.
EngageStopProcedure_GraceExpired(n) ==
    \* CM:57,513-518,602-606 (guard/branch).
    /\ Manager(n)
    \* CM:57,513-518,602-606 (guard/branch).
    /\ s.life[n].cancelled
    \* CM:57,513-518,602-606 (guard/branch).
    /\ ~s.life[n].lifecycleDone
    \* CM:57,513-518,602-606 (guard/branch).
    /\ ~s.life[n].graceExpired
    \* CM:57,513-518,602-606 (guard/branch).
    /\ s.life[n].graceAge>=ManagerGrace
    \* CM:57,513-518,602-606 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].graceExpired = TRUE]

\* Scenarios 2; CM:602-614; CMD:450-460.
\* Runnable completion and manager grace expiry are different explanations for return.
ManagerStart_Return(n) ==
    \* CM:602-614; CMD:450-460 (guard/branch).
    /\ Manager(n)
    \* CM:602-614; CMD:450-460 (guard/branch).
    /\ s.life[n].cancelled
    \* CM:602-614; CMD:450-460 (guard/branch).
    /\ s.life[n].lifecycleDone \/ s.life[n].graceExpired
    \* CM:602-614; CMD:450-460 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].managerReturned = TRUE,
         !.life[n].releasePC = "get",
         !.elect[n].pc = "stopped"]

\* Scenarios 2; LR:188-194; CMD:392-399.
Release_UpgradeSkip(n) ==
    \* LR:188-194; CMD:392-399 (guard/branch).
    /\ s.life[n].managerReturned
    \* LR:188-194; CMD:392-399 (guard/branch).
    /\ s.life[n].releasePC="get"
    \* LR:188-194; CMD:392-399 (guard/branch).
    /\ s.life[n].upgrade
    \* LR:188-194; CMD:392-399 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].releasePC = "done"]

\* Scenarios 2; LR:196-208.
Release_Get(n) ==
    \* LR:196-208 (guard/branch).
    /\ s.life[n].managerReturned
    \* LR:196-208 (guard/branch).
    /\ s.life[n].releasePC="get"
    \* LR:196-208 (guard/branch).
    /\ ~s.life[n].upgrade
    \* LR:196-208 (guard/branch).
    /\ s.env.api[n]
    \* LR:196-208 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].releaseRead = s.lease,
         !.life[n].releasePC = "check"]

\* Scenarios 2; LR:204-208,216-221.
Release_Check(n) ==
    \* LR:204-208,216-221 (guard/branch).
    /\ s.life[n].releasePC="check"
    \* LR:204-208,216-221 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].releasePC = IF s.life[n].releaseRead.holder=n THEN "update" ELSE "done"]

\* Scenarios 2,3; LR:210-221; LL:73-95; CMD:392-399.
\* No PostgreSQL-exit/archive-completion guard exists here. Clean evidence is recorded, not asserted.
Release_Update(n) ==
    \* LR:210-221; LL:73-95; CMD:392-399 (guard/branch).
    /\ s.life[n].releasePC="update"
    \* LR:210-221; LL:73-95; CMD:392-399 (guard/branch).
    /\ s.env.api[n]
    \* LR:210-221; LL:73-95; CMD:392-399 (guard/branch).
    /\ s.life[n].releaseRead.rv=s.lease.rv
    \* LR:210-221; LL:73-95; CMD:392-399 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.lease = [s.lease EXCEPT !.holder=None, !.duration=IF s.elect[n].captured=0 THEN LeaseProfiles[1].released ELSE LeaseProfiles[s.elect[n].captured].released, !.rv=LeaseRV, !.renew=LeaseRV, !.cleanFrom=n, !.cleanAcks=IF s.life[n].immediate THEN {} ELSE AckRecords(n)],
         !.life[n].releasePC = "done"]

\* Scenarios 2; LR:196-203,216-221; CMD:396-398.
\* The defer makes one attempt; a foreign-holder read instead takes Release_Check.
Release_Error(n) ==
    \* LR:196-203,216-221; CMD:396-398 (guard/branch).
    /\ s.life[n].releasePC\in {"get","update"}
    \* LR:196-203,216-221; CMD:396-398 (guard/branch).
    /\ ~s.env.api[n] \/ (s.life[n].releasePC="update" /\ s.life[n].releaseRead.rv#s.lease.rv)
    \* LR:196-203,216-221; CMD:396-398 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].releasePC = "done"]

\* Scenarios 1,2; CMD:450-475; LC:102-104; FD:82-86.
\* Normal Pod namespace teardown stops remaining postmaster processes. It does not imply archiving completed.
Run_ContainerExit(n) ==
    \* CMD:450-475; LC:102-104; FD:82-86 (guard/branch).
    /\ s.life[n].managerReturned
    \* CMD:450-475; LC:102-104; FD:82-86 (guard/branch).
    /\ s.life[n].releasePC="done"
    \* CMD:450-475; LC:102-104; FD:82-86 (guard/branch).
    /\ ~s.life[n].containerExited
    \* CMD:450-475; LC:102-104; FD:82-86 (guard/branch).
    /\ ~s.life[n].upgrade
    \* CMD:450-475; LC:102-104; FD:82-86 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].containerExited = TRUE,
         !.life[n].postgresExited = TRUE,
         !.data[n].pgState = "down",
         !.data[n].stopWrites = TRUE,
         !.data[n].receiver = None,
         !.data[n].generated = s.data[n].durable,
         !.data[n].received = s.data[n].durable,
         !.inst[n].pc = "stopped",
         !.elect[n].pc = "stopped"]

\* Scenarios 1,2; LV:56-88.
\* Direct API probe result, separate from the instance informer cache.
IsHealthy_GetCluster(n) ==
    \* LV:56-88 (guard/branch).
    /\ Reconciler(n)
    \* LV:56-88 (guard/branch).
    /\ Running(n)
    \* LV:56-88 (guard/branch).
    /\ s.data[n].diskRole="primary"
    \* LV:56-88 (guard/branch).
    /\ s.life[n].isolationPC="idle"
    \* LV:56-88 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].isolationAPI = s.env.api[n],
         !.life[n].isolationPC = "ping"]

\* Scenarios 1,2; LV:79-87,108-122; pkg/management/postgres/webserver/probes/pinger.go:104-113.
IsHealthy_Ping(n) ==
    \* LV:79-87,108-122; pkg/management/postgres/webserver/probes/pinger.go:104-113 (guard/branch).
    /\ Reconciler(n)
    \* LV:79-87,108-122; pkg/management/postgres/webserver/probes/pinger.go:104-113 (guard/branch).
    /\ s.life[n].isolationPC="ping"
    \* LV:79-87,108-122; pkg/management/postgres/webserver/probes/pinger.go:104-113 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].isolationPeers = s.env.peer[n],
         !.life[n].isolationPC = "result"]

\* Scenarios 1,2; LV:72-88,108-115; LC:137-149.
\* Threshold-completed kubelet probe abstraction. API success compensates peer failure; retirement follows the SIGTERM order.
IsHealthy_IsolationProbe(n) ==
    \* LV:72-88,108-115; LC:137-149 (guard/branch).
    /\ Reconciler(n)
    \* LV:72-88,108-115; LC:137-149 (guard/branch).
    /\ s.life[n].isolationPC="result"
    \* LV:72-88,108-115; LC:137-149 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n] = IF ~s.life[n].isolationAPI /\ ~s.life[n].isolationPeers /\ s.life[n].cause="none" THEN [s.life[n] EXCEPT !.cause="isolation", !.phase="requested", !.stopAge=0, !.isolationPC="idle"] ELSE [s.life[n] EXCEPT !.isolationPC="idle"]]

\* Scenarios 2,3; PG:687-709; FD:40-53.
\* Current immediate fallback is retained. Loss after explicit immediate shutdown is excluded from clean-archive promises.
TryShuttingDownFastImmediate_Immediate(n) ==
    \* PG:687-709; FD:40-53 (guard/branch).
    /\ ~s.life[n].containerExited
    \* PG:687-709; FD:40-53 (guard/branch).
    /\ s.life[n].phase="fast"
    \* PG:687-709; FD:40-53 (guard/branch).
    /\ s.life[n].cause="demotion"
    \* PG:687-709; FD:40-53 (guard/branch).
    /\ s.life[n].stopAge>=FastDelay
    \* PG:687-709; FD:40-53 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].phase = "pgExit",
         !.life[n].immediate = TRUE,
         !.data[n].stopWrites = TRUE]

\* Scenarios 2; PG:660-677; LC:132-149.
\* Configured maxStopDelay expires: pg_ctl returns an error; lifecycle return still does not prove PostgreSQL exit.
TryShuttingDownSmartFast_StopTimeout(n) ==
    \* PG:660-677; LC:132-149 (guard/branch).
    /\ ~s.life[n].containerExited
    \* PG:660-677; LC:132-149 (guard/branch).
    /\ s.life[n].phase="fast"
    \* PG:660-677; LC:132-149 (guard/branch).
    /\ s.life[n].cause#"demotion"
    \* PG:660-677; LC:132-149 (guard/branch).
    /\ s.life[n].stopAge>=FastDelay
    \* PG:660-677; LC:132-149 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].phase = "done"]

\* Scenarios 2,3,4; FD:291-307,399-405; SY:45-79.
\* Client request introduces a unique normalized WAL identity; an unacknowledged request is not protected.
GenerateWAL(n,w) ==
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ Writer(n)
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ w\notin s.usedWAL
    \* FD:291-307,399-405; SY:45-79 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].generated = Append(s.data[n].generated,w),
         !.usedWAL = s.usedWAL\cup {w}]

\* Scenarios 2,3,4; FD:291-294,399-405; PG:1156-1181 (metadata observation).
\* PostgreSQL durable flush; a required synchronous ack cannot use merely received or sent WAL.
FlushWAL(n) ==
    \* FD:291-294,399-405; PG:1156-1181 (metadata observation) (guard/branch).
    /\ Running(n)
    \* FD:291-294,399-405; PG:1156-1181 (metadata observation) (guard/branch).
    /\ s.env.io[n]
    \* FD:291-294,399-405; PG:1156-1181 (metadata observation) (guard/branch).
    /\ IF s.data[n].diskRole="primary" THEN s.data[n].durable#s.data[n].generated ELSE s.data[n].durable#s.data[n].received
    \* FD:291-294,399-405; PG:1156-1181 (metadata observation) (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].durable = IF s.data[n].diskRole="primary" THEN s.data[n].generated ELSE s.data[n].received]

\* Scenarios 3,4; FD:24-29,291-294; PS:305-312.
\* WAL sender snapshot; sent is separate from receiver flush and replay.
SendWAL(n) ==
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Running(n)
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Receiver(n)
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.env.wal[n]
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Running(s.data[n].receiver)
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.data[s.data[n].receiver].diskRole="primary"
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.data[n].timeline=s.data[s.data[n].receiver].timeline
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Prefix(s.data[n].received,s.data[s.data[n].receiver].durable)
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.sent[n]#s.data[s.data[n].receiver].durable
    \* FD:24-29,291-294; PS:305-312 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.sent[n] = s.data[s.data[n].receiver].durable]

\* Scenarios 3,4; FD:24-29,291-294; PS:305-312.
ReceiveWAL(n) ==
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Running(n)
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Receiver(n)
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.env.wal[n]
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.env.io[n]
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ Prefix(s.data[n].received,s.sent[n])
    \* FD:24-29,291-294; PS:305-312 (guard/branch).
    /\ s.sent[n]#s.data[n].received
    \* FD:24-29,291-294; PS:305-312 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].received = s.sent[n]]

\* Scenarios 2,3,4; IC:1304-1309; PR:35-66; FD:68-86.
ReplayWAL(n) ==
    \* IC:1304-1309; PR:35-66; FD:68-86 (guard/branch).
    /\ Running(n)
    \* IC:1304-1309; PR:35-66; FD:68-86 (guard/branch).
    /\ s.data[n].diskRole="replica"
    \* IC:1304-1309; PR:35-66; FD:68-86 (guard/branch).
    /\ s.env.io[n]
    \* IC:1304-1309; PR:35-66; FD:68-86 (guard/branch).
    /\ Prefix(s.data[n].replayed,s.data[n].durable)
    \* IC:1304-1309; PR:35-66; FD:68-86 (guard/branch).
    /\ s.data[n].replayed#s.data[n].durable
    \* IC:1304-1309; PR:35-66; FD:68-86 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].replayed = s.data[n].durable]

\* Scenarios 2,3,4; FD:291-307,399-405; SY:45-79.
\* Client observes a durable synchronous commit. Required number never shrinks when a standby becomes unavailable.
AcknowledgeCommit(n,witnesses) ==
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ Writer(n)
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ s.data[n].durable#<<>>
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ witnesses\subseteq s.data[n].runtimeConfig.members\{n}
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ Cardinality(witnesses)>=s.data[n].runtimeConfig.number
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ \A r\in witnesses : Running(r) /\ s.data[r].receiver=n /\ s.env.wal[r] /\ s.data[r].timeline=s.data[n].timeline /\ Prefix(s.data[n].durable,s.data[r].durable)
    \* FD:291-307,399-405; SY:45-79 (guard/branch).
    /\ ~\E a\in s.acks : a.primary=n /\ a.prefix=s.data[n].durable /\ a.timeline=s.data[n].timeline
    \* FD:291-307,399-405; SY:45-79 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.acks = s.acks\cup {[primary |-> n, prefix |-> s.data[n].durable, timeline |-> s.data[n].timeline, members |-> s.data[n].runtimeConfig.members, number |-> s.data[n].runtimeConfig.number, generation |-> s.data[n].runtimeConfig.generation, witnesses |-> witnesses, copies |-> [r\in witnesses |-> s.data[r].durable]]}]

\* Scenarios 2,3; FD:68-86; IS:135-143.
ArchiveWAL(n) ==
    \* FD:68-86; IS:135-143 (guard/branch).
    /\ ArchiveEnabled
    \* FD:68-86; IS:135-143 (guard/branch).
    /\ Running(n)
    \* FD:68-86; IS:135-143 (guard/branch).
    /\ s.data[n].diskRole="primary"
    \* FD:68-86; IS:135-143 (guard/branch).
    /\ s.env.io[n]
    \* FD:68-86; IS:135-143 (guard/branch).
    /\ s.data[n].durable#<<>>
    \* FD:68-86; IS:135-143 (guard/branch).
    /\ [timeline |-> s.data[n].timeline, prefix |-> s.data[n].durable]\notin s.archive
    \* FD:68-86; IS:135-143 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.archive = IF ArchiveEnabled THEN s.archive\cup {[timeline |-> s.data[n].timeline, prefix |-> s.data[n].durable]} ELSE s.archive]

\* Scenarios 2,3; FD:68-86; IC:1304-1309.
\* Restore precedes durable flush/replay; missing next archive record permits promotion.
RestoreArchiveWAL(n,a) ==
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ ArchiveEnabled
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ Running(n)
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ s.data[n].diskRole="replica"
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ s.env.io[n]
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ a.timeline=s.data[n].timeline
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ Prefix(s.data[n].received,a.prefix)
    \* FD:68-86; IC:1304-1309 (guard/branch).
    /\ Len(a.prefix)>Len(s.data[n].received)
    \* FD:68-86; IC:1304-1309 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].received = a.prefix]

\* Scenarios 1,2,3,5; IC:1343-1359; PS:331-341; FD:24-29.
\* A normal drained stream consumes sent WAL before exit; transport failure can disconnect without a final prefix.
WalReceiverDown(n) ==
    \* IC:1343-1359; PS:331-341; FD:24-29 (guard/branch).
    /\ Receiver(n)
    \* IC:1343-1359; PS:331-341; FD:24-29 (guard/branch).
    /\ ~Running(n) \/ ~Running(s.data[n].receiver) \/ ~s.env.wal[n] \/ (s.data[s.data[n].receiver].stopWrites /\ s.life[s.data[n].receiver].phase="pgExit" /\ Prefix(s.data[s.data[n].receiver].durable,s.sent[n]))
    \* IC:1343-1359; PS:331-341; FD:24-29 (guard/branch).
    /\ ~s.env.wal[n] \/ ~Running(n) \/ (s.data[n].received=s.sent[n] /\ s.data[n].durable=s.data[n].received)
    \* IC:1343-1359; PS:331-341; FD:24-29 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].receiver = None,
         !.sent[n] = s.data[n].received]

\* Scenarios 1,3,5; OR:144-147,202-229; IC:448-451; FD:24-37.
\* New connections obey -rw labels; existing streams are not severed by a label patch.
WalReceiverConnect(n,p) ==
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ Running(n)
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ s.data[n].diskRole="replica"
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ ~Receiver(n)
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ s.env.wal[n]
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ Writer(p)
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ s.pods[p].label="primary"
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ s.pods[p].ready
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ Prefix(s.data[n].durable,s.data[p].durable)
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (guard/branch).
    /\ s.data[n].promotePC="none"
    \* OR:144-147,202-229; IC:448-451; FD:24-37 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.data[n].receiver = p,
         !.data[n].timeline = s.data[p].timeline,
         !.sent[n] = s.data[n].received]

\* Scenarios 1,5; IC:239-242; pkg/utils/pod_conditions.go:35-64.
ReadinessProbe(n) ==
    \* IC:239-242; pkg/utils/pod_conditions.go:35-64 (guard/branch).
    /\ s.pods[n].ready#(s.pods[n].active /\ DBReady(n) /\ s.env.probe[n])
    \* IC:239-242; pkg/utils/pod_conditions.go:35-64 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.pods[n].ready = s.pods[n].active /\ DBReady(n) /\ s.env.probe[n]]

\* Scenarios 1,5; OC:410-427; OR:199-229 (retry fix); FD:29-31.
\* Normal label convergence remains enabled after successful handoff.
ReconcileMetadata(n) ==
    \* OC:410-427; OR:199-229 (retry fix); FD:29-31 (guard/branch).
    /\ s.env.operatorUp
    \* OC:410-427; OR:199-229 (retry fix); FD:29-31 (guard/branch).
    /\ s.env.operatorAPI
    \* OC:410-427; OR:199-229 (retry fix); FD:29-31 (guard/branch).
    /\ s.cluster.current=s.cluster.target
    \* OC:410-427; OR:199-229 (retry fix); FD:29-31 (guard/branch).
    /\ s.pods[n].active
    \* OC:410-427; OR:199-229 (retry fix); FD:29-31 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.pods[n].label = IF n=s.cluster.current THEN "primary" ELSE "replica"]

\* Scenarios 1,2,3,5; OU:157-174,212-264; OR:65-78,262-329.
\* Rollout/drain stimulus, not a direct target patch.
RequestPlannedSwitchover ==
    \* OU:157-174,212-264; OR:65-78,262-329 (guard/branch).
    /\ ~s.op.requested
    \* OU:157-174,212-264; OR:65-78,262-329 (guard/branch).
    /\ s.cluster.current=s.cluster.target
    \* OU:157-174,212-264; OR:65-78,262-329 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.requested = TRUE]

\* Scenarios 2; CM:530-532; LC:122-135.
ManagerCancellation(n) ==
    \* CM:530-532; LC:122-135 (guard/branch).
    /\ Reconciler(n)
    \* CM:530-532; LC:122-135 (guard/branch).
    /\ ~s.life[n].cancelled
    \* CM:530-532; LC:122-135 (guard/branch).
    /\ s.life[n].cause="none"
    \* CM:530-532; LC:122-135 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].cause = "manager",
         !.life[n].cancelled = TRUE,
         !.life[n].graceAge = 0]

\* Scenarios 2; LC:137-149.
TerminationSignal(n) ==
    \* LC:137-149 (guard/branch).
    /\ Reconciler(n)
    \* LC:137-149 (guard/branch).
    /\ s.life[n].cause="none"
    \* LC:137-149 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].cause = "sigterm",
         !.life[n].phase = "requested",
         !.life[n].stopAge = 0]

\* Scenarios 2; LR:175-194; LC:126-129; CMD:379-385.
OnlineUpgrade(n) ==
    \* LR:175-194; LC:126-129; CMD:379-385 (guard/branch).
    /\ Reconciler(n)
    \* LR:175-194; LC:126-129; CMD:379-385 (guard/branch).
    /\ s.life[n].cause="none"
    \* LR:175-194; LC:126-129; CMD:379-385 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n].cause = "upgrade",
         !.life[n].upgrade = TRUE,
         !.life[n].cancelled = TRUE,
         !.life[n].graceAge = 0]

\* Scenarios 2; LR:179-186; LC:126-129.
\* Process replacement keeps PostgreSQL and disk state; new runnable has a new heldCh.
OnlineUpgrade_Exec(n) ==
    \* LR:179-186; LC:126-129 (guard/branch).
    /\ s.life[n].upgrade
    \* LR:179-186; LC:126-129 (guard/branch).
    /\ s.life[n].managerReturned
    \* LR:179-186; LC:126-129 (guard/branch).
    /\ s.life[n].releasePC="done"
    \* LR:179-186; LC:126-129 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n] = NewLife,
         !.inst[n] = [NewInst(s.cache[n]) EXCEPT !.initialized=FALSE],
         !.elect[n] = NewElector]

\* Scenarios 1,2,4,5; LC:95-120; LP:134-140; FD:82-86.
\* Abrupt process loss does not clean-release or erase durable WAL/disk role.
PodCrash(n) ==
    \* LC:95-120; LP:134-140; FD:82-86 (guard/branch).
    /\ ~s.life[n].containerExited
    \* LC:95-120; LP:134-140; FD:82-86 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n] = [NewLife EXCEPT !.cause="crash", !.containerExited=TRUE, !.postgresExited=TRUE, !.managerReturned=TRUE, !.releasePC="done"],
         !.data[n].pgState = "down",
         !.data[n].stopWrites = TRUE,
         !.data[n].receiver = None,
         !.data[n].generated = s.data[n].durable,
         !.data[n].received = s.data[n].durable,
         !.inst[n] = [NewInst(s.cache[n]) EXCEPT !.initialized=FALSE, !.pc="stopped"],
         !.elect[n] = NewElector,
         !.env.restartAllowed = s.env.restartAllowed\{n}]

\* Scenarios 1,4,5; LC:102-104; IS:41-152; LR:291-294.
\* Restart resets volatile PCs/acquisition/observation clocks while retaining disk configuration, WAL and role.
PodRestart(n) ==
    \* LC:102-104; IS:41-152; LR:291-294 (guard/branch).
    /\ s.life[n].containerExited
    \* LC:102-104; IS:41-152; LR:291-294 (guard/branch).
    /\ n\in s.env.restartAllowed
    \* LC:102-104; IS:41-152; LR:291-294 (guard/branch).
    /\ s.pods[n].active
    \* LC:102-104; IS:41-152; LR:291-294 (guard/branch).
    /\ s.env.api[n]
    \* LC:102-104; IS:41-152; LR:291-294 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.life[n] = [NewLife EXCEPT !.postgresExited=TRUE],
         !.cache[n] = s.cluster,
         !.inst[n] = [NewInst(s.cluster) EXCEPT !.initialized=FALSE],
         !.elect[n] = NewElector,
         !.data[n].promotePC = "none",
         !.data[n].pgState = "down"]

\* Scenarios 1,4,5; LC:102-104; FD:30-31.
PermitPodRestart(n) ==
    \* LC:102-104; FD:30-31 (guard/branch).
    /\ ~s.env.stable
    \* LC:102-104; FD:30-31 (guard/branch).
    /\ n\notin s.env.restartAllowed
    \* LC:102-104; FD:30-31 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.restartAllowed = s.env.restartAllowed\cup {n}]

\* Scenarios 5; pkg/utils/pod_conditions.go:74-78; OS:298-323.
\* Pod becomes inactive/terminating; this observation alone does not kill its container.
PodEviction(n) ==
    \* pkg/utils/pod_conditions.go:74-78; OS:298-323 (guard/branch).
    /\ s.pods[n].active
    \* pkg/utils/pod_conditions.go:74-78; OS:298-323 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.pods[n].active = FALSE,
         !.pods[n].ready = FALSE]

\* Scenarios 1,2,4; LR:302-304,489-503.
APIFailure(n) ==
    \* LR:302-304,489-503 (guard/branch).
    /\ s.env.api[n]
    \* LR:302-304,489-503 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.api[n] = FALSE]

\* Scenarios 1,2,4; LR:302-304,489-503.
APIFailure_Recover(n) ==
    \* LR:302-304,489-503 (guard/branch).
    /\ ~s.env.api[n]
    \* LR:302-304,489-503 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* LR:302-304,489-503 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.api[n] = TRUE]

\* Scenarios 1,4,5; RC:143-178; OC:663-685.
HTTPFailure(n) ==
    \* RC:143-178; OC:663-685 (guard/branch).
    /\ s.env.http[n]
    \* RC:143-178; OC:663-685 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.http[n] = FALSE]

\* Scenarios 1,4,5; RC:143-178; OC:663-685.
HTTPFailure_Recover(n) ==
    \* RC:143-178; OC:663-685 (guard/branch).
    /\ ~s.env.http[n]
    \* RC:143-178; OC:663-685 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* RC:143-178; OC:663-685 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.http[n] = TRUE]

\* Scenarios 1,5; pkg/utils/pod_conditions.go:35-64; OC:663-685.
ProbeFailure(n) ==
    \* pkg/utils/pod_conditions.go:35-64; OC:663-685 (guard/branch).
    /\ s.env.probe[n]
    \* pkg/utils/pod_conditions.go:35-64; OC:663-685 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.probe[n] = FALSE]

\* Scenarios 1,5; pkg/utils/pod_conditions.go:35-64; OC:663-685.
ProbeFailure_Recover(n) ==
    \* pkg/utils/pod_conditions.go:35-64; OC:663-685 (guard/branch).
    /\ ~s.env.probe[n]
    \* pkg/utils/pod_conditions.go:35-64; OC:663-685 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* pkg/utils/pod_conditions.go:35-64; OC:663-685 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.probe[n] = TRUE]

\* Scenarios 1,2,3,4; IC:1343-1359; FD:24-29.
ReplicationDisconnect(n) ==
    \* IC:1343-1359; FD:24-29 (guard/branch).
    /\ s.env.wal[n]
    \* IC:1343-1359; FD:24-29 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.wal[n] = FALSE]

\* Scenarios 1,2,3,4; IC:1343-1359; FD:24-29.
ReplicationDisconnect_Recover(n) ==
    \* IC:1343-1359; FD:24-29 (guard/branch).
    /\ ~s.env.wal[n]
    \* IC:1343-1359; FD:24-29 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* IC:1343-1359; FD:24-29 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.wal[n] = TRUE]

\* Scenarios 1; LV:72-88,108-115.
PeerFailure(n) ==
    \* LV:72-88,108-115 (guard/branch).
    /\ s.env.peer[n]
    \* LV:72-88,108-115 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.peer[n] = FALSE]

\* Scenarios 1; LV:72-88,108-115.
PeerFailure_Recover(n) ==
    \* LV:72-88,108-115 (guard/branch).
    /\ ~s.env.peer[n]
    \* LV:72-88,108-115 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* LV:72-88,108-115 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.peer[n] = TRUE]

\* Scenarios 2,4,5; IC:239-242; PG:581-618; PR:35-66.
StorageStall(n) ==
    \* IC:239-242; PG:581-618; PR:35-66 (guard/branch).
    /\ s.env.io[n]
    \* IC:239-242; PG:581-618; PR:35-66 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.io[n] = FALSE]

\* Scenarios 2,4,5; IC:239-242; PG:581-618; PR:35-66.
StorageStall_Recover(n) ==
    \* IC:239-242; PG:581-618; PR:35-66 (guard/branch).
    /\ ~s.env.io[n]
    \* IC:239-242; PG:581-618; PR:35-66 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* IC:239-242; PG:581-618; PR:35-66 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.io[n] = TRUE]

\* Scenarios 5; IC:239-242; RC:134-137.
SQLUnavailable(n) ==
    \* IC:239-242; RC:134-137 (guard/branch).
    /\ s.env.sql[n]
    \* IC:239-242; RC:134-137 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.sql[n] = FALSE]

\* Scenarios 5; IC:239-242; RC:134-137.
SQLUnavailable_Recover(n) ==
    \* IC:239-242; RC:134-137 (guard/branch).
    /\ ~s.env.sql[n]
    \* IC:239-242; RC:134-137 (guard/branch).
    /\ ~s.env.stable \/ n\in s.env.survivors
    \* IC:239-242; RC:134-137 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.sql[n] = TRUE]

\* Scenarios 5; OC:300-428; OS:752-776.
\* Discard volatile reconcile progress; persisted phase/pending/target survives.
OperatorCrash ==
    \* OC:300-428; OS:752-776 (guard/branch).
    /\ s.env.operatorUp
    \* OC:300-428; OS:752-776 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.operatorUp = FALSE,
         !.op.pc = "idle"]

\* Scenarios 5; OC:300-428.
OperatorRecover ==
    \* OC:300-428 (guard/branch).
    /\ ~s.env.operatorUp
    \* OC:300-428 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.operatorUp = TRUE]

\* Scenarios 4,5; OC:383-398; OQ:48-58.
OperatorAPIFailure ==
    \* OC:383-398; OQ:48-58 (guard/branch).
    /\ s.env.operatorAPI
    \* OC:383-398; OQ:48-58 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.operatorAPI = FALSE]

\* Scenarios 4,5; OC:383-398; OQ:48-58.
OperatorAPIRecover ==
    \* OC:383-398; OQ:48-58 (guard/branch).
    /\ ~s.env.operatorAPI
    \* OC:383-398; OQ:48-58 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.operatorAPI = TRUE]

\* Scenarios 1; LR:61-76,143-156; IC:1215-1224; FD:153-180.
\* A legitimate admission-valid rollout. Existing runnable keeps its captured profile.
UpdateLeaseConfiguration ==
    \* LR:61-76,143-156; IC:1215-1224; FD:153-180 (guard/branch).
    /\ s.cluster.leaseGeneration=1
    \* LR:61-76,143-156; IC:1215-1224; FD:153-180 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster.leaseGeneration = 2,
         !.cluster.rv = ClusterRV]

\* Scenarios 3,4; SY:45-79,129-147; IC:206-210,277-299.
\* Abstract validated operator-managed membership after supported cap/topology settings; no external names or direct quorum mutation.
UpdateSynchronousConfiguration(members,number) ==
    \* SY:45-79,129-147; IC:206-210,277-299 (guard/branch).
    /\ s.cluster.generation=1
    \* SY:45-79,129-147; IC:206-210,277-299 (guard/branch).
    /\ Cardinality(members)>=number
    \* SY:45-79,129-147; IC:206-210,277-299 (guard/branch).
    /\ members\{s.cluster.current}#{}
    \* SY:45-79,129-147; IC:206-210,277-299 (guard/branch).
    /\ members#s.cluster.syncMembers \/ number#s.cluster.syncNumber
    \* SY:45-79,129-147; IC:206-210,277-299 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.cluster.syncMembers = members,
         !.cluster.syncNumber = number,
         !.cluster.generation = 2,
         !.cluster.rv = ClusterRV]

\* Scenarios 5; FD:20-31,350-371; OC:389-455; IC:239-299.
\* Recovery suffix freezes fault injection in MC, recovers control plane and selected survivors, and does not resurrect the old primary or failed selected target.
RecoverEnvironment(survivors) ==
    \* FD:20-31,350-371; OC:389-455; IC:239-299 (guard/branch).
    /\ ~s.env.stable
    \* FD:20-31,350-371; OC:389-455; IC:239-299 (guard/branch).
    /\ Cardinality(survivors)>=InitialSyncNumber+1
    \* FD:20-31,350-371; OC:389-455; IC:239-299 (guard/branch).
    /\ \A n\in survivors : Running(n) /\ Reconciler(n) /\ s.pods[n].active
    \* FD:20-31,350-371; OC:389-455; IC:239-299 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.env.stable = TRUE,
         !.env.survivors = survivors,
         !.env.operatorUp = TRUE,
         !.env.operatorAPI = TRUE,
         !.env.api = [n \in Server |-> TRUE],
         !.env.http = [n \in Server |-> IF n\in survivors THEN TRUE ELSE s.env.http[n]],
         !.env.probe = [n \in Server |-> IF n\in survivors THEN TRUE ELSE s.env.probe[n]],
         !.env.sql = [n \in Server |-> IF n\in survivors THEN TRUE ELSE s.env.sql[n]],
         !.env.io = [n \in Server |-> IF n\in survivors THEN TRUE ELSE s.env.io[n]],
         !.env.wal = [n \in Server |-> IF n\in survivors THEN TRUE ELSE s.env.wal[n]],
         !.env.peer = [n \in Server |-> TRUE]]

\* Scenarios 1,2,5; LR:325-333,373-397; LE:284-306; CM:513-518; PG:635-673.
\* One time unit; elapsed clocks saturate above every decision threshold. Clock progress is not a finite fault budget.
ClockTick ==
    \* LR:325-333,373-397; LE:284-306; CM:513-518; PG:635-673 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst = [n\in Server |-> [s.inst[n] EXCEPT !.acquireAge=IF s.inst[n].pc="acquireWait" THEN Inc(@) ELSE @]],
         !.elect = [n\in Server |-> [s.elect[n] EXCEPT !.observeAge=IF s.elect[n].observed THEN Inc(@) ELSE @, !.takeoverAge=IF s.elect[n].takeoverObserved THEN Inc(@) ELSE @, !.pollAge=IF s.elect[n].captured>0 THEN Inc(@) ELSE @, !.renewAge=IF s.elect[n].mode="renew" THEN Inc(@) ELSE @]],
         !.life = [n\in Server |-> [s.life[n] EXCEPT !.graceAge=IF s.life[n].cancelled THEN Inc(@) ELSE @, !.stopAge=IF s.life[n].phase#"none" THEN Inc(@) ELSE @]]]

\* Scenarios 1,4,5; OC:300-329; SP:52-55 (controller-runtime cached client).
\* The operator retains a real informer object separately from its per-loop copy.
DeliverOperatorCluster ==
    \* OC:300-329; SP:52-55 (controller-runtime cached client) (guard/branch).
    /\ s.env.operatorUp
    \* OC:300-329; SP:52-55 (controller-runtime cached client) (guard/branch).
    /\ s.env.operatorAPI
    \* OC:300-329; SP:52-55 (controller-runtime cached client) (guard/branch).
    /\ s.op.cache#s.cluster
    \* OC:300-329; SP:52-55 (controller-runtime cached client) (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.cache = s.cluster]

\* Scenarios 4,5; OC:389-398; OR:135-142,176-196; SP:54-55,67-79.
\* A failed write returns/requeues; it cannot later succeed using the abandoned call.
Reconcile_APIError ==
    \* OC:389-398; OR:135-142,176-196; SP:54-55,67-79 (guard/branch).
    /\ s.env.operatorUp
    \* OC:389-398; OR:135-142,176-196; SP:54-55,67-79 (guard/branch).
    /\ ~s.env.operatorAPI
    \* OC:389-398; OR:135-142,176-196; SP:54-55,67-79 (guard/branch).
    /\ s.op.pc\in {"resourceStatus","failoverPhasePatch","plannedPhasePatch","selectedPhasePatch","pendingPatch","targetPatch"}
    \* OC:389-398; OR:135-142,176-196; SP:54-55,67-79 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = "idle"]

\* Scenarios 1,5; OC:413-427; OR:151-159.
\* Best-effort label failure does not block the initial failover; the transition guard retries next pass.
MarkOldPrimaryAsUnhealthy_Error ==
    \* OC:413-427; OR:151-159 (guard/branch).
    /\ s.env.operatorUp
    \* OC:413-427; OR:151-159 (guard/branch).
    /\ ~s.env.operatorAPI
    \* OC:413-427; OR:151-159 (guard/branch).
    /\ s.op.pc\in {"guardLabel","pendingLabel"}
    \* OC:413-427; OR:151-159 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.op.pc = IF s.op.pc="guardLabel" THEN "idle" ELSE "receivers"]

\* Scenarios 4,5; IC:288-300,1266-1268; IQ:42-48,83-94.
\* Non-conflict API errors return to reconcile; already completed promotion is retained.
InstanceReconcile_APIError(n) ==
    \* IC:288-300,1266-1268; IQ:42-48,83-94 (guard/branch).
    /\ Reconciler(n)
    \* IC:288-300,1266-1268; IQ:42-48,83-94 (guard/branch).
    /\ ~s.env.api[n]
    \* IC:288-300,1266-1268; IQ:42-48,83-94 (guard/branch).
    /\ s.inst[n].pc\in {"resetGet","resetUpdate","quorumRead","quorumUpdate","completePatch"}
    \* IC:288-300,1266-1268; IQ:42-48,83-94 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "idle"]

\* Scenarios 4,5; PG:1164-1169; IQ:59-62; IC:299-300.
\* Unavailable SQL metadata returns an error rather than publishing invented state.
GetSynchronousReplicationMetadata_Error(n) ==
    \* PG:1164-1169; IQ:59-62; IC:299-300 (guard/branch).
    /\ Reconciler(n)
    \* PG:1164-1169; IQ:59-62; IC:299-300 (guard/branch).
    /\ s.inst[n].pc="metadata"
    \* PG:1164-1169; IQ:59-62; IC:299-300 (guard/branch).
    /\ ManageQuorum(n)
    \* PG:1164-1169; IQ:59-62; IC:299-300 (guard/branch).
    /\ ~DBReady(n)
    \* PG:1164-1169; IQ:59-62; IC:299-300 (post-state; all other record fields unchanged).
    /\ s' = [s EXCEPT
         !.inst[n].pc = "idle"]

NormalNext ==
    \/ (Reconcile_GetCluster)
    \/ (GetManagedResources)
    \/ (UpdateResourceStatus)
    \/ (UpdateResourceStatus_Conflict)
    \/ (Reconcile_TransitionGuard)
    \/ (MarkOldPrimaryAsUnhealthy)
    \/ (\E n \in Server : GetReplicaStatusFromPodViaHTTP(n))
    \/ (EvaluatePodReadinessGuards)
    \/ (ReconcileTargetPrimaryForNonReplicaCluster)
    \/ (EvaluateQuorumCheck_Get)
    \/ (DeliverFailoverQuorum)
    \/ (EvaluateQuorumCheckWithStatus)
    \/ (UpdatePrimaryPod_Select)
    \/ (UpdatePrimaryPod_Wait)
    \/ (RegisterPhase_Get)
    \/ (RegisterPhase_Patch)
    \/ (RegisterPhase_Conflict)
    \/ (SetPrimaryInstance_Pending)
    \/ (AreWalReceiversDown)
    \/ (SetPrimaryInstance_Target)
    \/ (\E n \in Server : DeliverCluster(n))
    \/ (\E n \in Server : InstanceReconcile_GetCluster(n))
    \/ (\E n \in Server : RefreshConfigurationFiles(n))
    \/ (\E n \in Server : VerifyPgDataCoherenceForPrimary(n))
    \/ (\E n \in Server : VerifyPgDataCoherenceForPrimary_Wait(n))
    \/ (\E n \in Server : VerifyPgDataCoherenceForPrimary_Archive(n))
    \/ (\E n \in Server : Rewind_Demote(n))
    \/ (\E n \in Server : RunPostgresAndWait(n))
    \/ (\E n \in Server : InstanceIsReady(n))
    \/ (\E n \in Server : ReconcilePrimary(n))
    \/ (\E n \in Server : Acquire(n))
    \/ (\E n \in Server : Acquire_Return(n))
    \/ (\E n \in Server : Acquire_Deadline(n))
    \/ (\E n \in Server : WaitForWalReceiverDown(n))
    \/ (\E n \in Server : PromoteAndWait_Request(n))
    \/ (\E n \in Server : PromoteAndWait_Complete(n))
    \/ (\E n \in Server : PromoteAndWait_Return(n))
    \/ (\E n \in Server : ReconcilePrimary_CompleteStatus(n))
    \/ (\E n \in Server : ReconcileOldPrimary(n))
    \/ (\E n \in Server : ReconcileConfiguration(n))
    \/ (\E n \in Server : ResetFailoverQuorumObject_Get(n))
    \/ (\E n \in Server : ResetFailoverQuorumObject_Update(n))
    \/ (\E n \in Server : FailoverQuorum_Conflict(n))
    \/ (\E n \in Server : Reload(n))
    \/ (\E n \in Server : ProcessConfigReloadAndManageRestart(n))
    \/ (\E n \in Server : GetSynchronousReplicationMetadata(n))
    \/ (\E n \in Server : UpdateFailoverQuorumObject_Get(n))
    \/ (\E n \in Server : UpdateFailoverQuorumObject_Update(n))
    \/ (\E n \in Server : TryTakeOver_Get(n))
    \/ (\E n \in Server : TryTakeOver_ReadError(n))
    \/ (\E n \in Server : TryTakeOver_OwnHolder(n))
    \/ (\E n \in Server : TryTakeOver_EmptyHolder(n))
    \/ (\E n \in Server : TryTakeOver_ForeignHolder(n))
    \/ (\E n \in Server : PreAcquire_Retry(n))
    \/ (\E n \in Server : Claim(n))
    \/ (\E n \in Server : Claim_ConflictOrError(n))
    \/ (\E n \in Server : RunLeaderElection_FirstAcquired(n))
    \/ (\E n \in Server : LeaderElection_Retry(n))
    \/ (\E n \in Server : LeaderElection_RenewFast(n))
    \/ (\E n \in Server : LeaderElection_Fallback(n))
    \/ (\E n \in Server : LeaderElection_Get(n))
    \/ (\E n \in Server : LeaderElection_GetError(n))
    \/ (\E n \in Server : LeaderElection_Check(n))
    \/ (\E n \in Server : LeaderElection_Update(n))
    \/ (\E n \in Server : LeaderElection_UpdateError(n))
    \/ (\E n \in Server : RunLeaderElection_RenewDeadline(n))
    \/ (\E n \in Server : ClassifyLeaseAfterRun_Get(n))
    \/ (\E n \in Server : ClassifyLeaseAfterRun_Unverifiable(n))
    \/ (\E n \in Server : ClassifyLeaseAfterRun_Held(n))
    \/ (\E n \in Server : ClassifyLeaseAfterRun_Preempted(n))
    \/ (\E n \in Server : PostgresLifecycle_Cancelled(n))
    \/ (\E n \in Server : TryShuttingDownSmartFast_Checkpoint(n))
    \/ (\E n \in Server : Shutdown_StopRequest(n))
    \/ (\E n \in Server : TryShuttingDownSmartFast_Fallback(n))
    \/ (\E n \in Server : Shutdown_ClientsFinished(n))
    \/ (\E n \in Server : Shutdown_ArchiveComplete(n))
    \/ (\E n \in Server : RunPostgresAndWait_Exit(n))
    \/ (\E n \in Server : PostgresLifecycle_Return(n))
    \/ (\E n \in Server : EngageStopProcedure_GraceExpired(n))
    \/ (\E n \in Server : ManagerStart_Return(n))
    \/ (\E n \in Server : Release_UpgradeSkip(n))
    \/ (\E n \in Server : Release_Get(n))
    \/ (\E n \in Server : Release_Check(n))
    \/ (\E n \in Server : Release_Update(n))
    \/ (\E n \in Server : Release_Error(n))
    \/ (\E n \in Server : Run_ContainerExit(n))
    \/ (\E n \in Server : IsHealthy_GetCluster(n))
    \/ (\E n \in Server : IsHealthy_Ping(n))
    \/ (\E n \in Server : IsHealthy_IsolationProbe(n))
    \/ (\E n \in Server : TryShuttingDownFastImmediate_Immediate(n))
    \/ (\E n \in Server : TryShuttingDownSmartFast_StopTimeout(n))
    \/ (\E n \in Server : FlushWAL(n))
    \/ (\E n \in Server : SendWAL(n))
    \/ (\E n \in Server : ReceiveWAL(n))
    \/ (\E n \in Server : ReplayWAL(n))
    \/ (\E n \in Server, witnesses \in SUBSET Server : AcknowledgeCommit(n,witnesses))
    \/ (\E n \in Server : ArchiveWAL(n))
    \/ (\E n \in Server, a \in s.archive : RestoreArchiveWAL(n,a))
    \/ (\E n \in Server : WalReceiverDown(n))
    \/ (\E n \in Server, p \in Server : WalReceiverConnect(n,p))
    \/ (\E n \in Server : ReadinessProbe(n))
    \/ (\E n \in Server : ReconcileMetadata(n))
    \/ (\E n \in Server : OnlineUpgrade_Exec(n))
    \/ (\E n \in Server : PodRestart(n))
    \/ (\E n \in Server : PermitPodRestart(n))
    \/ (\E n \in Server : APIFailure_Recover(n))
    \/ (\E n \in Server : HTTPFailure_Recover(n))
    \/ (\E n \in Server : ProbeFailure_Recover(n))
    \/ (\E n \in Server : ReplicationDisconnect_Recover(n))
    \/ (\E n \in Server : PeerFailure_Recover(n))
    \/ (\E n \in Server : StorageStall_Recover(n))
    \/ (\E n \in Server : SQLUnavailable_Recover(n))
    \/ (OperatorRecover)
    \/ (OperatorAPIRecover)
    \/ (\E survivors \in SUBSET Server : RecoverEnvironment(survivors))
    \/ (ClockTick)
    \/ (DeliverOperatorCluster)
    \/ (Reconcile_APIError)
    \/ (MarkOldPrimaryAsUnhealthy_Error)
    \/ (\E n \in Server : InstanceReconcile_APIError(n))
    \/ (\E n \in Server : GetSynchronousReplicationMetadata_Error(n))

FaultNext ==
    \/ (\E n \in Server, w \in WAL : GenerateWAL(n,w))
    \/ (RequestPlannedSwitchover)
    \/ (\E n \in Server : ManagerCancellation(n))
    \/ (\E n \in Server : TerminationSignal(n))
    \/ (\E n \in Server : OnlineUpgrade(n))
    \/ (\E n \in Server : PodCrash(n))
    \/ (\E n \in Server : PodEviction(n))
    \/ (\E n \in Server : APIFailure(n))
    \/ (\E n \in Server : HTTPFailure(n))
    \/ (\E n \in Server : ProbeFailure(n))
    \/ (\E n \in Server : ReplicationDisconnect(n))
    \/ (\E n \in Server : PeerFailure(n))
    \/ (\E n \in Server : StorageStall(n))
    \/ (\E n \in Server : SQLUnavailable(n))
    \/ (OperatorCrash)
    \/ (OperatorAPIFailure)
    \/ (UpdateLeaseConfiguration)
    \/ (\E members \in SUBSET Server, number \in 1..(Cardinality(Server)-1) : UpdateSynchronousConfiguration(members,number))

Next == NormalNext \/ FaultNext
Spec == Init /\ [][Next]_vars

\* Structural domains; source states are introduced by the annotated actions.
NodeOrNone == Server \cup {None}
LeaseType == [holder:NodeOrNone,duration:Nat,renew:Versions,rv:Versions,
              cleanFrom:NodeOrNone,cleanAcks:SUBSET s.acks]
SyncType == [members:SUBSET Server,number:1..Cardinality(Server),generation:{1,2}]
ClusterType == [current:Server,target:Server\cup{Pending},phase:{"healthy","failover","switchover"},
                readyCount:0..Cardinality(Server),generation:{1,2},leaseGeneration:{1,2},
                syncMembers:SUBSET Server,syncNumber:1..Cardinality(Server),rv:Versions]
InstancePC == {"idle","files","initialize","ready","rewind","primary","acquire","acquireWait",
               "receiverWait","promoteRequest","promoteWait","completePatch","oldPrimary","retiring",
               "config","resetGet","resetUpdate","reload","reloadWait","metadata","quorumRead","quorumUpdate","stopped"}
ElectorPC == {"idle","preGet","preCheck","preWait","claim","signal","runGet","runCheck",
              "runIdle","renewStart","renewFast","runUpdate","verifyGet","verifyCheck","stopped"}
OperatorPC == {"idle","resources","resourceStatus","transitionGuard","guardLabel","pendingLabel",
               "collect","choose","quorumGet","quorumDecision","failoverPhaseGet","failoverPhasePatch",
               "plannedPhaseGet","plannedPhasePatch","selectedPhaseGet","selectedPhasePatch","pendingPatch",
               "receivers","targetPatch"}
QuorumTyped(q) == /\ q.exists\in BOOLEAN /\ q.primary\in NodeOrNone /\ q.members\subseteq Server
                  /\ q.number\in 0..Cardinality(Server) /\ q.generation\in {0,1,2} /\ q.rv\in Versions
WALSeq(q) == q\in Seq(WAL) /\ Cardinality(SeqSet(q))=Len(q)
TypeOK ==
    /\ s.order\in Orders
    /\ s.cluster\in ClusterType
    /\ s.lease\in LeaseType
    /\ QuorumTyped(s.quorum)
    /\ s.usedWAL\subseteq WAL
    /\ DOMAIN s.pods=Server /\ DOMAIN s.cache=Server /\ DOMAIN s.inst=Server
    /\ DOMAIN s.elect=Server /\ DOMAIN s.life=Server /\ DOMAIN s.data=Server /\ DOMAIN s.sent=Server
    /\ s.op.pc\in OperatorPC /\ s.op.cache\in ClusterType /\ s.op.cluster\in ClusterType /\ s.op.phaseRead\in ClusterType
    /\ s.op.active\subseteq Server /\ s.op.ready\subseteq s.op.active /\ s.op.collected\subseteq s.op.active
    /\ s.op.candidate\in NodeOrNone /\ s.op.purpose\in {"none","planned","failover"}
    /\ QuorumTyped(s.op.qcache) /\ QuorumTyped(s.op.quorum)
    /\ s.env.survivors\subseteq Server /\ s.env.restartAllowed\subseteq Server
    /\ \A f\in {"api","http","probe","sql","io","wal","peer"}:s.env[f]\in [Server->BOOLEAN]
    /\ \A f\in {"operatorUp","operatorAPI","stable"}:s.env[f]\in BOOLEAN
    /\ \A n\in Server:
         /\ s.pods[n]\in [active:BOOLEAN,ready:BOOLEAN,label:{"primary","replica","unhealthy"}]
         /\ s.cache[n]\in ClusterType /\ s.inst[n].snapshot\in ClusterType
         /\ s.inst[n].pc\in InstancePC /\ s.inst[n].initialized\in BOOLEAN /\ s.inst[n].reloadNeeded\in BOOLEAN
         /\ QuorumTyped(s.inst[n].qread) /\ QuorumTyped(s.inst[n].metadata)
         /\ s.elect[n].pc\in ElectorPC /\ s.elect[n].captured\in {0,1,2}
         /\ s.elect[n].firstAcquired\in BOOLEAN /\ s.elect[n].observed\in BOOLEAN /\ s.elect[n].takeoverObserved\in BOOLEAN
         /\ s.elect[n].read\in LeaseType /\ s.elect[n].observation\in LeaseType /\ s.elect[n].takeoverObservation\in LeaseType
         /\ s.elect[n].mode\in {"acquire","renew"}
         /\ \A f\in {"observeAge","takeoverAge","pollAge","renewAge"}:s.elect[n][f]\in 0..TimerCap
         /\ s.life[n].cause\in {"none","manager","preempted","sigterm","demotion","isolation","upgrade","crash"}
         /\ s.life[n].phase\in {"none","requested","checkpoint","smart","fast","archive","pgExit","done"}
         /\ s.life[n].releasePC\in {"idle","get","check","update","done"}
         /\ s.life[n].releaseRead\in LeaseType
         /\ \A f\in {"cancelled","managerReturned","postgresExited","archiveComplete","lifecycleDone","containerExited","upgrade","graceExpired","immediate","isolationAPI","isolationPeers"}:s.life[n][f]\in BOOLEAN
         /\ s.life[n].isolationPC\in {"idle","ping","result"}
         /\ s.inst[n].acquireAge\in 0..TimerCap
         /\ s.life[n].graceAge\in 0..TimerCap /\ s.life[n].stopAge\in 0..TimerCap
         /\ s.data[n].diskRole\in {"primary","replica"}
         /\ s.data[n].pgState\in {"down","running","stopping"}
         /\ s.data[n].receiver\in NodeOrNone\{n}
         /\ s.data[n].stopWrites\in BOOLEAN
         /\ s.data[n].fileConfig\in SyncType /\ s.data[n].runtimeConfig\in SyncType
         /\ s.data[n].promotePC\in {"none","requested","done"}
         /\ \A f\in {"generated","received","durable","replayed"}:WALSeq(s.data[n][f])
         /\ WALSeq(s.sent[n])
    /\ \A a\in s.acks:WALSeq(a.prefix) /\ a.primary\in Server /\ a.witnesses\subseteq Server /\ a.members\subseteq Server
    /\ \A a\in s.archive:WALSeq(a.prefix)
    /\ \A h\in s.history:h.node\in Server /\ WALSeq(h.retained) /\ WALSeq(h.fork) /\ h.acks\subseteq s.acks /\ h.cleanAcks\subseteq s.acks

\* Core safety: FD:291-294; SY:45-79. Historical evidence, not current membership.
DurableAcknowledgmentEvidence ==
    \A a\in s.acks:
       /\ a.number>0 /\ Cardinality(a.witnesses)>=a.number
       /\ a.witnesses\subseteq a.members\{a.primary}
       /\ DOMAIN a.copies=a.witnesses
       /\ (\A n\in a.witnesses:Prefix(a.prefix,a.copies[n]))
       /\ SeqSet(a.prefix)\subseteq s.usedWAL
       /\ a.prefix#<<>>
\* Structural: LP:134-140; FD:24-29; PG:581-623. Disk role may remain primary.
PhysicalStateCoherent ==
    \A n\in Server:
       /\ (s.life[n].containerExited => s.data[n].pgState="down")
       /\ (s.life[n].postgresExited => s.data[n].pgState="down")
       /\ Prefix(s.data[n].replayed,s.data[n].durable)
       /\ (s.data[n].diskRole="replica" => Prefix(s.data[n].durable,s.data[n].received))
       /\ (s.data[n].diskRole="primary" => Prefix(s.data[n].durable,s.data[n].generated))
       /\ SeqSet(s.data[n].durable)\subseteq s.usedWAL
AcquisitionStateCoherent ==
    \A n\in Server:
       /\ (s.elect[n].firstAcquired => s.elect[n].captured#0)
       /\ (s.elect[n].captured#0 => ValidLeaseConfig(LeaseProfiles[s.elect[n].captured]))

\* Brief §5, Scenarios 1-2; FD:56-103. Labels and holder identities are not writer counts.
SingleWriter == Cardinality({n\in Server:Writer(n)})<=1
\* Brief §5, Scenarios 3-4; FD:291-307,350-405. Evaluate only completed promotions.
AcknowledgedPrefixPreserved ==
    \A h\in s.history : \A a\in h.acks : Prefix(a.prefix,h.retained)
\* Brief §5, Scenario 2; FD:68-86. A release/timeout mismatch alone is not a violation.
CleanHandoffComplete ==
    ArchiveEnabled => \A h\in s.history : h.cleanFrom#None => \A a\in h.cleanAcks : Prefix(a.prefix,h.retained)
\* Brief §5, Scenarios 3-4; PR:35-93; FD:68-86. Fork uses applied WAL, not mere receipt.
ConsistentPrimaryHistory ==
    \A h\in s.history : \A a\in h.acks : Prefix(a.prefix,h.fork)
\* Brief §5, Scenario 5. Recover a sufficient subset, without reviving the failed primary.
RecoveryReady ==
    /\ s.env.stable /\ s.env.operatorUp /\ s.env.operatorAPI
    /\ Cardinality(s.env.survivors)>=InitialSyncNumber+1
    /\ \E n\in s.env.survivors : Acked\subseteq SeqSet(s.data[n].durable)
UsablePrimary ==
    \E n\in s.env.survivors :
       /\ s.cluster.current=n /\ s.cluster.target=n
       /\ Writer(n) /\ s.pods[n].active /\ s.pods[n].ready /\ s.pods[n].label="primary"
       /\ Cardinality(s.env.survivors\cap s.data[n].runtimeConfig.members)>=s.data[n].runtimeConfig.number
EventualUsablePrimary == RecoveryReady ~> UsablePrimary

=============================================================================
