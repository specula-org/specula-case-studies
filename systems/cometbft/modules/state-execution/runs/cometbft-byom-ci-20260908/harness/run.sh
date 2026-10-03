#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_root="$(cd "$script_dir/.." && pwd)"
source_root="${SPECULA_SOURCE:-$(cd "$output_root/.." && pwd)/source}"
trace_dir="${SPECULA_TRACE_DIR:-$output_root/traces}"
log_dir="${SPECULA_HARNESS_LOG_DIR:-$output_root/spec/output}"
temporary_root=""

cleanup() {
    if [[ -n "$temporary_root" && "$temporary_root" == "$output_root"/.harness-work.* ]]; then
        find "$temporary_root" -xdev -depth -delete
    fi
}
trap cleanup EXIT

if [[ ! -d "$source_root/.git" ]]; then
    echo "Immutable CometBFT source checkout not found: $source_root" >&2
    echo "Set SPECULA_SOURCE to the initialization source checkout." >&2
    exit 1
fi
source_head="$(git -C "$source_root" rev-parse HEAD)"

if [[ -n "${SPECULA_WORK_SOURCE:-}" ]]; then
    work_source="$SPECULA_WORK_SOURCE"
    if [[ ! -d "$work_source/.git" ]]; then
        echo "Writable CometBFT git checkout not found: $work_source" >&2
        exit 1
    fi
    if [[ "$(cd "$work_source" && pwd -P)" == "$(cd "$source_root" && pwd -P)" ]]; then
        echo "SPECULA_WORK_SOURCE must not be the immutable source checkout." >&2
        exit 1
    fi
    work_head="$(git -C "$work_source" rev-parse HEAD)"
    if [[ "$work_head" != "$source_head" ]]; then
        echo "Writable checkout is at $work_head; expected source HEAD $source_head" >&2
        exit 1
    fi
else
    temporary_root="$(mktemp -d "$output_root/.harness-work.XXXXXX")"
    work_source="$temporary_root/source"
    timeout 10m git clone --quiet --no-hardlinks --no-checkout "$source_root" "$work_source"
    timeout 2m git -C "$work_source" checkout --quiet --detach "$source_head"
fi

"$script_dir/apply.sh" "$work_source"
mkdir -p "$trace_dir" "$log_dir"

run_case() {
    local name="$1"
    local package="$2"
    local test_filter="$3"
    local trace_file="$trace_dir/$name.ndjson"
    local log_file="$log_dir/harness-${name//_/-}.log"

    : > "$trace_file"
    (
        cd "$work_source"
        set -o pipefail
        timeout 10m env SPECULA_TRACE_FILE="$trace_file" \
            go test -mod=readonly "$package" -run "$test_filter" -count=1 2>&1 \
            | tee "$log_file"
    )
    test -s "$trace_file"
    jq -e -s 'length > 0 and all(.[]; .tag == "trace" and (.event.name | type == "string") and (.event.state | type == "object"))' \
        "$trace_file" >/dev/null
    echo "$name: $(wc -l < "$trace_file") trace events"
}

run_case apply_valid ./internal/state '^TestSpeculaTraceApplyValidUpdate$'
run_case apply_rejected ./internal/state '^TestSpeculaTraceApplyRejectedUpdate$'
run_case replay_app_only ./internal/consensus '^TestHandshakeReplaySome$/^mode_0_single$'
run_case replay_real ./internal/consensus '^TestHandshakeReplayNone$/^mode_1_single$'
run_case replay_mock ./internal/consensus '^TestHandshakeReplayNone$/^mode_2_single$'
run_case replay_none ./internal/consensus '^TestHandshakeReplayNone$/^mode_0_single$'

echo "Fresh traces written below $trace_dir"
