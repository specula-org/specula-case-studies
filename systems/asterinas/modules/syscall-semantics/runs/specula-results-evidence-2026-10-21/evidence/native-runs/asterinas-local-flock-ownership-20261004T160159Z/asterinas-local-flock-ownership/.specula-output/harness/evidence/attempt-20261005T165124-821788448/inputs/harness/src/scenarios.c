/* SPDX-License-Identifier: MPL-2.0 */
#define _GNU_SOURCE
#define main regression_framework_main
#include "test.h"
#undef main
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <cpuid.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static const char *fixture = "/tmp/specula-flock";
static char scenario[32] = "C01";
static int instrumented, prefix;
static _Thread_local int acting_tid = 1;
static atomic_int capture_returns;
struct observed_return { const char *operation; int fd, argument, result, error; };
static struct observed_return outcomes[3][128];
static atomic_int outcome_count[3];
static int record_return(const char *operation, int fd, int argument, int result)
{
    int saved_errno=errno;
    if (atomic_load_explicit(&capture_returns,memory_order_acquire)) {
        int slot=acting_tid-1;
        int n=atomic_load_explicit(&outcome_count[slot],memory_order_relaxed);
        if (n>=128) abort();
        outcomes[slot][n]=(struct observed_return){operation,fd,argument,result,result<0?saved_errno:0};
        atomic_store_explicit(&outcome_count[slot],n+1,memory_order_release);
    }
    errno=saved_errno;
    return result;
}
static int observed_flock(int fd,int op) { int r=flock(fd,op); return record_return("flock",fd,op,r); }
static int observed_close(int fd) { int r=close(fd); return record_return("close",fd,0,r); }
static int observed_dup(int fd) { int r=dup(fd); return record_return("dup",fd,0,r); }
#define flock observed_flock
#define close observed_close
#define dup observed_dup

struct worker { pthread_t thread; atomic_int ready, command, done; int tid, cpu, fd, op, unlock, result, error; };
static struct worker workers[2];
static struct worker *roles[2];
static int controller_cpu;
static int current_cpu(void) { unsigned cpu; CHECK(syscall(SYS_getcpu,&cpu,NULL,NULL)); return cpu; }
static long control(long op, long a, long b, long c)
{
    return syscall(SYS_prctl, 0x53504543, op, a, b, c);
}
static uint64_t now(void)
{
    struct timespec t;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &t));
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void wait_atomic(atomic_int *value, int wanted)
{
    uint64_t deadline = now() + 10000000000ULL;
    while (atomic_load_explicit(value, memory_order_acquire) != wanted) {
        if (now() >= deadline) { fprintf(stderr, "fixture synchronization deadline\n"); exit(2); }
        sched_yield();
    }
}
static void wait_boundary_after(int tid, int boundary, long after)
{
    uint64_t deadline = now() + 10000000000ULL;
    for (;;) {
        long observation = control(2, tid, 2, 0);
        if ((observation & 255) == boundary && (observation >> 8) > after) break;
        if (now() >= deadline) { fprintf(stderr, "missing observed kernel boundary tid=%d boundary=%d\n", tid, boundary); exit(2); }
        sched_yield();
    }
}
static void wait_boundary(int tid, int boundary) { wait_boundary_after(tid,boundary,0); }
static int open_fixture(void);
static void *worker_main(void *argument)
{
    struct worker *w = argument;
    w->cpu = current_cpu();
    atomic_store_explicit(&w->ready, 1, memory_order_release);
    wait_atomic(&w->ready,2);
    acting_tid = w->tid;
    if (instrumented) CHECK(control(1, w->tid, 0, 0));
    atomic_store_explicit(&w->ready, 3, memory_order_release);
    for (;;) {
        wait_atomic(&w->command, 1);
        atomic_store(&w->command, 0);
        errno = 0;
        w->result = w->op == 0 ? open_fixture() : flock(w->fd, w->op);
        w->error = errno;
        if (w->unlock && w->result == 0) CHECK(flock(w->fd, LOCK_UN));
        atomic_store_explicit(&w->done, 1, memory_order_release);
    }
    return NULL;
}
static void start_worker(int index, int fd, int op, int unlock)
{
    struct worker *w = roles[index];
    w->fd = fd; w->op = op; w->unlock = unlock;
    atomic_store(&w->done, 0);
    atomic_store_explicit(&w->command, 1, memory_order_release);
}
static void finish_worker(int index)
{
    struct worker *w = roles[index];
    wait_atomic(&w->done, 1);
    printf("SPECULA_RETURN {\"tid\":%d,\"result\":%d,\"errno\":%d}\n",w->tid,w->result,w->error);
    CHECK_WITH(w->result, (w->op == 0 ? _ret >= 3 : _ret == 0) && w->error == 0);
}
static int open_fixture(void) { int fd=CHECK(open(fixture,O_RDWR)); return record_return("open",fd,O_RDWR,fd); }
static void dump(void)
{
    for (int tid=1; tid<=3; ++tid) {
        int count=atomic_load_explicit(&outcome_count[tid-1],memory_order_acquire);
        for (int i=0;i<count;++i) {
            struct observed_return r=outcomes[tid-1][i];
            printf("SPECULA_RETURN {\"tid\":%d,\"operation\":\"%s\",\"fd_raw\":%d,\"argument\":%d,\"result\":%d,\"errno\":%d}\n",tid,r.operation,r.fd,r.argument,r.result,r.error);
        }
    }
    if (!instrumented) { printf("SPECULA_CONTROL_END {\"case\":\"%s\",\"failures\":%d}\n",scenario,__total_failures); return; }
    static char line[16384];
    for (int tid = 1; tid <= 3; ++tid) {
        long count = CHECK(control(2, tid, 0, 0));
        long dropped = CHECK(control(2, tid, 1, 0));
        printf("SPECULA_BUFFER {\"tid\":%d,\"events\":%ld,\"dropped\":%ld}\n", tid, count, dropped);
        for (long i = 0; i < count; ++i) {
            long length = CHECK(control(3, tid, i, (long)line));
            CHECK_WITH(length, _ret > 0 && _ret < sizeof(line));
            line[length] = 0;
            printf("SPECULA_EVENT %s\n", line);
        }
    }
    long mapping_length = CHECK(control(7, 0, 0, (long)line));
    line[mapping_length] = 0;
    printf("SPECULA_IDENTITIES %s\n",line);
    printf("SPECULA_END {\"case\":\"%s\",\"complete\":%s,\"prefix\":%s,\"failures\":%d}\n", scenario, prefix ? "false" : "true", prefix ? "true" : "false", __total_failures);
    fflush(stdout);
}

