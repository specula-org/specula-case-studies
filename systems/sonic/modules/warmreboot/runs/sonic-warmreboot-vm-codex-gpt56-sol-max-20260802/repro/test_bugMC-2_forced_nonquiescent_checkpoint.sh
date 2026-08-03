#!/usr/bin/env bash
# MC-2 reproduction attempt.
#
# The test walks Level 0 -> Level 3 in order.  Level 2 uses a reachable,
# post-consumer-pop APPL_DB route state (the state produced by the public
# ProducerStateTable sequence in sonic-swss/tests/test_warm_reboot.py:925-936)
# and runs the unmodified public warm-reboot entry point inside an isolated
# user/mount namespace.  Redis is real; SONiC service commands are narrowly
# shimmed because this host has no usable SONiC/DVS runtime.  Consequently the
# test can prove the failed freeze is converted to success and the bad Redis
# state is checkpointed, but it deliberately does not claim to have observed
# the unavailable orchagent warm-restore consumer.

set -Eeuo pipefail

WORKTREE=/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2/worktree
FINDING_DIR=/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/confirmation/MC-2
REPRO_DIR=/users/Pial/Specula/runs/sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/warmreboot/.specula-output/repro
FAST_REBOOT="$WORKTREE/src/sonic-utilities/scripts/fast-reboot"

for command_name in bash git make redis-cli redis-server timeout unshare mount chroot; do
    command -v "$command_name" >/dev/null || {
        echo "FATAL missing-command=$command_name"
        exit 1
    }
done

test -x "$FAST_REBOOT"
# Redis UNIX-domain socket paths are limited to roughly 108 bytes, while the
# caller's absolute repro path is intentionally very long. Keep ephemeral
# runtime state under /tmp; the durable test itself remains in REPRO_DIR.
TMP_DIR=$(mktemp -d /tmp/MC-2-repro.XXXXXX)
ROOT="$TMP_DIR/root"
PRIMARY_SOCKETS=()
RESTORE_SOCKETS=()

cleanup()
{
    local socket
    for socket in "${PRIMARY_SOCKETS[@]}" "${RESTORE_SOCKETS[@]}"; do
        if [[ -n "$socket" && -S "$socket" ]]; then
            redis-cli -s "$socket" shutdown nosave >/dev/null 2>&1 || true
        fi
    done
    # The path is created by the fixed mktemp template above.
    if [[ "${KEEP_REPRO_TMP:-0}" != 1 && -n "${TMP_DIR:-}" && "$TMP_DIR" == /tmp/MC-2-repro.* ]]; then
        find "$TMP_DIR" -depth -delete 2>/dev/null || true
    elif [[ "${KEEP_REPRO_TMP:-0}" == 1 ]]; then
        echo "DEBUG retained_tmp=$TMP_DIR"
    fi
}
trap cleanup EXIT

wait_for_redis()
{
    local socket=$1
    local attempt
    for attempt in $(seq 1 100); do
        if redis-cli -s "$socket" ping 2>/dev/null | grep -qx PONG; then
            return 0
        fi
        /bin/sleep 0.02
    done
    echo "FATAL redis-not-ready=$socket"
    return 1
}

echo "MC-2 reproduction: forced failed freeze before Redis checkpoint"
echo "source_sha=$(git -C "$WORKTREE" rev-parse HEAD)"
echo "sonic_utilities_sha=$(git -C "$WORKTREE/src/sonic-utilities" rev-parse HEAD)"
echo "sonic_swss_sha=$(git -C "$WORKTREE/src/sonic-swss" rev-parse HEAD)"

mkdir -p \
    "$ROOT/usr/bin" "$ROOT/usr/lib" "$ROOT/usr/lib64" "$ROOT/usr/sbin" \
    "$ROOT/usr/local/bin" "$ROOT/etc/alternatives" "$ROOT/etc/sonic" "$ROOT/usr/share/sonic/device/vs" \
    "$ROOT/host/reboot-cause" "$ROOT/host/image-current/boot" \
    "$ROOT/proc" "$ROOT/sys/kernel" "$ROOT/dev" "$ROOT/tmp" "$ROOT/var/log" \
    "$ROOT/shims" "$ROOT/test" "$ROOT/state"
