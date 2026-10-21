# Brief coverage audit

- Category B; revision `604948581512d83734377974d4c34adb4530f2d7`. The seven requested anchor blobs were rechecked against that revision.
- Method: read the active lines of the actual cfg files, excluding TLA comments. Full constants and enabled invariants are recorded in [cfg-audit.json](validation/cfg-audit.json).
- `MC.tla` extends `base`; all safety predicates below are inherited unchanged. No hunt replaces a predicate with a weaker alias.
- `MC.cfg` and `MC_converge_{ext2,exfat}.cfg` check core/structural safety only. Scenario invariants are disabled during convergence.

## Brief §2: scenarios

| Scenario | Targeting configurations | Mechanism and limits |
|---|---|---|
| S1, saved EOF versus delivered prefix | `MC_hunt_s1_{ramfs,ext2,exfat}.cfg`; `MC_hunt_s1_growth_{ramfs,ext2,exfat}.cfg`; `MC_hunt_s1_growth_resize_{ramfs,ext2,exfat}.cfg`; separate ramfs `_suffix` and `_offset` configs | Page-aligned initial EOF and endpoints. Shrink, pwrite extension, and ftruncate extension are separate input families. Growth allows a request of 2P after observing P, so under-reporting is reachable. Each backend uses its own guards. Both read and pread64 are inputs. |
| S2, stale preparation | `MC_hunt_s2_exfat_{accounting,extent,preserve}.cfg`; `MC_hunt_s2_shrink_{ramfs,ext2,exfat}.cfg`; `MC_hunt_s2_{ramfs,ext2}.cfg`; `MC_hunt_s2_exfat_fault.cfg` | At most two extenders and one subsequent reader; no truncate in the historical-extent hunts. Original O and returned k are retained independently of L. Separate exFAT targets prevent accounting failure from masking either settled-extent check. One stable source fault is admitted only in the composition config. |
| S3, logical length/allocation/zeros | `MC_hunt_s3_{ramfs,ext2,exfat}.cfg`; `_holes_` and `_regrow_` variants; `MC_hunt_s3_extend_zero_exfat.cfg`; `MC_hunt_s3_cold_tail_exfat.cfg` | Sequential reference workloads exercise same-page, cross-page/same-cluster, and cross-cluster endpoints with P=2, G=4, and four pages. Holes use a pre-existing nonzero subject whose freed clusters are reused. Regrow uses two resize calls. Cold-tail callback blocking is explicit. These configs cover S3 and test-route semantics, not new §6.1 findings. |
| S4, publication before acceptance | `MC_hunt_s4_empty_{ramfs,ext2,exfat}.cfg`; `_fault_` and `_read_fault_` variants; composition in `MC_hunt_s2_exfat_fault.cfg` | Zero-count calls; zero-progress, within-page, and completed-page-prefix EFAULT. User mappings remain fixed during each attempt. Cold full-page overwrite fragments can remain Uninit; initialized fragments can persist. No universal rollback oracle. |

## Brief §5: every proposed safety predicate is enabled

