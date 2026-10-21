// SPDX-License-Identifier: MPL-2.0
#define _GNU_SOURCE
#include <assert.h>
#include <cpuid.h>
#include <errno.h>
#include <gnu/libc-version.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

_Static_assert(SYS_wait4 == 61 && SYS_waitid == 247, "x86-64 syscall ABI");
_Static_assert(sizeof(siginfo_t) == 128 && P_PID == 1, "x86-64 siginfo ABI");
_Static_assert(WNOHANG == 1 && WEXITED == 4 && WNOWAIT == 0x01000000,
               "wait option ABI");

enum { MAX_CALLS = 16, CALIBRATION_SAMPLES = 64 };
struct clock_cpu {
    int cpu;
    unsigned max_extended, features_edx, invariant_edx;
    char vendor[13];
};
struct shared {
    atomic_int ready, allow_exit, started, command, done, finish, clock_seq;
    struct clock_cpu clocks[3];
};
struct result {
    uint64_t start, end;
    int api, options, error;
    long ret;
    unsigned char before[128], after[128];
};
struct waiter {
    _Alignas(128) unsigned char output[128];
    struct result calls[MAX_CALLS];
    int actor, cpu, count, smp, api, options;
};
static struct waiter waiters[2];
static struct shared *shared;
static pid_t child;
static int competing, overlap, already_exited, main_api = 4, delay_us, exit_value = 37;
static uint64_t clock_samples[2][CALIBRATION_SAMPLES][4];

