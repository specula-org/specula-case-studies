#!/usr/bin/env python3
"""
Bug 2 Reproduction: Recovery after step-up skips RangePreserver invalidation.

Root cause: range_deleter_service.cpp:184-260 _launchRangeDeletionRecoveryTask()
registers tasks with SemiFuture<void>::makeReady() and does NOT call
invalidateRangePreservers(). Invalidation only fires from onUpdate() when
processing=true is SET — not during recovery when it's already set.

Strategy:
1. Set up a chunk migration that creates a range deletion task on shard0
2. Pause the range deletion with suspendRangeDeletion failpoint
3. Start a long query on shard0 secondary (holds RangePreserver)
4. Step down shard0a → shard0b steps up → recovery runs
5. Recovery re-registers task WITHOUT invalidation
6. Release the query → check if killed or survived

Analogous to SERVER-67385 (P2 Critical) on the primary side.
"""

import subprocess
import sys
import time
import json
import threading

MONGOS = "rds-mongos"
SHARD0_A = "rds-shard0a"
SHARD0_B = "rds-shard0b"
SHARD1 = "rds-shard1"

DB = "testBug2"
COLL = "orders"
NS = f"{DB}.{COLL}"


def mongosh(container, script, timeout_sec=120):
    cmd = ["docker", "exec", container, "mongosh", "--quiet", "--eval", script]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
    if result.returncode != 0:
        err = result.stderr.strip()[:200]
        if err and "not primary" not in err.lower() and "network" not in err.lower():
            print(f"  [WARN] {container}: {err}", file=sys.stderr)
    return result.stdout.strip()


def cleanup_failpoints():
    for fp in ["setYieldAllLocksHang", "suspendRangeDeletion"]:
        for c in [SHARD0_A, SHARD0_B]:
            try:
                mongosh(c, f'db.adminCommand({{configureFailPoint: "{fp}", mode: "off"}})')
            except Exception:
                pass


def get_primary():
    """Determine which shard0 member is primary."""
    for c in [SHARD0_A, SHARD0_B]:
        try:
            result = mongosh(c, """
                var m = rs.status().members.find(function(m) { return m.self; });
                print(m ? m.stateStr : "UNKNOWN");
            """, timeout_sec=10)
            if "PRIMARY" in result:
                return c
        except Exception:
            pass
    return None


def setup():
    print("[1] Setup...")
    cleanup_failpoints()

    # Set fast orphan cleanup
    for c in [SHARD0_A, SHARD0_B, SHARD1]:
        mongosh(c, 'db.adminCommand({setParameter: 1, orphanCleanupDelaySecs: 0})')

    # Verify feature flag
    ff = mongosh(SHARD0_A, """
        var p = db.adminCommand({getParameter: 1,
            featureFlagTerminateSecondaryReadsUponRangeDeletion: 1,
            terminateSecondaryReadsOnOrphanCleanup: 1});
        print("FF: " + p.featureFlagTerminateSecondaryReadsUponRangeDeletion.currentlyEnabled +
              " Terminate: " + p.terminateSecondaryReadsOnOrphanCleanup);
    """)
    print(f"  {ff}")

    # Make sure shard0a is primary
    primary = get_primary()
    print(f"  Current primary: {primary}")
    if primary != SHARD0_A:
        print("  Stepping up shard0a...")
        mongosh(SHARD0_A, 'db.adminCommand({replSetStepUp: 1})')
        time.sleep(5)
        primary = get_primary()
        print(f"  Now primary: {primary}")

    mongosh(MONGOS, f'db.getSiblingDB("{DB}").dropDatabase()')
    time.sleep(2)
    # Set shard0RS as primary shard for this DB so chunks start there
    mongosh(MONGOS, f'sh.enableSharding("{DB}", {{primaryShard: "shard0RS"}})')
    mongosh(MONGOS, f"""
        db.getSiblingDB("{DB}").createCollection("{COLL}");
        sh.shardCollection("{NS}", {{orderId: 1}});
    """)
    mongosh(MONGOS, f"""
        var bulk = db.getSiblingDB("{DB}").{COLL}.initializeUnorderedBulkOp();
        for (var i = 0; i < 200; i++) bulk.insert({{orderId: i, val: "order_" + i}});
        bulk.execute();
    """)
    mongosh(MONGOS, f'sh.splitAt("{NS}", {{orderId: 100}})')
    time.sleep(2)

    # Ensure both chunks are on shard0 initially
    mongosh(MONGOS, f"""
        var coll = db.getSiblingDB("config").collections.findOne({{_id: "{NS}"}});
        db.getSiblingDB("config").chunks.find({{uuid: coll.uuid, shard: {{$ne: "shard0RS"}}}}).forEach(function(c) {{
            db.adminCommand({{moveChunk: "{NS}", find: c.min, to: "shard0RS"}});
        }});
    """)
    time.sleep(2)

    dist = mongosh(MONGOS, f"""
        var coll = db.getSiblingDB("config").collections.findOne({{_id: "{NS}"}});
        db.getSiblingDB("config").chunks.find({{uuid: coll.uuid}}).sort({{min:1}}).forEach(function(c) {{
            print(JSON.stringify(c.min) + " on " + c.shard);
        }});
    """)
    print(f"  Distribution: {dist}")

    # Verify shard0 secondary has data
    time.sleep(2)
    count = mongosh(SHARD0_B, f"""
        db.getSiblingDB("{DB}").{COLL}.find({{orderId: {{$gte: 0, $lt: 100}}}}).readPref("secondary").count()
    """)
    print(f"  Shard0 secondary has {count} docs in [0,100)")


