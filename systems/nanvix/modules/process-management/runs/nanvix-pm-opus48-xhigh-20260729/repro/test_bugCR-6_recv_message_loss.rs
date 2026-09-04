// Reproduction for finding CR-6:
// "IPC post_message/recv can lose a message on the error path (consume-then-copy)"
//
// Nanvix kernel sites:
//   - src/kernel/src/ipc/recv.rs:49-63        (recv: wait(consume) then copy_to_user)
//   - src/kernel/src/pm/process/manager/unsafe.rs:1084-1094 (try_recv: receive_message + note_message_received)
//   - src/kernel/src/ipc/mbx/mailbox.rs:74-98 (Mailbox::receive removes the message)
//   - src/kernel/src/pm/process/manager/mod.rs:2975-3015 (note_message_posted/received)
//   - src/kernel/src/pm/process/manager/mod.rs:3782-3797 (post_message: send then note_posted)
//   - src/kernel/src/mm/virt/vmem.rs:1357-1364 (copy_to_user_unaligned returns Err(BadAddress)
//                                               when the destination is not a user-space region)
//
// This is a faithful, self-contained reconstruction (escalation Level 2/3): the real kernel
// cannot be booted to issue a `Recv` kcall in this batch environment, so the reproduction
// executes the *verbatim* real `Mailbox` queue logic together with the real manager counter
// logic and the real `recv()`/`try_recv()` ordering. Only `copy_to_user` is modeled — it
// returns Err for a non-user (bad) destination buffer exactly as
// `Vmem::copy_to_user_unaligned` does (vmem.rs:1357-1364). No system logic is altered.
//
// The injected precondition (a message buffered in the mailbox + a recv with a bad user
// pointer) is reachable through a real API sequence:
//   1. a producer posts a message to process P (another process's `send`, or the IKC poller
//      `poll_ikc_messages` -> EventManager::post_message -> pm.post_message);
//   2. a thread of P issues the `Recv` kcall (dispatcher.rs:140) with `msg` (arg0) pointing
//      outside its user address space.
//
// Build/run: rustc --edition 2021 -O test_bugCR-6_recv_message_loss.rs -o /tmp/cr6 && /tmp/cr6

use std::collections::LinkedList;

