#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:?Set SOURCE_REPO to a SlateDB checkout}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slatedb-cr6-repro.XXXXXX")"
TEST_NAME="bug_cr6_custom_scheduler_l0_order"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cp -a "$SOURCE_REPO/." "$TMP_ROOT/repo"
cd "$TMP_ROOT/repo"

mkdir -p slatedb/tests
cat > "slatedb/tests/${TEST_NAME}.rs" <<'RS'
use slatedb::compactor::{
    CompactionScheduler, CompactionSchedulerSupplier, CompactionSpec, CompactorStateView, SourceId,
};
use slatedb::config::{
    CompactionWorkerOptions, CompactorOptions, FlushOptions, FlushType, PutOptions, Settings,
    WriteOptions,
};
use slatedb::object_store::memory::InMemory;
use slatedb::object_store::ObjectStore;
use slatedb::{CompactorBuilder, Db};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone)]
struct ReverseL0OnceSupplier {
    allow: Arc<AtomicBool>,
    proposed: Arc<AtomicBool>,
    observed_order: Arc<Mutex<Option<(Vec<String>, Vec<String>, Vec<String>)>>>,
}

struct ReverseL0OnceScheduler {
    allow: Arc<AtomicBool>,
    proposed: Arc<AtomicBool>,
    observed_order: Arc<Mutex<Option<(Vec<String>, Vec<String>, Vec<String>)>>>,
}

impl CompactionSchedulerSupplier for ReverseL0OnceSupplier {
    fn compaction_scheduler(
        &self,
        _options: &CompactorOptions,
    ) -> Box<dyn CompactionScheduler + Send + Sync> {
        Box::new(ReverseL0OnceScheduler {
            allow: self.allow.clone(),
            proposed: self.proposed.clone(),
            observed_order: self.observed_order.clone(),
        })
    }
}

impl CompactionScheduler for ReverseL0OnceScheduler {
    fn propose(&self, state: &CompactorStateView) -> Vec<CompactionSpec> {
        if !self.allow.load(Ordering::SeqCst) || self.proposed.load(Ordering::SeqCst) {
            return Vec::new();
        }

        let l0 = state.manifest().l0();
        if l0.len() < 2 {
            return Vec::new();
        }

        if self.proposed.swap(true, Ordering::SeqCst) {
            return Vec::new();
        }

        let manifest_l0 = l0
            .iter()
            .map(|view| view.id.to_string())
            .collect::<Vec<_>>();
        let manifest_l0_ssts = l0
            .iter()
            .map(|view| view.sst.id.unwrap_compacted_id().to_string())
            .collect::<Vec<_>>();
        let sources = l0
            .iter()
            .rev()
            .map(|view| SourceId::SstView(view.id))
            .collect::<Vec<_>>();
        let submitted_l0_sources = sources
            .iter()
            .map(|source| match source {
                SourceId::SstView(id) => id.to_string(),
                SourceId::SortedRun(id) => format!("SR({id})"),
            })
            .collect::<Vec<_>>();
        *self.observed_order.lock().unwrap() = Some((
            manifest_l0.clone(),
            manifest_l0_ssts.clone(),
            submitted_l0_sources.clone(),
        ));
        println!(
            "CR6 scheduler manifest L0 view IDs newest->oldest: {:?}",
            manifest_l0
        );
        println!(
            "CR6 scheduler manifest physical SST IDs newest->oldest: {:?}",
            manifest_l0_ssts
        );
        println!(
            "CR6 scheduler submitted source view IDs oldest->newest: {:?}",
            submitted_l0_sources
        );

        vec![CompactionSpec::new(sources, 0)]
    }

    // Intentionally inherit the trait default validate(), which returns Ok(()).
}

