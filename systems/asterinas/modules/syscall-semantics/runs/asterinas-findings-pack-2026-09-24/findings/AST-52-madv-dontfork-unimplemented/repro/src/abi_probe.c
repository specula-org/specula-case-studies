/* SPDX-License-Identifier: MIT
 * v2: one assertion group per child; no kernel-crash triggers or global changes.
 * Linux ABI is tested, not a portable POSIX abstraction. See docs/METHOD.md.
 */
#if !defined(__x86_64__)
#error "v2 raw ABI cases currently target Linux x86-64"
#endif
#include "legacy_cases.inc"
#include <arpa/inet.h>
#include <dirent.h>
#include <ftw.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/time.h>
#ifdef __GLIBC__
#include <gnu/libc-version.h>
#endif

static int measured_errno(long rc, int saved) { return rc == -1 ? saved : 0; }
static int unsupported_env(const char *what) {
    int e = errno;
    if (e == ENOSYS || e == EPERM || e == EACCES) {
        printf("ENV %s unavailable or policy-blocked: errno=%d\n", what, e);
        return SKIP;
    }
    errno = e;
    return setup(what);
}
static int timerfd_cpu_common(clockid_t clock) {
    errno = 0;
    int fd = timerfd_create(clock, TFD_NONBLOCK | TFD_CLOEXEC);
    int e = errno;
    printf("OBS {\"clock\":%d,\"accepted\":%s,\"errno\":%d}\n",
           (int)clock, fd >= 0 ? "true" : "false", measured_errno(fd, e));
    if (fd >= 0) close(fd);
    if (fd < 0 && (e == ENOSYS || e == EPERM)) { errno = e; return unsupported_env("timerfd_create"); }
    return fd == -1 && e == EINVAL ? PASS : FAIL;
}
static int timerfd_cpu_process(void) { return timerfd_cpu_common(CLOCK_PROCESS_CPUTIME_ID); }
static int timerfd_cpu_thread(void) { return timerfd_cpu_common(CLOCK_THREAD_CPUTIME_ID); }

