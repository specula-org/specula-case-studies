// SPDX-License-Identifier: MPL-2.0
//
// MC-6: "Ext2 direct write returns while an earlier submitted BIO remains live"
//
// Escalation levels 0 and 1 -- pure black box (A/B/C) plus user-space timing
// pressure and device-queue load (D/E/F/G).
// Only public syscalls are used: open/pwrite/pread/mmap/mprotect/close/unlink.
// No failpoints, no kernel hooks, no state injection, no source modification.
// The same binary runs on Linux (control) and on Asterinas (target); the driver
// compares them.
//
// Mechanism under test
// --------------------
// kernel/core/src/fs/fs_impls/ext2/inode/file.rs:590 `write_direct_blocks`
// walks the write range one *mapped device run* at a time. For each run it
// copies from the user buffer into a freshly allocated BioSegment and submits
// an asynchronous write into a local `IoBatch`. The batch is only waited on at
// file.rs:667, after the loop. Any error inside the loop -- including the
// `write_fallible` fault at file.rs:620 -- takes an early `return Err(..)`, so
// the `IoBatch` is dropped. `IoBatch` (kernel/libs/io-util/src/batch.rs:107)
// has no `Drop` impl and no cancel API, so every BIO already handed to the
// device stays live and still lands. file.rs:516 then rolls the metadata back,
// releases the inode lock, and `sys_pwrite64` returns EFAULT.
//
// Counterexample being instantiated
// ---------------------------------
// spec/output/MC_hunt_finding_mc2_direct_completion_bfs.out, invariant
// MCNoUnaccountedPendingEffect:
//   State  3: MCSysPwrite64Start(t2,"Ext2Direct","Complete",0,"UpToDate")
//   State  9: MCBioSegmentWriteFallibleFaultZero(t2)
//   State 13: result[t2] = "Fault", pc[t2] = "Idle",
//             pendingBios = {<<t2,1,1,0,1,0>>}   (part 1 still pending)
// i.e. a block-aligned O_DIRECT pwrite64 at offset 0 whose *second* mapped run
// faults with zero bytes copied, while the first run's BIO is already gone to
// the device and is never waited for.
//
// Reaching two mapped runs from user space
// ----------------------------------------
// `IoRangeIter::next` (ext2/inode/io_range.rs) yields one `IoRange::Mapped`
// per *contiguous device-block run*. The ext2 block allocator is plain
// first-fit over the group bitmap and ignores the goal hint
// (ext2/block_group.rs:290 `alloc_consecutive`), so appending one block to a
// victim file, then one block to a spacer file, then one more block to the
// victim, deterministically gives the victim two non-adjacent device blocks
// and therefore two mapped runs.
//
// Cases
// -----
//   A frag_boundary   fragmented victim, fault exactly at the run boundary
//                     (the counterexample's FaultZero shape)
//   B frag_midrun     fragmented victim, fault 2048 bytes into the second run
//                     (the FaultPositive shape)
//   C contig_control  NEGATIVE CONTROL for the mechanism: victim allocated as
//                     one contiguous run, same faulting buffer. The fault now
//                     lands inside the first and only run, before anything is
//                     submitted, so a "publish only what was already submitted"
//                     implementation must publish nothing here.
//   D pending_visible after the EFAULT return, poll block 0 through a separate
//                     pre-opened O_DIRECT fd. Seeing OLD and then NEW with no
//                     intervening write means the effect was still pending when
//                     the syscall returned.
//   E stale_clobber   after the EFAULT return, issue a *successful* O_DIRECT
//                     pwrite of block 0 with a third pattern. That call waits
//                     for its own BIO, so on return its data is on the device.
//                     If block 0 later reads back as the failed write's pattern,
//                     a syscall that reported failure has reverted a syscall
//                     that reported success.
//   F queue_pressure  case E again, with a background thread issuing 64-block
//                     O_DIRECT writes to its own file so the device queue stays
//                     deep and the orphaned BIO is more likely to still be
//                     queued when the later write is submitted.
//   G free_realloc    case E again, but ftruncate(fd, 0) between the faulting
//                     write and the rewrite. That frees the device block the
//                     orphaned BIO targets; first-fit then hands the same block
//                     back for the rewrite, so a late landing corrupts a block
//                     that has been freed and re-allocated in between.
//
// A/B/C verdicts (computed per OS, no cross-OS assumption baked in)
//   OK                    ret >= 0 and exactly `ret` bytes changed, or
//                         ret < 0 and nothing changed
//   COMMIT_WITHOUT_REPORT ret < 0 (EFAULT) yet bytes are committed
//   NO_PUBLICATION        ret < 0 and nothing changed
//   SHORT_WRITE           ret > 0 and shorter than requested
//   OTHER                 anything else; the raw numbers are printed too

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>

