# TLC simulation execution workaround

The first progress simulation (`27109878e57c4ea3bf88305ea6218535`) was stopped after all sixteen workers threw `ClassCastException` in `FcnLambdaValue.toFcnRcd` while `SimulationWorker.getTrace` compared states for liveness checking. Its log, JVM stop reason, and exit 143 are retained. This is a TLC execution error, not an NVFlare finding or successful budget coverage.

The bundled bytecode casts the result of applying lazy function EXCEPT updates to `FcnRcdValue`; the failing result was a `TupleValue`. The isolated retry uses `eager_copy.py` to wrap only explicit function constructors in `TLCEval`. The bundled standard module defines `TLCEval(v) == v`; the transformation changes evaluation strategy, not the transition relation. It does not wrap function-set type predicates, remove any invariant/fairness condition, change a constant or shrink a bound. The canonical `base.tla` and `MC.tla` are untouched, and each execution copy has a hash/transform receipt.

All four implementation traces pass on the eager copy (`output/traces-eager-control/`). The retry started with the original progress configuration, 30-minute budget, depth 100 and 999999999 requested traces. Its workers were observed executing liveness checks, and subsequent progress exceeded the initial sixteen traces without the former exception. Final bounded coverage is recorded in `output/run-coverage.json` and `bug-report.md`; generated-trace counters are not an exhaustive liveness proof.

The exit-cleanup simulation uses the same identity transformation. Other already-running safety simulations retain their original execution copies; all logs must be checked for worker exceptions before assigning a bounded no-violation result.
