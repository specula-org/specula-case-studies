use crate::compaction_worker::{CompactionWorkerHandler, WorkerMessage};
use crate::compactions_store::CompactionsStore;
use crate::compactor::{
    stats::CompactionStats, CompactionScheduler, Compactor, CompactorEventHandler,
    CompactorMessage, SourceId,
};
use crate::compactor_executor::{CompactionExecutor, StartCompactionJobArgs};
use crate::compactor_state::CompactionSpec;
use crate::config::{
    CompactionWorkerOptions, CompactorOptions, GarbageCollectorDirectoryOptions,
    GarbageCollectorOptions,
};
use crate::db_state::{SortedRun, SsTableHandle, SsTableId, SsTableView};
use crate::dispatcher::MessageHandler;
use crate::error::SlateDBError;
use crate::format::sst::SsTableFormat;
use crate::garbage_collector::GarbageCollector;
use crate::manifest::store::{ManifestStore, StoredManifest};
use crate::manifest::ManifestCore;
use crate::object_stores::ObjectStores;
use crate::tablestore::{TableStore, TableStoreKind};
use crate::tla_trace;
use crate::types::RowEntry;
use crate::utils::IdGenerator;
use fail_parallel::FailPointRegistry;
use object_store::memory::InMemory;
use object_store::path::Path;
use object_store::ObjectStore;
use parking_lot::Mutex;
use slatedb_common::clock::SystemClock;
use slatedb_common::metrics::MetricsRecorderHelper;
use slatedb_common::{DbRand, MockSystemClock};
use std::sync::Arc;
use std::time::Duration;
use ulid::Ulid;

const ROOT: &str = "/specula-trace-harness";
const COMPACTOR_SEED: u64 = 17;
const SUBMIT_SEED_J2: u64 = 21;
const SUBMIT_SEED_J3: u64 = 23;
const WORKER1_SEED: u64 = 31;
const WORKER2_SEED: u64 = 37;

#[derive(Clone)]
struct TestScheduler {
    queue: Arc<Mutex<Vec<CompactionSpec>>>,
}

impl TestScheduler {
    fn new() -> Self {
        Self {
            queue: Arc::new(Mutex::new(Vec::new())),
        }
    }

    fn push(&self, spec: CompactionSpec) {
        self.queue.lock().push(spec);
    }
}

impl CompactionScheduler for TestScheduler {
    fn propose(&self, _state: &crate::compactor::CompactorStateView) -> Vec<CompactionSpec> {
        std::mem::take(&mut *self.queue.lock())
    }
}

struct NoopExecutor {
    jobs: Mutex<Vec<StartCompactionJobArgs>>,
}

impl NoopExecutor {
    fn new() -> Self {
        Self {
            jobs: Mutex::new(Vec::new()),
        }
    }
}

impl CompactionExecutor for NoopExecutor {
    fn start_compaction_job(&self, args: StartCompactionJobArgs) {
        self.jobs.lock().push(args);
    }

    fn stop_compaction_job(&self, _id: Ulid) -> bool {
        true
    }

    fn stop(&self) {}
}

struct HarnessFixture {
    clock: Arc<MockSystemClock>,
    object_store: Arc<dyn ObjectStore>,
    manifest_store: Arc<ManifestStore>,
    compactions_store: Arc<CompactionsStore>,
    table_store: Arc<TableStore>,
    scheduler: Arc<TestScheduler>,
    compactor_options: Arc<CompactorOptions>,
    worker_options: Arc<CompactionWorkerOptions>,
    root_sr: SortedRun,
    l0_view: SsTableView,
}

