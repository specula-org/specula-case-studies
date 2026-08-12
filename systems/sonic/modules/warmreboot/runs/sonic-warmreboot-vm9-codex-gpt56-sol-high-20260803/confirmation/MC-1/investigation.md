# MC-1 investigation evidence

## Source and counterexample

- Source: MC. `spec/output/MC_hunt_scenario1_bfs.out` reports `Invariant OwnershipRecovery is violated` and a five-state behavior.
- Relevant admissible trace: state 2 `MCAcceptRequest` creates an active/in-progress request; state 3 records D-Bus delivery with `hostPending = TRUE` and `hostStatus = "accepted"`; state 4 `MCCrashBackend` clears backend activity, manager state, request identity, and thread ownership while leaving the host pending; state 5 restarts the backend with manager `idle` while the host remains accepted/pending.

## Code audit

### Relevant sites

- `src/sonic-sysmgr/rebootbackend/rebootbe.h:48` initializes every `RebootBE` object's `m_CurrentStatus` to `IDLE`.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:26-33` constructs a new backend and a new `RebootThread`; it reads no durable operation identity or host status.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:44-74` performs warm-start library initialization, then immediately enters the notification loop; there is no startup reconciliation with `RebootStatus`.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:146-224` gates a request only on the process-local manager state, starts the local worker, and returns the worker's immediate result.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:227-241` allows every method when that local state is `IDLE`.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:244-274` consults the host's `RebootStatus` only when the local manager already says a HALT is in progress. A fresh backend instead returns its fresh local `RebootThread` response.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:313-346` reports success after launching the worker and explicitly defers later errors to `RebootStatus`; the D-Bus call itself happens asynchronously at `reboot_thread.cpp:165-176`.
- `src/sonic-host-services/host_modules/reboot.py:69-80` maintains reboot ownership independently in `reboot_status_flag` in the host-service process.
- `src/sonic-host-services/host_modules/reboot.py:199-243` is the real D-Bus entry point. It leaves `active=true` after accepting an operation and returns `"Previous reboot is ongoing"` for a later request while active.
- `src/sonic-host-services/host_modules/reboot.py:245-251` exposes that separately maintained status over D-Bus.
- `dockers/docker-sysmgr/supervisord.conf:35-42` configures `rebootbackend` with `autorestart=true`. The host service is a separate systemd service (`src/sonic-host-services/data/debian/sonic-host-services-data.sonic-hostservice.service:4-12`), so restarting the backend without restarting the host service is an ordinary deployment fault boundary.

### Public call chain and real consumer

1. An authenticated local-system gNOI `Reboot` reaches `src/sonic-gnmi/gnmi_server/gnoi_system.go:192-237`.
2. `sendRebootReqOnNotifCh` publishes the validated request to `Reboot_Request_Channel` at `gnoi_system.go:116-150` and waits for `Reboot_Response_Channel` at `gnoi_system.go:152-189`.
3. `RebootBE::Start` selects the request and dispatches it through `DoTask` (`rebootbe.cpp:44-74,290-316`).
4. `HandleRebootRequest` launches `RebootThread`; the worker calls the host service through D-Bus (`rebootbe.cpp:146-224`, `reboot_thread.cpp:152-183`, `interfaces.cpp:27-49`).
5. The gNOI server treats a SWSS success response as an OK RPC and returns an empty successful `RebootResponse` at `gnoi_system.go:174-179,228-237`. This is the real consumer of a false-success backend response.
6. A gNOI `RebootStatus` request is similarly returned to the remote client at `gnoi_system.go:240-266`; it consumes the fresh backend's local `active=false` response after restart.

### Reachable trigger scenario

1. Send a valid WARM `Reboot` through the normal request channel/gNOI path.
2. The backend launches its worker, the real host D-Bus service validates the request, sets its independent `reboot_status_flag.active=true`, launches the host reboot worker, and returns success.
3. Before the host worker completes, restart only `rebootbackend`. Supervisor's `autorestart=true` starts a fresh process while the separate host service and its worker remain alive.
4. Query `RebootStatus`: the fresh backend is `IDLE` and returns a fresh local inactive/unknown response rather than the host's active status.
5. Send another valid reboot. The fresh backend's local guard permits it and immediately returns SWSS success after launching a worker. The still-active host guard rejects the later D-Bus operation as `"Previous reboot is ongoing"`, but that rejection arrives asynchronously after the gNOI success response.

