/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Reproduction test for finding MC-2: "A final temporary reference can
 * deadlock flock cleanup".
 *
 * Mechanism under test (Asterinas pinned at 0c6053709):
 *   FlockList::unlock (kernel/core/src/fs/file/flock.rs:164-181) holds the
 *   per-inode flock-list Mutex while its retain closure upgrades each item's
 *   Weak owner to a temporary Arc.  If another thread closes the only fd
 *   referencing that owner, the fd-table reference is dropped while the
 *   temporary Arc is still alive; when the retain closure then drops the
 *   temporary Arc (the last reference), InodeHandle::drop
 *   (kernel/core/src/fs/file/inode_handle.rs:537) runs synchronously inside
 *   the scanning thread and calls back into FlockList::unlock, which tries to
 *   acquire the same non-recursive Mutex (ostd/src/sync/mutex.rs:35).  The
 *   scanning thread parks forever while holding the Mutex, so every later
 *   flock operation on this inode also hangs forever.
 *
 * Cases (selected by the /case file or SPECULA_CASE):
 *   MC2-L0      Level 0: natural race, no kernel test hooks.  Thread A spins
 *               flock(fd_a, LOCK_UN); thread B spins open+flock(SH|NB)+close.
 *               The controller watches per-thread iteration counters; a
 *               simultaneous freeze of both loops followed by a fresh
 *               LOCK_NB flock probe hanging proves the deadlock through the
 *               public API alone.
 *   MC2-L1      Level 1: deterministic reproduction of the exact C11 shape
 *               using the campaign's reviewed kernel test hooks (prctl gate
 *               that holds the scanning thread inside the retain window).
 *               Boundary 3 (nested FlockListUnlockEnter, selfHeld=true) is
 *               observed, then the same LOCK_NB probe proves permanence.
 *   MC2-L1-ctl  Negative control (C12-alias shape): one extra dup alias keeps
 *               the owner alive, so no destructor runs under the guard; every
 *               syscall must return.  Distinguishes the deadlock from generic
 *               fixture, scheduler or guest failure.
 *
 * The fixture runs as pid 1 inside the instrumented Asterinas guest and boots
 * via the campaign's reviewed harness scheme ("flock": x86_64, SMP=2).
 */
#define _GNU_SOURCE
#define main regression_framework_main
#include "test.h"
#undef main
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static const char *fixture = "/tmp/specula-flock";
static char scenario[32] = "MC2-L1";
static int instrumented;
/* "plain" cases never register kernel trace slots: every trace hook
 * (including the gate and the refcount observer) stays disabled, so the
 * race window has its pristine, un-widened width. */
static int trace_on = 1;

/* Observed syscall returns, recorded per acting tid like the campaign fixture. */
static _Thread_local int acting_tid = 1;
static atomic_int capture_returns;
struct observed_return { const char *operation; int fd, argument, result, error; };
static struct observed_return outcomes[4][128];
static atomic_int outcome_count[4];
static int record_return(const char *operation, int fd, int argument, int result)
{
    int saved_errno = errno;
    if (atomic_load_explicit(&capture_returns, memory_order_acquire)) {
        int slot = acting_tid - 1;
        int n = atomic_load_explicit(&outcome_count[slot], memory_order_relaxed);
        if (n >= 128) abort();
        outcomes[slot][n] = (struct observed_return){operation, fd, argument, result,
                                                     result < 0 ? saved_errno : 0};
        atomic_store_explicit(&outcome_count[slot], n + 1, memory_order_release);
    }
    errno = saved_errno;
    return result;
}
static int observed_flock(int fd, int op) { int r = flock(fd, op); return record_return("flock", fd, op, r); }
static int observed_close(int fd) { int r = close(fd); return record_return("close", fd, 0, r); }
static int observed_dup(int fd) { int r = dup(fd); return record_return("dup", fd, 0, r); }
#define flock observed_flock
#define close observed_close
#define dup observed_dup

/*
 * Workers: each is pinned to a kernel trace slot (tid 2..4) by registering
 * itself through the instrumented prctl interface.  `command` 0 means idle;
 * `op` 0 means "open the fixture file", otherwise it is a flock opcode.
 */
struct worker {
    pthread_t thread;
    atomic_int ready, command, done;
    int tid, cpu, fd, op, unlock, result, error;
    /* Level-0 loop state */
    atomic_ulong loop_count;
    atomic_int loop_stop, loop_mode, loop_started, loop_frozen_seen;
    unsigned long frozen_at;
};
static struct worker workers[3];
static int controller_cpu;

