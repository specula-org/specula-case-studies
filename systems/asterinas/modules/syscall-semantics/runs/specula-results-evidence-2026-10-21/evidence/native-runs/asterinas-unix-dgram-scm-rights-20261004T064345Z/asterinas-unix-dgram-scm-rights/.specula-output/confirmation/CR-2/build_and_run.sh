#!/usr/bin/env bash
# CR-2 reproduction build + guest run. Mirrors the accepted harness recipe
# (.specula-output/harness/run.sh + src/guest-build.sh) with the CR-2 repro
# test as /init instead of the harness fixture.
set -euo pipefail
run_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
here=$(cd -- "$(dirname -- "$0")" && pwd)
source="$run_root/source"
harness_build="$run_root/.specula-output/harness/build"
mkdir -p "$here/root/dev" "$here/root/tmp" "$harness_build/cargo-git" "$harness_build/cargo-registry"

# Back up the harness ISO before osdk overwrites it in source/target/osdk.
if [ -f "$source/target/osdk/asterinas-osdk-bin.iso" ] && [ ! -f "$here/harness-iso-backup.iso" ]; then
    cp "$source/target/osdk/asterinas-osdk-bin.iso" "$here/harness-iso-backup.iso"
fi

resource_dir=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04
available=$("$resource_dir/effective-mem-gib.sh")
echo "effective_mem_GiB=$available"
if awk -v a="$available" 'BEGIN {exit !(a >= 10)}'; then
    echo "memory gate passed"
else
    echo "memory gate FAILED: need 10 GiB" >&2
    exit 2
fi

docker_cmd=(sudo -n docker -H unix:///var/run/docker.sock)
image=asterinas/kernel-dev:0.18.1-20260926
"${docker_cmd[@]}" image inspect "$image" > /dev/null

container="cr2-repro-$$"
cleanup() { "${docker_cmd[@]}" rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cat > "$here/guest-build-cr2.sh" <<'EOF'
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
EOF

"${docker_cmd[@]}" create --name "$container" --cpus 2 --memory 8g --pids-limit 512 \
    --device /dev/kvm --mount "type=bind,src=$run_root,dst=/work" \
    --mount "type=bind,src=$source,dst=/home/chin39/Documents/asterinas-dev" \
    --mount "type=bind,src=$harness_build/cargo-git,dst=/root/.cargo/git" \
    --mount "type=bind,src=$harness_build/cargo-registry,dst=/root/.cargo/registry" \
    --mount "type=bind,src=$here,dst=/cr2build" \
    -e CARGO_NET_OFFLINE=false -e CARGO_BUILD_JOBS=2 -e OSDK_LOCAL_DEV=1 \
    -e CR2_RIGHTS="${CR2_RIGHTS:-}" "$image" \
    bash /cr2build/guest-build-cr2.sh > /dev/null
set +e
timeout 1800 "${docker_cmd[@]}" start -a "$container" > "$here/build.log" 2>&1
build_status=$?
set -e
echo "$build_status" > "$here/build.exit"
if (( build_status != 0 )); then
    tail -60 "$here/build.log"
    exit "$build_status"
fi
"${docker_cmd[@]}" rm "$container" >/dev/null

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
