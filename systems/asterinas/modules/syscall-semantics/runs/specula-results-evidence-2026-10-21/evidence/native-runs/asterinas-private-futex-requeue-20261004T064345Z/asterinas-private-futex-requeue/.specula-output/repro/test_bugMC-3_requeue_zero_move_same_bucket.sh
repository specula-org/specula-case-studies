#!/usr/bin/env bash
# Reproduction runner for finding MC-3 (same-bucket REQUEUE with a zero
# migration quota moves one waiter) -- Asterinas guest run.
#
# Compiles test_bugMC-3_requeue_zero_move_same_bucket.c as a static guest
# /init, packages it with the campaign's already-built kernel image (harness
# build/target/osdk/iso_root/boot/asterinas-osdk-bin, source 0c6053709; no
# source changes), and boots it under QEMU exactly like the campaign harness
# (container.sh recipe): KVM, OVMF, SMP 2, 2G, isa-debug-exit shutdown. The
# container-side steps live in mc3_inner.sh (docker run without -i discards
# heredoc stdin, so the inner script must be a file, as in the harness
# recipe).
#
# Container limits follow the campaign resource policy: cpus 2, memory 8g,
# pids 512. The heavy-stage lock is held by the receiving controller and is
# not reacquired here.
#
# The Linux 7.2.8 control for the same binary is run natively on the host
# (see mc3_host_control.log): every candidate pair shows the correct
# signature (REQUEUE(1,0) wakes one, moves none, WAKE(A) still finds the
# second waiter).
#
# Usage: bash test_bugMC-3_requeue_zero_move_same_bucket.sh
set -euo pipefail

run=/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue
repro="$run/.specula-output/repro"
work="$repro/mc3_guest"
mkdir -p "$work"

sudo -n docker -H unix:///var/run/docker.sock run --rm \
    --cpus=2 --memory=8g --pids-limit=512 --device=/dev/kvm \
    -v "$run:/work" asterinas/kernel-dev:0.18.1-20260926 \
    bash /work/.specula-output/repro/mc3_inner.sh

echo "=== guest serial log (test output) ==="
grep -E "\[MC-3\]|MC3_TEST_DONE|QEMU_STATUS" "$work/guest.log" || true