FN_SETUP(fixture)
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *requested = getenv("SPECULA_CASE");
    if (requested) snprintf(scenario, sizeof(scenario), "%s", requested);
    else {
        int f = open("/case", O_RDONLY);
        if (f >= 0) { int n = read(f, scenario, sizeof(scenario)-1); if (n > 0) scenario[strcspn(scenario,"\r\n")] = 0; close(f); }
    }
    mkdir("/tmp", 0777);
    int setup = CHECK(open(fixture, O_CREAT | O_TRUNC | O_RDWR, 0600));
    struct stat st; struct statfs fs; struct utsname uts;
    CHECK(fstat(setup, &st)); CHECK(fstatfs(setup, &fs)); CHECK(uname(&uts)); CHECK(close(setup));
    long cpus = control(4, 0, 0, 0);
    instrumented = cpus >= 0;
    if (!instrumented) cpus = sysconf(_SC_NPROCESSORS_ONLN);
    printf("SPECULA_CONFIG {\"case\":\"%s\",\"instrumented\":%s,\"smp\":%ld,\"kernel\":\"%s %s\",\"fs_type\":%lu,\"inode_raw\":%lu,\"device_raw\":%lu}\n",scenario,instrumented?"true":"false",cpus,uts.sysname,uts.release,(unsigned long)fs.f_type,(unsigned long)st.st_ino,(unsigned long)st.st_dev);
    if (instrumented) CHECK(mount("proc", "/proc", "proc", 0, NULL));
    char command_line[4096];
    int command_fd=CHECK(open("/proc/cmdline",O_RDONLY));
    int command_len=CHECK(read(command_fd,command_line,sizeof(command_line)-1));
    CHECK(close(command_fd)); command_line[command_len]=0;
    command_line[strcspn(command_line,"\r\n")]=0;
    printf("SPECULA_CMDLINE %s\n",command_line);
    unsigned eax,ebx,ecx,edx;
    int invariant_tsc=__get_cpuid(0x80000007,&eax,&ebx,&ecx,&edx) && (edx & (1U<<8));
    printf("SPECULA_CLOCK {\"source\":\"LFENCE RDTSC LFENCE\",\"invariant_tsc\":%s}\n",invariant_tsc?"true":"false");
    controller_cpu=current_cpu();
    for (int i = 0; i < 2; ++i) {
        workers[i].tid = i + 2;
        CHECK(pthread_create(&workers[i].thread, NULL, worker_main, &workers[i]));
        wait_atomic(&workers[i].ready, 1);
    }
    roles[0]=&workers[0]; roles[1]=&workers[1];
    if (!strcmp(scenario,"C00-open-overlap") || !strcmp(scenario,"C13-open-close")) {
        CHECK_WITH(current_cpu(),_ret==controller_cpu);
        if (workers[0].cpu==controller_cpu) { roles[0]=&workers[1]; roles[1]=&workers[0]; }
        CHECK_WITH(roles[0]->cpu,_ret!=controller_cpu);
        CHECK_WITH(roles[1]->cpu,_ret==controller_cpu);
        roles[0]->tid=2; roles[1]->tid=3;
    }
    printf("SPECULA_PLACEMENT {\"controller\":%d,\"tid2\":%d,\"tid3\":%d}\n",controller_cpu,roles[0]->cpu,roles[1]->cpu);
    for (int i=0;i<2;++i) { atomic_store_explicit(&workers[i].ready,2,memory_order_release); wait_atomic(&workers[i].ready,3); }
    if (instrumented) CHECK(control(1, 1, 0, 0));
    atomic_store_explicit(&capture_returns,1,memory_order_release);