#define BLK 4096
#define VICTIM_BLOCKS 2
#define VICTIM_BYTES (VICTIM_BLOCKS * BLK)
#define PATH_MAX_LEN 256

#define OLD_BYTE 'A'
#define NEW_BYTE 'B'
#define LATE_BYTE 'C'

/* Rounds for the two timing-sensitive cases (escalation level 1). */
#define ROUNDS 64
/* Probe reads issued after the faulting pwrite returns, per round. */
#define PROBES 16

static int failures;
static char *scratch; /* page-aligned staging buffer, VICTIM_BYTES */

static void die(const char *what)
{
	fprintf(stderr, "MC6_FATAL %s: %s\n", what, strerror(errno));
	fflush(stderr);
	exit(2);
}

static char *alloc_aligned(size_t bytes)
{
	void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (p == MAP_FAILED)
		die("mmap(scratch)");
	return p;
}

/* Direct-write `bytes` of `fill` at `off`. Returns 0 on success. */
static int direct_fill_byte(int fd, long off, size_t bytes, int fill)
{
	ssize_t n;

	memset(scratch, fill, bytes);
	n = pwrite(fd, scratch, bytes, off);
	if (n != (ssize_t)bytes) {
		fprintf(stderr, "MC6_SETUP pwrite(off=%ld,len=%zu) = %zd (%s)\n",
			off, bytes, n, strerror(errno));
		return -1;
	}
	return 0;
}

static int direct_fill(int fd, long off, size_t bytes)
{
	return direct_fill_byte(fd, off, bytes, OLD_BYTE);
}

static int open_direct(const char *path, int flags)
{
	int fd = open(path, flags | O_DIRECT, 0600);

	if (fd < 0)
		fprintf(stderr, "MC6_NOTE open(%s, O_DIRECT) failed: %s\n",
			path, strerror(errno));
	return fd;
}

/*
 * Build the victim file.
 *
 * fragmented != 0: victim block 0, spacer block 0, victim block 1.  First-fit
 * allocation puts a foreign block between the victim's two blocks, so the
 * victim spans two mapped runs.
 *
 * fragmented == 0: one single VICTIM_BYTES direct write, so both blocks come
 * from one `alloc_consecutive` call and form a single mapped run.
 */
static int build_victim(const char *dir, const char *tag, int fragmented,
			char *victim_path, char *spacer_path)
{
	int vfd, sfd;

	snprintf(victim_path, PATH_MAX_LEN, "%s/mc6_victim_%s", dir, tag);
	snprintf(spacer_path, PATH_MAX_LEN, "%s/mc6_spacer_%s", dir, tag);
	unlink(victim_path);
	unlink(spacer_path);

	vfd = open_direct(victim_path, O_RDWR | O_CREAT | O_TRUNC);
	if (vfd < 0)
		return -1;

	if (!fragmented) {
		if (direct_fill(vfd, 0, VICTIM_BYTES) != 0) {
			close(vfd);
			return -1;
		}
		return vfd;
	}

	if (direct_fill(vfd, 0, BLK) != 0) {
		close(vfd);
		return -1;
	}

	sfd = open_direct(spacer_path, O_RDWR | O_CREAT | O_TRUNC);
	if (sfd < 0) {
		close(vfd);
		return -1;
	}
	if (direct_fill(sfd, 0, BLK) != 0) {
		close(sfd);
		close(vfd);
		return -1;
	}
	close(sfd);

	/* Grows the victim by one block; first-fit hands out the block after
	 * the spacer's, so victim block 1 is not adjacent to victim block 0. */
	if (direct_fill(vfd, BLK, BLK) != 0) {
		close(vfd);
		return -1;
	}
	return vfd;
}

