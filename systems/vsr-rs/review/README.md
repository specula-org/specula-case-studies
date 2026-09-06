# Curation Verification

The portable [reproduction runner](../repro/README.md) was executed on 2026-09-06
against an uninstrumented archive of revision
`3ac0104a567092139534c9022205d02281a2da41`, tree
`a154948e355d4059720575cbe1146c0253e06406`. All three cases reproduced their expected
behavior and the combined command exited 0. See the
[complete output](reproduction-pinned.log) for healthy controls and fault results.
TLC was not rerun during this curation.

The sender rerun's healthy SET replied in 0.409 s. The faulted SET received no
reply during the 800 ms stop or the additional 8 s after resume. The original
run's 7.728 s reply and this bounded no-reply result are separate observations;
neither measures permanent unavailability.

The [upstream audit](upstream-audit.json) captures the complete ten-entry
issue/PR inventory and the merged PR #10 diff as read on 2026-09-06. That diff
changes reconnect backoff and client disconnect cleanup. It leaves the view-file
fallback, singleton commit logic, and shared blocking writes in place. No
matching report or maintainer confirmation of CR-1 through CR-3 was found.

The original reports remain unchanged. The system overview and run READMEs
distinguish the three counted bugs from false positives, the known duplicate,
the environment-limited persistence finding, and the masked nonce finding.
The original severity-summary arithmetic is not adopted.
