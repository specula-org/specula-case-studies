#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKTREE="$OUTPUT_ROOT/confirmation/CR-1/worktree"
FINDING_DIR="$OUTPUT_ROOT/confirmation/CR-1"
TEST_FILE="$WORKTREE/ratis-test/src/test/java/org/apache/ratis/grpc/TestBugCR1LatePendingReply.java"
LOG_FILE="$FINDING_DIR/cr1_late_pending_reply_mvn.log"
TRACE_FILE="$WORKTREE/ratis-test/target/specula-traces/cr1-late-success-after-timeout.ndjson"

mkdir -p "$(dirname "$TEST_FILE")"

cat > "$TEST_FILE" <<'JAVA'
/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.ratis.grpc;

import org.apache.ratis.BaseTest;
import org.apache.ratis.RaftTestUtil;
import org.apache.ratis.client.RaftClient;
import org.apache.ratis.client.RaftClientConfigKeys;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.protocol.RaftClientReply;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.impl.MiniRaftCluster;
import org.apache.ratis.specula.RatisGrpcTrace;
import org.apache.ratis.statemachine.StateMachine;
import org.apache.ratis.statemachine.impl.SimpleStateMachine4Testing;
import org.apache.ratis.util.JavaUtils;
import org.apache.ratis.util.TimeDuration;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import static org.apache.ratis.RaftTestUtil.waitForLeader;

public class TestBugCR1LatePendingReply extends BaseTest implements MiniRaftClusterWithGrpc.FactoryGet {
  @AfterEach
  public void closeTrace() {
    RatisGrpcTrace.close();
  }

  @Test
  @Timeout(120)
  public void lateSuccessAfterTimeoutKeepsClusterUsable() throws Exception {
    MiniRaftClusterWithGrpc cluster = null;
    boolean followersBlocked = false;
    try {
      final RaftProperties properties = new RaftProperties();
      properties.setClass(MiniRaftCluster.STATEMACHINE_CLASS_KEY,
          SimpleStateMachine4Testing.class, StateMachine.class);
      GrpcConfigKeys.Server.setHeartbeatChannel(properties, true);
      RaftServerConfigKeys.Rpc.setRequestTimeout(properties, TimeDuration.valueOf(300, TimeUnit.MILLISECONDS));
      RaftClientConfigKeys.Rpc.setRequestTimeout(properties, TimeDuration.valueOf(30, TimeUnit.SECONDS));

      cluster = getFactory().newCluster(3, properties);
      cluster.start();
      final RaftServer.Division leader = waitForLeader(cluster);
      RatisGrpcTrace.startScenario("cr1-late-success-after-timeout");
      RatisGrpcTrace.registerLeader(leader.getId());
      cluster.getFollowers().forEach(follower -> RatisGrpcTrace.registerFollower(follower.getId()));

      try (RaftClient client = cluster.createClient(leader.getId())) {
        Assertions.assertTrue(client.io().send(new RaftTestUtil.SimpleMessage("warmup")).isSuccess());
        cluster.getServerAliveStream()
            .filter(server -> !server.getInfo().isLeader())
            .map(SimpleStateMachine4Testing::get)
            .forEach(SimpleStateMachine4Testing::blockWriteStateMachineData);
        followersBlocked = true;

        final CompletableFuture<RaftClientReply> slow =
            client.async().send(new RaftTestUtil.SimpleMessage("slow"));
        JavaUtils.attempt(() -> assertEvent("TimeoutAppend"), 30, HUNDRED_MILLIS, "TimeoutAppend", LOG);

        cluster.getServerAliveStream()
            .filter(server -> !server.getInfo().isLeader())
            .map(SimpleStateMachine4Testing::get)
            .forEach(SimpleStateMachine4Testing::unblockWriteStateMachineData);
        followersBlocked = false;

        Assertions.assertTrue(slow.get(30, TimeUnit.SECONDS).isSuccess());
        JavaUtils.attempt(() -> assertEvent("ReceiveSuccessWithoutRequest"), 30, HUNDRED_MILLIS,
            "ReceiveSuccessWithoutRequest", LOG);
        Assertions.assertTrue(client.io().send(new RaftTestUtil.SimpleMessage("after-late-reply")).isSuccess());
        assertEvent("AdvanceCommitIndex");
      }
    } finally {
      if (cluster != null && followersBlocked) {
        cluster.getServerAliveStream()
            .filter(server -> !server.getInfo().isLeader())
            .map(SimpleStateMachine4Testing::get)
            .forEach(SimpleStateMachine4Testing::unblockWriteStateMachineData);
      }
      if (cluster != null) {
        cluster.shutdown();
      }
    }
  }

