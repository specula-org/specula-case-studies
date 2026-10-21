// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#define PAGE_BYTES 4096
#define COMPLETE_BYTES (2 * PAGE_BYTES)
#define TARGET_FD 3

enum scenario {
	SCENARIO_RAMFS_NORMAL,
	SCENARIO_RAMFS_FAULTS,
	SCENARIO_RAMFS_ZERO_APPEND,
	SCENARIO_EXT2_BUFFERED,
	SCENARIO_EXT2_DIRECT,
	SCENARIO_OVERLAP_PREFIX,
	SCENARIO_REFERENCE_RESTART,
};

struct fault_buffer {
	void *mapping;
	size_t mapping_len;
	char *ptr;
};

static pthread_barrier_t phase_barrier;
static pthread_t actor_threads[2];
static enum scenario selected_scenario;
static char *valid_buffers[2];
static struct fault_buffer fault_zero[2];
static struct fault_buffer fault_after_page[2];
static struct fault_buffer fault_after_prefix[2];

static __attribute__((noreturn)) void fail(int code)
{
	_exit(code);
}

static void require(int condition, int code)
{
	if (!condition)
		fail(code);
}

static void pin_to_cpu(int cpu, int code)
{
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	require(sched_setaffinity(0, sizeof(set), &set) == 0, code);
}

static void wait_phase(int code)
{
	int ret = pthread_barrier_wait(&phase_barrier);

	require(ret == 0 || ret == PTHREAD_BARRIER_SERIAL_THREAD, code);
}

#define ACTOR_PHASE(actor, selected, code, operation) \
	do { \
		wait_phase(code); \
		if ((actor) == (selected)) { \
			operation; \
		} \
		wait_phase((code) + 1); \
	} while (0)

static char *alloc_aligned_buffer(unsigned char fill, int code)
{
	void *buffer = NULL;

	require(posix_memalign(&buffer, PAGE_BYTES, COMPLETE_BYTES) == 0, code);
	memset(buffer, fill, COMPLETE_BYTES);
	return buffer;
}

