---- MODULE base ----
(***************************************************************************)
(* LiteBox Category B model.  The five extensions below correspond exactly *)
(* to Modeling Brief Scenarios 1--5.  Operations are split at the real     *)
(* lock-release, repeated-lookup, publication, ownership-transfer, and     *)
(* waiter-validation boundaries in current source head 49f7231e.           *)
(***************************************************************************)

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Thread, Node, Path, Fd, OFD, MapAddr,
    RootNode, InitialParentNode, InitialCwdNode, NoNode,
    RootPath, ParentPath, CwdPath, ChildPath, NoPath,
    InitialFd, InitialOFD, NoFd, NoOFD,
    InitialMapAddr, NoAddr,
    MainThread, NoThread,
    MaxGeneration, MaxOffset, MaxChunks

ASSUME /\ Thread /= {}
       /\ Node /= {}
       /\ Path /= {}
       /\ Fd /= {}
       /\ OFD /= {}
       /\ MapAddr /= {}
       /\ RootNode \in Node
       /\ InitialParentNode \in Node \ {RootNode}
       /\ InitialCwdNode \in Node \ {RootNode, InitialParentNode}
       /\ NoNode \notin Node
       /\ {RootPath, ParentPath, CwdPath, ChildPath} \subseteq Path
       /\ Cardinality({RootPath, ParentPath, CwdPath, ChildPath}) = 4
       /\ NoPath \notin Path
       /\ InitialFd \in Fd
       /\ InitialOFD \in OFD
       /\ NoFd \notin Fd
       /\ NoOFD \notin OFD
       /\ InitialMapAddr \in MapAddr
       /\ NoAddr \notin MapAddr
       /\ MainThread \in Thread
       /\ NoThread \notin Thread
       /\ MaxGeneration \in Nat \ {0}
       /\ MaxOffset \in Nat \ {0}
       /\ MaxChunks \in Nat \ {0}

Perm == {"R", "RW", "RX"}
PCState ==
    { "idle",
      "fs_walked", "chdir_validated",
      "fd_chunk", "dir_loaded", "dir_produced",
      "vm_map_host", "vm_plan_collected",
      "clone_prepared", "clone_parent_published", "clone_stack_valid",
      "clone_attached", "clone_transferred",
      "futex_waking", "futex_selected" }
CreateResult == {"none", "success", "failure"}
SpawnResult == {"none", "success", "failure"}
InitOwner == {"none", "caller", "platform", "child"}
WaiterPhase ==
    { "idle", "inserted_unvalidated", "validated_waiting",
      "selected_unvalidated", "selected_validated", "woken_unvalidated",
      "woken", "mismatch" }
EpollInterestType == [fd : Fd, ofd : OFD]

VARIABLES
    pc,
    \* Scenario 1: namespace identity.
    namespace, nodeAlive, nodeParent, walkedParent, walkedPath,
    cwdNode, cwdPath, cwdCandidate, createResult, createdNode,
    relativeLookupNode,
    \* Scenario 2: raw-fd and OFD identity.
    fdSlot, fdGeneration, ofdRefs, opOFD, opFd, lastChunkOFD,
    chunksDone, dirOffset, dirFd, dirCursor, epollInterests,
    \* Scenario 3: mapping generation and auxiliary state.
    hostMapped, hostGeneration, hostPerm,
    vmemMapped, vmemGeneration, vmemPerm,
    patchIntervals, mapGeneration, localMapAddr, localMapGeneration,
    localMapPerm, planAddr, planGeneration, patchApplied,
    patchAppliedPlanGeneration, patchAppliedHostGeneration,
    \* Scenario 4: clone publication and ownership.
    threads, committedThreads, threadCount, parentTid, initOwner,
    spawnResult, cloneChild,
    \* Scenario 5: futex waiter lifecycle.
    waiterPhase, futexValue, waiterExpected, waitQueue, wakeBudget,
    selected, wakeCount, wakeReturn, wakeHadUnvalidated

fsVars ==
    <<namespace, nodeAlive, nodeParent, walkedParent, walkedPath,
      cwdNode, cwdPath, cwdCandidate, createResult, createdNode,
      relativeLookupNode>>

fdVars ==
    <<fdSlot, fdGeneration, ofdRefs, opOFD, opFd, lastChunkOFD,
      chunksDone, dirOffset, dirFd, dirCursor, epollInterests>>

vmVars ==
    <<hostMapped, hostGeneration, hostPerm,
      vmemMapped, vmemGeneration, vmemPerm,
      patchIntervals, mapGeneration, localMapAddr, localMapGeneration,
      localMapPerm, planAddr, planGeneration, patchApplied,
      patchAppliedPlanGeneration, patchAppliedHostGeneration>>

cloneVars ==
    <<threads, committedThreads, threadCount, parentTid, initOwner,
      spawnResult, cloneChild>>

futexVars ==
    <<waiterPhase, futexValue, waiterExpected, waitQueue, wakeBudget,
      selected, wakeCount, wakeReturn, wakeHadUnvalidated>>

vars == <<pc, fsVars, fdVars, vmVars, cloneVars, futexVars>>

FSFrame == UNCHANGED <<fdVars, vmVars, cloneVars, futexVars>>
FDFrame == UNCHANGED <<fsVars, vmVars, cloneVars, futexVars>>
VMFrame == UNCHANGED <<fsVars, fdVars, cloneVars, futexVars>>
CloneFrame == UNCHANGED <<fsVars, fdVars, vmVars, futexVars>>
FutexFrame == UNCHANGED <<fsVars, fdVars, vmVars, cloneVars>>

