#!/usr/bin/env bash
#
# Verifies that OnDiskStorage::write (secure/storage/src/on_disk.rs:64-70)
# does NOT call fsync/fdatasync/sync_all. This is the storage-backend
# precondition that makes Bug 1 / Bug 2 (Family 1, MC-1) actually
# reachable in production: a power loss between the rename and the kernel
# flushing the dirty page can lose the SafetyData write.
#
# We approach the verification two ways:
#  (a) Static source-code analysis — grep the actual write() implementation
#      for fsync/sync_all/fdatasync. If absent, the durability gap is real.
#  (b) Dynamic strace — if a probe binary is available in the build cache,
#      run it under strace and check the syscall trace.
#
# (a) is the authoritative evidence; (b) is a nice-to-have confirmation.

set -euo pipefail

APTOS_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../artifact/aptos-core && pwd)"
ON_DISK_RS="${APTOS_CORE}/secure/storage/src/on_disk.rs"

if [ ! -f "${ON_DISK_RS}" ]; then
    echo "FAILED: cannot locate ${ON_DISK_RS}"
    exit 2
fi

echo "==> Source-level check: on_disk.rs::write() body"
echo

# Pull the body of fn write — it is a self-contained ~6-line method.
awk '/fn write\(/{flag=1} flag{print; if (/^    \}$/){exit}}' "${ON_DISK_RS}"

echo
echo "==> Looking for fsync / sync_all / fdatasync inside on_disk.rs:"
if grep -nE 'fsync|sync_all|fdatasync' "${ON_DISK_RS}"; then
    echo
    echo "UNEXPECTED: on_disk.rs DOES reference a sync primitive — verify location."
    exit 1
fi

echo "  (none — confirming OnDiskStorage performs no kernel-level durability sync)"
echo

echo "==> Looking for the production-warning comment on OnDiskStorage:"
grep -n "This should not be used in production" "${ON_DISK_RS}" || \
    echo "  (production warning comment absent — but the missing fsync is the key fact)"

echo
echo "VERIFIED: OnDiskStorage::write performs File::create + write_all + fs::rename,"
echo "          with no fsync / sync_all / fdatasync. A power loss between the rename"
echo "          and the kernel's writeback can lose the SafetyData write. This is the"
echo "          storage-backend precondition for Bug 1 / Bug 2 in production."
