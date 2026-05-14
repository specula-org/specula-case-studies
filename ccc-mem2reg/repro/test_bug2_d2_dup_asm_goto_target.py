#!/usr/bin/env python3
"""
Reproduction for CCC mem2reg Bug 2 (Family F6 / D2):
phi-elimination critical-edge trampoline only retargets ONE edge when the
predecessor terminator (or InlineAsm goto_labels) has multiple edges to the
same target block.

Trigger conditions (in mem2reg/phi_eliminate.rs):
  * The phi-bearing target block has a critical edge from a predecessor P.
  * P's terminator/InlineAsm goto_labels has TWO OR MORE entries pointing
    to that same target block (e.g., switch with `default == case_i`, or
    asm-goto labels list with duplicate entries).
  * `retarget_block_edge_once` rewrites the FIRST matching edge to the new
    trampoline and `return`s, leaving the OTHER edges still pointing to
    the original target.
  * The trampoline carries the phi-copy instruction; runtime paths that take
    one of the un-rewired edges arrive at the target with the phi destination
    REGISTER UNINITIALIZED.

Natural triggers (switch with `default==case_i`) are unreachable from C
source because CCC's frontend emits each case label as a fresh empty block
and `cfg_simplify` doesn't thread switch terminators through them. The
remaining reachable trigger uses `asm goto` with duplicate label entries:

    asm goto("jmp %l1" : : : : bail, bail);

CCC's parser accepts a duplicate identifier in the goto-label list, the
lowering produces `goto_labels = [("bail", B), ("bail", B)]` (two entries to
the SAME BlockId), and the inline-asm backend resolves the positional
reference `%l1` to the SECOND entry. After phi elimination the second entry
is unchanged, so the runtime jump bypasses the trampoline and the phi
destination at `bail` is read uninitialised.

(GCC rejects the duplicate label name, but that doesn't change CCC's bug:
the same retarget-once defect would trigger on any future IR shape with
duplicate switch / asm-goto targets.)

Expected behaviour:
  test(0, 0) returns 7   (asm-goto's snapshot at the asm site)
  test(1, 0) returns 100 (direct goto bypassing the asm-goto path)

Buggy behaviour (CCC):
  test(0, 0) returns garbage from whatever register held a stale value
  (observed: 515 in our run); test(1, 0) returns the correct 100.
"""

import os
import subprocess
import sys
import tempfile
import textwrap

CCC = "/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler/target/release/ccc"

SOURCE = textwrap.dedent(r"""
#include <stdio.h>

int test(int cond, int x) {
    int v;
    if (cond) { v = 100; goto bail; }
    v = 7;
    /* %l1 = positional reference to the SECOND label in the goto list.
       After phi-elim, only the FIRST entry was retargeted to the
       trampoline, so this jump bypasses the phi-copy. */
    asm goto("jmp %l1" : : : : bail, bail);
    v = 99;
    if (x) goto other;
    return v;
other:
    v = 88;
    return v;
bail:
    return v;
}

int main(void) {
    int r00 = test(0, 0);
    int r10 = test(1, 0);
    printf("test(0, 0) = %d (expected 7)\n",  r00);
    printf("test(1, 0) = %d (expected 100)\n", r10);
    /* The cond=0 path goes through the buggy critical edge.
       The cond=1 path goes through a non-critical edge and works. */
    if (r00 != 7 && r10 == 100) {
        printf("BUG REPRODUCED: mem2reg D2 retarget-once bypassed phi copy "
               "(test(0,0) = %d, expected 7 — phi dest uninitialised)\n", r00);
        return 1;
    }
    printf("No bug observed (test(0,0) returned the expected 7)\n");
    return 0;
}
""")


def main():
    if not os.path.exists(CCC):
        print(f"CCC compiler not found at {CCC}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "bug2.c")
        asm = os.path.join(tmp, "bug2.s")
        exe = os.path.join(tmp, "bug2")
        with open(src, "w") as f:
            f.write(SOURCE)

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