chmod 1777 "$ROOT/tmp"
ln -s usr/bin "$ROOT/bin"
ln -s usr/lib "$ROOT/lib"
ln -s usr/lib64 "$ROOT/lib64"
ln -s usr/sbin "$ROOT/sbin"
: > "$ROOT/dev/null"
printf '%s\n' 'BOOT_IMAGE=/boot/vmlinuz-test ro console=ttyS0' > "$ROOT/proc/cmdline"
printf '%s\n' 0 > "$ROOT/sys/kernel/kexec_loaded"
printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' > "$ROOT/etc/passwd"
printf '%s\n' 'root:x:0:' > "$ROOT/etc/group"
printf '%s\n' 'hosts: files dns' > "$ROOT/etc/nsswitch.conf"
printf '%s\n' 'aboot_platform=repro' > "$ROOT/host/machine.conf"
printf '%s\n' 'console=ttyS0' > "$ROOT/host/image-current/kernel-cmdline"
: > "$ROOT/host/image-current/boot/vmlinuz-test"
: > "$ROOT/host/image-current/boot/initrd.img-test"
: > "$ROOT/etc/sonic/sonic_version.yml"
printf '%s\n' 'swss teamd syncd' > "$ROOT/etc/sonic/warm-reboot_order"

cat > "$ROOT/shims/sonic-shim" <<'SHIM'
#!/usr/bin/env bash
set -u
name=$(basename "$0")

record()
{
    if [[ -n "${REPRO_CALL_LOG:-}" ]]; then
        printf '%s\n' "$1" >> "$REPRO_CALL_LOG"
    fi
}

case "$name" in
    sonic-cfggen)
        if [[ " $* " == *' DEVICE_METADATA.localhost.platform '* ]]; then
            echo vs
        elif [[ " $* " == *' asic_type '* ]]; then
            echo vs
        fi
        ;;
    show)
        echo '{"hwsku":"Repro-HWSKU"}'
        ;;
    sonic-installer)
        if [[ "${1:-}" == list ]]; then
            echo 'Current: SONiC-OS-current'
            echo 'Next: SONiC-OS-current'
        fi
        ;;
    sonic-db-cli)
        joined=" $* "
        if [[ "$joined" == *' FEATURE|'*' has_per_asic_scope '* ]]; then
            echo false
        elif [[ "$joined" == *' FEATURE|'*' has_global_scope '* ]]; then
            echo true
        elif [[ "$joined" == *' hget '*' state '* ]]; then
            echo pre-shutdown-succeeded
        fi
        ;;
    docker)
        joined=" $* "
        if [[ "$joined" == *'orchagent_restart_check'* ]]; then
            record 'restart_check=failed'
            exit 1
        fi
        if [[ "${1:-}" == cp ]]; then
            destination=${@: -1}
            /usr/bin/cp /state/redis-dir/dump.rdb "$destination"
            record 'snapshot=copy'
        fi
        ;;
    centralize_database)
        /usr/bin/redis-cli -s "$REPRO_REDIS_SOCKET" SAVE >/dev/null
        record 'snapshot=save'
        echo redis
        ;;
    systemctl)
        case "${1:-}" in
            is-enabled)
                echo enabled
                ;;
            list-dependencies)
                echo sonic.target
                ;;
            list-units)
                ;;
            stop)
                record "service_stop=${2:-unknown}"
                ;;
        esac
        ;;
    pfcwd|config|logger|redis-cli|container|sync)
        ;;
    sleep)
        # Keep the public-entry-point harness fast. Level 3 uses /bin/sleep.
        ;;
    *)
        echo "unexpected shim invocation: $name $*" >&2
        exit 90
        ;;
esac
SHIM
chmod +x "$ROOT/shims/sonic-shim"
for shim_name in sonic-cfggen show sonic-installer sonic-db-cli docker centralize_database systemctl pfcwd config logger redis-cli container sync sleep; do
    ln -s sonic-shim "$ROOT/shims/$shim_name"
done

for local_script in check_db_integrity.py asic_config_check teamd_increase_retry_count.py; do
    cat > "$ROOT/usr/local/bin/$local_script" <<'NOOP'
#!/bin/sh
exit 0
NOOP
    chmod +x "$ROOT/usr/local/bin/$local_script"
done
cat > "$ROOT/usr/local/bin/lag_keepalive.py" <<'NOOP_PY'
raise SystemExit(0)
NOOP_PY

cat > "$ROOT/usr/sbin/kexec" <<'NOOP'
#!/bin/sh
exit 0
NOOP
cat > "$ROOT/usr/sbin/reboot" <<'REBOOT'
#!/bin/sh
printf '%s\n' 'reboot=called' >> "$REPRO_CALL_LOG"
exit 0
REBOOT
chmod +x "$ROOT/usr/sbin/kexec" "$ROOT/usr/sbin/reboot"

