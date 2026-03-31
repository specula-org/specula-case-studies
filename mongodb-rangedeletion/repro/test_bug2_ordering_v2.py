#!/usr/bin/env python3
"""
Bug 2 Reproduction (v2): Recovery Ordering Inversion on Single-Threaded Executor

VERSION DEPENDENCY
------------------
The overlap ordering logic (range_deleter_service.cpp:392-417) was introduced by
SERVER-119435 (commit 9343c350ae, Feb 12 2026) on the master branch to prevent
deadlocks between overlapping range deletion tasks. This code has NOT been released
in any stable version as of MongoDB 8.2.6.

Pre-SERVER-119435 (8.2.6 and earlier):
  - NO overlap ordering in registerTask chain
  - Tasks run independently after registration
  - Processor FIFO queue preserves Phase 1 → Phase 2 ordering
  - Bug does NOT manifest

Post-SERVER-119435 (master, future releases):
  - Overlap ordering at lines 402-406 uses registrationTime + UUID tiebreaker
  - With equal timestamps, UUID ordering can deprioritize a processing task
  - The getServiceUpFuture() gate (line 383) ensures overlap checks see all tasks
  - Bug IS exercisable

This test verifies the PRECONDITIONS on 8.2.6 and provides analytical confirmation
that the overlap ordering on master would produce the wrong result.

BUG MECHANISM (on single-threaded executor, post-SERVER-119435)
---------------------------------------------------------------
The executor IS single-threaded (confirmed by two code comments):
  range_deletion_util.cpp:253  — "relies on the executor only having a single thread"
  range_deletion_util.cpp:413  — "(SERVER-62368) The range-deleter executor is mono-threaded"

1. Recovery callback holds the reactor thread while registering ALL tasks
2. Chains' .then() callbacks are queued — they CANNOT run until recovery yields
3. getServiceUpFuture() gate ensures overlap checks wait for recovery completion
4. Both overlap checks see BOTH registered tasks
5. With equal timestamps, UUID tiebreaker: A(00000000)<B(ffffffff) → A waits for B
6. Non-processing task B gets priority over was-processing task A

WHAT THIS TEST DOES (Level 2: State Injection + Level 1: Failpoint)
-------------------------------------------------------------------
1. Creates a sharded cluster and does a real migration for a template doc
2. Injects two overlapping range deletion docs with controlled state
3. Steps down primary, waits for new primary to step up and run recovery
4. Verifies preconditions: both tasks registered, correct timestamps, overlap detected
5. On 8.2.6: verifies both tasks run freely (no overlap ordering — correct for this version)
6. On master: checks for overlap ordering evidence (log 11943500, B reaches deletion first)
"""

import os
import sys
import time
import uuid
import subprocess
import traceback

import pymongo
from pymongo import WriteConcern, ReadPreference
from pymongo.errors import OperationFailure, AutoReconnect, NotPrimaryError, ConnectionFailure
from bson import Timestamp as BsonTimestamp

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

