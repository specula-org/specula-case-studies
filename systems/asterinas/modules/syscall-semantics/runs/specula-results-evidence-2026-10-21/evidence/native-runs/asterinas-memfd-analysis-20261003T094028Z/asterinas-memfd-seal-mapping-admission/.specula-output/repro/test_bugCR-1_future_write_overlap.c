// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding CR-1: "Overlapping FUTURE_WRITE publication
// may misclassify mapping write eligibility" (asterinas/asterinas @
// 0c60537098f4c2949ad2d382aaf499de72263d76, seal feature from PR #2408).
//
// Hypothesis under test (code review; MC found NO counterexample within
// 2 syscall threads / 3 page slots / 6 owner IDs):
//   A F_ADD_SEALS(F_SEAL_FUTURE_WRITE) publication overlapping (i) mmap
//   admission or (ii) an old mapping's mprotect can
//     (a) let a NEW mapping acquire forbidden write access, or
//     (b) wrongly strip a PRE-EXISTING mapping's retained eligibility.
//
// Doctrine used for classification (Linux memfd_create(2) F_SEAL_FUTURE_WRITE
// and v6.16.5 mm/memfd.c check_write_seal/memfd_check_seals_mmap; mirrored by
// Asterinas MemfdInode::check_writable):
//   - A mapping whose eligibility was checked BEFORE the seal is published
//     keeps its upgrade eligibility for its whole lifetime, no matter when
//     its mmap returns (return order alone is not a violation).
//   - A mapping admitted AFTER publication must never become writable:
//     PROT_WRITE mmap -> EPERM, mprotect upgrade -> EACCES, write(2) -> EPERM.
//
// Bucket classification in the racing arms is done with F_GET_SEALS observed
// in the same thread immediately before the mmap call. If F_GET_SEALS already
// reports the seal, the kernel-side eligibility check of the subsequent mmap
// provably runs after the seals-mutex critical section that published it
// (both take the same MemfdInode seals mutex), so the mapping is provably
// post-publication: any upgrade success there is harm (a). Pre-publication
// mappings for harm (b) are pinned with barriers + F_GET_SEALS==0 checks.
//
// Escalation: Level 0 only (public syscalls, pthreads, barriers, spin
// delays, best-effort affinity). No state injection, no kernel patching.
//
// Exit codes: 0 no CR-1 violation; 3 harm (a); 4 harm (b); 5 torn state;
// 6 control mismatch (setup/expectation failure, reported distinctly).

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>

#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#endif
#ifndef F_GET_SEALS
#define F_GET_SEALS 1034
#endif
#ifndef F_SEAL_SEAL
#define F_SEAL_SEAL 0x0001
#define F_SEAL_SHRINK 0x0002
#define F_SEAL_GROW 0x0004
#define F_SEAL_WRITE 0x0008
#define F_SEAL_FUTURE_WRITE 0x0010
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002
#endif

#define PAGE 4096UL
#define EXPECT_SEAL F_SEAL_FUTURE_WRITE

static int bug_a; /* harm (a): forbidden new write access */
static int bug_b; /* harm (b): stripped retained eligibility */
static int bug_torn; /* upgrade succeeded but write access was broken */
static int control_fail;

/* Informational counters (not violations per the doctrine). */
static atomic_long win_admit_ok, win_admit_fail; /* mid-window admissions */
static atomic_long win_upgrade_ok, win_upgrade_fail; /* mid-window upgrades (legal either way) */
static atomic_long postobs_admit_ok, postobs_upgrade_eacces;
static atomic_long postobs_wmmap_eperm, mid_wmmap_ok;
static atomic_long s4_seal_ebusy, s4_seal_ok, s4_ro_admit_eperm; /* MC-1 surface info */
static atomic_long churn_iters;

static void report(const char *step, long ret, int err)
{
    printf("  %-56s -> ret=%-6ld errno=%s(%d)\n", step, ret, err ? strerror(err) : "0", err);
    fflush(stdout);
}

static int new_memfd(const char *name)
{
    int fd = (int)syscall(SYS_memfd_create, name, MFD_ALLOW_SEALING);
    if (fd < 0) {
        report("memfd_create(MFD_ALLOW_SEALING)", fd, errno);
        control_fail = 1;
        return -1;
    }
    if (ftruncate(fd, (off_t)PAGE) != 0) {
        report("ftruncate(PAGE)", -1, errno);
        close(fd);
        control_fail = 1;
        return -1;
    }
    return fd;
}

