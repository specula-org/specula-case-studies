# Warmreboot trace instrumentation

`apply.sh` copies the C++/Python emitters into the pinned artifact and applies four idempotent patches. Raw probes send one JSON object per Unix datagram to the harness collector; this keeps C++ threads and the finalizer's parallel shell children from interleaving partial lines. `trace_reducer.py` then chooses only a causally enabled ordering and mirrors the corresponding `base.tla` update. It fails on missing observed fields, unknown names, an impossible next action, or an epoch overflow.

`spec/Trace.tla` canonicalizes the JSON arrays for `warm.required` and `shutdown.stoppedAtCommit` to TLA+ sets at validation time. This is representation-only: the complete records and every field are still checked by exact equality.

## Instrumentation points

- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:216,327`: accepted request after manager status update; joinable/non-joinable finish after `Join` and manager reset.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:115,171,178,201,227,250,337`: timer start, host/D-Bus success or failure, three platform-deadline branches, and thread-launch exception.
- `src/sonic-host-services/host_modules/reboot.py:160,202,226,248,263,269`: terminal worker completion and host accept/reject branches.
- `src/sonic-utilities/scripts/fast-reboot:907,916`: logical fast-reboot begin immediately before warm enablement, plus each successful namespace enable.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:106,164,277,282,318,335,346`: component registration/readiness, injected timeout interpretation, deadline, per-namespace/global finalization, and DB save completion.

After applying, obtain exact current lines with:

```bash
rg -n 'tla_trace::Emit|specula_trace_event|specula_trace_emit' \
  /users/Pial/targets/sonic-buildimage-warmreboot-high/src/sonic-sysmgr \
  /users/Pial/targets/sonic-buildimage-warmreboot-high/src/sonic-host-services \
  /users/Pial/targets/sonic-buildimage-warmreboot-high/src/sonic-utilities \
  /users/Pial/targets/sonic-buildimage-warmreboot-high/files/image_config/warmboot-finalizer
```

## Adjusting events

To add an observed field, change the JSON passed at the real trigger point and add the field to `REQUIRED_OBSERVED` in `harness/src/trace_reducer.py`. If it is abstract state, update the reducer action and keep the complete modified record in `event.state`.

To add an event type, copy the nearest `tla_trace::Emit`, `specula_trace_emit`, or `specula_trace_event` call, then implement the exact base-action guard/update in `apply_if_enabled`. Do not emit a partial abstract record.

To move a capture point, move only the probe call to the required before/after boundary; keep observed reads at that boundary. For parallel shell paths, retain Unix-datagram emission rather than appending to a regular file.

Rebuild and rerun from `.specula-output/` with `bash harness/run.sh`.

## Coverage limits

The first trace batch covers all normally reachable instrumented events plus D-Bus transport loss and a timeout observation at the readiness boundary. The timeout probe is telemetry only and must not mark the component restored. `StartThreadLaunchFailure` and `HandleRebootFinishNonJoinable` require forcing the C++ runtime's `std::thread` constructor to throw, which the existing test framework cannot inject. Host application rejection is instrumented but the current base action's guard requires `hostPending` while `dbusPhase="calling"`, a state no preceding base action establishes. `HostComplete` requires letting the host worker survive its 260-second reboot timeout or a physical host fault; it is intentionally not triggered in this VM harness. These four probes are retained for hardware/fault-injection runs and are reported as environment-limited by `verify_traces.py`.

Snapshot/shutdown/restore actions are not probed in this first batch where the instrumentation contract calls for hooks outside this checkout (CONFIG_DB/APPL_DB barriers, supervisor, systemd timers, boot-ID observer) or where exercising the real path would stop services or invoke kexec. They must be added at those owning components rather than synthesized in the harness.
