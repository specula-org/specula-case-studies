/* SPDX-License-Identifier: MPL-2.0 */
//
// Reproduction test for finding CR-2:
//   "Scenario 2: Queue selection and ancillary completion have different orders"
//
// Hypothesized defect class (code review): the datagram queue serializes message
// identity and consumption under the queue mutex, but ancillary FD publication
// (file-table insert + fd-number copy) happens after the lock is released, so
// publications from an earlier PEEK and a later ordinary receive can interleave
// and break identity or consumption:
//   (a) message consumed twice;
//   (b) a PEEK publication delivering moved rights;
//   (c) stale rights published after consumption.
//
// This is a Level 0 black-box test: public APIs only (socketpair, open, write,
// sendmsg, recvmsg with MSG_PEEK, pread, close). Threads are pinned to distinct
// CPUs and their relative start offsets are swept across rounds; that is timing
// assistance only (Level 1 style staggering of real calls, no logic change).
//
// Variants:
//   V0 sequential peek -> recv -> peek on one message (deterministic check that
//      peek clones instead of moving rights and does not consume);
//   V1 racing PEEK (T1) vs ordinary recv (T2), the core CR-2 interleaving;
//   V2 two competing ordinary receivers (at-most-once consumption);
//   V3 four peeks racing one ordinary recv (peek copies outlive consumption);
//   V4 three-message queue under peek+recv storm (identity under load).
//
// Observable failure modes for the hypothesized defect:
//   - both ordinary receivers return the same message (consumed twice);
//   - a peek returns no SCM_RIGHTS, or a following ordinary receive loses its
//     rights (peek moved them);
//   - any received fd fails pread, reads the wrong marker byte, or the kernel
//     panics/hangs (stale/freed object behind a delivered fd);
//   - fd-count accounting differs from the expected installed set;
//   - MSG_CTRUNC or malformed cmsg headers on exactly-sized buffers.
//
// The sender closes its copies of the passed files right after sendmsg, so the
// receive queue owns the only references: a premature release by the
// peek/consume interleaving would leave a dead object behind a delivered fd.
//
// Output protocol (parsed by the runner):
//   CR2_SYS / CR2_VARIANT / CR2_FAIL / CR2_TRACE_WARN / CR2_DONE
// As PID 1 in the Asterinas initramfs the binary powers the machine off at the
// end; on Linux it exits with the failure count. On Asterinas the prctl trace
// interface (0x53504300..5) of the pinned instrumentation dumps per-thread
// kernel event timestamps (SCM_MAP/SCM_RAW lines) on instrumented V1 rounds;
// they are analyzed post-hoc to prove the selection/publication interleaving
// actually occurred while the properties held.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include <pthread.h>

#ifdef CR2_RIGHTS
#define RIGHTS_PER_MSG CR2_RIGHTS /* escalation builds widen the window */
#else
#define RIGHTS_PER_MSG 2
#endif
#define RIGHTS_OBJ_MOD 2 /* distinct objects behind the rights array */
#define MAX_PEEKS 6
#define MAX_RESULTS 16
#define MAX_FDS (MAX_RESULTS * RIGHTS_PER_MSG)
#define FD_SCAN_HI 64

static int instrumented, failures, trace_warns;
static int main_trace_on;
static int sv[2]; /* sv[0] sender, sv[1] receiver */
static int obj_fd[2];
static char marker[2] = { 'A', 'B' };

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
}

/* For libc/setup calls that return -1 and set errno. */
static void check(long ret, const char *what)
{
	if (ret < 0) {
		say("CR2_FATAL %s errno=%d (%s)", what, errno,
		    strerror(errno));
		_exit(9);
	}
}

/* For pthread calls that return an error code directly. */
static void check_rc(int rc, const char *what)
{
	if (rc != 0) {
		say("CR2_FATAL %s rc=%d", what, rc);
		_exit(9);
	}
}

