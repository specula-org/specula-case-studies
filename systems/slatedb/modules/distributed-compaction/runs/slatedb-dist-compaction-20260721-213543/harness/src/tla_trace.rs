use crate::compactor_state::{CompactionStatus, Compactions, VersionedCompactions};
use crate::db_state::SsTableId;
use crate::manifest::{ManifestCore, VersionedManifest};
use crate::compactor_state::CompactorState;
use parking_lot::Mutex;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};
use ulid::Ulid;
use uuid::Uuid;

const JOBS: [&str; 3] = ["j1", "j2", "j3"];
const WORKERS: [&str; 2] = ["w1", "w2"];
const OUTPUT_SSTS: [&str; 3] = ["o0", "o1", "o2"];
const INITIAL_MANIFEST_REFS: [&str; 2] = ["s0", "s2"];
const CHECKPOINT_TTL_TICKS: i64 = 3;

#[derive(Clone, Debug)]
struct JobMeta {
    origin: &'static str,
    retry: &'static str,
    submitted_ts: i64,
}

impl Default for JobMeta {
    fn default() -> Self {
        Self {
            origin: "NoOrigin",
            retry: "NoRetry",
            submitted_ts: 0,
        }
    }
}

#[derive(Clone, Debug)]
struct JobRecord {
    status: &'static str,
    worker: String,
    last_hb: i64,
    origin: &'static str,
    retry: &'static str,
    ctx: bool,
    output: bool,
    submitted_ts: i64,
}

impl Default for JobRecord {
    fn default() -> Self {
        Self {
            status: "Absent",
            worker: "Nil".to_string(),
            last_hb: 0,
            origin: "NoOrigin",
            retry: "NoRetry",
            ctx: false,
            output: false,
            submitted_ts: 0,
        }
    }
}

#[derive(Clone, Debug, Default)]
struct CheckpointBinding {
    actual_id: Option<Uuid>,
    refs: BTreeSet<String>,
    expire: i64,
}

#[derive(Clone, Debug)]
struct DurableCache {
    manifest_refs: BTreeSet<String>,
    checkpoints: BTreeMap<String, CheckpointBinding>,
    manifest_version: u64,
    manifest_epoch: u64,
    compactions_exists: bool,
    dur_jobs: BTreeMap<String, JobRecord>,
    compactions_version: u64,
    compactions_epoch: u64,
}

impl Default for DurableCache {
    fn default() -> Self {
        let mut dur_jobs = BTreeMap::new();
        for job in JOBS {
            dur_jobs.insert(job.to_string(), JobRecord::default());
        }
        let mut checkpoints = BTreeMap::new();
        for job in JOBS {
            checkpoints.insert(job.to_string(), CheckpointBinding::default());
        }
        Self {
            manifest_refs: INITIAL_MANIFEST_REFS
                .into_iter()
                .map(str::to_string)
                .collect(),
            checkpoints,
            manifest_version: 1,
            manifest_epoch: 0,
            compactions_exists: false,
            dur_jobs,
            compactions_version: 0,
            compactions_epoch: 0,
        }
    }
}

#[derive(Clone, Debug)]
struct CoordCache {
    manifest_refs: BTreeSet<String>,
    checkpoints: BTreeMap<String, CheckpointBinding>,
    jobs: BTreeMap<String, JobRecord>,
    seen_manifest_version: u64,
    seen_compactions_version: u64,
}

impl Default for CoordCache {
    fn default() -> Self {
        let mut jobs = BTreeMap::new();
        for job in JOBS {
            jobs.insert(job.to_string(), JobRecord::default());
        }
        let mut checkpoints = BTreeMap::new();
        for job in JOBS {
            checkpoints.insert(job.to_string(), CheckpointBinding::default());
        }
        Self {
            manifest_refs: INITIAL_MANIFEST_REFS
                .into_iter()
                .map(str::to_string)
                .collect(),
            checkpoints,
            jobs,
            seen_manifest_version: 0,
            seen_compactions_version: 0,
        }
    }
}

