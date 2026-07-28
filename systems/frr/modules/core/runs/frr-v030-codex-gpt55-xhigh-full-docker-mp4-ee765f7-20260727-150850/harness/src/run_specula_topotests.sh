#!/usr/bin/env bash
set -euo pipefail

cd /root/persist/frr-build/tests/topotests

export TOPOTESTS_CHECK_MEMLEAK="${TOPOTESTS_CHECK_MEMLEAK:-/tmp/memleak_}"
export TOPOTESTS_CHECK_STDERR="${TOPOTESTS_CHECK_STDERR:-Yes}"
export PYTHONUNBUFFERED=1

mkdir -p /tmp/traces
chmod 0777 /tmp/traces

run_scenario() {
	local scenario="$1"
	local test_name="$2"
	local p1="$3"
	local p2="$4"
	local trace_router="$5"
	local stop_event="$6"
	local stop_note="$7"
	local trace="/tmp/traces/${scenario}.ndjson"
	local notify="/tmp/traces/${scenario}.notify"

	rm -f "$trace" "$notify"
	export SPECULA_TRACE_FILE="$trace"
	export SPECULA_NOTIFY_STATE="$notify"
	export SPECULA_PREFIX_P1="$p1"
	export SPECULA_PREFIX_P2="$p2"
	export SPECULA_TRACE_ROUTER="$trace_router"

	pytest -s \
		--junitxml "/tmp/topotests-${scenario}.xml" \
		"specula_route_realization/test_specula_route_realization.py::${test_name}"

	python3 - "$trace" "$stop_event" "$stop_note" <<'PY'
import json
import os
import sys

path, stop_event, stop_note = sys.argv[1:]
out = []
matched = False

with open(path, "r", encoding="utf-8") as f:
    for line in f:
        out.append(line)
        obj = json.loads(line)
        event = obj.get("event", {})
        if (
            obj.get("tag") == "frr_route_realization"
            and event.get("name") == stop_event
            and (not stop_note or event.get("note") == stop_note)
        ):
            matched = True
            break

if not matched:
    raise SystemExit(f"{path}: stop event {stop_event}/{stop_note or '*'} not found")

tmp = f"{path}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.writelines(out)
os.replace(tmp, path)
PY

	if [ ! -s "$trace" ]; then
		echo "scenario ${scenario} produced no trace events" >&2
		exit 1
	fi
}

run_scenario "static_route_realization" \
	"test_static_route_realization" \
	"198.51.100.0/24" \
	"203.0.113.0/24" \
	"r1" \
	"route_notify_internal" \
	"installed"

run_scenario "bgp_suppress_fib_route_realization" \
	"test_bgp_suppress_fib_route_realization" \
	"10.0.0.0/24" \
	"203.0.113.0/24" \
	"r1" \
	"bgp_zebra_route_notify_owner" \
	"installed"
