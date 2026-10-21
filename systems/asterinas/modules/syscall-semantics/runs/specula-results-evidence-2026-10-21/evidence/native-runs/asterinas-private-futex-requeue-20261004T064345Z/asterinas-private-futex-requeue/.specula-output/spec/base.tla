------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

(***************************************************************************
Category B. Asterinas 0c60537098f4c2949ad2d382aaf499de72263d76.
Source aliases used on every action block:
 F = kernel/core/src/process/posix_thread/futex.rs
 S = kernel/core/src/syscall/futex.rs
 P = kernel/core/src/process/signal/pause.rs
 W = ostd/src/sync/wait.rs
 Q = ostd/src/task/scheduler/mod.rs
 T = kernel/core/src/time/core/timer.rs
 TW = kernel/core/src/time/wait.rs
 L = pinned Linux v6.16.5 kernel/futex/ (reference oracle only).
One stable VMAR, match-any bitsets, aligned mapped words, no signals.
Keys are private identities, not hashes. BucketOf is an explicit collision map.
Finite generation sets bound admission, never completion of admitted work.
***************************************************************************)
CONSTANTS WaitIds, CallIds, Controllers, Keys, Buckets, BucketOf,
          Values, Quotas, Durations, InitialWords
ASSUME /\ WaitIds /= {} /\ CallIds /= {} /\ Controllers /= {}
       /\ Keys /= {} /\ Buckets \subseteq Nat /\ Buckets /= {}
       /\ BucketOf \in [Keys -> Buckets]
       /\ InitialWords \in [Keys -> Values]
       /\ Quotas \subseteq 0..2147483647
       /\ WaitIds \subseteq (Nat \ {0}) /\ CallIds \subseteq (Nat \ {0})
       /\ Durations \subseteq [timed: BOOLEAN, ticks: Nat]

VARIABLE s
vars == <<s>>
No == "none"
NoOwner == <<"none", 0>>
LocalOwner == <<"local", 0>>
NoId == 0
Never == [timed |-> FALSE, ticks |-> 0]
After(n) == [timed |-> TRUE, ticks |-> n]
DefaultDurations == {Never, After(0), After(1)}
WOwner(g) == <<"wait", g>>
COwner(c) == <<"call", c>>
BOwner(b) == <<"bucket", b>>
XOwner(c) == <<"transfer", c>>
SeqSet(q) == {q[i] : i \in 1..Len(q)}
Min(a,b) == IF a < b THEN a ELSE b
Max(a,b) == IF a > b THEN a ELSE b
DeleteAt(q,i) == SubSeq(q,1,i-1) \o SubSeq(q,i+1,Len(q))
SwapRemove(q,i) == IF i = Len(q) THEN SubSeq(q,1,i-1)
                   ELSE [j \in 1..(Len(q)-1) |-> IF j=i THEN q[Len(q)] ELSE q[j]]
Pos(q,g) == CHOOSE i \in 1..Len(q) : q[i]=g
DefaultKey == CHOOSE k \in Keys : TRUE
DefaultBucket == BucketOf[DefaultKey]
DefaultBucketMap == [k \in Keys |-> IF k="B" THEN 2 ELSE 1]
DefaultWords == [k \in Keys |-> 0]

\* S:81-83; F:78-80; W:181-189. Scenario 1 registration locals.
EmptyWait == [pc |-> "idle", key |-> DefaultKey, original |-> DefaultBucket,
    expected |-> InitialWords[DefaultKey], observed |-> InitialWords[DefaultKey],
    duration |-> Never, hasWoken |-> FALSE, closed |-> FALSE,
    pause |-> No, result |-> No, cleanup |-> No, returns |-> 0,
    notified |-> FALSE, futexAccepted |-> FALSE, noise |-> 0, sample |-> 0]
\* F:473-482,500-533. Scenarios 3/4 distinguish queue and extracted ownership.
EmptyEntry == [key |-> DefaultKey, owner |-> NoOwner, registered |-> 0,
               removals |-> 0, lastKey |-> DefaultKey]
\* P:172-208; T:64-112,198-281. Scenario 3 callback references are explicit.
EmptyTimer == [state |-> "none", deadline |-> 0, localRef |-> FALSE,
    cb |-> "idle", cbRef |-> FALSE, lock |-> "free", cancelled |-> FALSE,
    accepted |-> FALSE]
\* F:366-381,398-427,485-533. Scenario 2 locals and scenario 4 observers.
EmptyCall == [pc |-> "idle", actor |-> <<>>,
    kind |-> "wake", src |-> DefaultKey, dst |-> DefaultKey,
    rawWake |-> 0, rawMove |-> 0, effective |-> 1,
    index |-> 1, temp |-> NoId, accepted |-> FALSE,
    wakes |-> 0, moves |-> 0, processed |-> 0, result |-> -1,
    woke |-> {}, moved |-> {}, cohort |-> {},
    noise |-> [g \in WaitIds |-> 0], liveViolation |-> FALSE,
    identityOK |-> TRUE, acceptedClosed |-> FALSE]

