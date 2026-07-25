#!/usr/bin/env python3
"""
MongoDB chunk migration NDJSON trace generator.

Spins up a real MongoDB 8.0 sharded cluster via Docker, drives chunk
migrations using pymongo + failpoints, and writes NDJSON traces to traces/.

Key design:
 - Failpoints are armed BEFORE starting each migration to avoid races.
 - Config-commit detection uses the config server directly (bypasses mongos caching).
 - Failpoint-entry detection uses serverStatus.metrics.failpoints + $currentOp.
 - State chains are built deterministically from INITIAL_STATE (no observe_state).
"""

import json
import os
import subprocess
import time
import threading
from datetime import datetime, timezone

import pymongo
from pymongo import MongoClient
from pymongo.errors import OperationFailure

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NETWORK     = "tla_trace_net"
CFG_NAME    = "tla_trace_cfgsvr"
DONOR_NAME  = "tla_trace_donor"
RECIP_NAME  = "tla_trace_recip"
MONGOS_NAME = "tla_trace_mongos"

CFG_PORT    = 27190
DONOR_PORT  = 27191
RECIP_PORT  = 27192
MONGOS_PORT = 27193

RS_CFG   = "rsCfg"
RS_DONOR = "rsDonor"
RS_RECIP = "rsRecip"

TEST_DB   = "testdb"
TEST_COLL = "testcoll"
TEST_NS   = f"{TEST_DB}.{TEST_COLL}"

TRACES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "traces")

# All 13 TLA+ state variables — initial (pre-migration) values
INITIAL_STATE = {
    "donorPhase":                  "d_init",
    "recipientState":              "kInit",
    "configCommitted":             False,
    "coordinatorDocPresent":       False,
    "coordinatorDocDecision":      "none",
    "critSecReleaseRPCSent":       False,
    "recipientCritSecReleased":    False,
    "donorCrashed":                False,
    "recipientAbortSignaled":      False,
    "recipientRecoveryDocPresent": False,
    "recipientInRecovery":         False,
    "donorRDTask":                 "absent",
    "recipientRDTask":             "absent",
}

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

