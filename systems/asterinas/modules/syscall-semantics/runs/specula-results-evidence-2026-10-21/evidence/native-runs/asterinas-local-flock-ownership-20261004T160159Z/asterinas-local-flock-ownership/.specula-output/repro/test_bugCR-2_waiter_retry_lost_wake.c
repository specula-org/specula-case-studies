/*
 * CR-2 reproduction test: waiter registration, notification, and retry
 * against a new blocker (flock).
 *
 * Hypothesis under test (code-review finding CR-2): a release or replacement
 * overlapping actual registration (C07), migration between two SH blockers
 * (C08), or a wake race (C09) can leave a live blocked flock request without
 * a notification or a reachable registration/retry path, i.e. a lost wake.
 *
 * Observable failure criterion: a blocking flock() call never returns even
 * though every blocker has provably released, proven by a fresh open file
 * description successfully taking LOCK_EX|LOCK_NB afterwards. The flock wait
 * machinery has no timers or spurious re-wakes, so a lost notification is
 * permanent; a 10 second per-wait deadline is unambiguous.
 *
 * Escalation levels:
 *   Level 0 (default): pure black-box real syscalls with randomized release
 *     timing (racy window hunt) plus churn-storm rounds.
 *   Level 1 (only when the kernel exposes the campaign's test hooks via
 *     prctl(0x53504543,...)): deterministic window forcing with the
 *     gate/gate_wait/release_gate hooks. These hooks only spin-wait at
 *     chosen points; the kernel logic is unchanged. Skipped on Linux, where
 *     the probe prctl returns EINVAL.
 *
 *     Level-1 note: the gate hooks spin in kernel mode, which Asterinas
 *     cannot preempt. While a gate is held, the frozen task therefore
 *     occupies its CPU, and any OTHER task that parks and is woken onto
 *     that CPU starves forever. To keep the fixture sound, every worker
 *     that does not participate in a gated pattern is parked on a blocking
 *     flock on a separate inode first, so that no task issues syscalls
 *     (and thus no task can park on the contended signal-disposition
 *     mutex taken on every syscall exit) while a gate is held. An earlier
 *     revision froze the second of two waiters with gate_wait while the
 *     third worker and the controller kept polling; the resulting
 *     starvation deadlock was a fixture artifact, not a flock defect.
 *
 * Build: gcc -O2 -static -pthread test_bugCR-2_waiter_retry_lost_wake.c -o init
 * On Asterinas (as initramfs /init, PID 1) the test powers off the VM at the
 * end; on Linux it runs as an ordinary binary (control run).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static const char *fixture_path = "/tmp/specula-flock";
static const char *park_path = "/tmp/specula-flock-park";
#define SPEC_PRCTL 0x53504543

static long control(long op, long a, long b, long c)
{
    return syscall(SYS_prctl, SPEC_PRCTL, op, a, b, c);
}

/* ---- diagnostics and verdict bookkeeping ---- */

static int failures;
static int lost_wake_events;

static void failf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("CR2-FAIL: ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    failures++;
}

static uint64_t now_ns(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t))
        failf("clock_gettime failed errno=%d", errno);
    return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}

static void spin_wait_ns(uint64_t ns)
{
    uint64_t deadline = now_ns() + ns;
    while (now_ns() < deadline)
        sched_yield();
}

/* wait until *value == wanted with a deadline; 0 on success, -1 on timeout */
static int wait_atomic_deadline(atomic_int *value, int wanted, uint64_t deadline_ns,
                                const char *what)
{
    while (atomic_load_explicit(value, memory_order_acquire) != wanted) {
        if (now_ns() >= deadline_ns) {
            failf("TIMEOUT waiting for %s", what);
            return -1;
        }
        sched_yield();
    }
    return 0;
}

/* ---- per-thread RNG for racy timing ---- */

