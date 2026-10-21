# Local flock ownership, conversion and release contracts

Use this preparation to produce a native analysis brief for one local inode's
flock ownership, mode conversion, release and waiter retry protocol. The target
is Category B because acquisition, reference lifetime and wakeup cross thread
boundaries. Completing this protocol campaign does not require a new defect.

Status is `SOURCE_PREPARATION_COMPLETE`. Native analysis, Linux controls,
Asterinas tests, traces, model checking and runtime validation are `NOT_RUN`.
This document registers no finding and reserves no AST ID. Its `FL-SQ-*` names
identify unverified source questions, not dispositions. It incorporates the
[accepted scope review](../../specula-scope-assessment-2026-10-02/ultraplan-third-fourth-2026-10-04.md),
so this is not a blind baseline. Full Git archaeology, current issue/PR discussion
review and mechanism-level deduplication remain native analysis work.

## Inputs and boundary

- Asterinas is `0c60537098f4c2949ad2d382aaf499de72263d76`, tree
  `4693fdec88cd7da14bed4f1541eba593f123059c`. Source inspection used the clean,
  history-preserving input at
  `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source`.
  The receiver's independent input is
  `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source`.
  Verify the preparation manifest and file hashes before using that copy. This
  pin is not a claim about current `upstream/main` or the authoritative checkout.
- Linux is v6.16.5, commit `4645fefac0b24d509b962c096b0327e87f34b1d2`.
  Inspection used the existing archive export at
  `/tmp/codex-memfd-prepipeline-20261003-4uz0nrgz/linux-v6.16.5`.
  The selected reference files for the receiver are under
  `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5`.
  They have no Git history and are not a Linux runtime or build tree. Record
  the actual Linux kernel and filesystem when executing a later control.
- Cover one existing ordinary ramfs/tmpfs file, independent opens of that inode,
  dup aliases, `LOCK_SH`, `LOCK_EX`, `LOCK_UN`, optional `LOCK_NB`, controlled
  conversion, close, final object release and blocked acquisition retry.
  Establish the inode, permissions and stable pathname before each case.
- Exclude POSIX/fcntl record and OFD locks, remote filesystems, mandatory locks,
  special files, unlink/rename, mmap/SCM_RIGHTS references, exec, process exit,
  malformed flags, resource exhaustion and arbitrary signal/restart behavior.
  Thread creation and fixture setup are supporting operations. Global fairness,
  FIFO ownership transfer and wall-clock latency are not promised contracts.

## Production path and compensation

The links below use the receiver's fixed input. File hashes at the end identify
the inspected bytes. Line ranges are explanatory ranges within those files.

