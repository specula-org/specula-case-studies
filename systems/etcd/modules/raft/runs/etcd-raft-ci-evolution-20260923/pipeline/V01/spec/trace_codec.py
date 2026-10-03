"""Typed NDJSON encoding/preflight for Trace.tla; does not generate executions."""
from dataclasses import dataclass
import json
import sys

@dataclass
class FiniteSet:
    values: list

@dataclass
class Function:
    pairs: list  # [(key, value), ...]; supports record-valued message bag keys.

def encode(value):
    if isinstance(value, Function):
        return {"tag": "map", "value": [{"key": encode(k), "value": encode(v)} for k, v in value.pairs]}
    if isinstance(value, FiniteSet):
        return {"tag": "set", "value": [encode(v) for v in value.values]}
    if isinstance(value, (set, frozenset)):
        return {"tag": "set", "value": [encode(v) for v in sorted(value, key=repr)]}
    if isinstance(value, (list, tuple)):
        return {"tag": "seq", "value": [encode(v) for v in value]}
    if isinstance(value, dict):
        if all(isinstance(k, str) for k in value):
            return {"tag": "record", "value": {k: encode(v) for k, v in value.items()}}
        return encode(Function(list(value.items())))
    if type(value) in (str, int, bool):
        return {"tag": "atom", "value": value}
    raise TypeError(f"Unsupported trace value type: {type(value).__name__}")

def no_duplicate_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON field {key!r}")
        result[key] = value
    return result

def validate(value):
    if not isinstance(value, dict) or set(value) != {"tag", "value"}:
        raise ValueError("every typed value must contain exactly tag/value")
    tag, body = value["tag"], value["value"]
    if tag == "atom":
        if type(body) not in (str, int, bool):
            raise ValueError("atom must be a string, integer or Boolean")
    elif tag in ("set", "seq"):
        if not isinstance(body, list):
            raise ValueError(f"{tag} requires an array")
        for element in body:
            validate(element)
    elif tag == "record":
        if not isinstance(body, dict):
            raise ValueError("record requires an object")
        for element in body.values():
            validate(element)
    elif tag == "map":
        if not isinstance(body, list):
            raise ValueError("map requires an array of pairs")
        seen = set()
        for pair in body:
            if not isinstance(pair, dict) or set(pair) != {"key", "value"}:
                raise ValueError("map pair requires exactly key/value")
            validate(pair["key"])
            validate(pair["value"])
            key = json.dumps(pair["key"], sort_keys=True, separators=(",", ":"))
            if key in seen:
                raise ValueError("duplicate encoded function key")
            seen.add(key)
    else:
        raise ValueError(f"unknown typed value tag: {tag!r}")

EVENTS = set("Tick Campaign TickQuiesced TransferLeader Invoke InvokeV2 Propose ReadIndex ReturnAPI Cancel Receive Lose Duplicate ReportSnapshot ReportUnreachable Ready StartPersist CompletePersist StorageApplySnapshot StorageAppend StorageSetHardState Publish QueueApplication Advance ApplySnapshot ApplyEntry FinishApplication SaveApplication CompleteWrite CompleteRead CreateSnapshot PersistLocalSnapshot Compact SnapshotAvailability Crash Stop Restart".split())

PARAMS = {'Tick': {'timeout', 'node'}, 'Campaign': {'timeout', 'node'}, 'TickQuiesced': {'node'}, 'TransferLeader': {'timeout', 'node', 'target'}, 'Invoke': {'context', 'encoded', 'parent', 'target', 'weight', 'kind', 'id', 'node'}, 'InvokeV2': {'changes', 'encoded', 'parent', 'transition', 'weight', 'id', 'node'}, 'Propose': {'timeout', 'node', 'id'}, 'ReadIndex': {'timeout', 'node', 'id'}, 'ReturnAPI': {'id'}, 'Cancel': {'id'}, 'Receive': {'timeout', 'message'}, 'Lose': {'message'}, 'Duplicate': {'message'}, 'ReportSnapshot': {'timeout', 'node', 'failed', 'message'}, 'ReportUnreachable': {'timeout', 'node', 'message'}, 'Ready': {'node'}, 'StartPersist': {'node', 'part'}, 'CompletePersist': {'node', 'part'}, 'StorageApplySnapshot': {'node'}, 'StorageAppend': {'node'}, 'StorageSetHardState': {'node'}, 'Publish': {'node'}, 'QueueApplication': {'node'}, 'Advance': {'node'}, 'ApplySnapshot': {'node'}, 'ApplyEntry': {'timeout', 'node'}, 'FinishApplication': {'node'}, 'SaveApplication': {'node'}, 'CompleteWrite': {'node', 'id'}, 'CompleteRead': {'node', 'position', 'id'}, 'CreateSnapshot': {'node', 'index'}, 'PersistLocalSnapshot': {'node'}, 'Compact': {'node', 'index'}, 'SnapshotAvailability': {'node', 'available'}, 'Crash': {'node'}, 'Stop': {'node'}, 'Restart': {'timeout', 'node'}}

def preflight(path):
    count = 0
    with open(path, encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            event = json.loads(line, object_pairs_hook=no_duplicate_fields)
            if event.get("tag") != "trace":
                continue
            count += 1
            try:
                required = {"tag", "ts", "event", "post", "settings" if count == 1 else "params"}
                if set(event) != required:
                    raise ValueError(f"event fields must be {sorted(required)}")
                if count == 1 and event["event"] != "Init":
                    raise ValueError("first trace event must be Init")
                if count > 1 and event["event"] not in EVENTS:
                    raise ValueError("unknown event")
                validate(event["settings" if count == 1 else "params"])
                if count > 1 and (event["params"]["tag"] != "record" or set(event["params"]["value"]) != PARAMS[event["event"]]):
                    raise ValueError("action params do not match its declared inputs")
                validate(event["post"])
                if event["post"]["tag"] != "record" or set(event["post"]["value"]) != {"raft", "disk", "ready", "application", "requests", "wire"}:
                    raise ValueError("post must contain all six observed state components")
            except ValueError as error:
                raise ValueError(f"{path}:{line_number}: {error}") from error
    if not count:
        raise ValueError("trace contains no trace events")
    return count

if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: python3 trace_codec.py TRACE.ndjson [TRACE.ndjson ...]")
    for trace_path in sys.argv[1:]:
        print(f"{trace_path}: {preflight(trace_path)} structurally valid events; correspondence is not checked here")
