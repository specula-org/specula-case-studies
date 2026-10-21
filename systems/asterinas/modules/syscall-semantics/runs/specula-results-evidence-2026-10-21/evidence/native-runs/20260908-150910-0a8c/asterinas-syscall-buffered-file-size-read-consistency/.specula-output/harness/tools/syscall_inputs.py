"""Generate and validate target-neutral syscall-input artifacts.

The contract describes input shape and accessibility. It deliberately does not
encode target source locations, known findings, or expected syscall results.
Target harnesses materialize the abstract cases and record observations in a
separate evidence sidecar.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, cast

SCHEMA_VERSION = 1
CONTRACT_ARTIFACT = "syscall-input-contract"
CASES_ARTIFACT = "syscall-input-cases"
EVIDENCE_ARTIFACT = "syscall-input-evidence"
MAX_GENERATED_CANDIDATES = 100_000
TRUNCATED_RC = 3

_DIRECTIONS = {"user-to-kernel", "kernel-to-user", "bidirectional"}
_SHAPES = {"buffer", "iovec"}
_POINTER_REGIONS = {
    "valid",
    "null",
    "unmapped",
    "prot-none",
    "read-only",
    "guard-page",
    "noncanonical",
    "kernel-range",
}
_ALIAS_TOPOLOGIES = {"disjoint", "identical", "adjacent", "partial-overlap"}
_FAULT_PATHS = {"metadata", "payload"}
_EVIDENCE_STATUSES = {"pass", "candidate", "unsupported", "not-run", "harness-error"}
_PROGRESS_FIELDS = {"attempted", "copied", "committed", "reported", "offset_advanced"}
_PROGRESS_FIELD_ORDER = tuple(sorted(_PROGRESS_FIELDS))
_EXECUTION_FIELDS = frozenset({"case_id", "status", "oracle", "observations", "evidence"})
_OBSERVATION_FIELDS = frozenset({"result", "progress", "state_before", "state_after"})
_RESULT_FIELDS = frozenset({"return", "errno"})
_CASE_FIELDS = frozenset(
    {
        "id",
        "copy_direction",
        "fault_paths",
        "input",
        "observations",
        "requested_length",
        "shape",
        "syscall",
    }
)
_CONTRACT_FIELDS = frozenset(
    {"schema_version", "artifact", "campaign", "page_size", "max_cases", "syscalls"}
)
_SYSCALL_FIELDS = frozenset(
    {
        "name",
        "direction",
        "shape",
        "lengths",
        "pointer_regions",
        "iov_counts",
        "alias_topologies",
        "fault_paths",
        "observations",
    }
)
_NAME_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")
_CASE_ID_RE = re.compile(r"uc-[0-9a-f]{16}")
_CASE_JSON_ENCODER = json.JSONEncoder(separators=(",", ":"), check_circular=False)
_IovecLayout = tuple[
    list[dict[str, Any]],
    tuple[tuple[str, int], ...],
    dict[str, tuple[tuple[int, str], ...]],
    str | None,
]


class ArtifactError(ValueError):
    """A user-supplied artifact violates the public contract."""


@dataclass(frozen=True)
class EvidenceSummary:
    execution_count: int
    status_counts: tuple[tuple[str, int], ...]


@dataclass(frozen=True)
class _GenerationComplexity:
    case_count: int
    edge_count: int
    object_count: int


def _object(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ArtifactError(f"{where} must be a JSON object")
    if value and not all(type(key) is str for key in value) and not all(isinstance(key, str) for key in value):
        raise ArtifactError(f"{where} must be a JSON object")
    return value


def _parsed_object(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ArtifactError(f"{where} must be a JSON object")
    return value


def _case_object(value: Any, where: str) -> dict[str, Any]:
    if isinstance(value, dict) and value.keys() == _CASE_FIELDS:
        return value
    return _object(value, where)


def _list(value: Any, where: str) -> list[Any]:
    if not isinstance(value, list):
        raise ArtifactError(f"{where} must be a JSON array")
    return value


def _reject_unknown(
    value: dict[str, Any], allowed: set[str] | frozenset[str], where: str
) -> None:
    keys = value.keys()
    if keys == allowed or keys <= allowed:
        return
    unknown = sorted(set(value) - allowed)
    raise ArtifactError(f"{where} has unknown field(s): {', '.join(unknown)}")


def _positive_int(value: Any, where: str, *, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 < value <= maximum:
        raise ArtifactError(f"{where} must be an integer in 1..{maximum}")
    return value


def _int_list(
    value: Any,
    where: str,
    *,
    minimum: int,
    maximum: int,
    max_items: int = 64,
) -> list[int]:
    raw = _list(value, where)
    if not raw:
        raise ArtifactError(f"{where} must not be empty")
    if len(raw) > max_items:
        raise ArtifactError(f"{where} must contain at most {max_items} entries")
    result: list[int] = []
    if len(raw) < 16:
        for index, item in enumerate(raw):
            if isinstance(item, bool) or not isinstance(item, int) or not minimum <= item <= maximum:
                raise ArtifactError(f"{where}[{index}] must be an integer in {minimum}..{maximum}")
            if item in result:
                raise ArtifactError(f"{where} contains duplicate value {item}")
            result.append(item)
        return result
    seen: set[int] = set()
    for index, item in enumerate(raw):
        if isinstance(item, bool) or not isinstance(item, int) or not minimum <= item <= maximum:
            raise ArtifactError(f"{where}[{index}] must be an integer in {minimum}..{maximum}")
        if item in seen:
            raise ArtifactError(f"{where} contains duplicate value {item}")
        seen.add(item)
        result.append(item)
    return result


def _enum_list(value: Any, where: str, allowed: set[str]) -> list[str]:
    raw = _list(value, where)
    if not raw:
        raise ArtifactError(f"{where} must not be empty")
    result: list[str] = []
    for index, item in enumerate(raw):
        if not isinstance(item, str) or item not in allowed:
            choices = ", ".join(sorted(allowed))
            raise ArtifactError(f"{where}[{index}] must be one of: {choices}")
        if item in result:
            raise ArtifactError(f"{where} contains duplicate value {item!r}")
        result.append(item)
    return result


def _contract(document: Any, *, parsed_json: bool = False) -> dict[str, Any]:
    as_object = _parsed_object if parsed_json else _object
    contract = as_object(document, "contract")
    _reject_unknown(contract, _CONTRACT_FIELDS, "contract")
    schema_version = contract.get("schema_version")
    if isinstance(schema_version, bool) or schema_version != SCHEMA_VERSION:
        raise ArtifactError(f"contract.schema_version must be the integer {SCHEMA_VERSION}")
    if contract.get("artifact") != CONTRACT_ARTIFACT:
        raise ArtifactError(f"contract.artifact must be {CONTRACT_ARTIFACT!r}")
    campaign = contract.get("campaign")
    if not isinstance(campaign, str) or not campaign or len(campaign) > 128:
        raise ArtifactError("contract.campaign must be a non-empty string of at most 128 characters")
    page_size = _positive_int(contract.get("page_size"), "contract.page_size", maximum=1 << 30)
    if page_size & (page_size - 1):
        raise ArtifactError("contract.page_size must be a power of two")
    _positive_int(contract.get("max_cases"), "contract.max_cases", maximum=100_000)

    raw_syscalls = _list(contract.get("syscalls"), "contract.syscalls")
    if not raw_syscalls:
        raise ArtifactError("contract.syscalls must not be empty")
    if len(raw_syscalls) > 64:
        raise ArtifactError("contract.syscalls must contain at most 64 entries")
    names: set[str] = set()
    for index, raw_syscall in enumerate(raw_syscalls):
        where = f"contract.syscalls[{index}]"
        syscall = as_object(raw_syscall, where)
        _reject_unknown(syscall, _SYSCALL_FIELDS, where)
        name = syscall.get("name")
        if not isinstance(name, str) or not _NAME_RE.fullmatch(name):
            raise ArtifactError(f"{where}.name must match {_NAME_RE.pattern}")
        if name in names:
            raise ArtifactError(f"contract.syscalls contains duplicate name {name!r}")
        names.add(name)
        if syscall.get("direction") not in _DIRECTIONS:
            raise ArtifactError(f"{where}.direction must be one of: {', '.join(sorted(_DIRECTIONS))}")
        shape = syscall.get("shape")
        if shape not in _SHAPES:
            raise ArtifactError(f"{where}.shape must be one of: {', '.join(sorted(_SHAPES))}")
        _int_list(
            syscall.get("lengths"),
            f"{where}.lengths",
            minimum=0,
            maximum=(1 << 63) - 1,
            max_items=64,
        )
        _enum_list(syscall.get("pointer_regions"), f"{where}.pointer_regions", _POINTER_REGIONS)
        observations = syscall.get("observations", [])
        if not isinstance(observations, list) or not all(
            isinstance(item, str) and _NAME_RE.fullmatch(item) for item in observations
        ):
            raise ArtifactError(f"{where}.observations must be an array of safe names")
        if len(set(observations)) != len(observations):
            raise ArtifactError(f"{where}.observations contains duplicates")
        if shape == "iovec":
            _int_list(
                syscall.get("iov_counts"),
                f"{where}.iov_counts",
                minimum=0,
                maximum=1024,
                max_items=16,
            )
            _enum_list(syscall.get("alias_topologies"), f"{where}.alias_topologies", _ALIAS_TOPOLOGIES)
            _enum_list(syscall.get("fault_paths", ["metadata", "payload"]), f"{where}.fault_paths", _FAULT_PATHS)
        elif any(field in syscall for field in ("iov_counts", "alias_topologies", "fault_paths")):
            raise ArtifactError(f"{where} may use iov_counts, alias_topologies, or fault_paths only for iovec")
    return contract


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest()


def _boundary_points(length: int, page_size: int) -> list[int]:
    points = {0, length}
    if length > 0:
        points.add(1)
        points.add(length - 1)
    page_boundaries = {page_size}
    last_page = ((length - 1) // page_size) * page_size if length else 0
    if last_page < length:
        page_boundaries.add(last_page)
    for page in page_boundaries:
        if 0 < page < length:
            points.update((page - 1, page, page + 1))
    return sorted(point for point in points if 0 <= point <= length)


def _copy_directions(direction: str) -> list[str]:
    if direction == "bidirectional":
        return ["user-to-kernel", "kernel-to-user"]
    return [direction]


def _accessible_units(region: str, direction: str, requested: int, page_size: int) -> list[int]:
    if region == "guard-page":
        return _boundary_points(requested, page_size)
    if region == "valid" or (region == "read-only" and direction == "user-to-kernel"):
        return [requested]
    return [0]


def _case_id(payload: dict[str, Any]) -> str:
    # Builders insert nested keys in sorted order and emit only schema-safe
    # ASCII strings, preserving canonical bytes without recursive sorting.
    # JSONEncoder keeps per-call state local; the shared object holds only options.
    encoded = _CASE_JSON_ENCODER.encode(payload).encode()
    return f"uc-{hashlib.sha256(encoded).hexdigest()[:16]}"


def _case_id_with_serialized_edges(payload: dict[str, Any], edge_field: str) -> str:
    input_object: dict[str, Any] = payload["input"]
    edges = input_object["edges"]
    input_object["edges"] = ()
    try:
        encoded = _CASE_JSON_ENCODER.encode(payload)
    finally:
        input_object["edges"] = edges
    encoded_bytes = encoded.replace('"edges":[]', edge_field, 1).encode()
    return f"uc-{hashlib.sha256(encoded_bytes).hexdigest()[:16]}"


def _default_observations(extra: list[str]) -> list[str]:
    defaults = [
        "return",
        "errno",
        "copied-bytes",
        "committed-state",
        "output-sentinels",
        "offset-delta",
        "resource-delta",
    ]
    return [*defaults, *(item for item in extra if item not in defaults)]


def _buffer_cases(
    syscall: dict[str, Any],
    page_size: int,
    *,
    limit: int | None = None,
    sink: Callable[[dict[str, Any]], None] | None = None,
) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    produced = 0
    if limit is not None and limit <= 0:
        return cases
    emit = cases.append if sink is None else sink
    stop_at = limit if limit is not None else float("inf")

    def add(case: dict[str, Any]) -> bool:
        nonlocal produced
        emit(case)
        produced += 1
        return produced >= stop_at
    observations = _default_observations(list(syscall.get("observations", [])))
    for direction in _copy_directions(str(syscall["direction"])):
        for length in list(syscall["lengths"]):
            for region in list(syscall["pointer_regions"]):
                for accessible in _accessible_units(str(region), direction, int(length), page_size):
                    payload: dict[str, Any] = {
                        "copy_direction": direction,
                        "fault_paths": [] if accessible >= length else ["buffer"],
                        "input": {
                            "edges": [],
                            "objects": [
                                {
                                    "access_direction": direction,
                                    "accessible_units": accessible,
                                    "id": "buffer",
                                    "kind": "buffer",
                                    "region": region,
                                    "requested_units": length,
                                    "unit": "byte",
                                }
                            ],
                        },
                        "observations": observations,
                        "requested_length": length,
                        "shape": "buffer",
                        "syscall": syscall["name"],
                    }
                    if add({"id": _case_id(payload), **payload}):
                        return cases
    return cases


def _ordinal_boundaries(count: int) -> list[int]:
    points = {0, count}
    if count > 0:
        points.update((1, count - 1))
    return sorted(points)


def _iovec_span_lengths(count: int, length: int, topology: str) -> list[int]:
    if count == 0:
        return []
    if topology == "disjoint":
        return [length] * count
    if topology == "identical":
        return [length]
    if topology == "adjacent":
        return [count * length]
    stride = max(1, length // 2) if length else 0
    return [(count - 1) * stride + length]


def _iovec_layout(
    count: int, length: int, topology: str, fault_labels: Sequence[str]
) -> _IovecLayout:
    edges: list[dict[str, Any]] = []
    grouped: dict[str, list[tuple[int, str]]] = {}
    for index in range(count):
        if topology == "disjoint":
            object_id, offset = f"buffer-{index}", 0
        elif topology == "identical":
            object_id, offset = "buffer-0", 0
        elif topology == "adjacent":
            object_id, offset = "buffer-0", index * length
        else:
            object_id = "buffer-0"
            offset = index * (max(1, length // 2) if length else 0)
        edges.append({"index": index, "length": length, "object_id": object_id, "offset": offset})
        end = offset + length
        grouped.setdefault(object_id, []).append((end, fault_labels[index]))
    return (
        edges,
        tuple(
            sorted(
                (object_id, object_edges[-1][0])
                for object_id, object_edges in grouped.items()
            )
        ),
        {object_id: tuple(object_edges) for object_id, object_edges in grouped.items()},
        None if len(edges) < 4 else '"edges":' + _CASE_JSON_ENCODER.encode(edges),
    )


def _iovec_case(
    syscall_name: str,
    *,
    direction: str,
    count: int,
    requested_length: int,
    topology: str,
    observations: list[str],
    layout: _IovecLayout,
    reuse_edges: bool = False,
    metadata_region: str = "valid",
    metadata_accessible: int | None = None,
    payload_override: tuple[str, str, int] | None = None,
) -> dict[str, Any]:
    template_edges, ordered_spans, faults_by_object, encoded_edge_field = layout
    edges = template_edges if reuse_edges else [edge.copy() for edge in template_edges]
    metadata_accessible = count if metadata_accessible is None else metadata_accessible
    objects: list[dict[str, Any]] = [
        {
            "access_direction": "user-to-kernel",
            "accessible_units": metadata_accessible,
            "id": "iovec",
            "kind": "iovec-array",
            "region": metadata_region,
            "requested_units": count,
            "unit": "entry",
        }
    ]
    for object_id, requested_units in ordered_spans:
        region, accessible = "valid", requested_units
        if payload_override is not None and payload_override[0] == object_id:
            _, region, accessible = payload_override
        objects.append(
            {
                "access_direction": direction,
                "accessible_units": accessible,
                "id": object_id,
                "kind": "buffer",
                "region": region,
                "requested_units": requested_units,
                "unit": "byte",
            }
        )

    faults: list[str] = []
    if metadata_accessible < count:
        faults.append("iovec-metadata")
    if payload_override is not None:
        overridden_object, _, overridden_accessible = payload_override
        for required_access, fault in faults_by_object.get(overridden_object, ()):
            if overridden_accessible < required_access:
                faults.append(fault)

    payload: dict[str, Any] = {
        "copy_direction": direction,
        "fault_paths": faults,
        "input": {
            "alias_topology": "none" if count == 0 else "single" if count == 1 else topology,
            "edges": edges,
            "objects": objects,
        },
        "observations": observations,
        "requested_length": requested_length,
        "shape": "iovec",
        "syscall": syscall_name,
    }
    case_id = (
        _case_id(payload)
        if encoded_edge_field is None
        else _case_id_with_serialized_edges(payload, encoded_edge_field)
    )
    return {"id": case_id, **payload}


def _iovec_cases(
    syscall: dict[str, Any],
    page_size: int,
    *,
    limit: int | None = None,
    sink: Callable[[dict[str, Any]], None] | None = None,
) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    produced = 0
    reuse_edges = sink is not None
    if limit is not None and limit <= 0:
        return cases
    emit = cases.append if sink is None else sink
    stop_at = limit if limit is not None else float("inf")

    def add(case: dict[str, Any]) -> bool:
        nonlocal produced
        emit(case)
        produced += 1
        if produced > MAX_GENERATED_CANDIDATES:
            raise ArtifactError(
                f"syscall {syscall['name']!r} expands beyond {MAX_GENERATED_CANDIDATES} candidate cases; "
                "narrow its lengths, iov_counts, pointer_regions, or alias_topologies"
            )
        return produced >= stop_at

    pointer_regions = [str(value) for value in list(syscall["pointer_regions"])]
    fault_paths = set(str(value) for value in list(syscall.get("fault_paths", ["metadata", "payload"])))
    fault_labels = [f"iov[{index}].base" for index in range(max(syscall["iov_counts"]))]
    observations = _default_observations(list(syscall.get("observations", [])))
    syscall_name = str(syscall["name"])
    metadata_boundaries = (
        {int(count): _ordinal_boundaries(int(count)) for count in list(syscall["iov_counts"])}
        if "metadata" in fault_paths and "guard-page" in pointer_regions
        else {}
    )
    accessibility_cache: dict[tuple[str, str, int, int], list[int]] = {}

    def accessible_units(region: str, direction: str, requested: int) -> list[int]:
        key = (region, direction, requested, page_size)
        if key not in accessibility_cache:
            accessibility_cache[key] = _accessible_units(region, direction, requested, page_size)
        return accessibility_cache[key]

    layout_cache: dict[tuple[int, int, str], _IovecLayout] = {}

    def layout_for(count: int, length: int, topology: str) -> _IovecLayout:
        key = (count, length, topology)
        if key not in layout_cache:
            layout_cache[key] = _iovec_layout(count, length, topology, fault_labels)
        return layout_cache[key]

    lengths = [int(value) for value in list(syscall["lengths"])]
    for direction in _copy_directions(str(syscall["direction"])):
        for length_int in lengths:
            for count in list(syscall["iov_counts"]):
                count_int = int(count)
                if count_int == 0 and length_int != lengths[0]:
                    continue
                topologies = ["disjoint"] if count_int < 2 else list(syscall["alias_topologies"])
                for topology in topologies:
                    if topology == "partial-overlap" and count_int >= 2 and length_int < 2:
                        continue
                    topology_name = str(topology)
                    layout = layout_for(count_int, length_int, topology_name)
                    requested_length = count_int * length_int
                    if add(
                        _iovec_case(
                            syscall_name,
                            direction=direction,
                            count=count_int,
                            requested_length=requested_length,
                            topology=topology_name,
                            observations=observations,
                            layout=layout,
                            reuse_edges=reuse_edges,
                        )
                    ):
                        return cases
                    if "metadata" in fault_paths:
                        for region in pointer_regions:
                            if region == "valid":
                                continue
                            boundaries = (
                                metadata_boundaries[count_int]
                                if region == "guard-page"
                                else accessible_units(region, "user-to-kernel", count_int)
                            )
                            for accessible in boundaries:
                                if add(
                                    _iovec_case(
                                        syscall_name,
                                        direction=direction,
                                        count=count_int,
                                        requested_length=requested_length,
                                        topology=topology_name,
                                        observations=observations,
                                        layout=layout,
                                        reuse_edges=reuse_edges,
                                        metadata_region=region,
                                        metadata_accessible=accessible,
                                    )
                                ):
                                    return cases
                    if "payload" in fault_paths:
                        _, ordered_spans, _, _ = layout
                        for object_id, span in ordered_spans:
                            for region in pointer_regions:
                                if region == "valid":
                                    continue
                                for accessible in accessible_units(region, direction, span):
                                    if add(
                                        _iovec_case(
                                            syscall_name,
                                            direction=direction,
                                            count=count_int,
                                            requested_length=requested_length,
                                            topology=topology_name,
                                            observations=observations,
                                            layout=layout,
                                            reuse_edges=reuse_edges,
                                            payload_override=(object_id, region, accessible),
                                        )
                                    ):
                                        return cases
    return cases


def _require_unique_case_ids(cases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ids = [case["id"] for case in cases]
    ids.sort()
    for index in range(1, len(ids)):
        if ids[index] == ids[index - 1]:
            raise ArtifactError(f"generator produced duplicate case ID or hash collision: {ids[index]}")
    return cases


def _estimate_complexity(contract: dict[str, Any]) -> _GenerationComplexity:
    page_size = int(contract["page_size"])
    case_count = edge_count = object_count = 0
    for raw_syscall in list(contract["syscalls"]):
        syscall = _object(raw_syscall, "contract.syscalls[]")
        before = case_count
        directions = _copy_directions(str(syscall["direction"]))
        pointer_regions = [str(value) for value in list(syscall["pointer_regions"])]
        if syscall["shape"] == "buffer":
            for direction in directions:
                for raw_length in list(syscall["lengths"]):
                    length = int(raw_length)
                    for region in pointer_regions:
                        variants = len(_accessible_units(region, direction, length, page_size))
                        case_count += variants
                        object_count += variants
        else:
            fault_paths = set(str(value) for value in list(syscall.get("fault_paths", ["metadata", "payload"])))
            lengths = [int(value) for value in list(syscall["lengths"])]
            for direction in directions:
                for length in lengths:
                    for raw_count in list(syscall["iov_counts"]):
                        count = int(raw_count)
                        if count == 0 and length != lengths[0]:
                            continue
                        topologies = ["disjoint"] if count < 2 else list(syscall["alias_topologies"])
                        for raw_topology in topologies:
                            topology = str(raw_topology)
                            if topology == "partial-overlap" and count >= 2 and length < 2:
                                continue
                            span_groups: tuple[tuple[int, int], ...]
                            if topology == "disjoint":
                                payload_object_count = count
                                span_groups = ((length, count),) if count else ()
                            else:
                                span_lengths = _iovec_span_lengths(count, length, topology)
                                payload_object_count = len(span_lengths)
                                span_groups = tuple((span, 1) for span in span_lengths)
                            variants = 1
                            if "metadata" in fault_paths:
                                for region in pointer_regions:
                                    if region == "valid":
                                        continue
                                    boundaries = (
                                        _ordinal_boundaries(count)
                                        if region == "guard-page"
                                        else _accessible_units(region, "user-to-kernel", count, page_size)
                                    )
                                    variants += len(boundaries)
                            if "payload" in fault_paths:
                                for span, multiplicity in span_groups:
                                    for region in pointer_regions:
                                        if region != "valid":
                                            variants += multiplicity * len(
                                                _accessible_units(region, direction, span, page_size)
                                            )
                            case_count += variants
                            edge_count += variants * count
                            object_count += variants * (1 + payload_object_count)
        if case_count == before:
            raise ArtifactError(f"syscall {syscall['name']!r} has no applicable input combinations")
    return _GenerationComplexity(case_count, edge_count, object_count)


def _materialized_graph_counts(
    cases: list[dict[str, Any]], *, parsed_json: bool = False
) -> tuple[int, int]:
    as_object = _parsed_object if parsed_json else _object
    edge_count = object_count = 0
    for case in cases:
        graph = as_object(case["input"], "case.input")
        edge_count += len(graph["edges"])
        object_count += len(graph["objects"])
    return edge_count, object_count


def _generation_summary(
    complexity: _GenerationComplexity,
    maximum: int,
    cases: list[dict[str, Any]],
) -> dict[str, Any]:
    if len(cases) == complexity.case_count:
        emitted_edge_count = complexity.edge_count
        emitted_object_count = complexity.object_count
    else:
        emitted_edge_count, emitted_object_count = _materialized_graph_counts(cases)
    return {
        "candidate_count": complexity.case_count,
        "candidate_edge_count": complexity.edge_count,
        "candidate_object_count": complexity.object_count,
        "emitted_count": len(cases),
        "emitted_edge_count": emitted_edge_count,
        "emitted_object_count": emitted_object_count,
        "max_cases": maximum,
        "truncated": len(cases) != complexity.case_count,
    }


def _compare_generated_cases(contract: dict[str, Any], supplied: list[dict[str, Any]]) -> None:
    page_size = int(contract["page_size"])
    maximum = int(contract["max_cases"])
    index = 0

    def compare(case: dict[str, Any]) -> None:
        nonlocal index
        if index >= len(supplied) or supplied[index] != case:
            raise ArtifactError("cases do not match deterministic generation from contract")
        index += 1

    for raw_syscall in list(contract["syscalls"]):
        remaining = maximum - index
        if remaining <= 0:
            break
        syscall = _object(raw_syscall, "contract.syscalls[]")
        if syscall["shape"] == "buffer":
            _buffer_cases(syscall, page_size, limit=remaining, sink=compare)
        else:
            _iovec_cases(syscall, page_size, limit=remaining, sink=compare)
    if index != len(supplied):
        raise ArtifactError("cases do not match deterministic generation from contract")


def generate_cases(document: Any, *, parsed_json: bool = False) -> dict[str, Any]:
    """Validate a contract and return a deterministic case document."""
    contract = _contract(document, parsed_json=parsed_json)
    complexity = _estimate_complexity(contract)
    if complexity.case_count > MAX_GENERATED_CANDIDATES:
        raise ArtifactError(f"contract expands beyond {MAX_GENERATED_CANDIDATES} candidate cases; narrow the contract")
    page_size = int(contract["page_size"])
    maximum = int(contract["max_cases"])
    generated: list[dict[str, Any]] = []
    for syscall in list(contract["syscalls"]):
        remaining = maximum - len(generated)
        if remaining <= 0:
            break
        syscall_obj = _object(syscall, "contract.syscalls[]")
        if syscall_obj["shape"] == "buffer":
            generated.extend(_buffer_cases(syscall_obj, page_size, limit=remaining))
        else:
            generated.extend(_iovec_cases(syscall_obj, page_size, limit=remaining))
    cases = _require_unique_case_ids(generated)
    expected_emitted = min(complexity.case_count, maximum)
    if len(cases) != expected_emitted:
        raise RuntimeError("pre-generation complexity estimate diverged from emitted case count")

    return {
        "schema_version": SCHEMA_VERSION,
        "artifact": CASES_ARTIFACT,
        "campaign": contract["campaign"],
        "contract_sha256": _canonical_sha256(contract),
        "generation": _generation_summary(complexity, maximum, cases),
        "cases": cases,
    }


def _cases(
    document: Any, contract: dict[str, Any] | None = None, *, parsed_json: bool = False
) -> dict[str, Any]:
    as_object = _parsed_object if parsed_json else _object
    as_case_object = _parsed_object if parsed_json else _case_object
    cases = as_object(document, "cases")
    _reject_unknown(
        cases,
        {"schema_version", "artifact", "campaign", "contract_sha256", "generation", "cases"},
        "cases",
    )
    schema_version = cases.get("schema_version")
    if isinstance(schema_version, bool) or schema_version != SCHEMA_VERSION:
        raise ArtifactError(f"cases.schema_version must be the integer {SCHEMA_VERSION}")
    if cases.get("artifact") != CASES_ARTIFACT:
        raise ArtifactError(f"cases.artifact must be {CASES_ARTIFACT!r}")
    campaign = cases.get("campaign")
    digest = cases.get("contract_sha256")
    if not isinstance(campaign, str) or not campaign:
        raise ArtifactError("cases.campaign must be a non-empty string")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ArtifactError("cases.contract_sha256 must be a lowercase SHA-256 digest")
    generation = as_object(cases.get("generation"), "cases.generation")
    count_fields = (
        "candidate_count",
        "candidate_edge_count",
        "candidate_object_count",
        "emitted_count",
        "emitted_edge_count",
        "emitted_object_count",
        "max_cases",
    )
    _reject_unknown(generation, {*count_fields, "truncated"}, "cases.generation")
    for field in count_fields:
        value = generation.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ArtifactError(f"cases.generation.{field} must be a non-negative integer")
    if not isinstance(generation.get("truncated"), bool):
        raise ArtifactError("cases.generation.truncated must be boolean")
    raw_cases = _list(cases.get("cases"), "cases.cases")
    ids: list[str] = []
    for index, raw_case in enumerate(raw_cases):
        case = as_case_object(raw_case, f"cases.cases[{index}]")
        case_id = case.get("id")
        if not isinstance(case_id, str) or not _CASE_ID_RE.fullmatch(case_id):
            raise ArtifactError(f"cases.cases[{index}].id is invalid")
        ids.append(case_id)
    ids.sort()
    for index in range(1, len(ids)):
        if ids[index] == ids[index - 1]:
            raise ArtifactError(f"cases.cases contains duplicate id {ids[index]!r}")
    del ids
    validated_cases = cast(list[dict[str, Any]], raw_cases)
    if generation["emitted_count"] != len(raw_cases):
        raise ArtifactError("cases.generation.emitted_count does not match cases.cases")
    emitted_edge_count, emitted_object_count = _materialized_graph_counts(
        validated_cases, parsed_json=parsed_json
    )
    if generation["emitted_edge_count"] != emitted_edge_count:
        raise ArtifactError("cases.generation.emitted_edge_count does not match cases.cases")
    if generation["emitted_object_count"] != emitted_object_count:
        raise ArtifactError("cases.generation.emitted_object_count does not match cases.cases")
    for noun in ("count", "edge_count", "object_count"):
        if generation[f"candidate_{noun}"] < generation[f"emitted_{noun}"]:
            raise ArtifactError(f"cases.generation.candidate_{noun} is smaller than emitted_{noun}")
    if generation["truncated"] != (generation["candidate_count"] != generation["emitted_count"]):
        raise ArtifactError("cases.generation.truncated does not match the recorded counts")
    if not generation["truncated"] and (
        generation["candidate_edge_count"] != generation["emitted_edge_count"]
        or generation["candidate_object_count"] != generation["emitted_object_count"]
    ):
        raise ArtifactError("untruncated cases must have equal candidate and emitted graph counts")
    if contract is not None:
        if campaign != contract["campaign"]:
            raise ArtifactError("cases.campaign does not match contract.campaign")
        if digest != _canonical_sha256(contract):
            raise ArtifactError("cases.contract_sha256 does not match contract")
        complexity = _estimate_complexity(contract)
        if complexity.case_count > MAX_GENERATED_CANDIDATES:
            raise ArtifactError(
                f"contract expands beyond {MAX_GENERATED_CANDIDATES} candidate cases; narrow the contract"
            )
        maximum = int(contract["max_cases"])
        if len(validated_cases) != min(complexity.case_count, maximum):
            raise ArtifactError("cases do not match deterministic generation from contract")
        if generation != _generation_summary(complexity, maximum, validated_cases):
            raise ArtifactError("cases do not match deterministic generation from contract")
        _compare_generated_cases(contract, validated_cases)
    return cases


def _relative_evidence_path(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise ArtifactError(f"{where} must be a non-empty relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) in {"", "."}:
        raise ArtifactError(f"{where} must stay under the run work directory")
    return value


def _evidence(
    document: Any,
    contract: dict[str, Any],
    cases: dict[str, Any],
    *,
    cases_sha256: str,
    work_dir: Path | None = None,
    parsed_json: bool = False,
) -> dict[str, Any]:
    as_object = _parsed_object if parsed_json else _object
    evidence = as_object(document, "evidence")
    _reject_unknown(
        evidence,
        {
            "schema_version",
            "artifact",
            "campaign",
            "contract_sha256",
            "cases_sha256",
            "target",
            "executions",
        },
        "evidence",
    )
    schema_version = evidence.get("schema_version")
    if isinstance(schema_version, bool) or schema_version != SCHEMA_VERSION:
        raise ArtifactError(f"evidence.schema_version must be the integer {SCHEMA_VERSION}")
    if evidence.get("artifact") != EVIDENCE_ARTIFACT:
        raise ArtifactError(f"evidence.artifact must be {EVIDENCE_ARTIFACT!r}")
    if evidence.get("campaign") != contract["campaign"] or evidence.get("campaign") != cases["campaign"]:
        raise ArtifactError("evidence.campaign does not match contract and cases")
    if evidence.get("contract_sha256") != cases["contract_sha256"]:
        raise ArtifactError("evidence.contract_sha256 does not match contract")
    if evidence.get("cases_sha256") != cases_sha256:
        raise ArtifactError("evidence.cases_sha256 does not match cases file")

    target = as_object(evidence.get("target"), "evidence.target")
    _reject_unknown(target, {"name", "identity", "smp"}, "evidence.target")
    for field in ("name", "identity"):
        if not isinstance(target.get(field), str) or not target[field]:
            raise ArtifactError(f"evidence.target.{field} must be a non-empty string")
    _positive_int(target.get("smp"), "evidence.target.smp", maximum=1 << 20)

    known_ids = {case["id"] for case in cases["cases"]}
    executions = _list(evidence.get("executions"), "evidence.executions")
    last_oracle: str | None = None
    for index, raw_execution in enumerate(executions):
        where = f"evidence.executions[{index}]"
        execution = as_object(raw_execution, where)
        if execution.keys() != _EXECUTION_FIELDS:
            _reject_unknown(execution, _EXECUTION_FIELDS, where)
        case_id = execution.get("case_id")
        if case_id not in known_ids:
            raise ArtifactError(f"{where}.case_id is an unknown case_id: {case_id!r}")
        status = execution.get("status")
        if status not in _EVIDENCE_STATUSES:
            raise ArtifactError(f"{where}.status must be one of: {', '.join(sorted(_EVIDENCE_STATUSES))}")
        oracle = execution.get("oracle")
        if not isinstance(oracle, str) or (oracle != last_oracle and not _NAME_RE.fullmatch(oracle)):
            raise ArtifactError(f"{where}.oracle must be a safe non-empty name")
        last_oracle = oracle

        observations = as_object(execution.get("observations"), f"{where}.observations")
        if observations.keys() != _OBSERVATION_FIELDS:
            _reject_unknown(observations, _OBSERVATION_FIELDS, f"{where}.observations")
        result = as_object(observations.get("result"), f"{where}.observations.result")
        if result.keys() != _RESULT_FIELDS:
            _reject_unknown(result, _RESULT_FIELDS, f"{where}.observations.result")
        returned = result.get("return")
        if returned is not None and (isinstance(returned, bool) or not isinstance(returned, int)):
            raise ArtifactError(f"{where}.observations.result.return must be null or an integer")
        errno = result.get("errno")
        if errno is not None and (not isinstance(errno, str) or not _NAME_RE.fullmatch(errno)):
            raise ArtifactError(f"{where}.observations.result.errno must be null or a safe name")
        progress = as_object(observations.get("progress"), f"{where}.observations.progress")
        if progress.keys() != _PROGRESS_FIELDS:
            _reject_unknown(progress, _PROGRESS_FIELDS, f"{where}.observations.progress")
            missing_progress = sorted(_PROGRESS_FIELDS - set(progress))
            raise ArtifactError(f"{where}.observations.progress is missing: {', '.join(missing_progress)}")
        for field in _PROGRESS_FIELD_ORDER:
            value = progress[field]
            if value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
                raise ArtifactError(
                    f"{where}.observations.progress.{field} must be null or a non-negative integer"
                )
        as_object(observations.get("state_before"), f"{where}.observations.state_before")
        as_object(observations.get("state_after"), f"{where}.observations.state_after")

        paths = _list(execution.get("evidence"), f"{where}.evidence")
        if status in {"pass", "candidate"} and not paths:
            raise ArtifactError(f"{where}.evidence must not be empty for status {status!r}")
        for path_index, path in enumerate(paths):
            relative = _relative_evidence_path(path, f"{where}.evidence[{path_index}]")
            if work_dir is not None:
                raw_evidence_path = work_dir / relative
                try:
                    if raw_evidence_path.is_symlink():
                        raise ArtifactError(f"{where}.evidence[{path_index}] is a symlink")
                    evidence_path = raw_evidence_path.resolve()
                    evidence_path.relative_to(work_dir)
                    usable = evidence_path.is_file() and evidence_path.stat().st_size > 0
                except ValueError as exc:
                    raise ArtifactError(f"{where}.evidence[{path_index}] escapes the work directory") from exc
                except OSError as exc:
                    raise ArtifactError(f"cannot inspect {where}.evidence[{path_index}]: {exc}") from exc
                if not usable:
                    raise ArtifactError(f"{where}.evidence[{path_index}] is missing or empty")
    return evidence


def _read_bytes(path: Path) -> bytes:
    if path.is_symlink():
        raise ArtifactError(f"refusing to read symlink: {path}")
    try:
        return path.read_bytes()
    except FileNotFoundError as exc:
        raise ArtifactError(f"file does not exist: {path}") from exc
    except OSError as exc:
        raise ArtifactError(f"cannot read {path}: {exc}") from exc


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-standard numeric constant {value}")


def _json_from_bytes(payload: bytes, path: Path) -> Any:
    try:
        return json.loads(payload.decode("utf-8"), parse_constant=_reject_json_constant)
    except (UnicodeDecodeError, ValueError) as exc:
        raise ArtifactError(f"invalid JSON in {path}: {exc}") from exc


def validate_evidence_files(
    contract_path: Path,
    cases_path: Path,
    evidence_path: Path,
    *,
    work_dir: Path | None = None,
) -> EvidenceSummary:
    """Validate one bound sidecar bundle and summarize its execution statuses."""
    if work_dir is not None:
        if work_dir.is_symlink() or not work_dir.is_dir():
            raise ArtifactError(f"work directory is missing or a symlink: {work_dir}")
        work_dir = work_dir.resolve()
        for label, artifact_path in (
            ("contract", contract_path),
            ("cases", cases_path),
            ("evidence", evidence_path),
        ):
            if artifact_path.is_symlink():
                raise ArtifactError(f"{label} artifact is a symlink: {artifact_path}")
            try:
                artifact_path.resolve().relative_to(work_dir)
            except ValueError as exc:
                raise ArtifactError(f"{label} artifact escapes the work directory: {artifact_path}") from exc
            except OSError as exc:
                raise ArtifactError(f"cannot inspect {label} artifact {artifact_path}: {exc}") from exc
    contract = _contract(_read_json(contract_path), parsed_json=True)
    cases_bytes = _read_bytes(cases_path)
    cases = _cases(_json_from_bytes(cases_bytes, cases_path), contract, parsed_json=True)
    if _object(cases["generation"], "cases.generation")["truncated"]:
        raise ArtifactError("truncated cases cannot support an evidence sidecar")
    evidence = _evidence(
        _read_json(evidence_path),
        contract,
        cases,
        cases_sha256=hashlib.sha256(cases_bytes).hexdigest(),
        work_dir=work_dir,
        parsed_json=True,
    )
    statuses = Counter(item["status"] for item in evidence["executions"])
    return EvidenceSummary(
        execution_count=sum(statuses.values()),
        status_counts=tuple(sorted(statuses.items())),
    )


def _read_json(path: Path) -> Any:
    if path.is_symlink():
        raise ArtifactError(f"refusing to read symlink: {path}")
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream, parse_constant=_reject_json_constant)
    except FileNotFoundError as exc:
        raise ArtifactError(f"file does not exist: {path}") from exc
    except (UnicodeDecodeError, ValueError) as exc:
        raise ArtifactError(f"invalid JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise ArtifactError(f"cannot read {path}: {exc}") from exc


def _write_json(path: Path, document: Any) -> None:
    if path.is_symlink():
        raise ArtifactError(f"refusing to replace symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    descriptor, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(raw_tmp)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(payload)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="specula syscall-inputs",
        description="Generate structured syscall-input cases and validate non-TLA evidence.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate", help="Generate cases from an input contract")
    generate.add_argument("--contract", type=Path, required=True)
    generate.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("validate", help="Validate a contract, case set, or evidence sidecar")
    validate.add_argument("artifact", type=Path)
    validate.add_argument("--contract", type=Path)
    validate.add_argument("--cases", type=Path)
    validate.add_argument("--work-dir", type=Path)
    return parser


def _run(args: argparse.Namespace) -> int:
    if args.command == "generate":
        document = generate_cases(_read_json(args.contract), parsed_json=True)
        _write_json(args.output, document)
        generation = _object(document["generation"], "generation")
        suffix = " (truncated)" if generation["truncated"] else ""
        print(f"generated {generation['emitted_count']}/{generation['candidate_count']} cases{suffix}: {args.output}")
        return TRUNCATED_RC if generation["truncated"] else 0

    document = _parsed_object(_read_json(args.artifact), "artifact")
    artifact = document.get("artifact")
    if artifact == CONTRACT_ARTIFACT:
        _contract(document, parsed_json=True)
        print(f"valid {CONTRACT_ARTIFACT}: {len(document['syscalls'])} syscalls")
        return 0
    if args.contract is None:
        raise ArtifactError(f"--contract is required to validate {artifact!r}")
    contract = _contract(_read_json(args.contract), parsed_json=True)
    if artifact == CASES_ARTIFACT:
        cases = _cases(document, contract, parsed_json=True)
        truncated = bool(_parsed_object(cases["generation"], "cases.generation")["truncated"])
        suffix = " (truncated)" if truncated else ""
        print(f"valid {CASES_ARTIFACT}: {len(cases['cases'])} cases{suffix}")
        return TRUNCATED_RC if truncated else 0
    if artifact == EVIDENCE_ARTIFACT:
        if args.cases is None:
            raise ArtifactError("--cases is required to validate syscall-input evidence")
        if args.work_dir is None:
            raise ArtifactError("--work-dir is required to validate syscall-input evidence paths")
        summary = validate_evidence_files(args.contract, args.cases, args.artifact, work_dir=args.work_dir)
        noun = "execution" if summary.execution_count == 1 else "executions"
        print(f"valid {EVIDENCE_ARTIFACT}: {summary.execution_count} {noun}")
        return 0
    raise ArtifactError(f"unknown artifact type: {artifact!r}")


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
        return _run(args)
    except ArtifactError as exc:
        print(f"specula syscall-inputs: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"specula syscall-inputs: {exc}", file=sys.stderr)
        return 2
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 1