static inline uint64_t stamp(void)
{
    unsigned lo, hi;
    // The memory clobber constrains the compiler. LFENCE orders execution
    // on the admitted Intel CPUs but leaves store visibility unbounded.
    __asm__ volatile("lfence\n\trdtsc\n\tlfence"
                     : "=a"(lo), "=d"(hi) : : "memory");
    return ((uint64_t)hi << 32) | lo;
}
static void until(atomic_int *value, int expected)
{
    while (atomic_load_explicit(value, memory_order_acquire) != expected)
        sched_yield();
}
static void pin(int cpu)
{
    cpu_set_t cpus;
    CPU_ZERO(&cpus);
    CPU_SET(cpu, &cpus);
    assert(sched_setaffinity(0, sizeof(cpus), &cpus) == 0);
    assert(sched_getcpu() == cpu);
}
// Outcome mode only. The pinned Asterinas stores a new affinity mask without migrating the
// caller (kernel/core/src/syscall/sched_affinity.rs:33), and new threads start with a full mask,
// so placement cannot be forced from user space. Request the CPU, then record where the actor
// actually runs instead of asserting it. Grouped mode keeps pin() and its assertion.
static void outcome_pin(const char *actor, int cpu)
{
    cpu_set_t cpus;
    CPU_ZERO(&cpus);
    CPU_SET(cpu, &cpus);
    assert(sched_setaffinity(0, sizeof(cpus), &cpus) == 0);
    printf("WR_OUTCOME_PLACEMENT {\"actor\":\"%s\",\"requested_cpu\":%d,\"actual_cpu\":%d}\n",
           actor, cpu, sched_getcpu());
    fflush(stdout);
}
static void check_cpu(int cpu)
{
    cpu_set_t cpus;
    assert(sched_getaffinity(0, sizeof(cpus), &cpus) == 0);
    assert(CPU_COUNT(&cpus) == 1 && CPU_ISSET(cpu, &cpus));
    assert(sched_getcpu() == cpu);
}
static void check_clock_cpu(int actor, int cpu)
{
    struct clock_cpu *info = &shared->clocks[actor - 1];
    unsigned a, b, c, d;
    check_cpu(cpu);
    info->cpu = cpu;
    __cpuid(0, a, b, c, d);
    memcpy(info->vendor, &b, 4);
    memcpy(info->vendor + 4, &d, 4);
    memcpy(info->vendor + 8, &c, 4);
    info->vendor[12] = '\0';
    __cpuid(1, a, b, c, d);
    info->features_edx = d;
    info->max_extended = __get_cpuid_max(0x80000000, NULL);
    if (info->max_extended >= 0x80000007) {
        __cpuid(0x80000007, a, b, c, d);
        info->invariant_edx = d;
    }
    // Other vendors need a separately reviewed LFENCE execution contract.
    // CPUID is kept outside all measured operations and calibration samples.
    if (strcmp(info->vendor, "GenuineIntel") || !(info->features_edx & (1U << 4)) ||
        !(info->features_edx & (1U << 26)) || !(info->invariant_edx & (1U << 8))) {
        fprintf(stderr, "WR_CLOCK_UNSUPPORTED actor=%d cpu=%d vendor=%s max=%x features=%x invariant=%x\n",
                actor, cpu, info->vendor, info->max_extended, info->features_edx, info->invariant_edx);
        exit(78);
    }
}
static void clock_responder(int phase)
{
    check_cpu(waiters[1].cpu);
    for (int i = 0; i < CALIBRATION_SAMPLES; ++i) {
        int seq = (phase * CALIBRATION_SAMPLES + i) * 2;
        until(&shared->clock_seq, seq + 1);
        clock_samples[phase][i][1] = stamp();
        clock_samples[phase][i][2] = stamp();
        atomic_store_explicit(&shared->clock_seq, seq + 2, memory_order_release);
    }
    check_cpu(waiters[1].cpu);
}
static void clock_initiator(int phase)
{
    check_cpu(waiters[0].cpu);
    for (int i = 0; i < CALIBRATION_SAMPLES; ++i) {
        int seq = (phase * CALIBRATION_SAMPLES + i) * 2;
        clock_samples[phase][i][0] = stamp();
        atomic_store_explicit(&shared->clock_seq, seq + 1, memory_order_release);
        until(&shared->clock_seq, seq + 2);
        clock_samples[phase][i][3] = stamp();
    }
    check_cpu(waiters[0].cpu);
}
static void check_signals(void)
{
    struct sigaction action;
    sigset_t mask;
    assert(sigaction(SIGCHLD, NULL, &action) == 0);
    assert(action.sa_handler == SIG_DFL && !(action.sa_flags & SA_NOCLDWAIT));
    assert(pthread_sigmask(SIG_SETMASK, NULL, &mask) == 0);
    assert(sigismember(&mask, SIGCHLD) == 1);
}
static unsigned long observer_delay_cycles(void)
{
#ifdef __asterinas__
    return overlap ? 50000000UL : 0UL;
#else
    return 0;
#endif
}
static int control(int command, int actor)
{
#ifdef __asterinas__
    return syscall(SYS_prctl, 0x53575000 + command, actor, child,
                   actor == 1 ? observer_delay_cycles() : 0UL, 0);
#else
    (void)command;
    (void)actor;
    return sysconf(_SC_NPROCESSORS_ONLN);
#endif
}
static void output_fields(const unsigned char *output, int api)
{
    int32_t words[32];
    memcpy(words, output, 128);
    if (api == 4)
        printf("{\"pid\":0,\"uid\":0,\"signo\":0,\"siCode\":0,\"status\":%d}", words[0]);
    else
        printf("{\"pid\":%d,\"uid\":%u,\"signo\":%d,\"siCode\":%d,\"status\":%d}",
               words[4], (unsigned)words[5], words[0], words[2], words[6]);
}
static struct result *invoke(struct waiter *waiter, int api, int options)
{
    check_cpu(waiter->cpu);
    assert(waiter->count < MAX_CALLS);
    struct result *r = &waiter->calls[waiter->count++];
    memset(waiter->output, 0, sizeof(waiter->output));
    if (api == 4) {
        int status = -999;
        memcpy(waiter->output, &status, sizeof(status));
    }
    memcpy(r->before, waiter->output, 128);
    r->api = api;
    r->options = options;
    errno = 0;
    r->start = stamp();
    if (api == 4)
        r->ret = syscall(SYS_wait4, child, waiter->output, options, NULL);
    else
        r->ret = syscall(SYS_waitid, P_PID, child, waiter->output, options, NULL);
    r->error = errno;
    r->end = stamp();
    check_cpu(waiter->cpu);
    memcpy(r->after, waiter->output, 128);
    return r;
}
static void expect_event(struct result *r)
{
    assert(r->error == 0);
    if (r->api == 4) {
        int status;
        memcpy(&status, r->after, sizeof(status));
        assert(r->ret == child && WIFEXITED(status));
        assert(WEXITSTATUS(status) == exit_value);
    } else {
        siginfo_t info;
        memcpy(&info, r->after, sizeof(info));
        assert(r->ret == 0 && info.si_pid == child && info.si_uid == getuid());
        assert(info.si_signo == SIGCHLD && info.si_code == CLD_EXITED);
        assert(info.si_status == exit_value);
    }
}
static void expect_echild(struct result *r)
{
    assert(r->ret == -1 && r->error == ECHILD);
}
static void *worker(void *arg)
{
    struct waiter *waiter = arg;
    pin(waiter->cpu);
    check_clock_cpu(waiter->actor, waiter->cpu);
    check_signals();
    waiter->smp = control(1, waiter->actor);
    assert(waiter->smp >= 2);
    clock_responder(0);
    until(&shared->command, 1);
    if (overlap) {
        until(&shared->started, 1);
        usleep(1000);
    }
    if (competing)
        atomic_fetch_or_explicit(&shared->started, 2, memory_order_release);
    invoke(waiter, waiter->api, waiter->options);
    atomic_store_explicit(&shared->done, 1, memory_order_release);
    // The second exchange starts only after the controller task observes
    // notifier completion. No modeled lock is held by either participant.
    clock_responder(1);
    // Both parent tasks stay alive until the child finishes visiting them.
    until(&shared->finish, 1);
    return NULL;
}
static void print_calls(struct waiter *waiter)
{
    for (int i = 0; i < waiter->count; ++i) {
        struct result *r = &waiter->calls[i];
        printf("WR_USER {\"actor\":\"w%d\",\"generation\":%d,\"api\":%d,\"options\":%d,"
               "\"start\":%" PRIu64 ",\"end\":%" PRIu64 ",\"libcRet\":%ld,\"errno\":%d,\"out\":",
               waiter->actor, i + 1, r->api, r->options, r->start, r->end, r->ret, r->error);
        output_fields(r->after, r->api);
        printf(",\"before_bytes\":\"");
        for (int j = 0; j < 128; ++j) printf("%02x", r->before[j]);
        printf("\",\"after_bytes\":\"");
        for (int j = 0; j < 128; ++j) printf("%02x", r->after[j]);
        printf("\"}\n");
    }
}

