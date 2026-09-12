#!/usr/bin/env bash
set -euo pipefail

source_repo="${SOURCE_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-1/worktree}"
repro_root="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro"
harness="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/harness"
trace_dir="$(mktemp -d "$repro_root/cr1-traces.XXXXXX")"
log_file="$trace_dir/go-test.log"
run_regex='^(TestSpeculaMatchingNormal|TestSpeculaMatchingUncertain|TestSpeculaMatchingAppendShutdown|TestSpeculaMatchingInsertionAfterStop|TestSpeculaMatchingReplacementFencing)$'

echo "CR-1 reproduction: acceptance uncertainty and fresh ownership"
echo "source_repo=$source_repo"
echo "trace_dir=$trace_dir"
echo "run_regex=$run_regex"
echo "command=env TEMPORAL_TEST_TIMEOUT=13m SPECULA_HARNESS=$harness SPECULA_TRACE_DIR=$trace_dir timeout 900 go test -p 1 -tags test_dep ./service/matching -run '$run_regex' -count=1 -timeout=14m -v"

cd "$source_repo"
set +e
env TEMPORAL_TEST_TIMEOUT=13m SPECULA_HARNESS="$harness" SPECULA_TRACE_DIR="$trace_dir" \
	timeout 900 go test -p 1 -tags test_dep ./service/matching -run "$run_regex" -count=1 -timeout=14m -v 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

echo "go_test_exit=$status"

python3 - "$trace_dir" <<'PY'
import collections
import json
import sys
from pathlib import Path

trace_dir = Path(sys.argv[1])
names = [
    "normal",
    "uncertain-write",
    "append-shutdown",
    "insertion-after-stop",
    "replacement-fencing",
]
interesting = [
    "CreateTasksCommit",
    "CreateTasksUncertainReturn",
    "CreateTasksConditionFailed",
    "AddTaskReply",
    "AddTaskReplyLost",
    "AppendTaskShutdown",
    "TakeOverTaskQueueBegin",
    "UpdateTaskQueueCommit",
    "GetTasksSnapshot",
    "RecordTaskStarted",
    "RecordTaskStartedError",
    "PollTaskQueueResponse",
    "CompleteTask",
    "DeleteTasks",
    "TraceEnd",
]

print("=== trace evidence summary ===")
for name in names:
    path = trace_dir / f"{name}.ndjson"
    evidence_path = trace_dir / f"{name}.ndjson.evidence.json"
    owner_path = trace_dir / f"{name}.ndjson.owner-readback.json"
    print(f"TRACE {name}")
    if not path.exists():
        print("  missing=true")
        continue
    records = []
    with path.open() as f:
        for line in f:
            if not line.strip():
                continue
            obj = json.loads(line)
            rec = obj.get("record", obj)
            if rec.get("tag") == "temporal-matching":
                records.append(rec)
    counts = collections.Counter(r.get("event") for r in records)
    selected = {k: counts[k] for k in interesting if counts[k]}
    print("  events=" + json.dumps(selected, sort_keys=True))
    trace_end = next((r for r in reversed(records) if r.get("event") == "TraceEnd"), None)
    if evidence_path.exists():
        evidence = json.loads(evidence_path.read_text())
        print("  durable_end=" + json.dumps(evidence.get("durable"), sort_keys=True))
    if trace_end:
        post = trace_end.get("post", {})
        history = post.get("history", {})
        worker_true = sum(1 for h in history.values() if isinstance(h, dict) and h.get("worker"))
        starts = [h.get("start") for h in history.values() if isinstance(h, dict) and h.get("start")]
        obsolete = sum(1 for h in history.values() if isinstance(h, dict) and h.get("obsolete"))
        expired = sum(1 for h in history.values() if isinstance(h, dict) and h.get("expired"))
        calls = [
            {
                "pc": c.get("pc"),
                "response": c.get("response"),
                "receipt": c.get("receipt"),
                "buffer": c.get("buffer"),
            }
            for c in post.get("calls", [])
            if isinstance(c, dict) and c.get("pc") != "unused"
        ]
        owners = [
            {
                "life": o.get("life"),
                "range": o.get("range"),
                "read": o.get("read"),
                "ack": o.get("ack"),
                "maxRead": o.get("maxRead"),
                "loaded": o.get("loaded"),
                "queued": o.get("queued"),
                "outstanding": o.get("outstanding"),
                "skipFinal": o.get("skipFinal"),
            }
            for o in post.get("owner", [])
            if isinstance(o, dict) and o.get("life") != "cold"
        ]
        print(f"  history_worker_true={worker_true} starts={starts} obsolete={obsolete} expired={expired}")
        print("  calls=" + json.dumps(calls, sort_keys=True))
        print("  owners=" + json.dumps(owners, sort_keys=True))
    print(f"  files={path.name},{evidence_path.name if evidence_path.exists() else 'missing-evidence'},{owner_path.name if owner_path.exists() else 'missing-owner-readback'}")

print("=== summary ===")
print("normal and targeted uncertainty/reload scenarios completed; see go_test_exit above")
PY

exit "$status"
