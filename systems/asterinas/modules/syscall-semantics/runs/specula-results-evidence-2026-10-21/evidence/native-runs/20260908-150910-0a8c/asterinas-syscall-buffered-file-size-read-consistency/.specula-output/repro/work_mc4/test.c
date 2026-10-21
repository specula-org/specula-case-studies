#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

static int bugs;

/* Returns file size after ftruncate(len) on a file of size before. */
static long do_case(const char *path, long before, long len, long *read_n)
{
    char buf[8192];
    memset(buf, 0xAA, sizeof(buf));
    prctl(0x53504543, 0UL, 2048UL, 16384UL, 0UL); /* (re)arm kernel trace recorder */
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) { perror("open"); write(1, "MC4CASE openfail\n", 18); return -2; }
    if (before > 0) {
        if (write(fd, buf, before) != before) { perror("write"); return -2; }
        fsync(fd);
    }
    int r = ftruncate(fd, len);
    int e = errno;
    struct stat st;
    fstat(fd, &st);
    memset(buf, 0x55, sizeof(buf));
    ssize_t n = pread(fd, buf, sizeof(buf), 0);
    prctl(0x53504544, 0UL, 0UL, 0UL, 0UL); /* drain kernel trace receipts */
    printf("MC4CASE %s before=%ld ftruncate(%ld)=%d errno=%d st_size=%ld pread=%zd\n",
           path, before, len, r, r ? e : 0, (long)st.st_size, n);
    if (r == 0 && (long)st.st_size != len) {
        printf("MC4BUG  %s: ftruncate(%ld) succeeded but st_size=%ld\n",
               path, len, (long)st.st_size);
        bugs++;
    }
    if (r == 0 && (long)n != len) {
        printf("MC4BUG  %s: after successful ftruncate(%ld), pread at 0 returned %zd bytes\n",
               path, len, n);
        bugs++;
    }
    *read_n = n;
    close(fd);
    return st.st_size;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    write(1, "MC4INIT start\n", 15);
    mkdir("/dev", 0755); mkdir("/proc", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("proc", "/proc", "proc", 0, NULL);
    mkdir("/ext2", 0777); mkdir("/exfat", 0777);
    if (mount("/dev/vda", "/ext2", "ext2", 0, NULL)) perror("mount ext2");
    write(1, "MC4INIT ext2 mounted\n", 21);
    if (mount("/dev/vdb", "/exfat", "exfat", 0, NULL)) perror("mount exfat");
    write(1, "MC4INIT exfat mounted\n", 22);

    long rn;
    /* A: empty exFAT file extended by ftruncate (the MC counterexample step) */
    do_case("/exfat/mc4a", 0, 1, &rn);
    do_case("/exfat/mc4a2", 0, 8192, &rn);
    /* B: cross-cluster grow */
    do_case("/exfat/mc4b", 4096, 8192, &rn);
    /* C: same-cluster shrink */
    do_case("/exfat/mc4c", 4096, 2048, &rn);
    /* ext2 control */
    do_case("/ext2/mc4a", 0, 8192, &rn);
    do_case("/ext2/mc4c", 4096, 2048, &rn);

    printf("MC4VERDICT %s bugs=%d\n", bugs ? "BUG" : "CLEAN", bugs);
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
