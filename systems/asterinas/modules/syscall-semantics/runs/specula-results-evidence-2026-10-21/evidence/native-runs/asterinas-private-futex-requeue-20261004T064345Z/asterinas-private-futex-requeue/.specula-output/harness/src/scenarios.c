// SPDX-License-Identifier: MPL-2.0
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static _Atomic int words[4096];
static _Atomic int *a, *b, *other;
static long probe(void *addr, int command, unsigned long arg) {
    long r=syscall(SYS_futex,addr,0x5350,command,arg,0,0);
    assert(r>=0); return r;
}
static void pin(int cpu) {
    cpu_set_t set; CPU_ZERO(&set); CPU_SET(cpu,&set);
    assert(sched_setaffinity(0,sizeof(set),&set)==0);
}
static void delay(long ns) {
    struct timespec begin,now;clock_gettime(CLOCK_MONOTONIC,&begin);
    do {sched_yield();clock_gettime(CLOCK_MONOTONIC,&now);}
    while ((now.tv_sec-begin.tv_sec)*1000000000L+now.tv_nsec-begin.tv_nsec<ns);
}
static long wake(_Atomic int *p,int n) {return syscall(SYS_futex,p,FUTEX_WAKE_PRIVATE,n,0,0,0);}
static long requeue(_Atomic int *p,_Atomic int *q,int nw,int nm) {return syscall(SYS_futex,p,FUTEX_REQUEUE_PRIVATE,nw,nm,q,0);}
struct waiter {pthread_t thread;int stream;_Atomic int *word;long ns;int expected;long result;int error;};
static void *wait_fn(void *arg) {
    struct waiter *w=arg;pin(w->stream%2);probe(0,1,w->stream);
    struct timespec t={.tv_nsec=w->ns};errno=0;
    w->result=syscall(SYS_futex,w->word,FUTEX_WAIT_PRIVATE,w->expected,w->ns<0?0:&t,0,0);
    w->error=errno;return 0;
}
static void start(struct waiter *w,int stream,_Atomic int *p,long ns) {
    *w=(struct waiter){.stream=stream,.word=p,.ns=ns};
    assert(pthread_create(&w->thread,0,wait_fn,w)==0);
}
static void enrolled(unsigned n) {
    struct timespec start,now;clock_gettime(CLOCK_MONOTONIC,&start);
    while ((unsigned)probe(0,5,0)<n) {
        sched_yield();clock_gettime(CLOCK_MONOTONIC,&now);
        assert(now.tv_sec-start.tv_sec<2);
    }
    probe(0,10,n);
}
static void join(struct waiter *w) {assert(pthread_join(w->thread,0)==0);probe(0,9,w->stream);}
static _Atomic int gate;
static void *opposite(void *arg) {
    (void)arg;pin(1);probe(0,1,7);
    atomic_store_explicit(&gate,1,memory_order_release);
    while(atomic_load_explicit(&gate,memory_order_acquire)!=2) sched_yield();
    probe(0,10,4);requeue(b,a,1,1);return 0;
}
int main(void) {
    setvbuf(stdout,0,_IONBF,0);
    int c=atoi(getenv("FUTEX_CASE")?getenv("FUTEX_CASE"):"1");
    pin(0);probe(0,1,1);memset(words,0,sizeof(words));
    a=&words[0];long ba=probe(a,4,0);b=0;other=0;
    int same=(c==3||c==5||c==7||c==10);
    for(int i=1;i<4096;i++) {
        long bi=probe(&words[i],4,0);
        if(!b && (same?(bi==ba):(bi!=ba))) b=&words[i];
        else if(!other && bi==ba) other=&words[i];
        if(b&&other)break;
    }
    assert(b&&other);if(c==9)b=a;
    probe(0,2,c);probe(a,3,0);if(b!=a)probe(b,3,1);probe(other,3,2);
    struct waiter x,y,z,u;pthread_t op;
    if(c==1) {
        x=(struct waiter){.stream=2,.word=a,.ns=-1,.expected=1};
        assert(pthread_create(&x.thread,0,wait_fn,&x)==0);join(&x);
        assert(x.result==-1&&x.error==EAGAIN);assert(wake(a,1)==0);
    } else if(c==2) {
        start(&x,2,a,-1);enrolled(1);assert(wake(a,1)==1);join(&x);
    } else if(c>=3&&c<=9) {
        unsigned offset=0;
        if(c==7) {start(&z,4,other,-1);enrolled(1);offset=1;}
        start(&x,2,a,-1);enrolled(1+offset);start(&y,3,a,-1);enrolled(2+offset);
        int nw=c==8?0:1;int nm=(c==5||c==6||c==7)?0:1;
        requeue(a,b,nw,nm);wake(b,2);wake(a,2);
        if(c==7)wake(other,1);
        join(&x);join(&y);if(c==7)join(&z);
    } else if(c==10||c==11||c==12||c==13) {
        start(&x,2,a,-1);enrolled(1);start(&y,3,a,20000000);enrolled(2);
        requeue(a,b,1,1);join(&x);
        if(c==12) {delay(19000000);wake(b,1);}
        join(&y);wake(b,1);
        if(c==13) {
            start(&z,4,b,-1);enrolled(3);start(&u,5,b,-1);enrolled(4);
            requeue(b,a,1,1);wake(a,2);wake(b,2);join(&z);join(&u);
        }
    } else if(c==14) {
        start(&x,2,a,-1);enrolled(1);start(&y,3,a,-1);enrolled(2);
        start(&z,4,b,-1);enrolled(3);start(&u,5,b,-1);enrolled(4);
        assert(pthread_create(&op,0,opposite,0)==0);
        while(!atomic_load_explicit(&gate,memory_order_acquire))sched_yield();
        atomic_store_explicit(&gate,2,memory_order_release);
        requeue(a,b,1,1);assert(pthread_join(op,0)==0);probe(0,9,7);
        wake(a,4);wake(b,4);join(&x);join(&y);join(&z);join(&u);
    } else if(c==15) {
        start(&x,2,a,0);join(&x);wake(a,1);
    } else if(c==16) {
        start(&x,2,a,-1);enrolled(1);start(&y,3,a,-1);enrolled(2);
        requeue(a,b,0,0);wake(a,2);wake(b,2);join(&x);join(&y);
    } else if(c==17) {
        start(&x,2,a,200000000);enrolled(1);wake(a,1);join(&x);
    } else if(c==18) {
        start(&x,2,a,-1);
        unsigned lo,hi;__asm__ volatile("lfence; rdtsc":"=a"(lo),"=d"(hi)::"memory");
        unsigned long t=((unsigned long)hi<<32)|lo;
        atomic_store_explicit(a,1,memory_order_release);
        assert(syscall(SYS_futex,a,0x5350,7,t,0,1)>=0);
        wake(a,1);join(&x);
    } else abort();
    /* Let cancelled heap nodes and callbacks drain before freezing the buffers. */
    delay(10000000);probe(0,8,0);probe(0,6,c);
    printf("SPECULA_USER_DONE %d\n",c);
    reboot(RB_POWER_OFF);
    return 0;
}
