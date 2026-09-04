# CR-6 Investigation (fresh, independent)

## Finding
post_message mutates queue/accounting before validating; recv consumes a message
before copying it out — an error path can drop a message or leave accounting
inconsistent. Cited sites (finding gives `pm/ipc/recv.rs`, real path is `ipc/recv.rs`):
- `src/kernel/src/pm/process/manager/mod.rs:3782` (post_message)
- `src/kernel/src/ipc/recv.rs:56` (recv)

## Step 1 — Code audit

### Mechanism A: post_message mutate-then-count (manager/mod.rs:3782)
post_message: `state_mut().post_message(message)` -> `Mailbox::send` -> `buffer.push_back`
(UNBOUNDED LinkedList, mailbox.rs:43). No queue-capacity limit => NO "queue overflow" error.
Then `note_message_posted()?` (manager/mod.rs:2975) `checked_add(1)`; Err only on counter
overflow at usize::MAX (2^64-1) — physically unreachable. If it fired, message is already
enqueued while count NOT incremented => imbalance + post returns Err. Ordering smell but the
error path is UNREACHABLE.

### Mechanism B: recv consume-then-copy (ipc/recv.rs:49-63)  <-- reachable, consequential
recv: `EventManager::wait` (CONSUMES) then `copy_to_user` (COPIES).
Consume chain: wait (event/manager.rs:1020) -> try_wait (:490) -> ProcessManager::try_recv
(unsafe.rs:1084) -> state.receive_message -> Mailbox::receive (mailbox.rs:74) `buffer.remove`
(POP) ; then `note_message_received()?` (DECREMENT). Popped Message returned to recv, which
THEN calls copy_to_user -> vmcopy_to_user -> Vmem::copy_to_user_unaligned (vmem.rs:1482):
returns Err(BadAddress/NoSuchEntry) on invalid/unmapped user buffer; does NOT kill the process.
On Err, recv returns Err but the message is already gone and count decremented; nothing
re-queues. => PERMANENT message loss. Accounting stays BALANCED (queue and count both -1);
harm is LOSS, not miscount.

### Reachability
- recv entry: Recv kcall (dispatcher.rs:140), arg0 = user-controlled buffer pointer. Bad/
  unmapped buffer -> copy fails after consumption. Reachable via public API.
- handle_sleep_error(Generic) (dispatcher.rs:259) just returns KcallResult::Error — NO re-queue,
  NO restart. Loss permanent.
- Real consumers: receiver process (loses sender's message, cannot retry) and sender (send
  succeeded, believes delivered).

## Step 2 — Developer-knowledge search
- Contrast: rendezvous push/pull DOES handle copy failure (ipc/rendezvous.rs:352-372, :520-540):
  "Copy failed. Wake up the sleeping puller/pusher to prevent deadlock" + return Err WITHOUT
  losing data. Mailbox recv path has no equivalent safeguard => evidence of oversight, not
  intended contract.
- Existing test pm/test.rs:47 drives real Mailbox (send/is_empty) but not the copy-failure loss.
- No comment/TODO on recv claiming loss is by design.

## Step 3 — Known-status / precedent
- No remote configured; searched nanvix/nanvix tracker via API:
  - #2891 "[syscall] Add pull-based payload transfer to recv()" — performance change in USERSPACE
    socket layer (src/libs/syscall/.../socket/recv.rs). DIFFERENT site + mechanism (round-trips),
    not kernel mailbox consume-then-copy loss.
  - #2904/#2905 rendezvous timeouts. Different mechanism.
  - Nothing reports kernel ipc/recv.rs consume-then-copy or post_message mutate-then-count.
- Novelty: NEW (searched open+closed issues and recent PRs).

## Preliminary assessment (verdict after Phase 2)
Source: Code Review (TV-6, no MC CE). Mechanism A unreachable; Mechanism B = reachable permanent
message loss on bad-buffer recv, no mask, real consumers harmed => toward REPRODUCED via real
Mailbox code + reachable copy failure.
