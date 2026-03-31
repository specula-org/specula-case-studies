"""
Client-side trace emission for MongoDB transaction router trace harness (v3).

Emits NDJSON lines for router-level events matching the v3 spec that models
decision logic, resource contention, and error classification.

Server-side events (coordinator) are extracted from MongoDB LOGV2 logs
by parse_logs.py.
"""

import json
import time
import threading


# Static shard name mapping: MongoDB shard name -> TLA+ ID
SHARD_MAP = {
    "shard1RS": "s1",
    "shard2RS": "s2",
}


def map_shard(mongo_shard_name):
    """Map MongoDB shard name to TLA+ ID."""
    for k, v in SHARD_MAP.items():
        if k in mongo_shard_name:
            return v
    return mongo_shard_name


def infer_commit_type(participants, disallow_sws=False):
    """Infer commit type from participant topology.

    Mirrors SelectCommitType in base.tla / transaction_router.cpp:1649-1771.

    Args:
        participants: dict {tla_shard_id: "PK_ro"|"PK_wr"}
        disallow_sws: if True, SWS is disallowed (sticky flag from prior txn)
    """
    n_participants = len(participants)
    write_shards = [s for s, pk in participants.items() if pk == "PK_wr"]
    n_write = len(write_shards)

    if n_participants == 0:
        return "CT_noShards"
    elif n_participants == 1:
        return "CT_single"
    elif n_write == 1 and not disallow_sws:
        return "CT_sws"
    elif n_write == 0:
        return "CT_readOnly"
    else:
        return "CT_2pc"


class TraceEmitter:
    """Thread-safe NDJSON trace emitter for client-side (router) events."""

    def __init__(self, trace_file, router_id="r1"):
        self._file = open(trace_file, "w")
        self._lock = threading.Lock()
        self._router_id = router_id
        self._txn_counter = 0
        self._txn_map = {}  # (lsid, txnNumber) -> "t1", "t2", ...
        self._session_meta = {}  # txn_tla_id -> {lsid, txnNumber}

    def close(self):
        with self._lock:
            self._file.flush()
            self._file.close()

    def _ts_ns(self):
        """Real timestamp in nanoseconds."""
        return int(time.time() * 1e9)

    def _emit(self, obj):
        with self._lock:
            self._file.write(json.dumps(obj, separators=(",", ":")) + "\n")
            self._file.flush()

    def register_txn(self, session):
        """Register a pymongo session's transaction, return TLA+ txn ID."""
        lsid = session.session_id["id"].as_uuid().hex
        txn_number = session._server_session.transaction_id
        key = (lsid, txn_number)
        if key not in self._txn_map:
            self._txn_counter += 1
            tla_id = f"t{self._txn_counter}"
            self._txn_map[key] = tla_id
            self._session_meta[tla_id] = {"lsid": lsid, "txnNumber": txn_number}
        return self._txn_map[key]

    def get_session_meta(self):
        """Return session metadata for log correlation."""
        return dict(self._session_meta)

    # === Router Events (v3 spec) ===

    def router_start_txn(self, txn_id, participants):
        """RouterStartTxn: after transaction started with known participants.

        Args:
            participants: dict {tla_shard_id: "PK_ro"|"PK_wr"}
        """
        self._emit({
            "tag": "trace",
            "ts": self._ts_ns(),
            "event": "RouterStartTxn",
            "txn": txn_id,
            "router": self._router_id,
            "participants": participants,
            "rPhase": "RP_started",
        })

    def router_commit_txn(self, txn_id, commit_type, attempt=0):
        """RouterCommitTxn: after commit type is selected."""
        r_phase = "RP_done" if commit_type == "CT_noShards" else "RP_committing"
        self._emit({
            "tag": "trace",
            "ts": self._ts_ns(),
            "event": "RouterCommitTxn",
            "txn": txn_id,
            "router": self._router_id,
            "commitType": commit_type,
            "rPhase": r_phase,
            "attempt": attempt,
        })

    def direct_commit(self, txn_id):
        """DirectCommit: after single-shard or read-only direct commit succeeds."""
        self._emit({
            "tag": "trace",
            "ts": self._ts_ns(),
            "event": "DirectCommit",
            "txn": txn_id,
            "router": self._router_id,
            "rPhase": "RP_done",
        })

    def sws_commit_read_only(self, txn_id):
        """SWSCommitReadOnly: after read-only shards committed in SWS path."""
        self._emit({
            "tag": "trace",
            "ts": self._ts_ns(),
            "event": "SWSCommitReadOnly",
            "txn": txn_id,
            "router": self._router_id,
        })

    def sws_commit_write(self, txn_id):
        """SWSCommitWrite: after write shard committed in SWS path."""
        self._emit({
            "tag": "trace",
            "ts": self._ts_ns(),
            "event": "SWSCommitWrite",
            "txn": txn_id,
            "router": self._router_id,
            "rPhase": "RP_done",
        })

    def router_receive_2pc_result(self, txn_id, r_phase="RP_done"):
        """RouterReceive2PCResult: after 2PC coordinator returns result."""
        self._emit({
            "tag": "trace",
            "ts": self._ts_ns(),
            "event": "RouterReceive2PCResult",
            "txn": txn_id,
            "router": self._router_id,
            "rPhase": r_phase,
        })
