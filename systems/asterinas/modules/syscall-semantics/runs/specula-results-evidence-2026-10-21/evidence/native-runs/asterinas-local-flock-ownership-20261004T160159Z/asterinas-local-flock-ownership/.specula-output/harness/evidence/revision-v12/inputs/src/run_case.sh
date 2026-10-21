#!/usr/bin/env bash
set -euo pipefail
[[ -f /harness/evidence/runtime-reviewed.sha256 ]] || { echo "INCOMPLETE: runtime review gate is open" >&2; exit 2; }
(cd /harness && sha256sum -c evidence/runtime-reviewed.sha256)
case_name=$1
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
export PATH="/source/target/harness-osdk/debug:$PATH"
printf '%s\n' "$case_name" > /harness/build/root/case
(cd /harness/build/root && find . -print0 | cpio --null -o --format=newc > /harness/build/initramfs.cpio)
sha256sum /harness/build/root/init /harness/build/initramfs.cpio
cd /source/kernel
timeout 200 cargo osdk run --scheme flock --initramfs /harness/build/initramfs.cpio --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error
