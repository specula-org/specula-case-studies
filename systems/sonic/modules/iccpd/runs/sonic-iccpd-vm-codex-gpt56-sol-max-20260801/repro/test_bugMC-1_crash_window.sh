#!/usr/bin/env bash
set -Eeuo pipefail

# MC-1: a real peer TCP close reaches scheduler_csm_socket_cleanup, then the
# local process dies before mlacp_peer_disconn_handler can publish/perform its
# cleanup.  This test uses clean upstream binaries, real kernel interfaces,
# the real peer protocol, real mclagsyncd, and real isolated Redis databases.
# GDB is used only at Level 1 to hold the admissible counterexample boundary;
# it neither changes state nor skips any instruction in the product.

WORKTREE="/users/Pial/Specula/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/iccpd/.specula-output/confirmation/MC-1/worktree"
EXPECTED_HEAD="9df8ccbf72c31948741b5554d09c38ac6c1ec6e9"
EXPECTED_SWSS="b20a59691baca9ff6e4fbe46a7cd8223a3419117"
SWSS_CACHE_REPO="/tmp/mc1-sonic-swss.pQLYKG/repo"
RUN_TMP="$(mktemp -d /tmp/mc1-repro.XXXXXX)"
CREATED_ETC_ICCPD=0
CREATED_SHARE_SWSS=0
declare -a ALL_NAMESPACES=()
declare -a BG_JOBS=()

