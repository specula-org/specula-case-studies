# Instrumentation specification

Instrument the pinned Asterinas source to produce short per-thread timebox traces of the memfd admission and mapping lifecycle. This document specifies the handoff for harness generation. No source instrumentation, kernel execution or implementation trace collection has been performed by spec generation. The model and trace validator use source commit `0c60537098f4c2949ad2d382aaf499de72263d76`.

## 1. Trace event schema

Use per-thread preallocated buffers, then serialize outside the measured execution. Each modeled source boundary emits exactly one event with a tight `[start,end]` interval and a copied post-state payload. Preserve per-thread order. Do not add a global event counter, shared tracing mutex or blocking output on the hot path. Use existing safe OSTD timing facilities. Keep unsafe code out of `kernel/`.

Postprocessing maps raw pointers, handles and addresses to the identities below, checks missing/dropped events and clock consistency, and writes NDJSON under `../traces/` relative to `spec/`. The first row is setup. Every remaining row is an event. The interleaving of lines from different threads imposes no order: `Trace.tla` builds per-thread sequences and uses `ViablePIDs`. Globally compress timestamps while preserving equality and strict ordering. Distinct threads need comparable clocks. Never infer cross-thread order from a later Relaxed load.

### Setup row

```json
{"tag":"setup","source":"0c60537098f4c2949ad2d382aaf499de72263d76","num_pages":3,"owner_slots":6,"allow_sealing":true,"page_size":4096,"base_address":1073741824,"eof_bytes":12288,"initial_counter":0,"initial_seals":0,"inode":"memfd0","vmo":"vmo0","fd_modes":{"rw":"O_RDWR","rw2":"O_RDWR","ro":"O_RDONLY"}}
```

Create an ordinary memfd using `MFD_ALLOW_SEALING`, set its size once, and establish stable descriptors. `rw` is the created description. `rw2` and `ro` are distinct reopened file descriptions of the same inode and page cache, not duplicated descriptions incorrectly labeled as distinct. Verify actual modes with `F_GETFL` and initial seals with `F_GET_SEALS`. Record actual raw identities alongside the normalized trace in the harness manifest. The bootstrap has no mappings and a zero writable counter. For the no-ALLOW_SEALING control, use `allow_sealing=false`, `initial_seals=1`, and the corresponding configuration constant. No EXEC or huge-page flags are admitted.

Addresses in requests and owners are page indices relative to `base_address`. Offsets are page indices from file offset zero. A non-fixed map's normalized range denotes its actual selected allocation, which the harness records at `VmarMapOptions::build`. Postprocessing can join that selection to its earlier request using the operation ID. Preserve the original hint in the raw capture manifest. Fixed replacement uses the requested range. Reject traces whose selected ranges fall outside the configured address abstraction, rather than silently relocating conflicting addresses.

### Event envelope

Every event has `tag="trace"`, `event`, `thread` (`"t1"` or `"t2"`), integer `start`, integer `end`, and `state`. `SyscallEnter` additionally has `args`. Its exact request schema is:

```json
{"kind":"map","lo":0,"hi":3,"off":0,"fd":"rw","shared":true,"perms":3,"fixed":false,"seals":0}
```

Kinds are `map`, `protect`, `unmap`, `add`, `get`, and `fault`. Use the canonical irrelevant fields in `base.tla`'s request constructors. Permission masks encode R=1, W=2 and X=4. Retained MAY uses the same normalized bit positions, rather than raw kernel MAY positions. Seal masks use Linux's SEAL=1, WRITE=8 and FUTURE_WRITE=16. Empty sets are zero. Ranges are half-open. Fault requests model controlled ordinary shared WRITE faults only, with `perms=3` and a one-page range.

`CursorUnmap` and `CursorProtect` additionally require `range`: `[lo,hi]` for the actual removed or protected ordinary-page entry, normalized to page indices, or `[]` for cursor completion. Capture this from the returned fragment/range or the loop exit. A protect operation that writes unchanged flags still returns a range. Skipping absent entries happens inside that source operation and emits no separate event. An unfaulted mapping emits only the completion event, with `range=[]` and `state.ptes=[]`.

`state.local.serial`, together with `thread`, identifies the operation. It starts at one and increments on entry. The local record below is required after **every** event. Values come from the source's arguments, branch, return, local variables or normalized owner handles. The preprocessor may carry forward unchanged local fields. It must not choose new branch outcomes or permissions from model expectations.

