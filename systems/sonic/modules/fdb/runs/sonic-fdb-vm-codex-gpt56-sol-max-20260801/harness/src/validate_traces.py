#!/usr/bin/env python3
"""Fast structural checks before Trace.tla replay."""

import argparse
import json
from pathlib import Path


FDB_FIELDS = {
    "generation", "kernel", "cache", "stateDb", "asic", "observer",
    "txn", "eventQueueSize", "crmCount", "portCounts", "vlanCount",
    "pendingEpoch", "lastFlushCleanup", "lastDeletion", "fdbFailure",
    "fdbRetry", "fdbCompensated",
}
FLUSH_FIELDS = {
    "flushEpoch", "scope", "port", "kind", "path", "status",
    "snapshot", "ackCreated", "ackQueueSize", "pendingEpoch", "asic",
    "lastFlushCleanup", "lastDeletion",
}
FDB_EVENTS = {
    "SaiLearnEvent", "SaiMoveEvent", "SaiAgeEvent", "SaiDuplicateEvent",
    "FdbOrchUpdateStart", "FdbOrchIgnoreAgedEvent",
    "FdbOrchUpdateCounters", "FdbOrchStoreFdbEntryState",
    "FdbOrchNotifyObservers", "FdbOrchNotificationRepairFailure",
}
FLUSH_EVENTS = {
    "FdbOrchFlushFDBEntriesRequest", "FdbOrchFlushFdbByVlanRequest",
    "SaiFlushSuccess", "SaiFlushFailure", "SaiEnqueueFlushAck",
    "SaiDuplicateFlushAck", "FdbOrchHandleSyncdFlushNotif",
    "FdbOrchIgnoreSyncdFlushNotif",
}
ENTRY_FIELDS = {"present", "gen", "dest", "bpGen", "kind"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def check_entry(value: object, where: str) -> None:
    require(isinstance(value, dict), f"{where}: entry is not an object")
    require(ENTRY_FIELDS <= value.keys(), f"{where}: incomplete entry")


def check_file(path: Path) -> int:
    require(path.is_file(), f"{path}: missing trace")
    previous_seq = 0
    count = 0
    with path.open(encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, 1):
            require(raw.endswith("\n"), f"{path}:{line_number}: partial line")
            record = json.loads(raw)
            where = f"{path}:{line_number}"
            require(record.get("tag") == "trace", f"{where}: wrong tag")
            require(record.get("process") == "orchagent", f"{where}: wrong process")
            sequence = record.get("seq")
            require(isinstance(sequence, int) and sequence == previous_seq + 1,
                    f"{where}: non-contiguous seq")
            previous_seq = sequence
            require(isinstance(record.get("timestamp_ns"), int),
                    f"{where}: missing timestamp")
            event = record.get("event")
            require(isinstance(event, dict), f"{where}: missing event")
            name = event.get("name")
            require(isinstance(name, str), f"{where}: missing event name")
            state = event.get("state")
            require(isinstance(state, dict), f"{where}: missing state")
            if name in FDB_EVENTS:
                fdb = state.get("fdb")
                require(isinstance(fdb, dict) and FDB_FIELDS <= fdb.keys(),
                        f"{where}: incomplete fdb bundle")
                for field in ("kernel", "cache", "stateDb", "asic", "observer"):
                    check_entry(fdb[field], f"{where}.fdb.{field}")
            if name in FLUSH_EVENTS:
                flush = state.get("flush")
                require(isinstance(flush, dict) and FLUSH_FIELDS <= flush.keys(),
                        f"{where}: incomplete flush bundle")
                check_entry(flush["snapshot"], f"{where}.flush.snapshot")
                check_entry(flush["asic"], f"{where}.flush.asic")
            count += 1
    require(count > 0, f"{path}: empty trace")
    return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    total = 0
    for path in args.paths:
        count = check_file(path)
        print(f"validated {path.name}: {count} events")
        total += count
    print(f"validated {len(args.paths)} traces: {total} events")


if __name__ == "__main__":
    main()
