# Confirmation Report — warmreboot

## Final Result

Reproduced bugs: 3 = 1 NEW + 2 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 2
Env-limited findings: 1
False positives: 0
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 7
Dispositions: 7 total = 3 reproduced + 1 env-limited + 2 masked + 0 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | ENV_LIMITED | no |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | MASKED | no |
| 6 | MC-6 | MASKED | no |
| 7 | CR-5 | DROPPED | no |

## Entry 1: Concurrent reboot attempts can overwrite ownership and erase a live epoch

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-utilities/pull/1460; fix-status: unfixed)
- **Location**: src/sonic-utilities/scripts/fast-reboot:973

## Description

Reboot admission scans shared restart flags separately from publishing them, allowing two callers to observe no reboot in progress. After the newer caller publishes, the older caller’s unscoped signal/EXIT cleanup can clear both flags; the newer caller then performs irreversible shutdown using cold-reboot behavior without revalidation.

## Trigger scenario

1. Start two unmodified `fast-reboot` CLI processes.
2. Both read the warm-restart flag as false; caller 2 publishes after caller 1.
3. Send normal `SIGTERM` cancellation to caller 1 at its supported trap point.
4. Caller 1’s TERM/EXIT cleanup writes both global flags false.
5. Caller 2 continues: the unchanged service-management consumer selects cold `stop` instead of warm/fast `kill`, then reaches kexec with both flags false.

## Developer intent

Merged [PR #1460](https://github.com/sonic-net/sonic-utilities/pull/1460) added the existing guard specifically because overlapping reboots can reset the flag and cause components to cold reboot. The service-management code likewise states that warm/fast reboot must not perform normal service stop. The guard remains a non-atomic read-before-write operation, so the simultaneous-admission case is unfixed.

## Reproduction result

Executable test: [test_bugMC-1_concurrent_reboot_cleanup.py](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-1_concurrent_reboot_cleanup.py)

Command:

```text
timeout 5m python3 /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-1_concurrent_reboot_cleanup.py
```

Actual output:

```text
SOURCE sonic-utilities=1462eff8982c69dcc262ffeac408ae7797689642
PRODUCT_SOURCE_MODIFIED=no
CONTROL flags=warm:true,fast:true consumer_action=kill expected=kill
LEVEL0 attempts=10 timing_barriers=no triggered=no
LEVEL0 outcome=race window not observed; escalating to Level 1
LEVEL1 caller_rc owner1=143 owner2=0
LEVEL1 assistance=timing barriers plus SIGTERM at the production trap-supported cancellation point; product logic unchanged
TRACE_BEGIN
owner=2 admission-read warm=false
owner=1 admission-read warm=false
owner=1 publish fast=true
owner=1 publish warm=true
owner=2 publish fast=true
owner=2 publish warm=true
owner=1 cancellation-point=entered
owner=1 kexec=-u -a
owner=1 cleanup warm=false
owner=1 cleanup fast=false
owner=1 kexec=-u -a
owner=2 db-integrity-check=passed
owner=1 cleanup warm=false
owner=2 kexec=-l /host/image-test/boot/vmlinuz-test --initrd=/host/image-test/boot/initrd.img-test --append=console=ttyS0   SONIC_BOOT_TYPE=fast-reboot -a
owner=1 cleanup fast=false
owner=2 post-admission-read warm=false
owner=2 post-admission-read fast=false
owner=2 consumer-action=stop
owner=2 kexec=-e
TRACE_END
OBSERVED shared_flags warm=false fast=false
OBSERVED real_consumer=files/scripts/service_mgmt.sh:61 action=stop expected=kill
OBSERVED newer_reboot_attempted=yes flags_at_reboot=warm=false fast=false
BUG_TRIGGERED: Level 1 older signal/EXIT cleanup erased the newer attempt's flags; the real service consumer selected cold stop and the newer caller continued to reboot without revalidation.
RESULT: PASS
```

Confirmation checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 1**, using public CLI processes, normal SIGTERM cancellation, and timing barriers only.
2. Level 2/3 reachability justification: **not applicable; neither was used**.
3. Real consumer observing the wrong outcome: `files/scripts/service_mgmt.sh:64-81`, which invoked cold `stop` instead of expected `kill`.
4. Permanent or masked: **permanent for the affected reboot epoch and not masked**. Cold stop executes before kexec, the newer caller reaches reboot with both flags false, and no later guard or finalizer reasserts them.

## Recommendation

Atomically acquire a unique reboot attempt token before publishing flags. Cleanup must compare that token before clearing state, and the caller must revalidate ownership immediately before route deletion and service shutdown. Add concurrent admission/cancellation coverage using the reproduced sequence.

---

## Entry 2: Forced orchagent pause failure permits a non-quiescent checkpoint

- **Finding ID**: MC-2
- **Status**: ENV_LIMITED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/debate.md

# MC-2

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-utilities/pull/4297; fix-status: unfixed)
- **Location**: src/sonic-utilities/scripts/fast-reboot:1140

