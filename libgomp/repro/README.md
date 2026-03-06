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

## Files

| File | Description |
|------|-------------|
| `final_barrier_cancel_task.c` | Legitimate trigger via final barrier (standard OpenMP) |
| `README.md` | This file |
