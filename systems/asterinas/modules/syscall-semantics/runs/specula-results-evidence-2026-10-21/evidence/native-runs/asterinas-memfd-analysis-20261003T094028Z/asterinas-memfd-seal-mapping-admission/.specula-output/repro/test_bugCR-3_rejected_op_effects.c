// SPDX-License-Identifier: MPL-2.0
//
// CR-3 reproduction (Level 0 — pure public-API syscalls, single process, no
// failpoints, no state injection, no source modification).
//
// Finding: "Failed mprotect prefix and busy seal addition may leave
// inconsistent observable effects" — scenario-4 remaining arms (rejected
// operations must keep their operation-specific, Linux-contract effects).
//
// Arm A (EACCES mid-range prefix): a multi-segment mprotect over A (2 pages
//   RW via the writable memfd fd, has MAY_WRITE) followed by B (1 page
//   read-only shared via an O_RDONLY handle of the same memfd, no MAY_WRITE —
//   the Linux VM_MAYWRITE admission rule) fails with EACCES on the B segment.
//   The Linux contract keeps the already-applied prefix: A must remain
//   writable after the failure (a wrong rollback would discard it), B must
//   NOT acquire WRITE (an over-grant beyond its MAY bits), and both
//   mappings' MAY-bit admission must be unchanged afterwards.
// Arm B (ENOMEM over a hole): mprotect over a 3-page mapping whose middle
//   page was unmapped fails with ENOMEM; pages before the hole must stay
//   protected (prefix applied and retained), and the suffix must be
//   untouched. This is the contract stated in mprotect(2) and in
//   Asterinas's own doc comment in protect.rs ("pages before the unmapped
//   hole are still protected").
// Arm C (busy combined seal): F_ADD_SEALS(F_SEAL_WRITE|F_SEAL_FUTURE_WRITE|
//   F_SEAL_SEAL) while a writable shared mapping is active fails with EBUSY.
//   The Linux contract is all-or-nothing: F_GET_SEALS must be unchanged (no
//   partial publication of the non-WRITE bits), the deny flag must not leak
//   (a second writable shared mmap and write(fd) still succeed), and after
//   unmapping the retry must succeed and publish all three bits with full
//   enforcement (new writable shared mmap -> EPERM, write(fd) -> EPERM).
//
// Every FAIL line is an observable deviation from that contract, i.e. the
// finding's hypothesized inconsistency manifesting. Exit status 0 means all
// checks passed and the hypothesized deviations did NOT occur.
//
// Reference runs:
//   Linux (host kernel in the asterinas/dev container) — step1.
//   Asterinas guest (instrumented worktree == /work/source, scheme
//   specula_memfd) via the guest initramfs — step2.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
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
#define F_SEAL_SEAL 0x0001
#define F_SEAL_SHRINK 0x0002
#define F_SEAL_GROW 0x0004
#define F_SEAL_WRITE 0x0008
#define F_SEAL_FUTURE_WRITE 0x0010
#endif
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

#define PAGE 4096
#define COMBINED (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE | F_SEAL_SEAL)

static int g_pass, g_fail;

static void pass(const char *id, const char *fmt, ...)
{
    g_pass++;
    va_list ap;
    va_start(ap, fmt);
    printf("PASS %s: ", id);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}

static void fail(const char *id, const char *fmt, ...)
{
    g_fail++;
    va_list ap;
    va_start(ap, fmt);
    printf("FAIL %s: ", id);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}

/* Expects the raw syscall result 0. */
static int expect_ok(const char *id, const char *what, long ret)
{
    if (ret == 0) {
        pass(id, "%s succeeded", what);
        return 1;
    }
    fail(id, "%s expected success, got ret=%ld errno=%d (%s)",
         what, ret, errno, strerror(errno));
    return 0;
}

/* Expects the raw syscall result -1 with errno == want. */
static int expect_fail(const char *id, const char *what, int want, long ret)
{
    if (ret == -1 && errno == want) {
        pass(id, "%s failed with %s as expected", what, strerror(want));
        return 1;
    }
    fail(id, "%s expected %s, got ret=%ld errno=%d (%s)",
         what, strerror(want), ret, errno, strerror(errno));
    return 0;
}

static void segv_exit(int sig)
{
    (void)sig;
    _exit(0);
}

