#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
SPEC_DIR="$OUTPUT_DIR/spec"
TRACE_DIR="$OUTPUT_DIR/traces"
SOURCE_DIR=${FDB_SOURCE_DIR:-/users/Pial/targets/sonic-swss-fdb}
DEPS_PREFIX=${FDB_DEPS_PREFIX:-"$HARNESS_DIR/.deps/root"}
WORK_DIR="$HARNESS_DIR/.work"
BUILD_LOG_DIR="$WORK_DIR/build-logs"
SCENARIOS_FILE="$HARNESS_DIR/src/scenarios.tsv"
TEST_DIR="$SOURCE_DIR/tests/mock_tests"
TEST_BINARY="$TEST_DIR/tests"
TLA2TOOLS_JAR=${TLA2TOOLS_JAR:-/users/Pial/Specula/lib/tla2tools.jar}
COMMUNITY_JAR=${COMMUNITY_JAR:-/users/Pial/Specula/lib/CommunityModules-deps.jar}
BUILD_JOBS=${FDB_BUILD_JOBS:-4}

mkdir -p "$TRACE_DIR" "$BUILD_LOG_DIR" "$WORK_DIR/gcov"

"$HARNESS_DIR/apply.sh" "$SOURCE_DIR"

if [[ ! -f "$DEPS_PREFIX/usr/include/sai/sai.h" ||
      ! -f "$DEPS_PREFIX/usr/lib/x86_64-linux-gnu/libsaivs.so" ||
      ! -f "$DEPS_PREFIX/usr/lib/x86_64-linux-gnu/libswsscommon.so" ]]; then
    "$HARNESS_DIR/src/bootstrap_deps.sh" "$DEPS_PREFIX"
fi

PKG_CONFIG_PATH="$DEPS_PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig"
CPPFLAGS="-I$DEPS_PREFIX/usr/include -I$DEPS_PREFIX/usr/include/swss -I/usr/local/include/swss"
LDFLAGS="-L$DEPS_PREFIX/usr/lib/x86_64-linux-gnu -L$DEPS_PREFIX/usr/lib -L/usr/local/lib -Wl,-rpath,$DEPS_PREFIX/usr/lib/x86_64-linux-gnu -Wl,-rpath,$DEPS_PREFIX/usr/lib -Wl,-rpath,/usr/local/lib"
LIBRARY_PATH="$DEPS_PREFIX/usr/lib/x86_64-linux-gnu:$DEPS_PREFIX/usr/lib:/usr/local/lib"
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    LIBRARY_PATH="$LIBRARY_PATH:$LD_LIBRARY_PATH"
fi

echo "[build] regenerating autotools files"
if ! (
    cd "$SOURCE_DIR"
    timeout 180 ./autogen.sh
) >"$BUILD_LOG_DIR/autogen.log" 2>&1; then
    tail -100 "$BUILD_LOG_DIR/autogen.log" >&2
    exit 1
fi

echo "[build] configuring against isolated SONiC dependencies"
if ! (
    cd "$SOURCE_DIR"
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH" timeout 180 ./configure \
        --with-extra-inc="$DEPS_PREFIX/usr/include" \
        CPPFLAGS="$CPPFLAGS" \
        LDFLAGS="$LDFLAGS"
) >"$BUILD_LOG_DIR/configure.log" 2>&1; then
    tail -100 "$BUILD_LOG_DIR/configure.log" >&2
    exit 1
fi

echo "[build] compiling the real orchagent mock-test binary"
if ! timeout 900 make -C "$TEST_DIR" -j"$BUILD_JOBS" tests \
        CXXFLAGS='-g -O0 -Wno-error=conversion' \
        >"$BUILD_LOG_DIR/make.log" 2>&1; then
    tail -150 "$BUILD_LOG_DIR/make.log" >&2
    exit 1
fi

trace_paths=()
while IFS=$'\t' read -r trace_name gtest_filter description; do
    if [[ -z "$trace_name" || "$trace_name" = \#* ]]; then
        continue
    fi
    trace_file="$TRACE_DIR/$trace_name"
    truncate -s 0 "$trace_file"
    gcov_dir="$WORK_DIR/gcov/${trace_name%.ndjson}"
    mkdir -p "$gcov_dir"
    echo "[trace] $trace_name — $description"
    (
        cd "$TEST_DIR"
        timeout 120 env \
            GCOV_PREFIX="$gcov_dir" \
            GCOV_PREFIX_STRIP=4 \
            FDB_SWSS_SHARE_DIR="$DEPS_PREFIX/usr/share/swss" \
            FDB_TLA_TRACE_FILE="$trace_file" \
            LD_LIBRARY_PATH="$LIBRARY_PATH" \
            "$TEST_BINARY" --gtest_color=no --gtest_filter="$gtest_filter"
    )
    if [[ ! -s "$trace_file" ]]; then
        echo "error: scenario produced no trace: $trace_name" >&2
        exit 1
    fi
    trace_paths+=("$trace_file")
done < "$SCENARIOS_FILE"

python3 "$HARNESS_DIR/src/validate_traces.py" "${trace_paths[@]}"

if [[ "${FDB_SKIP_TLC:-0}" != "1" ]]; then
    if [[ ! -f "$TLA2TOOLS_JAR" || ! -f "$COMMUNITY_JAR" ]]; then
        echo "error: TLC jars not found; set TLA2TOOLS_JAR and COMMUNITY_JAR" >&2
        exit 1
    fi

    validation_root=$(mktemp -d "${TMPDIR:-/tmp}/fdb-tlc.XXXXXX")
    replay_trace="$TRACE_DIR/trace.ndjson"
    cleanup_validation() {
        if [[ -f "$replay_trace" ]]; then
            unlink "$replay_trace"
        fi
        if [[ -d "$validation_root" ]]; then
            find "$validation_root" -depth -delete
        fi
    }
    trap cleanup_validation EXIT

    for trace_file in "${trace_paths[@]}"; do
        trace_stem=$(basename -- "$trace_file" .ndjson)
        cp "$trace_file" "$replay_trace"
        mkdir -p "$validation_root/$trace_stem"
        tlc_log="$validation_root/$trace_stem.log"
        echo "[tlc] replaying $(basename -- "$trace_file")"
        if ! (
            cd "$SPEC_DIR"
            timeout 300 java -XX:+UseParallelGC -Xmx4G \
                -cp "$TLA2TOOLS_JAR:$COMMUNITY_JAR" \
                tlc2.TLC -config Trace.cfg Trace.tla \
                -lncheck final -workers 1 \
                -metadir "$validation_root/$trace_stem" -fpmem 0.9
        ) >"$tlc_log" 2>&1; then
            cat "$tlc_log" >&2
            exit 1
        fi
        if ! grep -q 'Model checking completed. No error has been found.' "$tlc_log"; then
            cat "$tlc_log" >&2
            echo "error: TLC did not report successful completion" >&2
            exit 1
        fi
        grep 'Model checking completed. No error has been found.' "$tlc_log"
    done

    cleanup_validation
    trap - EXIT
fi

echo "generated ${#trace_paths[@]} validated traces in $TRACE_DIR"
