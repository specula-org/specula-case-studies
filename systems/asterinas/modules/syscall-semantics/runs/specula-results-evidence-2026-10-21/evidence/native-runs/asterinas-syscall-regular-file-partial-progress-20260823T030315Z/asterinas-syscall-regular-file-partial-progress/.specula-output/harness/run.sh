#!/bin/sh

set -eu

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
SOURCE_ROOT=$(dirname -- "$OUTPUT_DIR")/source
TRACE_DIR=$OUTPUT_DIR/traces
LOG_DIR=$HARNESS_DIR/logs
CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-/tmp}/specula-asterinas-regular-file}
RUSTUP_CACHE=$CACHE_ROOT/rustup
CARGO_CACHE=$CACHE_ROOT/cargo
IMAGE=asterinas/dev:0.18.1-20260805
SCENARIOS=${SPECULA_SCENARIOS:-"ramfs_normal ramfs_faults ramfs_zero_append ext2_buffered ext2_direct overlap_prefix reference_restart"}
INHERIT_METHODS_REV=98f7e3eb9efdac98faf5a7076f154f30894b9b02
INHERIT_METHODS_DB=inherit-methods-macro-8255edaf944235d3
HOST_CARGO_DIR=${CARGO_HOME:-$HOME/.cargo}
SEED_DB=${SPECULA_CARGO_GIT_SEED_DB:-$HOST_CARGO_DIR/git/db/$INHERIT_METHODS_DB}

mkdir -p "$LOG_DIR" "$TRACE_DIR/raw" "$RUSTUP_CACHE" \
	"$CARGO_CACHE/registry" "$CARGO_CACHE/git"
target_db=$CARGO_CACHE/git/db/$INHERIT_METHODS_DB
if git --git-dir="$SEED_DB" cat-file -e "$INHERIT_METHODS_REV^{commit}" 2>/dev/null \
	&& ! git --git-dir="$target_db" cat-file -e "$INHERIT_METHODS_REV^{commit}" 2>/dev/null; then
	mkdir -p "$target_db"
	cp -a "$SEED_DB/." "$target_db/"
fi
for scenario in $SCENARIOS; do
	rm -f "$LOG_DIR/$scenario.log" "$TRACE_DIR/$scenario.ndjson"
	rm -f "$TRACE_DIR/raw/$scenario-"*.ndjson
done
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
		cd /tmp
		timeout 1100 rustup toolchain install nightly-2026-07-21 \
			--profile minimal \
			--component rust-src \
			--component rustc-dev \
			--component llvm-tools-preview \
			--target x86_64-unknown-none
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
		export CARGO_NET_GIT_FETCH_WITH_CLI=true

		cd /root/asterinas
		timeout 1800 make kernel \
			SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
			INITRAMFS_SKIP_GZIP=1 \
			> /root/specula-output/harness/logs/build.log 2>&1

		for scenario in $SCENARIOS; do
			log=/root/specula-output/harness/logs/$scenario.log
			passed=false
			for run_attempt in 1 2 3; do
				if timeout 600 make run_kernel \
					SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true \
					INITRAMFS_SKIP_GZIP=1 \
					SPECULA_INIT=/test/io/specula/run_$scenario.sh \
					2>&1 | tee "$log" >/dev/null \
					&& grep -q "SPECULA_SCENARIO_PASS $scenario" "$log"; then
					passed=true
					echo "completed $scenario"
					break
				fi
			if [ "$run_attempt" -lt 3 ] \
				&& grep -q "Could not set up host forwarding rule" "$log"; then
				echo "retrying $scenario after QEMU host-port collision ($run_attempt/3)" >&2
				continue
			fi
			tail -80 "$log" >&2
			exit 1
			done
			if [ "$passed" != true ]; then
				exit 1
			fi
		done
	'

for scenario in $SCENARIOS; do
	python3 "$HARNESS_DIR/src/postprocess_trace.py" \
		"$scenario" "$LOG_DIR/$scenario.log" "$TRACE_DIR"
done
python3 "$HARNESS_DIR/src/check_traces.py" "$TRACE_DIR"

for scenario in $SCENARIOS; do
	lines=$(wc -l < "$TRACE_DIR/$scenario.ndjson")
	printf "%s: %s trace events\n" "$scenario" "$lines"
done