| `state.local` fields | Capture / normalization |
|---|---|
| `pc`, `serial`, `request`, `result` | Record the executed source boundary, operation identity, normalized input and current result (`pending`, `OK`, `EPERM`, `EACCES`, `EBUSY`, `ENOMEM`). `request` has the same shape as `args`. |
| `may`, `tracked`, `checked`, `observed` | Record the actual MAY bits and tracking decision, whether the memfd check ran, and its locked seal observation. An unchecked ro/private path uses `checked=false, observed=0`. Do not infer tracking from MAY. |
| `queue`, `index`, `last_end` | Copy the source's ordered mapping snapshot and loop progress. Queue entries are `{lo,hi,perms,may}`. Index is one-based. The current source snapshot remains unchanged if earlier merging consumes an entry. |
| `cur`, `tmp`, `rest` | Normalize owned wrappers and ordered survivor handles. Zero means no handle. `rest` is an array of zero to two owner IDs. |
| `part_lo`, `part_hi`, `cut`, `side` | Record the actual intersection and split boundary, with side `left` or `right`. |
| `done`, `touched` | Ascending page arrays. `done` records completed/unchanged successful protection segments. `touched` records only mapped pages returned by the current protect/unmap cursor, including updates that leave flags unchanged. Skipped absent pages and completion add nothing. No rollback is synthesized after error. |
| `merge_side`, `neighbor`, `anchor` | Record predecessor/successor selection, normalized neighbor and the original insertion address. `merge_side` is `prev` or `next`. |
| `generation` | Allocate an admission generation when `MappedVmo::new` succeeds, under the existing VMAR lock. Splits and merges preserve per-page generations. |
| `deny_count` | Record the old value returned by the atomic denial attempt, including the failure value. It is zero before such an attempt. |

Initial values for source locals that are not yet assigned are specified in `EmptyCall`. They are carried metadata, not additional reads or synchronization. Pure oracle history (`beforeSeals` at VMAR acquisition, `denyEligible`, `quiescent`, `retired` and before/after history logs) is reconstructed by the base model. Those ghosts are not presented as directly observable kernel fields. The source observations that feed them are checked separately.

### Mandatory action-specific state

`PostState(t,event)` in `Trace.tla` defines the exact domain and values of `state`. `ValidatePostState` compares the complete record, so an omitted, extra or changed field fails replay. In addition to `local`, supply these fields when applicable:

| Field | Event selection and source of evidence |
|---|---|
| `owners` | Every event in `OwnerActions`. Emit only changed wrapper records, ordered by normalized ID. Each record has `id,role,lo,hi,off,fd,shared,perms,may,tracked,generations`. The generations array has one entry per address slot and zero outside the wrapper's current range. A destroyed wrapper emits `NoOwner`'s canonical free record. An event with no wrapper change emits `[]`. |
| `tree` | Every event in `TreeActions`. Emit installed wrapper records ordered by owner ID while holding the VMAR lock. This also checks the acquisition/release snapshots. |
| `counter` | `WritableMappingDeny`, or a tracked `MappedVmoNew`, split duplication, merge duplication, or wrapper drop. Obtain the exact post-RMW value from the old value returned by `try_update`/`fetch_add`/`fetch_sub`. On conditional failure, use the failed RMW's observed value. Do not reread the counter after the event. Untracked controls omit this field. |
| `seals` | Every event in `SealActions` and a `MemfdCheckWritable` that actually checked the inode. Copy bits while holding the existing seal mutex. |
| `vmar_owner` | `VmarLock` and `VmarUnlock`. Use the acquiring thread string or `"none"` after release. |
| `seal_owner` | `MemfdAddSealsLock` and `MemfdAddSealsUnlock`. Use the acquiring thread string or `"none"` after release. |
| `ptes` | `CursorUnmap`, `CursorProtect`, and `HandlePageFault`. Emit changed abstract entries as `{addr,generation,perms}` in ascending address order. Capture actual removed/updated flags from the cursor operations. Completion and an update with unchanged flags emit `[]`. The cursor event's `range` distinguishes those cases. |
| `dispatched` | `DispatchTlbFlush`. Emit the current cursor's ascending list of returned mapped pages. This includes updates with unchanged flags but excludes skipped absent pages. It records abstract invalidation coverage, not one IPI per page. |
| `completed` | `SyncTlbFlush`. Emit the same coverage list only after the actual synchronization returns. It certifies completion under the ordinary TLB substrate contract. It does not purport to inspect every CPU's hardware TLB. |
| `return_value` | `SyscallReturn`. Preserve the actual signed syscall result: errors are -1/-12/-13/-16, map success is the actual byte address, get success is the seal bitmask, and other successes are zero. A controlled fault uses the handler's corresponding result. |

