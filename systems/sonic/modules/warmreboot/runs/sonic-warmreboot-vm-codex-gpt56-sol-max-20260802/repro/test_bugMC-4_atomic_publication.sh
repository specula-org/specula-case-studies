#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_root=$(dirname -- "$script_dir")
source_root="$output_root/confirmation/MC-4/worktree/src/sonic-sairedis"
driver_source="$script_dir/bugMC4_public_flow_driver.cpp"
run_dir=$(mktemp -d /tmp/mc4-run-XXXXXX)
driver="$run_dir/bugMC4_public_flow_driver"
go_file="$run_dir/debugger-armed"
harness_log="$run_dir/harness.log"
gdb_log="$run_dir/gdb.log"
gdb_commands="$run_dir/gdb.commands"
harness_pid=""
gdb_pid=""

cleanup() {
    if [[ -n "$gdb_pid" ]] && kill -0 "$gdb_pid" 2>/dev/null; then
        kill "$gdb_pid" 2>/dev/null || true
        wait "$gdb_pid" 2>/dev/null || true
    fi
    if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
        kill "$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
    fi
    rm -f -- "$driver" "$go_file" "$harness_log" "$gdb_log" "$gdb_commands"
    rmdir -- "$run_dir" 2>/dev/null || true
}
trap cleanup EXIT

test "$(git -C "$source_root" rev-parse HEAD)" = "9bd6103824e4590b24fbce2bc014d8902b51eccb"
test -x "$source_root/syncd/.libs/syncd"

timeout 4m g++ -std=c++14 -g -O0 \
    -I"$source_root" \
    -I"$source_root/lib" \
    -I"$source_root/syncd" \
    -I"$source_root/SAI/inc" \
    -I"$source_root/SAI/experimental" \
    -I"$source_root/SAI/meta" \
    -I/usr/local/include \
    "$driver_source" \
    "$source_root/syncd/libSyncd.a" \
    -L"$source_root/vslib/.libs" -lsaivs \
    -L"$source_root/lib/.libs" -lsairedis \
    -L"$source_root/meta/.libs" -lsaimetadata -lsaimeta \
    -lhiredis -lswsscommon -ldl -lpthread -lzmq -lz \
    -Wl,-rpath,"$source_root/lib/.libs" \
    -Wl,-rpath,"$source_root/meta/.libs" \
    -Wl,-rpath,"$source_root/vslib/.libs" \
    -o "$driver"

LD_LIBRARY_PATH="$source_root/vslib/.libs:$source_root/lib/.libs:$source_root/meta/.libs:/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    timeout 90s "$driver" "$source_root" "$go_file" >"$harness_log" 2>&1 &
harness_pid=$!

for _ in $(seq 1 600); do
    if grep -q '^ATTACH_READY ' "$harness_log" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$harness_pid" 2>/dev/null; then
        wait "$harness_pid" || true
        cat "$harness_log"
        exit 1
    fi
    sleep 0.05
done

ready_line=$(grep '^ATTACH_READY ' "$harness_log" | tail -1)
syncd_pid=$(printf '%s\n' "$ready_line" | sed -n 's/.*syncd_pid=\([0-9][0-9]*\).*/\1/p')
redis_socket=$(printf '%s\n' "$ready_line" | sed -n 's/.*redis_socket=\([^ ]*\).*/\1/p')
test -n "$syncd_pid"
test -S "$redis_socket"

cat >"$gdb_commands" <<EOF
set pagination off
set confirm off
attach $syncd_pid
set \$mc4_cut = (char*) &_ZN5syncd11RedisClient15setVidAndRidMapERKSt13unordered_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEEE + 0x99
break *\$mc4_cut
commands
  silent
  printf "BREAKPOINT_HIT after_RedisClient.cpp:669 before_line_670=yes\\n"
  shell redis-cli -s $redis_socket -n 1 --raw HLEN VIDTORID | sed 's/^/BREAKPOINT VIDTORID_hlen=/'
  shell redis-cli -s $redis_socket -n 1 --raw HLEN RIDTOVID | sed 's/^/BREAKPOINT RIDTOVID_hlen=/'
  kill
  quit
end
printf "GDB_ARMED pid=$syncd_pid\\n"
continue
EOF

gdb -q -batch -x "$gdb_commands" >"$gdb_log" 2>&1 &
gdb_pid=$!
for _ in $(seq 1 200); do
    if grep -q '^GDB_ARMED ' "$gdb_log" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$gdb_pid" 2>/dev/null; then
        wait "$gdb_pid" || true
        cat "$gdb_log"
        cat "$harness_log"
        exit 1
    fi
    sleep 0.05
done
grep -q '^GDB_ARMED ' "$gdb_log"
: >"$go_file"

set +e
wait "$gdb_pid"
gdb_status=$?
gdb_pid=""
wait "$harness_pid"
harness_status=$?
harness_pid=""
set -e

cat "$harness_log"
cat "$gdb_log"

test "$gdb_status" -eq 0
test "$harness_status" -eq 0
grep -q '^BREAKPOINT_HIT after_RedisClient.cpp:669 before_line_670=yes' "$gdb_log"
grep -q '^BREAKPOINT VIDTORID_hlen=0' "$gdb_log"
grep -Eq '^BREAKPOINT RIDTOVID_hlen=[1-9][0-9]*' "$gdb_log"
grep -q '^TEST_PASS MC-4' "$harness_log"
