// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

enum operation {
	OP_WRITE,
	OP_PREAD,
	OP_PWRITE,
};

struct fault_buffer {
	void *mapping;
	char *cursor;
	size_t mapping_len;
};

struct worker_args {
	pthread_barrier_t *barrier;
	atomic_int *ready;
	enum operation operation;
	int fd;
	char *buffer;
	size_t length;
	off_t offset;
	ssize_t result;
	int error;
};

static void fail(const char *what)
{
	fprintf(stderr, "SPECULA_SETUP_ERROR %s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void wait_at_barrier(pthread_barrier_t *barrier)
{
	int error = pthread_barrier_wait(barrier);

	if (error != 0 && error != PTHREAD_BARRIER_SERIAL_THREAD) {
		errno = error;
		fail("pthread_barrier_wait");
	}
}

static void start_simultaneously(pthread_barrier_t *barrier, atomic_int *ready)
{
	wait_at_barrier(barrier);
	atomic_fetch_add_explicit(ready, 1, memory_order_seq_cst);
	while (atomic_load_explicit(ready, memory_order_seq_cst) != 2)
		;
}

static char *allocate_buffer(size_t length, int fill)
{
	char *buffer = mmap(NULL, length, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (buffer == MAP_FAILED)
		fail("mmap buffer");
	memset(buffer, fill, length);
	return buffer;
}

static struct fault_buffer allocate_prefix_fault(size_t page_size, int fill)
{
	struct fault_buffer buffer = {
		.mapping_len = 2 * page_size,
	};

	buffer.mapping = mmap(NULL, buffer.mapping_len, PROT_READ | PROT_WRITE,
			      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (buffer.mapping == MAP_FAILED)
		fail("mmap fault buffer");
	memset(buffer.mapping, fill, page_size);
	if (mprotect((char *)buffer.mapping + page_size, page_size, PROT_NONE) <
	    0)
		fail("mprotect fault page");
	buffer.cursor = (char *)buffer.mapping + page_size / 2;
	return buffer;
}

static void prepare_file(const char *temporary, const char *target,
			 size_t file_size)
{
	char *contents = allocate_buffer(file_size, 0x5a);
	int fd;
	ssize_t written;

	unlink(temporary);
	unlink(target);
	fd = open(temporary, O_CREAT | O_EXCL | O_RDWR, 0600);
	if (fd < 0)
		fail("open staging file");
	written = pwrite(fd, contents, file_size, 0);
	if (written != (ssize_t)file_size)
		fail("populate staging file");
	if (fsync(fd) < 0)
		fail("fsync staging file");
	if (close(fd) < 0)
		fail("close staging file");
	if (rename(temporary, target) < 0)
		fail("rename staging file");
	munmap(contents, file_size);
}

static int open_shared_file(const char *target, off_t initial_offset)
{
	int fd = open(target, O_RDWR);

	if (fd < 0)
		fail("open trace target");
	if (lseek(fd, initial_offset, SEEK_SET) != initial_offset)
		fail("set shared offset");
	return fd;
}

static void *run_worker(void *opaque)
{
	struct worker_args *args = opaque;

	start_simultaneously(args->barrier, args->ready);
	errno = 0;
	switch (args->operation) {
	case OP_WRITE:
		args->result = write(args->fd, args->buffer, args->length);
		break;
	case OP_PREAD:
		args->result = pread(args->fd, args->buffer, args->length,
				     args->offset);
		break;
	case OP_PWRITE:
		args->result = pwrite(args->fd, args->buffer, args->length,
				      args->offset);
		break;
	}
	args->error = errno;
	return NULL;
}

static void finish_threads(pthread_t worker, pthread_barrier_t *barrier)
{
	int error = pthread_join(worker, NULL);

	if (error != 0) {
		errno = error;
		fail("pthread_join");
	}
	error = pthread_barrier_destroy(barrier);
	if (error != 0) {
		errno = error;
		fail("pthread_barrier_destroy");
	}
}

static void run_ramfs_fault_vector(size_t page_size, size_t unit)
{
	const char *temporary = "/tmp/specula_stage_ramfs_fault";
	const char *target = "/tmp/.specula_ramfs_fault_vector";
	struct fault_buffer fault = allocate_prefix_fault(page_size, 0x41);
	char *complete = allocate_buffer(page_size, 0x42);
	pthread_barrier_t barrier;
	atomic_int ready = ATOMIC_VAR_INIT(0);
	pthread_t worker;
	struct worker_args worker_args;
	struct iovec iov[2];
	ssize_t vector_result;
	int vector_error;
	int fd;
	int fd2;

	prepare_file(temporary, target, 7 * unit);
	fd = open_shared_file(target, 0);
	fd2 = dup(fd);
	if (fd2 < 0)
		fail("dup trace target");
	if (pthread_barrier_init(&barrier, NULL, 2) != 0)
		fail("pthread_barrier_init");
	worker_args = (struct worker_args){
		.barrier = &barrier,
		.ready = &ready,
		.operation = OP_WRITE,
		.fd = fd2,
		.buffer = complete,
		.length = page_size,
	};
	if (pthread_create(&worker, NULL, run_worker, &worker_args) != 0)
		fail("pthread_create");
	iov[0] = (struct iovec){ .iov_base = complete, .iov_len = page_size };
	iov[1] = (struct iovec){ .iov_base = fault.cursor,
				 .iov_len = page_size };
	start_simultaneously(&barrier, &ready);
	errno = 0;
	vector_result = writev(fd, iov, 2);
	vector_error = errno;
	finish_threads(worker, &barrier);
	printf("SPECULA_RESULT ramfs_fault_vector writev=%zd errno=%d write=%zd errno=%d\n",
	       vector_result, vector_error, worker_args.result,
	       worker_args.error);
	close(fd2);
	close(fd);
	munmap(fault.mapping, fault.mapping_len);
	munmap(complete, page_size);
}

static void run_ramfs_eof_positional(size_t page_size, size_t unit)
{
	const char *temporary = "/tmp/specula_stage_ramfs_eof";
	const char *target = "/tmp/.specula_ramfs_eof_positional";
	char *shared_buffer = allocate_buffer(page_size, 0);
	char *positional_buffer = allocate_buffer(page_size, 0);
	pthread_barrier_t barrier;
	atomic_int ready = ATOMIC_VAR_INIT(0);
	pthread_t worker;
	struct worker_args worker_args;
	ssize_t shared_result;
	int shared_error;
	int fd;
	int fd2;

	prepare_file(temporary, target, 7 * unit);
	fd = open_shared_file(target, 6 * unit);
	fd2 = dup(fd);
	if (fd2 < 0)
		fail("dup trace target");
	if (pthread_barrier_init(&barrier, NULL, 2) != 0)
		fail("pthread_barrier_init");
	worker_args = (struct worker_args){
		.barrier = &barrier,
		.ready = &ready,
		.operation = OP_PREAD,
		.fd = fd2,
		.buffer = positional_buffer,
		.length = page_size,
		.offset = 6 * unit,
	};
	if (pthread_create(&worker, NULL, run_worker, &worker_args) != 0)
		fail("pthread_create");
	start_simultaneously(&barrier, &ready);
	errno = 0;
	shared_result = read(fd, shared_buffer, page_size);
	shared_error = errno;
	finish_threads(worker, &barrier);
	printf("SPECULA_RESULT ramfs_eof_positional read=%zd errno=%d pread=%zd errno=%d\n",
	       shared_result, shared_error, worker_args.result,
	       worker_args.error);
	close(fd2);
	close(fd);
	munmap(shared_buffer, page_size);
	munmap(positional_buffer, page_size);
}

static void run_correct_vector_positional(size_t page_size, size_t unit)
{
	const char *temporary = "/ext2/specula_stage_correct";
	const char *target = "/ext2/.specula_correct_vector_positional";
	char *read_buffer1 = allocate_buffer(page_size, 0);
	char *read_buffer2 = allocate_buffer(page_size, 0);
	char *write_buffer = allocate_buffer(page_size, 0x43);
	pthread_barrier_t barrier;
	atomic_int ready = ATOMIC_VAR_INIT(0);
	pthread_t worker;
	struct worker_args worker_args;
	struct iovec iov[2];
	ssize_t vector_result;
	int vector_error;
	int fd;
	int fd2;

	prepare_file(temporary, target, 7 * unit);
	fd = open_shared_file(target, 0);
	fd2 = dup(fd);
	if (fd2 < 0)
		fail("dup trace target");
	if (pthread_barrier_init(&barrier, NULL, 2) != 0)
		fail("pthread_barrier_init");
	worker_args = (struct worker_args){
		.barrier = &barrier,
		.ready = &ready,
		.operation = OP_PWRITE,
		.fd = fd2,
		.buffer = write_buffer,
		.length = page_size,
		.offset = 6 * unit,
	};
	if (pthread_create(&worker, NULL, run_worker, &worker_args) != 0)
		fail("pthread_create");
	iov[0] = (struct iovec){ .iov_base = read_buffer1,
				 .iov_len = page_size };
	iov[1] = (struct iovec){ .iov_base = read_buffer2,
				 .iov_len = page_size };
	start_simultaneously(&barrier, &ready);
	errno = 0;
	vector_result = readv(fd, iov, 2);
	vector_error = errno;
	finish_threads(worker, &barrier);
	printf("SPECULA_RESULT correct_vector_positional readv=%zd errno=%d pwrite=%zd errno=%d\n",
	       vector_result, vector_error, worker_args.result,
	       worker_args.error);
	close(fd2);
	close(fd);
	munmap(read_buffer1, page_size);
	munmap(read_buffer2, page_size);
	munmap(write_buffer, page_size);
}

static void run_exfat_fault_vector(size_t page_size, size_t unit)
{
	const char *temporary = "/exfat/specula_stage_exfat";
	const char *target = "/exfat/.specula_exfat_fault_vector";
	struct fault_buffer fault = allocate_prefix_fault(page_size, 0x44);
	char *read_buffer1 = allocate_buffer(page_size, 0);
	char *read_buffer2 = allocate_buffer(page_size, 0);
	pthread_barrier_t barrier;
	atomic_int ready = ATOMIC_VAR_INIT(0);
	pthread_t worker;
	struct worker_args worker_args;
	struct iovec iov[2];
	ssize_t vector_result;
	int vector_error;
	int fd;
	int fd2;

	prepare_file(temporary, target, 7 * unit);
	fd = open_shared_file(target, 6 * unit);
	fd2 = dup(fd);
	if (fd2 < 0)
		fail("dup trace target");
	if (pthread_barrier_init(&barrier, NULL, 2) != 0)
		fail("pthread_barrier_init");
	worker_args = (struct worker_args){
		.barrier = &barrier,
		.ready = &ready,
		.operation = OP_PWRITE,
		.fd = fd2,
		.buffer = fault.cursor,
		.length = page_size,
		.offset = 6 * unit,
	};
	if (pthread_create(&worker, NULL, run_worker, &worker_args) != 0)
		fail("pthread_create");
	iov[0] = (struct iovec){ .iov_base = read_buffer1,
				 .iov_len = page_size };
	iov[1] = (struct iovec){ .iov_base = read_buffer2,
				 .iov_len = page_size };
	start_simultaneously(&barrier, &ready);
	errno = 0;
	vector_result = readv(fd, iov, 2);
	vector_error = errno;
	finish_threads(worker, &barrier);
	printf("SPECULA_RESULT exfat_fault_vector readv=%zd errno=%d pwrite=%zd errno=%d\n",
	       vector_result, vector_error, worker_args.result,
	       worker_args.error);
	close(fd2);
	close(fd);
	munmap(fault.mapping, fault.mapping_len);
	munmap(read_buffer1, page_size);
	munmap(read_buffer2, page_size);
}

int main(int argc, char **argv)
{
	long page_size = sysconf(_SC_PAGESIZE);
	size_t unit;

	if (argc != 2) {
		fprintf(stderr, "usage: %s SCENARIO\n", argv[0]);
		return EXIT_FAILURE;
	}
	if (page_size <= 0 || page_size % 2 != 0)
		fail("sysconf page size");
	unit = (size_t)page_size / 2;

	if (strcmp(argv[1], "ramfs_fault_vector") == 0)
		run_ramfs_fault_vector((size_t)page_size, unit);
	else if (strcmp(argv[1], "ramfs_eof_positional") == 0)
		run_ramfs_eof_positional((size_t)page_size, unit);
	else if (strcmp(argv[1], "correct_vector_positional") == 0)
		run_correct_vector_positional((size_t)page_size, unit);
	else if (strcmp(argv[1], "exfat_fault_vector") == 0)
		run_exfat_fault_vector((size_t)page_size, unit);
	else {
		fprintf(stderr, "unknown scenario: %s\n", argv[1]);
		return EXIT_FAILURE;
	}

	printf("SPECULA_SCENARIO_DONE %s\n", argv[1]);
	return EXIT_SUCCESS;
}
