# Spec Generation Review: asterinas-syscall-buffered-file-size-read-consistency

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 4/5 | All four scenarios have extensions and targeting configurations; 40 hunt configs exist. S4 lacks a partial write fault into an already initialized page. |
| Action Design | 3/5 | Implementation-derived names and the ramfs/exFAT lock windows are preserved. VMO write batching does not always follow the source control flow. |
| Source Annotations | 4/5 | All 42 actions have source references. Complex actions such as VmoCollectBegin and VmoCopyPage use aggregate ranges rather than citations for each branch and update. |
| Invariant Coverage | 3/5 | All 11 brief safety predicates are enabled somewhere. The read-fault hunts leave failed read offset behavior unchecked. |
| MC Spec Structure | 5/5 | Only nondeterministic request admission and fault setup consume budgets; reactive continuations remain unrestricted. Thread symmetry is sound, counters remain in the view, and convergence/hunt invariants are separated. No message constraint or kernel liveness claim is needed. |
| Trace Spec Design | 4/5 | Mandatory post-state checks, per-thread timeboxes, and no silent state-changing actions. TraceMatched is universal; ambiguous replay needs the documented Trace_witness.cfg fallback before a mismatch is concluded. |
| Instrumentation Mapping | 4/5 | All 42 actions have matching wrappers and mapping rows with capture timing and fields. The batch mismatch below prevents a faithful event sequence for some admitted inputs. |
| Logical Correctness | 3/5 | SANY and all three structural convergence runs pass. A source-derived batching check fails, and a mutation demonstrates vacuous failed-read coverage. |

## Overall: 30/40

## Issues Found

- **[P2] Preserve the actual write batch capacity before copying.**
  `base.tla:401-414` collects the entire remaining anonymous write range when `Backend = "ramfs"`.
  The source allocates the batch using `ceil(write_range.len()/PAGE_SIZE)` and limits each collection by that capacity (`kernel/core/src/vm/page_cache/vmo/mod.rs:579-582,678-690,780`).
  An unaligned range can touch more pages than this capacity even with fewer than 32 pages.
  For `P=2, L=C=2, O=1, N=2, fault=0`, the source prepares page 0 and faults on its first copy before preparing page 1.
  The model requires both pages to be prepared first, materializing page 1 despite the fault.
  This changes cache state and the mandatory instrumentation sequence; `brief-coverage.md:64` incorrectly treats the 32-page maximum as sufficient to guarantee one batch.
  Retain the actual per-call batch capacity and split collection/copy at its boundary.
  A [source-derived TLC probe](output/review-specgen/UnalignedFaultWorkload.log) reaches `collectNext=0, collectEnd=2` with native capacity 1 and exits 12 at depth 9; the [aligned control](output/review-specgen/AlignedFaultWorkload.log) exits 0.

- **[P2] Add a failed-read offset assertion to the read-fault hunts.**
  `MC.tla:78` supplies only faulting reads; with the supplied initial EOF, each finishes with EFAULT.
  `SuccessfulTransferAccounting` checks only successful calls (`base.tla:707-710`), and the read arm of `ControlledOffsetAccounting` also requires success (`base.tla:714-719`).
  Thus the invariants enabled by `MC_hunt_s4_read_fault_{ramfs,ext2,exfat}.cfg:21` cannot detect an erroneous offset advance on EFAULT.
  The implementation propagates the error before updating the offset (`kernel/core/src/fs/file/inode_handle.rs:285-290`).
  In isolated copies, changing the error path to advance position by D still passes all three supplied read-fault hunts, each with exit 0.
  Adding `EFAULT read => positionAfter = startPosition` catches `D=1, result=-1, position 0->1`: [mutant exit 12](output/review-specgen/offset-mutant-with-oracle.log), [unmodified control exit 0](output/review-specgen/offset-control-with-oracle.log).
  Preserve this source-specific error rule without imposing a universal partial-I/O rollback contract.

- **[P2] Exercise initialized-page partial-write acceptance in S4.**
  The brief explicitly distinguishes initialized pages from rejected Uninit fragments (`modeling-brief.md:66-72,149`).
  Every `MC_hunt_s4_fault_*.cfg` starts with `InitialSize=P`, only page 0 warm, and `WriteLimit=1`.
  `FailedWriteWorkload` writes at `O=P` (`MC.tla:74-77`), so ext2/exFAT copy faults occur in newly prepared pages.
  The S2 composition admits only zero-progress source faults (`MC.tla:79-81`), which cannot cover a retained partial fragment either.
  Consequently, the initialized-page EFAULT branch at `base.tla:499-517`, corresponding to `vmo/mod.rs:740-745`, has no targeting partial-copy hunt.
  Add a case such as `InitialSize=2P, InitialWarm={0,1}, O=P, N=P, fault=1`, alongside the cold case, and check the backend-specific accepted contents.
  `AcceptedExtent` currently checks only logical size (`base.tla:742-746`), so its existing wiring alone does not establish this distinction.

Validation was run against copies of the reviewed modules; the reviewed inputs and source anchors remain unchanged.
The seven anchor hashes match the generation receipts for revision `604948581512d83734377974d4c34adb4530f2d7`.
All three modules pass SANY.
Structural convergence completes with 8,131 ramfs, 4,967 ext2, and 5,665 exFAT distinct states, all exit 0.
A valid synthetic read trace passes; changing its observed D is rejected with exit 13.
The [runner](output/review-specgen/run_checks.py), [results and commands](output/review-specgen/results.json), [input hashes](output/review-specgen/inputs.json), and [action/invariant wiring audit](output/review-specgen/wiring.json) retain the evidence.
These checks establish artifact behavior and source-level discrepancies; no kernel execution or implementation bug confirmation was performed.

## Verdict: NEEDS_IMPROVEMENT
