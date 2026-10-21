# Memfd trace instrumentation

This Category B harness captures the real Asterinas memfd, VMAR, VMO and ordinary page-table paths for Phase 3 replay. It requires Docker, access to /dev/kvm, Python 3, and the asterinas/dev:0.18.1-20260926 image. Run it from .specula-output:

```bash
bash harness/run.sh
```

The script applies the instrumentation to source commit 0c60537098f4c2949ad2d382aaf499de72263d76, builds the kernel and a minimal initramfs, runs the same C scenarios on Linux and Asterinas, and collects ../traces relative to this directory. It uses the repository's regression/common/test.h framework. The existing memfd and mmap tests do not expose the required internal boundaries, controlled write faults, or concurrent timing variants, so src/scenarios.c supplies four test groups using that framework.

Builds and test execution have explicit timeouts. The guest runs with two vCPUs and 2 GiB of RAM. Only /dev/kvm is exposed to the container. The earlycon kernel argument enables the OSTD serial sink used to drain captures. Collection requires SPECULA_TEST_EXIT 0 in addition to the OSDK exit status. Previous logs, raw captures and traces move to attempts/ before another run.

## Evidence from the completed run

The completed run produced 90 traces with 4,201 events. All 32 event types occur, and every buffer reports zero dropped events. Asterinas passed 426 assertions. Linux 7.2.8 passed 427 assertions with the Linux expectations in the same test source. raw/run.json pins the source, patch, test binaries, boot ELF, initramfs, Docker image and validator inputs with SHA-256 hashes.

validation/results.json records replay for every trace and binds each verdict to the trace and spec hashes. Regenerate validation evidence after collecting another corpus. Eighty-two traces pass Trace.cfg directly. Eight short seal/read races have a blocked speculative ordering under its universal completion property. Each has a complete matching witness under the supplied TraceSearch.cfg, with the same exact state checks and protocol invariants. Their full universal failures and existential witnesses are retained in validation/. Acceptance requires an error specifically naming TraceNotComplete and a final l equal to the number of events plus one.

raw/coverage.json records event and interval coverage. Thirty-two traces have cross-thread overlap. The strongest short traces have six overlapping pairs out of eighteen cross-thread pairs, or 33.3 percent. Those six pairs also have different observed CPU IDs. raw/protocol-coverage.json identifies these protocol witnesses:

- admission-race-10 checks unsealed admission before FUTURE publication and returns after publication while retaining MAY_WRITE.
- The final-unmap-race traces include seven denial attempts before synchronization and nine after synchronization. Their RMW receipts distinguish EBUSY from successful denial.
- Eight old-protect-race traces publish FUTURE during an old mapping's successful permission upgrade.

The tests preserve the observed TV-1a, TV-1b and TV-2 differences from Linux. A replay match means correspondence with the implementation model. It does not certify the excluded Linux compatibility predicates or fix the kernel.

## Capture and normalization

src/tla_trace.rs is copied to kernel/core/src/tla_trace.rs. Each ThreadLocal holds its own preallocated Buffer. Emission copies fixed-size records into that buffer without allocation, shared tracing locks, a global event counter, or serial output. The prctl control operation initializes or drains a buffer outside measured operations. Its controlled fault operation invokes the real VMAR write-fault handler. It exercises handler and page-table effects, without claiming a hardware fault or a physical-content check.

now() brackets source operations with fenced OSTD read_tsc() samples. State is copied after the end sample while any required source lock is still held. RMW receipts retain the returned atomic value. No counter field uses a later load. The only counter load is the bootstrap identity check before the first mapping.

Capture uses a complete Local record plus each action's specialized fields from Trace.tla PostState. Seal snapshots use the inode mutex. Owner and tree snapshots use the existing VMAR lock. Cursor receipts report actual returned ranges and changed PTE permissions. Dispatch and synchronization remain separate events. The model's representative remote TLB state is an abstraction justified by these receipts and the ordinary TLB substrate contract.