struct TraceRuntime {
    file: Option<File>,
    job_aliases: BTreeMap<Ulid, String>,
    sst_aliases: BTreeMap<String, String>,
    dur_meta: BTreeMap<String, JobMeta>,
    coord_meta: BTreeMap<String, JobMeta>,
    coord_up: bool,
    manifest_version: u64,
    manifest_epoch: u64,
    compactions_exists: bool,
    compactions_version: u64,
    compactions_epoch: u64,
    coord_seen_manifest_version: u64,
    coord_seen_compactions_version: u64,
    logical_time: i64,
    last_raw_time: i64,
    time_aliases: BTreeMap<i64, i64>,
    durable_cache: DurableCache,
    coord_cache: CoordCache,
    worker_time: BTreeMap<String, i64>,
    local_executing: BTreeMap<String, BTreeSet<String>>,
    buffered_ctx: BTreeMap<String, BTreeSet<String>>,
    present_ssts: BTreeSet<String>,
    deleted_ssts: BTreeSet<String>,
    output_ts: BTreeMap<String, i64>,
    publish_count: BTreeMap<String, i64>,
    retry_count: BTreeMap<String, i64>,
}

impl Default for TraceRuntime {
    fn default() -> Self {
        let durable_cache = DurableCache::default();
        let coord_cache = CoordCache::default();
        let worker_time = WORKERS
            .into_iter()
            .map(|worker| (worker.to_string(), 0))
            .collect();
        let local_executing = WORKERS
            .into_iter()
            .map(|worker| (worker.to_string(), BTreeSet::new()))
            .collect();
        let buffered_ctx = WORKERS
            .into_iter()
            .map(|worker| (worker.to_string(), BTreeSet::new()))
            .collect();
        let output_ts = OUTPUT_SSTS
            .into_iter()
            .map(|sst| (sst.to_string(), 0))
            .collect();
        let publish_count = JOBS
            .into_iter()
            .map(|job| (job.to_string(), 0))
            .collect();
        let retry_count = JOBS
            .into_iter()
            .map(|job| (job.to_string(), 0))
            .collect();
        Self {
            file: None,
            job_aliases: BTreeMap::new(),
            sst_aliases: BTreeMap::new(),
            dur_meta: default_job_meta_map(),
            coord_meta: default_job_meta_map(),
            coord_up: false,
            manifest_version: 1,
            manifest_epoch: 0,
            compactions_exists: false,
            compactions_version: 0,
            compactions_epoch: 0,
            coord_seen_manifest_version: 0,
            coord_seen_compactions_version: 0,
            logical_time: 0,
            last_raw_time: 0,
            time_aliases: BTreeMap::from([(0, 0)]),
            durable_cache,
            coord_cache,
            worker_time,
            local_executing,
            buffered_ctx,
            present_ssts: INITIAL_MANIFEST_REFS
                .into_iter()
                .map(str::to_string)
                .collect(),
            deleted_ssts: BTreeSet::new(),
            output_ts,
            publish_count,
            retry_count,
        }
    }
}

fn default_job_meta_map() -> BTreeMap<String, JobMeta> {
    JOBS.into_iter()
        .map(|job| (job.to_string(), JobMeta::default()))
        .collect()
}

static TRACE_RUNTIME: OnceLock<Mutex<TraceRuntime>> = OnceLock::new();

fn runtime() -> &'static Mutex<TraceRuntime> {
    TRACE_RUNTIME.get_or_init(|| Mutex::new(TraceRuntime::default()))
}

pub(crate) struct TraceScenarioGuard;

impl Drop for TraceScenarioGuard {
    fn drop(&mut self) {
        let mut runtime = runtime().lock();
        if let Some(mut file) = runtime.file.take() {
            let _ = file.flush();
        }
        *runtime = TraceRuntime::default();
    }
}

pub(crate) fn start_scenario(name: &str) -> TraceScenarioGuard {
    let trace_dir = std::env::var("SPECULA_TRACE_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("traces"));
    std::fs::create_dir_all(&trace_dir).expect("failed to create trace directory");
    let trace_path = trace_dir.join(format!("{name}.ndjson"));
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&trace_path)
        .expect("failed to open trace file");

    let mut runtime = runtime().lock();
    *runtime = TraceRuntime::default();
    runtime.file = Some(file);
    TraceScenarioGuard
}

pub(crate) fn register_job(actual: Ulid, model: &str) {
    runtime()
        .lock()
        .job_aliases
        .insert(actual, model.to_string());
}

pub(crate) fn register_sst(actual: &SsTableId, model: &str) {
    if let Some(key) = sst_key(actual) {
        runtime().lock().sst_aliases.insert(key, model.to_string());
    }
}

