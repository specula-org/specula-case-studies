/* MC-6 reproduction: zero-count positional write (pwrite64 beyond EOF) must have
 * no effect on a regular file's size.
 *
 * Level 0, pure black-box, single-threaded, public syscalls only.
 * Steps mirror the MC counterexample (MC_hunt_s4_empty_ramfs_bfs1.out):
 *   initial file size 2 (L=2), then pwrite64(fd, buf, 0, 4).
 *
 * Expected (Linux / POSIX: write(2) with nbyte==0 shall "return zero and have
 * no other results" for regular files): pwrite64 returns 0, size stays 2, a
 * read at offset 2 hits EOF (returns 0).
 * Buggy (ramfs per the MC trace): pwrite64 returns 0 but size becomes 4 and
 * the hole [2,4) becomes readable zeros.
 *
 * Usage: test_bugMC-6_ramfs_empty_pwrite <dir>   (file is created as <dir>/mc6subject)
 * Prints MC6_REPRO lines and a final verdict:
 *   MC6_RESULT BUG_TRIGGERED  — size changed by an empty pwrite
 *   MC6_RESULT OK             — size unchanged (contract honored)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SEED_LEN 2          /* initial file size ("hi"), mirrors CE L=2 */
#define EMPTY_OFF 4         /* zero-count pwrite offset (beyond EOF), mirrors CE O=4 */

static long fsize(int fd)
{
    struct stat st;
    if (fstat(fd, &st)) { perror("fstat"); return -1; }
    return (long)st.st_size;
}

int main(int argc, char **argv)
{
    char path[512];
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    snprintf(path, sizeof(path), "%s/mc6subject", dir);

    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 111; }

    /* Seed: 2 bytes so that offset 4 is beyond EOF. */
    ssize_t w = pwrite(fd, "hi", SEED_LEN, 0);
    if (w != SEED_LEN) { perror("seed pwrite"); return 112; }
    long size0 = fsize(fd);
    printf("MC6_REPRO seed_size=%ld (expect %d)\n", size0, SEED_LEN);

    /* Control 1: empty pwrite INSIDE the file (offset 1 < EOF) must be a no-op
     * on every implementation. */
    static char buf[16];
    errno = 0;
    ssize_t r_in = pwrite(fd, buf, 0, 1);
    long size_in = fsize(fd);
    printf("MC6_REPRO empty_pwrite_infile ret=%zd errno=%d size=%ld (expect ret=0 size=%d)\n",
           r_in, errno, size_in, SEED_LEN);

    /* The counterexample step: empty pwrite beyond EOF. */
    errno = 0;
    ssize_t r = pwrite64(fd, buf, 0, EMPTY_OFF);
    int saved_errno = errno;
    long size1 = fsize(fd);
    printf("MC6_REPRO empty_pwrite_beyond_eof ret=%zd errno=%d size_after=%ld (expect ret=0 size=%d)\n",
           r, saved_errno, size1, SEED_LEN);

    /* Consequence: the hole [2,4) is now readable zeros instead of EOF. */
    unsigned char hole[8];
    memset(hole, 0xA5, sizeof(hole));
    ssize_t rd = pread(fd, hole, 2, SEED_LEN);
    printf("MC6_REPRO hole_read_at_eof ret=%zd bytes=%02x%02x (expect ret=0 at EOF)\n",
           rd, hole[0], hole[1]);

    /* Control 2: shared-offset write(2) with count 0 — offset must be preserved
     * and (POSIX) size must not change either. */
    off_t pos = lseek(fd, EMPTY_OFF, SEEK_SET);
    errno = 0;
    ssize_t w0 = write(fd, buf, 0);
    off_t pos_after = lseek(fd, 0, SEEK_CUR);
    long size2 = fsize(fd);
    printf("MC6_REPRO empty_shared_write ret=%zd errno=%d pos=%ld->%ld size=%ld\n",
           w0, errno, (long)pos, (long)pos_after, size2);

    int bug = (r == 0 && size1 == EMPTY_OFF && rd == 2);
    printf("MC6_RESULT %s\n", bug ? "BUG_TRIGGERED" : "OK");
    if (bug) {
        printf("MC6_SUMMARY empty pwrite64(off=%d,len=0) on a %d-byte file returned 0 but"
               " enlarged size to %ld and made the hole readable\n",
               EMPTY_OFF, SEED_LEN, size1);
    }
    close(fd);
    unlink(path);
    return 0;
}
