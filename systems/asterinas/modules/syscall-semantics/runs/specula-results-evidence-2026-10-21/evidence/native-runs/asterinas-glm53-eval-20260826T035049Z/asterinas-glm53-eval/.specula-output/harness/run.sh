#!/usr/bin/env bash

# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

harness_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output_dir=$(cd "$harness_dir/.." && pwd)
artifact_dir=$(cd "$output_dir/.." && pwd)
source_dir="$artifact_dir/source"
traces_dir="$output_dir/traces"
logs_dir="$harness_dir/build/logs"
stats_dir="$harness_dir/build/stats"
cfg_dir="$harness_dir/build/cfg"
dev_image=${SPECULA_DEV_IMAGE:-asterinas/dev:0.18.1-20260805}
scenarios=(
    ramfs_fault_vector
    ramfs_eof_positional
    correct_vector_positional
    exfat_fault_vector
)
if [[ -n ${SPECULA_SCENARIOS:-} ]]; then
    read -r -a scenarios <<< "$SPECULA_SCENARIOS"
fi

if [[ ! -c /dev/kvm ]]; then
    echo "/dev/kvm is required for the Asterinas trace scenarios" >&2
    exit 1
fi

mkdir -p "$traces_dir/raw" "$logs_dir" "$stats_dir" "$cfg_dir"
bash "$harness_dir/apply.sh"

docker_args=(
    run --rm
    --network=host
    --device=/dev/kvm
    -v "$artifact_dir:/work"
    -w /work/source
    -e RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu
)

host_user_dir=$(getent passwd "$(id -u)" | cut -d: -f6)
if [[ -d "$host_user_dir/.cargo/git" && -d "$host_user_dir/.cargo/registry" ]]; then
    docker_args+=(
        -v "$host_user_dir/.cargo/git:/root/.cargo/git"
        -v "$host_user_dir/.cargo/registry:/root/.cargo/registry"
        -e CARGO_NET_OFFLINE=true
    )
fi

timeout 1800 docker "${docker_args[@]}" "$dev_image" bash -lc '
    set -euo pipefail
    for scenario in "$@"; do
        echo "Running Specula scenario: $scenario"
        timeout 1200 make --no-print-directory run_kernel \
            AUTO_TEST=specula \
            SPECULA_SCENARIO="$scenario" \
            TARGET_ARCH=x86_64 \
            SMP=2 \
            MEM=2G \
            ENABLE_KVM=1 \
            QEMU_HOSTFWD=off \
            CONSOLE=hvc0 \
            LOG_LEVEL=error \
            INITRAMFS_SKIP_GZIP=1
        cp qemu.log "/work/.specula-output/harness/build/logs/$scenario.qemu.log"
    done
' bash "${scenarios[@]}"

for scenario in "${scenarios[@]}"; do
    log_file="$logs_dir/$scenario.qemu.log"
    trace_file="$traces_dir/specula-$scenario.ndjson"
    raw_dir="$traces_dir/raw/$scenario"
    cfg_file="$cfg_dir/specula-$scenario.cfg"
    stats_file="$stats_dir/specula-$scenario.json"

    if ! rg -q "^SPECULA_SCENARIO_DONE $scenario" "$log_file"; then
        echo "$scenario did not report completion" >&2
        exit 1
    fi
    preprocess_args=(
        --log "$log_file" \
        --output "$trace_file" \
        --raw-dir "$raw_dir" \
        --cfg-template "$output_dir/spec/Trace.cfg" \
        --cfg-output "$cfg_file" \
        --stats-output "$stats_file"
    )
    if [[ $scenario == ramfs_fault_vector ]]; then
        preprocess_args+=(
            --contention-prefix-output \
                "$traces_dir/specula-$scenario-contention-prefix.ndjson"
            --contention-prefix-cfg-output \
                "$cfg_dir/specula-$scenario-contention-prefix.cfg"
            --contention-prefix-stats-output \
                "$stats_dir/specula-$scenario-contention-prefix.json"
        )
    fi
    timeout 60 python3 "$harness_dir/src/preprocess_trace.py" \
        "${preprocess_args[@]}"
done

timeout 60 python3 "$harness_dir/src/check_traces.py" \
    --traces-dir "$traces_dir" \
    --stats-dir "$stats_dir" \
    --trace-spec "$output_dir/spec/Trace.tla" \
    --module "$harness_dir/src/tla_trace.rs" \
    --output "$harness_dir/build/coverage.json"

for stats_file in "$stats_dir"/specula-*.json; do
    python3 - "$stats_file" <<'PY'
import json
import sys

stats = json.load(open(sys.argv[1]))
print(
    f"{sys.argv[1]}: {stats['events']} events, "
    f"{len(stats['event_types'])} event types, "
    f"overlap={stats['overlap_rate']:.1%}"
)
PY
done
