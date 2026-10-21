# Modeling-Brief Coverage Audit

This audit was filled from the generated `base.tla`, `MC.tla`, and
`MC_hunt_*.cfg` files. It covers the brief's Category B state machine only:
regular-file `read`, `write`, `pread64`, `pwrite64`, `readv`, and `writev` on
one shared open-file description. Progress values are symbolic
zero/prefix/complete classes, not concrete byte or page counts.

## Brief §2 scenarios

| Scenario | Base-spec mechanism | Targeting hunt configuration | Coverage |
|---|---|---|---|
| S1: positive progress is collapsed | `VmoRead`, `VmoWrite`, `ErrorFromTuple`, `InodeHandleCommitOffset`, `InodeHandlePropagateError`, per-vector dispatch, syscall finish, `HandlePendingSignal`, and `RestartSyscall` | `MC_hunt_s1_partial_progress.cfg` | The config permits one vector syscall, requires iovec 1 to complete, and permits only a positive-prefix fault on iovec 2. It enables both result/progress invariants, shared-offset accounting, and restart non-replay. |
| S2: adapter publication/copy ordering | `Ext2VirtioFsReadComputeLimit`, `RamFsExfatReadComputeLimit`, `RamFsWritePublishRequestedEnd`, `DeferredWritePrepare`, and filesystem return actions | `MC_hunt_s2_unbounded_read.cfg` plus `MC_hunt_s2_prepublished_write.cfg`; `MC_hunt_s2_adapter_ordering.cfg` is the combined profile | The read profile starts `pread64` exactly at logical EOF while cache capacity remains positive. The write profile starts faultable RamFS `pwrite64` at EOF after requested-end publication. Splitting the profiles prevents one earlier violation from masking the other. |
| S3: vector serialization is released per entry | `InodeHandle*AcquireOffset`, `InodeHandleCommitOffset`, `InodeHandleReleaseOffset`, the per-iovec dispatch actions, and `commitLog` | `MC_hunt_s3_vector_linearization.cfg` | Two threads and two admissions permit a scalar competitor to commit after vector iovec 1 releases the lock and before iovec 2 reacquires it. Copy faults are disabled. |
| S4: positional offset isolation | `InodeHandleReadAtStart`, `InodeHandleWriteAtStart`, and `InodeHandlePositionalReturn` bypass `offsetOwner` and `sharedOffset`; scalar shared operations use the mutex path | `MC_hunt_s4_positional_isolation.cfg` | Two threads mix shared and positional scalar operations with copy faults disabled. The positional invariant is the only scenario invariant enabled. |

The restart portion of S1 is represented but cannot currently fire: no
in-scope regular-file path in the brief produces `EINTR`, and the model does
not manufacture one after progress. `RestartNoReplay` is still enabled in the
S1 hunt so a future source-backed `EINTR` producer can be added without an
uncovered restart contract.

## Brief §5 safety invariants

| Brief invariant | Defined in base | Wired in MC | Enabled in actual hunt cfg(s) |
|---|---|---|---|
| `ReadReturnCoversCopies` | `base.tla:929` | `MC.tla:263` | `MC_hunt_s1_partial_progress.cfg:31`; `MC_hunt_s2_unbounded_read.cfg:29`; combined S2 cfg line 29 |
| `WriteReturnCoversCommit` | `base.tla:938` | `MC.tla:264` | `MC_hunt_s1_partial_progress.cfg:32`; `MC_hunt_s2_prepublished_write.cfg:29`; combined S2 cfg line 30 |
| `NoReadPastEOF` | `base.tla:947` | `MC.tla:265` | `MC_hunt_s2_unbounded_read.cfg:30`; combined S2 cfg line 31 |
| `NoNominalEOFOnFault` | `base.tla:951` | `MC.tla:266` | `MC_hunt_s2_prepublished_write.cfg:30`; combined S2 cfg line 32 |
| `SharedOffsetTracksReport` | `base.tla:959` | `MC.tla:267` | `MC_hunt_s1_partial_progress.cfg:33` |
| `VectorSingleLinearization` | `base.tla:973` | `MC.tla:268` | `MC_hunt_s3_vector_linearization.cfg:29` |
| `PositionalOffsetIsolation` | `base.tla:981` | `MC.tla:269` | `MC_hunt_s4_positional_isolation.cfg:29` |
| `RestartNoReplay` | `base.tla:992` | `MC.tla:270` | `MC_hunt_s1_partial_progress.cfg:34` |

