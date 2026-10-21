# Independent review of the initial flock trace harness

Verdict: **NEEDS_IMPROVEMENT**. The three material findings below remain open. This exact version is not approved for dependent trace/TLC verification after a correction.

Reviewer: `/root/harness_review`, an independent delegated reviewer. The reviewer did not author the harness and made no harness or production-source changes. Review date: 2026-10-05T13:09:11.340098+00:00.

The reviewed immutable input directory is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/attempt-20261005T125923-424150666/inputs`. Its manifest is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/attempt-20261005T125923-424150666/inputs.json`. The source baseline is `0c60537098f4c2949ad2d382aaf499de72263d76`, verified with `git rev-parse HEAD`. Line references to harness files below refer to that snapshot. The source patch and its actual instrumented sites were inspected against the baseline production flow.

This review implements `resources.json.corrective_review_gate`. It is static source/model/harness review only. The reviewer ran no build, guest, Linux control, test, TLC, or trace validation and acquired no resource locks. No runtime or deadlock result is established here.

## Material findings

### R1. Release events start after the operation they must bracket

`harness/src/instrument.py:70` inserts `CloseFileTableUnlock` using `simple()` after the lexical table-lock scope has ended. `instrument.py:288` drops the scheduler runqueue guard before calling `after_rq_unlock()`. That helper, at `harness/src/flock_trace.rs:205-207`, starts the `SchedulerParkCommit` or `SchedulerParkAbort` interval only then. The actual table unlock, runqueue unlock, and park dequeue are outside their recorded intervals.

A competing thread can finish `GetFileFast` after the real table unlock but before the recorded unlock interval starts. Likewise, a waking thread can finish `SchedulerUnpark` after the real runqueue release but before `SchedulerParkCommit` starts. `Trace.tla` then requires the competing event first because its end precedes the release event's start. The full base action still requires the modeled table/runqueue owner to be zero, so the real execution has no matching interleaving. This is a false trace mismatch in a supported concurrent history, not evidence of a kernel defect.

Disposition: **OPEN**. Capture each release start before the real release and its end after it. The park-commit interval must include the actual dequeue as well. Preserve the existing production lock boundaries and do not serialize competing tasks with a trace lock. Review the changed exact version before dependent verification.

### R2. Primitive-hook lookup retains addresses after allocation lifetime ends

`harness/src/flock_trace.rs:103-116` appends OFD address records permanently, and `__specula_arc_observe` at lines 212-230 uses that address lookup for every instrumented kernel Arc/Weak. The `InodeHandleDropFinish` path never retires the address. Once the actual allocation is freed, another Arc payload allocated at the same address can match the old OFD. Its clone can overwrite `saved`, while its drop or upgrade can either emit a false owner event or increment the dropped counter. Choosing the maximum normalized ID does not distinguish an unrelated allocation from a live fixture owner. C10 deliberately continues allocating after a fixture owner has completed final release.

This is a source-confirmed missing lifetime boundary. No allocator reuse was executed or observed by this reviewer. The finding does not claim that a particular initial run already hit the condition.

Disposition: **OPEN**. Retire the primitive-hook address mapping at the observed completion of owner cleanup. Keep any historical identity evidence separately. Preserve the identity while an expired Weak in the protected list can still need to be observed during cleanup, and do not add a strong reference for logging.

### R3. C08 can accept the first park marker as evidence of the second registration

`harness/src/scenarios.c:160-163` saves the worker's event count, unlocks A, waits for any new event, then waits for boundary value `5`. The buffer's `last` field is updated only for selected event kinds in `flock_trace.rs:196-198`. `SchedulerResume` and `WakerDoWait` increment the event count without clearing the preceding `SchedulerParkCommit` marker.

Consequently, the count check can finish after the worker resumes while `last` is still the first park's `5`. The next wait returns immediately, and the main thread can release B before the worker registers on B. Such a trace can match the model while failing the required blocker-migration case.

Disposition: **OPEN**. Wait for a new registration/park occurrence after the recorded first-release boundary, using an occurrence counter or event index. Check the recorded blocker identity against B before releasing B. Retain the outer case timeout and return incomplete if that boundary is not observed.

## Other limits to close before the final phase review

- The initial snapshot does not contain `harness/src/run_case.sh`, `collect.py`, or `check_traces.py`, although `run.sh:48,52,58` invokes them. Its end-to-end path is therefore incomplete. These files control guest execution, trace interpretation, dropped-buffer handling, and coverage. Their completed exact versions need independent review. `INSTRUMENTATION.md` and runtime evidence are also absent from this reviewed snapshot.
- The exported events contain normalized identities, but the `OWNERS` and `SLOTS` raw pointer maps are not exported. The instrumentation contract requires raw-to-normalized identity evidence. Preserve that evidence through a read-only scalar export without cloning an owner. The source must also reject or explicitly bound unsupported raw descriptor assumptions if it relies on `raw_fd - 2`.
- The borrowed-table path is not exercised because every current case creates worker threads first. In that path, `instrument.py:80-87` corrects only a local packet, while the `ArcPutSyscall` fallback at lines 94-95 reuses the older `saved` clone packet. A borrowed-table extension needs a correct captured reference packet and its own reviewed control. Do not report that branch as validated by these shared-table cases.
- C07-before releases A before starting the contender at all. It supplies an uncontended baseline, but does not by itself establish a close release/registration overlap. Actual trace coverage and the Category B overlap requirement remain unmeasured.
- `run.sh` checks the 10 GiB build admission threshold at startup, but does not check the 6 GiB host-memory threshold immediately before TLC. The provided validation adapter and any changed collection code are semantic inputs that should be copied and hashed with the attempt. The initial snapshot records only top-level `.tla`/`.cfg` files from `spec`, while its runtime command also depends on `spec/generation-checks/validate_trace.py`.
- Sequential Linux controls C01-C05 are required by `instrumentation-spec.md`. Their runtime versions and outputs are not part of the initial snapshot or invoked by this `run.sh`. Preserve explicit NOT_RUN status until they are executed and inspected.

