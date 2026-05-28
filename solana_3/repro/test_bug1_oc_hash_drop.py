#!/usr/bin/env python3
"""
Bug 1 (MC-D2) supporting verification: OC notification drops voted hash.

Known/historical: matches anza-xyz/agave#12307 (open, "community" label).
This script does NOT itself reproduce the bug end-to-end — that would require
a multi-validator cluster with a duplicate-slot scenario. Instead, it
structurally verifies that the buggy code pattern remains present in the
current agave source:

  (A) `BankNotification::OptimisticallyConfirmed` enum variant carries
      only a `Slot`, not a `(Slot, Hash)` pair.
  (B) The RPC handler at `process_notification` fetches the bank with
      `bank_forks.read().unwrap().get(slot)` and does NOT verify
      `bank.hash() == cluster_oc_hash` before promoting.
  (C) Contrast: the duplicate-confirmed slot sender at
      `cluster_info_vote_listener.rs:727` DOES preserve `(slot, hash)`,
      proving the hash-drop on the OC notification path is asymmetric
      (and therefore not a "we don't need hash anywhere" design choice).

A duplicate-slot scenario reaching the buggy path would produce a state
where `rpc_oc_view[v][slot] != cluster_oc_hash`. This script reaches
that conclusion via structural verification rather than runtime
reproduction. The upstream #12307 ticket serves as community
confirmation of the same bug.
"""
import re
import sys
from pathlib import Path

AGAVE = Path("/home/ubuntu/Specula/case-studies/solana_3/artifact/agave")
TRACKER = AGAVE / "rpc/src/optimistically_confirmed_bank_tracker.rs"
VOTE_LISTENER = AGAVE / "core/src/cluster_info_vote_listener.rs"


def section(title):
    print(f"\n=== {title} ===")


def must(cond, msg):
    status = "OK" if cond else "FAIL"
    print(f"  [{status}] {msg}")
    return cond


def main():
    failures = 0

    section("(A) BankNotification::OptimisticallyConfirmed enum variant")
    src = TRACKER.read_text()
    # Find the enum definition
    m = re.search(r"pub enum BankNotification \{[^}]+\}", src, re.DOTALL)
    if not m:
        print("  [FAIL] could not locate BankNotification enum")
        return 1
    enum_body = m.group(0)
    print("  Enum definition found:")
    for line in enum_body.splitlines():
        print(f"    {line}")
    has_slot_only = re.search(r"OptimisticallyConfirmed\(Slot\)\s*,", enum_body) is not None
    has_slot_and_hash = re.search(r"OptimisticallyConfirmed\(Slot\s*,\s*Hash\)", enum_body) is not None
    if not must(has_slot_only, "variant is `OptimisticallyConfirmed(Slot)` — hash NOT in the type"):
        failures += 1
    if not must(not has_slot_and_hash, "variant is NOT `OptimisticallyConfirmed(Slot, Hash)` (hash genuinely absent)"):
        failures += 1

    section("(B) RPC handler in process_notification for OC notification")
    # Locate the process_notification function, then within it the OC arm.
    # process_notification takes a tuple-destructured first argument; its
    # signature spans multiple lines and includes nested parens. Use DOTALL
    # and a non-greedy match up to the function's opening brace.
    fn_match = re.search(
        r"fn process_notification\(.*?\)\s*(?:->\s*\w+\s*)?\{",
        src,
        re.DOTALL,
    )
    if not fn_match:
        print("  [FAIL] could not locate fn process_notification(...)")
        return 1
    fn_start = fn_match.end()
    # Walk braces to find end of function
    depth = 1
    i = fn_start
    while i < len(src) and depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    fn_body = src[fn_start : i - 1]
    # Find the OC arm within the function body
    arm_match = re.search(
        r"BankNotification::OptimisticallyConfirmed\(slot\)\s*=>\s*\{",
        fn_body,
    )
    if not arm_match:
        print("  [FAIL] could not locate OC arm in process_notification")
        return 1
    arm_start = arm_match.end()
    depth = 1
    i = arm_start
    while i < len(fn_body) and depth > 0:
        if fn_body[i] == "{":
            depth += 1
        elif fn_body[i] == "}":
            depth -= 1
        i += 1
    handler_body = fn_body[arm_start : i - 1]
    print("  Handler body excerpt (first ~20 lines):")
    for line in handler_body.splitlines()[:20]:
        print(f"    {line}")
    fetches_by_slot = (
        "bank_forks.read().unwrap().get(slot)" in handler_body
        or re.search(r"bank_forks\.read\(\)\.unwrap\(\)\.get\(\s*slot\s*\)", handler_body) is not None
    )
    no_hash_compare = "bank.hash()" not in handler_body and "cluster_oc_hash" not in handler_body
    if not must(fetches_by_slot, "handler calls `bank_forks.read().unwrap().get(slot)` — fetches by slot"):
        failures += 1
    if not must(no_hash_compare, "handler does NOT compare `bank.hash()` against any cluster-OC hash"):
        failures += 1

    section("(C) Contrast: duplicate_confirmed_slot_sender preserves (slot, hash)")
    vl_src = VOTE_LISTENER.read_text()
    dup_send = re.search(
        r"duplicate_confirmed_slot_sender[^;]*?send\([^;]*?last_vote_slot[^;]*?last_vote_hash[^;]*?\)",
        vl_src,
        re.DOTALL,
    )
    if not must(dup_send is not None, "duplicate_confirmed_slot_sender.send carries both (slot, hash)"):
        failures += 1
    else:
        # Show line(s)
        excerpt = dup_send.group(0).strip().replace("\n", " ")
        print(f"    Excerpt: {excerpt[:200]}")

    oc_send = re.search(
        r"BankNotification::OptimisticallyConfirmed\(\s*([A-Za-z_][\w]*)\s*\)",
        vl_src,
    )
    if oc_send:
        arg = oc_send.group(1).strip()
        carry_hash = "hash" in arg.lower()
        print(f"  OC notification constructor argument: `{arg}`")
        if not must(not carry_hash, "OC notification constructor argument does NOT include any hash"):
            failures += 1
    else:
        print("  [FAIL] could not locate OC notification constructor call")
        failures += 1

    section("Summary")
    if failures == 0:
        print("  ALL CHECKS PASSED — bug pattern (OC hash-drop) confirmed present in current code.")
        print("  Upstream evidence: https://github.com/anza-xyz/agave/issues/12307 (open)")
        return 0
    else:
        print(f"  {failures} check(s) failed. Either the bug is no longer present, or the source layout changed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
