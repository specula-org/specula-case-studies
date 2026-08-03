# MC-3 investigation

## Scope and provenance

- Source tree: `sonic-buildimage` commit `d5a2f4d1df9fdf71e48777905cd3f032b3d78a94`.
- Relevant submodules: `sonic-swss` `b20a59691baca9ff6e4fbe46a7cd8223a3419117`, `sonic-utilities` `1462eff8982c69dcc262ffeac408ae7797689642`, and `sonic-swss-common` `c544c90acc862dddacdb454a2ad8d5eb1a68e105`.
- Supplied TLC output: `spec/output/MC_hunt_scenario3_fair_bfs.out`. TLC reports `CompleteSameEpochSnapshot` violated. States 5-8 publish and consume `READY` while each producer remains `running` and `quiescent = FALSE`; states 11-16 stop/copy a same-epoch snapshot; state 18 consumes ASIC0 with `snapshotValid[asic0] = FALSE`. The trace has an empty queue and empty DB/hardware views, so it establishes an incomplete producer fence but does not itself exhibit a wrong data value.

## Executable code path

1. `src/sonic-swss/orchagent/orchdaemon.cpp:1185-1188` calls `warmRestartCheck()` after a restart request.
2. `warmRestartCheck()` chooses `READY` and synchronously publishes it through `restartCheckReply()` at `orchdaemon.cpp:1384-1414`.
3. Only after that call returns does the main loop drain the optional ring (`orchdaemon.cpp:1190-1199`), disable FDB aging (`:1204-1205`), disable bridge-port FDB learning (`:1207-1214`), flush the sairedis pipeline (`:1217-1218`), and enter the heartbeat freeze (`:1220-1221`).
4. The unbuffered notification implementation constructs `PUBLISH` and waits for Redis's integer reply at `src/sonic-swss-common/common/notificationproducer.cpp:15-43`. A subscribed caller can therefore consume the notification before orchagent begins any of the post-return work.
5. The real caller, `src/sonic-swss/orchagent/orchagent_restart_check.cpp:108-140`, consumes `RESTARTCHECKREPLY`; on `READY` it prints `RESTARTCHECK succeeded` and returns success. Its own contract at `:31-37` says `READY` is returned and orchagent freezes when everything is okay.
6. `src/sonic-utilities/scripts/fast-reboot:1130-1146` treats that helper exit as a successfully paused orchagent. The shutdown loop follows at `:1206-1217`, and the database backup follows at `:1219`. On warm/fast boot, `files/scripts/swss.sh:533-543` uses `docker kill swss`, so unfinished post-reply work can be terminated rather than awaited.
7. A warm/fast boot later loads the retained RDB in `files/build_templates/docker_image_ctl.j2:102-115`.

The ring path is independently relevant: `Consumer::execute()` queues captured work into the ring in `src/sonic-swss/orchagent/orch.cpp:576-625`, whereas the readiness scan checks consumer retry/task maps rather than queued lambdas. The ring worker executes those lambdas in `orchdaemon.cpp:149-172`, and the explicit drain is after the reply.

## Downstream behavior and recovery path

`OrchDaemon::warmRestoreAndSyncUp()` calls every orch's `bake()`, runs three task passes, validates the result, applies the syncd view, invokes warm-boot completion handlers, and sets `orchagent` to `reconciled` (`src/sonic-swss/orchagent/orchdaemon.cpp:1265-1340`). `Orch::bake()` repopulates work from retained Redis tables (`src/sonic-swss/orchagent/orch.cpp:686-704`), and `FdbOrch::bake()` also repopulates dynamic FDB state from `STATE_DB` (`src/sonic-swss/orchagent/fdborch.cpp:107-120`). This is a concrete recovery mechanism to test after forcing the coordinator-visible early reply.

## Developer intent and history

- The original feature commit `9fda944cd` (upstream PR https://github.com/sonic-net/sonic-swss/pull/562) describes the pre-stop check as ensuring orchagent is not transient so restore is deterministic; the helper comment likewise couples `READY` with freezing.
- FDB-learning and FDB-aging fencing were added later by commits `f13aaed9f` (PR 628) and `94fbcd96c` (PR 634), after the reply site.
- Ring-buffer support was added by commit `900f38c80` (upstream PR https://github.com/sonic-net/sonic-swss/pull/3242), retaining the same reply-before-drain order.
- The existing FDB warm-restart test waits two seconds after helper success before stopping SWSS (`src/sonic-swss/tests/test_fdb.py:229-237`), so it verifies eventual fence state but does not test the response boundary.
- Current upstream `sonic-swss` master (`4f3dda156`) retains the same ordering; current `sonic-utilities` master (`b17c482`) retains the same coordinator path.

## Prior-report search

GitHub issue and merged/closed-PR searches were run in `sonic-swss`, `sonic-utilities`, and `sonic-buildimage` for `RESTARTCHECK`, `READY`, `freeze`, warm-restart readiness, and ring-buffer ordering.

- https://github.com/sonic-net/sonic-swss/issues/827 reports the opposite timeout symptom: orchagent reaches/follows `READY`, but the requester misses the response and later retries cannot be served.
- https://github.com/sonic-net/sonic-swss/pull/4725 changes timeout and `NOT_READY` diagnostics; it does not move or supersede the reply.
- https://github.com/sonic-net/sonic-buildimage/issues/12257 concerns another producer not propagating CONFIG_DB data into APP_DB before the check, not orchagent's post-reply fence.
- https://github.com/sonic-net/sonic-buildimage/issues/25224 concerns unfreeze behavior rather than this publication boundary.

No issue or merged/closed PR found in those searches reports or fixes this exact `RESTARTCHECKREPLY`-before-ring/FDB/flush/freeze mechanism.

## Reproduction hypothesis

Run the official DVS image and the real `/usr/bin/orchagent_restart_check`. First use ordinary two-endpoint dataplane traffic as a negative control after an unassisted READY: the completed fence should prevent dynamic FDB learning. Then, as timing assistance only, ptrace the real orchagent and hold it at the syscall exit that receives Redis's response to its real `PUBLISH RESTARTCHECKREPLY`; at that boundary the helper can consume `READY`, while the tracee has not executed its next user-space instruction. Send identical traffic, inspect ASIC_DB and STATE_DB, take the same SIGKILL action used by the coordinator path, reload a Redis checkpoint, restart SWSS in warm mode, and observe whether reconciliation or configured FDB aging repairs the retained state.