impl HarnessFixture {
    async fn new() -> Self {
        let clock = Arc::new(MockSystemClock::with_time(0));
        let object_store: Arc<dyn ObjectStore> = Arc::new(InMemory::new());
        let manifest_store = Arc::new(ManifestStore::new(&Path::from(ROOT), object_store.clone()));
        let compactions_store =
            Arc::new(CompactionsStore::new(&Path::from(ROOT), object_store.clone()));
        let table_store = Arc::new(TableStore::new(
            ObjectStores::new(object_store.clone(), None),
            SsTableFormat::default(),
            Path::from(ROOT),
            None,
            TableStoreKind::Compactor,
        ));

        let s0 = write_fixed_sst(&table_store, fixed_ulid(0, 0x10), b"a", b"root").await;
        let s2 = write_fixed_sst(&table_store, fixed_ulid(2, 0x20), b"b", b"l0").await;
        let root_sr = SortedRun {
            id: 0,
            sst_views: vec![SsTableView::identity(s0.clone())],
        };
        let l0_view = SsTableView::identity(s2.clone());

        let mut core = ManifestCore::new();
        Arc::make_mut(&mut core.tree).compacted.push(root_sr.clone());
        Arc::make_mut(&mut core.tree)
            .l0
            .push_back(l0_view.clone());
        StoredManifest::create_new_db(manifest_store.clone(), core, clock.clone())
            .await
            .unwrap();

        let scheduler = Arc::new(TestScheduler::new());
        let mut compactor_options = CompactorOptions::default();
        compactor_options.max_concurrent_compactions = 1;
        compactor_options.worker_heartbeat_timeout = Duration::from_millis(2);
        let mut worker_options = CompactionWorkerOptions::default();
        worker_options.max_concurrent_compactions = 1;

        Self {
            clock,
            object_store,
            manifest_store,
            compactions_store,
            table_store,
            scheduler,
            compactor_options: Arc::new(compactor_options),
            worker_options: Arc::new(worker_options),
            root_sr,
            l0_view,
        }
    }

    fn register_initial_ssts(&self) {
        tla_trace::register_sst(&self.root_sr.sst_views[0].sst.id, "s0");
        tla_trace::register_sst(&self.l0_view.sst.id, "s2");
    }

    async fn new_compactor(&self, seed: u64) -> CompactorEventHandler {
        let recorder = MetricsRecorderHelper::noop();
        let stats = Arc::new(CompactionStats::new(&recorder));
        CompactorEventHandler::new(
            self.manifest_store.clone(),
            self.compactions_store.clone(),
            self.compactor_options.clone(),
            self.scheduler.clone(),
            Arc::new(DbRand::new(seed)),
            stats,
            self.clock.clone(),
            recorder,
        )
        .await
        .unwrap()
    }

    fn predict_local_job_id(&self, seed: u64) -> Ulid {
        let rand = DbRand::new(seed);
        let predicted = rand.rng().gen_ulid(self.clock.as_ref());
        predicted
    }

    fn new_worker(&self, worker_id: &str, seed: u64) -> CompactionWorkerHandler {
        let executor: Arc<dyn CompactionExecutor + Send + Sync> = Arc::new(NoopExecutor::new());
        CompactionWorkerHandler::new(
            worker_id.to_string(),
            self.worker_options.clone(),
            self.compactions_store.clone(),
            self.manifest_store.clone(),
            executor,
            self.clock.clone(),
            Arc::new(DbRand::new(seed)),
            Arc::new(FailPointRegistry::new()),
        )
    }

    async fn durable_view(&self) -> (crate::manifest::VersionedManifest, crate::VersionedCompactions) {
        (
            self.manifest_store.read_latest_manifest().await.unwrap(),
            self.compactions_store.read_latest_compactions().await.unwrap(),
        )
    }

    async fn submit_external(&self, model_job: &str, seed: u64, spec: CompactionSpec) -> Ulid {
        let compaction_id = Compactor::submit(
            spec,
            self.compactions_store.clone(),
            Arc::new(DbRand::new(seed)),
            self.clock.clone(),
        )
        .await
        .unwrap();
        tla_trace::register_job(compaction_id, model_job);
        let (manifest, compactions) = self.durable_view().await;
        tla_trace::emit_external_submit(
            self.clock.now().timestamp_millis(),
            compaction_id,
            &manifest,
            &compactions,
        );
        compaction_id
    }

    async fn emit_refresh_checkpoint(&self, job_id: Ulid) {
        let mut manifest = StoredManifest::load(self.manifest_store.clone(), self.clock.clone())
            .await
            .unwrap();
        let checkpoint = manifest
            .manifest()
            .core
            .checkpoints
            .first()
            .expect("missing checkpoint after commit")
            .clone();
        manifest
            .refresh_checkpoint(checkpoint.id, Duration::from_secs(900))
            .await
            .unwrap();
        let (durable_manifest, durable_compactions) = self.durable_view().await;
        tla_trace::emit_refresh_checkpoint(
            self.clock.now().timestamp_millis(),
            job_id,
            &durable_manifest,
            &durable_compactions,
        );
    }

