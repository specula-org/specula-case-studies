// SPDX-License-Identifier: MPL-2.0
// Reproduction for finding MC-5: "ExFAT regrown holes can read the subject's
// old backing bytes".
//
// Sequence (mirrors the MC counterexample MC_hunt_s3_holes_exfat_bfs1.out):
//   1. create + seed a 3-page file with identifiable per-page patterns
//   2. fsync (seed bytes must be durable on disk)
//   3. ftruncate(fd, 0)   -> decommits cache pages, frees clusters, disk bytes stay
//   4. pwrite 1 page at offset 2*4096 -> extends to 12288, reclaims clusters,
//      publishes EOF across the untouched hole [0, 8192)
//   5. pread the hole -> POSIX/Linux contract: zeros. Bug: stale seed bytes.
//
// Runs the same sequence on exfat (subject), ext2 and ramfs/tmpfs (controls).
// Pure black-box syscalls (escalation Level 0): no races, no failpoints,
// sequential single thread.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE 4096
#define SEED_PAGES 3
#define FILE_SIZE (SEED_PAGES * PAGE) /* 12288 */
#define HOLE_BYTES (2 * PAGE)         /* [0, 8192) */

static const char seed_pat[SEED_PAGES] = { 'A', 'B', 'C' };

static void fill(unsigned char *buf, unsigned char v) { memset(buf, v, PAGE); }

/* Returns 0 if hole reads as zeros (correct), 1 if stale bytes (bug),
 * -1 on test-harness error. */
static int run_one(const char *fstag, const char *path)
{
    unsigned char seed[PAGE], zbuf[PAGE], rbuf[PAGE];
    int fd = -1, rc = -1;

    fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return -1; }

    /* 1-2. Seed 3 pages and make them durable. */
    for (int i = 0; i < SEED_PAGES; i++) {
        fill(seed, (unsigned char)seed_pat[i]);
        ssize_t w = pwrite(fd, seed, PAGE, (off_t)i * PAGE);
        if (w != PAGE) { perror("seed pwrite"); goto out; }
    }
    if (fsync(fd) != 0) { perror("fsync"); goto out; }

    /* 3. Truncate to zero. */
    if (ftruncate(fd, 0) != 0) { perror("ftruncate"); goto out; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size != 0) { perror("fstat after truncate"); goto out; }

    /* 4. Extending write: one full page at offset 8192, hole = [0, 8192). */
    fill(zbuf, 'Z');
    ssize_t w = pwrite(fd, zbuf, PAGE, 2 * (off_t)PAGE);
    if (w != PAGE) { perror("extending pwrite"); goto out; }
    if (fstat(fd, &st) != 0 || st.st_size != FILE_SIZE) {
        fprintf(stderr, "[%s] size after extension: got %lld want %d\n",
                fstag, (long long)st.st_size, FILE_SIZE);
        goto out;
    }

    /* 5a. Sanity: the written page must read back as 'Z'. */
    memset(rbuf, 0x5C, PAGE);
    ssize_t r = pread(fd, rbuf, PAGE, 2 * (off_t)PAGE);
    if (r != PAGE) { perror("pread tail"); goto out; }
    int tail_ok = 1;
    for (int i = 0; i < PAGE; i++) if (rbuf[i] != 'Z') { tail_ok = 0; break; }
    printf("[%s] tail page (written at 8192): %s\n", fstag,
           tail_ok ? "all 'Z' (write landed)" : "CORRUPT");

    /* 5b. The hole. CE-exact small read first, then full pages. */
    memset(rbuf, 0x5C, PAGE);
    r = pread(fd, rbuf, 2, 0); /* the counterexample's pread64(fd, 0, 2) */
    if (r != 2) { fprintf(stderr, "[%s] short pread ret %zd\n", fstag, r); goto out; }
    printf("[%s] pread(off=0,len=2) returned bytes: %02x %02x ('%c%c')\n",
           fstag, rbuf[0], rbuf[1],
           (rbuf[0] >= 32 && rbuf[0] < 127) ? rbuf[0] : '.',
           (rbuf[1] >= 32 && rbuf[1] < 127) ? rbuf[1] : '.');

    int hole_nonzero = 0, hole_seedmatch = 0;
    for (int pg = 0; pg < 2; pg++) {
        memset(rbuf, 0x5C, PAGE);
        r = pread(fd, rbuf, PAGE, (off_t)pg * PAGE);
        if (r != PAGE) { fprintf(stderr, "[%s] hole pread pg%d ret %zd\n", fstag, pg, r); goto out; }
        int nz = 0, sm = 0;
        for (int i = 0; i < PAGE; i++) {
            if (rbuf[i] != 0) nz++;
            if (rbuf[i] == (unsigned char)seed_pat[pg]) sm++;
        }
        hole_nonzero += nz;
        if (sm == PAGE) hole_seedmatch++;
        printf("[%s] hole page %d: %d/%d non-zero bytes, seed-'%c' match: %s; first16:",
               fstag, pg, nz, PAGE, seed_pat[pg], sm == PAGE ? "FULL" : "no");
        for (int i = 0; i < 16; i++) printf(" %02x", rbuf[i]);
        printf("\n");
    }

    if (hole_nonzero == 0) {
        printf("[%s] MC5_RESULT CLEAN hole reads as zeros (correct)\n", fstag);
        rc = 0;
    } else {
        printf("[%s] MC5_RESULT BUG hole returned %d non-zero bytes"
               " (full seed-pattern pages: %d/2)\n",
               fstag, hole_nonzero, hole_seedmatch);
        rc = 1;
    }
out:
    close(fd);
    unlink(path);
    return rc;
}

int main(void)
{
    int worst = 0;

    printf("MC-5 repro: ftruncate(0) -> extending pwrite -> pread hole\n");
    fflush(stdout);

    int rc_ext2  = run_one("ext2",  "/ext2/mc5_subject.bin");
    int rc_ramfs = run_one("ramfs", "/ramfs/mc5_subject.bin");
    int rc_exfat = run_one("exfat", "/exfat/mc5_subject.bin");

    printf("MC5_SUMMARY ext2=%d ramfs=%d exfat=%d (1=stale bytes observed, 0=zeros, -1=error)\n",
           rc_ext2, rc_ramfs, rc_exfat);
    if (rc_exfat == 1 && rc_ext2 == 0 && rc_ramfs == 0)
        printf("MC5_VERDICT REPRODUCED exFAT hole reads stale backing bytes; controls clean\n");
    else if (rc_exfat == 0)
        printf("MC5_VERDICT NOT_REPRODUCED exFAT hole reads as zeros\n");
    else
        printf("MC5_VERDICT INCONCLUSIVE ext2=%d ramfs=%d exfat=%d\n",
               rc_ext2, rc_ramfs, rc_exfat);
    fflush(stdout);

    if (rc_ext2 < 0 || rc_ramfs < 0 || rc_exfat < 0) worst = 2;
    else if (rc_exfat == 1) worst = 1; /* bug observed: nonzero exit marker */
    return worst;
}
