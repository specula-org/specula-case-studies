#!/bin/sh
# SPDX-License-Identifier: MPL-2.0

# Level 0 public-API reproduction: eventfd readiness, EPOLLONESHOT,
# an EFAULT copyout, then a normal epoll_wait retry on an SMP=2 guest.
set -eu

target_repo=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/worktree

# The documented image supplies the pinned toolchain and Linux vDSO files.
run_log=$(mktemp "${TMPDIR:-/tmp}/test_bugMC-2.XXXXXX")
trap 'rm -f "$run_log"' EXIT HUP INT TERM

set +e
timeout 20m docker run --rm --privileged --network=host --device=/dev/kvm \
  -v "$target_repo:/root/asterinas" \
  -w /root/asterinas \
  asterinas/asterinas:0.18.0-20260702 \
  sh -lc 'SMP=2 SPECULA_INIT="/test/io/specula/run_validation.sh copyout_oneshot" make run_kernel' \
  >"$run_log" 2>&1
run_status=$?
set -e

cat "$run_log"
if [ "$run_status" -ne 0 ]; then
  exit "$run_status"
fi
if grep -a -q 'SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT' "$run_log"; then
  exit 1
fi
if grep -a -q 'SPECULA_REGRESSION_PASS copyout_oneshot' "$run_log"; then
  exit 0
fi
exit 2