    async fn emit_write_output(
        &self,
        worker_id: &str,
        job_id: Ulid,
        output: &SsTableHandle,
    ) {
        let (durable_manifest, durable_compactions) = self.durable_view().await;
        tla_trace::emit_write_output_sst(
            self.clock.now().timestamp_millis(),
            worker_id,
            job_id,
            &output.id,
            &durable_manifest,
            &durable_compactions,
        );
    }

    async fn run_gc_once(&self) {
        let gc = GarbageCollector::new(
            self.manifest_store.clone(),
            self.compactions_store.clone(),
            self.table_store.clone(),
            self.object_store.clone(),
            GarbageCollectorOptions {
                manifest_options: None,
                wal_options: None,
                wal_fence_options: None,
                compacted_options: Some(GarbageCollectorDirectoryOptions {
                    min_age: Duration::from_millis(1),
                    interval: None,
                    dry_run: false,
                }),
                compactions_options: None,
                detach_options: None,
                metric_level: None,
                boundary_files_enabled: false,
            },
            &MetricsRecorderHelper::noop(),
            self.clock.clone(),
            None,
        );
        gc.run_gc_once().await;
    }
}

fn fixed_ulid(ts_ms: u64, rand: u128) -> Ulid {
    Ulid::from_parts(ts_ms, rand)
}

async fn write_fixed_sst(
    table_store: &Arc<TableStore>,
    id: Ulid,
    key: &'static [u8],
    value: &'static [u8],
) -> SsTableHandle {
    let mut writer = table_store.table_writer(SsTableId::Compacted(id));
    writer
        .add(RowEntry::new_value(key, value, 0))
        .await
        .unwrap();
    writer.close().await.unwrap()
}

fn output_sorted_run(id: u32, handle: SsTableHandle) -> SortedRun {
    SortedRun {
        id,
        sst_views: vec![SsTableView::identity(handle)],
    }
}

#[tokio::test]
async fn trace_success_gc_and_submitted_fail() {
    let _guard = tla_trace::start_scenario("success_gc_and_submitted_fail");
    let fixture = HarnessFixture::new().await;
    fixture.register_initial_ssts();

    let mut compactor = fixture.new_compactor(COMPACTOR_SEED).await;

    fixture.clock.advance(Duration::from_millis(1)).await;
    let j1 = fixture.predict_local_job_id(COMPACTOR_SEED);
    tla_trace::register_job(j1, "j1");
    fixture
        .scheduler
        .push(CompactionSpec::new(vec![SourceId::SortedRun(0)], 0));
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();

    let mut worker = fixture.new_worker("w1", WORKER1_SEED);
    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut worker, WorkerMessage::PollCompactions)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut worker, WorkerMessage::HeartbeatOwnedJobs)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    let output = write_fixed_sst(
        &fixture.table_store,
        fixed_ulid(4, 0x30),
        b"c",
        b"out",
    )
    .await;
    tla_trace::register_sst(&output.id, "o0");
    fixture.emit_write_output("w1", j1, &output).await;
    MessageHandler::handle(
        &mut worker,
        WorkerMessage::CompactionJobFinished {
            id: j1,
            result: Ok(output_sorted_run(0, output.clone())),
        },
    )
    .await
    .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut compactor, CompactorMessage::CommitCompacted)
        .await
        .unwrap();

    let j2 = fixture
        .submit_external(
            "j2",
            SUBMIT_SEED_J2,
            CompactionSpec::new(
                vec![SourceId::SortedRun(99)],
                1,
            ),
        )
        .await;
    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    fixture.emit_refresh_checkpoint(j1).await;

    fixture.clock.advance(Duration::from_secs(901)).await;
    fixture.run_gc_once().await;
    let remaining = fixture
        .table_store
        .list_compacted_ssts(..)
        .await
        .unwrap()
        .into_iter()
        .map(|meta| meta.id)
        .collect::<Vec<_>>();
    assert!(
        !remaining.contains(&fixture.root_sr.sst_views[0].sst.id),
        "expected source SST to be collected by GC"
    );
    let (durable_manifest, durable_compactions) = fixture.durable_view().await;
    tla_trace::emit_gc_sweep(
        fixture.clock.now().timestamp_millis(),
        &fixture.root_sr.sst_views[0].sst.id,
        &durable_manifest,
        &durable_compactions,
    );

    let _ = j2;
}

