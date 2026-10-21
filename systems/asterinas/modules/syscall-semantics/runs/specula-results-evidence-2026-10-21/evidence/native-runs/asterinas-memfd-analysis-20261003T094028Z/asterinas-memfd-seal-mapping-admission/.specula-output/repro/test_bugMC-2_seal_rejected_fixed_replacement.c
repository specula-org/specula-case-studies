/*
 * test_bugMC-2_seal_rejected_fixed_replacement.c
 *
 * Finding MC-2: "Seal-rejected fixed replacement removes the existing mapping"
 * (Asterinas @ 0c60537098f4c2949ad2d382aaf499de72263d76).
 *
 * Level 0 black-box reproduction through the public syscall interface only.
 * The sequence instantiates the MC counterexample (spec/output/validation/
 * MC_hunt_TV2.out, invariant SealRejectedReplacement):
 *
 *   1. mmap(memfd, PROT_READ|PROT_WRITE, MAP_SHARED)          -> old mapping
 *   2. fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE)            -> succeeds
 *   3. mmap(same range, PROT_READ|PROT_WRITE,
 *           MAP_SHARED|MAP_FIXED, fd, 0)                      -> EPERM (both systems)
 *
 * Linux contract (mmap(2)/POSIX): a failed mmap must not modify the address
 * space, so the pre-existing mapping survives the EPERM.  The finding claims
 * Asterinas removes the old range *before* the seal check
 * (VmarMapOptions::build -> alloc_free_region_exact_truncate ->
 * MemfdInode::check_writable), leaving a hole after the failed syscall.
 *
 * Probes after the rejected fixed replacement:
 *   P1 mprotect(range, PROT_READ)      -> 0 = intact, ENOMEM = range unmapped
 *   P2 direct read with SIGSEGV guard  -> data intact vs fault
 *   P3 fork()ed child reads the range  -> exits 42 vs killed by SIGSEGV
 *   P4 fcntl(F_ADD_SEALS, F_SEAL_WRITE) -> EBUSY = old writable mapping still
 *      registered (Linux) vs success = the old owner was dropped (bug)
 *
 * Two shapes are exercised: full replacement (phase A, exactly the
 * counterexample: 1 page replaced by 1 page) and partial replacement
 * (phase B: middle page of a 3-page mapping replaced; edges must survive).
 *
 * Output is plain text on stdout; final line is
 *   MC2-VERDICT: OLD_MAPPING_INTACT     (Linux-correct behavior, exit 0)
 *   MC2-VERDICT: OLD_MAPPING_DESTROYED  (bug reproduced, exit 1)
 *   MC2-VERDICT: SETUP_FAILURE          (exit 3)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#endif
#ifndef F_GET_SEALS
#define F_GET_SEALS 1034
#endif
#ifndef F_SEAL_SEAL
#define F_SEAL_SEAL 0x0004
#endif
#ifndef F_SEAL_WRITE
#define F_SEAL_WRITE 0x0008
#endif
#ifndef F_SEAL_FUTURE_WRITE
#define F_SEAL_FUTURE_WRITE 0x0010
#endif
#ifndef SYS_memfd_create
#define SYS_memfd_create 319 /* x86_64 */
#endif

#define PAGE 4096

static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_fault_pending;

static void fault_handler(int sig)
{
    (void)sig;
    if (g_fault_pending) {
        g_fault_pending = 0;
        siglongjmp(g_jmp, 1);
    }
    _exit(128 + sig);
}

static int memfd_create_fd(const char *name)
{
    return (int)syscall(SYS_memfd_create, name, MFD_ALLOW_SEALING);
}

static const char *errno_name(int e)
{
    switch (e) {
    case 0: return "0";
    case EPERM: return "EPERM";
    case EBUSY: return "EBUSY";
    case ENOMEM: return "ENOMEM";
    case EACCES: return "EACCES";
    case EINVAL: return "EINVAL";
    case EEXIST: return "EEXIST";
    default: return "other";
    }
}

/* Reads one byte at p; returns 0 and stores the value on success, 1 on fault. */
static int guarded_read(volatile unsigned char *p, unsigned char *out)
{
    g_fault_pending = 1;
    if (sigsetjmp(g_jmp, 1) != 0) {
        g_fault_pending = 0;
        return 1;
    }
    *out = *p;
    g_fault_pending = 0;
    return 0;
}

