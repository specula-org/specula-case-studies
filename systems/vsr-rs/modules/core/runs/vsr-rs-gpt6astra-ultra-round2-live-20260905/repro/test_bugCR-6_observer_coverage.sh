#!/usr/bin/env bash
set -euo pipefail

repo="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-6/worktree"
cd "$repo"

echo "CR-6 reproduction attempt: simulator observer-history coverage"
echo "repo_head=$(git rev-parse HEAD)"
echo "status:"
git status --short

echo
echo "Level 0: run the public library/simulator test suite with no failpoints or source changes"
echo "+ timeout 5m cargo test --workspace -- --nocapture"
timeout 5m cargo test --workspace -- --nocapture
echo "Level 0 result: public tests completed without an observable safety/liveness failure."

echo
echo "Level 1: run a deterministic simulator command with normal fault/timing knobs"
echo "+ timeout 5m cargo run -p vsr-simulator -- --lite --requests-max 50 --ticks-max-requests 100000 --ticks-max-convergence 100000 --packet-loss-probability 0.05 --packet-replay-probability 0.1 --replica-crash-probability 0.00005 --replica-reboot-probability 0.5 12345"
timeout 5m cargo run -p vsr-simulator -- --lite --requests-max 50 --ticks-max-requests 100000 --ticks-max-convergence 100000 --packet-loss-probability 0.05 --packet-replay-probability 0.1 --replica-crash-probability 0.00005 --replica-reboot-probability 0.5 12345
echo "Level 1 result: fault/timing-assisted simulator run completed without an observable failure."

echo
echo "Observer-surface audit: static checks for the cited omissions"
python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import sys

props = Path("simulator/properties.rs").read_text()
sim = Path("simulator/lib.rs").read_text()
net = Path("simulator/network.rs").read_text()

def block(text, start, end):
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j]

checks = []
sim_context = block(props, "pub struct SimContext", "pub trait Property")
checks.append((
    "SimContext exposes tick, replicas, replies, and core, but no transport history",
    all(token in sim_context for token in ["pub tick", "pub replicas", "pub replies", "pub core"]) and
    not any(token in sim_context for token in ["sent", "delivered", "lost", "dropped", "history"])
))

property_trait = block(props, "pub trait Property", "/// The default property set.")
checks.append((
    "Property has check/finalize/on_reboot callbacks only",
    all(token in property_trait for token in ["fn check", "fn finalize", "fn on_reboot"]) and
    not any(token in property_trait for token in ["on_send", "on_deliver", "on_drop", "on_reply"])
))

checks.append((
    "Committed-prefix properties skip already verified committed indices",
    "skip(self.verified[id])" in props and
    "skip(*verified)" in props and
    "ctx.replies[self.verified..]" in props
))

tick = block(sim, "pub fn tick(&mut self) -> Result<()>", "/// Disables network faults")
checks.append((
    "Simulator checks properties after request/crash/heartbeat/network phases",
    tick.index("self.tick_requests();") < tick.index("self.tick_crash();") <
    tick.index("self.tick_heartbeat();") < tick.index("self.tick_network();") <
    tick.index("self.check_properties()?;")
))

tick_network = block(sim, "fn tick_network(&mut self)", "/// Moves the replicas")
checks.append((
    "tick_network batches delivery and has no property check inside the delivery loop",
    tick_network.count("self.flush();") == 2 and
    "self.network.take_due(self.ticks)" in tick_network and
    "check_properties" not in tick_network
))

flush = block(sim, "fn flush(&mut self)", "fn check_properties")
checks.append((
    "Replica replies are delivered directly to clients and appended to replies, not passed through Network::send",
    "for reply in replica.drain_replies()" in flush and
    "clients[reply.client_id].on_reply" in flush and
    "replies.push(reply)" in flush
))

snapshot = block(sim, "pub struct Snapshot", "use properties")
checks.append((
    "Snapshot exposes in-flight messages and aggregate counters, not full past transport history",
    "pub messages: Vec<Envelope>" in snapshot and
    "pub network: MessageSummary" in snapshot and
    "history" not in snapshot
))

network_summary = block(net, "pub struct MessageSummary", "pub struct Network")
checks.append((
    "MessageSummary is aggregate counters only",
    all(token in network_summary for token in ["pub sent", "pub delivered", "pub lost", "pub replayed", "pub delayed"]) and
    "Vec" not in network_summary and "Envelope" not in network_summary
))

try:
    inv = subprocess.check_output(["git", "show", "origin/lean:lean/Vsr/Invariant.lean"], text=True)
    safety = subprocess.check_output(["git", "show", "origin/lean:lean/Vsr/Safety.lean"], text=True)
    live = subprocess.check_output(["git", "show", "origin/lean:lean/Vsr/Liveness.lean"], text=True)
except subprocess.CalledProcessError as exc:
    print(f"FAIL: could not read retained Lean branch: {exc}", file=sys.stderr)
    sys.exit(1)

checks.append(("Retained Lean invariant branch explicitly assumes at least two replicas", "def TwoReplicas" in inv and "2 <= s.config.replicaCount" in inv.replace("≤", "<=")))
def theorem_window(text, name):
    start = text.index(f"theorem {name}")
    next_theorem = text.find("\ntheorem ", start + 1)
    next_end = text.find("\nend ", start + 1)
    stops = [pos for pos in [next_theorem, next_end] if pos != -1]
    end = min(stops) if stops else len(text)
    return text[start:end]

checks.append(("Retained Lean safety theorem is still a sorry", "sorry" in theorem_window(safety, "safety")))
checks.append(("Retained Lean liveness theorem is still a sorry", "sorry" in theorem_window(live, "settles")))

failed = False
for name, ok in checks:
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
    failed = failed or not ok

if failed:
    sys.exit(1)

print("Level 2 result: no legal state injection used; exposing the suspected false-negative requires private state mutation or a hypothetical regression.")
print("Level 3 result: no source patch used; patching library logic would create the symptom rather than reproduce a current bug.")
print("Overall: the observer omissions are real coverage boundaries, but this test did not reproduce a current reachable wrong outcome through the public simulator/library paths.")
PY