\* F:384-475; W:181-189. Start with no registrations and no active calls.
Init == s = [word |-> InitialWords, now |-> 0,
    w |-> [g \in WaitIds |-> EmptyWait], e |-> [g \in WaitIds |-> EmptyEntry],
    tm |-> [g \in WaitIds |-> EmptyTimer],
    q |-> [b \in Buckets |-> <<>>], locks |-> [b \in Buckets |-> NoOwner],
    op |-> [c \in CallIds |-> EmptyCall],
    actor |-> [a \in Controllers |-> NoId], stores |-> 0,
    collect |-> [active |-> FALSE, sample |-> 0, ready |-> <<>>],
    callbacks |-> [g \in WaitIds |-> <<>>]]

\* Harness environment, brief scenario 1. This is a user atomic store, not WAKE_OP.
UserStore(k,v) ==
    /\ k \in Keys /\ v \in Values
    /\ s' = [s EXCEPT !.word[k]=v, !.stores=@+1]

\* S:55-76,81-83; F:78-80,590-594. Relative duration is not frozen here.
SysFutexWait(g,k,v,d) ==
    /\ s.w[g].pc="idle" /\ k \in Keys /\ v \in Values /\ d \in Durations
    /\ s' = [s EXCEPT !.w[g]=[EmptyWait EXCEPT !.pc="lock", !.key=k,
         !.original=BucketOf[k], !.expected=v, !.duration=d],
         !.e[g]=[EmptyEntry EXCEPT !.key=k, !.lastKey=k, !.owner=LocalOwner]]

\* F:83-88. The lock spans load, comparison, and publication.
FutexWaitLock(g) ==
    /\ s.w[g].pc="lock" /\ s.locks[s.w[g].original]=NoOwner
    /\ s'=[s EXCEPT !.locks[s.w[g].original]=WOwner(g), !.w[g].pc="load"]

\* F:86-90. Snapshot the atomic load before comparison. A user store may interleave.
FutexWaitLoad(g) ==
    /\ s.w[g].pc="load"
    /\ s'=[s EXCEPT !.w[g].observed=s.word[s.w[g].key], !.w[g].pc="compare"]

\* F:86-104; process/posix_thread/thread_local.rs:102-135.
\* Only a recoverable mapped-page fault is admitted. Never remove the retry.
FutexWaitFault(g) ==
    /\ s.w[g].pc="load"
    /\ s'=[s EXCEPT !.w[g].pc="faultUnlock"]
\* F:93.
FutexWaitFaultUnlock(g) ==
    /\ s.w[g].pc="faultUnlock"
    /\ s'=[s EXCEPT !.locks[s.w[g].original]=NoOwner, !.w[g].pc="resolve"]
\* F:95-104.
HandlePageFault(g) ==
    /\ s.w[g].pc="resolve"
    /\ s'=[s EXCEPT !.w[g].pc="lock"]

\* F:107-114. Branches preserve the loaded value even if userspace stores again.
FutexWaitCompare(g) ==
    /\ s.w[g].pc="compare"
    /\ s'=[s EXCEPT !.w[g].pc=IF s.w[g].observed=s.w[g].expected
             THEN "enqueue" ELSE "mismatchUnlock",
         !.w[g].result=IF s.w[g].observed=s.w[g].expected THEN No ELSE "EAGAIN"]
\* F:107-112.
FutexWaitMismatchUnlock(g) ==
    /\ s.w[g].pc="mismatchUnlock"
    /\ s'=[s EXCEPT !.locks[s.w[g].original]=NoOwner, !.w[g].pc="close",
                    !.e[g].owner=NoOwner]

\* F:114,473-475. Registration is an append under the original bucket lock.
FutexBucketAddItem(g) ==
    /\ s.w[g].pc="enqueue"
    /\ s'=[s EXCEPT !.q[s.w[g].original]=Append(@,g),
         !.e[g].owner=BOwner(s.w[g].original), !.e[g].registered=@+1,
         !.w[g].pc="unlock"]
\* F:116-119. A pending wake survives the interval before waiter.wait().
FutexWaitUnlock(g) ==
    /\ s.w[g].pc="unlock"
    /\ s'=[s EXCEPT !.locks[s.w[g].original]=NoOwner, !.w[g].pc="pauseCheck"]

\* P:171-177; TW:72-79; T:178-184. After(0) expires without creating a timer.
PauseTimeoutCheck(g) ==
    /\ s.w[g].pc="pauseCheck"
    /\ IF s.w[g].duration=After(0)
       THEN s'=[s EXCEPT !.w[g].pc="cleanupLock", !.w[g].pause="ETIME",
                 !.w[g].noise=@+1, !.tm[g].deadline=s.now, !.tm[g].state="expired"]
       ELSE s'=[s EXCEPT !.w[g].pc=IF ~s.w[g].duration.timed THEN "wait" ELSE "armRead"]

\* P:172-176; TW:160-166; T:64-82. WAIT passes After(d), so start at arming time.
TimerSetClock(g,t) ==
    /\ s.w[g].pc="armRead" /\ t \in Nat /\ t>=s.now
    /\ s'=[s EXCEPT !.now=t, !.w[g].sample=t, !.w[g].pc="arm"]

\* T:67-68,188-192. Publication uses the saved read and takes the heap lock.
TimerSetTimeout(g) ==
    /\ s.w[g].pc="arm" /\ ~s.collect.active
    /\ s'=[s EXCEPT !.tm[g].state="armed", !.tm[g].deadline=s.w[g].sample+s.w[g].duration.ticks,
         !.tm[g].localRef=TRUE, !.w[g].pc="wait"]