pub(crate) fn emit_coord_event(
    event_name: &str,
    now_ms: i64,
    job: Option<Ulid>,
    state: &CompactorState,
    durable_manifest: &VersionedManifest,
    durable_compactions: &VersionedCompactions,
) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }

    let now = runtime.advance_logical_time(now_ms);
    let model_job = job.and_then(|id| runtime.job_aliases.get(&id).cloned());
    runtime.apply_coord_event_updates(event_name, model_job.as_deref(), now, durable_manifest);
    runtime.apply_symbolic_transition(event_name);

    let durable_cache = runtime.build_durable_cache(durable_manifest, durable_compactions);
    if event_name == "CoordinatorRefreshCompactions" {
        runtime.adopt_coord_meta_from_durable(state, &durable_cache);
    }
    if event_name == "StartCoordinator" {
        runtime.coord_meta = runtime.dur_meta.clone();
    }
    let coord_cache = runtime.build_coord_cache(state);
    let line = runtime.build_trace_line(
        event_name,
        now,
        model_job.as_deref(),
        None,
        None,
        &durable_cache,
        &coord_cache,
    );
    runtime.coord_cache = coord_cache;
    runtime.durable_cache = durable_cache;
    runtime.write_line(line);
}

pub(crate) fn emit_worker_event(
    event_name: &str,
    now_ms: i64,
    worker: &str,
    job: Option<Ulid>,
    durable_manifest: &VersionedManifest,
    durable_compactions: &VersionedCompactions,
) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }

    let now = runtime.advance_logical_time(now_ms);
    let model_job = job.and_then(|id| runtime.job_aliases.get(&id).cloned());
    runtime.worker_time.insert(worker.to_string(), now);
    runtime.apply_worker_event_updates(event_name, worker, model_job.as_deref());
    runtime.apply_symbolic_transition(event_name);
    let durable_cache = runtime.build_durable_cache(durable_manifest, durable_compactions);
    let line = runtime.build_trace_line(
        event_name,
        now,
        model_job.as_deref(),
        Some(worker),
        None,
        &durable_cache,
        &runtime.coord_cache,
    );
    runtime.durable_cache = durable_cache;
    runtime.write_line(line);
}

pub(crate) fn emit_external_submit(
    now_ms: i64,
    job: Ulid,
    durable_manifest: &VersionedManifest,
    durable_compactions: &VersionedCompactions,
) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }
    let now = runtime.advance_logical_time(now_ms);
    let Some(model_job) = runtime.job_aliases.get(&job).cloned() else {
        return;
    };
    runtime.dur_meta.insert(
        model_job.clone(),
        JobMeta {
            origin: "RemoteOrigin",
            retry: "NoRetry",
            submitted_ts: now,
        },
    );
    runtime.apply_symbolic_transition("ExternalSubmit");
    let durable_cache = runtime.build_durable_cache(durable_manifest, durable_compactions);
    let line = runtime.build_trace_line(
        "ExternalSubmit",
        now,
        Some(model_job.as_str()),
        None,
        None,
        &durable_cache,
        &runtime.coord_cache,
    );
    runtime.durable_cache = durable_cache;
    runtime.write_line(line);
}

pub(crate) fn emit_crash_coordinator(now_ms: i64) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }
    let now = runtime.advance_logical_time(now_ms);
    runtime.apply_symbolic_transition("CrashCoordinator");
    let line = runtime.build_trace_line(
        "CrashCoordinator",
        now,
        None,
        None,
        None,
        &runtime.durable_cache,
        &runtime.coord_cache,
    );
    runtime.write_line(line);
}

pub(crate) fn emit_write_output_sst(
    now_ms: i64,
    worker: &str,
    job: Ulid,
    output: &SsTableId,
    durable_manifest: &VersionedManifest,
    durable_compactions: &VersionedCompactions,
) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }
    let now = runtime.advance_logical_time(now_ms);
    let Some(model_job) = runtime.job_aliases.get(&job).cloned() else {
        return;
    };
    let Some(model_sst) = sst_key(output).and_then(|key| runtime.sst_aliases.get(&key).cloned()) else {
        return;
    };
    runtime.worker_time.insert(worker.to_string(), now);
    runtime.present_ssts.insert(model_sst.clone());
    runtime.deleted_ssts.remove(&model_sst);
    runtime.output_ts.insert(model_sst, now);
    if let Some(jobs) = runtime.buffered_ctx.get_mut(worker) {
        jobs.insert(model_job.clone());
    }
    let durable_cache = runtime.build_durable_cache(durable_manifest, durable_compactions);
    let line = runtime.build_trace_line(
        "WriteOutputSst",
        now,
        Some(model_job.as_str()),
        Some(worker),
        None,
        &durable_cache,
        &runtime.coord_cache,
    );
    runtime.durable_cache = durable_cache;
    runtime.write_line(line);
}

