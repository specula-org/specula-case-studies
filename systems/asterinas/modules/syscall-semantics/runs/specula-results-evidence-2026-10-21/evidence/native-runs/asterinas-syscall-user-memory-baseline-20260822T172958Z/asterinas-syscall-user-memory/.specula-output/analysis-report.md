# Code Analysis Report: Asterinas Syscall User-Memory Semantics

## 1. Result and Scope

The analysis selects one Category B shared-state model for all in-scope syscalls. The common transaction is:

`Idle -> Snapshot -> Validate -> Transfer -> EffectCommitted -> Copyout -> Return/Error/Restart`

An immutable operation profile defines where Linux places the effect and copy-out commit points. This is necessary because Linux permits some receive, batch-send, and accept effects to precede a later user-memory error. The required property is a documented per-syscall outcome, not universal rollback or an exact byte-for-byte partial count.

**Conclusion**: yes, the pinned source contains direct ordering/accounting mismatches capable of violating those contracts. IP UDP publishes before a fallible source copy completes; Unix datagram retains a non-peek selected message after destination-copy failure; socket batch/header copy-out writes input-only fields; SCM_RIGHTS installs before number publication; and zero-length Unix records and datagram-socket SCM cycles lack bounded accounting/collection. Runtime tests are still required to record concrete user-visible traces on this export.

The source contains several mechanisms that warrant formal or runtime verification:

- fallible copies carry partial counts that some adapters erase before updating syscall progress or a shared file offset;
- vectored file I/O invokes one file operation per iovec, releasing transaction-level serialization between entries;
- socket backends place queue publication/consumption on different sides of the user copy;
- `recvmsg` and `sendmmsg` copy out more of the saved input structure than Linux does;
- SCM_RIGHTS installs an FD before its complete numeric value is copied to user memory;
- zero-length Unix datagram/seqpacket records consume no accounted queue capacity, and seqpacket readiness ignores such records;
- the SCM Unix-socket cycle guard covers stream sockets but omits datagram sockets, allowing a strong-reference ownership cycle;
- restart decisions are made above the layer that knows whether progress was committed.

These are source-level findings or open mechanism questions. No model checking, kernel build, QEMU run, or new regression execution was part of Code Analysis. Section 11 records the resulting verification status.

### Scope decisions

| Included | Excluded |
|---|---|
| `read`/`write`, positional and vectored variants | Missing syscalls or unsupported flags as findings by themselves |
| `sendmsg`, `recvmsg`, `sendmmsg`, `recvfrom`, `accept` | Harmless errno differences |
| User-copy, iovec, socket, file-offset, page-cache, control-message, and file-table helpers | Parser-only defects without shared state; route to test/fuzz/code review |
| Concurrent header mutation, remap/protection, signal, timeout, and restart | TLB/RCU/page-table lifetime as a second model |
| Linux v6.16 observable contracts | Exact Linux implementation scheduling or byte-copy count |