Init ==
    /\ pc = [t \in Thread |-> "idle"]
    \* Context and ResolvedPath bootstrap: resolver.rs:50-105.
    /\ namespace =
        [p \in Path |->
            IF p = RootPath THEN RootNode
            ELSE IF p = ParentPath THEN InitialParentNode
            ELSE IF p = CwdPath THEN InitialCwdNode
            ELSE NoNode]
    /\ nodeAlive =
        [n \in Node |-> n \in {RootNode, InitialParentNode, InitialCwdNode}]
    /\ nodeParent =
        [n \in Node |->
            IF n \in {InitialParentNode, InitialCwdNode} THEN RootNode ELSE NoNode]
    /\ walkedParent = [t \in Thread |-> NoNode]
    /\ walkedPath = [t \in Thread |-> NoPath]
    /\ cwdNode = [t \in Thread |-> InitialCwdNode]
    /\ cwdPath = [t \in Thread |-> CwdPath]
    /\ cwdCandidate = [t \in Thread |-> NoNode]
    /\ createResult = [t \in Thread |-> "none"]
    /\ createdNode = [t \in Thread |-> NoNode]
    /\ relativeLookupNode = [t \in Thread |-> NoNode]
    \* Raw storage starts with one typed descriptor: fd/mod.rs:614-624.
    /\ fdSlot = [f \in Fd |-> IF f = InitialFd THEN InitialOFD ELSE NoOFD]
    /\ fdGeneration = [f \in Fd |-> IF f = InitialFd THEN 1 ELSE 0]
    /\ ofdRefs = [o \in OFD |-> IF o = InitialOFD THEN 1 ELSE 0]
    /\ opOFD = [t \in Thread |-> NoOFD]
    /\ opFd = [t \in Thread |-> NoFd]
    /\ lastChunkOFD = [t \in Thread |-> NoOFD]
    /\ chunksDone = [t \in Thread |-> 0]
    /\ dirOffset = [f \in Fd |-> 0]
    /\ dirFd = [t \in Thread |-> NoFd]
    /\ dirCursor = [t \in Thread |-> 0]
    /\ epollInterests = {}
    \* One committed tracked file mapping: mm.rs:121-159.
    /\ hostMapped = [a \in MapAddr |-> a = InitialMapAddr]
    /\ hostGeneration = [a \in MapAddr |-> IF a = InitialMapAddr THEN 1 ELSE 0]
    /\ hostPerm = [a \in MapAddr |-> "R"]
    /\ vmemMapped = [a \in MapAddr |-> a = InitialMapAddr]
    /\ vmemGeneration = [a \in MapAddr |-> IF a = InitialMapAddr THEN 1 ELSE 0]
    /\ vmemPerm = [a \in MapAddr |-> "R"]
    /\ patchIntervals = [a \in MapAddr |-> IF a = InitialMapAddr THEN 1 ELSE 0]
    /\ mapGeneration = [a \in MapAddr |-> IF a = InitialMapAddr THEN 1 ELSE 0]
    /\ localMapAddr = [t \in Thread |-> NoAddr]
    /\ localMapGeneration = [t \in Thread |-> 0]
    /\ localMapPerm = [t \in Thread |-> "R"]
    /\ planAddr = [t \in Thread |-> NoAddr]
    /\ planGeneration = [t \in Thread |-> 0]
    /\ patchApplied = [t \in Thread |-> FALSE]
    /\ patchAppliedPlanGeneration = [t \in Thread |-> 0]
    /\ patchAppliedHostGeneration = [t \in Thread |-> 0]
    \* Initial process has one committed attachment: process.rs:167-185.
    /\ threads = {MainThread}
    /\ committedThreads = {MainThread}
    /\ threadCount = 1
    /\ parentTid = [t \in Thread |-> NoThread]
    /\ initOwner = [t \in Thread |-> IF t = MainThread THEN "child" ELSE "none"]
    /\ spawnResult = [t \in Thread |-> "none"]
    /\ cloneChild = [t \in Thread |-> NoThread]
    \* Futex entries do not exist until wait inserts them: futex.rs:83-106.
    /\ waiterPhase = [t \in Thread |-> "idle"]
    /\ futexValue = 0
    /\ waiterExpected = [t \in Thread |-> 0]
    /\ waitQueue = <<>>
    /\ wakeBudget = [t \in Thread |-> 0]
    /\ selected = {}
    /\ wakeCount = [t \in Thread |-> 0]
    /\ wakeReturn = [t \in Thread |-> 0]
    /\ wakeHadUnvalidated = [t \in Thread |-> FALSE]

(***************************************************************************)
(* Scenario 1: path snapshot versus stable namespace identity.             *)
(***************************************************************************)

\* Resolver::parent_dir_and_name walks and returns a backend walking handle.
\* litebox/src/fs/resolver.rs:214-232; in_mem.rs:249-293.
ResolverParentDirAndName(t, p) ==
    \* The walk observes the current path binding: resolver.rs:222-231.
    /\ pc[t] = "idle"
    /\ p \in Path \ {RootPath, ChildPath}
    /\ namespace[p] /= NoNode
    /\ nodeAlive[namespace[p]]
    \* InMem returns an owned Arc after releasing each read lock: in_mem.rs:257-293.
    /\ walkedParent' = [walkedParent EXCEPT ![t] = namespace[p]]
    /\ walkedPath' = [walkedPath EXCEPT ![t] = p]
    /\ pc' = [pc EXCEPT ![t] = "fs_walked"]
    /\ UNCHANGED <<namespace, nodeAlive, nodeParent, cwdNode, cwdPath,
                    cwdCandidate, createResult, createdNode, relativeLookupNode>>
    /\ FSFrame

\* InMem::rmdir_at locks only the named parent and removes an empty child.
\* litebox/src/fs/in_mem.rs:556-570; resolver.rs:925-946.
InMemRmdirAt(p) ==
    LET victim == namespace[p] IN
    \* Lookup and empty-directory check occur under the parent write lock: in_mem.rs:559-566.
    /\ p \in Path \ {RootPath, ChildPath}
    /\ victim /= NoNode
    /\ nodeAlive[victim]
    /\ ~ \E child \in Node : nodeAlive[child] /\ nodeParent[child] = victim
    \* Removal unlinks the directory but stale Arc handles survive: in_mem.rs:567-570.
    /\ namespace' = [namespace EXCEPT ![p] = NoNode]
    /\ nodeAlive' = [nodeAlive EXCEPT ![victim] = FALSE]
    /\ nodeParent' = [nodeParent EXCEPT ![victim] = NoNode]
    /\ UNCHANGED <<pc, walkedParent, walkedPath, cwdNode, cwdPath,
                    cwdCandidate, createResult, createdNode, relativeLookupNode>>
    /\ FSFrame

\* A later mkdir/open(O_CREAT) can bind a fresh object at the same pathname.
\* litebox/src/fs/in_mem.rs:478-505,508-538; resolver.rs:575-611,893-922.
InMemRecreateAt(p, n) ==
    \* The recreated pathname must currently be absent: in_mem.rs:488-490,518-520.
    /\ p \in {ParentPath, CwdPath}
    /\ namespace[p] = NoNode
    /\ n \in Node \ {RootNode}
    /\ ~nodeAlive[n]
    \* Insertion creates a fresh identity under root: in_mem.rs:491-502,521-531.
    /\ namespace' = [namespace EXCEPT ![p] = n]
    /\ nodeAlive' = [nodeAlive EXCEPT ![n] = TRUE]
    /\ nodeParent' = [nodeParent EXCEPT ![n] = RootNode]
    /\ UNCHANGED <<pc, walkedParent, walkedPath, cwdNode, cwdPath,
                    cwdCandidate, createResult, createdNode, relativeLookupNode>>
    /\ FSFrame

\* InMem::create_file_at uses the retained directory object after the walk lock is gone.
\* litebox/src/fs/in_mem.rs:478-505; resolver.rs:578-611.
InMemCreateFileAt(t, n) ==
    \* Backend commit uses the cached handle without linked-state revalidation: in_mem.rs:486-502.
    /\ pc[t] = "fs_walked"
    /\ n \in Node \ {RootNode}
    /\ ~nodeAlive[n]
    /\ namespace[ChildPath] = NoNode
    \* The child is inserted into the cached object even if that object was unlinked: in_mem.rs:499-502.
    /\ nodeAlive' = [nodeAlive EXCEPT ![n] = TRUE]
    /\ nodeParent' = [nodeParent EXCEPT ![n] = walkedParent[t]]
    /\ namespace' =
        IF nodeAlive[walkedParent[t]] /\ namespace[walkedPath[t]] = walkedParent[t]
        THEN [namespace EXCEPT ![ChildPath] = n]
        ELSE namespace
    /\ createResult' = [createResult EXCEPT ![t] = "success"]
    /\ createdNode' = [createdNode EXCEPT ![t] = n]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<walkedParent, walkedPath, cwdNode, cwdPath,
                    cwdCandidate, relativeLookupNode>>
    /\ FSFrame

