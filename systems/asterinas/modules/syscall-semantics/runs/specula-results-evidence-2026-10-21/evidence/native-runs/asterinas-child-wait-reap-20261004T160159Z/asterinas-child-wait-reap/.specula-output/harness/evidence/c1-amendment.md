# Candidate v5 amendment for review finding C1

Author: lane controller (Claude), 2026-10-06. Trigger: `review-v5.md` finding C1 (Medium).
The evidence-directory QMP socket path was at least 110 bytes, above the 108-byte
`sockaddr_un.sun_path` limit, so QEMU could not start any guest case.

Change: `src/boot.py` (and its frozen copy in `candidate-v5/src/boot.py`) now uses a
container-local `/tmp/wr-<uuid4 hex>.qmp` path (44 bytes), records it in the outcome JSON, and
still unlinks it in the `finally` block. `candidate-v5/hashes.json` was regenerated for that
one file. No other file changed. The candidate name stays `v5` because `review_gate.py` binds
that name; the reviewed pre-amendment bytes are git commit `e601dea`.

The author does not approve this change. It needs an independent re-review before execution.

Correction after re-review finding C2 (Low): commit `2af46b8` also added a stray
`harness/src/__pycache__/boot.cpython-314.pyc` from a syntax check. Commit `7e0fb7e` removed it
and added a `__pycache__/` ignore rule. The reviewed HEAD contains no bytecode.
