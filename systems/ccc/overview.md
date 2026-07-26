# CCC

## Scope

Specula analyzed and tested CCC's mem2reg and register-allocation modules, including dominator and dominance-frontier construction, phi placement, renaming and elimination, liveness analysis, linear-scan allocation, callee/caller-saved assignment, and spilling.

## Bugs

Specula found 2 new bugs:

- Two asm-goto edges to the same block overwrite one mem2reg snapshot, allowing the earlier edge to receive a later value and silently miscompile the program.
- The register allocator can keep a live value in a caller-saved register named in an inline-assembly clobber list, producing a wrong result.