\* W:273-274. Swap and scheduler parking are separate visibility boundaries.
WakerDoWait(g) ==
    /\ s.w[g].pc="wait"
    /\ s'=[s EXCEPT !.w[g].hasWoken=FALSE,
         !.w[g].pc=IF s.w[g].hasWoken THEN "inspect" ELSE "park"]
\* W:274. The scheduler closure rechecks the flag before blocking.
WaiterPark(g) ==
    /\ s.w[g].pc="park"
    /\ s'=[s EXCEPT !.w[g].pc=IF s.w[g].hasWoken THEN "wait" ELSE "sleep"]

\* Q:441-444; W:272-275. Returning from park does not perform a Waker swap.
WaiterSpuriousReturn(g) ==
    /\ s.w[g].pc="sleep"
    /\ s'=[s EXCEPT !.w[g].pc="wait"]

\* P:202-204. The remain check and cancellation hold the same timer lock.
PauseTimeoutTimerLock(g) ==
    /\ s.w[g].pc="inspect" /\ s.tm[g].localRef /\ s.tm[g].lock="free"
    /\ s'=[s EXCEPT !.tm[g].lock="waiter", !.w[g].pc="remainRead"]
\* P:202-221. No timer and no signals yields Ok(()).
PauseTimeoutNoTimer(g) ==
    /\ s.w[g].pc="inspect" /\ ~s.tm[g].localRef
    /\ s'=[s EXCEPT !.w[g].pause="OK", !.w[g].pc="cleanupLock"]
\* P:204-208; T:94-112. A zero remaining duration wins this pause result.
PauseTimeoutClock(g,t) ==
    /\ s.w[g].pc="remainRead" /\ t \in Nat /\ t>=s.now
    /\ s'=[s EXCEPT !.now=t, !.w[g].sample=t, !.w[g].pc="remain"]

\* T:106-112. A later clock read elsewhere cannot change this local decision.
PauseTimeoutRemain(g) ==
    /\ s.w[g].pc="remain"
    /\ s'=[s EXCEPT !.w[g].pc=IF s.w[g].sample>=s.tm[g].deadline THEN "timerUnlock" ELSE "cancel",
         !.w[g].pause=IF s.w[g].sample>=s.tm[g].deadline THEN "ETIME" ELSE "OK"]
\* P:207-208; T:87-90,253-255. A callback waiting for the lock observes cancellation.
TimerCancel(g) ==
    /\ s.w[g].pc="cancel" /\ s.tm[g].lock="waiter"
    /\ s'=[s EXCEPT !.tm[g].cancelled=TRUE, !.tm[g].state="cancelled",
                    !.w[g].pc="timerUnlock"]
\* P:202-221. Drop the guard separately from the last local Arc<Timer>.
PauseTimeoutTimerUnlock(g) ==
    /\ s.w[g].pc="timerUnlock"
    /\ s'=[s EXCEPT !.tm[g].lock="free", !.w[g].pc="timerDrop"]
\* P:202-221.
PauseTimeoutTimerDrop(g) ==
    /\ s.w[g].pc="timerDrop"
    /\ s'=[s EXCEPT !.tm[g].localRef=FALSE, !.w[g].pc="cleanupLock"]

\* Environment monotonic clock observation. Operation reads below retain locals.
\* Expiry delivery is reactive and is never quota-limited.
ClockAdvance(t) ==
    /\ t \in Nat /\ t>=s.now
    /\ s'=[s EXCEPT !.now=t]
PendingTimers == {g \in WaitIds : s.tm[g].cb="idle" /\ s.tm[g].state \in {"armed","cancelled"}}
\* T:207-215,253-255,299-304. Cancellation leaves the heap deadline unchanged.
HeapHeads == {g \in PendingTimers : \A h \in PendingTimers : s.tm[g].deadline<=s.tm[h].deadline}
Collectible(g) == s.tm[g].cancelled \/ s.collect.sample>=s.tm[g].deadline
\* T:205,220-221. Each invocation owns its vector until it drains. Its first
\* generation names the slot, without bounding empty collection attempts.
CallbackBatch(g) == CHOOSE b \in WaitIds : g \in SeqSet(s.callbacks[b])
\* T:200-206. One heap-lock interval owns one current_time for the entire loop.
TimerCollectClock(t) ==
    /\ ~s.collect.active /\ PendingTimers/={} /\ t \in Nat /\ t>=s.now
    /\ s'=[s EXCEPT !.now=t, !.collect=[active |-> TRUE, sample |-> t, ready |-> <<>>]]
\* T:207-221. The collected callbacks become runnable only after heap release.
TimerCollectEnd ==
    /\ s.collect.active
    \* T:207-215. A future heap head ends the loop even with cancelled nodes later.
    /\ PendingTimers={} \/ \E g \in HeapHeads : ~Collectible(g)
    /\ s'=[s EXCEPT !.collect.active=FALSE,
         !.tm=[g \in WaitIds |-> IF s.tm[g].cb="collected"
              THEN [s.tm[g] EXCEPT !.cb="due"] ELSE s.tm[g]],
         !.callbacks=IF s.collect.ready= <<>> THEN @
              ELSE [@ EXCEPT ![Head(s.collect.ready)]=s.collect.ready]]