## Description

When `orchagent_restart_check` fails, forced mode suppresses the error and `pause_orchagent()` returns success at [fast-reboot:1140](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/worktree/src/sonic-utilities/scripts/fast-reboot:1140). Consequently, the outer multi-ASIC handler never excludes the failed ASIC. Execution crosses the irreversible boundary, stops `swss`, and saves Redis without proving producer quiescence.

The named TLC counterexample is genuine: it reports `Invariant CheckpointAfterQuiescence is violated` after producer enqueue, ignored pause failure, writer stop, and snapshot save in that order.

Full evidence is recorded in [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/investigation.md).

## Trigger scenario

A reachable sequence already exists in `sonic-swss/tests/test_warm_reboot.py:906-936`:

1. Enable warm restart.
2. Configure Ethernet0 and its connected neighbor.
3. Call `ProducerStateTable(APP_ROUTE_TABLE_NAME).set("3.3.3.0/24", nexthop="20.0.0.1", ifname="Ethernet0")`.
4. Because that next hop is unresolved, the real `orchagent_restart_check` returns failure.
5. Invoke `warm-reboot -f`.
6. Forced mode converts the failure into successful control flow, stops `swss`, and saves Redis.

This corresponds to counterexample State 5, `MCProducerEnqueue(<<asic_0, orch_producer>>)`, followed by State 6, `MCPauseOrchagentIgnoreFailure(asic_0)`.

## Developer intent