#[tokio::test]
async fn trace_external_submit_exec_error() {
    let _guard = tla_trace::start_scenario("external_submit_exec_error");
    let fixture = HarnessFixture::new().await;
    fixture.register_initial_ssts();

    let mut compactor = fixture.new_compactor(COMPACTOR_SEED).await;
    let mut worker = fixture.new_worker("w1", WORKER1_SEED);

    fixture.clock.advance(Duration::from_millis(1)).await;
    let j3 = fixture
        .submit_external(
            "j3",
            SUBMIT_SEED_J3,
            CompactionSpec::new(vec![SourceId::SstView(fixture.l0_view.id)], 2),
        )
        .await;
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut worker, WorkerMessage::PollCompactions)
        .await
        .unwrap();
    MessageHandler::handle(
        &mut worker,
        WorkerMessage::CompactionJobFinished {
            id: j3,
            result: Err(SlateDBError::InvalidDBState),
        },
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn trace_reclaim_stop_duplicate() {
    let _guard = tla_trace::start_scenario("reclaim_stop_duplicate");
    let fixture = HarnessFixture::new().await;
    fixture.register_initial_ssts();

    let mut compactor = fixture.new_compactor(COMPACTOR_SEED).await;
    let mut worker = fixture.new_worker("w1", WORKER1_SEED);

    fixture.clock.advance(Duration::from_millis(1)).await;
    let _j3 = fixture
        .submit_external(
            "j3",
            SUBMIT_SEED_J3,
            CompactionSpec::new(vec![SourceId::SstView(fixture.l0_view.id)], 2),
        )
        .await;
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut worker, WorkerMessage::PollCompactions)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(3)).await;
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();
    MessageHandler::handle(&mut worker, WorkerMessage::PollCompactions)
        .await
        .unwrap();
}

#[tokio::test]
async fn trace_crash_restart_and_heartbeat_lose_ownership() {
    let _guard = tla_trace::start_scenario("crash_restart_and_heartbeat_lose_ownership");
    let fixture = HarnessFixture::new().await;
    fixture.register_initial_ssts();

    let compactor = fixture.new_compactor(COMPACTOR_SEED).await;
    tla_trace::emit_crash_coordinator(fixture.clock.now().timestamp_millis());
    drop(compactor);

    let mut restarted = fixture.new_compactor(COMPACTOR_SEED + 1).await;
    let mut worker1 = fixture.new_worker("w1", WORKER1_SEED);
    let mut worker2 = fixture.new_worker("w2", WORKER2_SEED);

    fixture.clock.advance(Duration::from_millis(1)).await;
    let _j3 = fixture
        .submit_external(
            "j3",
            SUBMIT_SEED_J3,
            CompactionSpec::new(vec![SourceId::SstView(fixture.l0_view.id)], 2),
        )
        .await;
    MessageHandler::handle(&mut restarted, CompactorMessage::PollManifest)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut worker1, WorkerMessage::PollCompactions)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(3)).await;
    MessageHandler::handle(&mut restarted, CompactorMessage::PollManifest)
        .await
        .unwrap();
    MessageHandler::handle(&mut worker2, WorkerMessage::PollCompactions)
        .await
        .unwrap();
    MessageHandler::handle(&mut worker1, WorkerMessage::HeartbeatOwnedJobs)
        .await
        .unwrap();
}

#[tokio::test]
async fn trace_handle_finished_lost_ownership() {
    let _guard = tla_trace::start_scenario("handle_finished_lost_ownership");
    let fixture = HarnessFixture::new().await;
    fixture.register_initial_ssts();

    let mut compactor = fixture.new_compactor(COMPACTOR_SEED).await;
    let mut worker = fixture.new_worker("w1", WORKER1_SEED);

    fixture.clock.advance(Duration::from_millis(1)).await;
    let j3 = fixture
        .submit_external(
            "j3",
            SUBMIT_SEED_J3,
            CompactionSpec::new(vec![SourceId::SstView(fixture.l0_view.id)], 2),
        )
        .await;
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(1)).await;
    MessageHandler::handle(&mut worker, WorkerMessage::PollCompactions)
        .await
        .unwrap();

    fixture.clock.advance(Duration::from_millis(3)).await;
    MessageHandler::handle(&mut compactor, CompactorMessage::PollManifest)
        .await
        .unwrap();

    let orphan_output = write_fixed_sst(
        &fixture.table_store,
        fixed_ulid(4, 0x41),
        b"lost",
        b"ownership",
    )
    .await;
    MessageHandler::handle(
        &mut worker,
        WorkerMessage::CompactionJobFinished {
            id: j3,
            result: Ok(output_sorted_run(2, orphan_output)),
        },
    )
    .await
    .unwrap();
}
