#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$OUTPUT_DIR/harness"
TRACE_DIR="$OUTPUT_DIR/traces"
SPEC_DIR="$OUTPUT_DIR/spec"
ICCPD_DIR="${ICCPD_SOURCE_DIR:-/users/Pial/targets/sonic-buildimage-iccpd/src/iccpd}"
BUILD_DIR="$HARNESS_DIR/build"
TLA2TOOLS_JAR="${TLA2TOOLS_JAR:-/users/Pial/Specula/lib/tla2tools.jar}"
COMMUNITY_JAR="${COMMUNITY_JAR:-/users/Pial/Specula/lib/CommunityModules-deps.jar}"

mkdir -p "$BUILD_DIR" "$TRACE_DIR"
bash "$HARNESS_DIR/apply.sh"

echo "Building the instrumented iccpd daemon..."
timeout 300 bash -c '
    set -euo pipefail
    cd "$1"
    ./autogen.sh
    ./configure CFLAGS="-O0 -g -DICCPD_TLA_TRACE"
    make clean
    make -j"$(nproc)"
' _ "$ICCPD_DIR"

echo "Linking the real-code scenario driver..."
timeout 120 bash -c '
    set -euo pipefail
    iccpd_dir="$1"
    harness_dir="$2"
    build_dir="$3"
    cd "$iccpd_dir"
    gcc -std=gnu11 -O0 -g -DICCPD_TLA_TRACE -DHAVE_CONFIG_H \
        -I. -Iinclude -Isrc -I/usr/include/libnl3 \
        -c "$harness_dir/src/test_iccpd_trace.c" \
        -o "$build_dir/test_iccpd_trace.o"
    objects=()
    for object in src/iccpd-*.o; do
        [[ "$object" == "src/iccpd-iccp_main.o" ]] || objects+=("$object")
    done
    gcc -o "$build_dir/test_iccpd_trace" \
        "$build_dir/test_iccpd_trace.o" "${objects[@]}" \
        -lnl-genl-3 -lnl-route-3 -lnl-3 -lpthread
' _ "$ICCPD_DIR" "$HARNESS_DIR" "$BUILD_DIR"

find "$TRACE_DIR" -maxdepth 1 -type f -name '*.ndjson' -delete
scenarios=(warmboot_full warmboot_partial warmboot_failed portchannel_down)
for scenario in "${scenarios[@]}"; do
    echo "Running $scenario..."
    timeout 30 "$BUILD_DIR/test_iccpd_trace" "$scenario" \
        "$TRACE_DIR/$scenario.ndjson"
done

python3 "$HARNESS_DIR/src/validate_traces.py" "$TRACE_DIR"/*.ndjson

if [[ -f "$TLA2TOOLS_JAR" && -f "$COMMUNITY_JAR" ]]; then
    echo "Running quick TLC replay for every collected trace..."
    tla_tmp="$(mktemp -d)"
    cleanup_validation() {
        if [[ -f "$TRACE_DIR/trace.ndjson" ]]; then
            rm "$TRACE_DIR/trace.ndjson"
        fi
        find "$tla_tmp" -depth -delete
    }
    trap cleanup_validation EXIT
    for scenario in "${scenarios[@]}"; do
        cp "$TRACE_DIR/$scenario.ndjson" "$TRACE_DIR/trace.ndjson"
        validation_output="$(
            cd "$SPEC_DIR"
            timeout 300 java -XX:+UseParallelGC -Xmx4G \
                -cp "$TLA2TOOLS_JAR:$COMMUNITY_JAR" tlc2.TLC \
                -config Trace.cfg Trace.tla -lncheck final \
                -metadir "$tla_tmp/$scenario" -fpmem 0.9
        )"
        if ! grep -q 'Model checking completed. No error has been found.' \
                <<<"$validation_output"; then
            printf '%s\n' "$validation_output" >&2
            echo "error: TLC trace replay failed for $scenario" >&2
            exit 1
        fi
        echo "  $scenario: TLC replay passed"
    done
    cleanup_validation
    trap - EXIT
else
    echo "warning: TLC jars not found; structural checks passed, replay skipped" >&2
fi

echo "Trace results:"
for trace in "$TRACE_DIR"/*.ndjson; do
    printf '  %s: %s events\n' "$(basename "$trace")" "$(wc -l < "$trace")"
done
