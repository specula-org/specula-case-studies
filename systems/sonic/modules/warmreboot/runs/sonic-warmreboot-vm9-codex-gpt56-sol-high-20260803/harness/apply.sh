#!/bin/bash
set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)
ARTIFACT_DIR=${SPECULA_ARTIFACT_DIR:-/users/Pial/targets/sonic-buildimage-warmreboot-high}

timeout 600 git -C "$ARTIFACT_DIR" submodule update --init -- \
    src/sonic-host-services src/sonic-utilities \
    src/sonic-sysmgr/gnoi src/sonic-swss-common

verify_commit()
{
    local repository=$1
    local expected=$2
    local actual
    actual=$(git -C "$repository" rev-parse HEAD)
    if [[ "$actual" != "$expected" ]]; then
        echo "$repository is at $actual, expected pinned commit $expected" >&2
        return 1
    fi
}

verify_commit "$ARTIFACT_DIR/src/sonic-host-services" 233cd591c324d4090a077f87da0eaaad7d12cabc
verify_commit "$ARTIFACT_DIR/src/sonic-utilities" b17c48270c15fc6d5c81a23d97e2946cd7059dcd
verify_commit "$ARTIFACT_DIR/src/sonic-sysmgr/gnoi" 2b6ff72de5769839fc68bd019f345a184e3b0bf1
verify_commit "$ARTIFACT_DIR/src/sonic-swss-common" 6acbb00b8b3a1baf647d7c89aac3290d02bc0a5f

apply_patch_once()
{
    local repository=$1
    local patch_file=$2
    if [[ $(basename "$patch_file") != "sysmgr.patch" ]]; then
        if git -C "$repository" apply --unidiff-zero --reverse --check "$patch_file" >/dev/null 2>&1; then
            echo "already applied: $(basename "$patch_file")"
        elif git -C "$repository" apply --unidiff-zero --check "$patch_file"; then
            git -C "$repository" apply --unidiff-zero "$patch_file"
            echo "applied: $(basename "$patch_file")"
        else
            echo "cannot apply $(basename "$patch_file"): source differs from the pinned input" >&2
            return 1
        fi
        return
    fi
    if (cd "$repository" && patch --no-backup-if-mismatch -R -p1 --dry-run --silent < "$patch_file") >/dev/null 2>&1; then
        echo "already applied: $(basename "$patch_file")"
    elif (cd "$repository" && patch --no-backup-if-mismatch -p1 --dry-run --silent < "$patch_file") >/dev/null 2>&1; then
        (cd "$repository" && patch --no-backup-if-mismatch -p1 --silent < "$patch_file")
        echo "applied: $(basename "$patch_file")"
    else
        echo "cannot apply $(basename "$patch_file"): source differs from the pinned input" >&2
        return 1
    fi
}

install -m 0644 "$HARNESS_DIR/src/tla_trace.h" \
    "$ARTIFACT_DIR/src/sonic-sysmgr/rebootbackend/tla_trace.h"
install -m 0644 "$HARNESS_DIR/src/tla_trace.cpp" \
    "$ARTIFACT_DIR/src/sonic-sysmgr/rebootbackend/tla_trace.cpp"
install -m 0644 "$HARNESS_DIR/src/specula_trace.py" \
    "$ARTIFACT_DIR/src/sonic-host-services/host_modules/specula_trace.py"

apply_patch_once "$ARTIFACT_DIR" "$HARNESS_DIR/patches/sysmgr.patch"
apply_patch_once "$ARTIFACT_DIR/src/sonic-host-services" "$HARNESS_DIR/patches/host-services.patch"
apply_patch_once "$ARTIFACT_DIR/src/sonic-utilities" "$HARNESS_DIR/patches/sonic-utilities.patch"
apply_patch_once "$ARTIFACT_DIR" "$HARNESS_DIR/patches/finalizer.patch"