static int add_seals(int fd, unsigned int seals)
{
    errno = 0;
    return fcntl(fd, F_ADD_SEALS, (unsigned long)seals);
}

static int get_seals(int fd)
{
    errno = 0;
    return fcntl(fd, F_GET_SEALS);
}

static void pin(int cpu)
{
    /* Best-effort only: single-CPU guests still interleave syscalls. */
#ifdef __linux__
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
#endif
}

static void spin(unsigned long iters)
{
    for (unsigned long i = 0; i < iters; i++)
#if defined(__x86_64__)
        __asm__ volatile("pause");
#else
        __asm__ volatile("" ::: "memory");
#endif
}

/* Try to upgrade a PROT_READ shared mapping to PROT_READ|PROT_WRITE.
 * Returns 0 on success. */
static int try_upgrade(void *p)
{
    errno = 0;
    return mprotect(p, PAGE, PROT_READ | PROT_WRITE);
}

static int try_downgrade(void *p)
{
    errno = 0;
    return mprotect(p, PAGE, PROT_READ);
}

/* ============ S1: deterministic core (harm b + harm a controls) ============ */

static void s1_deterministic_core(void)
{
    printf("[S1] pre-publication mapping retains eligibility; post-publication admissions never gain it\n");

    int fd = new_memfd("cr1-s1");
    if (fd < 0)
        return;

    /* Pre-publication eligible mapping through the O_RDWR fd. */
    int seals0 = get_seals(fd);
    report("fcntl(F_GET_SEALS) before seal", seals0, errno);
    if (seals0 != 0) {
        printf("  control: fresh memfd must have no seals\n");
        control_fail = 1;
        close(fd);
        return;
    }
    errno = 0;
    void *p_pre = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    report("mmap(PROT_READ, MAP_SHARED, rw_fd) pre-seal",
           (long)(p_pre == MAP_FAILED ? -1 : 0), p_pre == MAP_FAILED ? errno : 0);
    if (p_pre == MAP_FAILED) {
        control_fail = 1;
        close(fd);
        return;
    }

    /* Publish FUTURE_WRITE (mapping already established). */
    long r = add_seals(fd, F_SEAL_FUTURE_WRITE);
    report("fcntl(F_ADD_SEALS, F_SEAL_FUTURE_WRITE) with live mapping", r, errno);
    if (r != 0) {
        control_fail = 1;
        munmap(p_pre, PAGE);
        close(fd);
        return;
    }

    /* Harm (b) core: the pre-existing mapping must keep upgrading forever. */
    for (int k = 0; k < 200; k++) {
        if (try_upgrade(p_pre) != 0) {
            printf("  CR1 BUG B: pre-seal mapping lost upgrade eligibility "
                   "(iteration %d, errno=%d)\n", k, errno);
            bug_b = 1;
            break;
        }
        *(volatile unsigned char *)p_pre = 0x58; /* 'X' — a real write */
        if (try_downgrade(p_pre) != 0) {
            printf("  CR1 BUG B: downgrade of pre-seal mapping failed "
                   "(iteration %d, errno=%d)\n", k, errno);
            bug_b = 1;
            break;
        }
    }
    if (!bug_b)
        printf("  ok: 200 upgrade/store/downgrade cycles on the pre-seal mapping\n");

    /* Verify the store reached the shared file page through an independent
     * post-seal read-only mapping. */
    errno = 0;
    void *p_obs = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    report("mmap(PROT_READ, MAP_SHARED, rw_fd) post-seal observer",
           (long)(p_obs == MAP_FAILED ? -1 : 0), p_obs == MAP_FAILED ? errno : 0);
    if (p_obs == MAP_FAILED) {
        control_fail = 1; /* Linux admits it; Asterinas must too (no WRITE seal here) */
    } else {
        unsigned char c = *(volatile unsigned char *)p_obs;
        printf("  observer mapping read back: 0x%02x (want 0x58)\n", c);
        if (c != 0x58) {
            printf("  CR1 BUG TORN: upgraded store not visible through the "
                   "shared observer mapping\n");
            bug_torn = 1;
        }
        /* Harm (a) control 1: a post-seal read-only admission must NOT be
         * upgradeable (it has no pre-publication eligibility). */
        if (try_upgrade(p_obs) == 0) {
            printf("  CR1 BUG A: post-seal read-only admission upgraded to "
                   "PROT_WRITE\n");
            bug_a = 1;
        } else {
            printf("  ok: post-seal read-only admission refuses upgrade (errno=%d)\n", errno);
        }
        munmap(p_obs, PAGE);
    }

    /* Harm (a) control 2: new PROT_WRITE shared mmap must fail EPERM. */
    errno = 0;
    void *p_w = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int w_err = p_w == MAP_FAILED ? errno : 0;
    report("mmap(PROT_READ|PROT_WRITE, MAP_SHARED) post-seal",
           (long)(p_w == MAP_FAILED ? -1 : 0), w_err);
    if (p_w != MAP_FAILED) {
        printf("  CR1 BUG A: post-seal PROT_WRITE shared mmap admitted\n");
        bug_a = 1;
        munmap(p_w, PAGE);
    } else if (w_err != EPERM) {
        printf("  control: expected EPERM for post-seal writable mmap\n");
        control_fail = 1;
    }

    /* Harm (a) control 3: write(2) through the writable fd must fail EPERM. */
    errno = 0;
    char byte = 'Z';
    long wr = write(fd, &byte, 1);
    report("write(rw_fd) post-seal", wr, errno);
    if (wr >= 0) {
        printf("  CR1 BUG A: post-seal write(2) accepted\n");
        bug_a = 1;
    }

    int seals_end = get_seals(fd);
    report("fcntl(F_GET_SEALS) final", seals_end, errno);
    if (!(seals_end & F_SEAL_FUTURE_WRITE)) {
        printf("  control: FUTURE_WRITE seal missing after publication\n");
        control_fail = 1;
    }

    /* Leave the pre-seal mapping live until the end: its existence must not
     * have disturbed the publication either. */
    try_upgrade(p_pre);
    munmap(p_pre, PAGE);
    close(fd);
    printf("\n");
    fflush(stdout);
}