/* Writes *addr in a forked child. Returns 1 if writable, 0 if it faults. */
static int probe_writable(volatile char *addr)
{
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        exit(2);
    }
    if (pid == 0) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = segv_exit;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        *addr = 'X';
        _exit(1);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        perror("waitpid");
        exit(2);
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : 0;
}

int main(void)
{
    int fd = (int)syscall(SYS_memfd_create, "cr3", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        perror("memfd_create");
        return 2;
    }
    if (ftruncate(fd, 4 * PAGE)) {
        perror("ftruncate");
        return 2;
    }
    printf("CR-3 rejected-operation effects: memfd ready (fd=%d, 4 pages)\n", fd);

    /* Reserve then free a 64-page VA window so MAP_FIXED_NOREPLACE has room. */
    char *hint = mmap(NULL, 64 * PAGE, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (hint == MAP_FAILED) {
        perror("reserve");
        return 2;
    }
    if (munmap(hint, 64 * PAGE)) {
        perror("munmap reserve");
        return 2;
    }
    char *A = hint;              /* 2 pages, RW MAP_SHARED via the writable fd  */
    char *B = hint + 2 * PAGE;   /* 1 page,  RO  MAP_SHARED via O_RDONLY fd     */
    char *C = hint + 8 * PAGE;   /* 3 pages, RW MAP_SHARED via the writable fd  */
    char *M1 = hint + 16 * PAGE; /* C1 first writable shared mapping            */
    char *M2 = hint + 17 * PAGE; /* C4 second writable shared mapping           */
    char *M3 = hint + 18 * PAGE; /* C8 post-seal writable mapping attempt       */

    /* ---------- Arm A: EACCES mid-range must keep the applied prefix ---------- */

    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    int fd_ro = open(path, O_RDONLY);
    if (fd_ro < 0) {
        fail("A0", "open(%s, O_RDONLY) failed: %s", path, strerror(errno));
    } else {
        pass("A0", "O_RDONLY memfd handle opened via /proc/self/fd");
    }

    void *pa = mmap(A, 2 * PAGE, PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    void *pb = mmap(B, PAGE, PROT_READ,
                    MAP_SHARED | MAP_FIXED_NOREPLACE, fd_ro, 0);
    if (pa == MAP_FAILED || pb == MAP_FAILED) {
        fail("A1", "fixed mappings failed: A=%p B=%p errno=%d (%s)",
             pa, pb, errno, strerror(errno));
        return 2;
    }
    pass("A1", "A (2 pages RW via writable fd) + B (1 page RO via O_RDONLY fd) mapped adjacently");

    expect_ok("A2", "mprotect(A, 2 pages, PROT_READ)",
              mprotect(A, 2 * PAGE, PROT_READ));
    expect_fail("A3", "mprotect(A+B, PROT_READ|PROT_WRITE)", EACCES,
                mprotect(A, 3 * PAGE, PROT_READ | PROT_WRITE));
    {
        int w = probe_writable(&A[0]);
        if (w == 1)
            pass("A4", "prefix preserved: write to A[0] succeeded after the failed mprotect");
        else
            fail("A4", "prefix NOT preserved: write to A[0] returned %d (expected writable=1)", w);
    }
    {
        int w = probe_writable(&B[0]);
        if (w == 0)
            pass("A5", "no over-grant: write to B[0] still faults (PROT_WRITE beyond MAY_WRITE refused)");
        else
            fail("A5", "over-grant: write to B[0] returned %d (expected SIGSEGV=0)", w);
    }
    expect_ok("A6", "mprotect(A alone, PROT_READ|PROT_WRITE)",
              mprotect(A, 2 * PAGE, PROT_READ | PROT_WRITE));
    expect_fail("A7", "mprotect(B alone, PROT_READ|PROT_WRITE)", EACCES,
                mprotect(B, PAGE, PROT_READ | PROT_WRITE));

    /* ---------- Arm B: ENOMEM over a hole must keep the protected prefix ---------- */

    {
        void *pc = mmap(C, 3 * PAGE, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
        if (pc == MAP_FAILED) {
            fail("B1", "fixed mapping failed: %s", strerror(errno));
            return 2;
        }
        pass("B1", "C (3 pages RW) mapped");
    }
    expect_ok("B2", "munmap middle page", munmap(C + PAGE, PAGE));
    expect_fail("B3", "mprotect(C with hole, PROT_READ)", ENOMEM,
                mprotect(C, 3 * PAGE, PROT_READ));
    {
        int w = probe_writable(&C[0]);
        if (w == 0)
            pass("B4", "prefix protected: write to C[0] faults after the failed mprotect");
        else
            fail("B4", "prefix not protected: write to C[0] returned %d (expected SIGSEGV=0)", w);
    }
    {
        int w = probe_writable(&C[2 * PAGE]);
        if (w == 1)
            pass("B5", "suffix untouched: write to C[2] still succeeds");
        else
            fail("B5", "suffix changed: write to C[2] returned %d (expected writable=1)", w);
    }

    /* ---------- Arm C: busy combined seal addition must publish nothing ---------- */

    {
        void *m1 = mmap(M1, PAGE, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
        if (m1 == MAP_FAILED) {
            fail("C1", "writable shared mmap failed: %s", strerror(errno));
            return 2;
        }
        pass("C1", "writable shared mapping active");
    }
    expect_fail("C2", "F_ADD_SEALS(WRITE|FUTURE_WRITE|SEAL) while writable-mapped", EBUSY,
                fcntl(fd, F_ADD_SEALS, COMBINED));
    {
        long seals = fcntl(fd, F_GET_SEALS);
        if (seals == 0)
            pass("C3", "no partial publication: F_GET_SEALS == 0 after the EBUSY failure");
        else
            fail("C3", "seal bits published despite failure: F_GET_SEALS == 0x%lx", seals);
    }
    {
        void *m2 = mmap(M2, PAGE, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
        if (m2 == MAP_FAILED)
            fail("C4", "deny flag leaked: second writable shared mmap failed: %s", strerror(errno));
        else
            pass("C4", "deny flag not leaked: second writable shared mmap admitted");
    }
    {
        char buf = 'X';
        ssize_t n = write(fd, &buf, 1);
        if (n == 1)
            pass("C5", "write(fd) still succeeds after the EBUSY failure");
        else
            fail("C5", "write(fd) unexpectedly failed: ret=%ld errno=%d (%s)",
                 (long)n, errno, strerror(errno));
    }
    {
        /* Remove every mapping of the memfd (A and C were RW since A6/B5,
         * plus the two C1/C4 mappings) so the seal retry can succeed. */
        int rc = munmap(A, 2 * PAGE);
        rc |= munmap(B, PAGE);
        rc |= munmap(C, 3 * PAGE);
        rc |= munmap(M1, PAGE);
        rc |= munmap(M2, PAGE);
        if (rc)
            fail("C6", "munmap before retrying the seal failed: %s", strerror(errno));
    }
    expect_ok("C6", "F_ADD_SEALS(WRITE|FUTURE_WRITE|SEAL) after munmap",
              fcntl(fd, F_ADD_SEALS, COMBINED));
    {
        long seals = fcntl(fd, F_GET_SEALS);
        if (seals == COMBINED)
            pass("C7", "all bits published after success: F_GET_SEALS == 0x%x", COMBINED);
        else
            fail("C7", "wrong seals after success: F_GET_SEALS == 0x%lx (expected 0x%x)",
                 seals, COMBINED);
    }
    {
        void *m3 = mmap(M3, PAGE, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
        if (m3 == MAP_FAILED && errno == EPERM)
            pass("C8", "new writable shared mmap after sealing failed with %s as expected",
                 strerror(EPERM));
        else
            fail("C8", "new writable shared mmap after sealing expected %s, got ret=%p errno=%d (%s)",
                 strerror(EPERM), m3, errno, strerror(errno));
    }
    {
        char buf = 'X';
        ssize_t n = write(fd, &buf, 1);
        if (n == -1 && errno == EPERM)
            pass("C9", "write(fd) after F_SEAL_WRITE failed with %s as expected",
                 strerror(EPERM));
        else
            fail("C9", "write(fd) after F_SEAL_WRITE expected %s, got ret=%ld errno=%d (%s)",
                 strerror(EPERM), (long)n, errno, strerror(errno));
    }

    printf("CR-3 summary: %d checks passed, %d checks failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
