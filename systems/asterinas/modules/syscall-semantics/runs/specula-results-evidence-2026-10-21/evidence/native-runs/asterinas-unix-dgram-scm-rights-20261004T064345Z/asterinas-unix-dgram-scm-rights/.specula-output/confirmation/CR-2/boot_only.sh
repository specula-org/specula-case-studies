#!/usr/bin/env bash
# CR-2: boot the rebuilt ISO (CR-2 test as /init) and capture the guest log.
set -euo pipefail
run_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
here=$(cd -- "$(dirname -- "$0")" && pwd)
source="$run_root/source"
harness_build="$run_root/.specula-output/harness/build"
docker_cmd=(sudo -n docker -H unix:///var/run/docker.sock)
image=asterinas/kernel-dev:0.18.1-20260926
container="cr2-boot-$$"
cleanup() { "${docker_cmd[@]}" rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"${docker_cmd[@]}" create --name "$container" --cpus 2 --memory 8g --pids-limit 512 \
    --device /dev/kvm --mount "type=bind,src=$run_root,dst=/work" \
    --mount "type=bind,src=$harness_build/cargo-git,dst=/root/.cargo/git" \
    --mount "type=bind,src=$harness_build/cargo-registry,dst=/root/.cargo/registry" \
    "$image" timeout 300 qemu-system-x86_64 \
    -bios /root/ovmf/release/OVMF.fd -machine q35,kernel-irqchip=split \
    -m 2G -smp 2 -cpu host -accel kvm -nographic -monitor none -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -cdrom /work/source/target/osdk/asterinas-osdk-bin.iso > /dev/null
set +e
timeout 360 "${docker_cmd[@]}" start -a "$container" > "$here/guest.log" 2>&1
guest_status=$?
set -e
echo "$guest_status" > "$here/guest.exit"
echo "guest_status=$guest_status"
if grep -q '^CR2_DONE' "$here/guest.log"; then
    grep -E '^CR2_' "$here/guest.log"
else
    tail -40 "$here/guest.log"
    exit 1
fi