| Source | Production behavior that must survive abstraction |
|---|---|
| [syscall/open.rs:84](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/syscall/open.rs:84), lines 84–130, and [path/mod.rs:166](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/vfs/path/mod.rs:166), lines 166–208 | Opening an existing pathname creates a new `Arc<InodeHandle>`. Two opens share the inode but have different OFD identity. |
| [file_table.rs:137](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/file_table.rs:137), lines 137–205 and 341–361, plus [syscall/dup.rs:10](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/syscall/dup.rs:10) | Dup clones the same file Arc. `get_file_fast!` borrows from an exclusive file table, or clones an Arc and releases the read lock for a shared table. A syscall in flight can therefore outlive the last numeric FD. |
| [syscall/flock.rs:12](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/syscall/flock.rs:12), lines 12–34 and 62–80 | Dispatch accepts the selected operations, obtains an inode handle, and holds its file reference across blocking acquisition. EINTR is translated to ERESTARTSYS. This preparation keeps signal interruption outside the case matrix. |
| [inode_handle.rs:228](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/inode_handle.rs:228), lines 228–252, and [inode_ext.rs:73](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/vfs/fs_apis/inode_ext.rs:73), lines 73–82 | O_PATH is rejected. A once-initialized per-inode `FsLockContext` owns the flock list. An unlock with no context succeeds without creating one. |
| [flock.rs:27](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/flock.rs:27), lines 27–82 | Each lock holds a Weak file owner and an Arc wait queue. Same-owner comparison is allocation identity, not FD number or process ID. Clones share the queue. Every `FlockItem` Drop wakes its queue, including replaced and removed list items. |
| [flock.rs:114](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/flock.rs:114), lines 114–157 | One list Mutex covers conflict search, registration on the first conflicting item's queue, and grant/replacement. Conflict is checked before replacing an existing same-owner lock. A blocked call retries the entire check after wakeup. Wakeup does not grant ownership. |
| [flock.rs:164](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/flock.rs:164), lines 164–181 | Unlock retains the list while holding its Mutex. It upgrades each Weak owner temporarily, removes the matching owner, and removes expired owners. A live match is explicitly woken. Removed items also wake through Drop, so the expired-owner branch must not be treated as missing notification. |
| [syscall/close.rs:19](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/syscall/close.rs:19), lines 19–35, [file_table.rs:274](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/file_table.rs:274), lines 274–298, and [inode_handle.rs:537](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/fs/file/inode_handle.rs:537), lines 537–541 | Close removes the FD, releases the file-table write lock, then drops `ClosedFile`. Its explicit cleanup releases POSIX range locks. Dropping its file Arc can destroy the `InodeHandle`, whose Drop calls `unlock_flock`. Closing one alias alone is not the flock release event. |
| [pause.rs:128](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/process/signal/pause.rs:128), lines 128–168, and [time/wait.rs:170](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/kernel/core/src/time/wait.rs:170), lines 170–206 | `pause_until` supplies no timeout. It installs a signal waker, executes the waiter condition/cancellation loop and clears the signal waker. Even with signals excluded, keep the actual retry and closure path. |
| [ostd wait.rs:110](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/ostd/src/sync/wait.rs:110), lines 110–148 and 209–282 | Queue draining pops wakers and releases the queue spinlock before invoking wake. `wait_until_or_cancelled` rechecks after cancellation and closes before that recheck. Waiter Drop closes the waker. Wake and wait use release/acquire operations and preserve a notification delivered before sleep. Repeated queue entries and notifications are not distinct grants. |
| [scheduler/mod.rs:441](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/ostd/src/task/scheduler/mod.rs:441), lines 441–493, and [mutex.rs:30](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source/ostd/src/sync/mutex.rs:30), lines 30–70 and 113–116 | Parking rechecks the wake condition and relies on the scheduler runqueue lock to bridge dequeue/enqueue. The list Mutex blocks on a boolean lock, with no recursive-owner fast path. Its guard releases the Mutex only when dropped. |

Asterinas tmpfs aliases RamFs at `kernel/core/src/fs/fs_impls/tmpfs/fs.rs:18–29`.
RamInode stores its extension at `ramfs/fs.rs:163–164` and returns it at
`1550–1552`, so the ordinary file's context is inode-scoped. Range-lock cleanup
uses a separate `RwMutex` at `range_lock/mod.rs:217–225`; its `unlock_all` at
`436–439` does not release flock locks. Keep these distinctions while excluding
range-lock behavior from the campaign.

The successful acquisition stores a clone of the request item. That clone and
the local request share a wait queue, so dropping the local request on return
can also wake that queue without releasing the stored flock. Replacing an
owner's item wakes its old queue, and explicit unlock can notify once directly
and again through item Drop. These are reasons to preserve the full retry loop,
not evidence of duplicate ownership or a missing handoff.

## Fixed Linux source oracle and allowed histories

The reference is the generic local flock path. Linux ramfs and tmpfs operation
tables have no `.flock` override at `fs/ramfs/file-mmu.c:41–50` and
`mm/shmem.c:5229–5242`. With file locking enabled, `fs/locks.c:2174–2179` reaches
`locks_lock_file_wait`, and `include/linux/filelock.h:420–423` delegates to the
inode helper. Do not use NFS or SMB behavior as the oracle for this target.

