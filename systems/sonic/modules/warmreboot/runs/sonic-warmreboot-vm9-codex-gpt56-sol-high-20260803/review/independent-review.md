# Independent review

## Tracker decision

The tracker batch records reviewed, new, recordable bugs. This run contributes three rows:

| Finding | Pipeline disposition | Severity | Tracker decision |
|---|---|---:|---|
| MC-1 | REPRODUCED | High | Add. A restarted `rebootbackend` loses accepted-reboot ownership while the host operation remains active, exposing stale inactive gNOI status and falsely acknowledging another reboot request. |
| MC-2 | REPRODUCED | High | Add. Runtime extension install/enable is a supported management surface, no admission guard rejects it during finalization, and the static finalizer snapshot omits the late reconciling component. |
| MC-4 | REPRODUCED | Critical | Add. A failed backup-side `docker cp` leaves a non-empty partial `dump.rdb` that restore gates accept; Redis then aborts with an RDB EOF error and database startup does not self-recover. |

## Not added from this review

| Finding | Pipeline disposition | Severity | Reason |
|---|---|---:|---|
| MC-3 | MASKED | Critical | Not a bug row. The post-freeze configuration crossing is real, but the reproduced DVS flow shows SWSS startup replay applies the durable configuration and masks the lasting ASIC divergence. |
| MC-5 | REPRODUCED | High | Not added yet. The pipeline demonstrates the in-process classification path, but this review keeps it pending until direct validation separates transient D-Bus transport loss from authoritative host outcome in the deployed SONiC host-service path. |

## MC-2 contract conclusion

MC-2 is not a false positive on the basis of "install during warm finalization may be unsupported." The official application-extension HLD makes runtime package installation, warm/fast restart integration, package warm upgrade, and `processes[].reconciles` finalizer participation part of the supported extension design. Current `sonic-package-manager install --enable` creates the reconcile file, registers an enabled FEATURE, and `featured` starts the feature via systemd. Current `finalize-warmboot.sh` snapshots reconcile files once and has no lock, ordering, or generation check against package registration.

If SONiC wants to forbid this exact administrative interleaving, the bug becomes a missing admission guard: no current public path rejects or defers `install --enable` while warm finalization is in progress. Either way, the current behavior lets a real consumer observe the wrong result.

## Current-source recheck

MC-2 was rerun on current upstream `sonic-buildimage@544f52cb3abf45287ac81829ba855fc1950fac52` on 2026-08-11. The reproduced output is preserved in [mc2-current-reproduction.txt](mc2-current-reproduction.txt). The decisive result is:

```text
LATE_COMPONENT_STATE=restoring
GLOBAL_WARM_FLAG=false
REAL_CONSUMER_BAD_OUTCOME=SERVICE_ACTION=stop
REAL_CONSUMER_EXPECTED_CONTROL=SERVICE_ACTION=kill
BUG_TRIGGERED: finalizer omitted latecomp and a real consumer selected cold stop instead of warm kill
```

## Wording boundary

MC-2 should be reported as a finalizer/package-registration coordination bug, not as a general "components have no dependency barrier" duplicate. The mechanism is membership discovery after a static snapshot, not dependency ordering among already-known warm-restart participants.
