#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:?Set SOURCE_REPO to a SlateDB checkout}"
REPRO_TMP_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/slatedb-mc1-repro.XXXXXX")"
REPRO_DIR="$REPRO_TMP_PARENT/project"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$REPRO_TMP_PARENT/target}"
export CARGO_TARGET_DIR
export TMPDIR="$REPRO_TMP_PARENT"
trap 'rm -rf "$REPRO_TMP_PARENT"' EXIT

mkdir -p "$REPRO_DIR/src"

cat > "$REPRO_DIR/Cargo.toml" <<EOF
[package]
name = "slatedb_mc1_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
slatedb = { path = "$SOURCE_REPO/slatedb", default-features = false }
tokio = { version = "1.47.1", features = ["macros", "rt-multi-thread", "time"] }
tokio-util = { version = "0.7.16", default-features = false, features = ["rt"] }
EOF

cat > "$REPRO_DIR/src/main.rs" <<'EOF'
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use slatedb::admin::Admin;
use slatedb::compactor::{
    CompactionRequest, CompactionSchedulerSupplier, CompactionSpec, CompactionStatus,
    SizeTieredCompactionSchedulerSupplier, SourceId,
};
use slatedb::config::{
    CompactionWorkerOptions, CompactorOptions, SizeTieredCompactionSchedulerOptions,
};
use slatedb::object_store::memory::InMemory;
use slatedb::{CloseReason, Db, ErrorKind, Settings};
use tokio_util::sync::CancellationToken;

fn fast_worker_options(max_concurrent_compactions: usize) -> CompactionWorkerOptions {
    CompactionWorkerOptions {
        max_concurrent_compactions,
        compactions_poll_interval: Duration::from_millis(10),
        heartbeat_interval: Duration::from_millis(10),
        max_subcompactions: 1,
        ..CompactionWorkerOptions::default()
    }
}

fn fast_compactor_options(worker: Option<CompactionWorkerOptions>) -> CompactorOptions {
    let scheduler_options: HashMap<String, String> = SizeTieredCompactionSchedulerOptions {
        min_compaction_sources: 2,
        max_compaction_sources: 8,
        include_size_threshold: 4.0,
    }
    .into();

    CompactorOptions {
        poll_interval: Duration::from_millis(10),
        max_concurrent_compactions: 4,
        scheduler_options,
        worker,
        commit_compacted_interval: Duration::from_millis(10),
        worker_heartbeat_timeout: Duration::from_secs(30),
        ..CompactorOptions::default()
    }
}

fn fast_settings() -> Settings {
    Settings {
        flush_interval: Some(Duration::from_millis(10)),
        manifest_poll_interval: Duration::from_millis(10),
        l0_sst_size_bytes: 256,
        l0_max_ssts: 8,
        compactor_options: Some(fast_compactor_options(Some(fast_worker_options(4)))),
        ..Settings::default()
    }
}