\* T:207-215,299-304. Every pop selects a heap head, including cancelled nodes.
\* Expiry uses this batch's current_time even after another CPU reads.
TimerCollect(g) ==
    /\ s.collect.active /\ g \in HeapHeads /\ Collectible(g)
    /\ s'=[s EXCEPT !.tm[g].cb=IF s.tm[g].cancelled THEN "done" ELSE "collected",
         !.collect.ready=IF s.tm[g].cancelled THEN @ ELSE Append(@,g),
         !.tm[g].state=IF s.tm[g].cancelled THEN "cancelled" ELSE "expired"]
\* T:220-221,262-265. Only the invocation's next callback may start. A failed
\* weak upgrade returns immediately, so that vector advances in this action.
TimerCallbackUpgrade(g) ==
    /\ s.tm[g].cb="due"
    /\ Head(s.callbacks[CallbackBatch(g)])=g
    /\ s'=[s EXCEPT !.tm[g].cb=IF s.tm[g].localRef THEN "ref" ELSE "done",
         !.tm[g].cbRef=s.tm[g].localRef,
         !.callbacks[CallbackBatch(g)]=IF s.tm[g].localRef THEN @ ELSE Tail(@)]
\* T:267-272. Strong callback reference can outlive pause_timeout's local timer.
TimerCallbackLock(g) ==
    /\ s.tm[g].cb="ref" /\ s.tm[g].lock="free"
    /\ s'=[s EXCEPT !.tm[g].lock="callback", !.tm[g].cb="check"]
\* T:269-272.
TimerCallbackCheck(g) ==
    /\ s.tm[g].cb="check"
    /\ s'=[s EXCEPT !.tm[g].cb=IF s.tm[g].cancelled THEN "finish" ELSE "wake"]
\* P:174-175; T:279-281; W:262-265. Acceptance depends on the atomic flag.
TimerCallbackWake(g) ==
    /\ s.tm[g].cb="wake"
    /\ s'=[s EXCEPT !.tm[g].accepted=~s.w[g].hasWoken,
         !.tm[g].cb=IF s.w[g].hasWoken THEN "finish" ELSE "unpark",
         !.w[g].hasWoken=TRUE, !.w[g].noise=@+1,
         !.w[g].notified=@ \/ ~s.w[g].hasWoken]
\* W:266. Consuming a flag before unpark is permitted.
TimerCallbackUnpark(g) ==
    /\ s.tm[g].cb="unpark"
    /\ s'=[s EXCEPT !.tm[g].cb="finish",
         !.w[g].pc=IF s.w[g].pc="sleep" THEN "wait" ELSE @]
\* T:220-221,262-281. Release the guard and strong reference before this
\* invocation can begin its next callback. Other invocations retain their vectors.
TimerCallbackFinish(g) ==
    /\ s.tm[g].cb="finish"
    /\ s'=[s EXCEPT !.tm[g].cb="done", !.tm[g].cbRef=FALSE, !.tm[g].lock="free",
         !.callbacks[CallbackBatch(g)]=Tail(@)]

\* F:124. Deliberately use saved original, even after cross-bucket migration.
FutexCleanupLock(g) ==
    /\ s.w[g].pc="cleanupLock" /\ s.locks[s.w[g].original]=NoOwner
    /\ s'=[s EXCEPT !.locks[s.w[g].original]=WOwner(g), !.w[g].pc="cleanup"]
\* F:477-482. Arc identity lookup and swap_remove, with no key comparison.
FutexRemoveByWaker(g) ==
    /\ s.w[g].pc="cleanup"
    /\ LET b == s.w[g].original
           found == g \in SeqSet(s.q[b])
       IN s'=[s EXCEPT !.q[b]=IF found THEN SwapRemove(@,Pos(@,g)) ELSE @,
           !.e[g].owner=IF found THEN NoOwner ELSE @,
           !.e[g].removals=IF found THEN @+1 ELSE @,
           !.w[g].cleanup=IF found THEN "found" ELSE "miss",
           !.w[g].pc="cleanupUnlock"]
\* F:124. The temporary bucket guard ends before the return decision.
FutexCleanupUnlock(g) ==
    /\ s.w[g].pc="cleanupUnlock"
    /\ s'=[s EXCEPT !.locks[s.w[g].original]=NoOwner, !.w[g].pc="decide"]
\* F:125-139; S:136-139. Keep even the unexpected EINTR branch visible.
FutexWaitDecide(g) ==
    /\ s.w[g].pc="decide"
    /\ s'=[s EXCEPT !.w[g].result=IF s.w[g].cleanup="miss" THEN "OK"
           ELSE IF s.w[g].pause="ETIME" THEN "ETIMEDOUT" ELSE "ERESTARTSYS",
         !.w[g].pc="close"]
\* W:244-248,278-281. Closure permanently sets the flag, not a second completion.
WaiterDrop(g) ==
    /\ s.w[g].pc="close"
    /\ s'=[s EXCEPT !.w[g].closed=TRUE, !.w[g].hasWoken=TRUE,
         !.w[g].noise=@+1, !.w[g].pc="return"]
\* S:81-83,136-143. One logical return per unique WAIT generation.
SysFutexWaitReturn(g) ==
    /\ s.w[g].pc="return"
    /\ s'=[s EXCEPT !.w[g].returns=@+1, !.w[g].pc="done"]

SourceBucket(c) == BucketOf[s.op[c].src]
DestBucket(c) == BucketOf[s.op[c].dst]
FirstBucket(c) == Min(SourceBucket(c),DestBucket(c))
SecondBucket(c) == Max(SourceBucket(c),DestBucket(c))
Live(g) == /\ s.e[g].registered=1 /\ s.e[g].removals=0
           /\ ~s.w[g].closed /\ ~s.w[g].hasWoken
           /\ s.w[g].pc \in {"pauseCheck","armRead","arm","wait","park","sleep"}
