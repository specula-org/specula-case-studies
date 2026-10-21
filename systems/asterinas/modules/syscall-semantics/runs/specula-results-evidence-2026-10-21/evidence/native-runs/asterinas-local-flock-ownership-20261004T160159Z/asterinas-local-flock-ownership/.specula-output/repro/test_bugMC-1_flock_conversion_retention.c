/* test_bugMC-1_flock_conversion_retention.c
 *
 * Reproduction for finding MC-1: Asterinas checks a conflicting conversion
 * before removing the caller's existing shared flock (flock.rs:114 try_set_lock
 * conflict search at line 116 precedes the same-owner replacement at line 124;
 * blocking path parks at flock.rs:147 while the old mode stays in the list).
 * Linux v6.16.5 flock_lock_inode (fs/locks.c:1101-1125) removes the caller's
 * different-mode lock BEFORE the conflict scan, so a conflicting SH->EX
 * conversion fails or blocks with the old lock already gone.
 *
 * Part 1 (sequential, C05 shape): A and B hold SH on independent opens. A's
 *   EX|NB conversion returns EAGAIN. B unlocks. C (independent open) probes
 *   EX|NB. Linux oracle: C succeeds (A's failed conversion dropped A's SH).
 *   Asterinas bug: C gets EAGAIN because A's old SH was retained. The proof is
 *   finished by unlocking A and retrying C, which then succeeds: the retained
 *   A-SH was the only remaining blocker.
 *
 * Part 2 (concurrent, C06 shape): A and B hold SH. Two threads enter blocking
 *   EX conversions through the same OFDs. Linux: the first converter drops its
 *   own SH before parking; the second converter drops its own SH and finds
 *   nothing left, so exactly one converter completes during the observation
 *   window (the other waits for the peer's live EX, as the Linux contract
 *   allows). Asterinas bug: both converters park while still holding their own
 *   SH, each registered on the other's SH waitqueue; neither can ever proceed
 *   without an external unlock/close, so zero converters complete during the
 *   window. The test then drains deterministically with explicit LOCK_UNs so
 *   it terminates on both kernels.
 *
 * Level 0 black-box: only public open/close/flock and pthread calls with valid
 * flags; no state injection, no source patch, no failpoints, no timing hooks.
 *
 * Build: gcc -O2 -static -pthread test_bugMC-1_flock_conversion_retention.c -o init
 * As guest init (PID 1) it powers off after printing; as a host process it
 * exits 0 when the observed pattern matches the environment's expectation
 * (Asterinas guest = bug pattern, real Linux = Linux oracle pattern), else 1.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>

static const char *fixture = "/tmp/specula-mc1-repro";
static int on_asterinas;

static uint64_t now_ns(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) { perror("clock_gettime"); _exit(2); }
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}

/* Guest-proven idle wait: yield-loop until the deadline passes (nanosleep is
 * not relied on in the guest). */
static void spin_until(uint64_t deadline_ns)
{
    while (now_ns() < deadline_ns) sched_yield();
}

static int wait_flag(atomic_int *flag, int64_t timeout_ns, const char *what)
{
    uint64_t deadline = now_ns() + (uint64_t)timeout_ns;
    while (!atomic_load_explicit(flag, memory_order_acquire)) {
        if (now_ns() >= deadline) return 0; /* timed out, still unset */
        sched_yield();
    }
    (void)what;
    return 1;
}

static const char *errname(int e)
{
    return e == 0 ? "0" : e == EAGAIN ? "EAGAIN" : strerror(e);
}

static int open_fixture(void)
{
    int fd = open(fixture, O_RDWR);
    if (fd < 0) { perror("open fixture"); _exit(2); }
    return fd;
}

struct conv {
    int fd;
    atomic_int entered;
    atomic_int done;
    int result;
    int error;
};