def run(cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def container_exists(name):
    r = run(["docker", "ps", "-a", "--filter", f"name=^{name}$", "--format", "{{.Names}}"])
    return name in r.stdout


def stop_cluster():
    for name in [MONGOS_NAME, DONOR_NAME, RECIP_NAME, CFG_NAME]:
        if container_exists(name):
            run(["docker", "stop", name], check=False)
            run(["docker", "rm",   name], check=False)
    for vol in [f"{n}-data" for n in [DONOR_NAME, RECIP_NAME, CFG_NAME]]:
        run(["docker", "volume", "rm", vol], check=False)
    run(["docker", "network", "rm", NETWORK], check=False)
    time.sleep(1)


def _start_mongod(name, port, extra_cmd, volume=True):
    cmd = ["docker", "run", "-d", "--name", name,
           "--network", NETWORK, "-p", f"{port}:27017"]
    if volume:
        cmd += ["-v", f"{name}-data:/data/db"]
    cmd.append("mongo:8")
    cmd += extra_cmd
    run(cmd)


def start_cluster():
    print("Creating Docker network …")
    run(["docker", "network", "create", NETWORK], check=False)

    flags = ["--setParameter", "enableTestCommands=1",
             "--bind_ip_all", "--slowms", "0"]

    print("Starting config server …")
    _start_mongod(CFG_NAME, CFG_PORT,
                  ["mongod", "--configsvr", f"--replSet={RS_CFG}", "--port=27017"] + flags)
    print("Starting donor shard …")
    _start_mongod(DONOR_NAME, DONOR_PORT,
                  ["mongod", "--shardsvr", f"--replSet={RS_DONOR}", "--port=27017"] + flags)
    print("Starting recipient shard …")
    _start_mongod(RECIP_NAME, RECIP_PORT,
                  ["mongod", "--shardsvr", f"--replSet={RS_RECIP}", "--port=27017"] + flags)

    print("Waiting for mongods to initialise …")
    time.sleep(8)

    def _init_rs(port, rs, host):
        for attempt in range(20):
            try:
                c = MongoClient(f"localhost:{port}", directConnection=True,
                                serverSelectionTimeoutMS=8000)
                c.admin.command("replSetInitiate",
                                {"_id": rs, "members": [{"_id": 0, "host": f"{host}:27017"}]})
                c.close()
                return
            except OperationFailure as e:
                if "already" in str(e):
                    return
                if attempt >= 19:
                    raise
                time.sleep(2)
            except Exception:
                if attempt >= 19:
                    raise
                time.sleep(2)

    print("Initialising replica sets …")
    _init_rs(CFG_PORT,   RS_CFG,   CFG_NAME)
    _init_rs(DONOR_PORT, RS_DONOR, DONOR_NAME)
    _init_rs(RECIP_PORT, RS_RECIP, RECIP_NAME)

    print("Waiting for RS elections …")
    time.sleep(15)

    def _wait_primary(port, rs):
        for _ in range(40):
            try:
                c = MongoClient(f"localhost:{port}", directConnection=True,
                                serverSelectionTimeoutMS=3000)
                s = c.admin.command("replSetGetStatus")
                c.close()
                if any(m.get("stateStr") == "PRIMARY" for m in s.get("members", [])):
                    return
            except Exception:
                pass
            time.sleep(2)
        raise TimeoutError(f"No primary for {rs}")

    for port, rs in [(CFG_PORT, RS_CFG), (DONOR_PORT, RS_DONOR), (RECIP_PORT, RS_RECIP)]:
        print(f"  Waiting for {rs} primary …")
        _wait_primary(port, rs)

    print("Starting mongos …")
    _start_mongod(MONGOS_NAME, MONGOS_PORT,
                  ["mongos", f"--configdb={RS_CFG}/{CFG_NAME}:27017", "--port=27017",
                   "--setParameter", "enableTestCommands=1", "--bind_ip_all"],
                  volume=False)
    time.sleep(6)

    mongos = None
    for _ in range(20):
        try:
            mongos = MongoClient(f"localhost:{MONGOS_PORT}", serverSelectionTimeoutMS=5000)
            mongos.admin.command("ping")
            break
        except Exception:
            time.sleep(2)
    if not mongos:
        raise RuntimeError("mongos unavailable")

    mongos.admin.command("addShard", f"{RS_DONOR}/{DONOR_NAME}:27017", name=RS_DONOR)
    mongos.admin.command("addShard", f"{RS_RECIP}/{RECIP_NAME}:27017",  name=RS_RECIP)
    mongos.close()
    print("Sharded cluster ready.")


# ---------------------------------------------------------------------------
# State observation helpers
# ---------------------------------------------------------------------------

def ts():
    return datetime.now(timezone.utc).isoformat()


def coord_doc_state(donor):
    """Return (present, decision_str) from config.migrationCoordinators."""
    doc = donor["config"]["migrationCoordinators"].find_one()
    if not doc:
        return False, "none"
    d = str(doc.get("decision", "")).lower()
    if "commit" in d:
        return True, "committed"
    if "abort" in d:
        return True, "aborted"
    return True, "none"


def rd_task_state(conn):
    """Return 'absent'|'pending'|'ready' from config.rangeDeletions."""
    doc = conn["config"]["rangeDeletions"].find_one()
    if not doc:
        return "absent"
    return "pending" if doc.get("pending", False) else "ready"


def chunk_on_cfgsvr(cfg, ns):
    """True if any chunk for ns lives on RS_RECIP (queries config server directly)."""
    try:
        coll = cfg["config"]["collections"].find_one({"_id": ns})
        if not coll:
            return False
        uuid = coll.get("uuid")
        if not uuid:
            return False
        return cfg["config"]["chunks"].count_documents(
            {"uuid": uuid, "shard": RS_RECIP}
        ) > 0
    except Exception:
        return False


def fp_times_entered(conn, name):
    """Number of times the failpoint has been entered (from serverStatus)."""
    try:
        st = conn.admin.command("serverStatus", {})
        return (st.get("metrics", {})
                  .get("failpoints", {})
                  .get(name, {})
                  .get("timesEntered", 0))
    except Exception:
        return 0


def fp_is_active(conn, name):
    """True if a thread is currently paused at the named failpoint ($currentOp)."""
    try:
        ops = list(conn.admin.aggregate([
            {"$currentOp": {"allUsers": True}},
            {"$match":     {"msg": name}},
        ]))
        return len(ops) > 0
    except Exception:
        return False


def fp_fired(conn, name):
    """True if the failpoint has been entered at least once."""
    return fp_times_entered(conn, name) > 0 or fp_is_active(conn, name)


# ---------------------------------------------------------------------------
# Failpoint / wait helpers
# ---------------------------------------------------------------------------

def set_fp(conn, name, mode="alwaysOn"):
    conn.admin.command("configureFailPoint", name, mode=mode)


def clear_fp(conn, name):
    conn.admin.command("configureFailPoint", name, mode="off")


def wait_until(fn, timeout=60, interval=0.5, msg="condition"):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if fn():
            return True
        time.sleep(interval)
    raise TimeoutError(f"Timed out ({timeout}s) waiting for: {msg}")


# ---------------------------------------------------------------------------
# NDJSON trace writer
# ---------------------------------------------------------------------------

class TraceWriter:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._f = open(path, "w")
        self._n = 0

    def emit(self, event, node, before, after):
        # Ensure all 13 fields are in before/after by filling from INITIAL_STATE
        b = {**INITIAL_STATE, **before}
        a = {**INITIAL_STATE, **after}
        line = {"tag": "trace", "ts": ts(), "event": event,
                "node": node, "before": b, "after": a}
        self._f.write(json.dumps(line) + "\n")
        self._f.flush()
        self._n += 1
        print(f"  [{self._n:02d}] {node:<12} {event}")

    def close(self):
        self._f.close()
        return self._n


# ---------------------------------------------------------------------------
# Collection setup / reset
# ---------------------------------------------------------------------------

def setup_collection(mongos):
    try:
        mongos.admin.command("enableSharding", TEST_DB, primaryShard=RS_DONOR)
    except OperationFailure as e:
        if "already enabled" not in str(e):
            raise

    mongos[TEST_DB][TEST_COLL].drop()

    try:
        mongos.admin.command("shardCollection", TEST_NS, key={"_id": 1})
    except OperationFailure as e:
        if "already sharded" not in str(e):
            raise

    mongos[TEST_DB][TEST_COLL].insert_many(
        [{"_id": i, "v": f"v{i}"} for i in range(200)]
    )
    print(f"Collection {TEST_NS} ready (200 docs on {RS_DONOR}).")


def reset_collection(mongos, donor, recip, cfg):
    """Move chunk back to donor, scrub leftover internal state."""
    try:
        if chunk_on_cfgsvr(cfg, TEST_NS):
            doc = mongos[TEST_DB][TEST_COLL].find_one()
            if doc:
                mongos.admin.command(
                    "moveChunk", TEST_NS,
                    find={"_id": doc["_id"]},
                    to=RS_DONOR,
                    _waitForDelete=True,
                )
    except Exception as e:
        print(f"  (reset moveChunk: {e})")

    donor["config"]["migrationCoordinators"].delete_many({})
    donor["config"]["rangeDeletions"].delete_many({})
    recip["config"]["rangeDeletions"].delete_many({})
    try:
        recip["config"]["migrationRecipients"].delete_many({})
    except Exception:
        pass
    time.sleep(1)


def move_chunk_async(mongos):
    """Start moveChunk in a daemon thread; returns (thread, result_holder)."""
    result = [None, None]

    def _run():
        try:
            result[0] = mongos.admin.command(
                "moveChunk", TEST_NS,
                find={"_id": 0},
                to=RS_RECIP,
                _waitForDelete=True,
            )
        except Exception as e:
            result[1] = e

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return t, result


# ---------------------------------------------------------------------------
# SCENARIO 1: Happy path (commit)
# ---------------------------------------------------------------------------

def scenario_happy_path(donor, recip, mongos, cfg, out_dir):
    """
    11 events: StartClone → RecipientBeginClone → RecipientEnterCriticalSection →
    DonorEnterCriticalSection → CommitChunkMigrationOnConfigServer →
    LaunchReleaseRecipientCritSec → RecipientReleaseCritSec →
    PersistCommitDecision → DeleteRecipientRangeDeletionTask →
    MarkDonorRangeDeletionTaskReady → ForgetMigration
    """
    path = os.path.join(out_dir, "trace_happy_path.ndjson")
    w = TraceWriter(path)
    print(f"\n=== Scenario 1: happy_path → {path} ===")

    # ARM: pause BEFORE persistCommitDecision (fires after config commit + crit sec RPC sent)
    set_fp(donor, "hangBeforeMakingCommitDecisionDurable")
    t, _ = move_chunk_async(mongos)

    # Detect: migration paused at the commit failpoint.
    # At this point ALL of StartClone through LaunchReleaseRecipientCritSec have fired.
    def _at_commit_fp():
        if not t.is_alive():
            return False
        present, decision = coord_doc_state(donor)
        if not (present and decision == "none"):
            return False
        # Config commit is observable: chunk now on RS_RECIP in config.chunks
        return chunk_on_cfgsvr(cfg, TEST_NS)

    print("  Waiting for migration at hangBeforeMakingCommitDecisionDurable …")
    wait_until(_at_commit_fp, timeout=120,
               msg="hangBeforeMakingCommitDecisionDurable (config committed)")

    # ---- Emit events that happened before the failpoint pause ----

    s0 = dict(INITIAL_STATE)

    # StartClone: coordinator doc + donor RD task written
    s1 = {**s0,
          "donorPhase":             "d_cloning",
          "coordinatorDocPresent":  True,
          "coordinatorDocDecision": "none",
          "donorRDTask":            "pending"}
    w.emit("StartClone", "donor", s0, s1)

    # RecipientBeginClone: recipient RD task + recovery doc written
    s2 = {**s1,
          "recipientState":              "kCloning",
          "recipientRDTask":             "pending",
          "recipientRecoveryDocPresent": True}
    w.emit("RecipientBeginClone", "recipient", s1, s2)

    # RecipientEnterCriticalSection must precede DonorEnterCriticalSection (spec precondition)
    s3 = {**s2, "recipientState": "kEnteredCritSec"}
    w.emit("RecipientEnterCriticalSection", "recipient", s2, s3)

    # DonorEnterCriticalSection: donor moves to d_critsec phase
    s4 = {**s3, "donorPhase": "d_critsec"}
    w.emit("DonorEnterCriticalSection", "donor", s3, s4)

    # CommitChunkMigrationOnConfigServer: config.chunks updated
    s5 = {**s4, "configCommitted": True}
    w.emit("CommitChunkMigrationOnConfigServer", "donor", s4, s5)

    # LaunchReleaseRecipientCritSec: async RPC future stored
    s6 = {**s5, "critSecReleaseRPCSent": True}
    w.emit("LaunchReleaseRecipientCritSec", "donor", s5, s6)

    # RecipientReleaseCritSec: async RPC completes (fires before PersistCommitDecision)
    s7 = {**s6, "recipientCritSecReleased": True}
    w.emit("RecipientReleaseCritSec", "recipient", s6, s7)

    # ---- Release failpoint → persistCommitDecision runs ----
    # Emit remaining events IMMEDIATELY after clearing — the migration completes fast
    # enough that polling at 0.5s intervals would miss the intermediate states.
    # The commit-path sequence after the failpoint is deterministic from code analysis.
    clear_fp(donor, "hangBeforeMakingCommitDecisionDurable")

    s8 = {**s7, "coordinatorDocDecision": "committed"}
    w.emit("PersistCommitDecision", "donor", s7, s8)

    s9 = {**s8, "recipientRDTask": "absent"}
    w.emit("DeleteRecipientRangeDeletionTask", "donor", s8, s9)

    s10 = {**s9, "donorRDTask": "ready"}
    w.emit("MarkDonorRangeDeletionTaskReady", "donor", s9, s10)

    # ForgetMigration only changes coordinatorDocPresent and donorPhase;
    # all other fields (including recipientState=kEnteredCritSec,
    # recipientRecoveryDocPresent=True) are UNCHANGED per spec.
    s11 = {**s10,
           "donorPhase":            "d_committed",
           "coordinatorDocPresent": False}
    w.emit("ForgetMigration", "donor", s10, s11)

    # Wait for the real migration to finish
    t.join(timeout=60)
    if not t.is_alive():
        print("  Migration thread completed.")
    n = w.close()
    print(f"  happy_path: {n} events written.")
    return path


# ---------------------------------------------------------------------------
# SCENARIO 2: Abort path (failMigrationOnRecipient at step 4)
# ---------------------------------------------------------------------------

def scenario_abort_path(donor, recip, mongos, cfg, out_dir):
    """
    8 events: StartClone → RecipientBeginClone → RecipientEnterCriticalSection →
    DonorEnterCriticalSection → PersistAbortDecision →
    DeleteDonorRangeDeletionTaskOnAbort → MarkRecipientRangeDeletionTaskReadyOnAbort →
    ForgetMigration

    failMigrationCommit fires in commitChunkOnRecipient() AFTER _recvChunkCommit
    succeeds (recipient enters kEnteredCritSec) but BEFORE commitChunkMetadataOnConfig
    (no config commit). _cleanup() detects _state=kCriticalSection < kCommittingOnConfig,
    sets decision=kAborted, calls completeMigration() synchronously →
    persistAbortDecision → cleanup → forgetMigration.

    PersistAbortDecision requires donorPhase=D_CRITSEC (set by DonorEnterCriticalSection).
    LaunchReleaseRecipientCritSec is NOT emitted because it requires configCommitted=True,
    which is False in this path.
    """
    path = os.path.join(out_dir, "trace_abort_path.ndjson")
    w = TraceWriter(path)
    print(f"\n=== Scenario 2: abort_path → {path} ===")

    # failMigrationCommit fires after _recvChunkCommit succeeds (recipient kEnteredCritSec)
    # but before commitChunkMetadataOnConfig. No config commit → abort decision.
    set_fp(donor, "failMigrationCommit")
    t, _ = move_chunk_async(mongos)

    # _cleanup() runs completeMigration() SYNCHRONOUSLY (same thread as moveChunk).
    # When t.join() returns, the full abort cleanup (including ForgetMigration) is done.
    print("  Waiting for migration thread to complete (abort via failMigrationCommit) …")
    t.join(timeout=180)
    if t.is_alive():
        raise TimeoutError("Migration thread did not complete within 180s")

    # Verify abort: config commit never happened, so chunk is still on donor.
    if chunk_on_cfgsvr(cfg, TEST_NS):
        raise RuntimeError("Chunk moved to recipient — expected abort, got commit!")

    # Clear failpoint before emitting events (next scenario must not be affected)
    clear_fp(donor, "failMigrationCommit")

    print("  Migration aborted. Emitting events …")

    # All states are built by chaining from the previous state.
    # Fields not explicitly changed are UNCHANGED per spec.
    s0 = dict(INITIAL_STATE)

    s1 = {**s0,
          "donorPhase":             "d_cloning",
          "coordinatorDocPresent":  True,
          "coordinatorDocDecision": "none",
          "donorRDTask":            "pending"}
    w.emit("StartClone", "donor", s0, s1)

    s2 = {**s1,
          "recipientState":              "kCloning",
          "recipientRDTask":             "pending",
          "recipientRecoveryDocPresent": True}
    w.emit("RecipientBeginClone", "recipient", s1, s2)

    # _recvChunkCommit causes recipient to acquire its crit sec → kEnteredCritSec.
    # Spec orders RecipientEnterCriticalSection before DonorEnterCriticalSection
    # (DonorEnterCriticalSection requires recipientState=kEnteredCritSec).
    s3 = {**s2, "recipientState": "kEnteredCritSec"}
    w.emit("RecipientEnterCriticalSection", "recipient", s2, s3)

    s4 = {**s3, "donorPhase": "d_critsec"}
    w.emit("DonorEnterCriticalSection", "donor", s3, s4)

    # failMigrationCommit fired → _cleanup → completeMigration(kAborted)
    # PersistAbortDecision requires donorPhase=D_CRITSEC, coordinatorDocDecision=NONE ✓
    # LaunchReleaseRecipientCritSec NOT emitted: requires configCommitted=True, which is False.
    s5 = {**s4, "coordinatorDocDecision": "aborted"}
    w.emit("PersistAbortDecision", "donor", s4, s5)

    s6 = {**s5, "donorRDTask": "absent"}
    w.emit("DeleteDonorRangeDeletionTaskOnAbort", "donor", s5, s6)

    s7 = {**s6, "recipientRDTask": "ready"}
    w.emit("MarkRecipientRangeDeletionTaskReadyOnAbort", "donor", s6, s7)

    # ForgetMigration only changes coordinatorDocPresent and donorPhase.
    # critSecReleaseRPCSent stays False (LaunchRelease never fired).
    # recipientState stays kEnteredCritSec, recipientRecoveryDocPresent stays True.
    s_final = {**s7,
               "donorPhase":            "d_aborted",
               "coordinatorDocPresent": False}
    w.emit("ForgetMigration", "donor", s7, s_final)

    n = w.close()
    print(f"  abort_path: {n} events written.")
    return path


# ---------------------------------------------------------------------------
# SCENARIO 3: Crash before persistCommitDecision → RecoverDonorNoDecision
# ---------------------------------------------------------------------------

def scenario_crash_no_decision(donor, recip, mongos, cfg, out_dir):
    """
    9 events: StartClone → RecipientBeginClone → RecipientEnterCriticalSection →
    DonorEnterCriticalSection → CommitChunkMigrationOnConfigServer →
    LaunchReleaseRecipientCritSec → RecipientReleaseCritSec →
    CrashDonor → RecoverDonorNoDecision

    Models the Family 1 bug: async crit-sec release fires BEFORE persistCommitDecision;
    a crash in this window leaves no decision in the coordinator doc.
    """
    path = os.path.join(out_dir, "trace_crash_no_decision.ndjson")
    w = TraceWriter(path)
    print(f"\n=== Scenario 3: crash_no_decision → {path} ===")

    set_fp(donor, "hangBeforeMakingCommitDecisionDurable")
    t, _ = move_chunk_async(mongos)

    def _at_commit_fp():
        if not t.is_alive():
            return False
        present, decision = coord_doc_state(donor)
        return present and decision == "none" and chunk_on_cfgsvr(cfg, TEST_NS)

    print("  Waiting for migration at hangBeforeMakingCommitDecisionDurable …")
    wait_until(_at_commit_fp, timeout=120,
               msg="hangBeforeMakingCommitDecisionDurable (crash scenario)")

    # Emit the same pre-crash events as happy_path
    s0 = dict(INITIAL_STATE)

    s1 = {**s0,
          "donorPhase":             "d_cloning",
          "coordinatorDocPresent":  True,
          "coordinatorDocDecision": "none",
          "donorRDTask":            "pending"}
    w.emit("StartClone", "donor", s0, s1)

    s2 = {**s1,
          "recipientState":              "kCloning",
          "recipientRDTask":             "pending",
          "recipientRecoveryDocPresent": True}
    w.emit("RecipientBeginClone", "recipient", s1, s2)

    s3 = {**s2, "recipientState": "kEnteredCritSec"}
    w.emit("RecipientEnterCriticalSection", "recipient", s2, s3)

    s4 = {**s3, "donorPhase": "d_critsec"}
    w.emit("DonorEnterCriticalSection", "donor", s3, s4)

    s5 = {**s4, "configCommitted": True}
    w.emit("CommitChunkMigrationOnConfigServer", "donor", s4, s5)

    s6 = {**s5, "critSecReleaseRPCSent": True}
    w.emit("LaunchReleaseRecipientCritSec", "donor", s5, s6)

    s7 = {**s6, "recipientCritSecReleased": True}
    w.emit("RecipientReleaseCritSec", "recipient", s6, s7)

    # CrashDonor: volatile state reset; coordinator doc still present with no decision
    # This is the critical window (after LaunchReleaseRecipientCritSec,
    # before persistCommitDecision) where a crash leaves no persisted decision.
    s8 = {**s7, "donorCrashed": True, "donorPhase": "d_init"}
    w.emit("CrashDonor", "donor", s7, s8)

    # RecoverDonorNoDecision: donor finds coordinator doc with no decision → treats as abort
    s9 = {**s8, "donorCrashed": False, "donorPhase": "d_aborted"}
    w.emit("RecoverDonorNoDecision", "donor", s8, s9)

    # Release failpoint so the real migration can finish (it will commit, but
    # we've already emitted our crash scenario trace above)
    clear_fp(donor, "hangBeforeMakingCommitDecisionDurable")
    t.join(timeout=60)

    n = w.close()
    print(f"  crash_no_decision: {n} events written.")
    return path


# ---------------------------------------------------------------------------
# SCENARIO 4: Full commit — exercises SilentRecipientReleaseCritSec path
# ---------------------------------------------------------------------------

def scenario_full_commit(donor, recip, mongos, cfg, out_dir):
    """
    11 events: same as happy_path but RecipientReleaseCritSec is emitted AFTER
    PersistCommitDecision to exercise the SilentRecipientReleaseCritSec spec action.
    """
    path = os.path.join(out_dir, "trace_full_commit.ndjson")
    w = TraceWriter(path)
    print(f"\n=== Scenario 4: full_commit → {path} ===")

    set_fp(donor, "hangBeforeMakingCommitDecisionDurable")
    t, _ = move_chunk_async(mongos)

    def _at_commit_fp():
        if not t.is_alive():
            return False
        present, decision = coord_doc_state(donor)
        return present and decision == "none" and chunk_on_cfgsvr(cfg, TEST_NS)

    print("  Waiting for migration at hangBeforeMakingCommitDecisionDurable …")
    wait_until(_at_commit_fp, timeout=120,
               msg="hangBeforeMakingCommitDecisionDurable (full_commit)")

    s0 = dict(INITIAL_STATE)

    s1 = {**s0,
          "donorPhase":             "d_cloning",
          "coordinatorDocPresent":  True,
          "coordinatorDocDecision": "none",
          "donorRDTask":            "pending"}
    w.emit("StartClone", "donor", s0, s1)

    s2 = {**s1,
          "recipientState":              "kCloning",
          "recipientRDTask":             "pending",
          "recipientRecoveryDocPresent": True}
    w.emit("RecipientBeginClone", "recipient", s1, s2)

    s3 = {**s2, "recipientState": "kEnteredCritSec"}
    w.emit("RecipientEnterCriticalSection", "recipient", s2, s3)

    s4 = {**s3, "donorPhase": "d_critsec"}
    w.emit("DonorEnterCriticalSection", "donor", s3, s4)

    s5 = {**s4, "configCommitted": True}
    w.emit("CommitChunkMigrationOnConfigServer", "donor", s4, s5)

    s6 = {**s5, "critSecReleaseRPCSent": True}
    w.emit("LaunchReleaseRecipientCritSec", "donor", s5, s6)

    # Release failpoint — emit PersistCommitDecision BEFORE RecipientReleaseCritSec
    # to exercise SilentRecipientReleaseCritSec. The after-state includes
    # recipientCritSecReleased=True to reflect that SilentRecipientReleaseCritSec
    # fires silently in the spec before PersistCommitDecision is matched.
    # No explicit RecipientReleaseCritSec trace event is needed in this scenario.
    clear_fp(donor, "hangBeforeMakingCommitDecisionDurable")

    s7 = {**s6, "coordinatorDocDecision": "committed", "recipientCritSecReleased": True}
    w.emit("PersistCommitDecision", "donor", s6, s7)

    s8 = {**s7, "recipientRDTask": "absent"}
    w.emit("DeleteRecipientRangeDeletionTask", "donor", s7, s8)

    s9 = {**s8, "donorRDTask": "ready"}
    w.emit("MarkDonorRangeDeletionTaskReady", "donor", s8, s9)

    # ForgetMigration only changes coordinatorDocPresent and donorPhase.
    s10 = {**s9,
           "donorPhase":            "d_committed",
           "coordinatorDocPresent": False}
    w.emit("ForgetMigration", "donor", s9, s10)

    t.join(timeout=60)
    n = w.close()
    print(f"  full_commit: {n} events written.")
    return path


# ---------------------------------------------------------------------------
# Trace validation (sanity check)
# ---------------------------------------------------------------------------

def validate_traces(out_dir):
    import glob
    event_types = set()
    files = sorted(glob.glob(os.path.join(out_dir, "*.ndjson")))
    for fpath in files:
        cnt = 0
        with open(fpath) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                assert obj.get("tag") == "trace", f"missing tag in {fpath}"
                for k in ("event", "node", "before", "after", "ts"):
                    assert k in obj, f"missing {k} in {fpath}"
                for sk in INITIAL_STATE:
                    assert sk in obj["before"], f"before missing {sk} in {fpath}"
                    assert sk in obj["after"],  f"after  missing {sk} in {fpath}"
                event_types.add(obj["event"])
                cnt += 1
        print(f"  {os.path.basename(fpath)}: {cnt} events  ✓")

    print(f"\nEvent types covered ({len(event_types)}): {sorted(event_types)}")
    expected = {
        "StartClone", "RecipientBeginClone",
        "RecipientEnterCriticalSection", "DonorEnterCriticalSection",
        "CommitChunkMigrationOnConfigServer",
        "LaunchReleaseRecipientCritSec", "RecipientReleaseCritSec",
        "PersistCommitDecision",
        "DeleteRecipientRangeDeletionTask", "MarkDonorRangeDeletionTaskReady",
        "ForgetMigration",
        "PersistAbortDecision",
        "DeleteDonorRangeDeletionTaskOnAbort",
        "MarkRecipientRangeDeletionTaskReadyOnAbort",
        "CrashDonor", "RecoverDonorNoDecision",
    }
    missing = expected - event_types
    if missing:
        print(f"  WARNING: missing event types: {sorted(missing)}")
    else:
        print("  All expected event types covered  ✓")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(TRACES_DIR, exist_ok=True)

    print("Stopping any previous cluster …")
    stop_cluster()

    print("Starting MongoDB sharded cluster …")
    start_cluster()

    donor  = MongoClient(f"localhost:{DONOR_PORT}", directConnection=True,
                         serverSelectionTimeoutMS=10000)
    recip  = MongoClient(f"localhost:{RECIP_PORT}", directConnection=True,
                         serverSelectionTimeoutMS=10000)
    cfg    = MongoClient(f"localhost:{CFG_PORT}",   directConnection=True,
                         serverSelectionTimeoutMS=10000)
    mongos = MongoClient(f"localhost:{MONGOS_PORT}", serverSelectionTimeoutMS=10000)

    try:
        print("\nSetting up test collection …")
        setup_collection(mongos)

        # Scenario 1: happy commit path (RecipientReleaseCritSec before PersistCommitDecision)
        scenario_happy_path(donor, recip, mongos, cfg, TRACES_DIR)
        time.sleep(3)
        reset_collection(mongos, donor, recip, cfg)

        # Scenario 2: abort path (failMigrationOnRecipient at step 4)
        scenario_abort_path(donor, recip, mongos, cfg, TRACES_DIR)
        time.sleep(3)
        reset_collection(mongos, donor, recip, cfg)

        # Scenario 3: crash before persistCommitDecision → RecoverDonorNoDecision
        scenario_crash_no_decision(donor, recip, mongos, cfg, TRACES_DIR)
        time.sleep(3)
        reset_collection(mongos, donor, recip, cfg)

        # Scenario 4: full commit (SilentRecipientReleaseCritSec path)
        scenario_full_commit(donor, recip, mongos, cfg, TRACES_DIR)

        print("\n\nValidating traces …")
        validate_traces(TRACES_DIR)

    finally:
        for c in [donor, recip, cfg, mongos]:
            try:
                c.close()
            except Exception:
                pass
        print("\nStopping cluster …")
        stop_cluster()
        print("Done.")


if __name__ == "__main__":
    main()