pub(crate) fn emit_refresh_checkpoint(
    now_ms: i64,
    job: Ulid,
    durable_manifest: &VersionedManifest,
    durable_compactions: &VersionedCompactions,
) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }
    let now = runtime.advance_logical_time(now_ms);
    let Some(model_job) = runtime.job_aliases.get(&job).cloned() else {
        return;
    };
    if let Some(binding) = runtime.durable_cache.checkpoints.get(&model_job) {
        let mut updated = binding.clone();
        updated.expire = now + CHECKPOINT_TTL_TICKS;
        runtime.durable_cache.checkpoints.insert(model_job.clone(), updated);
    }
    runtime.apply_symbolic_transition("RefreshCheckpoint");
    let durable_cache = runtime.build_durable_cache(durable_manifest, durable_compactions);
    let line = runtime.build_trace_line(
        "RefreshCheckpoint",
        now,
        Some(model_job.as_str()),
        None,
        None,
        &durable_cache,
        &runtime.coord_cache,
    );
    runtime.durable_cache = durable_cache;
    runtime.write_line(line);
}

pub(crate) fn emit_gc_sweep(
    now_ms: i64,
    sst: &SsTableId,
    durable_manifest: &VersionedManifest,
    durable_compactions: &VersionedCompactions,
) {
    let mut runtime = runtime().lock();
    if runtime.file.is_none() {
        return;
    }
    let now = runtime.advance_logical_time(now_ms);
    let Some(model_sst) = sst_key(sst).and_then(|key| runtime.sst_aliases.get(&key).cloned()) else {
        return;
    };
    runtime.present_ssts.remove(&model_sst);
    runtime.deleted_ssts.insert(model_sst.clone());
    let durable_cache = runtime.build_durable_cache(durable_manifest, durable_compactions);
    let line = runtime.build_trace_line(
        "GcSweep",
        now,
        None,
        None,
        Some(model_sst.as_str()),
        &durable_cache,
        &runtime.coord_cache,
    );
    runtime.durable_cache = durable_cache;
    runtime.write_line(line);
}

impl TraceRuntime {
    fn advance_logical_time(&mut self, raw_now: i64) -> i64 {
        if let Some(mapped) = self.time_aliases.get(&raw_now).copied() {
            return mapped;
        }
        let delta = raw_now.saturating_sub(self.last_raw_time);
        let step = if delta <= 1 {
            delta
        } else if delta <= CHECKPOINT_TTL_TICKS {
            delta
        } else {
            CHECKPOINT_TTL_TICKS + 1
        };
        self.logical_time += step;
        self.last_raw_time = raw_now;
        self.time_aliases.insert(raw_now, self.logical_time);
        self.logical_time
    }

    fn translate_time(&self, raw_time: i64) -> i64 {
        self.time_aliases.get(&raw_time).copied().unwrap_or(raw_time)
    }

    fn apply_symbolic_transition(&mut self, event_name: &str) {
        match event_name {
            "StartCoordinator" => {
                self.coord_up = true;
                self.manifest_epoch += 1;
                self.compactions_exists = true;
                self.compactions_epoch = self.manifest_epoch;
                self.compactions_version += 1;
                self.coord_seen_manifest_version = self.manifest_version;
                self.coord_seen_compactions_version = self.compactions_version;
            }
            "CrashCoordinator" => {
                self.coord_up = false;
            }
            "CoordinatorRefreshCompactions" => {
                self.coord_seen_compactions_version = self.compactions_version;
            }
            "CoordinatorRefreshManifest" => {
                self.coord_seen_manifest_version = self.manifest_version;
            }
            "MaybeScheduleCompactions" => {
                self.compactions_exists = true;
                self.compactions_version += 1;
                self.coord_seen_compactions_version = self.compactions_version;
            }
            "ExternalSubmit" => {
                self.compactions_exists = true;
                self.compactions_version += 1;
            }
            "MaybeValidateSubmittedFail"
            | "MaybeValidateSubmittedSchedule"
            | "ReclaimStaleWorkers"
            | "CommitCompactedEntriesFail"
            | "CommitCompactedEntriesWriteCompactions" => {
                self.compactions_version += 1;
                self.coord_seen_compactions_version = self.compactions_version;
            }
            "MaybeValidateSubmittedDrain" => {
                self.manifest_version += 1;
                self.compactions_version += 1;
                self.coord_seen_manifest_version = self.manifest_version;
                self.coord_seen_compactions_version = self.compactions_version;
            }
            "PollAndClaim"
            | "ReleaseClaimPostClaimInvalid"
            | "HeartbeatOwnedJobs"
            | "HandleFinishedSuccess"
            | "HandleFinishedExecError" => {
                self.compactions_version += 1;
            }
            "CommitCompactedEntriesWriteManifest" => {
                self.manifest_version += 1;
                self.coord_seen_manifest_version = self.manifest_version;
            }
            "RefreshCheckpoint" => {
                self.manifest_version += 1;
            }
            _ => {}
        }
    }

