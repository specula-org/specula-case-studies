#!/usr/bin/env python3
"""
Bug 1 Reproduction: deleteRangeDeletionTaskLocally missing migrationId filter

Escalation Level 2 (State Injection) — Demonstrates the exact query flaw that
the MC 9-state counterexample (MC_hunt_identity.cfg, TaskDocConsistency violated)
identified.

The MC trace shows:
  1. M1 starts on range R1, creates task doc
  2. M1 aborts → deleteRangeDeletionTaskLocally deletes M1's task doc
  3. M2 starts on same R1, commits → creates new task doc
  4. M1's abort REPLAYS (recovery) → deleteRangeDeletionTaskLocally(collUUID, R1)
  5. Query matches M2's doc (no migrationId filter) → DELETES M2's doc

This test reproduces the core defect: the delete query in deleteRangeDeletionTaskLocally
uses {collectionUuid, range.min, range.max} WITHOUT migrationId, while the recipient-side
equivalent correctly includes migrationId. We demonstrate:
  A) The buggy query deletes BOTH docs for same range (wrong)
  B) The migrationId-aware query deletes only the target doc (correct)

Source: range_deletion_util.cpp:702-708 (buggy) vs 677-693 (correct)
"""

import os
import sys
import time
import uuid
import subprocess
import traceback

import pymongo
from pymongo import WriteConcern
from pymongo.errors import OperationFailure, AutoReconnect, ConnectionFailure

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
COMPOSE_FILE = os.path.join(SCRIPT_DIR, 'docker-compose-repro.yml')

PORTS = {
    'mongos':    47017,
    'configsvr': 47018,
    'shard0a':   47019,
    'shard0b':   47020,
    'shard1':    47021,
}

TEST_DB = 'testDB'
TEST_COLL = 'testColl'
TEST_NS = f'{TEST_DB}.{TEST_COLL}'


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def docker_compose(cmd, check=True):
    result = subprocess.run(
        f'docker compose -f {COMPOSE_FILE} {cmd}',
        shell=True, capture_output=True, text=True, timeout=120
    )
    if check and result.returncode != 0 and 'Warning' not in result.stderr:
        log(f"  docker compose {cmd}: {result.stderr[:300]}")
    return result


def conn(name, timeout_ms=10000):
    return pymongo.MongoClient(
        'localhost', PORTS[name],
        directConnection=True,
        serverSelectionTimeoutMS=timeout_ms,
        uuidRepresentation='standard'
    )


