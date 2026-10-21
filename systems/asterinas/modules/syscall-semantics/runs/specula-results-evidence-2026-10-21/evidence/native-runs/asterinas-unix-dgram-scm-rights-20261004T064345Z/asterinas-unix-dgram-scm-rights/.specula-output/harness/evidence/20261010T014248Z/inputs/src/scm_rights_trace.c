/* SPDX-License-Identifier: MPL-2.0 */
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define main regression_main
#include "../common/test.h"
#undef main

static int instrumented, case_id, sockets[2], objects[2];
static int rights_count;
static pthread_barrier_t ready, go, finished;
static _Atomic int turn;
static _Atomic unsigned long long remote_tick;
static _Atomic unsigned long long start_tick;
static _Atomic int started, worker_cpu[2];
static int clock_partner;
static unsigned long long clock_period_fs;
static const char *layouts[] = { "Full",	"Null",		"Zero",
				 "Short",	"HeaderOnly",	"NoInteger",
				 "One",		"OnePadded",	"SpaceOne",
				 "FirstFault",	"LaterFault",	"PartialFault",
				 "HeaderFault", "HeaderPartial" };

static long ctl(int cmd, unsigned long a, unsigned long b, unsigned long c,
		unsigned long d)
{
	if (!instrumented)
		return 0;
	/* The private clock result needs all 64 bits. libc prctl returns an int. */
	return CHECK(syscall(SYS_prctl, 0x53504300 + cmd, a, b, c, d));
}

static uint64_t tick(void)
{
	if (instrumented)
		return ctl(4, 0, 0, 0, 0);
	struct timespec now;
	CHECK(clock_gettime(CLOCK_MONOTONIC, &now));
	return (uint64_t)now.tv_sec * 1000000000ULL + now.tv_nsec;
}

static int current_cpu(void)
{
	unsigned cpu;
	CHECK(syscall(SYS_getcpu, &cpu, NULL, NULL));
	return cpu;
}

struct call {
	unsigned char *mapping, *control, *payload;
	struct iovec iov;
	struct msghdr hdr;
	int layout, good, peek, attempt;
	long result;
	int error;
};

