# MC-4 Investigation

## Scope

Finding MC-4 only.  Source is the model-checking counterexample
`spec/output/hunt/MC_hunt_scenario2_rerun2.log`.  I did not read other
findings, `bug-report.md`, `confirmed-bugs.md`, or the shared repair queue.

## Counterexample evidence

The counterexample reports `Invariant StepDownTermNotLost is violated`.

Relevant steps:

- State 5 executes `<MCLeaderStateImpl_submitStepDownEvent(s1,1)>`; the model has
  `stepDownQueued(s1)=TRUE`, `queuedStepDownTerm(s1)=1`, and the sender is caught
  up.
- State 11 executes `<MCLeaderStateImpl_submitStepDownEvent(s1,3)>`; the model has
  `maxObservedStepDownTerm(s1)=3`, but `queuedStepDownTerm(s1)=1` remains.  This is
  the type-only deduplication behavior: the later higher-term step-down event is
  observed by the leader path but not retained in the queue.

## Code evidence

- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:129`
  implements `StateUpdateEvent.equals`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:137`
  compares only `this.type == that.type`; the event term and handler are not part
  of equality.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:157`
  submits events through a synchronized queue method.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:158`
  returns early when `queue.contains(event)` is true, so any queued `STEP_DOWN`
  causes a later same-type `STEP_DOWN` to be dropped.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:510`
  accepts higher terms reported by caught-up followers.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:512`
  submits the higher-term step-down event.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:742`
  builds a `STEP_DOWN` event whose handler captures the specific term.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:747`
  executes the captured term through `stepDown`.

Real producer paths include AppendEntries and snapshot replies:

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java`
  calls `onFollowerTerm(reply.getTerm())` for `NOT_LEADER` append responses.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java`
  calls `onFollowerTerm(reply.getTerm())` for `NOT_LEADER` append responses.

Real consumer path:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1500`
  handles `requestVote`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java:75`
  rejects stale candidates only when the local current term is greater than the
  candidate term.
- If the higher term is lost and only the older step-down term is persisted,
  `requestVote` can grant a vote to a candidate at the stale older term.

## Prior-report search

I searched the upstream issue/PR history for the same mechanism, including open,
closed, and merged records:

- `repo:apache/ratis "StateUpdateEvent" "STEP_DOWN"`
- `repo:apache/ratis "queue.contains(event)"`
- `repo:apache/ratis "submitStepDownEvent" "higher term"`
- `repo:apache/ratis "LeaderStateImpl" "avoid duplicated events"`
- `repo:apache/ratis is:issue is:closed "LeaderStateImpl" "higher term"`
- `repo:apache/ratis is:issue "step down" "higher term"`
- `repo:apache/ratis is:pr is:merged "LeaderStateImpl" "step down"`

The only directly related upstream PR found was
`https://github.com/apache/ratis/pull/1258` (`RATIS-2290. Simply the EventQueue in
leader`), which introduced/simplified the current type-only event queue behavior.
I did not find a prior issue, closed report, or merged PR describing or fixing a
higher-term `STEP_DOWN` dropped behind an older same-type event.

## Reproduction plan

Use a normal simulated Ratis cluster to obtain a real leader and caught-up
follower, then hold one `EventQueue.poll` with a test-only
`CodeInjectionForTesting` hook so that two real `LeaderStateImpl.onFollowerTerm`
calls can overlap in the queue.  Submit a lower caught-up follower term followed
by a higher caught-up follower term.  The expected bad observation is that the
server steps down to the lower term only, and a real `requestVote` call at that
lower term succeeds even though the server had already observed the higher term.