/* ============ S2: racing mmap admission vs publication ============ */

struct race_ctx {
    int fd;
    atomic_int published; /* 1 after the sealer's fcntl returned */
    atomic_int stop;
    atomic_long go; /* barrier substitute for thread start */
    unsigned long spin_delay;
    unsigned long iters;
};

static void *mapper_thread(void *arg)
{
    struct race_ctx *ctx = arg;
    pin(0);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(50);

    for (unsigned long i = 0; i < ctx->iters && !atomic_load_explicit(&ctx->stop, memory_order_relaxed); i++) {
        /* Classification: does the seal already exist at syscall-entry time
         * in this thread? Both F_GET_SEALS and the mmap admission take the
         * MemfdInode seals mutex, so this ordering is authoritative. */
        int seals_before = get_seals(ctx->fd);
        int post = (seals_before & EXPECT_SEAL) != 0;

        void *p = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, ctx->fd, 0);
        if (p == MAP_FAILED) {
            atomic_fetch_add(&win_admit_fail, 1);
            continue;
        }
        if (post) {
            atomic_fetch_add(&postobs_admit_ok, 1);
            if (try_upgrade(p) == 0) {
                *(volatile unsigned char *)p = 0x41;
                printf("  CR1 BUG A: post-publication admission upgraded to "
                       "PROT_WRITE (seals seen before mmap: 0x%x)\n", seals_before);
                bug_a = 1;
            } else {
                atomic_fetch_add(&postobs_upgrade_eacces, 1);
            }
        } else {
            atomic_fetch_add(&win_admit_ok, 1);
            if (try_upgrade(p) == 0)
                atomic_fetch_add(&win_upgrade_ok, 1);
            else
                atomic_fetch_add(&win_upgrade_fail, 1);
        }
        munmap(p, PAGE);

        /* PROT_WRITE admission arm. */
        seals_before = get_seals(ctx->fd);
        post = (seals_before & EXPECT_SEAL) != 0;
        void *q = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, ctx->fd, 0);
        if (q != MAP_FAILED) {
            *(volatile unsigned char *)q = 0x42;
            if (post) {
                printf("  CR1 BUG A: post-publication PROT_WRITE mmap admitted "
                       "(seals seen before mmap: 0x%x)\n", seals_before);
                bug_a = 1;
            } else {
                atomic_fetch_add(&mid_wmmap_ok, 1);
            }
            munmap(q, PAGE);
        } else if (post) {
            atomic_fetch_add(&postobs_wmmap_eperm, 1);
        }
        spin(ctx->spin_delay);
    }
    return NULL;
}

