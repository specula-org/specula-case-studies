#!/usr/bin/env bash
# Runs repro/test_bugMC-1_seal_readonly_admission.c inside the Asterinas guest
# (instrumented kernel at source commit 0c60537098f4c2949ad2d382aaf499de72263d76,
# already built at source/target/osdk by the run's harness) and captures the
# serial output. The same C file run natively on Linux 7.2.8 provides the
# reference outcome.
set -euo pipefail
run_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
repro_dir="$run_dir/.specula-output/repro"
guest_log="$repro_dir/test_bugMC-1_asterinas_run.log"
container_name="specula-mc1-repro-$$"
cleanup() { docker rm -f "$container_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$container_name" --device /dev/kvm --network host \
    -v "$run_dir:/work" -w /work/source --entrypoint sleep \
    asterinas/dev:0.18.1-20260926 infinity >/dev/null

docker exec "$container_name" bash -euo pipefail -c '
    cd /work/source
    export CARGO_BUILD_JOBS=4 OSDK_LOCAL_DEV=1
    out=/work/.specula-output/repro
    timeout 600 cargo install --path osdk --locked --force >"$out/osdk-install-mc1.log" 2>&1
    timeout 120 gcc -O2 -static -DASTERINAS_GUEST \
        -o "$out/init-mc1" "$out/test_bugMC-1_seal_readonly_admission.c"
    rm -rf "$out/mc1-initramfs"; mkdir -p "$out/mc1-initramfs"
    cp "$out/init-mc1" "$out/mc1-initramfs/init"
    (cd "$out/mc1-initramfs" && find . -print0 | cpio --null -o --format=newc >"$out/mc1-initramfs.cpio")
    cd kernel
    timeout 900 cargo osdk build --scheme specula_memfd --boot-method=vmm-direct \
        --grub-boot-protocol=multiboot \
        --initramfs "$out/mc1-initramfs.cpio" \
        --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error \
        >"$out/kernel-build-mc1.log" 2>&1
'

set +e
docker exec "$container_name" bash -c '
    cd /work/source/kernel
    out=/work/.specula-output/repro
    timeout 600 cargo osdk run --scheme specula_memfd --boot-method=vmm-direct \
        --grub-boot-protocol=multiboot \
        --initramfs "$out/mc1-initramfs.cpio" \
        --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error
' | tee "$guest_log"
run_status=${PIPESTATUS[0]}
set -e
printf 'osdk-run exit: %s\n' "$run_status"
exit "$run_status"
