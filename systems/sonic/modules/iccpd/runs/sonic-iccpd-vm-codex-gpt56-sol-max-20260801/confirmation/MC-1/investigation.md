# MC-1 investigation

## Provenance and source classification

- Repository: `sonic-net/sonic-buildimage`, exact worktree HEAD `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9`.
- Source classification: MC. The supplied TLC output `spec/output/MC_hunt_scenario1_bfs_validated.out` contains an actual violation of `MCWarmRecoveryTerminates` after 1,361,429 generated states (356,965 distinct); this is not a no-violation/code-review promotion.
- Counterexample sequence: state 6 executes `MCheartbeat_check(n1)` and records a detected disconnect with `cleanupDone = FALSE`; state 11 executes `MCsystem_finalize_Crash(n1)` before peer cleanup, losing the volatile disconnect program counter; states 12-15 restart and reach `Running`, but `cleanupDone` remains false, `recoveryPending` remains true, and the trace stutters. This makes the crash point an admissible counterexample-trace step for Level 1 timing assistance.

## Code-path evidence

- `src/iccpd/src/scheduler.c:844-853` takes the CSM lock, unregisters the peer socket, closes it, and only then calls `mlacp_peer_disconn_handler(csm)` at line 851. A process death after the close and before that call loses the only pending cleanup invocation.
- `src/iccpd/src/mlacp_link_handler.c:2291-2439` performs the substantive failover work only from `mlacp_peer_disconn_handler`: FDB conversion/deletion, ICCP-down publication, peer-link isolation cleanup, traffic recovery, VLAN/system-MAC recovery, and remote-interface deletion.
- `src/iccpd/src/system.c:57-92` recreates the singleton with zeroed userspace state and fresh lists. `src/iccpd/src/iccp_csm.c:129-166` likewise resets CSM socket, warm-reboot, role, and peer-link fields. None persists an unfinished-disconnect record.
- Startup in `src/iccpd/src/scheduler.c:375-410` rebuilds interfaces/config/neighbors before connecting to mclagsyncd. The comment at `src/iccpd/src/mlacp_link_handler.c:601-604` explicitly notes that startup session-down processing occurs before the mclagsyncd socket exists; lines 605-610 skip the publication in that case. `src/iccpd/src/iccp_cli.c:92-98` then treats repeated configuration as a duplicate, so mclagsyncd's later configuration replay does not rerun that processing.
- The only delayed disconnect cleanup found is the peer warm-reboot grace timer in `src/iccpd/src/mlacp_fsm.c:956-965`; its timestamp is volatile and is lost in this crash. The scheduler's syncd reconnect loop has no generic reconciliation barrier.
- Normal `system_finalize` cleanup is reached only after the scheduler returns (`src/iccpd/src/iccp_main.c:265-267`), so SIGKILL/abrupt termination bypasses it.
- Deployment does not close the gap: `dockers/docker-iccpd/supervisord.conf:39-43` sets `autorestart=false`, while `dockers/docker-iccpd/iccpd.sh` leaves mclagsyncd alive after `iccpd` exits. A later external restart reconstructs volatile caches but receives the retained downstream database state.

## Real-consumer evidence

The real downstream source was checked at the exact `sonic-swss` submodule commit `b20a59691baca9ff6e4fbe46a7cd8223a3419117` and compiled locally. `mclagsyncd/mclagsyncd.cpp:44-121` accepts/reaccepts iccpd connections; EOF is caught at lines 112-115 and causes a reconnect loop, not cleanup. `mclagsyncd/mclaglink.cpp:1288-1317` consumes the traffic-distribution message and writes `traffic_disable` into APPL_DB. The ICCP-state, remote-interface, and isolation handlers similarly change persistent Redis output only when messages arrive. Startup configuration replay (`mclagsyncd/mclaglink.cpp:137-187`) does not delete stale output.

At the exact `sonic-mgmt-framework` submodule commit `5dd487b0c66c85ceb0521e6452d9dc80fb357320`, the production MC-LAG CLI requests `MCLAG_TABLE` (`CLI/actioner/sonic_cli_mclag.py:194-196`) and merges its domain state, including `oper_status`, into displayed domain information (`CLI/actioner/sonic_cli_mclag.py:384-403`). Thus the retained State DB value has a concrete production reader rather than being an unused diagnostic field.

## Developer intent

The disconnect handler's comments and operations say that loss of the peer must recover traffic and clear peer-derived forwarding state. In particular, `src/iccpd/src/mlacp_link_handler.c:2406-2418` explicitly re-enables traffic disabled while the peer was present. The startup-order warning at lines 601-604 confirms that the authors know session-down notification depends on a connected consumer, but there is no later replay.

## Prior-report search and novelty evidence

- Searched the upstream `sonic-buildimage` issue tracker and pull requests for the handler names, socket-close ordering, ICCP disconnect cleanup, stale forwarding after restart, and mclagsyncd traffic/isolation cleanup. Also searched complete local `master` history (including recently merged commits at this checkout) with `git log --all`, `-S`, and relevant `--grep` terms.
- The closest issue found was [sonic-buildimage#16075](https://github.com/sonic-net/sonic-buildimage/issues/16075), but it reports a stack-smashing crash in `update_peerlink_isolate_from_all_csm_lif`; it does not report loss of already-pending disconnect cleanup across an abrupt restart.
- History attributes the basic ordering to `524cf9e56` (MCLAG feature, PR #2514) and later cleanup additions to `82b6bcfbb` (MCLAG enhancements, PR #4819). No merged/closed fix or report for this crash-consistency mechanism was found. Novelty evidence therefore supports `NEW` for this mechanism at the tested revision.

## Reproduction plan

Use an unmodified, clean exact-HEAD `iccpd` build and the real exact-submodule `mclagsyncd`, each node in an isolated network namespace with its own Redis. First try normal peer/process operations without a breakpoint (Level 0). If the tiny ordering cannot be established, use a debugger breakpoint at the first instruction of `mlacp_peer_disconn_handler` (Level 1 timing assistance only), after the real peer TCP close has already passed through `scheduler_csm_socket_cleanup`; terminate the process at that admissible state-11 boundary, restart from the same configuration, and query the real mclagsyncd/APPL_DB consumer after bounded settling time. No state injection or symptom-producing source patch is permitted.
