# Reproduction Tests — arc-swap_2

This directory is intentionally empty.

The MC and code-review pass produced **zero new bugs** for the current
implementation (`vorner/arc-swap` at commit `d5dd00c`). All five MC
violations are historical-class reproductions: the spec's
`MCRelaxOrdering(site)` adversary deliberately downgrades one SC-labelled
atomic per execution to demonstrate that the SC labels are load-bearing.
Removing the adversary (running with `MaxOrderingGaps=0`, configs
`MC_hunt_familyB.cfg`, `MC_hunt_familyD.cfg`, and the base `MC.cfg`)
exhausts the reachable graph (depth 248 / 7.5M distinct states; depth 78
/ 2M distinct on the base) without violations.

Per the bug-confirmation skill (`Phase 2 — Mandatory for new bugs`):

> Known/historical bugs (those matching an existing JIRA ticket) do NOT
> require reproduction — the existing ticket serves as confirmation.

Each MC counterexample maps to an upstream issue/PR that has already been
fixed in the codebase under audit:

| MC counterexample | Upstream | Fix commit | SC site (current code)         |
|-------------------|----------|------------|--------------------------------|
| `ListHeadLoad`    | #164     | `d849a2d`  | `debt/list.rs:102`             |
| `FastConfirmLoad` | #76      | `6b644ff`  | `strategy/hybrid.rs:52`        |
| `FallbackLoad`    | #198     | `d5dd00c`  | `strategy/hybrid.rs:83`        |
| `DebtPaySuccess`  | #204     | `cccf354`  | `debt/mod.rs:77` (success leg) |
| `DebtPayFailure`  | PR #195  | `bd5d327`  | `debt/mod.rs:77` (failure leg) |

Verified by `git log` on the artifact: all five fix commits are present
on HEAD. See `confirmed-bugs.md` for the full classification.
