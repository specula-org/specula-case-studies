# vsr-rs

## Scope

Specula analyzed and tested [penberg/vsr-rs](https://github.com/penberg/vsr-rs),
a Rust implementation of Viewstamped Replication, including normal replication,
client retries and cached replies, view changes, state transfer, crash recovery,
and the shipped TCP key-value store's persistence and transport integration.
Both runs target revision
[`3ac0104a567092139534c9022205d02281a2da41`](https://github.com/penberg/vsr-rs/tree/3ac0104a567092139534c9022205d02281a2da41).

## Bugs

Specula found **3 new bugs**, all reproduced in the second run. The references
below are local to that run; identically numbered first-run candidates describe
different investigations.

| Reference | Component | Finding | Reproduction evidence |
| --- | --- | --- | --- |
| CR-1 | kvstore startup | An existing invalid or unreadable view file is treated as first initialization, so a reused replica identity starts in view 0 and can acknowledge conflicting history. | The real example accepts and overwrites a malformed view file. A separate public-API schedule using that constructor choice produces conflicting committed slot-1 replies; a `Replica::recover(view=1)` control prevents the conflict. |
| CR-2 | Library request commit | An accepted one-replica configuration records the primary's self-ack but checks quorum only on a peer `PrepareOk`, so client requests never commit. | Public client/replica calls leave `op=1`, `commit=0`, no application execution, and no replies after repeated idle/retry rounds. A three-replica control commits and replies. |
| CR-3 | kvstore peer transport | One connected peer that stops reading can block the shared sender's unbounded `write_all`, delaying queued traffic to healthy destinations. | Three real kvstore processes handle a healthy 4 MiB SET, then a stopped backup leaves the next SET unanswered for 800 ms. The archived test receives its reply only after that backup resumes, at 7.728 s total. This is a finite observation, not a measured permanent outage. |

The [second-run confirmation report](modules/core/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/confirmed-bugs.md)
contains the full scenarios and controls. These are code-review findings with
runtime reproductions; they were not discovered as TLC counterexamples. Internal
reproduction does not establish upstream maintainer confirmation.

As of 2026-09-06, the upstream issue/PR inventory contains no matching report for
these three mechanisms. [PR #10](https://github.com/penberg/vsr-rs/pull/10) merged
as `0b64760fb163861d19fd42b4c13e3494f610879c` on 2026-09-06, fixing connection
backoff and disconnect cleanup from [issue #9](https://github.com/penberg/vsr-rs/issues/9).
Its diff does not fix the three mechanisms above. Archived reports retain the
earlier, then-current open status of #10.

## Evidence

- [First run](modules/core/runs/vsr-rs-gpt6astra-ultra-20260905/README.md):
  no new bugs; three false positives and one dropped duplicate of the known
  client-ID reuse issue.
- [Second run](modules/core/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/README.md):
  three reproduced bugs, one environment-limited finding, one masked finding,
  and one false positive. The directory-fsync and recovery-nonce findings are
  retained in the record but excluded from the three-bug count.
- [Reproduce the three bugs](repro/README.md).

The second run replayed four implementation traces containing 186 events. Its
constrained baseline hunting graph completed without a violation; the broader
`MC.cfg` search timed out. These checks cover the modeled library assumptions,
not a general safety or liveness proof or validation of the example's filesystem
and socket behavior.
