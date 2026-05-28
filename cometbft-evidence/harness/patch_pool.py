#!/usr/bin/env python3
"""Patch evidence/pool.go to insert TLA trace-emit calls.

Idempotent: skips inserts whose marker text is already present.
"""

import sys
import re
import os


MARKER = "// TLA_TRACE_PATCH"


class Patcher:
    def __init__(self, src: str):
        self.src = src

    def _already_has(self, marker_suffix: str) -> bool:
        return f"{MARKER}: {marker_suffix}" in self.src

    def insert_after_line(self, anchor: str, marker_suffix: str, payload: str):
        """Insert payload after the first line whose stripped content equals anchor.stripped().

        Indentation of the inserted block is copied from the anchor line.
        """
        if self._already_has(marker_suffix):
            return
        lines = self.src.splitlines(keepends=True)
        for i, line in enumerate(lines):
            if anchor in line:
                indent = re.match(r"\s*", line).group(0)
                full_payload = (
                    f"{indent}{MARKER}: {marker_suffix}\n"
                    + "".join(f"{indent}{ln}\n" for ln in payload.splitlines())
                )
                lines.insert(i + 1, full_payload)
                self.src = "".join(lines)
                return
        raise RuntimeError(f"anchor not found: {anchor!r}")

    def insert_before_line(self, anchor: str, marker_suffix: str, payload: str):
        """Insert payload before the first line containing anchor."""
        if self._already_has(marker_suffix):
            return
        lines = self.src.splitlines(keepends=True)
        for i, line in enumerate(lines):
            if anchor in line:
                indent = re.match(r"\s*", line).group(0)
                full_payload = (
                    f"{indent}{MARKER}: {marker_suffix}\n"
                    + "".join(f"{indent}{ln}\n" for ln in payload.splitlines())
                )
                lines.insert(i, full_payload)
                self.src = "".join(lines)
                return
        raise RuntimeError(f"anchor not found: {anchor!r}")

    def replace_block(self, pattern: re.Pattern, replacement_func, marker_suffix: str):
        """Apply a regex-based replacement for multi-line patterns."""
        if self._already_has(marker_suffix):
            return
        self.src, n = pattern.subn(replacement_func, self.src, count=1)
        if n == 0:
            raise RuntimeError(f"replace_block: pattern not found for {marker_suffix}")