static long ctl(int cmd, unsigned long a, unsigned long b, unsigned long c,
		unsigned long d)
{
	if (!instrumented)
		return 0;
	return syscall(SYS_prctl, 0x53504300 + cmd, a, b, c, d);
}

static atomic_int go, ready1, ready2;
static int cpu_of[2];

static int current_cpu(void)
{
	unsigned cpu;
	check(syscall(SYS_getcpu, &cpu, NULL, NULL), "getcpu");
	return (int)cpu;
}

static void pin_to_ordinal(int ordinal)
{
	cpu_set_t available, selected;
	int n = 0;
	if (sched_getaffinity(0, sizeof(available), &available) < 0)
		return;
	CPU_ZERO(&selected);
	for (int cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (CPU_ISSET(cpu, &available) && ++n == ordinal + 1) {
			CPU_SET(cpu, &selected);
			pthread_setaffinity_np(pthread_self(),
					       sizeof(selected), &selected);
			return;
		}
	}
}

struct result {
	long ret;
	int error;
	int nfds;
	int fds[RIGHTS_PER_MSG];
	char payload;
	size_t controllen;
	int trunc, level, type;
	size_t cmsg_len;
};

struct job {
	int tid, variant, round;
	int t1_peek; /* T1's receive mode: 1 = MSG_PEEK, 0 = consume */
	int peeks; /* how many receives T1 performs */
	int delay;
	int instrumented_round;
	struct result r[MAX_PEEKS];
	int ncalls;
	long ctl_dump;
};

/* Reads the caller's control buffer and validates one SCM_RIGHTS message. */
static int parse_result(struct result *r, unsigned char *control)
{
	struct cmsghdr *h = (struct cmsghdr *)control;
	r->level = h->cmsg_level;
	r->type = h->cmsg_type;
	r->cmsg_len = h->cmsg_len;
	if (r->ret < 0) {
		r->error = errno;
		return 0;
	}
	if (r->trunc || r->level != SOL_SOCKET || r->type != SCM_RIGHTS ||
	    r->cmsg_len != CMSG_LEN(RIGHTS_PER_MSG * sizeof(int)))
		return -1;
	memcpy(r->fds, CMSG_DATA(h), RIGHTS_PER_MSG * sizeof(int));
	r->nfds = RIGHTS_PER_MSG;
	return 0;
}

/* A delivered fd must name a live captured object with the right marker. */
static int fd_ok(int fd, int index, int round)
{
	char value = 0;
	long n = pread(fd, &value, 1, 0);
	if (n != 1) {
		say("CR2_FAIL round=%d fd=%d pread returned %ld errno=%d (dead object?)",
		    round, fd, n, errno);
		failures++;
		return 0;
	}
	if (value != marker[index % RIGHTS_OBJ_MOD]) {
		say("CR2_FAIL round=%d fd=%d marker '%c' expected '%c'", round,
		    fd, value, marker[index]);
		failures++;
		return 0;
	}
	return 1;
}

static int fds_distinct(struct result *rs, int nres, int round)
{
	int seen[MAX_FDS], n = 0;
	for (int i = 0; i < nres; i++)
		for (int j = 0; j < rs[i].nfds; j++) {
			if (rs[i].fds[j] < 5) {
				say("CR2_FAIL round=%d implausible fd %d",
				    round, rs[i].fds[j]);
				failures++;
				return 0;
			}
			for (int k = 0; k < n; k++)
				if (seen[k] == rs[i].fds[j]) {
					say("CR2_FAIL round=%d fd %d delivered twice across receives",
					    round, rs[i].fds[j]);
					failures++;
					return 0;
				}
			seen[n++] = rs[i].fds[j];
		}
	return 1;
}

