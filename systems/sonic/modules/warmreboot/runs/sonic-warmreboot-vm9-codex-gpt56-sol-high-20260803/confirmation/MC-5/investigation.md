# MC-5 investigation

## Code audit

- Source revision: `9914efc028c3835c564eb0c6028a019991b5c422`. The checkout contains pre-existing TLA trace instrumentation; the classification statements themselves are tracked code from commit `46eb26ee1f1a02703f7a7ec94732b1fff68e5d19`.
- `src/sonic-sysmgr/rebootbackend/interfaces.cpp:35-40`: `HostServiceDbus::Reboot` catches every `DBus::Error` raised by `issue_reboot` and returns `DbusStatus::DBUS_FAIL` with the fixed transport-error string.
- `src/sonic-sysmgr/rebootbackend/interfaces.cpp:43-48`: an authoritative nonzero return from the host service also becomes the same `DbusStatus::DBUS_FAIL` enum. `reboot_interfaces.h:7-15` has only `DBUS_SUCCESS` and `DBUS_FAIL`, so the caller cannot distinguish these origins.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:165-176`: `send_dbus_reboot_request` maps every `DBUS_FAIL` to `log_error_and_set_non_retry_failure`.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:349-364`: definitive `STATUS_FAILURE` and `STATUS_RETRIABLE_FAILURE` are separate protocol states, but only the thread-launch exception path at lines 330-345 selects the retriable state.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:280-287`: after a definitive warm-reboot failure, the next warm request is rejected with `SWSS_RC_FAILED_PRECONDITION`.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:319-335`: completion joins the worker and makes the manager idle, but does not reconcile or clear the failure classification.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:244-273`: the `RebootStatus` request returns the stored worker status for warm/cold reboots. Platform status reconciliation exists only for HALT at lines 248-251.

## Call chain and reachability

Normal public path: request notification received by `RebootBE::Start` (`rebootbe.cpp:44-74`) -> `DoTask` (`rebootbe.cpp:290-316`) -> `HandleRebootRequest` (`rebootbe.cpp:146-224`) -> `RebootThread::Start` (`reboot_thread.cpp:313-347`) -> `send_dbus_reboot_request` (`reboot_thread.cpp:152-184`) -> `HostServiceDbus::Reboot` (`interfaces.cpp:27-49`). The response path is `DoTask` -> `HandleStatusRequest` -> `RebootThread::GetResponse`.

Concrete trigger:

1. A valid WARM reboot request enters `Reboot_Request_Channel` while the manager is idle.
2. The worker dispatches `issue_reboot`, and the D-Bus call raises `DBus::Error` because the transport/service becomes unavailable.
3. The wrapper returns `DBUS_FAIL`; the worker stores definitive `STATUS_FAILURE`.
4. `HandleRebootFinish` joins and sets the manager idle without changing the stored class.
5. A normal status request observes `STATUS_FAILURE`.
6. A second valid WARM reboot request reaches `RebootThread::Start` and is rejected with `SWSS_RC_FAILED_PRECONDITION`; D-Bus is not called again.

Reachability evidence: the real system bus in this environment returns `org.freedesktop.DBus.Error.ServiceUnknown` for the declared `org.SONiC.HostService.reboot.issue_reboot` method when the SONiC host service is absent. The MC violation follows State 2 `<MCAcceptRequest>` then State 3 `<MCLoseDbus>`, where `failureCause = "transport"` and `failureClass = "definitive"`. The Level-2 reproduction injects exactly the `DbusResponse` produced by the catch at `interfaces.cpp:35-40`, not an invented peer value.

Safeguards checked: joining clears only `active`; it does not clear or downgrade status. Warm/cold status does not query the host. The next-warm guard fires, but it is the consumer-visible harm rather than a mask. A separately requested COLD reboot is allowed as manual recovery, but there is no automatic retry, resend, reconciliation, or later status correction for WARM.

## Developer-knowledge evidence

- The comment at `interfaces.cpp:43` documents host return `0` as success and `1` as failure, but the wrapper uses the same enum for that response and a caught transport exception.
- `reboot_thread.h:39-44` documents `UNKNOWN`, `SUCCESS`, `RETRIABLE_FAILURE`, and `FAILURE` as distinct status values.
- `reboot_thread.cpp:283-284` explicitly says a non-retriable warm failure must not be retried and that cold boot is the recovery.
- Tracked tests `rebootbe_test.cpp:376-418` assert that a generic injected `DBUS_FAIL` becomes definitive `STATUS_FAILURE` for both cold and warm requests. `reboot_thread_test.cpp:352-366` separately asserts that definitive failure blocks a later warm request. No tracked test distinguishes caught D-Bus transport error from authoritative host rejection.
- Merged PR #20786 introduced this behavior as part of gNOI warm-reboot support without documenting transport-failure classification. Merged PR #22634 later added platform status handling only for HALT and states that behavior for other reboot types was preserved.

## Known-status / precedent search

Tracker/API searches covered open and closed issues and all-state PRs with `rebootbackend DBUS_FAIL`, exact `HostServiceDbus::Reboot` / `failed to call reboot host service` phrases, and `retriable failure` plus reboot. Issue and PR searches for the classification terms returned zero exact reports. Current upstream path history contains only the sysmgr rename and the HALT-status change after introduction; neither separates transport uncertainty or changes the warm retry guard.

Issue #22545 is a near match at the same observable error string, but reports a different mechanism: a valid COLD request without `message` triggers a deterministic `KeyError` in `sonic-host-services/reboot.py`. It does not report transient transport uncertainty, the collapsed result type, or warm retry rejection, so it is not the same defect.

Novelty evidence: `NEW` — no issue or open/closed/merged PR was found for this mechanism at this site.

## Reproduction preflight and escalation record

- Existing artifact preflight: `src/sonic-sysmgr/tests/.libs/tests` was built on the same source SHA but its wrapper points to generated protobuf artifacts under `/users/Pial/targets/sonic-buildimage-warmreboot-high`; it was treated as a smoke-check/recipe source. Its initial run failed before the test because `/var/run/redis/redis.sock` was a stale symlink. The corresponding source checkout is also SHA `9914efc...`; generated `librebootgnoi.so.0.0.0` was reused. Current production sources were rebuilt directly into the reproduction executable.
- Level 0: the declared real D-Bus method was called on the system bus with no failpoint and returned `org.freedesktop.DBus.Error.ServiceUnknown`. End-to-end production `rebootbackend` was not available: no SONiC host-service bus owner was present, no built daemon existed, and the environment lacks the `libdbus-c++-1` development/runtime library required to rebuild `interfaces.cpp`.
- Level 1: timing assistance is not applicable to this non-racy classification path, and cannot create the absent SONiC service. No source or logic was changed.
- Level 2: a fresh Redis instance was supplied and the test used the real notification entry point, manager loop, reboot worker, status consumer, and retry guard. The D-Bus boundary returned the exact reachable `DBUS_FAIL` value emitted at `interfaces.cpp:35-40`, corresponding to counterexample State 3 `<MCLoseDbus>`. This level exercised the complete caller-visible consequence.
- Level 3: not reached because Level 2 triggered the target behavior; production source logic was not patched.