\* Task::sys_chdir first resolves and validates a pathname.
\* litebox_shim_linux/src/syscalls/file.rs:1742-1782.
TaskSysChdirValidate(t, p) ==
    \* file_status confirms the current binding is a directory: file.rs:1755-1781.
    /\ pc[t] = "idle"
    /\ p \in Path \ {RootPath, ChildPath}
    /\ namespace[p] /= NoNode
    /\ nodeAlive[namespace[p]]
    /\ cwdCandidate' = [cwdCandidate EXCEPT ![t] = namespace[p]]
    /\ walkedPath' = [walkedPath EXCEPT ![t] = p]
    /\ pc' = [pc EXCEPT ![t] = "chdir_validated"]
    /\ UNCHANGED <<namespace, nodeAlive, nodeParent, walkedParent, cwdNode,
                    cwdPath, createResult, createdNode, relativeLookupNode>>
    /\ FSFrame

\* Context::set_cwd publishes only the normalized ResolvedPath string.
\* litebox_shim_linux/src/syscalls/file.rs:1784-1785; resolver.rs:84-87.
TaskSysChdirPublish(t) ==
    \* There is no identity recheck between file_status and set_cwd: file.rs:1762-1785.
    /\ pc[t] = "chdir_validated"
    /\ cwdNode' = [cwdNode EXCEPT ![t] = cwdCandidate[t]]
    /\ cwdPath' = [cwdPath EXCEPT ![t] = walkedPath[t]]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<namespace, nodeAlive, nodeParent, walkedParent, walkedPath,
                    cwdCandidate, createResult, createdNode, relativeLookupNode>>
    /\ FSFrame

\* Task::resolve_path turns cwd back into text and resolves that text again.
\* litebox_shim_linux/src/syscalls/file.rs:205-228.
TaskResolvePathRelative(t) ==
    \* cwd_prefix reads the stored path, not a stable directory handle: file.rs:205-226.
    /\ pc[t] = "idle"
    /\ relativeLookupNode' = [relativeLookupNode EXCEPT ![t] = namespace[cwdPath[t]]]
    /\ UNCHANGED <<pc, namespace, nodeAlive, nodeParent, walkedParent,
                    walkedPath, cwdNode, cwdPath, cwdCandidate, createResult,
                    createdNode>>
    /\ FSFrame

(***************************************************************************)
(* Scenario 2: raw fd slots versus open-file-description identity.         *)
(***************************************************************************)

\* Long read/readv/sendfile/mmap operations enter a loop but retain raw fd.
\* litebox_shim_linux/src/lib.rs:516-541,588-628; syscalls/file.rs:625-648.
TaskChunkedReadBegin(t, f) ==
    \* Initial validation resolves the current raw slot: file.rs:606-610,961-973.
    /\ pc[t] = "idle"
    /\ f \in Fd
    /\ fdSlot[f] /= NoOFD
    /\ opFd' = [opFd EXCEPT ![t] = f]
    /\ opOFD' = [opOFD EXCEPT ![t] = fdSlot[f]]
    /\ lastChunkOFD' = [lastChunkOFD EXCEPT ![t] = NoOFD]
    /\ chunksDone' = [chunksDone EXCEPT ![t] = 0]
    /\ pc' = [pc EXCEPT ![t] = "fd_chunk"]
    /\ UNCHANGED <<fdSlot, fdGeneration, ofdRefs, dirOffset, dirFd,
                    dirCursor, epollInterests>>
    /\ FDFrame

\* Each chunk calls sys_read/run_on_raw_fd and therefore resolves the raw slot again.
\* litebox_shim_linux/src/syscalls/file.rs:625-648,938-956; mm.rs:287-304.
TaskChunkedReadChunk(t) ==
    \* The current slot, not opOFD, selects the consumer for this chunk: file.rs:637-648.
    /\ pc[t] = "fd_chunk"
    /\ chunksDone[t] < MaxChunks
    /\ fdSlot[opFd[t]] /= NoOFD
    /\ lastChunkOFD' = [lastChunkOFD EXCEPT ![t] = fdSlot[opFd[t]]]
    /\ chunksDone' = [chunksDone EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<pc, fdSlot, fdGeneration, ofdRefs, opOFD, opFd,
                    dirOffset, dirFd, dirCursor, epollInterests>>
    /\ FDFrame

\* The loop returns after at least one chunk.
\* litebox_shim_linux/src/syscalls/file.rs:650-688; lib.rs:535-543.
TaskChunkedReadFinish(t) ==
    \* Return publishes total progress but performs no identity recheck: file.rs:650-688.
    /\ pc[t] = "fd_chunk"
    /\ chunksDone[t] > 0
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<fdVars, fsVars, vmVars, cloneVars, futexVars>>

\* sys_close consumes the raw slot under the raw-descriptor write lock.
\* litebox_shim_linux/src/syscalls/file.rs:782-847,888-894; fd/mod.rs:683-691.
FilesStateCloseSlot(f) ==
    LET old == fdSlot[f] IN
    \* fd_consume_raw_integer takes the slot before typed close: fd/mod.rs:683-691.
    /\ f \in Fd
    /\ old /= NoOFD
    /\ fdGeneration[f] < MaxGeneration
    /\ fdSlot' = [fdSlot EXCEPT ![f] = NoOFD]
    /\ fdGeneration' = [fdGeneration EXCEPT ![f] = @ + 1]
    /\ ofdRefs' = [ofdRefs EXCEPT ![old] = @ - 1]
    /\ dirOffset' = [dirOffset EXCEPT ![f] = 0]
    /\ UNCHANGED <<pc, opOFD, opFd, lastChunkOFD, chunksDone,
                    dirFd, dirCursor, epollInterests>>
    /\ FDFrame

\* A later open/dup can occupy the now-empty integer slot with another OFD.
\* litebox/src/fd/mod.rs:627-664; syscalls/file.rs:112-135.
FilesStateReuseSlot(f, o) ==
    \* fd_into_specific_raw_integer publishes exactly one typed fd in the slot: fd/mod.rs:640-663.
    /\ f \in Fd
    /\ o \in OFD
    /\ fdSlot[f] = NoOFD
    /\ fdGeneration[f] < MaxGeneration
    /\ fdSlot' = [fdSlot EXCEPT ![f] = o]
    /\ fdGeneration' = [fdGeneration EXCEPT ![f] = @ + 1]
    /\ ofdRefs' = [ofdRefs EXCEPT ![o] = @ + 1]
    /\ dirOffset' = [dirOffset EXCEPT ![f] = 0]
    /\ UNCHANGED <<pc, opOFD, opFd, lastChunkOFD, chunksDone,
                    dirFd, dirCursor, epollInterests>>
    /\ FDFrame

\* DescriptorTable::duplicate clones the shared entry but not fd-local metadata.
\* litebox/src/fd/mod.rs:70-105; shim file.rs:2452-2481.
DescriptorsDuplicate(source, target) ==
    LET shared == fdSlot[source] IN
    \* The typed duplicate shares its underlying entry: fd/mod.rs:84-104.
    /\ source \in Fd
    /\ target \in Fd \ {source}
    /\ shared /= NoOFD
    /\ fdSlot[target] = NoOFD
    /\ fdGeneration[target] < MaxGeneration
    \* Raw publication does not copy Diroff fd metadata: fd/mod.rs:73-76; file.rs:2460-2481.
    /\ fdSlot' = [fdSlot EXCEPT ![target] = shared]
    /\ fdGeneration' = [fdGeneration EXCEPT ![target] = @ + 1]
    /\ ofdRefs' = [ofdRefs EXCEPT ![shared] = @ + 1]
    /\ dirOffset' = [dirOffset EXCEPT ![target] = 0]
    /\ UNCHANGED <<pc, opOFD, opFd, lastChunkOFD, chunksDone,
                    dirFd, dirCursor, epollInterests>>
    /\ FDFrame