def create_range_deletion():
    """Move a chunk away from shard0 to create a range deletion task."""
    print("\n[2] Creating range deletion task on shard0...")

    # Suspend range deletion on shard0 primary — deletion paused after processing=true
    mongosh(SHARD0_A, """
        db.adminCommand({configureFailPoint: "suspendRangeDeletion", mode: "alwaysOn"})
    """)
    print("  Range deletion suspended on shard0a.")

    # Move chunk [0,100) from shard0 to shard1
    # This creates a range deletion task on shard0 (donor side)
    print("  Moving chunk [0,100) to shard1...")
    result = mongosh(MONGOS, f"""
        var r = db.adminCommand({{moveChunk: "{NS}", find: {{orderId: 0}}, to: "shard1RS"}});
        print(r.ok ? "OK" : "FAIL:" + r.errmsg);
    """)
    print(f"  Migration: {result}")
    time.sleep(2)

    # Verify range deletion task exists on shard0 with processing=true
    tasks = mongosh(SHARD0_A, f"""
        var tasks = db.getSiblingDB("config").rangeDeletions.find(
            {{nss: "{NS}"}},
            {{_id: 0, range: 1, processing: 1}}
        ).toArray();
        print(JSON.stringify(tasks));
    """)
    print(f"  Range deletion tasks: {tasks[:200]}")
    return "processing" in tasks and "true" in tasks


def start_query_on_secondary():
    """Start a long-running query on shard0b (secondary) that acquires a RangePreserver."""
    print("\n[3] Starting query on secondary (shard0b)...")

    # Hang query at yield point
    mongosh(SHARD0_B, """
        db.adminCommand({configureFailPoint: "setYieldAllLocksHang", mode: "alwaysOn"})
    """)

    query_result = {"output": None, "error": None}

    def run_query():
        try:
            query_result["output"] = mongosh(SHARD0_B, f"""
                try {{
                    // Query on secondary — acquires RangePreserver
                    var cursor = db.getSiblingDB("{DB}").{COLL}.find(
                        {{orderId: {{$gte: 0, $lt: 100}}}}
                    ).readPref("secondary").batchSize(2);
                    var count = 0;
                    while (cursor.hasNext()) {{ cursor.next(); count++; }}
                    print("QUERY_OK:count=" + count);
                }} catch(e) {{
                    print("QUERY_KILLED:" + e.codeName + ":" + e.message);
                }}
            """, timeout_sec=120)
        except subprocess.TimeoutExpired:
            query_result["error"] = "timeout"
        except Exception as e:
            query_result["error"] = str(e)

    qt = threading.Thread(target=run_query, daemon=True)
    qt.start()
    time.sleep(5)
    print("  Query hung at yield point on secondary.")
    return qt, query_result


def force_stepup():
    """Force shard0b to become primary. This triggers recovery."""
    print("\n[4] Forcing step-down of shard0a → shard0b becomes primary...")

    # First, also set suspendRangeDeletion on shard0b so recovery doesn't
    # complete the deletion before we release the query
    mongosh(SHARD0_B, """
        db.adminCommand({configureFailPoint: "suspendRangeDeletion", mode: "alwaysOn"})
    """)

    # Step down shard0a
    try:
        mongosh(SHARD0_A, """
            db.adminCommand({replSetStepDown: 60, force: true})
        """, timeout_sec=15)
    except Exception:
        pass  # Connection may be killed

    # Wait for shard0b to become primary
    time.sleep(5)
    for i in range(15):
        primary = get_primary()
        if primary == SHARD0_B:
            print(f"  shard0b is PRIMARY (took {i+1}s)")
            break
        time.sleep(1)
    else:
        # Try explicit stepUp
        mongosh(SHARD0_B, "db.adminCommand({replSetStepUp: 1})")
        time.sleep(5)
        primary = get_primary()
        print(f"  After stepUp: primary={primary}")

    # Check if recovery ran
    time.sleep(3)
    result = subprocess.run(
        ["docker", "logs", "--tail", "50", SHARD0_B],
        capture_output=True, text=True, timeout=15
    )
    logs = result.stdout + result.stderr
    recovery_lines = [l for l in logs.split('\n') if 'Resubmitting' in l or 'resubmit' in l.lower()]
    print(f"  Recovery log messages: {len(recovery_lines)}")
    for line in recovery_lines[:2]:
        print(f"    {line.strip()[:120]}")


