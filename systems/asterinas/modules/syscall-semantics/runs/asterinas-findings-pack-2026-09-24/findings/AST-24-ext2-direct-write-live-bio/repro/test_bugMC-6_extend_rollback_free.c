// SPDX-License-Identifier: MPL-2.0
//
// MC-6, challenger extension: the ROLLBACK/CLEANUP path of
// "Ext2 direct write returns while an earlier submitted BIO remains live".
//
// Why this file exists
// --------------------
// The turn-1 reproduction covered only the counterexample's `rangeClass =
// "InPlace"` shape, where `rollback_write` (file.rs:319) is a no-op because
// `end <= old_size`. In that shape the orphaned BIO writes user bytes into the
// file's own block at the offset the user asked for, so there is nothing to
// corrupt. The dangerous shape is the *extending* write:
//
//   InodeInner::write_direct_at (file.rs:290-325)
//     prepare_write(fs, offset, end)          // allocates the new blocks
//     write_direct_blocks(fs, offset, reader) // run 1 submitted, run 2 faults
//     -> Err  =>  rollback_write(old_size, end)
//                   block_manager.truncate_to_byte_len(old_size)   // FREES them
//
// so the kernel returns the device block to the ext2 free bitmap while its own
// unwaited BIO is still writing into it. First-fit then hands that same block
// to the next file that asks for one. That is a block-level write-after-free,
// and it is what "the effect can also intervene with a later operation" means
// concretely.
//
// Structure of one round
// ----------------------
// Phase 0  layout   soak up the low contiguous free space, then create pads and
//                   unlink alternate ones, leaving isolated single-block holes
//                   so any 2-block allocation must straddle two device runs.
//
// Phase 1  control  extend the victim to 8192 with a good buffer (it takes two
//                   non-adjacent holes), then repeat the turn-1 in-place
//                   faulting pwrite on it. Reading back CTRL,BASE proves the
//                   layout really produced two mapped runs and that run 1 was
//                   submitted before run 2 faulted. Without this the negative
//                   result below would be unfalsifiable. Then ftruncate(0),
//                   which frees exactly those two blocks again.
//
// Phase 2  subject  the same faulting pwrite, now EXTENDING from size 0. Run 1
//                   (pattern ORPH) is submitted into the lowest free block;
//                   run 2 faults; rollback frees both. statvfs before/after
//                   shows the blocks came back. A thief file then claims the
//                   lowest free block and writes THIEF into it. If the thief
//                   later reads back ORPH, a syscall that reported EFAULT and
//                   whose blocks were freed has corrupted an unrelated file.
//
// Two layouts, because the first one taught us something
// ------------------------------------------------------
// SPARSE (cases H/H2): soak the low contiguous free space, then punch isolated
//   one-block holes. This does NOT produce two runs: `BlockGroup::alloc_blocks`
//   (block_group.rs:275-296) calls `alloc_consecutive(count)` and only halves
//   `count` when that fails, so while any two adjacent free blocks exist in the
//   group a fresh 2-block allocation comes back contiguous. `control_bad` on
//   every round is the evidence.
// FULL (cases J/J2): create the one-block holes first, then fill the volume to
//   ENOSPC, then punch alternate holes. Now no two adjacent free blocks exist,
//   `alloc_consecutive(2)` must fail, `requested_count` halves to 1, and the
//   extending write's two blocks come from two separate allocations at
//   non-adjacent addresses. That is the only way the newly allocated region
//   spans two mapped runs, which is what the rollback-frees-live-block shape
//   needs.
//
// Escalation: level 0 (H, J) and level 1 (H2, J2 add a background thread that
// keeps the device queue deep). Only open/pwrite/pread/ftruncate/unlink/mmap/
// mprotect/statvfs are used -- no failpoint, no injected state, no kernel
// modification.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#define BLK 4096
#define ROUNDS 64
#define FULL_ROUNDS 32
#define PAD_FILES 24
#define SOAK_BLOCKS 256
#define HOLE_FILES 192
#define FILL_CHUNK_BLOCKS 256
#define FILL_MAX_CHUNKS 16384
/* Refuse to fill anything bigger than a dedicated test volume (4 GiB). */
#define FULL_MAX_FS_BLOCKS 1048576L
#define PRESSURE_BLOCKS 64
#define PATH_MAX_LEN 256

