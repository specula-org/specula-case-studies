#!/bin/sh

set -eu

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
SOURCE_ROOT=$(dirname -- "$OUTPUT_DIR")/source
TRACE_DIR=$OUTPUT_DIR/traces
LOG_DIR=$HARNESS_DIR/logs
CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-/tmp}/specula-asterinas-fd-epoll}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/asterinas:0.18.0-20260702
SCENARIOS="concurrent_fcntl dup_replace_flags close_reuse readiness_epoll"

mkdir -p "$LOG_DIR" "$TRACE_DIR/raw" "$RUSTUP_CACHE" \
	"$CARGO_CACHE/registry" "$CARGO_CACHE/git"
"$HARNESS_DIR/apply.sh" "$SOURCE_ROOT"

if [ ! -c /dev/kvm ]; then
	echo "run.sh: /dev/kvm is required for the SMP=2 Asterinas runs" >&2
	exit 1
fi

export SCENARIOS

timeout 1200 docker run --rm --network=host \
	-v "$RUSTUP_CACHE":/root/.rustup \
	"$IMAGE" bash -lc '
		set -eu
		if ! rustup component list \
			--toolchain nightly-2026-07-21-x86_64-unknown-linux-gnu \
			--installed >/dev/null 2>&1; then
			cd /tmp
			timeout 1100 rustup toolchain install nightly-2026-07-21 \
				--profile minimal \
				--component rust-src \
				--component rustc-dev \
				--component llvm-tools-preview \
				--target x86_64-unknown-none
		fi
	'

timeout 1800 docker run --rm --privileged --network=host \
	--device=/dev/kvm \
	-v "$RUSTUP_CACHE":/root/.rustup \
	-v "$CARGO_CACHE/registry":/root/.cargo/registry \
	-v "$CARGO_CACHE/git":/root/.cargo/git \
	-v "$SOURCE_ROOT":/root/asterinas \
	-v "$OUTPUT_DIR":/root/specula-output \
	-e SCENARIOS \
	-w /root/asterinas \
	"$IMAGE" bash -lc '
		set -euo pipefail
		output_uid=$(stat -c %u /root/specula-output/harness/run.sh)
		output_gid=$(stat -c %g /root/specula-output/harness/run.sh)
		trap '\''chown -R "$output_uid:$output_gid" /root/specula-output/harness/logs /root/specula-output/traces 2>/dev/null || true'\'' EXIT

		export RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu

		cd /root/asterinas
		timeout 1800 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 > /root/specula-output/harness/logs/build.log 2>&1

		for scenario in $SCENARIOS; do
			log=/root/specula-output/harness/logs/$scenario.log
			timeout 600 make run_kernel \
				SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
				INITRAMFS_SKIP_GZIP=1 \
				SPECULA_INIT=/test/io/specula/run_$scenario.sh \
				2>&1 | tee "$log"
			grep -q "SPECULA_SCENARIO_PASS $scenario" "$log"
		done
	'

for scenario in $SCENARIOS; do
	python3 "$HARNESS_DIR/collect_trace.py" \
		"$scenario" "$LOG_DIR/$scenario.log" "$TRACE_DIR"
done
python3 "$HARNESS_DIR/check_traces.py" "$TRACE_DIR"