/* Every fd in [5,FD_SCAN_HI) must be exactly the installed set, all valid. */
static int account_fds(struct result *rs, int nres, int round)
{
	int expected[MAX_FDS], n = 0;
	for (int i = 0; i < nres; i++)
		for (int j = 0; j < rs[i].nfds; j++)
			expected[n++] = rs[i].fds[j];
	for (int fd = 5; fd < FD_SCAN_HI; fd++) {
		int live = fcntl(fd, F_GETFD) >= 0;
		int wanted = 0;
		for (int k = 0; k < n; k++)
			if (expected[k] == fd)
				wanted = 1;
		if (live != wanted) {
			say("CR2_FAIL round=%d fd=%d live=%d expected=%d (accounting)",
			    round, fd, live, wanted);
			failures++;
			return 0;
		}
	}
	/* All delivered fds must still read the right markers. */
	for (int i = 0; i < nres; i++)
		for (int j = 0; j < rs[i].nfds; j++)
			if (!fd_ok(rs[i].fds[j], j, round))
				return 0;
	return 1;
}

static void close_delivered(struct result *rs, int nres)
{
	for (int i = 0; i < nres; i++)
		for (int j = 0; j < rs[i].nfds; j++)
			close(rs[i].fds[j]);
}

static void do_one_recv(struct result *r, int peek)
{
	unsigned char control[CMSG_SPACE(RIGHTS_PER_MSG * sizeof(int))] = { 0 };
	char payload = '?';
	struct iovec iov = { &payload, 1 };
	struct msghdr hdr = { .msg_iov = &iov,
			      .msg_iovlen = 1,
			      .msg_control = control,
			      .msg_controllen = sizeof(control) };
	memset(r, 0, sizeof(*r));
	r->ret = recvmsg(sv[1], &hdr, peek ? MSG_PEEK : 0);
	r->error = errno;
	r->payload = payload;
	r->controllen = hdr.msg_controllen;
	r->trunc = (hdr.msg_flags & MSG_CTRUNC) != 0;
	if (r->ret >= 0 && parse_result(r, control) < 0) {
		say("CR2_FAIL malformed cmsg ret=%ld trunc=%d level=%d type=%d len=%zu",
		    r->ret, r->trunc, r->level, r->type, r->cmsg_len);
		failures++;
	}
}

static void *worker(void *arg)
{
	struct job *w = arg;
	pin_to_ordinal(w->tid - 1);
	cpu_of[w->tid - 1] = current_cpu();
	if (w->tid == 1)
		atomic_store(&ready1, 1);
	else
		atomic_store(&ready2, 1);
	if (w->instrumented_round)
		/* Register this thread's kernel trace buffer for this round. */
		ctl(0, w->tid, obj_fd[0], obj_fd[1],
		    w->variant * 1000 + w->round);
	while (!atomic_load(&go))
		;
	for (volatile int i = 0; i < w->delay; i++)
		;
	int n = (w->tid == 1 && w->peeks > 0) ? w->peeks : 1;
	for (int i = 0; i < n; i++) {
		do_one_recv(&w->r[i], w->tid == 1 ? w->t1_peek : 0);
		if (i + 1 < n)
			for (volatile int d = 0; d < 50; d++)
				; /* small gap inside peek storms */
	}
	w->ncalls = n;
	if (w->instrumented_round)
		w->ctl_dump = ctl(3, 0, 0, 0, 0); /* dump + detach buffer */
	return NULL;
}

/* Opens the fixture: fresh socketpair and two marker files (fds stay open
 * so that trace registration can capture the object pointers). */
static void fixture_open(void)
{
	for (int fd = 3; fd < FD_SCAN_HI; fd++)
		close(fd);
	check(socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv),
	      "socketpair");
	for (int i = 0; i < 2; i++) {
		char name[64];
		snprintf(name, sizeof(name), "/tmp/cr2-%d-%d", (int)getpid(),
			 i);
		obj_fd[i] = open(name, O_CREAT | O_RDWR | O_EXCL, 0600);
		check(obj_fd[i], "open object");
		check(unlink(name), "unlink object");
		check(write(obj_fd[i], &marker[i], 1), "write marker");
	}
}

/* Sends nmessages SCM_RIGHTS datagrams, then drops the sender's copies so
 * the receive queue owns the only references. Registers the main trace
 * buffer first (needs the object fds open). */
