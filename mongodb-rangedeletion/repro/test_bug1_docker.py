#!/usr/bin/env python3
"""
Reproduce Bug 1: deleteRangeDeletionTaskLocally missing migrationId filter

Uses Docker + mongosh to trigger the scenario:
1. Start migration M1, abort it, pause before forgetMigration
2. Step down to leave M1's coordinator doc
3. Commit migration M2 on same range
4. Step-up recovery replays M1 abort → deletes M2's task doc

Target: MongoDB 8.2.6 (latest)
"""

import subprocess
import time
import sys
import os

COMPOSE = os.path.join(os.path.dirname(__file__), "..", "harness", "docker-compose.yml")

def mongosh(container, cmd, timeout=30):
    r = subprocess.run(
        ["docker", "exec", container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return r

def setup_cluster():
    print("=== Setting up 2-shard cluster (3-node RS for shard0) ===")

    # Use a compose file with 3-node shard0 (needed for stepdown)
    subprocess.run(["docker", "compose", "-f", COMPOSE, "down", "-v"],
                   capture_output=True, timeout=30)

    # We need the harness docker-compose. But it only has 1-node shards.
    # For stepdown we need at least 2 nodes. Write a custom compose.
    compose_content = """
version: '3.8'
services:
  configsvr:
    image: mongo:latest
    container_name: rd-configsvr
    command: >
      mongod --configsvr --replSet configRS --port 27017
      --setParameter enableTestCommands=1
      --bind_ip_all
    networks: [mongo-net]

  shard0a:
    image: mongo:latest
    container_name: rd-shard0a
    command: >
      mongod --shardsvr --replSet shard0RS --port 27017
      --setParameter enableTestCommands=1
      --setParameter logComponentVerbosity='{sharding: {verbosity: 2}}'
      --bind_ip_all
      --logpath /var/log/mongodb/mongod.log --logappend
    volumes: [shard0a-logs:/var/log/mongodb]
    networks: [mongo-net]

  shard0b:
    image: mongo:latest
    container_name: rd-shard0b
    command: >
      mongod --shardsvr --replSet shard0RS --port 27017
      --setParameter enableTestCommands=1
      --bind_ip_all
    networks: [mongo-net]

  shard1:
    image: mongo:latest
    container_name: rd-shard1
    command: >
      mongod --shardsvr --replSet shard1RS --port 27017
      --setParameter enableTestCommands=1
      --bind_ip_all
    networks: [mongo-net]

  mongos:
    image: mongo:latest
    container_name: rd-mongos
    command: >
      mongos --configdb configRS/configsvr:27017
      --setParameter enableTestCommands=1
      --bind_ip_all --port 27017
    depends_on: [configsvr]
    ports: ["27317:27017"]
    networks: [mongo-net]

volumes:
  shard0a-logs:

networks:
  mongo-net:
    driver: bridge
"""
    compose_path = "/tmp/rd-compose.yml"
    with open(compose_path, "w") as f:
        f.write(compose_content)

    subprocess.run(["docker", "compose", "-f", compose_path, "down", "-v"],
                   capture_output=True, timeout=30)
    subprocess.run(["docker", "compose", "-f", compose_path, "up", "-d"],
                   capture_output=True, timeout=60)
    time.sleep(8)

    # Init RS
    for c in ["rd-configsvr", "rd-shard0a", "rd-shard0b", "rd-shard1"]:
        for i in range(25):
            if mongosh(c, "db.runCommand({ping:1})").returncode == 0:
                break
            time.sleep(1)

    mongosh("rd-configsvr", 'rs.initiate({_id:"configRS",configsvr:true,members:[{_id:0,host:"configsvr:27017"}]})')
    time.sleep(3)
    mongosh("rd-shard0a", 'rs.initiate({_id:"shard0RS",members:[{_id:0,host:"shard0a:27017",priority:2},{_id:1,host:"shard0b:27017",priority:1}]})')
    time.sleep(5)
    mongosh("rd-shard1", 'rs.initiate({_id:"shard1RS",members:[{_id:0,host:"shard1:27017"}]})')
    time.sleep(3)

    for i in range(20):
        if mongosh("rd-mongos", "db.runCommand({ping:1})").returncode == 0:
            break
        time.sleep(1)

    mongosh("rd-mongos", 'sh.addShard("shard0RS/shard0a:27017,shard0b:27017"); sh.addShard("shard1RS/shard1:27017")')
    time.sleep(2)

    # Create sharded collection
    mongosh("rd-mongos", '''
        sh.enableSharding("testDB");
        db.getSiblingDB("testDB").createCollection("testColl");
        sh.shardCollection("testDB.testColl", {_id: 1});
        var d = db.getSiblingDB("testDB");
        for (var i = 0; i < 100; i++) d.testColl.insertOne({_id: i, data: "pad"});
    ''')
    print("Cluster ready.")
    return compose_path


def run_test():
    print("\n=== Step 1: Start migration M1, pause before forgetMigration ===")

    # Enable failpoint to pause after abort's deleteRangeDeletionTaskLocally
    # but before forgetMigration removes coordinator doc
    r = mongosh("rd-shard0a", '''
        db.adminCommand({
            configureFailPoint: "hangBeforeForgettingMigrationAfterAbortDecision",
            mode: "alwaysOn"
        });
    ''')
    print(f"  Failpoint: ok={'ok' in r.stdout}")

    # Move chunk to shard1 — this is M1
    print("  Starting M1 (moveChunk shard0 → shard1)...")
    r = mongosh("rd-mongos", '''
        db.adminCommand({moveChunk: "testDB.testColl", find: {_id: 50}, to: "shard1RS"});
    ''', timeout=60)
    print(f"  M1 result: {r.stdout.strip()[:100]}")

    # Check coordinator doc on shard0
    r = mongosh("rd-shard0a", '''
        var docs = db.getSiblingDB("config").migrationCoordinators.find().toArray();
        print("coordDocs: " + docs.length);
    ''')
    print(f"  {r.stdout.strip()}")

    # Check range deletion tasks
    r = mongosh("rd-shard0a", '''
        var docs = db.getSiblingDB("config").rangeDeletions.find().toArray();
        print("rangeDeletions: " + docs.length);
        docs.forEach(d => print("  range: " + tojson(d.range) + " migrationId: " + d._id));
    ''')
    print(f"  {r.stdout.strip()}")

    print("\n=== Step 2: Step down shard0 primary before forgetMigration ===")
    # Release failpoint but immediately step down
    mongosh("rd-shard0a", '''
        db.adminCommand({configureFailPoint: "hangBeforeForgettingMigrationAfterAbortDecision", mode: "off"});
    ''')

    # Step down immediately
    mongosh("rd-shard0a", '''
        try { db.adminCommand({replSetStepDown: 10, force: true}); }
        catch(e) { print("stepdown: " + e.message); }
    ''')
    time.sleep(8)

    # Find new primary
    for c in ["rd-shard0a", "rd-shard0b"]:
        r = mongosh(c, "rs.isMaster().ismaster")
        if "true" in r.stdout.lower():
            primary = c
            break
    else:
        primary = "rd-shard0a"
    print(f"  New primary: {primary}")

    # Check coordinator doc survived (should be there since forgetMigration didn't complete)
    r = mongosh(primary, '''
        var docs = db.getSiblingDB("config").migrationCoordinators.find().toArray();
        print("coordDocs after stepdown: " + docs.length);
    ''')
    print(f"  {r.stdout.strip()}")

    print("\n=== Step 3: Commit migration M2 on same range ===")
    # Chunk should be on shard1 now (M1 committed the move before aborting cleanup)
    # Or it might still be on shard0 if M1 was truly aborted before data move
    # Let's move the same range again
    r = mongosh("rd-mongos", '''
        // Check where the chunk is
        var chunks = db.getSiblingDB("config").chunks.find({ns: "testDB.testColl"}).toArray();
        chunks.forEach(c => print("chunk: " + tojson(c.min) + " → " + c.shard));
    ''')
    print(f"  Current chunks: {r.stdout.strip()}")

    # Move chunk (M2) — if already on shard1, move back to shard0 then to shard1
    r = mongosh("rd-mongos", '''
        try {
            db.adminCommand({moveChunk: "testDB.testColl", find: {_id: 50}, to: "shard0RS"});
            print("Moved to shard0RS");
        } catch(e) {
            print("Move to shard0: " + e.message);
        }
    ''', timeout=60)
    print(f"  {r.stdout.strip()[:150]}")

    r = mongosh("rd-mongos", '''
        try {
            db.adminCommand({moveChunk: "testDB.testColl", find: {_id: 50}, to: "shard1RS"});
            print("M2 committed: moved to shard1RS");
        } catch(e) {
            print("M2: " + e.message);
        }
    ''', timeout=60)
    print(f"  {r.stdout.strip()[:150]}")

    print("\n=== Step 4: Check range deletion task docs ===")
    # After M2 commits, shard0 should have a new range deletion task doc
    r = mongosh(primary, '''
        var docs = db.getSiblingDB("config").rangeDeletions.find().toArray();
        print("rangeDeletions: " + docs.length);
        docs.forEach(d => print("  id=" + d._id + " range=" + tojson(d.range)));
    ''')
    print(f"  {r.stdout.strip()}")

    # Wait for recovery to replay M1's coordinator doc
    print("\n=== Step 5: Wait for recovery to replay M1's abort ===")
    time.sleep(10)

    # Check again — if bug triggered, M2's task doc is gone
    r = mongosh(primary, '''
        var docs = db.getSiblingDB("config").rangeDeletions.find().toArray();
        print("rangeDeletions after recovery: " + docs.length);
        docs.forEach(d => print("  id=" + d._id + " range=" + tojson(d.range)));
    ''')
    result = r.stdout.strip()
    print(f"  {result}")

    if "rangeDeletions after recovery: 0" in result:
        print("\n  =============================================")
        print("  BUG REPRODUCED: M2's range deletion task doc")
        print("  was deleted by M1's abort recovery!")
        print("  =============================================")
        return True
    else:
        print("\n  Bug not triggered in this run.")
        print("  M2's task doc may have been cleaned up normally,")
        print("  or the recovery timing didn't align.")
        return False


def cleanup(compose_path):
    subprocess.run(["docker", "compose", "-f", compose_path, "down", "-v"],
                   capture_output=True, timeout=30)


if __name__ == "__main__":
    compose_path = setup_cluster()
    try:
        triggered = run_test()
        if not triggered:
            print("\nRetrying with different timing...")
            triggered = run_test()
    finally:
        cleanup(compose_path)

    sys.exit(0 if triggered else 1)