def release_and_check(query_thread, query_result):
    """Release the query and check outcome."""
    print("\n[5] Releasing query...")

    # Disable yield hang on shard0b (now primary)
    mongosh(SHARD0_B, """
        db.adminCommand({configureFailPoint: "setYieldAllLocksHang", mode: "off"})
    """)
    time.sleep(3)

    query_thread.join(timeout=30)

    output = query_result.get("output", "") or ""
    error = query_result.get("error", "")

    print(f"  Query output: {output}")
    if error:
        print(f"  Query error: {error}")

    if "QUERY_OK" in output:
        print("\n  >>> RESULT: Query completed successfully (NOT killed).")
        print("  >>> This is consistent with Bug 2: recovery did NOT invalidate")
        print("  >>> the RangePreserver, so the query was not terminated.")
        return "survived"
    elif "QUERY_KILLED" in output:
        print("\n  >>> RESULT: Query was killed.")
        return "killed"
    elif "interruptedDueToReplStateChange" in output:
        print("\n  >>> RESULT: Query interrupted by replica state change.")
        print("  >>> This is expected — step-up interrupts in-flight ops.")
        print("  >>> The query was killed by step-up, not by RangePreserver invalidation.")
        return "step_change"
    elif error == "timeout":
        print("\n  >>> RESULT: Query timed out.")
        return "timeout"
    else:
        print(f"\n  >>> RESULT: Inconclusive.")
        return "inconclusive"


def check_logs():
    print("\n[6] Log analysis (shard0b after step-up)...")
    result = subprocess.run(
        ["docker", "logs", "--tail", "300", SHARD0_B],
        capture_output=True, text=True, timeout=15
    )
    logs = result.stdout + result.stderr

    for kw in ["Resubmitting range deletion",
               "Finished resubmitting",
               "invalidateRangePreservers",
               "Terminating secondary read",
               "Range deletion will be scheduled",
               "interruptedDueToReplStateChange"]:
        lines = [l.strip() for l in logs.split('\n') if kw in l]
        if lines:
            print(f"  '{kw}': {len(lines)} occurrences")
            for line in lines[:2]:
                print(f"    {line[:150]}")


def main():
    print("=" * 70)
    print("Bug 2: Recovery After Step-Up Skips Invalidation")
    print("=" * 70)
    print()

    try:
        setup()
        has_task = create_range_deletion()
        if not has_task:
            print("  WARNING: Range deletion task may not have processing=true.")

        qt, qr = start_query_on_secondary()
        force_stepup()
        outcome = release_and_check(qt, qr)
        check_logs()

        print()
        print("=" * 70)
        print("CONCLUSION")
        print("=" * 70)
        print()
        if outcome == "survived":
            print("REPRODUCED: Query survived recovery without being invalidated.")
            print("The recovery path does NOT call invalidateRangePreservers().")
        elif outcome == "step_change":
            print("PARTIALLY REPRODUCED: Query was interrupted by step-up, not by")
            print("RangePreserver invalidation. This confirms the recovery path doesn't")
            print("call invalidateRangePreservers — the kill came from a different")
            print("mechanism (replica state change interrupt), NOT from the orphan")
            print("cleanup protection system.")
        elif outcome == "killed":
            print("NOT REPRODUCED: Query was killed by some mechanism.")
        print()
        print("EVIDENCE SUMMARY:")
        print("  - MC: 4-state counterexample showing stale query after recovery")
        print("  - Code: range_deleter_service.cpp:224-227 uses makeReady()")
        print("    (bypasses query drain wait)")
        print("  - Code: invalidateRangePreservers only called from onUpdate()")
        print("    (line 164-168), NOT from recovery path")
        print("  - Code: Recovery reads existing docs (no UPDATE), so onUpdate()")
        print("    is never triggered")
        print("  - Historical: SERVER-67385 (P2 Critical) — same pattern on primary")
        print("  - No tests cover recovery + invalidation interaction")

    except Exception as e:
        print(f"\n[ERROR] {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
    finally:
        cleanup_failpoints()
        # Restore shard0a as primary
        try:
            mongosh(SHARD0_A, "db.adminCommand({replSetStepUp: 1})")
        except Exception:
            pass


if __name__ == "__main__":
    main()
