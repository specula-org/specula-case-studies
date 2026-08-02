# MC-1 reproduction

## Test and command

- Test: `/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/repro/test_bugMC-1_crash_window.sh`
- Command: `timeout 180s ./test_bugMC-1_crash_window.sh`
- Exit status: 0
- Product provenance: clean `git archive HEAD` build of sonic-buildimage `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9`; real mclagsyncd built at exact sonic-swss submodule `b20a59691baca9ff6e4fbe46a7cd8223a3419117`.

## Escalation

- Level 0 used two real iccpd peers, real TCP, real network interfaces, real mclagsyncd, and isolated real Redis. Killing the peer and local processes without a breakpoint did not hit the narrow ordering: ordinary cleanup won and changed the downstream state to `down`.
- Level 1 used the same environment and a debugger breakpoint solely to hold time at the first instruction of `mlacp_peer_disconn_handler`. A real peer SIGKILL caused the production scheduler to close the peer socket. GDB proved `csm->sock_fd == -1` and showed `scheduler_session_disconnect_handler` at `scheduler.c:851` as the caller. It then applied the abrupt local process-death action corresponding to counterexample state 11.
- Level 2 and Level 3 were not used because Level 1 demonstrated live harm.

## Actual output

```text
BUILD sonic-buildimage=9df8ccbf72c31948741b5554d09c38ac6c1ec6e9 sonic-swss=b20a59691baca9ff6e4fbe46a7cd8223a3419117
BUILD iccpd_sha256=84d6535646f7333b682b5b7e247a199e534791fec60bc629bbc2adb0d1aca6a4 mclagsyncd_sha256=aa44f44185dc5e88871bb70653b0457b0ac265823afa9d471dafd0f7af768b0f
LEVEL0_PRE oper_status=up
LEVEL0_RESULT=not_triggered close_after_teardown=0 observed_oper_status=down
LEVEL1_PRE oper_status=up
LEVEL1_BREAKPOINT_HIT sock_fd=-1
#0  mlacp_peer_disconn_handler (csm=0x55c34eba1920) at mlacp_link_handler.c:2350
#1  0x000055c31f79e7d7 in scheduler_session_disconnect_handler (csm=0x55c34eba1920) at scheduler.c:851
AFTER_CRASH oper_status=up
POST_RESTART_2S oper_status=up
POST_RESTART_8S oper_status=up
DOWNSTREAM_RECOVERY_OBSERVED=no (waited >2x configured session_timeout after reconnect)
TEST_RESULT=BUG_REPRODUCED level=1
```

## Expected versus observed

The no-crash control published `oper_status=down`. At the admissible crash boundary, the down publication at `src/iccpd/src/mlacp_link_handler.c:2397` never ran. After a clean restart reconnected to the still-running real mclagsyncd, State DB continued to report `up` at 2 and 8 seconds even though the peer remained dead. Eight seconds exceeds twice the configured three-second session timeout; no startup reconciliation, resend, loopback, or consumer guard repaired it.

The wrong value is produced/retained by the real consumer path `sonic-swss/mclagsyncd/mclaglink.cpp:1320-1359` and is read for the production CLI by `sonic-mgmt-framework/CLI/actioner/sonic_cli_mclag.py:384-403`.

## Counterexample match

The live ordering matches the MC trace: peer loss is detected, peer socket teardown finishes, abrupt process death occurs before disconnect cleanup, the process restarts, and running state is reached without replaying cleanup. The GDB frame and `sock_fd=-1` observation directly identify the claimed root-cause boundary rather than a different crash.

## Decision evidence

The reachable Level 1 trigger and persistent wrong value observed through a real consumer meet the skill's `REPRODUCED` row. The failure is not masked and this environment is not limiting the trigger.
