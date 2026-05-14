#!/usr/bin/env python3
"""
Reproduction test for Bug #3 (F3):
`run_backward_dataflow` in src/backend/liveness.rs:504-568 caps the
iteration count at `MAX_ITERATIONS = 50`. When the cap is hit, the loop
exits with `changed == true`, i.e. the live_in / live_out sets are still
under-approximated. The caller (`compute_live_intervals`) accepts the
result without any assertion, warning, or error. Phase-2/Phase-3 regalloc
and Tier-2 slot packing then consume the unsound intervals.

There are two parts:

1. Source-code audit: confirm the cap exists, no debug_assert fires, no
   error path, and only a TLA+ trace hook is called.

2. Attempt to construct a pathological C CFG and compile it. The backward
   dataflow in CCC iterates blocks in reverse order, so reducible CFGs
   converge in O(depth). To exceed 50 sweeps we need an irreducible or
   reverse-reducible CFG. We attempt one via computed goto chains.

Because triggering the cap in real C is very difficult (fuzzer-only in
practice), the primary evidence is the source audit. This test documents
both.

Classification: CONFIRMED by source audit. The cap exists and is silent.
Functional reproduction on hand-written C did not trigger it; the bug is
real but latent to pathological inputs.
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = "/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler"
LIVENESS = os.path.join(ROOT, "src/backend/liveness.rs")
CCC = os.path.join(ROOT, "target/release/ccc-x86")


def audit_source() -> bool:
    src = open(LIVENESS).read()
    m = re.search(
        r"fn run_backward_dataflow\([^}]+?while changed && iteration < MAX_ITERATIONS \{.*?\n\}",
        src, re.DOTALL)
    if not m:
        # Fallback: locate manually via line range.
        lines = src.splitlines()
        start = None
        for i, l in enumerate(lines):
            if "fn run_backward_dataflow" in l:
                start = i
                break
        assert start is not None, "can't locate run_backward_dataflow"
        body = "\n".join(lines[start:start + 70])
    else:
        body = m.group(0)
    print("=== run_backward_dataflow body (truncated) ===")
    for line in body.splitlines()[:70]:
        print(line)
    print("=== end ===")

    checks = {
        "cap constant":
            "const MAX_ITERATIONS: u32 = 50" in src,
        "loop guard uses cap":
            re.search(r"while changed && iteration < MAX_ITERATIONS", src)
            is not None,
        "no debug_assert on convergence":
            "debug_assert!(!changed" not in src,
        "no Result/error on cap":
            "Err(\"dataflow" not in src,
        "trace-only cap hook":
            "emit_dataflow_cap_hit" in src,
    }
    print("\n=== Source audit checklist ===")
    all_ok = True
    for k, v in checks.items():
        mark = "OK" if v else "FAIL"
        print(f"  [{mark}] {k}")
        all_ok = all_ok and v
    return all_ok


def build_pathological_c(n: int) -> str:
    """Build a C program with an irreducible-ish CFG using computed goto.

    We create `n` labels each of which does `x = reg_X + k` and jumps to
    another label. The chain is: for i, i points to i+1, plus a back-edge
    from 0 to n-1 once at entry. That alone is reducible; we add two
    extra cross-edges to make the CFG less reducible for the compiler's
    block ordering.
    """
    # Declare a jump table; `addr` indexes into it. The control flow is
    # selected at runtime so the compiler's liveness must treat every
    # label as reachable from every goto.
    labels = [f"L{i}" for i in range(n)]
    body = []
    body.append("int f(int seed, int n) {")
    body.append("    int x = seed;")
    body.append("    int* addr;")
    body.append("    static void* targets[] = {")
    for lb in labels:
        body.append(f"        && {lb},")
    body.append("    };")
    body.append("    if (n < 0) n = 0;")
    body.append(f"    if (n >= {n}) n = {n - 1};")
    body.append("    goto *targets[n];")
    for i, lb in enumerate(labels):
        nxt = labels[(i + 1) % n]
        prv = labels[(i - 1) % n]
        body.append(f"{lb}: x += {i + 1}; if (seed & 1) goto {prv}; seed >>= 1; if (seed) goto {nxt}; return x;")
    body.append("}")
    return "\n".join(body)


def try_reproduce() -> bool:
    n = 80  # try ≥ 50 labels so a worst-case ordering exceeds the cap
    src = build_pathological_c(n)
    with tempfile.TemporaryDirectory() as td:
        c_path = os.path.join(td, "pathological.c")
        s_path = os.path.join(td, "pathological.s")
        with open(c_path, "w") as f:
            f.write(src)
        r = subprocess.run([CCC, "-S", c_path, "-o", s_path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("\nPathological compile failed (not unexpected):")
            print(r.stderr[:400])
            # Parsing failure may mean CCC doesn't support computed-goto.
            return False
        asm = open(s_path).read()
        labels = len(re.findall(r"^\.LBB\d+:", asm, re.MULTILINE))
        print(f"\ngenerated CCC assembly with {labels} local labels")
        # Without tla_trace enabled we can't directly observe if the cap
        # was hit. We can only note that *if* the compile succeeds, any
        # under-approximation is silent. This is the point of the bug.
        return True


def main() -> int:
    print(">>> Phase 1: source-code audit <<<")
    ok = audit_source()
    print()
    print(">>> Phase 2: try to trigger the cap on hand-written C <<<")
    tried = try_reproduce()
    print()
    if ok:
        print("RESULT: BUG CONFIRMED by code audit.")
        print("  - MAX_ITERATIONS = 50 cap is hard-coded.")
        print("  - Loop exits silently on cap-hit with `changed == true`.")
        print("  - No debug_assert, no error propagation.")
        print("  - Only a TLA+ trace hook fires (off by default).")
        if tried:
            print("  - Pathological CFG compiles without diagnostics;")
            print("    whether the cap fired is invisible to the user.")
        print()
        print("Reproduction status: CONFIRMED by audit. Functional")
        print("reproduction requires constructing a CFG needing > 50")
        print("backward-dataflow sweeps, which in practice is only")
        print("reachable with fuzzer-generated or obfuscated inputs.")
        print("The *silence* of the cap-hit is the bug; fixing it is a")
        print("one-line debug_assert.")
        return 0
    print("RESULT: audit inconclusive.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
