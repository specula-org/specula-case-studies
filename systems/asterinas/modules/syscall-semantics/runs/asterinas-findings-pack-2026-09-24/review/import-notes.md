# Import notes

This import preserves all 72 AST records and their historical evidence statuses.
It does not rerun or independently adjudicate the findings. Original reports
retain their source observations, qualifications, and historical fix state.

## Upstream reconciliation, checked 2026-09-24

- [PR #3875](https://github.com/asterinas/asterinas/pull/3875) is open and covers
  empty writes in ramfs and exFAT. It is relevant to AST-02's empty-write subcase
  and AST-14. AST-14's original metadata predates this association and still
  records no direct upstream match. AST-02's zero-progress copy-fault cases are
  a separate residual scope.
- [PR #3778](https://github.com/asterinas/asterinas/pull/3778) is open; the
  collection associates AST-05 and AST-10 with its read/resize changes. The
  [2026-09-03 review](https://github.com/asterinas/asterinas/pull/3778#discussion_r3920838790)
  identifies the resize race before the recorded 01b run.
- [Issue #711](https://github.com/asterinas/asterinas/issues/711) remains open
  and is the known partial-progress family shared by AST-01/04. The ext2
  durability consequence and read replay consequence remain separate records.
- [PR #3481](https://github.com/asterinas/asterinas/pull/3481) and
  [PR #3576](https://github.com/asterinas/asterinas/pull/3576) remain open.
  Their AST-06 and AST-09 coverage is attributed to the supplied reports;
  curation did not rerun either patch.

## File handling

The original package README is retained as `source-README.md`; `README.md` is
the collection entry point. Package assembly files under `_build/` and macOS
metadata are excluded. Canonical reproduction variants remain present.
Relative Markdown links to artifacts outside the supplied package are rendered
as unavailable-source notes. Source and destination hashes distinguish these
navigation edits from unchanged files. Executable reproduction sources and
scripts retain their original contents. Their environment-specific paths are
not rewritten or presented as a portable runner. Local attributes preserve
patch context and the original AST-04 shell script's whitespace byte for byte.
