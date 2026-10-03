#!/bin/bash
# Build the instrumented copy of the pinned nvflare package used by the trace harness.
#
#   harness/build/nvflare_src/nvflare  <- git archive <pinned commit> of the arm's source
#                                        + src/tla_hooks.py (no-op hook module) + patches/instrumentation.patch
#
# The arm's source tree is never modified.  The build dir is a git repo whose base commit is "pinned source +
# tla_hooks", with the instrumentation applied as working-tree changes, so after editing hooks in place you can
# regenerate the patch with: bash harness/make_patch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/paths.sh"
SRC="$NVF_SOURCE"
COMMIT=53ba7ee567468ea7971dad4faccef13c6cb35dc2
BUILD="$SCRIPT_DIR/build/nvflare_src"
PATCH="$SCRIPT_DIR/patches/instrumentation.patch"

head_commit="$(git -C "$SRC" rev-parse HEAD)"
if [ "$head_commit" != "$COMMIT" ]; then
    echo "Source HEAD $head_commit is not the authorized pin $COMMIT" >&2
    exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
git -C "$SRC" archive "$COMMIT" nvflare | tar -x -C "$BUILD"
cp "$SCRIPT_DIR/src/tla_hooks.py" "$BUILD/nvflare/fuel/utils/tla_hooks.py"
(
    cd "$BUILD"
    git init -q
    git add -A
    git -c user.name=specula-harness -c user.email=harness@localhost commit -q -m "nvflare @ $COMMIT + tla_hooks"
    git apply --whitespace=nowarn "$PATCH"
)
{
    echo "source=$SRC"
    echo "commit=$COMMIT"
    echo "patch_sha256=$(sha256sum "$PATCH" | cut -d' ' -f1)"
    echo "tla_hooks_sha256=$(sha256sum "$SCRIPT_DIR/src/tla_hooks.py" | cut -d' ' -f1)"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$SCRIPT_DIR/build/PROVENANCE"

# every instrumented module must still compile
timeout 120 "$NVF_PYTHON" -m compileall -q "$BUILD/nvflare/fuel/utils/tla_hooks.py" \
    $(git -C "$BUILD" diff --name-only | sed "s|^|$BUILD/|") > /dev/null
echo "instrumented copy ready: $BUILD ($(git -C "$BUILD" diff --stat | tail -1))"
