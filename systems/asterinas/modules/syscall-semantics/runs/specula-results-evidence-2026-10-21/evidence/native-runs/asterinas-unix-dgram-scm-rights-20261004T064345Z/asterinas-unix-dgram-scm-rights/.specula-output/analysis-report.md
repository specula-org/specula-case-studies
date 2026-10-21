# Code analysis: Unix datagram SCM_RIGHTS publication

This analysis defines a bounded ownership protocol for Spec Generation.
It establishes no new defect candidate.
AST-32 remains an existing source lead about installation before number publication, and AST-36 remains an existing source lead used only as the payload-fault consumption/PEEK control.
The proposed checks, Linux control programs, production instrumentation, model checking, reproduction, and later staged reviews have not run.

## 1. Identity, authority, and evidence limits

| Item | Inspected value |
| --- | --- |
| Repository | `/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/source` |
| Output directory | Sibling `.specula-output` in this target's run |
| Asterinas commit | `0c60537098f4c2949ad2d382aaf499de72263d76` |
| Asterinas tree | `4693fdec88cd7da14bed4f1541eba593f123059c` |
| Checkout history | Non-shallow; no remote is configured in this analysis checkout. GitHub was queried explicitly as `asterinas/asterinas`. |
| Initial working-tree state | No tracked changes; pre-existing untracked `.codex/` directory. |
| Linux comparison | `4645fefac0b24d509b962c096b0327e87f34b1d2`, prepared Linux v6.16.5 selected-file export at `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5` |
| Linux identity check | Six relevant local files were compared byte-for-byte with the pinned `gregkh/linux` raw source. All matched; see `analysis-evidence/linux-source-check.json`. |
| Required inputs | `reports/parallel-scopes-2026-10-04/scm-rights/contracts.md` and `resources.json` under `/home/chin39/Documents/play/specula-profile` |
| Methodology | Installed Specula 1.2.0 `code_analysis/SKILL.md`, full `guide.md`, shared deep-analysis, concurrent-analysis, bug-archaeology, modeling-brief-format, example, and persistent-findings references. |

GitHub issue/PR observations are a 2026-10-04 live snapshot, distinct from the selected source pin.
Closed status alone was never used as proof of a fix.
Historical maintainer/test evidence is reported as historical evidence, not as this run's reproduction.
The browser could not retrieve the raw Linux URLs, so direct HTTPS downloads supplied the successful pinned-byte comparison.

The shared resource policy was read before repository, network, or build work.
At most two source-analysis helpers were used, in successive batches, despite the skill's general preference for more parallel helpers.
This analysis performed read-only source/Git/GitHub work and wrote this target's analysis artifacts only.
It ran no build, guest, TLC process, pipeline phase transition, repair, upstream submission, or shared-catalog mutation.
The controller must hold the shared heavy-stage lock for any later heavy phase and apply the policy's memory/worker/container limits.

### Persistent-finding lookup

The supplied `persistent-findings-context.json` names this source and run, has `previous: null`, and contains no inherited records.
The installed CLI was invoked as:

```text
/home/chin39/Documents/play/Specula/.venv/bin/specula findings --work ../.specula-output lookup --query SCM_RIGHTS --query FileMessage --query AST-32 --query AST-36
```

It returned `[]`.
The known leads were therefore matched manually to the supplied contracts, catalog, ID map, and the original Recon analysis's §6.5 and finding tables.
The current catalog still records both as `SOURCE LEAD` at `reports/asterinas-bug-findings-2026-08/README.md:101,105`.
The original report at `runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md:273-283,414-428` describes the same mechanisms.
Its older broad invariant is refined here to completed-call boundaries and complete integer copies.
No completed confirmation record exists to reuse, and this analysis neither creates a reuse receipt nor promotes the leads.

## 2. Step 0 and Phase 1: structural reconnaissance

**Category B (Concurrent / Lock-Free / Runtime)** is the appropriate category.
The target is a lock-based runtime ownership/publication protocol within one kernel, even though its API sends messages.
The distributed and BFT playbooks are not applicable.
The atomicity boundaries come from the queue mutex, per-insertion file-table lock, user-copy results, and Rust-owned temporary values.

Paths in Asterinas tables below are relative to `kernel/core/src/`, unless explicitly prefixed by OSTD or `kernel/libs/`.
All seven requested files were read in full by the primary analyst.
The focused helper reports provide independent complete reads of the same critical paths.

| File | Lines | Responsibility and atomicity |
| --- | ---: | --- |
| `syscall/sendmsg.rs` | 65 | Lines 31–37 clone the socket and release its table access before reading SCM rights. Lines 45–59 build owned control messages and dispatch the send. |
| `syscall/recvmsg.rs` | 59 | Lines 28–45 perform protocol receive and explicitly release the table borrow. Lines 47–58 output address/control data and finally the whole msghdr. |
| `net/socket/unix/ctrl_msg.rs` | 339 | Lines 87–114 capture file objects, 116–151 publish received FDs, 222–274 merge auxiliary ownership, and 284–313 move or clone rights. |
| `net/socket/unix/datagram/message.rs` | 301 | Lines 54–100 serialize send-copy/enqueue. Lines 174–217 serialize selection/copy/dequeue-or-PEEK. Lines 262–270 dispose queued messages. |
| `net/socket/util/message_header.rs` | 204 | Lines 45–101 parse controls; 104–129 handle complete versus failed control-message output; 144–203 define lengths and alignment. |
| `util/net/socket.rs` | 180 | Lines 80–98 define the user msghdr; 100–156 handle optional address/control buffers; 159–178 construct iovec readers/writers. |
| `fs/file/file_table.rs` | 407 | Lines 190–205 insert/remove owned entries; 274–297 defer close cleanup; 341–362 distinguish shared-table lookup from exclusive lookup. |
| Total requested core | 1,555 | Physical source lines, including comments and declarations. This is not the LOC count of the entire kernel. |

Adjacent production reads include the complete `net/socket/unix/datagram/socket.rs` and `util/iovec.rs`, socket nonblocking dispatch at `net/socket/mod.rs:37-68`, supported flags in `net/socket/util/message_flags.rs:1-70`, `syscall/close.rs:19-44`, `kernel/libs/aster-util/src/slot_vec.rs:9-107`, OSTD `mm/io/mod.rs:766-808`, and OSTD `mm/vm_space.rs:153-190`.
These reads establish reachability and cleanup without expanding the modeled syscall surface.

### Supported bounded setup

Use a Unix datagram socketpair created with `SOCK_NONBLOCK`, a nonempty payload, and one nonempty SCM_RIGHTS control message containing ordinary file or pipe references.
Use one valid iovec, `msg_name = NULL`, a writable full msghdr, valid metadata, and stable disjoint payload/control regions.
Fault permissions are configured before the operation and never changed during it.
Receive flags are 0 or `MSG_PEEK`, and send flags are 0.

The socket wrapper uses the socket's nonblocking status to make one receive attempt (`net/socket/mod.rs:58-61`; `net/socket/unix/datagram/socket.rs:299-316`).
`MSG_DONTWAIT` and `MSG_CMSG_CLOEXEC` are declared constants but absent from `RecvFlags::SUPPORTED` (`net/socket/util/message_flags.rs:40-59`).
The wrapper warns about unsupported flags rather than proving their semantics (`net/socket/unix/datagram/socket.rs:304-307`), so neither flag belongs in the harness.

