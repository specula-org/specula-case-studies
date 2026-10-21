#!/usr/bin/env bash
# Boot the rebuilt ISO and capture the MC-1 reproduction output from serial.
set -euo pipefail
RUNROOT=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights
HARNESS=$RUNROOT/.specula-output/harness
out="$RUNROOT/.specula-output/confirmation/MC-1/guest.log"
sudo -n docker -H unix:///var/run/docker.sock rm -f mc1-guest >/dev/null 2>&1 || true
sudo -n docker -H unix:///var/run/docker.sock create --name mc1-guest --cpus 2 --memory 8g --pids-limit 512 \
  --device /dev/kvm \
  --mount "type=bind,src=$RUNROOT,dst=/work" \
  --mount "type=bind,src=$RUNROOT/source,dst=/home/chin39/Documents/asterinas-dev" \
  --mount "type=bind,src=$HARNESS/build/cargo-git,dst=/root/.cargo/git" \
  --mount "type=bind,src=$HARNESS/build/cargo-registry,dst=/root/.cargo/registry" \
  asterinas/kernel-dev:0.18.1-20260926 timeout 420 qemu-system-x86_64 \
  -bios /root/ovmf/release/OVMF.fd -machine q35,kernel-irqchip=split \
  -m 2G -smp 2 -cpu host -accel kvm -nographic -monitor none -no-reboot \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -cdrom /work/source/target/osdk/asterinas-osdk-bin.iso > /dev/null
set +e
sudo -n docker -H unix:///var/run/docker.sock start -a mc1-guest > "$out" 2>&1
status=$?
set -e
echo "guest_exit=$status"
grep -a "MC1_" "$out" || true
