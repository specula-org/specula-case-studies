// SPDX-License-Identifier: MPL-2.0
//
// MC-2: "A retained write prefix is returned as EFAULT with no offset progress"
//
// Escalation level 0 -- pure black box. Only public syscalls are used:
// open/pwrite/pread/fsync/mmap/mprotect/lseek/write/close. No failpoints, no
// kernel hooks, no state injection, no source modification. The same binary
// runs on Linux (control) and on Asterinas (target); the driver compares them.
//
// Trigger: one buffered write() on an ext2 regular file whose user buffer is
// partly PROT_NONE, so the copy faults after a positive prefix has already been
// copied into -- and dirtied in -- the page cache.
//
// Three cases, all reaching the same defect through a different page-state mix
// (kernel/core/src/vm/page_cache/vmo/mod.rs, write_pages_with_backend):
//
//   mixed_page   an earlier page is copied in full and dirtied (Ok arm,
//                set_dirty), then the next page faults with zero bytes copied.
//   partial_page the fault lands inside a single up-to-date page
//                (Err arm, written_size > 0 && state.is_up_to_date).
//   uninit_tail  the counterexample's exact shape: the unaligned head page is
//                UpToDate (CommitMode::Read) and takes the whole readable
//                prefix, while the page-aligned middle is committed Uninit
//                (CommitMode::Overwrite) and is the page that faults.
//                MC_hunt_scenario_1_mixed_page_prefix_bfs.out State 6:
//                MCFileOpsWriteAtCopyFaultPositive(t1,"Uninit","Positive").
//
// Measured, all through the public API: write()'s return value and errno, the
// shared file offset before/after (lseek SEEK_CUR), which bytes of the file
// actually changed, and whether the change survives fsync + an O_DIRECT read
// (i.e. reaches the block device rather than living only in the page cache).

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
#define MAX_FILE_BYTES (4 * PAGE_BYTES)

#define OLD_BYTE 'A'
#define NEW_BYTE 'B'

struct case_spec {
	const char *name;
	size_t file_bytes;     /* size of the pre-existing file            */
	int cold_setup;        /* create via O_DIRECT so the cache is cold */
	size_t warm_bytes;     /* bytes pre-read buffered (0 = none)       */
	long write_off;        /* file offset the write starts at          */
	size_t write_len;      /* requested write length                   */
	size_t readable_bytes; /* readable prefix of the user buffer       */
};

static int failures;
static char *scratch;  /* page-aligned, MAX_FILE_BYTES */
static char *aligned;  /* page-aligned, MAX_FILE_BYTES */

static void die(const char *what)
{
	fprintf(stderr, "MC2_FATAL %s: %s\n", what, strerror(errno));
	fflush(stderr);
	exit(2);
}

/* Three anonymous pages of NEW_BYTE; only the last `readable_bytes` of the
 * first page stay readable, the rest is revoked. Returns the mapping base and
 * sets *out_ptr to where the write should start. */
static char *make_fault_buffer(size_t readable_bytes, char **out_ptr)
{
	char *base = mmap(NULL, 3 * PAGE_BYTES, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (base == MAP_FAILED)
		die("mmap");
	memset(base, NEW_BYTE, 3 * PAGE_BYTES);
	if (mprotect(base + PAGE_BYTES, 2 * PAGE_BYTES, PROT_NONE) != 0)
		die("mprotect");
	*out_ptr = base + PAGE_BYTES - readable_bytes;
	return base;
}

/* Create `path` as `file_bytes` of OLD_BYTE. With cold_setup the file is
 * written through O_DIRECT, which invalidates the overlapping cached pages, so
 * the page cache starts out cold and a later aligned write commits its pages
 * Uninit. Returns a buffered O_RDWR fd. */
static int fresh_target(const struct case_spec *c, const char *path,
			const char **setup_kind)
{
	int fd;

	unlink(path);
	memset(scratch, OLD_BYTE, c->file_bytes);

	fd = -1;
	*setup_kind = "buffered";
	if (c->cold_setup) {
		fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_DIRECT, 0600);
		if (fd >= 0) {
			if (pwrite(fd, scratch, c->file_bytes, 0) !=
			    (ssize_t)c->file_bytes) {
				close(fd);
				unlink(path);
				fd = -1;
			} else {
				*setup_kind = "o_direct";
			}
		}
	}
	if (fd < 0) {
		fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0)
			die("open(create)");
		if (pwrite(fd, scratch, c->file_bytes, 0) !=
		    (ssize_t)c->file_bytes)
			die("pwrite(fill)");
	}
	if (fsync(fd) != 0)
		die("fsync(fill)");
	if (close(fd) != 0)
		die("close(fill)");

	fd = open(path, O_RDWR);
	if (fd < 0)
		die("open(rw)");
	if (c->warm_bytes > 0 &&
	    pread(fd, scratch, c->warm_bytes, 0) != (ssize_t)c->warm_bytes)
		die("pread(warm)");
	return fd;
}

static size_t count_changed(const char *buf, size_t len, long *first, long *last)
{
	size_t n = 0;

	*first = -1;
	*last = -1;
	for (size_t i = 0; i < len; i++) {
		if (buf[i] == OLD_BYTE)
			continue;
		n++;
		if (*first < 0)
			*first = (long)i;
		*last = (long)i;
	}
	return n;
}

/* Read the file back bypassing the page cache, to show the retained prefix is
 * durable and not a cache-only artifact. Returns -1 if O_DIRECT is unusable. */
