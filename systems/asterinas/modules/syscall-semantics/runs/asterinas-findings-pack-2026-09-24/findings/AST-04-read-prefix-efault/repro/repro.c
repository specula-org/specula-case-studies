// SPDX-License-Identifier: MPL-2.0
//
// Repro for MC-1: "A positive read prefix is exposed but returned as EFAULT".
//
// Escalation level 0 (pure black box): only mmap/mprotect/open/read/pread/lseek.
// No failpoints, no kernel patch, no state injection.
//
// The user buffer straddles a mapped/unmapped boundary, which is what happens
// naturally when a buffer sits at the tail of an mmap arena next to a guard
// page. The kernel copies the writable prefix into the buffer and then faults
// on the rest.
//
// Linux contract (filemap_read(): `return already_read ? already_read : error`):
//   read() returns the positive short count, the file offset advances by that
//   count, and the copied prefix is visible in the user buffer.
//
// Asterinas under test: the fallible copy returns Err((PageFault, copied)),
// every layer above converts the tuple to a scalar EFAULT and drops `copied`,
// so read() reports -1/EFAULT and the shared offset never moves -- even though
// `copied` bytes of the user buffer were already overwritten.
//
// The same binary is run on the Linux host (control) and inside Asterinas.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE_BYTES 4096
// Writable bytes in front of the PROT_NONE hole.
#define PREFIX_BYTES 128
#define FILE_BYTES (2 * PAGE_BYTES)

static int anomalies;

static char pattern_byte(size_t i)
{
	return (char)('A' + (int)(i % 26));
}

// Returns a pointer with PREFIX_BYTES writable bytes followed by PROT_NONE.
static char *make_straddling_buffer(void)
{
	char *m = mmap(NULL, 3 * PAGE_BYTES, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (m == MAP_FAILED) {
		perror("mmap");
		exit(2);
	}
	memset(m, 0, 3 * PAGE_BYTES);
	if (mprotect(m + PAGE_BYTES, 2 * PAGE_BYTES, PROT_NONE) != 0) {
		perror("mprotect");
		exit(2);
	}
	return m + PAGE_BYTES - PREFIX_BYTES;
}

static void create_file(const char *path)
{
	char *content = malloc(FILE_BYTES);
	if (content == NULL) {
		perror("malloc");
		exit(2);
	}
	for (size_t i = 0; i < FILE_BYTES; i++)
		content[i] = pattern_byte(i);

	unlink(path);
	int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
	if (fd < 0) {
		fprintf(stderr, "open(%s) for create: %s\n", path,
			strerror(errno));
		exit(2);
	}
	ssize_t total = 0;
	while (total < FILE_BYTES) {
		ssize_t n = write(fd, content + total, FILE_BYTES - total);
		if (n <= 0) {
			fprintf(stderr, "write(%s): %s\n", path,
				strerror(errno));
			exit(2);
		}
		total += n;
	}
	if (close(fd) != 0) {
		perror("close");
		exit(2);
	}
	free(content);
}

// Counts leading bytes of `buf` that match the file pattern starting at
// `file_off`. Only the writable prefix is inspected, so this never faults.
static size_t visible_prefix(const char *buf, size_t file_off)
{
	size_t n = 0;
	while (n < PREFIX_BYTES && buf[n] == pattern_byte(file_off + n))
		n++;
	return n;
}

static void scrub(char *buf)
{
	memset(buf, '.', PREFIX_BYTES);
}

// One shared-offset read() whose buffer faults after a positive prefix.
static void probe_read(const char *tag, const char *path)
{
	char *buf = make_straddling_buffer();
	char *good = malloc(FILE_BYTES);
	if (good == NULL) {
		perror("malloc");
		exit(2);
	}

	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		exit(2);
	}

	scrub(buf);
	errno = 0;
	ssize_t ret = read(fd, buf, FILE_BYTES);
	int err = errno;
	off_t off_after = lseek(fd, 0, SEEK_CUR);
	size_t visible = visible_prefix(buf, 0);

	printf("%s read      : ret=%zd errno=%d(%s) offset_after=%lld visible_prefix=%zu\n",
	       tag, ret, ret < 0 ? err : 0,
	       ret < 0 ? strerror(err) : "-", (long long)off_after, visible);

	if (ret < 0 && visible > 0) {
		printf("%s ANOMALY   : read() reported failure (%s) but %zu bytes of the user buffer were already overwritten with file data\n",
		       tag, strerror(err), visible);
		anomalies++;
	}
	if (ret < 0 && off_after != 0) {
		printf("%s ANOMALY   : offset moved to %lld on a reported failure\n",
		       tag, (long long)off_after);
		anomalies++;
	}
	if (ret > 0 && off_after != ret) {
		printf("%s ANOMALY   : short read returned %zd but offset is %lld\n",
		       tag, ret, (long long)off_after);
		anomalies++;
	}

	// Follow-up read into a fully valid buffer: does the stream continue
	// after the bytes the kernel already delivered, or replay them?
	memset(good, '.', FILE_BYTES);
	ssize_t ret2 = read(fd, good, PREFIX_BYTES);
	printf("%s next read : ret=%zd first_byte='%c' (expected '%c' if the delivered prefix is accounted for, '%c' if it is replayed)\n",
	       tag, ret2, ret2 > 0 ? good[0] : '?', pattern_byte(visible),
	       pattern_byte(0));
	if (ret < 0 && visible > 0 && ret2 > 0 && good[0] == pattern_byte(0)) {
		printf("%s ANOMALY   : the %zu delivered bytes are replayed by the next read -- a caller that repairs its mapping and retries sees them twice\n",
		       tag, visible);
		anomalies++;
	}

	close(fd);
	free(good);
	munmap(buf - (PAGE_BYTES - PREFIX_BYTES), 3 * PAGE_BYTES);
}

