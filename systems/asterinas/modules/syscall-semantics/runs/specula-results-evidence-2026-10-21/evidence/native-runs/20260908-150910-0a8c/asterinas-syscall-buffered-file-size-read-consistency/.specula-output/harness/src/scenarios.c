/* SPDX-License-Identifier: MPL-2.0 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <x86intrin.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "test.h"
#include "cases.h"

static const char *backends[] = {"ramfs", "ext2", "exfat"};
static unsigned char seed[16384];
static _Atomic unsigned long launch_tsc;
static unsigned int trial;
static int subject(const char *backend, size_t size)
{
    char path[128];
    snprintf(path, sizeof(path), "/%s/subject", backend);
    int fd = CHECK(open(path, O_CREAT | O_TRUNC | O_RDWR, 0600));
    CHECK_WITH(pwrite(fd, seed, size, 0), _ret == (ssize_t)size);
    CHECK(fsync(fd));
    CHECK(lseek(fd, 0, SEEK_SET));
    return fd;
}

struct attempt {
    int fd, tid, scenario;
    pthread_barrier_t *barrier;
    ssize_t result;
    int error;
};

static const struct input_case *trace_fault_case(void)
{
    for (size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++)
        if(cases[i].kind==2 && cases[i].region==5 && cases[i].length==8192 && cases[i].accessible==4096) return &cases[i];
    abort();
}

static void *worker(void *arg)
{
    struct attempt *a = arg;
    cpu_set_t cpu; CPU_ZERO(&cpu); CPU_SET(a->tid, &cpu);
    CHECK(sched_setaffinity(0, sizeof(cpu), &cpu));
    unsigned char *map = CHECK_WITH(mmap(NULL, 24576, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0), _ret != MAP_FAILED);
    memset(map, a->tid ? 66 : a->scenario==3 || a->scenario==4 ? 65 : 165, 24576);
    unsigned char *buffer = map;
    size_t accessible = 16384;
    if (a->scenario == 3) {
        accessible = trace_fault_case()->accessible;
        buffer = map + 8192 - accessible;
        CHECK(mprotect(buffer + accessible, 4096, PROT_NONE));
    }
    CHECK(prctl(0x53504543, a->tid, 2048UL, accessible, 0UL));
    pthread_barrier_wait(a->barrier);
    if (a->tid==0) atomic_store(&launch_tsc, __rdtsc()+1000000);
    unsigned long launch;
    while (!(launch=atomic_load(&launch_tsc))) _mm_pause();
    while (__rdtsc()<launch) _mm_pause();
    errno = 0;
    if (a->tid == 0) {
        if (a->scenario == 5) {
            a->result=ftruncate(a->fd,4096);
        } else if (a->scenario == 0) {
            CHECK(ftruncate(a->fd, 2048));
            a->result = read(a->fd, buffer, 4096);
            CHECK(ftruncate(a->fd, 8192));
            memset(buffer,165,8192);
            a->result = pread(a->fd,buffer,8192,0);
            CHECK(pread(a->fd,buffer,0,0));
            CHECK(pwrite(a->fd,buffer,0,0));
        } else if (a->scenario == 3) {
            a->result = pwrite(a->fd, buffer, trace_fault_case()->length, 2048);
        } else if (a->scenario == 4) {
            a->result = pwrite(a->fd, buffer, 4096, 4096);
        } else {
            a->result = pread(a->fd, buffer, 8192, 0);
        }
    } else if (a->scenario == 5) {
        a->result=ftruncate(a->fd,4096);
    } else if (a->scenario == 1) {
        a->result = ftruncate(a->fd, 0);
    } else if (a->scenario == 2) {
        a->result = pwrite(a->fd, buffer, 8192, 2048);
    } else if (a->scenario == 4) {
        a->result = pwrite(a->fd, buffer, 4096, 8192);
    }
    a->error = errno;
    pthread_barrier_wait(a->barrier);
    CHECK(prctl(0x53504544, 0UL, 0UL, 0UL, 0UL));
    CHECK(munmap(map, 24576));
    return NULL;
}

static void trace_scenario(const char *backend, int scenario)
{
    int fd = subject(backend, 4096);
    atomic_store(&launch_tsc,0);
    pthread_t threads[2];
    pthread_barrier_t barrier;
    CHECK(pthread_barrier_init(&barrier, NULL, 2));
    struct attempt a[2];
    printf("SPECULA_BEGIN {\"name\":\"%s-%d-%u\",\"backend\":\"%s\"}\n", backend, scenario, trial++, backend);
    fflush(stdout);
    for (int i = 0; i < 2; i++) {
        a[i] = (struct attempt){.fd=fd, .tid=i, .scenario=scenario, .barrier=&barrier};
        CHECK(pthread_create(&threads[i], NULL, worker, &a[i]));
    }
    for (int i = 0; i < 2; i++) CHECK(pthread_join(threads[i], NULL));
    struct stat st;
    CHECK(fstat(fd, &st));
    off_t pos = CHECK(lseek(fd, 0, SEEK_CUR));
    printf("SPECULA_END {\"size\":%ld,\"position\":%ld,\"returns\":[%ld,%ld],\"errno\":[%d,%d]}\n",
        st.st_size, pos, a[0].result, a[1].result, a[0].error, a[1].error);
    fflush(stdout);
    CHECK(pthread_barrier_destroy(&barrier));
    CHECK(close(fd));
}

static void input_case(const char *backend, const struct input_case *c)
{
    int fd = subject(backend, 12288);
    unsigned char *map = CHECK_WITH(mmap(NULL, 32768, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0), _ret != MAP_FAILED);
    memset(map, c->kind==2 ? 65 : 165, 32768);
    unsigned char *buffer = map + 8192;
    if (c->region==1) buffer=NULL;
    else if (c->region==2) {
        CHECK(munmap(map+8192, 12288));
    } else if (c->region==3) CHECK(mprotect(buffer, 12288, PROT_NONE));
    else if (c->region==4) CHECK(mprotect(buffer, 12288, PROT_READ));
    else if (c->region==5) {
        buffer=map+16384-c->accessible;
        CHECK(mprotect(map+16384, 12288, PROT_NONE));
    }
    CHECK(lseek(fd, 2048, SEEK_SET));
    errno=0;
    ssize_t result = c->kind==0 ? read(fd,buffer,c->length) : c->kind==1 ? pread(fd,buffer,c->length,2048) : pwrite(fd,buffer,c->length,2048);
    int error = result<0 ? errno : 0;
    off_t pos=CHECK(lseek(fd,0,SEEK_CUR));
    struct stat st; CHECK(fstat(fd,&st));
    long delivered=-1, committed=-1, prefix=-1, outside=-1;
    if (c->region!=1 && c->region!=2) {
        CHECK(mprotect(map,32768,PROT_READ|PROT_WRITE));
        if (c->kind!=2) {
            delivered=0; prefix=0; outside=0;
            for (size_t i=0;i<c->length;i++) if (buffer[i]!=165) delivered++;
            while ((size_t)prefix<c->length && buffer[prefix]!=165) prefix++;
            for (size_t i=c->length;i<c->length+64;i++) if (buffer[i]!=165) outside++;
        }
    }
    unsigned char contents[16384];
    ssize_t readable=CHECK(pread(fd,contents,sizeof(contents),0));
    if(c->kind==2) {
        committed=0;
        for(ssize_t i=0;i<readable;i++) if(contents[i]==65) committed++;
    }
    printf("SPECULA_CASE {\"backend\":\"%s\",\"case_id\":\"%s\",\"object_id\":\"%s\",\"return\":%ld,\"errno\":%d,\"delivered\":%ld,\"committed\":%ld,\"delivered_prefix\":%ld,\"outside_request_changed\":%ld,\"size_before\":12288,\"size_after\":%ld,\"offset_before\":2048,\"offset_after\":%ld,\"readable_after\":%ld}\n",
        backend,c->id,c->object,result,error,delivered,committed,prefix,outside,st.st_size,pos,readable);
    fflush(stdout);
    CHECK(munmap(map,32768));
    CHECK(close(fd));
}

FN_SETUP(buffers)
    memset(seed,83,sizeof(seed));
END_SETUP()

FN_TEST(buffered_file_protocol)
    for (size_t b=0;b<3;b++) {
        for(int s=0;s<5;s++) trace_scenario(backends[b],s);
        for(size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++) input_case(backends[b],&cases[i]);
    }
    for (int i=0;i<96;i++) trace_scenario("ext2",5);
    TEST_SUCC(0);
END_TEST()
