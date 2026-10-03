#!/usr/bin/env python3
"""Phase 2 preservation/output audit; does not execute product code or TLC."""
import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(__file__).resolve().parents[1]
ROOT = OUT.parents[4]
HANDOFF = ROOT / "handoff"
SOURCE = ROOT / "source"
SUPPLIED = HANDOFF / "full/run/nvflare-job/.specula-output"
PIN = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args):
    r = subprocess.run(args, cwd=SOURCE, text=True, capture_output=True)
    return {"command": args, "cwd": str(SOURCE), "exit_code": r.returncode,
            "stdout": r.stdout, "stderr": r.stderr}


result = {"kind": "Phase 2 preservation/output checks, not verification verdict",
          "checked_at_utc": datetime.now(timezone.utc).isoformat(),
          "command": ["python3", str(Path(__file__).resolve())]}
manifest = json.loads((HANDOFF / "asset-manifest.json").read_text())
original_bad = [x["path"] for x in manifest if sha(SUPPLIED / x["path"]) != x["sha256"]]
result["original_assets"] = {"checked": len(manifest), "mismatches": original_bad}

records = json.loads((HANDOFF / "conversations/index.json").read_text())
raw_bad = [x["raw"] for x in records if sha(HANDOFF / x["raw"]) != x["sha256"]]
result["raw_conversations"] = {"checked": len(records), "mismatches": raw_bad}

inventory = json.loads((OUT / "adoption/inventory.json").read_text())
changed = [x["workspace"] for x in inventory["copied"]
           if sha(OUT / x["workspace"]) != x["sha256"]]
result["adopted_assets"] = {"checked": len(inventory["copied"]),
                            "changed": changed,
                            "expected_document_changes": ["spec/brief-coverage.md"]}
result["source_head"] = command(["git", "rev-parse", "HEAD"])
result["source_status"] = command(["git", "status", "--short"])
result["tracked_source_diff"] = command(["git", "diff", "--exit-code", PIN, "--"])

mandatory = ["modeling-brief.md", "takeover-review.md", "spec/base.tla", "spec/base.cfg",
             "spec/MC.tla", "spec/MC.cfg", "spec/Trace.tla", "spec/Trace.cfg",
             "spec/instrumentation-spec.md", "spec/brief-coverage.md"]
result["mandatory_outputs"] = [{"path": x, "bytes": (OUT / x).stat().st_size,
                                "sha256": sha(OUT / x)} for x in mandatory]
result["hunt_cfg_count"] = len(list((OUT / "spec").glob("MC_hunt_*.cfg")))
result["seed_cfg_count"] = len(list((OUT / "spec").glob("MC_seed_*.cfg")))
result["all_cfg_count"] = len(list((OUT / "spec").glob("*.cfg")))
result["historical_official_traces"] = len(list((OUT / "adoption/supplied-traces").glob("*.ndjson")))
result["active_traces_exist"] = (OUT / "traces").exists()

documents = ["modeling-brief.md", "takeover-review.md", "spec/brief-coverage.md",
             "adoption/model-audit.md", "adoption/harness-audit.md",
             "adoption/findings-reconciliation.md", "adoption/README.md", "index.md"]
broken = []
for rel in documents:
    f = OUT / rel
    for link in re.findall(r"\]\(([^)]+)\)", f.read_text()):
        if "://" in link or link.startswith("#"):
            continue
        dest = re.sub(r":\d+$", "", link.split("#")[0])
        if not (f.parent / dest).exists():
            broken.append({"document": rel, "link": link})
result["review_document_links"] = {"documents": documents, "broken": broken}
result["passed"] = (
    not original_bad and not raw_bad and changed == ["spec/brief-coverage.md"]
    and result["source_head"]["stdout"].strip() == PIN
    and result["tracked_source_diff"]["exit_code"] == 0
    and all(x["bytes"] > 0 for x in result["mandatory_outputs"])
    and result["hunt_cfg_count"] == 16 and result["seed_cfg_count"] == 7
    and result["all_cfg_count"] == 27 and result["historical_official_traces"] == 30
    and not result["active_traces_exist"] and not broken
)
(OUT / "adoption/integrity-checks.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({k: v for k, v in result.items() if k in
                 ("passed", "original_assets", "raw_conversations", "adopted_assets",
                  "hunt_cfg_count", "seed_cfg_count", "all_cfg_count",
                  "historical_official_traces", "active_traces_exist")}, indent=2))
raise SystemExit(0 if result["passed"] else 1)

