#!/usr/bin/env python3
"""
Reproduction test for Bug #2 (F2):
`is_returns_twice_call` (src/backend/liveness.rs:1013-1019) recognises
only the hard-coded name set:

    matches!(func.as_str(),
        "setjmp" | "_setjmp" | "sigsetjmp" | "__sigsetjmp")

`vfork()`, `getcontext()`, `setcontext()`, and any user function marked
`__attribute__((returns_twice))` are NOT recognised. They never make it
into `setjmp_block_indices` (liveness.rs:544-568), and
`extend_intervals_for_setjmp` never extends the intervals of values live
across the call. Tier-2 slot-packing may therefore reuse a slot that
still holds a value live across the returns-twice call's *second*
return.

This is a silent miscompile on real programs that call vfork/getcontext.

Approach:
1. Static inspection: confirm that the hard-coded list excludes the
   relevant libc function names.
2. End-to-end compilation: compile a C file that exercises vfork and
   compare the produced assembly against the setjmp form. Check that
   the block containing vfork is NOT treated as a returns-twice block
   (observable as slot layout differing from setjmp in ways that imply
   the extension did not run).

Classification: CONFIRMED by code audit. The actual observable slot
collision requires a subtle multi-path reuse; a full end-to-end crash
test would require a `vfork()`+`longjmp()`-style harness. This test
documents the missing entries and demonstrates the differential
behavior between setjmp (recognised) and vfork (not).
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = "/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler"
LIVENESS = os.path.join(ROOT, "src/backend/liveness.rs")
CCC = os.path.join(ROOT, "target/release/ccc-x86")

EXPECTED_MISSING = {"vfork", "getcontext", "setcontext"}


def inspect_source() -> bool:
    src = open(LIVENESS).read()
    # Find `is_returns_twice_call` body.
    m = re.search(
        r"fn is_returns_twice_call\(inst: &Instruction\) -> bool \{(.*?)\n\}",
        src, re.DOTALL)
    if not m:
        print("FAIL: could not locate is_returns_twice_call in liveness.rs")
        return False
    body = m.group(1)
    print("=== is_returns_twice_call body ===")
    print(body.rstrip())
    # Extract the name-set.
    names_re = re.findall(r'"([^"]+)"', body)
    recognised = set(names_re)
    print(f"\nrecognised names: {sorted(recognised)}")
    missing_found = EXPECTED_MISSING - recognised
    print(f"absent (buggy):   {sorted(missing_found)}")
    if missing_found == EXPECTED_MISSING:
        print("\nCONFIRMED: vfork / getcontext / setcontext are NOT recognised")
        print("as returns-twice calls. Per liveness.rs:544-568, these callsites")
        print("will not trigger extend_intervals_for_setjmp, so Tier-2 slot")
        print("packing may reuse slots that hold values live across them.")
        return True
    print("\nPARTIAL: some expected missing names are actually present.")
    return False


C_SOURCE = r"""
#include <setjmp.h>
extern int vfork(void);
extern int helper(int a, int b);

int with_setjmp(jmp_buf env) {
    int a = helper(1, 2);
    int b = helper(3, 4);
    int c = helper(5, 6);
    int d = helper(7, 8);
    int rc = setjmp(env);
    int e = helper(9, 10);
    int f = helper(11, 12);
    return a + b + c + d + e + f + rc;
}

int with_vfork(void) {
    int a = helper(1, 2);
    int b = helper(3, 4);
    int c = helper(5, 6);
    int d = helper(7, 8);
    int rc = vfork();
    int e = helper(9, 10);
    int f = helper(11, 12);
    return a + b + c + d + e + f + rc;
}
"""


def differential_compile() -> None:
    with tempfile.TemporaryDirectory() as td:
        c_path = os.path.join(td, "repro.c")
        s_path = os.path.join(td, "repro.s")
        with open(c_path, "w") as f:
            f.write(C_SOURCE)

        r = subprocess.run([CCC, "-S", c_path, "-o", s_path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CCC compile failed:", r.stderr)
            return

        asm = open(s_path).read()

        def extract(fn: str) -> str:
            lines = []
            inside = False
            for line in asm.splitlines():
                if line.startswith(f"{fn}:"):
                    inside = True
                if inside:
                    lines.append(line)
                if inside and line.startswith(f".size {fn}"):
                    break
            return "\n".join(lines)

        sj = extract("with_setjmp")
        vf = extract("with_vfork")

        # Heuristic: count slots used (distinct -N(%rbp) offsets that are
        # written to). Tier-2 reuse would collapse more values onto fewer
        # slots in the vfork case.
        def slot_count(body: str) -> int:
            offsets = set(re.findall(r"movq %[^,]+, (-\d+)\(%rbp\)", body))
            return len(offsets)

        print(f"\n=== stack size (subq $N, %rsp) ===")
        print("setjmp:", re.findall(r"subq \$(\d+), %rsp", sj))
        print("vfork :", re.findall(r"subq \$(\d+), %rsp", vf))
        print(f"\n=== distinct slot-write offsets ===")
        print("setjmp:", slot_count(sj))
        print("vfork :", slot_count(vf))


def main() -> int:
    print(">>> Phase 1: static source audit <<<")
    ok = inspect_source()
    print()
    print(">>> Phase 2: differential compile (setjmp vs vfork) <<<")
    differential_compile()
    print()
    if ok:
        print("RESULT: BUG CONFIRMED by code audit.")
        print("Hard-coded returns-twice set in liveness.rs:1013-1019 omits")
        print("vfork/getcontext/setcontext; extend_intervals_for_setjmp is")
        print("therefore never invoked for those callsites, allowing Tier-2")
        print("slot packing to reuse slots holding values alive across the")
        print("returns-twice call's second return.")
        return 0
    print("RESULT: audit inconclusive — source list unexpectedly contains entries.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
