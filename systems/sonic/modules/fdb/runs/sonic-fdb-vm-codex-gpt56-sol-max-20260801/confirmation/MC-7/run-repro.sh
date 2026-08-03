#!/usr/bin/env bash
set -euo pipefail

MC7_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MC7_WORKTREE="$MC7_DIR/worktree"
MC7_REPRO_SOURCE="$MC7_DIR/../../repro/test_bugMC-7_startup_nhg_replay.cpp"
MC7_BUILD_DIR="$MC7_DIR/build-mc7"
MC7_DB_CONFIG="$MC7_WORKTREE/tests/mock_tests/database_config.json"
MC7_LUA_DIR="/users/Pial/dependencies/sonic-swss-common/common"
MC7_EXPECTED_SHA="4f3dda156e52ed7647b1dbf900d54d87efaea455"

MC7_ACTUAL_SHA=$(git -C "$MC7_WORKTREE" rev-parse HEAD)
if [[ "$MC7_ACTUAL_SHA" != "$MC7_EXPECTED_SHA" ]]; then
    echo "unexpected_source_sha=$MC7_ACTUAL_SHA" >&2
    exit 2
fi

mkdir -p "$MC7_BUILD_DIR"
printf 'source_sha=%s\n' "$MC7_ACTUAL_SHA"
printf '%s\n' 'build_compat=define missing installed-swsscommon CFG_VXLAN_EVPN_NVO_TABLE_NAME as VXLAN_EVPN_NVO'

cd "$MC7_WORKTREE"
timeout 5m g++ -std=c++14 -O0 -g -Wno-write-strings \
    '-DCFG_VXLAN_EVPN_NVO_TABLE_NAME="VXLAN_EVPN_NVO"' \
    -I. -Iwarmrestart -I/usr/local/include/swss -I/usr/include/libnl3 \
    "$MC7_REPRO_SOURCE" \
    fdbsyncd/fdbsync.cpp warmrestart/warmRestartAssist.cpp \
    -L/usr/local/lib -Wl,-rpath,/usr/local/lib \
    -lswsscommon -lnl-route-3 -lnl-3 -lhiredis -lpthread \
    -o "$MC7_BUILD_DIR/test_bugMC-7_startup_nhg_replay"

timeout 30s unshare --user --map-root-user --net --mount --propagation private \
    bash -c '
set -euo pipefail
MC7_WORKTREE=$1
MC7_TEST_BINARY=$2
MC7_DB_CONFIG=$3
MC7_LUA_DIR=$4
MC7_TMP=$(mktemp -d)
cleanup() {
    redis-cli -s /var/run/redis/redis.sock shutdown nosave >/dev/null 2>&1 || true
    rm -rf "$MC7_TMP"
}
trap cleanup EXIT

mount -t tmpfs -o size=4m tmpfs /var/run/redis
mkdir -p /var/run/redis/sonic-db
cp "$MC7_DB_CONFIG" /var/run/redis/sonic-db/database_config.json

mount -t tmpfs -o size=4m tmpfs /usr/share
mkdir -p /usr/share/swss
mount --bind "$MC7_LUA_DIR" /usr/share/swss

ip link set lo up
redis-server \
    --bind 127.0.0.1 \
    --port 6379 \
    --unixsocket /var/run/redis/redis.sock \
    --unixsocketperm 777 \
    --notify-keyspace-events AKE \
    --save "" \
    --appendonly no \
    --daemonize yes \
    --pidfile /var/run/redis/redis.pid \
    --logfile "$MC7_TMP/redis.log"

for attempt in $(seq 1 50); do
    if redis-cli -s /var/run/redis/redis.sock ping 2>/dev/null | grep -q PONG; then
        break
    fi
    sleep 0.1
done

# Legitimate existing configuration, buffered by SubscriberStateTable but not
# processed by fdbsyncd until after its startup netlink dumps.
redis-cli -s /var/run/redis/redis.sock -n 4 \
    HSET "VXLAN_EVPN_NVO|nvo1" source_vtep 10.0.0.1 >/dev/null

# Prove the Level-2 injected precondition is reachable through the real public
# Linux API in this environment.
ip nexthop add id 268435458 via 192.0.2.1 fdb
printf "reachable_real_api_precondition="
ip -details nexthop show id 268435458

cd "$MC7_WORKTREE/tests/mock_tests"
"$MC7_TEST_BINARY"
' bash "$MC7_WORKTREE" \
    "$MC7_BUILD_DIR/test_bugMC-7_startup_nhg_replay" \
    "$MC7_DB_CONFIG" \
    "$MC7_LUA_DIR"