fail() {
    printf 'TEST_FAILURE=%s\n' "$*" >&2
    for log in "$RUN_TMP"/*/*.log "$RUN_TMP"/*/*/*.log; do
        if [[ -f "$log" ]]; then
            printf 'LOG_TAIL=%s\n' "$log" >&2
            tail -n 25 "$log" >&2 || true
        fi
    done
    exit 1
}

kill_namespace_processes() {
    local ns="$1" pid
    if ! sudo -n ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
        return
    fi
    while read -r pid; do
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            sudo -n kill -KILL "$pid" 2>/dev/null || true
        fi
    done < <(sudo -n ip netns pids "$ns" 2>/dev/null || true)
}

destroy_lab() {
    local ns
    for ns in "$@"; do
        kill_namespace_processes "$ns"
        sudo -n ip netns del "$ns" 2>/dev/null || true
    done
}

cleanup() {
    local ns job
    set +e
    for ns in "${ALL_NAMESPACES[@]}"; do
        kill_namespace_processes "$ns"
        sudo -n ip netns del "$ns" 2>/dev/null || true
    done
    for job in "${BG_JOBS[@]}"; do
        if [[ "$job" =~ ^[0-9]+$ ]]; then
            kill -KILL "$job" 2>/dev/null || true
            wait "$job" 2>/dev/null || true
        fi
    done
    if (( CREATED_ETC_ICCPD == 1 )); then
        sudo -n rmdir -- /etc/iccpd 2>/dev/null || true
    fi
    if (( CREATED_SHARE_SWSS == 1 )); then
        sudo -n rmdir -- /usr/share/swss 2>/dev/null || true
    fi
    rm -rf -- "$RUN_TMP"
}
trap cleanup EXIT

command -v sudo >/dev/null || fail "sudo is required"
sudo -n true || fail "passwordless sudo is required for isolated namespaces"
for tool in git autoreconf make g++ redis-server redis-cli ip ss gdb timeout; do
    command -v "$tool" >/dev/null || fail "missing tool: $tool"
done

actual_head="$(git -C "$WORKTREE" rev-parse HEAD)"
[[ "$actual_head" == "$EXPECTED_HEAD" ]] || fail "unexpected sonic-buildimage HEAD $actual_head"
actual_swss="$(git -C "$WORKTREE" ls-tree HEAD src/sonic-swss | awk '{print $3}')"
[[ "$actual_swss" == "$EXPECTED_SWSS" ]] || fail "unexpected sonic-swss submodule $actual_swss"

mkdir -p "$RUN_TMP/clean"
git -C "$WORKTREE" archive HEAD src/iccpd | tar -x -C "$RUN_TMP/clean"
(
    cd "$RUN_TMP/clean/src/iccpd"
    timeout 45s autoreconf -fi >/dev/null 2>&1
    timeout 45s ./configure CFLAGS='-O0 -g' >/dev/null 2>&1
    timeout 60s make -j2 >/dev/null 2>&1
)
ICCPD_BIN="$RUN_TMP/clean/src/iccpd/src/iccpd"
[[ -x "$ICCPD_BIN" ]] || fail "clean iccpd build failed"

mkdir -p "$RUN_TMP/swss-src"
if [[ -d "$SWSS_CACHE_REPO/.git" ]] && git -C "$SWSS_CACHE_REPO" cat-file -e "$EXPECTED_SWSS^{commit}" 2>/dev/null; then
    git -C "$SWSS_CACHE_REPO" archive "$EXPECTED_SWSS" mclagsyncd | tar -x -C "$RUN_TMP/swss-src"
else
    git init -q "$RUN_TMP/swss-repo"
    git -C "$RUN_TMP/swss-repo" remote add origin https://github.com/sonic-net/sonic-swss.git
    timeout 60s git -C "$RUN_TMP/swss-repo" fetch -q --depth=1 origin "$EXPECTED_SWSS"
    git -C "$RUN_TMP/swss-repo" archive FETCH_HEAD mclagsyncd | tar -x -C "$RUN_TMP/swss-src"
fi
MCLAGSYNCD_BIN="$RUN_TMP/mclagsyncd"
timeout 60s g++ -std=c++11 -O0 -g \
    -I"$RUN_TMP/swss-src" -I/usr/local/include/swss -I/usr/include/libnl3 \
    -DCFG_MCLAG_UNIQUE_IP_TABLE_NAME='"MCLAG_UNIQUE_IP"' \
    -DCFG_DEVICE_METADATA_TABLE_NAME='"DEVICE_METADATA"' \
    "$RUN_TMP/swss-src/mclagsyncd/mclagsyncd.cpp" \
    "$RUN_TMP/swss-src/mclagsyncd/mclaglink.cpp" \
    -o "$MCLAGSYNCD_BIN" \
    -lswsscommon -lhiredis -lnl-3 -lnl-route-3 -lpthread
[[ -x "$MCLAGSYNCD_BIN" ]] || fail "mclagsyncd build failed"

if [[ ! -d /etc/iccpd ]]; then
    sudo -n mkdir -- /etc/iccpd
    CREATED_ETC_ICCPD=1
fi
if [[ ! -d /usr/share/swss ]]; then
    sudo -n mkdir -- /usr/share/swss
    CREATED_SHARE_SWSS=1
fi
SWSS_LUA_SOURCE="/users/Pial/dependencies/sonic-swss-common/common"
[[ -f "$SWSS_LUA_SOURCE/producer_state_table_apply_view.lua" ]] || fail "missing swsscommon Lua runtime assets"
mkdir -p "$RUN_TMP/swss-share"
cp "$SWSS_LUA_SOURCE"/*.lua "$RUN_TMP/swss-share/"

redis_cmd() {
    local ns="$1" db="$2"
    shift 2
    sudo -n ip netns exec "$ns" redis-cli --raw -n "$db" "$@"
}

wait_redis_value() {
    local ns="$1" db="$2" key="$3" field="$4" expected="$5" tries="${6:-150}"
    local value i
    for ((i=0; i<tries; i++)); do
        value="$(redis_cmd "$ns" "$db" HGET "$key" "$field" 2>/dev/null || true)"
        if [[ "$value" == "$expected" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

find_process() {
    local ns="$1" wanted="$2" pid target i
    for ((i=0; i<100; i++)); do
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            target="$(sudo -n readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
            if [[ "$target" == "$wanted" ]]; then
                printf '%s\n' "$pid"
                return 0
            fi
        done < <(sudo -n ip netns pids "$ns" 2>/dev/null || true)
        sleep 0.1
    done
    return 1
}

write_db_config() {
    local dir="$1" socket_path="$2"
    mkdir -p "$dir"
    printf '%s\n' \
        '{' \
        "  \"INSTANCES\": {\"redis\": {\"hostname\": \"127.0.0.1\", \"port\": 6379, \"unix_socket_path\": \"${socket_path}\", \"persistence_for_warm_boot\": \"yes\"}}," \
        '  "DATABASES": {' \
        '    "APPL_DB": {"id": 0, "separator": ":", "instance": "redis"},' \
        '    "ASIC_DB": {"id": 1, "separator": ":", "instance": "redis"},' \
        '    "COUNTERS_DB": {"id": 2, "separator": ":", "instance": "redis"},' \
        '    "LOGLEVEL_DB": {"id": 3, "separator": ":", "instance": "redis"},' \
        '    "CONFIG_DB": {"id": 4, "separator": "|", "instance": "redis"},' \
        '    "STATE_DB": {"id": 6, "separator": "|", "instance": "redis"}' \
        '  }' \
        '}' > "$dir/database_config.json"
}

launch_mclagsyncd() {
    local ns="$1" dbdir="$2" logfile="$3"
    (
        sudo -n unshare -m --propagation private sh -c '
            mount --bind "$1" /var/run/redis/sonic-db
            mount --bind "$2" /usr/share/swss
            exec ip netns exec "$3" env platform=broadcom "$4"
        ' sh "$dbdir" "$RUN_TMP/swss-share" "$ns" "$MCLAGSYNCD_BIN" >"$logfile" 2>&1 || :
    ) >/dev/null 2>&1 &
    BG_JOBS+=("$!")
}

launch_iccpd() {
    local ns="$1" dbdir="$2" etcdir="$3" rundir="$4" logfile="$5"
    (
        sudo -n unshare -m --propagation private sh -c '
            mount --bind "$1" /var/run/redis/sonic-db
            mount --bind "$2" /etc/iccpd
            mount --bind "$3" /var/run/iccpd
            exec ip netns exec "$4" "$5" -c -l "$6"
        ' sh "$dbdir" "$etcdir" "$rundir" "$ns" "$ICCPD_BIN" "$logfile" >"$logfile" 2>&1 || :
    ) >/dev/null 2>&1 &
    BG_JOBS+=("$!")
}

# Globals assigned by setup_lab: LAB_DIR, NS_A, NS_B, A_PID, B_PID.
setup_lab() {
    local label="$1" octet="$2" suffix="${BASHPID}${RANDOM}"
    local va="v${label}a${suffix: -5}" vb="v${label}b${suffix: -5}"
    local node ns ipaddr peeraddr mac
    LAB_DIR="$RUN_TMP/lab-$label"
    NS_A="mc1${label}a${suffix}"
    NS_B="mc1${label}b${suffix}"
    ALL_NAMESPACES+=("$NS_A" "$NS_B")
    mkdir -p "$LAB_DIR"

    sudo -n ip netns add "$NS_A"
    sudo -n ip netns add "$NS_B"
    sudo -n ip link add "$va" type veth peer name "$vb"
    sudo -n ip link set "$va" netns "$NS_A"
    sudo -n ip link set "$vb" netns "$NS_B"
    sudo -n ip -n "$NS_A" link set "$va" name PortChannel10
    sudo -n ip -n "$NS_B" link set "$vb" name PortChannel10

    for node in a b; do
        if [[ "$node" == a ]]; then
            ns="$NS_A"; ipaddr="10.77.${octet}.1"; peeraddr="10.77.${octet}.2"; mac="02:77:${octet}:00:00:01"
        else
            ns="$NS_B"; ipaddr="10.77.${octet}.2"; peeraddr="10.77.${octet}.1"; mac="02:77:${octet}:00:00:02"
        fi
        mkdir -p "$LAB_DIR/$node/etc" "$LAB_DIR/$node/run" "$LAB_DIR/$node/db" "$LAB_DIR/$node/redis"
        write_db_config "$LAB_DIR/$node/db" "$LAB_DIR/$node/redis/redis.sock"
        printf '%s\n' \
            'mclag_id:1' \
            "    local_ip:${ipaddr}" \
            "    peer_ip:${peeraddr}" \
            '    peer_link:PortChannel10' \
            '    mclag_interface:PortChannel20' \
            "system_mac:${mac}" > "$LAB_DIR/$node/etc/iccpd.conf"

        sudo -n ip -n "$ns" link set lo up
        sudo -n ip -n "$ns" addr add "${ipaddr}/24" dev PortChannel10
        sudo -n ip -n "$ns" link set PortChannel10 up
        sudo -n ip -n "$ns" link add PortChannel20 type dummy
        sudo -n ip -n "$ns" link set PortChannel20 up

        sudo -n ip netns exec "$ns" redis-server \
            --bind 127.0.0.1 --protected-mode no --port 6379 \
            --unixsocket "$LAB_DIR/$node/redis/redis.sock" --unixsocketperm 770 \
            --save '' --appendonly no --daemonize yes \
            --dir "$LAB_DIR/$node/redis" \
            --pidfile "$LAB_DIR/$node/redis/redis.pid" \
            --logfile "$LAB_DIR/$node/redis/redis.log"
        for _ in {1..50}; do
            if [[ "$(redis_cmd "$ns" 0 PING 2>/dev/null || true)" == PONG ]]; then break; fi
            sleep 0.1
        done
        [[ "$(redis_cmd "$ns" 0 PING 2>/dev/null || true)" == PONG ]] || fail "Redis did not start in $ns"
        redis_cmd "$ns" 4 HSET 'DEVICE_METADATA|localhost' mac "$mac" >/dev/null
        redis_cmd "$ns" 4 HSET 'MCLAG|1' \
            source_ip "$ipaddr" peer_ip "$peeraddr" peer_link PortChannel10 \
            keepalive_interval 1 session_timeout 3 >/dev/null
        redis_cmd "$ns" 4 HSET 'MCLAG_INTERFACE|1|PortChannel20' NULL NULL >/dev/null
    done

    launch_mclagsyncd "$NS_A" "$LAB_DIR/a/db" "$LAB_DIR/a/mclagsyncd.log"
    launch_mclagsyncd "$NS_B" "$LAB_DIR/b/db" "$LAB_DIR/b/mclagsyncd.log"
    sleep 0.5
    launch_iccpd "$NS_A" "$LAB_DIR/a/db" "$LAB_DIR/a/etc" "$LAB_DIR/a/run" "$LAB_DIR/a/iccpd.log"
    launch_iccpd "$NS_B" "$LAB_DIR/b/db" "$LAB_DIR/b/etc" "$LAB_DIR/b/run" "$LAB_DIR/b/iccpd.log"
    A_PID="$(find_process "$NS_A" "$ICCPD_BIN")" || fail "node A iccpd did not start"
    B_PID="$(find_process "$NS_B" "$ICCPD_BIN")" || fail "node B iccpd did not start"

    wait_redis_value "$NS_A" 6 'MCLAG_TABLE|1' oper_status up 250 || fail "node A did not reach ICCP up"
    wait_redis_value "$NS_B" 6 'MCLAG_TABLE|1' oper_status up 250 || fail "node B did not reach ICCP up"
}

restart_a() {
    launch_iccpd "$NS_A" "$LAB_DIR/a/db" "$LAB_DIR/a/etc" "$LAB_DIR/a/run" "$LAB_DIR/a/iccpd-restart.log"
    A_PID="$(find_process "$NS_A" "$ICCPD_BIN")" || fail "node A did not restart"
    # mclagsyncd must have accepted the replacement control connection.
    local i established=0
    for ((i=0; i<100; i++)); do
        if sudo -n ip netns exec "$NS_A" ss -tn | awk '$1 == "ESTAB" && ($4 ~ /:2626$/ || $5 ~ /:2626$/) {found=1} END {exit !found}'; then
            established=1
            break
        fi
        sleep 0.1
    done
    (( established == 1 )) || fail "restarted A did not reconnect to real mclagsyncd"
}

iccp_state() { redis_cmd "$1" 6 HGET 'MCLAG_TABLE|1' oper_status; }

printf 'BUILD sonic-buildimage=%s sonic-swss=%s\n' "$actual_head" "$actual_swss"
printf 'BUILD iccpd_sha256=%s mclagsyncd_sha256=%s\n' \
    "$(sha256sum "$ICCPD_BIN" | awk '{print $1}')" \
    "$(sha256sum "$MCLAGSYNCD_BIN" | awk '{print $1}')"

# Level 0: only normal process failure operations, with no debugger/failpoint.
# We intentionally reject a stale snapshot unless the product log proves the
# local process had already closed its peer socket.
setup_lab l0 71
printf 'LEVEL0_PRE oper_status=%s\n' "$(iccp_state "$NS_A")"
sudo -n kill -KILL "$B_PID"
sudo -n kill -KILL "$A_PID"
sleep 0.5
level0_close=0
if grep -Eq 'CSM socket [0-9]+ close, location 1' "$LAB_DIR/a/iccpd.log"; then
    level0_close=1
fi
level0_state="$(iccp_state "$NS_A")"
if (( level0_close == 1 )) && [[ "$level0_state" == up ]]; then
    restart_a
    sleep 8
    printf 'LEVEL0_RESULT=triggered_after_real_socket_teardown\n'
    printf 'POST_RESTART_8S oper_status=%s\n' "$(iccp_state "$NS_A")"
    [[ "$(iccp_state "$NS_A")" == up ]] || fail "Level 0 stale state did not persist"
    printf 'DOWNSTREAM_RECOVERY_OBSERVED=no\n'
    printf 'TEST_RESULT=BUG_REPRODUCED level=0\n'
    exit 0
fi
printf 'LEVEL0_RESULT=not_triggered close_after_teardown=%s observed_oper_status=%s\n' \
    "$level0_close" "$level0_state"
destroy_lab "$NS_A" "$NS_B"

# Level 1: timing assistance only.  A real peer death drives A through the
# production scheduler.  At handler entry the debugger proves sock_fd == -1,
# then applies the counterexample's abrupt process-death action.
setup_lab l1 72
printf 'LEVEL1_PRE oper_status=%s\n' "$(iccp_state "$NS_A")"
GDB_LOG="$LAB_DIR/a/gdb.log"
timeout 30s sudo -n gdb -q -batch -p "$A_PID" \
    -ex 'set pagination off' \
    -ex 'break mlacp_peer_disconn_handler' \
    -ex 'continue' \
    -ex 'printf "LEVEL1_BREAKPOINT_HIT sock_fd=%d\n", csm->sock_fd' \
    -ex 'bt 3' \
    -ex "shell /bin/kill -KILL $A_PID" \
    -ex 'quit' >"$GDB_LOG" 2>&1 &
GDB_JOB="$!"
BG_JOBS+=("$GDB_JOB")
sleep 0.75
sudo -n kill -KILL "$B_PID"
set +e
wait "$GDB_JOB"
gdb_rc=$?
set -e
[[ "$gdb_rc" -eq 0 ]] || fail "gdb timing helper failed with $gdb_rc"
grep -Fq 'LEVEL1_BREAKPOINT_HIT sock_fd=-1' "$GDB_LOG" || fail "breakpoint did not prove post-teardown state"
grep -Fq 'scheduler_session_disconnect_handler' "$GDB_LOG" || fail "breakpoint stack lacks real scheduler caller"
printf '%s\n' "$(grep -E 'LEVEL1_BREAKPOINT_HIT|#0 |#1 ' "$GDB_LOG" | head -3)"
printf 'AFTER_CRASH oper_status=%s\n' "$(iccp_state "$NS_A")"
[[ "$(iccp_state "$NS_A")" == up ]] || fail "ICCP-down publication occurred before crash"

restart_a
sleep 2
post2_iccp="$(iccp_state "$NS_A")"
printf 'POST_RESTART_2S oper_status=%s\n' "$post2_iccp"
sleep 6
post8_iccp="$(iccp_state "$NS_A")"
printf 'POST_RESTART_8S oper_status=%s\n' "$post8_iccp"
[[ "$post2_iccp" == up && "$post8_iccp" == up ]] || fail "stale ICCP state was reconciled"
printf 'DOWNSTREAM_RECOVERY_OBSERVED=no (waited >2x configured session_timeout after reconnect)\n'
printf 'TEST_RESULT=BUG_REPRODUCED level=1\n'
