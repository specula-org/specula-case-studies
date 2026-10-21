/*
 * CR-4 reproduction fixture: "Successful request's local Drop drains the
 * waiter queue outside the list Mutex".
 *
 * Level 0 (pure public API): three threads exercise real flock(2) on one
 * ordinary file under two contention shapes:
 *   - "race": two blocking EX contenders wait behind one EX holder; the
 *     holder's unlock makes them race; the winner's successful request clone
 *     drops after the list-Mutex critical section closes, so if the loser
 *     re-enqueued on the winner's item within that window, the clone-drop
 *     drain pops it and it performs a futile wake-retry-re-enqueue cycle.
 *   - "conv": one blocking EX contender waits on a SH holder; the holder
 *     converts SH->EX (same-owner replacement grant). The replaced item's
 *     Drop (inside the critical section) wakes the contender, whose retry
 *     re-enqueues on the new EX item, racing the converter's clone-drop
 *     window. Highest-probability interleaving for the drain to fire.
 *   - "convdown" (control): EX holder downgrades to SH while a SH contender
 *     waits. The replacement Drop's wake is load-bearing here: the contender
 *     is granted on its retry (compatible), proving the wake-on-Drop policy
 *     also delivers necessary notifications.
 *
 * On the instrumented Asterinas guest (prctl 0x53504543 trace interface of
 * the campaign harness), the fixture registers trace tids and afterwards
 * walks the per-tid event buffers to detect the CR-4 signature directly:
 * a FlockItemDropRequest (request-clone drop) followed by WaitQueuePop
 * events before WaitQueueFinish, i.e. the clone-drop drain actually popped
 * a queued waiter. It also counts waiter re-enqueue cycles (two
 * TrySetLockRegister events with the same request id and no grant between),
 * where any count above the protocol baseline (one per lost race / one per
 * conversion round) is drain-caused futile work, and measures the grant
 * return window (TrySetLockUnlock -> FlockItemDropRequest) in TSC ticks.
 *
 * On an uninstrumented Linux host the same workload runs as a fixture smoke
 * control (no tracing): every flock must succeed and every round completes.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/utsname.h>

#define RACE_ROUNDS 14
#define CONV_ROUNDS 14
#define CONVDOWN_ROUNDS 3
#define HOLD_US 50000L          /* winner holds the granted lock 50 ms */
#define TRACE_THREADS 4         /* kernel trace slots */
#define MAXEV 2048              /* kernel per-tid event buffer capacity */

static const char *fixture_path = "/tmp/specula-flock";
static int instrumented;
static uint64_t tsc_per_sec;

static long control(long op, long a, long b, long c)
{
    return syscall(SYS_prctl, 0x53504543, op, a, b, c);
}