static int current_cpu(void)
{
    unsigned cpu;
    CHECK(syscall(SYS_getcpu, &cpu, NULL, NULL));
    return cpu;
}
static long control(long op, long a, long b, long c)
{
    return syscall(SYS_prctl, 0x53504543, op, a, b, c);
}
static uint64_t now(void)
{
    struct timespec t;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &t));
    return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
static void spin_sleep_ns(uint64_t ns)
{
    uint64_t deadline = now() + ns;
    while (now() < deadline) sched_yield();
}
static void wait_atomic(atomic_int *value, int wanted)
{
    uint64_t deadline = now() + 10000000000ULL;
    while (atomic_load_explicit(value, memory_order_acquire) != wanted) {
        if (now() >= deadline) { fprintf(stderr, "fixture synchronization deadline\n"); exit(2); }
        sched_yield();
    }
}
static void wait_boundary_after(int tid, int boundary, long after)
{
    uint64_t deadline = now() + 10000000000ULL;
    for (;;) {
        long observation = control(2, tid, 2, 0);
        if ((observation & 255) == boundary && (observation >> 8) > after) break;
        if (now() >= deadline) {
            fprintf(stderr, "missing observed kernel boundary tid=%d boundary=%d\n", tid, boundary);
            exit(2);
        }
        sched_yield();
    }
}
static void wait_boundary(int tid, int boundary) { wait_boundary_after(tid, boundary, 0); }

static int open_fixture(void)
{
    int fd = CHECK(open(fixture, O_RDWR));
    return record_return("open", fd, O_RDWR, fd);
}

static void *worker_main(void *argument)
{
    struct worker *w = argument;
    w->cpu = current_cpu();
    atomic_store_explicit(&w->ready, 1, memory_order_release);
    wait_atomic(&w->ready, 2);
    acting_tid = w->tid;
    if (instrumented && trace_on) CHECK(control(1, w->tid, 0, 0));
    atomic_store_explicit(&w->ready, 3, memory_order_release);
    for (;;) {
        wait_atomic(&w->command, 1);
        atomic_store(&w->command, 0);
        if (w->loop_mode) {
            /*
             * Level-0 racing loop.  Thread A: flock(fd, LOCK_UN) forever.
             * Thread B: open + flock(SH|NB) + close forever.  Every syscall is
             * a plain public API call; nothing is injected.
             */
            atomic_store_explicit(&w->loop_started, 1, memory_order_release);
            while (!atomic_load_explicit(&w->loop_stop, memory_order_acquire)) {
                if (w->op == 0) {
                    int fd = open(fixture, O_RDWR);
                    if (fd < 0) break;
                    if (flock(fd, LOCK_SH | LOCK_NB) != 0) { close(fd); break; }
                    close(fd);
                } else {
                    if (flock(w->fd, w->op) != 0) break;
                }
                atomic_fetch_add_explicit(&w->loop_count, 1, memory_order_relaxed);
            }
            w->result = 0;
            atomic_store_explicit(&w->done, 1, memory_order_release);
            continue;
        }
        errno = 0;
        w->result = w->op == 0 ? open_fixture() : flock(w->fd, w->op);
        w->error = errno;
        if (w->unlock && w->result == 0) CHECK(flock(w->fd, LOCK_UN));
        atomic_store_explicit(&w->done, 1, memory_order_release);
    }
    return NULL;
}

static void start_worker(int index, int fd, int op, int unlock)
{
    struct worker *w = &workers[index];
    w->fd = fd; w->op = op; w->unlock = unlock;
    w->loop_mode = 0;
    atomic_store(&w->done, 0);
    atomic_store_explicit(&w->command, 1, memory_order_release);
}
static void finish_worker(int index)
{
    struct worker *w = &workers[index];
    wait_atomic(&w->done, 1);
    printf("SPECULA_RETURN {\"tid\":%d,\"result\":%d,\"errno\":%d}\n", w->tid, w->result, w->error);
    if (w->op != 0) CHECK_WITH(w->result, _ret == 0 && w->error == 0);
}
static int worker_done_after(int index, uint64_t ns)
{
    struct worker *w = &workers[index];
    uint64_t deadline = now() + ns;
    while (now() < deadline) {
        if (atomic_load_explicit(&w->done, memory_order_acquire)) return 1;
        sched_yield();
    }
    return atomic_load_explicit(&w->done, memory_order_acquire);
}

