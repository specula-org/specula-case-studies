// Prints the guest CPU count for the initramfs init script. The pinned image has no
// static BusyBox with an nproc applet, so this probe replaces `busybox nproc`. It reports
// both the online count and the scheduler affinity count, and init prints the former.
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    cpu_set_t set;
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    int affinity = sched_getaffinity(0, sizeof(set), &set) == 0 ? CPU_COUNT(&set) : -1;
    printf("%ld %d\n", online, affinity);
    return online > 0 ? 0 : 1;
}