static void *sealer_thread(void *arg)
{
    struct race_ctx *ctx = arg;
    pin(1);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(50);
    spin(ctx->spin_delay * 3);
    long r = add_seals(ctx->fd, F_SEAL_FUTURE_WRITE);
    if (r != 0) {
        printf("  control: F_ADD_SEALS(FUTURE_WRITE) failed errno=%d\n", errno);
        control_fail = 1;
    }
    atomic_store_explicit(&ctx->published, 1, memory_order_release);
    /* The mapper is bounded only by its own iteration budget so that the
     * post-publication buckets accumulate real volume. */
    return NULL;
}

static void run_racing_round(int nthreads_mapper, int nthreads_sealer,
                             unsigned long mapper_iters, unsigned long spin_delay,
                             unsigned int seals_flags)
{
    struct race_ctx ctx;
    atomic_init(&ctx.published, 0);
    atomic_init(&ctx.stop, 0);
    atomic_init(&ctx.go, 0);
    ctx.spin_delay = spin_delay;
    ctx.iters = mapper_iters;

    ctx.fd = new_memfd("cr1-race");
    if (ctx.fd < 0)
        return;

    pthread_t mappers[2], sealers[2];
    for (int i = 0; i < nthreads_mapper; i++)
        pthread_create(&mappers[i], NULL, mapper_thread, &ctx);
    for (int i = 0; i < nthreads_sealer; i++)
        pthread_create(&sealers[i], NULL, sealer_thread, &ctx);
    atomic_store_explicit(&ctx.go, 1, memory_order_release);
    for (int i = 0; i < nthreads_mapper; i++)
        pthread_join(mappers[i], NULL);
    for (int i = 0; i < nthreads_sealer; i++)
        pthread_join(sealers[i], NULL);

    /* Post-publication probes from the main thread: the sealers have been
     * joined, so these admissions provably observe published seals. */
    int seals = get_seals(ctx.fd);
    if (!(seals & F_SEAL_FUTURE_WRITE)) {
        printf("  control: seal not published after join (0x%x)\n", seals);
        control_fail = 1;
    }
    errno = 0;
    void *q = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, ctx.fd, 0);
    if (q != MAP_FAILED) {
        printf("  CR1 BUG A: PROT_WRITE mmap admitted after publication+join\n");
        bug_a = 1;
        munmap(q, PAGE);
    }
    errno = 0;
    void *p = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, ctx.fd, 0);
    if (p == MAP_FAILED) {
        if (seals_flags & F_SEAL_WRITE) {
            /* Asterinas over-rejects read-only rw-fd admissions after a WRITE
             * seal (the MC-1 surface). Record, do not flag for CR-1. */
            atomic_fetch_add(&s4_ro_admit_eperm, 1);
        } else {
            printf("  control: post-seal read-only mmap failed errno=%d\n", errno);
            control_fail = 1;
        }
    } else {
        if (try_upgrade(p) == 0) {
            printf("  CR1 BUG A: post-publication read-only admission upgraded "
                   "after join\n");
            bug_a = 1;
        }
        munmap(p, PAGE);
    }
    close(ctx.fd);
}

/* ============ S4: combined WRITE+FUTURE_WRITE publication ============ */

struct s4_ctx {
    int fd;
    atomic_int go, stop, sealed;
    unsigned long iters;
};

static void *s4_mapper(void *arg)
{
    struct s4_ctx *ctx = arg;
    pin(0);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(50);
    for (unsigned long i = 0; i < ctx->iters; i++) {
        int seals_before = get_seals(ctx->fd);
        int post = (seals_before & (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE)) != 0;
        void *p = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, ctx->fd, 0);
        if (p != MAP_FAILED) {
            if (post && try_upgrade(p) == 0) {
                printf("  CR1 BUG A: post-(W+FUTURE)-publication admission "
                       "upgraded to PROT_WRITE (seals: 0x%x)\n", seals_before);
                bug_a = 1;
            }
            munmap(p, PAGE);
        } else if (post) {
            atomic_fetch_add(&s4_ro_admit_eperm, 1); /* MC-1 surface info */
        }
        void *q = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, ctx->fd, 0);
        if (q != MAP_FAILED) {
            if (post) {
                printf("  CR1 BUG A: post-(W+FUTURE)-publication PROT_WRITE "
                       "mmap admitted (seals: 0x%x)\n", seals_before);
                bug_a = 1;
            }
            munmap(q, PAGE);
        }
        spin(97);
    }
    return NULL;
}