/* Kernel trace dump (identical format to the campaign fixture). */
static char line[16384];
static void dump(void)
{
    for (int tid = 1; tid <= 4; ++tid) {
        int count = atomic_load_explicit(&outcome_count[tid - 1], memory_order_acquire);
        for (int i = 0; i < count; ++i) {
            struct observed_return r = outcomes[tid - 1][i];
            printf("SPECULA_RETURN {\"tid\":%d,\"operation\":\"%s\",\"fd_raw\":%d,\"argument\":%d,\"result\":%d,\"errno\":%d}\n",
                   tid, r.operation, r.fd, r.argument, r.result, r.error);
        }
    }
    if (!instrumented) {
        printf("SPECULA_CONTROL_END {\"case\":\"%s\",\"failures\":%d}\n", scenario, __total_failures);
        return;
    }
    if (!trace_on) {
        printf("SPECULA_PLAIN_END {\"case\":\"%s\",\"failures\":%d}\n", scenario, __total_failures);
        return;
    }
    for (int tid = 1; tid <= 4; ++tid) {
        long count = CHECK(control(2, tid, 0, 0));
        long dropped = CHECK(control(2, tid, 1, 0));
        printf("SPECULA_BUFFER {\"tid\":%d,\"events\":%ld,\"dropped\":%ld}\n", tid, count, dropped);
        for (long i = 0; i < count; ++i) {
            long length = CHECK(control(3, tid, i, (long)line));
            CHECK_WITH(length, _ret > 0 && _ret < sizeof(line));
            line[length] = 0;
            printf("SPECULA_EVENT %s\n", line);
        }
    }
    long mapping_length = CHECK(control(7, 0, 0, (long)line));
    line[mapping_length] = 0;
    printf("SPECULA_IDENTITIES %s\n", line);
}

/*
 * Level-0 freeze detector: sample both racing loops every 250 ms.  Both loops
 * advance at kHz+ rates; six consecutive identical samples for BOTH loops
 * (1.5 s) cannot happen while the guest schedules normally -- the only
 * permanent park on these paths is the self-deadlock under test.
 */
static int detect_level0_freeze(struct worker *a, struct worker *b, uint64_t budget_ns,
                                unsigned long *out_a, unsigned long *out_b)
{
    unsigned long last_a = 0, last_b = 0;
    int frozen_samples = 0;
    unsigned long count_a = 0, count_b = 0;
    uint64_t start = now();
    while (now() - start < budget_ns) {
        spin_sleep_ns(250000000ULL);
        count_a = atomic_load_explicit(&a->loop_count, memory_order_relaxed);
        count_b = atomic_load_explicit(&b->loop_count, memory_order_relaxed);
        if (count_a == last_a && count_b == last_b) {
            frozen_samples++;
            if (frozen_samples >= 6 && count_a >= 1 && count_b >= 1) {
                *out_a = count_a; *out_b = count_b;
                return 1;
            }
        } else {
            frozen_samples = 0;
        }
        last_a = count_a; last_b = count_b;
    }
    *out_a = count_a; *out_b = count_b;
    return 0;
}

/*
 * Permanence probe: a fresh non-blocking flock on the same file must return
 * immediately (0 or EAGAIN) in a healthy system.  If it never returns, the
 * flock-list Mutex is held forever -- every future flock consumer on this
 * inode hangs.
 */
static int probe_permanence(int probe_fd, int probe_worker_index, uint64_t wait_ns)
{
    start_worker(probe_worker_index, probe_fd, LOCK_SH | LOCK_NB, 0);
    int done = worker_done_after(probe_worker_index, wait_ns);
    printf("MC2_PROBE {\"op\":\"flock LOCK_SH|LOCK_NB\",\"returned\":%s,\"wait_ms\":%llu}\n",
           done ? "true" : "false", (unsigned long long)(wait_ns / 1000000ULL));
    return !done;
}

