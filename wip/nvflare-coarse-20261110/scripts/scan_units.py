#!/usr/bin/env python3
"""Uniform static scan for STANDARD.md unit candidates in a list of source files.

scan_units.py REGION_FILE [--out notes/scan-<name>.csv]

For every file (paths relative to nvflare/ at the pinned source) it reports, with
the enclosing function:
  T  thread / timer / executor creation (threading.Thread, Timer, submit, ...)
  K  keyed-record operations on instance containers: `del self.x[k]`,
     `self.x.pop(k)` without a default, `self.x[k] = v`, `self.x[k]` reads
     (only for attributes initialized as dict/list/set somewhere in the file)
  I  iteration over an instance container without a snapshot (list()/copy)
  G  process-global state: os.environ writes, `global`, module-level mutables
  X  external operations: job store, process, container API, cell requests,
     file persistence, status updates
The scan only produces candidates; each is classified by hand in the ledger.
"""
import ast, csv, re, sys
from pathlib import Path

SRC = Path("/home/ubuntu/nvflare-integrated-model-20261103/sources/current/nvflare")
XOPS = {
    "store": r"\b(set_status|update_meta|set_results_uri|delete|save_workspace|create|get_job|get_jobs_by_status|update_job_status|_scan)\(",
    "proc": r"\b(Popen|subprocess\.run|kill|terminate|wait|poll|create_namespaced_pod|delete_namespaced_pod|read_namespaced_pod|containers\.run|remove)\(",
    "cell": r"\b(send_request|broadcast_request|fire_and_forget|broadcast_multi_requests|send_aux_request|multicast_aux_requests|send_reliable_request|aux_send|send_to_peer)\(",
    "persist": r"\b(torch\.save|np\.save|os\.replace|os\.rename|fsync|shutil\.rmtree|os\.remove|write_bytes|write_text)\(",
    "status": r"\b(system_panic|update_job_run_status|fire_event|notify_job_status|_set_status|set_run_status)\(",
}


def containers(tree):
    names = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Attribute) and isinstance(t.value, ast.Name) and t.value.id == "self":
                    v = n.value
                    if isinstance(v, (ast.Dict, ast.List, ast.Set)) or (
                            isinstance(v, ast.Call) and isinstance(v.func, ast.Name)
                            and v.func.id in ("dict", "list", "set", "OrderedDict", "defaultdict", "deque")):
                        names.add(t.attr)
    return names


def funcs(tree):
    """line -> enclosing qualified function name"""
    spans = []
    def walk(node, prefix):
        for ch in ast.iter_child_nodes(node):
            if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef)):
                q = prefix + ch.name
                spans.append((ch.lineno, ch.end_lineno, q))
                walk(ch, q + ".")
            elif isinstance(ch, ast.ClassDef):
                walk(ch, prefix + ch.name + ".")
            else:
                walk(ch, prefix)
    walk(tree, "")
    def at(line):
        best = ""
        for a, b, q in spans:
            if a <= line <= b and len(q) >= len(best):
                best = q
        return best or "<module>"
    return at


def scan(rel):
    p = SRC / rel
    text = p.read_text()
    tree = ast.parse(text)
    conts = containers(tree)
    at = funcs(tree)
    lines = text.splitlines()
    rows = []
    for i, line in enumerate(lines, 1):
        code = line.split("#")[0]
        if not code.strip():
            continue
        f = at(i)
        def add(kind, what):
            rows.append(dict(file_line=f"{rel}:{i}", kind=kind, func=f, what=what, code=code.strip()[:160]))
        if re.search(r"threading\.Thread\(|\bThread\(target|threading\.Timer\(|\bTimer\(|\.submit\(|ThreadPoolExecutor\(|run_in_thread|start_new_thread", code):
            add("T", "thread/timer/executor")
        for m in re.finditer(r"\bdel\s+self\.(\w+)\[", code):
            if m.group(1) in conts:
                add("K", f"del {m.group(1)}[k]")
        for m in re.finditer(r"\bself\.(\w+)\.pop\(([^)]*)\)", code):
            if m.group(1) in conts:
                args = m.group(2)
                add("K", f"pop {m.group(1)}" + (" (default)" if "," in args else " (no default)"))
        for m in re.finditer(r"\bself\.(\w+)\[([^\]]+)\]\s*=(?!=)", code):
            if m.group(1) in conts:
                add("K", f"set {m.group(1)}[k]")
        for m in re.finditer(r"\bself\.(\w+)\[([^\]]+)\](?!\s*=)", code):
            if m.group(1) in conts and not re.search(r"\bdel\s+self\." + m.group(1), code):
                add("K", f"get {m.group(1)}[k]")
        m = re.search(r"\bfor\s+.+\s+in\s+self\.(\w+)(\.(items|keys|values)\(\))?\s*:", code)
        if m and m.group(1) in conts:
            add("I", f"iterate {m.group(1)} (no snapshot)")
        if re.search(r"os\.environ\[[^\]]+\]\s*=|os\.environ\.update|os\.putenv", code):
            add("G", "os.environ write")
        if re.match(r"\s*global\s+\w+", code):
            add("G", "global")
        for k, rx in XOPS.items():
            if re.search(rx, code):
                add("X", k)
    # module-level mutable containers
    for n in tree.body:
        if isinstance(n, ast.Assign) and isinstance(n.value, (ast.Dict, ast.List, ast.Set)):
            for t in n.targets:
                if isinstance(t, ast.Name) and not t.id.isupper():
                    rows.append(dict(file_line=f"{rel}:{n.lineno}", kind="G", func="<module>",
                                     what=f"module mutable {t.id}", code=lines[n.lineno - 1].strip()[:160]))
    return rows


def main():
    region = Path(sys.argv[1])
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else None
    rows = []
    for rel in [l.strip() for l in region.read_text().splitlines() if l.strip() and not l.startswith("#")]:
        rows += scan(rel)
    if out:
        with out.open("w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=["file_line", "kind", "func", "what", "code"])
            w.writeheader(); w.writerows(rows)
    from collections import Counter
    c = Counter(r["kind"] for r in rows)
    print(dict(c), "total", len(rows))


if __name__ == "__main__":
    main()