static void outcome_fields(const unsigned char *bytes, int api)
{
    if (api == 4) {
        int status;
        memcpy(&status, bytes, sizeof(status));
        printf("{\"status\":%d}", status);
    } else {
        siginfo_t info;
        memcpy(&info, bytes, sizeof(info));
        printf("{\"si_signo\":%d,\"si_errno\":%d,\"si_code\":%d,"
               "\"si_pid\":%d,\"si_uid\":%u,\"si_status\":%d}",
               info.si_signo, info.si_errno, info.si_code,
               info.si_pid, info.si_uid, info.si_status);
    }
}

static void outcome_buffer(const unsigned char *bytes, int api, int inaccessible)
{
    if (inaccessible) {
        printf("{\"accessible\":false,\"fields\":null,\"bytes\":null}");
        return;
    }
    printf("{\"accessible\":true,\"fields\":");
    outcome_fields(bytes, api);
    printf(",\"bytes\":\"");
    for (int i = 0; i < (api == 4 ? 4 : 128); ++i) printf("%02x", bytes[i]);
    printf("\"}");
}

static struct result outcome_invoke(struct waiter *waiter, const char *purpose,
                                  int api, int options, const char *buffer)
{
    struct result r = { .api = api, .options = options };
    int inaccessible = !strcmp(buffer, "PROT_NONE");
    size_t page_size = 0;
    void *output = waiter->output;
    // No placement assertion here: on the pinned Asterinas a waiter may stay on another CPU.
    // outcome_pin() records the actual placement instead.
    if (inaccessible) {
        long size = sysconf(_SC_PAGESIZE);
        assert(size > 0);
        page_size = (size_t)size;
        output = mmap(NULL, page_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        assert(output != MAP_FAILED);
    } else {
        memset(output, !strcmp(buffer, "siginfo-poison") ? 0xa5 : 0, 128);
        if (api == 4) {
            int status = -999;
            memcpy(output, &status, sizeof(status));
        }
        memcpy(r.before, output, 128);
    }
    errno = 0;
    if (api == 4)
        r.ret = syscall(SYS_wait4, child, output, options, NULL);
    else
        r.ret = syscall(SYS_waitid, P_PID, child, output, options, NULL);
    r.error = errno;
    if (!inaccessible) memcpy(r.after, output, 128);
    // Serialize only completed syscall results, outside the wait operation.
    // No cross-thread order or duration is inferred from the output order.
    flockfile(stdout);
    printf("WR_OUTCOME_CALL {\"actor\":\"w%d\",\"call_index\":%d,\"purpose\":\"%s\","
           "\"api\":\"%s\",\"syscall_number\":%d,\"options\":%d,\"pid\":%d,"
           "\"idtype\":%s,\"rusage\":null,\"buffer\":\"%s\",\"return\":%ld,\"errno\":%d,\"before\":",
           waiter->actor, ++waiter->count, purpose, api == 4 ? "wait4" : "waitid",
           api == 4 ? SYS_wait4 : SYS_waitid, options, child,
           api == 4 ? "null" : "\"P_PID\"", buffer, r.ret, r.error);
    outcome_buffer(r.before, api, inaccessible);
    printf(",\"after\":");
    outcome_buffer(r.after, api, inaccessible);
    puts("}");
    fflush(stdout);
    funlockfile(stdout);
    if (inaccessible) assert(munmap(output, page_size) == 0);
    return r;
}

static struct result outcome_wait(struct waiter *waiter, const char *purpose,
                                int api, int options)
{
    return outcome_invoke(waiter, purpose, api, options,
                          api == 4 ? "status-sentinel" : "siginfo-zero");
}

static int outcome_event(const struct result *r)
{
    siginfo_t info;
    memcpy(&info, r->after, sizeof(info));
    return r->ret == 0 && r->error == 0 && info.si_pid == child &&
           info.si_uid == getuid() && info.si_signo == SIGCHLD &&
           info.si_code == CLD_EXITED && info.si_status == exit_value;
}

static void outcome_identity(const char *scenario, const char *pair, int affinity_count,
                             long online_cpus, const int cpus[2])
{
    unsigned a, b, c, d, features, invariant = 0;
    char vendor[13] = {0}, hypervisor[13] = {0};
    __cpuid(0, a, b, c, d);
    memcpy(vendor, &b, 4);
    memcpy(vendor + 4, &d, 4);
    memcpy(vendor + 8, &c, 4);
    __cpuid(1, a, b, c, d);
    features = d;
    int virtualized = !!(c & (1U << 31));
    if (virtualized) {
        __cpuid(0x40000000, a, b, c, d);
        memcpy(hypervisor, &b, 4);
        memcpy(hypervisor + 4, &c, 4);
        memcpy(hypervisor + 8, &d, 4);
    }
    unsigned maximum = __get_cpuid_max(0x80000000, NULL);
    if (maximum >= 0x80000007) {
        __cpuid(0x80000007, a, b, c, d);
        invariant = d;
    }
    struct utsname identity;
    assert(uname(&identity) == 0);
    printf("WR_OUTCOME_META {\"mode\":\"outcome\",\"scenario\":\"%s\",\"pair\":\"%s\","
           "\"child_pid\":%d,\"child_uid\":%u,\"exit_value\":%d,\"exit_delay_us\":%d,"
           "\"already_exited\":%s,\"online_cpus\":%ld,\"affinity_count\":%d,\"selected_cpus\":[%d,%d],"
           "\"sigchld\":\"SIG_DFL\",\"sa_nocldwait\":false,\"sigchld_blocked\":true,"
           "\"kernel_recorder\":\"NOT_ARMED\",\"observer_delay_control\":\"INACTIVE\","
           "\"kernel\":\"%s %s %s\",\"libc\":\"glibc %s\","
           "\"cpu_identity\":{\"cpu\":%d,\"vendor\":\"%s\",\"max_extended\":%u,"
           "\"features_edx\":%u,\"invariant_edx\":%u,\"hypervisor_present\":%s,\"hypervisor_vendor\":\"%s\"}}\n",
           scenario, pair, child, getuid(), exit_value, delay_us,
           already_exited ? "true" : "false", online_cpus,
           affinity_count, cpus[0], cpus[1], identity.sysname, identity.release, identity.machine,
           gnu_get_libc_version(), sched_getcpu(), vendor, maximum, features, invariant,
           virtualized ? "true" : "false", hypervisor);
    fflush(stdout);
}

static void *outcome_worker(void *arg)
{
    struct waiter *waiter = arg;
    outcome_pin("w2", waiter->cpu);
    check_signals();
    until(&shared->command, 1);
    if (overlap) {
        until(&shared->started, 1);
        usleep(1000);
    }
    if (competing) atomic_fetch_or_explicit(&shared->started, 2, memory_order_release);
    outcome_wait(waiter, "consume", waiter->api, waiter->options);
    atomic_store_explicit(&shared->done, 1, memory_order_release);
    return NULL;
}

static int outcome_main(int argc, char **argv)
{
    assert(argc == 7);
    const char *scenario = argv[1], *pair = argv[4];
    int sq = !strcmp(scenario, "sq-zero") || !strcmp(scenario, "sq-poison");
    int cf = !strcmp(scenario, "cf4") || !strcmp(scenario, "cfid") || !strcmp(scenario, "cfnowait");
    int lx = !strcmp(scenario, "lx");
    competing = !strcmp(scenario, "compete");
    overlap = !strcmp(scenario, "overlap");
    assert(sq || cf || lx || competing || overlap || !strcmp(scenario, "nohang") ||
           !strcmp(scenario, "observe4") || !strcmp(scenario, "observeid"));
    assert(!strcmp(pair, "44") || !strcmp(pair, "ii") || !strcmp(pair, "4i") || !strcmp(pair, "i4"));
    assert(!strcmp(argv[5], "ready") || !strcmp(argv[5], "blocked"));
    exit_value = atoi(argv[2]);
    delay_us = atoi(argv[3]);
    assert(exit_value >= 0 && exit_value <= 255 && delay_us >= 0 && delay_us <= 100000);
    already_exited = cf || lx || overlap || !strcmp(argv[5], "ready");
    alarm(20);
    struct sigaction action = { .sa_handler = SIG_DFL };
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGCHLD, &action, NULL) == 0);
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    assert(pthread_sigmask(SIG_BLOCK, &mask, NULL) == 0);
    check_signals();
    cpu_set_t available;
    assert(sched_getaffinity(0, sizeof(available), &available) == 0);
    int cpus[2], count = 0, affinity_count = CPU_COUNT(&available);
    long online_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    assert(affinity_count == 2);
    for (int i = 0; i < CPU_SETSIZE && count < 2; ++i)
        if (CPU_ISSET(i, &available)) cpus[count++] = i;
    for (int i = 0; i < 2; ++i) {
        waiters[i].actor = i + 1;
        waiters[i].cpu = cpus[i];
        waiters[i].api = pair[i] == '4' ? 4 : 247;
        waiters[i].options = waiters[i].api == 4 ? 0 : WEXITED;
    }
    shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(shared != MAP_FAILED);
    memset(shared, 0, sizeof(*shared));
    // Each guest boots afresh. Leaving all actors unregistered also prevents the
    // syscall observer from reading PROT_NONE before the real copyout-fault call.
    child = fork();
    assert(child >= 0);
    if (!child) {
        outcome_pin("child", cpus[1]);
        atomic_store_explicit(&shared->ready, 1, memory_order_release);
        until(competing && !already_exited ? &shared->started : &shared->allow_exit,
              competing && !already_exited ? 3 : 1);
        if (delay_us) usleep(delay_us);
        syscall(SYS_exit, exit_value);
        __builtin_unreachable();
    }
    until(&shared->ready, 1);
    outcome_pin("w1", cpus[0]);
    outcome_identity(scenario, pair, affinity_count, online_cpus, cpus);
    struct waiter *w = &waiters[0];
    if (already_exited) {
        atomic_store_explicit(&shared->allow_exit, 1, memory_order_release);
        struct result established = outcome_wait(w, "establish-zombie", 247, WEXITED | WNOWAIT);
        if (!outcome_event(&established)) {
            puts("WR_OUTCOME_SETUP_FAILED");
            return 65;
        }
    }
    if (competing || overlap) {
        pthread_t thread;
        assert(pthread_create(&thread, NULL, outcome_worker, &waiters[1]) == 0);
        atomic_store_explicit(&shared->command, 1, memory_order_release);
        atomic_fetch_or_explicit(&shared->started, 1, memory_order_release);
        outcome_wait(w, overlap ? "observer" : "consume", overlap ? 247 : w->api,
                     overlap ? WEXITED | WNOWAIT : w->options);
        until(&shared->done, 1);
        assert(pthread_join(thread, NULL) == 0);
    } else if (cf) {
        int api = !strcmp(scenario, "cf4") ? 4 : 247;
        int options = api == 4 ? 0 : WEXITED;
        if (!strcmp(scenario, "cfnowait")) options |= WNOWAIT;
        outcome_invoke(w, "fault", api, options, "PROT_NONE");
        outcome_wait(w, "after-fault", api, api == 4 ? WNOHANG : WEXITED | WNOHANG);
    } else if (lx) {
        outcome_wait(w, "without-wexited", 247, WSTOPPED | WNOHANG);
        outcome_wait(w, "with-wexited", 247, WEXITED | WNOHANG);
    } else {
        if (sq) {
            outcome_invoke(w, "live-siginfo", 247, WEXITED | WNOHANG,
                           !strcmp(scenario, "sq-zero") ? "siginfo-zero" : "siginfo-poison");
        } else if (!strcmp(scenario, "nohang")) {
            outcome_wait(w, "live-wait4", 4, WNOHANG);
            outcome_wait(w, "live-waitid", 247, WEXITED | WNOHANG);
        }
        atomic_store_explicit(&shared->allow_exit, 1, memory_order_release);
        if (!strncmp(scenario, "observe", 7)) {
            outcome_wait(w, "observe-1", 247, WEXITED | WNOWAIT);
            outcome_wait(w, "observe-2", 247, WEXITED | WNOWAIT | WNOHANG);
        }
        int api = !strcmp(scenario, "observeid") ? 247 : 4;
        outcome_wait(w, "consume", api, api == 4 ? 0 : WEXITED);
    }
    outcome_wait(w, "post-waitid", 247, WEXITED | WNOWAIT);
    outcome_wait(w, "post-wait4", 4, WNOHANG);
    puts("WR_OUTCOME_COMPLETE");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 7 && !strcmp(argv[6], "--outcome")) return outcome_main(argc, argv);
    assert(argc <= 6);
    const char *scenario = argc > 1 ? argv[1] : "compete";
    assert(!strcmp(scenario, "nohang") || !strcmp(scenario, "observe4") ||
           !strcmp(scenario, "observeid") || !strcmp(scenario, "compete") ||
           !strcmp(scenario, "overlap"));
    if (argc > 2) exit_value = atoi(argv[2]);
    if (argc > 3) delay_us = atoi(argv[3]);
    assert(exit_value >= 0 && exit_value <= 255 && delay_us >= 0 && delay_us <= 100000);
    alarm(20);
    competing = !strcmp(scenario, "compete");
    overlap = !strcmp(scenario, "overlap");
    already_exited = overlap || (argc > 5 && !strcmp(argv[5], "ready"));
    const char *pair = argc > 4 ? argv[4] : "4i";
    assert(!strcmp(pair, "44") || !strcmp(pair, "ii") || !strcmp(pair, "4i") || !strcmp(pair, "i4"));
    main_api = pair[0] == '4' ? 4 : 247;
    struct sigaction action = { .sa_handler = SIG_DFL };
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGCHLD, &action, NULL) == 0);
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    assert(pthread_sigmask(SIG_BLOCK, &mask, NULL) == 0);
    check_signals();
    cpu_set_t available;
    assert(sched_getaffinity(0, sizeof(available), &available) == 0);
    int cpus[2], count = 0;
    for (int i = 0; i < CPU_SETSIZE && count < 2; ++i)
        if (CPU_ISSET(i, &available)) cpus[count++] = i;
    assert(count == 2);
    waiters[0].actor = 1;
    waiters[0].cpu = cpus[0];
    waiters[1].actor = 2;
    waiters[1].cpu = cpus[1];
    waiters[1].api = (competing || overlap) && pair[1] == 'i' ? 247 : 4;
    waiters[1].options = waiters[1].api == 247 ? WEXITED : 0;
    shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(shared != MAP_FAILED);
    memset(shared, 0, sizeof(*shared));
    assert(control(0, 0) >= 0);
    child = fork();
    assert(child >= 0);
    if (!child) {
        pin(cpus[1]);
        check_clock_cpu(3, cpus[1]);
        assert(control(1, 3) >= 2);
        atomic_store_explicit(&shared->ready, 1, memory_order_release);
        until(competing && !already_exited ? &shared->started : &shared->allow_exit,
              competing && !already_exited ? 3 : 1);
        if (delay_us) usleep(delay_us);
        check_cpu(cpus[1]);
        syscall(SYS_exit, exit_value);
        __builtin_unreachable();
    }
    until(&shared->ready, 1);
    pin(cpus[0]);
    check_clock_cpu(1, cpus[0]);
    waiters[0].smp = control(1, 1);
    assert(waiters[0].smp >= 2);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, worker, &waiters[1]) == 0);
    clock_initiator(0);
    struct waiter *main_waiter = &waiters[0];
    if (already_exited) {
        atomic_store_explicit(&shared->allow_exit, 1, memory_order_release);
        expect_event(invoke(main_waiter, 247, WEXITED | WNOWAIT));
    }
    if (competing) {
        atomic_store_explicit(&shared->command, 1, memory_order_release);
        atomic_fetch_or_explicit(&shared->started, 1, memory_order_release);
        struct result *a = invoke(main_waiter, main_api, main_api == 4 ? 0 : WEXITED);
        until(&shared->done, 1);
        struct result *b = &waiters[1].calls[0];
        if (a->ret >= 0) { expect_event(a); expect_echild(b); }
        else { expect_echild(a); expect_event(b); }
    } else if (overlap) {
        atomic_store_explicit(&shared->command, 1, memory_order_release);
        atomic_store_explicit(&shared->started, 1, memory_order_release);
        struct result *observer = invoke(main_waiter, 247, WEXITED | WNOWAIT);
        until(&shared->done, 1);
        expect_event(&waiters[1].calls[0]);
        if (observer->ret >= 0) expect_event(observer);
        else expect_echild(observer);
    } else {
        if (!strcmp(scenario, "nohang")) {
            struct result *r = invoke(main_waiter, 4, WNOHANG);
            assert(r->ret == 0 && r->error == 0 && !memcmp(r->before, r->after, 128));
            r = invoke(main_waiter, 247, WEXITED | WNOHANG);
            assert(r->ret == 0 && r->error == 0);
        }
        atomic_store_explicit(&shared->allow_exit, 1, memory_order_release);
        if (strncmp(scenario, "observe", 7) == 0) {
            expect_event(invoke(main_waiter, 247, WEXITED | WNOWAIT));
            expect_event(invoke(main_waiter, 247, WEXITED | WNOWAIT | WNOHANG));
        }
        if (!strcmp(scenario, "observeid")) expect_event(invoke(main_waiter, 247, WEXITED | WNOHANG));
        else expect_event(invoke(main_waiter, 4, !strcmp(scenario, "observe4") ? WNOHANG : 0));
        atomic_store_explicit(&shared->command, 1, memory_order_release);
        until(&shared->done, 1);
        expect_echild(&waiters[1].calls[0]);
    }
    expect_echild(invoke(main_waiter, 247, WEXITED | WNOWAIT));
    expect_echild(invoke(main_waiter, 4, WNOHANG));
    while (control(2, 0) < 0) { assert(errno == EAGAIN); sched_yield(); }
    clock_initiator(1);
    struct utsname identity;
    assert(uname(&identity) == 0);
    printf("WR_META {\"scenario\":\"%s\",\"child_pid\":%d,\"child_uid\":%u,\"exit_value\":%d,"
           "\"smp\":%d,\"concurrent\":%s,\"buffers\":{\"w1\":%" PRIuPTR ",\"w2\":%" PRIuPTR "},"
           "\"sigchld\":\"SIG_DFL\",\"sa_nocldwait\":false,\"sigchld_blocked\":true,"
           "\"valid_buffers\":true,\"rusage_null\":true,\"kernel\":\"%s %s %s\",\"libc\":\"glibc %s\","
           "\"clock\":\"lfence-rdtsc-lfence-v4\",\"clock_samples_per_phase\":%d,"
           "\"clock_phases\":[\"pre\",\"post\"],\"cpu_affinity\":[%d,%d],\"exit_delay_us\":%d,"
           "\"pair\":\"%s\",\"already_exited\":%s,\"observer_delay_cycles\":%lu}\n",
           scenario, child, getuid(), exit_value, waiters[0].smp, competing || overlap ? "true" : "false",
           (uintptr_t)waiters[0].output, (uintptr_t)waiters[1].output,
           identity.sysname, identity.release, identity.machine, gnu_get_libc_version(),
           CALIBRATION_SAMPLES, cpus[0], cpus[1], delay_us, pair, already_exited ? "true" : "false",
           observer_delay_cycles());
    for (int actor = 1; actor <= 3; ++actor) {
        const struct clock_cpu *info = &shared->clocks[actor - 1];
        printf("WR_CLOCK_CPU {\"actor\":\"%s\",\"cpu\":%d,\"vendor\":\"%s\","
               "\"max_extended\":%u,\"features_edx\":%u,\"invariant_edx\":%u}\n",
               actor == 1 ? "w1" : actor == 2 ? "w2" : "child", info->cpu,
               info->vendor, info->max_extended, info->features_edx, info->invariant_edx);
    }
    for (int phase = 0; phase < 2; ++phase)
        for (int i = 0; i < CALIBRATION_SAMPLES; ++i)
            printf("WR_CLOCK %s %d %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
                   phase ? "post" : "pre", i, clock_samples[phase][i][0],
                   clock_samples[phase][i][1], clock_samples[phase][i][2], clock_samples[phase][i][3]);
    print_calls(&waiters[0]);
    print_calls(&waiters[1]);
    atomic_store_explicit(&shared->finish, 1, memory_order_release);
    assert(pthread_join(thread, NULL) == 0);
    puts("WR_COMPLETE");
    return 0;
}
