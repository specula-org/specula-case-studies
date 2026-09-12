#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$(dirname "$harness_dir")"
source_dir="${TEMPORAL_SOURCE:-/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-update}"
mkdir -p "$harness_dir/evidence" "$output_dir/traces"
bash "$harness_dir/apply.sh" "$source_dir"
export CGO_ENABLED=0 GOMAXPROCS="${GOMAXPROCS:-8}"
export GOTMPDIR="${GOTMPDIR:-$harness_dir/evidence/build-tmp}"
mkdir -p "$GOTMPDIR"
export SPECULA_TRACE_DIR="$output_dir/traces"
python3 - "$source_dir" "$harness_dir" <<'PY'
import datetime,hashlib,json,os,subprocess,sys
from pathlib import Path
source,h=map(Path,sys.argv[1:])
record={'startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'source':str(source),'revision':subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),
        'go':subprocess.check_output(['go','version'],cwd=source,text=True).strip(),
        'env':{k:os.environ[k] for k in ('CGO_ENABLED','GOMAXPROCS','GOTMPDIR','SPECULA_TRACE_DIR')},
        'patchSHA256':hashlib.sha256((h/'patches/instrumentation.patch').read_bytes()).hexdigest(),
        'build':['go','test','-c','-tags','test_dep,disable_grpc_modules','-p','4','./tests'],
        'test':['temporal-tests','-test.run','^TestSpeculaUpdateTrace$','-test.v','-test.timeout=6m','-persistenceType=sql','-persistenceDriver=sqlite']}
(h/'evidence/run-command.json').write_text(json.dumps(record,indent=2)+'\n')
PY
cd "$source_dir"
timeout 600 go test -c -tags test_dep,disable_grpc_modules -p 4     -o "$harness_dir/evidence/temporal-tests" ./tests > "$harness_dir/evidence/test-build.log" 2>&1
(
    cd tests
    timeout 420 "$harness_dir/evidence/temporal-tests" -test.run '^TestSpeculaUpdateTrace$'         -test.v -test.timeout=6m -persistenceType=sql -persistenceDriver=sqlite         > "$harness_dir/evidence/scenarios.log" 2>&1
)
echo "All nine real Temporal/SQLite scenarios passed."
bash "$harness_dir/validate.sh"