`role` is a lifetime annotation: `free`, `reserved`, `tree`, `detached`, `split`, or `merge`. Instrumentation follows an owned token across Rust moves rather than identifying it by the temporary address of a Rust value. Assign reusable owner slots deterministically as the smallest available ID under the existing VMAR lock. Maintain raw token identity in the archival capture to audit that normalization. A successful counter RMW creates a reservation token before object construction finishes. Moving it performs no increment or decrement.

`pt` and `tlb` are an access projection. The model retains a representative old remote translation until synchronization. Record PTE changes and actual dispatch/completion receipts to justify that projection. Normal shared write faults preserve existing permission flags and enable WRITE as in `vm_mapping.rs:474-568`. Read fault-around, private faults, COW, physical contents and hardware failures are outside this projection. Do not manufacture PTE snapshots by reading the model's expected state.

## 2. Action-to-code mapping

All paths in this table are relative to `source/`. Each event name is exactly its base action name and is matched by `Trace<Action>`. Every row requires `state.local` plus the action-specific fields selected above. Emit the listed branch/no-op boundaries too. Cursor holes have no separate boundary and produce no event.

| Base action / trace event | Source location | Trigger and additional fields |
|---|---|---|
| `SyscallEnter` | `kernel/core/src/syscall/mmap.rs:16-35`, `fcntl.rs:207-224`, `mprotect.rs:11-53`, `munmap.rs:8-24`; controlled fault: `kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:9` | At entry after selecting valid supported arguments. Emit `args`, increment the per-thread operation serial and preserve input flags. A controlled WRITE fault is a harness access operation with the same entry/return envelope. |
| `MmapFdMode` | `kernel/core/src/syscall/mmap.rs:128-140` | After the FD-mode branch, including early EACCES. Copy remaining MAY bits. No VMAR state has changed. |
| `VmarLock` | `kernel/core/src/vm/vmar/vmar_impls/map.rs:269-326`, `protect.rs:21-29`, `unmap.rs:44-50` | After acquiring the write guard and selecting/copying the affected range snapshot. Emit `tree,vmar_owner`. The allocator-selection normalization adds no allocation failure branch. |
| `MemfdCheckWritable` | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80-89`, `kernel/core/src/vm/vmar/vmar_impls/map.rs:337-349` | Capture the locked seal observation and check result. Copy MAY afterward and record the actual `true` tracking branch even when MAY_WRITE was cleared. Emit `seals` only when checked. An unchecked ro/private path still emits the branch event. |
| `MappedVmoNew` | `kernel/core/src/vm/vmar/vm_mapping.rs:944-953`, `kernel/core/src/vm/page_cache/vmo/mod.rs:1199-1206` | At the acquisition RMW outcome, retaining returned old count. Emit `counter` if tracked and the new reservation in `owners` on success. Failure emits no new owner. Join the token's construction metadata to this event without moving the RMW. |
| `MemfdAddSealsLock` | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:46-47` | After acquiring the seal mutex. Emit `seals,seal_owner`. |
| `MemfdAddSealsCheck` | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:49-65` | At frozen/deny/publish branch selection. Emit `seals`. EXEC expansion is excluded. |
| `WritableMappingDeny` | `kernel/core/src/vm/page_cache/vmo/mod.rs:1212-1220` | At the conditional RMW's success or EBUSY result. Emit exact post-RMW `counter` and old `local.deny_count`. The seal mutex is still held. |
| `MemfdPublishSeals` | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:68` | After ORing requested bits. Emit `seals`. This event is separate from denial. |
| `MemfdAddSealsUnlock` | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:46-71` | At guard destruction on success, EBUSY or EPERM. Preserve the locked final snapshot and emit `seals,seal_owner="none"`. |
| `MemfdGetSeals` | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:73-75`, `kernel/core/src/syscall/fcntl.rs:219-224` | Around the short read-only locked section. Emit `seals` and retain the returned bits in `local.observed`. |
| `VmarProtectCheck` | `kernel/core/src/vm/vmar/vmar_impls/protect.rs:29-43,73-77` | At each ordered snapshot iteration and at loop end. Record hole, same-permission, MAY-check and final-result branches. Earlier completed pages remain in `local.done`. |
| `VmarProtectTake` | `kernel/core/src/vm/vmar/vmar_impls/protect.rs:45-58` | After removing the entry by its snapshot start, or taking the absent-start branch. Emit `tree,owners` and the actual intersection. |
| `VmarRemoveNext` | `kernel/core/src/vm/vmar/vmar_impls/mod.rs:386-398` | After detaching each removal entry or reaching loop end. Emit `tree,owners`. Fixed replacement then proceeds to its later seal check. |
| `VmMappingSplitRange` | `kernel/core/src/vm/vmar/vm_mapping.rs:766-785` | At each left/right split decision, even when no split is needed. Record the boundary and branch. |
| `MappedVmoDupAtOffset` | `kernel/core/src/vm/vmar/vm_mapping.rs:732,1026-1035`; `kernel/core/src/vm/page_cache/vmo/mod.rs:1227-1228` | At duplicate-owner creation and the optional increment RMW. Emit `owners` and tracked `counter`. The original still owns its full range. |
| `VmMappingSplit` | `kernel/core/src/vm/vmar/vm_mapping.rs:733-747` | After transferring the original into the left piece and finishing the right piece. Emit both changed `owners`. Moving an owner must not create an extra counter event. |
| `VmarInsertRest` | `kernel/core/src/vm/vmar/vmar_impls/protect.rs:60-66`, `mod.rs:399-409` | After inserting each survivor without merging, then once on completion of reinsertion. Emit `tree,owners`. Preserve left-before-right order. |
| `CursorUnmap` | `ostd/src/mm/page_table/cursor/mod.rs:484-522`; `ostd/src/mm/vm_space.rs:475-502`; `kernel/core/src/vm/vmar/vm_mapping.rs:830-835` | After `take_next` removes an existing ordinary-page PTE, emit its returned `range` and changed `ptes`. After `None` ends the scan, emit one completion with `range=[]`, `ptes=[]` and `local.pc="dispatch"`. Skip absent entries within the call, without events or additions to `touched`. Keep the consumed `VmMapping` alive. |
| `CursorProtect` | `ostd/src/mm/page_table/cursor/mod.rs:525-564`; `kernel/core/src/vm/vmar/vm_mapping.rs:854-871` | After `protect_next` updates an existing PTE, emit the returned `range` and changed `ptes`, even if flags remain unchanged. Emit one completion with `range=[]`, `ptes=[]` and `local.pc="dispatch"` when `None` or the loop condition ends the scan. Skipped holes add no events or `touched` pages. VMO-backed protection clears hardware W even for a WRITE permission upgrade. |
| `DispatchTlbFlush` | `kernel/core/src/vm/vmar/vm_mapping.rs:836,872`; `ostd/src/mm/vm_space.rs:535`; `ostd/src/mm/tlb.rs:76-117` | At effective dispatch after the page loop. Emit `dispatched`. The explicit second unmap dispatch is an empty-stack no-op and is included in this boundary. No completion is inferred from dispatch. |
| `SyncTlbFlush` | `kernel/core/src/vm/vmar/vm_mapping.rs:837,873`; `ostd/src/mm/tlb.rs:119-150`; `ostd/src/smp.rs:77-93,163-175` | Immediately after the actual sync returns. Emit `completed`. Keep the mapping owner through this event. |
| `VmMappingProtect` | `kernel/core/src/vm/vmar/vm_mapping.rs:875`; `kernel/core/src/vm/vmar/vmar_impls/protect.rs:69-70` | At construction of the returned object with new current permissions. Emit `owners`. Retained MAY does not change. |
| `MappedVmoDropUnmapped` | `kernel/core/src/vm/vmar/vm_mapping.rs:839-840,1039-1043` | At destruction of the consumed removed wrapper after sync. Emit the free record in `owners` and tracked post-decrement `counter`. |
| `VmarTryMerge` | `kernel/core/src/vm/vmar/vmar_impls/mod.rs:290-311`; `kernel/core/src/vm/vmar/vm_mapping.rs:1056-1086` | At predecessor and successor compatibility decisions, including failure. Record the neighbor and original insertion anchor. Check full current/MAY flags, sharing, file identity and offset continuity. |
| `MappedVmoDupForMerge` | `kernel/core/src/vm/vmar/vm_mapping.rs:1080-1102,1026-1035` | At creation of the replacement's duplicated LEFT backing owner. Emit `owners` and tracked `counter`. Both inputs still live. |
| `MappedVmoDropMergeSelf` | `kernel/core/src/vm/vmar/vm_mapping.rs:808-821,1039-1043` | When `try_merge_with` returns the replacement and drops consumed self. Emit `owners` and tracked `counter`. |
| `MappedVmoDropMergeNeighbor` | `kernel/core/src/vm/vmar/vmar_impls/mod.rs:295-310`; `kernel/core/src/vm/vmar/vm_mapping.rs:1039-1043` | After tree removal destroys the old neighbor. Emit `tree,owners` and tracked `counter`. |
| `VmarInsertMapping` | `kernel/core/src/vm/vmar/vmar_impls/mod.rs:314-324`; `map.rs:402`; `protect.rs:70` | After final publication of the inserted or merged object. Emit `tree,owners`. |
| `VmarUnlock` | `kernel/core/src/vm/vmar/vmar_impls/map.rs:404`, `protect.rs:31-80`, `unmap.rs:48-51` | Copy the final tree under the guard, then release it. Emit `tree,vmar_owner="none"`. This preserves failure effects before another operation can change the range. |
| `HandlePageFault` | `kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:9-23`; `kernel/core/src/vm/vmar/vm_mapping.rs:374-427,450-457,474-568` | Around the ordinary shared WRITE fault while the VMAR read guard remains held. Emit changed `ptes` and result. The model abstracts page-cache commit and cursor internals for this access-priming operation. |
| `SyscallReturn` | `kernel/core/src/syscall/mmap.rs:36`, `fcntl.rs:216,224`, `mprotect.rs:55`, `munmap.rs:26`; controlled fault: `kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:17-23` | At the actual result boundary. Emit `return_value` and set the local state to idle. Do not use this later timestamp as the admission linearization point. |