| Contract | Allowed Linux history and source | Implication for Asterinas analysis |
|---|---|---|
| OFD identity | `fs/locks.c:465–474` identifies the owner by the file object. Lines 939–948 exclude the same file object from conflict. Dup installs the same referenced file at `fs/file.c:1454–1466`. | A dup alias may change or release its OFD's flock. Independent opens may conflict even inside one process. Repeated same-owner locking is not a recursion count requiring multiple UN operations. |
| Compatible grants | `fs/locks.c:886–893` permits SH/SH and conflicts whenever either different-owner lock is EX. Admission and insertion hold the inode lock at 1096–1137. | Distinct incompatible grants cannot coexist. Numeric FD reuse is not evidence of shared ownership. |
| Nonblocking conflict | After a conflict is found, `fs/locks.c:1118–1125` returns EAGAIN when FL_SLEEP is absent. | A failed new acquisition grants nothing. This alone says nothing about a previous mode during conversion. |
| Conversion failure | `fs/locks.c:1101–1108` removes an existing different-mode lock before the conflict loop. A conflicting `SH -> EX|NB` then returns EAGAIN with that owner's old SH already removed. Allocation failure at 1090–1093 occurs earlier and is excluded here. | Do not require rollback to the old SH after EAGAIN. Asterinas checks conflicts before replacement, so this is `FL-SQ-1` for sequential calibration. |
| Successful conversion | A same-mode request returns without replacement at 1104–1105. A different-mode conversion deletes then checks/inserts while holding the same inode spinlock at 1096–1137. When conflict requires waiting, the lock is released and another owner may proceed. | Do not demand a globally atomic upgrade or invent a mid-critical-section acquisition window in the pinned Linux source. Asterinas replacement's Drop notification remains relevant even on an uncontended conversion. |
| Retry after release | Deletion unlinks and wakes blocked requests at `fs/locks.c:866–870`. The blocked call waits, then calls `flock_lock_inode` again at 2079–2093. | A wake means retry, not reservation. A waiter may lose a race, discover another blocker, and wait again. No FIFO outcome or universal starvation freedom follows. |
| Close and final release | `fs/open.c:1574–1589` removes the FD then performs synchronous put for close. `fs/file_table.c:567–570` calls final cleanup only on the last reference. `__fput` calls `locks_remove_file` at 439–457; `fs/locks.c:2641–2655` and 2685–2697 remove this file's flock. | A remaining dup or syscall reference may keep the owner alive. Do not release on the first close or wait for a process-wide final close of independent opens. |
| In-flight reference | `fs/file.c:1153–1182` borrows for an exclusive table and obtains a reference for a shared table. `include/linux/file.h:60–64,83` pairs fdget with fdput; `fs/file_table.c:515–542` can defer final fput to task work. | A syscall whose file lookup already succeeded need not become EBADF when another thread closes its last FD. Allow final release at the real last-reference cleanup, rather than fabricating an instantaneous FD-close event. |

An EX contender can be blocked by several SH owners. Asterinas registers on
the first conflict, so releasing that blocker may only move the waiter's next
registration to another owner. Successful completion requires all incompatible
owners to release and the contender to receive execution time. A host timeout
does not establish that those premises held.

## Source questions to preserve

### FL-SQ-1: failed or blocked conversion keeps the old Asterinas SH

**Observed source:** Asterinas `flock.rs:115–124` returns/registers on a conflict
before replacing an existing same-owner item. Linux `fs/locks.c:1101–1125`
removes the old mode before that check. The difference is not an errno-only
question. With A and B holding independent SH locks, let A's EX|NB request
fail, release B, then try EX|NB through independent C. The fixed Linux source
predicts success for C. Asterinas source predicts a remaining A SH conflict.

**Concurrent question:** If both SH owners request blocking EX, can retaining
both SH items leave both calls waiting, whereas the Linux removal path allows
one converter to proceed? Preserve the actual queues and release obligations.
Do not report a stalled test as a defect without showing entry, registration,
the retained owners and the absence of an external blocker. The sequential
control and concurrency question share one conversion mechanism, not two
automatically distinct findings.

### FL-SQ-2: a temporary upgraded owner may run its destructor under the list Mutex

**Observed source:** `FlockList::unlock` holds `inner` while its retain closure
calls `Weak::upgrade` at `flock.rs:166–180`. The returned Arc is local to that
closure. `InodeHandle::drop` calls back into `unlock_flock`. OSTD's Mutex has no
recursive acquisition path (`ostd/src/sync/mutex.rs:30–70`). These observations
do not yet establish an observed Asterinas deadlock.

