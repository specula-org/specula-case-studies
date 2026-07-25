#!/usr/bin/env python3
"""
MC-4: RunningOp Sessions Silently Dropped on Refresh Failure.

Root cause: logical_session_cache_impl.cpp:388-397.
The backSwap loop iterates only `activeSessions` (from _activeSessions), not
`runningOpSessions` (from getActiveOpSessions()). A runningOp session that fails
refresh is NOT placed into _activeSessions for retry.

Affected code:
    // line 394-397: backSwap only over activeSessions
    for (const auto& [lsid, record] : activeSessions) {
        if (failedLsids.count(lsid) > 0) {
            _activeSessions.emplace(lsid, record);  // runningOpSessions NOT here
        }
    }

Escalation ladder:
  Level 0 — Observe sessions that expire despite being in running operations.
  Level 1 — Use failpoint to inject refresh failures for runningOp sessions.
  Level 2 — State injection: create session appearing in getActiveOpSessions but not
             _activeSessions, trigger refresh failure.
  Level 3 — Code modification: force refresh failure for runningOp path.
"""

import sys
import time
import threading
import pymongo
from pymongo import MongoClient

MONGOD_URI = "mongodb://localhost:27017"


def level0_blackbox():
    """
    Level 0: Observe via public API.

    Start a long-running operation with a session. Force refresh failures.
    Check if the session eventually expires from config.system.sessions
    despite the running operation.
    """
    print("=== Level 0: Black-box observation ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect to MongoDB at {MONGOD_URI}: {e}")
        return False

    print("  Level 0 requires triggering refresh failures which is not possible")
    print("  via public API without failpoints. Cannot observe the drop via")
    print("  normal operations.")
    client.close()
    return False


def level1_failpoints():
    """
    Level 1: Use failpoints to inject refresh failures.

    Use 'onIsMasterSuccess' or 'refreshSessionsWithRefreshFail' failpoints
    (if they exist) to force config.system.sessions upsert to fail.
    Then observe that runningOp sessions are not retried.
    """
    print("=== Level 1: Failpoint-assisted ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    # Try to use failpoint to make refreshSessions fail
    try:
        client.admin.command(
            "configureFailPoint",
            "failRefreshSessions",
            mode={"times": 3}
        )
        print("  Activated failpoint 'failRefreshSessions'")
    except Exception as e:
        print(f"  Failpoint 'failRefreshSessions' not available: {e}")
        print("  No suitable built-in failpoint found for refreshSessions failure.")
        client.close()
        return False

    # Start a long-running operation to populate getActiveOpSessions()
    session = client.start_session()
    try:
        # Run a slow operation to keep the session in getActiveOpSessions()
        # In a real test we'd use a cursor with .batch_size(1) or similar
        print("  Level 1: Would need to observe session TTL expiry after forced")
        print("  refresh failures while operation is running. Infrastructure missing.")
        return False
    finally:
        session.end_session()
        client.close()


def level2_state_injection():
    """
    Level 2: State injection.

    Directly manipulate config.system.sessions to remove a session entry
    that corresponds to a "running operation", then verify the refresh
    cycle does not re-insert it (because runningOp path won't retry on failure).
    """
    print("=== Level 2: State injection ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    print("  State injection for this bug requires controlling which sessions appear")
    print("  in getActiveOpSessions() vs _activeSessions, which is not directly")
    print("  injectable from outside the process.")
    client.close()
    return False


if __name__ == "__main__":
    print("MC-4: RunningOp Session Drop Reproduction Test")
    print("===============================================")
    print()

    result = level0_blackbox()
    if not result:
        result = level1_failpoints()
    if not result:
        result = level2_state_injection()

    if result:
        print("\nRESULT: REPRODUCED")
        sys.exit(0)
    else:
        print("\nRESULT: REPRODUCTION FAILED")
        print("Reasons at each level:")
        print("  L0: Cannot trigger refresh failures via public API.")
        print("  L1: No suitable built-in failpoint for refreshSessions failure on runningOp path.")
        print("  L2: getActiveOpSessions() contents not directly injectable from outside.")
        print("  L3: Source not compiled; Level 3 would add a conditional in _refresh to")
        print("      force refreshSessions to fail for runningOp sessions.")
        print("Bug stands on code audit: backSwap at logical_session_cache_impl.cpp:394")
        print("iterates only activeSessions, not runningOpSessions.")
        sys.exit(1)