## Positive source checks and their bounds

The 49 dispatcher event names and local continuation updates were compared with `Trace.tla` and `base.tla`. The adapter keeps exact post-state equality and dispatches to complete base actions. This review does not authorize weakening those guards or field checks to accommodate instrumentation errors.

The main ownership mechanism remains production code. The patch retains the FlockList Mutex around conflict search, registration, replacement and retain. A stored FlockItem keeps a Weak owner. The request's shared wait queue, old-item Drop, explicit unlock wake, removed-item Drop and request Drop remain distinct real operations. The rewritten retain closure still drops its temporary owner before returning its keep/remove decision, while the outer list guard is held. The C11 gate delays a real successful Weak upgrade without creating an extra owner Arc, and the source does not defer the corresponding last put or release the outer guard to make progress.

The private alloc-source patch preserves the actual clone fetch-add, put fetch-sub, and Weak upgrade CAS result. It records the resulting strong count before a possible synchronous destructor, and records payload cleanup after it returns. The original pinned `alloc/src/sync.rs` hash was verified as `2e11d0c0eb5ebabdbb3d045ed5b241869feeacff6eae9a8869bf48ebcf87eef1`. No host sysroot was modified by this reviewer.

For the fixture's unique thread registrations, the writer uses preallocated per-task storage, disables local interrupts while mutably borrowing that task's projection, and publishes immutable event slots with release/acquire ordering. Formatting and user copying happen after publication. No shared logger Mutex, global per-event sequence counter, or logging-induced owner clone was found on these paths. This is not a general authorization to expose the instrumentation control API outside the bounded fixture.

The reviewed OSDK scheme requests two vCPUs and 2 GiB, and `run.sh` requests a container with two CPUs, 8 GiB and 512 PIDs plus only `/dev/kvm`. Build and guest calls have outer timeouts. Actual SMP, image/kernel identity, trace overlap, coverage, successful collection, and trace replay still require execution evidence.

## Reviewed content hashes

Paths in this table are relative to the immutable `inputs` directory.

| File | SHA-256 |
|---|---|
| `harness/patches/instrumentation.patch` | `88f1118fba640e24a67a64c8c455931593cdc3ac76e4ac7b7e34dad705aaeb70` |
| `harness/src/flock_trace.rs` | `55e5d9ec2d1aade22f0f2634913ddfde9771774b5ff0cff01fff74dd97ad554e` |
| `harness/src/instrument.py` | `58b2dcaae08f8eecc75b08e3c562ad90d421d38cbd77215d5de3190148fa3485` |
| `harness/src/patch_alloc.py` | `3c98ffcd54e157af631b186675dddd80e7bec2a35c2f95e503af15f1b2865e56` |
| `harness/src/scenarios.c` | `392ae890aadfd8bac0a0962c86b7031716cb35798ce8e3fd484ce26f8204b5b9` |
| `harness/src/build.sh` | `007330f1041cb2f5071f757ad7a4dde61f19730f3e8d711a0055a48d48b5ab7a` |
| `harness/apply.sh` | `43cd880d879a363e19e68345b0aef97bfde05042345a946e6434d069ae8621eb` |
| `harness/run.sh` | `fb79c96fb930a3fb49a5e9ac34b81f3a5a10b37b4fb93d180f4602bd7ca3dee6` |
| `harness/clean.sh` | `241a1c260c373dd47b78cd90e90e3d2933232e44f0d9c9f6c5c6a138de3f3ce1` |
| `spec/base.tla` | `5114e9f43633ca283e41fec12ecd9774aef8c0f2bf89e45008834a06f71dfc08` |
| `spec/Trace.tla` | `918b7c4afe353cf32e50bc01c598b621d7ffd667b4e8ff835d4ba78716c17abf` |
| `spec/Trace.cfg` | `a3b384f0dd0c4155222692134581790b0f7097fbebb54c160bc24f114398a140` |

Additional read-only contracts were inspected from their supplied paths:

| File | SHA-256 |
|---|---|
| `spec/instrumentation-spec.md` | `beeec7c8d523d76299bee5beb9f136919465cffba680d716db95023217581f72` |
| `spec/generation-checks/validate_trace.py` | `944aeb8ea4f6af4ca7070144a006a3451ad3d06f58992a5a922f26464b515f29` |
| Shared `resources.json` | `830ddc08b8aab37da0412f916e5bc9da0f7c60871c169204d1eded197d40f26e` |
| Flock `contracts.md` | `e79b45097838deee1fba63276542191c53e1655a41f47db45ac84ba4dad25cac` |

The controller must preserve this version, the proposed corrections, their diff and reason, and renewed reviewed hashes. R1-R3 need independent closure. New runner/collector semantics need review before the affected trace/TLC run. This artifact approves no later working-tree edits implicitly.
