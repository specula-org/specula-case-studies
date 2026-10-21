/* Minimal init for the MC-1 repro guest: set up mounts, drop privileges, run test. */
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void) {
    mkdir("/dev", 0755); mkdir("/proc", 0755); mkdir("/tmp", 0777);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("proc", "/proc", "proc", 0, NULL);
    mkdir("/ramfs", 0777);
    chown("/ramfs", 1000, 1000);
    chmod("/ramfs", 0777);
    pid_t child = fork();
    if (child == 0) {
        if (setgid(1000) || setuid(1000)) _exit(120);
        execl("/test_mc1", "/test_mc1", NULL);
        perror("exec");
        _exit(121);
    }
    int status = 0;
    waitpid(child, &status, 0);
    printf("MC1_EXIT %d\n", status);
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