echo "LEVEL0 attempt=public-entrypoint-normal-operations"
cp "$FAST_REBOOT" "$TMP_DIR/warm-reboot"
chmod +x "$TMP_DIR/warm-reboot"
level0_help=$(PATH="$ROOT/shims:/usr/bin:/bin" "$TMP_DIR/warm-reboot" -h)
grep -F -- '-f    : force execution - ignore Orchagent RESTARTCHECK failure' <<< "$level0_help"
set +e
docker_info_output=$(docker info 2>&1)
docker_info_rc=$?
set -e
echo "LEVEL0 docker_info_rc=$docker_info_rc"
printf '%s\n' "$docker_info_output" | tail -n 2
echo "LEVEL0 result=BLOCKED reason=no-accessible-docker-daemon-or-SONiC-DVS-instance"

echo "LEVEL1 attempt=timing-assistance-at-restart-check-window"
echo "LEVEL1 result=BLOCKED reason=a-delay-cannot-supply-the-missing-swss/orchagent/syncd-runtime"

echo "ARTIFACT_PREFLIGHT target_dir=$WORKTREE/target"
if [[ -d "$WORKTREE/target" ]]; then
    artifact_count=$(find "$WORKTREE/target" -maxdepth 4 -type f \( -name orchagent -o -name 'docker-sonic-vs.gz' -o -name 'sonic-vs.img.gz' \) | wc -l)
else
    artifact_count=0
fi
echo "ARTIFACT_PREFLIGHT compatible_artifacts=$artifact_count"
echo "ARTIFACT_PREFLIGHT finding_local_prior_build_recipe=none"
echo "BOOTSTRAP_ATTEMPT command='make configure PLATFORM=vs' timeout=30s"
set +e
timeout -k 3s 30s make -C "$WORKTREE" configure PLATFORM=vs > "$TMP_DIR/configure.log" 2>&1
configure_rc=$?
set -e
echo "BOOTSTRAP_ATTEMPT configure_rc=$configure_rc"
tail -n 8 "$TMP_DIR/configure.log"
if [[ $configure_rc -eq 0 ]]; then
    echo "BOOTSTRAP_ATTEMPT command='make SONIC_BUILD_JOBS=2 target/sonic-vs.img.gz' timeout=30s"
    set +e
    timeout -k 3s 30s make -C "$WORKTREE" SONIC_BUILD_JOBS=2 target/sonic-vs.img.gz > "$TMP_DIR/image-build.log" 2>&1
    image_build_rc=$?
    set -e
    echo "BOOTSTRAP_ATTEMPT image_build_rc=$image_build_rc"
    tail -n 8 "$TMP_DIR/image-build.log"
fi

