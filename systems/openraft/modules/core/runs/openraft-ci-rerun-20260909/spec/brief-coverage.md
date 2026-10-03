# Modeling-brief coverage audit

This audit was filled from the generated `base.tla`, `MC.tla`, and the actual
`MC_hunt_*.cfg` files. It records reachability intent; it does not claim that an
exhaustive hunt has completed or that OpenRaft is safe.

## Scope and CI-initialization intent

The reference is a single Category A model whose shared state composes all five
brief scenarios. It preserves the implementation's ordered Engine loop while
splitting the asynchronous boundaries that run outside it: vote/log acceptance,
submission, durable completion, LocalIO delivery, response release, state-machine
apply, snapshot worker completion, purge, per-peer heartbeat, replication, and
ReadIndex tasks. Historical fixed implementations are not reintroduced.

The initial baseline models snapshot contents as metadata plus the canonical
committed prefix. It assumes the documented ordered durable-write and immediate
reader-visibility storage contract. Snapshot bytes/chunks, codecs, unsafe
`allow_log_reversion`, endpoint identity faults, and leadership-transfer internals
remain outside this baseline, matching brief section 3.2. The model exposes both
standard and advanced LeaderId modes; the supplied configs select advanced mode.

## Brief section 2 scenarios

| Scenario | Base mechanisms and actions | Targeting hunt config | Status |
|---|---|---|---|
| 1. Restored leadership before application recovery | Persistent/volatile vote and log split; optional `persistedCommitted`; `Crash`, `RestartLoadState`, `StorageHelperRestoreFromSnapshot`, per-entry `StorageHelperReapplyCommitted`, `StorageHelperFinishRecovery`, `EngineStartupRestoreLeader`, ReadIndex/lease plus `LinearizerTryAwaitReady` | `MC_hunt_scenario1_recovery.cfg` | Covered; config uses `PersistCommitted = FALSE`, one crash, one write, one read, and recovery/reactive steps unbounded |
| 2. Persistence-before-ack I/O pipeline | `acceptedIO`, `submittedIO`, `durableIO`, `flushedIO`; separate `RaftCoreRunCommandSaveVote`, append submit, storage completion, LocalIO, IOFlushed response release, save-commit, apply, responder completion | `MC_hunt_scenario2_io.cfg` | Covered; two writes, one crash/loss, no unrelated membership/snapshot/read/heartbeat injection |
| 3. Membership transactions and session fencing | Effective vs committed membership; `NextCoherent`; request-owned intent/retain/phase; separate first submit and `ManagementApiFlattenJoint`; session rebuild and stale response handling | `MC_hunt_scenario3_membership.cfg` | Covered; two concurrent requests plus leader/crash/snapshot/session composition enabled |
| 4. Snapshot, membership, and purge lifecycle | Queued/running build, accepted metadata vs durable snapshot, full-snapshot install before worker completion, submitted/flushed notification, scheduled/in-memory/durable purge frontiers | `MC_hunt_scenario4_snapshot.cfg` | Covered; two builds, one install, two crashes, and one membership transaction enabled |
| 5. Independent heartbeat, replication, and read paths | Per-peer `heartbeatEvent`, network set for delay/reorder/loss, replication session checks, send-time lease, separate ReadIndex quorum task whose captured membership can outlive the current session | `MC_hunt_scenario5_paths.cfg` | Covered; three heartbeats/elections/clock advances, two reads/losses, and a membership-session change enabled |

No scenarios were merged; each brief scenario has its own hunt config.

## Brief section 5 safety invariants

