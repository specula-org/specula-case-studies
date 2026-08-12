# MC-4 investigation evidence

## Scope and provenance

- Source: real model-checking counterexample, `spec/output/MC_hunt_scenario4_bfs.out`.
- The output reports `Invariant SnapshotSafety is violated` and reaches state 7,
  `MCLeavePartialSnapshot(asic0)`, after state 6 has pruned the snapshot.  State 7
  records `snapshotValidity[asic0] = "valid"`, `copyComplete[asic0] = FALSE`, and
  `snapshotFailure = 1`.
- The main checkout pins `src/sonic-utilities` to
  `b17c48270c15fc6d5c81a23d97e2946cd7059dcd`; the submodule was initialized at
  exactly that SHA for this investigation.
- The main worktree already contained unrelated sonic-sysmgr/finalizer changes.
  They were not modified or used by this investigation.

## Step 1: code audit

### Cited sites and behavior

- `src/sonic-utilities/scripts/fast-reboot:452-506` defines
  `backup_database`.  For advanced reboot types it irreversibly flushes ASIC,
  COUNTERS, and FLEX_COUNTER databases at lines 456-461; for fast reboot it also
  flushes RESTAPI_DB at lines 463-466; it destructively filters STATE_DB at lines
  471-496.
- `src/sonic-utilities/scripts/fast-reboot:501` publishes directly to the final
  warm-restore directory with
  `docker cp database$DEV:/var/lib/$target_db_inst/$REDIS_FILE $warm_dir`.
  It uses neither a temporary filename nor a rename and does not inspect this
  command's status.  The check at lines 502-505 concerns only timeout while
  removing the source dump inside the database container.
- `src/sonic-utilities/scripts/fast-reboot:1163-1165` explicitly declares the
  flow committed and disables `set -e` before the backup.  The main entry point
  invokes `execute_in_namespaces all backup_database` at line 1219 and continues
  through reboot even if the `docker cp` at line 501 fails.
- `files/build_templates/docker_image_ctl.j2:102-115` defines the database
  container's `preStartAction`.  At lines 107-109, any regular
  `/host/warmboot$DEV/dump.rdb` under a warm/fast boot type is copied into the
  Redis data directory.  There is no checksum, RDB parser, epoch, manifest, or
  copy-completion check.
- `dockers/docker-database/supervisord.conf.j2:49` removes only an empty RDB
  (`[[ -s ... ]] || rm`).  A non-empty partial RDB survives and is passed to the
  real `/usr/bin/redis-server` consumer.
- `files/build_templates/docker_image_ctl.j2:291-294` then waits without a
  bounded retry for both host and container Redis PINGs.  The warm artifact is
  moved to `.old` only after those PINGs succeed, at lines 296-298.
- `dockers/docker-database/supervisord.conf.j2:53` sets `autorestart=false` for
  Redis.  No sync, resend, fallback restore, or integrity guard repairs the
  artifact after Redis rejects it.

### Call chain and reachability

Normal public-operation chain:

1. An administrator or reboot service invokes the installed `fast-reboot`,
   `warm-reboot`, or `express-reboot` entry point.  Main processing begins at
   `src/sonic-utilities/scripts/fast-reboot:922`.
2. The script pauses orchagent, marks itself committed, stops services, prunes
   Redis state, and invokes the public `docker cp` operation at line 501.
3. A Docker daemon/client termination, host fault, or transport interruption
   after destination creation but before the archive completes makes `docker cp`
   return failure.  Because the script is in `set +e` mode and does not check that
   status, reboot proceeds.
4. On the next warm/fast boot, the database container's normal `start` path calls
   `preStartAction` (`files/build_templates/docker_image_ctl.j2:546-564` for an
   existing container, or lines 873-879 for a new one).
5. The existence-only gate copies the partial RDB into Redis.  The non-empty-only
   supervisor guard accepts it; Redis rejects it; the start script waits for PONG.