static void s4_control_and_race(void)
{
    printf("[S4] combined F_SEAL_WRITE|F_SEAL_FUTURE_WRITE publication\n");
    /* Control: an upgradable mapping makes the combined seal fail EBUSY. */
    int fd = new_memfd("cr1-s4ctl");
    if (fd >= 0) {
        void *p = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
        if (p != MAP_FAILED) {
            long r = add_seals(fd, F_SEAL_WRITE | F_SEAL_FUTURE_WRITE);
            report("F_ADD_SEALS(WRITE|FUTURE_WRITE) with upgradable mapping", r, errno);
            if (r == 0) {
                /* Not CR-1's overlap mechanism: record as control mismatch. */
                printf("  control: WRITE seal published over an upgradable mapping\n");
                control_fail = 1;
            } else if (errno != EBUSY) {
                control_fail = 1;
            } else {
                atomic_fetch_add(&s4_seal_ebusy, 1);
                /* The mapping keeps eligibility even after the EBUSY. */
                if (try_upgrade(p) != 0) {
                    printf("  CR1 BUG B: mapping lost eligibility after a "
                           "failed (EBUSY) seal attempt (errno=%d)\n", errno);
                    bug_b = 1;
                }
            }
            munmap(p, PAGE);
        }
        close(fd);
    }

    /* Race: mapper churn vs combined-seal publication until it lands. */
    for (int round = 0; round < 12 && !bug_a; round++) {
        struct s4_ctx ctx;
        atomic_init(&ctx.go, 0);
        atomic_init(&ctx.stop, 0);
        atomic_init(&ctx.sealed, 0);
        ctx.iters = 400;
        ctx.fd = new_memfd("cr1-s4");
        if (ctx.fd < 0)
            return;
        pthread_t tm;
        pthread_create(&tm, NULL, s4_mapper, &ctx);
        atomic_store_explicit(&ctx.go, 1, memory_order_release);
        /* Let the mapper warm up, then attempt the publication. */
        spin(300 + round * 37);
        long r = add_seals(ctx.fd, F_SEAL_WRITE | F_SEAL_FUTURE_WRITE);
        if (r == 0)
            atomic_fetch_add(&s4_seal_ok, 1);
        else
            atomic_fetch_add(&s4_seal_ebusy, 1);
        pthread_join(tm, NULL);
        close(ctx.fd);
    }
    printf("  combined-seal rounds: ok=%ld ebusy=%ld ro-admit-EPERM(MC-1 surface)=%ld\n",
           atomic_load(&s4_seal_ok), atomic_load(&s4_seal_ebusy),
           atomic_load(&s4_ro_admit_eperm));
    printf("\n");
    fflush(stdout);
}

/* ============ S5: mprotect churn on pre-seal mappings vs publication ===== */

struct churn_ctx {
    void *p; /* pre-admitted PROT_READ mapping */
    atomic_int go, stop;
    unsigned long iters;
    int id;
};

static void *churner(void *arg)
{
    struct churn_ctx *ctx = arg;
    pin(ctx->id);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(100);
    for (unsigned long i = 0; i < ctx->iters; i++) {
        if (try_upgrade(ctx->p) != 0) {
            printf("  CR1 BUG B: pre-seal mapping %d lost eligibility during "
                   "churn (iter %lu, errno=%d)\n", ctx->id, i, errno);
            bug_b = 1;
            return NULL;
        }
        *(volatile unsigned char *)ctx->p = (unsigned char)(0x60 + ctx->id);
        if (try_downgrade(ctx->p) != 0) {
            printf("  CR1 BUG B: downgrade failed during churn (errno=%d)\n", errno);
            bug_b = 1;
            return NULL;
        }
        atomic_fetch_add(&churn_iters, 1);
        spin(ctx->id ? 113 : 57);
    }
    return NULL;
}

