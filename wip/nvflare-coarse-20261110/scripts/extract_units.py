#!/usr/bin/env python3
"""Static unit extraction for the full-system ledger (PROMPT step 4, STANDARD 9 and 13).

extract_units.py [--chunks c1,c2,...]  -> notes/units-scope.csv

For every in-scope file (notes/scope.csv, decisions c1..c7) the AST gives:
  T  thread entries: Thread(target=self.m) / Timer(.., self.m) / submit(self.m) /
     run_in_thread / start_new_thread, and run() of Thread subclasses
  H  callbacks: a method passed as a value (not called): message / aux / command /
     event handlers, result callbacks; `handle_event` of components
  S  object state: an instance attribute written outside __init__, or an instance
     container mutated anywhere (keyed records: set/pop/del by key are noted)
  G  process-global state: module-level mutables written at run time, `global`
     writes, class-level containers mutated, os.environ writes
  X  external operations in other functions: cell / aux sends, processes and
     containers, file and store persistence, status updates and events
Lifetime and sharing are assigned by the rules in STANDARD 13 (written out in
classify() below); the selection rule marks a unit `select` when its lifetime is at
least job and its sharing at least cross-component. These are candidates: each
chunk's rows are reviewed by reading the code when the chunk is built (the review
column records whether that happened).
"""
import ast, csv, re, sys
from collections import defaultdict
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SRC = Path("/home/ubuntu/nvflare-integrated-model-20261103/sources/current/nvflare")
PROCESS_HOST = {"c1", "c2", "c6", "c7"}   # code that runs in the SP / CP parent (hosts many jobs)
LIFE_RANK = {"request": 0, "round": 1, "job": 2, "process": 3, "persistent": 4}
SHARE_RANK = {"component": 0, "cross-component": 1, "cross-process": 2, "cross-job": 3}
MUTATORS = {"append", "add", "pop", "update", "clear", "remove", "discard", "setdefault", "extend", "insert",
            "popitem", "appendleft", "popleft", "put", "put_nowait", "get_nowait"}
REMOTE_REG = re.compile(r"register_request_cb|register_aux_message_handler|register_message_handler|"
                        r"add_handler|register_.*topic|register_.*channel|set_message_handler|register_stream|"
                        r"register_blob_cb|register_objects?_cb|register_.*_cb|register_request_handler|"
                        r"register_command|add_command|CommandSpec|register_processor")
XOPS = {
    "cell": r"\b(send_request|broadcast_request|fire_and_forget|broadcast_multi_requests|send_aux_request|"
            r"multicast_aux_requests|send_reliable_request|aux_send|send_to_peer|fire_multi_requests_and_forget|"
            r"queue_message|send_blob|send_objects?|stream_\w+)\(",
    "proc": r"\b(Popen|subprocess\.run|subprocess\.call|kill|terminate|os\.kill|killpg|create_namespaced_\w+|"
            r"delete_namespaced_\w+|containers\.run)\(",
    "persist": r"\b(torch\.save|np\.save|os\.replace|os\.rename|fsync|shutil\.rmtree|shutil\.move|os\.remove|"
               r"write_bytes|write_text|json\.dump|pickle\.dump|open\([^)]*['\"][wa]b?['\"])",
    "store": r"\b(set_status|update_meta|set_results_uri|save_workspace|create_job|delete_job|update_job_status|"
             r"set_job_status|persist_components|save_snapshot)\(",
    "status": r"\b(system_panic|fire_event|fire_fed_event|update_job_run_status|notify_job_status|_set_status|"
              r"set_run_status|abort_task|stop_run|abort_job)\(",
}
DATA_CLASS = re.compile(r"(Request|Reply|Message|Msg|Context|Spec|Error|Exception|Config|Args|Item|Info|Result|"
                        r"Event|Constants?|Keys?|Type|Status|Def|Meta|Header|Record|Dict|Struct)$")
PROC_CLASS = re.compile(r"(Engine|Server|Cell|Connector|Driver|Manager|Agent|Registry|Keeper|Session|Sess|Deployer|"
                        r"Relay|Admin|API|Api|Proxy|Monitor|Bridge|Backend|Endpoint|Conn|Connection|Listener|Pool|"
                        r"Service|Channel|Router|Runner)$")
CONFIG_CLASS = re.compile(r"(Configurator|Configer|Deployer|Builder|Validator|Factory|Loader|Parser|Checker)$")
JOB_CLASS = re.compile(r"(Executor|Controller|Workflow|Widget|Launcher|Ctl|Persistor|Gatherer|Assessor|Handler|"
                       r"Responder|Learner|Trainer|Aggregator|Updater|Coordinator|Applet)$")