\* getdents64 loads fd-local Diroff before producing directory entries.
\* litebox_shim_linux/src/syscalls/file.rs:2571-2603.
TaskSysGetdirent64Load(t, f) ==
    \* with_metadata reads Diroff from the individual typed fd: file.rs:2592-2598.
    /\ pc[t] = "idle"
    /\ f \in Fd
    /\ fdSlot[f] /= NoOFD
    /\ dirFd' = [dirFd EXCEPT ![t] = f]
    /\ dirCursor' = [dirCursor EXCEPT ![t] = dirOffset[f]]
    /\ pc' = [pc EXCEPT ![t] = "dir_loaded"]
    /\ UNCHANGED <<fdSlot, fdGeneration, ofdRefs, opOFD, opFd,
                    lastChunkOFD, chunksDone, dirOffset, epollInterests>>
    /\ FDFrame

\* One successful entry production advances the local cursor.
\* litebox_shim_linux/src/syscalls/file.rs:2604-2643.
TaskSysGetdirent64Produce(t) ==
    \* dir_off increments once per emitted entry: file.rs:2604-2643.
    /\ pc[t] = "dir_loaded"
    /\ dirCursor[t] < MaxOffset
    /\ dirCursor' = [dirCursor EXCEPT ![t] = @ + 1]
    /\ pc' = [pc EXCEPT ![t] = "dir_produced"]
    /\ UNCHANGED <<fdSlot, fdGeneration, ofdRefs, opOFD, opFd,
                    lastChunkOFD, chunksDone, dirOffset, dirFd,
                    epollInterests>>
    /\ FDFrame

\* getdents64 stores the cursor back into only the individual fd metadata.
\* litebox_shim_linux/src/syscalls/file.rs:2644-2648.
TaskSysGetdirent64Store(t) ==
    \* set_fd_metadata updates the alias selected by dirFd only: file.rs:2644-2648.
    /\ pc[t] = "dir_produced"
    /\ fdSlot[dirFd[t]] /= NoOFD
    /\ dirOffset' = [dirOffset EXCEPT ![dirFd[t]] = dirCursor[t]]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<fdSlot, fdGeneration, ofdRefs, opOFD, opFd,
                    lastChunkOFD, chunksDone, dirFd, dirCursor,
                    epollInterests>>
    /\ FDFrame

\* EpollFile::add_interest keys an interest by raw fd and current Arc identity.
\* litebox_shim_linux/src/syscalls/epoll.rs:232-265,327-340.
EpollFileAddInterest(f) ==
    LET e == [fd |-> f, ofd |-> fdSlot[f]] IN
    \* try_from resolves the slot, then add_interest stores a Weak identity: epoll.rs:53-77,239-264.
    /\ f \in Fd
    /\ fdSlot[f] /= NoOFD
    /\ e \notin epollInterests
    /\ epollInterests' = epollInterests \cup {e}
    /\ UNCHANGED <<pc, fdSlot, fdGeneration, ofdRefs, opOFD, opFd,
                    lastChunkOFD, chunksDone, dirOffset, dirFd, dirCursor>>
    /\ FDFrame

(***************************************************************************)
(* Scenario 3: mapping generation versus stale auxiliary state.            *)
(***************************************************************************)

MappingWriter(a) ==
    \E t \in Thread : pc[t] = "vm_map_host" /\ localMapAddr[t] = a

\* File mmap first performs the host/platform mapping.
\* litebox_shim_linux/src/syscalls/mm.rs:121-128,167-245.
TaskDoMmapFileHost(t, a, p) ==
    \* The platform host operation is separate from Vmem publication: mm.rs:234-245.
    /\ pc[t] = "idle"
    /\ a \in MapAddr
    /\ p \in Perm
    /\ mapGeneration[a] < MaxGeneration
    /\ ~MappingWriter(a)
    /\ mapGeneration' = [mapGeneration EXCEPT ![a] = @ + 1]
    /\ hostMapped' = [hostMapped EXCEPT ![a] = TRUE]
    /\ hostGeneration' = [hostGeneration EXCEPT ![a] = mapGeneration[a] + 1]
    /\ hostPerm' = [hostPerm EXCEPT ![a] = p]
    /\ localMapAddr' = [localMapAddr EXCEPT ![t] = a]
    /\ localMapGeneration' = [localMapGeneration EXCEPT ![t] = mapGeneration[a] + 1]
    /\ localMapPerm' = [localMapPerm EXCEPT ![t] = p]
    /\ pc' = [pc EXCEPT ![t] = "vm_map_host"]
    /\ UNCHANGED <<vmemMapped, vmemGeneration, vmemPerm, patchIntervals,
                    planAddr, planGeneration, patchApplied,
                    patchAppliedPlanGeneration, patchAppliedHostGeneration>>
    /\ VMFrame

\* PageManager::register_existing_mapping publishes the host result into Vmem.
\* litebox_shim_linux/src/syscalls/mm.rs:246-261; litebox/src/mm/mod.rs:300-329.
PageManagerRegisterExistingMapping(t) ==
    LET a == localMapAddr[t] IN
    \* This is the commit after the platform operation: shim mm.rs:246-261.
    /\ pc[t] = "vm_map_host"
    /\ a \in MapAddr
    /\ hostMapped[a]
    /\ hostGeneration[a] = localMapGeneration[t]
    /\ vmemMapped' = [vmemMapped EXCEPT ![a] = TRUE]
    /\ vmemGeneration' = [vmemGeneration EXCEPT ![a] = localMapGeneration[t]]
    /\ vmemPerm' = [vmemPerm EXCEPT ![a] = localMapPerm[t]]
    \* Non-exec mappings are recorded for later patch collection: shim mm.rs:143-156.
    /\ patchIntervals' = [patchIntervals EXCEPT ![a] = localMapGeneration[t]]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<hostMapped, hostGeneration, hostPerm, mapGeneration,
                    localMapAddr, localMapGeneration, localMapPerm,
                    planAddr, planGeneration, patchApplied,
                    patchAppliedPlanGeneration, patchAppliedHostGeneration>>
    /\ VMFrame

\* sys_munmap removes the mapping, then clears every overlapping cache tuple.
\* litebox_shim_linux/src/syscalls/mm.rs:379-411; common_linux/src/mm.rs:100-121.
TaskSysMunmap(a) ==
    \* remove_pages unmaps the current host and Vmem range: common_linux mm.rs:112-120.
    /\ a \in MapAddr
    /\ hostMapped[a] \/ vmemMapped[a]
    /\ ~MappingWriter(a)
    /\ hostMapped' = [hostMapped EXCEPT ![a] = FALSE]
    /\ vmemMapped' = [vmemMapped EXCEPT ![a] = FALSE]
    \* Successful unmap deletes overlapping tracking tuples: shim mm.rs:381-410.
    /\ patchIntervals' = [patchIntervals EXCEPT ![a] = 0]
    /\ UNCHANGED <<pc, hostGeneration, hostPerm, vmemGeneration, vmemPerm,
                    mapGeneration, localMapAddr, localMapGeneration, localMapPerm,
                    planAddr, planGeneration, patchApplied,
                    patchAppliedPlanGeneration, patchAppliedHostGeneration>>
    /\ VMFrame