| Predicate defined in base.tla | Enabled hunt cfgs, read from disk | Total cfgs |
|---|---|---|
| `TypeOK` | [MC_hunt_s1_ramfs.cfg](MC_hunt_s1_ramfs.cfg), [MC_hunt_s2_exfat_accounting.cfg](MC_hunt_s2_exfat_accounting.cfg) | 40 |
| `LockExclusion` | [MC_hunt_s1_ext2.cfg](MC_hunt_s1_ext2.cfg), [MC_hunt_s1_exfat.cfg](MC_hunt_s1_exfat.cfg) | 40 |
| `SuccessfulTransferAccounting` | [MC_hunt_s1_ramfs.cfg](MC_hunt_s1_ramfs.cfg), [MC_hunt_s1_growth_ramfs.cfg](MC_hunt_s1_growth_ramfs.cfg), [MC_hunt_s2_exfat_accounting.cfg](MC_hunt_s2_exfat_accounting.cfg) | 19 |
| `UnreportedReadSuffixUnchanged` | [MC_hunt_s1_ramfs_suffix.cfg](MC_hunt_s1_ramfs_suffix.cfg) | 10 |
| `ControlledOffsetAccounting` | [MC_hunt_s1_ramfs_offset.cfg](MC_hunt_s1_ramfs_offset.cfg), [MC_hunt_s4_empty_ext2.cfg](MC_hunt_s4_empty_ext2.cfg), [MC_hunt_s4_read_fault_ramfs.cfg](MC_hunt_s4_read_fault_ramfs.cfg) | 19 |
| `SettledReadableExtent` | [MC_hunt_s2_exfat_extent.cfg](MC_hunt_s2_exfat_extent.cfg), [MC_hunt_s2_shrink_exfat.cfg](MC_hunt_s2_shrink_exfat.cfg), [MC_hunt_s3_exfat.cfg](MC_hunt_s3_exfat.cfg) | 10 |
| `ExtendersPreserveExtent` | [MC_hunt_s2_exfat_preserve.cfg](MC_hunt_s2_exfat_preserve.cfg) | 4 |
| `SuccessfulResizeContract` | [MC_hunt_s3_exfat.cfg](MC_hunt_s3_exfat.cfg), [MC_hunt_s3_extend_zero_exfat.cfg](MC_hunt_s3_extend_zero_exfat.cfg), [MC_hunt_s3_regrow_ext2.cfg](MC_hunt_s3_regrow_ext2.cfg) | 8 |
| `HoleZeros` | [MC_hunt_s3_holes_exfat.cfg](MC_hunt_s3_holes_exfat.cfg), [MC_hunt_s3_regrow_ramfs.cfg](MC_hunt_s3_regrow_ramfs.cfg), [MC_hunt_s3_regrow_ext2.cfg](MC_hunt_s3_regrow_ext2.cfg) | 10 |
| `EmptyWriteNoEffect` | [MC_hunt_s4_empty_ramfs.cfg](MC_hunt_s4_empty_ramfs.cfg), [MC_hunt_s4_empty_exfat.cfg](MC_hunt_s4_empty_exfat.cfg), [MC_hunt_s4_empty_ext2.cfg](MC_hunt_s4_empty_ext2.cfg) | 3 |
| `AcceptedExtent` | [MC_hunt_s4_fault_ramfs.cfg](MC_hunt_s4_fault_ramfs.cfg), [MC_hunt_s4_fault_ext2.cfg](MC_hunt_s4_fault_ext2.cfg), [MC_hunt_s4_fault_exfat.cfg](MC_hunt_s4_fault_exfat.cfg) | 3 |

## Brief §6.1: reachable setup

| Finding | Required schedule | Config and target |
|---|---|---|
| MC1, ramfs stale count | Start L=C=P. Read samples S=P, K=P. Truncate publishes C=L=0 before the reader acquires cache; VmoIoBegin takes its successful zero-copy branch and BackendReturn retains K=P. For growth, request 2P, save K=P, then extend before copying; D can be 2P. | `MC_hunt_s1_ramfs.cfg` and `MC_hunt_s1_growth_ramfs.cfg`; accounting. `_suffix` and `_offset` isolate the other two observables. No copy-limit fix is reverted. |
| MC2, exFAT stale reservation | B prepares end=3P, releases W; A prepares end=2P while L=P, lowering C. Both copy orders remain enabled. B can copy zero at O=2P and still publish/return its saved extent. A publishing last can regress L; B publishing last can leave L>C. A subsequent reader remains enabled after both writes complete. | `MC_hunt_s2_exfat_accounting.cfg`, `_extent.cfg`, `_preserve.cfg`; corresponding single target. `_shrink_exfat.cfg` permits truncate before or after preparation. `_exfat_fault.cfg` adds one fixed source fault. |

## Target priorities and contract boundaries

- Priority 1: K, original O, clamped copyO, VMO effective end, cursor D, accepted byte offsets, destination tags, result, and offset are separate. Positive short reads are permitted; equality of request and return, whole-call snapshots, and EOF-at-return are never required.
- Priority 2: L, C, exFAT allocation A and rounded cluster count, ext2 backend npages, page initialization, and backing bytes are distinct. SettledReadableExtent allows C>L and checks missing cold-page paths as well as L>C. Byte-zero checks use only isolated histories with no concurrent mutation; overlap invalidates the byte oracle, not the operation.
- Priority 3: AcceptedExtent checks ramfs zero-progress append-at-EOF against Linux v6.12 generic_perform_write (initial inaccessible source fails before write_begin), and isolated ext2/exFAT EFAULT against their unchanged logical-size rule. It makes no claim that all failed partial writes roll back, all copied fragments commit, or exFAT cache/allocation preparation must roll back. General partial-copy result differences remain TV6 and issue #711 context.
- Priority 4: read holds the description offset mutex through return; pread64 and pwrite64 do not change position. Positional checks compare the return transition’s before/after position, allowing intervening shared reads. Successful read checks also compare advancement with independently delivered D.
- Every normal continuation is unbounded in MCThreadStep. Only new syscall inputs and pre-established inaccessible suffixes consume counters. Thread symmetry is sound because all threads can issue the same inputs and their payload tags are renamed with them. Counters remain in the view; there are no messages or buffer constraints.