def name_of(f):
    if isinstance(f, ast.Name):
        return f.id
    if isinstance(f, ast.Attribute):
        return name_of(f.value) + "." + f.attr
    return "?"


def self_attr(n):
    return n.attr if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "self" else None


class ClassScan:
    def __init__(self, cls, text):
        self.cls = cls; self.text = text
        self.methods = {m.name: m for m in cls.body if isinstance(m, (ast.FunctionDef, ast.AsyncFunctionDef))}
        self.bases = [name_of(b) for b in cls.bases]
        self.reads = defaultdict(set); self.writes = defaultdict(set); self.keyed = defaultdict(set)
        self.containers = set(); self.threads = {}; self.callbacks = {}; self.remote_cbs = set()
        self.xops = defaultdict(set)
        for mname, m in self.methods.items():
            self.scan_method(mname, m)
        if any(b.endswith("Thread") for b in self.bases) and "run" in self.methods:
            self.threads.setdefault("run", self.methods["run"].lineno)
        if "handle_event" in self.methods:
            self.callbacks.setdefault("handle_event", self.methods["handle_event"].lineno)

    def scan_method(self, mname, m):
        for n in ast.walk(m):
            if isinstance(n, ast.Assign) or isinstance(n, ast.AnnAssign) or isinstance(n, ast.AugAssign):
                tgts = n.targets if isinstance(n, ast.Assign) else [n.target]
                for t in tgts:
                    for tt in (t.elts if isinstance(t, ast.Tuple) else [t]):
                        a = self_attr(tt)
                        if a:
                            self.writes[a].add(mname)
                            v = getattr(n, "value", None)
                            if isinstance(v, (ast.Dict, ast.List, ast.Set)) or (
                                    isinstance(v, ast.Call) and name_of(v.func).split(".")[-1] in
                                    ("dict", "list", "set", "OrderedDict", "defaultdict", "deque", "Queue")):
                                self.containers.add(a)
                        if isinstance(tt, ast.Subscript) and self_attr(tt.value):
                            self.writes[self_attr(tt.value)].add(mname); self.keyed[self_attr(tt.value)].add("set")
            elif isinstance(n, ast.Delete):
                for t in n.targets:
                    if isinstance(t, ast.Subscript) and self_attr(t.value):
                        self.writes[self_attr(t.value)].add(mname); self.keyed[self_attr(t.value)].add("del")
            elif isinstance(n, ast.Call):
                fn = n.func
                if isinstance(fn, ast.Attribute) and self_attr(fn.value) and fn.attr in MUTATORS:
                    a = self_attr(fn.value); self.writes[a].add(mname)
                    if fn.attr in ("pop", "setdefault", "popitem"):
                        self.keyed[a].add(fn.attr)
                fname = name_of(fn)
                args = list(n.args) + [k.value for k in n.keywords]
                kw = {k.arg: k.value for k in n.keywords}
                tgt = None
                if fname.endswith("Thread") and "target" in kw:
                    tgt = kw["target"]
                elif fname.endswith("Timer") and len(n.args) >= 2:
                    tgt = n.args[1]
                elif fname.split(".")[-1] in ("submit", "run_in_thread", "start_new_thread", "call_soon_threadsafe") and n.args:
                    tgt = n.args[0]
                if tgt is not None and self_attr(tgt) in self.methods:
                    self.threads.setdefault(self_attr(tgt), n.lineno)
                for a in args:
                    sa = self_attr(a)
                    if sa in self.methods and a is not tgt:
                        self.callbacks.setdefault(sa, n.lineno)
                        if REMOTE_REG.search(fname):
                            self.remote_cbs.add(sa)
            elif isinstance(n, ast.Attribute):
                a = self_attr(n)
                if a:
                    self.reads[a].add(mname)
        seg = ast.get_source_segment(self.text, m) or ""
        for k, rx in XOPS.items():
            if re.search(rx, seg):
                self.xops[mname].add(k)

    def kind(self, mname):
        if mname in self.threads:
            return "thread"
        if mname in self.callbacks:
            return "remote" if mname in self.remote_cbs else "callback"
        return "public" if not mname.startswith("_") else "private"


def lifetime_of_class(cname, chunk):
    if PROC_CLASS.search(cname):
        return "process"
    if JOB_CLASS.search(cname):
        return "job"
    return "process" if chunk in PROCESS_HOST else "job"


