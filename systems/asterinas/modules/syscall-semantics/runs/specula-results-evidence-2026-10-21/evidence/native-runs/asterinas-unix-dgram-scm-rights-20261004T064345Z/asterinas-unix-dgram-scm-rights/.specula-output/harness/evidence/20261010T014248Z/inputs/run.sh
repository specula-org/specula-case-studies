#!/usr/bin/env bash
set -euo pipefail
harness=$(cd -- "$(dirname -- "$0")" && pwd)
target=$(cd -- "$harness/../.." && pwd)
out="$target/.specula-output"
mkdir -p "$harness/evidence" "$out/traces" "$harness/build/cargo-git" "$harness/build/cargo-registry"
bash "$harness/apply.sh"
run_id=$(date -u +%Y%m%dT%H%M%SZ)
evidence="$harness/evidence/$run_id"
mkdir "$evidence"
mkdir "$evidence/inputs" "$evidence/normalized"
cp -r "$harness/src" "$harness/patches" "$harness/run.sh" "$harness/apply.sh" "$harness/clean.sh" "$evidence/inputs/"
git -C "$target/source" diff --binary > "$evidence/source.diff"
printf '%s\n' "$evidence" > "$harness/evidence/latest"
resource_dir=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04
cp "$resource_dir/effective-mem-gib.sh" "$evidence/inputs/"
cp /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json "$evidence/inputs/"
available=$("$resource_dir/effective-mem-gib.sh")
printf 'effective_mem_GiB=%s\n' "$available" > "$evidence/resources.txt"
while ! awk -v available="$available" 'BEGIN {exit !(available >= 10)}'; do
    printf 'Waiting for 10 GiB MemFree + Inactive(file) (currently %s GiB).\n' "$available"
    sleep 10
    available=$("$resource_dir/effective-mem-gib.sh")
done
printf 'build_start_effective_mem_GiB=%s\n' "$available" >> "$evidence/resources.txt"
docker_cmd=(sudo -n docker -H unix:///var/run/docker.sock)
image=asterinas/kernel-dev:0.18.1-20260926
"${docker_cmd[@]}" image inspect "$image" > "$evidence/image.json"
git -C "$target/source" rev-parse HEAD > "$evidence/source.txt"
sha256sum "$harness/patches/instrumentation.patch" "$harness/src/"*.{rs,c,py,sh} \
    "$out/spec/base.tla" "$out/spec/Trace.tla" "$out/spec/Trace.cfg" \
    "$out/spec/TraceSearch.cfg" "$harness/run.sh" "$harness/apply.sh" "$harness/clean.sh" \
    "$evidence/inputs/resources.json" "$evidence/inputs/effective-mem-gib.sh" > "$evidence/inputs.sha256"
container="scm-trace-$run_id"
cleanup() { "${docker_cmd[@]}" rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"${docker_cmd[@]}" create --name "$container" --cpus 2 --memory 8g --pids-limit 512 \
    --device /dev/kvm --mount "type=bind,src=$target,dst=/work" \
    --mount "type=bind,src=$target/source,dst=/home/chin39/Documents/asterinas-dev" \
    --mount "type=bind,src=$harness/build/cargo-git,dst=/root/.cargo/git" \
    --mount "type=bind,src=$harness/build/cargo-registry,dst=/root/.cargo/registry" \
    -e CARGO_NET_OFFLINE=false -e CARGO_BUILD_JOBS=2 -e OSDK_LOCAL_DEV=1 "$image" \
    timeout 1800 bash /work/.specula-output/harness/src/guest-build.sh > "$evidence/container.id"
set +e
timeout 1800 "${docker_cmd[@]}" start -a "$container" > "$evidence/build.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$evidence/build.exit"
if (( status != 0 )); then tail -60 "$evidence/build.log"; exit "$status"; fi
sha256sum "$target/source/target/osdk/asterinas-osdk-bin.iso" \
    "$target/source/target/osdk/asterinas-osdk-bin.elf" \
    "$harness/build/root/init" "$target/source/osdk/target/debug/cargo-osdk" > "$evidence/binaries.sha256"
cp "$target/source/target/osdk/asterinas-run-base/Cargo.lock" "$evidence/Cargo.lock"
"${docker_cmd[@]}" rm "$container" >/dev/null
"${docker_cmd[@]}" create --name "$container" --cpus 2 --memory 8g --pids-limit 512 \
    --device /dev/kvm --mount "type=bind,src=$target,dst=/work" \
    --mount "type=bind,src=$target/source,dst=/home/chin39/Documents/asterinas-dev" \
    --mount "type=bind,src=$harness/build/cargo-git,dst=/root/.cargo/git" \
    --mount "type=bind,src=$harness/build/cargo-registry,dst=/root/.cargo/registry" \
    "$image" timeout 300 qemu-system-x86_64 \
    -bios /root/ovmf/release/OVMF.fd -machine q35,kernel-irqchip=split \
    -m 2G -smp 2 -cpu host -accel kvm -nographic -monitor none -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -cdrom /work/source/target/osdk/asterinas-osdk-bin.iso \
    > "$evidence/guest-container.id"
set +e
timeout 360 "${docker_cmd[@]}" start -a "$container" > "$evidence/guest.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$evidence/guest.exit"
if (( status != 0 && status != 33 )) || ! rg -q '^SCM_DONE 0' "$evidence/guest.log"; then
    tail -80 "$evidence/guest.log"
    exit 1
fi
timeout 120 "$harness/build/linux-control" > "$evidence/linux.log" 2>&1
python3 "$harness/src/normalize.py" "$evidence" "$evidence/normalized"
wc -l "$evidence/normalized/"*.ndjson
python3 "$harness/src/validate.py" "$evidence"
python3 - "$evidence" <<'PY'
import json
import sys
from pathlib import Path

evidence = Path(sys.argv[1])
traces = json.loads((evidence / 'traces.json').read_text())
qualified = [t['case'] for t in traces
             if t['cross_thread_pairs'] and 5 * t['overlaps'] >= t['cross_thread_pairs']]
quality = dict(required_overlap_fraction=0.2, qualified_cases=qualified,
               passed=bool(qualified), traces=traces)
(evidence / 'overlap-quality.json').write_text(json.dumps(quality, indent=2) + '\n')
if not qualified:
    raise SystemExit('No trace meets the harness-generation skill\'s 20% cross-thread overlap requirement. '
                     'The replayed traces remain in this attempt\'s normalized directory.')
PY
cp "$evidence/normalized/"*.ndjson "$out/traces/"
printf '%s\n' "$evidence" > "$harness/evidence/accepted"