The pinned Asterinas toolchain is `nightly-2026-07-21`. Its installed Rust source
at `/home/chin39/.rustup/toolchains/nightly-2026-07-21-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/alloc/src/sync.rs`
shows Weak upgrade adding a strong reference at 3299–3327, Arc Drop testing
the last reference at 2850–2855 and invoking `drop_slow` at 2896–2898, and
`drop_slow` destroying the payload at 2132–2143. This supports the lifetime
question, but the actual future build toolchain must still be recorded.

The proposed history uses two independent opens, A and B, on the same inode.
B holds a flock. Thread 1 calls UN through A and upgrades B while scanning
the list. Thread 2 closes B's final descriptor and drops its `ClosedFile` while
the temporary Arc remains. If the temporary Arc is then the last reference,
dropping it inside Thread 1's retain closure would enter B's destructor before
Thread 1 releases the same list Mutex. Establish or refute that reachability
with the complete native analysis and subsequent instrumentation.

Compensation checked: `get_file_fast!` keeps A alive but does not by itself keep
the separately opened B alive. B's stored lock owner is Weak. `ClosedFile` drops
after the FD-table lock has been released and its range-lock cleanup uses a
different lock. FlockItem removal wakes waiters but does not defer the temporary
owner Arc's destructor. The inspected path contains no deferred owner-drop
list or recursive Mutex fast path. Extra aliases, a B syscall in flight, or
diagnostic code that clones B would prevent this particular last-reference
window, so none may be silently omitted from the evidence.

This question belongs to the same release protocol. It is not an instruction
to assume deadlock, add an artificial self-deadlock, or bypass the original
locking to make the trace fit. No new AST ID or severity is assigned here.

## Planned cases

Every row is `NOT_RUN`. Expected values are source-based oracle proposals.
Use fresh fixture state per row, record all syscall results, and distinguish
kernel EAGAIN from libc's equivalent EWOULDBLOCK spelling.

| Case | Planned schedule and observation | Purpose and expected distinction |
|---|---|---|
| FL-C01 | Acquire SH through two independent opens. Probe EX|NB through a third. Release both SH owners and retry. | Calibrate SH coexistence, EX conflict and eventual successful retry. |
| FL-C02 | Acquire through A, duplicate A to A2, repeat the same mode, then UN through A2. Probe through independent B. Also UN an unlocked independent open. | Establish shared OFD identity, no recursive lock count, and harmless unlock with no ownership. |
| FL-C03 | Acquire EX through A with alias A2. Close A and probe B, then close A2 and probe again after close completes, with no syscall retaining A. | One alias close preserves the lock. Actual final release permits B's acquisition. |
| FL-C04 | Convert a sole owner's SH to EX and EX to SH. For downgrade, register a separate SH waiter first and observe retry. | Calibrate uncontended conversions and old-item Drop notification without assuming wake directly grants the waiter. |
| FL-C05 | A and B hold SH. A's EX|NB fails. B unlocks. C requests EX|NB before A performs any further operation. | Calibrate FL-SQ-1. Linux source predicts C succeeds because A's failed conversion removed its SH. Retain any Asterinas divergence for disposition. |
| FL-C06 | A and B hold SH. Arrange A to enter blocking EX conversion, then B to enter blocking EX conversion. A successful converter releases before the other must complete. | Test the same conversion mechanism under contention. No signal, deadline, fairness or old-lock rollback premise should be invented. |
| FL-C07 | Let the last conflicting owner release immediately before, then immediately after, a contender's actual conflict/registration boundary in separate attempts. | Determine whether the contender observes no conflict or receives a retained wake and retries. A user-ready flag alone does not prove queue registration. |
| FL-C08 | A and B hold SH, C waits for EX. Release the blocker on which C was registered, observe C's retry against the other blocker, then release that blocker. | Exercise migration between real blocker queues. The first wake need not complete C. |
| FL-C09 | Two independent EX contenders wait behind one holder. Release it, let the first successful contender release, and observe the second. | Verify incompatible ownership exclusion and retry after losing a wake race. Accept either winner and do not impose FIFO. |
| FL-C10 | B's blocking syscall has captured its OFD behind A's conflicting lock. Another thread closes B's last FD. A unlocks; B's syscall completes and drops its held reference. C then probes. | The syscall may succeed after the numeric FD closes. Capture the final reference drop and subsequent release, without claiming EBADF is mandatory. |
| FL-C11 | B holds a flock. UN through independent A overlaps the temporary Weak upgrade of B and the close/drop of B's final FD as described in FL-SQ-2. | Establish whether the proposed last-reference callback window is reachable. Preserve lock ownership, references, and incomplete output if progress stops. A watchdog alone is inconclusive. |
| FL-C12 | Repeat FL-C11 with one extra B alias, with B closed before upgrade, and with close after A's scan releases its Mutex. | Negative controls separate the exact last-reference window from fixture, scheduling or generic cleanup failures. Close the retained alias during controlled cleanup. |