\* maybe_patch_on_mprotect_exec snapshots tuples and releases elf_patch_cache.
\* litebox_shim_linux/src/syscalls/mm.rs:482-508.
TaskMaybePatchOnMprotectExecCollect(t, a) ==
    \* Collection copies only fd/address/length, with no mapping generation: mm.rs:489-508.
    /\ pc[t] = "idle"
    /\ a \in MapAddr
    /\ patchIntervals[a] > 0
    /\ planAddr' = [planAddr EXCEPT ![t] = a]
    /\ planGeneration' = [planGeneration EXCEPT ![t] = patchIntervals[a]]
    /\ patchApplied' = [patchApplied EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "vm_plan_collected"]
    /\ UNCHANGED <<hostMapped, hostGeneration, hostPerm,
                    vmemMapped, vmemGeneration, vmemPerm,
                    patchIntervals, mapGeneration, localMapAddr,
                    localMapGeneration, localMapPerm,
                    patchAppliedPlanGeneration, patchAppliedHostGeneration>>
    /\ VMFrame

\* maybe_patch_exec_segment acts on the address snapshot without revalidation.
\* litebox_shim_linux/src/syscalls/mm.rs:522-535,768-789,930-969.
TaskMaybePatchExecSegmentApply(t) ==
    LET a == planAddr[t] IN
    \* The loop calls the patcher after the collection lock is gone: mm.rs:522-535.
    /\ pc[t] = "vm_plan_collected"
    /\ a \in MapAddr
    \* No generation/current-mapping guard precedes patching: mm.rs:768-789,930-969.
    /\ patchApplied' = [patchApplied EXCEPT ![t] = TRUE]
    /\ patchAppliedPlanGeneration' =
        [patchAppliedPlanGeneration EXCEPT ![t] = planGeneration[t]]
    /\ patchAppliedHostGeneration' =
        [patchAppliedHostGeneration EXCEPT
            ![t] = IF hostMapped[a] THEN hostGeneration[a] ELSE 0]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<hostMapped, hostGeneration, hostPerm,
                    vmemMapped, vmemGeneration, vmemPerm,
                    patchIntervals, mapGeneration, localMapAddr,
                    localMapGeneration, localMapPerm, planAddr, planGeneration>>
    /\ VMFrame

\* sys_mprotect_raw changes host and Vmem permissions under PageManager's Vmem lock.
\* shim mm.rs:414-441; litebox/src/mm/linux.rs:741-800.
TaskSysMprotectRaw(a, p) ==
    \* protect_mapping requires a live range and validates may-permissions: linux.rs:750-769.
    /\ a \in MapAddr
    /\ p \in Perm
    /\ hostMapped[a]
    /\ vmemMapped[a]
    \* update_permissions precedes Vmem reinsertion: linux.rs:771-800.
    /\ hostPerm' = [hostPerm EXCEPT ![a] = p]
    /\ vmemPerm' = [vmemPerm EXCEPT ![a] = p]
    /\ UNCHANGED <<pc, hostMapped, hostGeneration, vmemMapped,
                    vmemGeneration, patchIntervals, mapGeneration,
                    localMapAddr, localMapGeneration, localMapPerm,
                    planAddr, planGeneration, patchApplied,
                    patchAppliedPlanGeneration, patchAppliedHostGeneration>>
    /\ VMFrame

(***************************************************************************)
(* Scenario 4: clone publication and ownership transfer before commit.     *)
(***************************************************************************)

CloneInFlight ==
    \E t \in Thread :
        pc[t] \in {"clone_prepared", "clone_parent_published", "clone_stack_valid",
                   "clone_attached", "clone_transferred"}

\* do_clone completes flags/TLS validation and allocates a child tid.
\* litebox_shim_linux/src/syscalls/process.rs:568-685.
TaskDoClonePrepare(t, child) ==
    \* All flag, cgroup, set_tid, signal, and TLS checks precede allocation: process.rs:590-677.
    /\ pc[t] = "idle"
    /\ t \in committedThreads
    /\ child \in Thread \ {MainThread}
    /\ child \notin threads
    /\ child \notin {cloneChild[x] : x \in {u \in Thread : pc[u] /= "idle"}}
    \* next_thread_id allocation occurs before parent_tid publication: process.rs:679-685.
    /\ cloneChild' = [cloneChild EXCEPT ![t] = child]
    /\ parentTid' = [parentTid EXCEPT ![t] = NoThread]
    /\ spawnResult' = [spawnResult EXCEPT ![t] = "none"]
    /\ pc' = [pc EXCEPT ![t] = "clone_prepared"]
    /\ UNCHANGED <<threads, committedThreads, threadCount, initOwner>>
    /\ CloneFrame

\* PARENT_SETTID writes caller memory before clone3 stack validation.
\* litebox_shim_linux/src/syscalls/process.rs:685-697.
TaskDoClonePublishParentTid(t) ==
    \* parent_tid is written immediately after tid allocation: process.rs:685-688.
    /\ pc[t] = "clone_prepared"
    /\ parentTid' = [parentTid EXCEPT ![t] = cloneChild[t]]
    /\ pc' = [pc EXCEPT ![t] = "clone_parent_published"]
    /\ UNCHANGED <<threads, committedThreads, threadCount, initOwner,
                    spawnResult, cloneChild>>
    /\ CloneFrame

\* Valid clone3 stack combinations proceed to process attachment.
\* litebox_shim_linux/src/syscalls/process.rs:690-700.
TaskDoCloneStackValidationSuccess(t) ==
    \* Stack validation and SP calculation are distinct from publication: process.rs:690-698.
    /\ pc[t] = "clone_parent_published"
    /\ pc' = [pc EXCEPT ![t] = "clone_stack_valid"]
    /\ UNCHANGED <<cloneVars, fsVars, fdVars, vmVars, futexVars>>

\* Invalid clone3 stack combinations return after parent_tid was already written.
\* litebox_shim_linux/src/syscalls/process.rs:685-692.
TaskDoCloneStackValidationFailure(t) ==
    \* EINVAL returns without undoing the write at lines 685-688: process.rs:690-692.
    /\ pc[t] = "clone_parent_published"
    /\ spawnResult' = [spawnResult EXCEPT ![t] = "failure"]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<threads, committedThreads, threadCount, parentTid,
                    initOwner, cloneChild>>
    /\ CloneFrame

\* ThreadState::new_thread attaches before platform spawn.
\* litebox_shim_linux/src/syscalls/process.rs:66-75,207-218,700-706.
ThreadStateNewThread(t) ==
    LET child == cloneChild[t] IN
    \* attach_thread inserts under process.inner and increments nr_threads: process.rs:207-218.
    /\ pc[t] = "clone_stack_valid"
    /\ child \in Thread \ threads
    /\ threads' = threads \cup {child}
    /\ threadCount' = threadCount + 1
    \* The NewThreadArgs box initially owns the attached ThreadState: process.rs:700-725.
    /\ initOwner' = [initOwner EXCEPT ![child] = "caller"]
    /\ pc' = [pc EXCEPT ![t] = "clone_attached"]
    /\ UNCHANGED <<committedThreads, parentTid, spawnResult, cloneChild>>
    /\ CloneFrame

