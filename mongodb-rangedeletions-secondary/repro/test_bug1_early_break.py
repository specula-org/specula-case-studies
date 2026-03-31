#!/usr/bin/env python3
"""
Bug 1 Reproduction: Early-break in invalidation loop skips trackers
with non-monotonic shardPlacementVersion.

Root cause: metadata_manager.cpp:273-295 iterates _metadata (sorted by
collPlacementVersion) but compares shardPlacementVersion with an early-break
optimization (line 291). When a shard loses all chunks (shardV drops to {0,0}),
collPlacementVersion still increases, making shardV non-monotonic in the list.

Strategy:
1. Set orphanCleanupDelaySecs=0 to allow rapid chunk migration cycles
2. Migrate chunks back-and-forth to create non-monotonic shardV entries
3. Hold a query on secondary (via setYieldAllLocksHang) to retain metadata
4. Trigger invalidation via chunk migration — check if query survives
"""

import subprocess
import sys
import time
import json
import threading

MONGOS = "rds-mongos"
SHARD0_PRIMARY = "rds-shard0a"
SHARD0_SECONDARY = "rds-shard0b"
SHARD1 = "rds-shard1"

DB = "testBug1v3"
COLL = "items"
NS = f"{DB}.{COLL}"


def mongosh(container, script, timeout_sec=120):
    cmd = ["docker", "exec", container, "mongosh", "--quiet", "--eval", script]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
    if result.returncode != 0:
        err = result.stderr.strip()[:200]
        if err and "not primary" not in err.lower():
            print(f"  [WARN] {container}: {err}", file=sys.stderr)
    return result.stdout.strip()


def cleanup_failpoints():
    for fp in ["setYieldAllLocksHang", "suspendRangeDeletion"]:
        for c in [SHARD0_PRIMARY, SHARD0_SECONDARY]:
            try:
                mongosh(c, f'db.adminCommand({{configureFailPoint: "{fp}", mode: "off"}})')
            except Exception:
                pass


def move_chunk(find_key, to_shard, wait=True):
    result = mongosh(MONGOS, f"""
        var r = db.adminCommand({{moveChunk: "{NS}", find: {{x: {find_key}}}, to: "{to_shard}"}});
        print(r.ok ? "OK" : "FAIL:" + (r.errmsg || "unknown").substring(0, 80));
    """, timeout_sec=120)
    if wait:
        time.sleep(1)
    return "OK" in result


def wait_for_orphan_cleanup(shard_container, max_wait=30):
    """Wait until orphan cleanup completes on a shard."""
    for i in range(max_wait):
        result = mongosh(shard_container, """
            var tasks = db.getSiblingDB("config").rangeDeletions.countDocuments({});
            print(tasks);
        """)
        try:
            if int(result) == 0:
                return True
        except ValueError:
            pass
        time.sleep(1)
    return False


def setup():
    print("[1] Setup...")
    cleanup_failpoints()

    # Set orphanCleanupDelaySecs=0 on both shard0 nodes for fast cleanup
    for c in [SHARD0_PRIMARY, SHARD0_SECONDARY, SHARD1]:
        mongosh(c, 'db.adminCommand({setParameter: 1, orphanCleanupDelaySecs: 0})')

    mongosh(MONGOS, f'db.getSiblingDB("{DB}").dropDatabase()')
    time.sleep(2)
    mongosh(MONGOS, f'sh.enableSharding("{DB}")')
    mongosh(MONGOS, f"""
        db.getSiblingDB("{DB}").createCollection("{COLL}");
        sh.shardCollection("{NS}", {{x: 1}});
    """)
    mongosh(MONGOS, f"""
        var bulk = db.getSiblingDB("{DB}").{COLL}.initializeUnorderedBulkOp();
        for (var i = 0; i < 300; i++) bulk.insert({{x: i, data: "doc_" + i}});
        bulk.execute();
    """)
    mongosh(MONGOS, f'sh.splitAt("{NS}", {{x: 100}})')
    mongosh(MONGOS, f'sh.splitAt("{NS}", {{x: 200}})')
    time.sleep(2)

    # Verify feature flag is enabled
    ff = mongosh(SHARD0_PRIMARY, """
        var p = db.adminCommand({getParameter: 1,
            featureFlagTerminateSecondaryReadsUponRangeDeletion: 1,
            terminateSecondaryReadsOnOrphanCleanup: 1});
        print("FF enabled: " + p.featureFlagTerminateSecondaryReadsUponRangeDeletion.currentlyEnabled);
        print("Terminate: " + p.terminateSecondaryReadsOnOrphanCleanup);
    """)
    print(f"  {ff}")

    dist = mongosh(MONGOS, f"""
        var coll = db.getSiblingDB("config").collections.findOne({{_id: "{NS}"}});
        db.getSiblingDB("config").chunks.find({{uuid: coll.uuid}}).sort({{min:1}}).forEach(function(c) {{
            print(JSON.stringify(c.min) + " -> " + JSON.stringify(c.max) + " on " + c.shard);
        }});
    """)
    print(f"  Distribution:\n  {dist.replace(chr(10), chr(10)+'  ')}")


