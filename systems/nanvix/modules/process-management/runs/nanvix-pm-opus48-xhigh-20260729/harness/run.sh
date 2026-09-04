#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.
#
# One-command Specula PM trace harness pipeline:
#   1. apply instrumentation to the Nanvix source artifact
#   2. build the test-enabled kernel and the standalone UserVM
#   3. boot the kernel in the UserVM and capture its console
#   4. split the console into one NDJSON trace per scenario (in traces/)
#   5. (if a TLC toolchain is available) validate each trace against spec/Trace.tla
#   6. report per-scenario event counts and validation results
#
# Run from the .specula-output directory:   bash harness/run.sh
#
# Environment overrides:
#   ARTIFACT   path to the Nanvix source tree (default: ../../source relative to harness/)
#   TLA_JAR    path to tla2tools.jar          (default: /home/ruize/Specula/lib/tla2tools.jar)
#   CM_JAR     path to CommunityModules jar   (default: /home/ruize/Specula/lib/CommunityModules-deps.jar)
#   BUILD_TIMEOUT / BOOT_TIMEOUT  seconds     (defaults: 900 / 180)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="${ARTIFACT:-$SCRIPT_DIR/../../source}"
ARTIFACT="$(cd "$ARTIFACT" && pwd)"
TRACES_DIR="$OUTPUT_ROOT/traces"
SPEC_DIR="$OUTPUT_ROOT/spec"
WORK_DIR="$SCRIPT_DIR/.work"
CONSOLE_LOG="$WORK_DIR/console.log"

BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"

mkdir -p "$TRACES_DIR" "$WORK_DIR"

echo "=================================================================="
echo " Specula PM trace harness"
echo " artifact = $ARTIFACT"
echo " traces   = $TRACES_DIR"
echo "=================================================================="

# --- 1. Apply instrumentation ---------------------------------------------------------------------
echo "[run] applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# --- 2. Build test-kernel + UserVM ----------------------------------------------------------------
echo "[run] building test-kernel and UserVM (timeout ${BUILD_TIMEOUT}s)..."
if ! timeout "$BUILD_TIMEOUT" make -C "$ARTIFACT" all-test-kernel all-uservm > "$WORK_DIR/build.log" 2>&1; then
    echo "[run] BUILD FAILED (see $WORK_DIR/build.log)"; tail -30 "$WORK_DIR/build.log"; exit 1
fi
echo "[run] build ok."

# --- 3. Boot in the UserVM and capture the console ------------------------------------------------
KERNEL="$ARTIFACT/bin/kernel-test.elf"
USERVM="$ARTIFACT/bin/uservm.elf"
echo "[run] booting kernel in UserVM (timeout ${BOOT_TIMEOUT}s)..."
timeout "$BOOT_TIMEOUT" "$USERVM" -kernel "$KERNEL" -kernel-args "test_magic=0xDEADBEEF" \
    > "$CONSOLE_LOG" 2>&1 || true
if ! grep -q "hello, world" "$CONSOLE_LOG"; then
    echo "[run] WARNING: kernel did not reach the success magic string; in-kernel tests may have failed."
fi
TLA_COUNT=$(grep -c "@@TLA@@" "$CONSOLE_LOG" || true)
echo "[run] captured $TLA_COUNT trace events."

# --- 4. Split into per-scenario NDJSON ------------------------------------------------------------
python3 - "$CONSOLE_LOG" "$TRACES_DIR" <<'PY'
import os, sys
console, outdir = sys.argv[1], sys.argv[2]
cur, buf, order = None, {}, []
for line in open(console, errors="replace"):
    if "@@SCENARIO@@ " in line:
        cur = line.split("@@SCENARIO@@ ", 1)[1].strip()
        buf.setdefault(cur, [])
        if cur not in order:
            order.append(cur)
    elif "@@TLA@@ " in line and cur is not None:
        buf[cur].append(line.split("@@TLA@@ ", 1)[1].rstrip("\n"))
for name in order:
    with open(os.path.join(outdir, name + ".ndjson"), "w") as o:
        o.write("\n".join(buf[name]) + ("\n" if buf[name] else ""))
    print(f"[run]   {name:22s} {len(buf[name])} events")
PY

# --- 5. Validate (best effort) --------------------------------------------------------------------
TLA_JAR="${TLA_JAR:-/home/ruize/Specula/lib/tla2tools.jar}"
CM_JAR="${CM_JAR:-/home/ruize/Specula/lib/CommunityModules-deps.jar}"
if command -v java >/dev/null 2>&1 && [ -f "$TLA_JAR" ] && [ -f "$CM_JAR" ]; then
    echo "[run] validating traces against spec/Trace.tla ..."
    FAIL=0
    for f in "$TRACES_DIR"/*.ndjson; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .ndjson)"
        OUT=$(cd "$SPEC_DIR" && timeout 300 env JSON="$f" \
            java -XX:+UseParallelGC -cp "$TLA_JAR:$CM_JAR" tlc2.TLC \
            -deadlock -config Trace.cfg Trace.tla 2>&1) || true
        if echo "$OUT" | grep -q "No error has been found"; then
            echo "[run]   PASS  $name"
        else
            echo "[run]   FAIL  $name"
            FAIL=1
        fi
    done
    [ "$FAIL" -eq 0 ] && echo "[run] all traces validated." || echo "[run] some traces failed validation (see above)."
else
    echo "[run] TLC toolchain not found; skipping validation (traces still written to $TRACES_DIR)."
fi

echo "[run] done. Traces in $TRACES_DIR"
