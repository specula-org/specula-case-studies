"""
Client-side trace emission for TxnsMoveRange trace harness.

Emits NDJSON lines for router-level events that are observable from the
pymongo client: RouterSendTxnStmt, RouterHandleOk, RouterHandleAbort,
RouterRetryOnStale, ShardRespond.

Server-side migration events (StartMigration, ConfigCommit, etc.) are
extracted from MongoDB LOGV2 logs by parse_logs.py.

Event format matches Trace.tla expectations:
  {"event": "ActionName", "txn": "t1", "ns": "ns1", ...}
"""

import json
import time
import threading


# Static shard name mapping: MongoDB shard name -> TLA+ ID
SHARD_MAP = {
    "shard1RS": "s1",
    "shard2RS": "s2",
    "shard1": "s1",
    "shard2": "s2",
}

# Namespace mapping: MongoDB ns -> TLA+ namespace
NS_MAP = {
    "testdb.items": "ns1",
}

# Key mapping: keep as-is (k1, k2, etc.)


def map_shard(mongo_shard_name):
    """Map MongoDB shard name to TLA+ ID."""
    for k, v in SHARD_MAP.items():
        if k in str(mongo_shard_name):
            return v
    return str(mongo_shard_name)


def map_ns(mongo_ns):
    """Map MongoDB namespace to TLA+ namespace."""
    return NS_MAP.get(mongo_ns, mongo_ns)


class TraceEmitter:
    """Thread-safe NDJSON trace emitter for client-side events."""

    def __init__(self, trace_file):
        self._file = open(trace_file, "w")
        self._lock = threading.Lock()
        self._txn_counter = 0
        self._txn_map = {}       # (lsid, txnNumber) -> "t1", "t2", ...
        self._session_meta = {}  # txn_tla_id -> {lsid, txnNumber}
        self._stmt_counter = {}  # txn_tla_id -> current statement number

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
            self._stmt_counter[tla_id] = 0
        return self._txn_map[key]

    def get_session_meta(self):
        """Return session metadata for log correlation."""
        return dict(self._session_meta)

    # === Router Events ===

    def router_send_txn_stmt(self, txn_id, ns, key, shard,
                              placement_conflict_time=-1):
        """RouterSendTxnStmt: router dispatches statement to shard."""
        self._stmt_counter[txn_id] = self._stmt_counter.get(txn_id, 0) + 1
        stm = self._stmt_counter[txn_id]
        self._emit({
            "event": "RouterSendTxnStmt",
            "txn": txn_id,
            "ns": map_ns(ns),
            "key": key,
            "stm": stm,
            "shard": shard,
            "rPlacementConflictTime": placement_conflict_time,
        })
        return stm

    def router_handle_ok(self, txn_id, stm, completed_stmt):
        """RouterHandleOk: router processes successful response."""
        self._emit({
            "event": "RouterHandleOk",
            "txn": txn_id,
            "stm": stm,
            "rCompletedStmt": completed_stmt,
        })

    def router_handle_abort(self, txn_id, stm, status):
        """RouterHandleAbort: router aborts on non-retryable error."""
        self._emit({
            "event": "RouterHandleAbort",
            "txn": txn_id,
            "stm": stm,
            "status": status,
        })

    def router_retry_on_stale(self, txn_id):
        """RouterRetryOnStale: router retries first statement after stale error."""
        self._stmt_counter[txn_id] = 0  # Reset statement counter for retry
        self._emit({
            "event": "RouterRetryOnStale",
            "txn": txn_id,
            "rPlacementConflictTime": -1,
        })

    def create_database(self, txn_id, db_name="db"):
        """CreateDatabase: router marks database as created in txn."""
        self._emit({
            "event": "CreateDatabase",
            "txn": txn_id,
            "db": db_name,
        })

    # === Shard Events (inferred from client-side observation) ===

    def shard_respond(self, txn_id, shard, ns, status, found, stm):
        """ShardRespond: shard processed and responded to statement.

        Emitted just before the corresponding RouterHandle event, since
        by the time pymongo returns, the shard has already responded.
        """
        self._emit({
            "event": "ShardRespond",
            "txn": txn_id,
            "shard": shard,
            "ns": map_ns(ns),
            "status": status,
            "found": found,
            "stm": stm,
        })