static void fixture_send(int nmessages, long trace_case)
{
	unsigned char control[CMSG_SPACE(RIGHTS_PER_MSG * sizeof(int))] = { 0 };
	char payload = 'x';
	struct iovec iov = { &payload, 1 };
	struct msghdr msg = { .msg_iov = &iov,
			      .msg_iovlen = 1,
			      .msg_control = control,
			      .msg_controllen = sizeof(control) };
	struct cmsghdr *h = CMSG_FIRSTHDR(&msg);
	h->cmsg_level = SOL_SOCKET;
	h->cmsg_type = SCM_RIGHTS;
	h->cmsg_len = CMSG_LEN(RIGHTS_PER_MSG * sizeof(int));
	int rights[RIGHTS_PER_MSG];
	for (int i = 0; i < RIGHTS_PER_MSG; i++)
		rights[i] = obj_fd[i % RIGHTS_OBJ_MOD];
	memcpy(CMSG_DATA(h), rights, sizeof(rights));
	ctl(1, 0, 0, 1, 0);
	if (trace_case >= 0) {
		ctl(0, 0, obj_fd[0], obj_fd[1], trace_case);
		main_trace_on = 1;
	}
	for (int m = 0; m < nmessages; m++)
		check(sendmsg(sv[0], &msg, 0), "sendmsg");
	/* Drop the sender's copies: the queue owns the only references now. */
	close(obj_fd[0]);
	close(obj_fd[1]);
}

/*
 * Runs one racing round. Workers are created first so that their trace
 * registration (which needs the object fds open) happens before the sender
 * drops its copies; the sendmsg runs after both workers report ready, then
 * the race is released. t2_delay < 0 lets T2 lead by the swept amount;
 * t2_delay >= 0 pins T2's delay explicitly. Returns whether the workers
 * ended up on distinct CPUs.
 */
static int run_pair(int variant, int round, int t1_peek, int t1_peeks,
		    int t2_delay, int instr, int nmessages, struct job *j1,
		    struct job *j2)
{
	pthread_t th1, th2;
	memset(j1, 0, sizeof(*j1));
	memset(j2, 0, sizeof(*j2));
	j1->tid = 1;
	j2->tid = 2;
	j1->variant = j2->variant = variant;
	j1->round = j2->round = round;
	j1->t1_peek = t1_peek;
	j1->peeks = t1_peeks;
	j1->instrumented_round = j2->instrumented_round = instr;
	/* Alternate which thread leads and by how much (timing assistance). */
	j1->delay = (round % 2) ? ((round * 37) % 2000) : 0;
	j2->delay = t2_delay >= 0 ? t2_delay
				  : (round % 2 ? 0 : ((round * 53) % 2000));
	atomic_store(&go, 0);
	atomic_store(&ready1, 0);
	atomic_store(&ready2, 0);
	check_rc(pthread_create(&th1, NULL, worker, j1), "pthread_create 1");
	while (!atomic_load(&ready1))
		;
	check_rc(pthread_create(&th2, NULL, worker, j2), "pthread_create 2");
	while (!atomic_load(&ready2))
		;
	int ok_cpus = cpu_of[0] != cpu_of[1];
	fixture_send(nmessages, instr ? variant * 1000 + round : -1);
	atomic_store(&go, 1);
	check_rc(pthread_join(th1, NULL), "pthread_join 1");
	check_rc(pthread_join(th2, NULL), "pthread_join 2");
	return ok_cpus;
}

static void round_cleanup(void)
{
	/* The dump command (0x53504303) panics if no buffer is registered
	 * (scm_trace.rs:180 takes the buffer with unwrap), so only dump
	 * rounds whose fixture registered the main trace buffer. */
	if (main_trace_on) {
		ctl(2, 0, 0, 0, 0);
		ctl(3, 0, 0, 0, 0);
		main_trace_on = 0;
	}
	for (int fd = 3; fd < FD_SCAN_HI; fd++)
		close(fd);
}

/* ---------------- variants ---------------- */

