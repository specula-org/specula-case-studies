# Bug Report — asterinas-memfd-seal-mapping-admission

## Summary

The specification converged in one round on source `0c60537098f4c2949ad2d382aaf499de72263d76`. All 90 implementation traces have complete matching executions, and `MC.cfg` exhausted 40,745 distinct states to depth 157 without an enabled invariant violation or deadlock. No model, configuration, invariant, instrumentation or trace changes were needed during this validation.

All four scenarios and all nine supplied hunting configurations were checked. Four configurations expose two known implementation defects: TV-1 / AST-73 and TV-2 / AST-75. TV-1a and TV-1b share one cause and are reported together as MC-1. No additional defect was found within the supplied bounds. The five protocol configurations completed without violations. All passing hunts reached depth greater than 25, so the workflow's simulation condition did not apply.

The result supports modeling admission, sealing, retained eligibility, mapping ownership and ordinary revocation as one protocol. Structural convergence does not establish Linux compatibility: the compatibility counterexamples remain failures.

## Evidence and interpretation

The source and 53 recorded artifact hashes matched `harness/raw/run.json` at initialization. All 90 trace hashes matched the harness's recorded corpus. The trace validator calls the full base actions and compares the exact action-specific post-state, including syscall results, seal observations, RMW receipts, mapping owners, cursor ranges and flush completion.

Eighty-two traces pass `TraceMatched` directly. Eight seal/read traces (`04`, `08`, `10`, `14`, `16`, `18`, `26`, `28`) fail its universal completion requirement on a speculative ordering. Layered debugging at TLC level 4 shows the read blocked by the other thread's seal mutex. Every affected trace has a complete alternative witness under the existing `TraceSearch.cfg`, with only `TraceNotComplete` violated and `l=10` after nine events. This is a Category B abstraction gap between universal completion and existential correspondence. No checks were weakened. Both outcomes are retained in [trace acceptance](output/validation/trace-acceptance.json) and the adjacent logs.

The existing Phase 2.5 execution recorded 426 successful Asterinas assertions and 427 Linux assertions, with different expected outcomes for the known defects. Those counts show that the harness captured its expectations, including failures of Linux compatibility. This phase verified the artifacts and replayed their traces. It did not rebuild or rerun either kernel. The host reference was Linux 7.2.8. Controlled Asterinas faults invoke the real handler but do not prove physical memory contents or inspect hardware TLBs. See [instrumentation](../harness/INSTRUMENTATION.md), [guest log](../harness/logs/guest.log), [Linux log](../harness/logs/linux.log), and [manifest](../harness/raw/run.json).

All Asterinas source line numbers below refer to the uninstrumented pinned commit, available with `git show HEAD:<path>`. Applied tracing shifts working-copy line numbers. The Linux contract uses the saved v6.18 sources, whose relevant functions were also checked against the public tagged source. The persistent-findings lookup returned no reusable records. The AST identifiers come from the input brief's known controls, not a reuse receipt.

## Bug 1: Post-seal read-only mappings retain writable accounting

- **ID and prior attribution:** MC-1, known TV-1 / AST-73.
- **Classification and severity:** Case C, Medium. Valid read-only admission or later WRITE sealing fails. These executions do not demonstrate unauthorized write access.
- **Scenario:** Admission determines eligibility and accounting.
- **Invariant violated:** `ReadOnlyAdmissionCompatibility`, independently `ReadOnlyAdmissionAfterWrite` and `ReadOnlyAdmissionNoFalseBusy`.
- **Config:** `MC_hunt_scenario1.cfg`, `MC_hunt_TV1a.cfg`, and `MC_hunt_TV1b.cfg`.
- **Counterexamples:** [TV-1a, 14 states](output/validation/MC_hunt_TV1a.out), [TV-1b, 22 states](output/validation/MC_hunt_TV1b.out), and [scenario 1, 14 states](output/validation/MC_hunt_scenario1.out).

### Trace Summary

TV-1a starts without mappings or seals. States 2–8 add WRITE: state 5 changes the counter from zero to denied, and state 6 publishes WRITE. States 9–11 enter an O_RDWR shared READ mapping and acquire the VMAR lock. State 12 observes WRITE and clears MAY_WRITE, but retains `track=TRUE`. State 13 attempts writable-owner acquisition against the denied counter and receives EPERM. State 14 records the failed mapping at VMAR unlock, violating the read-only admission oracle.

TV-1b publishes FUTURE in states 2–7 without denying the counter. States 8–11 admit an O_RDWR shared READ request, clear MAY_WRITE and retain tracking. State 12 increments the counter to one. States 13–17 publish the mapping and return successfully. States 18–20 begin a quiescent WRITE addition. State 21 returns EBUSY despite zero semantically write-eligible owners. State 22 records unchanged FUTURE seals and the failed addition. This is the second consequence of the same tracking decision.

