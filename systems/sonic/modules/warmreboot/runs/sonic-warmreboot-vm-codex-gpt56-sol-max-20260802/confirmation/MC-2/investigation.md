# MC-2 investigation

## Code audit

### Relevant implementation

- Public entry point: `src/sonic-utilities/scripts/fast-reboot`. The script selects warm-reboot behavior from its invoked name and parses `-f` as `FORCE=yes` (`fast-reboot:236`, `fast-reboot:265-266`). The help text defines `-f` as ignoring an orchagent RESTARTCHECK failure.
- `pause_orchagent()` runs the production command `docker exec -i swss$DEV /usr/bin/orchagent_restart_check -w 2000 -r 5` (`fast-reboot:1130-1137`). On a nonzero result, its forced branch logs that the failure is ignored (`fast-reboot:1138-1142`) and falls through to the unconditional success log (`fast-reboot:1146`), so the function returns zero.
- `execute_in_namespaces()` has a separate forced-failure handler that removes a failed ASIC from `ASIC_LIST` and disables fast/warm restart for it (`fast-reboot:101-152`, especially `:137-145`). Because `pause_orchagent()` converts the failed restart check to a zero function result, that outer handler does not see this failure.
- Multi-ASIC warm reboot sets `FORCE=yes` before calling the pause function (`fast-reboot:1149-1155`), so the same path is automatic there rather than requiring the command-line `-f` option.
- After the pause stage, the script marks the point after which cleanup/rollback is no longer possible and changes to non-fatal error handling (`fast-reboot:1163-1165`). It then stops services, including `swss`, according to the reboot order (`fast-reboot:1199-1217`) and calls `execute_in_namespaces all backup_database` (`fast-reboot:1219`).
- `backup_database()` calls `centralize_database APPL_DB` for warm reboot and copies Redis's RDB into `/host/warmboot` (`fast-reboot:452-506`, especially `:498-501`). `src/sonic-utilities/scripts/centralize_database:30-42` migrates the requested DBs and issues `redis-cli SAVE`; it does not check producer queues or orchagent readiness.

The cited line numbers in the finding correspond to an earlier source layout. In the checked-out `sonic-utilities` revision `1462eff8982c69dcc262ffeac408ae7797689642`, the suppression site is `scripts/fast-reboot:1140` and the snapshot call is `scripts/fast-reboot:1219`.

### Call chain and reachability

Normal/forced entry-point chain:

`warm-reboot -f` -> `parseOptions()` -> `reboot_pre_check()` -> `pause_orchagent()` -> ignored nonzero `orchagent_restart_check` -> irreversible section -> `stop_service swss` -> `backup_database()` -> `centralize_database()` -> Redis `SAVE`.

The precondition is reachable through existing public database producer operations. The upstream DVS test `src/sonic-swss/tests/test_warm_reboot.py:901-967` enables warm restart, writes an unresolved route through `swsscommon.ProducerStateTable` at `:925-932`, and observes the real `/usr/bin/orchagent_restart_check` fail at `:934-936` because next hop `20.0.0.1` is unresolved. That test deletes the unfinished route at `:943-944` before proceeding, whereas the finding's forced path retains it.

`src/sonic-swss-common/common/producerstatetable.cpp:72-76,129-168` implements a producer write as the persistent table-key set plus the state hash. `src/sonic-swss/orchagent/orch.cpp:428-474,686-704` enumerates those hashes back into consumer work during warm restore.

The named TLC output `spec/output/MC_hunt_scenario2_after_stop_order_bfs.out` reports `Invariant CheckpointAfterQuiescence is violated`. Its relevant sequence is:

1. State 5, `MCProducerEnqueue(<<asic_0, orch_producer>>)`: queue depth is one and work is in flight.
2. State 6, `MCPauseOrchagentIgnoreFailure(asic_0)`: the freeze result is `ignored-failure`; queue depth and in-flight work remain.
3. States 7-9: the flow acknowledges the freeze phase, crosses the irreversible phase, and stops the writer while the work remains.
4. State 10: the snapshot is saved with the same outstanding work and `snapshotValid = FALSE`.

This is the same action order as the implementation path above.

### Consumer and safeguards

