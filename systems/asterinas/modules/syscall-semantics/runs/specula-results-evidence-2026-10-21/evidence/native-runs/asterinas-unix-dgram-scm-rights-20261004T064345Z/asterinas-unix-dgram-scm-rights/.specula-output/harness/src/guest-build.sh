#!/usr/bin/env bash
set -euo pipefail
cd /home/chin39/Documents/asterinas-dev
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
# Local-development dependency paths are embedded when OSDK is compiled.
timeout 900 cargo build --locked --manifest-path osdk/Cargo.toml
mkdir -p /work/.specula-output/harness/build/root/{dev,tmp}
gcc -static -O2 -g -pthread -Wall -Werror -DSCM_ASTERINAS \
    test/initramfs/src/regression/network/scm_rights_trace.c \
    -o /work/.specula-output/harness/build/root/init
gcc -static -O2 -g -pthread -Wall -Werror \
    test/initramfs/src/regression/network/scm_rights_trace.c \
    -o /work/.specula-output/harness/build/linux-control
cd /work/.specula-output/harness/build/root
find . -print0 | cpio --null -o --format=newc > ../initramfs.cpio
cd /home/chin39/Documents/asterinas-dev/kernel
../osdk/target/debug/cargo-osdk osdk build --scheme scm-trace --release \
    --initramfs /work/.specula-output/harness/build/initramfs.cpio \
    --kcmd-args=loglevel=error --kcmd-args=console=ttyS0 --kcmd-args=earlycon
