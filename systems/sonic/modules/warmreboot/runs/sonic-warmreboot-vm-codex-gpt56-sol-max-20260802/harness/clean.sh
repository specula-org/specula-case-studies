#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT=${SPECULA_ARTIFACT:-/users/Pial/targets/sonic-buildimage-warmreboot}
UTILITIES_DIR="${ARTIFACT}/src/sonic-utilities"
PATCH_FILE="${SCRIPT_DIR}/patches/sonic-utilities-warmreboot-trace.patch"

if git -C "${UTILITIES_DIR}" apply --reverse --check "${PATCH_FILE}" >/dev/null 2>&1; then
    git -C "${UTILITIES_DIR}" apply --reverse "${PATCH_FILE}"
    echo "Removed only the Specula warm-reboot instrumentation patch."
else
    echo "Instrumentation patch is not applied; nothing changed."
fi