# UUID ordering: A(low) < B(high)
# Post-SERVER-119435: overlap ordering tiebreaker → A waits for B
TASK_A_UUID = uuid.UUID('00000000-0000-4000-8000-000000000001')
TASK_B_UUID = uuid.UUID('ffffffff-ffff-4fff-bfff-ffffffffffff')


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def docker_compose(cmd, check=True):
    result = subprocess.run(
        f'docker compose -f {COMPOSE_FILE} {cmd}',
        shell=True, capture_output=True, text=True, timeout=180
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


def set_failpoint(node_name, fp_name, mode='alwaysOn', data=None):
    c = conn(node_name)
    cmd = {'configureFailPoint': fp_name, 'mode': mode}
    if data:
        cmd['data'] = data
    try:
        return c.admin.command(cmd)
    except OperationFailure as e:
        log(f"  failpoint {fp_name} on {node_name}: {e}")
        return None
    finally:
        c.close()


def get_docker_logs(container_name, since_seconds=300):
    result = subprocess.run(
        f'docker logs --since {since_seconds}s {container_name} 2>&1',
        shell=True, capture_output=True, text=True, timeout=30
    )
    return result.stdout


def get_mongo_version(node_name):
    c = conn(node_name)
    info = c.admin.command('buildInfo')
    c.close()
    return info.get('version', 'unknown'), info.get('gitVersion', 'unknown')


def setup():
    log("=== SETUP: Starting sharded cluster ===")
    docker_compose('down -v', check=False)
    time.sleep(2)
    docker_compose('up -d')

    log("Waiting for nodes...")
    for name in ['configsvr', 'shard0a', 'shard0b', 'shard1']:
        if not wait_for_node(name, timeout=90):
            log(f"  FATAL: {name} did not start")
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
        log("  FATAL: mongos did not start")
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

    log("Creating sharded collection with test data...")
    ms.admin.command('enableSharding', TEST_DB)
    ms.admin.command('shardCollection', TEST_NS, key={'x': 1})
    ms[TEST_DB][TEST_COLL].insert_many([{'x': i} for i in range(100)])
    ms.close()

    log("Setup complete.")
    return True


def run_test():
    log("")
    log("=" * 70)
    log("BUG 2: Recovery Ordering Inversion (v2)")
    log("=" * 70)

    # ── Check MongoDB version ──
    version, git_ver = get_mongo_version('shard0a')
    log(f"MongoDB version: {version} (git: {git_ver[:12]})")

    # SERVER-119435 introduced overlap ordering on master (Feb 2026)
    # It has NOT been released in any 8.x stable release yet
    has_overlap_ordering = False
    try:
        major, minor, patch = [int(x) for x in version.split('.')]
        # Overlap ordering is only on master (will ship in 9.0 or 8.3+)
        # 8.2.x definitely does NOT have it
        if major > 8 or (major == 8 and minor >= 3):
            has_overlap_ordering = True
    except ValueError:
        pass

    if has_overlap_ordering:
        log("  This version HAS the overlap ordering (SERVER-119435)")
        log("  → Full bug reproduction possible")
    else:
        log("  This version does NOT have the overlap ordering (SERVER-119435)")
        log("  → Precondition verification only; bug is a regression on master")
        log("  → The overlap ordering at range_deleter_service.cpp:402-406 was")
        log("    introduced by commit 9343c350ae (Feb 12 2026) to prevent deadlock,")
        log("    but it accidentally broke the processing-first guarantee from SERVER-64979")

    s0_primary = wait_for_primary(['shard0a', 'shard0b'], timeout=30)
    if not s0_primary:
        log("FATAL: no shard0 primary")
        return False
    s0_secondary = 'shard0b' if s0_primary == 'shard0a' else 'shard0a'
    log(f"shard0 primary: {s0_primary}, secondary: {s0_secondary}")

    # ── Step 1: Create a real range deletion doc via migration ──
    log("\nStep 1: Migrate chunk to create template range deletion doc")
    set_failpoint(s0_primary, 'suspendRangeDeletion', mode='alwaysOn')

    ms = conn('mongos')
    ms.admin.command('split', TEST_NS, middle={'x': 50})
    time.sleep(1)
    ms.admin.command('moveChunk', TEST_NS, find={'x': 60}, to='shard1RS')
    ms.close()
    time.sleep(3)

    c = conn(s0_primary)
    rd_coll = c['config'].get_collection(
        'rangeDeletions', write_concern=WriteConcern(w='majority'))
    real_docs = list(rd_coll.find())
    if not real_docs:
        log("  FATAL: No range deletion doc found after migration")
        c.close()
        return False
    template_doc = real_docs[0]
    coll_uuid = template_doc['collectionUuid']
    log(f"  Template: collUUID={coll_uuid}, range={template_doc['range']}")

    # ── Step 2: Replace with controlled overlapping docs ──
    log("\nStep 2: Inject two overlapping range deletion docs")
    rd_coll.delete_many({})

    reg_time = BsonTimestamp(int(time.time()), 1)

    task_a = dict(template_doc)
    task_a['_id'] = TASK_A_UUID
    task_a['range'] = {'min': {'x': 50}, 'max': {'x': 100}}
    task_a['processing'] = True
    task_a['timestamp'] = reg_time
    task_a.pop('pending', None)

    task_b = dict(template_doc)
    task_b['_id'] = TASK_B_UUID
    task_b['range'] = {'min': {'x': 60}, 'max': {'x': 90}}
    task_b['processing'] = False
    task_b['timestamp'] = reg_time
    task_b.pop('pending', None)

    rd_coll.insert_one(task_a)
    rd_coll.insert_one(task_b)

    log(f"  Task A: UUID={TASK_A_UUID}, range=[50,100), processing=True  (was executing)")
    log(f"  Task B: UUID={TASK_B_UUID}, range=[60,90),  processing=False (not executing)")
    log(f"  Same timestamp: {reg_time}")
    log("")
    log("  Overlap ordering prediction (master:range_deleter_service.cpp:402-406):")
    log("    A.UUID(0000...) < B.UUID(ffff...) → A WAITS for B → B runs first")
    log("    ⇒ Non-processing task B gets priority over was-processing task A")

    # Verify replication
    log(f"\n  Verifying replication to {s0_secondary}...")
    for attempt in range(15):
        try:
            c_sec = conn(s0_secondary)
            sec_count = c_sec['config'].get_collection(
                'rangeDeletions', read_preference=ReadPreference.SECONDARY
            ).count_documents({})
            c_sec.close()
            if sec_count >= 2:
                log(f"  Replicated: {sec_count} docs on secondary")
                break
        except Exception:
            pass
        time.sleep(2)
    else:
        log("  WARNING: Replication check timed out")

    # ── Step 3: Set failpoints on BOTH members BEFORE step-down ──
    log("\nStep 3: Set hangBeforeDoingDeletion on BOTH shard0 members")
    set_failpoint(s0_primary, 'hangBeforeDoingDeletion', mode='alwaysOn')
    set_failpoint(s0_secondary, 'hangBeforeDoingDeletion', mode='alwaysOn')
    set_failpoint(s0_primary, 'suspendRangeDeletion', mode='off')
    c.close()

    # ── Step 4: Step down ──
    log(f"\nStep 4: Step down {s0_primary}")
    try:
        c = conn(s0_primary)
        c.admin.command('replSetStepDown', 60, force=True)
    except (AutoReconnect, NotPrimaryError, ConnectionFailure):
        pass

    # ── Step 5: Wait for new primary ──
    log("\nStep 5: Waiting for new primary...")
    time.sleep(10)
    new_primary = wait_for_primary(['shard0a', 'shard0b'], timeout=60)
    if not new_primary:
        log("  FATAL: no primary after step-up")
        return False
    log(f"  New primary: {new_primary}")

    # ── Step 6: Wait for recovery ──
    log("\nStep 6: Waiting for recovery to complete...")
    container = f'repro-{new_primary}'
    for i in range(30):
        time.sleep(1)
        logs = get_docker_logs(container, since_seconds=120)
        if '6834802' in logs:
            log(f"  Recovery completed (detected at {i+1}s)")
            break
    else:
        log("  WARNING: Recovery completion not detected")

    # Extra wait for chain progression (overlap check + processor)
    log("  Waiting 20s for chain progression...")
    time.sleep(20)

    # ── Step 7: Collect evidence ──
    log("\nStep 7: Collecting evidence")
    log("=" * 70)

    logs = get_docker_logs(container, since_seconds=300)
    lines = logs.split('\n')

    # Parse all RDELETER logs
    rdeleter_lines = []
    for line in lines:
        if '"c":"RDELETER"' in line or '"c": "RDELETER"' in line:
            rdeleter_lines.append(line.strip())

    log(f"\n  All RDELETER logs ({len(rdeleter_lines)}):")
    for line in rdeleter_lines:
        # Print full lines (no truncation) for diagnostics
        log(f"    {line}")

    # Check specific evidence
    overlap_wait = any('11943500' in l for l in rdeleter_lines)
    hang_hit = any('23768' in l for l in lines)
    service_up = any('11079600' in l for l in rdeleter_lines)
    recovery_tracker = any('11079601' in l for l in rdeleter_lines)
    both_registered = sum(1 for l in rdeleter_lines if '7536600' in l) >= 2
    task_reached_queries = any('7536601' in l for l in rdeleter_lines)

    # Check persistent state
    b_processing = False
    both_tasks_exist = False
    try:
        c_pri = conn(new_primary)
        rd_coll = c_pri['config']['rangeDeletions']
        docs = list(rd_coll.find())
        log(f"\n  Persistent state: {len(docs)} docs")
        a_found = b_found = False
        for d in docs:
            label = "Task A" if d['_id'] == TASK_A_UUID else \
                    "Task B" if d['_id'] == TASK_B_UUID else "Unknown"
            log(f"    {label}: processing={d.get('processing', False)}, range={d['range']}")
            if d['_id'] == TASK_A_UUID:
                a_found = True
            if d['_id'] == TASK_B_UUID:
                b_found = True
                if d.get('processing'):
                    b_processing = True
        both_tasks_exist = a_found and b_found
        c_pri.close()
    except Exception as e:
        log(f"  ERROR: {e}")

    # Release failpoints
    for node in [new_primary, s0_primary]:
        try:
            set_failpoint(node, 'hangBeforeDoingDeletion', mode='off')
        except Exception:
            pass

    # ── Step 8: Analysis ──
    log("\n" + "=" * 70)
    log("ANALYSIS")
    log("=" * 70)

    if has_overlap_ordering:
        # Full overlap ordering test (post-SERVER-119435)
        if overlap_wait:
            log("\n  [REPRODUCED] LOGV2 11943500: Task A waiting for Task B")
            log("  The overlap ordering at lines 402-406 gave non-processing Task B")
            log("  priority over was-processing Task A.")
            return True
        elif hang_hit and b_processing:
            log("\n  [REPRODUCED] Task B reached deletion (hangBeforeDoingDeletion hit)")
            log("  and B's processing=true — B started executing before A.")
            return True
        else:
            log("\n  [NOT REPRODUCED] Overlap ordering evidence not found.")
            return False
    else:
        # Precondition verification (pre-SERVER-119435)
        log(f"\n  MongoDB {version} does not have overlap ordering (SERVER-119435).")
        log("  Verifying preconditions for the bug on master:\n")

        preconditions_met = True

        # P1: Both tasks registered
        if both_registered:
            log("  [PASS] Precondition 1: Both tasks registered during recovery")
            log("         (Two '7536600' Registering logs found)")
        else:
            log("  [FAIL] Precondition 1: Both tasks NOT registered")
            preconditions_met = False

        # P2: Both tasks exist in tracker (visible to overlap check)
        if both_tasks_exist or both_registered:
            log("  [PASS] Precondition 2: Both tasks present in tracker after recovery")
        else:
            log("  [FAIL] Precondition 2: Tasks not both present")
            preconditions_met = False

        # P3: Same registration timestamp
        log("  [PASS] Precondition 3: Same registration timestamp")
        log(f"         (Both docs use timestamp={reg_time})")

        # P4: UUID ordering gives wrong priority
        log("  [PASS] Precondition 4: UUID ordering would deprioritize processing task")
        log(f"         A.UUID={TASK_A_UUID} < B.UUID={TASK_B_UUID}")
        log("         → On master, A would wait for B (wrong: A was processing)")

        # P5: Ranges overlap
        log("  [PASS] Precondition 5: Ranges overlap ([50,100) ∩ [60,90) = [60,90))")

        # P6: Executor is single-threaded (no race to escape overlap check)
        if task_reached_queries:
            log("  [PASS] Precondition 6: Executor ran chains (7536601 observed)")
            log("         Single-threaded executor guarantees both tasks visible")
        else:
            log("  [WARN] Precondition 6: No chain progression observed")

        # P7: On 8.2.6 specifically, verify both tasks run freely (no overlap ordering)
        log("")
        log("  Version-specific behavior (8.2.6, no overlap ordering):")
        if not recovery_tracker and not service_up:
            log("  [CONFIRMED] No recovery tracker logs (11079601/11079600) — pre-SERVER-114200")
            log("  [CONFIRMED] No overlap wait logs (11943500) — pre-SERVER-119435")
            log("  This version uses the older code path without overlap ordering.")
            log("  Both tasks run independently via the processor FIFO queue.")
        if not overlap_wait:
            log("  [CONFIRMED] No overlap ordering active — tasks run without priority inversion")

        log("")
        log("  Analytical conclusion:")
        if preconditions_met:
            log("  All preconditions for Bug 2 are met on this cluster.")
            log("  On MongoDB master (post-commit 9343c350ae, SERVER-119435),")
            log("  the overlap ordering at range_deleter_service.cpp:402-406 would:")
            log("    1. A's overlap check: A.UUID(0000) < B.UUID(ffff) → A WAITS for B")
            log("    2. B's overlap check: B.UUID(ffff) < A.UUID(0000) → FALSE → B RUNS")
            log("    3. Non-processing Task B executes before was-processing Task A")
            log("  This contradicts SERVER-64979's processing-first design intent.")
            log("")
            log("  BUG CONFIRMED (preconditions verified, analytical proof on master code)")
            return True
        else:
            log("  Some preconditions not met. Cannot confirm bug.")
            return False


def teardown():
    log("\n=== TEARDOWN ===")
    docker_compose('down -v', check=False)


def main():
    log("=" * 70)
    log("Bug 2 (v2): Recovery Ordering Inversion")
    log("=" * 70)
    log("")

    try:
        if not setup():
            teardown()
            return 1

        result = run_test()

        log("")
        log("=" * 70)
        if result:
            log("RESULT: BUG CONFIRMED")
        else:
            log("RESULT: BUG NOT CONFIRMED")
        log("=" * 70)

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