  private static void assertEvent(String event) {
    Assertions.assertTrue(RatisGrpcTrace.getEventCount(event) > 0,
        () -> "Missing event " + event + "; counts=" + RatisGrpcTrace.eventCounts());
  }
}
JAVA

cd "$WORKTREE"

MAVEN_CMD=("./mvnw" "-pl" "ratis-test" "-am"
  "-Dtest=TestBugCR1LatePendingReply#lateSuccessAfterTimeoutKeepsClusterUsable"
  "-DskipShade" "-DskipRat" "-DskipCheckstyle" "-DskipSpotbugs" "-DskipOWASP"
  "-DskipJavadoc" "-DskipSource" "-Dgpg.skip" "-Djacoco.skip" "test")

echo "CR1_REPRO_COMMAND: timeout 10m ${MAVEN_CMD[*]}"
echo "CR1_REPRO_LEVEL0: warmup client append uses normal public RaftClient/gRPC path and succeeds before timing assistance."
echo "CR1_REPRO_LEVEL1: follower state machines are blocked to let the real AppendEntries request time out; no Ratis source logic is patched."

if ! timeout 10m "${MAVEN_CMD[@]}" > "$LOG_FILE" 2>&1; then
  echo "CR1_MAVEN_RESULT: FAIL"
  tail -n 120 "$LOG_FILE"
  exit 1
fi

echo "CR1_MAVEN_RESULT: PASS"
python3 - "$TRACE_FILE" "$LOG_FILE" <<'PY'
import json
import sys
from pathlib import Path

trace = Path(sys.argv[1])
log = Path(sys.argv[2])
if not trace.exists():
    raise SystemExit(f"missing trace file: {trace}")

records = []
for lineno, raw in enumerate(trace.read_text(encoding="utf-8").splitlines(), 1):
    if not raw.strip():
        continue
    obj = json.loads(raw)
    obj["_lineno"] = lineno
    obj["_raw"] = raw
    records.append(obj)

late = [r for r in records if r.get("event") == "ReceiveSuccessWithoutRequest"]
if not late:
    raise SystemExit("missing ReceiveSuccessWithoutRequest")
late_ids = {(r.get("follower"), r.get("callId"), r.get("isHeartbeat")) for r in late}

print(f"CR1_TRACE_FILE: {trace}")
print("CR1_TRACE_EVIDENCE:")
for r in records:
    key = (r.get("follower"), r.get("callId"), r.get("isHeartbeat"))
    event = r.get("event")
    if key in late_ids and event in {"SendAppendData", "TimeoutAppend", "FollowerAppendSuccess",
                                      "ReceiveSuccessWithoutRequest"}:
        print(f"{r['_lineno']}:{r['_raw']}")
late_start = min(r["_lineno"] for r in late)
for r in records:
    if r.get("event") == "AdvanceCommitIndex" and r["_lineno"] > late_start:
        print(f"{r['_lineno']}:{r['_raw']}")
        break

summary = []
for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
    if "Tests run:" in line or "BUILD SUCCESS" in line or "Finished at:" in line:
        summary.append(line)
print("CR1_SUREFIRE_SUMMARY:")
for line in summary[-6:]:
    print(line)
print("CR1_ASSERTION: JUnit assertions passed: the timed-out client write succeeded, "
      "ReceiveSuccessWithoutRequest was observed, and a later client write succeeded.")
PY