END_SETUP()

static void wait_open_stage(int stage)
{
    uint64_t deadline=now()+10000000000ULL;
    while (control(10,0,0,0) != stage) {
        if (now()>=deadline) { fprintf(stderr,"missing open-table boundary\n"); exit(2); }
        sched_yield();
    }
}
FN_TEST(local_flock)
    if (!strcmp(scenario,"C00-open-overlap") || !strcmp(scenario,"C13-open-close")) {
        CHECK(control(9,0,0,0));
        start_worker(0,-1,0,0); wait_open_stage(1);
        start_worker(1,-1,0,0); wait_open_stage(2);
        CHECK(control(11,0,0,0));
        wait_boundary(2,7); wait_boundary(3,7);
        TEST_RES(control(2,2,0,0), _ret == 2);
        TEST_RES(control(2,3,0,0), _ret == 2);
        if (!strcmp(scenario,"C00-open-overlap")) {
            prefix=1;
        } else {
            TEST_SUCC(close(3));
            CHECK(control(12,0,0,0));
            finish_worker(0); finish_worker(1);
            TEST_SUCC(close(4));
        }
        __TEST_SUMMARY();
        return;
    }
    int a = open_fixture(), b = open_fixture(), c = -1, alias = -1;
    if (!strcmp(scenario,"C01")) {
        c = open_fixture();
        TEST_SUCC(flock(a, LOCK_SH | LOCK_NB)); TEST_SUCC(flock(b, LOCK_SH | LOCK_NB));
        TEST_ERRNO(flock(c, LOCK_EX | LOCK_NB), EAGAIN);
        TEST_SUCC(flock(a, LOCK_UN)); TEST_SUCC(flock(b, LOCK_UN)); TEST_SUCC(flock(c, LOCK_EX | LOCK_NB));
    } else if (!strcmp(scenario,"C02")) {
        TEST_SUCC(flock(a, LOCK_EX | LOCK_NB)); alias = CHECK(dup(a));
        TEST_SUCC(flock(alias, LOCK_EX | LOCK_NB)); TEST_SUCC(flock(alias, LOCK_UN));
        TEST_SUCC(flock(b, LOCK_UN)); TEST_SUCC(flock(b, LOCK_EX | LOCK_NB));
    } else if (!strcmp(scenario,"C03")) {
        TEST_SUCC(flock(a, LOCK_EX | LOCK_NB)); alias = CHECK(dup(a));
        int removed=a; TEST_SUCC(close(a)); a = -1; TEST_ERRNO(flock(removed, LOCK_UN), EBADF); TEST_ERRNO(flock(b, LOCK_EX | LOCK_NB), EAGAIN);
        TEST_SUCC(close(alias)); alias = -1; TEST_SUCC(flock(b, LOCK_EX | LOCK_NB));
    } else if (!strcmp(scenario,"C04")) {
        TEST_SUCC(flock(a, LOCK_SH | LOCK_NB)); TEST_SUCC(flock(a, LOCK_EX | LOCK_NB));
        if (instrumented) { start_worker(0,b,LOCK_SH,1); wait_boundary(2,5); }
        TEST_SUCC(flock(a, LOCK_SH | LOCK_NB));
        if (instrumented) finish_worker(0);
    } else if (!strcmp(scenario,"C05")) {
        c = open_fixture(); TEST_SUCC(flock(a,LOCK_SH|LOCK_NB)); TEST_SUCC(flock(b,LOCK_SH|LOCK_NB));
        TEST_ERRNO(flock(a,LOCK_EX|LOCK_NB),EAGAIN); TEST_SUCC(flock(b,LOCK_UN));
        if (instrumented) TEST_ERRNO(flock(c,LOCK_EX|LOCK_NB),EAGAIN);
        else TEST_SUCC(flock(c,LOCK_EX|LOCK_NB));
    } else if (!strcmp(scenario,"C06")) {
        TEST_SUCC(flock(a,LOCK_SH|LOCK_NB)); TEST_SUCC(flock(b,LOCK_SH|LOCK_NB));
        start_worker(0,a,LOCK_EX,1); wait_boundary(2,5);
        start_worker(1,b,LOCK_EX,1); wait_boundary(3,5); prefix=1;
    } else if (!strcmp(scenario,"C07-before") || !strcmp(scenario,"C07-after")) {
        TEST_SUCC(flock(a,LOCK_EX|LOCK_NB));
        if (!strcmp(scenario,"C07-before")) { TEST_SUCC(flock(a,LOCK_UN)); start_worker(0,b,LOCK_EX,1); }
        else { start_worker(0,b,LOCK_EX,1); wait_boundary(2,5); TEST_SUCC(flock(a,LOCK_UN)); }
        finish_worker(0);
    } else if (!strcmp(scenario,"C07-notify")) {
        TEST_SUCC(flock(a,LOCK_EX|LOCK_NB)); CHECK(control(8,2,0,0));
        start_worker(0,b,LOCK_EX,1); wait_boundary(2,6);
        TEST_SUCC(flock(a,LOCK_UN)); CHECK(control(6,0,0,0)); finish_worker(0);
    } else if (!strcmp(scenario,"C08")) {
        c=open_fixture(); TEST_SUCC(flock(a,LOCK_SH|LOCK_NB)); TEST_SUCC(flock(b,LOCK_SH|LOCK_NB));
        start_worker(0,c,LOCK_EX,1); wait_boundary(2,5);
        long before=control(2,2,0,0); TEST_SUCC(flock(a,LOCK_UN));
        wait_boundary_after(2,5,before); TEST_SUCC(flock(b,LOCK_UN)); finish_worker(0);
    } else if (!strcmp(scenario,"C09")) {
        c=open_fixture(); TEST_SUCC(flock(a,LOCK_EX|LOCK_NB));
        start_worker(0,b,LOCK_EX,1); wait_boundary(2,5);
        start_worker(1,c,LOCK_EX,1); wait_boundary(3,5);
        TEST_SUCC(flock(a,LOCK_UN)); finish_worker(0); finish_worker(1);
    } else if (!strcmp(scenario,"C10")) {
        TEST_SUCC(flock(a,LOCK_EX|LOCK_NB)); start_worker(0,b,LOCK_EX,0); wait_boundary(2,5);
        TEST_SUCC(close(b)); b=-1; TEST_SUCC(flock(a,LOCK_UN)); finish_worker(0);
        c=open_fixture(); TEST_SUCC(flock(c,LOCK_EX|LOCK_NB));
    } else if (!strcmp(scenario,"C11") || !strncmp(scenario,"C12-",4)) {
        TEST_SUCC(flock(b,LOCK_EX|LOCK_NB));
        if (!strcmp(scenario,"C12-before")) {
            TEST_SUCC(close(b)); b=-1; TEST_SUCC(flock(a,LOCK_UN));
        } else if (!strcmp(scenario,"C12-after")) {
            start_worker(0,a,LOCK_UN,0); finish_worker(0); TEST_SUCC(close(b)); b=-1;
        } else {
            if (!strcmp(scenario,"C12-alias")) alias=CHECK(dup(b));
            CHECK(control(5,b,0,0)); start_worker(0,a,LOCK_UN,0); wait_boundary(2,2);
            TEST_SUCC(close(b)); b=-1; CHECK(control(6,0,0,0));
            if (alias >= 0) finish_worker(0);
            else { wait_boundary(2,3); prefix=1; }
        }
    } else { fprintf(stderr,"unknown scenario: %s\n",scenario); exit(2); }
    if (!prefix) {
        if (alias >= 0) TEST_SUCC(close(alias));
        if (c >= 0) TEST_SUCC(close(c));
        if (b >= 0) TEST_SUCC(close(b));
        if (a >= 0) TEST_SUCC(close(a));
    }
END_TEST()

int main(void)
{
    dump();
    if (getpid() == 1) { sync(); reboot(RB_POWER_OFF); }
    return __total_failures ? 1 : 0;
}
