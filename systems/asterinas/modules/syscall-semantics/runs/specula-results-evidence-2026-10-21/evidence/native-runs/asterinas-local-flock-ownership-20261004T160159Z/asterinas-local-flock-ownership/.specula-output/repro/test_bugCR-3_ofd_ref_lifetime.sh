#!/usr/bin/env bash
# Host-side driver for repro/test_bugCR-3_ofd_ref_lifetime.c (finding CR-3,
# "Last descriptor removal is not final OFD release").
#
# Runs, inside the campaign's reviewed, already-built container
# (specula-flock-harness-20261005: /source at pinned 0c6053709 with the
# reviewed trace instrumentation, kernel ELF built by the harness phase):
#   CR3-LINUX  Linux control: the same fixture run as a normal process on
#              the container's Linux (tmpfs), validating the encoded
#              expected values against real Linux behavior
#   CR3-GUEST  the fixture as the Asterinas guest init, via the reviewed
#              "flock" OSDK scheme (2 vCPU / 2 GiB), run 3 times for race
#              coverage in the threaded sections
#
# No kernel rebuild is performed (initramfs-only), so the harness phase's
# 10 GiB build admission threshold does not apply. Every run is bounded by
# `timeout`; a fired timeout is recorded, never retried silently.
set -uo pipefail
base=$(cd -- "$(dirname -- "$0")/.." && pwd)
harness_dir="$base/harness"
repro_dir="$base/repro"
fixture_src="$repro_dir/test_bugCR-3_ofd_ref_lifetime.c"
container=specula-flock-harness-20261005
docker=(sudo -n docker -H unix:///var/run/docker.sock)
out_dir="$repro_dir/cr3-run-$(date -u +%Y%m%dT%H%M%SZ)"
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

# ---- Linux control (escalation Level 0 expected-behavior validation) ----
echo "=== CR3-LINUX control (container Linux, tmpfs)" | tee -a "$out_dir/driver.log"
timeout 240 "${docker[@]}" run --rm --cpus 2 --memory 1g --pids-limit 128 \
    --tmpfs /tmp:rw,nosuid,size=64m,exec \
    -v "$repro_dir/test_bugCR-3_ofd_ref_lifetime.c:/fixture.c:ro" \
    asterinas/kernel-dev:0.18.1-20260926 \
    bash -c 'set -e; gcc -O2 -static -pthread /fixture.c -o /tmp/init && cd /tmp && timeout 60 /tmp/init' \
    > "$out_dir/CR3-LINUX.log" 2>&1
linux_status=$?
echo "CR3-LINUX exit=$linux_status" | tee -a "$out_dir/driver.log"

# ---- Asterinas guest runs (escalation Level 0, 3 repetitions) ----
run_guest() {
    local run_id=$1
    echo "=== CR3-GUEST run $run_id" | tee -a "$out_dir/driver.log"
    timeout 300 "${docker[@]}" exec "$container" bash -c '
        set -e
        export PATH=/source/target/harness-osdk/debug:$PATH CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
        rm -rf /repro-root && mkdir -p /repro-root/{tmp,proc,sys,dev}
        gcc -O2 -static -pthread /repro-fixture.c -o /repro-root/init
        (cd /repro-root && find . -print0 | cpio --null -o --format=newc > /repro-initramfs.cpio) 2>/dev/null
        sha256sum /repro-root/init /repro-initramfs.cpio
        cd /source/kernel
        timeout 240 cargo osdk run --scheme flock --initramfs /repro-initramfs.cpio --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error
    ' > "$out_dir/CR3-GUEST-$run_id.log" 2>&1
    local status=$?
    echo "CR3-GUEST-$run_id exit=$status" | tee -a "$out_dir/driver.log"
    grep -E "CR3-RESULT|CR3 SUMMARY" "$out_dir/CR3-GUEST-$run_id.log" || true
}

for i in 1 2 3; do
    run_guest "$i"
done

echo "=== per-run CR3-RESULT lines ===" | tee -a "$out_dir/driver.log"
grep -H -E "CR3-RESULT" "$out_dir"/CR3-GUEST-*.log | tee -a "$out_dir/driver.log"
echo "driver done" | tee -a "$out_dir/driver.log"