src/collect.py validates JSON, identities, access modes, bootstrap state, completion receipts, per-thread operation serials, event counts, timestamp monotonicity, and matching TSC frequencies. It assigns the smallest free owner slot in VMAR-serialized mutation order and retains unique raw tokens across Rust moves. It joins actual mmap allocation selections to their requests, rejects ranges outside the three-page window, and compresses timestamps without changing comparisons. Raw per-thread files and timestamp dictionaries remain in raw/. Identical normalized files can result from separate executions with the same ordering. Their raw clocks remain distinct.

Clock comparison assumes the common x86 KVM TSC domain. Per-event CPU IDs are archival metadata. sched_setaffinity.rs explicitly does not migrate a running thread immediately, so a successful affinity request is not CPU-placement evidence. Collection uses observed CPUs for SMP overlap and does not reject a trace merely because a worker remains on CPU 0. The modeled operations do not depend on affinity.

## Instrumentation locations

The paths in this table are relative to source/kernel/core/src unless they begin with ostd/. Line numbers describe the applied patch. Dynamic helper names expand to the exact event names in Trace.tla.

| Events | Source boundary after apply |
| --- | --- |
| SyscallEnter, SyscallReturn | syscall/mod.rs:386, 397, 404 call the dispatcher envelope. The controlled fault envelope is in tla_trace.rs:739. |
| MmapFdMode | syscall/mmap.rs:135 and 141 capture rejection and the completed mode branch. |
| VmarLock, VmarUnlock | vm/vmar/vmar_impls/map.rs:272 and 456, protect.rs:24 and 160, unmap.rs:51 and 57 bracket the write guards. |
| MemfdCheckWritable | fs/fs_impls/ramfs/memfd.rs:163 captures the locked check. vm/vmar/vmar_impls/map.rs:350 captures unchecked controls. |
| MappedVmoNew | vm/page_cache/vmo/mod.rs:1201 records the acquisition RMW. vm/vmar/vmar_impls/map.rs:363 and 410 attach failure or reservation metadata. Untracked construction has its own saved timebox. |
| MemfdAddSealsLock, MemfdAddSealsCheck, MemfdPublishSeals, MemfdAddSealsUnlock | fs/fs_impls/ramfs/memfd.rs:50, 60, 83, 101 and 116 follow the actual lock, branches, publication and release. |
| WritableMappingDeny | vm/page_cache/vmo/mod.rs:1235 records the conditional RMW and its failure value. |
| MemfdGetSeals | fs/fs_impls/ramfs/memfd.rs:133 captures the locked read. |
| VmarProtectCheck, VmarProtectTake | vm/vmar/vmar_impls/protect.rs:37, 52, 70, 91, 110 and 142 cover loop branches, detachment and completion. |
| VmarRemoveNext | vm/vmar/vmar_impls/mod.rs:421 and 455 capture detachment and loop completion. |
| VmMappingSplitRange, MappedVmoDupAtOffset, VmMappingSplit | vm/vmar/vm_mapping.rs:826, 775 and 801 record decisions, duplication and ownership transfer. |
| VmarInsertRest | vm/vmar/vmar_impls/mod.rs:277 and 441, and protect.rs:133 capture each survivor and completion. |
| CursorUnmap | ostd/src/mm/vm_space.rs:496 and 504 report take_next results through unmap_with_trace. vm/vmar/vm_mapping.rs:953 copies them into the task buffer. |
| CursorProtect | vm/vmar/vm_mapping.rs:1009, 1017 and 1025 report returned ranges, permission changes and completion. |
| DispatchTlbFlush | ostd/src/mm/vm_space.rs:571 records effective unmap dispatch. vm/vmar/vm_mapping.rs:1034 records protect dispatch. |
| SyncTlbFlush | vm/vmar/vm_mapping.rs:959 and 1037 emit only after synchronization returns. |
| VmMappingProtect | vm/vmar/vm_mapping.rs:1044 captures the returned mapping's new current permissions. |
| MappedVmoDropUnmapped | vm/vmar/vm_mapping.rs:960 selects the destruction role. Its Drop implementation at 1224 records release after synchronization. |
| VmarTryMerge, MappedVmoDupForMerge | vm/vmar/vm_mapping.rs:1248 and 1331 capture compatibility and duplicated left backing ownership. vm/vmar/vmar_impls/mod.rs:312 and 329 include absent-neighbor decisions. |
| MappedVmoDropMergeSelf, MappedVmoDropMergeNeighbor | vm/vmar/vm_mapping.rs:918 and vm/vmar/vmar_impls/mod.rs:304 and 321 classify actual Drop calls. The neighbor event receives the tree snapshot after removal. |
| VmarInsertMapping | vm/vmar/vmar_impls/mod.rs:346 captures final publication. |
| HandlePageFault | vm/vmar/vmar_impls/page_fault.rs:33 captures the handler result under the read guard. vm/vmar/vm_mapping.rs:526 and 592 supply actual changed PTE flags. |