## 3. Special considerations

Timebox every RMW separately from seal observation/publication. Capture the RMW's returned value in a local before emitting. Capture seal and tree fields while the locks already required by the implementation protect them, and serialize copied data outside those locks. State capture must not reread an already released wrapper or a shared counter that another thread may have changed. Do not combine acquire/deny, reserve/publish, detach/revoke, dispatch/sync or sync/drop events to reduce trace size.

The model's abstract owner insertion at a successful RMW denotes the in-flight reservation. Metadata for that token can be copied from constructor arguments before the RMW and completed afterward, without creating a new synchronization edge. Preserve identity through `split_range`, both merge drops and every early return. In the small abstraction, at most four live wrappers are expected, while six IDs are available. Treat exhaustion as a capture/model-limit error, not a source EPERM or EBUSY.

Keep all kernel/user test work for the receiver. Begin with TV-1a, TV-1b and TV-2 differential cases, then collect the four protocol scenarios from `MC.tla`. Collect a trace with admission checked before FUTURE publication but returned after it. Collect final-owner removal with WRITE denial attempts before and after flush completion. Include busy combined seals, SEAL freeze, ro/private controls, noncontiguous offsets, different file descriptions, middle splits/remerge and protection prefix errors. Preserve pre/post snapshots and signed results for every attempt. Concurrent claims require attributable SMP≥2 execution with real cross-thread timebox overlap.

