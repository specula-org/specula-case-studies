// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding MC-1:
//   "Post-seal read-only mappings retain writable accounting"
//
// Bug mechanism (Asterinas, source 0c60537098f4c2949ad2d382aaf499de72263d76):
//   kernel/core/src/vm/vmar/vmar_impls/map.rs:337 decides `is_writable_tracked`
//   from the fd-derived `may_perms` (an O_RDWR memfd keeps MAY_WRITE) BEFORE
//   MemfdInode::check_writable (kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80)
//   strips MAY_WRITE for sealed inodes. MappedVmo::new
//   (kernel/core/src/vm/vmar/vm_mapping.rs:944) then unconditionally acquires
//   writable ownership via Vmo::writable_mapping_status().map()
//   (kernel/core/src/vm/page_cache/vmo/mod.rs:1199) whenever the mapping was
//   created through a writable handle.
//
//   Linux v6.16.5 instead runs the seal check first (mm/memfd.c
//   check_write_seal clears VM_MAYWRITE for read-only shared mappings) and
//   only then decides the writable accounting (mm/vma.c mmap_region =>
//   is_shared_maywrite), so a read-only shared mapping of a sealed memfd
//   takes no writable count.
//
// Case A (matching the MC-1 counterexample trace step by step):
//   memfd_create(MFD_ALLOW_SEALING)  [O_RDWR fd]
//   fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)      -> OK
//   mmap(PROT_READ, MAP_SHARED, fd)          -> Linux: OK
//                                              Asterinas bug: EPERM
//     (the read-only mapping is rejected because it still tries to take the
//      writable-mapping slot although the WritableMappingStatus counter is -1)
//   Control: the same mmap through an O_RDONLY handle -> OK on both kernels
//            (the bug is specific to the writable-handle accounting decision).
//
// Case B (the second manifestation of the same cause):
//   memfd_create(MFD_ALLOW_SEALING)  [O_RDWR fd]
//   fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE) -> OK
//   mmap(PROT_READ, MAP_SHARED, fd)        -> OK on both kernels
//   mprotect(PROT_READ|PROT_WRITE)         -> EACCES on both (MAY_WRITE stripped)
//   fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)   -> Linux: OK (no writable mapping exists)
//                                              Asterinas bug: EBUSY
//     (the read-only mapping incremented the writable-mapping counter at
//      admission, so WRITE sealing falsely sees an active writable owner)
//   munmap                                 -> OK
//   fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)   -> OK on both (the counter dropped)
//
// The test uses only public APIs (memfd_create, ftruncate, fcntl, mmap,
// mprotect, munmap, open) with no instrumentation, no timing tricks, and no
// concurrency: the divergence is deterministic admission-control logic.
//
// Expected correct (Linux-compatible) outcome: both cases complete without
// violations; the program prints "MC-1: NOT REPRODUCED" and exits 0.
// If the bug is present, the printed violations name the failing operation
// and the program prints "MC-1: REPRODUCED ... N deviation(s)" and exits
// with the violation count.
//
// Dual-use: as the guest /init (mounts /proc for the O_RDONLY control handle
// and powers the VM off afterwards; detected via getppid() == 0) and as an
// ordinary host binary for the Linux reference run.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE 4096UL

/*
 * Prints one step's outcome and records a Linux-compatibility violation
 * when the signalled expectation does not hold. Returns the violation count.
 */
static int report(const char *step, const char *call, long ret, int err,
                  int expect_ok, int expect_errno)
{
    int bad = 0;
    if (expect_ok && ret < 0)
        bad = 1;
    if (!expect_ok && (ret >= 0 || err != expect_errno))
        bad = 1;
    printf("  %-34s -> ret=%-11ld errno=%-4d (%s)  expected: %s%s\n",
           step, ret, ret < 0 ? err : 0,
           ret < 0 ? strerror(err) : "ok",
           expect_ok ? "success" : "failure",
           expect_ok ? "" : (ret < 0 ? "" : " [VIOLATION]"));
    if (bad)
        printf("  ^^ MC-1 VIOLATION at \"%s\": Linux allows this operation, "
               "Asterinas deviates.\n",
               step);
    return bad;
}

