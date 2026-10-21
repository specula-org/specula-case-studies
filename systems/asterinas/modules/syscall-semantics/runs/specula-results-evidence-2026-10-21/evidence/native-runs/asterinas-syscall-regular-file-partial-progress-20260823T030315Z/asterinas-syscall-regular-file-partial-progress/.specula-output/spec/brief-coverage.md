# Modeling brief coverage

This audit was filled from the generated `MC_hunt_*.cfg` files after they were
written and parsed. It covers the Modeling Brief's Category B scenarios and
only the brief's requested regular-file scope.

## Brief §2 scenarios

| Scenario | Base actions/mechanism | Targeting hunt config | Reachability in that config |
|---|---|---|---|
| 1. Positive copy progress is erased | aggregate `FileOpsReadAtCopyFaultPositive` / `FileOpsWriteAtCopyFaultPositive`, cumulative retained-prefix observation independent of `pageState`, `FileOpsReadAtFinish`, buffered/ramfs fault disposition, scalar/vector return actions | `MC_hunt_scenario_1_positive_copy_progress.cfg`; mixed-page specialization in `MC_hunt_scenario_1_mixed_page_prefix.cfg`; composed vector form also in Scenario 3 | The general cfg permits one scalar read and one scalar write to fault after a positive cumulative prefix. The mixed-page cfg enables only one buffered write and one positive fault; `MCMixedPageRetainedPrefixReported` becomes relevant only when the faulting page is `Uninit` while an earlier page is already retained. Internal page/range loops emit one aggregate backend-boundary event, including no-copy and multi-call paths. |
| 2. Backend publication escapes outcome | `Ext2InodeWriteAtZeroLengthReturn` versus `RamInodeWriteAtPublishMetadata`, cumulative old-EOF-aware buffered retain/discard actions, `BioSubmit`, `SubmittedBioComplete`, `InodeInnerWriteDirectAtRollback` | `MC_hunt_scenario_2_backend_publication.cfg`; MC2 is isolated by `MC_hunt_finding_mc2_direct_completion.cfg`; same-owner delayed completion is isolated by `MC_hunt_finding_delayed_bio_vector.cfg` | The scenario cfg enables shared and positional writes plus buffered/direct faults. Buffered disposition distinguishes the later faulting page from any earlier dirty page. The ext2 zero-length branch returns before its inode guard, while ramfs can publish a far-offset size before a zero copy. The MC2 cfg checks pending and already-completed direct effects. The one-thread delayed-BIO cfg forces an older attempt's BIO to complete between entries of the same task's later vector call. BIO completion stays reactive and unbounded in all three. |
| 3. Vector call spans scalar critical sections | per-entry `InodeHandle*AcquireOffset`, `FileOpsAcquireData`, `FileOpsReleaseData`, `DoSys*Entry*Continue/Return`, distinct `VectorOffsetGap`/`VectorDataGap` witnesses, overlap-qualified `vectorIntervened`, and diagnostic `bufferEpochs` | `MC_hunt_scenario_3_vector_atomicity.cfg`; exact MC1 form in `MC_hunt_finding_mc1_later_iovec_fault.cfg`; append/zero-fault composition in `MC_hunt_scenario_3_append_gap.cfg` | `VectorOffsetGap` covers OFD release/reacquisition. `VectorDataGap` starts when the first backend guard drops and remains open through the next entry's OFD acquisition, ramfs EOF snapshot, and backend acquisition. Positional/BIO writes and ramfs EOF publication mark it only when abstract ranges overlap. The inode-wide epoch remains trace diagnostic state and is not used to classify disjoint writes. The MC1 cfg completion-gates a later positive fault; the append cfg completion-gates an `O_APPEND` zero-copy fault after pre-positioning changed f_pos. |
| 4. Positional neutrality with split snapshots | `InodeHandleReadAtBegin`, `InodeHandleWriteAtBegin`, `RamInodeReadAtSnapshotSize`, `entryDataEpoch`, `bufferEpochs`, per-call `positionalOFDExpected`, `RangesOverlap`, and `DataConflictsWithVector` | `MC_hunt_scenario_4_positional_offset.cfg` | One positional read/write and one vector read/write may overlap. Shared offset publications refresh active positional expectations. An overlapping positional write conflicts with either vector direction; an overlapping positional read conflicts with a vector write. Disjoint positional I/O does not mark a vector split. Copy faults are disabled to isolate offset/data-generation interleavings. |
| 5. Append positioning before success | `InodeHandleWriteChooseAppendStart`, `MarkVectorOffsetIntervenedForAttempt`, `InodeHandleWriteReturnError` | `MC_hunt_scenario_5_append_failure.cfg`; vector composition in `MC_hunt_scenario_3_append_gap.cfg` | One shared write and one zero-prefix write fault are enabled. The append action records changed f_pos before the backend call. The focused composition requires the append writer to finish with `Fault`/zero copy before its vector-specific invariant can fail. |
| 6. Restart lacks progress provenance | `InterruptibleBackendReturnEintr`, `SysReadTranslateEintr`, `SysWriteTranslateEintr`, `HandlePendingSignal*`, `TaskRestartSyscall` | `MC_hunt_scenario_6_restart.cfg`; replay isolation in `MC_hunt_scenario_6_effect_replay.cfg` | The pinned `MC.cfg` keeps interruption disabled. The restart hunt enables one reference-only EINTR after copied progress. The replay hunt enables one write publication, rewind, and re-execution with the same effect token. Signal delivery has no progress guard in either hunt, matching the implementation's errno-only decision. |

