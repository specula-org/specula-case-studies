#!/usr/bin/env bash
# Host-side driver for repro/test_bugMC-2_flock_temp_ref_deadlock.c (finding MC-2).
#
# Runs three guest scenarios inside the campaign's reviewed, already-built
# container (specula-flock-harness-20261005: /source at pinned 0c6053709 with
# the reviewed trace instrumentation, kernel ELF built by the harness phase):
#   MC2-L1      deterministic gate-assisted reproduction (escalation Level 1)
#   MC2-L1-ctl  negative control with an extra dup alias (must not deadlock)
#   MC2-L0      natural race, no kernel hooks (escalation Level 0)
#
# No kernel rebuild is performed; only the userspace initramfs is regenerated,
# so the 10 GiB kernel-build admission threshold does not apply.  The guest
# needs 2 GiB RAM / 2 vCPUs (QEMU via the reviewed "flock" OSDK scheme).
# Every guest run is bounded by `timeout`; a fired timeout is recorded, never
# retried silently.
set -uo pipefail
base=$(cd -- "$(dirname -- "$0")/.." && pwd)
harness_dir="$base/harness"
repro_dir="$base/repro"
fixture_src="$repro_dir/test_bugMC-2_flock_temp_ref_deadlock.c"
container=specula-flock-harness-20261005
docker=(sudo -n docker -H unix:///var/run/docker.sock)
out_dir="$repro_dir/mc2-run-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out_dir"
echo "output directory: $out_dir" | tee "$out_dir/driver.log"

# Consistency gates, mirroring the reviewed harness's own run entry checks.
(cd "$harness_dir" && sha256sum -c evidence/runtime-reviewed.sha256) \
    > "$out_dir/reviewed-hash-gate.log" 2>&1 || { echo 'FATAL: reviewed harness hashes changed' | tee -a "$out_dir/driver.log"; exit 2; }
"${docker[@]}" exec "$container" sha256sum /source/target/osdk/asterinas-osdk-bin.elf \
    > "$out_dir/kernel-elf.txt" 2>&1 || { echo 'FATAL: container/kernel ELF missing' | tee -a "$out_dir/driver.log"; exit 2; }
grep -q '^d51c220500302e72765e313e754fc780d89cfd8ddbacfea4a40f853c122d1dbb' "$out_dir/kernel-elf.txt" \
    || { echo 'FATAL: kernel ELF hash differs from the reviewed harness build' | tee -a "$out_dir/driver.log"; exit 2; }
"${docker[@]}" start "$container" >/dev/null 2>&1 || true
"${docker[@]}" cp "$fixture_src" "$container:/repro-fixture.c"

run_case() {
    local case_name=$1 timeout_s=$2
    echo "=== running case $case_name (timeout ${timeout_s}s)" | tee -a "$out_dir/driver.log"
    timeout "$timeout_s" "${docker[@]}" exec "$container" bash -c '
        set -e
        export PATH=/source/target/harness-osdk/debug:$PATH CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
        rm -rf /repro-root && mkdir -p /repro-root/{tmp,proc,sys,dev}
        gcc -O2 -static -pthread -I /source/test/initramfs/src/regression/common /repro-fixture.c -o /repro-root/init
        printf "%s\n" "$1" > /repro-root/case
        (cd /repro-root && find . -print0 | cpio --null -o --format=newc > /repro-initramfs.cpio) 2>/dev/null
        sha256sum /repro-root/init /repro-initramfs.cpio
        cd /source/kernel
        cargo osdk run --scheme flock --initramfs /repro-initramfs.cpio --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error
   ' _ "$case_name" > "$out_dir/$case_name.log" 2>&1
    local status=$?
    echo "$status" > "$out_dir/$case_name.exit"
    echo "case $case_name exit=$status" | tee -a "$out_dir/driver.log"
}

run_case MC2-L1 300
run_case MC2-L1-ctl 300
run_case MC2-L0 300

echo "=== summary" | tee -a "$out_dir/driver.log"
for c in MC2-L1 MC2-L1-ctl MC2-L0; do
    printf '%s: exit=%s verdict=' "$c" "$(cat "$out_dir/$c.exit")"
    grep -h "MC2_VERDICT" "$out_dir/$c.log" | tail -1 || true
done | tee -a "$out_dir/driver.log"