static void s5_churn_vs_publication(void)
{
    printf("[S5] concurrent mprotect churn on pre-seal mappings during publication\n");
    int fd = new_memfd("cr1-s5");
    if (fd < 0)
        return;

    void *p1 = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    void *p2 = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    if (p1 == MAP_FAILED || p2 == MAP_FAILED) {
        printf("  control: pre-seal mappings failed\n");
        control_fail = 1;
        close(fd);
        return;
    }
    int seals0 = get_seals(fd);
    if (seals0 != 0) {
        control_fail = 1;
    }

    struct churn_ctx c1 = { 0 }, c2 = { 0 };
    c1.p = p1; c1.iters = 8000UL; c1.id = 0;
    c2.p = p2; c2.iters = 8000UL; c2.id = 1;
    atomic_init(&c1.go, 0); atomic_init(&c1.stop, 0);
    atomic_init(&c2.go, 0); atomic_init(&c2.stop, 0);
    pthread_t t1, t2;
    pthread_create(&t1, NULL, churner, &c1);
    pthread_create(&t2, NULL, churner, &c2);
    atomic_store_explicit(&c1.go, 1, memory_order_release);
    atomic_store_explicit(&c2.go, 1, memory_order_release);

    /* Publish while both churners upgrade/downgrade. */
    long r = add_seals(fd, F_SEAL_FUTURE_WRITE);
    report("F_ADD_SEALS(FUTURE_WRITE) during churn", r, errno);
    if (r != 0)
        control_fail = 1;

    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    /* Eligibility must survive the publication + churn. */
    if (try_upgrade(p1) != 0 || try_upgrade(p2) != 0) {
        printf("  CR1 BUG B: pre-seal mapping lost eligibility after churn (errno=%d)\n", errno);
        bug_b = 1;
    } else {
        printf("  ok: both pre-seal mappings still upgrade after publication+churn "
               "(%ld churn iterations)\n", atomic_load(&churn_iters));
    }

    /* Shared-page visibility check through a post-seal observer. */
    *(volatile unsigned char *)p1 = 0x5A;
    *(volatile unsigned char *)p2 = 0x5B;
    try_downgrade(p1);
    errno = 0;
    void *obs = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    if (obs != MAP_FAILED) {
        if (*(volatile unsigned char *)obs != 0x5B) {
            printf("  CR1 BUG TORN: stores from upgraded mappings not coherent "
                   "(observed 0x%02x)\n", *(volatile unsigned char *)obs);
            bug_torn = 1;
        }
        munmap(obs, PAGE);
    }

    munmap(p1, PAGE);
    munmap(p2, PAGE);
    close(fd);
    printf("\n");
    fflush(stdout);
}

/* helper never used — placeholder removed below */

/* ====== S6 (Level 1): timing-assisted stress ====== */

/* Burst admissions around the first publication. The sealer publishes after a
 * swept delay while the mapper fires admissions continuously before the seal
 * is visible, then keeps re-issuing the (idempotent) add so the publication
 * critical section stays hot against admission checks. */
struct s6a_arg {
    struct race_ctx *ctx;
    unsigned long delay;
};

static void *s6a_republisher(void *arg)
{
    struct s6a_arg *a = arg;
    struct race_ctx *ctx = a->ctx;
    pin(1);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(50);
    spin(a->delay);
    long r = add_seals(ctx->fd, F_SEAL_FUTURE_WRITE);
    if (r != 0) {
        printf("  control: S6 publication failed errno=%d\n", errno);
        control_fail = 1;
    }
    atomic_store_explicit(&ctx->published, 1, memory_order_release);
    /* Keep the publication critical section hot: re-add the (idempotent)
     * seal so admission checks keep contending with it. The mapper is
     * bounded only by its own iteration budget. */
    for (int i = 0; i < 2000; i++) {
        add_seals(ctx->fd, F_SEAL_FUTURE_WRITE);
        spin(3);
    }
    return NULL;
}