There is no scenario merger: each brief scenario has its own hunting config.

## Brief §5 safety invariants

The “enabled” column was checked against the uncommented `INVARIANTS` entries
in the actual hunt configs.

| Brief invariant | Defined in `base.tla` | MC alias | Enabled hunt configs |
|---|---|---|---|
| `TypeOK` | `TypeOK` | `MCTypeOK` | every `MC_hunt_*.cfg` |
| `ReportedCoversVisibleCopy` | `ReportedCoversVisibleCopy` | `MCReportedCoversVisibleCopy` | Scenarios 1, 4 |
| `ReportedCoversCommittedWrite` | `ReportedCoversCommittedWrite` | `MCReportedCoversCommittedWrite` | Scenarios 1, 2; MC2 finding hunt |
| `SharedOffsetMatchesReported` | `SharedOffsetMatchesReported` | `MCSharedOffsetMatchesReported` | Scenario 5 |
| `FileSizeMatchesProgress` | `FileSizeMatchesProgress` | `MCFileSizeMatchesProgress` | Scenario 2 |
| `VectorCallLinearizable` | `VectorCallLinearizable` | `MCVectorCallLinearizable` | Scenarios 3, 4; delayed-BIO finding hunt |
| `PositionalOffsetStable` | `PositionalOffsetStable` | `MCPositionalOffsetStable` | Scenario 4 |
| `NoUnaccountedPendingEffect` | `NoUnaccountedPendingEffect` | `MCNoUnaccountedPendingEffect` | Scenario 2 and the MC2 finding hunt |
| `RestartRequiresZeroProgress` | `RestartRequiresZeroProgress` | `MCRestartRequiresZeroProgress` | Scenario 6 |
| `NoEffectReplay` | `NoEffectReplay` | `MCNoEffectReplay` | Scenario 6 effect-replay hunt |

`MC.cfg` enables only convergence invariants (`MCTypeOK`, structural checks,
progress bounds, and BIO lifecycle). Every scenario invariant above is listed
there but commented out, then enabled in at least one hunt config.

`LaterIovecFaultLinearizable` / `MCLaterIovecFaultLinearizable` is an MC1-only
specialization beyond the ten §5 invariants. It prevents the MC1 hunt from
terminating on a generic successful-vector interleaving before the required
positive fault in a later iovec is reached.

`MixedPageRetainedPrefixReported` /
`MCMixedPageRetainedPrefixReported` is a Scenario 1/2 regression
specialization beyond the ten §5 invariants. It is enabled only in
`MC_hunt_scenario_1_mixed_page_prefix.cfg`, where it requires a completed ext2
buffered attempt with a later `Uninit` faulting page and independently recorded
positive retained progress. This prevents the aggregate model from silently
discarding an earlier dirty page.

Scenario 1's positive-copy hunt checks reported progress against independently
observed visible and committed progress. The exact `SharedOffsetMatchesReported`
predicate remains unchanged and enabled in Scenario 5, where zero-progress
failure-path OFD movement is isolated. No per-thread completion gate wraps that
global predicate: such a gate could attribute an append offset defect to an
unrelated positive-copy attempt.

