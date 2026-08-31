#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_ROOT="$OUTPUT_ROOT/harness"
TRACE_ROOT="$OUTPUT_ROOT/traces"
RAW_ROOT="$TRACE_ROOT/raw"
SPEC_ROOT="$OUTPUT_ROOT/spec"
SOURCE_ROOT="${LITEBOX_SOURCE_ROOT:-/home/ubuntu/tmp/litebox-specula-source.xc2YsN/litebox}"
TLA_JAR="${TLA_JAR:-/home/ubuntu/Specula-e2e/lib/tla2tools.jar}"
COMMUNITY_JAR="${COMMUNITY_JAR:-/home/ubuntu/Specula-e2e/lib/CommunityModules-deps.jar}"

export LITEBOX_SOURCE_ROOT="$SOURCE_ROOT"
export LITEBOX_TLA_RAW_DIR="$RAW_ROOT"
mkdir -p "$RAW_ROOT"

bash "$HARNESS_ROOT/apply.sh"

(
    cd "$SOURCE_ROOT"
    cargo fmt --all -- --check
    cargo test -p litebox_shim_linux --features tla_trace --no-run
    cargo test -p litebox --features tla_trace --no-run

    cargo test -p litebox_shim_linux --features tla_trace \
        tla_namespace_identity_trace -- --nocapture --test-threads=1
    cargo test -p litebox_shim_linux --features tla_trace \
        tla_fd_ofd_identity_trace -- --nocapture --test-threads=1
    cargo test -p litebox_shim_linux --features tla_trace \
        tla_mapping_generation_trace -- --nocapture --test-threads=1
    cargo test -p litebox_shim_linux --features tla_trace \
        tla_clone_ -- --nocapture --test-threads=1
    cargo test -p litebox --features tla_trace \
        tla_futex_validation_quota_trace -- --nocapture --test-threads=1
    cargo test -p litebox --features tla_trace \
        tla_futex_overlap_trace -- --nocapture --test-threads=1
)

for scenario in \
    namespace_identity \
    fd_ofd_identity \
    mapping_generation \
    clone_success \
    clone_stack_failure \
    clone_spawn_failure \
    futex_validation_quota \
    futex_overlap
do
    python3 "$HARNESS_ROOT/preprocess_trace.py" \
        "$RAW_ROOT" "$scenario" "$TRACE_ROOT/$scenario.ndjson"
done

cp "$TRACE_ROOT/namespace_identity.ndjson" "$TRACE_ROOT/trace.ndjson"
python3 "$HARNESS_ROOT/check_traces.py" "$TRACE_ROOT"

python3 - "$TRACE_ROOT" <<'PY'
import json
import sys
from pathlib import Path

for path in sorted(Path(sys.argv[1]).glob("*.ndjson")):
    if path.name == "trace.ndjson":
        continue
    data = json.loads(path.read_text(encoding="utf-8"))
    count = sum(len(events) for events in data["events"].values())
    print(f"{path.name}: {count} trace events")
PY

if test -f "$TLA_JAR" && test -f "$COMMUNITY_JAR"; then
    (
        cd "$SPEC_ROOT"
        java -XX:+UseParallelGC -cp "$TLA_JAR:$COMMUNITY_JAR" \
            tlc2.TLC -workers 1 -config Trace.cfg Trace.tla
    )
else
    echo "TLC smoke validation skipped: set TLA_JAR and COMMUNITY_JAR" >&2
fi

echo "Traces collected in $TRACE_ROOT"