static void v0_sequential(int rounds)
{
	for (int round = 0; round < rounds; round++) {
		fixture_open();
		fixture_send(1, -1);
		struct result r[3];
		do_one_recv(&r[0], 1); /* peek */
		do_one_recv(&r[1], 0); /* ordinary recv */
		do_one_recv(&r[2], 1); /* peek again: queue must be empty */
		if (r[0].ret != 1 || r[0].nfds != RIGHTS_PER_MSG ||
		    r[0].payload != 'x')
			say("CR2_FAIL round=%d V0 peek ret=%ld nfds=%d payload=%c",
			    round, r[0].ret, r[0].nfds, r[0].payload),
			    failures++;
		if (r[1].ret != 1 || r[1].nfds != RIGHTS_PER_MSG ||
		    r[1].payload != 'x')
			say("CR2_FAIL round=%d V0 recv after peek lost rights: ret=%ld nfds=%d (peek moved them?)",
			    round, r[1].ret, r[1].nfds),
			    failures++;
		if (r[2].ret != -1 || r[2].error != EAGAIN)
			say("CR2_FAIL round=%d V0 second peek ret=%ld errno=%d (peek consumed?)",
			    round, r[2].ret, r[2].error),
			    failures++;
		struct result live[2] = { r[0], r[1] };
		fds_distinct(live, 2, round);
		account_fds(live, 2, round);
		struct result extra;
		do_one_recv(&extra, 0);
		if (extra.ret != -1 || extra.error != EAGAIN)
			say("CR2_FAIL round=%d V0 message consumed twice: extra ret=%ld",
			    round, extra.ret),
			    failures++;
		close_delivered(live, 2);
		round_cleanup();
	}
	say("CR2_VARIANT V0 rounds=%d", rounds);
}

static void v1_peek_vs_recv(int rounds, int period)
{
	int both = 0, recv_only = 0, same_cpu = 0;
	for (int round = 0; round < rounds; round++) {
		int instr = round % period == 0;
		fixture_open();
		struct job j1, j2;
		if (!run_pair(1, round, 1, 0, -1, instr, 1, &j1, &j2))
			same_cpu++;
		if (instr && (j1.ctl_dump < 0 || j2.ctl_dump < 0)) {
			trace_warns++;
			say("CR2_TRACE_WARN round=%d dump1=%ld dump2=%ld",
			    round, j1.ctl_dump, j2.ctl_dump);
		}
		struct result *pk = &j1.r[0], *rc = &j2.r[0];
		if (rc->ret == 1) {
			if (rc->nfds != RIGHTS_PER_MSG || rc->payload != 'x')
				say("CR2_FAIL round=%d V1 recv malformed ret=%ld nfds=%d payload=%c",
				    round, rc->ret, rc->nfds, rc->payload),
				    failures++;
		} else if (rc->ret != -1 || rc->error != EAGAIN) {
			say("CR2_FAIL round=%d V1 recv ret=%ld errno=%d",
			    round, rc->ret, rc->error),
			    failures++;
		}
		if (pk->ret == 1) {
			if (pk->nfds != RIGHTS_PER_MSG || pk->payload != 'x')
				say("CR2_FAIL round=%d V1 peek malformed ret=%ld nfds=%d payload=%c",
				    round, pk->ret, pk->nfds, pk->payload),
				    failures++;
		} else if (!(rc->ret == 1 && pk->error == EAGAIN)) {
			/* Peek may only fail with EAGAIN after consumption. */
			say("CR2_FAIL round=%d V1 peek failed while message unconsumed: ret=%ld errno=%d (recv ret=%ld)",
			    round, pk->ret, pk->error, rc->ret),
			    failures++;
		}
		if (rc->ret == 1 && pk->ret == 1)
			both++; /* the CR-2 interleaving window was hit */
		if (rc->ret == 1 && pk->ret != 1)
			recv_only++;
		struct result live[3];
		int n = 0;
		if (pk->ret == 1)
			live[n++] = *pk;
		if (rc->ret == 1)
			live[n++] = *rc;
		if (n) {
			fds_distinct(live, n, round);
			account_fds(live, n, round);
		}
		struct result extra;
		do_one_recv(&extra, 0);
		if (rc->ret == 1) {
			if (extra.ret != -1 || extra.error != EAGAIN)
				say("CR2_FAIL round=%d V1 message consumed twice: extra ret=%ld",
				    round, extra.ret),
				    failures++;
		} else if (extra.ret != 1 || extra.nfds != RIGHTS_PER_MSG) {
			say("CR2_FAIL round=%d V1 follow-up lost after peek-only round: ret=%ld",
			    round, extra.ret),
			    failures++;
		} else {
			live[n++] = extra;
			fds_distinct(live, n, round);
		}
		close_delivered(live, n);
		round_cleanup();
	}
	say("CR2_VARIANT V1 rounds=%d both_delivered=%d recv_only=%d same_cpu=%d",
	    rounds, both, recv_only, same_cpu);
}