No reference to the receiving socket is sent as a right.
Final queue disposal occurs only after the last receiver socket owner is released and no receive is active.
The peer may retain a `MessageQueue` Arc, but `MessageReceiver::drop` still replaces its contents with `None` (`net/socket/unix/datagram/socket.rs:63-77`; `net/socket/unix/datagram/message.rs:262-270`).

## 3. Phase 2: bug archaeology and coverage

The collection and verified discussion ledgers under `analysis-evidence/` are the audit trail.
The final coverage table and historical classifications are appended in §9 after the technical analysis.
Search collection is not conflated with deep reading or confirmation.

The initial eight issue searches used `gh issue list --state all --limit 1000` with `socket`, `SCM_RIGHTS`, `recvmsg`, `sendmsg`, `file descriptor`, `label:C-bug`, `race`, and `leak`.
They returned 114, 2, 9, 7, 51, 313, 58, and 21 records respectively, yielding 466 distinct issues.
No search reached its 1,000-result cap.
All 109 open PRs were collected with their full bodies and source heads for bug-fix-intent screening.
The helpers verified issues in two parallel streams, each with two batches of eight issues.

History mining used `git log --all --follow` separately for every requested core file, so the move from `kernel/src/` to `kernel/core/src/` did not hide earlier changes.
The union contains 98 commits, with 17 initial keyword/semantic-signal matches.
The remaining subjects and bodies were screened for semantic fixes hidden under refactoring or feature subjects.
Full selected patches and exact commit/file membership are retained in `core-history.json`, `bugfix-history.json`, and `commits/`.

### Source-introduction and behavior PRs read by the primary analyst

Every row below includes the complete body, issue conversation, submitted reviews, and inline review comments, including empty and bot reviews where present.
Downloaded counts were checked against the saved JSON arrays.
All source behavior is independently checked at the selected pin.

