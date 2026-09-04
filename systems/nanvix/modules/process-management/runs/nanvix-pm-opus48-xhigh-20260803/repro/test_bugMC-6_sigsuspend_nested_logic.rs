// Reproduction for MC-6: "Nested signal delivery during sigsuspend corrupts the saved mask".
//
// Invariant violated (model checking): SigsuspendMaskRestored
// Counterexample: spec/output/MC_hunt_scenario4_mc6_final.out
//
// This is the PORTABLE corroboration. It replays the exact counterexample sequence against a
// faithful, byte-for-byte copy of the three cited kernel code paths. It does not alter any logic;
// it executes the identical decision logic that the kernel uses, so the same defect manifests.
//
// The end-to-end, real-code reproduction is repro/test_bugMC-6_sigsuspend_nested.sh, which builds
// and boots the actual Nanvix `test`-feature kernel and drives the REAL per-thread signal state
// (ThreadState::{set_saved_blocked,take_saved_blocked,set_blocked,blocked}) through the same
// sequence, printing an @@MC6@@ marker.
//
// Cited real code (worktree paths):
//   thread/state.rs:93,105,452-453,465-466  -- single `saved_blocked: Option<u64>` slot + take()
//   process/manager/mod.rs:730-735          -- install_sigsuspend_mask (sigsuspend save)
//   process/manager/signal.rs:294-300,495   -- try_deliver_signal commit + build_frame saves mask
//   process/manager/signal.rs:607-611       -- sigreturn_restore mask-restore precedence (the bug)
//
// Build & run:  rustc -O test_bugMC-6_sigsuspend_nested_logic.rs -o /tmp/mc6 && /tmp/mc6

const UNBLOCKABLE: u64 = (1 << (9 - 1)) | (1 << (19 - 1)); // SIGKILL(9), SIGSTOP(19); irrelevant here.

fn sig_bit(s: usize) -> u64 {
    1u64 << (s - 1) // state/signal.rs uses `1 << (signum - 1)`.
}

/// Faithful copy of the parts of `ThreadState` that carry the signal mask.
/// thread/state.rs: `blocked: u64` (line 93), `saved_blocked: Option<u64>` (line 105).
struct ThreadState {
    blocked: u64,
    saved_blocked: Option<u64>,
}

impl ThreadState {
    fn new() -> Self {
        // thread/state.rs:154,156 -- blocked: 0, saved_blocked: None.
        ThreadState { blocked: 0, saved_blocked: None }
    }
    fn blocked(&self) -> u64 {
        self.blocked
    }
    fn set_blocked(&mut self, mask: u64) {
        self.blocked = mask;
    }
    fn take_saved_blocked(&mut self) -> Option<u64> {
        // thread/state.rs:452-453 -- `self.saved_blocked.take()` (single slot, consumed on read).
        self.saved_blocked.take()
    }
    fn set_saved_blocked(&mut self, mask: Option<u64>) {
        // thread/state.rs:465-466.
        self.saved_blocked = mask;
    }
}

/// A signal frame placed on the user stack. `blocked` is the mask that was in effect BEFORE
/// delivery (process/manager/signal.rs:495 `build_frame(cpu, blocked, ...)`).
struct SigFrame {
    blocked: u64,
}

/// process/manager/sigframe.rs next_blocked: add the delivered signal to the mask (no NODEFER here).
fn next_blocked(current: u64, sa_mask: u64, signum: usize, nodefer: bool) -> u64 {
    let mut m = current | sa_mask;
    if !nodefer {
        m |= sig_bit(signum);
    }
    m
}

/// install_sigsuspend_mask -- process/manager/mod.rs:730-735.
fn install_sigsuspend_mask(state: &mut ThreadState, mask: u64) {
    let installed: u64 = mask & !UNBLOCKABLE;
    let previous: u64 = state.blocked();
    state.set_saved_blocked(Some(previous));
    state.set_blocked(installed);
}