run_forced_checkpoint_case()
{
    local level=$1
    local source_script=$2
    local redis_dir="$ROOT/state/redis-dir"
    local socket="$ROOT/state/${level}.sock"
    local restore_socket="$ROOT/state/${level}-restore.sock"
    local call_log="$ROOT/state/calls.log"
    local flow_log="$TMP_DIR/${level}-flow.log"
    local snapshot="$ROOT/host/warmboot/dump.rdb"

    find "$redis_dir" -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    mkdir -p "$redis_dir" "$ROOT/host/warmboot"
    unlink "$snapshot" 2>/dev/null || true
    : > "$call_log"
    cp "$source_script" "$ROOT/test/warm-reboot"
    chmod +x "$ROOT/test/warm-reboot"

    redis-server \
        --port 0 \
        --unixsocket "$socket" \
        --unixsocketperm 700 \
        --dir "$redis_dir" \
        --dbfilename dump.rdb \
        --save '' \
        --appendonly no \
        --daemonize yes \
        --pidfile "$ROOT/state/${level}.pid"
    PRIMARY_SOCKETS+=("$socket")
    wait_for_redis "$socket"

    # Reachable post-pop state from ProducerStateTable(APP_ROUTE_TABLE_NAME):
    # the consumer has materialized the desired route hash but retains the
    # unresolved operation in its in-memory retry queue.
    redis-cli -s "$socket" HSET 'ROUTE_TABLE:3.3.3.0/24' \
        nexthop '20.0.0.1' ifname 'Ethernet0' >/dev/null
    echo "$level injected_precondition=ROUTE_TABLE:3.3.3.0/24 nexthop=20.0.0.1"

    set +e
    unshare --user --map-root-user --mount --pid --fork /bin/bash -c '
        set -e
        mount --make-rprivate /
        mount --bind /usr/bin "$1/usr/bin"
        mount --bind /usr/lib "$1/usr/lib"
        mount --bind /usr/lib64 "$1/usr/lib64"
        mount --bind /etc/alternatives "$1/etc/alternatives"
        exec chroot "$1" /usr/bin/env -i \
            PATH=/shims:/usr/bin:/bin \
            LC_ALL=C \
            REPRO_REDIS_SOCKET="/state/$2.sock" \
            REPRO_CALL_LOG=/state/calls.log \
            /test/warm-reboot -vfr
    ' repro-namespace "$ROOT" "$level" > "$flow_log" 2>&1
    local flow_rc=$?
    set -e

    echo "$level public_entrypoint_rc=$flow_rc"
    if [[ $flow_rc -ne 0 ]]; then
        echo "$level public_entrypoint_failure_output:"
        tail -n 40 "$flow_log" | sed 's/^/  /'
    fi
    grep -E 'Pausing orchagent|RESTARTCHECK failed|Ignoring orchagent pausing failure|Orchagent paused successfully|Stopping swss|Backing up database|Rebooting with' "$flow_log" || true
    echo "$level call_order:"
    sed 's/^/  /' "$call_log"

    test "$flow_rc" -eq 0
    test -f "$snapshot"
    grep -q '^restart_check=failed$' "$call_log"
    grep -q '^service_stop=swss$' "$call_log"
    grep -q '^snapshot=save$' "$call_log"
    grep -q '^reboot=called$' "$call_log"
    local restart_line stop_line save_line reboot_line
    restart_line=$(grep -n '^restart_check=failed$' "$call_log" | cut -d: -f1)
    stop_line=$(grep -n '^service_stop=swss$' "$call_log" | cut -d: -f1)
    save_line=$(grep -n '^snapshot=save$' "$call_log" | cut -d: -f1)
    reboot_line=$(grep -n '^reboot=called$' "$call_log" | cut -d: -f1)
    test "$restart_line" -lt "$stop_line"
    test "$stop_line" -lt "$save_line"
    test "$save_line" -lt "$reboot_line"

    redis-cli -s "$socket" shutdown nosave >/dev/null
    redis-server \
        --port 0 \
        --unixsocket "$restore_socket" \
        --unixsocketperm 700 \
        --dir "$ROOT/host/warmboot" \
        --dbfilename dump.rdb \
        --save '' \
        --appendonly no \
        --daemonize yes \
        --pidfile "$ROOT/state/${level}-restore.pid"
    RESTORE_SOCKETS+=("$restore_socket")
    wait_for_redis "$restore_socket"
    local restored_nexthop restored_ifname
    restored_nexthop=$(redis-cli -s "$restore_socket" HGET 'ROUTE_TABLE:3.3.3.0/24' nexthop)
    restored_ifname=$(redis-cli -s "$restore_socket" HGET 'ROUTE_TABLE:3.3.3.0/24' ifname)
    echo "$level restored_route=nexthop=$restored_nexthop ifname=$restored_ifname"
    test "$restored_nexthop" = '20.0.0.1'
    test "$restored_ifname" = 'Ethernet0'
    redis-cli -s "$restore_socket" shutdown nosave >/dev/null
}

echo "LEVEL2 attempt=reachable-state-injection-plus-unmodified-public-entrypoint"
run_forced_checkpoint_case LEVEL2 "$FAST_REBOOT"
echo "LEVEL2 result=CHECKPOINT_PATH_OBSERVED live_consumer=UNAVAILABLE"

echo "LEVEL3 attempt=timing-only-source-modification-plus-public-entrypoint"
awk '
    /execute_in_namespaces all backup_database/ && !inserted {
        print "/bin/sleep 0.05 # MC-2 Level-3 timing-only delay"
        inserted=1
    }
    { print }
' "$FAST_REBOOT" > "$TMP_DIR/warm-reboot-level3"
chmod +x "$TMP_DIR/warm-reboot-level3"
bash -n "$TMP_DIR/warm-reboot-level3"
echo "LEVEL3 modification='/bin/sleep 0.05 immediately before backup_database; no logic changed'"
run_forced_checkpoint_case LEVEL3 "$TMP_DIR/warm-reboot-level3"
echo "LEVEL3 result=CHECKPOINT_PATH_OBSERVED live_consumer=UNAVAILABLE"

echo "EXPECTED forced freeze failure must abort or remove the ASIC before SAVE"
echo "OBSERVED failed restart-check -> success return -> swss stop -> SAVE -> reboot"
echo "CONSUMER_STATUS argued-only: orchagent/main.cpp:1021-1025 cannot be executed without a SONiC/DVS image and Docker-daemon access"
echo "FINAL_ATTEMPT_RESULT=ENVIRONMENT_LIMITED"