// ---------------------------------------------------------------------------
// Minimal faithful stand-ins for ::sys types used by Mailbox.
// ThreadIdentifier mirrors sys/pm/tid.rs (i32; NONE = -1, is_none()).
// ---------------------------------------------------------------------------
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct ThreadIdentifier(i32);
impl ThreadIdentifier {
    const NONE: ThreadIdentifier = ThreadIdentifier(-1);
    fn is_none(&self) -> bool {
        *self == Self::NONE
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct MessageReceiver {
    pid: i32,
    tid: ThreadIdentifier,
}

// Message stands in for sys::ipc::Message: it carries a destination and a payload byte we can
// track to prove a specific message was lost. `destination` is the only field Mailbox reads.
#[derive(Clone, Debug)]
struct Message {
    destination: MessageReceiver,
    payload0: u8,
}

// ---------------------------------------------------------------------------
// REAL Mailbox — copied verbatim from src/kernel/src/ipc/mbx/mailbox.rs
// (only the import paths differ). Do not modify: this is the system code under test.
// ---------------------------------------------------------------------------
#[derive(Default)]
struct Mailbox {
    buffer: LinkedList<Message>,
}

impl Mailbox {
    pub fn send(&mut self, message: Message) {
        self.buffer.push_back(message);
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    pub fn receive(&mut self, tid: ThreadIdentifier) -> Option<Message> {
        // Search for a message that is addressed to the thread.
        let message_index = self
            .buffer
            .iter()
            .position(|msg| { msg.destination }.tid == tid);

        // If a message was found, remove it from the buffer and return it.
        if let Some(index) = message_index {
            return Some(self.linkedlist_remove(index));
        }

        // Locate the first message that is addressed to the process.
        let message_index = self
            .buffer
            .iter()
            .position(|msg| { msg.destination }.tid.is_none());

        // If a message was found, remove it from the buffer and return it.
        if let Some(index) = message_index {
            return Some(self.linkedlist_remove(index));
        }

        None
    }

    // LinkedList::remove(index) is nightly-only in std; emulate the exact semantics
    // (remove and return the element at `index`) used by the kernel's LinkedList.
    fn linkedlist_remove(&mut self, index: usize) -> Message {
        let mut tail = self.buffer.split_off(index);
        let elem = tail.pop_front().expect("index in range");
        self.buffer.append(&mut tail);
        elem
    }

    fn len(&self) -> usize {
        self.buffer.len()
    }
}

// ---------------------------------------------------------------------------
// REAL manager counter logic — from src/kernel/src/pm/process/manager/mod.rs
// note_message_posted (2975-2986) / note_message_received (3001-3015).
// ---------------------------------------------------------------------------
struct Manager {
    mailbox: Mailbox,
    number_buffered_messages: usize,
}

#[derive(Debug)]
struct KernelError(&'static str);

impl Manager {
    fn new() -> Self {
        Manager { mailbox: Mailbox::default(), number_buffered_messages: 0 }
    }

    fn note_message_posted(&mut self) -> Result<(), KernelError> {
        match self.number_buffered_messages.checked_add(1) {
            Some(n) => {
                self.number_buffered_messages = n;
                Ok(())
            }
            None => Err(KernelError("number of buffered messages overflowed")),
        }
    }

    fn note_message_received(&mut self) -> Result<(), KernelError> {
        match self.number_buffered_messages.checked_sub(1) {
            Some(n) => {
                self.number_buffered_messages = n;
                Ok(())
            }
            None => Err(KernelError("number of buffered messages underflowed")),
        }
    }

    // REAL post_message ordering — manager/mod.rs:3782-3797.
    fn post_message(&mut self, message: Message) -> Result<(), KernelError> {
        self.mailbox.send(message); // mutate queue
        self.note_message_posted()?; // then count
        Ok(())
    }

    // REAL try_recv ordering — manager/unsafe.rs:1084-1094.
    fn try_recv(&mut self, tid: ThreadIdentifier) -> Result<Option<Message>, KernelError> {
        match self.mailbox.receive(tid) {
            Some(message) => {
                self.note_message_received()?; // consume (queue -1, count -1)
                Ok(Some(message))
            }
            None => Ok(None),
        }
    }
}

// Models Vmem::copy_to_user_unaligned (vmem.rs:1357-1364): returns Err(BadAddress) when the
// destination pointer is not a valid user-space buffer. `good_buffer == false` reproduces the
// "bad user buffer" case named by the finding.
fn copy_to_user(good_buffer: bool, _msg: &Message) -> Result<(), KernelError> {
    if good_buffer {
        Ok(())
    } else {
        Err(KernelError("BadAddress: destination region does not lie in user space"))
    }
}

// REAL recv() control flow — ipc/recv.rs:49-63 (EventManager::wait consumes via try_recv;
// then copy_to_user; on Err, return Err WITHOUT restoring the consumed message).
fn recv(mgr: &mut Manager, tid: ThreadIdentifier, good_buffer: bool) -> Result<(), KernelError> {
    // EventManager::wait -> try_wait -> ProcessManager::try_recv (consumes the message).
    let message = match mgr.try_recv(tid)? {
        Some(m) => m,
        None => return Err(KernelError("would block: no message")),
    };
    // Back in recv(): copy the consumed message to the user buffer.
    copy_to_user(good_buffer, &message).map_err(|e| e)
}

fn main() {
    let mut failures = 0;

    // Destination: process mailbox (tid = NONE), the common IPC case.
    let dest = MessageReceiver { pid: 7, tid: ThreadIdentifier::NONE };
    let recv_tid = ThreadIdentifier(42); // a thread of process 7 calling recv()
    const MARKER: u8 = 0xAB;

    // ---- Control: happy path (good buffer) delivers the message correctly. ----
    {
        let mut mgr = Manager::new();
        mgr.post_message(Message { destination: dest, payload0: MARKER }).unwrap();
        assert_eq!(mgr.mailbox.len(), 1);
        assert_eq!(mgr.number_buffered_messages, 1);

        let r = recv(&mut mgr, recv_tid, /*good_buffer=*/ true);
        println!("[control] recv(good buffer) -> {:?}", r);
        println!(
            "[control] after recv: queue_len={}, counter={}",
            mgr.mailbox.len(),
            mgr.number_buffered_messages
        );
        if r.is_ok() && mgr.mailbox.len() == 0 && mgr.number_buffered_messages == 0 {
            println!("[control] OK: message delivered exactly once.\n");
        } else {
            println!("[control] UNEXPECTED harness behavior.\n");
            failures += 1;
        }
    }

    // ---- Bug: bad buffer on the error path loses the message permanently. ----
    {
        let mut mgr = Manager::new();
        // Step 1 (real API): a producer posts a message to process 7's mailbox.
        mgr.post_message(Message { destination: dest, payload0: MARKER }).unwrap();
        println!(
            "[bug] posted 1 message: queue_len={}, counter={}",
            mgr.mailbox.len(),
            mgr.number_buffered_messages
        );

        // Step 2 (real API): process 7 calls Recv with a bad `msg` pointer.
        let r = recv(&mut mgr, recv_tid, /*good_buffer=*/ false);
        println!("[bug] recv(bad buffer) -> {:?}", r);
        println!(
            "[bug] after failed recv: queue_len={}, counter={}",
            mgr.mailbox.len(),
            mgr.number_buffered_messages
        );

        // Step 3: the receiver retries with a VALID buffer. If recv were all-or-nothing,
        // the message would still be here and delivered now.
        let retry = recv(&mut mgr, recv_tid, /*good_buffer=*/ true);
        println!("[bug] retry recv(good buffer) -> {:?}", retry);

        let message_lost = r.is_err() && mgr.mailbox.len() == 0 && retry.is_err();
        if message_lost {
            println!(
                "\n>>> BUG REPRODUCED: the IPC message (marker=0x{:02X}) was CONSUMED and then \
                 DROPPED on the copy_to_user error path.",
                MARKER
            );
            println!(
                ">>> The mailbox is now empty and the retry with a valid buffer receives NOTHING \
                 -- the message is permanently lost."
            );
            println!(
                ">>> Correct (all-or-nothing) behavior: on copy failure the message stays queued \
                 so the retry delivers marker=0x{:02X}.",
                MARKER
            );
        } else {
            println!("\n>>> NOT reproduced: message survived the error path.");
            failures += 1;
        }
    }

    // ---- Secondary: post_message mutate-then-count divergence (accounting only). ----
    // Demonstrates the ordering: message is enqueued BEFORE the count is updated, so a failure
    // of note_message_posted would leave the queue and counter diverged. (The real trigger --
    // usize overflow -- is unreachable; shown here only to document the ordering.)
    {
        let mut mgr = Manager::new();
        mgr.mailbox.send(Message { destination: dest, payload0: 1 }); // queue mutated first
        // note_message_posted() would run next; if it failed, queue=1 but counter=0.
        let queue_before_count = mgr.mailbox.len();
        let count_before = mgr.number_buffered_messages;
        println!(
            "\n[post_message ordering] queue mutated to {} while counter still {} (count happens \
             after) -- documents mutate-then-count.",
            queue_before_count, count_before
        );
    }

    if failures == 0 {
        println!("\nRESULT: CR-6 reproduced (recv consume-then-copy loses a message).");
        std::process::exit(0);
    } else {
        println!("\nRESULT: {} check(s) did not behave as expected.", failures);
        std::process::exit(1);
    }
}