    fn apply_coord_event_updates(
        &mut self,
        event_name: &str,
        model_job: Option<&str>,
        now: i64,
        durable_manifest: &VersionedManifest,
    ) {
        match event_name {
            "MaybeScheduleCompactions" => {
                if let Some(job) = model_job {
                    let meta = JobMeta {
                        origin: "LocalOrigin",
                        retry: "NoRetry",
                        submitted_ts: now,
                    };
                    self.dur_meta.insert(job.to_string(), meta.clone());
                    self.coord_meta.insert(job.to_string(), meta);
                }
            }
            "MaybeValidateSubmittedFail" | "MaybeValidateSubmittedSchedule" => {
                if let Some(job) = model_job {
                    if let Some(meta) = self.dur_meta.get_mut(job) {
                        meta.retry = "NoRetry";
                    }
                    if let Some(meta) = self.coord_meta.get_mut(job) {
                        meta.retry = "NoRetry";
                    }
                }
            }
            "ReclaimStaleWorkers" => {
                if let Some(job) = model_job {
                    if let Some(meta) = self.dur_meta.get_mut(job) {
                        meta.retry = "TimeoutRetry";
                    }
                    if let Some(meta) = self.coord_meta.get_mut(job) {
                        meta.retry = "TimeoutRetry";
                    }
                    if let Some(count) = self.retry_count.get_mut(job) {
                        *count += 1;
                    }
                }
            }
            "CommitCompactedEntriesWriteManifest" => {
                if let Some(job) = model_job {
                    if let Some(count) = self.publish_count.get_mut(job) {
                        *count += 1;
                    }
                    self.bind_checkpoint(job, durable_manifest, now);
                }
            }
            "StartCoordinator" => {
                for job in JOBS {
                    if let Some(record) = self.durable_cache.dur_jobs.get(job) {
                        if record.status == "Scheduled" {
                            if let Some(meta) = self.dur_meta.get_mut(job) {
                                meta.retry = "RestartRetry";
                            }
                            if let Some(meta) = self.coord_meta.get_mut(job) {
                                meta.retry = "RestartRetry";
                            }
                        }
                    }
                }
            }
            "MaybeValidateSubmittedDrain" => {
                if let Some(job) = model_job {
                    if let Some(count) = self.publish_count.get_mut(job) {
                        *count += 1;
                    }
                    self.bind_checkpoint(job, durable_manifest, now);
                }
            }
            _ => {}
        }
    }

    fn apply_worker_event_updates(&mut self, event_name: &str, worker: &str, model_job: Option<&str>) {
        match event_name {
            "PollAndClaimStopDuplicate" | "HeartbeatLoseOwnership" => {
                if let Some(job) = model_job {
                    if let Some(jobs) = self.local_executing.get_mut(worker) {
                        jobs.remove(job);
                    }
                    if let Some(jobs) = self.buffered_ctx.get_mut(worker) {
                        jobs.remove(job);
                    }
                }
            }
            "DispatchClaimedJob" => {
                if let Some(job) = model_job {
                    if let Some(jobs) = self.local_executing.get_mut(worker) {
                        jobs.insert(job.to_string());
                    }
                }
            }
            "ReleaseClaimPostClaimInvalid" => {
                if let Some(job) = model_job {
                    if let Some(meta) = self.dur_meta.get_mut(job) {
                        meta.retry = "PostClaimInvalid";
                    }
                    if let Some(count) = self.retry_count.get_mut(job) {
                        *count += 1;
                    }
                }
            }
            "HandleFinishedSuccess" | "HandleFinishedLostOwnership" => {
                if let Some(job) = model_job {
                    if let Some(jobs) = self.local_executing.get_mut(worker) {
                        jobs.remove(job);
                    }
                    if let Some(jobs) = self.buffered_ctx.get_mut(worker) {
                        jobs.remove(job);
                    }
                }
            }
            "HandleFinishedExecError" => {
                if let Some(job) = model_job {
                    if let Some(jobs) = self.local_executing.get_mut(worker) {
                        jobs.remove(job);
                    }
                    if let Some(jobs) = self.buffered_ctx.get_mut(worker) {
                        jobs.remove(job);
                    }
                    if let Some(meta) = self.dur_meta.get_mut(job) {
                        meta.retry = "ExecErrorRetry";
                    }
                    if let Some(count) = self.retry_count.get_mut(job) {
                        *count += 1;
                    }
                }
            }
            _ => {}
        }
    }

