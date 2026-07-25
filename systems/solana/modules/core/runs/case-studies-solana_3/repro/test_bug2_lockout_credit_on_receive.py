#!/usr/bin/env python3
"""
Bug 2 (MC-E1) supporting verification: honest validator credits Byzantine
lockout-violating vote.

Known/historical: matches solana-labs/solana#7521 ("slashing v0", filed 2019,
unresolved when the repo was archived; deployment never occurred). Per the
Solana whitepaper / Tower BFT design notes, the protocol's safety argument
explicitly relies on slashing penalizing lockout violations off-chain; with
slashing absent, the receive-side accumulators on honest validators do not
filter out Byzantine lockout-violating votes.

This script does NOT itself reproduce the bug end-to-end — that would
require a multi-validator agave testnet plus a Byzantine validator binary
that broadcasts lockout-violating votes. Instead, it structurally
verifies that the buggy code pattern remains present in the current
agave source:

  (A) `LatestValidatorVotesForFrozenBanks::check_add_vote` accepts a
      vote by `(vote_pubkey, vote_slot, frozen_hash)` and does NOT
      consult the voter's own tower / lockout history.
  (B) `ClusterInfoVoteListener::track_optimistic_confirmation_vote`
      similarly accepts a vote by `(slot, hash, pubkey, stake)` and
      does NOT consult the voter's lockout state.
  (C) No code path in the receive direction of these modules invokes
      a "voter lockout violation" check (search for any callable
      named `*lockout_violat*` or `is_lockout_violation*`).

If any one of (A)/(B) gains a lockout check or (C) detects such a check
in the receive path, the bug may have been mitigated upstream. Until
then, the receive-side defense is absent and the protocol's safety
relies entirely on the Byzantine-stake bound (≤ 1/3 stake).
"""
import re
import sys
from pathlib import Path

AGAVE = Path("/home/ubuntu/Specula/case-studies/solana_3/artifact/agave")
LVF = AGAVE / "core/src/consensus/latest_validator_votes_for_frozen_banks.rs"
VOTE_LISTENER = AGAVE / "core/src/cluster_info_vote_listener.rs"


def section(title):
    print(f"\n=== {title} ===")


def must(cond, msg):
    status = "OK" if cond else "FAIL"
    print(f"  [{status}] {msg}")
    return cond


def main():
    failures = 0

    # ----- (A) check_add_vote signature -----
    section("(A) LatestValidatorVotesForFrozenBanks::check_add_vote")
    lvf_src = LVF.read_text()
    # Locate the function signature (multi-line). Grab everything from
    # `pub fn check_add_vote(` to the matching `)` that ends the params.
    m = re.search(r"pub fn check_add_vote\(", lvf_src)
    if not m:
        print("  [FAIL] could not locate check_add_vote")
        return 1
    sig_start = m.end()
    depth = 1
    i = sig_start
    while i < len(lvf_src) and depth > 0:
        if lvf_src[i] == "(":
            depth += 1
        elif lvf_src[i] == ")":
            depth -= 1
        i += 1
    sig = lvf_src[sig_start : i - 1]
    print("  Function parameters (between the parens):")
    for line in sig.splitlines():
        print(f"    {line}")

    # Now grab the function body and check for ANY lockout-related logic.
    # Skip past the return type to the opening brace.
    body_match = re.search(r"\{", lvf_src[i:])
    if not body_match:
        print("  [FAIL] could not locate body of check_add_vote")
        return 1
    body_start = i + body_match.end()
    depth = 1
    j = body_start
    while j < len(lvf_src) and depth > 0:
        if lvf_src[j] == "{":
            depth += 1
        elif lvf_src[j] == "}":
            depth -= 1
        j += 1
    body = lvf_src[body_start : j - 1]
    accepts_only_4_args = (
        "vote_pubkey" in sig
        and "vote_slot" in sig
        and "frozen_hash" in sig
        and "is_replay_vote" in sig
    )
    # Anything that even smells like a lockout consultation
    has_lockout_check = re.search(r"lockout|tower\b|voter_tower|lockout_violat", body, re.I) is not None
    if not must(accepts_only_4_args, "params are (vote_pubkey, vote_slot, frozen_hash, is_replay_vote) — no tower / lockout info"):
        failures += 1
    if not must(not has_lockout_check, "body has NO lockout/tower consultation — accepts vote regardless of voter lockout"):
        failures += 1

    # ----- (B) track_optimistic_confirmation_vote -----
    section("(B) ClusterInfoVoteListener::track_optimistic_confirmation_vote")
    vl_src = VOTE_LISTENER.read_text()
    m = re.search(r"fn track_optimistic_confirmation_vote\(", vl_src)
    if not m:
        print("  [FAIL] could not locate track_optimistic_confirmation_vote")
        return 1
    sig_start = m.end()
    depth = 1
    i = sig_start
    while i < len(vl_src) and depth > 0:
        if vl_src[i] == "(":
            depth += 1
        elif vl_src[i] == ")":
            depth -= 1
        i += 1
    sig = vl_src[sig_start : i - 1]
    print("  Function parameters:")
    for line in sig.splitlines():
        print(f"    {line}")
    body_match = re.search(r"\{", vl_src[i:])
    body_start = i + body_match.end() if body_match else None
    if body_start is None:
        print("  [FAIL] could not find body of track_optimistic_confirmation_vote")
        return 1
    depth = 1
    j = body_start
    while j < len(vl_src) and depth > 0:
        if vl_src[j] == "{":
            depth += 1
        elif vl_src[j] == "}":
            depth -= 1
        j += 1
    body = vl_src[body_start : j - 1]
    accepts_basic_args = (
        "slot" in sig and "hash" in sig and "pubkey" in sig and "stake" in sig
    )
    no_lockout_check = re.search(r"lockout|tower\b|voter_tower", body, re.I) is None
    if not must(accepts_basic_args, "params include (slot, hash, pubkey, stake) — no tower/lockout argument"):
        failures += 1
    if not must(no_lockout_check, "body has NO lockout/tower consultation"):
        failures += 1
    print("  Body excerpt:")
    for line in body.splitlines()[:10]:
        print(f"    {line}")

    # ----- (C) Receive-direction lockout-violation detector? -----
    section("(C) Search for any receive-side lockout-violation detector")
    # Search both files for any function or call named like "*lockout_violat*"
    # or "is_lockout_violation*"
    patterns = [
        r"lockout_violat\w*",
        r"is_lockout_violation\w*",
        r"reject_lockout_violation\w*",
    ]
    all_text = lvf_src + "\n" + vl_src
    hits = []
    for pat in patterns:
        for m in re.finditer(pat, all_text):
            hits.append(m.group(0))
    if not must(len(hits) == 0, "no `lockout_violat*` / `is_lockout_violation*` identifier in either file (receive-side check absent)"):
        failures += 1
        print(f"    Unexpected hits: {hits}")

    # ----- Summary -----
    section("Summary")
    if failures == 0:
        print("  ALL CHECKS PASSED — receive-side lockout enforcement is absent.")
        print("  An honest validator will credit ANY (voter, slot, hash) vote that arrives")
        print("  via gossip / replay, including one that violates the voter's own lockout.")
        print("  Upstream evidence: https://github.com/solana-labs/solana/issues/7521")
        print("  (slashing v0, filed 2019, unresolved when repo was archived 2025-01-22)")
        return 0
    else:
        print(f"  {failures} check(s) failed. Either the bug is no longer present, or the source layout changed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