static void v2_recv_vs_recv(int rounds)
{
	int exactly_one = 0;
	for (int round = 0; round < rounds; round++) {
		fixture_open();
		struct job j1, j2;
		/* Both threads are ordinary receivers. */
		run_pair(2, round, 0, 0, -1, 0, 1, &j1, &j2);
		struct result *a = &j1.r[0], *b = &j2.r[0];
		int wins = (a->ret == 1) + (b->ret == 1);
		if (wins != 1) {
			say("CR2_FAIL round=%d V2 at-most-once violated: wins=%d (a=%ld b=%ld)",
			    round, wins, a->ret, b->ret),
			    failures++;
		} else {
			exactly_one++;
			struct result *win = a->ret == 1 ? a : b;
			struct result live[1] = { *win };
			if (win->nfds != RIGHTS_PER_MSG ||
			    win->payload != 'x') {
				say("CR2_FAIL round=%d V2 winner malformed ret=%ld nfds=%d",
				    round, win->ret, win->nfds),
				    failures++;
			}
			fds_distinct(live, 1, round);
			account_fds(live, 1, round);
			struct result extra;
			do_one_recv(&extra, 0);
			if (extra.ret != -1 || extra.error != EAGAIN)
				say("CR2_FAIL round=%d V2 message consumed twice: extra ret=%ld",
				    round, extra.ret),
				    failures++;
			close_delivered(live, 1);
		}
		round_cleanup();
	}
	say("CR2_VARIANT V2 rounds=%d exactly_one=%d", rounds, exactly_one);
}

static void v3_peek_storm(int rounds)
{
	for (int round = 0; round < rounds; round++) {
		fixture_open();
		struct job j1, j2;
		run_pair(3, round, 1, 4, 0, 0, 1, &j1, &j2); /* T2 starts first */
		struct result *rc = &j2.r[0];
		if (rc->ret != 1 || rc->nfds != RIGHTS_PER_MSG ||
		    rc->payload != 'x')
			say("CR2_FAIL round=%d V3 recv ret=%ld nfds=%d",
			    round, rc->ret, rc->nfds),
			    failures++;
		struct result live[1 + MAX_PEEKS];
		int n = 0;
		if (rc->ret == 1)
			live[n++] = *rc;
		for (int i = 0; i < j1.ncalls; i++) {
			struct result *pk = &j1.r[i];
			if (pk->ret == 1) {
				if (pk->nfds != RIGHTS_PER_MSG ||
				    pk->payload != 'x')
					say("CR2_FAIL round=%d V3 peek[%d] ret=%ld nfds=%d",
					    round, i, pk->ret, pk->nfds),
					    failures++;
				live[n++] = *pk;
			} else if (pk->ret != -1 || pk->error != EAGAIN) {
				say("CR2_FAIL round=%d V3 peek[%d] errno=%d",
				    round, i, pk->error),
				    failures++;
			}
		}
		/* Peek-installed fds are validated after consumption completed:
		 * a stale/moved reference would fail pread here. */
		fds_distinct(live, n, round);
		account_fds(live, n, round);
		struct result extra;
		do_one_recv(&extra, 0);
		if (extra.ret != -1 || extra.error != EAGAIN)
			say("CR2_FAIL round=%d V3 consumed twice: extra ret=%ld",
			    round, extra.ret),
			    failures++;
		close_delivered(live, n);
		round_cleanup();
	}
	say("CR2_VARIANT V3 rounds=%d", rounds);
}

