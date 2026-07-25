// Bug 1: HaSetActorState::new_actor_msg ignores `up` parameter
//
// Location: crates/hamgrd/src/ha_actor_messages.rs:144-145
// The function signature accepts `up: bool` but the body hardcodes `up: true`:
//   pub fn new_actor_msg(up: bool, my_id: &str, ha_set: DashHaSetTable) -> Result<ActorMessage> {
//       ActorMessage::new(Self::msg_key(my_id), &Self { up: true, ha_set })
//   }
//
// Impact: Deletion notifications (up=false) are silently converted to up=true.
// Even if deletion code were to call new_actor_msg(false, ...), child actors
// would never learn the HA set was removed.
//
// This test is added to: crates/hamgrd/src/ha_actor_messages.rs (test module)
// Run with:
//   cargo test --package hamgrd test_bug1_ha_set_actor_state_new_actor_msg_ignores_up_param -- --nocapture

#[cfg(test)]
mod test {
    use crate::ha_actor_messages::HaSetActorState;
    use crate::db_structs::DashHaSetTable;

    #[test]
    fn test_bug1_ha_set_actor_state_new_actor_msg_ignores_up_param() {
        let ha_set = DashHaSetTable {
            version: "1".to_string(),
            vip_v4: "3.2.0.0".to_string(),
            vip_v6: None,
            owner: None,
            scope: Some("dpu".to_string()),
            local_npu_ip: "10.0.0.0".to_string(),
            local_ip: "18.0.0.0".to_string(),
            peer_ip: "18.0.1.0".to_string(),
            cp_data_channel_port: None,
            dp_channel_dst_port: None,
            dp_channel_src_port_min: None,
            dp_channel_src_port_max: None,
            dp_channel_probe_interval_ms: None,
            dp_channel_probe_fail_threshold: None,
        };

        // Call new_actor_msg with up=false — simulating a deletion notification
        let msg = HaSetActorState::new_actor_msg(false, "test-ha-set", ha_set).unwrap();
        let state: HaSetActorState = msg.deserialize_data().unwrap();

        // BUG: The function hardcodes up=true, ignoring the parameter.
        // This assertion demonstrates the bug — it FAILS because state.up is true.
        assert!(
            state.up == false,
            "BUG CONFIRMED: HaSetActorState::new_actor_msg(up=false, ...) produced up={}, expected false. \
             The `up` parameter is ignored; `true` is hardcoded at ha_actor_messages.rs:145.",
            state.up
        );
    }
}
