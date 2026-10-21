#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,re,subprocess,os,difflib
h=Path(__file__).resolve().parents[1]; out=h.parent; root=out.parent; source=root/'source'
manifest=json.loads((h/'patches/manifest.json').read_text())
points={}; patches=[]
for name,info in manifest.items():
    p=source/name; text=p.read_text()
    assert hashlib.sha256(p.read_bytes()).hexdigest()==info['after_sha256'],name
    for m in re.finditer(r'tla_trace::(?:event|page|returned)\(\s*"([^"]+)"',text):
        points.setdefault(m.group(1),[]).append(f'{name}:{text[:m.start()].count(chr(10))+1}')
    for helper,event in [('enter','SyscallEnter'),('copied','VmoCopyPage')]:
        for m in re.finditer(r'tla_trace::'+helper+r'\(',text):
            points.setdefault(event,[]).append(f'{name}:{text[:m.start()].count(chr(10))+1}')
    old='' if info['before_sha256'] is None else subprocess.check_output(['git','--git-dir='+str(root/'baseline.git'),'show','refs/specula/baseline:'+name]).decode()
    patches.extend(difflib.unified_diff(old.splitlines(True),text.splitlines(True),fromfile='/dev/null' if info['before_sha256'] is None else 'a/'+name,tofile='b/'+name))