static int armed_timerfd(void) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec it = {.it_value = {0, 10000000}};
    if (timerfd_settime(fd, 0, &it, NULL) < 0) { int e=errno; close(fd); errno=e; return -1; }
    return fd;
}
static int await_timerfd(int fd) {
    struct pollfd p = {.fd=fd, .events=POLLIN};
    int r = poll(&p, 1, 1500);
    if (r == 1 && (p.revents & POLLIN)) return 0;
    if (r == 0) errno = ETIMEDOUT;
    return -1;
}
static int timerfd_poll_common(int disarm) {
    int fd = armed_timerfd();
    if (fd < 0) return unsupported_env("armed_timerfd");
    if (await_timerfd(fd)) { close(fd); return setup("initial timer expiration"); }
    uint64_t ticks = 0;
    if (disarm) {
        struct itimerspec it = {0};
        if (timerfd_settime(fd, 0, &it, NULL)) { close(fd); return setup("disarm"); }
    } else if (read(fd, &ticks, sizeof(ticks)) != (ssize_t)sizeof(ticks)) {
        close(fd); return setup("consume timer expiration");
    }
    struct pollfd p = {.fd=fd, .events=POLLIN};
    int ready = poll(&p, 1, 0);
    errno = 0;
    ssize_t n = read(fd, &ticks, sizeof(ticks)); int e=errno;
    printf("OBS {\"ready_after\":%d,\"revents\":%d,\"second_read\":%zd,\"errno\":%d}\n",
           ready, p.revents, n, measured_errno(n,e));
    close(fd);
    return ready==0 && n==-1 && e==EAGAIN ? PASS : FAIL;
}
static int timerfd_poll_drain(void) { return timerfd_poll_common(0); }
static int timerfd_poll_disarm(void) { return timerfd_poll_common(1); }
static int timerfd_epoll_drain(void) {
    int fd=armed_timerfd(); if(fd<0) return unsupported_env("armed_timerfd");
    int ep=epoll_create1(EPOLL_CLOEXEC); if(ep<0) {close(fd); return setup("epoll_create1");}
    struct epoll_event ev={.events=EPOLLIN,.data.u64=0x1234}, out={0};
    if(epoll_ctl(ep,EPOLL_CTL_ADD,fd,&ev)) {close(ep);close(fd);return setup("epoll_ctl");}
    int first=epoll_wait(ep,&out,1,1500);
    if(first!=1 || !(out.events & EPOLLIN)) {close(ep);close(fd);errno=ETIMEDOUT;return setup("initial epoll event");}
    uint64_t ticks=0;
    if(read(fd,&ticks,sizeof(ticks))!=8) {close(ep);close(fd);return setup("timer read");}
    memset(&out,0,sizeof(out)); int second=epoll_wait(ep,&out,1,0);
    printf("OBS {\"first\":%d,\"second\":%d,\"events_after\":%u}\n",first,second,out.events);
    close(ep);close(fd);return second==0?PASS:FAIL;
}
static int posix_timer_payload(void) {
    int sig=SIGRTMIN; sigset_t set;
    sigemptyset(&set);sigaddset(&set,sig);
    if(sigprocmask(SIG_BLOCK,&set,NULL)) return setup("block timer signal");
    struct sigevent sev={0}; sev.sigev_notify=SIGEV_SIGNAL;sev.sigev_signo=sig;sev.sigev_value.sival_int=0x13579;
    timer_t timer;
    if(timer_create(CLOCK_MONOTONIC,&sev,&timer)) return unsupported_env("timer_create");
    struct itimerspec it={.it_value={0,10000000}};
    if(timer_settime(timer,0,&it,NULL)) {timer_delete(timer);return setup("timer_settime");}
    siginfo_t info;memset(&info,0,sizeof(info));struct timespec wait={1,0};
    errno=0;int r=sigtimedwait(&set,&info,&wait);int e=errno;
    printf("OBS {\"signal_matches\":%s,\"code\":%d,\"value\":%d,\"errno\":%d}\n",
           r==sig?"true":"false",info.si_code,info.si_value.sival_int,measured_errno(r,e));
    timer_delete(timer);
    return r==sig && info.si_code==SI_TIMER && info.si_value.sival_int==0x13579?PASS:FAIL;
}
static int timer_create_bad_signal(void) {
    struct sigevent sev={0};sev.sigev_notify=SIGEV_SIGNAL;sev.sigev_signo=256+SIGUSR1;
    timer_t timer;errno=0;int r=timer_create(CLOCK_MONOTONIC,&sev,&timer);int e=errno;
    printf("OBS {\"accepted\":%s,\"errno\":%d}\n",r==0?"true":"false",measured_errno(r,e));
    if(r==0) timer_delete(timer); /* Never arm an unexpectedly accepted timer. */
    if(r<0 && (e==EPERM||e==ENOSYS)){errno=e;return unsupported_env("timer_create");}
    return r==-1 && e==EINVAL?PASS:FAIL;
}
static int pidfd_bad_signal(void) {
#if defined(SYS_pidfd_open) && defined(SYS_pidfd_send_signal)
    int fd=(int)syscall(SYS_pidfd_open,getpid(),0);if(fd<0)return unsupported_env("pidfd_open");
    /* A broken implementation may narrow to SIGUSR1. Block it before testing. */
    sigset_t set;sigemptyset(&set);sigaddset(&set,SIGUSR1);
    if(sigprocmask(SIG_BLOCK,&set,NULL)){close(fd);return setup("sigprocmask");}
    errno=0;long r=syscall(SYS_pidfd_send_signal,fd,256+SIGUSR1,NULL,0);int e=errno;
    printf("OBS {\"accepted\":%s,\"errno\":%d}\n",r==0?"true":"false",measured_errno(r,e));
    close(fd);
    if(r<0&&(e==EPERM||e==ENOSYS)){errno=e;return unsupported_env("pidfd_send_signal");}
    return r==-1&&e==EINVAL?PASS:FAIL;
#else
    return SKIP;
#endif
}
static int new_unlinked_file(void) {
    char name[]="./v2-file-XXXXXX";int fd=mkstemp(name);if(fd>=0)unlink(name);return fd;
}
static int utimens_preepoch(void) {
    int fd=new_unlinked_file();if(fd<0)return setup("mkstemp");
    struct timespec ts[2]={{-1,123456789},{-1,123456789}};
    errno=0;int r=futimens(fd,ts);int e=errno;struct stat st;memset(&st,0,sizeof(st));
    int sr=fstat(fd,&st);
    printf("OBS {\"ret\":%d,\"errno\":%d,\"negative_seconds_preserved\":%s}\n",
           r,measured_errno(r,e),sr==0&&st.st_mtim.tv_sec==-1?"true":"false");
    close(fd);if(sr)return setup("fstat");
    /* Exact nanoseconds are logged by a separate query if needed; not all FS have nanosecond resolution. */
    return r==0 && st.st_mtim.tv_sec==-1 ? PASS : FAIL;
}
static int utimes_preepoch(void) {
    char name[]="./v2-utimes-XXXXXX";int fd=mkstemp(name);if(fd<0)return setup("mkstemp");
    struct timeval tv[2]={{-1,0},{-1,0}};
    errno=0;long r=syscall(SYS_utimes,name,tv);int e=errno;struct stat st;memset(&st,0,sizeof(st));
    int sr=fstat(fd,&st);
    printf("OBS {\"ret\":%ld,\"errno\":%d,\"negative_seconds_preserved\":%s}\n",
           r,measured_errno(r,e),sr==0&&st.st_mtim.tv_sec==-1?"true":"false");
    close(fd);unlink(name);if(sr)return setup("fstat");
    return r==0 && st.st_mtim.tv_sec==-1?PASS:FAIL;
}
/* One local connection, no external network and no helper process. */
static int tcp_pair(int *listener,int *client,int *accepted,int keepidle,int nonblock_listener) {
    *listener=*client=*accepted=-1;
    *listener=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);if(*listener<0)return -1;
    if(keepidle && setsockopt(*listener,IPPROTO_TCP,TCP_KEEPIDLE,&keepidle,sizeof(keepidle)))return -1;
    struct sockaddr_in a={.sin_family=AF_INET,.sin_port=0,.sin_addr={.s_addr=htonl(INADDR_LOOPBACK)}};
    if(bind(*listener,(struct sockaddr*)&a,sizeof(a))||listen(*listener,1))return -1;
    socklen_t len=sizeof(a);if(getsockname(*listener,(struct sockaddr*)&a,&len))return -1;
    *client=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);if(*client<0)return -1;
    if(connect(*client,(struct sockaddr*)&a,sizeof(a)))return -1;
    if(nonblock_listener){int fl=fcntl(*listener,F_GETFL);if(fl<0||fcntl(*listener,F_SETFL,fl|O_NONBLOCK))return -1;}
    /* Readiness gates the test setup; no sleep guessed to stand for connection completion. */
    struct pollfd p={.fd=*listener,.events=POLLIN};
    if(poll(&p,1,1500)!=1){errno=ETIMEDOUT;return -1;}
    *accepted=accept(*listener,NULL,NULL);return *accepted<0?-1:0;
}
static void close_tcp(int l,int c,int a){if(a>=0)close(a);if(c>=0)close(c);if(l>=0)close(l);}
static int tcp_accept_keepidle(void) {
    int l,c,a;if(tcp_pair(&l,&c,&a,17,0)){int e=errno;close_tcp(l,c,a);errno=e;return unsupported_env("TCP setup");}
    int before=0,after=0;socklen_t n=sizeof(int);
    if(getsockopt(l,IPPROTO_TCP,TCP_KEEPIDLE,&before,&n)){close_tcp(l,c,a);return setup("listener getsockopt");}
    n=sizeof(int);if(getsockopt(a,IPPROTO_TCP,TCP_KEEPIDLE,&after,&n)){close_tcp(l,c,a);return setup("accepted getsockopt");}
    printf("OBS {\"listener\":%d,\"accepted\":%d,\"inherited\":%s}\n",before,after,before==after?"true":"false");
    close_tcp(l,c,a);return before==17 && after==17?PASS:FAIL;
}
static int pidfd_procdir(void) {
#ifdef SYS_pidfd_send_signal
    int fd=open("/proc/self",O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(fd<0)return unsupported_env("open /proc/self");
    errno=0;long r=syscall(SYS_pidfd_send_signal,fd,0,NULL,0);int e=errno;close(fd);
    printf("OBS {\"ret\":%ld,\"errno\":%d}\n",r,measured_errno(r,e));
    if(r<0&&(e==ENOSYS||e==EPERM)){errno=e;return unsupported_env("pidfd_send_signal");}
    return r==0?PASS:FAIL;
#else
    return SKIP;
#endif
}
static int clock_nanosleep_rawpast(void) {
    struct timespec current;
    if(clock_gettime(CLOCK_MONOTONIC_RAW,&current))return unsupported_env("read MONOTONIC_RAW");
    if(current.tv_sec==0&&current.tv_nsec<=1)return SKIP;
    struct timespec ts={0,1};errno=0;
    long r=syscall(SYS_clock_nanosleep,CLOCK_MONOTONIC_RAW,TIMER_ABSTIME,&ts,NULL);int e=errno;
    printf("OBS {\"ret\":%ld,\"errno\":%d}\n",r,measured_errno(r,e));
    return r==-1 && e==EOPNOTSUPP?PASS:FAIL;
}
static int inotify_rename_cookie(void) {
    char dir[]="./v2-inotify-XXXXXX";if(!mkdtemp(dir))return setup("mkdtemp");
    int d=open(dir,O_RDONLY|O_DIRECTORY);if(d<0)return setup("open directory");
    int f=openat(d,"old",O_CREAT|O_EXCL|O_RDWR,0600);if(f<0){close(d);return setup("create file");}close(f);
    int in=inotify_init1(IN_NONBLOCK|IN_CLOEXEC);if(in<0){close(d);return unsupported_env("inotify_init1");}
    int wd=inotify_add_watch(in,dir,IN_MOVED_FROM|IN_MOVED_TO);if(wd<0){close(in);close(d);return setup("inotify_add_watch");}
    if(renameat(d,"old",d,"new")){close(in);close(d);return setup("renameat");}
    struct pollfd p={.fd=in,.events=POLLIN};int ready=poll(&p,1,300);
    unsigned char buf[1024];uint32_t from=0,to=0;int nf=0,nt=0;size_t off=0;
    errno=0;ssize_t n=read(in,buf,sizeof(buf));int e=errno;
    if(n>0){while(off+sizeof(struct inotify_event)<=(size_t)n){
        struct inotify_event h;memcpy(&h,buf+off,sizeof(h));
        if(off+sizeof(h)+h.len>(size_t)n){close(in);close(d);return FAIL;}
        if(h.mask&IN_MOVED_FROM){from=h.cookie;nf++;}
        if(h.mask&IN_MOVED_TO){to=h.cookie;nt++;}
        off+=sizeof(h)+h.len;
    }}
    printf("DETAIL cookie_from=%u cookie_to=%u\n",from,to);
    printf("OBS {\"ready\":%d,\"from_count\":%d,\"to_count\":%d,\"cookies_nonzero_equal\":%s,\"errno\":%d}\n",
           ready,nf,nt,from!=0&&from==to?"true":"false",measured_errno(n,e));
    close(in);unlinkat(d,"new",0);close(d);rmdir(dir);
    return ready==1&&nf==1&&nt==1&&from!=0&&from==to?PASS:FAIL;
}
static int inotify_control_only(void) {
    int fd=inotify_init1(IN_NONBLOCK|IN_CLOEXEC);if(fd<0)return unsupported_env("inotify_init1");
    errno=0;int wd=inotify_add_watch(fd,".",IN_ONLYDIR);int e=errno;
    printf("OBS {\"accepted\":%s,\"errno\":%d}\n",wd>=0?"true":"false",measured_errno(wd,e));
    if(wd>=0)inotify_rm_watch(fd,wd);
    close(fd);
    /* Linux v6.18 accepts IN_ONLYDIR alone: ALL_INOTIFY_BITS includes controls.
     * This was a false-positive hypothesis; retain it as a negative control. */
    return wd>=0?PASS:FAIL;
}
static int tcp_dontwait(void) {
    int l,c,a;if(tcp_pair(&l,&c,&a,0,0)){int e=errno;close_tcp(l,c,a);errno=e;return unsupported_env("TCP setup");}
    struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=alarm_handler;sigemptyset(&sa.sa_mask);
    if(sigaction(SIGALRM,&sa,NULL)){close_tcp(l,c,a);return setup("sigaction");}
    alarm_seen=0;alarm(1);char b;double start=now();errno=0;
    ssize_t r=recv(a,&b,1,MSG_DONTWAIT);int e=errno;double elapsed=now()-start;alarm(0);
    printf("DETAIL elapsed=%.6f\n",elapsed);
    printf("OBS {\"ret\":%zd,\"errno\":%d,\"alarm_seen\":%d}\n",r,measured_errno(r,e),(int)alarm_seen);
    close_tcp(l,c,a);return r==-1&&e==EAGAIN&&!alarm_seen?PASS:FAIL;
}
static int tcp_sigpipe(void) {
    int l,c,a;if(tcp_pair(&l,&c,&a,0,0)){int e=errno;close_tcp(l,c,a);errno=e;return unsupported_env("TCP setup");}
    sigset_t set;sigemptyset(&set);sigaddset(&set,SIGPIPE);
    if(sigprocmask(SIG_BLOCK,&set,NULL)){close_tcp(l,c,a);return setup("block SIGPIPE");}
    struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=SIG_DFL;sigemptyset(&sa.sa_mask);
    if(sigaction(SIGPIPE,&sa,NULL)||shutdown(c,SHUT_WR)){close_tcp(l,c,a);return setup("shutdown");}
    errno=0;ssize_t r=send(c,"x",1,0);int e=errno;
    struct timespec zero={0};siginfo_t info;int sig=sigtimedwait(&set,&info,&zero);
    errno=0;ssize_t r2=send(c,"x",1,MSG_NOSIGNAL);int e2=errno;
    errno=0;int sig2=sigtimedwait(&set,&info,&zero);int e3=errno;
    printf("OBS {\"ret\":%zd,\"errno\":%d,\"sigpipe\":%s,\"nosignal_ret\":%zd,\"nosignal_errno\":%d,\"nosignal_suppressed\":%s}\n",
           r,measured_errno(r,e),sig==SIGPIPE?"true":"false",r2,measured_errno(r2,e2),sig2==-1&&e3==EAGAIN?"true":"false");
    close_tcp(l,c,a);return r==-1&&e==EPIPE&&sig==SIGPIPE&&r2==-1&&e2==EPIPE&&sig2==-1&&e3==EAGAIN?PASS:FAIL;
}
/* Negative controls / layer witnesses. These are NOT additional bug findings. */
static int libc_ppoll_timeout(void) {
    struct timespec ts={0,20000000};errno=0;int r=ppoll(NULL,0,&ts,NULL);int e=errno;
    printf("OBS {\"ret\":%d,\"errno\":%d,\"timeout_unchanged\":%s}\n",r,measured_errno(r,e),ts.tv_sec==0&&ts.tv_nsec==20000000?"true":"false");
    return r==0&&ts.tv_sec==0&&ts.tv_nsec==20000000?PASS:FAIL;
}
static int libc_clock_error(void) {
    struct timespec ts={0,1};errno=0;int r=clock_nanosleep(CLOCK_MONOTONIC_RAW,0,&ts,NULL);int e=errno;
    printf("OBS {\"library_ret\":%d,\"errno_after\":%d}\n",r,e);
    /* The error number is the return value. errno is observed, not asserted. */
    return r==EOPNOTSUPP?PASS:FAIL;
}
static int timerfd_copy_fault(void) {
    int fd=armed_timerfd();if(fd<0)return unsupported_env("armed_timerfd");
    if(await_timerfd(fd)){close(fd);return setup("initial timer expiration");}
    size_t page=(size_t)sysconf(_SC_PAGESIZE);
    void *p=mmap(NULL,page,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(p==MAP_FAILED){close(fd);return setup("guard page");}
    errno=0;long r=syscall(SYS_read,fd,p,8);int e=errno;
    uint64_t ticks=0;errno=0;ssize_t r2=read(fd,&ticks,8);int e2=errno;
    printf("OBS {\"first_ret\":%ld,\"first_errno\":%d,\"next_ret\":%zd,\"next_errno\":%d}\n",r,measured_errno(r,e),r2,measured_errno(r2,e2));
    munmap(p,page);close(fd);
    return r==-1&&e==EFAULT&&r2==-1&&e2==EAGAIN?PASS:FAIL;
}
static int utimens_both_omit(void) {
    struct timespec ts[2]={{0,UTIME_OMIT},{0,UTIME_OMIT}};errno=0;
    long r=syscall(SYS_utimensat,-1,NULL,ts,0);int e=errno;
    printf("OBS {\"ret\":%ld,\"errno\":%d}\n",r,measured_errno(r,e));return r==0?PASS:FAIL;
}
static int tcp_accept_flags(void) {
    int l,c,a;if(tcp_pair(&l,&c,&a,0,1)){int e=errno;close_tcp(l,c,a);errno=e;return unsupported_env("TCP setup");}
    int lf=fcntl(l,F_GETFL),af=fcntl(a,F_GETFL),df=fcntl(a,F_GETFD);
    if(lf<0||af<0||df<0){close_tcp(l,c,a);return setup("fcntl flags");}
    printf("OBS {\"listener_nonblock\":%s,\"accepted_nonblock\":%s,\"accepted_cloexec\":%s}\n",lf&O_NONBLOCK?"true":"false",af&O_NONBLOCK?"true":"false",df&FD_CLOEXEC?"true":"false");
    close_tcp(l,c,a);return (lf&O_NONBLOCK)&&!(af&O_NONBLOCK)&&!(df&FD_CLOEXEC)?PASS:FAIL;
}

struct test { const char *name; int (*fn)(void); };
static const struct test tests[]={

    {"path_bytes", path_bytes},
    {"datagram_writev", datagram_writev},
    {"datagram_readv", datagram_readv},
    {"pipe_readv_progress", pipe_readv_progress},
    {"nofile_limit", nofile_limit},
    {"select_large_nfds", select_large_nfds},
    {"select_short_bitmap", select_short_bitmap},
    {"select_timeout", select_timeout},
    {"ppoll_timeout", ppoll_timeout},
    {"rusage_null", rusage_null},
    {"rusage_accounting", rusage_accounting},
    {"sigchld_payload", sigchld_payload},
    {"madvise_dontfork", madvise_dontfork},
    {"madvise_free_shared", madvise_free_shared},
    {"pwritev2_append", pwritev2_append},
    {"tty_vtime", tty_vtime},
    {"tty_canonical_bytes", tty_canonical_bytes},
    {"tty_canonical_vmin", tty_canonical_vmin},
    {"tty_winsize_signal", tty_winsize_signal},
    {"timerfd_cpu_process", timerfd_cpu_process},
    {"timerfd_cpu_thread", timerfd_cpu_thread},
    {"timerfd_poll_drain", timerfd_poll_drain},
    {"timerfd_poll_disarm", timerfd_poll_disarm},
    {"timerfd_epoll_drain", timerfd_epoll_drain},
    {"posix_timer_payload", posix_timer_payload},
    {"timer_create_bad_signal", timer_create_bad_signal},
    {"pidfd_bad_signal", pidfd_bad_signal},
    {"utimens_preepoch", utimens_preepoch},
    {"utimes_preepoch", utimes_preepoch},
    {"tcp_accept_keepidle", tcp_accept_keepidle},
    {"pidfd_procdir", pidfd_procdir},
    {"clock_nanosleep_rawpast", clock_nanosleep_rawpast},
    {"inotify_rename_cookie", inotify_rename_cookie},
    {"inotify_control_only", inotify_control_only},
    {"tcp_dontwait", tcp_dontwait},
    {"tcp_sigpipe", tcp_sigpipe},
    {"libc_ppoll_timeout", libc_ppoll_timeout},
    {"libc_clock_error", libc_clock_error},
    {"timerfd_copy_fault", timerfd_copy_fault},
    {"utimens_both_omit", utimens_both_omit},
    {"tcp_accept_flags", tcp_accept_flags},
};
static int remove_owned(const char *path,const struct stat *st,int kind,struct FTW *f) {
    (void)st;(void)kind;(void)f;return remove(path);
}
static int run_case(const struct test *t) {
    char root[PATH_MAX];const char *tmp=getenv("TMPDIR");if(!tmp||!*tmp)tmp="/tmp";
    if(snprintf(root,sizeof(root),"%s/tlpi-abi-XXXXXX",tmp)>=(int)sizeof(root)){errno=ENAMETOOLONG;return setup("TMPDIR");}
    if(!mkdtemp(root))return setup("case directory");
    printf("CASE %s\n",t->name);
    pid_t p=fork();if(p<0){rmdir(root);return setup("harness fork");}
    if(!p){if(chdir(root))_exit(SETUP_ERROR);_exit(t->fn());}
    int status=0,code=SETUP_ERROR;double deadline=now()+5.0;
    for(;;){pid_t r=waitpid(p,&status,WNOHANG);
        if(r==p){code=WIFEXITED(status)?WEXITSTATUS(status):125;break;}
        if(r<0&&errno!=EINTR){perror("waitpid");kill(p,SIGKILL);while(waitpid(p,&status,0)<0&&errno==EINTR){}break;}
        if(now()>=deadline){kill(p,SIGKILL);while(waitpid(p,&status,0)<0&&errno==EINTR){}code=124;break;}
        struct timespec pause={0,10000000};nanosleep(&pause,NULL);
    }
    /* root was created by this invocation; FTW_PHYS prevents following symlinks. */
    if(nftw(root,remove_owned,16,FTW_DEPTH|FTW_PHYS))fprintf(stderr,"cleanup failed: %s\n",root);
    const char *s=code==PASS?"PASS":code==FAIL?"FAIL":code==SKIP?"SKIP":code==124?"TIMEOUT":code==125?"CRASH":"SETUP_ERROR";
    printf("RESULT\t%s\t%s\n",t->name,s);return code;
}
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IONBF,0);
    if(sizeof(void*)!=8){fputs("64-bit Linux ABI required\n",stderr);return 2;}
    if(argc==2&&!strcmp(argv[1],"--info")){
#ifdef __GLIBC__
        const char *libc=gnu_get_libc_version();
#else
        const char *libc="non-glibc (version not detected)";
#endif
        printf("{\"abi\":\"linux-x86_64\",\"pointer_bits\":%zu,\"page_size\":%ld,\"probe_libc\":\"%s\"}\n",sizeof(void*)*8,sysconf(_SC_PAGESIZE),libc);
        return 0;
    }
    if(argc>2){fprintf(stderr,"Usage: %s [case|--list]\n",argv[0]);return 2;}
    if(argc==2&&!strcmp(argv[1],"--list")){for(size_t i=0;i<sizeof(tests)/sizeof(tests[0]);i++)puts(tests[i].name);return 0;}
    if(argc==2){for(size_t i=0;i<sizeof(tests)/sizeof(tests[0]);i++)if(!strcmp(argv[1],tests[i].name))return run_case(&tests[i]);fputs("unknown case\n",stderr);return 2;}
    int bad=0;for(size_t i=0;i<sizeof(tests)/sizeof(tests[0]);i++){int r=run_case(&tests[i]);if(r!=PASS&&r!=SKIP)bad=1;}return bad;
}
