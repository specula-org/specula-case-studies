#!/usr/bin/env bash
# Reproduction runner for finding MC-4 (REQUEUE returns only the number of
# woken waiters) -- Asterinas guest run plus native Linux control.
#
# 1. Native Linux control: compiles the same C source (no -DGUEST) and runs
#    it on the host (Linux 7.2.8), saving mc4_host_control.log. Expected:
#    every CE round returns 2 (wakes + requeues).
# 2. Guest run: compiles the test as a static guest /init, packages it with
#    the campaign's already-built kernel image (harness
#    build/target/osdk/iso_root/boot/asterinas-osdk-bin, source 0c6053709;
#    observation-only instrumentation, no futex semantic changes), and boots
#    it under QEMU exactly like the campaign harness (container.sh recipe):
#    KVM, OVMF, SMP 2, 2G, isa-debug-exit shutdown. The container-side steps
#    live in mc4_inner.sh (docker run without -i discards heredoc stdin, so
#    the inner script must be a file, as in the harness recipe).
#
# Container limits follow the campaign resource policy: cpus 2, memory 8g,
# pids 512. The heavy-stage lock is held by the receiving controller and is
# not reacquired here.
#
# Usage: bash test_bugMC-4_requeue_return_count.sh
set -euo pipefail

run=/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue
repro="$run/.specula-output/repro"
work="$repro/mc4_guest"
mkdir -p "$work"

# 1. Native Linux control (same binary as the guest, no -DGUEST).
if [[ ! -f "$repro/mc4_host_control.log" ]]; then
    gcc -O2 -Wall -pthread -o /tmp/mc4_host_control \
        "$repro/test_bugMC-4_requeue_return_count.c"
    {
        echo "# MC-4 control run: host Linux 7.2.8, same test binary (no -DGUEST)"
        echo "# command: gcc -O2 -Wall -pthread -o /tmp/mc4_host_control test_bugMC-4_requeue_return_count.c && timeout 120 /tmp/mc4_host_control"
        timeout 120 /tmp/mc4_host_control
    } > "$repro/mc4_host_control.log" 2>&1
fi
echo "=== Linux control summary ==="
grep -E "\[MC-4\] (totals|RESULT)|LINUX_CORRECT|CONTROL_MATCH|ANOMALY" \
    "$repro/mc4_host_control.log" | head -8

# 2. Asterinas guest run.
sudo -n docker -H unix:///var/run/docker.sock run --rm \
    --cpus=2 --memory=8g --pids-limit=512 --device=/dev/kvm \
    -v "$run:/work" asterinas/kernel-dev:0.18.1-20260926 \
    bash /work/.specula-output/repro/mc4_inner.sh

echo "=== guest serial log (test output) ==="
grep -E "\[MC-4\]|MC4_TEST_DONE|QEMU_STATUS" "$work/guest.log" || true