static struct fault_buffer alloc_fault_buffer(int kind, unsigned char fill,
					       int code)
{
	struct fault_buffer result = {
		.mapping_len = 3 * PAGE_BYTES,
	};

	result.mapping = mmap(NULL, result.mapping_len, PROT_READ | PROT_WRITE,
			      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	require(result.mapping != MAP_FAILED, code);
	memset(result.mapping, fill, result.mapping_len);
	if (kind == 0) {
		require(mprotect(result.mapping, PAGE_BYTES, PROT_NONE) == 0,
			code + 1);
		result.ptr = result.mapping;
	} else if (kind == 1) {
		require(mprotect((char *)result.mapping + PAGE_BYTES, PAGE_BYTES,
				 PROT_NONE) == 0,
			code + 1);
		result.ptr = result.mapping;
	} else {
		require(mprotect((char *)result.mapping + PAGE_BYTES,
				 2 * PAGE_BYTES, PROT_NONE) == 0,
			code + 1);
		result.ptr = (char *)result.mapping + PAGE_BYTES - 128;
	}
	return result;
}

static void allocate_buffers(void)
{
	for (int actor = 0; actor < 2; actor++) {
		valid_buffers[actor] = alloc_aligned_buffer(0x31 + actor, 20 + actor);
		fault_zero[actor] = alloc_fault_buffer(0, 0x41 + actor, 30 + actor * 10);
		fault_after_page[actor] =
			alloc_fault_buffer(1, 0x51 + actor, 50 + actor * 10);
		fault_after_prefix[actor] =
			alloc_fault_buffer(2, 0x61 + actor, 70 + actor * 10);
	}
}

static void install_target_fd(int fd, int code)
{
	if (fd != TARGET_FD) {
		require(dup2(fd, TARGET_FD) == TARGET_FD, code);
		require(close(fd) == 0, code + 1);
	}
	require(lseek(TARGET_FD, 0, SEEK_SET) == 0, code + 2);
	struct stat st;
	require(fstat(TARGET_FD, &st) == 0, code + 3);
	require(st.st_size == COMPLETE_BYTES, code + 4);
}

static void setup_ramfs_target(void)
{
	const char *path = "/specula-regular-file";

	unlink(path);
	int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
	require(fd >= 0, 100);
	require(pwrite(fd, valid_buffers[0], COMPLETE_BYTES, 0) ==
			COMPLETE_BYTES,
		101);
	install_target_fd(fd, 102);
}

static void setup_ext2_target(int direct)
{
	const char *target = "/ext2/specula-regular-file";
	const char *spacer = "/ext2/specula-regular-file-spacer";

	unlink(target);
	unlink(spacer);
	int fd = open(target, O_CREAT | O_TRUNC | O_RDWR | O_DIRECT, 0600);
	require(fd >= 0, 110);
	require(pwrite(fd, valid_buffers[0], PAGE_BYTES, 0) == PAGE_BYTES, 111);
	int spacer_fd = open(spacer, O_CREAT | O_TRUNC | O_RDWR | O_DIRECT,
			     0600);
	require(spacer_fd >= 0, 112);
	require(pwrite(spacer_fd, valid_buffers[0], PAGE_BYTES, 0) ==
			PAGE_BYTES,
		113);
	require(close(spacer_fd) == 0, 114);
	require(pwrite(fd, valid_buffers[0], PAGE_BYTES, PAGE_BYTES) ==
			PAGE_BYTES,
		115);
	require(close(fd) == 0, 116);

	fd = open(target, O_RDWR | (direct ? O_DIRECT : 0));
	require(fd >= 0, 117);
	install_target_fd(fd, 118);
}

static enum scenario parse_scenario(const char *name)
{
	if (strcmp(name, "ramfs_normal") == 0)
		return SCENARIO_RAMFS_NORMAL;
	if (strcmp(name, "ramfs_faults") == 0)
		return SCENARIO_RAMFS_FAULTS;
	if (strcmp(name, "ramfs_zero_append") == 0)
		return SCENARIO_RAMFS_ZERO_APPEND;
	if (strcmp(name, "ext2_buffered") == 0)
		return SCENARIO_EXT2_BUFFERED;
	if (strcmp(name, "ext2_direct") == 0)
		return SCENARIO_EXT2_DIRECT;
	if (strcmp(name, "overlap_prefix") == 0)
		return SCENARIO_OVERLAP_PREFIX;
	if (strcmp(name, "reference_restart") == 0)
		return SCENARIO_REFERENCE_RESTART;
	fail(130);
}

static const char *control_name(enum scenario scenario)
{
	switch (scenario) {
	case SCENARIO_RAMFS_NORMAL:
	case SCENARIO_RAMFS_FAULTS:
	case SCENARIO_RAMFS_ZERO_APPEND:
		return "sp-ram-t0";
	case SCENARIO_EXT2_BUFFERED:
		return "sp-buf-t0";
	case SCENARIO_EXT2_DIRECT:
		return "sp-dir-t0";
	case SCENARIO_OVERLAP_PREFIX:
		return "sp-ovl-t0";
	case SCENARIO_REFERENCE_RESTART:
		return "sp-ref-t0";
	}
	fail(131);
}

static void expect_efault(ssize_t result, int code)
{
	require(result == -1 && errno == EFAULT, code);
}

static void run_ramfs_normal(int actor)
{
	struct iovec read_iov[2] = {
		{ .iov_base = valid_buffers[0], .iov_len = COMPLETE_BYTES },
		{ .iov_base = valid_buffers[0], .iov_len = COMPLETE_BYTES },
	};
	struct iovec write_iov[2] = {
		{ .iov_base = valid_buffers[1], .iov_len = COMPLETE_BYTES },
		{ .iov_base = valid_buffers[1], .iov_len = COMPLETE_BYTES },
	};

	ACTOR_PHASE(actor, 0, 200,
		require(readv(TARGET_FD, read_iov, 2) == COMPLETE_BYTES, 202));
	ACTOR_PHASE(actor, 1, 204,
		require(writev(TARGET_FD, write_iov, 2) ==
				2 * COMPLETE_BYTES,
			206));
	ACTOR_PHASE(actor, 0, 208,
		require(pread(TARGET_FD, valid_buffers[0], COMPLETE_BYTES, 0) ==
				COMPLETE_BYTES,
			210));
	ACTOR_PHASE(actor, 1, 212,
		require(pwrite(TARGET_FD, valid_buffers[1], COMPLETE_BYTES, 0) ==
				COMPLETE_BYTES,
			214));
	ACTOR_PHASE(actor, 0, 216,
		require(read(TARGET_FD, valid_buffers[0], COMPLETE_BYTES) == 0,
			218));
	ACTOR_PHASE(actor, 1, 220,
		require(write(TARGET_FD, valid_buffers[1], COMPLETE_BYTES) ==
				COMPLETE_BYTES,
			222));
}

static void run_ramfs_faults(int actor)
{
	struct iovec read_iov[2] = {
		{ .iov_base = valid_buffers[0], .iov_len = COMPLETE_BYTES },
		{ .iov_base = fault_after_page[0].ptr,
		  .iov_len = COMPLETE_BYTES },
	};
	struct iovec write_iov[2] = {
		{ .iov_base = valid_buffers[0], .iov_len = COMPLETE_BYTES },
		{ .iov_base = fault_after_page[0].ptr,
		  .iov_len = COMPLETE_BYTES },
	};

	ACTOR_PHASE(actor, 0, 230,
		require(pwrite(TARGET_FD, valid_buffers[0], COMPLETE_BYTES,
			       COMPLETE_BYTES) == COMPLETE_BYTES,
			232));
	ACTOR_PHASE(actor, 0, 234,
		require(readv(TARGET_FD, read_iov, 2) == COMPLETE_BYTES, 236));
	ACTOR_PHASE(actor, 1, 238,
		expect_efault(read(TARGET_FD, fault_zero[1].ptr,
				  COMPLETE_BYTES),
			240));
	ACTOR_PHASE(actor, 1, 242,
		expect_efault(pwrite(TARGET_FD, fault_after_page[1].ptr,
				   COMPLETE_BYTES, 0),
			244));
	ACTOR_PHASE(actor, 0, 246,
		require(writev(TARGET_FD, write_iov, 2) == COMPLETE_BYTES,
			248));
	ACTOR_PHASE(actor, 1, 250,
		expect_efault(write(TARGET_FD, fault_zero[1].ptr,
				   COMPLETE_BYTES),
			252));
}

static void run_ramfs_zero_append(int actor)
{
	ACTOR_PHASE(actor, 0, 260,
		require(pwrite(TARGET_FD, valid_buffers[0], 0,
			       4 * PAGE_BYTES) == 0,
			262));
	ACTOR_PHASE(actor, 0, 264, {
		int flags = fcntl(TARGET_FD, F_GETFL);
		require(flags >= 0, 266);
		require(fcntl(TARGET_FD, F_SETFL, flags | O_APPEND) == 0, 267);
	});
	ACTOR_PHASE(actor, 1, 268,
		expect_efault(write(TARGET_FD, fault_zero[1].ptr,
				   COMPLETE_BYTES),
			270));
}

static void run_ext2_buffered(int actor)
{
	ACTOR_PHASE(actor, 0, 280,
		expect_efault(pwrite(TARGET_FD, fault_after_prefix[0].ptr,
				   COMPLETE_BYTES, 0),
			282));
	ACTOR_PHASE(actor, 0, 284,
		expect_efault(pwrite(TARGET_FD, fault_after_page[0].ptr,
				   COMPLETE_BYTES, 0),
			286));
	ACTOR_PHASE(actor, 1, 288,
		expect_efault(pwrite(TARGET_FD, fault_zero[1].ptr,
				   COMPLETE_BYTES, COMPLETE_BYTES),
			290));
	ACTOR_PHASE(actor, 0, 292,
		require(pwrite(TARGET_FD, valid_buffers[0], COMPLETE_BYTES, 0) ==
				COMPLETE_BYTES,
			294));
	ACTOR_PHASE(actor, 1, 296,
		expect_efault(pread(TARGET_FD, fault_after_page[1].ptr,
				  COMPLETE_BYTES, 0),
			298));
	ACTOR_PHASE(actor, 1, 300,
		expect_efault(pread(TARGET_FD, fault_zero[1].ptr,
				  COMPLETE_BYTES, 0),
			302));
	ACTOR_PHASE(actor, 0, 304,
		require(read(TARGET_FD, valid_buffers[0], COMPLETE_BYTES) ==
				COMPLETE_BYTES,
			306));
	ACTOR_PHASE(actor, 1, 308,
		require(write(TARGET_FD, valid_buffers[1], 0) == 0, 310));
}

static void run_ext2_direct(int actor)
{
	ACTOR_PHASE(actor, 0, 320,
		require(pwrite(TARGET_FD, valid_buffers[0], COMPLETE_BYTES, 0) ==
				COMPLETE_BYTES,
			322));
	ACTOR_PHASE(actor, 1, 324,
		expect_efault(pread(TARGET_FD, fault_after_page[1].ptr,
				  COMPLETE_BYTES, 0),
			326));
	ACTOR_PHASE(actor, 0, 328,
		require(pread(TARGET_FD, valid_buffers[0], COMPLETE_BYTES, 0) ==
				COMPLETE_BYTES,
			330));
	ACTOR_PHASE(actor, 1, 332,
		expect_efault(pread(TARGET_FD, fault_zero[1].ptr,
				  COMPLETE_BYTES, 0),
			334));
	ACTOR_PHASE(actor, 0, 336,
		expect_efault(pwrite(TARGET_FD, fault_after_prefix[0].ptr,
				   COMPLETE_BYTES, 0),
			338));
	ACTOR_PHASE(actor, 0, 340, {
		expect_efault(pwrite(TARGET_FD, fault_after_page[0].ptr,
				   COMPLETE_BYTES, 0),
			342);
		usleep(20000);
	});
	ACTOR_PHASE(actor, 1, 344,
		require(write(TARGET_FD, valid_buffers[1], 0) == 0, 346));
}

static void run_overlap_prefix(int actor)
{
	wait_phase(350);
	ssize_t result = read(TARGET_FD, valid_buffers[actor], COMPLETE_BYTES);
	require(result == 0 || result == COMPLETE_BYTES, 351 + actor);
	wait_phase(354);
}

static void signal_handler(int signal_number)
{
	(void)signal_number;
}

static void install_signal_handler(int restart, int code)
{
	struct sigaction action = {
		.sa_handler = signal_handler,
		.sa_flags = restart ? SA_RESTART : 0,
	};
	require(sigemptyset(&action.sa_mask) == 0, code);
	require(sigaction(SIGUSR1, &action, NULL) == 0, code + 1);
}

static void run_reference_restart(int actor)
{
	ACTOR_PHASE(actor, 1, 360, install_signal_handler(0, 362));
	wait_phase(364);
	if (actor == 1) {
		errno = 0;
		ssize_t result = read(TARGET_FD, valid_buffers[1], COMPLETE_BYTES);
		require(result == -1 && errno == EINTR, 365);
	} else {
		usleep(1000);
		require(pthread_kill(actor_threads[1], SIGUSR1) == 0, 366);
	}
	wait_phase(367);

	ACTOR_PHASE(actor, 0, 368, install_signal_handler(1, 370));
	wait_phase(372);
	if (actor == 0) {
		require(write(TARGET_FD, valid_buffers[0], COMPLETE_BYTES) ==
				COMPLETE_BYTES,
			373);
	} else {
		usleep(1000);
		require(pthread_kill(actor_threads[0], SIGUSR1) == 0, 374);
	}
	wait_phase(375);
}

static void run_actor(int actor)
{
	switch (selected_scenario) {
	case SCENARIO_RAMFS_NORMAL:
		run_ramfs_normal(actor);
		break;
	case SCENARIO_RAMFS_FAULTS:
		run_ramfs_faults(actor);
		break;
	case SCENARIO_RAMFS_ZERO_APPEND:
		run_ramfs_zero_append(actor);
		break;
	case SCENARIO_EXT2_BUFFERED:
		run_ext2_buffered(actor);
		break;
	case SCENARIO_EXT2_DIRECT:
		run_ext2_direct(actor);
		break;
	case SCENARIO_OVERLAP_PREFIX:
		run_overlap_prefix(actor);
		break;
	case SCENARIO_REFERENCE_RESTART:
		run_reference_restart(actor);
		break;
	}
}

static void *actor_two(void *unused)
{
	(void)unused;
	pin_to_cpu(1, 400);
	actor_threads[1] = pthread_self();
	require(prctl(PR_SET_NAME, "sp-io-t1", 0, 0, 0) == 0, 401);
	wait_phase(402);
	run_actor(1);
	wait_phase(403);
	return NULL;
}

int main(int argc, char **argv)
{
	require(argc == 2, 1);
	selected_scenario = parse_scenario(argv[1]);
	pin_to_cpu(0, 2);
	actor_threads[0] = pthread_self();
	allocate_buffers();

	if (selected_scenario == SCENARIO_EXT2_BUFFERED)
		setup_ext2_target(0);
	else if (selected_scenario == SCENARIO_EXT2_DIRECT)
		setup_ext2_target(1);
	else
		setup_ramfs_target();

	require(prctl(PR_SET_NAME, control_name(selected_scenario), 0, 0, 0) == 0,
		3);
	require(pthread_barrier_init(&phase_barrier, NULL, 2) == 0, 4);
	pthread_t worker;
	require(pthread_create(&worker, NULL, actor_two, NULL) == 0, 5);
	wait_phase(6);
	run_actor(0);
	wait_phase(7);
	require(pthread_join(worker, NULL) == 0, 8);
	require(pthread_barrier_destroy(&phase_barrier) == 0, 9);
	require(prctl(PR_SET_NAME, "sp-io-flush", 0, 0, 0) == 0, 10);
	return EXIT_SUCCESS;
}
