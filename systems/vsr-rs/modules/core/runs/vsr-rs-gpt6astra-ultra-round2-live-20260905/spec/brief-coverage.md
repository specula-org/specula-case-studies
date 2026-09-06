# Brief coverage self-audit

Source: `3ac0104a567092139534c9022205d02281a2da41`. Category A, fixed membership, atomic library handlers. Audit performed against the actual `MC.cfg`, `MC_hunt_baseline.cfg`, and `MC_smoke.cfg`, including their uncommented `INVARIANTS` declarations.

The brief selects **zero targeted protocol hunts** (§3.1, §4, §6.1). Its explicit exclusions govern this audit: no invented persistence loss, nonce reuse, singleton, socket blockage, or oracle mutation in the conforming-library model. The skill's coverage checklist permits explicit out-of-scope dispositions; the mandatory audit is retained here. We do not generate six misleading configs that cannot reach their named mechanisms. `MC_hunt_baseline.cfg` is a shared baseline safety profile, not a claim to cover those mechanisms.

## Brief §2: Scenarios

| Scenario | Actual cfg / disposition | Scope and preserved downstream route |
|---|---|---|
| 1 EX-START | **Out of MC scope**; no targeting cfg | Brief explicitly says no TLA+ extension. `Crash`/`Recover` obey the library contract, so constructor fallback is unreachable by design. Preserve startup read/parse checks (`examples/kvstore/main.rs:683-701`) and API conflicting-commit witness (`lib.rs:646-694,716-730,737-765`); compose into a process test only if needed. |
| 2 LIB-SINGLE | **Out of MC scope**; no targeting cfg | `N >= 2` is an explicit baseline restriction, not an assertion about accepted API configurations. Preserve direct n=1 progress/rejection regression (`lib.rs:74-98,682-694,737-765`; `simulator/lib.rs:258-259`). No finite-liveness claim. |
| 3 EX-WRITER | **Out of MC scope**; no targeting cfg | Asynchronous bag delivery does not reproduce shared blocking sockets. Preserve unchanged-sender loopback test (`examples/kvstore/main.rs:342-392`) and failure-detector comparison (`31-35`). |
| 4 EX-FSYNC | **Out of MC scope**; no targeting cfg | Atomic `PublishReplica` assumes successful durable publication before release (`lib.rs:14-21`). This does not verify `persist_view` (`examples/kvstore/main.rs:569-579,749-750`). Preserve syscall-order and declared-filesystem-crash-model checks. |
| 5 EX-NONCE | **Out of MC scope**; no targeting cfg | `Recover` requires freshness and the MC wrapper uses canonical increasing nonces. This does not verify wall-clock allocation (`examples/kvstore/main.rs:692-697`). Preserve allocator audit, repeated-clock test, and separate stale-frame transport witness. EX-CLIENT remains the exact known duplicate. |
| 6 AS-01…AS-06, AS-LEAN | **Shared baseline property checks only**, `MC_hunt_baseline.cfg` | Full committed history, per-handler application checks, and replies in the fault network improve model observation. They do not test simulator oracle implementations or prove Lean theorems. Preserve oracle mutation, per-event observation, reply-network, finite-budget-policy, and proof-scope handoffs. |

No integration finding is merged into EX-CLIENT/#9, nor into a broad example-obligations scenario. The shared baseline profile only merges the standard property checks associated with AS-01/02/03.

## Brief §5: Safety properties

All implemented entries below are defined in `base.tla`, exported by `MC.tla` through `EXTENDS base`, and **enabled** in the actual baseline cfg. No defined safety property is left waiting for a nonexistent hunt cfg.

| Contract | Definition / MC wiring | Enabled cfgs or explicit exclusion |
|---|---|---|
| CommittedPrefixAgreement | `committedHistory` retains every committed full request/index across replicas, time, and crashes; equality is checked independently of current logs | `MC_hunt_baseline.cfg`, `MC.cfg`, `MC_smoke.cfg` |
| CommitBounded | `commit <= Len(log)` for every replica | Same three cfgs |
| AppliedPrefix | `applied = Prefix(log,commit)` and application accumulator equals sum of applied operation values | Same three cfgs |
| AtMostOnce | Unique `(client,number)` in each incarnation's full application history; observer resets with volatile application state | Same three cfgs |
| ReplyCorrect | Every emitted reply matches a historically committed request and its accumulator result; includes replies before network delivery | Same three cfgs |
| RestartMustRecover | **Not defined as a testable integration invariant**; constructor policy assumed by baseline | EX-START direct executable/API route; no targeting cfg, as directed by §3.2/4 |
| PublishedViewDurable | **Not defined as a filesystem invariant**; durability assumed by baseline | EX-FSYNC syscall/filesystem crash route; `DurableViewConsistent` checks model bookkeeping only and is not a substitute |
| RecoveryNonceFresh | **Not defined as an allocator invariant**; freshness is a precondition on `Recover` | EX-NONCE clock/allocator/transport route; `usedNonces` models the assumption, not evidence that the example satisfies it |

Liveness contracts `AcceptedSingletonCompletes` and `SenderIsolation` remain on their direct-test routes. `MC!ClientProgress` is defined but disabled: finite idle/retry/fault budgets provide no eventual-stability or fair-delivery witness. No liveness result is claimed.

## Brief §6.1: Model-checkable findings

| Entry | Trigger / expected invariant / cfg |
|---|---|
| **None selected** | No finding requires a targeting fault setup. Baseline checking is bounded assurance, not a new candidate. |

## Reachability and limitations of the shipped configs

| Config | Actual setup | Reachability limit |
|---|---|---|
| `MC.cfg` | 3 replicas, 2 clients, operations 1/2; 2 requests, 4 replica idles, 1 client retry, 1 crash, 1 loss, 1 duplication; timeout 2, view ≤2, message multiplicity ≤12 | Can introduce timeout/view-change and fresh recovery. Budgets are global, reactive handlers unbounded. Prunes states exceeding the message/view constraints. Not claimed exhaustive in this generation task. |
| `MC_hunt_baseline.cfg` | 3 replicas, 1 client, operations 1/2; 2 requests, 1 replica idle, 1 client retry, no crash, 1 loss, 1 duplication; timeout 2, view ≤1, messages ≤10 | Ordinary replication/retry/reply safety only; insufficient idles for a fresh timeout and no recovery. Intentionally does not cover the five independent integration/API mechanisms. |
| `MC_smoke.cfg` | 3 replicas, 1 client, operations 1/2; 1 request, 1 replica idle; no crash/loss/duplicate/retry; messages ≤10 | Small complete generation sanity check; excludes view changes and recovery. |

Replica symmetry is disabled because membership order determines primary and DVC ties. Client model-value renaming is enabled. Counters remain part of TLC state identity because they affect enabled actions. The message constraint counts multiplicity, not only distinct payloads.

## Additional handoff candidates preserved from §6.2/§6.3

These are not silently discarded by the empty protocol-hunt list: EX-PORT (i686 example cross-build); EX-WIRE (parser/ingress robustness); API-CONFIG (constructor preconditions); AS-04/05 (singleton, persistence, clock integration coverage); AS-06 (pre-healing deadline latch); AS-LEAN (proof status, nonce hypotheses, settling versus client progress); AS-TUI (loss-script replay). Exact anchors and evidence remain in `../modeling-brief.md` and `../analysis-report.md`. They remain separate from library safety claims.

Generation verification results and their scope are recorded in `validation.md`; no bounded pass should be read as a proof or a production bug confirmation.