def wait_for_node(name, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = conn(name, timeout_ms=2000)
            c.admin.command('ping')
            c.close()
            return True
        except Exception:
            time.sleep(1)
    return False


def wait_for_primary(rs_members, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for name in rs_members:
            try:
                c = conn(name, timeout_ms=2000)
                status = c.admin.command('replSetGetStatus')
                for m in status.get('members', []):
                    if m.get('self') and m['stateStr'] == 'PRIMARY':
                        c.close()
                        return name
                c.close()
            except Exception:
                pass
        time.sleep(1)
    return None


def setup():
    log("=== SETUP: Starting sharded cluster ===")
    docker_compose('down -v', check=False)
    time.sleep(2)
    docker_compose('up -d')

    log("Waiting for nodes...")
    for name in ['configsvr', 'shard0a', 'shard0b', 'shard1']:
        if not wait_for_node(name, timeout=90):
            log(f"FATAL: {name} did not start")
            return False

    log("Initializing replica sets...")
    c = conn('configsvr')
    try:
        c.admin.command('replSetInitiate', {
            '_id': 'configRS', 'configsvr': True,
            'members': [{'_id': 0, 'host': 'configsvr:27017'}]
        })
    except OperationFailure:
        pass
    c.close()
    time.sleep(5)

    c = conn('shard0a')
    try:
        c.admin.command('replSetInitiate', {
            '_id': 'shard0RS',
            'members': [
                {'_id': 0, 'host': 'shard0a:27017', 'priority': 2},
                {'_id': 1, 'host': 'shard0b:27017', 'priority': 1},
            ]
        })
    except OperationFailure:
        pass
    c.close()
    time.sleep(10)

    c = conn('shard1')
    try:
        c.admin.command('replSetInitiate', {
            '_id': 'shard1RS',
            'members': [{'_id': 0, 'host': 'shard1:27017'}]
        })
    except OperationFailure:
        pass
    c.close()
    time.sleep(5)

    if not wait_for_node('mongos', timeout=60):
        log("FATAL: mongos did not start")
        return False

    log("Adding shards...")
    ms = conn('mongos')
    for shard_conn in ['shard0RS/shard0a:27017', 'shard1RS/shard1:27017']:
        for attempt in range(5):
            try:
                ms.admin.command('addShard', shard_conn)
                break
            except OperationFailure as e:
                if 'already' in str(e).lower():
                    break
                time.sleep(5)
    time.sleep(3)

    log("Creating sharded collection...")
    ms.admin.command('enableSharding', TEST_DB)
    ms.admin.command('shardCollection', TEST_NS, key={'x': 1})
    ms[TEST_DB][TEST_COLL].insert_many([{'x': i} for i in range(100)])
    ms.close()

    log("Setup complete.")
    return True


def run_test():
    log("")
    log("=" * 70)
    log("TEST: deleteRangeDeletionTaskLocally missing migrationId filter")
    log("=" * 70)

    s0_primary = wait_for_primary(['shard0a', 'shard0b'], timeout=30)
    if not s0_primary:
        log("FATAL: no shard0 primary")
        return False

    # Step 1: Move a chunk to create a REAL range deletion doc (avoids schema issues)
    log("\nStep 1: Move chunk shard0 → shard1 to create a real range deletion doc")

    # Suspend range deletion so the doc persists
    c = conn(s0_primary)
    c.admin.command({'configureFailPoint': 'suspendRangeDeletion', 'mode': 'alwaysOn'})
    c.close()

    ms = conn('mongos')
    ms.admin.command('split', TEST_NS, middle={'x': 50})
    time.sleep(1)
    ms.admin.command('moveChunk', TEST_NS, find={'x': 60}, to='shard1RS')
    ms.close()
    time.sleep(3)

    # Read the real range deletion doc
    c = conn(s0_primary)
    rd_coll = c['config'].get_collection(
        'rangeDeletions', write_concern=WriteConcern(w='majority'))
    real_docs = list(rd_coll.find())
    if not real_docs:
        log("FATAL: No range deletion doc found after migration")
        c.close()
        return False

    real_doc = real_docs[0]
    log(f"  Real doc: _id={real_doc['_id']}")
    log(f"  Real doc keys: {list(real_doc.keys())}")
    log(f"  collectionUuid: {real_doc.get('collectionUuid')}")
    log(f"  range: {real_doc.get('range')}")

    coll_uuid = real_doc['collectionUuid']
    range_doc = real_doc['range']
    m2_id = real_doc['_id']  # This is the real M2 doc

    # Step 2: Create a second doc for same range (simulating M1's leftover)
    log("\nStep 2: Insert second doc for same range (simulating M1's leftover)")
    m1_id = uuid.UUID('11111111-1111-4111-8111-111111111111')

    # Clone the real doc with a different _id (migrationId)
    m1_doc = dict(real_doc)
    m1_doc['_id'] = m1_id
    rd_coll.insert_one(m1_doc)

    count_before = rd_coll.count_documents({})
    log(f"  Total docs: {count_before} (M1: {m1_id}, M2: {m2_id})")
    assert count_before == 2, f"Expected 2 docs, got {count_before}"

    # === Phase A: Demonstrate the buggy query ===
    log("\n--- Phase A: Buggy query (deleteRangeDeletionTaskLocally) ---")

    # This is the EXACT query from range_deletion_util.cpp:312-318
    # getQueryFilterForRangeDeletionTask(collectionUuid, range):
    #   {collectionUuid: UUID, "range.min": min, "range.max": max}
    buggy_filter = {
        'collectionUuid': coll_uuid,
        'range.min': range_doc['min'],
        'range.max': range_doc['max'],
    }
    log(f"  Query: {{collectionUuid: ..., range.min: {range_doc['min']}, range.max: {range_doc['max']}}}")
    log(f"  (NO migrationId / _id in filter)")

    result = rd_coll.delete_many(buggy_filter)
    count_after = rd_coll.count_documents({})
    log(f"  Deleted: {result.deleted_count} docs")
    log(f"  Remaining: {count_after} docs")

    phase_a_bug = (result.deleted_count == 2 and count_after == 0)
    if phase_a_bug:
        log("  >>> BOTH docs deleted — query matched M2's doc too!")
        log("  >>> In the abort-replay scenario, this deletes the wrong task doc.")
    else:
        log(f"  Unexpected: deleted={result.deleted_count}, remaining={count_after}")

    # === Phase B: Demonstrate the correct query ===
    log("\n--- Phase B: Correct query (deleteRangeDeletionTaskOnRecipient) ---")

    # Re-insert both docs
    m2_doc = dict(real_doc)
    m1_doc_b = dict(real_doc)
    m1_doc_b['_id'] = m1_id
    rd_coll.insert_one(m1_doc_b)
    rd_coll.insert_one(m2_doc)
    count_before = rd_coll.count_documents({})
    log(f"  Re-inserted 2 docs. Total: {count_before}")

    # This is the query from range_deletion_util.cpp:323-328
    # getQueryFilterForRangeDeletionTaskOnRecipient(collectionUuid, range, migrationId):
    #   {collectionUuid: UUID, "range.min": min, "range.max": max, _id: migrationId}
    correct_filter = dict(buggy_filter)
    correct_filter['_id'] = m1_id  # <-- migrationId scopes the delete to M1 only
    log(f"  Query: same + _id={m1_id}")

    result = rd_coll.delete_many(correct_filter)
    count_after = rd_coll.count_documents({})
    log(f"  Deleted: {result.deleted_count} docs")
    log(f"  Remaining: {count_after} docs")

    phase_b_correct = False
    if result.deleted_count == 1 and count_after == 1:
        surviving = rd_coll.find_one({})
        if surviving and surviving['_id'] == m2_id:
            phase_b_correct = True
            log(f"  >>> Only M1's doc deleted. M2's doc SURVIVES (_id={surviving['_id']})")
            log("  >>> The migrationId-aware query correctly scopes the delete.")
        else:
            log(f"  Wrong doc survived: {surviving.get('_id')}")
    else:
        log(f"  Unexpected: deleted={result.deleted_count}, remaining={count_after}")

    # === Phase C: Simulate the abort-replay scenario ===
    log("\n--- Phase C: Abort-replay scenario ---")
    log("  Scenario: M1 aborted, M2 committed on same range.")
    log("  M1's abort replays during recovery. Only M2's doc exists.")

    rd_coll.delete_many({})
    # Only M2's doc exists (M1's was already deleted in the first abort)
    rd_coll.insert_one(m2_doc)
    count_before = rd_coll.count_documents({})
    log(f"  State: only M2's doc in config.rangeDeletions (count={count_before})")

    log(f"  M1's abort replay runs deleteRangeDeletionTaskLocally(collUUID, range)")
    result = rd_coll.delete_many(buggy_filter)
    count_after = rd_coll.count_documents({})
    log(f"  Deleted: {result.deleted_count} docs")
    log(f"  Remaining: {count_after} docs")

    phase_c_bug = (result.deleted_count == 1 and count_after == 0)
    if phase_c_bug:
        log("  >>> M2's doc DELETED by M1's abort replay!")
        log("  >>> M2's in-memory task is now orphaned — persistent doc gone.")
        log("  >>> On next failover, M2's range deletion is permanently lost.")
        log("  >>> Orphaned documents remain on the donor shard indefinitely.")
    else:
        log(f"  Unexpected: deleted={result.deleted_count}, remaining={count_after}")

    # Cleanup failpoint
    try:
        c.admin.command({'configureFailPoint': 'suspendRangeDeletion', 'mode': 'off'})
    except Exception:
        pass
    c.close()

    # === Summary ===
    log("\n" + "=" * 70)
    log("RESULTS")
    log("=" * 70)

    all_phases = phase_a_bug and phase_b_correct and phase_c_bug

    if all_phases:
        log("")
        log("BUG REPRODUCED (Level 2: State Injection)")
        log("")
        log("Phase A: Buggy query deleted BOTH docs for same range   — CONFIRMED")
        log("Phase B: Correct query deleted only the target doc      — CONFIRMED")
        log("Phase C: Abort replay deleted M2's doc (wrong victim)   — CONFIRMED")
        log("")
        log("Root cause: deleteRangeDeletionTaskLocally (range_deletion_util.cpp:702)")
        log("uses getQueryFilterForRangeDeletionTask which filters by")
        log("{collectionUuid, range.min, range.max} WITHOUT migrationId.")
        log("")
        log("The recipient-side equivalent (line 677) uses")
        log("getQueryFilterForRangeDeletionTaskOnRecipient which INCLUDES migrationId.")
        log("Comment at lines 320-322: 'Add migrationId to the query filter in order")
        log("to be resilient to delayed network retries'")
        log("")
        log("Fix: Add migrationId parameter to deleteRangeDeletionTaskLocally and")
        log("use getQueryFilterForRangeDeletionTaskOnRecipient for the filter.")
    else:
        log("")
        log("BUG NOT FULLY REPRODUCED")
        log(f"  Phase A (buggy query): {'PASS' if phase_a_bug else 'FAIL'}")
        log(f"  Phase B (correct query): {'PASS' if phase_b_correct else 'FAIL'}")
        log(f"  Phase C (abort replay): {'PASS' if phase_c_bug else 'FAIL'}")

    return all_phases


def teardown():
    log("\n=== TEARDOWN ===")
    docker_compose('down -v', check=False)


def main():
    log("=" * 70)
    log("Bug 1: deleteRangeDeletionTaskLocally missing migrationId filter")
    log("MC: 9-state counterexample, TaskDocConsistency violated")
    log("=" * 70)
    log("")

    try:
        if not setup():
            log("FATAL: Setup failed")
            teardown()
            return 1

        result = run_test()
        return 0 if result else 1

    except KeyboardInterrupt:
        log("\nInterrupted")
        return 1
    except Exception as e:
        log(f"\nError: {e}")
        traceback.print_exc()
        return 1
    finally:
        teardown()


if __name__ == '__main__':
    sys.exit(main())
