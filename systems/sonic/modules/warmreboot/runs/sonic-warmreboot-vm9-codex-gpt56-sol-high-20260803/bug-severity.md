# Severity Classification — warmreboot

## Summary

- Total entries: 5
- Reproduced bugs: 4
- Severity-bearing findings: 1
- Critical: 2
- High: 3
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | Restarting `rebootbackend` during an accepted host reboot exposes stale inactive status and falsely acknowledges another gNOI reboot request. The host rejects the duplicate platform action, bounding the external harm to incorrect control-plane status and acknowledgement rather than a second reboot. |
| 2 | MC-2 | REPRODUCED | High | Enabling an extension package after the finalizer snapshots reconciliation registrations lets global finalization proceed while that component is still restoring. The service-management path then performs a cold stop instead of a warm kill, causing externally observable but reboot-epoch-bounded service disruption. |
| 3 | MC-3 | MASKED | Critical | A normal configuration update after `orchagent` acknowledges its freeze can leave CONFIG_DB and ASIC state persistently inconsistent, such as a configured-up port remaining down and disrupting data-plane traffic. SWSS startup replay currently masks that lasting consequence by applying the durable configuration to SAI after restart. |
| 4 | MC-4 | REPRODUCED | Critical | An interrupted `docker cp` during fast-reboot snapshot publication leaves a non-empty truncated RDB that passes restore gates and makes Redis abort during database startup. The resulting database-service failure has no automatic recovery and persists until external cleanup or cold recovery. |
| 5 | MC-5 | REPRODUCED | High | A transient D-Bus transport loss on the public warm-reboot request path becomes a permanent definitive failure, exposing incorrect status and rejecting every later warm-reboot attempt. The harm is externally observable but bounded because an operator can recover by choosing a cold reboot. |