    fn bind_checkpoint(&mut self, model_job: &str, manifest: &VersionedManifest, now_ms: i64) {
        let active_ids: HashSet<Uuid> = manifest.checkpoints().iter().map(|cp| cp.id).collect();
        let used: HashSet<Uuid> = self
            .durable_cache
            .checkpoints
            .values()
            .filter_map(|binding| binding.actual_id)
            .collect();
        let actual_id = manifest
            .checkpoints()
            .iter()
            .find(|cp| active_ids.contains(&cp.id) && !used.contains(&cp.id))
            .map(|cp| cp.id)
            .or_else(|| self.durable_cache.checkpoints.get(model_job).and_then(|cp| cp.actual_id));
        let refs = self
            .coord_cache
            .manifest_refs
            .iter()
            .filter(|sst| job_sources(model_job).iter().any(|source| *source == sst.as_str()))
            .cloned()
            .collect::<BTreeSet<_>>();
        let binding = CheckpointBinding {
            actual_id,
            refs,
            expire: now_ms + CHECKPOINT_TTL_TICKS,
        };
        self.durable_cache
            .checkpoints
            .insert(model_job.to_string(), binding.clone());
        self.coord_cache
            .checkpoints
            .insert(model_job.to_string(), binding);
    }

    fn adopt_coord_meta_from_durable(
        &mut self,
        state: &CompactorState,
        durable_cache: &DurableCache,
    ) {
        let local = self.build_coord_cache(state);
        for job in JOBS {
            let prev = self.coord_cache.jobs.get(job);
            let next = local.jobs.get(job);
            let durable = durable_cache.dur_jobs.get(job);
            if let (Some(prev), Some(next), Some(durable)) = (prev, next, durable) {
                let changed = prev.status != next.status
                    || prev.worker != next.worker
                    || prev.ctx != next.ctx
                    || prev.output != next.output
                    || prev.last_hb != next.last_hb;
                let mirrors_durable = next.status == durable.status
                    && next.worker == durable.worker
                    && next.ctx == durable.ctx
                    && next.output == durable.output
                    && next.last_hb == durable.last_hb;
                if changed && mirrors_durable {
                    if let Some(meta) = self.dur_meta.get(job).cloned() {
                        self.coord_meta.insert(job.to_string(), meta);
                    }
                }
            }
        }
    }

    fn build_durable_cache(
        &self,
        manifest: &VersionedManifest,
        compactions: &VersionedCompactions,
    ) -> DurableCache {
        let mut cache = DurableCache {
            manifest_refs: self.map_manifest_refs(manifest.core()),
            checkpoints: self.map_checkpoints(manifest),
            manifest_version: self.manifest_version,
            manifest_epoch: self.manifest_epoch,
            compactions_exists: self.compactions_exists,
            dur_jobs: self.map_jobs(&compactions.compactions, &self.dur_meta, &self.durable_cache.dur_jobs),
            compactions_version: self.compactions_version,
            compactions_epoch: self.compactions_epoch,
        };
        for job in JOBS {
            cache
                .dur_jobs
                .entry(job.to_string())
                .or_insert_with(JobRecord::default);
        }
        cache
    }

    fn build_coord_cache(&self, state: &CompactorState) -> CoordCache {
        let manifest = &state.manifest().value;
        let compactions = &state.compactions().value;
        let mut cache = CoordCache {
            manifest_refs: self.map_manifest_refs(&manifest.core),
            checkpoints: self.map_checkpoints_from_core(&manifest.core),
            jobs: self.map_jobs(compactions, &self.coord_meta, &self.coord_cache.jobs),
            seen_manifest_version: self.coord_seen_manifest_version,
            seen_compactions_version: self.coord_seen_compactions_version,
        };
        for job in JOBS {
            cache.jobs.entry(job.to_string()).or_insert_with(JobRecord::default);
        }
        cache
    }

