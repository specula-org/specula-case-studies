#!/usr/bin/env bash
set -euo pipefail
mode="${1:---diagnostic}"
if (( $# > 1 )) || [[ "$mode" != --diagnostic && "$mode" != --outcome && "$mode" != --consistency ]]; then
    printf 'Usage: %s [--outcome|--diagnostic|--consistency]\n' "$0" >&2
    exit 64
fi
[[ "$mode" != --diagnostic ]] || mode=--outcome
gate_args=("$mode")
fixture_args=()
boot_args=()
[[ "$mode" != --outcome ]] || { fixture_args+=(--outcome); boot_args+=(--outcome); }
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
lane_dir="$(cd -- "$harness_dir/../.." && pwd)"
source_dir="$lane_dir/source"
attempt="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
evidence="$harness_dir/evidence/$attempt"
traces="$harness_dir/../traces"
mkdir -p "$evidence" "$harness_dir/build"
image_ref=asterinas/dev:0.18.1-20260926
image_id=sha256:897cb1b354b3d7d28184d7a417c27565390fc3fa6886b328d2588e6de93c1dab
# The pinned asterinas/dev image exists only in the user's rootless daemon, which the
# lane preflight checked; the rootful daemon lacks it, so address the rootless socket.
docker_cmd=(docker -H unix:///run/user/1000/docker.sock)
container_base="specula-wait-reap-20261005-$attempt"
container_name="$container_base-fixture-build"

python3 - "$evidence" <<'PY'
from pathlib import Path
import datetime,json,sys
mem={k:int(v.split()[0]) for k,v in (line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())}
Path(sys.argv[1],'preflight-memory.json').write_text(json.dumps({
  'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
  'MemAvailable_kB':mem['MemAvailable'], 'required_kernel_build_kB':10*1024*1024},indent=2)+'\n')
PY
if ! python3 "$harness_dir/src/review_gate.py" "${gate_args[@]}" >"$evidence/review-gate.log" 2>&1; then
    cp "$harness_dir/review-gate.json" "$evidence/review-gate.json"
    printf '%s\n' '{"status":"INCOMPLETE_REVIEW_GATE","build":"NOT_RUN","linux_control":"NOT_RUN","asterinas_runtime":"NOT_RUN","trace_validation":"NOT_RUN"}' >"$evidence/status.json"
    cat "$evidence/review-gate.log"
    exit 78
fi

admit_memory() {
    python3 - "$evidence" "$1" <<'PY'
from pathlib import Path
import datetime,json,sys
mem={k:int(v.split()[0]) for k,v in (line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())}
# User decision 2026-10-09: gate on MemFree + Inactive(file), the measure printed by
# parallel-scopes-2026-10-04/effective-mem-gib.sh. MemAvailable understates reclaimable
# memory on this host (vm.watermark_scale_factor=2000). The 10 GiB threshold is unchanged.
effective=mem['MemFree']+mem['Inactive(file)']
passed=effective>=10*1024*1024
stage=sys.argv[2]
data={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'MemAvailable_kB':mem['MemAvailable'], 'effective_MemFree_plus_InactiveFile_kB':effective,
      'required_kB':10*1024*1024, 'stage':stage, 'admitted':passed}
Path(sys.argv[1],stage+'-memory-admission.json').write_text(json.dumps(data,indent=2)+'\n')
print(json.dumps(data))
if not passed:
    Path(sys.argv[1],'status.json').write_text(json.dumps({'status':'INCOMPLETE_RESOURCE_ADMISSION',
      'linux_control':'EXECUTED_SEE_LOGS' if stage=='kernel-build' else 'NOT_RUN',
      'asterinas_runtime':'NOT_RUN','trace_validation':'NOT_RUN'},indent=2)+'\n')
    raise SystemExit(75)
PY
}
admit_memory pre-execution
if [[ "$mode" == --outcome ]]; then
    results="$evidence/outcomes"
else
    results="$traces"
fi
mkdir -p "$results"
bash "$harness_dir/apply.sh" >"$evidence/apply.log" 2>&1
printf '%s %s\n' "$image_ref" "$image_id" >"$evidence/image-pin.txt"
"${docker_cmd[@]}" image inspect "$image_id" >"$evidence/container-image.json"
trap '"${docker_cmd[@]}" rm -f "$container_name" >/dev/null 2>&1 || true' EXIT
git -C "$source_dir" rev-parse HEAD 'HEAD^{tree}' >"$evidence/source.txt"
sha256sum "$harness_dir"/src/*.{rs,c,py} "$harness_dir/patches/instrumentation.patch" \
    "$lane_dir/.specula-output/spec/"{base.tla,Trace.tla,Trace.cfg,TraceSearch.cfg} >"$evidence/inputs.sha256"
lslocks --json --output PID,COMMAND,MODE,PATH >"$evidence/locks.json"

# The controller owns heavy.lock. This script records ownership and never
# recursively acquires that lock inside the admitted phase.
# Build containers need the network. The source's rust-toolchain.toml lists targets and
# components that the pinned image lacks (for example x86_64-unknown-none), and rustup
# installs them on first use. Guest and Linux-control containers stay offline.
# The lane-owned volume keeps rustup's first-use downloads for the kernel build. Docker
# seeds an empty named volume from the image's /root/.rustup on first mount.
rustup_volume=specula-wait-reap-20261005-rustup
timeout 1800 "${docker_cmd[@]}" run --rm --pull=never --name "$container_name" \
    --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --network=bridge \
    -v "$rustup_volume:/root/.rustup" \
    -v "$lane_dir:/work" -w /work/source "$image_id" bash -euc '
    export CARGO_BUILD_JOBS=2
    cc --version
    readlink -f /usr/bin/cc
    sha256sum /usr/include/x86_64-linux-gnu/sys/wait.h /usr/include/x86_64-linux-gnu/sys/syscall.h /usr/include/x86_64-linux-gnu/bits/types/siginfo_t.h /usr/lib/x86_64-linux-gnu/libc.a
    rustc --version
    rustup show
    rustup target list --installed
    ldd --version
    timeout 120 make -C test/initramfs/src/regression/process/wait_reap_trace \
        TEST_PLATFORM=asterinas OUTPUT_DIR=/work/.specula-output/harness/build/guest \
        BUILD_DIR=/work/.specula-output/harness/build/guest-deps
    timeout 120 make -C test/initramfs/src/regression/process/wait_reap_trace \
        TEST_PLATFORM=linux OUTPUT_DIR=/work/.specula-output/harness/build/linux \
        BUILD_DIR=/work/.specula-output/harness/build/linux-deps
    # The pinned image has no /bin/busybox. Its only static x86-64 BusyBox is this Nix
    # store build, which provides sh/ash but no nproc, so a static probe reports CPUs.
    busybox=/nix/store/303jirpnxxqssvpansrgxy7vk6zdyj9g-busybox-1.37.0/bin/busybox
    printf "%s  %s\n" 040f27e8c6075fcd7aefcd977d7c39cb9d35880c318a6ffc2db336353eb6f9fd "$busybox" | sha256sum -c -
    "$busybox" sh -c "exit 0"
    readelf -l "$busybox" > /work/.specula-output/harness/build/busybox-program-headers.txt
    if grep -q INTERP /work/.specula-output/harness/build/busybox-program-headers.txt; then
        printf "Guest init requires static BusyBox.\n" >&2
        exit 1
    fi
    cp "$busybox" /work/.specula-output/harness/build/guest/busybox
    cc -static -O2 -Wall -Werror -o /work/.specula-output/harness/build/guest/nproc_probe \
        /work/.specula-output/harness/src/nproc_probe.c
    readelf -l /work/.specula-output/harness/build/guest/nproc_probe > /work/.specula-output/harness/build/nproc-probe-program-headers.txt
    if grep -q INTERP /work/.specula-output/harness/build/nproc-probe-program-headers.txt; then
        printf "Guest CPU probe must be static.\n" >&2
        exit 1
    fi
    ' >"$evidence/fixture-build.log" 2>&1
sha256sum "$harness_dir/build/guest/busybox" "$harness_dir/build/guest/nproc_probe" >"$evidence/guest-busybox.sha256"
cp "$harness_dir/build/busybox-program-headers.txt" "$harness_dir/build/nproc-probe-program-headers.txt" "$evidence/"

linux_cpu_args=()
if [[ "$mode" == --outcome ]]; then
    # A CPU quota alone does not restrict placement. Pin the control to two
    # eligible host CPUs, while retaining the approved quota and memory limits.
    linux_cpus=$(python3 - <<'PY'
import os
cpus = sorted(os.sched_getaffinity(0))
assert len(cpus) >= 2
print(','.join(map(str, cpus[:2])))
PY
)
    # Rootless Docker here has no cpuset controller, so the daemon discards --cpuset-cpus with a
    # warning. The control also pins itself with taskset inside the container.
    linux_cpu_args+=(--cpuset-cpus="$linux_cpus" -e WR_LINUX_CPUS="$linux_cpus")
    printf '%s\n' "$linux_cpus" >"$evidence/linux-control-cpus.txt"
fi
while read -r case_name scenario value delay pair readiness wr_ids modes; do
    [[ -z "$case_name" || "$case_name" == \#* ]] && continue
    [[ "$mode" != --consistency || "$modes" == both ]] || continue
    container_name="$container_base-linux-$case_name"
    run_rc=0
    timeout 30 "${docker_cmd[@]}" run --rm --pull=never --name "$container_name" \
        --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --network=none \
        "${linux_cpu_args[@]}" \
        -v "$harness_dir/build/linux:/fixture:ro" "$image_id" \
        bash -euc 'pin=(); [ -z "${WR_LINUX_CPUS:-}" ] || pin=(taskset -c "$WR_LINUX_CPUS"); count=$("${pin[@]}" nproc); printf "WR_CONTROL_NPROC %s\n" "$count"; exec "${pin[@]}" timeout 25 /fixture/process/wait_reap_trace/wait_reap_trace "$@"' \
        fixture "$scenario" "$value" "$delay" "$pair" "$readiness" "${fixture_args[@]}" \
        >"$evidence/linux-$case_name.log" 2>&1 || run_rc=$?
    if [[ "$mode" == --outcome ]]; then
        if (( run_rc != 0 )); then
            "${docker_cmd[@]}" rm -f "$container_name" >>"$evidence/linux-$case_name.log" 2>&1 || true
        fi
        python3 "$harness_dir/src/collect.py" --outcome --linux-control --case "$case_name" --run-exit-code "$run_rc" \
            "$evidence/linux-$case_name.log" "$results/linux-$case_name.outcome.json"
    else
        (( run_rc == 0 )) || exit "$run_rc"
        python3 "$harness_dir/src/collect.py" --clock-diagnostic --linux-control \
            "$evidence/linux-$case_name.log" "$traces/$attempt-linux-$case_name.diagnostic.json"
    fi
done <"$harness_dir/cases.tsv"
if [[ "$mode" == --consistency ]]; then
    container_name="$container_base-linux-calibration"
    timeout 30 "${docker_cmd[@]}" run --rm --pull=never --name "$container_name" \
        --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --network=none \
        -v "$harness_dir/build/linux:/fixture:ro" "$image_id" \
        bash -euc 'count=$(nproc); printf "WR_CONTROL_NPROC %s\n" "$count"; exec timeout 25 /fixture/process/wait_reap_trace/wait_calibration' \
        >"$evidence/linux-calibration.log" 2>&1
fi
sha256sum "$harness_dir"/build/{guest,linux}/process/wait_reap_trace/* >"$evidence/binaries.sha256"

admit_memory kernel-build

container_name="$container_base-kernel-build"
# The pinned image's Cargo cache lacks the pin's git and OSDK dependencies, so they are fetched
# online with --locked from the checked-in lockfiles first. The OSDK kernel build then runs with
# CARGO_NET_OFFLINE, because its generated workspace has no lockfile and would otherwise resolve
# newer versions online. Its resulting lockfiles are logged as dependency provenance.
# Without a lockfile, offline Cargo must resolve git tags such as smoltcp's, which the fetched
# git cache does not hold, so the build failed. The generated workspace is therefore seeded with
# the checked-in root Cargo.lock: OSDK reuses an existing base crate whose Cargo.toml, main.rs
# and linker scripts are unchanged, and Cargo then keeps every locked version offline. A first
# offline pass only generates the base crate when it does not exist yet, and its failure is expected.
# build-std also needs the sysroot library workspace's dependencies, fetched with its own lockfile.
# Inner limits sum to 5400 s, leaving 600 s of the outer budget for startup and logging.
timeout 6000 "${docker_cmd[@]}" run --rm --pull=never --name "$container_name" \
    --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --network=bridge \
    -v "$rustup_volume:/root/.rustup" \
    -v "$lane_dir:/work" -w /work/source "$image_id" bash -euc '
    export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
    timeout 600 rustup show
    timeout 600 cargo fetch --locked
    timeout 600 cargo fetch --locked --manifest-path osdk/Cargo.toml
    timeout 600 cargo fetch --locked --manifest-path "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
    export CARGO_NET_OFFLINE=true
    timeout 1200 cargo build --manifest-path osdk/Cargo.toml --locked --target-dir /work/.specula-output/harness/build/osdk
    cd kernel
    base=/work/.specula-output/harness/build/kernel/asterinas-run-base
    if [ ! -f "$base/Cargo.toml" ]; then
        timeout 300 /work/.specula-output/harness/build/osdk/debug/cargo-osdk osdk build --release \
            --target-arch x86_64 --boot-method vmm-direct --strip-elf \
            --output /work/.specula-output/harness/build/kernel || echo WR_BASE_CRATE_GENERATION_PASS_FAILED_AS_EXPECTED
    fi
    test -f "$base/Cargo.toml"
    cp /work/source/Cargo.lock "$base/Cargo.lock"
    echo "WR_SEEDED_LOCKFILE $(sha256sum /work/source/Cargo.lock)"
    timeout 1500 /work/.specula-output/harness/build/osdk/debug/cargo-osdk osdk build --release \
        --target-arch x86_64 --boot-method vmm-direct --strip-elf \
        --output /work/.specula-output/harness/build/kernel
    diff -u /work/source/Cargo.lock "$base/Cargo.lock" || true
    cd ..
    rustup target list --installed
    # OSDK generates the kernel workspace, for example asterinas-run-base, under the --output directory.
    find /work/.specula-output/harness/build/kernel -maxdepth 2 -name Cargo.lock -print -exec sha256sum {} \; -exec cat {} \;
    test -n "$(find /work/.specula-output/harness/build/kernel -maxdepth 2 -name Cargo.lock -print -quit)" || echo WR_NO_GENERATED_KERNEL_LOCKFILE
    ' >"$evidence/kernel-build.log" 2>&1

kernel_path="$harness_dir/build/kernel/asterinas-osdk-bin.elf"
test -s "$kernel_path"
sha256sum "$kernel_path" >"$evidence/kernel.sha256"
binaries=(wait_reap_trace)
[[ "$mode" != --consistency ]] || binaries+=(wait_calibration)
for binary in "${binaries[@]}"; do
    python3 "$harness_dir/src/initramfs.py" \
        "$harness_dir/build/guest/process/wait_reap_trace/$binary" "$harness_dir/build/guest/busybox" \
        "$harness_dir/build/guest/nproc_probe" "$harness_dir/build/$binary.cpio"
done
sha256sum "$harness_dir/build/"*.cpio >"$evidence/initramfs.sha256"

while read -r case_name scenario value delay pair readiness wr_ids modes; do
    [[ -z "$case_name" || "$case_name" == \#* ]] && continue
    [[ "$mode" != --consistency || "$modes" == both ]] || continue
    container_name="$container_base-guest-$case_name"
    run_rc=0
    timeout 125 "${docker_cmd[@]}" run --rm --pull=never --name "$container_name" \
        --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --network=none --device=/dev/kvm \
        -v "$lane_dir:/work" "$image_id" \
        timeout 120 python3 /work/.specula-output/harness/src/boot.py "${boot_args[@]}" \
        --kernel /work/.specula-output/harness/build/kernel/asterinas-osdk-bin.elf \
        --initramfs /work/.specula-output/harness/build/wait_reap_trace.cpio \
        --log "/work/.specula-output/harness/evidence/$attempt/guest-$case_name.log" "$scenario" "$value" "$delay" "$pair" "$readiness" || run_rc=$?
    if [[ "$mode" == --outcome ]]; then
        if (( run_rc != 0 )); then
            "${docker_cmd[@]}" rm -f "$container_name" >>"$evidence/guest-$case_name.log" 2>&1 || true
        fi
        python3 "$harness_dir/src/collect.py" --outcome --case "$case_name" --run-exit-code "$run_rc" \
            "$evidence/guest-$case_name.log" "$results/guest-$case_name.outcome.json"
    else
        (( run_rc == 0 )) || exit "$run_rc"
        python3 "$harness_dir/src/collect.py" --consistency "$evidence/guest-$case_name.log" "$traces/$attempt-guest-$case_name.ndjson"
    fi
done <"$harness_dir/cases.tsv"
if [[ "$mode" == --consistency ]]; then
    container_name="$container_base-guest-calibration"
    timeout 125 "${docker_cmd[@]}" run --rm --pull=never --name "$container_name" \
        --cpus=2 --memory=8g --memory-swap=8g --pids-limit=512 --network=none --device=/dev/kvm \
        -v "$lane_dir:/work" "$image_id" \
        timeout 120 python3 /work/.specula-output/harness/src/boot.py \
        --kernel /work/.specula-output/harness/build/kernel/asterinas-osdk-bin.elf \
        --initramfs /work/.specula-output/harness/build/wait_calibration.cpio \
        --log "/work/.specula-output/harness/evidence/$attempt/guest-calibration.log" --calibration calibration 37 0
fi
printf 'Collection evidence: %s\n' "$evidence"
printf 'Collection mode: %s. Output directory: %s\n' "$mode" "$results"
if [[ "$mode" == --outcome ]]; then
    python3 - "$results" "$evidence/status.json" <<'PY'
from collections import Counter
import json
from pathlib import Path
import sys
reports = [json.loads(p.read_text()) for p in sorted(Path(sys.argv[1]).glob('*.outcome.json'))]
Path(sys.argv[2]).write_text(json.dumps(dict(status='OUTCOMES_RECORDED', mode='outcome',
    evidence_class='OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE', implementation_trace='NONE',
    trace_validation='BLOCKED_ENVIRONMENT', comparisons=dict(Counter(r['comparison'] for r in reports)),
    runs=len(reports)), indent=2) + '\n')
PY
    printf 'Syscall outcomes recorded. Implementation trace: NONE. Trace validation: BLOCKED_ENVIRONMENT.\n'
else
    printf 'Diagnostics are INELIGIBLE. Any grouped output carries the sampled-bound consistency claim. Trace validation was NOT_RUN.\n'
fi