`AppendFailureVectorLinearizable` /
`MCAppendFailureVectorLinearizable` is the analogous Scenario 3/5 completion
gate. It is enabled only in `MC_hunt_scenario_3_append_gap.cfg`, where it
requires a completed vector plus a completed `O_APPEND` writer with `Fault`
and zero copied progress. This prevents a zero-length successful append from
preempting the requested fault composition.

## Brief §6.1 model-checkable findings

| Finding | Required trigger | Expected violated invariant | Targeting hunt configs |
|---|---|---|---|
| MC1 | A vector completes one entry, a competing shared-offset operation runs, and a later entry faults after a positive prefix | `VectorCallLinearizable`, `ReportedCoversVisibleCopy`, or `ReportedCoversCommittedWrite` | `MC_hunt_finding_mc1_later_iovec_fault.cfg` targets `MCLaterIovecFaultLinearizable`, which is completion-gated on `vectorIndex > 1`, `EntryFault`, `copied = Positive`, and a qualified intervention. The broader Scenario 3 and Scenario 1 cfgs cover the two constituent mechanisms separately. |
| MC2 | An ext2 direct first range copies/submits, a later range faults, the syscall releases its locks, and the earlier BIO completes before or after a subsequent shared operation | `NoUnaccountedPendingEffect` or `SharedOffsetMatchesReported` | `MC_hunt_finding_mc2_direct_completion.cfg` enables only direct-copy faults plus one shared and one positional write. It checks `NoUnaccountedPendingEffect` while the BIO is pending and `ReportedCoversCommittedWrite` when the BIO completes before the failed syscall publishes its result. The broader `MC_hunt_scenario_2_backend_publication.cfg` also reaches the mechanism while covering ramfs/buffered publication. |

For MC2, `ReportedCoversCommittedWrite` is the deliberate route for the
completion-before-return branch. Once the BIO is complete it is no longer
pending, and the OFD may still be unchanged; the already-observable mismatch is
committed positive data paired with a zero/error report.

## Target-specific priority and boundary check

- Partial-copy accounting is represented by distinct `requested`, `copied`,
  `committed`, `reported`, aggregate progress, OFD offset, and file-size state.
- A positive buffered fault records cumulative retained progress separately
  from the later faulting page. `Uninit` plus positive retention represents an
  earlier page already dirtied before the loop reached the faulting page;
  old-EOF rollback remains a later disposition step.
- Zero-length ext2 writes use their real pre-lock `Ok(0)` path. Ramfs still
  acquires its page-cache/metadata guards, so a far-offset zero request can
  expose the brief's size-publication question.
- Vector atomicity retains one OFD/data critical section per iovec and permits
  competitors only through ordinary TLC interleavings after a section releases.
  The invariant checks conflict-qualified OFD intervention, range-overlapping
  data intervention, and the data epochs actually captured for readv entries.
- Append pre-positioning marks an OFD intervention when it changes f_pos,
  before any copy outcome. The dedicated Scenario 3/5 hunt then forces the
  writer's completed zero-copy fault state before reporting the vector split.
- Positional entry snapshots `ofdOffset`; every real shared publication updates
  the expected value for active positional calls. `PositionalOffsetStable`
  compares the live OFD state with that independent per-call expectation.
  Positional data effects can still occur between vector entries or after a
  ramfs EOF snapshot.
- The pinned ext2/ramfs configs cannot produce EINTR. Scenario 6 deliberately
  enables a reference-only capability that can return EINTR after progress so
  the progress-blind syscall/signal decision is testable. Violations from those
  cfgs are capability analysis, not evidence that pinned ext2/ramfs reaches it.
- Sockets, pipes, `msghdr`, control messages, `SCM_RIGHTS`, `accept`,
  `preadv`/`pwritev`, RWF variants, parser arithmetic, resource exhaustion,
  exact byte/page/chunk counts, user-buffer generation stability, and
  concurrent append-range placement are intentionally absent, matching the
  brief and target guidance.
- Historical issues and source TODO/FIXME comments are mechanism context only;
  no invariant or hunt treats them as a new finding.