### Root Cause

`MemfdInode::check_writable` removes MAY_WRITE for a post-seal shared READ mapping. Its caller enters the tracking branch using the old MAY bits and returns literal `true` after the helper changes those bits. `MappedVmo::new` consequently acquires writable accounting for an ineligible mapping. WRITE makes that acquisition fail. FUTURE permits the acquisition, which later makes WRITE denial fail with EBUSY.

The Linux v6.18 reference removes VM_MAYWRITE for the read-only case and acquires writable mapping accounting only when `is_shared_maywrite` remains true. This supports the oracle's distinction between current READ permissions and future write eligibility. See [memfd admission](https://github.com/torvalds/linux/blob/v6.18/mm/memfd.c#L373-L407) and [mapping accounting](https://github.com/torvalds/linux/blob/v6.18/mm/vma.c#L2731-L2744).

The validated Asterinas trace `tv1a-write-read.ndjson` records READ admission returning `-1` at line 15, while its O_RDONLY control succeeds. `tv1b-future-read.ndjson` records successful READ admission at line 17, a rejected WRITE upgrade at line 22, and WRITE sealing returning `-16` at line 28. The existing Linux log records successful READ admission and successful WRITE sealing for those respective cases.

### Affected Code

- `kernel/core/src/vm/vmar/vmar_impls/map.rs:337`: The tracking decision remains true after the seal check changes MAY_WRITE.
- `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80`: The seal check removes future write eligibility for read-only admission.
- `kernel/core/src/vm/vmar/vm_mapping.rs:944`: Construction acquires accounting according to that tracking decision.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:1199`: Acquisition rejects a denied counter, and the denial path at line 1212 rejects a positive counter.

### Recommendation

Derive tracking from the effective MAY_WRITE result after the seal check. Preserve the separate atomic admission/denial arbitration and old mappings' retained eligibility. Validate both post-WRITE READ admission and post-FUTURE READ followed by WRITE sealing before treating a repair as verified.

## Bug 2: Seal-rejected fixed replacement removes the existing mapping

- **ID and prior attribution:** MC-2, known TV-2 / AST-75.
- **Classification and severity:** Case C, Medium. A rejected request removes the caller's existing mapping and can cause subsequent accesses to fault. No cross-process corruption or privilege escalation is established.
- **Scenario:** Rejected operations have operation-specific effects.
- **Invariant violated:** `SealRejectedReplacement`.
- **Config:** `MC_hunt_TV2.cfg`.
- **Counterexample:** [31 states](output/validation/MC_hunt_TV2.out). The concurrent BFS workers reached search depth 37 before stopping. That statistic is distinct from the counterexample length.

### Trace Summary

States 2–11 create a three-page shared writable mapping with one tracked owner. States 12–17 publish FUTURE, preserving the existing mapping's eligibility. States 18–20 enter a shared writable MAP_FIXED replacement and acquire the VMAR lock. State 21 detaches the old mapping. States 22–24 prepare full-range removal without survivors. No PTE was faulted into this counterexample, so state 25 completes the cursor with empty coverage. States 26–27 dispatch and complete the ordinary flush boundary. State 28 drops the old owner and reduces the counter to zero. State 29 reaches the later seal check. State 30 observes FUTURE and rejects the incoming mapping with EPERM. State 31 records that all three previously mapped pages are now absent.

### Root Cause

`VmarMapOptions::build` processes `FixedReplace` through `alloc_free_region_exact_truncate` before calling the memfd seal check. The removal helper splits survivors, unmaps the selected range, completes ordinary TLB revocation and consumes the removed owner. The later EPERM return cannot restore the old mapping. This mechanism is independent of MC-1 because the writable request fails inside `check_writable`, before new-owner accounting.

Linux v6.18 checks the selected seal conflict in `do_mmap` before calling `mmap_region`. The oracle applies to this already-active seal conflict, not every mmap error. It does not require rollback of Linux-permitted partial mprotect effects. See [the early seal check](https://github.com/torvalds/linux/blob/v6.18/mm/mmap.c#L485-L491).

The validated `tv2-full.ndjson` trace records the replacement's `-1` at line 32, followed by `mprotect` returning `-12` at line 37. The partial replacement records the same outcomes at lines 38 and 43 of `tv2-partial.ndjson`, with only the middle page removed. The existing Linux log records EPERM for both incoming replacements and successful protection of the still-present old ranges.

### Affected Code

- `kernel/core/src/vm/vmar/vmar_impls/map.rs:289`: Fixed replacement removes the old range before the later check at line 342.
- `kernel/core/src/vm/vmar/vmar_impls/mod.rs:377`: Exact-range allocation consumes intersecting mappings through its removal loop.
- `kernel/core/src/vm/vmar/vm_mapping.rs:830`: Ordinary removal completes TLB synchronization before the consumed mapping drops.
- `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80`: The already-active FUTURE seal rejects the incoming shared WRITE request after removal.

### Recommendation

Resolve this seal-admission conflict before destructive replacement while preserving admission/denial ordering. Retain full and partial replacement controls. Do not add a blanket rollback requirement to mprotect or unrelated mmap failures.

## Not Reproduced

No additional protocol violation or deadlock was found in the following completed searches. State counts are per configuration and overlap across searches.

| Scenario | Config | Generated / distinct states | Complete depth | Result |
|---|---|---:|---:|---|
| Standard convergence | `MC.cfg` | 64,042 / 40,745 | 157 | No enabled structural or seal-protocol violation. |
| Admission protocol | `MC_hunt_scenario1_protocol.cfg` | 1,750 / 1,674 | 58 | Retained eligibility and seal publication passed. |
| Sealing overlaps | `MC_hunt_scenario2.cfg` | 10,205 / 6,466 | 88 | Retained eligibility and seal publication passed. |
| Initial SEAL control | `MC_hunt_scenario2_default_seal.cfg` | 3,340 / 1,984 | 84 | Existing SEAL blocks additions without blocking legal mappings. |
| Split, merge and final removal | `MC_hunt_scenario3.cfg` | 51,856 / 32,382 | 157 | Identity, ownership, retained eligibility and revocation checks passed. |
| Failure effects | `MC_hunt_scenario4.cfg` | 231 / 223 | 68 | Protection prefix and ordinary revocation checks passed. The replacement oracle is checked separately. |

The compatibility searches stopped on their enabled failures:

| Config | Generated / distinct states | Search depth at stop | Violated predicate | Disposition |
|---|---:|---:|---|---|
| `MC_hunt_scenario1.cfg` | 819 / 781 | 22 | `ReadOnlyAdmissionCompatibility` | MC-1, TV-1a witness. |
| `MC_hunt_TV1a.cfg` | 15 / 14 | 14 | `ReadOnlyAdmissionAfterWrite` | MC-1. |
| `MC_hunt_TV1b.cfg` | 23 / 22 | 22 | `ReadOnlyAdmissionNoFalseBusy` | MC-1, second manifestation. |
| `MC_hunt_TV2.cfg` | 70 / 68 | 37 | `SealRejectedReplacement` | MC-2. |

Every run used BFS, a 30-minute maximum, 2 GiB heap, 1 GiB off-heap and enabled deadlock checking. Runs finished naturally or stopped at an invariant failure before the budget expired. Original constants, scripts, symmetry and predicates were retained. [Machine-readable run results](output/validation/mc-results.json) identify every task, log hash, exit and result. The adjacent request and launcher records preserve the exact options.

## Coverage and limits

The checks retain the distinction between admission time and return time. The existing `admission-race-10` trace observes unsealed eligibility, overlaps FUTURE publication and returns with MAY_WRITE intact. Eight old-protect traces overlap FUTURE publication with an eligible mapping's successful upgrade. Final-unmap traces include seven denial attempts before synchronization and nine after synchronization, with exact RMW receipts distinguishing EBUSY from successful denial. These observations are indexed in [protocol coverage](../harness/raw/protocol-coverage.json).

The model has two callers, three ordinary page slots, six reusable owner IDs, one fixed-size memfd and bounded client scripts. It counts reserved, detached and temporary owners, and preserves mapping generations across splits and merges. Its longest plans issue nine mapping-thread requests and seven seal-thread requests. The searches exhaust those workloads, not arbitrary repeated syscalls or larger configurations.

Ordinary TLB completion is a substrate assumption supported by source ordering and captured completion receipts. This does not prove the hardware, general COW, page reclamation, arbitrary scheduling progress, or excluded operations. Private and O_RDONLY maps remain admission controls. MAP_SHARED_VALIDATE, exec sealing, hugetlb, GUP/DMA, mremap, fork/exec/exit, concurrent resizing and other filesystems remain outside scope.

No Case A invariant repair or Case B model repair was needed during convergence or hunting. The pre-existing harness-stage FD-mode correspondence correction remains recorded in [the changelog](changelog.md). The machine-readable findings in [findings.json](findings.json) contain exactly these two model-checking findings. No kernel fix or before/after repair verification was performed.

Generated trace-exploration modules and binaries were archived in [trace-exploration.zip](output/validation/trace-exploration.zip) with a [hash index](output/validation/trace-exploration.sha256.json), then removed by `clean_traces`. This archive also preserves the older exploration modules named in the harness manifest. Original counterexample logs and JSON remain under `output/validation/`.