Eligible(c) == {g \in SeqSet(s.q[SourceBucket(c)]) : s.e[g].key=s.op[c].src /\ Live(g)}

\* S:97-117,146-150; F:353-366. Two actors can reuse distinct call generations.
SysFutexControl(c,a,kind,src,dst,nw,nm) ==
    /\ s.op[c].pc="idle" /\ s.actor[a]=NoId
    /\ kind \in {"wake","requeue"} /\ src \in Keys /\ dst \in Keys
    /\ nw \in Quotas /\ nm \in Quotas
    /\ s'=[s EXCEPT !.op[c]=[EmptyCall EXCEPT !.pc="lockFirst", !.actor= <<a>>,
         !.kind=kind, !.src=src, !.dst=IF kind="wake" THEN src ELSE dst,
         !.rawWake=nw, !.rawMove=nm, !.effective=Max(1,nw)], !.actor[a]=c]
\* F:398-427. Separate acquisitions retain the lower lock while waiting on higher.
LockBucketPairsFirst(c) ==
    /\ s.op[c].pc="lockFirst" /\ s.locks[FirstBucket(c)]=NoOwner
    /\ s'=[s EXCEPT !.locks[FirstBucket(c)]=COwner(c),
         !.op[c].pc=IF FirstBucket(c)=SecondBucket(c) THEN "snapshot" ELSE "lockSecond"]
LockBucketPairsSecond(c) ==
    /\ s.op[c].pc="lockSecond" /\ s.locks[SecondBucket(c)]=NoOwner
    /\ s'=[s EXCEPT !.locks[SecondBucket(c)]=COwner(c), !.op[c].pc="snapshot"]
\* F:368,485-488. Ghost cohort is captured immediately before the wake scan.
FutexWakeStart(c) ==
    /\ s.op[c].pc="snapshot"
    /\ s'=[s EXCEPT !.op[c].cohort=Eligible(c),
         !.op[c].noise=[g \in WaitIds |-> s.w[g].noise], !.op[c].pc="wakeScan"]

\* F:488-495; W:262-265. The atomic swap precedes unpark and retain removal.
FutexItemWake(c) ==
    /\ s.op[c].pc="wakeScan" /\ s.op[c].index<=Len(s.q[SourceBucket(c)])
    /\ LET g == s.q[SourceBucket(c)][s.op[c].index]
           attempt == s.e[g].key=s.op[c].src /\ s.op[c].wakes<s.op[c].effective
       IN IF attempt
          THEN s'=[s EXCEPT !.op[c].temp=g, !.op[c].accepted=~s.w[g].hasWoken,
              !.op[c].acceptedClosed=@ \/ (s.w[g].closed /\ ~s.w[g].hasWoken),
              !.op[c].identityOK=@ /\ s.e[g].key=s.op[c].src,
              !.op[c].pc=IF s.w[g].hasWoken THEN "wakeCommit" ELSE "unpark",
              !.w[g].hasWoken=TRUE, !.w[g].notified=@ \/ ~s.w[g].hasWoken,
              !.w[g].futexAccepted=@ \/ ~s.w[g].hasWoken]
          ELSE s'=[s EXCEPT !.op[c].index=@+1]
\* W:266-268. Bucket removal waits for wake_up to return, not waiter completion.
FutexWakeUnpark(c) ==
    /\ s.op[c].pc="unpark"
    /\ LET g==s.op[c].temp IN s'=[s EXCEPT
         !.w[g].pc=IF s.w[g].pc="sleep" THEN "wait" ELSE @, !.op[c].pc="wakeCommit"]
\* F:489-495. Rejected wakes retain the entry and do not consume quota.
FutexWakeRetain(c) ==
    /\ s.op[c].pc="wakeCommit"
    /\ LET g==s.op[c].temp b==SourceBucket(c) ok==s.op[c].accepted
       IN s'=[s EXCEPT !.q[b]=IF ok THEN DeleteAt(@,s.op[c].index) ELSE @,
           !.e[g].owner=IF ok THEN NoOwner ELSE @, !.e[g].removals=IF ok THEN @+1 ELSE @,
           !.op[c].wakes=IF ok THEN @+1 ELSE @,
           !.op[c].woke=IF ok THEN @ \cup {g} ELSE @,
           !.op[c].index=IF ok THEN @ ELSE @+1, !.op[c].temp=NoId, !.op[c].pc="wakeScan"]
\* F:353-354,368-379. Same-address REQUEUE ends as WAKE without migration.
\* L/requeue.c:584-610: same-address processed entries are an oracle, not moves.
FutexWakeEnd(c) ==
    /\ s.op[c].pc="wakeScan" /\ s.op[c].index>Len(s.q[SourceBucket(c)])
    /\ s'=[s EXCEPT !.op[c].index=1,
         !.op[c].processed=IF s.op[c].kind="requeue" /\ s.op[c].src=s.op[c].dst
             THEN Min(s.op[c].rawMove,Cardinality(Eligible(c))) ELSE 0,
         !.op[c].pc=IF s.op[c].kind="wake" \/ s.op[c].src=s.op[c].dst THEN "finish"
             ELSE IF SourceBucket(c)=DestBucket(c) THEN "moveSame" ELSE "moveCross"]

