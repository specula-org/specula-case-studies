#!/usr/bin/env python3
"""Mechanical consistency audit for the generated Asterinas FD/epoll model."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


PINNED_HEAD = "4ba4abbe8cb3f2892129d67b0301cf247bbdda0f"
TRANSIENT_PATTERNS = ("*.out", "*.dot", "*.bin", "MC_TE.tla", "*.st")


def fail(message: str) -> None:
    raise AssertionError(message)


def quoted(text: str) -> set[str]:
    return set(re.findall(r'"([^"]+)"', text))


def slice_between(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    finish = text.index(end, begin)
    return text[begin:finish]


def source_line_count(source_root: Path, reference: str) -> None:
    match = re.fullmatch(r"(kernel/.+\.rs):([0-9,-]+)", reference)
    if not match:
        fail(f"malformed source reference: {reference}")
    path = source_root / match.group(1)
    if not path.is_file():
        fail(f"missing source path: {reference}")
    line_count = sum(1 for _ in path.open(encoding="utf-8"))
    for part in match.group(2).split(","):
        bounds = [int(value) for value in part.split("-")]
        first, last = (bounds[0], bounds[-1])
        if first < 1 or last < first or last > line_count:
            fail(f"out-of-range source reference: {reference} ({line_count} lines)")


def main() -> int:
    spec = Path(__file__).resolve().parent
    run_root = spec.parent.parent
    source = run_root / "source"
    traces = run_root / ".specula-output" / "traces"

    base = (spec / "base.tla").read_text(encoding="utf-8")
    mc = (spec / "MC.tla").read_text(encoding="utf-8")
    controls = (spec / "MC_Controls.tla").read_text(encoding="utf-8")
    trace = (spec / "Trace.tla").read_text(encoding="utf-8")
    instrumentation = (spec / "instrumentation-spec.md").read_text(
        encoding="utf-8"
    )
    coverage = (spec / "brief-coverage.md").read_text(encoding="utf-8")

    action_block = slice_between(
        base, "ProductionActionNames ==", "ProductionActionSource(name) =="
    )
    actions = quoted(action_block)
    source_pairs = dict(
        re.findall(r'name = "([^"]+)" -> "([^"]+)"', base)
    )
    if set(source_pairs) != actions:
        fail(
            "source-map domain mismatch: "
            f"missing={sorted(actions - set(source_pairs))}, "
            f"extra={sorted(set(source_pairs) - actions)}"
        )
    for reference in source_pairs.values():
        source_line_count(source, reference)
    all_generated_text = "\n".join(
        (base, mc, controls, trace, instrumentation, coverage)
    )
    all_source_references = set(
        re.findall(r"kernel/[^\s`)*]+\.rs:[0-9,-]+", all_generated_text)
    )
    for reference in all_source_references:
        source_line_count(source, reference)

    bounded = set(
        re.findall(
            r'Bounded\(\s*"[^"]+"\s*,\s*[^,]+,\s*"([^"]+)"', mc
        )
    )
    reactive = set(re.findall(r'Reactive\(\s*"([^"]+)"', mc))
    wrappers = bounded | reactive
    if wrappers != actions:
        fail(
            "MC wrapper mismatch: "
            f"missing={sorted(actions - wrappers)}, "
            f"extra={sorted(wrappers - actions)}"
        )
    if "Base!HasProductionSource(actionName)" not in mc:
        fail("MC Bounded/Reactive wrappers do not consume the source index")

    validate_block = slice_between(trace, "ValidatePostState(t, line) ==", "MatchEvent(t, line) ==")
    match_block = slice_between(trace, "MatchEvent(t, line) ==", "TraceInit ==")
    validate_events = quoted(validate_block) & actions
    match_events = quoted(match_block) & actions
    if validate_events != actions or match_events != actions:
        fail(
            "Trace dispatch mismatch: "
            f"validate_missing={sorted(actions - validate_events)}, "
            f"validate_extra={sorted(validate_events - actions)}, "
            f"match_missing={sorted(actions - match_events)}, "
            f"match_extra={sorted(match_events - actions)}"
        )
    if "HasProductionSource(line.event)" not in validate_block:
        fail("ValidatePostState does not consume the source index")
    if "HasProductionSource(line.event)" not in match_block:
        fail("MatchEvent does not consume the source index")

    table = slice_between(
        instrumentation, "## 2. One-to-one action mapping", "## 3. Controller-only"
    )
    rows = set(re.findall(r"^\| `([^`]+)` \|", table, re.MULTILINE))
    if rows != actions:
        fail(
            "instrumentation row mismatch: "
            f"missing={sorted(actions - rows)}, extra={sorted(rows - actions)}"
        )

    mc_configs = sorted(spec.glob("MC*.cfg"))
    trace_configs = sorted(spec.glob("Trace*.cfg"))
    enabled_union: set[str] = set()
    liveness_symmetry: list[str] = []
    for config in mc_configs:
        content = config.read_text(encoding="utf-8")
        for block in re.findall(
            r"EnabledActions\s*=\s*\{(.*?)\}", content, re.DOTALL
        ):
            enabled = quoted(block)
            if not enabled <= actions:
                fail(f"unknown EnabledActions in {config.name}: {sorted(enabled-actions)}")
            enabled_union |= enabled
        if re.search(r"^PROPERTIES\b", content, re.MULTILINE) and re.search(
            r"^SYMMETRY\b", content, re.MULTILINE
        ):
            liveness_symmetry.append(config.name)
        if config.name not in coverage:
            fail(f"MC config absent from brief coverage inventory: {config.name}")
    if enabled_union != actions:
        fail(
            "production action reachability mismatch: "
            f"missing={sorted(actions-enabled_union)}, "
            f"extra={sorted(enabled_union-actions)}"
        )
    if liveness_symmetry:
        fail(f"liveness configs use symmetry: {liveness_symmetry}")

    fixture_events: set[str] = set()
    for fixture in sorted(traces.glob("*.json")):
        data = json.loads(fixture.read_text(encoding="utf-8"))
        for events in data["traces"].values():
            fixture_events |= {event["event"] for event in events}
    if not fixture_events <= actions:
        fail(f"unknown Trace fixture events: {sorted(fixture_events-actions)}")
    for config in trace_configs:
        content = config.read_text(encoding="utf-8")
        match = re.search(r'TraceFile\s*=\s*"([^"]+)"', content)
        if not match or not (spec / match.group(1)).resolve().is_file():
            fail(f"unresolved TraceFile in {config.name}")
        if config.name not in coverage:
            fail(f"Trace config absent from brief coverage inventory: {config.name}")

    controller_names = set(re.findall(r"^(MCInject\w+)\(", controls, re.MULTILINE))
    if controller_names & (validate_events | match_events):
        fail("controller-only mutation leaked into Trace dispatch")
    controller_blocks = re.findall(
        r"^(MCInject\w+)\([^\n]*\) ==(.*?)(?=^MC(?:Inject\w+\(|\w+Spec ==)|\Z)",
        controls,
        re.MULTILINE | re.DOTALL,
    )
    if {name for name, _ in controller_blocks} != controller_names:
        fail("could not parse every controller mutation block")
    missing_controller_sources = [
        name for name, body in controller_blocks if "kernel/" not in body
    ]
    if missing_controller_sources:
        fail(f"controller blocks without pinned source target: {missing_controller_sources}")

    transient = sorted(
        str(path.relative_to(spec))
        for pattern in TRANSIENT_PATTERNS
        for path in spec.glob(pattern)
    )
    if transient:
        fail(f"TLC transients in durable spec directory: {transient}")

    head = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if head != PINNED_HEAD:
        fail(f"source HEAD changed: {head}")
    source_status = subprocess.check_output(
        ["git", "-C", str(source), "status", "--short"], text=True
    ).strip()
    if source_status:
        fail(f"source checkout is dirty:\n{source_status}")

    print(f"production_actions={len(actions)}")
    print(f"source_rows={len(source_pairs)} resolved=all")
    print(f"all_pinned_source_references={len(all_source_references)} resolved=all")
    print(f"mc_wrappers={len(wrappers)} enabled_union={len(enabled_union)}")
    print(f"trace_validate_branches={len(validate_events)}")
    print(f"trace_match_branches={len(match_events)}")
    print(f"instrumentation_rows={len(rows)}")
    print(f"mc_configs={len(mc_configs)} liveness_plus_symmetry=0")
    print(f"trace_configs={len(trace_configs)} fixtures_json=valid")
    print(
        f"controller_mutations={len(controller_names)} "
        "source_targets=all trace_leaks=0"
    )
    print(f"source_head={head} source_clean=true")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, ValueError) as error:
        print(f"AUDIT FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
