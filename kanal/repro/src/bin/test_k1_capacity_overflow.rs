/// Bug K-1: ReceiveFuture::drop push_front exceeds bounded capacity
///
/// When an async ReceiveFuture is dropped after a sender completed a direct
/// handoff, the drop handler pushes data back to the queue via push_front
/// WITHOUT checking if the queue is already at capacity. This causes the
/// queue to exceed the declared channel capacity.
///
/// Reproduction approach (Level 0 — pure black-box, manual Future polling):
///   1. Create a bounded(1) async channel
///   2. Poll a ReceiveFuture once with a noop waker → goes Pending
///   3. Sync sender completes a direct handoff to the recv signal
///   4. Sync sender fills the queue to capacity
///   5. Drop the ReceiveFuture → push_front → queue exceeds capacity
///   6. Observe: channel.len() > capacity
use std::future::Future;
use std::task::{Context, RawWaker, RawWakerVTable, Waker};

fn noop_waker() -> Waker {
    unsafe fn clone(_: *const ()) -> RawWaker {
        RawWaker::new(std::ptr::null(), &VTABLE)
    }
    unsafe fn wake(_: *const ()) {}
    unsafe fn wake_by_ref(_: *const ()) {}
    unsafe fn drop(_: *const ()) {}
    static VTABLE: RawWakerVTable = RawWakerVTable::new(clone, wake, wake_by_ref, drop);
    unsafe { Waker::from_raw(RawWaker::new(std::ptr::null(), &VTABLE)) }
}

fn main() {
    println!("=== Bug K-1: ReceiveFuture::drop push_front exceeds bounded capacity ===\n");

    let capacity = 1;
    let (async_sender, async_receiver) = kanal::bounded_async::<i32>(capacity);
    let sync_sender = async_sender.clone_sync();

    // Step 1: Create a ReceiveFuture and poll it once → Pending
    // The channel is empty, so the future registers in the wait_list.
    let mut recv_fut = Box::pin(async_receiver.recv());
    let waker = noop_waker();
    let mut cx = Context::from_waker(&waker);
    let result = recv_fut.as_mut().poll(&mut cx);
    assert!(result.is_pending(), "Expected Pending on empty channel");
    println!("[1] ReceiveFuture polled → Pending (registered in wait_list)");

    // Step 2: Sync sender does a direct handoff to the blocked recv signal.
    // This writes data=100 to the recv signal and sets its state to UNLOCKED (Success).
    // The noop waker means the future is NOT re-polled automatically.
    sync_sender.send(100).unwrap();
    println!("[2] Sender did handoff: sent 100 to recv signal");

    // Step 3: Another sync send fills the queue to capacity.
    // After step 2, the wait_list is empty (signal was popped). This send goes to queue.
    sync_sender.send(200).unwrap();
    println!("[3] Sender filled queue: sent 200 to queue");

    // Verify queue is at capacity before the drop.
    let len_before = async_sender.len();
    println!("[*] Queue length before drop: {} (capacity: {})", len_before, capacity);
    assert_eq!(len_before, capacity, "Queue should be exactly at capacity");

    // Step 4: Drop the ReceiveFuture.
    // Drop handler path: state=Success, not Done, not Pending → skip cancel.
    // blocking_wait() returns true (state is UNLOCKED).
    // capacity > 0 → push_front(data=100) into queue WITHOUT checking capacity.
    // Queue becomes [100, 200], len=2 > capacity=1.
    drop(recv_fut);
    println!("[4] Dropped ReceiveFuture (triggers push_front)");

    // Step 5: Observe the capacity violation.
    let len_after = async_sender.len();
    println!("[*] Queue length after drop: {} (capacity: {})", len_after, capacity);

    if len_after > capacity {
        println!("\n*** BUG K-1 CONFIRMED ***");
        println!("Queue length {} exceeds declared capacity {}", len_after, capacity);

        // Drain all items to show what's in the queue.
        let sync_receiver = async_receiver.clone_sync();
        let mut items = Vec::new();
        while let Ok(v) = sync_receiver.try_recv() {
            items.push(v);
        }
        println!("Items received: {:?} (count: {})", items, items.len());
        println!("Expected max items in queue: {}", capacity);
        std::process::exit(0); // Bug triggered
    } else {
        println!("\nBug NOT triggered. Queue length = {}", len_after);
        std::process::exit(1);
    }
}