\* F:500-511. Check quota AFTER visiting the entry, including unrelated entries.
FutexUpdateItemKey(c) ==
    /\ s.op[c].pc="moveSame" /\ s.op[c].index<=Len(s.q[SourceBucket(c)])
    /\ LET g==s.q[SourceBucket(c)][s.op[c].index]
           hit==s.e[g].key=s.op[c].src n==s.op[c].moves+(IF hit THEN 1 ELSE 0)
       IN s'=[s EXCEPT !.e[g].key=IF hit THEN s.op[c].dst ELSE @,
           !.e[g].lastKey=IF hit THEN s.op[c].dst ELSE @,
           !.op[c].moves=n, !.op[c].processed=n,
           !.op[c].moved=IF hit THEN @ \cup {g} ELSE @,
           !.op[c].index=@+1, !.op[c].pc=IF n>=s.op[c].rawMove THEN "finish" ELSE "moveSame"]
\* F:520-529. Extraction checks quota first and retains nonmatching entries.
FutexExtractItem(c) ==
    /\ s.op[c].pc="moveCross" /\ s.op[c].index<=Len(s.q[SourceBucket(c)])
    /\ LET b==SourceBucket(c) g==s.q[b][s.op[c].index]
           hit==s.e[g].key=s.op[c].src /\ s.op[c].moves<s.op[c].rawMove
       IN IF hit THEN s'=[s EXCEPT !.q[b]=DeleteAt(@,s.op[c].index),
            !.e[g].owner=XOwner(c), !.op[c].temp=g, !.op[c].moves=@+1,
            !.op[c].processed=@+1, !.op[c].pc="changeKey"]
          ELSE s'=[s EXCEPT !.op[c].index=@+1]
\* F:530-531. The extracted entry remains owned by this locked requeue.
FutexExtractedKey(c) ==
    /\ s.op[c].pc="changeKey"
    /\ LET g==s.op[c].temp IN s'=[s EXCEPT !.e[g].key=s.op[c].dst,
         !.e[g].lastKey=s.op[c].dst, !.op[c].pc="append"]
\* F:532,473-475. Append preserves extraction order in the destination vector.
FutexAppendExtracted(c) ==
    /\ s.op[c].pc="append"
    /\ LET g==s.op[c].temp b==DestBucket(c) IN s'=[s EXCEPT
         !.q[b]=Append(@,g), !.e[g].owner=BOwner(b), !.op[c].moved=@ \cup {g},
         !.op[c].temp=NoId, !.op[c].pc="moveCross"]
\* F:502,521-533. Normal iteration end is not bounded by an MC counter.
FutexMoveEnd(c) ==
    /\ s.op[c].pc \in {"moveSame","moveCross"}
    /\ s.op[c].index>Len(s.q[SourceBucket(c)])
    /\ s'=[s EXCEPT !.op[c].pc="finish"]

\* F:368-381; L/requeue.c:584-610. Capture the exhaustion oracle under both locks.
FutexRequeueFinish(c) ==
    /\ s.op[c].pc="finish"
    /\ LET o==s.op[c]
           qualified== /\ o.kind="requeue" /\ o.src/=o.dst
                       /\ o.rawWake=1 /\ o.rawMove=1 /\ Cardinality(o.cohort)=2
                       /\ \A g \in o.cohort :
                            /\ s.w[g].noise=o.noise[g]
                            \* P:172-208; T:106-112. Expiry itself disqualifies the quiet oracle.
                            /\ IF ~s.w[g].duration.timed THEN TRUE
                               ELSE s.w[g].duration.ticks>0 /\
                                  (s.tm[g].state="none" \/ s.now<s.tm[g].deadline)
       IN s'=[s EXCEPT !.op[c].liveViolation=qualified /\ ~((o.cohort \ o.woke) \subseteq o.moved),
           !.op[c].pc=IF SourceBucket(c)=DestBucket(c) THEN "releaseSource" ELSE "releaseDest"]
\* F:370-381. The destination guard's scope ends first, regardless of index order.
FutexReleaseDest(c) ==
    /\ s.op[c].pc="releaseDest"
    /\ s'=[s EXCEPT !.locks[DestBucket(c)]=NoOwner, !.op[c].pc="releaseSource"]
\* F:170,381.
FutexReleaseSource(c) ==
    /\ s.op[c].pc="releaseSource"
    /\ s'=[s EXCEPT !.locks[SourceBucket(c)]=NoOwner, !.op[c].pc="return"]
\* F:170,381; S:142-143. Implementation returns accepted wakes only.
SysFutexControlReturn(c) ==
    /\ s.op[c].pc="return"
    /\ s'=[s EXCEPT !.op[c].result=s.op[c].wakes, !.op[c].pc="done",
                    !.actor[s.op[c].actor[1]]=NoId]

