import hashlib,json,pathlib,sys
h,s=map(pathlib.Path,sys.argv[1:3])
files=['patches/instrumentation.patch','src/trace.rs','src/probes.rs','src/scenarios.c']
hashes={p:hashlib.sha256((h/p).read_bytes()).hexdigest() for p in files}
build=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
if sys.argv[3:]==['--check-built']:
    import subprocess
    recorded=json.loads((h/'logs/instrumentation-identity.json').read_text())
    assert recorded==dict(build_id=build,inputs=hashes), 'Harness inputs changed since the recorded build'
    assert subprocess.check_output(['git','-C',str(s),'rev-parse','HEAD'],text=True).strip()=='0c60537098f4c2949ad2d382aaf499de72263d76'
    assert subprocess.check_output(['git','-C',str(s),'diff','--binary'])==(h/'patches/instrumentation.patch').read_bytes(), 'Source differs from the recorded instrumentation'
    assert (s/'ostd/src/specula_trace.rs').read_bytes()==(h/'src/trace.rs').read_bytes()
    assert (s/'kernel/core/src/specula_probes.rs').read_text()==(h/'src/probes.rs').read_text().replace('HARNESS_BUILD_ID',build)
    assert (s/'test/initramfs/src/regression/process/specula_futex/scenarios.c').read_bytes()==(h/'src/scenarios.c').read_bytes()
    for line in (h/'logs/images-1.sha256').read_text().splitlines():
        expected,name=line.split(maxsplit=1)
        path=h.parent.parent/name.removeprefix('/work/')
        assert hashlib.sha256(path.read_bytes()).hexdigest()==expected, name
    kernel=h/'build/target/osdk/iso_root/boot/asterinas-osdk-bin'
    assert build.encode() in kernel.read_bytes(), 'The built kernel has a different instrumentation identity'
    print('Verified existing kernel and harness identity:',build)
    sys.exit(0)
assert not sys.argv[3:]
(s/'kernel/core/src/specula_probes.rs').write_text((h/'src/probes.rs').read_text().replace('HARNESS_BUILD_ID',build))
(h/'logs/instrumentation-identity.json').write_text(json.dumps(dict(build_id=build,inputs=hashes),indent=2)+'\n')
