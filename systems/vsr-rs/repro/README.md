# Reproduce the Three vsr-rs Bugs

Requirements: Linux, Git, Rust/Cargo, Python 3, GNU `timeout`, and available
loopback TCP ports. Cargo may download dependencies. The sender test stops and
resumes only the kvstore child process it starts.

From this directory:

```sh
bash run.sh all
```

To use an existing Git repository containing the pinned revision:

```sh
bash run.sh all /path/to/vsr-rs
```

The runner extracts revision `3ac0104a567092139534c9022205d02281a2da41` into a
temporary directory, limits Cargo to two build jobs, and removes its temporary
source, builds, and runtime files on exit. An existing checkout's worktree and
HEAD are not changed. Run one case by replacing `all` with `CR-1`, `CR-2`, or `CR-3`.

| Case | Expected observation |
| --- | --- |
| CR-1 | The example starts with a malformed view file and overwrites it; a separate public-API schedule commits conflicting slot-1 operations, while the recovery control emits no old-view reply. |
| CR-2 | The three-replica control commits; the singleton ends at `op=1 commit=0 value=0 replies=0`. |
| CR-3 | The healthy 4 MiB SET succeeds; stopping one connected backup leaves the next SET unanswered during the 800 ms observation window. |

Exit 0 means the reproducer observed its expected bug behavior. For CR-3,
exit 1 means the timing-sensitive fault did not trigger and exit 2 means setup
or the healthy control failed. Exact response times depend on the host and TCP
buffers. The short observation window does not establish permanent unavailability.

These scripts preserve the second run's test logic with source/build locations
made configurable. The unmodified originals remain in the
[second-run archive](../modules/core/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/repro/).
