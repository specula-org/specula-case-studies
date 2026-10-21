#!/bin/sh

set -eu

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
RUN_ROOT=$(dirname -- "$OUTPUT_DIR")
SOURCE_ROOT=${1:-"$RUN_ROOT/source"}
PATCH=$HARNESS_DIR/patches/source-hooks.patch

if (cd "$SOURCE_ROOT" && git apply --reverse --check "$PATCH") 2>/dev/null; then
	(cd "$SOURCE_ROOT" && git apply --reverse "$PATCH")
elif ! (cd "$SOURCE_ROOT" && git apply --check "$PATCH") 2>/dev/null; then
	echo "clean.sh: source hooks are neither applied nor clean" >&2
	exit 1
fi

remove_owned_file()
{
	source_file=$1
	target_file=$2
	if [ -e "$target_file" ]; then
		if ! cmp -s "$source_file" "$target_file"; then
			echo "clean.sh: refusing to remove modified $target_file" >&2
			exit 1
		fi
		rm -- "$target_file"
	fi
}

remove_owned_file "$HARNESS_DIR/src/tla_trace.rs" \
	"$SOURCE_ROOT/kernel/core/src/tla_trace.rs"
remove_owned_file "$HARNESS_DIR/src/block_tla_trace.rs" \
	"$SOURCE_ROOT/kernel/core/comps/block/src/tla_trace.rs"
remove_owned_file "$HARNESS_DIR/src/specula_io_trace.c" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/specula_io_trace.c"
remove_owned_file "$HARNESS_DIR/src/specula-Makefile" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/Makefile"
remove_owned_file "$HARNESS_DIR/src/specula.nix" \
	"$SOURCE_ROOT/test/initramfs/nix/specula/default.nix"

for scenario in ramfs_normal ramfs_faults ramfs_zero_append ext2_buffered \
	ext2_direct overlap_prefix reference_restart; do
	remove_owned_file "$HARNESS_DIR/src/run_${scenario}.sh" \
		"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/run_${scenario}.sh"
done

rmdir "$SOURCE_ROOT/test/initramfs/src/regression/io/specula" 2>/dev/null || true
rmdir "$SOURCE_ROOT/test/initramfs/nix/specula" 2>/dev/null || true
echo "Removed regular-file Specula trace instrumentation from $SOURCE_ROOT"