FN_SETUP(fixture)
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *requested = getenv("SPECULA_CASE");
    if (requested) snprintf(scenario, sizeof(scenario), "%s", requested);
    else {
        int f = open("/case", O_RDONLY);
        if (f >= 0) { int n = read(f, scenario, sizeof(scenario) - 1); if (n > 0) scenario[strcspn(scenario, "\r\n")] = 0; close(f); }
    }
    mkdir("/tmp", 0777);
    int setup = CHECK(open(fixture, O_CREAT | O_TRUNC | O_RDWR, 0600));
    struct stat st; struct statfs fs; struct utsname uts;
    CHECK(fstat(setup, &st)); CHECK(fstatfs(setup, &fs)); CHECK(uname(&uts)); CHECK(close(setup));
    long cpus = control(4, 0, 0, 0);
    instrumented = cpus >= 0;
    if (!instrumented) cpus = sysconf(_SC_NPROCESSORS_ONLN);
    printf("SPECULA_CONFIG {\"case\":\"%s\",\"instrumented\":%s,\"smp\":%ld,\"kernel\":\"%s %s\",\"fs_type\":%lu,\"inode_raw\":%lu,\"device_raw\":%lu}\n",
           scenario, instrumented ? "true" : "false", cpus, uts.sysname, uts.release,
           (unsigned long)fs.f_type, (unsigned long)st.st_ino, (unsigned long)st.st_dev);
    controller_cpu = current_cpu();
    if (!strcmp(scenario, "MC2-L0-plain")) trace_on = 0;
    for (int i = 0; i < 3; ++i) {
        workers[i].tid = i + 2;
        CHECK(pthread_create(&workers[i].thread, NULL, worker_main, &workers[i]));
        wait_atomic(&workers[i].ready, 1);
    }
    printf("SPECULA_PLACEMENT {\"controller\":%d,\"tid2\":%d,\"tid3\":%d,\"tid4\":%d}\n",
           controller_cpu, workers[0].cpu, workers[1].cpu, workers[2].cpu);
    for (int i = 0; i < 3; ++i) {
        atomic_store_explicit(&workers[i].ready, 2, memory_order_release);
        wait_atomic(&workers[i].ready, 3);
    }
    if (instrumented && trace_on) CHECK(control(1, 1, 0, 0));
    atomic_store_explicit(&capture_returns, 1, memory_order_release);
END_SETUP()