## Adjusting and replaying

To add a field, edit Local, Owner or Event in src/tla_trace.rs, its JSON formatter, and the matching source capture site. Update collect.py and the corresponding PostState field together. ValidatePostState compares the complete state record, so captured protocol fields cannot silently go unchecked. CPU IDs, raw identities and timestamp dictionaries are separately checked archival metadata, outside the modeled state.

To add an event, follow an existing emit or owner_event call at the real source operation, include both success and rejection branches, and extend the relevant collector event set and Trace.tla wrapper. Keep source locals attached to their existing operation serial. Do not reconstruct an outcome from what the model expects.

To move a capture point, move its two timestamp samples around the source operation and copy state afterward. Preserve the lock needed for a seal or tree snapshot. For owner creation and destruction, retain the RMW's saved interval when constructor metadata or tree removal is recorded later. Do not move the atomic operation, infer its result from a later read, or merge dispatch, synchronization and destruction.

After source-site edits, format the changed Rust files with the pinned toolchain in the development container and regenerate patches/instrumentation.patch with git diff --binary from source/. Keep unrelated edits out of that patch. After emitter edits, copy src/tla_trace.rs to the source module. apply.sh is idempotent, checks the pinned commit and refuses conflicting tracked edits. clean.sh reverses only the instrumentation patch and removes a matching copied emitter. Patch application and reversal were checked against pristine copies of all fifteen changed tracked files.

Re-run bash harness/run.sh after changes. Natural scheduling can change the corpus. The collector fails if event coverage is incomplete or no trace meets the 20 percent overlap requirement with observed cross-CPU overlap. Adjust only the user-space start offsets or bounded trial count when that gate fails. A build or guest timeout needs investigation and is not retried automatically.

For a quick replay, use the installed run_trace_validation tool with work_dir set to the absolute spec/ directory, spec_file="Trace.tla", config_file="Trace.cfg", and trace_file="../traces/tv1a-write-read.ndjson". Use config_file="../harness/config/TraceNoSealing.cfg" for default-seal.ndjson. That variant changes only AllowSealing to FALSE. If universal completion fails on a concurrent trace, preserve its output and try TraceSearch.cfg. Accept only its complete TraceNotComplete witness. A timeout, another invariant failure, or an exhausted search without that witness does not accept the trace.

## Input-model correction

The original base.tla MmapFdMode action cleared MAY_WRITE even on an O_RDONLY shared WRITE rejection. The pinned source returns EACCES before that local assignment. The authentic tv1a-write-read trace therefore stopped at event 31. initial-audit/original-tv1a-validation.json preserves that failure, and initial-audit/spec/ preserves the original inputs.

patches/base-correspondence.patch records the applied correction: leave MAY unchanged on the rejected branch. Trace.tla, its exact post-state equality, the protocol invariants and the compatibility predicates are unchanged. The correction matches the source local and does not repair or conceal TV-1a, TV-1b or TV-2. Phase 3 should retain this distinction when reviewing the model.

