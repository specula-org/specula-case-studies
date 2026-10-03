#!/usr/bin/env bash
set -euo pipefail
spec_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
run_dir="$(cd -- "$spec_dir/../../.." && pwd)"
pinned_root="$(cd -- "$run_dir/../../.." && pwd)/Specula"
task_tmp="$run_dir/tmp/spec-generation"
state_root="$run_dir/tlc-states/spec-generation"
mkdir -p "$task_tmp" "$state_root" "$spec_dir/output"
cd -- "$spec_dir"
java_args=(-Xmx4g -XX:MaxDirectMemorySize=1g -XX:+UseParallelGC "-Djava.io.tmpdir=$task_tmp" "-DTLA-Library=$pinned_root/lib" -cp "$pinned_root/lib/tla2tools.jar:$pinned_root/lib/CommunityModules-deps.jar")
mode="${1:-syntax}"
if [[ "$mode" == syntax ]]; then
    for module in base MC Trace Quality QualityTrace QualityDecisions QualityCampaignObservations ConfigurationProgress QualityManagement SourceAlignmentChecks; do
        timeout 2m java "${java_args[@]}" tla2sany.SANY "$module.tla" > "output/syntax-$module.log" 2>&1
        if rg -q 'Semantic errors:|Parse Error|Fatal errors|\*\*\* Errors:' "output/syntax-$module.log"; then
            cat "output/syntax-$module.log"
            exit 1
        fi
        printf '%s: syntax and semantic analysis passed\n' "$module"
    done
    exit 0
fi
case "$mode" in
    smoke) config=MC_smoke.cfg; module=MC ;;
    simulate) config="${2:-MC.cfg}"; module=MC ;;
    check) config="${2:-MC.cfg}"; module=MC ;;
    trace) exec python3 "$spec_dir/../harness/validate.py" ;;
    *) printf 'usage: %s {syntax|smoke|check [cfg]|simulate [cfg]|trace}\n' "$0" >&2; exit 2 ;;
esac
export SPECULA_WORK_DIR="${SPECULA_WORK_DIR:-$spec_dir/..}"
export SPECULA_RUN_DIR="${SPECULA_RUN_DIR:-$run_dir}"
export SPECULA_TLC_SCOPE="${SPECULA_TLC_SCOPE:-$run_dir}"
export SPECULA_TLC_MEMORY_LIMIT="${SPECULA_TLC_MEMORY_LIMIT:-200G}"
export SPECULA_TLC_WORKER_LIMIT="${SPECULA_TLC_WORKER_LIMIT:-60}"
export TMPDIR="${TMPDIR:-$task_tmp}"
export TLC_STATE_DIR="${TLC_STATE_DIR:-$state_root}"
export PYTHONPATH="$pinned_root/src${PYTHONPATH:+:$PYTHONPATH}"
python3 - "$spec_dir" "$module" "$config" "$mode" <<'PYTASK'
import asyncio,json,sys
from pathlib import Path
from specula.tlc_tasks import start_tlc,wait_tlc
async def main():
    work,module,cfg,mode=sys.argv[1:]
    options=['-m','4G','-M','1G','-w','2','-t','5']
    if mode=='simulate':options += ['-S','-n','999999999','-p','100']
    r=await start_tlc(work,module+'.tla',cfg,options)
    Path(work,'output','entrypoint-'+r['task_id']+'.json').write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps({'tlc_started':r}),flush=True)
    while True:
        result=await wait_tlc([r['task_id']],55,'all')
        if result['outcome']=='finished':break
    print(json.dumps(result));return result['tasks'][0]['exit_code'] or 0
raise SystemExit(asyncio.run(main()))
PYTASK