static void prepare(struct call *c, int layout, int good, int peek, int attempt)
{
	memset(c, 0, sizeof(*c));
	c->layout = layout;
	c->good = good;
	c->peek = peek;
	c->attempt = attempt;
	c->mapping = CHECK_WITH(mmap(NULL, 8192, PROT_READ | PROT_WRITE,
				     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
				_ret != MAP_FAILED);
	int demand_page = layout == 0 && (case_id == 17 || case_id == 18);
	memset(c->mapping, 0xa5, demand_page ? 4096 : 8192);
	c->control = c->mapping + 128;
	/* A writable demand page makes real publication work overlap more readily. */
	if (demand_page)
		c->control = c->mapping + 4096 - 16;
	size_t capacity = 16 + rights_count * sizeof(int);
	if (layout == 1)
		c->control = NULL;
	if (layout == 2)
		capacity = 0;
	if (layout == 3)
		capacity = 15;
	if (layout == 4)
		capacity = 16;
	if (layout == 5)
		capacity = 19;
	if (layout == 6)
		capacity = 20;
	if (layout == 7)
		capacity = 21;
	if (layout == 8)
		capacity = 24;
	int prefix = layout == 9  ? 16 :
		     layout == 10 ? 24 :
		     layout == 11 ? 26 :
		     layout == 13 ? 8 :
				    0;
	if (prefix) {
		c->control = c->mapping + 4096 - prefix;
		CHECK(mprotect(c->mapping + 4096, 4096, PROT_READ));
	}
	if (layout == 12) {
		c->control = c->mapping + 4096 - 16;
		CHECK(mprotect(c->mapping, 4096, PROT_READ));
	}
	c->payload = CHECK_WITH(mmap(NULL, 4096, PROT_READ | PROT_WRITE,
				     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
				_ret != MAP_FAILED);
	*c->payload = 0x5a;
	if (!good)
		CHECK(mprotect(c->payload, 4096, PROT_READ));
	c->iov = (struct iovec){ c->payload, 1 };
	c->hdr = (struct msghdr){ .msg_iov = &c->iov,
				  .msg_iovlen = 1,
				  .msg_control = c->control,
				  .msg_controllen = capacity };
}

static void receive(struct call *c)
{
	ctl(1, c->attempt, c->layout, c->good, c->peek);
	errno = 0;
	c->result = recvmsg(sockets[1], &c->hdr, c->peek ? MSG_PEEK : 0);
	c->error = errno;
}

static void report(struct call *c, int tid)
{
	printf("SCM_USER {\"case\":%d,\"tid\":%d,\"attempt\":%d,\"layout\":\"%s\","
	       "\"good\":%d,\"peek\":%d,\"return\":%ld,\"errno\":%d,\"length\":%zu,"
	       "\"flags\":%d,\"payload\":%u,\"bytes\":[",
	       case_id, tid, c->attempt, layouts[c->layout], c->good, c->peek,
	       c->result, c->error, c->hdr.msg_controllen, c->hdr.msg_flags,
	       *c->payload);
	for (int i = 0; c->control && i < 32; ++i)
		printf("%s%u", i ? "," : "", c->control[i]);
	puts("]}");
	CHECK(munmap(c->mapping, 8192));
	CHECK(munmap(c->payload, 4096));
}

struct worker {
	int tid, count;
	struct call calls[3];
};
static void *worker(void *arg)
{
	struct worker *w = arg;
	if (!instrumented && (case_id == 17 || case_id == 18)) {
		cpu_set_t available, selected;
		CHECK(sched_getaffinity(0, sizeof(available), &available));
		assert(CPU_COUNT(&available) >= 2);
		CPU_ZERO(&selected);
		int ordinal = 0;
		for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu)
			if (CPU_ISSET(cpu, &available) && ++ordinal == w->tid) {
				CPU_SET(cpu, &selected);
				break;
			}
		CHECK_WITH(pthread_setaffinity_np(pthread_self(), sizeof(selected), &selected),
			   _ret == 0);
	}
	atomic_store(&worker_cpu[w->tid - 1], current_cpu());
	atomic_fetch_add(&started, 1);
	/* Keep the first child runnable while the scheduler places the second. */
	while (atomic_load(&started) != 3) {
	}
	ctl(0, w->tid, objects[0], objects[1], case_id);
	pthread_barrier_wait(&ready);
	if (w->tid == clock_partner) {
		for (int i = 0; i < 128; ++i) {
			while (atomic_load(&turn) != 1) {
			}
			atomic_store(&remote_tick, tick());
			atomic_store(&turn, 2);
			while (atomic_load(&turn) == 2) {
			}
		}
	}
	pthread_barrier_wait(&go);
	while (tick() < atomic_load(&start_tick)) {
	}
	for (int i = 0; i < w->count; ++i)
		receive(&w->calls[i]);
	pthread_barrier_wait(&finished);
	/* All measured receives have finished before any thread prints. */
	if (w->tid == 2)
		while (atomic_load(&turn) != 3) {
		}
	for (int i = 0; i < w->count; ++i)
		report(&w->calls[i], w->tid);
	ctl(3, 0, 0, 0, 0);
	if (w->tid == 1)
		atomic_store(&turn, 3);
	return NULL;
}

static void one_case(int id)
{
	case_id = id;
	int competition = id == 17 || id == 18;
	/* Fixed empty-receive markers favor four rights in case 17. Case 18's
	 * two successful streams have their highest overlap bound with one. */
	rights_count = id == 18 ? 1 : 4;
	for (int fd = 3; fd < 128; ++fd)
		close(fd);
	CHECK(socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sockets));
	assert(sockets[0] == 3 && sockets[1] == 4);
	for (int i = 0; i < 2; ++i) {
		char name[80];
		snprintf(name, sizeof(name), "/tmp/scm-%d-%d", getpid(), i);
		objects[i] = CHECK(open(name, O_CREAT | O_RDWR | O_EXCL, 0600));
		CHECK(unlink(name));
		char marker = 'A' + i;
		CHECK(write(objects[i], &marker, 1));
		assert(objects[i] == 5 + i);
	}
	for (int fd = 0; fd < 64; ++fd)
		assert((fcntl(fd, F_GETFD) >= 0) == (fd < 7));
	printf("SCM_FIXTURE {\"case\":%d,\"setupFDCount\":5,\"maxFD\":63,\"rightsCount\":%d,"
	       "\"attemptSlots\":3,\"payloadSize\":1,\"headerBytes\":%zu,\"fdBytes\":%zu,"
	       "\"alignment\":%zu,\"implementation\":\"%s\"}\n",
	       id, rights_count, sizeof(struct cmsghdr), sizeof(int),
	       CMSG_SPACE(1) - CMSG_LEN(1) + 1,
	       instrumented ? "Asterinas" : "Linux");
	assert(sizeof(struct cmsghdr) == 16 && CMSG_LEN(4) == 20 &&
	       CMSG_SPACE(4) == 24);
	struct worker w[2] = { { .tid = 1 }, { .tid = 2 } };
	int layout = id >= 2 && id <= 14 ? id - 1 : 0;
	if (id != 19) {
		w[0].count = 1;
		prepare(&w[0].calls[0], layout, id != 20 && id != 21,
			id == 15 || id == 16 || id == 18 || id == 21, 1);
	}
	if (id == 15) {
		w[0].count = 3;
		prepare(&w[0].calls[1], 0, 1, 1, 2);
		prepare(&w[0].calls[2], 0, 1, 0, 3);
	}
	if (id == 16) {
		CHECK(munmap(w[0].calls[0].mapping, 8192));
		CHECK(munmap(w[0].calls[0].payload, 4096));
		prepare(&w[0].calls[0], 11, 1, 1, 1);
	}
	if (id == 16 || id == 20 || id == 21) {
		w[0].count = 2;
		prepare(&w[0].calls[1], 0, 1, 0, 2);
	}
	if (id == 17 || id == 18) {
		w[1].count = 1;
		prepare(&w[1].calls[0], 0, 1, 0, 1);
	}
	CHECK(pthread_barrier_init(&ready, NULL, 3));
	CHECK(pthread_barrier_init(&go, NULL, 3));
	CHECK(pthread_barrier_init(&finished, NULL, 2));
	atomic_store(&turn, 0);
	atomic_store(&started, 0);
	pthread_t threads[2];
	CHECK(pthread_create(&threads[0], NULL, worker, &w[0]));
	while (atomic_load(&started) != 1) {
	}
	CHECK(pthread_create(&threads[1], NULL, worker, &w[1]));
	while (atomic_load(&started) != 2) {
	}
	int main_cpu = current_cpu();
	int cpu1 = atomic_load(&worker_cpu[0]),
	    cpu2 = atomic_load(&worker_cpu[1]);
	assert(!(instrumented || competition) || cpu1 != cpu2);
	clock_partner = cpu1 != main_cpu ? 1 : 2;
	atomic_store(&started, 3);
	ctl(0, 0, objects[0], objects[1], id);
	clock_period_fs = instrumented ? ctl(5, 0, 0, 0, 0) : 1000000;
	pthread_barrier_wait(&ready);
	unsigned long long min_window = ~0ULL;
	unsigned long long samples[128][3];
	for (int i = 0; i < 128; ++i) {
		unsigned long long before = tick();
		atomic_store(&turn, 1);
		while (atomic_load(&turn) != 2) {
		}
		unsigned long long after = tick(),
				   other = atomic_load(&remote_tick);
		samples[i][0] = before;
		samples[i][1] = other;
		samples[i][2] = after;
		if (!(before <= other && other <= after))
			printf("SCM_CLOCK_FAILURE case=%d sample=%d before=%llu remote=%llu after=%llu\n",
			       id, i, before, other, after);
		assert(before <= other && other <= after);
		if (after - before < min_window)
			min_window = after - before;
		atomic_store(&turn, 0);
	}
	printf("SCM_CLOCK {\"case\":%d,\"samples\":128,\"source\":\"%s\",\"period_fs\":%llu,"
	       "\"minRoundTrip\":%llu,\"cpus\":[%d,%d,%d],\"exchanges\":[",
	       id, instrumented ? "HPET" : "CLOCK_MONOTONIC", clock_period_fs,
	       min_window, main_cpu, cpu1, cpu2);
	for (int i = 0; i < 128; ++i)
		printf("%s[%llu,%llu,%llu]", i ? "," : "", samples[i][0],
		       samples[i][1], samples[i][2]);
	puts("]}");
	unsigned char input[CMSG_SPACE(4 * sizeof(int))] = { 0 };
	char payload = 'x';
	char *bad = NULL;
	struct iovec iov = { &payload, 1 };
	if (id == 22) {
		bad = CHECK_WITH(mmap(NULL, 4096, PROT_NONE,
				      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
				 _ret != MAP_FAILED);
		iov.iov_base = bad;
	}
	struct msghdr msg = { .msg_iov = &iov,
			      .msg_iovlen = 1,
			      .msg_control = input,
			      .msg_controllen = CMSG_SPACE(rights_count * sizeof(int)) };
	struct cmsghdr *h = CMSG_FIRSTHDR(&msg);
	h->cmsg_level = SOL_SOCKET;
	h->cmsg_type = SCM_RIGHTS;
	h->cmsg_len = CMSG_LEN(rights_count * sizeof(int));
	int rights[4] = { 5, 6, 5, 6 };
	memcpy(CMSG_DATA(h), rights, rights_count * sizeof(int));
	ctl(1, 0, 0, id != 22, 0);
	errno = 0;
	long result = sendmsg(sockets[0], &msg, 0);
	int error = errno;
	assert(id == 22 ? result == -1 && error == EFAULT : result == 1);
	printf("SCM_SEND {\"case\":%d,\"return\":%ld,\"errno\":%d}\n", id,
	       result, error);
	if (id == 1) {
		CHECK(close(5));
		CHECK(dup2(6, 5));
	}
	if (id != 22) {
		if (id != 1)
			CHECK(close(5));
		CHECK(close(6));
	}
	unsigned long long window_start = competition ? tick() : 0;
	atomic_store(&start_tick, tick() + 10000000000000ULL / clock_period_fs);
	pthread_barrier_wait(&go);
	CHECK(pthread_join(threads[0], NULL));
	CHECK(pthread_join(threads[1], NULL));
	if (competition) {
		unsigned long long window_end = tick();
		printf("SCM_WINDOW {\"case\":%d,\"start\":%llu,\"end\":%llu}\n",
		       id, window_start, window_end);
	}
	printf("SCM_FDS {\"case\":%d,\"fds\":[", id);
	int comma = 0;
	for (int fd = 5; fd < 64; ++fd) {
		if (fcntl(fd, F_GETFD) < 0)
			continue;
		char value = 0;
		CHECK_WITH(pread(fd, &value, 1, 0), _ret == 1);
		assert(value == 'A' || value == 'B');
		printf("%s[%d,\"%c\"]", comma++ ? "," : "", fd, value);
	}
	puts("]}");
	ctl(2, 0, 0, 0, 0);
	for (int fd = 5; fd < 64; ++fd)
		if (fcntl(fd, F_GETFD) >= 0)
			CHECK(close(fd));
	CHECK(close(sockets[1]));
	CHECK(close(sockets[0]));
	ctl(3, 0, 0, 0, 0);
	if (bad)
		CHECK(munmap(bad, 4096));
	for (int fd = 3; fd < 64; ++fd)
		assert(fcntl(fd, F_GETFD) < 0 && errno == EBADF);
	printf("SCM_CASE_DONE {\"case\":%d}\n", id);
}

static int run_case(int id)
{
	pid_t child = CHECK(fork());
	if (!child) {
		one_case(id);
		_exit(0);
	}
	int status;
	CHECK(waitpid(child, &status, 0));
	return WIFEXITED(status) ? WEXITSTATUS(status) : 255;
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
	CHECK(uname(&name));
	instrumented = strcmp(name.sysname, "Linux") != 0;
#ifdef SCM_ASTERINAS
	instrumented = 1;
#endif
	printf("SCM_SYSTEM {\"sysname\":\"%s\",\"release\":\"%s\",\"version\":\"%s\",\"machine\":\"%s\"}\n",
	       name.sysname, name.release, name.version, name.machine);
}

FN_TEST(identity_and_capacity)
for (int id = 0; id <= 9; ++id)
	TEST_RES(run_case(id), _ret == 0);
END_TEST()

FN_TEST(control_faults)
for (int id = 10; id <= 14; ++id)
	TEST_RES(run_case(id), _ret == 0);
END_TEST()

FN_TEST(peek_and_competition)
for (int id = 15; id <= 18; ++id)
	TEST_RES(run_case(id), _ret == 0);
END_TEST()

FN_TEST(disposal_and_payload_faults)
for (int id = 19; id <= 22; ++id)
	TEST_RES(run_case(id), _ret == 0);
END_TEST()

int main(void)
{
	int status = regression_main();
	printf("SCM_DONE %d\n", status);
	if (getpid() == 1)
		reboot(RB_POWER_OFF);
	return status;
}
