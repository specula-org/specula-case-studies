# MC-2 investigation

## Scope and source

- Finding: MC-2, "Late Warm Component Is Omitted from Finalization Barrier".
- Source: MC. `spec/output/MC_hunt_scenario2_bfs.out` reports `Error: Invariant NoPrematureFinalization is violated` and contains a 14-state counterexample.
- Only the supplied counterexample output and MC-2 implementation sites were inspected; no TLA+ specification, `bug-report.md`, other finding, shared confirmed-bug file, or repair-request queue was opened.
- Checkout: `sonic-net/sonic-buildimage` at `9914efc028c3835c564eb0c6028a019991b5c422`.
- The checkout was already dirty. The finalizer has Specula trace instrumentation relative to `HEAD`; the production control flow cited below is unchanged. The existing changes were preserved.

## Step 1 — code audit

### Relevant code and entry point

- `files/image_config/warmboot-finalizer/warmboot-finalizer.service:7-8` declares a oneshot service whose normal entry point is `/usr/local/bin/finalize-warmboot.sh`.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:18-29` initializes built-in reconciliation components, runs `find /etc/sonic/ -iname '*_reconcile' -type f` once, and copies each discovered file's contents into the process-local `RECONCILE_COMPONENTS` associative array. There is no later `find`, inotify watch, generation counter, or registration freeze.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:65-91` derives `ASIC_SERVICE_LIST` and `GLOBAL_SERVICE_LIST` once from that associative array, before the script waits for the database or starts any worker.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:93-114` derives a worker's component list only from the already-populated `RECONCILE_COMPONENTS` array and the enabled state of services already present in its static service-list argument.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:151-174` polls `WARM_RESTART_TABLE|<component>.state` only for names already in the worker's current list.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:255-288` waits on that list (or times out); it never re-discovers registrations.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:297-334` starts namespace/global workers, waits for those workers, then calls `finalize_global`.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:183-187` implements warm finalization as `config warm_restart disable -n "$NETNS"`.

### Normal producer and call chain

The `_reconcile` files are not arbitrary test inputs. The SONiC Package Manager is a runtime public interface and its pinned source at the buildimage submodule SHA `b17c48270c15fc6d5c81a23d97e2946cd7059dcd` establishes this normal call chain:

1. Public CLI: `spm install --enable <package>` / `sonic-package-manager install --enable <package>` (`sonic_package_manager/main.py:394-425`, console entry points in `setup.py:237-238`).
2. `PackageManager.install()` calls `install_from_source()` for a new package (`sonic_package_manager/manager.py:350-377`).
3. `install_from_source()` calls `self.service_creator.create(package, ...)` (`manager.py:428-434`).
4. `ServiceCreator.create()` calls `generate_service_reconciliation_file(package)` before registering the feature (`sonic_package_manager/service_creator/creator.py:163-195`).
5. `generate_service_reconciliation_file()` writes `/etc/sonic/<service>_reconcile` from manifest processes whose `reconciles` field is true (`creator.py:518-532`).

Primary-source URLs:

- https://github.com/sonic-net/sonic-utilities/blob/b17c48270c15fc6d5c81a23d97e2946cd7059dcd/sonic_package_manager/main.py#L394-L460
- https://github.com/sonic-net/sonic-utilities/blob/b17c48270c15fc6d5c81a23d97e2946cd7059dcd/sonic_package_manager/manager.py#L350-L461
- https://github.com/sonic-net/sonic-utilities/blob/b17c48270c15fc6d5c81a23d97e2946cd7059dcd/sonic_package_manager/service_creator/creator.py#L163-L195
- https://github.com/sonic-net/sonic-utilities/blob/b17c48270c15fc6d5c81a23d97e2946cd7059dcd/sonic_package_manager/service_creator/creator.py#L518-L532

`PackageManager` serializes package operations with its own file lock (`manager.py:91-100`), but the finalizer neither acquires that lock nor otherwise coordinates with registration. Therefore a package install/update can create or replace a reconcile file after the finalizer's discovery and service-list snapshots.

### Concrete trigger scenario

1. A warm reboot is active and `warmboot-finalizer.service` starts.
2. The finalizer performs its one-time `/etc/sonic/*_reconcile` discovery and computes static ASIC/global service lists.
3. Concurrent normal administration invokes `spm install --enable <warm-sensitive-package>` (or an update of such a package). The package manager writes `/etc/sonic/<service>_reconcile` and registers/enables the feature. Its reconciling process has not yet reported `state=reconciled` for the current warm-reboot epoch.
4. Components in the finalizer's static lists finish. The late component is absent from every list, so no worker queries its state.
5. The parent `wait` returns and `finalize_global` disables the system warm-restart flag.
6. A real consumer sees the wrong global outcome: `files/scripts/service_mgmt.sh:8-16` reads `WARM_RESTART_ENABLE_TABLE|system`; `files/scripts/service_mgmt.sh:61-82` consequently uses the ordinary `stop` path rather than the warm `kill` path for a service whose reconciliation is still incomplete. Separately, current SONiC `config reload` treats the same flag as the guard that prevents reload while warm boot is in progress (`sonic-utilities/config/main.py:2255-2272` at the pinned SHA).

