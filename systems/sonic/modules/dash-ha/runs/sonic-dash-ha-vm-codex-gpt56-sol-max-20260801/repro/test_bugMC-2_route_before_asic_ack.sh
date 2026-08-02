#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=$(cd -- "$script_dir/.." && pwd)
repo="$output_dir/confirmation/MC-2/worktree"
swss_repo=/users/Pial/dependencies/sonic-swss-common
toolchain_lib="$output_dir/harness/.deps/root/usr/lib/x86_64-linux-gnu"

export SWSS_COMMON_REPO="$swss_repo"
export LIBCLANG_PATH="$toolchain_lib"
export LD_LIBRARY_PATH="$swss_repo/common/.libs:$toolchain_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CARGO_TERM_COLOR=never

cd "$repo"
timeout 10m cargo test -p hamgrd \
    actors::ha_set::mc2_repro::mc2_route_programmed_before_asic_ack \
    -- --exact --nocapture
