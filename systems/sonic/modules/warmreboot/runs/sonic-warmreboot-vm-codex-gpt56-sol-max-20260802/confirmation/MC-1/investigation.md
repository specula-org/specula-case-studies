# MC-1 investigation record

## Scope and provenance

- Source checkout: `sonic-buildimage` `d5a2f4d1df9fdf71e48777905cd3f032b3d78a94`, with `src/sonic-utilities` at `1462eff8982c69dcc262ffeac408ae7797689642` (2026-07-29).
- Supplied model-checking output: `spec/output/MC_hunt_scenario1_bfs.out`. TLC reports a real `PhaseMonotonicity` violation with a 13-state behavior.
- Only the supplied MC-1 counterexample output was inspected; no other spec, finding, or report file was opened.

## Step 1: code audit

### Relevant code

- `src/sonic-utilities/scripts/fast-reboot:883-894`: `check_warm_restart_in_progress()` enumerates `WARM_RESTART_ENABLE_TABLE|*` and separately reads each `enable` field. It is a read-only check and has no lock or atomic claim operation.
- `src/sonic-utilities/scripts/fast-reboot:972-977`: the public `fast-reboot` entry path calls that check, installs `clear_boot` as an exit/signal trap, then separately writes the fast and warm shared flags true.
- `src/sonic-utilities/scripts/fast-reboot:341-370`: `clear_boot()` unconditionally runs `config warm_restart disable` and, for fast reboot, writes `FAST_RESTART_ENABLE_TABLE|system.enable=false`. It has no caller identity, generation, epoch, or compare-and-set condition.
- `src/sonic-utilities/config/main.py:4091-4134`: `config warm_restart enable/disable` are plain writes of `true`/`false` to the same shared `WARM_RESTART_ENABLE_TABLE|<module>` field. No ownership metadata is stored.
- `src/sonic-utilities/scripts/fast-reboot:1149-1180`: after pausing orchagent, the script declares itself fully committed, performs fast-route deletion, and disables cleanup traps. There is no ownership or flag revalidation before this point.
- `src/sonic-utilities/scripts/fast-reboot:1206-1219` and `:170-217`: irreversible shutdown calls `systemctl stop` for configured services.
- `files/scripts/service_mgmt.sh:61-82`: the real service stop consumer reads both shared flags. If both are not `true`, it calls `/usr/bin/${SERVICE}.sh stop`; when either indicates warm/fast reboot, it calls `kill` instead. The cold `stop` branch is therefore an observable downstream consequence, not merely an intermediate flag snapshot.
- `src/sonic-utilities/sonic-utilities-data/templates/service_mgmt.sh.j2:40-60,114-130` contains the equivalent generated-package consumer behavior.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:224-234`: when both flags are false, the finalizer exits. It does not restore a live attempt's flags.

The finding's supplied line numbers correspond only approximately to this pinned checkout (for example, supplied line 978 is the end of the fast-reboot admission case here). The mechanism is at the exact functions and current lines above.

### Public call chain and reachability

Normal root CLI invocation follows:

`fast-reboot` -> `check_warm_restart_in_progress` -> install `clear_boot` trap -> publish fast/warm flags -> prechecks -> `pause_orchagent` -> committed shutdown -> `systemctl stop <service>` -> service `ExecStop` script -> `check_warm_boot`/`check_fast_boot` -> cold `stop` or warm/fast `kill`.

There is no reboot-wide `flock`, lock file, DB transaction, atomic Redis `SET NX`, owner token, or generation check in this chain. The `swss.sh` lock found at `files/scripts/swss.sh:35-50` serializes only that service's own state changes and does not serialize reboot admission or protect the global flags.

### Counterexample mapping and concrete trigger

The supplied trace maps to reachable operations as follows:

1. States 2-3: two users/processes invoke the normal `fast-reboot`/`warm-reboot` entry point.
2. States 4-5: both complete the read-only in-progress check while the shared flag is false.
3. State 6: caller 1 publishes the shared reboot flag.
4. State 7: caller 1 takes a normal failure/cancellation cleanup path and clears it.
5. State 8: caller 2 publishes its newer flag.
6. State 9: an older caller-1 cleanup clears the same global flag after caller 2's publication.
7. States 12-13: caller 2 passes freeze and enters irreversible work with the flag false.

At code level the natural adversarial sequence is: start two root CLI processes close together; let both scans observe false; let each publish; make the older process exit through any ordinary pre-commit failure (or cancellation) after the newer publication; its EXIT trap clears both shared flags; allow the newer process to continue. The newer process does not republish or revalidate. Its service consumer consequently chooses cold `stop` rather than warm/fast `kill`.

Safeguards recorded for reproduction:

- The current read-only scan rejects a caller only when it observes an already-true warm flag; it does not close the check-to-publish window.
- The EXIT trap is disabled only after the calling process commits; it does not scope cleanup from another process.
- Service scripts independently read the flags, but that is the consumer that converts erasure into cold behavior, not a mask.
- The finalizer exits when both flags are false and does not repair the state.

## Step 2: developer-knowledge evidence

- `git blame` attributes the scan to merged PR [sonic-utilities#1460](https://github.com/sonic-net/sonic-utilities/pull/1460). Its commit message says the check was added to avoid another overlapping warm reboot because the flag can be reset and components risk a cold reboot. This is direct developer evidence that false flags have a real cold-reboot consequence.
- The older open issue [sonic-utilities#499](https://github.com/sonic-net/sonic-utilities/issues/499) gives the sequence `warm-reboot`; another `warm-reboot` before finalization; the older finalizer disables the flag; the second boot starts non-warm. Maintainer discussion says a new warm reboot should be prevented until the previous one finalizes.
- Existing unit tests cover individual warm flag enable/disable (`tests/test_warm_restart.py:77-137`) and only the help path of `fast-reboot` (`tests/fast_reboot_test.py:8-28`). No existing test exercises two concurrent reboot callers or scoped cleanup.
- Local history searches using `git log -S` found the admission guard in #1460 and no later atomic admission, ownership token, or scoped-cleanup change. `git blame` shows unconditional cleanup has existed since the original flow, with the fast flag write added in 2023.

## Step 3: known-status and recent precedent check

- Tracker searches covered open/closed issues and PRs in `sonic-net/sonic-utilities`, `sonic-net/sonic-buildimage`, `sonic-net/SONiC`, and `sonic-net/sonic-mgmt` using `fast-reboot`, `warm-reboot`, `concurrent`, `race`, `check_warm_restart_in_progress`, `clear_boot`, and `reboot in progress` terms.
- The exact same shared-flag reset/cold-component defect at this admission site was publicly reported by merged [sonic-utilities#1460](https://github.com/sonic-net/sonic-utilities/pull/1460), with [sonic-utilities#499](https://github.com/sonic-net/sonic-utilities/issues/499) as an earlier overlapping-reboot report. The merged fix is only a read-before-write guard; this checkout still has the simultaneous-check TOCTOU and unscoped cleanup, so fix status for MC-1's mechanism is **unfixed**.
- Recently merged/closed work was rechecked: remote `master` through `b17c4827` (2026-07-30) has no `fast-reboot` diff beyond this checkout; recently merged PRs #4711/#4721 guard `config reload`, not concurrent reboot admission; open/closed #4718/#4719 persist a reboot-cause marker and do not add ownership or atomic acquisition.

Known-status evidence to carry into Phase 2: `KNOWN (cite: https://github.com/sonic-net/sonic-utilities/pull/1460; fix-status: unfixed)`. Because the source is an actual MC counterexample, known status does not pre-filter or skip reproduction.