\* Calling ThreadProvider::spawn_thread transfers the InitThread box to the platform.
\* litebox_shim_linux/src/syscalls/process.rs:708-727; platform/mod.rs:42-57.
TaskDoCloneTransferInit(t) ==
    LET child == cloneChild[t] IN
    \* Box<NewThreadArgs> moves into spawn_thread before the fallible call: process.rs:708-727.
    /\ pc[t] = "clone_attached"
    /\ initOwner[child] = "caller"
    /\ initOwner' = [initOwner EXCEPT ![child] = "platform"]
    /\ pc' = [pc EXCEPT ![t] = "clone_transferred"]
    /\ UNCHANGED <<threads, committedThreads, threadCount, parentTid,
                    spawnResult, cloneChild>>
    /\ CloneFrame

\* Successful SNP clone transfers the raw pointer to the child callback.
\* litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:250-275,151-162.
SnpLinuxKernelSpawnThreadSuccess(t) ==
    LET child == cloneChild[t] IN
    \* Host syscall success makes thread_start the new owner: snp_impl.rs:268-275,151-162.
    /\ pc[t] = "clone_transferred"
    /\ initOwner[child] = "platform"
    /\ initOwner' = [initOwner EXCEPT ![child] = "child"]
    /\ committedThreads' = committedThreads \cup {child}
    /\ spawnResult' = [spawnResult EXCEPT ![t] = "success"]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<threads, threadCount, parentTid, cloneChild>>
    /\ CloneFrame

\* SNP converts the box to a raw pointer before a fallible host syscall and has no error reclaim.
\* litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:264-275; process.rs:728-733.
SnpLinuxKernelSpawnThreadFailure(t) ==
    \* Box::into_raw precedes `HostSnpInterface::syscalls(...)?`: snp_impl.rs:264-274.
    /\ pc[t] = "clone_transferred"
    /\ initOwner[cloneChild[t]] = "platform"
    \* do_clone returns ENOMEM without detach or pointer reconstruction: process.rs:728-733.
    /\ spawnResult' = [spawnResult EXCEPT ![t] = "failure"]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<threads, committedThreads, threadCount, parentTid,
                    initOwner, cloneChild>>
    /\ CloneFrame

\* ThreadState::drop detaches a normally committed child.
\* litebox_shim_linux/src/syscalls/process.rs:78-88,221-249.
ProcessDetachThread(child) ==
    \* detach_thread removes the map entry and decrements nr_threads under the lock: process.rs:225-245.
    /\ child \in committedThreads \ {MainThread}
    /\ child \in threads
    /\ threads' = threads \ {child}
    /\ committedThreads' = committedThreads \ {child}
    /\ threadCount' = threadCount - 1
    /\ initOwner' = [initOwner EXCEPT ![child] = "none"]
    /\ UNCHANGED <<pc, parentTid, spawnResult, cloneChild>>
    /\ CloneFrame

(***************************************************************************)
(* Scenario 5: futex wake quota includes an unvalidated waiter.            *)
(***************************************************************************)

RemoveThread(s, t) == SelectSeq(s, LAMBDA x : x /= t)

\* FutexManager::wait inserts before reading the futex word.
\* litebox/src/sync/futex.rs:83-110; utilities/loan_list.rs:92-104.
FutexManagerWaitInsert(t, expected) ==
    \* LoanList insertion makes the entry selectable: futex.rs:96-106.
    /\ pc[t] = "idle"
    /\ waiterPhase[t] = "idle"
    /\ expected \in 0..1
    /\ waiterExpected' = [waiterExpected EXCEPT ![t] = expected]
    /\ waiterPhase' = [waiterPhase EXCEPT ![t] = "inserted_unvalidated"]
    /\ waitQueue' = Append(waitQueue, t)
    /\ UNCHANGED <<pc, futexValue, wakeBudget, selected, wakeCount,
                    wakeReturn, wakeHadUnvalidated>>
    /\ FutexFrame

\* The post-insertion value read validates a real waiter.
\* litebox/src/sync/futex.rs:108-118.
FutexManagerWaitCompareMatch(t) ==
    \* A matching word transitions to the blocking wait: futex.rs:108-118.
    /\ waiterPhase[t] \in
        {"inserted_unvalidated", "selected_unvalidated", "woken_unvalidated"}
    /\ futexValue = waiterExpected[t]
    /\ waiterPhase' =
        [waiterPhase EXCEPT
            ![t] = CASE @ = "inserted_unvalidated" -> "validated_waiting"
                      [] @ = "selected_unvalidated" -> "selected_validated"
                      [] OTHER -> "woken"]
    /\ UNCHANGED <<pc, futexValue, waiterExpected, waitQueue, wakeBudget,
                    selected, wakeCount, wakeReturn, wakeHadUnvalidated>>
    /\ FutexFrame

\* A mismatching word returns immediately and drops/removes the loan-list entry.
\* litebox/src/sync/futex.rs:108-113; utilities/loan_list.rs:129-134,153-180.
FutexManagerWaitCompareMismatch(t) ==
    \* Mismatch can race with selection because insertion preceded this read: futex.rs:104-113.
    /\ waiterPhase[t] \in
        {"inserted_unvalidated", "selected_unvalidated", "woken_unvalidated"}
    /\ futexValue /= waiterExpected[t]
    /\ waiterPhase' = [waiterPhase EXCEPT ![t] = "mismatch"]
    /\ waitQueue' = RemoveThread(waitQueue, t)
    /\ UNCHANGED <<pc, futexValue, waiterExpected, wakeBudget, selected,
                    wakeCount, wakeReturn, wakeHadUnvalidated>>
    /\ FutexFrame

\* FutexManager::wake starts one quota-limited extraction under the bucket lock.
\* litebox/src/sync/futex.rs:135-159.
FutexManagerWakeBegin(w) ==
    \* A wake request establishes its budget before list traversal: futex.rs:135-149.
    /\ pc[w] = "idle"
    /\ waiterPhase[w] = "idle"
    /\ ~ \E t \in Thread : pc[t] \in {"futex_waking", "futex_selected"}
    /\ wakeBudget' = [wakeBudget EXCEPT ![w] = 1]
    /\ wakeCount' = [wakeCount EXCEPT ![w] = 0]
    /\ wakeReturn' = [wakeReturn EXCEPT ![w] = 0]
    /\ wakeHadUnvalidated' = [wakeHadUnvalidated EXCEPT ![w] = FALSE]
    /\ selected' = {}
    /\ pc' = [pc EXCEPT ![w] = "futex_waking"]
    /\ UNCHANGED <<waiterPhase, futexValue, waiterExpected, waitQueue>>
    /\ FutexFrame

\* extract_if selects in queue order based only on address/bitset, not validation.
\* litebox/src/sync/futex.rs:145-159; utilities/loan_list.rs:251-285.
FutexManagerWakeSelect(w) ==
    LET q == Head(waitQueue) IN
    \* The first matching inserted entry consumes quota: futex.rs:149-158.
    /\ pc[w] = "futex_waking"
    /\ waitQueue /= <<>>
    /\ wakeCount[w] < wakeBudget[w]
    /\ waiterPhase[q] \in {"inserted_unvalidated", "validated_waiting"}
    /\ waitQueue' = Tail(waitQueue)
    /\ selected' = selected \cup {q}
    /\ waiterPhase' =
        [waiterPhase EXCEPT
            ![q] = IF @ = "inserted_unvalidated"
                    THEN "selected_unvalidated"
                    ELSE "selected_validated"]
    /\ wakeCount' = [wakeCount EXCEPT ![w] = @ + 1]
    /\ wakeHadUnvalidated' =
        [wakeHadUnvalidated EXCEPT
            ![w] = @ \/ waiterPhase[q] = "inserted_unvalidated"]
    /\ pc' =
        [pc EXCEPT
            ![w] = IF wakeCount[w] + 1 >= wakeBudget[w]
                    THEN "futex_selected"
                    ELSE "futex_waking"]
    /\ UNCHANGED <<futexValue, waiterExpected, wakeBudget, wakeReturn>>
    /\ FutexFrame