(h/'patches/instrumentation.patch').write_text(''.join(patches))
(h/'points.json').write_text(json.dumps(points,indent=2)+'\n')
assert len(points)==42
quality=json.loads((h/'quality.json').read_text()); validation=json.loads((h/'validation.json').read_text()); proposed=json.loads((h/'validation-proposed.json').read_text()); side=json.loads((h/'non-tla/coverage.json').read_text())
case_doc=json.loads((h/'non-tla/cases.json').read_text())
fault=[c for c in case_doc['cases'] if c['syscall']=='pwrite64' and c['requested_length']==8192 and c['input']['objects'][0]['region']=='guard-page' and c['input']['objects'][0]['accessible_units']==4096]
assert len(fault)==1
fixtures={'source_revision':'604948581512d83734377974d4c34adb4530f2d7','physical_page_size':4096,'physical_cluster_size':4096,'model_unit_bytes':2048,'max_model_cells':12,'initial_size_bytes':4096,'warm_pages':[0],'source_tags':{'seed':83,'t0':65,'t1':66,'sentinel':165,'zero':0},'smp':2,'caller_uid':1000,'caller_gid':1000,'worker_affinity':[0,1],'fault_case_id':fault[0]['id'],'fault_case_object':fault[0]['input']}
(h/'fixtures.json').write_text(json.dumps(fixtures,indent=2)+'\n')
rows='\n'.join('| `'+name+'` | '+'; '.join('`'+p+'`' for p in paths)+' |' for name,paths in sorted(points.items()))
body=f'''# Buffered-file trace harness

Source revision: `604948581512d83734377974d4c34adb4530f2d7`.
The exported source baseline is `d0809945830273c4a7be6c93fc6d862e5b798e29` in `../../baseline.git` (relative to this guide).

## Run and current result

From `.specula-output/`:

```sh
bash harness/run.sh
```

- {quality['scenarios']} guest traces, {quality['events']} events, {quality['covered_actions']}/42 event types exercised.
- {quality['overlapping_pairs']} cross-thread interval overlaps; the best short trace has {quality['best_overlap_fraction']:.0%} overlapping pairs.
- Supplied spec: {sum(r['matched'] for r in validation)}/{len(validation)} traces match, including complete witnesses where universal temporal checking encounters a dead-end ordering.
- Separate proposed spec: {sum(r['matched'] for r in proposed)}/{len(proposed)} traces match.
- Sidecar: {side['generated']} generated cases, {side['executed']} executions across three backends, zero truncated, unexecuted, unsupported, or harness-error cases. All executions pass the stated count/offset oracle. This does not certify the filesystem contract or its error rollback behavior.
- `run.sh` returns 1 because the supplied spec rejects `ramfs-2-2` and `ramfs-3-3`. It preserves those traces. See [validation.json](validation.json), [validation-proposed.json](validation-proposed.json), and [run-status.json](run-status.json).

The runner uses rootful Docker, `asterinas/dev:0.18.1-20260901`, and only `/dev/kvm` from the host. It builds the real kernel with OSDK, then boots its direct ELF image with two CPUs and `earlycon`. Root mounts the two disposable filesystem images; the regression program runs as UID/GID 1000. Both workers request separate CPU affinities. A user-space TSC rendezvous starts contenders; no kernel delay or extra trace lock is inserted. Builds and guest runs have outer timeouts. A guest timeout stops the run and requires diagnosis; it is not retried.

`SPECULA_IMAGE`, `SPECULA_DOCKER_SOCKET`, `SPECULA_ROOT`, and `SPECULA_JAVA` override local dependencies. `SPECULA_CONTAINER` reuses an explicitly named development container. The ordinary runner removes its own container on exit. The MCP validation tool could not locate `java`; the CLI validator uses the discovered JRE directly and the same Specula TLC jars.

## Native receipts and trace fields

[tla_trace.rs](src/tla_trace.rs) adds a preallocated 2048-record buffer to each POSIX thread's local data. `prctl(0x53504543, tid, 2048, accessible_prefix, 0)` arms it; `0x53504544` drains it after both workers leave their attempts. Overflow returns EOVERFLOW. The hot path uses no global ID registry, sequence counter, file writer, or shared tracing mutex. No unsafe Rust was added.

- `stamp()` uses safe OSTD `read_tsc()` with fences. Each semantic hook brackets the real operation; serialization follows the interval. Guard-release intervals start at the preceding receipt's end and include the lexical guard drop.
- The subject VMO address is retained per thread. `Scope` suppresses unrelated exFAT metadata-cache I/O and restores the enclosing capture state.
- `copied()` samples exported VmReader/VmWriter cursor addresses before and after the real fallible copy. It never measures progress from `avail()`, which ext2 limits independently of copying.
- Read receipts independently inspect the successfully copied destination prefix. Write/zero receipts inspect initialized frame bytes or only the just-written fragment of an Uninit frame. Raw uninitialized frame bytes are not dumped.
- Cache resize records the selected native zero interval. Ext2 allocation records the native block mask under its existing tree guard and a zero-copy cursor receipt after the corresponding disk write completes.
- [collect.py](src/collect.py) converts exact byte units and byte tags, retains native scalar/cursor/return receipts, and derives control markers and held-guard flags from executed hooks. It implements no file contents or filesystem transition simulator. Nonrepresentable counts and nonuniform tags fail conversion.
- All eight state projections and every LocalObserved field are emitted and checked by the supplied `ValidatePostState`; no weak validator or silent repair is used. Ghost reference histories remain spec observers.

Each scenario has raw native receipts and per-thread, schema-complete NDJSON under `traces/raw/<scenario>/`. The supplied preprocessor compresses timestamps without sorting threads into a total order. The top-level scenario `.ndjson` is its one-record input to Trace.tla. Earlier batches remain under `harness/history/`; the latest `coverage.json` names its source log. Validation records bind each exact trace SHA256. Serial logs also retain syscall-side observations.

## Scenarios and generated cases

[scenarios.c](src/scenarios.c) uses Asterinas's `test/initramfs/src/regression/common/test.h`. The five data scenarios run separately on ramfs, ext2, and exFAT:

1. Shrink, shared-offset read, extension, hole/EOF positional read, and empty I/O.
2. Read versus shrink to zero.
3. Read versus an extending buffered write.
4. A partial source-copy fault during extension.
5. Two extending writers with different payloads and disjoint ranges.

Another 96 short ext2 same-size resize trials exercise lock contention and timebox ordering. Each trace starts from one fsynced 4096-byte seeded file with page 0 warm. Physical pages and exFAT clusters are 4096 bytes; one model cell is 2048 bytes. See [fixtures.json](fixtures.json).

The fault trace consumes generated case `{fault[0]['id']}` and its `buffer` object. The complete byte-granular adapter consumes all 159 immutable cases, retaining their object IDs and empty alias-edge sets. It implements valid, null, unmapped, PROT_NONE, read-only, and guard-page mappings. Permissions remain fixed during each syscall; inaccessible mappings are restored only afterward for safe sentinel inspection.

The installed CLI lacked `syscall-inputs`. [tools/generator-identity.json](tools/generator-identity.json) pins the unmodified upstream utility recovered from local Git history. The harness-local `specula syscall-inputs` wrapper invokes that utility. Contract, cases, evidence, and referenced raw observations validate against that exact generator.

Sidecar `attempted` is the syscall request length; `copied` comes from destination sentinel inspection; `committed` comes from file readback; `reported` and offset changes come from the actual return and lseek. Unobservable progress is null. Delivered-prefix and outside-request sentinel observations are retained. Error cases do not assume all-or-nothing rollback. These results stay separate from `spec/findings.json`.

## Model mismatch and remaining coverage

The ramfs unaligned writes start at byte 2048 with length 8192. The real write path allocates a vector with capacity `ceil(8192 / 4096) = 2`, then collects pages 0 and 1 before copying. Three page indices span that unaligned range. The supplied `VmoCollectBegin` instead requires all three pages before any copy. A fault in the second copied page makes this ordering difference observable.

[proposed-base-batch-capacity.patch](patches/proposed-base-batch-capacity.patch) bounds each collection by the vector capacity actually selected by the source. It changes no post-state checks or outcome invariants. The supplied spec files remain byte-for-byte unchanged, verified by [spec-input-hashes.json](spec-input-hashes.json). To review the correction independently:

```sh
SPECULA_TRACE_SPEC="$PWD/harness/proposed-spec" python3 harness/src/validate_traces.py
```

`Trace_witness.cfg` is used only after a temporal replay failure. A witness counts as a match only when TLC reports TraceNotComplete violated and every final cursor equals that thread's event count plus one. Parse errors, structural-invariant failures, timeouts, and partial prefixes never count as matching witnesses.

Two instrumented event types remain unexercised:

- `VmoRangeError`: no inconsistent cache/backend bound occurred in the selected schedules. The harness observes real failing checks; it does not inject EINVAL. Another reachable publication history is needed to cover this path.
- `ExfatBackendReadBlocked`: the warm initial tail avoids the recursive R-under-W wait. Its hook records a failed native try_read before the original blocking read. A cold-tail fixture needs an external watchdog and ring/stack extraction because the blocked thread cannot drain its own buffer. No completion claim is made for this path.

Physical cluster-reuse identity (TV3), an Uninit page reused after an in-EOF partial fault, and cold-tail blocked-stack evidence are not covered. Their follow-ups need fixture receipts and, for reused Uninit cells, cross-attempt validity tracking before inspection. These limits are not passes or confirmed findings.

## Adjusting instrumentation

- Edit the native module in `src/tla_trace.rs` and hooks in `src/patch_source.py`, `src/patch_vmo.py`, or `src/patch_backends.py`. `apply.sh` rebuilds edits from exact baseline bytes and refuses unowned source changes.
- Add a native receipt field to `Receipt` or an unused documented value slot; decode it in `collect.py`. A new trace state field also needs its corresponding Trace.tla/base validation. Never replace a saved backend count with copied progress.
- Add an event at its real source transition, using an existing `event`, `page`, or `copied` hook as the pattern. Add its serializer branch and verify its coverage. Event names must match Trace.tla.
- To move a capture point, move the start stamp and native observation together. Keep the observation under its existing protecting guard and keep the actual drop inside release intervals. Do not reread shared state after releasing that guard.
- Re-run `bash harness/run.sh`. `clean.sh` restores only owned patched files after verifying their hashes. [instrumentation.patch](patches/instrumentation.patch) and [manifest.json](patches/manifest.json) make the applied result reviewable.

## Instrumentation points after apply

Paths below are relative to `source/`. The unchanged cursor advancement is at `ostd/src/mm/io/mod.rs:354-355`; its exported cursor values are sampled in the listed VMO copy hooks.

| Event | Native hook locations |
|---|---|
{rows}
'''
(h/'INSTRUMENTATION.md').write_text(body)
# Verify every original tracked file against the exported source identity.
entries=subprocess.check_output(['git','--git-dir='+str(root/'baseline.git'),'ls-tree','-r','-z','refs/specula/baseline']).split(b'\0')
changed=[]; missing=[]; count=0
for record in entries:
    if not record: continue
    meta,path=record.split(b'\t',1); mode,typ,oid=meta.split(); name=path.decode(); p=source/name; count+=1
    if not p.exists() and not p.is_symlink(): missing.append(name); continue
    data=os.readlink(p).encode() if mode==b'120000' else p.read_bytes()
    actual=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if actual!=oid.decode(): changed.append(name)
expected={name for name,info in manifest.items() if info['before_sha256'] is not None}
assert not missing and set(changed)==expected,(missing,set(changed)^expected)
for name,expected_hash in json.loads((h/'spec-input-hashes.json').read_text()).items(): assert hashlib.sha256((out/'spec'/name).read_bytes()).hexdigest()==expected_hash,name
identity={'source_revision':fixtures['source_revision'],'baseline':'d0809945830273c4a7be6c93fc6d862e5b798e29','tracked_files_checked':count,'changed_tracked_files':changed,'unexpected_changes':[],'missing':[],
          'artifacts':{str(p.relative_to(h)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [h/'build/kernel-direct/asterinas-osdk-bin.qemu_elf',h/'build/root/scenarios',h/'build/root/init',h/'build/initramfs.cpio',h/'src/tla_trace.rs',h/'src/collect.py',h/'src/scenarios.c',h/'src/cases.h',h/'patches/manifest.json']}}
(h/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
print('Guide and patch written; source and spec identities verified')