FN_TEST(mc2_temporary_last_reference_deadlock)
    if (!strcmp(scenario, "MC2-L0") || !strcmp(scenario, "MC2-L0-plain")) {
        /*
         * Level 0 -- pure public-API race, no kernel hooks.
         *   workers[0] (tid2): flock(fd_a, LOCK_UN) loop
         *   workers[1] (tid3): open + flock(SH|NB) + close loop
         */
        int a = open_fixture();
        atomic_store(&workers[0].loop_stop, 0);
        atomic_store(&workers[1].loop_stop, 0);
        workers[0].loop_mode = 1; workers[0].fd = a; workers[0].op = LOCK_UN;
        workers[1].loop_mode = 1; workers[1].fd = -1; workers[1].op = 0;
        atomic_store(&workers[0].done, 0);
        atomic_store(&workers[1].done, 0);
        atomic_store_explicit(&workers[0].command, 1, memory_order_release);
        atomic_store_explicit(&workers[1].command, 1, memory_order_release);
        wait_atomic(&workers[0].loop_started, 1);
        wait_atomic(&workers[1].loop_started, 1);

        unsigned long count_a = 0, count_b = 0;
        int frozen = detect_level0_freeze(&workers[0], &workers[1], 90000000000ULL,
                                          &count_a, &count_b);
        printf("MC2_L0_RACE {\"unlock_loop\":%lu,\"open_flock_close_loop\":%lu,\"frozen\":%s}\n",
               count_a, count_b, frozen ? "true" : "false");
        if (!frozen) {
            atomic_store_explicit(&workers[0].loop_stop, 1, memory_order_release);
            atomic_store_explicit(&workers[1].loop_stop, 1, memory_order_release);
            printf("MC2_VERDICT {\"case\":\"%s\",\"level\":0,\"deadlock\":false}\n", scenario);
            __TEST_SUMMARY();
            return;
        }
        /* Both loops froze mid-syscall: the racing syscalls never returned.
         * A loop that exited early (error) would have set done, so frozen +
         * not-done means both threads are still inside their syscall. */
        int a_returned = atomic_load_explicit(&workers[0].done, memory_order_acquire);
        int b_returned = atomic_load_explicit(&workers[1].done, memory_order_acquire);
        printf("MC2_FROZEN_SYSCALLS {\"tid2_flock_returned\":%s,\"tid3_close_or_flock_returned\":%s}\n",
               a_returned ? "true" : "false", b_returned ? "true" : "false");
        /* A fresh LOCK_NB flock on the same file must return instantly; if it
         * hangs, the flock-list Mutex is permanently held (self-deadlock). */
        int probe_fd = open_fixture();
        int poisoned = probe_permanence(probe_fd, 2, 2000000000ULL);
        int deadlock = frozen && !a_returned && !b_returned && poisoned;
        printf("MC2_VERDICT {\"case\":\"%s\",\"level\":0,\"deadlock\":%s,\"mutex_poisoned\":%s}\n",
               scenario, deadlock ? "true" : "false", poisoned ? "true" : "false");
    } else if (!strcmp(scenario, "MC2-L1") || !strcmp(scenario, "MC2-L1-ctl")) {
        /*
         * Level 1 -- deterministic window using the campaign's reviewed kernel
         * test gate (prctl 0x53504543 op 5): the gate parks the scanning
         * thread between the Weak upgrade and the keep decision, which is the
         * exact window the Level-0 race has to hit by luck.  The interleaving
         * is produced by ordinary syscalls only.
         */
        int control_kind = strcmp(scenario, "MC2-L1-ctl") == 0;
        int a = open_fixture(), b = open_fixture();
        int alias = -1;
        TEST_SUCC(flock(b, LOCK_EX | LOCK_NB));
        if (control_kind) alias = CHECK(dup(b));
        /* Arm the gate for b's owner, start flock(a, LOCK_UN) on tid2, wait
         * until tid2 has upgraded b's Weak owner (boundary 2) and now spins
         * inside the retain closure holding the list Mutex + the temp Arc. */
        CHECK(control(5, b, 0, 0));
        start_worker(0, a, LOCK_UN, 0);
        wait_boundary(2, 2);
        /* Drop b's last fd-table reference while the temp Arc is alive. */
        TEST_SUCC(close(b));
        b = -1;
        /* Release the gate: tid2 keeps the item, drops the temp Arc.  In the
         * last-reference case (MC2-L1) the drop runs InodeHandle::drop under
         * the held Mutex, which re-enters FlockList::unlock and parks on the
         * same non-recursive Mutex (boundary 3 = nested enter, selfHeld).  In
         * the alias control the owner survives, so the syscall returns. */
        CHECK(control(6, 0, 0, 0));
        if (control_kind) {
            finish_worker(0);
            /* The owner still holds EX through the alias: a fresh SH|NB probe
             * must return EAGAIN immediately (proving the Mutex is free). */
            int probe_fd = open_fixture();
            start_worker(1, probe_fd, LOCK_SH | LOCK_NB, 0);
            int done = worker_done_after(1, 2000000000ULL);
            printf("MC2_PROBE {\"op\":\"flock LOCK_SH|LOCK_NB\",\"returned\":%s}\n", done ? "true" : "false");
            TEST_RES(done, _ret == 1);
            TEST_RES(workers[1].result, _ret == -1 && workers[1].error == EAGAIN);
            TEST_SUCC(flock(alias, LOCK_UN));
            TEST_SUCC(close(alias));
            TEST_SUCC(close(a));
            TEST_SUCC(close(probe_fd));
            printf("MC2_VERDICT {\"case\":\"MC2-L1-ctl\",\"level\":1,\"deadlock\":false}\n");
        } else {
            /* Observe the nested, self-held unlock attempt (boundary 3). */
            wait_boundary(2, 3);
            /* tid2's flock(fd_a, LOCK_UN) never returns. */
            spin_sleep_ns(1000000000ULL);
            printf("MC2_FROZEN_SYSCALLS {\"tid2_flock_returned\":%s}\n",
                   atomic_load_explicit(&workers[0].done, memory_order_acquire) ? "true" : "false");
            /* Permanence: a fresh LOCK_NB flock on the same file hangs. */
            int probe_fd = open_fixture();
            int poisoned = probe_permanence(probe_fd, 1, 2000000000ULL);
            printf("MC2_VERDICT {\"case\":\"MC2-L1\",\"level\":1,\"deadlock\":true,\"mutex_poisoned\":%s}\n",
                   poisoned ? "true" : "false");
        }
    } else {
        fprintf(stderr, "unknown scenario: %s\n", scenario);
        exit(2);
    }
END_TEST()

int main(void)
{
    dump();
    printf("SPECULA_END {\"case\":\"%s\",\"failures\":%d}\n", scenario, __total_failures);
    fflush(stdout);
    if (getpid() == 1) { sync(); reboot(RB_POWER_OFF); }
    return __total_failures ? 1 : 0;
}