def classify(rows, chunk):
    for r in rows:
        life, share = r["lifetime"], r["sharing"]
        r["select"] = "select" if LIFE_RANK[life] >= LIFE_RANK["job"] and SHARE_RANK[share] >= SHARE_RANK["cross-component"] \
            else "excluded: short-lived or local"
    return rows


def scan_file(rel, chunk):
    text = (SRC / rel).read_text(errors="ignore")
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    mod = rel[:-3].replace("/", ".")
    rows = []

    def add(uid, line, utype, life, share, what):
        rows.append(dict(id=uid, file_line=f"{rel}:{line}", unit_type=utype, chunk=chunk, lifetime=life,
                         sharing=share, effects=what))
    # module-level mutables and `global` writes
    mod_mut = {}
    for n in tree.body:
        if isinstance(n, (ast.Assign, ast.AnnAssign)):
            tg = n.targets if isinstance(n, ast.Assign) else [n.target]
            v = n.value
            if v is not None and (isinstance(v, (ast.Dict, ast.List, ast.Set)) or (
                    isinstance(v, ast.Call) and (name_of(v.func).split(".")[-1] in
                                                 ("dict", "list", "set", "OrderedDict", "defaultdict", "deque")
                                                 or name_of(v.func).split(".")[-1][:1].isupper()))):
                for t in tg:
                    if isinstance(t, ast.Name) and not t.id.isupper():
                        mod_mut[t.id] = n.lineno
    gw = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Global):
            gw.update(n.names)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and isinstance(n.func.value, ast.Name) \
                and n.func.value.id in mod_mut and n.func.attr in MUTATORS:
            gw.add(n.func.value.id)
        if isinstance(n, ast.Subscript) and isinstance(n.ctx, (ast.Store, ast.Del)) and isinstance(n.value, ast.Name) \
                and n.value.id in mod_mut:
            gw.add(n.value.id)
    for g in sorted(gw):
        add(f"{mod}:{g}", mod_mut.get(g, 1), "G", "process", "cross-job" if chunk in PROCESS_HOST else "cross-component",
            "module-level state written at run time")
    for m in re.finditer(r"os\.environ\[[^\]]+\]\s*=|os\.environ\.update|os\.putenv", text):
        line = text[:m.start()].count("\n") + 1
        add(f"{mod}:environ@{line}", line, "G", "process", "cross-job", "os.environ write (inherited by child processes)")
    resolved = set()
    for cls in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
        for line in ClassScan(cls, text).threads.values():
            resolved.add(line)
    spans = sorted([(n.lineno, n.end_lineno, n.name) for n in ast.walk(tree)
                    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))])
    def encl(line):
        best = None
        for a, b, nm in spans:
            if a <= line <= b:
                best = nm if best is None else best + "." + nm
        return best or "<module>"
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and n.lineno not in resolved:
            fname = name_of(n.func); kw = {k.arg: k.value for k in n.keywords}
            tgt = kw.get("target") if fname.endswith("Thread") else (n.args[1] if fname.endswith("Timer") and len(n.args) >= 2
                  else (n.args[0] if fname.split(".")[-1] in ("submit", "run_in_thread", "start_new_thread") and n.args else None))
            if tgt is not None:
                tname = ast.get_source_segment(text, tgt) or "?"
                add(f"{mod}.{encl(n.lineno)}->{re.sub(r'[^A-Za-z0-9_.]', '', tname)[:40]}@{n.lineno}", n.lineno, "T",
                    "process" if chunk in PROCESS_HOST else "job", "cross-component", f"thread entry {tname[:60]}")
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and name_of(n.func).split(".")[-1] == "ThreadPoolExecutor":
            add(f"{mod}.{encl(n.lineno)}->pool@{n.lineno}", n.lineno, "T", "process" if chunk in PROCESS_HOST else "job",
                "cross-component", "thread pool: submitted work and served requests run concurrently")
    for cls in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
        cs = ClassScan(cls, text)
        cname = cls.name
        clife = lifetime_of_class(cname, chunk)
        data = bool(DATA_CLASS.search(cname)) and not cs.threads and not cs.remote_cbs
        # class-level containers mutated through the class name / cls
        for b in cls.body:
            if isinstance(b, ast.Assign) and isinstance(b.value, (ast.Dict, ast.List, ast.Set)):
                for t in b.targets:
                    if isinstance(t, ast.Name) and re.search(r"\b(cls|" + cname + r")\." + t.id + r"(\[|\.(" +
                                                              "|".join(MUTATORS) + r")\()", text):
                        add(f"{mod}.{cname}:{t.id}", b.lineno, "G", "process",
                            "cross-job" if chunk in PROCESS_HOST else "cross-component", "class-level container mutated")
        for tm, line in sorted(cs.threads.items(), key=lambda kv: kv[1]):
            add(f"{mod}.{cname}.{tm}", cs.methods[tm].lineno, "T", clife, "cross-component",
                "thread entry" + (": " + ",".join(sorted(cs.xops[tm])) if cs.xops[tm] else ""))
        for cb, line in sorted(cs.callbacks.items(), key=lambda kv: kv[1]):
            if cb in cs.threads:
                continue
            remote = cb in cs.remote_cbs
            touched = {a for a, ms in cs.writes.items() if cb in ms}
            add(f"{mod}.{cname}.{cb}", cs.methods[cb].lineno, "H", clife,
                "cross-process" if remote else "cross-component",
                ("remote handler" if remote else "callback") + (f"; writes {','.join(sorted(touched))}" if touched else "")
                + (": " + ",".join(sorted(cs.xops[cb])) if cs.xops[cb] else ""))
        if data:
            continue
        for a in sorted(set(cs.writes) | cs.containers):
            wm = cs.writes.get(a, set()) - {"__init__"}
            if not wm and a not in cs.keyed:
                continue            # configuration: written only in __init__
            if a in cs.methods:
                continue
            ms = (cs.reads.get(a, set()) | cs.writes.get(a, set())) - {"__init__"}
            kinds = {cs.kind(m) for m in ms}
            entry_ms = {m for m in ms if cs.kind(m) in ("thread", "callback", "remote", "public")}
            if "remote" in kinds:
                share = "cross-process"
            elif len(kinds & {"thread", "callback", "public"}) >= 2 or ("thread" in kinds and len(ms) > 1):
                share = "cross-component"
            elif len(entry_ms) >= 2 and wm:
                # written in one entry, used in another: other components call these methods
                share = "cross-component"
            else:
                share = "component"
            life = clife
            if CONFIG_CLASS.search(cname):
                life = "request"     # built while a configuration is parsed / an app is deployed
            elif re.search(r"(^|_)(req|request|reply|resp|msg|tmp|buf|buffer|chunk|frame|_last_|last_)", a):
                life = "request"
            elif re.search(r"(^|_)(task|round|current|curr|pending|attempt|seq)", a) and clife == "job":
                life = "round"
            keyed = ",".join(sorted(cs.keyed.get(a, set())))
            add(f"{mod}.{cname}:{a}", cls.lineno, "K" if keyed else "S", life, share,
                f"state written by {','.join(sorted(wm)) or '-'}" + (f"; keyed {keyed}" if keyed else "")
                + f"; accessed from {','.join(sorted(kinds)) or '-'}")
        for mname, ops in cs.xops.items():
            if mname in cs.threads or mname in cs.callbacks or mname == "__init__":
                continue
            life = "persistent" if ops & {"persist", "store"} else clife
            share = "cross-process" if ops & {"cell", "proc", "store", "persist"} else "cross-component"
            add(f"{mod}.{cname}.{mname}", cs.methods[mname].lineno, "X", life, share, "external op: " + ",".join(sorted(ops)))
    # module-level functions with external ops
    for fn in [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        seg = ast.get_source_segment(text, fn) or ""
        ops = {k for k, rx in XOPS.items() if re.search(rx, seg)}
        if ops:
            add(f"{mod}.{fn.name}", fn.lineno, "X", "persistent" if ops & {"persist", "store"} else "request",
                "cross-process" if ops & {"cell", "proc", "store", "persist"} else "component",
                "external op: " + ",".join(sorted(ops)))
    return classify(rows, chunk)


def main():
    want = sys.argv[sys.argv.index("--chunks") + 1].split(",") if "--chunks" in sys.argv else None
    scope = list(csv.DictReader((ROOT / "notes" / "scope.csv").open()))
    out = []
    for r in scope:
        d = r["decision"]
        if re.fullmatch(r"c\d", d) and (want is None or d in want):
            out += scan_file(r["file"], d)
    seen = set()
    for r in out:
        while r["id"] in seen:
            r["id"] += "'"
        seen.add(r["id"])
    cols = ["id", "file_line", "unit_type", "chunk", "lifetime", "sharing", "select", "effects"]
    with (ROOT / "notes" / "units-scope.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols); w.writeheader(); w.writerows(out)
    from collections import Counter
    c = Counter((r["chunk"], r["select"] == "select") for r in out)
    for ch in sorted({r["chunk"] for r in out}):
        print(ch, "units", c[(ch, True)] + c[(ch, False)], "selected", c[(ch, True)])
    print("types", Counter(r["unit_type"] for r in out))


if __name__ == "__main__":
    main()
