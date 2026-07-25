// Bug 2: HA set deletion does NOT notify registered ha-scope actors
//
// Location: crates/hamgrd/src/actors/ha_set.rs
//   - delete_dash_ha_set_table (lines 154-170): sends Del to common bridge only
//   - do_cleanup (lines 621-643): does not send HaSetActorState{up:false} to ha-scope
//
// Compare with update_dash_ha_set_table (lines 127-152) which DOES notify ha-scope actors:
//   let msg = HaSetActorState::new_actor_msg(true, &self.id, dash_ha_set).unwrap();
//   let peer_actors = ActorRegistration::get_registered_actors(incoming, RegistrationType::HaSetState);
//   for actor_sp in peer_actors {
//       outgoing.send(actor_sp, msg.clone());
//   }
//
// Impact: When an HA set is deleted, ha-scope actors continue running with stale
// HaSetActorState (up=true). They are orphaned — their parent is gone but they don't know.
//
// This test is added to: crates/hamgrd/src/actors/ha_set.rs (test module)
// Run with:
//   cargo test --package hamgrd test_bug2_ha_set_delete_no_ha_scope_notification -- --nocapture
//
// Expected output: Step 20 times out waiting for HaSetStateUpdate notification that was never sent.
// The #[should_panic(expected = "Timed out")] confirms the bug by catching the timeout panic.

#[tokio::test]
#[should_panic(expected = "Timed out waiting for request")]
async fn test_bug2_ha_set_delete_no_ha_scope_notification() {
    // Setup: create ha-set actor with registered ha-scope actor
    // 1. Send config, register vDPUs, register ha-scope, send vDPU states
    // 2. Verify initial HaSetActorState{up:true} sent to ha-scope (Step 9)
    // 3. Send Del to delete ha-set
    // 4. Verify all cleanup messages (Steps 14-19)
    // 5. Expect HaSetActorState{up:false} to ha-scope (Step 20) — TIMES OUT
    //
    // The timeout at Step 20 proves do_cleanup() does not notify ha-scope actors.
    // See full test code in crates/hamgrd/src/actors/ha_set.rs
}