/* Child probe: a fresh consumer process touches the range.  The child first
 * resets SIGSEGV/SIGBUS to their default dispositions (handlers are inherited
 * across fork), so a fault kills it exactly as it would kill a real consumer
 * process with no custom handlers installed. */
static const char *child_probe(volatile unsigned char *p)
{
    pid_t pid = fork();
    if (pid < 0)
        return "fork-failed";
    if (pid == 0) {
        struct sigaction d;
        memset(&d, 0, sizeof(d));
        d.sa_handler = SIG_DFL;
        sigaction(SIGSEGV, &d, NULL);
        sigaction(SIGBUS, &d, NULL);
        volatile unsigned char v = *p;
        (void)v;
        _exit(42);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0)
        return "waitpid-failed";
    if (WIFEXITED(status) && WEXITSTATUS(status) == 42)
        return "read-ok";
    if (WIFSIGNALED(status) && (WTERMSIG(status) == SIGSEGV || WTERMSIG(status) == SIGBUS))
        return "killed-by-fault";
    if (WIFEXITED(status) && (WEXITSTATUS(status) == 128 + SIGSEGV ||
                             WEXITSTATUS(status) == 128 + SIGBUS))
        return "exit-after-fault";
    return "unexpected-child-status";
}

/*
 * Runs one replacement scenario.  npages: size of the old mapping.
 * fixed_lo/fixed_hi: page indices [lo, hi) covered by the MAP_FIXED request.
 * Returns 0 = old range intact (correct), 1 = destroyed (bug), -1 = setup error.
 */
