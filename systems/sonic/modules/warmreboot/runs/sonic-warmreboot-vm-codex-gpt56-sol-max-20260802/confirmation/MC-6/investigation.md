# MC-6 investigation record

## Scope and provenance

- Finding handled: MC-6 only.
- Source checkout: `sonic-net/sonic-buildimage` at `d5a2f4d1df9fdf71e48777905cd3f032b3d78a94` (2026-08-02 commit date in the supplied checkout).
- Relevant pinned submodules inspected:
  - `sonic-utilities` at `1462eff8982c69dcc262ffeac408ae7797689642`.
  - `sonic-swss` at `b20a59691baca9ff6e4fbe46a7cd8223a3419117`.
  - `sonic-swss-common` at `c544c90acc862dddacdb454a2ad8d5eb1a68e105`.
  - `sonic-platform-daemons` at `6acdb85aa4d860d2bf174ddb33e65be148b351c6`.
- The supplied TLC output is an actual violation trace: `spec/output/MC_hunt_scenario6_flags_bfs.out:35` reports `Invariant WarmFlagSafeToClear is violated`.

## Step 1: code audit

### Cited code and behavior

- `files/image_config/warmboot-finalizer/warmboot-finalizer.service:1-11` installs a oneshot service, wanted by `multi-user.target`, whose only explicit ordering dependency is `database.service`; its entry point is `/usr/local/bin/finalize-warmboot.sh`.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:95-101` includes reconciliation components only for enabled/always-enabled services.
- `finalize-warmboot.sh:139-155` reads each component's `WARM_RESTART_TABLE|<component>.state` and keeps every value other than `reconciled` in the wait list.
- `finalize-warmboot.sh:237-259` polls 60 times, sleeping five seconds after each incomplete poll. A non-empty list after the loop only emits `Some components didn't finish reconcile`; the function returns success and has no failure output parameter.
- ASIC and global waits run in child processes (`finalize-warmboot.sh:268-297`); the parent waits for those children (`:299-300`) and then unconditionally calls `finalize_global` (`:302`). On multi-ASIC systems, each namespace child likewise calls `finalize_boot` after its bounded wait (`:284-289`).
- `finalize-warmboot.sh:165-175` clears the system warm flag through `config warm_restart disable` and clears the fast flag with a `STATE_DB hset`. `finalize_boot` invokes both when both cached entry flags were true (`:181-190`).
- `sonic-utilities/config/main.py:4114-4134` confirms that `config warm_restart disable` writes `WARM_RESTART_ENABLE_TABLE|<module>.enable=false`; it does not delete `WARM_RESTART_TABLE` component state.
- `finalize-warmboot.sh:308-310` then logs a save and invokes `config save -y`.

### Entry path and reachability

- The normal `warm-reboot` entry path reaches this state without a private call. `sonic-utilities/scripts/fast-reboot:979-992` selects the warm-reboot path and calls `enable_warm_restart` in every namespace; that helper invokes the public `config warm_restart enable ... system` API at `:896-898`.
- The normal fast-reboot path sets both `FAST_RESTART_ENABLE_TABLE|system=true` and the system warm-restart flag (`sonic-utilities/scripts/fast-reboot:972-978`), matching the counterexample's two true flags.
- The concrete admissible trace is:
  1. State 2, `MCFastRebootRequest`, records the pending request (`MC_hunt_scenario6_flags_bfs.out:113-172`).
  2. State 4 publishes `warm=TRUE, fast=TRUE` (`:265-324`).
  3. State 5 has `fpmsyncd_component=restored`, `orchagent_component=initial`, pending outcome, and no modeled output (`:341-400`). In implementation terms, fpmsyncd publishes under component name `bgp`, while orchagent publishes under `orchagent`.
  4. State 6 takes `MCFinalizeWarmbootWaitTimeout` while those states remain incomplete (`:417-476`).
  5. State 7 clears both flags without changing the component states or pending outcome (`:493-552`).
- A production example of the same timeout state exists in upstream issue #27700: after a public `warm-reboot`, orchagent repeatedly crashes, the finalizer logs 60 incomplete polls followed by `Some components didn't finish reconcile: orchagent` and `Finalizing warmboot`, and `show warm_restart state` still reports `orchagent ... restored`.

