#!/bin/bash
set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT_DIR=$(cd "$HARNESS_DIR/.." && pwd)
ARTIFACT_DIR=${SPECULA_ARTIFACT_DIR:-/users/Pial/targets/sonic-buildimage-warmreboot-high}
SYSMGR_DIR="$ARTIFACT_DIR/src/sonic-sysmgr"
TRACE_DIR="$OUTPUT_DIR/traces"
RAW_DIR="$TRACE_DIR/raw"
SPEC_DIR="$OUTPUT_DIR/spec"
TLA_JAR=${SPECULA_TLA_JAR:-/users/Pial/Specula/lib/tla2tools.jar}
RUN_TMP=$(mktemp -d /tmp/specula-warmreboot.XXXXXX)
export PYTHONDONTWRITEBYTECODE=1

cleanup()
{
    if [[ -S "$RUN_TMP/redis.sock" ]]; then
        redis-cli -s "$RUN_TMP/redis.sock" shutdown nosave >/dev/null 2>&1 || true
    fi
    case "$RUN_TMP" in
        /tmp/specula-warmreboot.*) rm -rf -- "$RUN_TMP" ;;
    esac
}
trap cleanup EXIT

mkdir -p "$TRACE_DIR" "$RAW_DIR"
find "$TRACE_DIR" -maxdepth 1 -type f -name '*.ndjson' -delete
find "$RAW_DIR" -maxdepth 1 -type f -name '*.ndjson' -delete

bash "$HARNESS_DIR/apply.sh"

chmod +x "$HARNESS_DIR"/src/*.py "$HARNESS_DIR"/src/*.sh "$HARNESS_DIR"/src/stubs/*
PYTHONPYCACHEPREFIX="$RUN_TMP/pycache" timeout 30 python3 -m py_compile "$HARNESS_DIR"/src/*.py \
    "$ARTIFACT_DIR/src/sonic-host-services/host_modules/reboot.py"
timeout 30 bash -n "$ARTIFACT_DIR/src/sonic-utilities/scripts/fast-reboot" \
    "$ARTIFACT_DIR/files/image_config/warmboot-finalizer/finalize-warmboot.sh" \
    "$HARNESS_DIR"/src/scenario_*.sh

timeout 300 autoreconf -fi "$SYSMGR_DIR"
timeout 300 bash -lc 'cd "$1" && ./configure --with-extra-inc=/usr/local/include --with-extra-lib=/usr/local/lib' _ "$SYSMGR_DIR"
if [[ ! -f "$SYSMGR_DIR/build/gen/librebootgnoi.la" ]]; then
    timeout 300 make -C "$SYSMGR_DIR" build/gen/librebootgnoi.la
fi
timeout 300 make -C "$SYSMGR_DIR/tests" clean
find "$SYSMGR_DIR/tests" "$SYSMGR_DIR/rebootbackend" -maxdepth 1 -type f -name '*.gcda' -delete
timeout 300 make -C "$SYSMGR_DIR/tests" tests

cp "$ARTIFACT_DIR/src/sonic-swss-common/common/database_config.json" "$RUN_TMP/database_config.json"
sed -i "s#/var/run/redis/redis.sock#$RUN_TMP/redis.sock#g; s/\"port\" : 6379/\"port\" : 0/" "$RUN_TMP/database_config.json"
sed -i "s#/var/run/redis/redis_chassis.sock#$RUN_TMP/redis-chassis.sock#g; s/\"port\" : 6380/\"port\" : 0/" "$RUN_TMP/database_config.json"
cat > "$RUN_TMP/redis.conf" <<EOF
port 0
unixsocket $RUN_TMP/redis.sock
unixsocketperm 700
daemonize yes
pidfile $RUN_TMP/redis.pid
save ""
appendonly no
EOF
timeout 30 redis-server "$RUN_TMP/redis.conf"
timeout 10 bash -c 'until [[ -S "$1" ]]; do sleep 0.05; done' _ "$RUN_TMP/redis.sock"
export SPECULA_DATABASE_CONFIG="$RUN_TMP/database_config.json"

run_scenario()
{
    local name=$1
    redis-cli -s "$RUN_TMP/redis.sock" FLUSHALL >/dev/null
    timeout 120 python3 "$HARNESS_DIR/src/run_scenario.py" \
        --raw "$RAW_DIR/$name.ndjson" --trace "$TRACE_DIR/$name.ndjson" -- \
        bash "$HARNESS_DIR/src/scenario_$name.sh"
}

run_scenario normal
run_scenario finalizer_deadline
run_scenario transport_failure

timeout 30 python3 "$HARNESS_DIR/src/verify_traces.py" "$TRACE_DIR"

if rg -n 'Validate(Backend|Shutdown|Warm)Post\s*==\s*TRUE' "$SPEC_DIR/Trace.tla"; then
    echo "Trace.tla contains a vacuous post-state validator" >&2
    exit 1
fi

for trace in "$TRACE_DIR"/*.ndjson; do
    trace_name=$(basename "$trace")
    (cd "$SPEC_DIR" && JSON="../traces/$trace_name" timeout 120 java -cp "$TLA_JAR" \
        tlc2.TLC -cleanup -config Trace.cfg Trace.tla) \
        > "$RUN_TMP/tlc-$trace_name.log" 2>&1 || {
            cat "$RUN_TMP/tlc-$trace_name.log" >&2
            exit 1
        }
    if ! rg -q 'Model checking completed|Finished in' "$RUN_TMP/tlc-$trace_name.log"; then
        cat "$RUN_TMP/tlc-$trace_name.log" >&2
        echo "TLC did not report completion for $trace_name" >&2
        exit 1
    fi
    echo "validated $trace_name"
done

echo "trace line counts:"
wc -l "$TRACE_DIR"/*.ndjson
