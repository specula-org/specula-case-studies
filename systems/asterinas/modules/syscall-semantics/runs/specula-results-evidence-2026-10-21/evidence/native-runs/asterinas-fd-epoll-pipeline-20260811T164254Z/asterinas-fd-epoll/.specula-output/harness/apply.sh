#!/bin/sh

set -eu

EXPECTED_HEAD=4ba4abbe8cb3f2892129d67b0301cf247bbdda0f
HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
SOURCE_ROOT=${1:-"$(dirname -- "$OUTPUT_DIR")/source"}

if [ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" != "$EXPECTED_HEAD" ]; then
	echo "apply.sh: source HEAD does not match $EXPECTED_HEAD" >&2
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
install_owned_file "$HARNESS_DIR/src/specula_fd_trace.c" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/specula_fd_trace.c" 0644
install_owned_file "$HARNESS_DIR/src/specula-Makefile" \
	"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/Makefile" 0644
install_owned_file "$HARNESS_DIR/src/specula.nix" \
	"$SOURCE_ROOT/test/initramfs/nix/specula/default.nix" 0644

for scenario in concurrent_fcntl dup_replace_flags close_reuse readiness_epoll; do
	install_owned_file "$HARNESS_DIR/src/run_${scenario}.sh" \
		"$SOURCE_ROOT/test/initramfs/src/regression/io/specula/run_${scenario}.sh" 0755
done

if git -C "$SOURCE_ROOT" apply --check "$HARNESS_DIR/patches/source-hooks.patch" 2>/dev/null; then
	git -C "$SOURCE_ROOT" apply "$HARNESS_DIR/patches/source-hooks.patch"
elif ! git -C "$SOURCE_ROOT" apply --reverse --check \
	"$HARNESS_DIR/patches/source-hooks.patch" 2>/dev/null; then
	echo "apply.sh: source hooks are neither clean nor already applied" >&2
	exit 1
fi

echo "Applied Specula FD/epoll trace instrumentation to $SOURCE_ROOT"
