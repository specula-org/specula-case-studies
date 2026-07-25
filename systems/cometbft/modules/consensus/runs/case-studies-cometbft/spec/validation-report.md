# Spec Validation Report: cometbft

Generated: 2026-02-26T12:11:44+00:00

## Syntax Validation (SANY)

- `base.tla`: PASS
- `MC.tla`: PASS
- `Trace.tla`: PASS

## Quick Model Check

- Quick MC: **VIOLATION FOUND**
```
Error: Evaluating invariant POLRoundValidity failed.
Attempted to check equality of record:
[round |-> 0, height |-> 1, polRound |-> -1, value |-> v1, source |-> s2]
with non-record
--
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\ validValue = (s1 :> "Nil" @@ s2 :> "Nil" @@ s3 :> "Nil")
/\ committedEvidence = {}
```

Full MC log: `/home/ubuntu/Specula/case-studies/cometbft/spec/quick-mc.log`

## Summary

- Checks run: 4
- Passed: 3
- Failed: 1

**Result: 1 CHECK(S) FAILED**
