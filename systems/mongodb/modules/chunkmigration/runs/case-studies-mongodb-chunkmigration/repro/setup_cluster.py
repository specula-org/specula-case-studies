#!/usr/bin/env python3
"""Initialize the sharded MongoDB cluster for reproduction tests."""

import time
import sys
from pymongo import MongoClient
from pymongo.errors import OperationFailure


# When running from host, use these ports (mapped by docker-compose)
# When running inside docker network, use service names and internal ports
DOCKER_HOST = "localhost"
USE_HOST = True  # Set to False if running inside docker network

def get_host(service, internal_port):
    """Get connection parameters for a service."""
    if USE_HOST:
        port_map = {
            ("configsvr", 27019): 27117 + 2,  # We'll compute below
            ("shard0a", 27018): 27117 + 3,
            ("shard0b", 27018): 27117 + 4,
            ("shard1", 27018): 27117 + 5,
            ("mongos", 27017): 27117,
        }
        # Actually, let's just use docker exec
        return service, internal_port
    return service, internal_port


def wait_for_mongod(host, port, timeout=60):
    """Wait for a mongod instance to become available."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            c = MongoClient(host, port, serverSelectionTimeoutMS=2000, directConnection=True)
            c.admin.command("ping")
            c.close()
            return True
        except Exception:
            time.sleep(1)
    return False


def init_replica_set(host, port, rs_name, members):
    """Initialize a replica set."""
    c = MongoClient(host, port, directConnection=True)
    config = {"_id": rs_name, "members": members}
    try:
        c.admin.command("replSetInitiate", config)
    except OperationFailure as e:
        if "already initialized" in str(e):
            print(f"  {rs_name} already initialized")
            c.close()
            return
        raise
    c.close()
    time.sleep(5)


def wait_for_primary(host, port, timeout=60):
    """Wait for the replica set to elect a primary."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            c = MongoClient(host, port, directConnection=True)
            status = c.admin.command("replSetGetStatus")
            for member in status.get("members", []):
                if member.get("stateStr") == "PRIMARY":
                    c.close()
                    return True
            c.close()
        except Exception:
            pass
        time.sleep(1)
    return False


def main():
    print("=== Setting up MongoDB sharded cluster ===\n")

    nodes = [
        ("configsvr", 27019),
        ("shard0a", 27018),
        ("shard0b", 27018),
        ("shard1", 27018),
    ]
    for host, port in nodes:
        print(f"Waiting for {host}:{port}...")
        if not wait_for_mongod(host, port):
            print(f"  FAILED: {host}:{port} not available")
            sys.exit(1)
        print(f"  OK")

    print("\nInitializing config server replica set...")
    init_replica_set("configsvr", 27019, "cfgrs", [
        {"_id": 0, "host": "configsvr:27019"}
    ])
    wait_for_primary("configsvr", 27019)
    print("  Config server RS ready")

    print("Initializing shard0 replica set (2-node)...")
    init_replica_set("shard0a", 27018, "shard0rs", [
        {"_id": 0, "host": "shard0a:27018", "priority": 2},
        {"_id": 1, "host": "shard0b:27018", "priority": 1},
    ])
    wait_for_primary("shard0a", 27018)
    print("  shard0 RS ready")

    print("Initializing shard1 replica set...")
    init_replica_set("shard1", 27018, "shard1rs", [
        {"_id": 0, "host": "shard1:27018"}
    ])
    wait_for_primary("shard1", 27018)
    print("  shard1 RS ready")

    print("\nWaiting for mongos...")
    if not wait_for_mongod("mongos", 27017):
        print("  FAILED: mongos not available")
        sys.exit(1)
    print("  mongos ready")

    print("\nAdding shards to cluster...")
    mongos = MongoClient("mongos", 27017)
    try:
        mongos.admin.command("addShard", "shard0rs/shard0a:27018,shard0b:27018")
        print("  shard0 added")
    except OperationFailure as e:
        if "already" in str(e).lower():
            print("  shard0 already added")
        else:
            raise
    try:
        mongos.admin.command("addShard", "shard1rs/shard1:27018")
        print("  shard1 added")
    except OperationFailure as e:
        if "already" in str(e).lower():
            print("  shard1 already added")
        else:
            raise

    print("\nEnabling sharding on testdb...")
    try:
        mongos.admin.command("enableSharding", "testdb")
    except OperationFailure:
        pass  # Already enabled

    print("Creating sharded collection testdb.testcol...")
    try:
        mongos.admin.command("shardCollection", "testdb.testcol", key={"x": 1})
    except OperationFailure as e:
        if "already" in str(e).lower():
            print("  Already sharded")
        else:
            raise

    print("Inserting test data...")
    db = mongos["testdb"]
    existing = db.testcol.count_documents({})
    if existing < 100:
        db.testcol.insert_many([{"x": i, "data": f"value_{i}"} for i in range(100)])

    print("Splitting chunk at x=50...")
    try:
        mongos.admin.command("split", "testdb.testcol", middle={"x": 50})
    except OperationFailure as e:
        if "can't split" in str(e).lower() or "already" in str(e).lower():
            print("  Chunk already split or can't split further")
        else:
            raise

    print("\n=== Cluster setup complete ===")
    print("  mongos: mongos:27017 (host: localhost:27117)")
    print("  shard0: shard0rs/shard0a:27018,shard0b:27018")
    print("  shard1: shard1rs/shard1:27018")
    print("  Database: testdb, Collection: testcol, Shard key: {x: 1}")
    print("  Chunks: [-inf, 50) and [50, +inf)")

    mongos.close()


if __name__ == "__main__":
    main()