| PR | Discussion/review/inline counts | Verified relevance |
| --- | --- | --- |
| [#2176](https://github.com/asterinas/asterinas/pull/2176) | 0 / 12 / 16 | Introduces SCM_RIGHTS and auxiliary references in `4d8078166eaf`. Review discusses circular references and control-count limits; those are explicit exclusions here. The thread does not validate the failing-integer publication order. |
| [#2412](https://github.com/asterinas/asterinas/pull/2412) | 0 / 7 / 8 | Introduces datagram queues in `fe1d4fe15f6b`. Inline discussion 2332086622 explains why the receiver type and its destructor are necessary even when the queue is shared. |
| [#3347](https://github.com/asterinas/asterinas/pull/3347) | 2 / 17 / 48 | Introduces datagram PEEK and shared ancillary clone/move behavior. Review corrects stream-specific empty-buffer and ancillary-boundary logic. Those corrected stream paths are not new datagram findings. |
| [#3600](https://github.com/asterinas/asterinas/pull/3600) | 1 / 8 / 20 | Adds `MSG_CTRUNC` and separates output flags from mutable input state. The retained source still installs before copying an FD integer. Bot review assertions were not treated as confirmed bugs. |
| [#2901](https://github.com/asterinas/asterinas/pull/2901) | 0 / 2 / 0 | Fixes empty control-header parsing by allowing header length equal to the header size. Empty rights/records are outside the model; no regression of this fix is proposed. |

These five PRs contribute 3 conversation comments, 46 submitted reviews, and 92 inline comments.
They are saved under `analysis-evidence/source-prs/` with bodies, `gh pr view --comments`, paginated API responses, diffs, and commit-to-PR associations.

## 4. Phase 3: verified execution paths

### 4.1 Sender capture and queue publication

`sys_sendmsg` first obtains its socket independently of the subsequent SCM lookup (`syscall/sendmsg.rs:31-38`).
`FileMessage::read_from` converts each raw sender number into a validated `FileDesc`, gets its file, and calls `into_owned()` (`net/socket/unix/ctrl_msg.rs:103-113`).
For a shared file table, `get_file_fast!` clones the file while holding the read lock; for an exclusive table, `into_owned()` clones the borrowed Arc (`fs/file/file_table.rs:341-362`).
Thus a captured right contains an object reference rather than a deferred lookup of the sender number.
Object identity here means the captured `FileLike` or open file description, not only an inode number.
Separate opens or pipe endpoints can refer to the same inode without being the same captured object.

`AuxiliaryData::from_control` transfers the owned vectors into its file list (`net/socket/unix/ctrl_msg.rs:222-240`).
`UnixDatagramSocket::do_send` owns that list and passes it by mutable reference to the queue (`net/socket/unix/datagram/socket.rs:92-120,267-296`).
Under the queue mutex, payload copying occurs before `mem::take(aux_data)` and before `push_back` (`net/socket/unix/datagram/message.rs:60-96`).
A failed send copy therefore publishes no message and leaves the temporary rights in the send operation to drop.
After a successful send, sender close or slot reuse cannot retarget the queued object.

Linux independently looks up and owns files in its SCM list (`net/core/scm.c:73-145`), transfers them to the skb, copies the payload, then queues the skb (`net/unix/af_unix.c:1916-1971,2089-2098,2232-2251`).
The skb destructor and SCM destructor release the corresponding temporary owners on failure.
These are source-supported lifetime arguments, not runtime EOF observations.

### 4.2 Selection, ordinary receive, and PEEK

`MessageReceiver::try_recv` holds `queue.inner` from inspecting the head through payload copying and ancillary extraction (`net/socket/unix/datagram/message.rs:179-217`).
An ordinary receive pops once and transfers the rights with `mem::take`.
A PEEK leaves the message at the head and clones the rights (`net/socket/unix/ctrl_msg.rs:304-310`).
The queue mutex is released when `try_recv` returns.
No other queue selector can observe a partially selected/dequeued message, but another operation may select after this return while the first operation is still publishing FDs.

Two ordinary receivers cannot both remove the single message.
One receives it and the other can return `EAGAIN` once it obtains the queue lock.
A PEEK that selects before ordinary receive can legitimately finish after that receive, delivering its own copies of the same objects.
If the ordinary receive selects first and consumes successfully, a later PEEK finds an empty queue.
Neither return order nor repeated object identity is evidence of duplicate consumption.

Linux acquires `iolock` before selecting the skb and keeps it until after ancillary delivery (`net/unix/af_unix.c:2511-2600`).
Its queue helper increments the skb reference for PEEK and unlinks ordinary receive (`net/core/datagram.c:183-202`).
Do not import Linux's longer critical section into the Asterinas model.
Compare the ownership/results contract without requiring identical internal schedules.

### 4.3 AST-32: installation before complete integer output

The complete reachable path is `sys_recvmsg` → datagram receive → `MessageHeader` → `CUserMsgHdr::write_control_messages_to_user` → `ControlMessage::write_all_to` → `FileMessage::write_to`.
Use stable valid outer metadata, successful payload copy, a writable control header, and an inaccessible page containing the first or a later FD integer.
Writer construction validates the address range, not each page's writability (OSTD `mm/vm_space.rs:178-190`), so this layout can reach the copy site.

`FileMessage::write_to` selects a capacity-limited prefix and writes its header before any installation (`net/socket/unix/ctrl_msg.rs:116-135`).
For each entry it clones the file into the table under `.write().insert(...)`, releases that temporary lock guard at the statement boundary, then calls `write_val::<i32>` (`net/socket/unix/ctrl_msg.rs:137-148`).
The `?` on number copy exits without `close_file` or another removal mechanism.
The inline comment at lines 145–147 explicitly questions cleanup and cites Linux header behavior, but it does not establish that the failing-number case matches Linux.

The caller catches the error, sets `MSG_CTRUNC`, and leaves `len` unchanged for this cmsg (`net/socket/util/message_header.rs:104-129`).
With a single rights message, reported length is therefore zero even if the header and several numbers were written.
The valid outer msghdr can still be written and `recvmsg` can return the payload length (`syscall/recvmsg.rs:50-58`).
Dropping the `FileMessage` releases every temporary Arc, including those whose entries were installed, but cannot remove independent table entries (`net/socket/unix/ctrl_msg.rs:69-71,139-148`; `fs/file/file_table.rs:190-205`).
This rules out temporary-vector cleanup as compensation for AST-32.

Linux's `receive_fd` reserves a slot, calls `put_user`, releases the reservation on that copy's failure, and only then installs `get_file(file)` (`fs/file.c:1364-1376`).
`scm_detach_fds` keeps the completed prefix, optionally reports a header for that prefix, and destroys the SCM temporary list (`net/core/scm.c:348-378`).
This is a per-entry contract. It does not require whole-message rollback.

**Disposition:** current source mechanism verified; existing AST-32 identity retained; fault reachability and resulting FD/object census still require the future production test and Linux control.
No fresh reproduction, severity promotion, or new catalog ID is claimed.

### 4.4 Capacity, header failure, and reporting

For header size `H`, integer size `I`, non-NULL advertised control length `C`, and `N > 0` rights, the selected count is `min(N, floor((C-H)/I))` when `C >= H`.
`C < H` errors before output, and a zero selected count also errors before the header (`net/socket/unix/ctrl_msg.rs:117-135`; `net/socket/util/message_header.rs:168-172`).
These errors become zero reported control length and `MSG_CTRUNC` with no installations.
NULL control is handled separately and produces the same no-FD/truncation outcome for a nonempty rights list (`util/net/socket.rs:143-151`).

When every selected number copy succeeds, Asterinas reports `H + k*I` plus available alignment padding, bounded by `C` (`net/socket/util/message_header.rs:120-126,195-203`).
The writer skips that padding without copying bytes, although the reported length includes it (`net/socket/util/message_header.rs:124-126`).
It marks truncation if `k < N`.
Unselected rights remain in the operation's vector until drop and are released then.
Do not model installation as moving entries out of that vector: insertion clones them.

If the control header is unwritable but the FD data region is writable, Asterinas fails before any insertion (`net/socket/unix/ctrl_msg.rs:135-148`).
Linux does the per-FD number writes and installations first and only then writes the header (`net/core/scm.c:348-368`).
If all numbers succeeded, a later Linux header failure can leave all FDs installed with zero reported control length and no `MSG_CTRUNC`, because the flag condition depends on incomplete FD delivery, not header failure (`net/core/scm.c:371-372`).
This negative control invalidates an overly strong invariant that equates zero cmsg length with no delivered ownership.

OSTD `write_val` requires a complete value and rolls its cursor back on a failed partial copy, but does not restore user bytes (`ostd/src/mm/io/mod.rs:795-808`).
Capture complete integer success separately from dirty bytes and header success.
Never infer publication from cursor movement, reported length, a changed sentinel alone, or a partially copied integer interpreted as an FD.

### 4.5 AST-36: bounded payload-fault control

`MultiWrite::write` may copy a payload prefix before returning a fault (`util/iovec.rs:304-320`).
Asterinas propagates that fault at `net/socket/unix/datagram/message.rs:195`, before ordinary dequeue at line 202 or PEEK control cloning at line 213.
The queued message and its rights remain, no receiver FD is installed, and a later valid attempt can select the same message.
This applies to the normal and PEEK fault paths at this source pin.

Linux ordinarily unlinks at selection, before `skb_copy_datagram_msg`.
Its payload error goes directly to `out_free`; normal receive releases the selected message's rights, while PEEK leaves the queue's skb reference alive (`net/core/datagram.c:183-202`; `net/unix/af_unix.c:2558-2600`; `net/unix/af_unix.c:1943-1955`).
Both implementations can leave partial payload bytes, so the oracle concerns message identity, consumption, and ownership rather than byte rollback.

**Disposition:** AST-36 remains a source lead and a single bounded comparison control.
No general payload-copy investigation, model-checker execution, or runtime verification is claimed.

### 4.6 Cleanup and final ownership

An installed FD owns its cloned file independently of the temporary rights vector (`fs/file/file_table.rs:190-205`).
`sys_close` removes the entry under the table write lock, releases the lock, and drops `ClosedFile` afterward (`syscall/close.rs:22-35`).
The close wrapper therefore briefly remains an owner even after the FD is absent.
A model that separates removal from release must include that pending owner.

On final receiver destruction, replacing `queue.inner` with `None` drops the queued messages and their auxiliary file vectors (`net/socket/unix/datagram/message.rs:262-270`).
This does not require the peer's queue Arc itself to disappear.
There are no transferred Unix sockets or reference cycles in the selected input domain.
Other sender, receiver, fixture, or pending operation references must still be counted before expecting a transferred pipe writer's destruction or EOF.

## 5. Supported case matrix and static predictions

Every row is **NOT_RUN** on both Asterinas and Linux in this analysis.
Counts below concern new receiver FD installations, not the fixture's existing descriptors.
For every run, retain the complete result tuple: return/errno, payload bytes, raw control bytes, complete integer outcomes, reported length/flags, FD-to-object map, queue identity, and cleanup events.

| Case | Setup and expected distinction | Source-supported Asterinas prediction | Linux reference contract |
| --- | --- | --- | --- |
| SCM-01 | Successful send, then sender close or reuse. | Captured references continue to name the old objects. | Same object-identity guarantee. |
| SCM-02 | Enough writable control space, distinct and repeated object entries. | Installs one fresh FD per entry, reports the cmsg, consumes once. | Same completed-call ownership. FD integers need not match across systems. |
| SCM-03 | NULL, zero, header-only, or less than one integer of space. | No installation; zero reported length; `MSG_CTRUNC`; ordinary receive consumes and drops temporary rights. | Same no-delivery outcome. |
| SCM-04 | Capacity admits only a nonempty prefix. | Installs and publishes the fitting prefix; reports aligned/capped length and truncation; temporary suffix drops. | Same permitted prefix retention, with no whole-receive rollback. |
| SCM-05 | Writable header, first integer inaccessible. | One installed entry, zero complete integers, zero reported length, `MSG_CTRUNC`, payload-length return when outer outputs succeed. AST-32. | Failed slot is released without installation; no complete integer; truncation. Ordinary datagram is already consumed. |
| SCM-06 | Four rights, two writable integers, third integer inaccessible. | Three installed entries, two complete integers, fourth untouched; header describes the selected count but reported length is zero. AST-32 refinement. | Two entries remain installed, failed slot is released, fourth unattempted; writable header reports the two-entry prefix and truncation. |
| SCM-07 | Header unwritable, integers writable, enough capacity for all. | No insertion; zero reported length and truncation. | All numbers/FDs may complete before header failure; zero reported length is allowed and does not undo them. `MSG_CTRUNC` need not be set when all rights were delivered. |
| SCM-08 | Repeated PEEK followed by normal receive; observe then close each delivery. | Each PEEK clones rights and may install fresh descriptors; normal receive consumes the original once. | Same permitted copies. |
| SCM-09 | PEEK with integer fault, then valid retry. | Queue rights survive; the failed PEEK can additionally retain AST-32's installed entry. Retry can deliver another copy. | Queue survives; failing entry is not installed; completed prefix remains valid. |
| SCM-10 | Two ordinary receivers, one datagram, disjoint buffers. | Exactly one successful consumption; the other may see `EAGAIN`. Publication proceeds outside the queue lock. | Single consumption; Linux serializes longer under `iolock`. |
| SCM-11 | PEEK and ordinary receive compete. | Earlier PEEK selection plus later ordinary consumption is allowed even if their completions reverse. Ordinary-first can leave PEEK empty. | Same ownership contract, with Linux's actual longer serialization. |
| SCM-12 | Drop final receiver with one queued message and no active receive. | Queued rights drop when contents become `None`; independent file owners remain. | Socket disposal frees queued skbs and SCM rights. |
| SCM-13 | Payload fault, then valid retry, separately for ordinary and PEEK. | Both modes retain the message before ancillary generation. AST-36. | Ordinary receive consumed the record; PEEK retains it. |
| SCM-14 | Send payload copy faults after rights capture. | No enqueue or receiver installation; send temporary rights drop. | No publication; skb/SCM cleanup releases temporary owners. |

The source anchors for SCM-01/12/14 are §4.1 and §4.6; SCM-02–07/09 use §4.3–4.4; SCM-08/10/11 use §4.2; SCM-13 uses §4.5.
The [prepared contracts](/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/contracts.md) supply matching stable case IDs.

### Layout and observation requirements for later execution

On the intended native x86-64 ABI, verify `sizeof(cmsghdr) == 16`, `sizeof(int) == 4`, and cmsg alignment 8 in the actual test binary.
`CMSG_SPACE(sizeof(int)) == 24` can admit two integers. To advertise exactly one, use `CMSG_LEN(sizeof(int)) == 20` and distinguish allocated memory from advertised capacity.
Use `CMSG_LEN` for the send header's payload declaration.

For SCM-05, end the writable header exactly at a page boundary and make the next page inaccessible.
For SCM-06, start the header 24 bytes before the boundary so two integers fit before the failing third; advertise enough for four rights to preserve an untouched suffix.
For SCM-07, keep the header readable but not writable and make the following integer region writable.
Record actual page permissions and offsets.
An out-of-user-range writer-construction failure or a control-header copy failure is not interchangeable with a reached number-copy failure.

The output observer must not open diagnostic files during the FD census interval.
Use an established bounded FD range with `fcntl(F_GETFD)` and independently identify objects through tagged ordinary files or distinct pipe endpoints.
Do not use numeric-FD equality as the object oracle, and never act on a partial integer.
Observe unexpected installed entries before cleaning them up.
Pipe EOF is meaningful only after every setup writer, queued owner, temporary owner, and receiver FD has been accounted for and closed.
Any buffered tag bytes must also be drained before EOF is the expected observation.
A timeout alone does not prove leaked ownership.

Concurrency experiments need disjoint user buffers and `SMP >= 2` under the shared policy.
User-space barriers show attempted concurrency but do not prove overlap between kernel insertion and copy.
Only attributable production events can demonstrate the relevant interleaving.

## 6. Modeling and production trace handoff

The [modeling brief](modeling-brief.md) groups this work into four mechanism scenarios and supplies extensions, properties, and exclusions.
The base model should implement the selected Asterinas order, including known failing paths.
Linux is the separately identified external contract and, where useful, an explicit reference transition relation.
It is not a source of extra Asterinas locking assumptions.

Use one datagram, two object identities, four ordered rights including duplicates, two receiver participants, and a bound of two PEEK attempts and two ordinary attempts.
The ordinary-attempt bound covers both competing receivers and the AST-36 fault/retry control; at most one attempt can consume the message.
Provide at least 16 free receiver slots beyond the fixture baseline to keep allocation failure out of the state space.
Bounded fault choices are static properties of each call's buffer layout.
Introduce no post-install VM change, spurious CAS, weakened lock, arbitrary reference loss, or synthetic allocator failure.

Track owner tokens or multiplicities independently of a ghost initial/clone/drop balance.
Use one underlying `fdTable` indexed by `(tableId, integer)`; sender and receiver mappings are role/provenance views of that table.
The sender and receiver may share a table, as in a single-process socketpair fixture, so each occupied slot is counted once and allocator decisions use the shared occupancy.
The two receiver participants share a table; reuse of a sender number must not be mistaken for reuse of the captured object.
Do not define the balance merely as the sum used by the invariant, which would make conservation tautological.
Reference moves preserve the balance. Sender capture, PEEK duplication, and insertion clones increase it. Drops decrease it.
The temporary receive list still contains every captured entry while a prefix is being installed.
Pending close wrappers count as operation owners until their real drop.
Instrumenting object identity must not add owning Arcs that change the lifecycle under test.

Completed-call publication predicates must distinguish transient states.
Asterinas legitimately has a pending installed entry before its copy, and Linux legitimately has a copied number before installation.
`NoFailedNumberInstalled` tests the former only after the attempt and cleanup complete.
`CapturedObjectIdentity` checks delivered associations at an appropriate completed-entry/call boundary.
`DeliveredPrefixSurvives` preserves successful earlier entries after later failures, independently of header output or reported length.
Define `Completed` after implicit local drops, not merely after the return value is decided at `syscall/recvmsg.rs:58`.
The local `message_header` owns its temporary rights through that scope cleanup.
A delivered entry has completed both number copying and installation.

Protocol checks and AST-32/AST-36 compatibility checks must have separate reported results over the same source-faithful transitions.
A known mismatch must not suppress remaining protocol coverage, and disabling a check must not remove the underlying behavior.
Any bounded negative result must state object, rights, receiver, PEEK, FD-supply, fault-layout, and scheduling bounds.
Liveness assumes weak fairness for started local operations and explicitly requested cleanup; it does not assume that indefinitely retained FDs will close themselves.

### Required event observations

| Production site | Event data needed | Modeling purpose |
| --- | --- | --- |
| `syscall/sendmsg.rs:31-59`; `net/socket/unix/ctrl_msg.rs:103-113` | Operation/thread ID, sender number, captured object identity and rights index; successful capture and any failed capture cleanup. | Separate sender slots from captured objects and send temporary ownership. |
| `net/socket/unix/datagram/message.rs:60-96` | Queue/message identity, lock epoch, payload-copy result, auxiliary transfer, enqueue result. | Establish copy-before-enqueue and the actual publication boundary. |
| `net/socket/unix/datagram/message.rs:179-217` | Receiver/mode, selected message, payload result, ordinary dequeue or PEEK, lock boundaries. | Bind payload, rights, and consumption to the same selected message. |
| `net/socket/unix/ctrl_msg.rs:304-310` | Rights indices and objects, move versus clone, operation owner identities. | Distinguish independent PEEK references from consumed queue references. |
| `syscall/recvmsg.rs:43-52` | End of protocol receive, table borrow release, entry into control output. | Preserve the queue/publication split and explicit borrow release. |
| `net/socket/unix/ctrl_msg.rs:117-148` | Advertised capacity, selected count, header result, per-entry installed FD/object, number-copy success/failure. | Establish the insertion-before-copy window and complete-number oracle. |
| OSTD `mm/io/mod.rs:795-808` | Copy result and, if available without changing behavior, partial copied-byte count. | Separate a failed complete integer from raw dirty bytes and reset cursor. |
| `net/socket/util/message_header.rs:104-129`; `util/net/socket.rs:143-156` | Failed cmsg, NULL branch, accumulated length and truncation result. | Reconcile actual effects with reported ancillary state. |
| `syscall/recvmsg.rs:53-58` | Final flags/control length, outer write result, return/errno, operation temporary cleanup completion. | Close the attempted operation without erasing partial delivery. |
| `fs/file/file_table.rs:190-205`; `syscall/close.rs:22-35` | Table insertion/removal and actual pending-close release, including unexpected installed entries. | Account for every independent FD owner. |
| `net/socket/unix/datagram/message.rs:262-270` | Final receiver disposal and each queued message/right released. | Account for queue owners even when peer queue handles survive. |

Use nonblocking event capture and defer formatting/output work outside critical sections.
Read back the instrumented source to prove hook placement and that error branches, user-copy order, guard lifetimes, and cleanup still match this pin.
Events need per-operation order and real lock order; wall-clock timestamps alone do not establish either.
An abstract simulator or user-space syscall log cannot substitute for production observations of internal transfers.
No instrumentation is implemented in this analysis.

### Existing tests inspected

`test/initramfs/src/regression/network/unix_stream_err.c:22-115` exercises stream rights and cleanup, but its socket kind and exact numeric-FD assertions are not reusable oracles for this run.
Its send `cmsg_len` uses `CMSG_SPACE` at line 47, another reason to build and validate the intended datagram layout explicitly rather than copying it blindly.
`test/initramfs/src/regression/network/msg_peek.c:236-298` tests zero-payload SEQPACKET rights copying, outside this input domain.
The datagram PEEK test at lines 301–316 has payload but no SCM_RIGHTS.
`test/initramfs/src/regression/network/msg_trunc.c:124-148` checks datagram/record truncation but not partial ancillary publication.
These files were inspected as source examples. None was run, and they supply no runtime proof for SCM-05/06/09/10/11.

## 7. Rejected hypotheses, developer signals, and scope exclusions

| Hypothesis or signal | Re-read evidence and disposition |
| --- | --- |
| Dropping the ancillary vector removes installed FDs. | Rejected: `ctrl_msg.rs:139-148` clones into independent `FileTableEntry` owners. Vector drop releases its own Arcs only. |
| Every ancillary fault requires whole-receive rollback. | Rejected: Linux `receive_fd` protects the failing entry; `scm_detach_fds` preserves already completed entries and ordinary receive may already have consumed the datagram. |
| Zero `msg_controllen` proves no number was delivered. | Rejected: Asterinas counts only fully completed cmsgs; Linux header faults can follow complete number delivery. See §4.3–4.4. |
| Restored writer cursor restores user memory. | Rejected: OSTD `mm/io/mod.rs:801-807` only subtracts `copied_len` from the cursor. |
| Repeated PEEK of the same object is duplicate consumption. | Rejected: `generate_control` deliberately clones at `ctrl_msg.rs:307`; Linux also duplicates at `net/unix/af_unix.c:1938-1941`. |
| Competing ordinary receivers can select the same head concurrently. | Rejected under the selected path: queue mutex spans head access, payload copy, and dequeue at `datagram/message.rs:179-217`. Later publication can still interleave. |
| Sender numeric-FD reuse retargets queued rights. | Rejected: `ctrl_msg.rs:109` captures an owned object reference and receiver publication never re-looks up the sender number. |
| Peer-held queue handles keep queued rights after receiver destruction. | Rejected: `MessageReceiver::drop` clears queue contents regardless of the queue Arc's remaining owners at `datagram/message.rs:268`. Socket cycles are excluded. |
| `MSG_CMSG_CLOEXEC` or per-call `MSG_DONTWAIT` is supported because the constant exists. | Rejected: explicit supported mask excludes both; socket-level nonblocking is the selected setup. |
| Resource-limit and allocation TODOs indicate an in-scope counterexample. | Excluded: `ctrl_msg.rs:99-101`, `message_header.rs:46-49`, and `file_table.rs:192` concern bounds outside this finite no-stress model. |
| Unix rights cycles / incomplete socket-type restriction. | Explicitly excluded: `ctrl_msg.rs:256-271` and PR #2176 discuss this distinct mechanism. Only ordinary files/pipes are transferred. |
| Credentials, unknown protocols, timeout/restart TODOs. | Excluded: `ctrl_msg.rs:228,245`, `sendmsg.rs:61`, `recvmsg.rs:37`; neither their inputs nor transitions occur here. |
| AST-31 whole-msghdr writeback or unrelated close/dup/exec races. | Explicit exclusions. `recvmsg.rs:56` remains visible as a successful terminal output under valid stable outer metadata, not a new fault surface. |

No in-scope compensating mechanism was found for AST-32's installed failing entry or AST-36's retained ordinary message.
Conversely, the source does support cleanup of undispatched temporary references, PEEK queue retention, and at-most-once ordinary dequeue.
These are static conclusions with the explicit scope above, not claims of unbounded correctness or completed runtime validation.

## 8. Phase 4 handoff and remaining gates

`modeling-brief.md` is the primary Spec Generation handoff.
The model remains required even with zero new MC candidates, because the bounded protocol properties and interactions have independent verification value.
Known failures remain separately attributable to AST-32 and AST-36.
There is no reason to allocate a new ID for a prefix variation or a PEEK instance of AST-32 without a genuinely different cause and consequence.

The ordinary staged reviews for model/spec generation, harness generation, validation, and findings remain required under the receiving controller.
This source analysis and its parallel cross-checks do not replace them.
The controller also owns heavy-stage locking, host reserve checks, provider readiness, execution commands, and any subsequent classification or repair authorization.

Remaining evidence includes the actual test ABI/layouts, same-program Linux controls on an identified running kernel, fixture FD/object census, production branch/event traces, meaningful bounded MC coverage, and release observations.
Any difference between the running Linux control and the pinned reference source must be reconciled before changing the oracle.
No phase marker, catalog status, or completion claim for those activities is written by this analysis.

## 9. Final archaeology ledgers and independent analysis checks

The finalized history, issue, open-PR, and independent source-read results follow here.

### 9.1 Coverage statistics

| Measure | Result |
| --- | ---: |
| Distinct issues collected across eight searches | 466 |
| Issues deeply read, with all conversation comments | 32 |
| Issue conversation comments read | 94 |
| Confirmed historical bug reports | 17 |
| Acknowledged design defects | 7 |
| Feature-context trackers | 5 |
| Uncertain issue reports | 2 |
| Disputed/false kernel-bug attributions excluded | 1 |
| User-error classifications | 0 |
| Open PR bodies screened | 109 |
| Open correction/boundary PRs deeply reviewed | 49 |
| Open PR conversation/review/inline records read | 97 / 92 / 199 |
| Open PR changed-file entries inspected | 775 |
| Historical PRs deeply read, excluding open PRs | 36 |
| Historical PR conversation/review/inline records read | 64 / 275 / 496 |
| Unique core-history commit subjects and full bodies screened | 98 |
| Keyword/semantic-signal matches reviewed in scoped patches | 17 |
| Additional non-keyword scoped patch reviews by history helper | 16 |
| Historical semantic-fix commits identified and analyzed | 13 |
| Keyword matches excluded as style/API-only | 8 |
| New in-scope defect candidates | 0 |
| Existing in-scope source leads retained without promotion | 2 |

The 36 historical PRs comprise the primary analyst's five source-behavior PRs, helper A's 21 history/context PRs, and helper B's ten issue-linked PRs.
The 32 deeply read issues comprise 16 per helper.
The remaining collected issues are discovery results, not deeply verified reports, and are not used as findings evidence.
Confirmed historical reports and design defects do not count as this run's new findings.
The rejected attribution count is one issue, #3178; rejected subclaims within other threads are separately documented rather than inflating that count.

### 9.2 All historical semantic-fix commits

All 13 commits are ancestors of the selected pin.
Severity below describes the historical mechanism, using the analysis skill's qualitative scale; it does not classify AST-32 or AST-36.
Closed fixes remain reference context and are not proposed as reverted-state model hunts.

| Commit | Component / historical severity | Verified cause and correction |
| --- | --- | --- |
| `8600278a5f34` | File-table lifetime / High | File tables were retained beyond process/thread exit; introduce removable ownership and drop contained files before notifying table destruction. |
| `e0b702663563` | Ancillary reporting / Medium | Capacity/error truncation did not set MSG_CTRUNC; propagate output flags through cmsg and recvmsg layers. Per-integer failure installation order was unchanged. |
| `f62ae4018801` | Ancillary input validation / Low | Rejecting header-only UNIX cmsgs disagreed with accepted Linux inputs; permit header.len equal to header size. Empty record/capacity testing remains excluded. |
| `419f31397f69` | Shared user I/O metadata validation / High | Centralize count and total-byte limits before allocation/conversion; add sendmsg/recvmsg oversized-iov checks, fixing #1327 and #1245. |
| `fc99595be200` | Final file release / Medium | Close notification tracked a descriptor close rather than the final file-object release; move it to FileCommon::drop. |
| `e631da203c2c` | Cleanup after unlock / High | Range-lock cleanup could sleep under file-table spinlock; return ClosedFile and defer its drop until after lock release. |
| `aa23e850c40b` | Range-lock ownership / High | PID ownership did not match shared FileTable ownership; key locks by table identity, release on table destruction, and recheck after blocking acquisition. |
| `7ade3b5dd65f` | Range-lock close semantics / Medium | Last-object-drop release missed any-descriptor-close semantics; close/dup/exec cleanup uses close_file, and range mutation now changes the stored range. |
| `ce4b59329f05` | Duplication publication/error order / Medium | dup2/dup3 closed target before validating source; validate source first and return removed target for cleanup outside lock; return EBADF. |
| `2d01804d19ed` | Procfs callback locking / High | File-table observer callbacks acquired sleeping procfs mutexes under spinlock and cached stale FD ownership; replace event/cache scheme with current table lookup. |
| `293f1ff4c937` | Cleanup after unlock / High | Move range-lock release out of file-table critical sections into object Drop. This historical workaround was later corrected for per-close semantics by 7ade3b5dd65f and owner-aware ClosedFile. |
| `6ce25dc38b4a` | Record-lock cleanup / High | Closing an FD/process failed to release range locks; install per-close cleanup across ordinary/all/exec close paths. Later lifecycle commits refine this. |
| `8e1aeaf578dc` | FD flags / Medium | insert_at ignored passed descriptor flags; preserve them. The same commit adds dup3 and fixes EventFile metadata outside this target. |

The complete 98-commit screen, exact historical paths, selected full/scoped patches, and every exclusion are retained in [the commit ledger](analysis-evidence/agent-a/commit-ledger.md) and its JSON counterpart.
Helper A's historical PR read ledger is [pr-ledger.json](analysis-evidence/agent-a/pr-ledger.json).
The original keyword union is [bugfix-history.json](analysis-evidence/bugfix-history.json); the complete file histories are [core-history.json](analysis-evidence/core-history.json).

| Current core path | Semantic-fix commit memberships |
| --- | ---: |
| `syscall/sendmsg.rs` | 1 |
| `syscall/recvmsg.rs` | 2 |
| `net/socket/unix/ctrl_msg.rs` | 1 |
| `net/socket/unix/datagram/message.rs` | 0 |
| `net/socket/util/message_header.rs` | 2 |
| `util/net/socket.rs` | 2 |
| `fs/file/file_table.rs` | 10 |

A commit touching several files contributes to several rows, so these memberships must not be summed into a distinct-fix count.
The concentration in file-table cleanup/ownership history motivates precise owner and lock boundaries.
Zero historical semantic-fix commits for the datagram queue does not eliminate its mandatory protocol coverage or its existing AST-36 lead.

### 9.3 Issue dispositions

| Issue | Classification | Verified mechanism, fix, and boundary |
| --- | --- | --- |
| [#1327](https://github.com/asterinas/asterinas/issues/1327) | Confirmed bug | Fixed by PR #2397 / 419f31397f69; maintainer explicitly confirms. Unbounded msg_iovlen allocated a Vec before shared validation; historical recvmsg outer-metadata boundary, excluded by valid metadata and bounded resource assumptions. |
| [#1245](https://github.com/asterinas/asterinas/issues/1245) | Confirmed bug | Fixed by PR #2397 / 419f31397f69; reporter explicitly confirms. Oversized iov lengths/counts reached infallible allocations; shared iovec validation moved into conversion. The original program includes an uninitialized recvmsg, so the follow-up readv reproducer and explicit fix discussion are the useful corroboration. |
| [#1304](https://github.com/asterinas/asterinas/issues/1304) | Confirmed bug | Fixed by PR #1365 / 1aa8b0abc65e; explicit Fixes link and merged change. UNIX stream RwLock permitted sleeping mutex/user-copy under atomic mode. Discussion rejects equating an epoll panic with this UNIX case without matching symbols. Reference only; current target uses its actual mutex boundaries. |
| [#2165](https://github.com/asterinas/asterinas/issues/2165) | Design defect | OPEN. Claimed PR #2351 fix was explicitly rejected and retracted; no fix established. Fallible user-memory I/O inside atomic mode remains a tracked architecture problem, especially IP socket spinlocks. The in-scope queue/file-table locks must be read directly; no generic VM-race expansion. |
| [#1608](https://github.com/asterinas/asterinas/issues/1608) | Uncertain | Stale-closed as not_planned; no verified fix or root cause. Go stream socketpair test uses dummy syscall implementations and fails in signal/executable-page handling; a C version works. No evidence attributes this to SCM_RIGHTS. Exclude from target, not a debunked report. |
| [#1554](https://github.com/asterinas/asterinas/issues/1554) | Confirmed bug | Fixed by PR #1559 / 85d2c9634f5c; full discussion includes Linux comparison and unit-test decision. Pipe capacity allowed short writes below PIPE_BUF. Pipe write atomicity is unrelated to ownership transfer of ordinary pipe references here. |
| [#1356](https://github.com/asterinas/asterinas/issues/1356) | Design defect | Implemented by PR #1616 / ec2c6ab7a3f2; thread changes fully stateless proposal to cached semi-stateless design. Split readiness state and actual queue state could yield stale POLLOUT loops and redundant locks. Reference only; nonblocking target does not model generic poller liveness. |
| [#506](https://github.com/asterinas/asterinas/issues/506) | Design defect | Resolved through PR #1092 / c320552ae108 and #1098 / fce5785af6a7, with distinct scopes. Per-FD close is not final FileLike release. Maintainers withdrew an Arc strong_count-based last-close proposal and removed unused cleanup methods; TCP closure required a separate fix. Thread also cites historical pipe2 output-fault cleanup 8df51ab0010. Do not assume all close operations are immediate or all syscall failures roll back ownership. |
| [#529](https://github.com/asterinas/asterinas/issues/529) | Confirmed bug | Maintainer reports done by PR #1855 / d40d452e9d52. Full PR establishes TCP reset/error behavior; a full historical UNIX poll audit is outside this scope. HUP/RDHUP/ERR use was inconsistent with shutdown/reset semantics. Stream/TCP readiness is excluded. |
| [#344](https://github.com/asterinas/asterinas/issues/344) | Design defect | Fixed by PR #394 / 4fef4d9b79f6; body explicitly references this issue and PR is merged. Missing TCP final-close polling/handshake handling. No SCM datagram applicability. |
| [#819](https://github.com/asterinas/asterinas/issues/819) | Confirmed bug | PR #1098 explicitly fixes #819 and explains reset-on-premature-removal mechanism. Pending TCP transmissions/closure depended on interface polling and retaining closing socket state. Original Nagle workaround was challenged because its old test was disabled, not validated. IP/TCP excluded. |
| [#1253](https://github.com/asterinas/asterinas/issues/1253) | Confirmed bug | Reporter confirms fix in PR #1257 / 59b7a9397fcf. Timer interrupt reentered local-runqueue lock and caused hangs seen in pipe/UNIX benchmarks. A slowdown masking the hang is not ownership evidence. Scheduler deadlock excluded. |
| [#1296](https://github.com/asterinas/asterinas/issues/1296) | Confirmed bug | PR #1302 / c68302f70072 explicitly fixes it; merged and approved. epoll waited while retaining file-table lock, preventing writer progress. Discussion rejects RwMutex as sufficient; must release locks before waiting. Reference for narrow lock ownership assumptions. |
| [#2782](https://github.com/asterinas/asterinas/issues/2782) | Confirmed bug | PR #2783 / bcf8f5e93c58 blocks the supplied huge-RLIMIT PoC. Reviewer explicitly says this does not eliminate general infallible-allocation exhaustion. poll allocated a user-sized Vec with excessive resource limits. Resource-limit stress and allocator failures excluded; record narrow mitigation, not universal OOM fix. |
| [#1483](https://github.com/asterinas/asterinas/issues/1483) | Confirmed bug | OPEN tracker with acknowledged examples, reproduction and later klint discussion; not globally fixed. Mutex/RwMutex acquisition under spinlocks/IRQ-disabled regions may panic. Generic atomic-mode audit is outside this bounded message protocol. |
| [#3157](https://github.com/asterinas/asterinas/issues/3157) | Confirmed bug | Condvar timeout case fixed by PR #3309 / e02711114587. Maintainer confirms all three cases; the two vsock rewrite cases were not independently source-verified here. Condvar retained counter spinlock while reacquiring sleeping mutex; vsock nested lock cases also acknowledged. Vsock and timeout races excluded. |
| [#1888](https://github.com/asterinas/asterinas/issues/1888) | Feature context | Go syscall-coverage tracker includes SCM_RIGHTS, PEEK, TRUNC and unsupported receive flags as requested features. The only comment is the stale bot. Closing linkage is feature/test PR #2943, not proof that every table row was implemented. Coverage motivation only. Do not infer MSG_CMSG_CLOEXEC support from a completed tracker. |
| [#2112](https://github.com/asterinas/asterinas/issues/2112) | Feature context | XFCE gap tracker explicitly requests AF_UNIX DGRAM and SCM_RIGHTS. In comments 2952755052 and 2954788778 the need is identified and acknowledged. Comment 3766174025 closes the application-support task because release 0.17.0 runs XFCE. Relevant introduction context. No individual publication-defect report or blanket ABI guarantee. |
| [#1851](https://github.com/asterinas/asterinas/issues/1851) | Feature context | Docker feature tracker includes MSG_DONTWAIT and MSG_CMSG_CLOEXEC requirements. Closed not_planned after staleness. Comment 3953884445 says Docker is still desired, the tracker is outdated by Podman, and remaining gaps need a new issue. Do not equate closed status with receive-flag support or a fix. |
| [#703](https://github.com/asterinas/asterinas/issues/703) | Feature context | runc/Kata feature tracker and all nine comments describe missing namespace, cgroup and syscall capabilities. Comment 3788365146 explicitly says it is replaced by #2911. Historical feature context, not a resolved SCM bug. |
| [#2905](https://github.com/asterinas/asterinas/issues/2905) | Confirmed bug | Reproduction and panic trace show dup3 with usize::MAX reaching SlotVec::put_at overflow. Timeline links the explicit validating fix #2906 and regression follow-up #2927. Outside scope: unrelated dup target validation and resource limits. |
| [#2907](https://github.com/asterinas/asterinas/issues/2907) | Design defect | FD type-safety issue was accepted with caveats: negative raw syscall values are legitimate sentinels. Comments 4089417067 and 4175356583 distinguish old-FD lookup from new-FD range validation. #3028 supplies the typed-FD change. Reference for FD-number domains, not evidence of SCM publication failure. |
| [#1146](https://github.com/asterinas/asterinas/issues/1146) | Design defect | Earlier accepted type-safety proposal separates RawFileDesc from valid FileDesc. Two comments discuss claiming and extending it to UID/GID. The thread provides no explicit closing fix. Later #3028 realizes the related type distinction at the selected pin, but is not asserted to have closed this issue. Reference only. Closed completed alone establishes no fix mapping. |
| [#2179](https://github.com/asterinas/asterinas/issues/2179) | Confirmed bug | Reproduction races procfs FD directory access against process exit and records an unwrap panic. Timeline links #2180, which checks optional file_table before use. Outside scope: procfs and process-exit race. |
| [#3178](https://github.com/asterinas/asterinas/issues/3178) | Disputed/False | The original CLONE_FILES defect attribution is disproved in comment 4679203237: procfs reuses the low pipe-write FD during exec, so the parent closes an unrelated descriptor. #3379 fixes the regression test by retaining a high write FD. False kernel-bug attribution. Relevant observer lesson: numeric FD reuse is not object identity. |
| [#2851](https://github.com/asterinas/asterinas/issues/2851) | Uncertain | Report contains a fork/F_SETOWN hang reproducer, but its GDB evidence is the idle loop and the sole comment is stale-bot text. The issue is closed not_planned. Related #2864 comment 3727569564 explicitly says no clear explanation links its defects to this hang. Outside scope. No supported root cause or fix; do not promote stale closure to resolution. |
| [#2864](https://github.com/asterinas/asterinas/issues/2864) | Confirmed bug | Maintainers acknowledge missing process-group ownership, missing SIGIO permission checks, blocking poll under file-table spin lock, and owner stored per FD instead of per open file description. Comment 4998337831 says #3577 resolved items 3/4 while 1/2 remain. Current open #3841/#3842 address remaining owner behavior. Outside scope: F_SETOWN and signal delivery. Shared file-description identity is reference context. Status is partially fixed, not fully fixed. |
| [#2256](https://github.com/asterinas/asterinas/issues/2256) | Design defect | Maintainer proposal identifies missing inode operations for non-inode FileLike objects. Discussion corrects the claim that fstatfs need not expose sockfs/pipefs. Comment 4028392232 states #2555 addressed the problem by a different approach. Reference for file-object architecture. Do not import the rejected InodeLike design into the pin. |
| [#1525](https://github.com/asterinas/asterinas/issues/1525) | Feature context | Requests pseudo filesystems to expose metadata and procfs identity for special files. Comment 3742264944 explicitly links completion to #2798. Architectural feature context only. |
| [#3792](https://github.com/asterinas/asterinas/issues/3792) | Confirmed bug | Reproducer and panic trace show lossy UTF-8 expansion of a 108-byte Unix pathname into 110 bytes, then an out-of-bounds getsockname copy. Timeline links raw-byte pathname fix #3850. Outside scope: pathname encoding and getsockname output; socketpair/message identity is the selected setup. |
| [#3374](https://github.com/asterinas/asterinas/issues/3374) | Confirmed bug | C reproducer supplies paired Linux/Asterinas output: small and zero getsockopt lengths succeed on Linux but return EINVAL in Asterinas. Timeline links #3848, not merely the earlier unmerged #3574. Outside scope: socket-option value ABI. Its partial-copy semantics must not be generalized to FD ownership. |
| [#3947](https://github.com/asterinas/asterinas/issues/3947) | Confirmed bug | Reporter supplies a reproduced pidfd_getfd permission-check/exec-credential race and a proposed locking fix. Comment 5929457059 acknowledges the VMAR/credential contract. Comment 5931921210 rejects the same race for current PTRACE_TRACEME because exec waits for sibling exit, while reporting distinct ptrace problems. No closing fix is linked. Outside scope: pidfd_getfd, exec, credentials and ptrace. Current reported issue is retained as known context, not a fresh discovery. |

The detailed evidence and limitations are in [helper A's issue ledger](analysis-evidence/agent-a/issue-ledger.md), [helper B's issue report](analysis-evidence/agent-b/issues-report.md), and their raw paginated responses.
Every cited historical fix PR was read with its full discussion and reviews; helper B's ten additional full-thread dispositions are in [historical-pr-report.md](analysis-evidence/agent-b/historical-pr-report.md).
In particular, #2165's claimed fix was retracted, #1608 and #2851 remain uncertain despite closure, and #2864 is only partially fixed.
The #3178 observer error reinforces the need to distinguish file identity from a reused numeric descriptor.

### 9.4 Open PR coverage

All 109 bodies were screened for correction intent, including mixed feature/correction work and defensive changes.
The 49 conservatively selected PRs were read with all conversation comments, review bodies, inline comments, and changed-file lists.
Overlapping hunks were additionally read for #3576, #3729, #3355, and #2615.
The scope review found no proposed change to this bounded SCM capture, queue ownership, failed-number installation, or ancillary cleanup mechanism.
This does not certify the correctness of unrelated changes.

The exact 109 HEAD identities, selection decisions, 49 full-thread counts, and per-PR exclusions are retained in [open-pr-ledger.json](analysis-evidence/agent-b/open-pr-ledger.json) and [open-pr-report.md](analysis-evidence/agent-b/open-pr-report.md).
All selected HEAD OIDs matched the initial collection snapshot, and downloaded comment/file totals matched API totals.

- [PR #3576](https://github.com/asterinas/asterinas/pull/3576) touches the sendmsg, recvmsg, and datagram paths, but its changes concern EINTR/ERESTARTSYS and timeout conversion, which are excluded here.
- [PR #3729](https://github.com/asterinas/asterinas/pull/3729) changes generic socket read/write parameters while implementing ext2 NOWAIT behavior; it does not change ancillary publication.
- [PR #3338](https://github.com/asterinas/asterinas/pull/3338) has fix intent, but the discussion disputes treating intentionally unsupported IP wildcard binding as a kernel bug. It is not counted as a confirmed SCM defect.

### 9.5 Independent source analysis and document checks

The two helpers completed four focused analysis assignments after their parallel history batches.
Each assignment applied the shared and Category B patterns, reread exact candidate sites, followed compensating paths, and checked scope against the supplied contracts.
The primary analyst cross-referenced these results with independent complete reads of all seven requested files.

| Focus | Independent report | Result |
| --- | --- | --- |
| Capture and SCM publication | [deep-control.md](analysis-evidence/agent-a/deep-control.md) | Confirms capture by owned object, clone-versus-move behavior, per-FD installation/copy split, and no compensating removal for existing AST-32. |
| File table and cleanup | [deep-file-table.md](analysis-evidence/agent-a/deep-file-table.md) | Confirms per-slot ownership, shared/exclusive lookup behavior, pending `ClosedFile` ownership, and queue-content disposal. |
| Datagram selection | [deep-queue.md](analysis-evidence/agent-b/deep-queue.md) | Confirms one queue critical section, permitted PEEK clones, at-most-once ordinary consumption, and bounded AST-36 attribution. |
| Output and completion | [deep-output.md](analysis-evidence/agent-b/deep-output.md) | Confirms NULL/capacity/fault distinctions, independent output fields, skipped alignment padding, and Linux's permitted header-fault outcome. |

No additional candidate survived these checks.
The final handoff explicitly distinguishes completed calls from return-value decisions before implicit drops, and out-of-range writer-construction failure from an inaccessible-page copy failure.
It also defines object identity as an open file description, keys FD slots by table and integer, and counts each occupied shared-table slot once.
The detailed source reports are analysis cross-checks, not the later pipeline's spec, harness, validation, or findings reviews.

Document checks verified the brief's seven required sections and subsections, its 100–200-line format bound, all 14 case IDs in the report, local evidence links, and deduplicated discussion counts.
The historical-PR count excludes the downloaded but unread #3122 thread.
The selected Asterinas HEAD/tree were rechecked, and all 15 manifest source files match their exact committed bytes.
The working tree still has no tracked changes and only the pre-existing untracked `.codex/` directory.
These are artifact/source consistency checks, not kernel tests or protocol verification.

The input/source fingerprints are in [source-input-manifest.json](analysis-evidence/source-input-manifest.json), the successful reference comparison is in [linux-source-check.json](analysis-evidence/linux-source-check.json), and audited counts are in [coverage-summary.json](analysis-evidence/coverage-summary.json).