#define BASE_BYTE 'O'  /* victim content before the faulting write */
#define CTRL_BYTE 'P'  /* phase 1 in-place faulting write */
#define ORPH_BYTE 'V'  /* phase 2 extending faulting write == the orphaned BIO */
#define THIEF_BYTE 'T' /* the file that claims the freed block */
#define PAD_BYTE 'p'

static char *scratch; /* page-aligned staging buffer, SOAK_BLOCKS * BLK */
static volatile int pressure_stop;
static volatile unsigned long pressure_ops;

static void die(const char *what)
{
	fprintf(stderr, "MC6X_FATAL %s: %s\n", what, strerror(errno));
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

static int open_direct(const char *path, int flags)
{
	return open(path, flags | O_DIRECT, 0600);
}

/* Direct-write `bytes` of `fill` at `off`. Returns 0 on success. */
static int direct_fill(int fd, long off, size_t bytes, int fill)
{
	ssize_t n;

	memset(scratch, fill, bytes);
	n = pwrite(fd, scratch, bytes, off);
	if (n != (ssize_t)bytes)
		return -1;
	return 0;
}

/*
 * Three anonymous pages with the tail page revoked; `readable` bytes starting
 * at the returned pointer are readable and everything after them faults.
 * Same recipe as the turn-1 reproduction.
 */
static char *make_fault_buffer(size_t readable, int fill, char **out_ptr)
{
	size_t head = 2 * BLK - readable;
	char *base = mmap(NULL, 3 * BLK, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (base == MAP_FAILED)
		die("mmap(faultbuf)");
	memset(base, fill, 3 * BLK);
	if (mprotect(base + 2 * BLK, BLK, PROT_NONE) != 0)
		die("mprotect");
	*out_ptr = base + head;
	return base;
}

/* Uniform byte of `bytes` at `off` read through a fresh O_DIRECT fd, or '?'. */
static char read_uniform(const char *path, long off, size_t bytes, char *buf)
{
	int fd = open_direct(path, O_RDONLY);
	char first;
	size_t i;

	if (fd < 0)
		return '!';
	if (pread(fd, buf, bytes, off) != (ssize_t)bytes) {
		close(fd);
		return '!';
	}
	close(fd);
	first = buf[0];
	for (i = 1; i < bytes; i++)
		if (buf[i] != first)
			return '?';
	return first;
}

static long total_blocks(const char *dir)
{
	struct statvfs vfs;

	if (statvfs(dir, &vfs) != 0)
		return -1;
	return (long)vfs.f_blocks;
}

static unsigned long free_blocks(const char *dir)
{
	struct statvfs vfs;

	if (statvfs(dir, &vfs) != 0)
		return 0;
	return (unsigned long)vfs.f_bfree;
}

/* ------------------------------------------------------------------ layout */

struct layout {
	char soak[PATH_MAX_LEN];
	char pad[PAD_FILES][PATH_MAX_LEN];
};

static void layout_destroy(struct layout *l)
{
	int i;

	for (i = 0; i < PAD_FILES; i++)
		unlink(l->pad[i]);
	unlink(l->soak);
}

/*
 * Consume the low contiguous free space, then punch isolated one-block holes
 * so that any two-block allocation lands on two non-adjacent device blocks.
 */
static int layout_build(const char *dir, struct layout *l)
{
	int i, fd;

	snprintf(l->soak, sizeof(l->soak), "%s/mc6x_soak", dir);
	unlink(l->soak);
	fd = open_direct(l->soak, O_RDWR | O_CREAT | O_TRUNC);
	if (fd < 0)
		return -1;
	if (direct_fill(fd, 0, SOAK_BLOCKS * BLK, PAD_BYTE) != 0) {
		close(fd);
		return -1;
	}
	close(fd);

	for (i = 0; i < PAD_FILES; i++) {
		snprintf(l->pad[i], sizeof(l->pad[i]), "%s/mc6x_pad%d", dir, i);
		unlink(l->pad[i]);
		fd = open_direct(l->pad[i], O_RDWR | O_CREAT | O_TRUNC);
		if (fd < 0)
			return -1;
		if (direct_fill(fd, 0, BLK, PAD_BYTE) != 0) {
			close(fd);
			return -1;
		}
		close(fd);
	}

	/* Punch every other pad: the free list is now isolated singletons. */
	for (i = 1; i < PAD_FILES; i += 2) {
		if (unlink(l->pad[i]) != 0)
			return -1;
		l->pad[i][0] = '\0';
	}
	return 0;
}

/*
 * FULL layout: one-block files first, then the volume is filled to ENOSPC, then
 * alternate one-block files are unlinked. No two adjacent free blocks are left,
 * so `alloc_consecutive(2)` fails and `BlockGroup::alloc_blocks` halves down to
 * single-block allocations -- the only way an extending direct write gets two
 * non-adjacent blocks and therefore two mapped runs.
 */
struct fulllayout {
	char hole[HOLE_FILES][PATH_MAX_LEN];
	char fill[PATH_MAX_LEN];
	long filled_blocks;
};

static void fulllayout_destroy(struct fulllayout *f)
{
	int i;

	unlink(f->fill);
	for (i = 0; i < HOLE_FILES; i++)
		if (f->hole[i][0])
			unlink(f->hole[i]);
}

static int fulllayout_build(const char *dir, struct fulllayout *f)
{
	long off = 0;
	int i, fd;

	for (i = 0; i < HOLE_FILES; i++) {
		snprintf(f->hole[i], sizeof(f->hole[i]), "%s/mc6f_h%03d", dir, i);
		unlink(f->hole[i]);
		fd = open_direct(f->hole[i], O_RDWR | O_CREAT | O_TRUNC);
		if (fd < 0)
			return -1;
		if (direct_fill(fd, 0, BLK, PAD_BYTE) != 0) {
			close(fd);
			return -1;
		}
		close(fd);
	}

	snprintf(f->fill, sizeof(f->fill), "%s/mc6f_fill", dir);
	unlink(f->fill);
	fd = open_direct(f->fill, O_RDWR | O_CREAT | O_TRUNC);
	if (fd < 0)
		return -1;
	memset(scratch, PAD_BYTE, (size_t)FILL_CHUNK_BLOCKS * BLK);
	for (i = 0; i < FILL_MAX_CHUNKS; i++) {
		if (pwrite(fd, scratch, (size_t)FILL_CHUNK_BLOCKS * BLK, off) !=
		    (ssize_t)((size_t)FILL_CHUNK_BLOCKS * BLK))
			break;
		off += (long)FILL_CHUNK_BLOCKS * BLK;
	}
	/* squeeze out whatever is left one block at a time */
	for (i = 0; i < FILL_CHUNK_BLOCKS * 8; i++) {
		if (pwrite(fd, scratch, BLK, off) != (ssize_t)BLK)
			break;
		off += BLK;
	}
	close(fd);
	f->filled_blocks = off / BLK;

	for (i = 1; i < HOLE_FILES; i += 2) {
		if (unlink(f->hole[i]) != 0)
			return -1;
		f->hole[i][0] = '\0';
	}
	return 0;
}

/* ---------------------------------------------------------------- pressure */

struct pressure_arg {
	char path[PATH_MAX_LEN];
};

static void *pressure_fn(void *raw)
{
	struct pressure_arg *arg = raw;
	char *buf = alloc_aligned(PRESSURE_BLOCKS * BLK);
	int fd = open_direct(arg->path, O_RDWR | O_CREAT | O_TRUNC);

	if (fd < 0)
		return NULL;
	memset(buf, 'q', PRESSURE_BLOCKS * BLK);
	while (!pressure_stop) {
		if (pwrite(fd, buf, PRESSURE_BLOCKS * BLK, 0) ==
		    (ssize_t)(PRESSURE_BLOCKS * BLK))
			pressure_ops++;
	}
	close(fd);
	return NULL;
}

/* ------------------------------------------------------------------- cases */

struct tally {
	int rounds;
	int control_ok;    /* phase 1 proved two mapped runs */
	int control_bad;   /* phase 1 saw a single run -- layout not fragmented */
	int setup_failed;
	int freed_ok;      /* statvfs showed the blocks came back */
	int freed_leak;    /* rollback did not return the blocks */
	int clobbered;     /* the thief read back the orphan's pattern */
	int intact;
	int other;
	int thief_failed;
};

static void run_case(const char *dir, const char *tag, const char *name,
		     int pressure, int full)
{
	struct tally t;
	struct layout l;
	struct fulllayout fl;
	pthread_t th;
	struct pressure_arg parg;
	char victim_path[PATH_MAX_LEN], thief_path[PATH_MAX_LEN];
	char *verify = alloc_aligned(2 * BLK);
	char *ctrl_base, *ctrl_ptr, *orph_base, *orph_ptr;
	int round, nrounds = full ? FULL_ROUNDS : ROUNDS;

	memset(&t, 0, sizeof(t));
	memset(&fl, 0, sizeof(fl));
	if (full && total_blocks(dir) > FULL_MAX_FS_BLOCKS) {
		printf("CASE %s %-24s SKIPPED_LARGE_FS (%s has %ld blocks)\n",
		       tag, name, dir, total_blocks(dir));
		fflush(stdout);
		return;
	}
	if (full && fulllayout_build(dir, &fl) != 0) {
		fulllayout_destroy(&fl);
		printf("CASE %s %-24s SETUP_FAILED (could not fill %s)\n", tag,
		       name, dir);
		fflush(stdout);
		return;
	}
	snprintf(victim_path, sizeof(victim_path), "%s/mc6x_victim_%s", dir, tag);
	snprintf(thief_path, sizeof(thief_path), "%s/mc6x_thief_%s", dir, tag);

	ctrl_base = make_fault_buffer(BLK, CTRL_BYTE, &ctrl_ptr);
	orph_base = make_fault_buffer(BLK, ORPH_BYTE, &orph_ptr);

	if (pressure) {
		snprintf(parg.path, sizeof(parg.path), "%s/mc6x_press_%s", dir,
			 tag);
		pressure_stop = 0;
		pressure_ops = 0;
		if (pthread_create(&th, NULL, pressure_fn, &parg) != 0)
			pressure = 0;
	}

	for (round = 0; round < nrounds; round++) {
		unsigned long bfree_before, bfree_after;
		char blk0, blk1, stolen;
		struct stat st;
		ssize_t ret;
		int vfd, tfd;

		unlink(victim_path);
		unlink(thief_path);
		memset(&l, 0, sizeof(l));
		if (!full && layout_build(dir, &l) != 0) {
			t.setup_failed++;
			layout_destroy(&l);
			continue;
		}

		vfd = open_direct(victim_path, O_RDWR | O_CREAT | O_TRUNC);
		if (vfd < 0) {
			t.setup_failed++;
			if (!full)
				layout_destroy(&l);
			continue;
		}

		/* -------- phase 1: control, proves the two-run layout -------- */
		if (direct_fill(vfd, 0, 2 * BLK, BASE_BYTE) != 0) {
			t.setup_failed++;
			close(vfd);
			if (!full)
				layout_destroy(&l);
			continue;
		}
		ret = pwrite(vfd, ctrl_ptr, 2 * BLK, 0);
		if (ret != -1 || errno != EFAULT) {
			t.setup_failed++;
			close(vfd);
			if (!full)
				layout_destroy(&l);
			continue;
		}
		blk0 = read_uniform(victim_path, 0, BLK, verify);
		blk1 = read_uniform(victim_path, BLK, BLK, verify);
		if (blk0 == CTRL_BYTE && blk1 == BASE_BYTE)
			t.control_ok++;
		else
			t.control_bad++;

		if (ftruncate(vfd, 0) != 0) {
			t.setup_failed++;
			close(vfd);
			if (!full)
				layout_destroy(&l);
			continue;
		}

		/* -------- phase 2: the extending write and its rollback ------ */
		bfree_before = free_blocks(dir);
		ret = pwrite(vfd, orph_ptr, 2 * BLK, 0);
		bfree_after = free_blocks(dir);
		if (ret != -1 || errno != EFAULT) {
			t.setup_failed++;
			close(vfd);
			if (!full)
				layout_destroy(&l);
			continue;
		}
		if (fstat(vfd, &st) == 0 && st.st_size != 0)
			t.other++;
		if (bfree_after >= bfree_before)
			t.freed_ok++;
		else
			t.freed_leak++;

		/* Claim the block the orphaned BIO is writing into. */
		tfd = open_direct(thief_path, O_RDWR | O_CREAT | O_TRUNC);
		if (tfd < 0 || direct_fill(tfd, 0, BLK, THIEF_BYTE) != 0) {
			t.thief_failed++;
			if (tfd >= 0)
				close(tfd);
			close(vfd);
			if (!full)
				layout_destroy(&l);
			continue;
		}
		close(tfd);

		stolen = read_uniform(thief_path, 0, BLK, verify);
		if (stolen == ORPH_BYTE)
			t.clobbered++;
		else if (stolen == THIEF_BYTE)
			t.intact++;
		else
			t.other++;

		close(vfd);
		unlink(victim_path);
		unlink(thief_path);
		if (!full)
			layout_destroy(&l);
		t.rounds++;
	}

	if (pressure) {
		pressure_stop = 1;
		pthread_join(th, NULL);
		snprintf(parg.path, sizeof(parg.path), "%s/mc6x_press_%s", dir,
			 tag);
		unlink(parg.path);
	}
	if (full)
		fulllayout_destroy(&fl);
	munmap(ctrl_base, 3 * BLK);
	munmap(orph_base, 3 * BLK);
	munmap(verify, 2 * BLK);

	printf("CASE %s %-24s rounds=%d control_ok=%d control_bad=%d "
	       "freed_ok=%d freed_leak=%d clobbered=%d intact=%d other=%d "
	       "setup_failed=%d thief_failed=%d filled_blocks=%ld "
	       "background_ops=%lu VERDICT=%s\n",
	       tag, name, t.rounds, t.control_ok, t.control_bad, t.freed_ok,
	       t.freed_leak, t.clobbered, t.intact, t.other, t.setup_failed,
	       t.thief_failed, full ? fl.filled_blocks : 0L,
	       pressure ? pressure_ops : 0UL,
	       t.clobbered > 0		? "CLOBBERED"
	       : t.control_ok == 0	? "SETUP_FAILED"
					: "NOT_OBSERVED");
	fflush(stdout);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";
	/* The FULL layout fills the volume to ENOSPC, so it needs an explicit
	 * opt-in and a dedicated test volume. */
	int allow_full = argc > 2 && strcmp(argv[2], "full") == 0;

	scratch = alloc_aligned(SOAK_BLOCKS * BLK);
	printf("MC6X_START dir=%s block=%d rounds=%d fs_blocks=%ld full=%d\n",
	       dir, BLK, ROUNDS, total_blocks(dir), allow_full);
	fflush(stdout);

	run_case(dir, "H", "sparse_extend_xfile", 0, 0);
	run_case(dir, "H2", "sparse_extend_pressure", 1, 0);
	if (allow_full) {
		run_case(dir, "J", "full_extend_xfile", 0, 1);
		run_case(dir, "J2", "full_extend_pressure", 1, 1);
	}

	printf("MC6X_DONE dir=%s\n", dir);
	fflush(stdout);
	return 0;
}
