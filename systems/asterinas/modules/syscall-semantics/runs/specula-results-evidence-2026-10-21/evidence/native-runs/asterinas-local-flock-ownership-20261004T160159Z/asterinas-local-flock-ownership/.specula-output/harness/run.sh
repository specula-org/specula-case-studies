#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(realpath "$harness_dir/../../source")
output_dir=$(realpath "$harness_dir/..")
[[ -f "$harness_dir/evidence/runtime-reviewed.sha256" ]] || { echo 'INCOMPLETE: exact-version corrective review is pending' >&2; exit 2; }
(cd "$harness_dir" && sha256sum -c evidence/runtime-reviewed.sha256)
container=specula-flock-harness-20261005
docker=(sudo -n docker -H unix:///var/run/docker.sock)
attempt="$harness_dir/evidence/attempt-$(date -u +%Y%m%dT%H%M%S-%N)"
mkdir -p "$attempt"
printf '%s\n' "$attempt" > "$harness_dir/evidence/latest-attempt.txt"
python3 - "$attempt" <<'PY'
import hashlib,json,pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1]); h=out.parent.parent
available=int(next(x.split()[1] for x in pathlib.Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:')))
locks=json.loads(subprocess.check_output(['lslocks','-J','-o','PID,PATH,MODE'],text=True))['locks']
held=[l for l in locks if l.get('path')=='/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/heavy.lock' and l.get('mode')=='WRITE']
manifest={'memavailable_kib':available,'heavy_lock_holders':held,'inputs':{}}
for p in sorted(list((h/'src').glob('*'))+list((h/'patches').glob('*'))+list(h.glob('*.sh'))+list((h.parent/'spec').glob('*.tla'))+list((h.parent/'spec').glob('*.cfg'))+[h.parent/'spec/generation-checks/validate_trace.py',h.parent/'spec/instrumentation-spec.md']):
    if not p.is_file(): continue
    key=str(p.relative_to(h.parent)); data=p.read_bytes()
    manifest['inputs'][key]=hashlib.sha256(data).hexdigest()
    dest=out/'inputs'/key; dest.parent.mkdir(parents=True,exist_ok=True); dest.write_bytes(data)
(out/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
if not held: raise SystemExit('no observed controller heavy-lock holder; return to the controller')
if available < 10*1024*1024: raise SystemExit('MemAvailable below the 10 GiB build admission threshold')
PY
bash "$harness_dir/apply.sh" "$source_dir" > "$attempt/apply.log" 2>&1
if ! "${docker[@]}" inspect "$container" >/dev/null 2>&1; then
    "${docker[@]}" create --name "$container" --cpus 2 --memory 8g --pids-limit 512 --device /dev/kvm \
        -v "$source_dir:/source" -v "$harness_dir:/harness" -w /source \
        asterinas/kernel-dev:0.18.1-20260926 sleep infinity > "$harness_dir/evidence/container-id.txt"
fi
[[ $("${docker[@]}" inspect -f '{{.Id}}' "$container") == $(cat "$harness_dir/evidence/container-id.txt") ]]
"${docker[@]}" start "$container" > "$attempt/container-start.log"
"${docker[@]}" inspect "$container" > "$attempt/container.json"
# The guest-side gate reads the same companion paths as the host-side gate.
"${docker[@]}" exec "$container" mkdir -p /spec/generation-checks
for spec_input in base.tla Trace.tla Trace.cfg instrumentation-spec.md generation-checks/validate_trace.py; do
    "${docker[@]}" cp "$output_dir/spec/$spec_input" "$container:/spec/$spec_input"
done
set +e
timeout 1800 "${docker[@]}" exec "$container" timeout 1770 bash /harness/src/build.sh > "$attempt/build.log" 2>&1
build_status=$?
set -e
printf '%s\n' "$build_status" > "$attempt/build.exit"
if [[ $build_status != 0 ]]; then
    if [[ $build_status == 124 ]]; then "${docker[@]}" stop -t 10 "$container" > "$attempt/container-stop.log"; fi
    echo "INCOMPLETE: build exited $build_status; evidence: $attempt"
    exit 2
fi
for control_case in C01 C02 C03 C04 C05; do
    timeout 120 "${docker[@]}" run --rm --cpus 2 --memory 8g --pids-limit 512 --tmpfs /tmp:rw,nosuid,size=64m \
        -v "$harness_dir/build/root/init:/fixture:ro" -e "SPECULA_CASE=$control_case" \
        asterinas/kernel-dev:0.18.1-20260926 timeout 60 /fixture > "$attempt/linux-$control_case.log" 2>&1
done
for case_name in C00-open-overlap C01 C02 C03 C04 C05 C06 C07-before C07-after C07-notify C08 C09 C10 C11 C12-alias C12-before C12-after C13-open-close; do
    set +e
    timeout 240 "${docker[@]}" exec "$container" timeout 220 bash /harness/src/run_case.sh "$case_name" > "$attempt/$case_name.log" 2>&1
    status=$?
    set -e
    printf '%s\n' "$status" > "$attempt/$case_name.exit"
    python3 "$harness_dir/src/collect.py" "$attempt/$case_name.log" "$output_dir/traces" "$case_name" "$attempt"
    if [[ $status != 0 ]]; then
        echo "INCOMPLETE: $case_name exited $status; preserve its prefix and return for review"
        exit 2
    fi
done
set +e
python3 "$harness_dir/src/check_traces.py" "$output_dir/traces" "$output_dir/spec" > "$attempt/coverage.json"
coverage_status=$?
set -e
# The supplied adapter preserves the reviewed existential witness semantics.
cd "$output_dir/spec"
for trace_file in "$output_dir/traces/"*.ndjson; do
    python3 - <<'MEMORY'
from pathlib import Path
available=int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:')))
if available < 6*1024*1024: raise SystemExit('INCOMPLETE: wait for the 6 GiB TLC admission threshold')
MEMORY
    timeout 1800 python3 generation-checks/validate_trace.py "$trace_file"
done

if [[ $coverage_status != 0 ]]; then
    echo "INCOMPLETE: supplied traces validated, but coverage obligations remain; see $attempt/coverage.json"
    exit 2
fi