static void s6a_burst_round(unsigned long sealer_delay)
{
    struct race_ctx ctx;
    atomic_init(&ctx.published, 0);
    atomic_init(&ctx.stop, 0);
    atomic_init(&ctx.go, 0);
    ctx.spin_delay = 0;
    ctx.iters = 250;

    ctx.fd = new_memfd("cr1-s6a");
    if (ctx.fd < 0)
        return;

    struct s6a_arg arg = { &ctx, sealer_delay };
    pthread_t tm, ts;
    pthread_create(&tm, NULL, mapper_thread, &ctx);
    pthread_create(&ts, NULL, s6a_republisher, &arg);
    atomic_store_explicit(&ctx.go, 1, memory_order_release);
    pthread_join(tm, NULL);
    pthread_join(ts, NULL);

    errno = 0;
    void *q = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, ctx.fd, 0);
    if (q != MAP_FAILED) {
        printf("  CR1 BUG A: post-publication PROT_WRITE mmap admitted (S6a)\n");
        bug_a = 1;
        munmap(q, PAGE);
    }
    close(ctx.fd);
}

/* Split/merge churn on a 4-page pre-admitted mapping during publication:
 * partial mprotects split the mapping, full upgrades merge it back. Every
 * upgrade must succeed and every store must work. */
struct s6b_ctx {
    int fd;
    void *p; /* 4 pages */
    atomic_int go, stop;
    unsigned long iters;
};

static void *s6b_publisher(void *arg)
{
    struct s6b_ctx *ctx = arg;
    pin(1);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(100);
    spin(700);
    long r = add_seals(ctx->fd, F_SEAL_FUTURE_WRITE);
    if (r != 0) {
        printf("  control: S6b publication failed errno=%d\n", errno);
        control_fail = 1;
    }
    for (int i = 0; i < 300; i++) {
        add_seals(ctx->fd, F_SEAL_FUTURE_WRITE);
        spin(37);
    }
    return NULL;
}

static void *s6b_churner(void *arg)
{
    struct s6b_ctx *ctx = arg;
    pin(0);
    while (!atomic_load_explicit(&ctx->go, memory_order_acquire))
        spin(100);
    for (unsigned long i = 0; i < ctx->iters; i++) {
        if (mprotect(ctx->p, 4 * PAGE, PROT_READ | PROT_WRITE) != 0) {
            printf("  CR1 BUG B: full upgrade of pre-seal mapping failed in "
                   "split/merge churn (iter %lu, errno=%d)\n", i, errno);
            bug_b = 1;
            return NULL;
        }
        *(volatile unsigned char *)(ctx->p) = 0x51;
        *(volatile unsigned char *)((char *)ctx->p + 3 * PAGE) = 0x52;
        /* Split: protect the first half back to read-only. */
        if (mprotect(ctx->p, 2 * PAGE, PROT_READ) != 0) {
            printf("  CR1 BUG B: partial protect failed (iter %lu, errno=%d)\n", i, errno);
            bug_b = 1;
            return NULL;
        }
        /* The second half is still writable... */
        *(volatile unsigned char *)((char *)ctx->p + 3 * PAGE) = 0x53;
        /* ...and each split piece must keep its upgrade eligibility. */
        if (try_upgrade(ctx->p) != 0) {
            printf("  CR1 BUG B: left split piece lost eligibility (iter %lu, errno=%d)\n",
                   i, errno);
            bug_b = 1;
            return NULL;
        }
        *(volatile unsigned char *)ctx->p = 0x54;
        if (mprotect(ctx->p, 4 * PAGE, PROT_READ) != 0) {
            printf("  CR1 BUG B: downgrade failed (errno=%d)\n", errno);
            bug_b = 1;
            return NULL;
        }
        atomic_fetch_add(&churn_iters, 1);
        spin(41);
    }
    return NULL;
}

