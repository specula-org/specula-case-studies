# Bug Reproduction

## Prerequisites

- Linux x86_64 (tested on Ubuntu 24.04)
- GCC with OpenMP support (`gcc -fopenmp`)
- Java 11+ (for TLC model checker)

## Method 1: TLA+ Model Checking (Recommended)

The bug was originally found via TLA+ model checking. This requires no patched libgomp.

```bash
cd ../spec/

# Download TLC if needed
# wget https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar

# Run the hunting config that finds the bug
java -jar tla2tools.jar -config MC_hunt_cross_cancel_task.cfg MC.tla
```

Expected output: `BarrierSafety` invariant violation with a counterexample showing
`PrimaryHandleTaskLast` overwriting BAR_CANCELLED.

## Method 2: Legitimate OpenMP Reproduction (Final Barrier Path)

This reproduces the bug using only standard OpenMP code. Requires building
NVIDIA's patched libgomp with a bug detector.

### Step 1: Build patched libgomp

```bash
# Clone GCC and apply NVIDIA's patches
cd ../artifact/
./setup.sh

# Apply the bug detector patch (adds fprintf before barrier_done)
cd gcc/
git apply ../patches/bug_detector.patch

# Build libgomp
mkdir -p /tmp/libgomp-build && cd /tmp/libgomp-build
/path/to/artifact/gcc/libgomp/configure \
    --disable-multilib CC=gcc CXX=g++ CFLAGS="-g -O2" CXXFLAGS="-g -O2"
make -j$(nproc) libgomp.la
```

### Step 2: Build and run the test

```bash
cd /path/to/repro/
gcc -fopenmp -O2 -o final_barrier_cancel_task final_barrier_cancel_task.c

LD_LIBRARY_PATH=/tmp/libgomp-build/.libs \
OMP_CANCELLATION=true \
OMP_NUM_THREADS=4 \
./final_barrier_cancel_task
```

### Expected output

On stderr (bug detection):
```
*** BUG DETECTED (tasks done, incr=32): BAR_CANCELLED (gen=0x6) about to be overwritten! team_cancelled=1 ***
```

On stdout (test progress):
```
Trial  0: tasks_executed=300/500 (partial)
Trial  1: tasks_executed=77/500 (partial)
...
```

Key indicators:
- `incr=32` = BAR_HOLDING_SECONDARIES (final barrier path)
- `gen=0x6` = BAR_CANCELLED (0x4) | BAR_WAITING_FOR_TASK (0x2)
- `(partial)` = cancel fired mid-execution — the trigger condition
- Typically 5-19 BUG DETECTED per run (20 trials)

### How it works

The test creates a parallel region with 4 threads:
- Thread 0 creates 500 deferred tasks with ~0.1ms busy work each
- Thread 1 waits 5ms, then issues `#pragma omp cancel parallel`
- Threads 0,2,3 reach the implicit barrier and start executing tasks
- After 5ms, cancel fires mid-execution → BAR_CANCELLED set
- Remaining tasks are cancelled; barrier_done overwrites BAR_CANCELLED

The 5ms delay (`usleep(5000)`) ensures cancel arrives during the task execution
window (~22ms total). In production, this timing gap occurs naturally from
workload variation and OS scheduling jitter.

---

## Bug #29: omp_fulfill_event Deadlock (Unshackled Thread)

**Severity**: Critical — deterministic deadlock
**Affects**: All GCC versions since 11 (stock GCC, not patch-specific)

### Quick Test (uses system libgomp)

```bash
cd repro/
gcc -fopenmp -O2 -lpthread -o detach_repro detach_fulfill_deadlock.c
timeout 5 ./detach_repro
echo $?  # 124 = deadlock confirmed
```

### Full A/B Controlled Test

The script `test_bug29.sh` performs a rigorous A/B comparison:

1. Clones GCC 14.2 source (sparse checkout, libgomp only)
2. Builds **unpatched** libgomp from source
3. Applies the one-line fix and builds **patched** libgomp
4. Runs the same reproduction program against both
5. Reports results

```bash
cd repro/
chmod +x test_bug29.sh
./test_bug29.sh
```

Expected output:
```
  Unpatched: 5/5 deadlocked, 0/5 passed
  Patched:   0/5 deadlocked, 5/5 passed

  BUG CONFIRMED: 5/5 deadlock without fix, 5/5 pass with fix.
```

The two libgomp builds differ by **exactly one line** in `task.c`:
```c
gomp_team_barrier_set_task_pending (&team->barrier);
```

### How the Reproduction Works

The program (`detach_fulfill_deadlock.c`) creates:
1. A parallel region with 4 threads
2. A detached task (via `#pragma omp task detach(ev)`) with **no dependent tasks**
3. An external pthread that calls `omp_fulfill_event` after 200ms

The 200ms delay ensures all team threads have entered the barrier wait loop
before the event is fulfilled.  Without the delay, the bug still exists but
may not trigger deterministically (the task body might not have returned yet).

The program uses only standard OpenMP 5.0 API and POSIX threads.  It is
structurally identical to GCC's own test `task-detach-13.c` (commit ba886d0c),
except without `depend` clauses — which is what triggers the buggy code path.

---

## Candidate #30: Relaxed Publish Probe (Execution Repro)

This is an execution-path stress repro for the relaxed publish candidate in the
cancellable barrier fallback path.

### Build

```bash
cd repro/
gcc -O2 -g -fopenmp -pthread -o cancel_relaxed_publish_probe cancel_relaxed_publish_probe.c
```

### Run

```bash
cd repro/
LIBGOMP_DIR=/path/to/libgomp/.libs ./test_bug30_candidate.sh
```

Useful knobs:

```bash
TRIALS=10000 THREADS=16 RUN_TIMEOUT=120 \
LIBGOMP_DIR=/path/to/libgomp/.libs \
./test_bug30_candidate.sh
```

Expected interpretation:
- If output/log contains `WEAKMEM_PROBE_STALE`, script exits non-zero (`FAIL`).
- If no probe hit is observed, script exits 0 (`inconclusive`, not a proof of absence).

Note: this script checks for runtime probe output; it is most useful with a
libgomp build that includes weak-memory probe instrumentation.

---

## Files

| File | Description |
|------|-------------|
| `final_barrier_cancel_task.c` | Bug #28: cancel+task race trigger (standard OpenMP) |
| `detach_fulfill_deadlock.c` | Bug #29: detach fulfill deadlock (standard OpenMP 5.0 + pthread) |
| `cancel_relaxed_publish_probe.c` | Candidate #30: cancel-path stress workload |
| `test_bug29.sh` | Bug #29: self-contained A/B test script |
| `test_bug30_candidate.sh` | Candidate #30: probe runner |
| `patches/bug29-fulfill-event-set-task-pending.patch` | Bug #29: GCC patch |
| `README.md` | This file |