static inline uint32_t xorshift(uint32_t *state)
{
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static void jitter(uint32_t *rng, uint32_t scale)
{
    uint32_t rounds = xorshift(rng) % scale;
    volatile uint32_t sink = 0;
    for (uint32_t i = 0; i < rounds; i++)
        sink += i;
    (void)sink;
}

/* ---- worker machinery ---- */

enum {
    CMD_NONE = 0,
    CMD_REGISTER, /* register this task as tracee w->tid */
    CMD_FLOCK,    /* flock(w->fd, w->op); if w->unlock_after, LOCK_UN on success */
    CMD_CHURN,    /* free-run nonblocking flock ops until churn flag clears, then LOCK_UN */
};

struct worker {
    pthread_t thread;
    atomic_int command;
    atomic_int done;
    atomic_int churn;
    int tid; /* tracee id when registered */
    int cmd;
    int fd;
    int op;
    int unlock_after;
    int result;
    int err;
    uint32_t rng;
};

static struct worker workers[3];
static int worker_cpu[3];

static void *worker_main(void *argument)
{
    struct worker *w = argument;
    unsigned cpu;
    if (!syscall(SYS_getcpu, &cpu, NULL, NULL))
        worker_cpu[w - workers] = (int)cpu;
    for (;;) {
        if (wait_atomic_deadline(&w->command, 1, now_ns() + 120000000000ULL, "worker command") != 0)
            _exit(3);
        atomic_store_explicit(&w->command, 0, memory_order_release);
        errno = 0;
        switch (w->cmd) {
        case CMD_REGISTER:
            /* register returns 0 on success (prctl convention of the hook) */
            w->result = (control(1, w->tid, 0, 0) == 0) ? 0 : -1;
            w->err = errno;
            break;
        case CMD_FLOCK:
            w->result = flock(w->fd, w->op);
            w->err = errno;
            if (w->unlock_after && w->result == 0)
                flock(w->fd, LOCK_UN);
            break;
        case CMD_CHURN:
            while (atomic_load_explicit(&w->churn, memory_order_acquire)) {
                uint32_t pick = xorshift(&w->rng) % 3;
                int op = pick == 0 ? (LOCK_SH | LOCK_NB)
                                   : (pick == 1 ? (LOCK_EX | LOCK_NB) : LOCK_UN);
                flock(w->fd, op);
                jitter(&w->rng, 400);
            }
            flock(w->fd, LOCK_UN);
            w->result = 0;
            break;
        default:
            w->result = -1;
            break;
        }
        atomic_store_explicit(&w->done, 1, memory_order_release);
    }
    return NULL;
}

static void worker_arm(struct worker *w, int cmd, int fd, int op, int unlock_after)
{
    w->cmd = cmd;
    w->fd = fd;
    w->op = op;
    w->unlock_after = unlock_after;
    w->result = -999;
    w->err = 0;
    atomic_store_explicit(&w->done, 0, memory_order_release);
    atomic_store_explicit(&w->command, 1, memory_order_release);
}

static void worker_churn_on(struct worker *w, int fd)
{
    w->cmd = CMD_CHURN;
    w->fd = fd;
    atomic_store_explicit(&w->done, 0, memory_order_release);
    atomic_store_explicit(&w->churn, 1, memory_order_release);
    atomic_store_explicit(&w->command, 1, memory_order_release);
}

static void worker_churn_off(struct worker *w)
{
    atomic_store_explicit(&w->churn, 0, memory_order_release);
}

static int worker_wait(struct worker *w, const char *what)
{
    uint64_t deadline = now_ns() + 10000000000ULL; /* 10 s */
    char label[128];
    snprintf(label, sizeof(label), "%s (tid=%d done)", what, w->tid);
    if (wait_atomic_deadline(&w->done, 1, deadline, label) != 0) {
        lost_wake_events++;
        printf("CR2-LOST-WAKE: worker tid=%d blocked %s never completed while no lock remains\n",
               w->tid, what);
        fflush(stdout);
        return -1;
    }
    if (w->cmd == CMD_FLOCK && w->result != 0) {
        failf("%s returned %d errno=%d (expected 0)", what, w->result, w->err);
        return -1;
    }
    if (w->cmd == CMD_REGISTER && w->result != 0) {
        failf("%s: tracee registration rejected (result=%d)", what, w->result);
        return -1;
    }
    return 0;
}

/* Prove that no flock is held on the fixture inode: a fresh OFD must be able
 * to take LOCK_EX nonblockingly. The probe fd is opened once and carries no
 * flock itself. */
static int probe_fd = -1;

static int current_cpu(void)
{
    unsigned cpu;
    if (syscall(SYS_getcpu, &cpu, NULL, NULL))
        return -1;
    return (int)cpu;
}

static int controller_cpu = -1;
/* Index of the worker that will play the gate-frozen role; it must run on a
 * different CPU than the controller (see the Level-1 note above). */
static int w_frozen = -1;

static int quiet_probe(const char *where)
{
    if (flock(probe_fd, LOCK_EX | LOCK_NB) != 0) {
        failf("quiet probe at %s failed with errno=%d (a lock is still held)", where, errno);
        return -1;
    }
    if (flock(probe_fd, LOCK_UN) != 0) {
        failf("quiet probe unlock at %s failed with errno=%d", where, errno);
        return -1;
    }
    return 0;
}

static int open_fixture(void)
{
    int fd = open(fixture_path, O_RDWR);
    if (fd < 0)
        failf("open(%s) failed errno=%d", fixture_path, errno);
    return fd;
}

/* ---- Level 0: racy black-box patterns ---- */

static uint32_t level0_rng = 0x20261004u;

static int level0_epilogue(int a, int b, int c, int d, const char *where)
{
    if (quiet_probe(where) != 0)
        return -1;
    if (d >= 0)
        close(d);
    if (c >= 0)
        close(c);
    if (b >= 0)
        close(b);
    if (a >= 0)
        close(a);
    return 0;
}

/* C07: explicit release (LOCK_UN) racing the waiter's registration/park. */
static int pattern_c07_release(int iter)
{
    int a = open_fixture(), b = open_fixture();
    if (a < 0 || b < 0)
        return -1;
    if (flock(a, LOCK_EX | LOCK_NB) != 0) {
        failf("c07 iter=%d acquire errno=%d", iter, errno);
        return -1;
    }
    worker_arm(&workers[0], CMD_FLOCK, b, LOCK_EX, 1);
    jitter(&level0_rng, 20000);
    if (flock(a, LOCK_UN) != 0) {
        failf("c07 iter=%d unlock errno=%d", iter, errno);
        return -1;
    }
    if (worker_wait(&workers[0], "c07 waiter") != 0)
        return -1;
    return level0_epilogue(a, b, -1, -1, "c07");
}

/* C07-replacement: the owner converts SH->EX (item replacement drops the old
 * item and wakes its queue) while the waiter is blocked on the old item,
 * converts back, and then releases. */
static int pattern_c07_convert(int iter)
{
    int a = open_fixture(), b = open_fixture();
    if (a < 0 || b < 0)
        return -1;
    if (flock(a, LOCK_SH | LOCK_NB) != 0) {
        failf("c07c iter=%d acquire errno=%d", iter, errno);
        return -1;
    }
    worker_arm(&workers[0], CMD_FLOCK, b, LOCK_EX, 1);
    jitter(&level0_rng, 20000);
    if (flock(a, LOCK_EX | LOCK_NB) != 0) { /* replacement, old queue woken */
        failf("c07c iter=%d convert errno=%d", iter, errno);
        return -1;
    }
    jitter(&level0_rng, 8000);
    if (flock(a, LOCK_SH | LOCK_NB) != 0) { /* replacement back */
        failf("c07c iter=%d convert back errno=%d", iter, errno);
        return -1;
    }
    jitter(&level0_rng, 8000);
    if (flock(a, LOCK_UN) != 0) {
        failf("c07c iter=%d unlock errno=%d", iter, errno);
        return -1;
    }
    if (worker_wait(&workers[0], "c07c waiter") != 0)
        return -1;
    return level0_epilogue(a, b, -1, -1, "c07c");
}

/* C08: two SH blockers; the waiter (EX) registers on the first; releasing the
 * first forces retry migration onto the second; releasing the second must
 * complete the waiter. */
static int pattern_c08_migration(int iter)
{
    int a = open_fixture(), b = open_fixture(), c = open_fixture();
    if (a < 0 || b < 0 || c < 0)
        return -1;
    if (flock(a, LOCK_SH | LOCK_NB) != 0 || flock(b, LOCK_SH | LOCK_NB) != 0) {
        failf("c08 iter=%d acquire errno=%d", iter, errno);
        return -1;
    }
    worker_arm(&workers[0], CMD_FLOCK, c, LOCK_EX, 1);
    jitter(&level0_rng, 20000);
    if (flock(a, LOCK_UN) != 0) { /* migration trigger */
        failf("c08 iter=%d unlock a errno=%d", iter, errno);
        return -1;
    }
    jitter(&level0_rng, 12000);
    if (flock(b, LOCK_UN) != 0) {
        failf("c08 iter=%d unlock b errno=%d", iter, errno);
        return -1;
    }
    if (worker_wait(&workers[0], "c08 waiter") != 0)
        return -1;
    return level0_epilogue(a, b, c, -1, "c08");
}

/* C09: two waiters blocked on one owner; the release wakes both; each
 * acquires and releases in turn. */
static int pattern_c09_two_waiters(int iter)
{
    int a = open_fixture(), b = open_fixture(), c = open_fixture();
    if (a < 0 || b < 0 || c < 0)
        return -1;
    if (flock(a, LOCK_EX | LOCK_NB) != 0) {
        failf("c09 iter=%d acquire errno=%d", iter, errno);
        return -1;
    }
    worker_arm(&workers[0], CMD_FLOCK, b, LOCK_EX, 1);
    jitter(&level0_rng, 6000);
    worker_arm(&workers[1], CMD_FLOCK, c, LOCK_EX, 1);
    jitter(&level0_rng, 20000);
    if (flock(a, LOCK_UN) != 0) {
        failf("c09 iter=%d unlock errno=%d", iter, errno);
        return -1;
    }
    if (worker_wait(&workers[0], "c09 waiter 1") != 0)
        return -1;
    if (worker_wait(&workers[1], "c09 waiter 2") != 0)
        return -1;
    return level0_epilogue(a, b, c, -1, "c09");
}

/* Release via close (InodeHandle::drop -> unlock): the owner's fd is closed
 * while the waiter is blocked. */
static int pattern_release_via_close(int iter)
{
    int a = open_fixture(), b = open_fixture();
    if (a < 0 || b < 0)
        return -1;
    if (flock(a, LOCK_EX | LOCK_NB) != 0) {
        failf("close-rel iter=%d acquire errno=%d", iter, errno);
        return -1;
    }
    worker_arm(&workers[0], CMD_FLOCK, b, LOCK_EX, 1);
    jitter(&level0_rng, 20000);
    if (close(a) != 0) { /* release happens in the destructor path */
        failf("close-rel iter=%d close errno=%d", iter, errno);
        return -1;
    }
    if (worker_wait(&workers[0], "close-rel waiter") != 0)
        return -1;
    return level0_epilogue(-1, b, -1, -1, "close-rel");
}

/* Churn storm: two workers free-run nonblocking SH/EX/UN (repeated item
 * replacement and removal, each waking registered waiters) while a third
 * worker holds a blocking EX request; the churn then stops and releases; the
 * blocking request must complete. */
static int pattern_churn_storm(int round)
{
    int fa = open_fixture(), fb = open_fixture(), fc = open_fixture();
    if (fa < 0 || fb < 0 || fc < 0) {
        failf("churn round=%d open failed", round);
        return -1;
    }
    worker_churn_on(&workers[0], fa);
    worker_churn_on(&workers[1], fb);
    spin_wait_ns(1000000 + (xorshift(&level0_rng) % 4000000));
    worker_arm(&workers[2], CMD_FLOCK, fc, LOCK_EX, 1);
    spin_wait_ns(1000000 + (xorshift(&level0_rng) % 4000000));
    worker_churn_off(&workers[0]);
    worker_churn_off(&workers[1]);
    if (worker_wait(&workers[0], "churn worker 0 quiesce") != 0)
        return -1;
    if (worker_wait(&workers[1], "churn worker 1 quiesce") != 0)
        return -1;
    if (worker_wait(&workers[2], "churn-storm waiter") != 0)
        return -1;
    return level0_epilogue(fa, fb, fc, -1, "churn");
}

static int run_level0(void)
{
    const int iters = 400;
    printf("CR2-LEVEL0-BEGIN patterns=5 iters=%d\n", iters);
    fflush(stdout);
    for (int i = 0; i < iters; i++) {
        if (pattern_c07_release(i) != 0 || pattern_c07_convert(i) != 0 ||
            pattern_c08_migration(i) != 0 || pattern_c09_two_waiters(i) != 0 ||
            pattern_release_via_close(i) != 0) {
            return -1;
        }
        if ((i % 100) == 99) {
            printf("CR2-LEVEL0-PROGRESS iter=%d\n", i + 1);
            fflush(stdout);
        }
    }
    const int rounds = 60;
    for (int r = 0; r < rounds; r++) {
        if (pattern_churn_storm(r) != 0)
            return -1;
        if ((r % 20) == 19) {
            printf("CR2-LEVEL0-CHURN-PROGRESS round=%d\n", r + 1);
            fflush(stdout);
        }
    }
    printf("CR2-LEVEL0-END ok\n");
    fflush(stdout);
    return 0;
}

/* ---- Level 1: deterministic window forcing via the campaign test hooks ---- */

static int instrumented;
static long cpus;

/* fine-grained Level-1 progress marker for bisection on the serial console */
static int l1_step;
#define L1STEP(msg) do { printf("CR2-L1-STEP %d %s\n", ++l1_step, msg); fflush(stdout); } while (0)

/* Boundary codes of the trace state machine:
 * 1 TrySetLockRegister, 2 FlockOwnerUpgrade, 3 unlockEnter(reentrant),
 * 4 SysFlockReturn, 5 SchedulerParkCommit, 6 WakerDoWait(!consumed),
 * 7 FileTableInsert. info(tid,2) returns ((index+1)<<8)|boundary. */
static long boundary_of(int tid)
{
    return control(2, tid, 2, 0);
}

static long published_of(int tid)
{
    return control(2, tid, 0, 0);
}

/* Wait for the given boundary to be recorded after the given event index. */
static int wait_boundary_after(int tid, int boundary, long min_index, const char *what)
{
    uint64_t deadline = now_ns() + 10000000000ULL;
    for (;;) {
        long obs = boundary_of(tid);
        if ((obs & 255) == boundary && (obs >> 8) > min_index)
            return 0;
        if (now_ns() >= deadline) {
            failf("TIMEOUT waiting for boundary %d of tid %d (%s)", boundary, tid, what);
            return -1;
        }
        sched_yield();
    }
}

/* Open-once cached fixtures for Level 1: the instrumentation budgets 16
 * traced allocations per task, so tracee-controlled OFDs must be reused
 * across repetitions. */
static int open_cached(int *slot)
{
    if (*slot < 0)
        *slot = open_fixture();
    return *slot;
}

/*
 * Parking: while a gate hook is armed, the frozen task spins in kernel mode
 * and cannot be preempted, so it occupies its CPU until the gate opens. Any
 * other task that parks in that window and is woken onto that CPU starves.
 * To keep the fixture sound, non-participating workers are parked here on a
 * blocking LOCK_SH against the controller's LOCK_EX on a separate inode, so
 * they issue no syscalls while a gate is held.
 */
static int park_fd = -1;               /* controller's EX on the park inode */
static int park_wfd[3] = {-1, -1, -1}; /* per-worker park fds (own OFDs) */

static int park_init(void)
{
    int setup = open(park_path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (setup < 0) {
        failf("park fixture create errno=%d", errno);
        return -1;
    }
    close(setup);
    park_fd = open(park_path, O_RDWR);
    if (park_fd < 0)
        return -1;
    for (int i = 0; i < 3; i++) {
        park_wfd[i] = open(park_path, O_RDWR);
        if (park_wfd[i] < 0)
            return -1;
    }
    return 0;
}

/* Park the workers whose flags are set; each parks on a blocking LOCK_SH. */
static int park_workers(int w0, int w1, int w2)
{
    if (flock(park_fd, LOCK_EX | LOCK_NB) != 0) {
        failf("park hold errno=%d", errno);
        return -1;
    }
    long before[3] = {published_of(2), published_of(3), published_of(4)};
    if (w0)
        worker_arm(&workers[0], CMD_FLOCK, park_wfd[0], LOCK_SH, 1);
    if (w1)
        worker_arm(&workers[1], CMD_FLOCK, park_wfd[1], LOCK_SH, 1);
    if (w2)
        worker_arm(&workers[2], CMD_FLOCK, park_wfd[2], LOCK_SH, 1);
    if (w0 && wait_boundary_after(2, 5, before[0], "park worker 0") != 0)
        return -1;
    if (w1 && wait_boundary_after(3, 5, before[1], "park worker 1") != 0)
        return -1;
    if (w2 && wait_boundary_after(4, 5, before[2], "park worker 2") != 0)
        return -1;
    return 0;
}

/* Release the parked workers; each wakes, takes LOCK_SH, unlocks, and done. */
static int unpark_workers(int w0, int w1, int w2)
{
    if (flock(park_fd, LOCK_UN) != 0) {
        failf("park release errno=%d", errno);
        return -1;
    }
    if (w0 && worker_wait(&workers[0], "unpark worker 0") != 0)
        return -1;
    if (w1 && worker_wait(&workers[1], "unpark worker 1") != 0)
        return -1;
    if (w2 && worker_wait(&workers[2], "unpark worker 2") != 0)
        return -1;
    return 0;
}

/* C07-notify window: the notification is delivered while the waiter is
 * between the has_woken swap and the park (frozen by gate_wait). */
static int level1_notify_before_park(void)
{
    static int a = -1, b = -1;
    int park[3] = {1, 1, 1};
    if (open_cached(&a) < 0 || open_cached(&b) < 0)
        return -1;
    park[w_frozen] = 0;
    if (park_workers(park[0], park[1], park[2]) != 0)
        return -1;
    if (flock(a, LOCK_EX | LOCK_NB) != 0) {
        failf("l1a acquire errno=%d", errno);
        return -1;
    }
    long before = published_of(w_frozen + 2);
    control(8, w_frozen + 2, 0, 0); /* gate_wait: freeze the waiter before park */
    worker_arm(&workers[w_frozen], CMD_FLOCK, b, LOCK_EX, 1);
    if (wait_boundary_after(w_frozen + 2, 6, before, "l1a waiter frozen in do_wait") != 0)
        return -1;
    if (flock(a, LOCK_UN) != 0) { /* notification lands while the waiter is unparked */
        failf("l1a unlock errno=%d", errno);
        return -1;
    }
    control(6, 0, 0, 0); /* release the gate: waiter proceeds to the park check */
    if (worker_wait(&workers[w_frozen], "l1a waiter") != 0)
        return -1;
    if (quiet_probe("l1a") != 0)
        return -1;
    return unpark_workers(park[0], park[1], park[2]);
}

/* C08 migration with the first window frozen: SH-A and SH-B; the waiter (EX)
 * is frozen after registering on A; A releases (wake pending, waiter frozen
 * at the gate); the gate opens; the waiter retries, registers on B and parks
 * (real park confirmed via boundary 5); B releases; the waiter must
 * complete. */
static int level1_migration(void)
{
    static int a = -1, b = -1, c = -1;
    int park[3] = {1, 1, 1};
    if (open_cached(&a) < 0 || open_cached(&b) < 0 || open_cached(&c) < 0)
        return -1;
    park[w_frozen] = 0;
    if (park_workers(park[0], park[1], park[2]) != 0)
        return -1;
    if (flock(a, LOCK_SH | LOCK_NB) != 0 || flock(b, LOCK_SH | LOCK_NB) != 0) {
        failf("l1b acquire errno=%d", errno);
        return -1;
    }
    long before = published_of(w_frozen + 2);
    control(8, w_frozen + 2, 0, 0);
    worker_arm(&workers[w_frozen], CMD_FLOCK, c, LOCK_EX, 1);
    if (wait_boundary_after(w_frozen + 2, 6, before, "l1b waiter frozen on first blocker") != 0)
        return -1;
    if (flock(a, LOCK_UN) != 0) {
        failf("l1b unlock a errno=%d", errno);
        return -1;
    }
    control(6, 0, 0, 0);
    if (wait_boundary_after(w_frozen + 2, 5, before, "l1b waiter parked on second blocker") != 0)
        return -1;
    if (flock(b, LOCK_UN) != 0) {
        failf("l1b unlock b errno=%d", errno);
        return -1;
    }
    if (worker_wait(&workers[w_frozen], "l1b waiter") != 0)
        return -1;
    if (quiet_probe("l1b") != 0)
        return -1;
    return unpark_workers(park[0], park[1], park[2]);
}

/* C09 two-waiter wake race, deterministic without freezing: both waiters
 * register on the owner's queue and are confirmed parked (boundary 5 each);
 * the release's wake_all pops both wakers; the first waiter acquires and
 * releases; the second must re-register on the new blocker, be woken by its
 * release, and complete. This is the campaign's C09 fixture shape. */
static int level1_two_waiters(void)
{
    static int a = -1, b = -1, c = -1;
    if (open_cached(&a) < 0 || open_cached(&b) < 0 || open_cached(&c) < 0)
        return -1;
    if (park_workers(0, 0, 1) != 0)
        return -1;
    if (flock(a, LOCK_EX | LOCK_NB) != 0) {
        failf("l1c acquire errno=%d", errno);
        return -1;
    }
    long before2 = published_of(2);
    worker_arm(&workers[0], CMD_FLOCK, b, LOCK_EX, 1);
    if (wait_boundary_after(2, 5, before2, "l1c waiter 1 parked") != 0)
        return -1;
    long before3 = published_of(3);
    worker_arm(&workers[1], CMD_FLOCK, c, LOCK_EX, 1);
    if (wait_boundary_after(3, 5, before3, "l1c waiter 2 parked") != 0)
        return -1;
    if (flock(a, LOCK_UN) != 0) { /* wake_all pops both wakers */
        failf("l1c unlock errno=%d", errno);
        return -1;
    }
    if (worker_wait(&workers[0], "l1c waiter 1") != 0)
        return -1;
    if (worker_wait(&workers[1], "l1c waiter 2") != 0)
        return -1;
    if (quiet_probe("l1c") != 0)
        return -1;
    return unpark_workers(0, 0, 1);
}

/* C07-before window, release wins the list mutex: the releaser is frozen by
 * gate(fd) inside unlock's retain scan (holding the list mutex); the
 * waiter's first try_set_lock then blocks on the list mutex; opening the
 * gate lets the unlock finish (the wake queue is empty), after which the
 * waiter's scan must find no conflict and acquire immediately. */
static int level1_release_wins_mutex(void)
{
    static int a = -1, b = -1;
    int w_waiter = (w_frozen == 0) ? 1 : 0;
    int park[3] = {0, 0, 0};
    if (open_cached(&a) < 0 || open_cached(&b) < 0)
        return -1;
    park[3 - w_frozen - w_waiter] = 1;
    if (park_workers(park[0], park[1], park[2]) != 0)
        return -1;
    if (flock(a, LOCK_EX | LOCK_NB) != 0) {
        failf("l1d acquire errno=%d", errno);
        return -1;
    }
    control(5, a, 0, 0); /* gate(a): freeze unlock's retain scan on a's item */
    long before = published_of(w_frozen + 2);
    worker_arm(&workers[w_frozen], CMD_FLOCK, a, LOCK_UN, 0);
    if (wait_boundary_after(w_frozen + 2, 2, before, "l1d releaser frozen in retain scan") != 0)
        return -1;
    worker_arm(&workers[w_waiter], CMD_FLOCK, b, LOCK_EX, 1);
    spin_wait_ns(50000000); /* let the waiter block on the list mutex */
    control(6, 0, 0, 0);
    if (worker_wait(&workers[w_frozen], "l1d releaser") != 0)
        return -1;
    if (worker_wait(&workers[w_waiter], "l1d waiter") != 0)
        return -1;
    if (quiet_probe("l1d") != 0)
        return -1;
    return unpark_workers(park[0], park[1], park[2]);
}

static int run_level1(void)
{
    if (!instrumented) {
        printf("CR2-LEVEL1-SKIPPED (no test hooks: not the instrumented kernel)\n");
        fflush(stdout);
        return 0;
    }
    printf("CR2-LEVEL1-BEGIN hooks=gate,gate_wait,release_gate smp=%ld\n", cpus);
    fflush(stdout);
    /* register the controller and all three workers as tracees */
    L1STEP("register-controller");
    if (control(1, 1, 0, 0) != 0) {
        failf("controller tracee registration failed");
        return -1;
    }
    L1STEP("register-worker-2");
    worker_arm(&workers[0], CMD_REGISTER, 0, 0, 0);
    if (worker_wait(&workers[0], "register tid2") != 0)
        return -1;
    L1STEP("register-worker-3");
    worker_arm(&workers[1], CMD_REGISTER, 0, 0, 0);
    if (worker_wait(&workers[1], "register tid3") != 0)
        return -1;
    L1STEP("register-worker-4");
    worker_arm(&workers[2], CMD_REGISTER, 0, 0, 0);
    if (worker_wait(&workers[2], "register tid4") != 0)
        return -1;
    L1STEP("park-init");
    if (park_init() != 0)
        return -1;
    /* Choose the gate-frozen role among workers on a CPU different from the
     * controller's; the frozen task spins in kernel mode and occupies its
     * CPU until the gate opens, so the controller must not share that CPU. */
    for (int i = 0; i < 3; i++) {
        if (worker_cpu[i] >= 0 && controller_cpu >= 0 && worker_cpu[i] != controller_cpu) {
            w_frozen = i;
            break;
        }
    }
    if (w_frozen < 0) {
        printf("CR2-LEVEL1-PLACEMENT-SKIP controller_cpu=%d worker_cpus=%d,%d,%d (no worker on a different CPU)\n",
               controller_cpu, worker_cpu[0], worker_cpu[1], worker_cpu[2]);
        fflush(stdout);
        return 0;
    }
    printf("CR2-LEVEL1-PLACEMENT controller_cpu=%d frozen_worker=%d frozen_cpu=%d\n",
           controller_cpu, w_frozen, worker_cpu[w_frozen]);
    fflush(stdout);
    control(6, 0, 0, 0); /* ensure the gates start disarmed */
    const int reps = 3;
    for (int i = 0; i < reps; i++) {
        L1STEP("l1a-notify-before-park");
        if (level1_notify_before_park() != 0)
            return -1;
        L1STEP("l1b-migration");
        if (level1_migration() != 0)
            return -1;
        L1STEP("l1c-two-waiters");
        if (level1_two_waiters() != 0)
            return -1;
        L1STEP("l1d-release-wins-mutex");
        if (level1_release_wins_mutex() != 0)
            return -1;
        printf("CR2-LEVEL1-PROGRESS rep=%d\n", i + 1);
        fflush(stdout);
    }
    control(6, 0, 0, 0); /* leave the gates disarmed */
    printf("CR2-LEVEL1-END ok\n");
    fflush(stdout);
    return 0;
}

/* ---- setup ---- */

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("CR2-BEGIN test=CR-2 waiter registration, notification and retry\n");
    fflush(stdout);
    if (getpid() == 1) {
        mkdir("/tmp", 0777);
        mount("proc", "/proc", "proc", 0, NULL);
    }
    int setup = open(fixture_path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (setup < 0) {
        failf("fixture create errno=%d", errno);
        goto out;
    }
    close(setup);
    probe_fd = open_fixture();
    if (probe_fd < 0)
        goto out;

    struct utsname uts;
    uname(&uts);
    cpus = control(4, 0, 0, 0);
    instrumented = cpus >= 0;
    if (!instrumented)
        cpus = sysconf(_SC_NPROCESSORS_ONLN);
    printf("CR2-CONFIG kernel=%s %s smp=%ld instrumented=%s pid=%d\n",
           uts.sysname, uts.release, cpus, instrumented ? "true" : "false", getpid());
    fflush(stdout);

    for (int i = 0; i < 3; i++) {
        workers[i].tid = i + 2;
        workers[i].rng = 0x9e3779b9u * (uint32_t)(i + 1);
        if (pthread_create(&workers[i].thread, NULL, worker_main, &workers[i]) != 0) {
            failf("pthread_create %d failed", i);
            goto out;
        }
    }
    spin_wait_ns(50000000); /* let the workers report their CPUs */
    controller_cpu = current_cpu();
    printf("CR2-PLACEMENT controller_cpu=%d worker_cpus=%d,%d,%d\n",
           controller_cpu, worker_cpu[0], worker_cpu[1], worker_cpu[2]);
    fflush(stdout);

    if (run_level0() != 0)
        goto out;
    if (run_level1() != 0)
        goto out;

out:
    if (probe_fd >= 0)
        close(probe_fd);
    printf("CR2-RESULT: %s (failures=%d lost_wake_events=%d)\n",
           (failures == 0) ? "PASS" : "FAIL", failures, lost_wake_events);
    fflush(stdout);
    if (getpid() == 1) {
        sync();
        reboot(RB_POWER_OFF);
    }
    return failures ? 1 : 0;
}