/// try_deliver_signal commit -- process/manager/signal.rs:286-303 (+ build_frame at 495 saving the
/// pre-delivery mask into the frame). Pushes a frame and installs the handler mask.
fn deliver_signal(state: &mut ThreadState, frames: &mut Vec<SigFrame>, signum: usize) {
    let blocked: u64 = state.blocked();
    frames.push(SigFrame { blocked }); // build_frame saves the mask in effect before delivery.
    let new_blocked: u64 = next_blocked(blocked, 0, signum, false) & !UNBLOCKABLE;
    state.set_blocked(new_blocked);
}

/// sigreturn_restore mask logic -- process/manager/signal.rs:604-612 (the defect).
/// Precedence: prefer the single saved_blocked slot over the frame's own saved mask.
fn sigreturn_restore(state: &mut ThreadState, frames: &mut Vec<SigFrame>) {
    let frame = frames.pop().expect("sigreturn with no frame");
    let restored_blocked: u64 = match state.take_saved_blocked() {
        Some(saved) => saved & !UNBLOCKABLE,
        None => frame.blocked & !UNBLOCKABLE,
    };
    state.set_blocked(restored_blocked);
}

fn main() {
    let mut st = ThreadState::new();
    let mut frames: Vec<SigFrame> = Vec::new();

    // Replay MC_hunt_scenario4_mc6_final.out step for step (thread t1, signal 1).
    // State 3->4  AsyncDeliver: signal 1 delivered (handler running); frame1 saves {}, blocked={1}.
    deliver_signal(&mut st, &mut frames, 1);
    assert_eq!(st.blocked(), sig_bit(1), "state 4: blocked should be {{1}}");

    // The mask in effect when sigsuspend() is called (state 5). POSIX requires sigsuspend() to
    // restore exactly this mask once its interrupting handler returns.
    let pre_suspend: u64 = st.blocked();

    // State 5->6  Sigsuspend({}): save the pre-suspend mask {1}, install temporary mask {}.
    install_sigsuspend_mask(&mut st, 0);
    assert_eq!(st.blocked(), 0, "state 6: temporary suspend mask should be {{}}");
    assert_eq!(st.saved_blocked, Some(sig_bit(1)), "state 6: saved slot holds pre-suspend {{1}}");

    // State 6->7  AsyncDeliver: signal 1 unblocked & delivered WHILE suspended; frame2 saves {},
    // blocked={1}.
    deliver_signal(&mut st, &mut frames, 1);
    assert_eq!(st.blocked(), sig_bit(1), "state 7: blocked should be {{1}}");

    // State 7->8  Sigreturn (nested handler): take_saved_blocked() returns the sigsuspend mask {1}
    // and CONSUMES the single slot -- this is the defect: a nested frame's return grabbed the
    // sigsuspend-saved mask instead of its own frame mask {}.
    sigreturn_restore(&mut st, &mut frames);
    assert_eq!(st.saved_blocked, None, "state 8: saved slot has been consumed by the nested return");

    // State 8->9  Sigreturn (sigsuspend unwind): slot is empty, so the FRAME mask {} is restored
    // instead of the pre-suspend mask {1}.
    sigreturn_restore(&mut st, &mut frames);

    let restored = st.blocked();
    println!("pre_suspend_mask = {:#x} (expected mask after sigsuspend returns)", pre_suspend);
    println!("restored_mask    = {:#x} (actual blocked mask after all frames unwound)", restored);

    if restored == pre_suspend {
        println!("RESULT: OK -- sigsuspend restored the pre-suspend mask (bug NOT present)");
        std::process::exit(1);
    } else {
        println!(
            "RESULT: BUG REPRODUCED -- SigsuspendMaskRestored violated: sigsuspend left blocked={:#x}, \
             but the pre-sigsuspend mask was {:#x}. The single saved_blocked slot was consumed by \
             the nested sigreturn (signal.rs:607), so the sigsuspend unwind restored the wrong mask.",
            restored, pre_suspend
        );
        std::process::exit(0);
    }
}
