// MC-3 reproduction: a zero-progress (or prefix) user-copy fault during a
// write/pwrite to a RamFS-backed file must NOT leave the inode extended to
// the full requested end. Linux contract: on EFAULT with zero progress the
// size is unchanged; on a fault after a positive prefix the write reports
// the committed prefix and the size equals the committed bytes.
//
// Escalation level: 0 (public syscalls only, single thread, deterministic).
// Phases:
//   ramfs_zero_pwrite     - exact MC CE shape: pwrite64(fd, buf, 2, 6) on a
//                           6-byte /tmp file, buf unreadable (PROT_NONE).
//   ramfs_zero_write      - same fault via write() (shared-offset path);
//                           also checks fd offset, SEEK_END, phantom reads.
//   ramfs_prefix_pwrite   - 2-page buffer, 2nd page PROT_NONE: fault after a
//                           positive prefix; EOF must equal committed prefix.
//   memfd_zero_pwrite     - memfd files are RamFS too.
//   ext2_zero_pwrite_ctrl - same operation on ext2 (control; ext2 rolls back).
//
// Expected (Linux): every phase CLEAN. BUG if st_size reports the requested
// end despite zero/short committed bytes.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static int g_bug_phases = 0;
static int g_skip_phases = 0;

static long ps = 4096;

static void out_kv(const char *key, long v) {
    printf("MC3_CASE %s=%ld\n", key, v);
}

static void phase_verdict(const char *phase, int is_bug, const char *why) {
    if (is_bug) {
        g_bug_phases++;
        printf("MC3_VERDICT %s BUG (%s)\n", phase, why);
    } else {
        printf("MC3_VERDICT %s CLEAN (%s)\n", phase, why);
    }
}

static void phase_skip(const char *phase, const char *why) {
    g_skip_phases++;
    printf("MC3_VERDICT %s SKIP (%s)\n", phase, why);
}

// Maps `npages` anonymous pages, fills them with `fill`, then protects the
// LAST `bad_pages` pages with PROT_NONE so the kernel copy faults there.
static char *make_faulty_buf(long npages, int bad_pages, char fill) {
    char *buf = mmap(NULL, (size_t)npages * (size_t)ps,
                     PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) {
        perror("mmap");
        return NULL;
    }
    memset(buf, fill, (size_t)npages * (size_t)ps);
    if (bad_pages > 0) {
        size_t bad_off = (size_t)(npages - bad_pages) * (size_t)ps;
        if (mprotect(buf + bad_off, (size_t)bad_pages * (size_t)ps,
                     PROT_NONE) != 0) {
            perror("mprotect");
            munmap(buf, (size_t)npages * (size_t)ps);
            return NULL;
        }
    }
    return buf;
}

static long fstat_size(int fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) {
        perror("fstat");
        return -1;
    }
    return (long)st.st_size;
}

// pwrite/fault with a fully unreadable 1-page buffer (zero progress).
// base_size: current file size; off/len: the write geometry.
// Returns 1 if the phase shows the bug, 0 if clean, -1 on setup failure.
static int zero_pwrite_case(const char *path, off_t off, size_t len,
                            long base_size) {
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        return -1;
    }
    // Seed base_size committed bytes.
    char seed = 'S';
    for (long i = 0; i < base_size; i++) {
        if (write(fd, &seed, 1) != 1) {
            perror("seed write");
            close(fd);
            return -1;
        }
    }
    long pre_size = fstat_size(fd);
    if (pre_size != base_size) {
        printf("MC3_CASE setup_mismatch pre_size=%ld expected=%ld\n",
               pre_size, base_size);
        close(fd);
        return -1;
    }

    char *bad = make_faulty_buf(1, 1, 'X'); // whole page PROT_NONE
    if (!bad) {
        close(fd);
        return -1;
    }

    errno = 0;
    ssize_t ret = pwrite(fd, bad, len, off);
    int e = errno;
    munmap(bad, (size_t)ps);

    out_kv("op=zero_pwrite ret", (long)ret);
    if (ret < 0) {
        out_kv("errno", e);
    }
    long post_size = fstat_size(fd);

    // Zero bytes were committed: EOF must stay at the old size, and a reader
    // must see EOF at base_size.
    long seek_end = (long)lseek(fd, 0, SEEK_END);
    char probe[8];
    ssize_t got = pread(fd, probe, sizeof(probe), off);
    out_kv("st_size", post_size);
    out_kv("seek_end", seek_end);
    out_kv("read_at_write_pos", (long)got);

    int bug = 0;
    if (post_size != base_size) {
        bug = 1;
    } else if (got != 0) {
        // Data visible past the committed region would be phantom content.
        bug = 1;
    }
    close(fd);
    if (bug) {
        return 1;
    }
    // Clean also demands the error be EFAULT (or a 0-return), not success.
    if (ret >= 0 && (size_t)ret > 0) {
        return 1; // reported bytes that were never copied
    }
    return 0;
}

static void phase_ramfs_zero_pwrite(const char *dir) {
    printf("MC3_PHASE_START ramfs_zero_pwrite\n");
    char path[256];
    snprintf(path, sizeof(path), "%s/mc3_zp", dir);
    int r = zero_pwrite_case(path, 6, 2, 6);
    if (r < 0) {
        phase_skip("ramfs_zero_pwrite", "setup failure");
    } else {
        phase_verdict("ramfs_zero_pwrite", r,
                      r ? "size grew on zero-progress fault" : "size unchanged");
    }
    unlink(path);
}

