#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR=$(cd -- "$HARNESS_DIR/.." && pwd)
TRACE_DIR="$OUTPUT_DIR/traces"
SPEC_DIR="$OUTPUT_DIR/spec"
ARTIFACT_DIR=${DASH_HA_SOURCE:-/users/Pial/targets/sonic-dash-ha}
SPECULA_HOME=${SPECULA_HOME:-/users/Pial/Specula}
SWSS_COMMON_REPO=${SWSS_COMMON_REPO:-/users/Pial/dependencies/sonic-swss-common}
LOCAL_DEPS="$HARNESS_DIR/.deps"
LOCAL_ROOT="$LOCAL_DEPS/root"
LOCAL_CLANG="$LOCAL_ROOT/usr/lib/x86_64-linux-gnu"

mkdir -p "$TRACE_DIR" "$LOCAL_DEPS/packages" "$LOCAL_ROOT"
"$HARNESS_DIR/apply.sh" "$ARTIFACT_DIR"

if [[ ! -d "$SWSS_COMMON_REPO/common" ]]; then
    echo "sonic-swss-common dependency not found at: $SWSS_COMMON_REPO" >&2
    echo "Set SWSS_COMMON_REPO to its source directory." >&2
    exit 2
fi
if [[ ! -d "$SWSS_COMMON_REPO/common/.libs" ]]; then
    echo "Built sonic-swss-common libraries are missing: $SWSS_COMMON_REPO/common/.libs" >&2
    exit 2
fi

# bindgen needs libclang. Provision the Debian runtime into the harness cache
# when the host does not expose a usable shared library; no root access needed.
if ! find "$LOCAL_CLANG" -maxdepth 1 -name 'libclang-*.so.*' -print -quit 2>/dev/null | rg -q .; then
    pushd "$LOCAL_DEPS/packages" >/dev/null
    timeout 300s apt-get download libclang1-14 libllvm14
    for package in ./*.deb; do
        timeout 120s dpkg-deb -x "$package" "$LOCAL_ROOT"
    done
    popd >/dev/null
fi

export SWSS_COMMON_REPO
export LIBCLANG_PATH="$LOCAL_CLANG"
export LD_LIBRARY_PATH="$LOCAL_CLANG:$SWSS_COMMON_REPO/common/.libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export RUST_BACKTRACE=1

echo "Building instrumented dash-ha tests..."
timeout 600s cargo test --manifest-path "$ARTIFACT_DIR/Cargo.toml" -p hamgrd --no-run

run_scenario() {
    local trace_name=$1
    local test_filter=$2
    local event_filter=$3
    local trace_file="$TRACE_DIR/$trace_name.ndjson"

    # Ensure a failed/missing test cannot leave a stale successful trace.
    : >"$trace_file"
    echo "Running $test_filter -> $trace_file"
    env \
        SPECULA_TRACE_FILE="$trace_file" \
        SPECULA_TRACE_EVENTS="$event_filter" \
        SPECULA_TRACE_MAX_EVENTS=64 \
        timeout 60s cargo test \
            --manifest-path "$ARTIFACT_DIR/Cargo.toml" \
            -p hamgrd "$test_filter" -- --nocapture --test-threads=1
}

run_scenario \
    vote_retry \
    specula_trace_vote_retry_and_final \
    NpuHandleVoteRequestRetry,NpuHandleVoteRequestFinal
run_scenario \
    switchover_retry \
    specula_trace_switchover_retry_and_final \
    NpuHandleSwitchoverRst,NpuHandleSwitchoverFin
run_scenario \
    peer_timeout \
    specula_trace_peer_connection_timeout \
    NpuCheckPeerConnectionAndRetry,NpuCheckPeerConnectionLost
run_scenario \
    config_route \
    specula_trace_config_route_writer \
    HaSetComputeRouteFromConfig

python3 - "$TRACE_DIR" <<'PY'
import json
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
expected = {
    "vote_retry.ndjson": {"NpuHandleVoteRequestRetry", "NpuHandleVoteRequestFinal"},
    "switchover_retry.ndjson": {"NpuHandleSwitchoverRst", "NpuHandleSwitchoverFin"},
    "peer_timeout.ndjson": {"NpuCheckPeerConnectionAndRetry", "NpuCheckPeerConnectionLost"},
    "config_route.ndjson": {"HaSetComputeRouteFromConfig"},
}
for name, expected_events in expected.items():
    path = trace_dir / name
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit(f"empty trace: {path}")
    timestamps = []
    seen = set()
    for index, row in enumerate(rows, 1):
        if row.get("tag") != "trace":
            raise SystemExit(f"{path}:{index}: tag must be trace")
        event = row.get("event")
        if not isinstance(event, dict) or not {"name", "node", "post"} <= event.keys():
            raise SystemExit(f"{path}:{index}: malformed event envelope")
        post = event["post"]
        required_post = {
            "nodeState", "messages", "inbox", "ackPending", "pendingRoleWrites",
            "routeOwner", "routeEpoch", "routeTerm", "routeCandidate",
            "routeCandidateEpoch", "routeCandidateTerm", "routePending",
            "lastRouteWriter", "haOwner",
        }
        if not isinstance(post, dict) or not required_post <= post.keys():
            raise SystemExit(f"{path}:{index}: incomplete post-state")
        timestamps.append(int(row["ts"]))
        seen.add(event["name"])
    if timestamps != sorted(timestamps):
        raise SystemExit(f"timestamps are not ordered in {path}")
    if seen != expected_events:
        raise SystemExit(f"event mismatch in {path}: expected {expected_events}, saw {seen}")
    print(f"JSON OK: {name}: {len(rows)} events: {', '.join(sorted(seen))}")
PY

TLA_JAR="$SPECULA_HOME/lib/tla2tools.jar"
COMMUNITY_JAR="$SPECULA_HOME/lib/CommunityModules-deps.jar"
if [[ ! -f "$TLA_JAR" || ! -f "$COMMUNITY_JAR" ]]; then
    echo "TLC dependencies are missing beneath $SPECULA_HOME/lib" >&2
    exit 2
fi

TLC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dash-ha-tlc.XXXXXX")
trap 'rm -rf -- "$TLC_TMP"' EXIT

validate_trace() {
    local trace_name=$1
    local trace_file="$TRACE_DIR/$trace_name.ndjson"
    local metadir="$TLC_TMP/$trace_name"
    local log="$TLC_TMP/$trace_name.log"
    mkdir -p "$metadir"
    if ! (
        cd "$SPEC_DIR"
        JSON="$trace_file" timeout 120s java -Xmx2G -XX:+UseParallelGC \
            -cp "$TLA_JAR:$COMMUNITY_JAR" \
            tlc2.TLC -workers 1 -config Trace.cfg -cleanup -lncheck final \
            -metadir "$metadir" Trace.tla
    ) >"$log" 2>&1; then
        echo "TLC validation failed for $trace_file" >&2
        tail -80 "$log" >&2
        return 1
    fi
    if ! rg -q 'Model checking completed. No error has been found.' "$log"; then
        echo "TLC did not report success for $trace_file" >&2
        tail -80 "$log" >&2
        return 1
    fi
    echo "TLC OK: $trace_name.ndjson"
}

validate_trace vote_retry
validate_trace switchover_retry
validate_trace peer_timeout
validate_trace config_route

echo "Harness completed successfully. Traces are in $TRACE_DIR"