## Evidence requirements and remaining gaps

FL-C01 through FL-C05 establish the sequential oracle, with an added blocking
waiter variant in FL-C04. They do not replace the protocol's ownership and progress
questions. Preserve compatible grants, aliases, conversion, actual last release,
registration, replacement/removal Drop notifications, wake consumption and retry
in the native brief, even if no candidate survives analysis.

Instrumentation must distinguish inode and OFD identity, numeric FDs, operation
entry/return, list lock acquisition/release, conflict owner, registration,
replacement/removal, wake acceptance, retry and final object destruction.
For FL-SQ-2, observe the temporary owner upgrade and its drop without cloning the
owner to log it. Instrumentation must not add an extra reference or change the
locking order that the case intends to measure. Preserve failed and partial
traces, and establish SMP >= 2 for concurrent runtime claims. The installed
gVisor flock blocklist contains blocking tests, but exclusion alone is neither
a regression result nor a bug oracle.

There is no source-scope blocker to preparing this lane. Formal acceptance still
needs complete native analysis and its independent review, a coherent brief,
fixed Linux control results with actual runtime identity, a reviewed harness
that can establish the critical windows, and reviewed model/trace evidence.
No preflight, provider readiness, model, harness or guest readiness conclusion
is made by this source subtask. Use the package's separate readiness records
and shared resource policy for those decisions. If an exact window cannot be
observed without changing the protocol, record an evidence gap instead of
forcing that behavior into the model or silently dropping the question.

## File identity

The following hashes cover complete files, even where only the cited production
sections were inspected. They are not a claim that every line or related issue
was audited. The source path prefixes above distinguish the Asterinas, Linux
and installed Rust roots.

