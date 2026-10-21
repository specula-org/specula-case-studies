------------------------------- MODULE MC -------------------------------
EXTENDS base
\* No operator override of reactive actions. B remains available for wrappers.
LOCAL B == INSTANCE base
CONSTANTS Workload, ReadLimit, WriteLimit, ResizeLimit, FaultLimit,
          Serialize, ReadAfterMutations
VARIABLE issued
mcVars == <<vars, issued>>

\* Only client admission and fixed inaccessible-buffer setup are bounded.
\* SyscallEnter's source mapping is in base.tla; scheduler preemption is free.
MCInit == /\ B!Init
          /\ issued = [reads |-> 0, writes |-> 0, resizes |-> 0, faults |-> 0]
MCSyscallEnter(t, a) ==
    /\ a \in Workload
    /\ LET k == a[1]
           faulty == k /= "ftruncate" /\ a[5] < a[3] IN
       /\ (k \in ReadKinds => issued.reads < ReadLimit)
       /\ (k = "pwrite64" => issued.writes < WriteLimit)
       /\ (k = "ftruncate" => issued.resizes < ResizeLimit)
       /\ (faulty => issued.faults < FaultLimit)
       \* Optional harness ordering applies only to new requests.
       /\ (~Serialize \/ Active = {})
       /\ (~ReadAfterMutations \/ k \notin ReadKinds
            \/ (Quiescent /\ issued.writes = WriteLimit /\ issued.resizes = ResizeLimit))
       /\ B!SyscallEnter(t, k, a[2], a[3], a[4], a[5])
       /\ issued' = [issued EXCEPT
                       !.reads = @ + IF k \in ReadKinds THEN 1 ELSE 0,
                       !.writes = @ + IF k = "pwrite64" THEN 1 ELSE 0,
                       !.resizes = @ + IF k = "ftruncate" THEN 1 ELSE 0,
                       !.faults = @ + IF faulty THEN 1 ELSE 0]
MCThreadStep(t) == /\ B!ThreadStep(t) /\ UNCHANGED issued
MCNext == \E t \in Threads :
             \/ MCThreadStep(t)
             \/ \E a \in Workload : MCSyscallEnter(t, a)
MCSpec == MCInit /\ [][MCNext]_mcVars

\* Every actor may issue every workload entry; renaming actors also renames
\* their byte tags. No named reader/writer roles break this symmetry.
ThreadSymmetry == Permutations(Threads)
\* Keep counters in the view: equal file states with different budgets differ
\* in enabled client requests. No message buffer exists in Category B.
MCView == mcVars
MCBounds == /\ issued.reads \in 0..ReadLimit
            /\ issued.writes \in 0..WriteLimit
            /\ issued.resizes \in 0..ResizeLimit
            /\ issued.faults \in 0..FaultLimit
MCStructure == TypeOK /\ LockExclusion /\ CopyAcceptanceStructure /\ OffsetLockStructure /\ MCBounds
\* No kernel liveness property: cold-tail lock waits are retained (TV7).

\* Request tuples: <<kind, original offset, length, resize target, accessible prefix>>.
\* These are test schedules/inputs, not alternative backend implementations.
SavedEOFWorkload ==
    {<<k, 0, P, 0, P>> : k \in ReadKinds}
    \cup {<<"ftruncate", 0, 0, z, 0>> : z \in {0, 2 * P}}
    \cup {<<"pwrite64", P, P, 0, P>>}
GrowthReadWorkload ==
    {<<k, 0, 2 * P, 0, 2 * P>> : k \in ReadKinds}
    \cup {<<"ftruncate", 0, 0, 2 * P, 0>>, <<"pwrite64", P, P, 0, P>>}
PreparedExtendersWorkload ==
    {<<"pwrite64", o, P, 0, P>> : o \in {P, 2 * P}}
    \cup {<<"pread64", 2 * P, P, 0, P>>}
PreparedShrinkWorkload ==
    {<<"pwrite64", 2 * P, P, 0, P>>, <<"ftruncate", 0, 0, 0, 0>>,
     <<"pread64", 2 * P, P, 0, P>>}
ResizeAndHolesWorkload ==
    {<<"ftruncate", 0, 0, z, 0>> : z \in {0, 1, P + 1, 3 * P}}
    \cup {<<"pwrite64", 2 * P, P, 0, P>>}
    \cup {<<"pread64", o, P, 0, P>> : o \in {0, P, 2 * P}}
RegrowTailWorkload ==
    {<<"ftruncate", 0, 0, z, 0>> : z \in {1, P + 1, 3 * P}}
    \cup {<<"pread64", o, 1, 0, 1>> : o \in {1, P, P + 1, 2 * P}}
EmptyWriteWorkload == {<<"pwrite64", 2 * P, 0, 0, 0>>}
FailedWriteWorkload ==
    {<<"pwrite64", P, P, 0, b>> : b \in {0, 1}}
    \cup {<<"pwrite64", P, 2 * P, 0, P>>,
          <<"pread64", P, P, 0, P>>}
FailedReadWorkload == {<<k, 0, P, 0, b>> : k \in ReadKinds, b \in {0, 1}}
PreparedFaultWorkload ==
    {<<"pwrite64", 2 * P, P, 0, b>> : b \in {0, P}}
    \cup {<<"pwrite64", P, P, 0, P>>, <<"pread64", 2 * P, P, 0, P>>}
ConvergenceWorkload ==
    {<<"read", 0, P, 0, P>>, <<"pwrite64", P, P, 0, P>>,
     <<"ftruncate", 0, 0, 0, 0>>}

FailedReadOffsetUnchanged ==
    \A e \in h.completed : (e.kind = "read" /\ e.status = "EFAULT") =>
        e.positionAfter = e.startPosition

=============================================================================
