# Case Studies Git Management

Rules for managing the `case-studies` repository. Follow these when adding new case studies, committing changes, or cleaning up.

## Directory Structure

Each case study follows this layout:

```
<case-name>/
  spec/           # TLA+ specs (base.tla, MC.tla, Trace.tla, configs, bug-report.md)
  harness/        # Instrumentation (apply.sh, run.sh, patches/, src/)
  artifact/       # Source code under analysis (git submodule)
  traces/         # Trace files (gitignored)
  repro/          # Bug reproduction code
  invariants/     # Reference docs for invariant design
  analysis-report.md
  modeling-brief.md
```

## What Gets Committed

- `spec/` — all TLA+ specs, configs, reports
- `harness/` — apply.sh, run.sh, patches/, src/ (instrumentation code)
- `analysis-report.md`, `modeling-brief.md`
- `repro/` — reproduction scripts and test code
- `invariants/` — reference documents
- `.gitignore` updates

## What Is Gitignored

Already covered by `.gitignore` — do NOT commit these:

- `*.log`, `*.pid` — agent/pipeline runtime files
- `*.raw.json`, `*.usage.json` — pipeline output
- `traces/`, `*.ndjson`, `*.ndjson.raw` — trace data
- `states/`, `*.st`, `*.fp` — TLC state files
- `**/artifact/build*/` — build directories
- `.prompts/`, `*-prompt.md` — generated prompts
- `nohup*.out`, `*.orig` — temp files

If you encounter a new category of generated files, add a rule to `.gitignore` before committing.

## Artifact Management

Artifacts are source code repositories. They are ALWAYS registered as **git submodules**.

### Adding a new artifact

1. If the artifact is a plain directory (not a git repo), initialize it:
   ```
   rm -rf <case>/artifact/<name>
   git submodule add <upstream-url> <case>/artifact/<name>
   ```

2. If it's already a git clone, move it out and re-add as submodule:
   ```
   mv <case>/artifact/<name> <case>/artifact/<name>.bak
   git submodule add <url> <case>/artifact/<name>
   cd <case>/artifact/<name> && git checkout <commit>
   rm -rf <case>/artifact/<name>.bak
   ```

### Instrumentation handling

**CRITICAL: Never discard instrumentation changes. Always preserve them as either a fork commit or a patch before restoring an artifact to clean state.**

There are two approaches:

#### Approach A: Fork (for specula-org forks)

If the artifact already has a fork on `specula-org/`, or if the changes are substantial:

1. Set remote to the fork: `git remote set-url origin https://github.com/specula-org/<repo>.git`
2. Commit instrumentation: `git add -A && git commit -m "add trace instrumentation"`
3. Push: `git push origin HEAD:<branch>`
4. Update submodule pointer in case-studies: `git add <case>/artifact/<name>`

#### Approach B: Patch (for upstream repos)

If the artifact points to upstream and changes are small:

1. Generate the patch (including untracked files):
   ```
   cd <case>/artifact/<name>
   git add -A
   git diff --cached > ../../harness/patches/instrumentation.patch
   git reset HEAD .
   ```
2. Restore artifact to clean: `git checkout -- . && git clean -fd`
3. Commit the patch to case-studies: `git add <case>/harness/patches/instrumentation.patch`

The `harness/apply.sh` script should apply the patch:
```bash
cd "$ARTIFACT_DIR" && git checkout -- .
git apply "$SCRIPT_DIR/patches/instrumentation.patch"
```

### Shared artifacts

When multiple case studies use the same upstream repo at the same commit:

1. Register the submodule in ONE case study (e.g., `mongodb/artifact/mongo-src`)
2. In others, use a **symlink**: `ln -s ../../mongodb/artifact/mongo-src <other-case>/artifact/mongo-src`
3. Commit the symlinks

**Exception:** If case studies need independent instrumentation (different patches applied simultaneously), each must have its own submodule — do NOT share via symlink.

### Orphan submodules

If a submodule is in the git index (`git ls-files --stage | grep 160000`) but NOT in `.gitmodules`, it's an orphan. Remove with `git rm --cached <path>`.

### Local path remotes

Artifact remotes must be HTTPS URLs, not local paths. Local paths like `/home/ubuntu/...` break on other machines. Fix with:
```
git remote set-url origin https://github.com/<org>/<repo>.git
```

## Forking

**Always ask the user before creating a fork on specula-org.** Use `gh repo fork <upstream> --org specula-org --clone=false`.

## Commit Workflow

When adding a new case study:

1. Update `.gitignore` if new file patterns need ignoring
2. `git add` all non-artifact content (spec/, harness/, reports, repro/)
3. Commit: `git commit -m "add <case-name> case study"`
4. Handle artifacts (submodule registration, fork/patch)
5. Commit: `git commit -m "register <case-name> artifact submodule"`
6. After all case-studies commits, update the pointer in the parent Specula repo:
   ```
   cd /home/ubuntu/Specula
   git add case-studies
   git commit -m "update case-studies submodule pointer"
   ```

## Checklist Before Committing

- [ ] No `*.raw.json`, `*.usage.json`, `*.log`, `*.pid` files staged
- [ ] No `traces/` or `*.ndjson` files staged
- [ ] All artifact directories are submodules (not plain directories)
- [ ] Dirty artifacts: instrumentation preserved (fork push or patch saved)
- [ ] Artifact remotes are HTTPS URLs (not local paths)
- [ ] No orphan submodule entries (index vs .gitmodules mismatch)
- [ ] Symlinks used for shared artifacts (same repo, same commit)
- [ ] Parent Specula repo pointer updated after case-studies commits
