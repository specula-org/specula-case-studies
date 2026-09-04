# Developer disposition

This table preserves the 18-entry review shown in
[`developer-disposition.png`](developer-disposition.png) and maps its PM labels
to the archived Specula finding identifiers. The source review uses `Confirmed`
for 11 entries and `Likely` for five; both labels are accepted bug dispositions
for this case study. `Approved` is represented as `Confirmed` in the tracker.

| PM | Source label | Category | Archived finding | Recorded disposition |
| --- | --- | --- | --- | --- |
| PM-01 | `Confirmed` | Lost wakeup / liveness | MC-1 | `Confirmed` |
| PM-02 | `Confirmed` | Signal starvation | MC-2 | `Confirmed` |
| PM-03 | `Confirmed` | Post-termination execution | MC-3 | `Confirmed` |
| PM-04 | `Confirmed` | Kernel panic / DoS | MC-4 | `Confirmed` |
| PM-05 | `Likely` | Condvar returns without mutex | MC-6 | `Confirmed` |
| PM-06 | `Likely` | Mutex-map leak / exhaustion | MC-7 | `Confirmed` |
| PM-07 | `Confirmed` | Masked fatal signal acted upon | MC-8 | `Confirmed` |
| PM-08 | `Confirmed` | Pending-signal lifecycle | MC-9 | `Confirmed` |
| PM-09 | `Likely` | Nested signal-mask corruption | MC-10a | `Confirmed` |
| PM-10 | `Confirmed` | Join status lost after bad copyout | CR-1 | `Confirmed` |
| PM-11 | `Confirmed` | Pending signals cleared by `execv` | CR-2 | `Confirmed` |
| PM-12 | `Likely` | Signal loss / mask leak | CR-3 | `Confirmed` |
| PM-13 | `Not a valid bug` | Non-robust mutex owner death | CR-4 | Excluded |
| PM-14 | `Confirmed` | CPU-bound signal starvation | CR-5 | `Confirmed` |
| PM-15 | `Likely` | IPC message lost after bad copyout | CR-6 | `Confirmed` |
| PM-16 | `Confirmed, critical` | Capability self-grant | CR-7 | `Confirmed` |
| PM-17 | `Confirmed, critical` | Stale MMIO mapping / UAF | CR-10 | `Confirmed` |
| PM-18 | `Not a valid bug` | Concurrent join/detach race | CR-11 | Excluded |

The mapping uses the exact category wording from the screenshot and the
corresponding mechanism in `spec/candidates.json`. Four other archived internal
candidates are outside this reviewer-facing set: MC-5, MC-10b, CR-8, and CR-9.
They are retained as run evidence but are not included in the 16 accepted
entries.
