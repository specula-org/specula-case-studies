#!/usr/bin/env bash
set -euo pipefail
cd /home/chin39/Documents/asterinas-dev
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
timeout 900 cargo build --locked --manifest-path osdk/Cargo.toml
mkdir -p /cr2build/root/dev /cr2build/root/tmp
gcc -static -O2 -g -pthread -Wall -Wextra -Werror -DSCM_ASTERINAS ${CR2_RIGHTS:+-DCR2_RIGHTS=$CR2_RIGHTS} \
    /work/.specula-output/repro/test_bugCR-2_peek_consume_interleave.c \
    -o /cr2build/root/init
cd /cr2build/root
find . -print0 | cpio --null -o --format=newc > /cr2build/initramfs.cpio
cd /home/chin39/Documents/asterinas-dev/kernel
../osdk/target/debug/cargo-osdk osdk build --scheme scm-trace --release \
    --initramfs /cr2build/initramfs.cpio \
    --kcmd-args=loglevel=error --kcmd-args=console=ttyS0 --kcmd-args=earlycon