| Invariant | Defined in | Wired through MC | Enabled in hunt config(s) |
|---|---|---|---|
| `StandardElectionSafety` | `base.tla` | inherited by `MC.tla` | scenarios 1, 2, 3, 4, 5 |
| `OrderedVoteSafety` | `base.tla` | inherited by `MC.tla` | scenarios 1, 3, 5 |
| `LogMatching` | `base.tla` | inherited by `MC.tla` | scenarios 1, 2, 3, 4, 5 |
| `LeaderCompleteness` | `base.tla` | inherited by `MC.tla` | scenarios 1, 2, 3, 4, 5 |
| `StateMachineSafety` | `base.tla` | inherited by `MC.tla` | scenarios 1, 2, 3, 4, 5 |
| `DurableBeforeAck` | `base.tla` | inherited by `MC.tla` | scenario 2 |
| `CursorOrder` | `base.tla` | inherited by `MC.tla` | scenarios 2, 4 |
| `RecoveryReadSafety` | `base.tla` | inherited by `MC.tla` | scenarios 1, 5 |
| `MembershipAgreement` | `base.tla` | inherited by `MC.tla` | scenario 3 |
| `EffectiveMembershipBacked` | `base.tla` | inherited by `MC.tla` | scenarios 3, 4 |
| `SessionFence` | `base.tla` | inherited by `MC.tla` | scenarios 3, 5 |
| `SnapshotPurgeSafety` | `base.tla` | inherited by `MC.tla` | scenario 4 |

`MC.cfg` enables only standard protocol safety plus `MCTypeOK`,
`NoPhantomCommitted`, and `MCProgressStructure`. All scenario-specific
invariants are present there but commented out, and are enabled above in the
targeted hunt configs.

## Brief section 6.1 model-checkable findings

| Finding | Reachable trigger setup | Expected invariant(s) | Targeting config |
|---|---|---|---|
| MC-1 fast-restored leader reads before replay/reconfirmation | Complete a client operation, crash the persisted self-voted leader, recover with optional committed persistence disabled, restore leadership, then execute ReadIndex or LeaseRead and await apply | `RecoveryReadSafety`; also `LeaderCompleteness`/`StateMachineSafety` as core checks | `MC_hunt_scenario1_recovery.cfg`; independent path/session composition in `MC_hunt_scenario5_paths.cfg` |
| MC-2 cross-request membership successor after leader/snapshot recovery | Start two request IDs with distinct goals/retain intent; commit a joint step; interleave crash/election or snapshot; let the original API resume its empty-change second call against the then-current effective membership | `MembershipAgreement`, `OrderedVoteSafety` | `MC_hunt_scenario3_membership.cfg` |
| MC-3 delayed heartbeat/read acknowledgment crosses session change | Create heartbeat/ReadIndex responses in `network`, change the leader vote or effective membership/session, then deliver delayed responses; heartbeat/replication are guarded while the independently spawned read task uses its captured membership | `SessionFence`, `RecoveryReadSafety` | `MC_hunt_scenario5_paths.cfg` |
| MC-4 crash between save/apply/install/purge loses the only committed source | Commit and save/apply an entry, build or install snapshot, queue in-memory purge, crash at each worker/notification/durable-purge boundary, recover and/or elect | `LeaderCompleteness`, `SnapshotPurgeSafety`; `StateMachineSafety` remains a core guard | `MC_hunt_scenario4_snapshot.cfg` |

## Honest limits and validation status

- `base.tla`, `MC.tla`, and `Trace.tla` pass SANY. `MC.cfg` completed 200
  random traces up to depth 100 (17,880 states generated) without an
  enabled-invariant violation.
- Each hunt config completed 40 random traces up to depth 80. These runs validate
  configuration and expression execution only; they are not exhaustive hunts
  and are not evidence that the four pending findings pass.
- The default safety-convergence config uses `PersistCommitted = TRUE`; the
  two read/recovery hunts deliberately use `FALSE` to exercise the public
  optional-commit path. Later validation should report the two contracts
  separately.
- Liveness formulas are defined in `MC.tla` but not enabled in the baseline
  safety pass because fairness and bounds require separate tuning.
- Real trace validation still depends on the next harness phase producing the
  event schema in `instrumentation-spec.md`; no implementation trace has been
  observed or checked during spec generation. A one-event synthetic trace did
  pass exact replay and the mandatory `TraceMatched` completion property.