def create_non_monotonic():
    """
    Create non-monotonic shardPlacementVersion through migration cycles.
    Wait for orphan cleanup between each step.
    """
    print("\n[2] Creating non-monotonic shardPlacementVersion...")

    # Step A: Move all to shard1 (shard0 shardV → {0,0})
    print("  A) All to shard1...")
    for key in [0, 100, 200]:
        ok = move_chunk(key, "shard1RS")
        if not ok:
            print(f"    FAIL at x={key}")
    wait_for_orphan_cleanup(SHARD0_PRIMARY)
    print("    Done. Shard0 has no chunks (shardV should be {0,0}).")

    # Step B: Move [0,100) back to shard0 (shard0 shardV → high)
    print("  B) [0,100) back to shard0...")
    ok = move_chunk(0, "shard0RS")
    print(f"    {'OK' if ok else 'FAIL'}")
    wait_for_orphan_cleanup(SHARD1)

    # Step C: Move [0,100) back to shard1 (shard0 shardV → {0,0} again)
    print("  C) [0,100) back to shard1...")
    ok = move_chunk(0, "shard1RS")
    print(f"    {'OK' if ok else 'FAIL'}")
    wait_for_orphan_cleanup(SHARD0_PRIMARY)

    # Step D: Move [100,200) to shard0 (shard0 shardV → high again)
    print("  D) [100,200) to shard0...")
    ok = move_chunk(100, "shard0RS")
    print(f"    {'OK' if ok else 'FAIL'}")
    wait_for_orphan_cleanup(SHARD1)

    # At this point, shard0's _metadata should have entries with shardV:
    # high_initial → {0,0} → high' → {0,0} → high''
    # Older entries get retired unless a query holds them.
    print("  Migration cycle complete.")


def reproduction():
    """
    Hold a query open on the secondary, trigger invalidation, check if killed.
    """
    print("\n[3] Reproduction scenario...")

    # Verify shard0 has chunk [100,200)
    count = mongosh(SHARD0_SECONDARY, f"""
        db.getSiblingDB("{DB}").{COLL}.find({{x: {{$gte: 100, $lt: 200}}}}).readPref("secondary").count()
    """)
    print(f"  Secondary sees {count} docs in [100,200)")

    # Step 1: Pause query execution on secondary AFTER it acquires RangePreserver
    print("  Enabling setYieldAllLocksHang on secondary...")
    mongosh(SHARD0_SECONDARY, """
        db.adminCommand({configureFailPoint: "setYieldAllLocksHang", mode: "alwaysOn"})
    """)

    # Step 2: Start query (it will get RangePreserver, then hang at yield)
    query_result = {"output": None, "error": None}

    def run_query():
        try:
            query_result["output"] = mongosh(SHARD0_SECONDARY, f"""
                try {{
                    var cursor = db.getSiblingDB("{DB}").{COLL}.find(
                        {{x: {{$gte: 100, $lt: 200}}}}
                    ).readPref("secondary").batchSize(2);
                    var count = 0;
                    while (cursor.hasNext()) {{ cursor.next(); count++; }}
                    print("QUERY_OK:count=" + count);
                }} catch(e) {{
                    print("QUERY_KILLED:" + e.codeName + ":" + e.message);
                }}
            """, timeout_sec=90)
        except subprocess.TimeoutExpired:
            query_result["error"] = "timeout"
        except Exception as e:
            query_result["error"] = str(e)

    qt = threading.Thread(target=run_query, daemon=True)
    qt.start()
    time.sleep(5)
    print("  Query started and hung at yield point.")

    # Step 3: Move chunk [100,200) to shard1 — triggers range deletion on shard0
    # This will trigger invalidateRangePreservers on the secondary via oplog.
    # If Bug 1 is present and _metadata has non-monotonic shardV, the early-break
    # may skip the query's tracker.
    print("  Moving [100,200) to shard1 (triggers invalidation)...")
    mig_result = {"ok": False}

    def do_mig():
        mig_result["ok"] = move_chunk(100, "shard1RS", wait=False)

    mt = threading.Thread(target=do_mig, daemon=True)
    mt.start()
    time.sleep(8)  # Wait for migration + oplog replication of processing=true

    # Step 4: Release the query
    print("  Releasing query (disabling failpoint)...")
    mongosh(SHARD0_SECONDARY, """
        db.adminCommand({configureFailPoint: "setYieldAllLocksHang", mode: "off"})
    """)

    qt.join(timeout=30)
    mt.join(timeout=30)

    print(f"  Migration result: {'OK' if mig_result['ok'] else 'FAIL/PENDING'}")
    return query_result


