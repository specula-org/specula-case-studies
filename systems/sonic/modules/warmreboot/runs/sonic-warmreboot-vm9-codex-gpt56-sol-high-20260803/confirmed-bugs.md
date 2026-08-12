# Confirmation Report — warmreboot

## Final Result

Reproduced bugs: 4 = 4 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 4 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | MASKED | no |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |

## Entry 1: Backend Restart Loses Accepted-Reboot Ownership

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/sonic-sysmgr/rebootbackend/rebootbe.h:48

## Description

A restarted `rebootbackend` initializes its ownership state to `IDLE` without reconciling the independently active host reboot. Consequently, gNOI receives an inactive `RebootStatus` and may receive success for another reboot even though the host rejects it as already ongoing.

## Trigger scenario

1. Submit a valid WARM reboot through `Reboot_Request_Channel`.
2. The host accepts it and retains `active=true`.
3. Restart only `rebootbackend`; the separate host service remains active.
4. Query `RebootStatus`; the restarted backend reports `active=false`.
5. Submit another reboot; the backend returns `SWSS_RC_SUCCESS`, while the host rejects it with `Previous reboot is ongoing`.

This matches counterexample states 2–5 in `spec/output/MC_hunt_scenario1_bfs.out`.

## Developer intent

PR [#22576](https://github.com/sonic-net/sonic-buildimage/pull/22576) explicitly added blocking and tests for second in-process reboot requests. PR [#22634](https://github.com/sonic-net/sonic-buildimage/pull/22634) states that host-side status is needed for accurate state reflection, but startup performs no reconciliation and host status is queried only when volatile local state already identifies HALT.

Upstream issue, commit-history, and recently updated closed/merged PR searches found no report or fix for this same restart-recovery mechanism.

## Reproduction result

Test: [test_bugMC-1_backend_restart.cpp](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-1_backend_restart.cpp)

Escalation: Level 0. The test uses normal Redis request/response channels, performs a backend stop/restart, and reaches host-active state through the first request. No state injection, failpoint, or source-logic modification was used.

Command executed from the worktree:

```bash
SPECULA_DATABASE_CONFIG="$repro_tmp/database_config.json" GCOV_PREFIX="$repro_tmp/gcov" GCOV_PREFIX_STRIP=20 timeout 30 src/sonic-sysmgr/tests/tests --gtest_filter=MC1BackendRestartLosesAcceptedOwnership.Level0PublicNotificationChannels
```

Actual output:

```text
Note: Google Test filter = MC1BackendRestartLosesAcceptedOwnership.Level0PublicNotificationChannels
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from MC1BackendRestartLosesAcceptedOwnership
[ RUN      ] MC1BackendRestartLosesAcceptedOwnership.Level0PublicNotificationChannels
FIRST_REBOOT_RESPONSE=SWSS_RC_SUCCESS HOST_ACTIVE=true
AFTER_RESTART_STATUS_ACTIVE=false HOST_ACTIVE=true HOST_STATUS_CALLS=0
SECOND_REBOOT_RESPONSE=SWSS_RC_SUCCESS HOST_REJECTED=1 HOST_ACTIVE=true
[       OK ] MC1BackendRestartLosesAcceptedOwnership.Level0PublicNotificationChannels (211 ms)
[----------] 1 test from MC1BackendRestartLosesAcceptedOwnership (211 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (211 ms total)
[  PASSED  ] 1 test.
```

The correct behavior is `active=true` after restart and a non-success/`IN_USE` result for the second request.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**.
2. Level 2/3 reachability sequence: **not applicable**.
3. Real consumer observing the wrong outcome: `src/sonic-gnmi/gnmi_server/gnoi_system.go:174-179` maps the backend success to an OK gNOI reboot RPC; `gnoi_system.go:255-266` returns the stale status.
4. Permanence/masking: the restarted backend has no reconciliation mechanism. The status mismatch lasts while the host operation remains pending, and the already-returned false success is permanent. The host guard prevents a duplicate platform command but does not repair or mask either gNOI-visible wrong outcome.

## Recommendation

Persist accepted operation identity and status, then reconcile it with host `RebootStatus` during backend startup before serving requests. Do not acknowledge a new reboot until the host-side acceptance or rejection is known, and return `IN_USE` while recovered ownership remains active.

---

## Entry 2: Late Warm Component Is Omitted from Finalization Barrier

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: files/image_config/warmboot-finalizer/finalize-warmboot.sh:25
- **Severity**: High
- **Reproduction test**: [test_bugMC-2_late_registration.sh](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-2_late_registration.sh)
- **Investigation**: [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-2/investigation.md)

## Description

The finalizer discovers `/etc/sonic/*_reconcile` files once, derives static service/component lists, and never revisits registration. A component registered afterward is omitted from every worker barrier, allowing global warm-restart finalization while that component remains restoring; the real service-management consumer then takes its cold-stop path.

## Trigger scenario

1. Warm reboot begins and the finalizer snapshots reconciliation files.
2. Concurrent administration runs `spm install --enable <package>`, which normally creates `/etc/sonic/<service>_reconcile`.
3. The new component remains in `restoring`.
4. Static finalizer workers complete without querying it.
5. `finalize_global` disables the system warm-restart flag.
6. `files/scripts/service_mgmt.sh:8-16,61-82` reads the false flag and invokes ordinary `stop` instead of warm `kill`.

## Developer intent

[PR #7286](https://github.com/sonic-net/sonic-buildimage/pull/7286) introduced reconcile-file discovery specifically to support extension packages. [PR #25072](https://github.com/sonic-net/sonic-buildimage/pull/25072) later added multi-ASIC barriers while retaining the one-time discovery. [Issue #6383](https://github.com/sonic-net/sonic-buildimage/issues/6383) and [PR #6454](https://github.com/sonic-net/sonic-buildimage/pull/6454) concern disabled components, not late registration.

Open/closed issue searches, merged/closed PR searches, and recent upstream history found no prior report or fix for this exact static-snapshot mechanism, so novelty is `NEW`.

## Reproduction result

Command:

```text
timeout 2m /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-2_late_registration.sh
```

Required checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**. This host lacks the native `sonic-db-cli`, `config`, and `spm` runtime.
2. Level 2 injected a reachable precondition through this real API sequence:

```text
sudo spm install --enable <package>
  -> PackageManager.install()
  -> PackageManager.install_from_source()
  -> ServiceCreator.create()
  -> ServiceCreator.generate_service_reconciliation_file()
  -> /etc/sonic/<service>_reconcile
```

This also instantiates counterexample State 13, where the required set changes after namespace finalization while the component remains unrestored.

3. Real consumer observing the wrong outcome: `files/scripts/service_mgmt.sh:8-16,61-82`. It executed `stop`; the positive control executed `kill`.
4. The bad state is **permanent for the current reboot epoch**. There is no rescan, resend, loopback, or automatic re-enable mechanism; no downstream mask fired.

Actual output:

```text
LEVEL0: FAIL native SONiC runtime unavailable; missing=sonic-db-cli config spm
LEVEL1: FAIL timing assistance alone cannot run absent SONiC public APIs
LEVEL2: injected reachable late registration after startup snapshot: late_reconcile=latecomp
--- finalizer output ---
Mon Aug 3 15:32:58 CDT 2026 - Wait for database to become ready...
Mon Aug 3 15:32:58 CDT 2026 - Database is ready...
Mon Aug 3 15:32:58 CDT 2026 - Checking if fast-reboot is enabled...
Mon Aug 3 15:32:58 CDT 2026 - Fast-reboot is disabled...
Mon Aug 3 15:32:58 CDT 2026 - Restoring counters folder after warmboot...
Mon Aug 3 15:32:58 CDT 2026 - Waiting for components: '' to reconcile ...
Mon Aug 3 15:32:58 CDT 2026 - Waiting for components: '' to reconcile ...
Mon Aug 3 15:32:59 CDT 2026 - Waiting for components to reconcile:
Mon Aug 3 15:32:59 CDT 2026 - Waiting for components to reconcile:
Mon Aug 3 15:32:59 CDT 2026 - Finalizing warmboot...
Mon Aug 3 15:32:59 CDT 2026 - Save in-memory database after warm/fast reboot ...
--- observed state ---
LATE_REGISTRATION=latecomp
LATE_COMPONENT_STATE=restoring
GLOBAL_WARM_FLAG=false
SERVICE_ACTION=stop
REAL_CONSUMER_BAD_OUTCOME=SERVICE_ACTION=stop
SERVICE_ACTION=kill
REAL_CONSUMER_EXPECTED_CONTROL=SERVICE_ACTION=kill
COUNTEREXAMPLE_MATCH=late required component remains restoring when global finalization disables warm restart
BUG_TRIGGERED: finalizer omitted latecomp and a real consumer selected cold stop instead of warm kill
```

## Recommendation

Coordinate package registration and finalization using a shared lock or versioned registration generation. Freeze registration during finalization, or repeatedly rebuild the barrier until the registration generation remains stable and every component in that stable generation has reconciled before disabling namespace or global warm-restart flags.

---

## Entry 3: Configuration Update Can Cross the Consumer Freeze Boundary

- **Finding ID**: MC-3
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/sonic-utilities/scripts/fast-reboot:1155

## Description

The shutdown path acknowledges and freezes `orchagent` before configuration producers are stopped. A normal configuration update can therefore enter CONFIG_DB after the freeze while ASIC state remains unchanged.

The crossing is real, but the tested consequence is transient: SWSS restart replays the durable configuration and `PortsOrch` applies it to SAI. This downstream reconciliation masks lasting harm.

## Trigger scenario

1. Set `Ethernet0` administratively down through `config interface shutdown`.
2. Enable SWSS warm restart.
3. Run `orchagent_restart_check` and receive `RESTARTCHECK succeeded`.
4. After that acknowledgement, run `config interface startup Ethernet0`.
5. Observe CONFIG_DB become `up` while ASIC state remains `false`.
6. Restart SWSS and observe ASIC state reconcile to `true`.

This was Level 0: public APIs and normal service operations only. No state injection, timing modification, or source patch was used.

## Developer intent

The restart-check code says it freezes `orchagent` to permit deterministic restoration. The main loop explicitly stops processing new database data after the readiness check, while the readiness criterion only examines tasks pending at that instant.

Upstream history contains related but distinct precedents: [PR #3342](https://github.com/sonic-net/sonic-utilities/pull/3342) moved database backup after producer shutdown, while [PR #4711](https://github.com/sonic-net/sonic-utilities/pull/4711) guards `config reload` during boot finalization. Searches of open/closed issues and recently merged/closed PRs found no prior report of this exact producer/orchagent-freeze mechanism.

Full evidence is recorded in [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-3/investigation.md).

## Reproduction result

Executed [test_bugMC-3_freeze_boundary.py](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-3_freeze_boundary.py):

```text
timeout 20m sudo -n /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-3_freeze_boundary.py
```

Captured output:

```text
Container Name: elastic_dewdney
LEVEL0_BASELINE port=Ethernet0 config=down asic=false
LEVEL0_FREEZE RESTARTCHECK succeeded
PRE_RESTART_UPDATE config=up app=down asic=false
POST_RESTART_RECONCILIATION asic=true
MASK_CONFIRMED queued post-freeze update was applied after SWSS restart
.
1 passed, 1 warning in 77.53s (0:01:17)
DVS_IMAGE=docker-sonic-vs:latest
PYTEST_COMMAND=/usr/bin/python3 -m pytest -s -q test_bugMC3_vf5ukncy.py --imgname=docker-sonic-vs:latest
```

Checklist:

1. Level 0 alone triggered the boundary crossing and transient discrepancy: **yes**.
2. Level 2/3 injection or patch: **not used**.
3. Real consumer: `PortsOrch`, `src/sonic-swss/orchagent/portsorch.cpp:2300`, applies `SAI_PORT_ATTR_ADMIN_STATE`. It was delayed, not permanently wrong.
4. Bad state permanence: **transient**. SWSS startup replay/reconciliation changed ASIC state from `false` to `true`, proving the mask fired.

## Recommendation

Fence configuration-producing APIs before acknowledging consumer freeze, then drain producer-to-consumer propagation using an explicit generation/barrier. Retain restart reconciliation as recovery, but do not rely on it as the sole ordering guarantee. Add create/update/delete tests around this boundary and make force-mode bypasses emit explicit diagnostics.

---

## Entry 4: Failed Snapshot Copy Leaves a Restorable Artifact

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/sonic-utilities/scripts/fast-reboot:501

## Description

After destructive Redis pruning, `backup_database` copies `dump.rdb` directly to the final warm-restore path without atomic publication or checking `docker cp` success. An interrupted copy leaves a non-empty partial artifact that the restore path accepts, causing Redis startup failure.

## Trigger scenario

A normal `fast-reboot` reaches `backup_database`, prunes Redis, and invokes `docker cp`. If the Docker archive transport disconnects mid-copy, the command fails but leaves `dump.rdb`; reboot continues because the script is already under `set +e`. On boot, `docker_image_ctl.j2:107` accepts the file by existence, and the Redis supervisor’s non-empty check also accepts it.

This matches counterexample state 7, `MCLeavePartialSnapshot(asic0)`, where `copyComplete = FALSE`, `snapshotValidity = "valid"`, and `snapshotFailure = 1`.

## Developer intent

Commit `ae20defd2` moved backup after swss/syncd shutdown specifically to prevent restart-invalid Redis state, indicating the snapshot is intended to be safe for restart.

Recently merged [sonic-buildimage PR #28541](https://github.com/sonic-net/sonic-buildimage/pull/28541) confirms invalid RDB files cause Redis and database.service failure, but fixes a different zero-byte restore-side race. Its new `-s` guard still accepts MC-4’s non-empty partial file.

Open, closed, and recently merged issue/PR searches across sonic-utilities and sonic-buildimage found no report for interrupted backup-side publication at this site. [Issue #6811](https://github.com/sonic-net/sonic-buildimage/issues/6811) concerns a missing database path, not a partial copy.

## Reproduction result

Test: `repro/test_bugMC-4_interrupted_docker_cp.py`  
Escalation: Level 0 control, then Level 1 transport-timing fault. Level 2 and Level 3 were unnecessary.

Command:

```text
timeout 2m /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-4_interrupted_docker_cp.py
```

Actual output:

```text
PREFLIGHT source_sha=b17c48270c15fc6d5c81a23d97e2946cd7059dcd
PREFLIGHT source guards: direct docker-cp publication; restore -f; Redis -s
REAL_API_SEQUENCE fast-reboot -> backup_database -> docker cp archive GET -> reboot -> database preStartAction -> redis-server
PREFLIGHT generated_valid_rdb_bytes=3145972
LEVEL0 docker_cp_rc=0 artifact_exists=True artifact_bytes=3145972
LEVEL0 requests=HEAD /_ping HTTP/1.1 | GET /v1.52/containers/database/archive?path=%2Fvar%2Flib%2Fredis%2Fdump.rdb HTTP/1.1
LEVEL0 endpoint_failure=None
LEVEL0 redis_check_rc=0 rdb_ok=True
LEVEL1 docker_cp_rc=1 artifact_exists=True artifact_bytes=1576704
LEVEL1 requests=HEAD /_ping HTTP/1.1 | GET /v1.52/containers/database/archive?path=%2Fvar%2Flib%2Fredis%2Fdump.rdb HTTP/1.1
LEVEL1 endpoint_failure=None
LEVEL1 docker_cp_output='unexpected EOF'
LEVEL1 restore_exists_gate=True redis_nonempty_guard=True
LEVEL1 redis_check_rc=1 redis_check_tail=[additional info] Reading type 0 (string) | [info] 7 keys read | [info] 0 expires | [info] 0 already expired
CONSUMER redis_server_rc=1
CONSUMER evidence=1443581:M 03 Aug 2026 15:29:44.192 # Short read or OOM loading DB. Unrecoverable error, aborting now. | 1443581:M 03 Aug 2026 15:29:44.192 # Internal error in RDB reading offset 0, function at rdb.c:2420 -> Unexpected EOF reading RDB file | --- RDB ERROR DETECTED --- | [offset 1573038] Unexpected EOF reading RDB file
LEVEL2 not attempted: Level 1 already triggered live harm
LEVEL3 not attempted: Level 1 already triggered live harm
BUG_TRIGGERED=yes
```

The decisive lines are `docker_cp_rc=1 artifact_exists=True`, both restore guards evaluating true, and `redis_server_rc=1` with `Unexpected EOF`.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 1 used the real public `docker cp` client and only interrupted its legitimate archive response.
2. Level 2/3 reachability justification: **not applicable**.
3. Real consumer/caller: `/usr/bin/redis-server`, invoked at `dockers/docker-database/supervisord.conf.j2:49`; `files/build_templates/docker_image_ctl.j2:291-294` observes the missing PONG and cannot complete database startup.
4. Permanent or masked? **Permanent until external cleanup or cold recovery.** Redis has `autorestart=false`; the artifact is moved aside only after PONG, which never occurs. No downstream synchronization, retry, fallback, or guard resolves it.

## Recommendation

Copy to an epoch-specific temporary path, validate the RDB and completion metadata, then atomically rename it to `dump.rdb`. Check copy failure before reboot proceeds, and require integrity/epoch validation during restoration rather than `-f` or `-s`.

---

## Entry 5: Transient D-Bus Failure Is Classified as Definitive

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-5/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: src/sonic-sysmgr/rebootbackend/interfaces.cpp:35; src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:169

## Description

A caught D-Bus transport exception and an authoritative host rejection both become `DBUS_FAIL`. The reboot worker consequently records transient uncertainty as definitive `STATUS_FAILURE`, permanently blocking subsequent warm-reboot attempts unless an operator switches to cold reboot.

## Trigger scenario

1. Submit a valid WARM reboot through `Reboot_Request_Channel`.
2. D-Bus transport fails during `issue_reboot`.
3. `HostServiceDbus::Reboot` returns `DBUS_FAIL`.
4. The worker records non-retriable `STATUS_FAILURE`.
5. `HandleRebootFinish` joins the worker but retains the classification.
6. A status request exposes `STATUS_FAILURE`.
7. A second valid WARM request is rejected with `SWSS_RC_FAILED_PRECONDITION` without another D-Bus call.

## Developer intent

The protocol explicitly defines `RETRIABLE_FAILURE`, while comments state only definitive warm failures should prevent retry. Existing tests assert generic `DBUS_FAIL` becomes `FAILURE`, but never distinguish transport loss from host rejection.

The upstream search covered open/closed issues and open/closed/merged PRs. [PR #20786](https://github.com/sonic-net/sonic-buildimage/pull/20786) introduced the behavior, while [PR #22634](https://github.com/sonic-net/sonic-buildimage/pull/22634) later added reconciliation only for HALT. [Issue #22545](https://github.com/sonic-net/sonic-buildimage/issues/22545) is a different missing-message `KeyError`, not transient-failure classification. No exact prior report was found.

## Reproduction result

Test: [test_bugMC-5_transient_dbus_definitive.cpp](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-5_transient_dbus_definitive.cpp)

Executed with a fresh Redis instance:

```bash
timeout 30s /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/test_bugMC-5_transient_dbus_definitive \
  /users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/repro/bugMC-5_database_config.json
```

Actual output:

```text
first_request_status=SWSS_RC_SUCCESS
after_transport_loss.active=false
after_transport_loss.class=STATUS_FAILURE
after_transport_loss.message=HostServiceDbus::Reboot: failed to call reboot host service
retry_request_status=SWSS_RC_FAILED_PRECONDITION
retry_request_message=RebootThread: last WARM reboot failed with non-retriable failure
later_status_class=STATUS_FAILURE
dbus_reboot_calls=1
BUG_REPRODUCED: transient D-Bus loss became permanent FAILURE and blocked the next normal warm reboot
```

Escalation reached: Level 2. Level 0 confirmed the real system bus can produce `org.freedesktop.DBus.Error.ServiceUnknown`, but the SONiC host service and production D-Bus library were unavailable. Level 1 timing assistance was inapplicable. Level 2 injected exactly the reachable `DBUS_FAIL` emitted by `interfaces.cpp:35-40`; no production logic was patched.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Admissible Level-2 sequence: counterexample State 2 `<MCAcceptRequest>` → State 3 `<MCLoseDbus>`, where `failureCause = "transport"` and `failureClass = "definitive"`.
3. Real consumers: `RebootBE::HandleStatusRequest` (`rebootbe.cpp:244`) exposes the wrong definitive status; `RebootBE::HandleRebootRequest` (`rebootbe.cpp:200`) receives and returns the failed-precondition rejection from `RebootThread::check_start_preconditions` (`reboot_thread.cpp:280`).
4. The bad state is persistent and not automatically masked. A later status query still returned `STATUS_FAILURE`; join, idle transition, resend, and status paths do not reconcile it. Only a separately requested cold reboot can overwrite it.

Full evidence: [investigation.md](/users/Pial/Specula/runs/sonic-warmreboot-vm9-codex-gpt56-sol-high-20260803/warmreboot/.specula-output/confirmation/MC-5/investigation.md)

## Recommendation

Split transport uncertainty from authoritative rejection. Map caught D-Bus transport errors to a retriable/unknown result, then reconcile using an idempotency key and host reboot status before resending. Add an integration test proving a lost D-Bus response neither causes duplicate reboot execution nor permanently blocks a safe warm retry.

---