static void v4_multi_message(int rounds)
{
	for (int round = 0; round < rounds; round++) {
		fixture_open();
		struct job j1, j2;
		/* T2 consumes one message; T1 peeks (bounded so every delivered fd
		 * stays inside the scanned fd range). */
		int v4_peeks = 6;
		if ((FD_SCAN_HI - 6) / RIGHTS_PER_MSG < 9)
			v4_peeks = (FD_SCAN_HI - 6) / RIGHTS_PER_MSG - 3;
		run_pair(4, round, 1, v4_peeks, 0, 0, 3, &j1, &j2);
		int consumed = 0;
		struct result live[MAX_RESULTS];
		int n = 0;
		if (j2.r[0].ret == 1) {
			consumed++;
			live[n++] = j2.r[0];
		}
		for (int i = 0; i < j1.ncalls; i++)
			if (j1.r[i].ret == 1)
				live[n++] = j1.r[i];
		for (;;) {
			struct result r;
			do_one_recv(&r, 0);
			if (r.ret == -1 && r.error == EAGAIN)
				break;
			if (r.ret != 1 || r.nfds != RIGHTS_PER_MSG) {
				say("CR2_FAIL round=%d V4 drain ret=%ld nfds=%d",
				    round, r.ret, r.nfds),
				    failures++;
				break;
			}
			consumed++;
			if (n < MAX_RESULTS)
				live[n++] = r;
			if (consumed > 3)
				break;
		}
		if (consumed != 3)
			say("CR2_FAIL round=%d V4 identity: consumed=%d expected 3 (double or lost consumption)",
			    round, consumed),
			    failures++;
		for (int i = 0; i < n; i++)
			if (live[i].ret == 1 && live[i].payload != 'x')
				say("CR2_FAIL round=%d V4 payload %c", round,
				    live[i].payload),
				    failures++;
		fds_distinct(live, n, round);
		account_fds(live, n, round);
		close_delivered(live, n);
		round_cleanup();
	}
	say("CR2_VARIANT V4 rounds=%d", rounds);
}

static void bootstrap(void) __attribute__((constructor(150)));
static void bootstrap(void)
{
	if (getpid() == 1) {
		mkdir("/dev", 0755);
		mkdir("/tmp", 0755);
		mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
		int fd = open("/dev/console", O_RDWR);
		if (fd >= 0) {
			for (int i = 0; i < 3; ++i)
				dup2(fd, i);
			if (fd > 2)
				close(fd);
		}
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	struct utsname name;
	check(uname(&name), "uname");
	instrumented = strcmp(name.sysname, "Linux") != 0;
#ifdef SCM_ASTERINAS
	/* Asterinas reports itself as Linux; the build flag selects the trace
	 * control interface of the pinned instrumentation. */
	instrumented = 1;
#endif
	say("CR2_SYS {\"sysname\":\"%s\",\"release\":\"%s\",\"instrumented\":%d}",
	    name.sysname, name.release, instrumented);
}

int main(void)
{
	time_t t0 = time(NULL);
	v0_sequential(20);
	v1_peek_vs_recv(240, 20);
	v2_recv_vs_recv(160);
	v3_peek_storm(120);
	v4_multi_message(60);
	int dt = (int)(time(NULL) - t0);
	say("CR2_DONE %d (failures=%d trace_warns=%d seconds=%d)", failures,
	    failures, trace_warns, dt);
	if (getpid() == 1)
		reboot(RB_POWER_OFF);
	return failures ? 1 : 0;
}
