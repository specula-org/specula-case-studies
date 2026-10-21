#!/usr/bin/env bash
# Reproduction runner for finding CR-1 (user value update + WAKE overlapping
# WAIT registration, including the unlocked fault-retry window) -- Asterinas
# guest run.
#
# Compiles test_bugCR-1_lost_wake_race.c as a static guest /init, packages
# it with the campaign's already-built kernel image (harness
# build/target/osdk/iso_root/boot/asterinas-osdk-bin, source 0c6053709,
# identity verified by harness/identity.py --check-built; no source changes),
# and boots it under QEMU exactly like the campaign harness (container.sh
# recipe): KVM, OVMF, SMP 2, 2G, isa-debug-exit shutdown. The container-side
# steps live in cr1_inner.sh (docker run without -i discards heredoc stdin,
# so the inner script must be a file, as in the harness recipe).
#
# Container limits follow the campaign resource policy: cpus 2, memory 8g,
# pids 512. The heavy-stage lock is held by the receiving controller and is
# not reacquired here.
#
# Usage: bash test_bugCR-1_lost_wake_race.sh
set -euo pipefail

run=/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue
repro="$run/.specula-output/repro"
work="$repro/cr1_guest"
mkdir -p "$work"

sudo -n docker -H unix:///var/run/docker.sock run --rm \
    --cpus=2 --memory=8g --pids-limit=512 --device=/dev/kvm \
    -v "$run:/work" asterinas/kernel-dev:0.18.1-20260926 \
    bash /work/.specula-output/repro/cr1_inner.sh

echo "=== guest serial log (test output) ==="
grep -E "CR1_" "$work/guest.log" || true