// Same fault shape through the positional path (pread64).
static void probe_pread(const char *tag, const char *path)
{
	char *buf = make_straddling_buffer();

	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		exit(2);
	}

	scrub(buf);
	errno = 0;
	ssize_t ret = pread(fd, buf, FILE_BYTES, 0);
	int err = errno;
	size_t visible = visible_prefix(buf, 0);

	printf("%s pread     : ret=%zd errno=%d(%s) visible_prefix=%zu\n", tag,
	       ret, ret < 0 ? err : 0, ret < 0 ? strerror(err) : "-", visible);
	if (ret < 0 && visible > 0) {
		printf("%s ANOMALY   : pread() reported failure (%s) but %zu bytes of the user buffer were already overwritten with file data\n",
		       tag, strerror(err), visible);
		anomalies++;
	}

	close(fd);
	munmap(buf - (PAGE_BYTES - PREFIX_BYTES), 3 * PAGE_BYTES);
}

// Control: the whole buffer is unmapped, so nothing is copied. Both kernels
// must report EFAULT here. This separates "EFAULT is wrong" from
// "EFAULT after a positive prefix is wrong".
static void probe_zero_prefix(const char *tag, const char *path)
{
	char *m = mmap(NULL, PAGE_BYTES, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (m == MAP_FAILED) {
		perror("mmap");
		exit(2);
	}
	if (mprotect(m, PAGE_BYTES, PROT_NONE) != 0) {
		perror("mprotect");
		exit(2);
	}

	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		exit(2);
	}
	errno = 0;
	ssize_t ret = read(fd, m, PAGE_BYTES);
	int err = errno;
	off_t off_after = lseek(fd, 0, SEEK_CUR);
	printf("%s zero-prefix control: ret=%zd errno=%d(%s) offset_after=%lld (both kernels must report EFAULT here)\n",
	       tag, ret, ret < 0 ? err : 0, ret < 0 ? strerror(err) : "-",
	       (long long)off_after);
	if (!(ret < 0 && err == EFAULT)) {
		printf("%s ANOMALY   : zero-progress fault did not report EFAULT\n",
		       tag);
		anomalies++;
	}

	close(fd);
	munmap(m, PAGE_BYTES);
}

static void run_backend(const char *tag, const char *path)
{
	create_file(path);
	printf("---- %s (%s) ----\n", tag, path);
	probe_read(tag, path);
	probe_pread(tag, path);
	probe_zero_prefix(tag, path);
	unlink(path);
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);

	printf("MC-1 repro: positive read prefix exposed but reported as EFAULT\n");
	printf("page=%d writable_prefix=%d file_bytes=%d\n", PAGE_BYTES,
	       PREFIX_BYTES, FILE_BYTES);

	if (argc > 1) {
		for (int i = 1; i < argc; i++)
			run_backend(argv[i], argv[i]);
	} else {
		run_backend("ramfs", "/mc1-regular-file");
		run_backend("ext2 ", "/ext2/mc1-regular-file");
	}

	printf("MC1_ANOMALIES %d\n", anomalies);
	printf(anomalies == 0 ? "MC1_RESULT MATCHES_LINUX\n" :
				"MC1_RESULT DIVERGES_FROM_LINUX\n");
	return 0;
}
