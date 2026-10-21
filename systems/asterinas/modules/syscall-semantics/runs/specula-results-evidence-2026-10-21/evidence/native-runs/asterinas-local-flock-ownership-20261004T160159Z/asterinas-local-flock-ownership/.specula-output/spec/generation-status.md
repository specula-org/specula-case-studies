# Local flock revision status

R1–R6 from `review-specgen.md` have been implemented for Asterinas
`0c60537098f4c2949ad2d382aaf499de72263d76`. The review findings were the only
revision input. The brief, analysis, source trees and independent review remain
unchanged. No git command was run and no commit was made.

Open insertion now clones the descriptor reference and retains the open-local
Arc until `ArcPutOpen`, followed by `SysOpenReturn`. Open and flock entry no
longer wait for the FD-table guard. Borrowed-table exclusivity is a separate
single-participant domain assumption. Trace replay searches for one complete
witness through the documented Phase 3 status adapter. C09 retains safety
checks without an unsupported completion claim. C01–C03 assert their return
values, and C10 includes the final independent C open/probe.

SANY parsed, semantically processed and linted all three final modules without
errors. Static auditing confirms 49 base actions, 49 trace dispatch cases,
49 instrumentation rows, and enabled coverage for all ten brief section 5
obligations. Current evidence is under `generation-checks/`. The original
parser logs in `spec/` remain historical generation evidence.

The final synthetic trace checks accepted R1, R2 and R3, plus the borrowed-table
control. They rejected wrong post-state, wrong reference count and the forced
losing serialization. Synthetic fixtures are explicitly generated model tests,
not runtime histories. The adapter emits `success`, `trace_mismatch` or `error`
for Phase 3. The stock MCP raw-output parser must not be used for the inverted
witness invariant. See `Trace.cfg` and `instrumentation-spec.md` for commands.

All 16 hunt configurations have run. Thirteen completed without a violation.
C05 violated `ConversionOracle` in 80 states. C06 violated `ConvertersDrain`
after 57 states and a stuttering suffix. C11 violated `NoRecursiveListWait`
in 34 states. Its enabled `FinalReleaseCompletes` check did not receive a
separate verdict before TLC stopped for the safety violation. These are model
results, not confirmed Asterinas bugs. No outcome or invariant was weakened
in response to a counterexample.

The general `MC.cfg` run reached the 30 minute limit and is INCOMPLETE
(`timeout` exit 124 after 1800.17 seconds). The last TLC progress report,
at 2026-10-05 16:03:54, records 38,007,124 distinct states,
20,165,074 states on the queue and depth 14. No final shutdown
statistics were emitted, so these are the last reported counts, not exact
termination counts. No violation had been reported. This is not a pass.
All 17 configurations ran with at most 3 GiB and two workers, one TLC process
at a time. Metadata remains under `states/`. The original general admission
bounds and symmetry were preserved.

Linux execution, Asterinas execution, runtime instrumentation, runtime trace
convergence, bug confirmation and independent review of the revised version
are NOT RUN. These local checks implement the user's standalone revision
request. They do not claim completion of the campaign's independent corrective
review gate. No nested pipeline or deployment was performed.

`REVISION-2026-10-05.md` records source mappings, assumptions, the acceptance
contract, commands, outcomes and changed files. `sha256sums.txt` binds the
final delivered specification and evidence, excluding itself and its own
verification-output log. See `generation-checks/checksum-check.log`.

The final required trace logs are retained. Five preliminary repeated trace
logs were overwritten during fixture bring-up before attempt-preserving log
names were added. The revision report records this evidence-retention gap.