static int run_scenario(const char *label, int npages, int fixed_lo, int fixed_hi)
{
    size_t len = (size_t)npages * PAGE;
    unsigned char *base = NULL;
    int fd = memfd_create_fd("mc2");
    printf("mc2[%s]: begin (old mapping %d pages, fixed range [%d,%d))\n",
           label, npages, fixed_lo, fixed_hi);

    if (fd < 0) {
        printf("mc2[%s]: SETUP FAILURE: memfd_create: %s\n", label, strerror(errno));
        return -1;
    }
    if (ftruncate(fd, (off_t)len) != 0) {
        printf("mc2[%s]: SETUP FAILURE: ftruncate: %s\n", label, strerror(errno));
        return -1;
    }
    base = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        printf("mc2[%s]: SETUP FAILURE: initial mmap: %s\n", label, strerror(errno));
        return -1;
    }
    for (int i = 0; i < npages; i++)
        base[i * PAGE] = (unsigned char)(0xA0 + i);
    base[len - 1] = 0x5A;
    printf("mc2[%s]: step1 initial RW SHARED mmap ok, base=%p, pattern written\n",
           label, (void *)base);

    if (fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE) != 0) {
        printf("mc2[%s]: SETUP FAILURE: F_ADD_SEALS(F_SEAL_FUTURE_WRITE): %s\n",
               label, strerror(errno));
        return -1;
    }
    int seals = fcntl(fd, F_GET_SEALS);
    printf("mc2[%s]: step2 F_ADD_SEALS(F_SEAL_FUTURE_WRITE) ok, F_GET_SEALS=0x%x\n",
           label, seals);
    if (seals != F_SEAL_FUTURE_WRITE) {
        printf("mc2[%s]: SETUP FAILURE: unexpected seals 0x%x\n", label, seals);
        return -1;
    }

    void *fixed_addr = base + (size_t)fixed_lo * PAGE;
    size_t fixed_len = (size_t)(fixed_hi - fixed_lo) * PAGE;
    errno = 0;
    void *r = mmap(fixed_addr, fixed_len, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED, fd, (off_t)(fixed_lo * PAGE));
    if (r == MAP_FAILED && errno == EPERM) {
        printf("mc2[%s]: step3 fixed RW SHARED mmap -> MAP_FAILED EPERM "
               "(admission rejected, as on Linux)\n", label);
    } else if (r == MAP_FAILED) {
        printf("mc2[%s]: NOTE: fixed mmap failed with %s (expected EPERM)\n",
               label, errno_name(errno));
    } else {
        printf("mc2[%s]: ANOMALY: sealed memfd admitted a new writable shared "
               "mapping at %p (different bug)\n", label, r);
        return -1;
    }

    /* P1: mprotect over the whole replaced range. */
    int destroyed = 0, intact = 0;
    errno = 0;
    int mp = mprotect(base, len, PROT_READ);
    if (mp == 0) {
        printf("mc2[%s]: P1 mprotect(range, PROT_READ) -> 0 (range still mapped)\n", label);
        intact++;
    } else {
        printf("mc2[%s]: P1 mprotect(range, PROT_READ) -> -1 %s\n",
               label, errno_name(errno));
        if (errno == ENOMEM)
            destroyed++;
    }

    /* P2: guarded direct read of every page of the replaced range. */
    for (int i = fixed_lo; i < fixed_hi; i++) {
        unsigned char v = 0;
        if (guarded_read(&base[i * PAGE], &v) == 0) {
            printf("mc2[%s]: P2 read page %d -> 0x%02x (no fault)\n", label, i, v);
            if (v == (unsigned char)(0xA0 + i))
                intact++;
        } else {
            printf("mc2[%s]: P2 read page %d -> FAULT (SIGSEGV/SIGBUS caught)\n", label, i);
            destroyed++;
        }
    }

    /* P3: independent child consumer touches the replaced range. */
    const char *cp = child_probe(&base[(size_t)fixed_lo * PAGE]);
    printf("mc2[%s]: P3 child consumer -> %s\n", label, cp);
    if (strcmp(cp, "read-ok") == 0)
        intact++;
    else if (strcmp(cp, "killed-by-fault") == 0 || strcmp(cp, "exit-after-fault") == 0)
        destroyed++;

    /* P4 (informational): can F_SEAL_WRITE be added now?  On Linux the old
     * writable mapping still exists, so this must fail (EBUSY).  If the old
     * owner was dropped by the rejected replacement, it succeeds. */
    errno = 0;
    int sw = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE);
    printf("mc2[%s]: P4 F_ADD_SEALS(F_SEAL_WRITE) after rejected replacement -> %s%s\n",
           label, sw == 0 ? "success" : "-1 ", sw == 0 ? "" : errno_name(errno));

    /* Edge pages outside the replaced range must survive on every system. */
    for (int i = 0; i < npages; i++) {
        if (i >= fixed_lo && i < fixed_hi)
            continue;
        unsigned char v = 0;
        if (guarded_read(&base[i * PAGE], &v) == 0 && v == (unsigned char)(0xA0 + i)) {
            printf("mc2[%s]: edge page %d intact (0x%02x)\n", label, i, v);
        } else {
            printf("mc2[%s]: ANOMALY: edge page %d lost outside replaced range\n", label, i);
            destroyed++;
        }
    }

    printf("mc2[%s]: phase result: destroyed_probes=%d intact_probes=%d\n",
           label, destroyed, intact);
    if (destroyed > 0 && intact == 0)
        return 1;
    if (destroyed == 0 && intact > 0)
        return 0;
    printf("mc2[%s]: AMBIGUOUS probe outcome\n", label);
    return -1;
}

int main(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = fault_handler;
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    printf("mc2: MC-2 reproduction start (pid %d, page size %d)\n", getpid(), PAGE);

    /* Phase A: full replacement — exactly the MC counterexample shape. */
    int a = run_scenario("full", 1, 0, 1);
    /* Phase B: partial replacement — middle page of a 3-page mapping. */
    int b = run_scenario("partial", 3, 1, 2);

    printf("mc2: phase full -> %s\n",
           a == 1 ? "OLD_MAPPING_DESTROYED" : a == 0 ? "OLD_MAPPING_INTACT" : "AMBIGUOUS");
    printf("mc2: phase partial -> %s\n",
           b == 1 ? "OLD_MAPPING_DESTROYED" : b == 0 ? "OLD_MAPPING_INTACT" : "AMBIGUOUS");

    if (a < 0 && b < 0) {
        printf("MC2-VERDICT: SETUP_FAILURE\n");
        return 3;
    }
    if (a == 1 || b == 1) {
        printf("MC2-VERDICT: OLD_MAPPING_DESTROYED\n");
        return 1;
    }
    printf("MC2-VERDICT: OLD_MAPPING_INTACT\n");
    return 0;
}
