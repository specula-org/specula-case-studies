# LiteBox known-aware rerun

## Result

This record preserves a LiteBox Specula rerun focused on maintainer-actionable findings rather than rediscovering already acknowledged technical debt.

- Original Specula run ID: `litebox-rerun-known-aware-gpt56sol-xhigh-20260829`
- Target source: `microsoft/litebox@49f7231eef1f53836648c88bf9897d116fb73a96`
- Initial requested model: `gpt-5.6-sol`, effort `xhigh`
- Final Phase 4 confirmation/classification completion: rerun with `gpt-5.5`, effort `xhigh`
- Final confirmation result: **9 reproduced bugs**, all pipeline-classified as `NEW`
- Severity summary: **3 Critical**, **5 High**, **1 Medium**

The final pipeline reports are [confirmed-bugs.md](confirmed-bugs.md) and [bug-severity.md](bug-severity.md). The pipeline summary is [pipeline-summary.md](pipeline-summary.md).

## Prompt guidance

The rerun added [target-specific guidance](.prompt-extra.md) for LiteBox. The main change from an ordinary run was to make novelty and maintainer awareness first-class confirmation criteria:

- check whether the same mechanism at the same code site is already documented in an issue, PR, source comment, TODO, or FIXME;
- deprioritize already known or maintainer-aware behavior unless the run adds a new harmful consequence, live consumer, or stronger trigger;
- separately record filed duplicate status, maintainer awareness, and newly demonstrated consequence;
- require a real consumer and observable consequence before calling an inconsistency reproduced.

## Bugs ordered by expected reporting value

The ordering below is intended for developer communication. It prioritizes public triggerability, concrete consequence, and evidence quality over severity labels alone.

1. **MC-6, Critical:** stale ELF patch state survives `MAP_FIXED` replacement and later `mprotect(PROT_EXEC)` rewrites bytes in the newer mapping.
2. **MC-9, Critical:** a futex waiter inserted but not yet value-validated can consume a `wake(1)` quota, leaving a validated waiter blocked.
3. **MC-3, High:** `readv` repeatedly resolves the raw fd across chunks, so one syscall can read from two different open-file descriptions after fd reuse.
4. **MC-8, High:** `clone3` can fail argument validation with `EINVAL` after writing a child TID into parent memory.
5. **MC-1, High:** `open(O_CREAT)` can race with `rmdir` and return a writable fd for an unreachable file in a detached parent directory.
6. **MC-2, High:** storing CWD as pathname text can redirect later relative operations to a replacement directory after remove-and-recreate.
7. **MC-4, High:** duplicated directory fds do not share `getdents64` directory position and can repeat entries.
8. **MC-7, Critical, caveated:** SNP spawn failure after child attachment can leak a phantom thread and block quiescence; reproduction requires fault injection for the host-spawn failure path.
9. **MC-5, Medium:** epoll interests retained after last close accumulate across raw-fd reuse; wrong readiness delivery is masked, but resource retention remains.

## Included evidence

This record includes:

- top-level run metadata in [run.json](run.json);
- the analysis and modeling reports: [analysis-report.md](analysis-report.md), [modeling-brief.md](modeling-brief.md), [spec/bug-report.md](spec/bug-report.md), and [spec/brief-coverage.md](spec/brief-coverage.md);
- TLA+ models and model-checking configurations under [spec/](spec/);
- trace harness guidance under [harness/](harness/);
- generated traces under [traces/](traces/);
- reproduction wrappers under [repro/](repro/).

The raw confirmation worktrees, build outputs, provider logs, activity streams, resume files, and full runtime logs are intentionally excluded from the committed record. The committed files keep the reports, specifications, traces, and reproducer scripts needed to audit the summarized findings without storing bulky transient state.