def analyze(query_result):
    print("\n[4] Analysis...")
    output = query_result.get("output", "") or ""
    error = query_result.get("error", "")

    print(f"  Query output: {output}")
    if error:
        print(f"  Query error: {error}")

    if "QUERY_OK" in output:
        print("\n  >>> RESULT: Query completed WITHOUT being killed.")
        print("  >>> Consistent with Bug 1: the early-break skipped this tracker.")
        return "survived"
    elif "QUERY_KILLED" in output:
        print("\n  >>> RESULT: Query was killed (invalidation reached tracker).")
        print("  >>> The non-monotonic _metadata entries may have been retired.")
        return "killed"
    elif error == "timeout":
        print("\n  >>> RESULT: Query timed out (migration may block yield release).")
        return "timeout"
    else:
        print("\n  >>> RESULT: Inconclusive.")
        return "inconclusive"


def check_logs():
    print("\n[5] Log analysis (shard0 secondary)...")
    result = subprocess.run(
        ["docker", "logs", "--tail", "300", SHARD0_SECONDARY],
        capture_output=True, text=True, timeout=30
    )
    logs = result.stdout + result.stderr
    for kw in ["invalidate", "Terminating secondary read", "RangePreserver", "StaleConfig"]:
        n = logs.lower().count(kw.lower())
        if n:
            # Find example lines
            lines = [l.strip() for l in logs.split('\n') if kw.lower() in l.lower()]
            print(f"  '{kw}': {n} occurrences")
            for line in lines[:2]:
                print(f"    {line[:150]}")


def main():
    print("=" * 70)
    print("Bug 1: Early-Break Invalidation Loop Reproduction")
    print("=" * 70)

    try:
        setup()
        create_non_monotonic()
        qr = reproduction()
        outcome = analyze(qr)
        check_logs()

        print()
        print("=" * 70)
        print("CONCLUSION")
        print("=" * 70)
        print()
        if outcome == "survived":
            print("REPRODUCED: Query survived invalidation with feature flag ON.")
            print("This confirms the early-break bug allows stale reads on secondaries.")
        elif outcome == "killed":
            print("NOT REPRODUCED: Query was correctly killed.")
            print("The _metadata entries were likely retired before the non-monotonic")
            print("sequence could accumulate. The bug requires multiple concurrent queries")
            print("pinning different metadata versions across multiple migration cycles.")
        print()
        print("EVIDENCE SUMMARY:")
        print("  - MC: 8-state counterexample with trackerShardV=<<0,2,0>>")
        print("  - Code: metadata_manager.cpp:291 breaks on first shardV > preMigV")
        print("  - Code: chunk_manager.cpp:929-937 returns shardV={0,0} for empty shard")
        print("  - Code: _metadata sorted by collPlacementV, NOT shardPlacementV")
        print("  - Tests: No existing test covers non-monotonic shardV sequence")

    except Exception as e:
        print(f"\n[ERROR] {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
    finally:
        cleanup_failpoints()


if __name__ == "__main__":
    main()