The default trace path is `../traces/trace.ndjson`. The `IOEnv.JSON` override selects another file. `Trace.cfg` enables `TraceMatched` and all implemented protocol predicates. It excludes the known compatibility predicates so an authentic implementation trace can be matched even when the independent Linux oracle fails. This is not a contract PASS. Kernel/trace status remains NOT_RUN until the receiver returns evidence.

`Trace.cfg` checks universal completion under replay-cursor fairness. Category B correspondence is existential: at least one ordering of overlapping events must reproduce the observations. A blocked speculative ordering can therefore violate `TraceMatched` even if another ordering matches. `TraceSearch.cfg` provides the corresponding existence check with the same actions and exact state validation. A counterexample **specifically to `TraceNotComplete`**, ending at `l > Len(TraceLog)`, is a complete matching witness. Exhausting the search without that witness rejects the trace. A timeout is inconclusive. A different invariant failure is not acceptance. Preserve both outputs when these modes differ, and do not call one blocked ordering an implementation defect.

There are no silent source actions. Missing mandatory events or fields must be repaired in capture or normalization. If source correspondence fails, investigate event timing, identity mapping, model assumptions and supported-operation scope. Do not bypass a base action, weaken `ValidatePostState`, relabel an expected compatibility failure as PASS, or alter the model to hide the input brief's known deviations.