    fn map_manifest_refs(&self, core: &ManifestCore) -> BTreeSet<String> {
        let mut refs = BTreeSet::new();
        for tree in core.trees() {
            for view in tree.l0.iter() {
                if let Some(mapped) = sst_key(&view.sst.id).and_then(|key| self.sst_aliases.get(&key).cloned()) {
                    refs.insert(mapped);
                }
            }
            for run in tree.compacted.iter() {
                for view in run.sst_views.iter() {
                    if let Some(mapped) = sst_key(&view.sst.id).and_then(|key| self.sst_aliases.get(&key).cloned()) {
                        refs.insert(mapped);
                    }
                }
            }
        }
        refs
    }

    fn map_checkpoints(&self, manifest: &VersionedManifest) -> BTreeMap<String, CheckpointBinding> {
        self.map_checkpoints_from_core(manifest.core())
    }

    fn map_checkpoints_from_core(&self, core: &ManifestCore) -> BTreeMap<String, CheckpointBinding> {
        let active_ids: HashSet<Uuid> = core.checkpoints.iter().map(|cp| cp.id).collect();
        let mut checkpoints = BTreeMap::new();
        for job in JOBS {
            let mut binding = self
                .durable_cache
                .checkpoints
                .get(job)
                .cloned()
                .or_else(|| self.coord_cache.checkpoints.get(job).cloned())
                .unwrap_or_default();
            if let Some(actual_id) = binding.actual_id {
                if !active_ids.contains(&actual_id) {
                    binding.actual_id = None;
                    binding.refs.clear();
                    binding.expire = 0;
                }
            }
            checkpoints.insert(job.to_string(), binding);
        }
        checkpoints
    }

