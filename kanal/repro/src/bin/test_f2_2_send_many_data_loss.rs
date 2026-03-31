/// Bug F2-2: SendManyFuture error path silently drops data
///
/// When the inner SendFuture returns an error (channel closed) but there are
/// remaining elements in the VecDeque, the error (containing the in-flight
/// element) is silently dropped. The loop continues and returns an error with
/// a DIFFERENT element, losing the original one.
///
/// Reproduction approach (Level 0 — pure black-box, manual Future polling):
///   1. Create a bounded(1) async channel with elements [1, 2, 3]
///   2. Poll send_many once: element 1 goes to queue, element 2 to signal
///   3. Drop the receiver → element 2's signal is terminated
///   4. Poll send_many again: inner future returns Err(2), but elements=[3]
///      is not empty → Err(2) is DROPPED → element 2 lost
///   5. Loop continues, sees recv_count=0, returns Err(3)
///   6. Observe: error contains 3 (not 2), element 2 is lost
use std::collections::VecDeque;
use std::future::Future;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

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
    println!("=== Bug F2-2: SendManyFuture error path silently drops data ===\n");

    let (async_sender, async_receiver) = kanal::bounded_async::<i32>(1);

    // Prepare elements to send.
    let mut elements = VecDeque::from(vec![1, 2, 3]);
    println!("[*] Initial elements: {:?}", elements);

    // Step 1: Create SendManyFuture and poll once.
    // First poll:
    //   - No waiting receivers
    //   - Element 1 pushed to queue (cap=1, queue empty)
    //   - Element 2 popped from elements, put into signal, pushed to wait_list
    //   - Inner SendFuture polled → Pending
    //   - Returns Pending
    let mut send_many_fut = Box::pin(async_sender.send_many(&mut elements));
    let waker = noop_waker();
    let mut cx = Context::from_waker(&waker);
    let result = send_many_fut.as_mut().poll(&mut cx);
    assert!(result.is_pending(), "Expected Pending, got {:?}", result);
    println!("[1] send_many polled → Pending");
    println!("    Elements 1 → queue, 2 → signal (in wait_list)");

    // Verify queue has element 1.
    let queue_len = async_sender.len();
    println!("[*] Queue length: {} (element 1 in queue)", queue_len);

    // Step 2: Drop the receiver. This terminates all signals in the wait_list.
    // Element 2's signal is terminated → FutureState::Failure.
    drop(async_receiver);
    println!("[2] Dropped receiver (terminates element 2's signal)");

    // Step 3: Poll send_many again.
    // Expected path:
    //   - in_wait_queue = true
    //   - Poll inner future → Failure → Err(SendError(2))
    //   - elements = [3], NOT empty → error is DROPPED → element 2 LOST
    //   - in_wait_queue = false
    //   - Loop: elements not empty, acquire lock, recv_count=0
    //   - Return Err(SendError(3))
    let result = send_many_fut.as_mut().poll(&mut cx);
    println!("[3] send_many polled again");

    match result {
        Poll::Ready(Err(kanal::SendError(returned_value))) => {
            println!("    Returned error with element: {}", returned_value);
            println!("    Remaining elements in VecDeque: {:?}", elements);

            if returned_value == 3 {
                println!("\n*** BUG F2-2 CONFIRMED ***");
                println!("Element 2 was silently lost!");
                println!("  - Element 1: in channel queue (sent successfully)");
                println!("  - Element 2: LOST (error Err(SendError(2)) was dropped internally)");
                println!("  - Element 3: returned in error to caller");
                println!("  Expected: Err(SendError(2)) with element 3 still in VecDeque");
                println!("  Actual:   Err(SendError(3)) with element 2 gone");
                std::process::exit(0); // Bug triggered
            } else if returned_value == 2 {
                println!("\nBug NOT triggered — error correctly returned element 2.");
                std::process::exit(1);
            } else {
                println!("\nUnexpected element in error: {}", returned_value);
                std::process::exit(1);
            }
        }
        Poll::Ready(Ok(())) => {
            println!("    send_many returned Ok — unexpected");
            std::process::exit(1);
        }
        Poll::Pending => {
            println!("    send_many returned Pending — unexpected");
            std::process::exit(1);
        }
    }
}