### Counterexample correspondence

- State 12: both namespace finalization epochs equal boot epoch 1, global finalization is still 0, `required = {}`, and `restoredEpoch[orchagent] = 0`.
- State 13: the late registration transition changes `required` to `{orchagent}` after both namespaces finalized; the component remains unrestored.
- State 14: `finalizedEpoch` becomes 1 while `restoredEpoch[orchagent]` remains 0, violating `NoPrematureFinalization`.

The implementation's one-time file discovery/static lists correspond to the empty barrier in State 12; a normal package-manager reconcile-file creation corresponds to State 13; `finalize_global` corresponds to State 14.

### Safeguards and downstream behavior found

- The finalizer waits for database readiness (`finalize-warmboot.sh:133-148`) but does not freeze package registration.
- Enabled-state filtering (`finalize-warmboot.sh:99-102`) applies only to services already in the static list; it cannot add a newly registered service.
- `wait` at line 332 joins only workers created from those static lists.
- The five-minute loop is not a repair: even known incomplete components are logged and finalization continues (`finalize-warmboot.sh:274-288`).
- `config warm_restart disable` writes the system flag to false; the pinned CLI implementation has no loopback/rescan/resend (`sonic-utilities/config/main.py:4127-4147`). No code was found that re-enables the current epoch when a late reconcile file appears.
- The false system flag is permanent for the current boot epoch unless another explicit command changes it. A future warm-reboot request is a new epoch, not a repair of this one.

## Step 2 — developer-knowledge search

### History and blame

- Commit `3a2b8c6ba5d6e05630b0897b32d862d3cb64aa4a` / PR #7286 introduced `_reconcile` discovery. Its stated intent was to support warm/fast reboot for extension packages. The implementation added only the startup `find` loop. https://github.com/sonic-net/sonic-buildimage/pull/7286
- Commit `054f5b7a5372cddc7a00c9b7bcf5eb5b129b5863` / PR #6454 made the finalizer wait only for enabled components. Issue #6383 and PR #6454 concern the distinct mechanism of waiting five minutes for a disabled component, not registration after discovery. https://github.com/sonic-net/sonic-buildimage/issues/6383 and https://github.com/sonic-net/sonic-buildimage/pull/6454
- Commit `7688773a3769b4b340cdcf26cf6e150abe67f2f8` / PR #25072 (merged 2026-04-12) added multi-ASIC workers and states the intent to wait for per-ASIC reconciliation and disable namespace/global flags after finalization. It retained the one-time discovery and static service lists. https://github.com/sonic-net/sonic-buildimage/pull/25072
- No TODO/FIXME/comment documents late registration as supported, tolerated, prohibited, or intentionally ignored.

### Tests

- Repository searches found no test of `finalize-warmboot.sh`, no late `_reconcile` creation test, and no assertion that package registration is frozen while the finalizer runs.
- The pinned sonic-utilities warm-restart tests assert that `config warm_restart disable` changes the system flag to false (`tests/test_warm_restart.py:88-97`) and, on multi-ASIC, changes each selected namespace to false (`:111-137`). They do not provide a re-enable or rescan safeguard.

## Step 3 — known status / precedent

Novelty: **NEW**.

Searches performed on 2026-08-03:

- GitHub issue search in `sonic-net/sonic-buildimage` for `warmboot finalizer reconcile component` (open and closed issues). Results included #28787, #27108, #27700, #13117, #3008, #6772, #6509, #6383, #5890, and #5244; none reports reconcile-file creation after the startup snapshot.
- GitHub PR search in `sonic-net/sonic-buildimage` for `warmboot finalizer reconcile component` (open, closed, and merged PRs). Results included #11477 and #6454 plus unrelated config-migration reverts; none reports or fixes this mechanism.
- GitHub closed-PR search for `_reconcile` returned no match, and `sonic-net/sonic-utilities` PR search for `generate_service_reconciliation_file` returned no match.
- Local upstream history through `origin/master`, including recent merged work, was searched for changes to `finalize-warmboot.sh` and messages matching warm-finalizer/reconciliation terms. The recent relevant changes were #25072 (multi-ASIC) and #25266 (fast-reboot timer cleanup); neither freezes/version-controls registration or re-scans components.
- The exact introduction (#7286), the enabled-component precedent (#6454/#6383), and the recently merged multi-ASIC rewrite (#25072) were individually re-checked. They are related context, not prior reports of the same late-registration/static-barrier defect.

No upstream issue, merged/closed PR, advisory, or commit message found in these searches reports this same mechanism at this site.