async fn wait_for_l0_len(db: &Db, wanted: usize, timeout: Duration) -> Vec<String> {
    let start = tokio::time::Instant::now();
    loop {
        db.refresh_manifest().await.unwrap();
        let manifest = db.manifest();
        let l0_ids = manifest
            .l0()
            .iter()
            .map(|view| view.id.to_string())
            .collect::<Vec<_>>();
        if l0_ids.len() == wanted {
            return l0_ids;
        }
        if start.elapsed() > timeout {
            panic!(
                "timed out waiting for L0 len {wanted}; latest len={} ids={l0_ids:?}",
                l0_ids.len()
            );
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_for_compaction(
    db: &Db,
    timeout: Duration,
) -> (Vec<String>, Vec<String>, Option<String>, Option<String>, usize) {
    let start = tokio::time::Instant::now();
    loop {
        db.refresh_manifest().await.unwrap();
        let manifest = db.manifest();
        let l0_ids = manifest
            .l0()
            .iter()
            .map(|view| view.id.to_string())
            .collect::<Vec<_>>();
        let l0_sst_ids = manifest
            .l0()
            .iter()
            .map(|view| view.sst.id.unwrap_compacted_id().to_string())
            .collect::<Vec<_>>();
        let watermark = manifest
            .last_compacted_l0_sst_view_id()
            .map(|id| id.to_string());
        let watermark_sst = manifest
            .last_compacted_l0_sst_id()
            .map(|id| id.to_string());
        let compacted_runs = manifest.compacted().len();
        if compacted_runs > 0 && watermark.is_some() {
            return (l0_ids, l0_sst_ids, watermark, watermark_sst, compacted_runs);
        }
        if start.elapsed() > timeout {
            panic!(
                "timed out waiting for compaction; latest l0_views={l0_ids:?} l0_ssts={l0_sst_ids:?} watermark={watermark:?} watermark_sst={watermark_sst:?} compacted_runs={compacted_runs}"
            );
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn put_and_flush_memtable(db: &Db, key: &[u8], value: &[u8]) {
    db.put_with_options(
        key,
        value,
        &PutOptions::default(),
        &WriteOptions {
            await_durable: false,
            ..Default::default()
        },
    )
    .await
    .unwrap();
    db.flush_with_options(FlushOptions {
        flush_type: FlushType::MemTable,
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn custom_scheduler_reversed_l0_sources_leave_stale_l0_and_stall_flush() {
    let object_store: Arc<dyn ObjectStore> = Arc::new(InMemory::new());
    let path = format!("/tmp/slatedb_cr6_{}", std::process::id());
    let allow = Arc::new(AtomicBool::new(false));
    let proposed = Arc::new(AtomicBool::new(false));
    let observed_order = Arc::new(Mutex::new(None));

    let mut settings = Settings::default();
    settings.flush_interval = None;
    settings.l0_sst_size_bytes = 1024 * 1024;
    settings.l0_max_ssts = 2;
    settings.l0_max_ssts_per_key = 2;
    settings.compactor_options = None;
    settings.garbage_collector_options = None;
    #[cfg(feature = "wal_disable")]
    {
        settings.wal_enabled = false;
    }

    let compactor_options = CompactorOptions {
        poll_interval: Duration::from_millis(20),
        max_concurrent_compactions: 1,
        commit_compacted_interval: Duration::from_millis(20),
        worker: Some(CompactionWorkerOptions {
            compactions_poll_interval: Duration::from_millis(20),
            max_sst_size: 1024 * 1024,
            ..Default::default()
        }),
        ..Default::default()
    };

    let scheduler = Arc::new(ReverseL0OnceSupplier {
        allow: allow.clone(),
        proposed: proposed.clone(),
        observed_order: observed_order.clone(),
    });
    let db = Db::builder(path.as_str(), object_store.clone())
        .with_settings(settings)
        .with_compactor_builder(
            CompactorBuilder::new(path.as_str(), object_store)
                .with_scheduler_supplier(scheduler)
                .with_options(compactor_options),
        )
        .build()
        .await
        .unwrap();

    put_and_flush_memtable(&db, b"k", b"v1").await;
    put_and_flush_memtable(&db, b"k", b"v2").await;

    let before_l0 = wait_for_l0_len(&db, 2, Duration::from_secs(5)).await;
    println!("CR6 before compaction L0 newest->oldest: {before_l0:?}");

    allow.store(true, Ordering::SeqCst);
    let (after_l0, after_l0_ssts, watermark, watermark_sst, compacted_runs) =
        wait_for_compaction(&db, Duration::from_secs(20)).await;
    println!(
        "CR6 after compaction+writer refresh: l0_views={after_l0:?} l0_ssts={after_l0_ssts:?} watermark_view={watermark:?} watermark_sst={watermark_sst:?} compacted_runs={compacted_runs}"
    );

    assert!(proposed.load(Ordering::SeqCst), "custom scheduler never proposed a compaction");
    let (scheduler_l0_views, scheduler_l0_ssts, submitted_sources) = observed_order
        .lock()
        .unwrap()
        .clone()
        .expect("scheduler did not record the L0/source order it saw");
    assert_eq!(
        watermark,
        Some(submitted_sources[0].clone()),
        "finish_compaction should have used the first, wrongly ordered source as the watermark"
    );
    assert_eq!(
        watermark_sst,
        Some(scheduler_l0_ssts[1].clone()),
        "the physical SST watermark should also point at the oldest scheduler input"
    );
    assert_eq!(
        after_l0_ssts,
        vec![scheduler_l0_ssts[0].clone()],
        "the writer merge retained an L0 that was already included in the compacted output"
    );

    println!(
        "CR6 scheduler source view order was {:?}; stale retained physical L0 after compaction: {}",
        scheduler_l0_views, scheduler_l0_ssts[0]
    );

    put_and_flush_memtable(&db, b"k", b"v3").await;
    let after_one_more_flush = wait_for_l0_len(&db, 2, Duration::from_secs(5)).await;
    println!("CR6 L0 after one further public memtable flush: {after_one_more_flush:?}");

    db.put_with_options(
        b"k",
        b"v4",
        &PutOptions::default(),
        &WriteOptions {
            await_durable: false,
            ..Default::default()
        },
    )
    .await
    .unwrap();

    let blocked_flush = tokio::time::timeout(
        Duration::from_secs(2),
        db.flush_with_options(FlushOptions {
            flush_type: FlushType::MemTable,
        }),
    )
    .await;
    println!("CR6 second post-compaction public flush result: {blocked_flush:?}");
    assert!(
        blocked_flush.is_err(),
        "the stale compacted L0 should consume one L0 slot and make the second post-compaction flush wait"
    );

    println!(
        "BUG TRIGGERED: public Db::flush_with_options(FlushType::MemTable) timed out because the stale compacted L0 still counts against l0_max_ssts"
    );
}
RS

echo "Running CR-6 reproduction from $TMP_ROOT/repo"
timeout 10m cargo test -p slatedb --test "$TEST_NAME" --features wal_disable -- --nocapture