All eight brief safety invariants are defined, aliased through `MC.tla`, and
enabled in at least one hunt configuration. `MC.cfg` intentionally comments
them out while retaining only core and structural invariants for convergence.

## Brief §6.1 model-checkable findings

| Finding | Reachable trigger in the hunt | Expected violated invariant | Hunt cfg |
|---|---|---|---|
| MC-1: later positive-prefix vector fault is omitted | One `Readv` or `Writev`; iovec 1 must complete; `AllowedFaultIovs = {2}` and `AllowedFaultProgress = {"Prefix"}`; one copy fault allowed | `ReadReturnCoversCopies` or `WriteReturnCoversCommit`; `SharedOffsetTracksReport` remains checked as the offset/result consistency companion | `MC_hunt_s1_partial_progress.cfg` |
| MC-2: competitor commits between vector entries | Two threads, two admitted shared operations, vector and scalar kinds enabled, no copy faults; `InodeHandleReleaseOffset` is a real interleaving boundary | `VectorSingleLinearization` | `MC_hunt_s3_vector_linearization.cfg` |

Direct scalar reproduction of historical issue #711 is not a hunt target.
The S1 iovec guard prevents that positive-control history from satisfying
MC-1. Brief §6.2 test-verifiable and §6.3 code-review-only findings are outside
the §6.1 hunt audit; S2 nevertheless has focused model profiles because its
adapter ordering directly drives four proposed safety invariants.

## Target-guidance cross-check

| Priority question | Representation |
|---|---|
| Result, committed progress, and shared offset after a partial copy fault | S1 progress fields (`requested`, `copied`, `committed`, `reported`), tuple conversion, offset commit/propagation split, and guarded vector hunt |
| One vector operation versus a competing shared-offset operation | S3 per-entry acquire/commit/release and tagged `commitLog` |
| Positional I/O must not change the shared offset | S4 explicit-offset start/return path and `PositionalOffsetIsolation` |
| SA_RESTART must not replay an effect | `HandlePendingSignal`, `RestartSyscall`, `effectLog`, and `RestartNoReplay`; no unsupported post-progress `EINTR` injection |

Sockets, pipes, `msghdr`, control messages, `SCM_RIGHTS`, `accept`,
`preadv`/`pwritev`, offset flags, parser arithmetic, exact copy counts, broad
resource exhaustion, and append-range atomicity are absent from the state
machine as required. Historical issues are mechanism context only and are not
encoded as findings.

## Generation-time smoke results

These runs validate configuration assembly and reachability; they are not the
later Specula validation phase.

| Config | Result |
|---|---|
| `MC.cfg` | Exhausted 511,868 distinct states; core/structural invariants held |
| `MC_hunt_s1_partial_progress.cfg` | Reached `MCReadReturnCoversCopies` violation on completed iovec 1 plus prefix-faulting iovec 2 |
| `MC_hunt_s2_unbounded_read.cfg` | Reached `MCNoReadPastEOF` violation |
| `MC_hunt_s2_prepublished_write.cfg` | Reached `MCNoNominalEOFOnFault` violation |
| `MC_hunt_s3_vector_linearization.cfg` | Reached `MCVectorSingleLinearization` violation |
| `MC_hunt_s4_positional_isolation.cfg` | Exhausted 2,016 distinct states with no invariant violation |