static void *conv_thread(void *arg)
{
    struct conv *c = arg;
    atomic_store_explicit(&c->entered, 1, memory_order_release);
    errno = 0;
    c->result = flock(c->fd, LOCK_EX);
    c->error = errno;
    atomic_store_explicit(&c->done, 1, memory_order_release);
    return NULL;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    struct utsname uts;
    if (uname(&uts) != 0) { perror("uname"); _exit(2); }
    /* The Asterinas guest reports its Linux-compatibility identity 5.13.0. */
    on_asterinas = (strncmp(uts.release, "5.13", 4) == 0);
    printf("MC1_ENV kernel=%s %s smp=%ld\n", uts.sysname, uts.release, sysconf(_SC_NPROCESSORS_ONLN));

    mkdir("/tmp", 0777);
    int setup = open(fixture, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (setup < 0) { perror("create fixture"); _exit(2); }
    close(setup);

    /* ---------------- Part 1: sequential failed conversion ---------------- */
    int a = open_fixture(), b = open_fixture(), c = open_fixture();
    printf("P1 opens a=%d b=%d c=%d (independent opens, one OFD each)\n", a, b, c);

    int r;
    errno = 0; r = flock(a, LOCK_SH | LOCK_NB); printf("P1 flock(a, SH|NB)   = %d errno=%s\n", r, errname(errno));
    if (r != 0) goto bad;
    errno = 0; r = flock(b, LOCK_SH | LOCK_NB); printf("P1 flock(b, SH|NB)   = %d errno=%s\n", r, errname(errno));
    if (r != 0) goto bad;

    errno = 0; r = flock(a, LOCK_EX | LOCK_NB);
    printf("P1 flock(a, EX|NB)   = %d errno=%s   <- A converts SH->EX, conflicts with B's SH\n", r, errname(errno));
    if (!(r == -1 && errno == EAGAIN)) goto bad; /* both kernels: EAGAIN here */

    errno = 0; r = flock(b, LOCK_UN);
    printf("P1 flock(b, UN)      = %d errno=%s   <- B releases its SH\n", r, errname(errno));
    if (r != 0) goto bad;

    errno = 0; r = flock(c, LOCK_EX | LOCK_NB);
    int p1_bug = (r == -1 && errno == EAGAIN);
    printf("P1 flock(c, EX|NB)   = %d errno=%s   <- DISCRIMINATOR: Linux oracle =0 (A's failed conversion removed A's SH); Asterinas bug =EAGAIN (A's old SH retained)\n", r, errname(errno));

    /* Prove the retained A-SH was the blocker: unlock A, retry C. */
    errno = 0; r = flock(a, LOCK_UN);
    printf("P1 flock(a, UN)      = %d errno=%s   <- A drops its retained old SH\n", r, errname(errno));
    if (r != 0) goto bad;
    errno = 0; r = flock(c, LOCK_EX | LOCK_NB);
    printf("P1 flock(c, EX|NB)   = %d errno=%s   <- after A's UN, C must succeed on both kernels\n", r, errname(errno));
    if (r != 0) goto bad;

    flock(c, LOCK_UN);
    close(a); close(b); close(c);

    /* ---------------- Part 2: two blocking converters ---------------- */
    int a2 = open_fixture(), b2 = open_fixture();
    printf("P2 opens a2=%d b2=%d\n", a2, b2);
    errno = 0; r = flock(a2, LOCK_SH | LOCK_NB); printf("P2 flock(a2, SH|NB)  = %d errno=%s\n", r, errname(errno));
    if (r != 0) goto bad;
    errno = 0; r = flock(b2, LOCK_SH | LOCK_NB);
    printf("P2 flock(b2, SH|NB)  = %d errno=%s\n", r, errname(errno));
    if (r != 0) goto bad;

    struct conv c1 = { .fd = a2 }, c2 = { .fd = b2 };
    pthread_t t1, t2;
    atomic_init(&c1.entered, 0); atomic_init(&c1.done, 0);
    atomic_init(&c2.entered, 0); atomic_init(&c2.done, 0);
    if (pthread_create(&t1, NULL, conv_thread, &c1) != 0) { perror("pthread_create t1"); _exit(2); }
    if (!wait_flag(&c1.entered, 5000000000LL, "t1 entered")) { fprintf(stderr, "t1 never entered\n"); _exit(2); }
    if (pthread_create(&t2, NULL, conv_thread, &c2) != 0) { perror("pthread_create t2"); _exit(2); }
    if (!wait_flag(&c2.entered, 5000000000LL, "t2 entered")) { fprintf(stderr, "t2 never entered\n"); _exit(2); }
    printf("P2 both converters entered blocking flock(a2/b2, EX)\n");

    /* Pure observation window: no interference from the main thread. */
    spin_until(now_ns() + 5000000000ULL);
    int d1 = atomic_load_explicit(&c1.done, memory_order_acquire);
    int d2 = atomic_load_explicit(&c2.done, memory_order_acquire);
    printf("P2 window(5s)        : t1_done=%d t2_done=%d   <- Asterinas bug: 0 0 (both parked, each holding the SH the other waits for); Linux oracle: exactly one completed\n", d1, d2);
    int p2_bug = (!d1 && !d2);

    /* Deterministic drain, valid on both kernels: release the locks the
     * parked/completed converters still hold, in an order that lets each
     * blocking call return. */
    errno = 0; r = flock(a2, LOCK_UN);
    printf("P2 drain: flock(a2, UN) = %d errno=%s\n", r, errname(errno));
    int got2 = wait_flag(&c2.done, 5000000000LL, "t2 drained");
    printf("P2 drain: t2_done=%d (blocking conversion returned)\n", atomic_load_explicit(&c2.done, memory_order_acquire));
    (void)got2;
    errno = 0; r = flock(b2, LOCK_UN);
    printf("P2 drain: flock(b2, UN) = %d errno=%s\n", r, errname(errno));
    int got1 = wait_flag(&c1.done, 5000000000LL, "t1 drained");
    printf("P2 drain: t1_done=%d (blocking conversion returned)\n", atomic_load_explicit(&c1.done, memory_order_acquire));
    if (!got1 || !got2) { printf("MC1_ASSESSMENT DRAIN_FAILED (a converter never returned after explicit unlock)\n"); goto bad; }
    printf("P2 results: t1 flock=%d errno=%s, t2 flock=%d errno=%s\n",
           c1.result, errname(c1.error), c2.result, errname(c2.error));

    flock(a2, LOCK_UN); flock(b2, LOCK_UN);
    pthread_join(t1, NULL); pthread_join(t2, NULL);
    close(a2); close(b2);

    printf("MC1_P1_OBSERVED C_EX_NB_after_B_unlock=%s\n", p1_bug ? "EAGAIN(retained SH blocks C)" : "SUCCESS(old lock gone)");
    printf("MC1_P2_OBSERVED completed_during_window=%d\n", d1 + d2);

    if (on_asterinas) {
        if (p1_bug && p2_bug) {
            printf("MC1_ASSESSMENT BUG_REPRODUCED: Asterinas retains the caller's old SH across a conflicting conversion; C's EX|NB is denied after B's release, and two blocking SH->EX converters deadlock mutually (0 completions in 5s)\n");
            printf("MC1_GUEST_DONE status=BUG_REPRODUCED\n");
        } else {
            printf("MC1_ASSESSMENT NOT_REPRODUCED on Asterinas (p1_bug=%d p2_bug=%d)\n", p1_bug, p2_bug);
            printf("MC1_GUEST_DONE status=NOT_REPRODUCED\n");
        }
    } else {
        if (!p1_bug && (d1 + d2) == 1) {
            printf("MC1_ASSESSMENT LINUX_CONTROL_MATCHED: failed conversion left no lock (C granted), and exactly one blocking converter completed spontaneously\n");
            printf("MC1_GUEST_DONE status=LINUX_CONTROL\n");
        } else {
            printf("MC1_ASSESSMENT LINUX_CONTROL_UNEXPECTED (p1_bug=%d completed=%d)\n", p1_bug, d1 + d2);
            printf("MC1_GUEST_DONE status=LINUX_CONTROL_UNEXPECTED\n");
        }
    }

    if (getpid() == 1) { sync(); reboot(RB_POWER_OFF); }
    return (on_asterinas ? (p1_bug && p2_bug) : (!p1_bug && (d1 + d2) == 1)) ? 0 : 1;

bad:
    printf("MC1_GUEST_DONE status=FIXTURE_ERROR\n");
    if (getpid() == 1) { sync(); reboot(RB_POWER_OFF); }
    return 2;
}
