# MC-3 investigation

## Scope and provenance

- Finding source is model checking, as supplied by the dispatcher. The model/specification and other finding reports were not opened.
- Target superproject: `9914efc028c3835c564eb0c6028a019991b5c422`.
- `sonic-utilities`: `b17c48270c15fc6d5c81a23d97e2946cd7059dcd`.
- `sonic-swss`: `b20a59691baca9ff6e4fbe46a7cd8223a3419117`.
- The executable DVS image reports `master.1179080-5bf45fc83`, built 2026-07-30. The target `sonic-swss` revision (2026-07-28) is an ancestor of the then-current upstream master, and no relevant freeze/reconciliation change exists between the target and current master.

## Step 1 — code audit

### Cited shutdown site and call chain

1. The normal operator entry point is the installed `fast-reboot`/`warm-reboot` script. It parses the invoked basename as the reboot type (`src/sonic-utilities/scripts/fast-reboot:10-12`) and enters its main sequence at line 922.
2. For warm, fast, express, and fast-fast reboot, the script calls `execute_in_namespaces asic pause_orchagent` (`src/sonic-utilities/scripts/fast-reboot:1154-1156`).
3. `pause_orchagent` invokes `/usr/bin/orchagent_restart_check -w 2000 -r 5` inside the real `swss` container (`src/sonic-utilities/scripts/fast-reboot:1130-1147`). A failure exits unless `FORCE=yes`; multi-ASIC operation unconditionally sets `FORCE=yes` after this point (`:1149-1152`).
4. `orchagent_restart_check` sends a normal `RESTARTCHECK` notification and returns success upon a `READY` reply (`src/sonic-swss/orchagent/orchagent_restart_check.cpp:108-140`).
5. `SwitchOrch` turns that notification into `checkRestartReadyState=true` (`src/sonic-swss/orchagent/switchorch.cpp:1577-1601`). `OrchDaemon` checks its current task maps, replies, flushes, and enters `freezeAndHeartBeat(UINT_MAX, ...)`, whose loop no longer selects database consumers (`src/sonic-swss/orchagent/orchdaemon.cpp:1181-1222,1384-1415,1440-1451`).
6. Only after the successful freeze acknowledgement does the reboot script stop timers and then stop the configured services (`src/sonic-utilities/scripts/fast-reboot:1187-1217`). Database backup occurs after the service-stop loop (`:1219`). There is no operator/configuration admission fence between `pause_orchagent` and service shutdown.

The finding's supplied line numbers map to surrounding shutdown work in this revision, but the precise freeze boundary is `fast-reboot:1137/1155` and the service-stop boundary is `fast-reboot:1206-1219`.

### Concrete reachable trigger

Normal API sequence used for reproduction:

1. `config interface shutdown Ethernet0` establishes an ASIC-visible `admin_status=down` baseline.
2. `config warm_restart enable swss` enables the supported warm-restart path.
3. `/usr/bin/orchagent_restart_check -w 2000 -r 5` returns `RESTARTCHECK succeeded` and freezes `orchagent`.
4. A concurrent operator issues the ordinary API `config interface startup Ethernet0` after the freeze acknowledgement but before SWSS shutdown.
5. `CONFIG_DB PORT|Ethernet0 admin_status` becomes `up`, while the ASIC-facing state remains `false` because `orchagent` is frozen.
6. SWSS follows its normal warm-restart stop/start lifecycle.

This route is reachable without state injection or source modification. The public CLI handler is `src/sonic-utilities/config/main.py:5325-5350`. `PortMgr` consumes the `PORT` ConfigDB table and writes the resulting `admin_status` into APP_DB (`src/sonic-swss/cfgmgr/portmgr.cpp:14-21,60-72,138-249`). `PortsOrch` is the real consumer that sets `SAI_PORT_ATTR_ADMIN_STATE` (`src/sonic-swss/orchagent/portsorch.cpp:2300-2320,5646-5667`).

### Safeguards and downstream mechanisms recorded

- The restart check only tests the task maps visible at the check instant (`orchdaemon.cpp:1384-1415`); it does not fence later producers.
- Non-force single-ASIC operation aborts on a failed check (`fast-reboot:1138-1145`). The `-f` path and multi-ASIC path can proceed despite failure (`:1140-1152`).
- Service stop followed by database backup provides a later quiescence/persistence boundary (`fast-reboot:1206-1219`).
- CONFIG_DB is durable across the SWSS restart. On startup, `portmgrd` re-reads the configured value and emits it to APP_DB; `PortsOrch` then applies it to SAI. Phase 2 explicitly asserted that this mechanism fired: the pre-restart ASIC value was `false` and the post-restart value became `true`.

## Step 2 — developer-knowledge evidence

- The restart-check source says its intent is to ensure a deterministic state can be restored and to "freeze if everything is ok" (`orchagent_restart_check.cpp:31-42`).
- The main loop says the successful check should "stop processing any new db data" but finish data already in the ring (`orchdaemon.cpp:1189-1199`).
- The readiness comment says the current criterion is only that no pending task exists in any orch agent and notes that further consideration is needed (`orchdaemon.cpp:1378-1383`).
- Existing test `src/sonic-swss/tests/test_warm_reboot.py:943-967` performs ConfigDB/APPL_DB deletions after a successful freeze before restarting SWSS. It verifies that the process is frozen, but does not assert a lasting wrong outcome from those post-freeze mutations.
- Merged sonic-utilities PR [#3342](https://github.com/sonic-net/sonic-utilities/pull/3342), commit `0e6a55ef`, records a different queued-write race: syncd could write an FDB event after ASIC_DB was flushed. Its fix moved database backup until after syncd/SWSS stop. This is a causal-quiescence precedent at a different producer/boundary, not a report of this ConfigDB/orchagent-freeze mechanism.
- Recently merged PR [#4711](https://github.com/sonic-net/sonic-utilities/pull/4711), commit `f49d6f45`, blocks `config reload` while warm/fast boot finalization is already in progress to prevent an unsafe syncd teardown. It does not fence ordinary configuration commands during the pre-shutdown freeze interval and reports a different mechanism/site.
- PR [#4297](https://github.com/sonic-net/sonic-utilities/pull/4297) concerns error handling for faulty ASICs after freeze; it does not report a configuration update crossing the boundary.

## Step 3 — known-status / precedent

- Direct upstream tracker searches covered open/closed issues and PRs in `sonic-net/sonic-utilities` and `sonic-net/sonic-swss` for `orchagent freeze configuration race`, `orchagent_restart_check`, `RESTARTCHECK freeze update`, and broader `warm-reboot`/`warm restart` configuration terms. The exact-mechanism searches returned no results.
- Recently merged/closed history was also searched locally through 2026-08-03 using `git log`, `git log -S`, and `git log -G` over `fast-reboot`, `orchagent_restart_check`, `orchdaemon`, and freeze/restart terms. The relevant but non-duplicate precedents are #3342, #4711, and #4297 above.
- No public issue, PR, CVE, advisory, or permitted dataset citation was found that reports this same configuration-producer/orchagent-freeze mechanism at this site.

**Novelty evidence: NEW.** This is an evidence result, not a default: exact and broad searches included issues plus recently merged/closed PRs, and the closest reports concern different mechanisms.
