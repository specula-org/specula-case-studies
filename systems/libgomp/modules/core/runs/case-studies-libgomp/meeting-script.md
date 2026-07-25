# Meeting Script: Specula Introduction

## Opening (30 seconds)

Thanks for having us. I know your team has already looked at the bugs we found and confirmed them, so I won't spend too much time on the bugs themselves. Instead, I want to walk you through HOW we found them — the tool and the methodology — because I think that's what's most interesting for collaboration.

## What is Specula (1 minute)

So, Specula is a fully automated pipeline. You give it source code, it gives you confirmed concurrency bugs.

Under the hood, it uses TLA+ formal verification. But the key difference from traditional TLA+ work is: nobody writes the spec by hand. The entire process — reading the code, writing the TLA+ spec, running model checking, debugging failures, confirming bugs — is done by AI agents. Each phase has a specialized agent that follows a detailed methodology guide.

We've applied this to over 40 systems so far — Raft implementations, BFT consensus protocols, OpenMP runtimes, lock-free data structures — in C, C++, Rust, Go, and Java. 

## The Pipeline (3 minutes)

Let me walk through the five phases, using your libgomp case as the example.

### Phase 1: Code Analysis

The first agent reads the source code and produces what we call a "modeling brief." For libgomp, it analyzed about 3,500 lines of C across five files — bar.c, bar.h, futex_waitv.h, team.c, and task.c.

The key output is "bug families" — groups of mechanisms that share a common pattern where bugs could hide. For your flat barrier, we identified four families:

- Family 1: the futex_waitv fallback protocol — where your author actually wrote a triple question mark in the code
- Family 2: cancellation flag cleanup — where the comment says "too many windows for race conditions"
- Family 3: the BAR_HOLDING_SECONDARIES lifecycle across parallel regions
- Family 4: team pointer ABA during handle_tasks

These developer signals — the question marks, the "too many race conditions" comment — are exactly the kind of things our tool picks up on.

### Phase 2: Spec Generation

The second agent takes the modeling brief and writes three TLA+ specifications:

- A base spec that models the barrier protocol. Every action is annotated with source file and line number — we model the implementation, not the paper.
- A model checking spec that wraps the base with bounded fault injection — we control how many tasks, cancellations, and detach events can happen, to keep the state space finite.
- Hunting configs — one per bug family, with tuned bounds and targeted invariants.

For libgomp, the base spec is about 1,000 lines covering all four bug families.

### Phase 2.5: Trace Harness

The third agent instruments the real C code to emit execution traces in NDJSON format. We insert trace emit calls at key points — barrier entry, ensure_last completion, task handling, cancellation. Then we run test scenarios and collect the traces.

This gives us real execution data to validate the spec against.

### Phase 3: Verification Loop

This is the core of the tool. It runs two checks in alternation until they both pass:

- Trace validation: replay real execution traces against the spec. This ensures the spec covers all observed behavior — that the spec is a superset of the real system.
- Model checking: exhaustively explore the spec's state space. This ensures no illegal states are reachable — that the spec is a subset of legal states.

These two pull in opposite directions. Trace validation wants the spec to be MORE permissive. Model checking wants it to be LESS permissive. When both pass simultaneously, we call that "convergence." A converged spec is trustworthy.

After convergence, we run the hunting configs — one per bug family. Each config has tight bounds and a targeted invariant. If TLC finds a violation, it's a real bug.

### Phase 4: Bug Confirmation

When the model checker finds a counterexample, the final agent does three things:

- Code audit: reads the source, traces the call chain, checks for existing safeguards
- Developer intent investigation: checks issues, commits, comments to understand what the developers believe about the behavior
- Low-invasiveness reproduction using only public APIs — no hacks, no internal function calls

For Bug 29, the reproducer is a standard OpenMP 5.0 program — pragma omp task detach plus omp_fulfill_event from a pthread. It's structurally identical to GCC's own test task-detach-13, except without depend clauses. 5 out of 5 deadlock without the fix, 5 out of 5 pass with the fix.

## Key Numbers (30 seconds)

For the libgomp case specifically:

- The deadlock bug — Bug 29 — was found in 492 states, under one second. The counterexample is 13 states long.
- The convergence check — 1.45 million states, all 18 invariants pass, 20 seconds.
- The four other bug families — all clean, no violations.
- Bug 29 affects all GCC versions since 11. The fix is one line.

## Closing (15 seconds)

That's the overview. I'm happy to show you any of these artifacts live — the spec, the model checker output, the reproducer. And I'd love to hear about your experience with the tool and discuss what else we could verify together.