static uint64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static inline uint64_t rdtsc(void)
{
    unsigned lo, hi;
    __asm__ __volatile__("lfence\n\trdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

static void hold_us(long us)
{
    struct timespec ts = { .tv_sec = us / 1000000, .tv_nsec = (us % 1000000) * 1000 };
    if (nanosleep(&ts, NULL) == 0) return;
    /* Fallback: TSC spin if nanosleep is unavailable. */
    if (tsc_per_sec) {
        uint64_t deadline = rdtsc() + (uint64_t)us * tsc_per_sec / 1000000;
        while (rdtsc() < deadline) sched_yield();
    } else {
        uint64_t deadline = now_ms() + us / 1000 + 1;
        while (now_ms() < deadline) sched_yield();
    }
}

struct worker {
    pthread_t thread;
    int tid, cpu, cmd_r, done_w, fd;
};
static struct worker workers[2];

static void *worker_main(void *argument)
{
    struct worker *w = argument;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(w->cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
    if (instrumented && control(1, w->tid, 0, 0) != 0) {
        fprintf(stderr, "trace register failed tid %d\n", w->tid);
        exit(2);
    }
    w->fd = open(fixture_path, O_RDWR);
    if (w->fd < 0) { fprintf(stderr, "worker open failed tid %d errno %d\n", w->tid, errno); exit(2); }
    char cmd;
    for (;;) {
        if (read(w->cmd_r, &cmd, 1) != 1) { fprintf(stderr, "cmd read failed tid %d\n", w->tid); exit(2); }
        if (cmd == 'x') break;
        int op = (cmd == 'd') ? LOCK_SH : LOCK_EX;
        if (flock(w->fd, op) != 0) {
            fprintf(stderr, "flock acquire failed tid %d op %d errno %d\n", w->tid, op, errno);
            exit(2);
        }
        hold_us((cmd == 'r' || cmd == 'c') ? HOLD_US : 20000);
        if (flock(w->fd, LOCK_UN) != 0) {
            fprintf(stderr, "flock unlock failed tid %d errno %d\n", w->tid, errno);
            exit(2);
        }
        if (write(w->done_w, ".", 1) != 1) { fprintf(stderr, "done write failed tid %d\n", w->tid); exit(2); }
    }
    return NULL;
}

static void wait_parked(int tid, long before)
{
    if (!instrumented) {
        /* Uninstrumented smoke run: no trace boundaries exist; a timed settle
         * lets the contender reach its blocking flock before we proceed. */
        hold_us(50000);
        return;
    }
    uint64_t deadline = now_ms() + 10000;
    for (;;) {
        long obs = control(2, tid, 2, 0);
        if ((obs & 255) == 5 && (obs >> 8) > (before >> 8)) return;
        if (now_ms() >= deadline) {
            fprintf(stderr, "park boundary timeout tid %d\n", tid);
            exit(2);
        }
        sched_yield();
    }
}

/* ---- in-guest trace analysis ---- */

struct ev { char name[40]; uint64_t start, end, popped, waker_id, drainq, rid; int accepted; };
static struct ev evs[TRACE_THREADS][MAXEV];
static int nev[TRACE_THREADS];

static void parse_event(char *line, struct ev *e)
{
    memset(e, 0, sizeof(*e));
    char *p = strstr(line, "\"event\":\"");
    if (p) {
        p += 9;
        size_t i = 0;
        while (p[i] && p[i] != '"' && i < sizeof(e->name) - 1) i++;
        memcpy(e->name, p, i);
    }
    p = strstr(line, "\"start\":");
    if (p) {
        unsigned long long s = 0, en = 0;
        if (sscanf(p, "\"start\":%llu,\"end\":%llu", &s, &en) >= 1) { e->start = s; e->end = en; }
    }
    p = strstr(line, "\"popped\":");
    if (p) sscanf(p, "\"popped\":%llu", &e->popped);
    p = strstr(line, "\"waker\":{\"id\":");
    if (p) sscanf(p, "\"waker\":{\"id\":%llu", &e->waker_id);
    e->accepted = strstr(line, "\"accepted\":true") != NULL;
    p = strstr(line, "\"drainQ\":");
    if (p) sscanf(p, "\"drainQ\":%llu", &e->drainq);
    p = strstr(line, "\"rid\":");
    if (p) sscanf(p, "\"rid\":%llu", &e->rid);
}

struct sig { int tid; int drop_index; int pops; int accepted; uint64_t pop_ids[8]; };
static struct sig sigs[64];
static int nsig;

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    mkdir("/tmp", 0777);
    int setup = open(fixture_path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (setup < 0) { perror("open fixture"); return 2; }
    struct stat st; struct statfs fs; struct utsname uts;
    if (fstat(setup, &st) || fstatfs(setup, &fs) || uname(&uts)) { perror("stat"); return 2; }
    close(setup);
    long cpus = control(4, 0, 0, 0);
    instrumented = cpus >= 0;
    if (!instrumented) cpus = sysconf(_SC_NPROCESSORS_ONLN);
    printf("CR4_CONFIG {\"instrumented\":%s,\"smp\":%ld,\"kernel\":\"%s %s\",\"fs_type\":%lu}\n",
           instrumented ? "true" : "false", cpus, uts.sysname, uts.release, (unsigned long)fs.f_type);
    if (cpus < 2) { fprintf(stderr, "need SMP >= 2 for concurrent runtime claims\n"); return 2; }

    /* Calibrate TSC for tick->ns conversion of measured windows. */
    {
        uint64_t t0 = rdtsc(), m0 = now_ms();
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 200 * 1000 * 1000 };
        nanosleep(&ts, NULL);
        uint64_t t1 = rdtsc(), m1 = now_ms();
        if (m1 > m0) tsc_per_sec = (t1 - t0) * 1000 / (m1 - m0);
    }
    printf("CR4_TSC {\"tsc_per_sec\":%llu}\n", (unsigned long long)tsc_per_sec);

    /* Controller pins to CPU 0; worker B (tid2) to CPU 1, worker C (tid3) to
     * CPU 0. The controller parks in pipe reads during every race, so the two
     * contenders always run on separate vCPUs at the decisive moments. */
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(0, &set);
    sched_setaffinity(0, sizeof(set), &set);

    int cmdB[2], cmdC[2], doneB[2], doneC[2];
    if (pipe(cmdB) || pipe(cmdC) || pipe(doneB) || pipe(doneC)) { perror("pipe"); return 2; }
    workers[0].tid = 2; workers[0].cpu = 1;
    workers[0].cmd_r = cmdB[0]; workers[0].done_w = doneB[1];
    workers[1].tid = 3; workers[1].cpu = 0;
    workers[1].cmd_r = cmdC[0]; workers[1].done_w = doneC[1];
    for (int i = 0; i < 2; i++) {
        if (pthread_create(&workers[i].thread, NULL, worker_main, &workers[i])) { perror("pthread"); return 2; }
    }
    if (instrumented && control(1, 1, 0, 0) != 0) { fprintf(stderr, "trace register failed tid 1\n"); return 2; }
    int a = open(fixture_path, O_RDWR);
    if (a < 0) { perror("controller open"); return 2; }
    char dot;
    long b2_before = 0, b3_before = 0;

    /* ---- "race" rounds: unlock makes two parked contenders race for the grant ---- */
    for (int r = 0; r < RACE_ROUNDS; r++) {
        if (flock(a, LOCK_EX | LOCK_NB) != 0) { fprintf(stderr, "holder EX|NB failed round %d errno %d\n", r, errno); return 2; }
        b2_before = control(2, 2, 2, 0);
        b3_before = control(2, 3, 2, 0);
        if (write(cmdB[1], "r", 1) != 1 || write(cmdC[1], "r", 1) != 1) { perror("cmd"); return 2; }
        wait_parked(2, b2_before);
        wait_parked(3, b3_before);
        if (flock(a, LOCK_UN) != 0) { fprintf(stderr, "holder UN failed round %d errno %d\n", r, errno); return 2; }
        /* Park while the contenders race; the winner's request-clone drop and
         * the loser's re-enqueue race on the two vCPUs without us. */
        if (read(doneB[0], &dot, 1) != 1 || read(doneC[0], &dot, 1) != 1) { perror("done"); return 2; }
    }

    /* ---- "conv" rounds: SH->EX conversion grant while one contender waits ---- */
    for (int r = 0; r < CONV_ROUNDS; r++) {
        if (flock(a, LOCK_SH | LOCK_NB) != 0) { fprintf(stderr, "holder SH|NB failed round %d errno %d\n", r, errno); return 2; }
        b2_before = control(2, 2, 2, 0);
        if (write(cmdB[1], "c", 1) != 1) { perror("cmd"); return 2; }
        wait_parked(2, b2_before);
        /* Same-owner conversion: no conflict, replaces the SH item. The old
         * item's Drop wakes the contender inside the critical section; its
         * retry re-enqueues on the new EX item, racing our clone-drop window. */
        if (flock(a, LOCK_EX) != 0) { fprintf(stderr, "conversion failed round %d errno %d\n", r, errno); return 2; }
        hold_us(HOLD_US);
        if (flock(a, LOCK_UN) != 0) { fprintf(stderr, "conv UN failed round %d errno %d\n", r, errno); return 2; }
        if (read(doneB[0], &dot, 1) != 1) { perror("done"); return 2; }
    }

    /* ---- "convdown" control: EX->SH downgrade; replacement wake is required ---- */
    for (int r = 0; r < CONVDOWN_ROUNDS; r++) {
        if (flock(a, LOCK_EX | LOCK_NB) != 0) { fprintf(stderr, "down holder EX failed round %d errno %d\n", r, errno); return 2; }
        b2_before = control(2, 2, 2, 0);
        if (write(cmdB[1], "d", 1) != 1) { perror("cmd"); return 2; }
        wait_parked(2, b2_before);
        if (flock(a, LOCK_SH | LOCK_NB) != 0) { fprintf(stderr, "downgrade failed round %d errno %d\n", r, errno); return 2; }
        if (read(doneB[0], &dot, 1) != 1) { perror("done"); return 2; }
        if (flock(a, LOCK_UN) != 0) { fprintf(stderr, "down UN failed round %d errno %d\n", r, errno); return 2; }
    }

    if (write(cmdB[1], "x", 1) != 1 || write(cmdC[1], "x", 1) != 1) { perror("stop"); return 2; }
    pthread_join(workers[0].thread, NULL);
    pthread_join(workers[1].thread, NULL);
    close(a);
    printf("CR4_WORKLOAD {\"complete\":true,\"race_rounds\":%d,\"conv_rounds\":%d,\"convdown_rounds\":%d}\n",
           RACE_ROUNDS, CONV_ROUNDS, CONVDOWN_ROUNDS);

    if (!instrumented) {
        printf("CR4_FIXTURE_SMOKE_OK\n");
        return 0;
    }

    /* ---- read back and analyze the kernel trace buffers ---- */
    static char line[16384];
    for (int tid = 1; tid <= 3; tid++) {
        long count = control(2, tid, 0, 0);
        long dropped = control(2, tid, 1, 0);
        if (count > MAXEV) count = MAXEV;
        for (long i = 0; i < count; i++) {
            long len = control(3, tid, i, (long)line);
            if (len <= 0) break;
            line[len] = 0;
            if (nev[tid] < MAXEV) parse_event(line, &evs[tid][nev[tid]++]);
        }
        printf("CR4_BUFFER {\"tid\":%d,\"events\":%ld,\"dropped\":%ld}\n", tid, count, dropped);
    }

    /* Signature A: a request-clone drop whose drain actually popped wakers. */
    long clone_drops = 0;
    uint64_t win_min = ~0ull, win_max = 0, win_sum = 0;
    for (int tid = 1; tid <= 3; tid++) {
        uint64_t last_unlock_end = 0;
        for (int i = 0; i < nev[tid]; i++) {
            struct ev *e = &evs[tid][i];
            if (!strcmp(e->name, "TrySetLockUnlock")) last_unlock_end = e->end;
            if (strcmp(e->name, "FlockItemDropRequest")) continue;
            clone_drops++;
            if (last_unlock_end && e->end >= last_unlock_end) {
                uint64_t w = e->end - last_unlock_end;
                if (w < win_min) win_min = w;
                if (w > win_max) win_max = w;
                win_sum += w;
            }
            int pops = 0, accepted = 0, j = i + 1;
            struct sig s = { .tid = tid, .drop_index = i, .pops = 0, .accepted = 0 };
            while (j < nev[tid] && strcmp(evs[tid][j].name, "WaitQueueFinish") &&
                   strcmp(evs[tid][j].name, "ArcPutSyscall")) {
                if (!strcmp(evs[tid][j].name, "WaitQueuePop")) {
                    if (s.pops < 8) s.pop_ids[s.pops] = evs[tid][j].popped;
                    s.pops++;
                    pops++;
                }
                if (!strcmp(evs[tid][j].name, "WakerWakeUp") && evs[tid][j].accepted) accepted = 1;
                j++;
            }
            if (pops > 0) {
                s.accepted = accepted;
                if (nsig < 64) sigs[nsig++] = s;
            }
            i = j - 1;
        }
    }

    /* Waiter re-enqueue cycles: two TrySetLockRegister with the same request id
     * and no grant between them. Baseline: exactly one per lost race round and
     * one per conv round (the loser's legitimate re-enqueue after a fair lost
     * race, which the Linux oracle also produces). Anything above that is
     * drain-caused futile work. */
    long reenq[TRACE_THREADS] = { 0 };
    for (int tid = 2; tid <= 3; tid++) {
        uint64_t last_reg_rid = 0;
        for (int i = 0; i < nev[tid]; i++) {
            struct ev *e = &evs[tid][i];
            if (!strcmp(e->name, "TrySetLockRegister")) {
                if (e->rid && e->rid == last_reg_rid) reenq[tid]++;
                last_reg_rid = e->rid;
            } else if (!strcmp(e->name, "TrySetLockAppend") || !strcmp(e->name, "TrySetLockInstall")) {
                last_reg_rid = 0;
            }
        }
    }
    long baseline = RACE_ROUNDS + CONV_ROUNDS; /* one legitimate re-enqueue each */
    long total_reenq = reenq[2] + reenq[3];
    long futile = total_reenq - baseline;

    printf("CR4_RESULT {\"clone_drops\":%ld,\"drain_fired\":%d,\"futile_cycles\":%ld,"
           "\"reenq_tid2\":%ld,\"reenq_tid3\":%ld,\"baseline_reenq\":%ld}\n",
           clone_drops, nsig, futile, reenq[2], reenq[3], baseline);
    if (clone_drops && win_min != ~0ull) {
        printf("CR4_WINDOW {\"min_ns\":%llu,\"avg_ns\":%llu,\"max_ns\":%llu}\n",
               (unsigned long long)(win_min * 1000000000ull / tsc_per_sec),
               (unsigned long long)(win_sum / clone_drops * 1000000000ull / tsc_per_sec),
               (unsigned long long)(win_max * 1000000000ull / tsc_per_sec));
    }

    for (int s = 0; s < nsig && s < 2; s++) {
        printf("CR4_SIGNATURE {\"index\":%d,\"tid\":%d,\"pops\":%d,\"accepted\":%d,\"popped\":[",
               s, sigs[s].tid, sigs[s].pops, sigs[s].accepted);
        for (int k = 0; k < sigs[s].pops && k < 8; k++)
            printf("%s%llu", k ? "," : "", (unsigned long long)sigs[s].pop_ids[k]);
        printf("]}\n");
        /* Re-read and print the raw window events as direct evidence. */
        int printed = 0;
        for (int j = sigs[s].drop_index; j < nev[sigs[s].tid] && printed < 12; j++, printed++) {
            long len = control(3, sigs[s].tid, j, (long)line);
            if (len <= 0) break;
            line[len] = 0;
            if (strstr(line, "\"event\":\"ArcPutSyscall\"")) break;
            printf("CR4_EVENT %s\n", line);
        }
    }
    if (nsig == 0)
        printf("CR4_NO_DRAIN {\"note\":\"every request-clone drop found an empty queue in this run\"}\n");

    printf("CR4_END\n");
    fflush(stdout);
    if (getpid() == 1) { sync(); reboot(RB_POWER_OFF); }
    return 0;
}