\* wake stores done and calls each waker after releasing the list lock.
\* litebox/src/sync/futex.rs:160-166.
FutexManagerWakeComplete(w) ==
    \* Completion begins after quota or queue exhaustion: futex.rs:153-165.
    /\ pc[w] = "futex_selected" \/ (pc[w] = "futex_waking" /\ waitQueue = <<>>)
    /\ waiterPhase' =
        [t \in Thread |->
            IF t \notin selected THEN waiterPhase[t]
            ELSE CASE waiterPhase[t] = "selected_validated" -> "woken"
                   [] waiterPhase[t] = "selected_unvalidated" -> "woken_unvalidated"
                   [] OTHER -> waiterPhase[t]]
    \* Return value is the number selected, regardless of later mismatch: futex.rs:153-166.
    /\ wakeReturn' = [wakeReturn EXCEPT ![w] = wakeCount[w]]
    /\ selected' = {}
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<futexValue, waiterExpected, waitQueue, wakeBudget,
                    wakeCount, wakeHadUnvalidated>>
    /\ FutexFrame

\* A woken or mismatching wait call returns and destroys its stack entry.
\* litebox/src/sync/futex.rs:108-119; utilities/loan_list.rs:129-134.
FutexManagerWaitReturn(t) ==
    \* Both normal wake and immediate mismatch leave wait(): futex.rs:111-119.
    /\ waiterPhase[t] \in {"woken", "mismatch"}
    /\ waiterPhase' = [waiterPhase EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<pc, futexValue, waiterExpected, waitQueue, wakeBudget,
                    selected, wakeCount, wakeReturn, wakeHadUnvalidated>>
    /\ FutexFrame

\* Guest/user code may change the futex word between insertion and comparison.
\* litebox/src/sync/futex.rs:108-110 (the modeled read site).
FutexSetValue(v) ==
    \* This environment step supplies the value later read by wait: futex.rs:108-110.
    /\ v \in 0..1
    /\ v /= futexValue
    /\ futexValue' = v
    /\ UNCHANGED <<pc, waiterPhase, waiterExpected, waitQueue, wakeBudget,
                    selected, wakeCount, wakeReturn, wakeHadUnvalidated>>
    /\ FutexFrame

(***************************************************************************)
(* Invariants.                                                             *)
(***************************************************************************)

TypeOK ==
    /\ pc \in [Thread -> PCState]
    /\ namespace \in [Path -> Node \cup {NoNode}]
    /\ nodeAlive \in [Node -> BOOLEAN]
    /\ nodeParent \in [Node -> Node \cup {NoNode}]
    /\ walkedParent \in [Thread -> Node \cup {NoNode}]
    /\ walkedPath \in [Thread -> Path \cup {NoPath}]
    /\ cwdNode \in [Thread -> Node]
    /\ cwdPath \in [Thread -> Path]
    /\ cwdCandidate \in [Thread -> Node \cup {NoNode}]
    /\ createResult \in [Thread -> CreateResult]
    /\ createdNode \in [Thread -> Node \cup {NoNode}]
    /\ relativeLookupNode \in [Thread -> Node \cup {NoNode}]
    /\ fdSlot \in [Fd -> OFD \cup {NoOFD}]
    /\ fdGeneration \in [Fd -> 0..MaxGeneration]
    /\ ofdRefs \in [OFD -> 0..Cardinality(Fd)]
    /\ opOFD \in [Thread -> OFD \cup {NoOFD}]
    /\ opFd \in [Thread -> Fd \cup {NoFd}]
    /\ lastChunkOFD \in [Thread -> OFD \cup {NoOFD}]
    /\ chunksDone \in [Thread -> 0..MaxChunks]
    /\ dirOffset \in [Fd -> 0..MaxOffset]
    /\ dirFd \in [Thread -> Fd \cup {NoFd}]
    /\ dirCursor \in [Thread -> 0..MaxOffset]
    /\ epollInterests \subseteq EpollInterestType
    /\ hostMapped \in [MapAddr -> BOOLEAN]
    /\ hostGeneration \in [MapAddr -> 0..MaxGeneration]
    /\ hostPerm \in [MapAddr -> Perm]
    /\ vmemMapped \in [MapAddr -> BOOLEAN]
    /\ vmemGeneration \in [MapAddr -> 0..MaxGeneration]
    /\ vmemPerm \in [MapAddr -> Perm]
    /\ patchIntervals \in [MapAddr -> 0..MaxGeneration]
    /\ mapGeneration \in [MapAddr -> 0..MaxGeneration]
    /\ localMapAddr \in [Thread -> MapAddr \cup {NoAddr}]
    /\ localMapGeneration \in [Thread -> 0..MaxGeneration]
    /\ localMapPerm \in [Thread -> Perm]
    /\ planAddr \in [Thread -> MapAddr \cup {NoAddr}]
    /\ planGeneration \in [Thread -> 0..MaxGeneration]
    /\ patchApplied \in [Thread -> BOOLEAN]
    /\ patchAppliedPlanGeneration \in [Thread -> 0..MaxGeneration]
    /\ patchAppliedHostGeneration \in [Thread -> 0..MaxGeneration]
    /\ threads \subseteq Thread
    /\ committedThreads \subseteq Thread
    /\ threadCount \in 0..Cardinality(Thread)
    /\ parentTid \in [Thread -> Thread \cup {NoThread}]
    /\ initOwner \in [Thread -> InitOwner]
    /\ spawnResult \in [Thread -> SpawnResult]
    /\ cloneChild \in [Thread -> Thread \cup {NoThread}]
    /\ waiterPhase \in [Thread -> WaiterPhase]
    /\ futexValue \in 0..1
    /\ waiterExpected \in [Thread -> 0..1]
    /\ waitQueue \in Seq(Thread)
    /\ wakeBudget \in [Thread -> 0..1]
    /\ selected \subseteq Thread
    /\ wakeCount \in [Thread -> 0..1]
    /\ wakeReturn \in [Thread -> 0..1]
    /\ wakeHadUnvalidated \in [Thread -> BOOLEAN]

\* Standard safety for nodes that are currently linked into the namespace.
\* Unlinked objects can remain allocated through stale Arc handles.
NamespaceIsATree ==
    /\ nodeAlive[RootNode]
    /\ nodeParent[RootNode] = NoNode
    /\ \A p \in Path :
        LET n == namespace[p] IN
        n /= NoNode =>
            /\ nodeAlive[n]
            /\ (n = RootNode \/
                /\ nodeParent[n] \in Node
                /\ \E parentPath \in Path : namespace[parentPath] = nodeParent[n])

\* Scenario 1: a reported successful create must remain linked through its walked parent.
ReachableCreate ==
    \A t \in Thread :
        createResult[t] = "success" =>
            /\ createdNode[t] \in Node
            /\ nodeAlive[createdNode[t]]
            /\ walkedParent[t] \in Node
            /\ nodeAlive[walkedParent[t]]
            /\ nodeParent[createdNode[t]] = walkedParent[t]

