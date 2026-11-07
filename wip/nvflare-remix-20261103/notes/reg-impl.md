# Reg group: SP client registry and cleanup thread (v8 plan)

Goal: replace the abstract dead-client report (CommSJ `WFCommReportDeadClient`, guarded by `PeerFailureCJ` and fault `deadClient`) with the real chain. Then T2, T3 and R2 become behaviors of the model, not findings outside it.

Real chain (pin c411a201):
- CP login: `ClientManager.authenticate` (client_manager.py:320-345) gives a fresh uuid token. A re-login of the same name pops the old token without `notify_dead_client`.
- Heartbeat: every 30 s it refreshes `last_connect_time` and runs `_sync_client_jobs` (fed_server.py:1013-1084, R2). The "job not on client" check only matches the participant tokens recorded at job start.
- Cleanup thread `client_cleanup` (fed_server.py:290-305) has no handler. Every 5 s, `remove_dead_clients` iterates the live `clients` dict without the lock and lists stale tokens.
- For each listed token, `logout_client`:
  1. `remove_client`, which returns None if the token is gone (T2);
  2. `notify_dead_client`:
     - resolve missing outcomes (`fail_run`, which takes seconds);
     - iterate `run_processes` without `engine.lock` (T3);
     - for each job whose PARTICIPANTS hold the token, `_notify_dead_job` sends HANDLE_DEAD_JOB to that job's SJ (fire_and_forget).
- SJ: `WFCommServer.handle_dead_job`, then `_dead_clients[c]` (wf_comm_server.py:191-202).

Port `pReg` (owner Reg). It is read by CommSJ and JobSP, and Reg reads pJobCP:
- `tok[c]`: current token generation of site c (0 = not registered).
- `stale[c]`: heartbeats stopped (missed beyond `heart_beat_timeout`).
- `notified[c]`: set of token generations for which HANDLE_DEAD_JOB was sent to our SJ.
- `cleanupCrashed`: the cleanup thread died.

Changes elsewhere:
- **JobSP (F and C):** record the participant generations at job start, as a port field `pJobSP.partTok[c]`. Also expose "another job's SJ exits" for T3. Option: an environment action in Reg_F gated by profile `otherJob`, which mutates the run_processes size during the notify iteration.
- **CommSJ (F and C):** the dead report needs `pReg.notified[c] \cap {pJobSP.partTok[c]} /= {}` instead of `PeerFailureCJ`. The coarse variant may keep a nondeterministic superset, but the refinement must hold.
- **JobCP:** none if Reg derives login and re-login from `pJobCP` (launch > 0 means logged in; `cpRestarted` means a re-login with generation + 1).

Variants:
- **Reg_C:**
  - stale and not stale when the CP is dead or with fault `deadClient`;
  - `notified` may be set for any stale participant generation;
  - re-login after `cpRestarted` with generation + 1 and no notify (R2);
  - `cleanupCrashed` only under faults (re-login during logout, other-job exit).
- **Reg_F:** pc-level `client_cleanup`:
  - list;
  - per token: remove, then None-deref crash (T2);
  - resolve outcomes;
  - iterate jobs: notify ours, other-job mutation crash (T3).

Properties:
- `GCleanupThreadAlive == ~pReg.cleanupCrashed`.
- R2 shows as a deadlock (the SJ waits forever) with KnownStuck off.
- K filters for hunts: `KT2T3 == pReg.cleanupCrashed`.

Checks:
1. gen_ref Reg F→C.
2. Refinement rechecks of JobSP and CommSJ after the port change.
3. TV on all four mixes. The POC trace has no dead client, so Reg must stay silent there.
4. Blind rediscovery of T2, T3 and R2, then a hunt family "reg".

Status: L13 done first (statusLost, GFinishedNoPanic). This plan is next.