| Root | File | SHA-256 |
|---|---|---|
| Asterinas | `kernel/core/src/syscall/flock.rs` | `85a1fcf7017b33d66aba7ec4d43c474d2ef2f3038ad7352854e08ba6edb0732a` |
| Asterinas | `kernel/core/src/syscall/open.rs` | `6f3968c228a07a8aa8440b5080e3b02d8ff500d29e339251402b8818c37ac584` |
| Asterinas | `kernel/core/src/syscall/dup.rs` | `01dac4a73456c13de189e907622c8288c50955452064fb6068cf83c2ea770281` |
| Asterinas | `kernel/core/src/syscall/close.rs` | `8357441428661d0243eb0f907724cb7dd8f438484b1e3fdfa86c92e41af8a40c` |
| Asterinas | `kernel/core/src/fs/file/flock.rs` | `5b0719c03c9057f7e3c3cd92c957fcf7635a286a4b56b76a0c1b4ca972b64295` |
| Asterinas | `kernel/core/src/fs/file/inode_handle.rs` | `2ae3f88894a7b5bf84690774510c333064eae4a77672ea508ac3f6e32f754e30` |
| Asterinas | `kernel/core/src/fs/file/file_table.rs` | `7eb1a315b7e97054d949e56ff65a0dcd19ae225c374c1ea83a33948283ff2104` |
| Asterinas | `kernel/core/src/fs/vfs/fs_apis/inode_ext.rs` | `cc0d86234207ececc1ad9555f89008ef09e3d9d5f6f3c98c5ca4f361842414d4` |
| Asterinas | `kernel/core/src/fs/vfs/path/mod.rs` | `9cea29a47ab22cdd24af14bf0d8a4b920626f5bd47cdf4a736a8468f7fc7c906` |
| Asterinas | `kernel/core/src/fs/vfs/range_lock/mod.rs` | `add0c13b3d45b034f5f122d8dfeb5811c6d27dd03c7c4d18459ab75f5bf2c249` |
| Asterinas | `kernel/core/src/fs/fs_impls/ramfs/fs.rs` | `6608b07f9b5c2b68b8a379d4eefc48c1156c76e13ec42faad5d6a2b671b6f195` |
| Asterinas | `kernel/core/src/fs/fs_impls/tmpfs/fs.rs` | `af86773ae73f711fbdfcc25452c432c570fef664c77658894c32e30f9cc46f7c` |
| Asterinas | `kernel/core/src/process/signal/pause.rs` | `26eccaacd4b11152ca31471f8cefe5bcce9703733693214b138bd1887b31cc5e` |
| Asterinas | `kernel/core/src/time/wait.rs` | `704a9d8841850d1be34f2dffa682f36a8a7f9bdbb831aca1ab028c54df4327b7` |
| Asterinas | `kernel/core/src/prelude.rs` | `6b23b03ad576e28f403605c31cd2017cd99e048e7c256e61797fd1f2cb27ccc1` |
| Asterinas | `ostd/src/sync/wait.rs` | `acb0fccb6c264169b7ee702f28b850444c9476425333f4304a6cb6fcd763d17e` |
| Asterinas | `ostd/src/sync/mutex.rs` | `af64fd9e97afbaa399277683c570fa314b3ff63f3a5599b434a59dfbd275e71e` |
| Asterinas | `ostd/src/task/scheduler/mod.rs` | `adbe8fbb06789c6a9cce19a53987e3355d2c8c50bc0449c6db23066acbd3f979` |
| Asterinas | `rust-toolchain.toml` | `b2508d8c9cd57258fad2fc77737e07172846161f6a7dd726cbd8e974de69c6f7` |
| Asterinas | `test/initramfs/src/conformance/gvisor/blocklists/flock_test` | `e4ca0059abe72e8b6d93ea49a246be43b161eeed1d65dab5c611daed0f236f0a` |
| Linux | `fs/locks.c` | `fd260dcc991732a6770f361f4b8cd71cdbe55947b7753be60d933376028f880e` |
| Linux | `fs/file.c` | `896b36bc5b26207c61818bd3a60ed7eb13e468cbafa1c7d7cb6d43dfa25cb29d` |
| Linux | `fs/file_table.c` | `b2548c3d8fb587ca9230d4584a236080d87b31ff0b29fd86c4c27dc77ca7a62f` |
| Linux | `fs/open.c` | `d532a51f54cafb5ff23c8eb763c5a8a95cf7dce24a387cdd07939707cc337991` |
| Linux | `include/linux/filelock.h` | `11431faaaa9c654f6726d22abfaa5ccc70ba63ea4237d026d66aa01c22b306e6` |
| Linux | `include/linux/file.h` | `6f85737b57c2ccf9fbc8ea844f2837691fb48de22ddef4dab31b96201bf5728a` |
| Linux | `include/linux/file_ref.h` | `6f8d93585a850bfc6205f82a670c266e41fb4c67be943a3bd1a4f88eda8504ae` |
| Linux | `fs/ramfs/file-mmu.c` | `bc92dad1ed8c2b0193cfc36ece27370f2df7caab17bf8d9b50e6c3cd198b9efd` |
| Linux | `mm/shmem.c` | `0222b7997d00aeb8114d3b668a810644afce44d9a464cfeac4c512d04cbdc2d8` |
| Installed Rust | `alloc/src/sync.rs` | `2e11d0c0eb5ebabdbb3d045ed5b241869feeacff6eae9a8869bf48ebcf87eef1` |