No state injection is required. Process restart is a normal operational fault, and the accepted host state is produced by the first real request. The sequence matches counterexample states 2 through 5.

### Safeguards and downstream behavior to test

- The host guard at `reboot.py:209-215` prevents a second platform reboot command from executing while the first host operation is active.
- That guard does not repair the restarted backend's ownership or the already-returned gNOI result because D-Bus failure is recorded only asynchronously (`reboot_thread.cpp:165-176,327-346`).
- The fresh backend has no periodic sync, startup query, durable ownership read, loopback, or resend. Its stale status persists until a later local request changes it; the host independently clears its own status only when the host worker completes (`reboot.py:157-197`).

## Developer-knowledge evidence

- Commit `46eb26ee1` / PR [#20786](https://github.com/sonic-net/sonic-buildimage/pull/20786) introduced the backend and states the intent to support gNOI warm reboot and HALT.
- Commit `3b4082cac` / PR [#22576](https://github.com/sonic-net/sonic-buildimage/pull/22576) says it added reasons for *blocking* an in-progress reboot. Its tests at `src/sonic-sysmgr/tests/rebootbe_test.cpp:498-556` assert that a second in-process request is blocked for same-method and cross-method combinations. They do not restart the backend.
- Commit `170f70d7b` / PR [#22634](https://github.com/sonic-net/sonic-buildimage/pull/22634) says host-side status is needed for accurate state reflection during HALT, but its implementation uses D-Bus only when the volatile local state already says HALT is active (`rebootbe.cpp:248-250`).
- Commit `0a5f37c49` / PR [#22404](https://github.com/sonic-net/sonic-buildimage/pull/22404) removed the prior `WARM_INIT_WAIT` startup state because it blocked a later warm reboot. This is evidence that current startup intentionally enters the operational loop without that coarse warm-start block; it does not discuss recovery of an already accepted gNOI operation.
- No nearby TODO/FIXME, design note, or existing test describes backend-process restart during an accepted host reboot.

## Known-status and precedent search

Novelty evidence: NEW candidate; no same-mechanism report was found.

- Searched GitHub's issue/PR tracker across open and closed results for `sonic-net/sonic-buildimage`, `sonic-net/sonic-host-services`, and `sonic-net/sonic-gnmi` using: `rebootbackend restart`, exact `"Previous reboot is ongoing"`, `gNOI reboot status restart`, `reboot restart active`, and `Reboot_Response_Channel`/`m_CurrentStatus` terms.
- The only `sonic-buildimage` result for `rebootbackend restart` was open issue [#27700](https://github.com/sonic-net/sonic-buildimage/issues/27700), which concerns an orchagent/syncd warm-reconciliation failure on sonic-vs, not loss of backend request ownership.
- Closed issue [#22157](https://github.com/sonic-net/sonic-buildimage/issues/22157) and merged PR [#22634](https://github.com/sonic-net/sonic-buildimage/pull/22634) concern missing HALT `RebootStatus` replies on SmartSwitch DPU flows, not backend restart or volatile ownership.
- Recently merged/closed PR searches produced host-services PR [#255](https://github.com/sonic-net/sonic-host-services/pull/255), which persists DPU module transition ownership at a different site, and no matching sonic-gnmi PR. This is a different subsystem/mechanism and is not a duplicate.
- A closed-PR view sorted by most recently updated for `rebootbackend` also surfaced build-only PRs [#27722](https://github.com/sonic-net/sonic-buildimage/pull/27722) and [#27447](https://github.com/sonic-net/sonic-buildimage/pull/27447), plus the older feature PRs already audited; none reconciles accepted reboot ownership after process restart. Recent (2026) file history likewise contains only build/container updates at the sysmgr site and a HALT timeout change at the host-service site.
- Searched local full commit histories in the three repositories for `reboot restart`, `restart reboot`, `rebootbackend`, and `Previous reboot is ongoing`; the relevant commits were the original feature and behavior changes cited above, with no repair or report for backend restart recovery.

Because this is MC-sourced with a real violation trace, it proceeds to Phase 2 regardless of novelty.