This sequence instantiates the counterexample's state-6 destructive prune and
state-7 `MCLeavePartialSnapshot(asic0)` transition without constructing an
illegal precondition.

### Safeguards found

- The Redis supervisor command now removes zero-byte RDB files, but not non-empty
  partial files (`dockers/docker-database/supervisord.conf.j2:49`).
- The restore decision checks `-f`, while the later supervisor check checks `-s`;
  neither validates Redis format or copy completion.
- The two `sync` calls at `src/sonic-utilities/scripts/fast-reboot:1247-1250`
  occur after publication and cannot turn an incomplete file into a valid one.
- The `.old` move is after successful PING, so it cannot clear a file that keeps
  Redis from reaching PONG.
- No caller checks backup success, rolls the destructive pruning back, retries
  the copy, or falls back to cold initialization.

## Step 2: developer-knowledge evidence

- Blame shows direct restore publication was introduced by sonic-buildimage
  commit `a2e3d2fcea` and direct backup publication by sonic-utilities history
  predating the current multi-ASIC adjustment; no nearby TODO/FIXME documents
  acceptance of incomplete snapshots.
- sonic-utilities commit `ae20defd2` / PR #3342 moved backup until after
  syncd/swss stop because a rare late FDB write produced a Redis state that made
  syncd crash on restart.  This shows the saved DB is intended to be restart-safe,
  but the change did not add atomic publication or copy-status validation.
- sonic-buildimage PR [#2287](https://github.com/sonic-net/sonic-buildimage/pull/2287)
  introduced loading the database saved by Redis and described it as a disruptive
  change; it does not discuss interrupted copies.
- Recently merged sonic-buildimage PR
  [#28541](https://github.com/sonic-net/sonic-buildimage/pull/28541) documents a
  different producer race: a repeated `preStartAction` injected a zero-byte RDB,
  Redis aborted with `Short read ... Unexpected EOF`, and database.service failed.
  Its fix added the current `-s` guard at supervisor line 49.  This is strong
  developer evidence that an invalid RDB has a real database-service consequence,
  while also showing that the present safeguard addresses zero-byte files only.
- No repository test was found for failed/interrupted publication at
  `fast-reboot:501`, for RDB integrity before restore, or for a non-empty partial
  RDB.  Existing source searches for `backup_database`, `dump.rdb`, and
  `preStartAction` found no test asserting this behavior is intended.

## Step 3: known-status and precedent search

Issue and PR searches covered open and closed results in both upstream
repositories, including recently merged/closed PRs.  Queries included
`dump.rdb`, `docker cp warm-reboot`, `snapshot warm-reboot corrupt`, `atomic
dump.rdb`, `Short read Redis`, `Unexpected EOF dump.rdb`, and `backup database
failed`.

- sonic-buildimage issue [#6811](https://github.com/sonic-net/sonic-buildimage/issues/6811)
  reports a missing database path caused by a `SonicDBConfig.get_port` exception;
  it is not an interrupted final-path copy and not the same mechanism.
- sonic-buildimage issue [#5439](https://github.com/sonic-net/sonic-buildimage/issues/5439)
  reports connection-refused errors during warmboot without a partial RDB or the
  cited publication site.
- PR [#28541](https://github.com/sonic-net/sonic-buildimage/pull/28541) is the
  closest and was specifically re-checked because it merged recently.  It reports
  a zero-byte file created by a second restore-side `preStartAction`, not a
  non-empty partial artifact left by failure of backup-side `docker cp` at
  `fast-reboot:501`; its fix does not reject the latter.
- Local full-history `git log -S` and `git blame` searches at both the backup and
  restore sites found no issue/PR/commit describing interrupted copy publication,
  atomic rename, a completion manifest, or integrity validation at this site.

Known-status evidence therefore records **Novelty: NEW**: no upstream issue or
open/recently closed PR found reports this same mechanism at this same backup
publication site.
