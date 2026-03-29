# Demo Commands

所有命令在 `/home/ubuntu/Specula` 目录下运行。

---

## Trace Validation (3 traces)

```bash
for t in barrier_basic cancel task_regions; do echo "=== $t ===" && JSON=$(pwd)/case-studies/libgomp/traces/${t}.ndjson java -cp lib/tla2tools.jar:lib/CommunityModules-deps.jar tlc2.TLC -config case-studies/libgomp/spec/Trace.cfg case-studies/libgomp/spec/Trace.tla -deadlock -metadir /tmp/tlc-trace-${t} 2>&1 | grep -E "Invariant|states generated"; done
```
成功 = `Invariant TraceConsumed is violated`

## Bug #29: 找到死锁

```bash
java -jar lib/tla2tools.jar -config case-studies/libgomp/spec/MC_hunt_detach_deadlock.cfg case-studies/libgomp/spec/MC.tla -metadir /tmp/tlc-hunt
```
成功 = `Invariant DetachFulfillNoDeadlock is violated`，13-state counterexample

## MC 收敛: 全部通过

```bash
java -jar lib/tla2tools.jar -deadlock -config case-studies/libgomp/spec/MC_stress.cfg case-studies/libgomp/spec/MC.tla -metadir /tmp/tlc-stress 2>&1 | grep -E "No error|states generated|Finished"
```
成功 = `No error has been found`，1.45M states

## 4 个 Bug Family: 全部干净

```bash
for f in 1 2 3 4; do echo -n "Family $f: " && java -jar lib/tla2tools.jar -deadlock -config case-studies/libgomp/spec/MC_hunt_family${f}.cfg case-studies/libgomp/spec/MC.tla -metadir /tmp/tlc-fam${f} 2>&1 | grep -o "No error has been found"; done
```

## Bug #29: 真实复现 (deadlock)

```bash
gcc -fopenmp -O2 -lpthread -o /tmp/detach_repro case-studies/libgomp/repro/detach_fulfill_deadlock.c && timeout 5 /tmp/detach_repro; echo "Exit: $? (124=deadlock)"
```
成功 = 挂 5 秒后 `Exit: 124 (124=deadlock)`

## 一键全跑

```bash
echo "--- Trace Validation ---"
for t in barrier_basic cancel task_regions; do echo -n "$t: " && JSON=$(pwd)/case-studies/libgomp/traces/${t}.ndjson java -cp lib/tla2tools.jar:lib/CommunityModules-deps.jar tlc2.TLC -config case-studies/libgomp/spec/Trace.cfg case-studies/libgomp/spec/Trace.tla -deadlock -metadir /tmp/tlc-trace-${t} 2>&1 | grep -o "Invariant TraceConsumed is violated"; done

echo "--- Bug #29 Hunt ---"
java -jar lib/tla2tools.jar -config case-studies/libgomp/spec/MC_hunt_detach_deadlock.cfg case-studies/libgomp/spec/MC.tla -metadir /tmp/tlc-hunt29 2>&1 | grep -E "Invariant|states generated"

echo "--- Convergence (1.45M states) ---"
java -jar lib/tla2tools.jar -deadlock -config case-studies/libgomp/spec/MC_stress.cfg case-studies/libgomp/spec/MC.tla -metadir /tmp/tlc-stress 2>&1 | grep -E "No error|states generated"

echo "--- Family Hunting ---"
for f in 1 2 3 4; do echo -n "Family $f: " && java -jar lib/tla2tools.jar -deadlock -config case-studies/libgomp/spec/MC_hunt_family${f}.cfg case-studies/libgomp/spec/MC.tla -metadir /tmp/tlc-fam${f} 2>&1 | grep -o "No error has been found"; done

echo "--- Live Bug #29 Reproduction ---"
gcc -fopenmp -O2 -lpthread -o /tmp/detach_repro case-studies/libgomp/repro/detach_fulfill_deadlock.c 2>/dev/null && timeout 5 /tmp/detach_repro 2>/dev/null; [ $? -eq 124 ] && echo "DEADLOCK CONFIRMED" || echo "No deadlock"
```

---

## 注意

- Bug #28 的 assertion reproducer 需要编译 NVIDIA patched libgomp，且 cancel 路径在 flat barrier 下会 deadlock，不适合现场 demo。口头讲 root cause 即可。
- Bug #29 reproducer 用系统 GCC 就能跑，不需要任何 patched libgomp。
