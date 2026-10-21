#!/bin/sh

set -eu

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
SOURCE_ROOT=${1:-"$(dirname -- "$OUTPUT_DIR")/source"}

if git -C "$SOURCE_ROOT" apply --reverse --check \
	"$HARNESS_DIR/patches/source-hooks.patch" 2>/dev/null; then
	git -C "$SOURCE_ROOT" apply --reverse "$HARNESS_DIR/patches/source-hooks.patch"
elif git -C "$SOURCE_ROOT" apply --check \
	"$HARNESS_DIR/patches/source-hooks.patch" 2>/dev/null; then
	:
else
	echo "clean.sh: source hooks do not match the harness patch" >&2
	exit 1
fi

remove_owned_file()
{
	source_file=$1
	target_file=$2

	if [ ! -e "$target_file" ]; then
		return
	fi
	if ! cmp -s "$source_file" "$target_file"; then
		echo "clean.sh: refusing to remove modified file $target_file" >&2
		exit 1
	fi
	rm -- "$target_file"
}

remove_owned_file "$HARNESS_DIR/src/tla_trace.rs" \
	"$SOURCE_ROOT/kernel/core/src/tla_trace.rs"
remove_owned_file "$HARNESS_DIR/src/specula_fd_trace.c" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/specula_fd_trace.c"
remove_owned_file "$HARNESS_DIR/src/specula-Makefile" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/Makefile"
remove_owned_file "$HARNESS_DIR/src/specula.nix" \
	"$SOURCE_ROOT/test/initramfs/nix/specula/default.nix"

for scenario in concurrent_fcntl dup_replace_flags close_reuse readiness_epoll; do
	remove_owned_file "$HARNESS_DIR/src/run_${scenario}.sh" \
		"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/run_${scenario}.sh"
done

rmdir -- "$SOURCE_ROOT/test/initramfs/src/regression/io/specula" 2>/dev/null || true
rmdir -- "$SOURCE_ROOT/test/initramfs/nix/specula" 2>/dev/null || true
echo "Removed Specula FD/epoll trace instrumentation from $SOURCE_ROOT"
