#!/usr/bin/env python3
"""Synchronous Unix-socket trace sequencer for SONiC warm-reboot tests.

Production probes send only the event name, concrete identifiers, and values
read back at the code boundary.  This collector owns the instrumentation-only
shadow state described by instrumentation-spec.md and serializes one NDJSON
stream in receive order.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import threading
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


OWNERS = ("owner_1", "owner_2")
ASICS = ("asic_0", "asic_1")


def _json_line(value: Dict[str, Any]) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()


def _parse_scalar(value: str) -> Any:
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    return value


def parse_fields(values: Iterable[str]) -> Dict[str, Any]:
    fields: Dict[str, Any] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"field must use key=value syntax: {value!r}")
        key, raw = value.split("=", 1)
        if not key:
            raise ValueError(f"empty field name: {value!r}")
        fields[key] = _parse_scalar(raw)
    return fields


class ShadowState:
    """Instrumentation-only state for the currently selected reboot attempt."""

    def __init__(self) -> None:
        self.owner_ids: Dict[str, str] = {}
        self.epoch = 0
        self.owner = "no-owner"
        self.cleanup_owner = "no-owner"
        self.flags: Dict[str, Any] = {"warm": False, "fast": False, "epoch": -1}
        self.request_kind = {owner: "none" for owner in OWNERS}
        self.phase = {owner: "idle" for owner in OWNERS}
        self.checked = {owner: False for owner in OWNERS}
        self.admitted = {owner: False for owner in OWNERS}
        self.attempt_epoch = {owner: -1 for owner in OWNERS}
        self.attempt_outcome = {owner: "none" for owner in OWNERS}
        self.cancelled = {owner: False for owner in OWNERS}
        self.irreversible_started = {owner: False for owner in OWNERS}
        self.ready_consumed = {asic: False for asic in ASICS}
        self.freeze_result = {asic: "pending" for asic in ASICS}
        self.snapshot_present = {asic: False for asic in ASICS}
        self.snapshot_valid = {asic: False for asic in ASICS}
        self.snapshot_stage = {asic: "idle" for asic in ASICS}
        self.writer_stopped = {asic: False for asic in ASICS}
        self.shutdown_status = {asic: "pending" for asic in ASICS}

    def abstract_owner(self, token: str, register: bool = False) -> str:
        if token in self.owner_ids:
            return self.owner_ids[token]
        if not register:
            raise ValueError(f"event arrived before FastReboot_Request for owner token {token!r}")
        if len(self.owner_ids) >= len(OWNERS):
            raise ValueError("trace contains more concrete callers than Trace.cfg Owners")
        owner = OWNERS[len(self.owner_ids)]
        self.owner_ids[token] = owner
        return owner

    @staticmethod
    def _require(condition: bool, message: str) -> None:
        if not condition:
            raise ValueError(message)

    def transition(self, raw: Dict[str, Any]) -> Dict[str, Any]:
        name = raw["name"]
        fields = raw.get("fields", {})
        token = raw["owner_token"]
        owner = self.abstract_owner(token, register=name == "FastReboot_Request")
        event: Dict[str, Any] = {"name": name}

        if name == "FastReboot_Request":
            kind = fields.get("kind")
            self._require(kind in {"warm_request", "fast_request"}, f"invalid request kind {kind!r}")
            self._require(self.phase[owner] == "idle", f"{owner} is not idle")
            self.request_kind[owner] = kind
            self.phase[owner] = "requested"
            self.attempt_outcome[owner] = "pending"
            event.update(
                owner=owner,
                kind=kind,
                post={
                    "request_kind": kind,
                    "phase": "requested",
                    "attempt_outcome": "pending",
                },
            )

        elif name == "CheckWarmRestartInProgress_Admit":
            self._require(self.phase[owner] == "requested", f"{owner} was not requested")
            self._require(not self.flags["warm"] and not self.flags["fast"], "admit observed active flags")
            self.checked[owner] = True
            self.phase[owner] = "checked"
            event.update(owner=owner, post={"checked": True, "phase": "checked"})

        elif name == "CheckWarmRestartInProgress_Reject":
            self._require(self.phase[owner] == "requested", f"{owner} was not requested")
            self._require(bool(self.flags["warm"] or self.flags["fast"]), "reject observed clear flags")
            self.phase[owner] = "completed"
            self.attempt_outcome[owner] = "rejected"
            event.update(
                owner=owner,
                post={"phase": "completed", "attempt_outcome": "rejected"},
            )

        elif name == "EnableWarmRestart":
            self._require(self.phase[owner] == "checked" and self.checked[owner], f"{owner} was not admitted")
            warm = bool(fields.get("warm"))
            fast = bool(fields.get("fast"))
            self._require(warm, "warm flag read-back was not enabled")
            self.epoch += 1
            self.owner = owner
            self.flags = {"warm": warm, "fast": fast, "epoch": self.epoch}
            self.phase[owner] = "flags-published"
            self.checked[owner] = False
            self.admitted[owner] = True
            self.attempt_epoch[owner] = self.epoch
            self.attempt_outcome[owner] = "pending"
            self.cancelled[owner] = False
            event.update(
                owner=owner,
                post={
                    "epoch": self.epoch,
                    "owner": owner,
                    "flags": dict(self.flags),
                    "phase": self.phase[owner],
                    "checked": self.checked[owner],
                    "admitted": self.admitted[owner],
                    "attempt_epoch": self.attempt_epoch[owner],
                    "attempt_outcome": self.attempt_outcome[owner],
                    "cancelled": self.cancelled[owner],
                },
            )

        elif name == "ClearBoot":
            self._require(self.admitted[owner], f"{owner} was never admitted")
            self._require(self.attempt_outcome[owner] == "pending", f"{owner} is already terminal")
            self._require(
                self.phase[owner] in {"flags-published", "freeze-acked", "cancelled"},
                f"clear_boot at invalid phase {self.phase[owner]!r}",
            )
            self.cleanup_owner = owner
            self.flags = {
                "warm": bool(fields.get("warm")),
                "fast": bool(fields.get("fast")),
                "epoch": -1,
            }
            self.cancelled[owner] = True
            self.phase[owner] = "cancelled"
            for asic in ASICS:
                observed = fields.get(f"snapshot_present_{asic}")
                if observed is not None:
                    self.snapshot_present[asic] = bool(observed)
                if self.snapshot_stage[asic] != "idle":
                    self.snapshot_stage[asic] = "renamed"
                self.snapshot_valid[asic] = False
            event.update(
                owner=owner,
                post={
                    "owner": self.owner,
                    "cleanup_owner": self.cleanup_owner,
                    "flags": dict(self.flags),
                    "phase": self.phase[owner],
                    "cancelled": self.cancelled[owner],
                    "snapshot_present": dict(self.snapshot_present),
                    "snapshot_valid": dict(self.snapshot_valid),
                    "snapshot_stage": dict(self.snapshot_stage),
                },
            )

        elif name == "FastReboot_ContinueAfterSignal":
            self._require(self.phase[owner] == "cancelled" and self.cancelled[owner], "signal cleanup did not run")
            self.phase[owner] = "flags-published"
            event.update(
                owner=owner,
                post={"phase": self.phase[owner], "cancelled": self.cancelled[owner]},
            )

        elif name == "PauseOrchagent_IgnoreFailure":
            asic = fields.get("asic")
            self._require(asic in ASICS, f"invalid ASIC {asic!r}")
            self._require(self.phase[self.owner] == "flags-published", "pause failure outside flag-published phase")
            self._require(self.freeze_result[asic] == "pending", f"duplicate pause result for {asic}")
            self.ready_consumed[asic] = True
            self.freeze_result[asic] = "ignored-failure"
            event.update(
                asic=asic,
                post={"ready_consumed": True, "freeze_result": "ignored-failure"},
            )

        elif name == "FastReboot_PauseOrchagentComplete":
            self._require(self.owner == owner, f"{owner} is not current owner")
            self._require(self.phase[owner] == "flags-published", "pause aggregation at wrong phase")
            self._require(
                all(value in {"ready", "ignored-failure"} for value in self.freeze_result.values()),
                "pause aggregation before all ASIC results",
            )
            self.phase[owner] = "freeze-acked"
            event.update(owner=owner, post={"phase": "freeze-acked"})

        elif name == "FastReboot_BeginIrreversibleWork":
            self._require(self.phase[owner] == "freeze-acked", "irreversible work before pause completion")
            self.irreversible_started[owner] = True
            self.phase[owner] = "irreversible"
            event.update(
                owner=owner,
                post={"phase": "irreversible", "irreversible_started": True},
            )

        elif name in {"StopSystemdService_Success", "StopSystemdService_MaskedFailure"}:
            asic = fields.get("asic")
            self._require(asic in ASICS, f"invalid ASIC {asic!r}")
            self._require(any(self.irreversible_started.values()), "service stop before irreversible boundary")
            self._require(not self.writer_stopped[asic], f"duplicate writer stop for {asic}")
            observed = bool(fields.get("writer_stopped"))
            if name == "StopSystemdService_Success":
                self._require(observed, f"successful stop left writer active on {asic}")
                self.writer_stopped[asic] = True
                self.shutdown_status[asic] = "succeeded"
            else:
                self.writer_stopped[asic] = observed
                self.shutdown_status[asic] = "lost"
            event.update(
                asic=asic,
                post={
                    "writer_stopped": self.writer_stopped[asic],
                    "shutdown_status": self.shutdown_status[asic],
                },
            )

        else:
            raise ValueError(f"collector has no schema transition for {name!r}")

        return event


class TraceCollector:
    """One-thread sequencer with synchronous acknowledgements to every probe."""

    def __init__(self, socket_path: Path, output_path: Path, scenario: str) -> None:
        self.socket_path = socket_path
        self.output_path = output_path
        self.scenario = scenario
        self.state = ShadowState()
        self.seq = 0
        self.errors: List[str] = []
        self._server: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._file = None

    def start(self) -> None:
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        self._file = self.output_path.open("w", encoding="utf-8", buffering=1)
        self._thread = threading.Thread(target=self._serve, name=f"trace-{self.scenario}", daemon=True)
        self._thread.start()
        if not self._ready.wait(timeout=5):
            raise RuntimeError("trace collector did not create its Unix socket")

    def _serve(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server = server
        server.bind(str(self.socket_path))
        server.listen(32)
        server.settimeout(0.2)
        self._ready.set()
        while not self._stop.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with conn:
                payload = b""
                while b"\n" not in payload:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    payload += chunk
                try:
                    raw = json.loads(payload.split(b"\n", 1)[0])
                    event = self.state.transition(raw)
                    self.seq += 1
                    envelope = {
                        "tag": "warmreboot",
                        "seq": self.seq,
                        "ts_ns": time.time_ns(),
                        "process": raw["process"],
                        "pid": raw["pid"],
                        "event": event,
                    }
                    assert self._file is not None
                    self._file.write(_json_line(envelope).decode())
                    self._file.flush()
                    os.fsync(self._file.fileno())
                    response = {"ok": True, "seq": self.seq}
                except Exception as exc:  # report a failed probe to both caller and test
                    message = f"{type(exc).__name__}: {exc}"
                    self.errors.append(message)
                    response = {"ok": False, "error": message}
                conn.sendall(_json_line(response))

    def stop(self) -> None:
        self._stop.set()
        if self._server is not None:
            self._server.close()
        if self._thread is not None:
            self._thread.join(timeout=5)
            if self._thread.is_alive():
                raise RuntimeError("trace collector thread did not stop")
        if self._file is not None:
            self._file.close()
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        sidecar = self.output_path.with_suffix(".ids.json")
        sidecar.write_text(
            json.dumps(
                {
                    "scenario": self.scenario,
                    "owners": self.state.owner_ids,
                    "asics": {"0": "asic_0", "1": "asic_1"},
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )


def emit(args: argparse.Namespace) -> int:
    raw = {
        "name": args.event,
        "owner_token": args.owner_token,
        "process": args.process,
        "pid": args.pid,
        "client_ts_ns": time.time_ns(),
        "fields": parse_fields(args.fields),
    }
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    client.connect(args.socket)
    client.sendall(_json_line(raw))
    response = b""
    while b"\n" not in response:
        chunk = client.recv(65536)
        if not chunk:
            break
        response += chunk
    client.close()
    acknowledgement = json.loads(response.split(b"\n", 1)[0])
    if not acknowledgement.get("ok"):
        raise RuntimeError(acknowledgement.get("error", "collector rejected probe"))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    emit_parser = subparsers.add_parser("emit", help="send one synchronous raw probe")
    emit_parser.add_argument("--socket", required=True)
    emit_parser.add_argument("--event", required=True)
    emit_parser.add_argument("--owner-token", required=True)
    emit_parser.add_argument("--process", required=True)
    emit_parser.add_argument("--pid", required=True, type=int)
    emit_parser.add_argument("fields", nargs="*")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "emit":
        return emit(args)
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
