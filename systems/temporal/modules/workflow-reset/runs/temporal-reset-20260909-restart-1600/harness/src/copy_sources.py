#!/usr/bin/env python3
import sys
from pathlib import Path
harness,source=map(Path,sys.argv[1:])
files={'trace.go':'common/resettrace/trace.go','sql_observer.go':'common/persistence/sql/reset_trace.go','mutable_observer.go':'service/history/workflow/reset_trace.go','history_observer.go':'service/history/historybuilder/reset_trace.go','scenarios_test.go':'tests/reset_trace_test.go'}
for src,dst in files.items():
 target=source/dst;target.parent.mkdir(parents=True,exist_ok=True)
 target.write_bytes((harness/'src'/src).read_bytes())