async fn wait_for<F, Fut>(label: &str, timeout: Duration, mut check: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = Instant::now() + timeout;
    loop {
        if check().await {
            return;
        }
        if Instant::now() >= deadline {
            panic!("timed out waiting for {label}");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn scheduled_matches(admin: &Admin, spec: &CompactionSpec) -> usize {
    admin
        .read_compactions(None)
        .await
        .expect("read compactions")
        .expect("compactions object exists")
        .recent_compactions()
        .filter(|c| c.status() == CompactionStatus::Scheduled && c.spec() == spec)
        .count()
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let object_store = Arc::new(InMemory::new());
    let path = "/specula/repro/mc1/external-compaction-conflict";

    let db = Db::builder(path, object_store.clone())
        .with_settings(fast_settings())
        .build()
        .await?;
    let admin = Admin::builder(path, object_store.clone()).build();

    for i in 0..2 {
        let key = format!("key-{i:04}");
        let value = vec![b'x'; 2048];
        db.put(key.as_bytes(), value.as_slice()).await?;
        db.flush().await?;
    }

    wait_for("initial L0 compaction to produce SR(0)", Duration::from_secs(10), || {
        let admin = &admin;
        async move {
            admin
                .read_compactor_state_view()
                .await
                .map(|view| !view.manifest().compacted().is_empty())
                .unwrap_or(false)
        }
    })
    .await;
    db.close().await?;

    let view = admin.read_compactor_state_view().await?;
    let scheduler = SizeTieredCompactionSchedulerSupplier::new()
        .compaction_scheduler(&CompactorOptions::default());
    let mut specs = scheduler.generate(&view, &CompactionRequest::Full)?;
    assert_eq!(specs.len(), 1, "expected exactly one Full compaction spec");
    let spec = specs.remove(0);
    assert!(
        spec.sources()
            .iter()
            .all(|source| matches!(source, SourceId::SortedRun(_))),
        "repro needs an SR-only compaction so the L0 parallelism guard is irrelevant"
    );
    println!(
        "Generated manual Full compaction spec: sources={:?}, destination={:?}",
        spec.sources(),
        spec.destination()
    );

    let first = admin.submit_compaction(spec.clone()).await?;
    let second = admin.submit_compaction(spec.clone()).await?;
    println!(
        "Submitted duplicate external compactions: first={}, second={}, initial_statuses={:?}/{:?}",
        first.id(),
        second.id(),
        first.status(),
        second.status()
    );

    let coordinator_admin = Admin::builder(path, object_store.clone()).build();
    let coordinator_token = CancellationToken::new();
    let coordinator_token_for_task = coordinator_token.clone();
    let coordinator = tokio::spawn(async move {
        coordinator_admin
            .run_compactor_with_options(
                coordinator_token_for_task,
                fast_compactor_options(None),
            )
            .await
    });

    wait_for("coordinator to promote both duplicate submissions", Duration::from_secs(10), || {
        let admin = &admin;
        let spec = &spec;
        async move { scheduled_matches(admin, spec).await == 2 }
    })
    .await;

    println!(
        "Coordinator promoted duplicate external submissions: scheduled_matches={}",
        scheduled_matches(&admin, &spec).await
    );
    coordinator_token.cancel();
    coordinator.await??;

    let worker_admin = Admin::builder(path, object_store.clone()).build();
    let worker_token = CancellationToken::new();
    let worker_token_for_task = worker_token.clone();
    let worker = tokio::spawn(async move {
        worker_admin
            .run_compaction_worker_with_options(worker_token_for_task, fast_worker_options(2))
            .await
    });

    let worker_result = tokio::time::timeout(Duration::from_secs(10), worker).await;
    match worker_result {
        Ok(Ok(Err(err))) => {
            println!("Worker returned error: {err}");
            println!("Worker error kind: {:?}", err.kind());
            assert_eq!(err.kind(), ErrorKind::Closed(CloseReason::Panic));
            println!("BUG TRIGGERED: duplicate Scheduled compactions caused worker panic");
        }
        Ok(Ok(Ok(()))) => {
            panic!("worker exited cleanly; expected panic from duplicate destination");
        }
        Ok(Err(join_err)) if join_err.is_panic() => {
            println!("Worker task panicked directly: {join_err}");
            println!("BUG TRIGGERED: duplicate Scheduled compactions caused worker panic");
        }
        Ok(Err(join_err)) => {
            panic!("worker join failed without panic: {join_err}");
        }
        Err(_) => {
            worker_token.cancel();
            panic!("timed out waiting for worker to consume duplicate Scheduled compactions");
        }
    }

    Ok(())
}
EOF

chmod +x "$REPRO_DIR/src/main.rs"

echo "Running MC-1 public API reproduction from $REPRO_DIR"
timeout 5m cargo run --quiet --manifest-path "$REPRO_DIR/Cargo.toml"