static int case_a(void)
{
    int violations = 0;
    printf("Case A: F_SEAL_WRITE then read-only shared mmap via the O_RDWR "
           "memfd handle (the MC-1 trace)\n");

    /* Counterexample step: create the shared-protocol O_RDWR memfd. */
    int fd = memfd_create("mc1-a", MFD_ALLOW_SEALING);
    printf("  %-34s -> fd=%d\n", "memfd_create(O_RDWR)", fd);
    if (fd < 0) {
        printf("  memfd_create failed: %s (setup error, not a violation)\n",
               strerror(errno));
        return 0;
    }
    ftruncate(fd, 2 * PAGE);

    /* Counterexample step: t1 F_ADD_SEALS(F_SEAL_WRITE) -> OK. */
    long ret = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE);
    violations += report("F_ADD_SEALS(F_SEAL_WRITE)", "fcntl", ret, errno, 1, 0);

    /* Counterexample step: t2 mmap(PROT_READ, MAP_SHARED, rw fd). */
    errno = 0;
    void *addr = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    violations += report("mmap(PROT_READ, MAP_SHARED)", "mmap",
                         (long)addr, errno, 1, 0);
    if (addr != MAP_FAILED) {
        if ((volatile char *)addr)
            ((volatile char *)addr)[0]; /* touch the readable page */
        munmap(addr, PAGE);
    }

    /* Control: an O_RDONLY handle takes the read-only path without the
     * writable-accounting decision; both kernels must admit it. */
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    int ro_fd = open(path, O_RDONLY);
    if (ro_fd >= 0) {
        errno = 0;
        addr = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, ro_fd, 0);
        violations += report("mmap(PROT_READ, O_RDONLY fd) [control]", "mmap",
                             (long)addr, errno, 1, 0);
        if (addr != MAP_FAILED)
            munmap(addr, PAGE);
        close(ro_fd);
    } else {
        printf("  open(/proc/self/fd) failed: %s (skipping control)\n",
               strerror(errno));
    }

    close(fd);
    return violations;
}

static int case_b(void)
{
    int violations = 0;
    printf("Case B: F_SEAL_FUTURE_WRITE, read-only shared mmap, then "
           "F_ADD_SEALS(F_SEAL_WRITE)\n");

    int fd = memfd_create("mc1-b", MFD_ALLOW_SEALING);
    printf("  %-34s -> fd=%d\n", "memfd_create(O_RDWR)", fd);
    if (fd < 0) {
        printf("  memfd_create failed: %s (setup error, not a violation)\n",
               strerror(errno));
        return 0;
    }
    ftruncate(fd, 2 * PAGE);

    long ret = fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE);
    violations += report("F_ADD_SEALS(F_SEAL_FUTURE_WRITE)", "fcntl", ret,
                         errno, 1, 0);

    errno = 0;
    void *addr = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, 0);
    violations += report("mmap(PROT_READ, MAP_SHARED)", "mmap",
                         (long)addr, errno, 1, 0);
    if (addr == MAP_FAILED) {
        close(fd);
        return violations;
    }
    if ((volatile char *)addr)
        ((volatile char *)addr)[0];

    /* check_writable stripped MAY_WRITE, so upgrading to writable must be
     * denied on both kernels. Not a violation; shows the mapping is
     * semantically read-only. */
    errno = 0;
    ret = mprotect(addr, PAGE, PROT_READ | PROT_WRITE);
    report("mprotect(PROT_READ|PROT_WRITE)", "mprotect", ret, errno, 0, EACCES);

    /* Linux: no writable mapping exists, so WRITE sealing succeeds.
     * Asterinas bug: the read-only mapping holds a writable count, so
     * WritableMappingStatus::deny returns EBUSY. */
    errno = 0;
    ret = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE);
    violations += report("F_ADD_SEALS(F_SEAL_WRITE)", "fcntl", ret, errno, 1, 0);

    long seals = fcntl(fd, F_GET_SEALS);
    printf("  %-34s -> seals=0x%lx\n", "F_GET_SEALS", seals);

    /* After unmapping the read-only mapping, the false owner is gone and
     * WRITE sealing must succeed on both kernels. */
    errno = 0;
    ret = munmap(addr, PAGE);
    report("munmap", "munmap", ret, errno, 1, 0);

    errno = 0;
    ret = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE);
    violations += report("F_ADD_SEALS(F_SEAL_WRITE) retry", "fcntl", ret,
                         errno, 1, 0);
    if (ret == 0 &&
        (fcntl(fd, F_GET_SEALS) & F_SEAL_WRITE) != F_SEAL_WRITE)
        violations++;

    close(fd);
    return violations;
}

int main(void)
{
    /* Guest init support: mount /proc for the /proc/self/fd control handle.
     * On the host this either succeeds or fails harmlessly (already mounted).*/
    mkdir("/proc", 0755);
    if (mount("proc", "/proc", "proc", 0, NULL) && errno != EBUSY)
        printf("note: mount /proc failed (%s); the O_RDONLY control needs it\n",
               strerror(errno));

    printf("MC-1 reproduction: post-seal read-only mappings retain writable "
           "accounting\n");
#ifdef ASTERINAS_GUEST
    printf("target: Asterinas kernel\n");
#else
    printf("target: reference kernel (expect zero deviations)\n");
#endif

    int v = case_a() + case_b();

    if (v == 0) {
        printf("MC-1: NOT REPRODUCED (all operations Linux-compatible)\n");
    } else {
        printf("MC-1: REPRODUCED (%d Linux-compat deviation(s) observed)\n", v);
    }

    /* Allow the serial console to drain before any power-off. */
    fflush(stdout);
    sync();

    if (getppid() == 0) {
        /* Running as init inside the Asterinas guest. */
        reboot(RB_POWER_OFF);
    }
    return v;
}