\* Scenario 1: relative lookup may fail after unlink, but must not rebind to another object.
CwdIdentityStable ==
    \A t \in Thread :
        relativeLookupNode[t] /= NoNode => relativeLookupNode[t] = cwdNode[t]

\* Standard descriptor structure: a slot function has one binding and its generation is bounded.
SingleBindingPerFdSlot ==
    \A f \in Fd :
        /\ fdSlot[f] \in OFD \cup {NoOFD}
        /\ fdGeneration[f] \in 0..MaxGeneration

OFDRefCountsCorrect ==
    \A o \in OFD : ofdRefs[o] = Cardinality({f \in Fd : fdSlot[f] = o})

\* Scenario 2: every completed chunk of one logical syscall uses its entry OFD.
OperationBindsOneOFD ==
    \A t \in Thread :
        lastChunkOFD[t] /= NoOFD => lastChunkOFD[t] = opOFD[t]

\* Scenario 2: aliases of one OFD expose one directory position.
AliasOffsetsShared ==
    \A f1, f2 \in Fd :
        fdSlot[f1] /= NoOFD /\ fdSlot[f1] = fdSlot[f2] => dirOffset[f1] = dirOffset[f2]

\* Scenario 2: the last-reference close must not leave a dead identity in epoll interests.
NoStaleEpollInterests ==
    \A e \in epollInterests : \E f \in Fd : fdSlot[f] = e.ofd

\* Standard mapping structure: abstract MapAddr values are disjoint single-page ranges.
MappingRangesDisjoint ==
    Cardinality({a \in MapAddr : vmemMapped[a]}) =
    Cardinality({<<a, vmemGeneration[a]>> : a \in {u \in MapAddr : vmemMapped[u]}})

\* Scenario 3: outside a real host-before-Vmem publication window, current records agree.
HostVmemAgreement ==
    \A a \in MapAddr :
        ~MappingWriter(a) =>
            /\ hostMapped[a] = vmemMapped[a]
            /\ (hostMapped[a] =>
                /\ hostGeneration[a] = vmemGeneration[a]
                /\ hostPerm[a] = vmemPerm[a])

\* Scenario 3: an applied plan must target the generation observed at collection.
NoStalePatchPlan ==
    \A t \in Thread :
        patchApplied[t] =>
            /\ patchAppliedHostGeneration[t] > 0
            /\ patchAppliedPlanGeneration[t] = patchAppliedHostGeneration[t]

\* Scenario 4: nr_threads always counts attachments, and settled attachments are committed.
ThreadCountMatchesAttachments ==
    /\ threadCount = Cardinality(threads)
    /\ (~CloneInFlight => threads = committedThreads)

\* Scenario 4: every failed clone is externally and internally atomic.
CloneFailureAtomic ==
    \A t \in Thread :
        spawnResult[t] = "failure" =>
            /\ parentTid[t] = NoThread
            /\ (cloneChild[t] = NoThread \/ cloneChild[t] \notin threads)
            /\ (cloneChild[t] = NoThread \/ initOwner[cloneChild[t]] \in {"none", "caller"})

\* Structural queue invariant used during spec convergence.
WaitQueueDistinct ==
    Cardinality({waitQueue[i] : i \in 1..Len(waitQueue)}) = Len(waitQueue)

\* Scenario 5: selecting before validation is harmful when the selected waiter
\* later mismatches and the spent quota leaves a validated waiter blocked.
WakeCountsValidatedWaiters ==
    \A w \in Thread :
        wakeReturn[w] > 0 /\ wakeHadUnvalidated[w] =>
            ~(/\ \E bad \in Thread : waiterPhase[bad] = "mismatch"
              /\ \E good \in Thread : waiterPhase[good] = "validated_waiting")

\* Scenario 5 liveness: a selected validated waiter eventually leaves selection.
ValidWaiterEventuallyReturns ==
    \A t \in Thread :
        (waiterPhase[t] = "selected_validated") ~>
        (waiterPhase[t] \in {"woken", "idle"})

(***************************************************************************)
(* Next preserves every implementation-level semantic boundary above.     *)
(***************************************************************************)

Next ==
    \/ \E t \in Thread, p \in Path : ResolverParentDirAndName(t, p)
    \/ \E p \in Path : InMemRmdirAt(p)
    \/ \E p \in Path, n \in Node : InMemRecreateAt(p, n)
    \/ \E t \in Thread, n \in Node : InMemCreateFileAt(t, n)
    \/ \E t \in Thread, p \in Path : TaskSysChdirValidate(t, p)
    \/ \E t \in Thread : TaskSysChdirPublish(t)
    \/ \E t \in Thread : TaskResolvePathRelative(t)
    \/ \E t \in Thread, f \in Fd : TaskChunkedReadBegin(t, f)
    \/ \E t \in Thread : TaskChunkedReadChunk(t)
    \/ \E t \in Thread : TaskChunkedReadFinish(t)
    \/ \E f \in Fd : FilesStateCloseSlot(f)
    \/ \E f \in Fd, o \in OFD : FilesStateReuseSlot(f, o)
    \/ \E source, target \in Fd : DescriptorsDuplicate(source, target)
    \/ \E t \in Thread, f \in Fd : TaskSysGetdirent64Load(t, f)
    \/ \E t \in Thread : TaskSysGetdirent64Produce(t)
    \/ \E t \in Thread : TaskSysGetdirent64Store(t)
    \/ \E f \in Fd : EpollFileAddInterest(f)
    \/ \E t \in Thread, a \in MapAddr, p \in Perm : TaskDoMmapFileHost(t, a, p)
    \/ \E t \in Thread : PageManagerRegisterExistingMapping(t)
    \/ \E a \in MapAddr : TaskSysMunmap(a)
    \/ \E t \in Thread, a \in MapAddr : TaskMaybePatchOnMprotectExecCollect(t, a)
    \/ \E t \in Thread : TaskMaybePatchExecSegmentApply(t)
    \/ \E a \in MapAddr, p \in Perm : TaskSysMprotectRaw(a, p)
    \/ \E t, child \in Thread : TaskDoClonePrepare(t, child)
    \/ \E t \in Thread : TaskDoClonePublishParentTid(t)
    \/ \E t \in Thread : TaskDoCloneStackValidationSuccess(t)
    \/ \E t \in Thread : TaskDoCloneStackValidationFailure(t)
    \/ \E t \in Thread : ThreadStateNewThread(t)
    \/ \E t \in Thread : TaskDoCloneTransferInit(t)
    \/ \E t \in Thread : SnpLinuxKernelSpawnThreadSuccess(t)
    \/ \E t \in Thread : SnpLinuxKernelSpawnThreadFailure(t)
    \/ \E child \in Thread : ProcessDetachThread(child)
    \/ \E t \in Thread, expected \in 0..1 : FutexManagerWaitInsert(t, expected)
    \/ \E t \in Thread : FutexManagerWaitCompareMatch(t)
    \/ \E t \in Thread : FutexManagerWaitCompareMismatch(t)
    \/ \E w \in Thread : FutexManagerWakeBegin(w)
    \/ \E w \in Thread : FutexManagerWakeSelect(w)
    \/ \E w \in Thread : FutexManagerWakeComplete(w)
    \/ \E t \in Thread : FutexManagerWaitReturn(t)
    \/ \E v \in 0..1 : FutexSetValue(v)

Spec == Init /\ [][Next]_vars

====