static void s6b_split_merge_churn(void)
{
    printf("[S6b] split/merge churn via partial mprotect vs publication\n");
    int fd = new_memfd("cr1-s6b");
    if (fd < 0)
        return;
    if (ftruncate(fd, 4 * (off_t)PAGE) != 0) {
        report("ftruncate(4 pages)", -1, errno);
        close(fd);
        return;
    }
    errno = 0;
    void *p = mmap(NULL, 4 * PAGE, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        report("mmap(4 pages, PROT_READ, MAP_SHARED)", -1, errno);
        control_fail = 1;
        close(fd);
        return;
    }
    if (get_seals(fd) != 0)
        control_fail = 1;

    struct s6b_ctx ctx = { 0 };
    ctx.fd = fd;
    ctx.p = p;
    ctx.iters = 4000;
    atomic_init(&ctx.go, 0);
    atomic_init(&ctx.stop, 0);

    pthread_t t1, t2;
    pthread_create(&t1, NULL, s6b_churner, &ctx);
    pthread_create(&t2, NULL, s6b_publisher, &ctx);
    atomic_store_explicit(&ctx.go, 1, memory_order_release);
    pthread_join(t2, NULL);
    pthread_join(t1, NULL);

    /* Final eligibility check on the still-live pre-seal mapping. */
    if (mprotect(p, 4 * PAGE, PROT_READ | PROT_WRITE) != 0) {
        printf("  CR1 BUG B: pre-seal mapping lost eligibility after churn (errno=%d)\n", errno);
        bug_b = 1;
    } else {
        printf("  ok: pre-seal mapping upgrades after %ld churn iterations\n",
               atomic_load(&churn_iters));
    }
    munmap(p, 4 * PAGE);
    close(fd);
    printf("\n");
    fflush(stdout);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("CR-1 overlap reproduction: FUTURE_WRITE publication vs mmap admission / mprotect\n");
    {
        struct utsname u;
        if (uname(&u) == 0)
            printf("kernel: %s %s (%s)\n", u.sysname, u.release, u.nodename);
    }
    printf("\n");

    s1_deterministic_core();

    printf("[S2] racing mmap admission vs FUTURE_WRITE publication (2 threads)\n");
    for (int round = 0; round < 100; round++)
        run_racing_round(1, 1, 150UL, 17UL + (unsigned long)round * 13, F_SEAL_FUTURE_WRITE);
    printf("  racing window: admitted=%ld failed=%ld upgraded_ok=%ld upgraded_fail=%ld "
           "(mid-window, both legal)\n",
           atomic_load(&win_admit_ok), atomic_load(&win_admit_fail),
           atomic_load(&win_upgrade_ok), atomic_load(&win_upgrade_fail));
    printf("  post-publication: read-admit-ok=%ld upgrade-eacces=%ld wmmap-eperm=%ld\n",
           atomic_load(&postobs_admit_ok), atomic_load(&postobs_upgrade_eacces),
           atomic_load(&postobs_wmmap_eperm));
    printf("\n");

    printf("[S3] 4-thread extension: 2 mappers + 2 concurrent sealers (beyond MC bounds)\n");
    for (int round = 0; round < 60; round++)
        run_racing_round(2, 2, 150UL, 29UL + (unsigned long)round * 7, F_SEAL_FUTURE_WRITE);
    printf("  racing window: admitted=%ld failed=%ld upgraded_ok=%ld upgraded_fail=%ld\n",
           atomic_load(&win_admit_ok), atomic_load(&win_admit_fail),
           atomic_load(&win_upgrade_ok), atomic_load(&win_upgrade_fail));
    printf("\n");

    s4_control_and_race();
    s5_churn_vs_publication();

    printf("[S6a] Level-1: burst admissions around publication\n");
    for (int round = 0; round < 200; round++)
        s6a_burst_round(11UL + (unsigned long)round * 23);
    printf("  burst window: admitted=%ld failed=%ld upgraded_ok=%ld upgraded_fail=%ld\n",
           atomic_load(&win_admit_ok), atomic_load(&win_admit_fail),
           atomic_load(&win_upgrade_ok), atomic_load(&win_upgrade_fail));
    printf("\n");

    s6b_split_merge_churn();

    printf("================ CR-1 summary ================\n");
    printf("harm(a) forbidden new write access : %s\n", bug_a ? "TRIGGERED" : "none");
    printf("harm(b) stripped eligibility       : %s\n", bug_b ? "TRIGGERED" : "none");
    printf("torn write state                   : %s\n", bug_torn ? "TRIGGERED" : "none");
    printf("control mismatches                 : %s\n", control_fail ? "YES" : "none");
    if (bug_a || bug_b || bug_torn) {
        printf("CR1_REPRO: TRIGGERED (a=%d b=%d torn=%d)\n", bug_a, bug_b, bug_torn);
    } else if (control_fail) {
        printf("CR1_REPRO: CONTROL_FAIL\n");
    } else {
        printf("CR1_REPRO: NOTHING (invariants held)\n");
    }
    fflush(stdout);
    return bug_a ? 3 : (bug_b ? 4 : (bug_torn ? 5 : (control_fail ? 6 : 0)));
}