WaitStep(g) == FutexWaitLock(g) \/ FutexWaitLoad(g) \/ FutexWaitFaultUnlock(g)
    \/ HandlePageFault(g) \/ FutexWaitCompare(g) \/ FutexWaitMismatchUnlock(g)
    \/ FutexBucketAddItem(g) \/ FutexWaitUnlock(g) \/ PauseTimeoutCheck(g)
    \/ TimerSetClock(g,s.now) \/ TimerSetTimeout(g) \/ WakerDoWait(g) \/ WaiterPark(g)
    \/ WaiterSpuriousReturn(g) \/ PauseTimeoutClock(g,s.now)
    \/ PauseTimeoutTimerLock(g) \/ PauseTimeoutNoTimer(g) \/ PauseTimeoutRemain(g)
    \/ TimerCancel(g) \/ PauseTimeoutTimerUnlock(g) \/ PauseTimeoutTimerDrop(g)
    \/ FutexCleanupLock(g) \/ FutexRemoveByWaker(g) \/ FutexCleanupUnlock(g)
    \/ FutexWaitDecide(g) \/ WaiterDrop(g) \/ SysFutexWaitReturn(g)
TimerStep(g) == TimerCollect(g) \/ TimerCallbackUpgrade(g) \/ TimerCallbackLock(g)
    \/ TimerCallbackCheck(g) \/ TimerCallbackWake(g) \/ TimerCallbackUnpark(g)
    \/ TimerCallbackFinish(g)
ControlStep(c) == LockBucketPairsFirst(c) \/ LockBucketPairsSecond(c)
    \/ FutexWakeStart(c) \/ FutexItemWake(c) \/ FutexWakeUnpark(c)
    \/ FutexWakeRetain(c) \/ FutexWakeEnd(c) \/ FutexUpdateItemKey(c)
    \/ FutexExtractItem(c) \/ FutexExtractedKey(c) \/ FutexAppendExtracted(c)
    \/ FutexMoveEnd(c) \/ FutexRequeueFinish(c) \/ FutexReleaseDest(c)
    \/ FutexReleaseSource(c) \/ SysFutexControlReturn(c)
CollectionStep == TimerCollectClock(s.now) \/ TimerCollectEnd
ReactiveNext == CollectionStep \/ (\E g \in WaitIds : WaitStep(g) \/ TimerStep(g))
    \/ (\E c \in CallIds : ControlStep(c))
Next == ReactiveNext
    \/ ClockAdvance(s.now+1)
    \/ (\E g \in WaitIds, k \in Keys, v \in Values, d \in Durations : SysFutexWait(g,k,v,d))
    \/ (\E c \in CallIds, a \in Controllers, kind \in {"wake","requeue"},
            src,dst \in Keys, nw,nm \in Quotas : SysFutexControl(c,a,kind,src,dst,nw,nm))
    \/ (\E g \in WaitIds : FutexWaitFault(g))
    \/ (\E k \in Keys, v \in Values : UserStore(k,v))
Spec == Init /\ [][Next]_vars

\* Structural sanity, F:473-539, W:181-189, T:64-281.
TypeOK == /\ s.word \in [Keys -> Values] /\ s.now \in Nat /\ s.stores \in Nat
    /\ DOMAIN s.w=WaitIds /\ DOMAIN s.e=WaitIds /\ DOMAIN s.tm=WaitIds
    /\ DOMAIN s.op=CallIds /\ DOMAIN s.actor=Controllers
    /\ s.q \in [Buckets -> Seq(WaitIds)]
    /\ s.locks \in [Buckets -> {NoOwner} \cup {WOwner(g):g \in WaitIds} \cup {COwner(c):c \in CallIds}]
    /\ \A g \in WaitIds :
         /\ s.w[g].key \in Keys /\ s.w[g].original \in Buckets
         /\ s.w[g].hasWoken \in BOOLEAN /\ s.w[g].closed \in BOOLEAN
         /\ s.w[g].returns \in Nat /\ s.e[g].registered \in Nat /\ s.e[g].removals \in Nat
         /\ s.e[g].key \in Keys /\ s.tm[g].deadline \in Nat
         /\ s.w[g].pc \in {"idle","lock","load","compare","faultUnlock","resolve",
              "enqueue","mismatchUnlock","unlock","pauseCheck","armRead","arm","wait","park","sleep",
              "inspect","remainRead","remain","cancel","timerUnlock","timerDrop","cleanupLock",
              "cleanup","cleanupUnlock","decide","close","return","done"}
         /\ s.w[g].expected \in Values /\ s.w[g].observed \in Values
         /\ s.w[g].duration \in Durations \cup {Never}
         /\ s.w[g].sample \in Nat
         /\ s.w[g].pause \in {No,"OK","ETIME"}
         /\ s.w[g].result \in {No,"OK","EAGAIN","ETIMEDOUT","ERESTARTSYS"}
         /\ s.w[g].cleanup \in {No,"found","miss"}
         /\ s.w[g].notified \in BOOLEAN /\ s.w[g].futexAccepted \in BOOLEAN
         /\ s.w[g].noise \in Nat
         /\ s.e[g].owner \in {NoOwner,LocalOwner} \cup {BOwner(b): b \in Buckets} \cup {XOwner(c): c \in CallIds}
         /\ s.tm[g].state \in {"none","armed","expired","cancelled"}
         /\ s.tm[g].cb \in {"idle","collected","due","ref","check","wake","unpark","finish","done"}
         /\ s.tm[g].localRef \in BOOLEAN /\ s.tm[g].cbRef \in BOOLEAN
         /\ s.tm[g].cancelled \in BOOLEAN /\ s.tm[g].accepted \in BOOLEAN
         /\ s.tm[g].lock \in {"free","waiter","callback"}
    /\ \A c \in CallIds : /\ s.op[c].wakes \in Nat /\ s.op[c].moves \in Nat
                          /\ s.op[c].woke \subseteq WaitIds /\ s.op[c].moved \subseteq WaitIds
                          /\ s.op[c].pc \in {"idle","lockFirst","lockSecond","snapshot",
                               "wakeScan","unpark","wakeCommit","moveSame","moveCross",
                               "changeKey","append","finish","releaseDest","releaseSource","return","done"}
                          /\ s.op[c].src \in Keys /\ s.op[c].dst \in Keys
                          /\ s.op[c].index \in Nat /\ s.op[c].processed \in Nat
                          /\ s.op[c].temp \in WaitIds \cup {NoId}
                          /\ s.op[c].actor \in {<<>>} \cup {<<a>> : a \in Controllers}
    /\ s.actor \in [Controllers -> CallIds \cup {NoId}]
    /\ s.collect \in [active: BOOLEAN, sample: Nat, ready: Seq(WaitIds)]
    /\ s.callbacks \in [WaitIds -> Seq(WaitIds)]

