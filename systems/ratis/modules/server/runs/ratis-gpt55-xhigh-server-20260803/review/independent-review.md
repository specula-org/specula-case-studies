# Independent review — ratis-server

Review date: `2026-08-04`

This run has one strong reportable result: MC-1. MC-2 is useful as a hardening
candidate, but it should not be presented as a reproduced bug.

| Finding | Raw disposition | Reviewed disposition | Notes |
| --- | --- | --- | --- |
| MC-1 | `REPRODUCED` | `REPRODUCED`, Critical | Strong result. `asyncFlushOutStream` advances the flushed boundary after a failed async force, allowing commit/client success ahead of durable log state. |
| MC-2 | `MASKED` | Candidate only, not a confirmed bug | The ordering concern is source-plausible, but the executable run did not observe a stale read. It ended with the old server demoted and reads failing with `ReadIndexException: Leader is unknown`. |
| CR-2 / CR-3 | `DROPPED` | Known or already fixed adjacent issues | Useful background, not new reportable bugs for this source tree. |
| CR-5 | `FALSE POSITIVE` | Not reportable | Current joint-consensus membership guards explain the observed behavior. |

Additional focused validation was run for MC-1 after the original run:

- Evidence directory: `review/focused-validation/server-mc1/`
- Command: `timeout 8m ./mvnw -pl ratis-server -am -Dtest=SpeculaAsyncFlushPersistentFailureTest#asyncFlushStillAdvancesCommitWhenEveryForceFails -DskipCheckStyle -DskipRat -Djacoco.skip=true test`
- Result: `BUILD SUCCESS`, `Tests run: 1, Failures: 0`
- Key observation: all `FileChannel.force(false)` calls after fault installation failed, but the admin reply still returned success and `flushIndex`/`commitIndex` advanced.

The focused validation strengthens the original MC-1 result because it covers
repeated force failures, not just a single failed force call.

Recommended outward-facing use:

- Report MC-1 as a reproduced Critical bug, with the Level 2 storage-fault
  injection disclosed.
- Do not count MC-2 as a confirmed bug; at most mention it as a masked
  hardening candidate if the audience wants secondary findings.
