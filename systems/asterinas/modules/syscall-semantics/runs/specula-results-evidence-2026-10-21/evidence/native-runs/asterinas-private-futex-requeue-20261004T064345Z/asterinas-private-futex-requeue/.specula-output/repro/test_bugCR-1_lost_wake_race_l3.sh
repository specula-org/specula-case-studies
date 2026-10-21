#!/usr/bin/env bash
# Reproduction runner, Level 3 (kernel-side widening of the fault-retry
# window) for finding CR-1 -- Asterinas guest run.
#
# Builds and boots a kernel from the finding's l3run tree: campaign source
# 0c6053709 + instrumentation + a 6-line timing-only patch (futex.rs: a
# ~200us tr::stamp() spin inside the unlocked fault-retry window after
# handle_page_fault, before the loop re-locks; no logic altered, no lock
# held there). The warm cargo target is a copy at its original absolute
# path, so only the changed crate rebuilds. The campaign's own kernel
# binary and harness build dir are never touched.
#
# The test binary is compiled with -DCR1_L3: only the fault-window phases
# (B: madvise-forced fault retry, D: madvise + randomized waker delays)
# run, with reduced counts since every faulted iteration now costs >=200us
# of kernel-held window.
#
# Container limits follow the campaign resource policy: cpus 2, memory 8g,
# pids 512. The heavy-stage lock is held by the receiving controller and is
# not reacquired here.
#
# Usage: bash test_bugCR-1_lost_wake_race_l3.sh
set -euo pipefail

run=/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue
repro="$run/.specula-output/repro"
l3="$run/.specula-output/confirmation/CR-1/l3run"

# Refresh the test source inside the l3 tree (authoritative copy stays in
# repro/).
mkdir -p "$l3/.specula-output/repro"
cp "$repro/test_bugCR-1_lost_wake_race.c" "$repro/cr1_l3_inner.sh" \
    "$l3/.specula-output/repro/"

sudo -n docker -H unix:///var/run/docker.sock run --rm \
    --cpus=2 --memory=8g --pids-limit=512 --device=/dev/kvm \
    -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
    -e no_proxy="${no_proxy:-}" \
    -v "$l3:/work" asterinas/kernel-dev:0.18.1-20260926 \
    bash /work/.specula-output/repro/cr1_l3_inner.sh

echo "=== guest serial log (Level 3 test output) ==="
grep -E "CR1_|QEMU_STATUS" "$l3/.specula-output/repro/cr1_l3_guest/guest.log" || true
