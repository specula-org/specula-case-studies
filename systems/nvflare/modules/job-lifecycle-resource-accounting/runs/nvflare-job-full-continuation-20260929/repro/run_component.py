#!/usr/bin/env python3
"""Replay an archived component test against a clean pinned source export."""

import argparse
import ast
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

REVISION = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
TESTS = {
    "CR-4": "test_bugCR-4_malformed_metadata.py",
    "CR-7": "test_bugCR-7_fractional_gpu_accounting.py",
    "CR-24": "test_bugCR-24_start_run_status_race.py",
}
ORIGINAL_PREFIX = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=TESTS)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, help="Parent of the temporary source export")
    parser.add_argument("--execute", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    script = Path(__file__).resolve().parent / TESTS[args.case]

    if args.execute is not None:
        old_path = ORIGINAL_PREFIX + args.case + "/worktree"
        new_path = str(args.execute.resolve())
        tree = ast.parse(script.read_text(), filename=str(script))
        replacements = 0

        class RelocateSource(ast.NodeTransformer):
            def visit_Constant(self, node):
                nonlocal replacements
                if node.value == old_path:
                    replacements += 1
                    return ast.copy_location(ast.Constant(new_path), node)
                return node

        tree = RelocateSource().visit(tree)
        if replacements != 1:
            raise RuntimeError(f"Expected one source-path literal, found {replacements}")
        ast.fix_missing_locations(tree)
        sys.argv = [str(script)]
        print(f"Pinned source: {REVISION}; relocated source: {new_path}", flush=True)
        exec(compile(tree, str(script), "exec"), {"__name__": "__main__", "__file__": str(script)})
        return 0

    actual = subprocess.check_output(
        ["git", "-C", str(args.source_repo), "rev-parse", REVISION + "^{commit}"], text=True
    ).strip()
    if actual != REVISION:
        raise RuntimeError("Source revision mismatch")
    payload = subprocess.check_output(["git", "-C", str(args.source_repo), "archive", REVISION])
    with tempfile.TemporaryDirectory(prefix="nvflare-component-", dir=args.work_dir) as temporary:
        source = Path(temporary) / "source"
        source.mkdir()
        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            archive.extractall(source, filter="data")
        try:
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), args.case,
                 "--source-repo", str(args.source_repo), "--execute", str(source)],
                cwd=temporary, timeout=120,
            )
        except subprocess.TimeoutExpired:
            print("Component replay timed out", file=sys.stderr)
            return 124
        return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
