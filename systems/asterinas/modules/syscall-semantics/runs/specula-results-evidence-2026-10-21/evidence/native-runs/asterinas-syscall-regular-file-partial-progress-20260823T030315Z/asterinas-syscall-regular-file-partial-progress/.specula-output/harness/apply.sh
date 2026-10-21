#!/bin/sh

set -eu

EXPECTED_TREE=3893ebda0ec3c6f2ef075109c6cb620073b855ef
HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
RUN_ROOT=$(dirname -- "$OUTPUT_DIR")
SOURCE_ROOT=${1:-"$RUN_ROOT/source"}
BASELINE_GIT=$RUN_ROOT/baseline.git
PATCH=$HARNESS_DIR/patches/source-hooks.patch

if [ "$(git --git-dir="$BASELINE_GIT" rev-parse refs/specula/baseline^{tree})" != "$EXPECTED_TREE" ]; then
	echo "apply.sh: baseline tree does not match $EXPECTED_TREE" >&2
	exit 1
fi

install_owned_file()
{
	source_file=$1
	target_file=$2
	mode=$3

	if [ -e "$target_file" ]; then
		if ! cmp -s "$source_file" "$target_file"; then
			echo "apply.sh: refusing to overwrite $target_file" >&2
			exit 1
		fi
		return
	fi

	mkdir -p "$(dirname -- "$target_file")"
	install -m "$mode" "$source_file" "$target_file"
}

install_owned_file "$HARNESS_DIR/src/tla_trace.rs" \
	"$SOURCE_ROOT/kernel/core/src/tla_trace.rs" 0644
install_owned_file "$HARNESS_DIR/src/block_tla_trace.rs" \
	"$SOURCE_ROOT/kernel/core/comps/block/src/tla_trace.rs" 0644
install_owned_file "$HARNESS_DIR/src/specula_io_trace.c" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/specula_io_trace.c" 0644
install_owned_file "$HARNESS_DIR/src/specula-Makefile" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/Makefile" 0644
install_owned_file "$HARNESS_DIR/src/specula.nix" \
	"$SOURCE_ROOT/test/initramfs/nix/specula/default.nix" 0644

for scenario in ramfs_normal ramfs_faults ramfs_zero_append ext2_buffered \
	ext2_direct overlap_prefix reference_restart; do
	install_owned_file "$HARNESS_DIR/src/run_${scenario}.sh" \
		"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/run_${scenario}.sh" 0755
done

if (cd "$SOURCE_ROOT" && git apply --check "$PATCH") 2>/dev/null; then
	(cd "$SOURCE_ROOT" && git apply "$PATCH")
elif ! (cd "$SOURCE_ROOT" && git apply --reverse --check "$PATCH") 2>/dev/null; then
	echo "apply.sh: source hooks are neither clean nor already applied" >&2
	exit 1
fi

echo "Applied regular-file Specula trace instrumentation to $SOURCE_ROOT"
