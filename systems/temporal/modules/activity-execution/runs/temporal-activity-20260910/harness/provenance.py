#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys
from pathlib import Path
h=Path(__file__).resolve().parent;r=Path(os.environ['SOURCE_DIR']);out=Path(sys.argv[1])
data={'sourceRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),
 'source':str(r),'buildCommand':['timeout','900','go','test','-c','-tags','test_dep','-o',str(out/'temporal-tests'),'./tests'],
 'testCommand':['timeout','600',str(out/'temporal-tests'),'-test.run',os.environ.get('HARNESS_TEST_PATTERN','^TestSpeculaActivityTrace$'),'-test.v','-test.timeout','540s','-persistenceType=sql','-persistenceDriver=sqlite'],
 'goVersion':subprocess.check_output(['go','version'],cwd=r,text=True).strip(),
 'env':{k:os.environ.get(k) for k in ['SPECULA_TRACE_ROOT','SPECULA_BINARY_SHA256','SPECULA_PATCH_SHA256','GOTOOLCHAIN','GOMAXPROCS','TMPDIR','GOTMPDIR']},
 'files':{str(p.relative_to(h)):hashlib.sha256(p.read_bytes()).hexdigest() for p in h.rglob('*') if p.is_file() and 'evidence' not in p.relative_to(h).parts}}
(out/'provenance.json').write_text(json.dumps(data,indent=2)+'\n')