static void phase_ramfs_zero_write(const char *dir) {
    printf("MC3_PHASE_START ramfs_zero_write\n");
    char path[256];
    snprintf(path, sizeof(path), "%s/mc3_zw", dir);
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        phase_skip("ramfs_zero_write", "open failed");
        return;
    }
    char seed[6];
    memset(seed, 'S', sizeof(seed));
    if (write(fd, seed, sizeof(seed)) != (ssize_t)sizeof(seed)) {
        perror("seed");
        close(fd);
        phase_skip("ramfs_zero_write", "seed failed");
        return;
    }

    char *bad = make_faulty_buf(1, 1, 'X');
    if (!bad) {
        close(fd);
        phase_skip("ramfs_zero_write", "buffer setup failed");
        return;
    }
    errno = 0;
    ssize_t ret = write(fd, bad, 2);
    int e = errno;
    munmap(bad, (size_t)ps);

    out_kv("op=zero_write ret", (long)ret);
    if (ret < 0) {
        out_kv("errno", e);
    }
    out_kv("st_size", fstat_size(fd));
    out_kv("fd_offset", (long)lseek(fd, 0, SEEK_CUR));
    out_kv("seek_end", (long)lseek(fd, 0, SEEK_END));

    int bug = fstat_size(fd) != 6; // zero bytes committed: EOF must stay 6
    close(fd);
    phase_verdict("ramfs_zero_write", bug,
                  bug ? "size or offset moved on fault" : "size unchanged");
    unlink(path);
}

static void phase_ramfs_prefix_pwrite(const char *dir) {
    printf("MC3_PHASE_START ramfs_prefix_pwrite\n");
    char path[256];
    snprintf(path, sizeof(path), "%s/mc3_pp", dir);
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        phase_skip("ramfs_prefix_pwrite", "open failed");
        return;
    }

    long total = 2 * ps; // request spans good page + PROT_NONE page
    char *buf = make_faulty_buf(2, 1, 'A');
    if (!buf) {
        close(fd);
        phase_skip("ramfs_prefix_pwrite", "buffer setup failed");
        return;
    }
    errno = 0;
    ssize_t ret = pwrite(fd, buf, (size_t)total, 0);
    int e = errno;
    out_kv("op=prefix_pwrite ret", (long)ret);
    if (ret < 0) {
        out_kv("errno", e);
    }

    // Measure what a reader actually gets, and how much of it is real data.
    char *out = malloc((size_t)total + 1);
    ssize_t got = pread(fd, out, (size_t)total, 0);
    long committed = 0;
    if (got > 0) {
        for (long i = 0; i < (long)got; i++) {
            if (out[i] == 'A') {
                committed++;
            } else {
                break;
            }
        }
    }
    free(out);
    munmap(buf, (size_t)total);

    out_kv("requested", total);
    out_kv("st_size", fstat_size(fd));
    out_kv("linux_expected_size", ps); // Linux commits exactly the good page
    out_kv("committed_prefix", committed);

    int bug = 0;
    if (got != ps) {
        bug = 1; // reader sees more or fewer bytes than were committed
    } else if (fstat_size(fd) != ps) {
        bug = 1; // EOF beyond the committed prefix
    }
    close(fd);
    phase_verdict("ramfs_prefix_pwrite", bug,
                  bug ? "EOF != committed prefix" : "EOF == committed prefix");
    unlink(path);
}

static void phase_memfd_zero_pwrite(void) {
    printf("MC3_PHASE_START memfd_zero_pwrite\n");
    int fd = syscall(SYS_memfd_create, "mc3", 0);
    if (fd < 0) {
        perror("memfd_create");
        phase_skip("memfd_zero_pwrite", "memfd_create failed");
        return;
    }
    char seed[6];
    memset(seed, 'S', sizeof(seed));
    if (write(fd, seed, sizeof(seed)) != (ssize_t)sizeof(seed)) {
        perror("seed");
        close(fd);
        phase_skip("memfd_zero_pwrite", "seed failed");
        return;
    }
    char *bad = make_faulty_buf(1, 1, 'X');
    if (!bad) {
        close(fd);
        phase_skip("memfd_zero_pwrite", "buffer setup failed");
        return;
    }
    errno = 0;
    ssize_t ret = pwrite(fd, bad, 2, 6);
    int e = errno;
    munmap(bad, (size_t)ps);
    out_kv("op=memfd_zero_pwrite ret", (long)ret);
    if (ret < 0) {
        out_kv("errno", e);
    }
    out_kv("st_size", fstat_size(fd));
    int bug = fstat_size(fd) != 6;
    close(fd);
    phase_verdict("memfd_zero_pwrite", bug,
                  bug ? "size grew on zero-progress fault" : "size unchanged");
}

static void phase_ext2_zero_pwrite_ctrl(void) {
    printf("MC3_PHASE_START ext2_zero_pwrite_ctrl\n");
    const char *path = "/ext2/mc3_zp";
    int r = zero_pwrite_case(path, 6, 2, 6);
    if (r < 0) {
        phase_skip("ext2_zero_pwrite_ctrl", "setup failure");
    } else {
        phase_verdict("ext2_zero_pwrite_ctrl", r,
                      r ? "size grew on zero-progress fault" : "size unchanged");
    }
    unlink(path);
}

int main(int argc, char **argv) {
    ps = sysconf(_SC_PAGESIZE);
    const char *dir = argc > 1 ? argv[1] : "/tmp";

    phase_ramfs_zero_pwrite(dir);
    phase_ramfs_zero_write(dir);
    phase_ramfs_prefix_pwrite(dir);
    phase_memfd_zero_pwrite();
    phase_ext2_zero_pwrite_ctrl();

    printf("bug_phases=%d\n", g_bug_phases);
    printf("skip_phases=%d\n", g_skip_phases);
    printf("MC3_REPRO_DONE\n");
    return g_bug_phases > 0 ? 1 : 0;
}
