#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT=${SPECULA_ARTIFACT:-/users/Pial/targets/sonic-buildimage-warmreboot}
UTILITIES_DIR="${ARTIFACT}/src/sonic-utilities"
PATCH_FILE="${SCRIPT_DIR}/patches/sonic-utilities-warmreboot-trace.patch"

[[ -d "${UTILITIES_DIR}" ]] || { echo "missing sonic-utilities checkout: ${UTILITIES_DIR}" >&2; exit 1; }
[[ -f "${PATCH_FILE}" ]] || { echo "missing instrumentation patch: ${PATCH_FILE}" >&2; exit 1; }

if git -C "${UTILITIES_DIR}" apply --reverse --check "${PATCH_FILE}" >/dev/null 2>&1; then
    echo "Instrumentation already applied."
elif git -C "${UTILITIES_DIR}" apply --check "${PATCH_FILE}"; then
    git -C "${UTILITIES_DIR}" apply "${PATCH_FILE}"
    echo "Applied warm-reboot instrumentation."
else
    echo "Instrumentation patch does not apply cleanly; preserve local edits and inspect git diff." >&2
    exit 1
fi

timeout 30s bash -n "${UTILITIES_DIR}/scripts/fast-reboot"
