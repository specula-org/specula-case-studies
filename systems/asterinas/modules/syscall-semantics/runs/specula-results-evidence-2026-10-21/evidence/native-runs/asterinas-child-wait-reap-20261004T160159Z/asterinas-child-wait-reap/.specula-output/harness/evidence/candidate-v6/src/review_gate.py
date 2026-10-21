#!/usr/bin/env python3
"""Check the review receipt without interpreting absence as approval."""
import hashlib
import json
from pathlib import Path


def check(consistency=False, outcome=False):
    if not __debug__:
        raise RuntimeError("Python optimization disables required refusal checks")
    harness = Path(__file__).resolve().parent.parent
    gate = json.loads((harness / "review-gate.json").read_text())
    if gate["status"] != "APPROVED":
        raise RuntimeError(gate["blocking_finding"])
    assert not (consistency and outcome), "choose one collection scope"
    assert gate["candidate"] == "v6", "review receipt is not for candidate v6"
    scopes = {"OUTCOME_ONLY", "CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND"}
    assert gate["approval_scope"] in scopes, "review receipt has no collection scope"
    if not outcome:
        assert gate["approval_scope"] == "CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND", "clock diagnostics and grouped consistency mode are not approved"
    else:
        assert gate["approval_scope"] == "OUTCOME_ONLY", "outcome-only mode is not approved"
    review = harness / gate["review"]
    assert hashlib.sha256(review.read_bytes()).hexdigest() == gate["review_sha256"]
    inputs = gate["reviewed_inputs"]
    required = {str(p.relative_to(harness)) for p in (harness / "src").iterdir() if p.is_file()}
    required.update({"run.sh", "apply.sh", "cases.tsv", "patches/instrumentation.patch", "evidence/applied.json"})
    required.update({"INSTRUMENTATION.md", "STATUS.md", "evidence/clock-method-v4.md",
                     "evidence/clock-method-v5.md", "evidence/v5-inputs.json", "evidence/candidate-v5/hashes.json",
                     "evidence/outcome-mode-v6.md", "evidence/v6-inputs.json", "evidence/candidate-v6/hashes.json"})
    required.update("../spec/" + p for p in ("base.tla", "Trace.tla", "Trace.cfg", "TraceSearch.cfg", "instrumentation-spec.md"))
    assert required <= set(inputs), "review receipt does not cover every semantic input"
    for name, expected in inputs.items():
        assert hashlib.sha256((harness / name).read_bytes()).hexdigest() == expected, f"changed reviewed input: {name}"
    snapshot = harness / "evidence/candidate-v6"
    for name, expected in json.loads((snapshot / "hashes.json").read_text()).items():
        assert hashlib.sha256((snapshot / name).read_bytes()).hexdigest() == expected, f"changed frozen v6 input: {name}"


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--consistency", action="store_true")
    modes.add_argument("--outcome", "--diagnostic", dest="outcome", action="store_true")
    args = parser.parse_args()
    try:
        check(consistency=args.consistency, outcome=args.outcome)
    except (RuntimeError, AssertionError, KeyError, OSError) as error:
        print(f"INCOMPLETE_REVIEW_GATE: {error}")
        raise SystemExit(78)
