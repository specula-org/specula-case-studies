#!/usr/bin/env python3
import hashlib,json,pathlib,sys
h=pathlib.Path(__file__).resolve().parent;source=pathlib.Path(sys.argv[1]).resolve()
files={}
for line in (h/'files.txt').read_text().splitlines():
 _,target=line.split('|');files[target]=hashlib.sha256((source/target).read_bytes()).hexdigest()
(h/'evidence'/'installed-files.json').write_text(json.dumps(dict(source=str(source),files=files),indent=2))