/*
 * Three anonymous pages of NEW_BYTE with the tail revoked.  `readable` bytes
 * starting at the returned pointer are readable; everything after faults.
 * `readable` must be <= 2 * BLK.
 */
static char *make_fault_buffer(size_t readable, char **out_ptr)
{
	size_t head = 2 * BLK - readable;
	char *base = mmap(NULL, 3 * BLK, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (base == MAP_FAILED)
		die("mmap(faultbuf)");
	memset(base, NEW_BYTE, 3 * BLK);
	if (mprotect(base + 2 * BLK, BLK, PROT_NONE) != 0)
		die("mprotect");
	*out_ptr = base + head;
	return base;
}

/* Classify each block of the file as OLD / NEW / LATE / MIXED, via `fd`. */
static void classify(int fd, char *buf, char *out, size_t bytes)
{
	size_t b;

	if (pread(fd, buf, bytes, 0) != (ssize_t)bytes)
		die("pread(verify)");
	for (b = 0; b < bytes / BLK; b++) {
		size_t i, old_n = 0, new_n = 0, late_n = 0;

		for (i = 0; i < BLK; i++) {
			char c = buf[b * BLK + i];

			if (c == OLD_BYTE)
				old_n++;
			else if (c == NEW_BYTE)
				new_n++;
			else if (c == LATE_BYTE)
				late_n++;
		}
		if (old_n == BLK)
			out[b] = 'O';
		else if (new_n == BLK)
			out[b] = 'N';
		else if (late_n == BLK)
			out[b] = 'L';
		else
			out[b] = '?';
	}
	out[bytes / BLK] = '\0';
}

static size_t changed_bytes(int fd, char *buf, size_t bytes)
{
	size_t i, n = 0;

	if (pread(fd, buf, bytes, 0) != (ssize_t)bytes)
		die("pread(changed)");
	for (i = 0; i < bytes; i++)
		if (buf[i] != OLD_BYTE)
			n++;
	return n;
}

/* Reads block 0 through `fd` and returns its uniform byte, or '?' if mixed. */
static char probe_block0(int fd, char *buf)
{
	size_t i;
	char first;

	if (pread(fd, buf, BLK, 0) != (ssize_t)BLK)
		die("pread(probe)");
	first = buf[0];
	for (i = 1; i < BLK; i++)
		if (buf[i] != first)
			return '?';
	return first;
}

/* ------------------------------------------------------------------ A / B / C */

struct case_spec {
	const char *tag;
	const char *name;
	int fragmented;
	size_t readable; /* readable prefix of the user buffer */
};

static const struct case_spec CASES[] = {
	{ "A", "frag_boundary", 1, BLK },
	{ "B", "frag_midrun", 1, BLK + 2048 },
	{ "C", "contig_control", 0, BLK },
};

static void run_case(const char *dir, const struct case_spec *c)
{
	char victim_path[PATH_MAX_LEN], spacer_path[PATH_MAX_LEN];
	char blocks_before[VICTIM_BLOCKS + 1], blocks_after[VICTIM_BLOCKS + 1];
	char blocks_buffered[VICTIM_BLOCKS + 1];
	char *base, *ptr, *verify;
	const char *verdict;
	struct stat st_before, st_after;
	size_t changed;
	ssize_t ret;
	int err, vfd, bfd;

	verify = alloc_aligned(VICTIM_BYTES);

	vfd = build_victim(dir, c->tag, c->fragmented, victim_path,
			   spacer_path);
	if (vfd < 0) {
		printf("CASE %s %-16s SETUP_FAILED\n", c->tag, c->name);
		failures++;
		munmap(verify, VICTIM_BYTES);
		return;
	}

	if (fstat(vfd, &st_before) != 0)
		die("fstat(before)");
	classify(vfd, verify, blocks_before, VICTIM_BYTES);

	base = make_fault_buffer(c->readable, &ptr);

	errno = 0;
	ret = pwrite(vfd, ptr, VICTIM_BYTES, 0);
	err = errno;

	if (fstat(vfd, &st_after) != 0)
		die("fstat(after)");
	classify(vfd, verify, blocks_after, VICTIM_BYTES);
	changed = changed_bytes(vfd, verify, VICTIM_BYTES);

	/* What an ordinary (non-O_DIRECT) reader sees. The direct write path
	 * invalidated the overlapping cached pages first, so this read comes
	 * from the block device. */
	bfd = open(victim_path, O_RDONLY);
	if (bfd < 0)
		die("open(buffered)");
	classify(bfd, verify, blocks_buffered, VICTIM_BYTES);
	close(bfd);

	if (ret < 0 && changed > 0)
		verdict = "COMMIT_WITHOUT_REPORT";
	else if (ret < 0 && changed == 0)
		verdict = "NO_PUBLICATION";
	else if (ret >= 0 && changed == (size_t)ret &&
		 ret == (ssize_t)VICTIM_BYTES)
		verdict = "OK";
	else if (ret > 0 && changed == (size_t)ret)
		verdict = "SHORT_WRITE";
	else
		verdict = "OTHER";

	printf("CASE %s %-16s ret=%zd errno=%d(%s) requested=%d "
	       "committed=%zu size=%lld->%lld direct=[%s->%s] buffered=[%s] "
	       "VERDICT=%s\n",
	       c->tag, c->name, ret, ret < 0 ? err : 0,
	       ret < 0 ? strerror(err) : "-", VICTIM_BYTES, changed,
	       (long long)st_before.st_size, (long long)st_after.st_size,
	       blocks_before, blocks_after, blocks_buffered, verdict);

	munmap(base, 3 * BLK);
	munmap(verify, VICTIM_BYTES);
	close(vfd);
	unlink(victim_path);
	unlink(spacer_path);
}

/* -------------------------------------------------------------------- case D */

/*
 * After the faulting pwrite returns EFAULT, block 0 is polled through a
 * separate, already-open O_DIRECT descriptor. `late` counts rounds where the
 * first probe still saw OLD and a later probe saw NEW: the publication happened
 * after the syscall had already returned.
 */
static void run_case_d(const char *dir)
{
	char victim_path[PATH_MAX_LEN], spacer_path[PATH_MAX_LEN];
	char *verify = alloc_aligned(BLK);
	int round, late = 0, immediate = 0, absent = 0, setup_failed = 0;
	char first_seen = 0, last_seen = 0;

	for (round = 0; round < ROUNDS; round++) {
		char tag[32];
		char *base, *ptr;
		int vfd, pfd, p;
		char first, cur;
		ssize_t ret;

		snprintf(tag, sizeof(tag), "D%d", round);
		vfd = build_victim(dir, tag, 1, victim_path, spacer_path);
		if (vfd < 0) {
			setup_failed++;
			break;
		}
		pfd = open_direct(victim_path, O_RDONLY);
		if (pfd < 0) {
			close(vfd);
			setup_failed++;
			break;
		}

		base = make_fault_buffer(BLK, &ptr);
		ret = pwrite(vfd, ptr, VICTIM_BYTES, 0);

		first = probe_block0(pfd, verify);
		cur = first;
		for (p = 1; p < PROBES && cur != NEW_BYTE; p++)
			cur = probe_block0(pfd, verify);

		if (round == 0)
			first_seen = first;
		last_seen = cur;

		if (ret < 0 && first == OLD_BYTE && cur == NEW_BYTE)
			late++;
		else if (ret < 0 && first == NEW_BYTE)
			immediate++;
		else if (ret < 0 && cur != NEW_BYTE)
			absent++;

		munmap(base, 3 * BLK);
		close(pfd);
		close(vfd);
		unlink(victim_path);
		unlink(spacer_path);
	}

	printf("CASE D %-16s rounds=%d late_publication=%d "
	       "already_published=%d never_published=%d setup_failed=%d "
	       "first_probe_round0=%c last_probe=%c VERDICT=%s\n",
	       "pending_visible", ROUNDS, late, immediate, absent,
	       setup_failed, first_seen ? first_seen : '-',
	       last_seen ? last_seen : '-',
	       late > 0 ? "PENDING_AT_RETURN" : "NOT_OBSERVED");

	if (late > 0)
		failures++;
	munmap(verify, BLK);
}

/* -------------------------------------------------------------------- case E */

/*
 * After the faulting pwrite returns EFAULT, a *successful* O_DIRECT pwrite
 * rewrites block 0 with LATE_BYTE. That call waits for its own BIO
 * (file.rs:667), so its data is on the device when it returns. `clobbered`
 * counts rounds where block 0 afterwards reads back as the failed write's
 * pattern: an operation that reported failure overwrote one that reported
 * success.
 */
static void run_case_e(const char *dir)
{
	char victim_path[PATH_MAX_LEN], spacer_path[PATH_MAX_LEN];
	char *verify = alloc_aligned(BLK);
	int round, clobbered = 0, ok = 0, other = 0, setup_failed = 0;
	int late_write_failed = 0;

	for (round = 0; round < ROUNDS; round++) {
		char tag[32];
		char *base, *ptr;
		int vfd, p;
		char seen;
		ssize_t ret, n;

		snprintf(tag, sizeof(tag), "E%d", round);
		vfd = build_victim(dir, tag, 1, victim_path, spacer_path);
		if (vfd < 0) {
			setup_failed++;
			break;
		}

		base = make_fault_buffer(BLK, &ptr);
		ret = pwrite(vfd, ptr, VICTIM_BYTES, 0);

		n = direct_fill_byte(vfd, 0, BLK, LATE_BYTE) == 0 ? BLK : -1;
		if (n != BLK) {
			late_write_failed++;
			munmap(base, 3 * BLK);
			close(vfd);
			unlink(victim_path);
			unlink(spacer_path);
			continue;
		}

		/* Re-read a few times: the stale BIO may still be in flight. */
		seen = probe_block0(vfd, verify);
		for (p = 1; p < PROBES && seen == LATE_BYTE; p++)
			seen = probe_block0(vfd, verify);

		if (ret < 0 && seen == NEW_BYTE)
			clobbered++;
		else if (seen == LATE_BYTE)
			ok++;
		else
			other++;

		munmap(base, 3 * BLK);
		close(vfd);
		unlink(victim_path);
		unlink(spacer_path);
	}

	printf("CASE E %-16s rounds=%d clobbered=%d intact=%d other=%d "
	       "setup_failed=%d late_write_failed=%d VERDICT=%s\n",
	       "stale_clobber", ROUNDS, clobbered, ok, other, setup_failed,
	       late_write_failed,
	       clobbered > 0 ? "SUCCESS_REVERTED_BY_FAILURE" : "NOT_OBSERVED");

	if (clobbered > 0)
		failures++;
	munmap(verify, BLK);
}

/* ------------------------------------------------------------------ case F/G */

/*
 * Background load: a second thread keeps the block device's queue busy with
 * large O_DIRECT writes to its own file, so that a BIO orphaned by the faulting
 * write is more likely to still be queued when the next request is submitted.
 * Pure timing assistance (escalation level 1) -- no kernel change.
 */
#define LOAD_BYTES (64 * BLK)

static volatile int load_stop;
static int load_ops;

static void *load_thread(void *arg)
{
	const char *dir = arg;
	char path[PATH_MAX_LEN];
	char *buf = alloc_aligned(LOAD_BYTES);
	int fd;

	snprintf(path, sizeof(path), "%s/mc6_load", dir);
	unlink(path);
	fd = open_direct(path, O_RDWR | O_CREAT | O_TRUNC);
	if (fd < 0)
		return NULL;
	memset(buf, 'L', LOAD_BYTES);
	while (!load_stop) {
		if (pwrite(fd, buf, LOAD_BYTES, 0) == (ssize_t)LOAD_BYTES)
			load_ops++;
	}
	close(fd);
	unlink(path);
	munmap(buf, LOAD_BYTES);
	return NULL;
}

/*
 * mode 0 (case F): faulting pwrite, then a successful O_DIRECT rewrite of
 *                  block 0, under background device-queue pressure.
 * mode 1 (case G): faulting pwrite, then ftruncate to 0 -- which frees the
 *                  device block the orphaned BIO is writing to -- then a
 *                  successful O_DIRECT write of block 0, which first-fit
 *                  re-allocates the very same device block. If the orphaned
 *                  write lands afterwards it corrupts a block that has since
 *                  been freed and handed out again.
 */
static void run_case_fg(const char *dir, int mode)
{
	const char *tagname = mode ? "G" : "F";
	const char *casename = mode ? "free_realloc" : "queue_pressure";
	char victim_path[PATH_MAX_LEN], spacer_path[PATH_MAX_LEN];
	char *verify = alloc_aligned(BLK);
	pthread_t th;
	int have_thread = 0;
	int round, clobbered = 0, ok = 0, other = 0, setup_failed = 0;

	load_stop = 0;
	load_ops = 0;
	if (!mode && pthread_create(&th, NULL, load_thread, (void *)dir) == 0)
		have_thread = 1;

	for (round = 0; round < ROUNDS; round++) {
		char tag[32];
		char *base, *ptr;
		int vfd, p;
		char seen;
		ssize_t ret;

		snprintf(tag, sizeof(tag), "%s%d", tagname, round);
		vfd = build_victim(dir, tag, 1, victim_path, spacer_path);
		if (vfd < 0) {
			setup_failed++;
			break;
		}

		base = make_fault_buffer(BLK, &ptr);
		ret = pwrite(vfd, ptr, VICTIM_BYTES, 0);

		if (mode && ftruncate(vfd, 0) != 0) {
			setup_failed++;
			munmap(base, 3 * BLK);
			close(vfd);
			unlink(victim_path);
			unlink(spacer_path);
			continue;
		}

		if (direct_fill_byte(vfd, 0, BLK, LATE_BYTE) != 0) {
			other++;
			munmap(base, 3 * BLK);
			close(vfd);
			unlink(victim_path);
			unlink(spacer_path);
			continue;
		}

		seen = probe_block0(vfd, verify);
		for (p = 1; p < PROBES && seen == LATE_BYTE; p++)
			seen = probe_block0(vfd, verify);

		if (ret < 0 && seen == NEW_BYTE)
			clobbered++;
		else if (seen == LATE_BYTE)
			ok++;
		else
			other++;

		munmap(base, 3 * BLK);
		close(vfd);
		unlink(victim_path);
		unlink(spacer_path);
	}

	load_stop = 1;
	if (have_thread)
		pthread_join(th, NULL);

	printf("CASE %s %-16s rounds=%d clobbered=%d intact=%d other=%d "
	       "setup_failed=%d background_ops=%d VERDICT=%s\n",
	       tagname, casename, ROUNDS, clobbered, ok, other, setup_failed,
	       load_ops,
	       clobbered > 0 ? "SUCCESS_REVERTED_BY_FAILURE" : "NOT_OBSERVED");

	if (clobbered > 0)
		failures++;
	munmap(verify, BLK);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/ext2";
	size_t i;

	setvbuf(stdout, NULL, _IOLBF, 0);
	printf("MC6_START dir=%s block=%d rounds=%d probes=%d\n", dir, BLK,
	       ROUNDS, PROBES);

	scratch = alloc_aligned(VICTIM_BYTES);

	for (i = 0; i < sizeof(CASES) / sizeof(CASES[0]); i++)
		run_case(dir, &CASES[i]);

	run_case_d(dir);
	run_case_e(dir);
	run_case_fg(dir, 0);
	run_case_fg(dir, 1);

	printf("MC6_DONE anomalies=%d\n", failures);
	return failures ? 1 : 0;
}
