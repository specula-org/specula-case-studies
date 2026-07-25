#!/usr/bin/env python3
"""
Reproduction test for Bug #1 (F1):
Inline-asm with empty outputs/inputs but non-empty caller-saved `clobbers`
is NOT treated as a call point by CCC's liveness analysis. Consequently,
the register allocator places values into caller-saved registers (e.g.,
%r11) across such an asm block, and the asm clobber silently corrupts them.

Root cause: src/backend/liveness.rs:364-370 guards the call-point insertion
on `!outputs.is_empty() || !inputs.is_empty()`, ignoring `clobbers`.

Secondary layer: src/backend/x86/codegen/emit.rs:95-110 — clobber_to_phys
recognises only callee-saved names, so caller-saved names never reach
stack_layout::regalloc_helpers::merge either.

Trigger scenario:
  int main() {
      int a = compute(10);
      int b = compute(20);
      asm volatile("..." ::: "r8","r9","r10","r11","memory");
      return a + b;             // <-- NO further call, so b can land in caller-saved
  }

With no trailing call, Phase 2 assigns `b` to a caller-saved register
(%r11 on x86). The asm writes 0xBAD1 into %r11. The final `a+b` then
uses the garbage.

Expected (correct) answer:  (10*10+7) + (20*20+7) = 107 + 407 = 514.
                            Exit code (int&0xFF) should be 514 & 255 = 2.

Observed on buggy CCC: 60 (from 107 + 0xBAD1 = 107 + 47825 = 47932;
                           47932 & 0xFF = 60).
"""
import os
import shutil
import subprocess
import sys
import tempfile

CCC = "/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler/target/release/ccc-x86"

C_SOURCE = r"""
__attribute__((noinline))
int compute(int x) { return x * x + 7; }

int main(void) {
    int a = compute(10);  // 107
    int b = compute(20);  // 407
    __asm__ __volatile__(
        "movq $0xBAD1, %%r11\n\t"
        "movq $0xBAD2, %%r10\n\t"
        "movq $0xBAD3, %%r9\n\t"
        "movq $0xBAD4, %%r8\n\t"
        : : : "r8", "r9", "r10", "r11", "memory"
    );
    return a + b;  // No further call; b may be in r8-r11.
}
"""


def main() -> int:
    assert shutil.which(CCC) or os.path.exists(CCC), f"ccc-x86 not found at {CCC}"
    if not shutil.which("gcc"):
        print("SKIP: gcc not available for linking", file=sys.stderr)
        return 77

    with tempfile.TemporaryDirectory() as td:
        c_path = os.path.join(td, "repro.c")
        s_path = os.path.join(td, "repro.s")
        bin_path = os.path.join(td, "repro")
        with open(c_path, "w") as f:
            f.write(C_SOURCE)

        r = subprocess.run([CCC, "-S", c_path, "-o", s_path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CCC compile failed:", r.stderr)
            return 2

        asm_text = open(s_path).read()
        print("=== Generated main() body ===")
        inside = False
        for line in asm_text.splitlines():
            if line.startswith("main:"):
                inside = True
            if inside:
                print(line)
            if inside and line.startswith(".size main"):
                break
        print("=== End main() ===")

        r = subprocess.run(["gcc", "-no-pie", s_path, "-o", bin_path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("gcc link failed:", r.stderr)
            return 2

        run = subprocess.run([bin_path], capture_output=True, text=True)
        code = run.returncode
        expected_exit = 514 & 0xFF  # 2
        print(f"\nexit code     = {code}")
        print(f"expected      = {expected_exit} (514 & 0xFF)")
        print(f"             full correct value would be 514")

        # Check: does the asm output show a caller-saved register being used
        # for a value that straddles the asm block? Specifically, look for
        # any reg in {r8,r9,r10,r11} read *after* the 0xBAD1 sequence.
        bad_seen = False
        after_clobber = False
        for line in asm_text.splitlines():
            if "0xBAD1" in line:
                after_clobber = True
                continue
            if after_clobber and line.strip().startswith("movq %rbx,"):
                # only callee-saved reads are OK
                pass
            # Look for a read of r8/r9/r10/r11 between the asm and ret.
            if after_clobber:
                if "addl %r8d" in line or "addl %r9d" in line \
                   or "addl %r10d" in line or "addl %r11d" in line \
                   or "addl %r11w" in line:
                    bad_seen = True
                if line.startswith("    ret"):
                    break

        if code == expected_exit:
            print("\nRESULT: REPRODUCTION FAILED (exit matches). Re-check "
                  "regalloc choice — in some builds, compute() also winds up "
                  "through the i128 / clobber paths.")
            return 1
        print("\nRESULT: BUG REPRODUCED — silent miscompile.")
        print("Details: the CCC regalloc placed a value in a caller-saved")
        print("         register across an inline-asm block whose clobber")
        print("         list includes that same register. The asm corrupted")
        print("         the value and the program returned the wrong answer.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