    fn map_jobs(
        &self,
        compactions: &Compactions,
        meta_map: &BTreeMap<String, JobMeta>,
        previous: &BTreeMap<String, JobRecord>,
    ) -> BTreeMap<String, JobRecord> {
        let mut jobs = JOBS
            .into_iter()
            .map(|job| {
                let meta = meta_map.get(job).cloned().unwrap_or_default();
                let prev = previous.get(job).cloned().unwrap_or_default();
                (
                    job.to_string(),
                    JobRecord {
                        status: prev.status,
                        worker: prev.worker,
                        last_hb: prev.last_hb,
                        origin: meta.origin,
                        retry: meta.retry,
                        ctx: prev.ctx,
                        output: prev.output,
                        submitted_ts: meta.submitted_ts,
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();
        for compaction in compactions.iter() {
            let Some(model_job) = self.job_aliases.get(&compaction.id()).cloned() else {
                continue;
            };
            let meta = meta_map.get(&model_job).cloned().unwrap_or_default();
            jobs.insert(
                model_job,
                JobRecord {
                    status: status_name(compaction.status()),
                    worker: compaction
                        .worker()
                        .map(|worker| worker.worker_id.clone())
                        .unwrap_or_else(|| "Nil".to_string()),
                    last_hb: compaction
                        .worker()
                        .map(|worker| {
                            let raw = i64::try_from(worker.last_heartbeat_ms).unwrap_or(i64::MAX);
                            self.translate_time(raw)
                        })
                        .unwrap_or(0),
                    origin: meta.origin,
                    retry: meta.retry,
                    ctx: compaction.ctx().is_some(),
                    output: !compaction.output_ssts().is_empty(),
                    submitted_ts: meta.submitted_ts,
                },
            );
        }
        jobs
    }

    fn build_trace_line(
        &self,
        event_name: &str,
        now_ms: i64,
        model_job: Option<&str>,
        worker: Option<&str>,
        sst: Option<&str>,
        durable: &DurableCache,
        coord: &CoordCache,
    ) -> Value {
        let mut event = Map::new();
        event.insert("name".to_string(), Value::String(event_name.to_string()));
        if let Some(job) = model_job {
            event.insert("job".to_string(), Value::String(job.to_string()));
        }
        if let Some(worker) = worker {
            event.insert("worker".to_string(), Value::String(worker.to_string()));
        }
        if let Some(sst) = sst {
            event.insert("sst".to_string(), Value::String(sst.to_string()));
        }
        event.insert(
            "state".to_string(),
            json!({
                "coord_up": self.coord_up,
                "coord_time": now_ms,
                "worker_time": WORKERS.iter().map(|worker| json!({
                    "worker": worker,
                    "time": self.worker_time.get(*worker).copied().unwrap_or(0),
                })).collect::<Vec<_>>(),
                "manifest_refs": durable.manifest_refs.iter().cloned().collect::<Vec<_>>(),
                "checkpoints": JOBS.iter().map(|job| checkpoint_json(job, durable.checkpoints.get(*job))).collect::<Vec<_>>(),
                "manifest_version": durable.manifest_version,
                "manifest_epoch": durable.manifest_epoch,
                "compactions_exists": durable.compactions_exists,
                "dur_jobs": JOBS.iter().map(|job| job_json(job, durable.dur_jobs.get(*job))).collect::<Vec<_>>(),
                "compactions_version": durable.compactions_version,
                "compactions_epoch": durable.compactions_epoch,
                "coord_manifest_refs": coord.manifest_refs.iter().cloned().collect::<Vec<_>>(),
                "coord_checkpoints": JOBS.iter().map(|job| checkpoint_json(job, coord.checkpoints.get(*job))).collect::<Vec<_>>(),
                "coord_jobs": JOBS.iter().map(|job| job_json(job, coord.jobs.get(*job))).collect::<Vec<_>>(),
                "coord_seen_manifest_version": coord.seen_manifest_version,
                "coord_seen_compactions_version": coord.seen_compactions_version,
                "local_executing": WORKERS.iter().map(|worker| json!({
                    "worker": worker,
                    "jobs": self.local_executing.get(*worker).cloned().unwrap_or_default().into_iter().collect::<Vec<_>>(),
                })).collect::<Vec<_>>(),
                "buffered_ctx": WORKERS.iter().map(|worker| json!({
                    "worker": worker,
                    "jobs": self.buffered_ctx.get(*worker).cloned().unwrap_or_default().into_iter().collect::<Vec<_>>(),
                })).collect::<Vec<_>>(),
                "present_ssts": self.present_ssts.iter().cloned().collect::<Vec<_>>(),
                "deleted_ssts": self.deleted_ssts.iter().cloned().collect::<Vec<_>>(),
                "output_ts": OUTPUT_SSTS.iter().map(|sst| json!({
                    "sst": sst,
                    "ts": self.output_ts.get(*sst).copied().unwrap_or(0),
                })).collect::<Vec<_>>(),
                "publish_count": JOBS.iter().map(|job| json!({
                    "job": job,
                    "count": self.publish_count.get(*job).copied().unwrap_or(0),
                })).collect::<Vec<_>>(),
                "retry_count": JOBS.iter().map(|job| json!({
                    "job": job,
                    "count": self.retry_count.get(*job).copied().unwrap_or(0),
                })).collect::<Vec<_>>(),
            }),
        );
        json!({
            "tag": "trace",
            "ts": real_ts_nanos().to_string(),
            "event": Value::Object(event),
        })
    }

    fn write_line(&mut self, line: Value) {
        let Some(file) = self.file.as_mut() else {
            return;
        };
        serde_json::to_writer(&mut *file, &line).expect("failed to write trace line");
        file.write_all(b"\n").expect("failed to write newline");
        file.flush().expect("failed to flush trace line");
    }
}

fn checkpoint_json(job: &str, binding: Option<&CheckpointBinding>) -> Value {
    let binding = binding.cloned().unwrap_or_default();
    json!({
        "job": job,
        "active": binding.actual_id.is_some(),
        "refs": binding.refs.into_iter().collect::<Vec<_>>(),
        "expire": if binding.actual_id.is_some() { binding.expire } else { 0 },
    })
}

fn job_json(job: &str, record: Option<&JobRecord>) -> Value {
    let record = record.cloned().unwrap_or_default();
    json!({
        "job": job,
        "status": record.status,
        "worker": record.worker,
        "last_hb": record.last_hb,
        "origin": record.origin,
        "retry": record.retry,
        "ctx": record.ctx,
        "output": record.output,
        "submitted_ts": record.submitted_ts,
    })
}

fn job_sources(job: &str) -> &'static [&'static str] {
    match job {
        "j1" | "j2" => &["s0"],
        "j3" => &["s2"],
        _ => &[],
    }
}

fn status_name(status: CompactionStatus) -> &'static str {
    match status {
        CompactionStatus::Submitted => "Submitted",
        CompactionStatus::Scheduled => "Scheduled",
        CompactionStatus::Running => "Running",
        CompactionStatus::Compacted => "Compacted",
        CompactionStatus::Completed => "Completed",
        CompactionStatus::Failed => "Failed",
    }
}

fn sst_key(sst: &SsTableId) -> Option<String> {
    match sst {
        SsTableId::Compacted(id) => Some(id.to_string()),
        _ => None,
    }
}

fn real_ts_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before unix epoch")
        .as_nanos()
}
