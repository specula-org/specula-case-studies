#!/usr/bin/env python3
"""
Reproduction for CCC mem2reg Bug 1 (Family F4 / D3):
Multi-asm-goto same-target overwrites goto_label_snapshots.

Trigger:
- A basic block contains two `asm goto(...)` instructions whose label-list
  includes the same target label.
- A promoted alloca's value changes between the two asm-goto sites
  (Store_ptr ; AsmGotoToL ; Store_ptr ; AsmGotoToL).
- mem2reg keys `goto_label_snapshots` only by (block, target-label), so the
  second asm-goto's snapshot overwrites the first's. The phi at L receives
  only one incoming entry per pred-block instead of one per asm-goto site,
  and the LATER snapshot is used even on the runtime edge from the EARLIER
  asm-goto.

Expected behaviour (and what GCC produces):
  check(0) returns 0   (first asm-goto's `jz` taken; v was 0 at that point)
  check(1) returns 1   (second asm-goto's `jnz` taken; v had been set to 1
                        between the two asm-goto sites)

Buggy behaviour (CCC):
  Both check(0) and check(1) return the SAME value (1) because the second
  snapshot (v=1) overwrote the first (v=0) in `goto_label_snapshots`. The
  phi destination at the `bail` label is unconditionally loaded with v=1.
"""

import os
import subprocess
import sys
import tempfile
import textwrap

CCC = "/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler/target/release/ccc"

SOURCE = textwrap.dedent(r"""
#include <stdio.h>

int check(int cond) {
    int v = 0;
    asm goto("testl %0, %0\n\tjz %l[bail]"
             : : "r"(cond) : "cc" : bail);
    v = 1;
    asm goto("testl %0, %0\n\tjnz %l[bail]"
             : : "r"(cond) : "cc" : bail);
    v = 2;
    return v;
bail:
    return v;
}

int main(void) {
    int r0 = check(0);
    int r1 = check(1);
    printf("check(0) = %d (expected 0)\n", r0);
    printf("check(1) = %d (expected 1)\n", r1);
    if (r0 != 0 || r1 != 1) {
        printf("BUG REPRODUCED: mem2reg D3 asm-goto snapshot overwrite\n");
        return 1;
    }
    printf("No bug observed\n");
    return 0;
}
""")


def main():
    if not os.path.exists(CCC):
        print(f"CCC compiler not found at {CCC}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "bug1.c")
        asm = os.path.join(tmp, "bug1.s")
        exe = os.path.join(tmp, "bug1")
        with open(src, "w") as f:
            f.write(SOURCE)

        # Compile with CCC (assemble only, then GCC links).
        r = subprocess.run([CCC, "-S", src, "-o", asm],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CCC failed to compile:", r.stderr, file=sys.stderr)
            return 2

        r = subprocess.run(["gcc", asm, "-o", exe],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("GCC link failed:", r.stderr, file=sys.stderr)
            return 2

        # Run the test binary.
        r = subprocess.run([exe], capture_output=True, text=True)
        print(r.stdout, end="")
        if r.stderr:
            print("STDERR:", r.stderr, end="", file=sys.stderr)

        if "BUG REPRODUCED" in r.stdout:
            print("\n[REPRO RESULT] PASS — bug triggered")
            return 0
        else:
            print("\n[REPRO RESULT] FAIL — bug not triggered")
            return 1


if __name__ == "__main__":
    sys.exit(main())
