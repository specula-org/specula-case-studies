#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(dirname -- "$HARNESS_DIR")"
SOURCE_DIR="${TEMPORAL_SOURCE:-/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-history-queue}"
export TEMPORAL_SOURCE="$SOURCE_DIR"
bash "$HARNESS_DIR/apply.sh"
RUN_DIR="$(mktemp -d "$HARNESS_DIR/evidence/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
export HQ_EVIDENCE_DIR="$RUN_DIR"
python3 - "$SOURCE_DIR" "$RUN_DIR" <<'PY'
import hashlib,json,pathlib,subprocess,sys
source=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2])
metadata={'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip(),'go':subprocess.check_output(['go','version'],cwd=source,text=True).strip(),'command':"timeout 600 go test -tags test_dep -count=1 -v -run '^TestTransferQueueActiveTaskExecutorSuite$/^TestHQTrace' ./service/history",'source':str(source),'backend':'SQLite WAL synchronous=FULL'}
(out/'command.json').write_text(json.dumps(metadata,indent=2))
PY
(
 cd "$SOURCE_DIR"
 timeout 600 go test -tags test_dep -count=1 -v \
  -run '^TestTransferQueueActiveTaskExecutorSuite$/^TestHQTrace' ./service/history
) > "$RUN_DIR/go-test.log" 2>&1 || { cat "$RUN_DIR/go-test.log"; exit 1; }
for scenario in healthy batched_checkpoint delete_lost_reply matching_lost_reply cursor_healthy cursor_stall; do
 python3 "$HARNESS_DIR/reduce.py" "$RUN_DIR/$scenario/raw.ndjson" "$OUTPUT_DIR/traces/$scenario.ndjson"
done
python3 "$HARNESS_DIR/validate.py" --evidence "$RUN_DIR/validation" --controls
python3 "$HARNESS_DIR/report.py" "$RUN_DIR"
printf '%s\n' "$RUN_DIR" > "$HARNESS_DIR/evidence/latest-run.txt"
wc -l "$OUTPUT_DIR"/traces/*.ndjson
echo "Evidence: $RUN_DIR"
