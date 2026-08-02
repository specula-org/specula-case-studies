#!/usr/bin/env bash
set -euo pipefail

worktree="/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-7/worktree"
specula_output="/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output"
swss_repo="/users/Pial/dependencies/sonic-swss-common"
clang_lib_dir="$specula_output/harness/.deps/root/usr/lib/x86_64-linux-gnu"

emit_test_patch() {
    cat <<'PATCH'
diff --git a/crates/hamgrd/src/actors/ha_scope/mod.rs b/crates/hamgrd/src/actors/ha_scope/mod.rs
--- a/crates/hamgrd/src/actors/ha_scope/mod.rs
+++ b/crates/hamgrd/src/actors/ha_scope/mod.rs
@@ -15,9 +15,9 @@ use tracing::{error, info, instrument};
 use base::HaScopeBase;
 use dpu::DpuHaScopeActor;
 use npu::NpuHaScopeActor;
 
 const MAX_RETRIES: u32 = 3;
-const RETRY_INTERVAL: u32 = 30; // seconds
+const RETRY_INTERVAL: u32 = 1; // Level-1 timing assistance; production is 30 seconds
 const BULK_SYNC_TIMEOUT: u32 = 150; // seconds
 const INLINE_SYNC_PKT_DROP_ALERT_THRESHOLD: u32 = 30; // packets
 
@@ -1654,6 +1654,59 @@ mod test {
                 "Switchover state should be 'in_progress' after approval"
             );
 
+            if std::env::var_os("SPECULA_REPRO_MC7").is_some() {
+                let switchover_id = npu_ha_scope_state.switchover_id.clone().unwrap();
+
+                // A real peer in a non-Active state emits Rst for each Syn. After
+                // the first rejection, that reconnecting peer enters Connected and
+                // emits its normal primary-election VoteRequest. The final vote
+                // response must not erase the in-flight switchover retry budget.
+                #[rustfmt::skip]
+                let commands = [
+                    send! { key: SwitchoverRequest::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "switchover_id": &switchover_id, "flag": "Rst" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    recv! { key: SwitchoverRequest::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id, "switchover_id": &switchover_id, "flag": "Syn" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+
+                    send! { key: VoteRequest::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "term": "0", "state": HaState::Connecting.as_str_name(), "desired_state": DesiredHaState::Unspecified.as_str_name() }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    recv! { key: VoteReply::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id, "response": "BecomeStandby" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+
+                    send! { key: SwitchoverRequest::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "switchover_id": &switchover_id, "flag": "Rst" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    recv! { key: SwitchoverRequest::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id, "switchover_id": &switchover_id, "flag": "Syn" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    send! { key: SwitchoverRequest::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "switchover_id": &switchover_id, "flag": "Rst" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    recv! { key: SwitchoverRequest::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id, "switchover_id": &switchover_id, "flag": "Syn" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    send! { key: SwitchoverRequest::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "switchover_id": &switchover_id, "flag": "Rst" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                    recv! { key: SwitchoverRequest::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id, "switchover_id": &switchover_id, "flag": "Syn" }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
+                ];
+
+                test::run_commands(&runtime, runtime.sp(HaScopeActor::name(), &scope_id), &commands).await;
+
+                let db = crate::db_for_table::<NpuDashHaScopeState>().await.unwrap();
+                let table = Table::new(db, NpuDashHaScopeState::table_name()).unwrap();
+                let observed: NpuDashHaScopeState = swss_serde::from_table(&table, &scope_id_in_state).unwrap();
+                assert_eq!(
+                    observed.local_ha_state.as_deref(),
+                    Some(HaState::SwitchingToActive.as_str_name())
+                );
+                assert_eq!(observed.switchover_state.as_deref(), Some("in_progress"));
+
+                println!("MC-7 TRIGGERED level=1");
+                println!("operation_id={switchover_id}");
+                println!("valid_switchover_rejections=4 retry_limit=3");
+                println!("observed_extra_wire_retry=SwitchoverRequest(Syn)#4");
+                println!(
+                    "observed_local_ha_state={}",
+                    observed.local_ha_state.as_deref().unwrap_or("<missing>")
+                );
+                println!(
+                    "observed_switchover_state={}",
+                    observed.switchover_state.as_deref().unwrap_or("<missing>")
+                );
+                println!("expected_after_rejection_4=Standby/failed and no Syn#4");
+                println!("real_consumers=peer HA scope plus NpuDashHaScopeState/upstream service");
+
+                handle.abort();
+                return;
+            }
+
             // ============================================================
             // Phase 4: Peer accepts and transitions to SwitchingToStandby.
             // When peer state is SwitchingToStandby, local transitions
diff --git a/crates/hamgrd/src/actors/test.rs b/crates/hamgrd/src/actors/test.rs
--- a/crates/hamgrd/src/actors/test.rs
+++ b/crates/hamgrd/src/actors/test.rs
@@ -16,8 +16,12 @@ use swbus_edge::{
 use swss_common::{FieldValues, Table};
 use tokio::time::sleep;
 async fn timeout<T, Fut: Future<Output = T>>(fut: Fut) -> Result<T, tokio::time::error::Elapsed> {
-    const TIMEOUT: Duration = Duration::from_millis(5000);
-    tokio::time::timeout(TIMEOUT, fut).await
+    let timeout = if std::env::var_os("SPECULA_REPRO_MC7").is_some() {
+        Duration::from_secs(40)
+    } else {
+        Duration::from_millis(5000)
+    };
+    tokio::time::timeout(timeout, fut).await
 }
 
 #[macro_export]
PATCH
}

patch_applied=0
cleanup() {
    if [[ "$patch_applied" -eq 1 ]]; then
        emit_test_patch | git apply --reverse --whitespace=nowarn
    fi
}
trap cleanup EXIT

cd "$worktree"

if rg -q 'SPECULA_REPRO_MC7' crates/hamgrd/src/actors/ha_scope/mod.rs crates/hamgrd/src/actors/test.rs; then
    echo "refusing to run: MC-7 test patch is already present" >&2
    exit 2
fi

if [[ ! -d crates/sonic-dash-api-proto/sonic-dash-api/proto ]]; then
    timeout 2m git submodule update --init --depth 1 crates/sonic-dash-api-proto/sonic-dash-api
fi

test -f "$swss_repo/common/.libs/libswsscommon.so"
test -f "$clang_lib_dir/libclang-14.so.1"

emit_test_patch | git apply --check --whitespace=nowarn
emit_test_patch | git apply --whitespace=nowarn
patch_applied=1

echo "MC-7 reproduction source_sha=$(git rev-parse HEAD)"
echo "Level 1: full ActorRuntime and normal SWBUS operations; retry delay only is 30s -> 1s"

env \
    SPECULA_REPRO_MC7=1 \
    CARGO_TERM_COLOR=never \
    SWSS_COMMON_REPO="$swss_repo" \
    LIBCLANG_PATH="$clang_lib_dir" \
    LD_LIBRARY_PATH="$swss_repo/common/.libs:$clang_lib_dir:${LD_LIBRARY_PATH:-}" \
    timeout 8m cargo test -p hamgrd \
        actors::ha_scope::test::npu_driven::ha_scope_npu_planned_switchover \
        -- --exact --nocapture --test-threads=1