## Test and review routes retained

| Brief entry | Treatment |
|---|---|
| TV1, known sequential EOF padding | The unlimited ramfs/exFAT writers remain in base; no independent novelty hunt. Later syscall tests should use sentinel buffers across/at EOF. Partial S3 reads may also encounter this behavior. |
| TV2, public exFAT resize | Actual missing updates are represented, with isolated successful-resize checks. Fixture/syscall confirmation still required. |
| TV3, backing bytes in holes | S3 holes configs permit truncate-to-zero, reuse of the same subject clusters, extending write, then settled read. Reuse and nonzero backing must be established by the fixture; a fresh zero disk cannot confirm this mechanism. |
| TV4/TV5, failed extender and empty positional write | S4 configs enable qualified AcceptedExtent and EmptyWriteNoEffect. Linux/backend comparison remains a test requirement. |
| TV6, page acceptance | VmoCollectBegin/CollectedPage preserve batch-before-copy ordering. Uninit faulted fragments stay uninitialized; earlier/initialized fragments remain represented. Read faults retain independently observed D. Error counts are not universally forced to equal D. |
| TV7, cold-tail lock dependency | ExfatBackendReadBlocked retains the W owner and a blocked PC. Partial endpoint configs can reach it. CHECK_DEADLOCK FALSE accommodates finite workloads and this recorded test-only concern; no liveness/fairness claim is made. A bounded guest completion test is required. |
| CR1/CR2, trait/docs mismatches | Record caller/range obligations; no artificial device, allocation, timestamp, or impossible kernel-zero-source EFAULT injection. |

## Abstraction and validation limits

- One regular-file inode; non-O_APPEND buffered calls on valid descriptors. No vectored I/O, signals/restart, direct I/O, mappings/page faults, durability, device errors, or resource exhaustion.
- Tagged cells represent uniform byte runs. P=2 is a model page, not a claim that kernel pages are two bytes. A trace mapping must preserve every modeled offset, endpoint, fault boundary, and tag; unsupported measurements must be rejected rather than rounded.
- At most 32 model pages; supplied configurations use at most four. Read vector capacity counts spanned pages, while write capacity rounds transfer length. An unaligned write can therefore require multiple batches within one segment. The validated model now preserves this distinction and its fault-time initialization effects.
- Existing dirty pages are retained without background writeback/eviction. exFAT backing reuse is one reachable fixture, not a claim about every allocation. The model distinguishes new initialization from previously cached data and preserves current tail/decommit behavior.
- Phase 3 revalidated 111 guest traces against all mandatory post-state fields and corrected VMO collection capacity. `MC.cfg` completed without violations, then all 40 unchanged hunting configs ran. See `bug-report.md` and `output/trace-round1-results.json` for observed defects, exact coverage, and remaining guest-confirmation gaps. The earlier generation-only checks remain in `validation/README.md`.

## Phase 3 coverage qualifications

- `MC_hunt_s4_read_fault_{ramfs,ext2,exfat}.cfg` contains only faulting reads. Successful-transfer and successful shared-offset clauses have no successful read completions in those inputs; positional before/after offset preservation remains applicable.
- `MC_hunt_s3_cold_tail_exfat.cfg` retains blocked cold-tail paths and checks no liveness property. Its completed resize path is a same-size request; its HoleZeros predicate has no newly exposed zero region to check. No-violation results do not establish cold-tail completion or zero filling.
- `MC_hunt_s1_growth_resize_exfat.cfg` checks read accounting but does not enable SuccessfulResizeContract. Its passing result does not establish that extension changes file size.
- The 18 BFS violations are mapped to eight Case C findings in `output/case-classification.json`. `bug-report.md` distinguishes model counterexamples, existing guest observations, and unconfirmed fixtures.
