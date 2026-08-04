#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="${SPECULA_RATIS_GRPC_ARTIFACT:-/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc}"
TRACE_DIR="${SPECULA_TRACE_DIR:-$OUTPUT_DIR/traces}"
SPEC_DIR="${SPECULA_TRACE_SPEC_DIR:-$OUTPUT_DIR/spec}"
LOG_DIR="$SCRIPT_DIR/logs"
MVN_TIMEOUT="${SPECULA_MVN_TIMEOUT:-1800}"
TLC_TIMEOUT="${SPECULA_TLC_TIMEOUT:-300}"
TLC_CP="${SPECULA_TLC_CP:-/home/ubuntu/specula-ratis-issue123-20260803/specula/lib/tla2tools.jar:/home/ubuntu/specula-ratis-issue123-20260803/specula/lib/CommunityModules-deps.jar}"

install -d "$TRACE_DIR" "$LOG_DIR"

bash "$SCRIPT_DIR/apply.sh"

python3 - "$TRACE_DIR" <<'PY'
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
trace_dir.mkdir(parents=True, exist_ok=True)
for path in trace_dir.glob("*.ndjson"):
    path.unlink()
PY

echo "Running TestSpeculaGrpcTraceHarness"
pushd "$ARTIFACT" >/dev/null
if ! timeout "$MVN_TIMEOUT" ./mvnw \
    -pl ratis-test -am \
    -DskipShade \
    -DskipRat \
    -Dcheckstyle.skip \
    -Dspotbugs.skip \
    -Dfindbugs.skip \
    -Dtest=TestSpeculaGrpcTraceHarness \
    -DfailIfNoTests=false \
    "-Dspecula.ratis.grpc.trace.dir=$TRACE_DIR" \
    test >"$LOG_DIR/maven-test.log" 2>&1; then
  tail -n 160 "$LOG_DIR/maven-test.log" >&2
  exit 1
fi
popd >/dev/null
tail -n 40 "$LOG_DIR/maven-test.log"

python3 - "$TRACE_DIR" <<'PY'
import collections
import json
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
expected_files = {
    "normal-append.ndjson": [
        "SendAppendData",
        "FollowerAppendSuccess",
        "ReceiveSuccessWithRequest",
        "AdvanceCommitIndex",
    ],
    "timeout-restart.ndjson": [
        "TimeoutAppend",
        "RestartAppender",
    ],
    "snapshot-staging-peer.ndjson": [
        "AddStagingPeer",
        "SnapshotAttemptForStagingPeer",
        "SendSnapshotChunk",
        "CheckProgress",
        "ApplyStagingConfiguration",
    ],
}
reset_or_cancel = {"StreamCompleteReset", "StreamErrorReset", "CancelAppendStream"}
known_events = {
    "SendAppendData",
    "AppendAfterSnapshot",
    "SendHeartbeat",
    "TimeoutAppend",
    "StreamErrorReset",
    "StreamCompleteReset",
    "Reconnect",
    "FollowerAppendSuccess",
    "FollowerAppendInconsistency",
    "ReceiveSuccessWithRequest",
    "ReceiveSuccessWithoutRequest",
    "ReceiveInconsistencyWithRequest",
    "ReceiveInconsistencyWithoutRequest",
    "CompactLeaderLog",
    "TriggerSnapshot",
    "SendSnapshotChunk",
    "FollowerSnapshotInProgress",
    "SnapshotInstalled",
    "SnapshotAlreadyInstalled",
    "SnapshotUnavailableOrExpired",
    "OldAppendReplyAfterSnapshot",
    "AddStagingPeer",
    "RestartAppender",
    "AppendSuccessForStagingPeer",
    "SnapshotAttemptForStagingPeer",
    "CheckProgress",
    "ApplyStagingConfiguration",
    "SetStreamReady",
    "CancelAppendStream",
    "SnapshotBackpressureBlock",
    "ResourceExhausted",
    "AdvanceCommitIndex",
}

errors = []
all_counts = collections.Counter()
for name, required in expected_files.items():
    path = trace_dir / name
    if not path.exists():
        errors.append(f"missing trace file: {path}")
        continue
    counts = collections.Counter()
    line_count = 0
    with path.open(encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            line_count += 1
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                errors.append(f"{name}:{line_no}: invalid JSON: {exc}")
                continue
            tag = obj.get("tag")
            if tag == "config":
                if "ts" not in obj or "scenario" not in obj:
                    errors.append(f"{name}:{line_no}: config line missing ts or scenario")
                continue
            if tag != "ratis-grpc":
                errors.append(f"{name}:{line_no}: unexpected tag {tag!r}")
                continue
            event = obj.get("event")
            if event not in known_events:
                errors.append(f"{name}:{line_no}: unknown event {event!r}")
                continue
            if "ts" not in obj or "node" not in obj:
                errors.append(f"{name}:{line_no}: event missing ts or node")
            if event not in {"CompactLeaderLog", "ApplyStagingConfiguration", "ResourceExhausted", "AdvanceCommitIndex"}:
                if "follower" not in obj:
                    errors.append(f"{name}:{line_no}: follower event missing follower")
            counts[event] += 1
            all_counts[event] += 1
    if line_count == 0:
        errors.append(f"{name}: empty trace file")
    missing = [event for event in required if counts[event] == 0]
    if missing:
        errors.append(f"{name}: missing required events {missing}")
    if name == "timeout-restart.ndjson" and not any(counts[event] for event in reset_or_cancel):
        errors.append(f"{name}: missing stream reset/cancel event")
    if name == "snapshot-staging-peer.ndjson":
        if not (counts["SnapshotInstalled"] or counts["SnapshotAlreadyInstalled"]):
            errors.append(f"{name}: missing installed snapshot event")
    print(f"{name}: {line_count} lines")
    for event, count in sorted(counts.items()):
        print(f"  {event}: {count}")

if errors:
    print("Trace validation errors:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

uncovered = sorted(event for event in known_events if all_counts[event] == 0)
print("All required trace files passed JSON and event coverage checks.")
if uncovered:
    print("Uncovered optional events:")
    for event in uncovered:
        print(f"  {event}")
PY

if [ "${SPECULA_RUN_TLC:-0}" = "1" ]; then
  echo "Running optional TLC replay smoke checks"
  tlc_status=0
  for trace in "$TRACE_DIR"/*.ndjson; do
    name="$(basename "$trace" .ndjson)"
    log="$LOG_DIR/tlc-$name.log"
    if JSON="$trace" timeout "$TLC_TIMEOUT" java -cp "$TLC_CP" tlc2.TLC \
        -config "$SCRIPT_DIR/Trace.harness.cfg" \
        -deadlock -noTE Trace >"$log" 2>&1; then
      echo "TLC replay passed: $name"
    else
      echo "TLC replay failed: $name; see $log" >&2
      tail -n 80 "$log" >&2
      tlc_status=1
    fi
  done
  exit "$tlc_status"
fi

echo "Trace files are in $TRACE_DIR"
echo "Optional TLC replay: SPECULA_RUN_TLC=1 bash $SCRIPT_DIR/run.sh"
