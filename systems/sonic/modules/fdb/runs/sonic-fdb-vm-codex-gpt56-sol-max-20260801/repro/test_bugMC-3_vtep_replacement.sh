#!/usr/bin/env bash
set -euo pipefail

mc3_repro_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mc3_worktree=$(CDPATH= cd -- "$mc3_repro_dir/../confirmation/MC-3/worktree" && pwd)
mc3_tmp=$(mktemp -d "${TMPDIR:-/tmp}/bugMC3.XXXXXX")
trap 'rm -rf -- "$mc3_tmp"' EXIT

cp -- "$mc3_worktree/orchagent/l2nhgorch.cpp" "$mc3_tmp/l2nhgorch.cpp"
cmp --silent "$mc3_worktree/orchagent/l2nhgorch.cpp" "$mc3_tmp/l2nhgorch.cpp"

for mc3_header in sai.h swssnet.h directory.h routeorch.h portsorch.h vxlanorch.h nhgorch.h l2nhgorch.h; do
    cp -- "$mc3_repro_dir/bugMC3_empty.hpp" "$mc3_tmp/$mc3_header"
done

# Extract the production endpoint-refcount and tunnel-user consumers verbatim.
sed -n '1013,1272p;1711,1835p' "$mc3_worktree/orchagent/vxlanorch.cpp" > "$mc3_tmp/vxlan_consumer.cpp"

mc3_sha=$(git -C "$mc3_worktree" rev-parse HEAD)
printf 'SOURCE_SHA=%s\n' "$mc3_sha"
printf 'SOURCE_UNMODIFIED=l2nhgorch.cpp plus vxlanorch.cpp:1013-1272,1711-1835\n'

timeout 2m g++ -std=c++17 -O0 -g \
    -include "$mc3_repro_dir/bugMC3_harness.hpp" \
    -I "$mc3_tmp" \
    "$mc3_tmp/l2nhgorch.cpp" \
    "$mc3_tmp/vxlan_consumer.cpp" \
    "$mc3_repro_dir/bugMC3_driver.cpp" \
    -o "$mc3_tmp/test_bugMC-3_vtep_replacement"

timeout 30s "$mc3_tmp/test_bugMC-3_vtep_replacement"
