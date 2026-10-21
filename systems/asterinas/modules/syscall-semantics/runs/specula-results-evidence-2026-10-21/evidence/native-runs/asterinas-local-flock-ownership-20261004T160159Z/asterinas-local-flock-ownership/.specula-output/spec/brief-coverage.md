# Brief coverage for local flock ownership

This is the spec-generation self-audit for the Category B implementation model
at Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`. The tables below were
checked against the enabled entries in the written cfg files. The revision's
executed local checks are recorded in `REVISION-2026-10-05.md` and
`generation-checks/`. Linux controls, runtime instrumentation and Asterinas
execution remain `NOT_RUN`. Synthetic replay is not implementation convergence
or bug confirmation.

## Scenarios in brief section 2

All configurations use `MC.tla` and the same `base.tla` implementation actions.
Each cfg name below has the prefix `MC_hunt_` and suffix `.cfg`.

| Scenario | Configurations and fixture | Mechanism retained |
|---|---|---|
| 1. OFD identity and compatible ownership | `1_compatible_owners` (C01), `1_ofd_alias` (C02), `1_fd_reuse` | Independent opens allocate fresh identities. Dup clones the existing identity. Lookup captures its owner before later FD removal/reuse. Same-owner replacement does not count recursive acquisitions. |
| 2. Conversion retention | `2_downgrade` (C04), `2_conversion_oracle` (C05), `2_converters` (C06) | Conflict precedes replacement in Asterinas. The old mode remains on both NB failure and blocking registration. Successful replacement synchronously drops the old queue before installation. |
| 3. Registration, notification and retry | `3_release_before_registration`, `3_release_after_registration` (C07), `3_blocker_migration` (C08), `3_wake_race` (C09), plus C04 | Registration selects the first conflicting list item under the Mutex. Every drain pops before waking, releases the queue spinlock, and completes before its caller resumes. Wake, enqueue, park check, park commit, consume and retry are distinct actions. |
| 4. FD removal and final release | `4_alias_close` (C03), `4_inflight_close` (C10), plus FD reuse | Descriptor references transfer into ClosedFile. The table guard is released before the put. Captured syscall references survive FD removal. Final put, destructor entry, list acquisition, cleanup and return are separate. |
| 5. Temporary last reference | `5_temporary_last_reference` (C11), `5_extra_alias_control`, `5_close_before_control`, `5_close_after_control` (C12) | Weak upgrade creates a temporary strong reference under the list guard. Close may drain the external references before the temporary put. A last put enters the real destructor continuation while retaining the outer guard. |

C08 orders the initial SH grants A then B so its first registration gate names
the actual first blocker. Its second release waits for registration on B.
C09 programs an unlock after each successful syscall returns, but checks only
`CompatibleOwners`, `UniqueOwnerItem`, `WakeRequiresRetry` and `NoOrphanedRetry`.
A winner can keep draining the loser as it retries and re-enqueues before each
empty check (`flock.rs:139-157`, `ostd/src/sync/wait.rs:119-131`). Both threads
can receive weakly fair execution without the winner returning. Completion
would require a further scheduling assumption that the brief does not supply.
`FixtureCompletes` is therefore disabled only for C09. Its retry and drain loops
remain unbounded, and FL-CR-1 remains an open review-only question.
C11 and the alias control admit close during the observed temporary-reference
window. Some interleavings can miss that admission window. Their cfgs therefore
check conditional final destruction, not unconditional fixture completion.
The before/after controls also check fixture completion. C12-before lets close
finish before unlock starts. The general configuration additionally permits a
zero-count item to remain while its destructor waits for another guard.

Open insertion clones the new file into the table while retaining its original
Arc in `pending`. `ArcPutOpen` follows `on_open`, and `SysOpenReturn` follows
that put and any destructor (`syscall/open.rs:54-67`). MC counts completion only
at the return. `ReferenceAccounting` counts this retained open-local reference
through `PendingRefs`, including when ClosedFile drops first and decrements 2
to 1. Entry into open or flock does not require an available table guard.

`ControlResults` checks the result at every `SysFlockReturn`, using its actor
and completed operation index before a later operation can overwrite it.
C01 requires both SH acquisitions to succeed, C's first EX probe to return
EAGAIN, and its post-release probe to succeed. C02 requires repeated same-owner
EX, both UN operations (including unmatched UN), and the independent probe to
succeed. C03 requires B's first probe to return EAGAIN and its second to succeed.
All other flock returns in these controls must succeed. The four relevant cfgs
enable this assertion. C10 also requires successful returns, including C's
independent EX probe after B's syscall has returned and dropped its final Arc.

## Obligations in brief section 5

`MC.tla` extends the base, so the base obligations below are directly available
to all hunt cfgs. The unqualified names below are their exact cfg entries.

| Obligation | Definition and actual enabling cfgs | Interpretation |
|---|---|---|
| `CompatibleOwners` | `base.tla`; all 16 hunts | Distinct owners may coexist only in SH mode. Expired Weak items are still conflict-visible until removed. |
| `UniqueOwnerItem` | `base.tla`; all 16 hunts | The ordered list has at most one item per OFD. |
| `CapturedOwnerStable` | `base.tla`; all Scenario 1 hunts and `4_inflight_close` | The captured OFD is immutable even when its numeric descriptor changes. |
| `ReferenceAccounting` | `base.tla`; `1_fd_reuse`, both Scenario 4 hunts, all Scenario 5 hunts | An independently maintained strong count equals descriptor, syscall, pending open/ClosedFile and temporary references. Zero-count objects cannot become live again. |
| `WakeRequiresRetry` | `base.tla`; `2_downgrade` and all Scenario 3 hunts | An action-history safety invariant checks that wake/park/consume transitions preserve the ownership list. Only conflict-checked append/install can grant. |
| `NoOrphanedRetry` | `base.tla`; `2_downgrade`, all Scenario 3 hunts, `4_inflight_close` | A blocked live request has a retained notification, a registration on an installed/draining queue, or a popped waker awaiting notification/enqueue. Pending drains and closed stale wakers are allowed. |
| `ConversionOracle` | `MC.tla`; `2_conversion_oracle` | Only C05's final C probe is compared with `LinuxStep`. The oracle removes a differing old mode before checking conflict, under one abstract inode-spinlock operation. |
| `ConvertersDrain` | `MC.tla`; `2_converters`, as `PROPERTIES` | Both finite converter programs, including their promised unlocks, eventually finish under the explicit fixture scheduling assumptions. This is an open source question. |
| `NoRecursiveListWait` | `base.tla`; all Scenario 5 hunts | The diagnostic rejects a destructor waiting on its own still-held outer list guard. No synthetic failure action is used. |
| `FinalReleaseCompletes` | `base.tla`; both Scenario 4 hunts and all Scenario 5 hunts, as `PROPERTIES` | Once the real last put has started destruction, scheduled cleanup eventually completes. It does not require final release at FD removal. |

`FixtureCompletes` adds finite-case progress checks to C03, C04, C07, C08, C10 and
the before/after C12 controls. `FairMCSpec` gives each participating thread weak
fairness for its admitted reactive work and enabled promised admissions. It
does not make recursive Mutex acquisition enabled. No global fairness, latency
bound or permanent ownership reservation is assumed. The implementation model
can falsify a targeted obligation. Those obligations are not assumptions.

The standard `MC.cfg` enables only `MCTypeOK`, `CompatibleOwners`,
`UniqueOwnerItem` and `Structure`. Its scenario obligations are listed as
comments, and the table above records where each is actually enabled.

## Questions in brief section 6.1

| Question | Reachable setup in the written fixture | Hunt and expected diagnostic |
|---|---|---|
| FL-MC-1 / FL-SQ-1 | C06 acquires two independent SH locks, starts A's blocking EX conversion, then starts B's conversion after A is actually queued on B. Neither program releases before its own conversion succeeds. Normal queue and request-drop compensation remains enabled. | `2_converters`: `ConvertersDrain`. C05 uses `2_conversion_oracle` for the same mechanism's sequential observation. No fault injection is necessary. |
| FL-MC-2 / FL-SQ-2 | C11 finishes B's SH syscall, leaving no B syscall reference, then unlocks through independent A. After A upgrades B, the other thread may close B and drop ClosedFile before A's temporary put. The zero count starts InodeHandle destruction while A's outer guard remains held. | `5_temporary_last_reference`: `NoRecursiveListWait` and `FinalReleaseCompletes`. A safety violation can stop TLC before its liveness check completes. A later separate liveness run must preserve the reviewed enabled-property version. |

FL-TV-1 still requires Linux/Asterinas C01–C05 controls with actual kernel and
filesystem identities. The fixed source oracle is Linux v6.16.5
`4645fefac0b24d509b962c096b0327e87f34b1d2`, `fs/locks.c:1096-1137`.
FL-TV-2 still requires SMP >= 2 and direct observations of upgrade, external
puts, temporary last put, held guard and recursive attempt. A timeout or ready
flag does not establish that history. No finding ID or severity is allocated.

FL-CR-1 remains a review-only scheduling/work question. Its behavior is preserved
by `FlockItemDropRequest`, which drains the installed clone's queue outside the
list Mutex. An awakened contender can retry and re-enqueue while that drain
continues. No latency invariant or separate bug hunt is invented for it.

## Bounds, abstractions and handoff

The base has no artificial interleaving, wake or scan budget. MC counters bound
only new open/dup/close/flock admissions. Each hunt's bounds equal its finite
program's admissions, with irrelevant kinds set to zero. All cfgs have three
thread identities, three available OFD identities, four modeled FD slots and
eight queue/request identities. Unused identities do not create extra actors.
Eight tokens exceed every fixture's number of non-UN requests. MC allocates
fresh token names canonically. Trace replay uses recorded fresh identities.
The general safety cfg uses thread symmetry. Named-role and temporal hunts do
not. Counters remain in the state fingerprint because they affect admission.
There are no messages or message-buffer constraints in this Category B model.

C10's `MaxOpen` increases from 2 to 3 and `MaxFlock` from 3 to 4 for the added
C open/probe. T3 waits for T2's second completed operation, B's actual flock
return, before opening C. Slot 2 is then the lowest free FD. No additional
cleanup gate filters kernel behavior. Every other admission bound is unchanged.

List order and duplicate queue entries are explicit sequences. No queue-capacity
constraint discards a registration. Mutex waiter selection is abstracted as a
waiting PC that can acquire only a free guard. The flock waiter and its runqueue
wake bridge are explicit. Weak/Arc primitives use their atomic source semantics,
not an invented weak-memory adversary. During assignment's old-item destructor,
the old item remains in the model's list projection until installation. The
list guard excludes every competing list access during that interval.

All shipped campaigns use the shared-table clone path. The base also has the
exclusive borrowed path. `ASSUME SharedTable \/ Cardinality(Threads) = 1`
requires a separate single-participant table fixture for the lockless borrow
(`file_table.rs:355-360`). This is a domain assumption, not an entry lock guard.
`TableReady` checks only `tableOwner = Nil` at lookup and table mutations.
The positive single-thread synthetic trace covers `SharedTable = FALSE`.
FsLockContext is initialized on demand. UN without a context succeeds.

Instrumentation and TraceSpec preserve every base action boundary. Their
schema and observation requirements are in `instrumentation-spec.md`. No
runtime trace is supplied or fabricated by this revision. The 49 actions have
49 trace dispatch cases and 49 instrumentation rows. The synthetic fixtures
exercise open-local lifetime, entry under a held table guard, overlapping
candidate orders and corrupted observations. The witness search and Phase 3
status adapter are described in `instrumentation-spec.md`. Parse checks and
synthetic replay remain distinct from runtime convergence and confirmation.

Before rerunning verification after any semantic correction, the controller
must preserve old/proposed bytes, hashes, diff, reason and triggering evidence,
obtain an independent exact-version review, close material findings, and then
renew affected verification and review. The author does not self-approve a
correction. The controller holds the shared heavy-stage lock. This native worker
does not acquire it again or launch a nested pipeline. If independent review is
unavailable, return the preserved review request with an incomplete status.
The standalone revision request explicitly authorizes the local C5-C7 checks
reported here. They do not assert that a new independent campaign review or
runtime convergence has occurred.
