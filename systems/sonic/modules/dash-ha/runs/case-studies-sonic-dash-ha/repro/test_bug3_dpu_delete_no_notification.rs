// Bug 3: DPU deletion does NOT notify registered vDPU actors
//
// Location: crates/hamgrd/src/actors/dpu.rs
//   - do_cleanup (lines 137-140): only deletes reset info, does NOT call update_dpu_state()
//     fn do_cleanup(&mut self, _context: &mut Context, state: &mut State) {
//         let (internal, _incoming, _outgoing) = state.get_all();
//         self.delete_reset_info(internal);
//     }
//   - handle_remote_dpu_message (lines 376-378): just stops without any notification
//     if dpu_kfv.operation == KeyOperation::Del {
//         context.stop();
//         return Ok(());
//     }
//
// Impact: When a DPU is deleted, registered vDPU actors continue running with stale
// DpuActorState (up=true). The vDPU believes the DPU is still alive and healthy.
// This cascades up the actor hierarchy: vDPU → HA set → HA scope all have stale state.
//
// This test is added to: crates/hamgrd/src/actors/dpu.rs (test module)
// Run with:
//   cargo test --package hamgrd test_bug3_dpu_delete_no_vdpu_notification -- --nocapture
//
// Expected output: Step 10 times out waiting for DPUStateUpdate that was never sent.
// The #[should_panic(expected = "Timed out")] confirms the bug by catching the timeout panic.

#[tokio::test]
#[should_panic(expected = "Timed out waiting for request")]
async fn test_bug3_dpu_delete_no_vdpu_notification() {
    // Setup: create DPU actor, register vDPU, bring DPU to up=true (pmon+bfd)
    // 1. Send pmon up state, DPU config, global config
    // 2. Register vDPU for DPU state updates
    // 3. Receive initial DPUStateUpdate (up=false, no bfd yet)
    // 4. Send BFD up state → DPU becomes up=true
    // 5. Receive DPUStateUpdate (up=true)
    // 6. Send Del to delete DPU
    // 7. Expect DPUStateUpdate (up=false) to vDPU (Step 10) — TIMES OUT
    //
    // The timeout at Step 10 proves do_cleanup() does not call update_dpu_state()
    // to notify registered vDPU actors about the DPU being deleted.
    // See full test code in crates/hamgrd/src/actors/dpu.rs
}