static ssize_t on_disk_changed(const char *path, size_t file_bytes)
{
	int fd = open(path, O_RDONLY | O_DIRECT);
	long first, last;
	ssize_t got;

	if (fd < 0)
		return -1;
	memset(aligned, 0, file_bytes);
	got = pread(fd, aligned, file_bytes, 0);
	close(fd);
	if (got != (ssize_t)file_bytes)
		return -1;
	return (ssize_t)count_changed(aligned, file_bytes, &first, &last);
}

static void run_case(const struct case_spec *c, const char *dir)
{
	char path[256];
	const char *setup_kind;
	char *base, *buf;
	int fd, saved_errno;
	off_t off_before, off_after;
	ssize_t ret, on_disk;
	size_t changed;
	long first, last;

	snprintf(path, sizeof(path), "%s/mc2-%s", dir, c->name);
	fd = fresh_target(c, path, &setup_kind);
	base = make_fault_buffer(c->readable_bytes, &buf);

	if (lseek(fd, c->write_off, SEEK_SET) != c->write_off)
		die("lseek(position)");
	off_before = lseek(fd, 0, SEEK_CUR);
	if (off_before < 0)
		die("lseek(before)");

	errno = 0;
	ret = write(fd, buf, c->write_len);
	saved_errno = errno;

	off_after = lseek(fd, 0, SEEK_CUR);
	if (off_after < 0)
		die("lseek(after)");

	if (fsync(fd) != 0)
		die("fsync(after)");

	memset(scratch, 0, c->file_bytes);
	if (pread(fd, scratch, c->file_bytes, 0) != (ssize_t)c->file_bytes)
		die("pread(verify)");
	changed = count_changed(scratch, c->file_bytes, &first, &last);

	if (close(fd) != 0)
		die("close(verify)");
	on_disk = on_disk_changed(path, c->file_bytes);
	munmap(base, 3 * PAGE_BYTES);

	printf("MC2_CASE %s setup=%s file_bytes=%zu warm_bytes=%zu write_off=%ld write_len=%zu readable_bytes=%zu\n",
	       c->name, setup_kind, c->file_bytes, c->warm_bytes, c->write_off,
	       c->write_len, c->readable_bytes);
	printf("MC2_WRITE %s ret=%zd errno=%d(%s)\n", c->name, ret,
	       ret < 0 ? saved_errno : 0,
	       ret < 0 ? strerror(saved_errno) : "none");
	printf("MC2_OFFSET %s before=%lld after=%lld delta=%lld\n", c->name,
	       (long long)off_before, (long long)off_after,
	       (long long)(off_after - off_before));
	printf("MC2_FILE %s changed_bytes=%zu first_changed=%ld last_changed=%ld\n",
	       c->name, changed, first, last);
	if (on_disk >= 0)
		printf("MC2_DIRECT %s on_disk_changed_bytes=%zd\n", c->name,
		       on_disk);
	else
		printf("MC2_DIRECT %s unavailable\n", c->name);

	if (ret > 0) {
		/* Linux contract: a positive short write reports exactly the
		 * bytes it committed and moves the shared offset by that much. */
		int ok = ((size_t)ret == changed) &&
			 ((off_after - off_before) == ret);

		printf("MC2_VERDICT %s %s reported=%zd committed=%zu offset_delta=%lld\n",
		       c->name, ok ? "CONSISTENT_SHORT_WRITE" : "INCONSISTENT",
		       ret, changed, (long long)(off_after - off_before));
		if (!ok)
			failures++;
	} else if (ret < 0 && saved_errno == EFAULT && changed > 0) {
		printf("MC2_VERDICT %s RETAINED_PREFIX_UNREPORTED reported=0 committed=%zu offset_delta=%lld\n",
		       c->name, changed, (long long)(off_after - off_before));
		failures++;
	} else if (ret < 0 && saved_errno == EFAULT) {
		printf("MC2_VERDICT %s EFAULT_NOTHING_COMMITTED reported=0 committed=0 offset_delta=%lld\n",
		       c->name, (long long)(off_after - off_before));
	} else {
		printf("MC2_VERDICT %s UNEXPECTED ret=%zd errno=%d\n", c->name,
		       ret, saved_errno);
		failures++;
	}
	fflush(stdout);
}

static const struct case_spec CASES[] = {
	/* earlier page fully copied and dirtied, next page faults at 0 bytes */
	{ "mixed_page", 2 * PAGE_BYTES, 0, 2 * PAGE_BYTES, 0, 2 * PAGE_BYTES,
	  PAGE_BYTES },
	/* fault inside one up-to-date page */
	{ "partial_page", 2 * PAGE_BYTES, 0, 2 * PAGE_BYTES, 0, 2 * PAGE_BYTES,
	  128 },
	/* counterexample shape: UpToDate head dirtied, Uninit middle faults */
	{ "uninit_tail", 3 * PAGE_BYTES, 1, PAGE_BYTES, PAGE_BYTES - 128,
	  2 * PAGE_BYTES + 128, 128 },
};

int main(int argc, char **argv)
{
	const char *dir = (argc > 1) ? argv[1] : "/ext2";

	if (posix_memalign((void **)&scratch, PAGE_BYTES, MAX_FILE_BYTES) != 0)
		die("posix_memalign(scratch)");
	if (posix_memalign((void **)&aligned, PAGE_BYTES, MAX_FILE_BYTES) != 0)
		die("posix_memalign(aligned)");

	printf("MC-2 repro: retained write prefix reported as EFAULT\n");
	printf("MC2_DIR %s\n", dir);

	for (size_t i = 0; i < sizeof(CASES) / sizeof(CASES[0]); i++)
		run_case(&CASES[i], dir);

	printf("MC2_RESULT %s\n",
	       failures ? "DIVERGES_FROM_LINUX" : "MATCHES_LINUX");
	printf("MC2_SCENARIO_DONE\n");
	fflush(stdout);
	return 0;
}