### Consumers and safeguards recorded

- Already-running C++ participants do not continuously derive their FSM from the database flag. `sonic-swss-common/common/warm_restart.cpp:86-139` reads the enable knob in `checkWarmStart`, and `:173-178` returns the cached `m_enabled`. The unit test explicitly says `checkWarmStart()` is expected only at process start/reinitialization (`tests/warm_restart_ut.cpp:63-66`).
- fpmsyncd calls `WarmStartHelper::checkAndStart()` once before entering its event loop (`sonic-swss/fpmsyncd/fpmsyncd.cpp:154-190`). `WarmStartHelper` caches both its enabled value and FSM state (`sonic-swss/warmrestart/warmRestartHelper.cpp:30-35,49-86`), so later clearing the database flag does not cancel the running timer/reconciliation path.
- Component progress is a separate observable record. `sonic-swss-common/common/warm_restart.cpp:222-233` writes state to `WARM_RESTART_TABLE`; `sonic-utilities/show/warm_restart.py:46-78` reads that table directly and does not consult the cleared enable flag. Thus `initialized`/`restored` remains visible after finalization, as the output in upstream issue #27700 also demonstrates.
- A late-start consumer historically did observe a wrong signal. Upstream issue #17943 records finalizer completion before pmon startup; xcvrd then read `is_warm_start: False` and entered the media-settings notification path that was meant to be suppressed during warm reboot.
- The pinned current xcvrd contains the downstream safeguard added by sonic-platform-daemons PR #666 / commit `4a00fd6d8965d410cbc5ed0a6a4f027365e98093`. `sonic-xcvrd/xcvrd/xcvrd_utilities/common.py:153-183` returns warm-recovery true when `WARM_RESTART_TABLE|syncd.restore_count > 0`, even after the finalizer cleared the system flag. `sonic-xcvrd/xcvrd/xcvrd.py:314-338` uses that result to skip `notify_media_setting`. Commit `4a00fd6...` is an ancestor of the pinned submodule commit.

## Step 2: developer-knowledge evidence

- Original finalizer PR #2715 states: after warm reboot is done, the service must disable the warm-reboot flag and tear down persisted setup. Its review also describes component state flags as system observability and asks participants to publish them.
- Issue #2729 documents why leaving the enable flag set is harmful: a later `config reload -y` is misclassified as warm. The finalizer author described clearing the flag roughly two minutes after boot as the mitigation.
- Issue #6383 captured the exact timeout-log-then-finalize sequence for a disabled natsyncd. PR #6454 fixed that report by filtering out disabled services, while retaining bounded wait and flag finalization. A later comment explicitly lists delayed disabling of the system flag as an undesirable effect of waiting the full five minutes.
- The April 2026 multi-ASIC PR #25072 says verification must confirm that the script waits for per-ASIC components and that warm/fast flags are disabled in every namespace and globally after finalization.
- sonic-platform-daemons PR #666 states that, in production, the finalizer clears the system flag before xcvrd publishes port/optics configuration; xcvrd then pushed too early and all ports flapped. The merged change deliberately replaced the flag as xcvrd's completion signal with `syncd.restore_count`.

## Step 3: known-status / precedent

- Tracker searches covered open issues, closed issues, open PRs, closed PRs, and PRs merged/updated in 2026. Queries included `warmboot-finalizer`, `finalize-warmboot`, the exact timeout log, `warm restart timeout reconcile`, and `warm restart flag reconcile` in `sonic-net/sonic-buildimage`; local full-path history was also checked.
- The exact mechanism was publicly reported at the same finalizer/flag boundary in issue #17943 and, with demonstrated all-port flaps, in sonic-platform-daemons PR #666: the finalizer clears the flag before a warm-reboot participant consumes it.
- PR #666 is merged and its commit `4a00fd6d8965d410cbc5ed0a6a4f027365e98093` is present in the pinned current xcvrd. Known-status record: `KNOWN (cite: https://github.com/sonic-net/sonic-platform-daemons/pull/666; fix-status: fixed)`.
- This finding is MC-sourced with a real counterexample, so the code-review-only drop pre-filter does not apply and Phase 2 is required.
