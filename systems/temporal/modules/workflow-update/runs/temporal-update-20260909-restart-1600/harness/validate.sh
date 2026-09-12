#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$(dirname "$harness_dir")"
tool_dir="${TLA_TOOLS_DIR:-/home/ubuntu/Specula-incremental-dataset-20260815/tools}"
test -f "$tool_dir/tla2tools.jar"
test -f "$tool_dir/CommunityModules-deps.jar"
python3 "$harness_dir/audit.py"
for scenario in healthy noncommit Timeout ExecuteAndTimeout rejection_skip accepted_close dispatch_failure stale_completion; do
    prefix="$harness_dir/evidence/replay-prefixes/$scenario.ndjson"
    python3 "$harness_dir/admission_prefix.py" "$output_dir/traces/$scenario.ndjson" "$prefix"
    (
        cd "$output_dir/spec"
        timeout 120 env JSON="$prefix" java -Xmx2g -XX:+UseParallelGC             -cp "$tool_dir/tla2tools.jar:$tool_dir/CommunityModules-deps.jar"             tlc2.TLC -workers 1 -config Trace.cfg             -metadir "$harness_dir/evidence/tlc-$scenario" Trace.tla             > "$harness_dir/evidence/trace-validation-$scenario.log" 2>&1
    )
    echo "$scenario: admission prefix passed (3 transitions); full trace INCOMPLETE"
done
python3 - "$harness_dir" <<'PY'
import json,sys
from pathlib import Path
h=Path(sys.argv[1])
(h/'evidence/validation-result.json').write_text(json.dumps({
    'status':'INCOMPLETE','completeTracePasses':0,'prefixPasses':8,
    'prefixActionTypes':['UpdateWorkflowExecution','UpdaterApplyRequestNew','AddWorkflowTaskScheduledEvent'],
    'reason':'Only measured admission prefixes have a full-state mapping. Remaining source/model boundaries and capture gaps are documented in INSTRUMENTATION.md.',
    'postStateComparison':'strict full equality', 'silentActions':0
},indent=2)+'\n')
PY
echo "INCOMPLETE: full traces cannot yet be replayed against the supplied Trace.tla."
exit 2