[PR #399](https://github.com/sonic-net/sonic-utilities/pull/399) introduced explicit forced continuation. Later, [PR #4297](https://github.com/sonic-net/sonic-utilities/pull/4297) specifically reported and attempted to handle faulty ASICs after orchagent freeze by excluding them and disabling warm restart. The [multi-ASIC warm-reboot HLD](https://github.com/sonic-net/SONiC/pull/2153) likewise requires a restart-check-failed ASIC to cold boot.

PR #4297 remains ineffective for this path because `pause_orchagent()` masks the failure before its outer handler sees it.

## Reproduction result

Executed [test_bugMC-2_forced_nonquiescent_checkpoint.sh](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-2_forced_nonquiescent_checkpoint.sh):

```text
MC-2 reproduction: forced failed freeze before Redis checkpoint
source_sha=d5a2f4d1df9fdf71e48777905cd3f032b3d78a94
sonic_utilities_sha=1462eff8982c69dcc262ffeac408ae7797689642
sonic_swss_sha=b20a59691baca9ff6e4fbe46a7cd8223a3419117
LEVEL0 attempt=public-entrypoint-normal-operations
    -f    : force execution - ignore Orchagent RESTARTCHECK failure
LEVEL0 docker_info_rc=1
Server:
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
LEVEL0 result=BLOCKED reason=no-accessible-docker-daemon-or-SONiC-DVS-instance
LEVEL1 attempt=timing-assistance-at-restart-check-window
LEVEL1 result=BLOCKED reason=a-delay-cannot-supply-the-missing-swss/orchagent/syncd-runtime
ARTIFACT_PREFLIGHT target_dir=/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/worktree/target
ARTIFACT_PREFLIGHT compatible_artifacts=0
ARTIFACT_PREFLIGHT finding_local_prior_build_recipe=none
BOOTSTRAP_ATTEMPT command='make configure PLATFORM=vs' timeout=30s
BOOTSTRAP_ATTEMPT configure_rc=2
+++ Making configure +++
BLDENV=bookworm make -f Makefile.work configure
make[1]: Entering directory '/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/worktree'
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
Makefile.work:109: *** SONiC requires Docker version 17.06.1 or later.  Stop.
make[1]: Leaving directory '/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/worktree'
make: *** [Makefile:125: configure] Error 2
make: Leaving directory '/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/worktree'
LEVEL2 attempt=reachable-state-injection-plus-unmodified-public-entrypoint
LEVEL2 injected_precondition=ROUTE_TABLE:3.3.3.0/24 nexthop=20.0.0.1
LEVEL2 public_entrypoint_rc=0
Sun Aug 2 04:53:38 UTC 2026 Pausing orchagent ...
RESTARTCHECK failed
Sun Aug 2 04:53:38 UTC 2026 Ignoring orchagent pausing failure ...
Sun Aug 2 04:53:38 UTC 2026 Orchagent paused successfully
Sun Aug 2 04:53:38 UTC 2026 Stopping swss ...
Sun Aug 2 04:53:39 UTC 2026 Backing up database ...
Sun Aug 2 04:53:39 UTC 2026 Rebooting with /sbin/reboot to SONiC-OS-current ...
LEVEL2 call_order:
  restart_check=failed
  service_stop=swss
  service_stop=teamd
  service_stop=syncd
  snapshot=save
  snapshot=copy
  service_stop=docker.service
  reboot=called
LEVEL2 restored_route=nexthop=20.0.0.1 ifname=Ethernet0
LEVEL2 result=CHECKPOINT_PATH_OBSERVED live_consumer=UNAVAILABLE
LEVEL3 attempt=timing-only-source-modification-plus-public-entrypoint
LEVEL3 modification='/bin/sleep 0.05 immediately before backup_database; no logic changed'
LEVEL3 injected_precondition=ROUTE_TABLE:3.3.3.0/24 nexthop=20.0.0.1
LEVEL3 public_entrypoint_rc=0
Sun Aug 2 04:53:40 UTC 2026 Pausing orchagent ...
RESTARTCHECK failed
Sun Aug 2 04:53:40 UTC 2026 Ignoring orchagent pausing failure ...
Sun Aug 2 04:53:40 UTC 2026 Orchagent paused successfully
Sun Aug 2 04:53:40 UTC 2026 Stopping swss ...
Sun Aug 2 04:53:40 UTC 2026 Backing up database ...
Sun Aug 2 04:53:40 UTC 2026 Rebooting with /sbin/reboot to SONiC-OS-current ...
LEVEL3 call_order:
  restart_check=failed
  service_stop=swss
  service_stop=teamd
  service_stop=syncd
  snapshot=save
  snapshot=copy
  service_stop=docker.service
  reboot=called
LEVEL3 restored_route=nexthop=20.0.0.1 ifname=Ethernet0
LEVEL3 result=CHECKPOINT_PATH_OBSERVED live_consumer=UNAVAILABLE
EXPECTED forced freeze failure must abort or remove the ASIC before SAVE
OBSERVED failed restart-check -> success return -> swss stop -> SAVE -> reboot
CONSUMER_STATUS argued-only: orchagent/main.cpp:1021-1025 cannot be executed without a SONiC/DVS image and Docker-daemon access
FINAL_ATTEMPT_RESULT=ENVIRONMENT_LIMITED
```

Checklist boundary:

1. Did Level 0 or Level 1 alone trigger the live bug? **no**.
2. Level 2 used the reachable upstream ProducerStateTable sequence above and counterexample State 5. It did not invent an impossible peer response.
3. The real consumer is `src/sonic-swss/orchagent/main.cpp:1021`: pending work makes `warmRestoreValidation()` fail, `init()` returns false, and orchagent exits. This consequence is **argued-only** here because no executable SONiC/DVS image or Docker-daemon access is available.
4. No automatic mask was found. `docker-wait-any-rs` lets `swss.service` exit when its service container stops, and that unit has no `Restart=` policy. Recovery therefore requires an operator action or later cold recovery rather than an automatic replay.

The production consequence is soundly supported, but the unavailable live orchagent/syncd/SAI runtime prevents observing that consumer outcome on this host.

## Recommendation

Preserve the nonzero `pause_orchagent()` result. Before the irreversible boundary:

- Abort forced single-ASIC warm reboot or explicitly select cold recovery.
- Let the multi-ASIC handler remove the failed ASIC and disable its warm-restart state.
- Permit checkpointing only after an independent producer-quiescence fence succeeds.
- Add a DVS regression based on the existing unresolved-route test that leaves the route pending and exercises forced reboot.

---

## Entry 3: READY is published before orchagent completes its freeze fence

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/sonic-swss/orchagent/orchdaemon.cpp:1413

## Description

`warmRestartCheck()` publishes `READY` at line 1413 before the caller drains the ring, disables FDB aging and learning, flushes the sairedis pipeline, and enters the heartbeat freeze at lines 1190–1221. Because the notification uses a synchronous Redis `PUBLISH`, the real requester can consume `READY` before orchagent executes its next instruction.

The supplied TLC trace is a real `CompleteSameEpochSnapshot` violation. The executable reproduction confirms the same ordering and demonstrates lasting harm: an incomplete checkpoint restored two ASIC FDB entries without corresponding STATE_DB records, followed by bidirectional dataplane failures.

## Trigger scenario

The test uses the real `/usr/bin/orchagent_restart_check`, normal VLAN configuration, ordinary endpoint traffic, Redis checkpoint/reload, and the official `docker-sonic-vs` image. Level 1 timing assistance holds orchagent immediately after Redis acknowledges its genuine `RESTARTCHECKREPLY` publication.

The completed-fence control learned no MACs. At the READY boundary, learning remained `HW`, aging remained `60`, and identical traffic learned both endpoint MACs before orchagent could record their notifications. SIGKILL, checkpoint reload, and warm restart then reproduced the coordinator sequence.

## Developer intent

The helper contract says `READY` means orchagent “is frozen and ready for warm restart,” and its real consumer returns success at `orchagent_restart_check.cpp:136-140`. Production `fast-reboot:1137-1146` consequently treats that exit status as a successfully paused orchagent.

This contract originated in [sonic-swss PR #562](https://github.com/sonic-net/sonic-swss/pull/562). Prior-report searches covered upstream open/closed issues and merged/closed PRs. The nearest results—[issue #827](https://github.com/sonic-net/sonic-swss/issues/827), [PR #4725](https://github.com/sonic-net/sonic-swss/pull/4725), [buildimage issue #12257](https://github.com/sonic-net/sonic-buildimage/issues/12257), and [buildimage issue #25224](https://github.com/sonic-net/sonic-buildimage/issues/25224)—concern different timeout, propagation, diagnostic, or unfreeze mechanisms. No prior report or fix for this publication-before-fence mechanism was found.

## Reproduction result

Executed [test_bugMC-3_ready_before_fence.py](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-3_ready_before_fence.py) under an outer 480-second timeout. Exit status: `0`.

```text
IMAGE docker-sonic-vs:latest sha256:e949c893220fd00bb81ac8ce9f4fb871205319baee8c006aa5d853f6ac36c2bc 2026-07-30T15:35:29Z
Container Name: hungry_sanderson
CONFIG fdb_aging_seconds=60
LEVEL0 helper_rc=0 helper_output='RESTARTCHECK succeeded'
LEVEL0 fence bridge_ports=2 modes={"SAI_BRIDGE_PORT_FDB_LEARNING_MODE_DISABLE": 2} aging=["0"]
LEVEL0 traffic ping_rcs=[0, 0] learned_asic=[] learned_state=[]
LEVEL1 boundary=HELD_AFTER_READY_PUBLISH_REPLY helper_rc=0 helper_output='RESTARTCHECK succeeded'
LEVEL1 fence bridge_ports=2 modes={"SAI_BRIDGE_PORT_FDB_LEARNING_MODE_HW": 2} aging=["60"]
LEVEL1 traffic ping_rcs=[0, 0] learned_asic=["6a:0c:88:f0:d9:aa", "ca:18:f1:63:82:9f"] learned_state=[]
CHECKPOINT save=True redis_restart_rc=0 redis_restart_output='redis-server: stopped\nredis-server: started' learned_asic=["6a:0c:88:f0:d9:aa", "ca:18:f1:63:82:9f"] learned_state=[]
RESTORE_INITIAL warm_state=reconciled learned_asic=["6a:0c:88:f0:d9:aa", "ca:18:f1:63:82:9f"] learned_state=[] bridge_ports=2 modes={"SAI_BRIDGE_PORT_FDB_LEARNING_MODE_HW": 2} aging=["60"]
RESTORE_FINAL learned_asic=["6a:0c:88:f0:d9:aa", "ca:18:f1:63:82:9f"] learned_state=[] consistent=false keepalive_attempts=9 keepalive_failures=[[1, 1], [1, 1], [1, 1], [1, 1], [1, 1]]
RESULT READY_PRECEDES_FENCE; PERSISTED_ASIC_STATE_MISMATCH_AND_DATAPLANE_FAILURES_AFTER_AGING_WINDOW
```

Checklist:

1. **Did Level 0 or Level 1 alone trigger it? yes.** Level 1 timing assistance alone triggered it using real interfaces and messages; Level 0 was the negative control.
2. **Level 2/3 reachability:** Not applicable; neither state injection nor a source patch was used.
3. **Real consumer/caller:** `src/sonic-swss/orchagent/orchagent_restart_check.cpp:136-140` consumed `READY` and returned success while the fence was incomplete. `src/sonic-utilities/scripts/fast-reboot:1137-1146` is the production caller relying on that result. The restored dataplane also produced five consecutive bidirectional ping failures.
4. **Permanent or masked:** Permanent for the reproduced active-MAC scenario; no downstream mask was observed. Warm reconciliation declared success, relearn traffic did not repopulate STATE_DB, and the mismatch plus dataplane failures persisted beyond the configured 60-second aging interval and 30-second margin.

## Recommendation

Complete the ring drain, FDB aging/learning fence, and sairedis flush before publishing `READY`. Alternatively, require an epoch-correlated `FROZEN` acknowledgement emitted only after the entire fence is established. Add a regression test that pauses exactly at the reply boundary, introduces normal dataplane traffic, reloads the checkpoint, and verifies ASIC/STATE consistency and forwarding.

---

## Entry 4: VID/RID maps are exposed non-reciprocally during replacement

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-sairedis/pull/1784; fix-status: unfixed)
- **Location**: src/sonic-sairedis/syncd/RedisClient.cpp:669

## Description

`Syncd::updateRedisDatabase` derives a coherent matching, but `RedisClient::setVidAndRidMap` publishes it through separate `DEL` and per-pair `HSET` commands. A crash after deleting `VIDTORID` leaves Redis permanently exposing an empty forward map alongside the complete old reverse map, matching the `IdentityMapBijective` counterexample.

## Trigger scenario

1. Cold-start syncd and apply a normal SAI switch view, creating 1,481 reciprocal mappings.
2. Issue another `INIT_VIEW`/switch-create/`APPLY_VIEW` through the public sairedis interface.
3. During a subsequent APPLY, pause immediately after `DEL VIDTORID` and terminate syncd before `DEL RIDTOVID`.
4. Let the independent Redis process retain the cut, then perform translation and restart using unmodified production classes.

## Developer intent

`Syncd.cpp:5966` contains `TODO check if those 2 maps are consistent`, while `HardReiniter.cpp:138-143` says the related replacement sequence must be atomic. No transaction, generation pointer, or restart validation implements that intent.

Upstream [PR #1784](https://github.com/sonic-net/sonic-sairedis/pull/1784) reports the same partial `setVidAndRidMap()` publication affecting a live flex-counter consumer. It remains open; current master still contains the fragmented implementation. Full evidence is recorded in [investigation.md](</users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-4/investigation.md>).

## Reproduction result

Executed [test_bugMC-4_atomic_publication.sh](</users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-4_atomic_publication.sh>):

```bash
timeout 5m /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-4_atomic_publication.sh
```

Level 0 used only public operations. It observed the transient translator failure, but successful publication later repaired the maps, so that observation alone was treated as masked. Level 1 used debugger timing to stop the unmodified syncd process at the exact command boundary and simulate the stated process failure; Levels 2 and 3 were not used.

Actual output:

```text
ARTIFACT source_root=/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-4/worktree/src/sonic-sairedis isolated_redis=yes
PUBLIC_PATH primary_syncd_pid=3579654
LEVEL0 initial_apply=success switch_vid=oid:0x21000000000000
LEVEL0 final vid_to_rid=1481 rid_to_vid=1481 bijective=yes
LEVEL0 concurrent_translator=threw message=":- translateVidToRid: unable to get RID for VID oid:0x21000000000000"
LEVEL0 downstream_repopulation=masked_transient_cut
ATTACH_READY syncd_pid=3579654 redis_socket=/tmp/mc4-redis-YTSkE6/redis.sock go_file=/tmp/mc4-run-2GkLwD/debugger-armed
LEVEL1 public_apply_status=SAI_STATUS_FAILURE exception=""
LEVEL1 persisted_cut vid_to_rid=0 rid_to_vid=1481 bijective=no
LEVEL1 after_1000ms vid_to_rid=0 rid_to_vid=1481 bijective=no
REAL_CONSUMER VirtualOidTranslator.cpp:361 result=threw message=":- translateVidToRid: unable to get RID for VID oid:0x21000000000000"
REAL_CALLER Syncd.cpp:6257 warm_restart_uses_same_translation=yes
RESTART_CONSUMER syncd_run_returned=yes elapsed_ms=64
REAL_RESTART Syncd.cpp:6041 init_failure_path_returned=yes exit_code=0
LEVEL1 after_restart vid_to_rid=0 rid_to_vid=1481 bijective=no
RESULT permanent_nonreciprocal_state=yes restart_validation_or_repair=no
TEST_PASS MC-4
GDB_ARMED pid=3579654
BREAKPOINT_HIT after_RedisClient.cpp:669 before_line_670=yes
BREAKPOINT VIDTORID_hlen=0
BREAKPOINT RIDTOVID_hlen=1481
[Inferior 1 (process 3579654) killed]
```

The same execution’s restart log confirms the caught initialization failure:

```text
bugMC4_public_flow_driver[3580000]: :- run: Runtime error during syncd init: map::at
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 1 used the public SAI flow and debugger timing only; no Redis state was injected and core source was unchanged.
2. Level 2/3 reachability requirement: **not applicable** — neither was used.
3. Real consumers observing wrong outcomes: `VirtualOidTranslator::translateVidToRid` at `syncd/VirtualOidTranslator.cpp:361` threw; its warm-restart caller is `syncd/Syncd.cpp:6257`. The full hard-reinit path also failed at `syncd/HardReiniter.cpp:100`, called from `syncd/Syncd.cpp:6041`.
4. Permanent or later repaired? **permanent after the crash cut** — the `0/1481` split remained after one second and after restart. No sync, resend, validation, or repair mechanism corrected it. Only a non-crashed successful APPLY repairs the transient Level-0 window.

## Recommendation

Publish both maps in one Redis transaction, or populate generation-scoped hashes, validate reciprocity, and atomically switch one generation pointer. Restart must reject or recover incomplete generations before translation, with crash-cut tests after every publication command.

---

## Entry 5: fpmsyncd publishes RECONCILED before route output is flushed

- **Finding ID**: MC-5
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-5/debate.md

# MC-5 — fpmsyncd publishes RECONCILED before route output is flushed

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/sonic-swss/warmrestart/warmRestartHelper.cpp:256
- **Severity**: High

## Description

The counterexample ordering is real: reconciliation queues buffered APPL_DB route operations, then synchronously publishes `RECONCILED` before [fpmsyncd.cpp:218](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-5/worktree/src/sonic-swss/fpmsyncd/fpmsyncd.cpp:218) flushes the pipeline. However, that unconditional flush immediately resolves the transient state and successfully delivers every route operation, so no permanent wrong state was reproduced.

## Trigger scenario

Enable BGP warm restart, restore old routes, receive legitimate refreshed FPM routes while restoration is active, then let the reconciliation timer expire with fewer than 50,000 pending operations. `WarmStartHelper::reconcile()` generates stale deletion, route update, and route addition operations before setting `RECONCILED`.

## Developer intent

The warm-restart unit test says `RECONCILED` is for external tools after synchronization. The original [routing warm-reboot PR #602](https://github.com/sonic-net/sonic-swss/pull/602) expects route changes to reach AppDB during reconciliation, while [PR #3241](https://github.com/sonic-net/sonic-swss/pull/3241) deliberately introduced buffered fpmsyncd output. Searches covering open/closed issues and recently merged/closed PRs found no report of this exact ordering; the related [issue #4579](https://github.com/sonic-net/sonic-swss/issues/4579) concerns premature reconciliation before BGP convergence, a different mechanism.

Full evidence: [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-5/investigation.md).

## Reproduction result

Test: [test_bugMC-5_reconciled_before_flush.cpp](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-5_reconciled_before_flush.cpp)

Escalation:

- Level 0: unavailable; no `fpmsyncd` binary or accessible SONiC DVS.
- Level 1: unavailable without the full daemon.
- Level 2: conclusive state injection using the exact state 6→7 counterexample transition and a reachable real-API sequence.
- Level 3: unnecessary because Level 2 demonstrated both the ordering and downstream mask without modifying production code.

Run from the supplied worktree:

```text
timeout 2m ../test_bugMC-5_reconciled_before_flush
```

Actual output:

```text
LEVEL0_RESULT=UNAVAILABLE reason=fpmsyncd_binary_and_SONiC_DVS_not_available_to_runner
LEVEL1_RESULT=UNAVAILABLE reason=no_full_daemon_for_timing_only_assistance
LEVEL2_MODE=STATE_INJECTION trace_step=State_6_MCFpmSyncdWarmRestartTimerExpired_to_State_7_MCNextCompletion
LEVEL2_REAL_API_SEQUENCE=enable_warm_restart->checkAndStart->runRestoration->legitimate_route_refresh_and_stale_omission->timer_expiry->reconcile->caller_flush
PRE_FLUSH state=reconciled pipeline_size=3 durable_route_queue=0 stale_route=192.0.2.1 changed_route=192.0.2.2 new_route=<absent>
COUNTEREXAMPLE_STATE_OBSERVED=yes
POST_FLUSH state=reconciled pipeline_size=0 durable_route_queue=3
CONSUMER_RESULT operations=3 delete=seen update=seen add=seen
POST_CONSUME stale_route=<absent> changed_route=198.51.100.2 new_route=198.51.100.3
MASK_FIRED=fpmsyncd_explicit_pipeline_flush
PERMANENT_BAD_STATE=no
TEST_RESULT=PASS
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 used the reachable sequence printed above and instantiates counterexample state 6, `MCFpmSyncdWarmRestartTimerExpired`, followed by state 7, `MCNextCompletion`.
3. The premature state consumer is `warmboot-finalizer` at `files/image_config/warmboot-finalizer/finalize-warmboot.sh:141`; orchagent’s real route consumer is attached at `orchagent/orchdaemon.cpp:371`. The latter ultimately received all three operations.
4. The bad state is **not permanent**. The unconditional `pipeline.flush()` masks it, as proved by `POST_FLUSH`, `CONSUMER_RESULT`, and `PERMANENT_BAD_STATE=no`.

## Recommendation

Make completion ordering explicit: flush and confirm the reconciliation pipeline before calling `setState(RECONCILED)`. Add a regression test asserting that an external STATE_DB observer cannot see `reconciled` while `ROUTE_TABLE_KEY_SET` is still empty, including flush-failure coverage.

---

## Entry 6: Warmboot finalizer clears flags after timeout with components incomplete

- **Finding ID**: MC-6
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-6/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-platform-daemons/pull/666; fix-status: fixed)
- **Location**: files/image_config/warmboot-finalizer/finalize-warmboot.sh:256

## Description

The finalizer genuinely logs a timeout and then clears warm/fast flags while `bgp`/fpmsyncd and orchagent remain incomplete. However, the current pinned implementation masks the known live consequence: running participants cache their warm-restart state, component status remains observable, and xcvrd now uses `syncd.restore_count` rather than the cleared flag.

Investigation evidence is recorded in [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-6/investigation.md).

## Trigger scenario

The Level-2 state is reachable through:

1. `sudo fast-reboot`, which enables both fast and warm system flags.
2. Participants enter `bgp=restored` and `orchagent=initialized`.
3. The finalizer performs all 60 polls without reconciliation.
4. It logs both incomplete components and clears both flags.

This instantiates counterexample States 4–6 (`flags=true`, fpmsyncd restored, orchagent initial, then `MCFinalizeWarmbootWaitTimeout`) before State 7 clears the flags.

## Developer intent

The bounded wait followed by flag removal has existed since the original finalizer PR. Developers also documented that leaving the flag set misclassifies later reloads. The historical live failure was xcvrd reading the cleared flag and prematurely publishing port settings; [PR #666](https://github.com/sonic-net/sonic-platform-daemons/pull/666) reports resulting all-port flaps and fixes them by consulting `syncd.restore_count`.

## Reproduction result

Test: [test_bugMC-6_timeout_flag_mask.py](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro/test_bugMC-6_timeout_flag_mask.py)

Command:

```text
cd /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro
timeout 2m ./test_bugMC-6_timeout_flag_mask.py
```

Actual output:

```text
SOURCE_REPO_COMMIT=d5a2f4d1df9fdf71e48777905cd3f032b3d78a94
XCVRD_SUBMODULE_COMMIT=6acdb85aa4d860d2bf174ddb33e65be148b351c6
FINALIZER_SHA256=a7b566988ee0e1f5f36e9429f60cb4ea90ddafbc4c42f64622740cdae25ff8c7
LEVEL0=UNAVAILABLE (host has no sonic-db-cli/SONiC runtime)
LEVEL1=UNAVAILABLE (timing assistance alone cannot supply the missing runtime)
LEVEL2=EXECUTED (CE states 4-6 via normal finalizer command boundary; sleep only collapsed)
FINALIZER_LOG=Some components didn't finish reconcile: bgp ...
FINALIZER_LOG=Some components didn't finish reconcile: orchagent ...
AFTER_TIMEOUT warm=false fast=false orchagent=initialized fpmsyncd_as_bgp=restored
FINALIZER_EVENTS=STATE_DB:HSET:FAST_RESTART_ENABLE_TABLE|system:enable=false,CONFIG_DB:DEL:WARM_RESTART|teamd,config:warm_restart:disable:system,config:save
SHOW_WARM_RESTART_STATE_BEGIN
name | restore_count | state
bgp | 1 | restored
neighsyncd | 1 | reconciled
orchagent | 1 | initialized
syncd | 1 | reconciled
SHOW_WARM_RESTART_STATE_END
HISTORICAL_FLAG_ONLY_WARM=false
CURRENT_XCVRD_WARM_GUARD=true
CURRENT_XCVRD_NOTIFY_BRANCH_TAKEN=false
MASK=syncd.restore_count remains 1, so current xcvrd suppresses premature media-setting publish
LEVEL3=NOT_REACHED (Level 2 reproduced the transition and proved the downstream mask)
TEST_RESULT=PASS (timeout/clear transition reproduced; claimed live harm is masked in pinned code)
```

Checklist:

1. **Did Level 0 or Level 1 alone trigger it?** no.
2. **Level-2 reachability:** supplied counterexample States 4–6, matching the real `fast-reboot → enable flags → participant state publication → finalizer timeout` sequence.
3. **Real consumer:** historical xcvrd observed the wrong flag and flapped ports. Current `sonic-xcvrd/xcvrd/xcvrd.py:317,337-338` instead observes the restore-count safeguard, so no current wrong outcome was reproduced.
4. **Permanent or masked:** flag clearing is persistent, but its consequence is masked. Running participants cache warm state, `show warm_restart state` retains incomplete states, and xcvrd’s restore-count guard prevents premature publication.

## Recommendation

Retain the xcvrd restore-count safeguard and require future late-start consumers to use durable participant state rather than the system enable flag. The finalizer should also publish an explicit timeout/failure status for operators instead of relying only on logs.

---

## Entry 7: Nondeterministic identity reconciliation can choose unstable object bindings

- **Finding ID**: CR-5
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: [sonic-buildimage#28650](https://github.com/sonic-net/sonic-buildimage/issues/28650); fix-status: unfixed)
- **Location**: src/sonic-sairedis/syncd/ComparisonLogic.cpp:67

## Description

`ComparisonLogic` seeds `rand()` from wall-clock time, while `BestCandidateFinder.cpp:1554-1606,2024-2035` randomly resolves tied identity candidates. Upstream issue #28650 reports this exact mechanism: identical virtual routers can be mismatched during warm-reboot APPLY_VIEW, causing duplicate VLAN-RIF creation, `SAI_STATUS_ITEM_ALREADY_EXISTS`, syncd shutdown-wait, and orchagent exit.

The checkout remains unfixed. Open PR [sonic-sairedis#2007](https://github.com/sonic-net/sonic-sairedis/pull/2007) adds virtual-router matching based on attached VLAN interfaces.

## Trigger scenario

Configure two VRFs, create two VLAN interfaces for each, bind each VLAN interface to its intended VRF, save the configuration, and warm-reboot. Identical virtual-router attributes and dependency counts can reach random candidate selection through the normal `NOTIFY(APPLY_VIEW)` path.

## Developer intent

Source comments acknowledge that tie selection is random, can cause unnecessary remove/recreate operations, and should potentially be deterministic. PR #2007 confirms the intended identity rule: match virtual routers using their attached VLAN interfaces.

The complete audit is recorded in [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/CR-5/investigation.md).

## Reproduction result

Phase 2 was not run and no `repro/test_bugCR-5_*` was created. The required skill’s code-review × already-reported pre-filter mandates dropping the duplicate before reproduction.

Real tracker-search output:

```text
total_count=1 incomplete=False
2007 | open | PR | [warm-reboot] Match virtual routers by VLAN interfaces during APPLY_VIEW
```

The linked upstream issue and fix PR are both open, so the fix status is unfixed.

## Recommendation

Track and merge PR #2007 rather than filing a duplicate. Additionally, validate RID/VID reciprocity unconditionally and use deterministic, unique identity discriminators for every object type that can reach the random fallback.

---