def patch_pool(path: str) -> None:
    with open(path, "r") as f:
        src = f.read()

    p = Patcher(src)

    # AddEvidence — "already pending" branch.
    p.insert_before_line(
        'evpool.logger.Info("Evidence already pending, ignoring this one", "ev", ev)',
        "AddEvidence already_pending",
        'emitAddEvidence(evpool, ev, "already_pending", false)',
    )

    # AddEvidence — "already committed" branch.
    p.insert_before_line(
        'evpool.logger.Info("Evidence was already committed, ignoring this one", "ev", ev)',
        "AddEvidence already_committed",
        'emitAddEvidence(evpool, ev, "already_committed", false)',
    )

    # AddEvidence — "verify_failed" branch.
    p.insert_before_line(
        "return types.NewErrInvalidEvidence(ev, err)",
        "AddEvidence verify_failed",
        'emitAddEvidence(evpool, ev, "verify_failed", false)',
    )

    # AddEvidence — "added" branch.
    p.insert_after_line(
        'evpool.logger.Info("Verified new evidence of byzantine behavior", "evidence", ev)',
        "AddEvidence added",
        'emitAddEvidence(evpool, ev, "added", false)',
    )

    # ReportConflictingVotes — after the closing `})` of the append literal.
    # We use a regex to span multi-line.
    rcv_pat = re.compile(
        r"(evpool\.consensusBuffer = append\(evpool\.consensusBuffer, duplicateVoteSet\{\s*\n"
        r"\s*VoteA: voteA,\s*\n"
        r"\s*VoteB: voteB,\s*\n"
        r"\s*\}\))"
    )

    def rcv_repl(m):
        return (
            m.group(1)
            + f"\n\t{MARKER}: ReportConflictingVotes\n"
            + "\temitReportConflictingVotes(evpool, voteA, voteB)"
        )

    p.replace_block(rcv_pat, rcv_repl, "ReportConflictingVotes")

    # markEvidenceAsCommitted — at the top of the loop body, before `if evpool.isPending(ev)`.
    # The anchor line is `if evpool.isPending(ev) {`. There are 2-3 occurrences in the file:
    # one inside processConsensusBuffer (different field name? no, also isPending), one inside
    # markEvidenceAsCommitted, and one inside removeExpiredPendingEvidence (using ev). Look at lines:
    # Line 333 in markEvidenceAsCommitted reads `if evpool.isPending(ev) {`. We anchor on the
    # specific neighboring text inside markEvidenceAsCommitted.
    mac_pat = re.compile(
        r"(func \(evpool \*Pool\) markEvidenceAsCommitted\(.*?\) \{\s*\n"
        r"\s*blockEvidenceMap := make\(map\[string\]struct\{\}, len\(evidence\)\)\s*\n"
        r"\s*for _, ev := range evidence \{)",
        re.DOTALL,
    )

    def mac_repl(m):
        prefix = m.group(1)
        return (
            prefix
            + f"\n\t\t{MARKER}: ApplyBlock_RemovePending"
            + "\n\t\twasPending := evpool.isPending(ev)"
            + "\n\t\temitApplyBlockRemovePending(evpool, ev, wasPending)"
            + "\n\t\t_ = wasPending"
        )

    p.replace_block(mac_pat, mac_repl, "ApplyBlock_RemovePending")

    # ApplyBlock_WriteCommitted: append after the inner `Set(keyCommitted, evBytes)` block.
    wc_pat = re.compile(
        r"(if err := evpool\.evidenceStore\.Set\(key, evBytes\); err != nil \{\s*\n"
        r"\s*evpool\.logger\.Error\(\"Unable to save committed evidence\", \"err\", err, \"key\(height/hash\)\", key\)\s*\n"
        r"\s*\})"
    )

    def wc_repl(m):
        block = m.group(1)
        return (
            block
            + f"\n\t\t{MARKER}: ApplyBlock_WriteCommitted"
            + "\n\t\temitApplyBlockWriteCommitted(evpool, ev)"
        )

    p.replace_block(wc_pat, wc_repl, "ApplyBlock_WriteCommitted")

    # processConsensusBuffer — already_pending branch.
    p.insert_before_line(
        'evpool.logger.Info("evidence already pending; ignoring", "evidence", dve)',
        "ProcessConsensusBuffer already_pending",
        'emitProcessConsensusBuffer(evpool, voteSet.VoteA.ValidatorAddress, "already_pending", evHashRec(dve))',
    )

    # processConsensusBuffer — already_committed branch.
    p.insert_before_line(
        'evpool.logger.Info("evidence already committed; ignoring", "evidence", dve)',
        "ProcessConsensusBuffer already_committed",
        'emitProcessConsensusBuffer(evpool, voteSet.VoteA.ValidatorAddress, "already_committed", evHashRec(dve))',
    )

    # processConsensusBuffer — added branch (after final logger.Info).
    p.insert_after_line(
        'evpool.logger.Info("verified new evidence of byzantine behavior", "evidence", dve)',
        "ProcessConsensusBuffer added",
        'emitProcessConsensusBuffer(evpool, voteSet.VoteA.ValidatorAddress, "added", evHashRec(dve))',
    )

    # processConsensusBuffer — dropped_above_state branch (default in the switch).
    # The default branch's logger.Error spans multiple lines; we anchor on its
    # closing-paren line and insert AFTER it (before the `continue`).
    p.insert_after_line(
        '"state.LastBlockHeight", state.LastBlockHeight)',
        "ProcessConsensusBuffer dropped_above_state",
        'emitProcessConsensusBuffer(evpool, voteSet.VoteA.ValidatorAddress, "dropped_above_state", nil)',
    )

    with open(path, "w") as f:
        f.write(p.src)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch_pool.py <path-to-pool.go>", file=sys.stderr)
        sys.exit(1)
    patch_pool(sys.argv[1])
    print(f"[patch_pool] patched {os.path.basename(sys.argv[1])}")