\* F:107-114,124-139. Timeout removes this generation and never undoes requeue.
FailureAtomicity == \A g \in WaitIds :
    /\ (s.w[g].result="EAGAIN" => s.e[g].registered=0 /\ s.e[g].owner \in {NoOwner,LocalOwner})
    /\ (s.w[g].result="ETIMEDOUT" => s.e[g].removals=1)
    /\ s.e[g].key=s.e[g].lastKey
\* F:477-498; W:244-281. Two accepted notifications before closure are allowed.
ExactlyOnceCompletion ==
    /\ \A g \in WaitIds : /\ s.w[g].returns<=1 /\ s.e[g].removals<=1
         /\ (s.w[g].closed => s.w[g].hasWoken)
         /\ (s.w[g].returns=1 => s.w[g].closed)
    /\ \A c \in CallIds : ~s.op[c].acceptedClosed
Owners(g) == {BOwner(b) : b \in {b \in Buckets : g \in SeqSet(s.q[b])}}
    \cup {XOwner(c) : c \in {c \in CallIds : s.op[c].temp=g /\ s.op[c].pc \in {"changeKey","append"}}}
\* F:78-80,477-534,590-674. The original reference is immutable across transfers.
ObjectIdentityStability ==
    /\ \A g \in WaitIds :
         /\ s.w[g].original=BucketOf[s.w[g].key]
         /\ s.e[g].registered<=1 /\ s.e[g].removals<=s.e[g].registered
         /\ Cardinality(Owners(g))=s.e[g].registered-s.e[g].removals
         /\ (Owners(g)/={} => Owners(g)={s.e[g].owner})
    /\ \A b \in Buckets :
         /\ Len(s.q[b])=Cardinality(SeqSet(s.q[b]))
         /\ \A g \in SeqSet(s.q[b]) : BucketOf[s.e[g].key]=b
    /\ \A c \in CallIds : s.op[c].identityOK
\* F:121-124,384-539; T:234-281. Only a drained completion incurs reclamation duty.
Quiescent == /\ \A b \in Buckets : s.locks[b]=NoOwner
    /\ \A c \in CallIds : s.op[c].pc \in {"idle","done"}
    /\ \A g \in WaitIds :
         /\ s.w[g].pc \in {"idle","done","wait","park","sleep"}
         /\ ~s.tm[g].cbRef /\ s.tm[g].cb \in {"idle","done"}
         /\ ~(s.tm[g].state="armed" /\ s.now>=s.tm[g].deadline)
ResourceAccountingBalance == ObjectIdentityStability /\
    (Quiescent => \A g \in WaitIds : s.w[g].returns=1 =>
        s.e[g].registered=s.e[g].removals /\ Owners(g)={} /\ ~s.tm[g].localRef)
\* P:202-221; F:125-139. Success may be spurious. No signal/restart is injected.
PermittedWaitResult == \A g \in WaitIds :
    /\ (s.w[g].returns=1 => s.w[g].result \in {"OK","EAGAIN","ETIMEDOUT"})
    /\ (s.w[g].result="ETIMEDOUT" =>
          s.w[g].duration.timed /\ s.now>=s.tm[g].deadline)
\* L/requeue.c:584-610,691. Separate clauses expose TV-1/2/3 independently.
RequeueWakeQuota == \A c \in CallIds : s.op[c].kind="requeue" => s.op[c].wakes<=s.op[c].rawWake
RequeueMoveQuota == \A c \in CallIds : s.op[c].kind="requeue" => s.op[c].moves<=s.op[c].rawMove
RequeueReturnCount == \A c \in CallIds :
    s.op[c].kind="requeue" /\ s.op[c].pc="done" => s.op[c].result=s.op[c].wakes+s.op[c].processed
RequeueQuotaAndResult == RequeueWakeQuota /\ RequeueMoveQuota /\ RequeueReturnCount
\* S:146-150; L/waitwake.c:180-197. This is separate from the REQUEUE zero oracle.
WakeQuota == \A c \in CallIds : s.op[c].wakes<=s.op[c].effective
\* Brief scenario 4; L/requeue.c:584-610. A max-only bound cannot check exhaustion.
LiveMigrationExhaustion == \A c \in CallIds : ~s.op[c].liveViolation
\* W:259-281; P:171-221. MC supplies finite admission/faults and fair reactive steps.
ConditionalCompletion == \A g \in WaitIds :
    (s.w[g].notified \/ s.w[g].pause="ETIME") ~> (s.w[g].returns=1)
=============================================================================