- The restart-check utility exists specifically to obtain READY/freeze before stopping orchagent; its source says the check prevents stopping in a transient state so deterministic state can be restored (`src/sonic-swss/orchagent/orchagent_restart_check.cpp:31-43,108-160`).
- During warm restore, `OrchDaemon::warmRestoreAndSyncUp()` refills each consumer and runs restore processing, then calls `warmRestoreValidation()` (`src/sonic-swss/orchagent/orchdaemon.cpp:1265-1325`). Validation rejects any remaining pending task (`orchdaemon.cpp:1356-1375`). `OrchDaemon::init()` propagates that failure (`orchdaemon.cpp:915-921`), and the real process caller exits when init fails (`src/sonic-swss/orchagent/main.cpp:1021-1025`).
- Orchagent is configured with `autorestart=false` in `dockers/docker-orchagent/supervisord.conf.common.j2:73-87` and is listed as a critical process in `dockers/docker-orchagent/critical_processes.j2:7`. The process-exit listener terminates the supervisor on such a critical-process exit when the feature's auto-restart policy is enabled (`src/sonic-supervisord-utilities-rs/src/proc_exit_listener.rs:386-406`). `swss.sh wait` monitors the `swss` container through `docker-wait-any-rs` (`files/scripts/swss.sh:516-518`), whose service-container path exits when `swss` stops even during warm restart (`src/sonic-ctrmgrd-rs/crates/docker-wait-any-rs/src/lib.rs:62-94`; asserted by `tests/docker_wait_any_test.rs:62-100`). The generated `swss.service` has no `Restart=` directive (`files/build_templates/per_namespace/swss.service.j2:20-28`), so this clean service exit is not automatically restarted.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:237-258` waits for components for up to five minutes and later clears/finalizes warm-restart state (`:165-169`, `:284-302`), but it does not restart the exited orchagent. A later operator-initiated cold start can recover service; no examined automatic loopback/resend mechanism consumes and repairs this failed warm-restore outcome.

## Developer-knowledge search

- Commit `17519cf5` / [sonic-utilities PR #399](https://github.com/sonic-net/sonic-utilities/pull/399) introduced the explicit `-f` behavior for ignoring an orchagent pause failure.
- Commit `0f3b5291` / [sonic-utilities PR #4199](https://github.com/sonic-net/sonic-utilities/pull/4199) added the multi-ASIC flow and forces this mode before pausing orchagents. Its documented validation used successful restart checks, so it does not exercise the failure path.
- Commit `6eedf8a7` / [sonic-utilities PR #4297](https://github.com/sonic-net/sonic-utilities/pull/4297), merged 2026-03-09, is titled “Added error-handling for faulty ASIC/s after orchagent freeze.” Its commit message says a failing ASIC should be removed from the operational list and have warm/fast restart disabled when `FORCE` is true. The patch implements that policy only in `execute_in_namespaces()`; it does not change the inner `pause_orchagent()` success return described above.
- The [SONiC multi-ASIC warm-reboot HLD PR #2153](https://github.com/sonic-net/SONiC/pull/2153) specifies that an ASIC with a restart-check failure is removed from the list and cold-booted on startup. This records the intended recovery policy for precisely this participant failure.
- Existing test coverage includes the reachable unresolved-route/restart-check failure in `src/sonic-swss/tests/test_warm_reboot.py:901-967`, but the test removes the unfinished route before freezing and restarting. The shutdown-order unit test (`src/sonic-utilities/tests/sonic_package_manager/test_service_creator.py:122`) verifies that `swss` is stopped before `syncd`; neither test covers a forced continuation after restart-check failure.

Tracker searches covered open and closed issues and recently merged PRs in `sonic-net/sonic-utilities`, `sonic-net/sonic-buildimage`, and `sonic-net/sonic-swss`, using `RESTARTCHECK failed`, `pause_orchagent`, `orchagent pausing failure`, `pending tasks warm restart`, `faulty ASIC`, and recent warm-reboot PR filters. Results such as buildimage issues #19316, #12029, #12361, #7919, and #6569 concern causes of pending restart checks, not this suppression/checkpoint mechanism. No later PR correcting the inner successful return was found through 2026-08-01.

## Known status / precedent

`Novelty: KNOWN (cite: https://github.com/sonic-net/sonic-utilities/pull/4297; fix-status: unfixed)`

PR #4297 is an upstream filed fix for the same restart-check participant-failure path and the same `execute_in_namespaces`/forced-mode site. Its stated behavior is to exclude the faulty ASIC and cold-boot it. At the checked-out descendant revision, the inner pause function still masks the status before that added handler observes it, so the reported fix is not effective for the actual restart-check failure.
