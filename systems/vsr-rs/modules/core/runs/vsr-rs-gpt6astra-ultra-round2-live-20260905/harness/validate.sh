#!/usr/bin/env bash
# Replay captured Rust traces against the complete supplied Trace.cfg contract.
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=$(cd -- "$harness_dir/.." && pwd)
validation_dir="$harness_dir/validation"
mkdir -p -- "$validation_dir"

tla_jar=${TLA_TOOLS_JAR:-/home/ubuntu/Specula-incremental-dataset-100-20260819/tools/tla2tools.jar}
community_jar=${COMMUNITY_MODULES_JAR:-/home/ubuntu/Specula-incremental-dataset-100-20260819/tools/CommunityModules-deps.jar}
validation_timeout=${TRACE_VALIDATION_TIMEOUT:-180}
[[ -r "$tla_jar" && -r "$community_jar" ]] || { echo 'Set TLA_TOOLS_JAR and COMMUNITY_MODULES_JAR to readable compatible jars.' >&2; exit 2; }
[[ "$validation_timeout" =~ ^[0-9]+$ ]] && (( validation_timeout > 0 && validation_timeout <= 1800 )) || { echo 'TRACE_VALIDATION_TIMEOUT must be 1..1800 seconds.' >&2; exit 2; }
tla_jar=$(realpath -- "$tla_jar")
community_jar=$(realpath -- "$community_jar")

if (( $# )); then
  traces=("$@")
else
  shopt -s nullglob
  traces=("$output_dir"/traces/*.ndjson)
fi
(( ${#traces[@]} )) || { echo 'No implementation NDJSON traces to validate.' >&2; exit 2; }
python3 "$harness_dir/audit_traces.py" "${traces[@]}" > "$validation_dir/audit.json"
printf 'trace\texit_code\tlog\twork_dir\n' > "$validation_dir/results.tsv"
status=0
for trace in "${traces[@]}"; do
  trace=$(realpath -- "$trace")
  name=$(basename -- "$trace" .ndjson)
  work_dir=$(mktemp -d "$validation_dir/tlc-${name}.XXXXXX")
  cp -- "$output_dir/spec/base.tla" "$output_dir/spec/Trace.tla" "$output_dir/spec/Trace.cfg" "$work_dir/"
  log="$validation_dir/${name}.log"
  printf 'Validating %s\n' "$name"
  set +e
  (
    cd -- "$work_dir"
    JSON="$trace" timeout --kill-after=10 "$validation_timeout" \
      java -XX:+UseParallelGC -Xmx2g -cp "$tla_jar:$community_jar" \
      tlc2.TLC -workers 1 -config Trace.cfg Trace.tla
  ) > "$log" 2>&1
  code=$?
  set -e
  printf '%s\t%s\t%s\t%s\n' "$trace" "$code" "$log" "$work_dir" >> "$validation_dir/results.tsv"
  if (( code == 0 )); then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s (exit %s; %s)\n' "$name" "$code" "$log" >&2
    status=1
  fi
done
exit "$status"