[Issue #711](https://github.com/asterinas/asterinas/issues/711) is historical mechanism evidence only. It is not a model-checkable finding in this report or the modeling brief.

## 2. Method, Baseline, and Coverage

The requested `specula-codex:code-analysis` workflow was followed:

1. **Category classification**: Category B, because local threads concurrently mutate mappings and kernel objects shared by syscall attempts.
2. **Phase 1, Reconnaissance**: mapped dispatch, user-memory, VFS, socket, file-table, and restart boundaries.
3. **Phase 2, Bug Archaeology**: read issue and PR discussions, screened exact-history commits, and separated historical evidence from current targets.
4. **Phase 3, Deep Analysis**: traced each syscall through implementation-specific commit and error paths, with parallel analysis of user-copy, file I/O, and socket paths followed by primary-agent verification.
5. **Phase 4, Modeling Brief**: grouped findings by mechanism, chose one automaton, and assigned model-check, test, or code-review verification.

### Baseline pin

| Item | Result |
|---|---|
| Source | Non-Git export at the user-supplied `source/` path |
| Reference commit | `604948581512d83734377974d4c34adb4530f2d7` |
| Parent | `b29ae5acedd3ef83dc73a01d4d1f40d8fef82292` |
| Commit date/subject | 2026-08-08, `Add aster-code-review benchmark problem:500-508` |
| History checkout | `/home/chin39/Documents/asterinas-dev`, read only |
| Identity check | All 53 repository files cited by the deliverables hashed against `COMMIT:path`; 53 matched, 0 mismatched |
| Deep-analysis slice | 40 files; 7,514 Rust code lines and 11,356 physical lines |

The 53-file identity check covers every source and test path cited below. The 40-file LOC slice is the principal implementation set; adjacent helpers/tests were verified but excluded from that code-size measurement.

### Shared state and synchronization map

| State | Primary owner | Synchronization/commit boundary | Evidence |
|---|---|---|---|
| Raw syscall arguments and return | Per-thread user context | Typed casts at dispatch; result written after handler | `kernel/core/src/syscall/mod.rs:200-299,324-345,379-399` |
| Top-level/nested user metadata | User process threads | Fallible copies; no userspace cooperation lock | `kernel/core/src/context.rs:88-117`; `kernel/core/src/util/iovec.rs:78-117` |
| Mapping/perms | Process VMAR | VMAR read/write locks per fault or map change, not for the whole copy | `kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:8-24`; `kernel/core/src/vm/vmar/vmar_impls/unmap.rs:44-52`; `kernel/core/src/vm/vmar/vmar_impls/protect.rs:17-80` |
| Open-file position | `InodeHandle` shared by duplicated FDs | `offset` mutex around one `FileLike::read/write` call | `kernel/core/src/fs/file/inode_handle.rs:272-320` |
| File/page-cache contents | Filesystem inode and cache pages | Filesystem/page locks; helpers often return `Result<()>` | `kernel/core/src/vm/page_cache/vmo/mod.rs:533-566,702-759` |
| Stream/datagram queues | Socket-family implementation | Family-specific mutex/spinlock and queue operation | `kernel/core/src/util/ring_buffer.rs:31-145`; `kernel/libs/aster-bigtcp/src/socket/bound/udp.rs:140-191` |
| File descriptor table | Thread/process file table | Table write lock around each insert/remove | `kernel/core/src/fs/file/file_table.rs:190-205` |
| Restart decision | Thread-local original register and signal path | Handler returns `ERESTARTSYS`; signal delivery may rewind PC | `kernel/core/src/thread/task.rs:71-105`; `kernel/core/src/process/signal/mod.rs:48-62,145-158` |

## 3. Phase 1: Structural Reconnaissance

### 3.1 Dispatch to user memory

The dispatch macro casts six raw argument words to each handler's declared types (`kernel/core/src/syscall/mod.rs:200-299`). Architecture tables select the handler, and `handle_syscall` writes either the returned value or negative errno (`kernel/core/src/syscall/mod.rs:324-345,379-399`). No general user-memory transaction is introduced at dispatch.

`Context::user_space` borrows the current task's VMAR (`kernel/core/src/context.rs:33-37`). `CurrentUserSpace::reader` and `writer` deliberately preserve Linux-style delayed validation: they create a fallible view without checking whether pages are currently mapped (`kernel/core/src/context.rs:88-117`). OSTD checks the active page table and the userspace address bound, then constructs a raw fallible reader/writer (`ostd/src/mm/vm_space.rs:153-195`).

The resulting call shape is:

`raw args -> typed syscall -> CurrentUserSpace -> VmReader/VmWriter -> FileLike/Socket -> page cache/ring/transport -> syscall result -> signal/restart`

Message calls add nested steps:

`CUserMsgHdr snapshot -> address/control/iovec snapshots -> payload effect -> address/control/top-level output`

### 3.2 Fallible copy contract

OSTD's primitive contract returns `(Error, copied_count)` and advances both cursors by that count (`ostd/src/mm/io/mod.rs:271-292,332-362`). Architecture copy code returns the actual copied length (`ostd/src/mm/io/copy.rs:169-213`).

Typed `read_val` and `write_val` restore their local cursor after failure (`ostd/src/mm/io/mod.rs:494-549,769-811`). That restoration does not undo bytes already written to user memory. The kernel-level conversion from `(ostd::Error, usize)` to `Error` discards the count (`kernel/core/src/error.rs:209-219`). Each caller must therefore either retain the tuple itself, stage the operation, or define a safe effect point before using `?`/`Into`.

### 3.3 Fault and remap interleaving

A recoverable kernel copy fault invokes the injected user page-fault handler; an unhandled fault redirects execution through the exception table (`ostd/src/mm/fault/mod.rs:54-86`). The handler consults current VMAR mappings under a read lock (`kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:8-24`). Concurrent `munmap` and `mprotect` take the VMAR write lock for their own update (`kernel/core/src/vm/vmar/vmar_impls/unmap.rs:44-52`; `kernel/core/src/vm/vmar/vmar_impls/protect.rs:17-80`).

No VMAR lock spans the entire raw user copy. A cooperating thread can therefore change a later page or nested metadata after a view is created. This is expected concurrency, not itself a defect. The verification question is whether every captured range and later effect remains safe and follows its syscall profile.

## 4. Linux Contract Matrix

The reference is observable Linux behavior, checked against v6.16 source and current man-pages. The matrix intentionally avoids a universal rollback rule.

| Operation | Required progress/offset contract | Post-effect copy-out contract | Primary reference |
|---|---|---|---|
| `read`, `write` | A positive completed transfer is reported as short/success; a shared open-file position follows completed progress | No metadata copy-out | [read(2)](https://man7.org/linux/man-pages/man2/read.2.html), [write(2)](https://man7.org/linux/man-pages/man2/write.2.html) |
| `pread64`, `pwrite64` | Same partial-progress rules; the shared file position is unchanged | No metadata copy-out | [pread(2)](https://man7.org/linux/man-pages/man2/pread.2.html) |
| `readv`, `writev` | Iovecs are processed in order as one atomic data-transfer operation relative to competing regular-file I/O; a short result stops later vectors | No metadata copy-out | [readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html), Linux `lib/iov_iter.c:1447-1494` |
| `preadv`, `pwritev` | Ordered vector transfer at the explicit offset; no shared-position update | No metadata copy-out | [readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html) |
| `sendmsg` stream | Positive committed bytes may be returned short | No top-level `msghdr` output | [sendmsg(2)](https://man7.org/linux/man-pages/man2/sendmsg.2.html), Linux `net/socket.c:2488-2652` |
| `sendmsg` datagram | Message publication is atomic; a source-copy fault must not publish a partial datagram | No top-level output | [sendmsg(2)](https://man7.org/linux/man-pages/man2/sendmsg.2.html), Linux `net/unix/af_unix.c:2390-2450` |
| `sendmmsg` | Return counts entries whose contractual `msg_len` output completed; Linux can send the current message and then fail its `msg_len` write, leaving at most one uncounted current send | Only `mmsghdr.msg_len` is output; `vlen` is clamped to `UIO_MAXIOV` | Linux `net/socket.c:2664-2730`; [sendmmsg(2)](https://man7.org/linux/man-pages/man2/sendmmsg.2.html) |
| `recvmsg` | Payload/message/control effects may precede a later output fault; no universal receive rollback | Outputs are name length/address, flags, control data/length; input pointer/iovec fields are not rewritten | Linux `net/socket.c:2739-2830`; [recvmsg(2)](https://man7.org/linux/man-pages/man2/recvmsg.2.html) |
| `recvfrom` | Receive can commit before address copy-out; address failure may replace a positive payload result | Address bytes and actual address length only | Linux `net/socket.c:2205-2238`; [recvfrom(2)](https://man7.org/linux/man-pages/man2/recvfrom.2.html) |
| `accept` | Connection acceptance precedes address copy-out; on copy-out failure Linux closes the new file and installs no FD | Peer address/length only | Linux `net/socket.c:1904-1969`; [accept(2)](https://man7.org/linux/man-pages/man2/accept.2.html) |
| SCM_RIGHTS receive | Earlier fully published FDs may remain, but a particular FD is installed only after its complete number is copied | Descriptor numbers/control header; later header quirks do not justify installing an unpublished number | Linux `fs/file.c:1325-1364`, `net/core/scm.c:330-379` |

Linux also snapshots iovec metadata into kernel memory and validates each captured range. It does not promise one generation across racing userspace writes (`lib/iov_iter.c:1355-1494`). The model must permit mixed generations while enforcing bounds and ownership safety.

## 5. Phase 2: Bug Archaeology

### 5.1 Coverage

- 30 complete issue threads were read; their 115 discussion comments were counted again on 2026-08-23.
- Classification: 19 confirmed defects, 7 acknowledged design/tracking limitations, and 4 reports not confirmed as implementation defects.
- Model relevance: 15 threads provide mechanism history; 15 were excluded from this state machine.
- 74 commits touching the pinned core paths were screened. Seven bug/hardening commits and three correctness-contract commits were analyzed in detail; 64 were style, refactor, feature, or otherwise non-bug changes.
- 129 open PR titles were screened. Six in-scope or adjacent fixes and two close candidates were deep-read, including 94 comments/reviews/discussion items.

Historical fixes justify scenarios but are not Phase 4 model-check targets.

### 5.2 Retained issue history

| Issue | Verified conclusion from full thread | Use here |
|---|---|---|
| [#711](https://github.com/asterinas/asterinas/issues/711) | Partial user-copy progress can be lost by current I/O abstractions; maintainers reconfirmed the umbrella issue in 2026 | Historical evidence only; explicitly excluded from MC findings |
| [#1223](https://github.com/asterinas/asterinas/issues/1223) | VmReader/VmWriter I/O-refactor tracker, closed as stale after providing architecture provenance | Reference for copy-contract migration |
| [#1136](https://github.com/asterinas/asterinas/issues/1136) | VFS API could not express fallible-copy progress cleanly; addressed by [PR #1153](https://github.com/asterinas/asterinas/pull/1153) and [#1156](https://github.com/asterinas/asterinas/pull/1156) | Scenario 1 mechanism history |
| [#1245](https://github.com/asterinas/asterinas/issues/1245) | Oversized iov lengths could drive allocation failure/panic; fixed through centralized iovec checks in [PR #2397](https://github.com/asterinas/asterinas/pull/2397) | Bounds history |
| [#1327](https://github.com/asterinas/asterinas/issues/1327) | `recvmsg` inherited the oversized-iovec allocation problem; fixed with the same helper checks | Nested-vector bounds history |
| [#1324](https://github.com/asterinas/asterinas/issues/1324) | Message-buffer capacity arithmetic overflow; fixed by `985813c7f974` | Message-size bounds history |
| [#1530](https://github.com/asterinas/asterinas/issues/1530) | Duplicate/continuation of VM atomic-mode lock concerns in #1420; exact full-class closure is not established by one patch | Fault/lock architecture reference only |
| [#1458](https://github.com/asterinas/asterinas/issues/1458) | Write-only x86 mapping repeatedly faulted/hung; fixed by [PR #1461](https://github.com/asterinas/asterinas/pull/1461) | Fault-path history, not current target |
| [#392](https://github.com/asterinas/asterinas/issues/392) | Early I/O-buffer design discussion identified the need for explicit fallible user-copy abstractions | Architecture provenance |
| [#2209](https://github.com/asterinas/asterinas/issues/2209) | Inverted mapping offsets caused merge underflow; fixed by [PR #2213](https://github.com/asterinas/asterinas/pull/2213) | Range-arithmetic history |
| [#3181](https://github.com/asterinas/asterinas/issues/3181) | `sendfile` dropped unwritten data after a short sink write; fixed by [PR #3191](https://github.com/asterinas/asterinas/pull/3191) | Partial-progress commit history |
| [#1542](https://github.com/asterinas/asterinas/issues/1542) | Earlier report of `sendfile` data truncation; later covered by the short-write fix | Partial-progress history, no separate target |
| [#1554](https://github.com/asterinas/asterinas/issues/1554) | Pipe writes up to `PIPE_BUF` were not atomic; fixed by [PR #1559](https://github.com/asterinas/asterinas/pull/1559) | Transaction-granularity history |
| [#1578](https://github.com/asterinas/asterinas/issues/1578) | Initial syscall-restart infrastructure landed in [PR #1598](https://github.com/asterinas/asterinas/pull/1598) | Restart mechanism history |
| [#506](https://github.com/asterinas/asterinas/issues/506) | The original close premise was partly disputed; the final discussion records an older FD cleanup/ownership problem fixed by `8df51ab00100` | Ownership history only |

### 5.3 Excluded issue history

| Issues | Reason for exclusion |
|---|---|
| [#1175](https://github.com/asterinas/asterinas/issues/1175), [#1334](https://github.com/asterinas/asterinas/issues/1334), [#1391](https://github.com/asterinas/asterinas/issues/1391), [#1194](https://github.com/asterinas/asterinas/issues/1194) | Reachable unwrap/error handling at unrelated syscall/futex/exit sites; static regression candidates without this model's shared state |
| [#1060](https://github.com/asterinas/asterinas/issues/1060) | `Pod` padding/union soundness is a type/soundness audit, not syscall commit ordering |
| [#1619](https://github.com/asterinas/asterinas/issues/1619) | Incorrect `memcpy` data traced to missing FPU state save; hardware-context state is outside this model |
| [#1587](https://github.com/asterinas/asterinas/issues/1587) | Futex waiter cleanup is a separate synchronization protocol |
| [#646](https://github.com/asterinas/asterinas/issues/646) | Report was a test interpretation error: nonblocking `EAGAIN` was treated as EOF; explicit false-signal example |
| [#179](https://github.com/asterinas/asterinas/issues/179) | Missing network-operation tracker; missing operations are excluded by instruction |
| [#1938](https://github.com/asterinas/asterinas/issues/1938) | Open SMP abort report has no confirmed causal link to user-memory progress |
| [#1420](https://github.com/asterinas/asterinas/issues/1420) | Duplicate mechanism context retained through #1530; modeling its full lock/atomic-mode protocol would create a second state machine |
| [#1535](https://github.com/asterinas/asterinas/issues/1535), [#1534](https://github.com/asterinas/asterinas/issues/1534), [#1540](https://github.com/asterinas/asterinas/issues/1540), [#1541](https://github.com/asterinas/asterinas/issues/1541) | Page-fault logging/fork/atomic-context hangs and panics; useful static lock audit history but not partial-progress protocol evidence |

### 5.4 Exact-history commits

| Commit/PR | Historical finding | Modeling relevance |
|---|---|---|
| [`668997ab51a9`](https://github.com/asterinas/asterinas/commit/668997ab51a93597d9d74d781c5498f116299cd9), [PR #1026](https://github.com/asterinas/asterinas/pull/1026) | Stale VM snapshot/check-map misuse | Concurrent mapping history; not an MC target |
| [`d9eccdcfbe1d`](https://github.com/asterinas/asterinas/commit/d9eccdcfbe1db71587f5f14b3d45ef337203ad51), [PR #1158](https://github.com/asterinas/asterinas/pull/1158) | Remote TLB state could retain stale mappings | Confirms mapping concurrency is delicate; TLB protocol excluded |
| [`4f0acddfd45e`](https://github.com/asterinas/asterinas/commit/4f0acddfd45e617460e32cf49e423410a7f712a6), [PR #1877](https://github.com/asterinas/asterinas/pull/1877) | Invalidation could return before remote acknowledgement | Same exclusion; reference only |
| [`5b7637eac334`](https://github.com/asterinas/asterinas/commit/5b7637eac33453dcfc9c927031edcca8a6f41e74), [PR #1948](https://github.com/asterinas/asterinas/pull/1948) | Page-table traversal lifetime needed RCU protection | Mapping lifetime history |
| [`54fbdcf059bb`](https://github.com/asterinas/asterinas/commit/54fbdcf059bbc25afc8eb7ff518157718fbf3750), [PR #1948](https://github.com/asterinas/asterinas/pull/1948) | Detached page-table subtree updates needed stray marking | Mapping serialization history |
| [`5a38c61c497a`](https://github.com/asterinas/asterinas/commit/5a38c61c497a00f281f2ac59eff82556e1eec905), [PR #2099](https://github.com/asterinas/asterinas/pull/2099) | Page ownership discriminator could be mutated through an API | Range/ownership hardening history |
| [`c851f054bf51`](https://github.com/asterinas/asterinas/commit/c851f054bf51a9665d6c875998710288caf33fa2), [PR #2605](https://github.com/asterinas/asterinas/pull/2605) | Cursor mapping silently replaced an existing PTE before hardening | Mapping action precondition history |
| [`f56d2f3bad8f`](https://github.com/asterinas/asterinas/commit/f56d2f3bad8ff769b50507356c0306488926d1cb), [PR #2391](https://github.com/asterinas/asterinas/pull/2391) | Documented delayed buffer validation in `CurrentUserSpace` | Current contract provenance |
| [`79b3f6889262`](https://github.com/asterinas/asterinas/commit/79b3f6889262bc606e38f0f3f313b3cbe8933d41), [PR #1948](https://github.com/asterinas/asterinas/pull/1948) | Made page-table RCU lifetime explicit in types | Correctness-contract reference |
| [`8b8970a1ccd7`](https://github.com/asterinas/asterinas/commit/8b8970a1ccd7fb80546096dc50fe7509d16cf1a7), [PR #3365](https://github.com/asterinas/asterinas/pull/3365) | File privilege invalidation exposed deferred inode-serialization requirements | Shared-file serialization reference |

### 5.5 Open PR audit

All listed changes are absent from the pinned baseline. State is as observed on 2026-08-23.

| PR | Baseline-relevant conclusion | Disposition |
|---|---|---|
| [#3720](https://github.com/asterinas/asterinas/pull/3720) | Fixes null-base/nonzero-length and original-range iovec validation; current head `7acf712904a6` | Test/code review; parser/range detail, not a standalone MC finding |
| [#3582](https://github.com/asterinas/asterinas/pull/3582) | Allows valid short virtio-fs results that baseline rejects; current head `033d22dee645` | Test reference for short-progress adapters |
| [#3576](https://github.com/asterinas/asterinas/pull/3576) | Moves restart production toward wait primitives; current head `8e02d0e94230` | Scenario 5 design evidence, not proof of a baseline duplicate |
| [#3481](https://github.com/asterinas/asterinas/pull/3481) | Addresses append and seal races; current head `d4d1cd3a22ac` | Scenario 1 shared-offset/append evidence |
| [#3297](https://github.com/asterinas/asterinas/pull/3297) | Introduces an ext2 rollback guard; current head `97ae1dfadc84` | Code-review target for error-path coverage |
| [#2613](https://github.com/asterinas/asterinas/pull/2613) | Changes page-table cursor invariants | Adjacent only; excluded as a second state machine |
| [#3574](https://github.com/asterinas/asterinas/pull/3574) | Partial scalar `getsockopt` output | Close candidate screened out: no in-scope shared effect |
| [#3643](https://github.com/asterinas/asterinas/pull/3643) | Kernel page-flag conversion hardening | Close candidate screened out: page-table ownership protocol |

## 6. Phase 3: Deep Source Analysis

### 6.1 Metadata snapshot and iovec import

`sendmsg` copies one top-level `CUserMsgHdr`, then separately copies the address, control messages, and iovec entries before invoking the socket (`kernel/core/src/syscall/sendmsg.rs:22-59`). `recvmsg` similarly captures the header and builds the writer array before receive (`kernel/core/src/syscall/recvmsg.rs:19-41`). The nested helper paths are in `kernel/core/src/util/net/socket.rs:100-179`.

`copy_iovs_and_convert` enforces at most 1024 entries, reads each `UserIoVec` separately, caps an aggregate, filters entries it considers empty, and retains the resulting fallible readers/writers (`kernel/core/src/util/iovec.rs:59-117`). The `MultiRead`/`MultiWrite` implementations correctly aggregate tuple partial counts across entries (`kernel/core/src/util/iovec.rs:175-230,232-327`).

Concurrent changes can occur between any entry snapshots. Linux does the same kind of metadata import and does not define a same-generation view. The safety contract is:

- each action uses only complete captured values;
- every accessed range is bounded and valid under the operation's delayed-access rules;
- no later kernel copy-out rewrites input-only captured fields;
- a remap-induced transfer fault follows the selected partial/effect profile.

The current `IoVec::is_empty` treats `base == 0` as empty even when `len > 0` (`kernel/core/src/util/iovec.rs:44-56`). That suppresses a range that Linux validates and is covered by baseline-absent PR #3720. It is a direct test/code-review candidate rather than a TLA+ concurrency scenario by itself.

### 6.2 File data, vector atomicity, and offsets

Scalar `read`/`write` form one user writer/reader and pass it to `FileLike` (`kernel/core/src/syscall/read.rs:21-44`; `kernel/core/src/syscall/write.rs:21-44`). `pread64`/`pwrite64` pass an explicit offset (`kernel/core/src/syscall/pread64.rs:22-43`; `kernel/core/src/syscall/pwrite64.rs:22-41`).

For an offset-aware `InodeHandle`, scalar `read` holds the offset mutex across `read_at` and increments it by the returned count. Scalar `write` does the same around `write_at` (`kernel/core/src/fs/file/inode_handle.rs:272-320`). Positional I/O bypasses the shared offset (`kernel/core/src/fs/file/inode_handle.rs:323-353`). This is a usable local commit point if every backend returns positive progress already written/copied.

The vector handlers do not call one vector-aware file method. They loop over captured entries and call `file.read`, `file.write`, `file.read_at`, or `file.write_at` for each (`kernel/core/src/syscall/preadv.rs:101-180`; `kernel/core/src/syscall/pwritev.rs:102-175`). For non-positional operations, the offset mutex is therefore released between entries. A competing operation can linearize between two iovecs of one syscall. The source contains explicit TODOs that this does not provide Linux vector atomicity (`kernel/core/src/syscall/preadv.rs:107-112,159-164`; `kernel/core/src/syscall/pwritev.rs:108-113,155-160`).

`O_APPEND` reads `path().size()` and assigns that value to the open-description offset before calling the filesystem (`kernel/core/src/fs/file/inode_handle.rs:308-318`). Positional append similarly replaces the supplied offset (`kernel/core/src/fs/file/inode_handle.rs:345-353`). The source FIXME states that this is not atomic with another appender. PR #3481 is baseline-absent design evidence.

#### Page-cache progress boundary

`Vmo::read` performs page-by-page `read_fallible(writer)?`, converting a tuple error to a plain error (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-566`). Anonymous writes do the same (`kernel/core/src/vm/page_cache/vmo/mod.rs:671-699`). Backed writes explicitly observe a positive `written_size`, mark an already-up-to-date page dirty, then return only `Error` (`kernel/core/src/vm/page_cache/vmo/mod.rs:702-759`).

Ext2 calls the page cache through a `Result<()>` API and returns the full requested count only after success (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-271`). On a write error it rolls back newly allocated length/block state, but that path cannot restore bytes overwritten inside an existing file. Ramfs can expand metadata before its page-cache copy and then return an error (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:694-757`). The outer `InodeHandle` advances `filePos` only on `Ok(len)`.

This is the count-erasure mechanism for Scenario 1. The report does not turn issue #711 into an MC target. The model instead asks forward-looking compound questions about how the same adapters interact with vector splitting, concurrent file operations, and restart.

#### Ring-buffer progress boundary

`ProducerU8Ext` commits a ring write only after all fallible segments return success (`kernel/core/src/util/ring_buffer.rs:31-67`). A wrapped `pick_fallible` can complete the first physical segment and fault in the second while returning a plain error (`kernel/core/src/util/ring_buffer.rs:82-109`). `ConsumerU8Ext` advances the head only after `pick_fallible` succeeds (`kernel/core/src/util/ring_buffer.rs:129-145`). Pipe writes call this adapter (`kernel/core/src/fs/pipe/common.rs:464-489`).

Thus a user destination can contain a faulting chunk's positive prefix while the logical queue head remains unchanged, or queue memory can contain a prefix before the producer tail remains unchanged. This is retained as count-erasure mechanism evidence associated with historical #711. The model does not require an exact physical-ring prefix or make this known mechanism a standalone MC target.

### 6.3 Socket-family commit profiles

| Path | Copy/effect order in baseline | Contract consequence |
|---|---|---|
| IP TCP send | Socket callback retains partial count and commits it as a short send (`kernel/libs/aster-bigtcp/src/socket/bound/tcp_conn.rs:373-443`) | Byte-stream profile can satisfy positive partial progress |
| IP TCP receive | Receive callback consumes/returns positive partial count (`kernel/libs/aster-bigtcp/src/socket/bound/tcp_conn.rs:446-535`; `kernel/core/src/net/socket/ip/stream/connected.rs:72-108`) | Byte-stream profile can satisfy positive partial progress |
| IP UDP send | Reserves/enqueues a sized buffer, then copies; the source warns that copy error still sends an unexpected packet (`kernel/core/src/net/socket/ip/datagram/bound.rs:86-116`; `kernel/libs/aster-bigtcp/src/socket/bound/udp.rs:140-167`) | Direct test candidate for violation of datagram publication atomicity |
| IP UDP receive | Non-peek receive removes the packet before the copy callback (`kernel/libs/aster-bigtcp/src/socket/bound/udp.rs:169-191`; `kernel/core/src/net/socket/ip/datagram/bound.rs:55-83`) | Copy-out error can coexist with consumed datagram, a Linux-permitted receive profile |
| Unix datagram send | Copies the complete payload into a kernel `Vec` before queue insertion (`kernel/core/src/net/socket/unix/datagram/message.rs:54-101`) | Source fault publishes no message |
| Unix datagram receive | Copies from the front message, then pops only after success (`kernel/core/src/net/socket/unix/datagram/message.rs:174-218`) | On fault, user bytes may change while the message remains queued; Linux v6.16 non-peek frees the selected datagram (`net/unix/af_unix.c:2493-2602`) |
| Unix stream/seqpacket | Uses ring helpers in fast and auxiliary paths (`kernel/core/src/net/socket/unix/stream/connected.rs:116-281,284-359`) | A faulting logical chunk leaves ring indices unchanged; prior successful chunks are returned. Exact chunk boundaries are not a new MC target |
| Vsock receive | Temporarily removes packets, copies, and restores/finishes based on result because `MultiWrite` cannot report the faulting packet's partial count (`kernel/core/src/net/socket/vsock/transport/connection/recv.rs:20-70`) | Explicit compensating design; retained as a non-finding/reference |

The divergence is not evidence for one universal socket rule. The model uses two effect granularities:

- stream/regular byte transfer: a positive committed prefix may return short; the model does not prescribe backend chunk boundaries;
- datagram publication: all-or-none send; non-peek receive has an explicit consume point, while `MSG_PEEK` never consumes.

### 6.4 Post-effect copy-out footprint

The baseline `CUserMsgHdr` contains pointers, input lengths, and output fields (`kernel/core/src/util/net/socket.rs:80-98`). After a successful receive, Asterinas updates output values in its saved copy and writes the entire structure back (`kernel/core/src/syscall/recvmsg.rs:47-58`). Linux v6.16 copies back the name length/address, flags, and control length, not the input pointer/iovec fields (`net/socket.c:2760-2813`).

Similarly, `sendmmsg` reads a full `CMmsgHdr`, sends one message, changes `msg_len`, then writes the whole structure (`kernel/core/src/syscall/sendmmsg.rs:49-76`). Linux writes only `entry->msg_len` and clamps the loop to `UIO_MAXIOV` (`net/socket.c:2664-2720`).

This creates two concurrency questions not present in the Linux copy-out footprint:

1. another thread can update an input-only field after snapshot and have the stale saved value written back after the socket effect;
2. an inaccessible byte belonging only to an input field can cause a post-effect `EFAULT` that Linux would not encounter.

Linux itself permits post-effect failures at contractual output fields. For `sendmmsg`, one current message can be sent but not included in the returned completed-message count if `msg_len` copy-out fails. The invariant therefore limits the fault field and hidden-effect count; it does not require rollback.

`recvfrom` and `accept` also put the effect before address output (`kernel/core/src/syscall/recvfrom.rs:29-48`; `kernel/core/src/syscall/accept.rs:55-80`). Asterinas accepts a connection, copies the peer address, and only then inserts the new socket into the file table. On address fault, dropping `connected_socket` leaves no installed FD. This matches Linux's no-FD-install cleanup shape even though the peer connection was accepted and closed.

### 6.5 SCM_RIGHTS and file-table ownership

Outgoing SCM_RIGHTS first resolves all supplied descriptor numbers to file objects (`kernel/core/src/net/socket/unix/ctrl_msg.rs:86-114`). On receive, `FileMessage::write_to` writes a control header, inserts each file into the current file table, and then writes the new descriptor number (`kernel/core/src/net/socket/unix/ctrl_msg.rs:116-152`). If the number copy faults, that newly inserted entry is not removed.

The enclosing `ControlMessage::write_all_to` catches the error, sets `MSG_CTRUNC`, and returns the bytes accumulated before the failed message (`kernel/core/src/net/socket/util/message_header.rs:104-129`). `recvmsg` can consequently proceed to its top-level output and return success while a file-table entry exists whose complete numeric identifier was not published.

Linux `receive_fd` reserves a number, writes it to user memory, and only then calls `fd_install`; on that number's copy fault it releases the reservation (`fs/file.c:1325-1364`). Linux can retain earlier fully published FDs if a later control/header write fails (`net/core/scm.c:330-379`). The correct invariant is therefore `Installed(fd) => NumberPublished(fd)`, not atomic rollback of the entire control buffer.

Consumed auxiliary file objects are moved out of the queued message for a non-peek receive (`kernel/core/src/net/socket/unix/ctrl_msg.rs:284-313`). Dropping undispatched objects releases their `Arc`s, so the source analysis does not claim a kernel-memory leak. The candidate is stranded process-visible ownership through the installed file-table entry.

`pipe2` provides adjacent ownership history: it inserts both FDs, drops the table lock for user copy-out, and tries to close the exact descriptors on failure; a FIXME requests reserved descriptors because another thread can observe/reuse slots in between (`kernel/core/src/syscall/pipe.rs:37-63`). This is reference evidence, not an additional modeled syscall.

### 6.6 Signal, timeout, and restart

On syscall entry the thread records the original return register (`kernel/core/src/thread/task.rs:83-90`). A handler that returns `ERESTARTSYS` is converted to `EINTR`; when a user handler has `SA_RESTART`, signal delivery restores the original register and rewinds the syscall instruction (`kernel/core/src/process/signal/mod.rs:48-62,145-158`).

The in-scope syscall handlers translate `EINTR` to `ERESTARTSYS` themselves (`kernel/core/src/syscall/read.rs:36-39`; `kernel/core/src/syscall/write.rs:36-39`; `kernel/core/src/syscall/sendmsg.rs:58-64`; `kernel/core/src/syscall/recvmsg.rs:32-40`; `kernel/core/src/syscall/recvfrom.rs:32-39`; `kernel/core/src/syscall/accept.rs:55-62`). Socket handlers contain FIXMEs that a configured timeout should suppress restart (`kernel/core/src/syscall/sendmsg.rs:60-62`; `kernel/core/src/syscall/recvmsg.rs:36-38`; `kernel/core/src/syscall/recvfrom.rs:35-37`; `kernel/core/src/syscall/accept.rs:58-60`).

The common `wait_events` helper retries only `EAGAIN` and returns other operation results; interruption comes from its poller/wait path (`kernel/core/src/process/signal/poll.rs:341-390`). This reduces the obvious replay surface, and no specific baseline backend was established to return `EINTR` after positive commit. The report therefore does not claim a confirmed duplicate. MC-5 asks whether any composed path can reach restart with nonzero `committedProgress`. PR #3576 is design evidence that restart responsibility remains distributed in the baseline.

### 6.7 Bounds, zero length, aliasing, and arithmetic

Confirmed review/test candidates:

- iovec count is bounded to 1024, but null base with nonzero length is incorrectly filtered as empty (`kernel/core/src/util/iovec.rs:44-62,78-117`);
- aggregate iovec bytes are capped at `isize::MAX`, whereas Linux caps at `MAX_RW_COUNT` (`kernel/core/src/util/iovec.rs:63-76`; Linux `lib/iov_iter.c:1464-1494`);
- `sendmmsg` iterates the raw `usize count` without Linux's 1024 clamp or `cond_resched`, and computes `base + sizeof(CMmsgHdr) * i` without checked arithmetic (`kernel/core/src/syscall/sendmmsg.rs:57-79`; Linux `net/socket.c:2678-2723`);
- aliases and overlaps are accepted by untyped OSTD copies, whose documentation does not promise a defined result for overlapping untyped ranges (`ostd/src/mm/io/mod.rs:295-311`).

Rejected arithmetic suspicion:

- `start_addr + idx * size_of::<UserIoVec>()` was checked for a wrap path. `count <= 1024`, and a start high enough to wrap a later entry fails the first address-bound reader construction before the loop reaches that addition (`kernel/core/src/util/iovec.rs:85-98`; `ostd/src/mm/vm_space.rs:165-170`). No reachable wrap was established from this expression.
- Control-message payload/alignment helpers check length relationships before using the aligned result; no current unchecked overflow was established in the audited path.

Parser-only malformed-header cases remain code-review/fuzzing candidates under the user's boundary; they are not shared-state invariants.

### 6.8 Zero-length Unix record accounting and readiness

Unix datagram queue capacity is measured only by `Inner::total_length`, the sum of payload bytes (`kernel/core/src/net/socket/unix/datagram/message.rs:34-38,68-77`). A zero-length message passes every capacity check, is appended to `VecDeque<Message>`, and adds zero to `total_length` (`kernel/core/src/net/socket/unix/datagram/message.rs:79-100`). The message can retain ancillary data, including up to 253 file references (`kernel/core/src/net/socket/unix/ctrl_msg.rs:81-113,220-274`). Repeated successful zero-length sends therefore have no per-record charge or record-count bound in this queue.

Unix seqpacket accepts an empty input record (`kernel/core/src/net/socket/unix/stream/connected.rs:284-301`). It appends one zero-length `RangedAuxiliaryData` entry without consuming ring capacity (`kernel/core/src/net/socket/unix/stream/connected.rs:318-359`). `check_io_events` tests only whether the byte ring is nonempty and ignores `all_aux`/`has_aux` (`kernel/core/src/net/socket/unix/stream/connected.rs:391-403`). A later direct receive can consume the zero-length record, but a level-triggered poll performed after enqueue does not report `IN`.

Linux allocates a record even when its payload length is zero, and its Unix queue logic includes record-count fullness checks (`net/unix/af_unix.c:288-291,2083-2098,2195-2235`). The exact Linux buffering formula is not modeled. The required abstract properties are:

- every queued datagram/seqpacket record has positive accounted cost independent of payload bytes;
- queue record/cost state is bounded;
- a queued seqpacket record contributes level-triggered readability, including a zero-length record.

The existing zero-length seqpacket SCM test proves that such records are intentional inputs, not malformed parser cases (`test/initramfs/src/regression/network/msg_peek.c:236-298`). It does not cover queue bounds or readiness.

### 6.9 Unix datagram SCM ownership cycles

Each Unix datagram socket owns a `MessageReceiver`, which owns an `Arc<MessageQueue>` (`kernel/core/src/net/socket/unix/datagram/socket.rs:31-43`; `kernel/core/src/net/socket/unix/datagram/message.rs:130-155,235-242`). Each queued message owns `AuxiliaryData`, whose file list is `Vec<Arc<dyn FileLike>>` (`kernel/core/src/net/socket/unix/datagram/message.rs:34-44`; `kernel/core/src/net/socket/unix/ctrl_msg.rs:69-71,205-218`).

`AuxiliaryData::from_control` explicitly warns that sending Unix sockets through SCM_RIGHTS can form cycles and that Linux uses garbage collection. Its capability check detects only `UnixStreamSocket` (`kernel/core/src/net/socket/unix/ctrl_msg.rs:256-274`). `UnixDatagramSocket` is a distinct file type and is not rejected. Sending a datagram socket's own FD to its own bound/connected queue can therefore form:

`UnixDatagramSocket -> MessageReceiver -> MessageQueue -> Message -> Arc<UnixDatagramSocket>`

Queue destruction occurs in `MessageReceiver::drop` (`kernel/core/src/net/socket/unix/datagram/message.rs:262-270`), but the strong-reference cycle prevents the owning socket from reaching that drop path after external FDs close. No Unix-socket garbage collector or alternate cycle breaker was found in the export. Linux has graph-based Unix-socket GC (`net/unix/garbage.c:560-621`).

This ownership graph is source-confirmed. A targeted resource-release test and code review are more direct than expanding the main partial-progress model into a garbage-collector protocol. The shared model can still represent `UnreachableButOwned` as a terminal ownership violation when a self-reference action is enabled.

### 6.10 User page faults while IP socket locks are held

IP stream state explicitly records that userspace reads/writes occur while spin locks are held and may break atomic mode (`kernel/core/src/net/socket/ip/stream/mod.rs:59-63`). TCP copy closures run under connection/raw-socket locks (`kernel/core/src/net/socket/ip/stream/connected.rs:72-125`; `kernel/libs/aster-bigtcp/src/socket/bound/tcp_conn.rs:383-443,457-535`). UDP holds its raw-socket lock across the user-copy callback (`kernel/libs/aster-bigtcp/src/socket/bound/udp.rs:152-166,180-191`).

User buffers are not prefaulted or pinned (`kernel/core/src/context.rs:88-117`). Asterinas documents that fault handling may load from disk and should not occur in atomic mode; disabling the handler requires leaving atomic mode, handling the fault, and retrying (`kernel/core/src/process/posix_thread/thread_local.rs:102-115`).

The lock/fault overlap is source-confirmed, but the exact observable outcome depends on a runtime page-fault path. Route it to a test harness using a valid not-present file-backed page. Do not add lock/preemption internals to the finite syscall transaction model unless the runtime test establishes an in-scope progress or consistency failure.

## 7. Existing Regression Evidence and Gaps

| Existing test | What it establishes | Missing coverage |
|---|---|---|
| `test/initramfs/src/regression/ipc/pipe/short_rw.c:29-41` | Records the current pipe fault result and retained message | Linux-valid positive partial result/queue progress and retry semantics |
| `test/initramfs/src/regression/fs/ext2/short_rw.c:16-52` | Prevents uninitialized page-cache data exposure after a fault | Returned short count and matching file position/content commit |
| `test/initramfs/src/regression/io/file_io/iovec_err.c:29-118` | Covers count and negative-length errors | Null-base/nonzero length, concurrent mutation, split mapping, vector atomicity |
| `test/initramfs/src/regression/network/udp_err.c:342-403` | Covers bad UDP buffer errors | Assert that no malformed packet reaches the peer |
| `test/initramfs/src/regression/network/sendmmsg.c:74-129` | Covers completed-message count after a later send error | Post-send copy-out fault, full-structure footprint, `vlen > 1024` |
| `test/initramfs/src/regression/network/unix_stream_err.c:22-114` | Exercises normal SCM_RIGHTS transfer | Descriptor-number copy fault and installed/unpublished FD accounting |
| `test/initramfs/src/regression/network/msg_peek.c:236-298` | Accepts and receives a zero-length seqpacket carrying SCM_RIGHTS | Queue bound, post-enqueue readiness, and ownership release after external closes |

No existing test was found for racing `msghdr`/`mmsghdr` mutation across post-effect copy-out or for the full-structure output footprint.

## 8. One Coherent Shared State Machine

### 8.1 State

| Variable | Domain/purpose |
|---|---|
| `phase[t]` | `Idle, Snapshot, Validate, Transfer, EffectCommitted, Copyout, Return, Error, Restart` |
| `opProfile[t]` | Syscall kind plus effect granularity, offset policy, partial policy, contractual outputs, post-fault policy, restart eligibility |
| `liveMeta`, `snapMeta[t]` | Mutable user metadata and captured top-level/nested values |
| `mappingState` | Small set of mapped/readable/writable/inaccessible abstract ranges |
| `requested[t]`, `copyProgress[t]`, `committedProgress[t]`, `reportedProgress[t]` | `Zero/Positive/Complete` progress classes |
| `iovIndex[t]`, `vectorOwner` | Ordered vector position and logical file transaction ownership |
| `filePos[f]`, `appendRange[t]` | Shared open-description offset and abstract append reservation |
| `queue[s]`, `queuedRecords[s]`, `queueCost[s]`, `readable[s]` | Record existence, bounded accounting, and level-triggered visibility independent of payload length |
| `messageToken[t]`, `published[t]`, `consumed[t]`, `peek[t]` | Stream/datagram effects |
| `effectToken[t]`, `copyoutMask[t]`, `copyoutFaultField[t]`, `batchCompleted[t]` | Irreversible syscall effect and output stage |
| `objectOwner[o]`, `fdNumberPublished[o]` | `Queued/InMessage/Reserved/Installed/Dropped` object ownership |
| `interrupt[t]`, `timeout[t]`, `restartToken[t]`, `attempt[t]` | Signal/timeout/restart state |

### 8.2 Actions

1. `Begin(op)`: capture raw typed arguments and select an immutable operation profile.
2. `SnapshotTop` and `SnapshotNested`: capture a header, then each iovec/address/control value. `MutateMeta` may occur between steps.
3. `ValidateRange`: establish only address/bound facts the implementation checks. `RemapRange` may later invalidate access.
4. `CopyChunk`: nondeterministically copy zero, a positive prefix, or all requested data and optionally fault.
5. `CommitBytes` or `CommitMessage`: apply byte-stream progress or one datagram/object effect at the profile's implementation point; every record adds positive abstract queue cost.
6. `AdvanceOffset`: update shared position only for the profile and commit represented by the result; positional operations skip it.
7. `CopyoutField`: copy only one contractual output field. A baseline variant can enable the observed whole-structure mask for MC-3.
8. `PublishFdNumber` and `InstallFd`: expose their ordering explicitly; accepted connections use `DropObject` on permitted copy-out failure.
9. `ReturnShort`, `ReturnError`, `ReturnBatch`: derive user result from the profile, not a universal rule.
10. `EnqueueEmptyRecord`/`DequeueRecord`: exercise record accounting and readiness with zero payload and optional SCM ownership.
11. `Interrupt`, `Timeout`, `Restart`: permit restart only from an attempt whose effects remain zero under the candidate invariant.

### 8.3 Per-operation profiles

| Profile | Effect granularity | Offset | Contractual output/post-effect rule |
|---|---|---|---|
| Scalar regular read/write | Byte prefix | Shared `f_pos` follows visible commit | No copy-out |
| Positional read/write | Byte prefix | Unchanged | No copy-out |
| Vector regular/positional | One ordered vector transaction with byte-prefix result | Shared or unchanged | No copy-out |
| Stream send/receive | Byte prefix | None | Positive progress returned short |
| Datagram send | Whole message | None | Source fault publishes none |
| Datagram/seqpacket receive | Whole-record selection plus copied prefix | None | Every record has cost/readability; non-peek consume and peek retention are explicit; metadata error may follow consume |
| `sendmmsg` | One message per entry | None | Count advances after `msg_len`; at most one current send may be hidden by that field's fault |
| `recvmsg`/`recvfrom` | Receive/message/FD effects | None | Only documented address/control/flag/length outputs; later error need not roll back receive |
| `accept` | One connection | None | Address fault drops accepted object and installs no FD |
| SCM_RIGHTS | One FD object at a time | None | Complete number publication precedes install |

This representation keeps all scenarios in one state space while avoiding a false common rollback policy.

## 9. Findings and Verification Routing

### 9.1 Model-checkable questions

| ID | Open question | Target invariants |
|---|---|---|
| MC-1 | Can vector splitting plus a competing shared-offset/append operation and a copy fault yield no valid single vector linearization point? | `VectorLinearizable`, `OffsetFollowsCommit`, `AppendRangesDisjoint` |
| MC-2 | Can `SelectReceiveRecord`, payload fault, concurrent peek/receive, and retry select or consume one datagram record more than once under a non-peek profile? | `OneCommitPerAttempt`, `DatagramConsumedOnce`, `ProgressIsVisible` |
| MC-3 | Can mutation/remap between socket effect and whole-structure output overwrite input-only state or hide an effect at a non-contractual fault field? | `CopyoutIsContractual`, `BatchHiddenEffectBound` |
| MC-4 | Can multi-FD delivery plus later output failure create installed-unpublished, duplicated, or ownerless objects? | `FdInstallRequiresNumberPublication`, `OwnershipConserved` |
| MC-5 | Can an interrupt/timeout after positive progress reach restart and repeat an effect? | `RestartBeforeCommit`, `OneCommitPerAttempt` |

Each is forward-looking behavior in the pinned source. None asks TLC to recreate a closed historical issue.

### 9.2 Runtime-test candidates

| ID | Source basis | Required observation |
|---|---|---|
| T-1 | Page-cache/ring adapters and vector loops | Split mapping returns a Linux-valid short result with matching content and shared/positional offset |
| T-2 | IP UDP send warning at `kernel/core/src/net/socket/ip/datagram/bound.rs:93-103` | No peer-visible datagram after a source-copy fault |
| T-3 | Unix datagram pop-after-copy at `kernel/core/src/net/socket/unix/datagram/message.rs:194-214` | Linux-compatible non-peek consumption and no replay after fault |
| T-4 | SCM install-before-number at `kernel/core/src/net/socket/unix/ctrl_msg.rs:137-149` | No installed FD unless its complete number is readable from the control buffer |
| T-5 | Whole `CUserMsgHdr`/`CMmsgHdr` writes | Only contractual outputs change; input-only remap cannot introduce an extra post-effect fault |
| T-6 | Iovec and batch bounds | Null/nonzero iovec, aliases, overlap, aggregate cap, zero-length, and `sendmmsg vlen > 1024` remain bounded and contained |
| T-7 | Scattered `EINTR -> ERESTARTSYS` mapping and timeout FIXMEs | No timed operation restart and no duplicate progress around `SA_RESTART` |
| T-8 | Zero-length Unix record accounting | Empty datagram/seqpacket queues remain bounded and a queued empty seqpacket reports `IN` |
| T-9 | Unix datagram self-FD ownership | After sending a socket's FD into its own queue and closing all external FDs, queue/socket/file references are released |
| T-10 | IP socket copy under atomic-mode locks | A valid not-present file-backed user page faults without sleeping/panicking under the socket lock and preserves the syscall contract |

### 9.3 Code-review candidates

| ID | Review boundary |
|---|---|
| CR-1 | Enumerate every tuple-partial conversion and determine which layer owns the progress count |
| CR-2 | Confirm ext2 rollback coverage when `invalidate_range(...)?` returns directly at `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:312-317` |
| CR-3 | Replace/review whole-structure `sendmmsg` output and add Linux's `UIO_MAXIOV` clamp |
| CR-4 | Decide and document `MAX_RW_COUNT` compatibility rather than `isize::MAX` aggregate vectors |
| CR-5 | Review `MSG_CMSG_CLOEXEC`, control-copy error suppression, and FD-number publication as one ownership contract |
| CR-6 | Charge every Unix queued record and include zero-length seqpacket records in readiness |
| CR-7 | Extend the Unix-socket cycle policy to datagram sockets or implement an ownership-cycle collector |

## 10. Rejected Invariants and False Positives

- **Rejected: `Error => no side effect`.** Linux `recvfrom`, `recvmsg`, `sendmmsg`, and `accept` can perform an effect before a later contractual output error (`net/socket.c:1904-1969,2205-2238,2664-2813`).
- **Rejected: exact partial counts.** The useful safety relation is positive/zero/complete progress and matching committed state; Linux can vary chunking and direct-I/O error details.
- **Rejected: one generation for all user metadata.** Both Linux and Asterinas import mutable iovecs without a userspace cooperation lock. The model checks safety for captured values, not snapshot isolation.
- **Rejected: direct recreation of #711.** Its mechanism informs Scenario 1, but its historical punchline is already known.
- **Rejected: all post-effect copy-out must succeed or roll back.** The contract is field- and syscall-specific.
- **Rejected: `copy_iovs_and_convert` address arithmetic is proven exploitable/triggerable.** The preceding bounded first-entry access prevents the hypothesized wrap path; no current trigger was established.
- **Rejected: every control-buffer fault leaks file objects.** Uninstalled `Arc`s are released. The narrower installed-before-number ordering remains a candidate.
- **Allowed: IP UDP receive consumes on copy fault.** Its non-peek dequeue-before-copy order matches the Linux consume profile (`kernel/core/src/net/socket/ip/datagram/bound.rs:55-83`).
- **Allowed: TCP returns a positive copied prefix.** Its lower layer preserves the callback's partial count (`kernel/libs/aster-bigtcp/src/socket/bound/tcp_conn.rs:373-443,446-535`).
- **Allowed: vsock stages/restores receive packets.** This is an explicit compensation for `MultiWrite` count loss, not an ownership defect (`kernel/core/src/net/socket/vsock/transport/connection/recv.rs:20-70`).
- **Allowed: SCM_RIGHTS under `MSG_PEEK` clones references.** Repeated peek publication is deliberate and distinct from non-peek duplicate consumption (`kernel/core/src/net/socket/unix/ctrl_msg.rs:284-313`).
- **Not a separate MC target: Unix stream physical chunk boundaries.** Prior fully successful chunks are reported; the known faulting-chunk count-erasure mechanism remains historical #711 context.
- **False report signal: #646.** The test confused `EAGAIN` with EOF; it does not support a socket queue defect.
- **Unconfirmed signal: #1938.** The SMP abort lacks a causal trace to the modeled state.

## 11. Validation Status and Limitations

| Check | Status |
|---|---|
| Skill methodology and Category B references | Completed |
| Exact source identity for cited files | Completed: 53/53 blob matches |
| Source call-path verification | Completed for all listed claims |
| Issue discussion audit | Completed: 30 threads, 115 comments |
| Commit audit | Completed: 74 exact-path commits screened |
| Open PR audit | Completed: 129 titles screened; 6 relevant/adjacent and 2 close candidates deep-read |
| Linux reference verification | Completed against man-pages and Linux v6.16 source |
| Source modifications | None |
| Builds, QEMU, or new runtime tests | Not run; this phase is analysis/spec handoff |
| TLA+ spec/model checking | Not run; routed through `modeling-brief.md` |

Open PR state and remote discussions are time-dependent. Their exact head OIDs or observed date are recorded where they influence conclusions. All implementation claims are tied to the pinned export rather than the current upstream default branch.

Primary handoff: `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md`.
