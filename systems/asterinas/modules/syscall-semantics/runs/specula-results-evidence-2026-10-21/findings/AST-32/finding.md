# AST-32 — SCM_RIGHTS installs an FD before publishing its number

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-23 |
| Date basis | dated local record |

SCM_RIGHTS inserts a file into the receiver table before copying its descriptor number to user memory. A fault can leave the installed descriptor behind, while the returned ancillary length omits it. The retained reproduction demonstrates the stray descriptor; it does not establish privilege escalation.

GLM-5.3 reproduced an installed receiver FD whose number was never published after a control-buffer fault. No privilege escalation was established.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-32-scm-rights-install-before-publish/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| SCM / MC-1 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
