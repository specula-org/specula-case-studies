//! Observation only: snapshots of real fields, native-message encoding, and NDJSON I/O.
use super::*;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[path = "owner.rs"]
mod owner;
use owner::Owner;
#[path = "scenarios.rs"]
mod scenarios;

pub const REVISION: &str = "3ac0104a567092139534c9022205d02281a2da41";
static SCENARIO: Mutex<()> = Mutex::new(());
static WRITER: Mutex<Option<TraceWriter>> = Mutex::new(None);
thread_local! { static CALLS: RefCell<Vec<(String, usize)>> = const { RefCell::new(Vec::new()) }; }
thread_local! { static NATIVE_CALL_COUNT: RefCell<usize> = const { RefCell::new(0) }; }

// These markers run at real library entry points, including early-return branches.
pub fn observe_call(event: &str, id: usize) {
    CALLS.with(|calls| calls.borrow_mut().push((event.to_owned(), id)));
    NATIVE_CALL_COUNT.with(|count| *count.borrow_mut() += 1);
}
fn check_call(event: &str, id: usize) {
    CALLS.with(|calls| {
        assert_eq!(
            std::mem::take(&mut *calls.borrow_mut()),
            vec![(event.to_owned(), id)]
        )
    });
}
pub fn message_kind<Op>(message: &Message<Op>) -> &'static str {
    match message {
        Message::Request { .. } => "Request",
        Message::Prepare { .. } => "Prepare",
        Message::PrepareOk { .. } => "PrepareOk",
        Message::Commit { .. } => "Commit",
        Message::GetState { .. } => "GetState",
        Message::NewState { .. } => "NewState",
        Message::StartViewChange { .. } => "StartViewChange",
        Message::DoViewChange { .. } => "DoViewChange",
        Message::StartView { .. } => "StartView",
        Message::Recovery { .. } => "Recovery",
        Message::RecoveryResponse { .. } => "RecoveryResponse",
    }
}

struct TraceWriter {
    file: BufWriter<File>,
    path: PathBuf,
    name: String,
    count: usize,
    native_events: usize,
    started: Instant,
}
fn initialize(name: &str) -> MutexGuard<'static, ()> {
    let guard = SCENARIO.lock().expect("previous scenario panicked");
    CALLS.with(|calls| calls.borrow_mut().clear());
    NATIVE_CALL_COUNT.with(|count| *count.borrow_mut() = 0);
    let dir = PathBuf::from(std::env::var("TRACE_DIR").expect("set TRACE_DIR via harness/run.sh"));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!("{name}.ndjson"));
    let completion = path.with_extension("complete.json");
    if completion.exists() {
        fs::remove_file(completion).unwrap();
    }
    *WRITER.lock().unwrap() = Some(TraceWriter {
        file: BufWriter::new(File::create(&path).unwrap()),
        path,
        name: name.to_owned(),
        count: 0,
        native_events: 0,
        started: Instant::now(),
    });
    guard
}
fn emit(mut event: Value) {
    let mut writer = WRITER.lock().unwrap();
    let writer = writer.as_mut().expect("initialize first");
    let name = event["event"].as_str().unwrap();
    if name.starts_with("On") || name.starts_with("ClientOn") {
        writer.native_events += 1;
    }
    event["tag"] = json!("trace");
    // Strings avoid the JSON module's bounded-integer decoder for wall time.
    event["ts"] = json!(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos()
        .to_string());
    event["monotonic_ns"] = json!(writer.started.elapsed().as_nanos().to_string());
    serde_json::to_writer(&mut writer.file, &event).unwrap();
    writer.file.write_all(b"\n").unwrap();
    writer.file.flush().unwrap();
    writer.count += 1;
}
fn shutdown(callback_count: usize) {
    CALLS.with(|calls| assert!(calls.borrow().is_empty(), "unobserved library callback"));
    let mut writer = WRITER.lock().unwrap().take().unwrap();
    writer.file.flush().unwrap();
    writer.file.get_ref().sync_all().unwrap();
    let native_callback_count = NATIVE_CALL_COUNT.with(|count| *count.borrow());
    assert_eq!(
        native_callback_count, writer.native_events,
        "one event per native callback"
    );
    assert_eq!(
        writer.count,
        callback_count + 1,
        "Init plus one event per owner step"
    );
    let record = json!({"scenario":writer.name,"event_count":writer.count,
        "owner_step_count":callback_count,"native_callback_count":native_callback_count,
        "completed":true,"revision":REVISION});
    fs::write(
        writer.path.with_extension("complete.json"),
        serde_json::to_vec_pretty(&record).unwrap(),
    )
    .unwrap();
}

#[derive(Debug, Default)]
struct Accumulator {
    value: i64,
}
impl StateMachine for Accumulator {
    type Input = i64;
    type Output = i64;
    fn apply(&mut self, input: i64) -> i64 {
        self.value += input;
        self.value
    }
}
fn client_name(id: usize) -> String {
    format!("c{id}")
}
fn request_json(client: usize, number: usize, op: i64) -> Value {
    json!({"client":client_name(client),"number":number,"op":op})
}
fn log_json(entries: &[LogEntry<i64>]) -> Vec<Value> {
    entries
        .iter()
        .map(|e| request_json(e.client_id, e.request_number, e.op))
        .collect()
}
type Nonces = Vec<BTreeMap<u64, usize>>;
fn nonce_json(nonces: &Nonces, node: usize, raw: u64) -> usize {
    *nonces[node]
        .get(&raw)
        .expect("nonce must originate from an observed recovery")
}
fn empty_state() -> Value {
    // Explicit absence encoding for a destroyed replica, not reconstructed live state.
    json!({"status":"Normal","view":0,"lastNormal":0,"commit":0,"log":[],
        "acks":[],"table":[],"heard":true,"waiting":0,"attempts":0,"stable":0,
        "svc":[],"dvcSent":false,"dvc":[],"catching":false,"nonce":0,
        "responses":[],"app":0,"applied":[],"out":[]})
}
fn replica_snapshot(r: &Replica<Accumulator>, nonces: &Nonces) -> Value {
    assert!(
        r.outbox.is_empty() && r.replies.is_empty(),
        "capture after draining both outputs"
    );
    let acks: Vec<_> = r
        .acks
        .iter()
        .map(|(k, v)| json!({"key":k,"value":v}))
        .collect();
    let table: Vec<_> = r.client_table.iter().map(|(k,v)| json!({"key":client_name(*k),
        "value":{"number":v.request_number,"hasReply":v.reply.is_some(),"result":v.reply.unwrap_or(0)}})).collect();
    let dvc: Vec<_> = r
        .do_view_change_from
        .iter()
        .map(|(k, v)| {
            json!({"key":k,
        "value":{"lastNormal":v.last_normal_view,"log":log_json(&v.log),"commit":v.commit_number}})
        })
        .collect();
    let responses: Vec<_> = r
        .recovery_responses
        .iter()
        .map(|(k, v)| {
            json!({"key":k,
        "value":{"view":v.view_number,"hasState":v.state.is_some(),
            "log":v.state.as_ref().map(|s| log_json(&s.log)).unwrap_or_default(),
            "commit":v.state.as_ref().map(|s|s.commit_number).unwrap_or(0)}})
        })
        .collect();
    json!({"status":format!("{:?}",r.status),"view":r.view_number,"lastNormal":r.last_normal_view,
        "commit":r.commit_number,"log":log_json(&r.log),"acks":acks,"table":table,
        "heard":r.heard_from_primary,"waiting":r.idle_periods_waiting,"attempts":r.view_change_attempts,
        "stable":r.idle_periods_stable,"svc":r.start_view_change_from,"dvcSent":r.do_view_change_sent,
        "dvc":dvc,"catching":r.catching_up,"nonce":nonce_json(nonces,r.self_id,r.recovery_nonce),
        "responses":responses,"app":r.state_machine().value,"applied":log_json(&r.trace_applied),"out":[]})
}
fn client_snapshot(c: &Client<i64>) -> Value {
    assert!(c.outbox.is_empty());
    let pending: Vec<_> = c
        .pending
        .iter()
        .map(|(number, op)| request_json(c.client_id, *number, *op))
        .collect();
    json!({"view":c.view_number,"next":c.next_request_number,"pending":pending})
}

fn envelope(kind: &str, src: Value, dst: Value) -> Value {
    json!({"kind":kind,"src":src,"dst":dst,"view":0,"opnum":0,"commit":0,"start":0,
        "lastNormal":0,"nonce":0,"hasState":false,"log":[],
        "request":{"client":"","number":0,"op":0},"result":0})
}
fn canonical(message: &Message<i64>, src: Value, dst: usize, nonces: &Nonces) -> Value {
    let mut m = envelope(message_kind(message), src.clone(), json!(dst));
    match message {
        Message::Request {
            client_id,
            request_number,
            op,
        } => {
            assert_eq!(src, json!(client_name(*client_id)));
            m["request"] = request_json(*client_id, *request_number, *op);
        }
        Message::Prepare {
            view_number,
            op_number,
            client_id,
            request_number,
            op,
            commit_number,
        } => {
            m["view"] = json!(view_number);
            m["opnum"] = json!(op_number);
            m["commit"] = json!(commit_number);
            m["request"] = request_json(*client_id, *request_number, *op);
        }
        Message::PrepareOk {
            view_number,
            op_number,
            replica_id,
        }
        | Message::GetState {
            view_number,
            op_number,
            replica_id,
        } => {
            assert_eq!(src, json!(replica_id));
            m["view"] = json!(view_number);
            m["opnum"] = json!(op_number);
        }
        Message::Commit {
            view_number,
            commit_number,
        } => {
            m["view"] = json!(view_number);
            m["commit"] = json!(commit_number);
        }
        Message::NewState {
            view_number,
            log,
            op_number_start,
            op_number_end,
            commit_number,
        } => {
            m["view"] = json!(view_number);
            m["log"] = json!(log_json(log));
            m["start"] = json!(op_number_start);
            m["opnum"] = json!(op_number_end);
            m["commit"] = json!(commit_number);
        }
        Message::StartViewChange {
            view_number,
            replica_id,
        } => {
            assert_eq!(src, json!(replica_id));
            m["view"] = json!(view_number);
        }
        Message::DoViewChange {
            view_number,
            replica_id,
            last_normal_view,
            log,
            op_number,
            commit_number,
        } => {
            assert_eq!(src, json!(replica_id));
            m["view"] = json!(view_number);
            m["lastNormal"] = json!(last_normal_view);
            m["log"] = json!(log_json(log));
            m["opnum"] = json!(op_number);
            m["commit"] = json!(commit_number);
        }
        Message::StartView {
            view_number,
            log,
            op_number,
            commit_number,
        } => {
            m["view"] = json!(view_number);
            m["log"] = json!(log_json(log));
            m["opnum"] = json!(op_number);
            m["commit"] = json!(commit_number);
        }
        Message::Recovery {
            replica_id,
            nonce,
            view_number,
        } => {
            assert_eq!(src, json!(replica_id));
            m["view"] = json!(view_number);
            m["nonce"] = json!(nonce_json(nonces, *replica_id, *nonce));
        }
        Message::RecoveryResponse {
            view_number,
            nonce,
            replica_id,
            state,
        } => {
            assert_eq!(src, json!(replica_id));
            m["view"] = json!(view_number);
            m["nonce"] = json!(nonce_json(nonces, dst, *nonce));
            m["hasState"] = json!(state.is_some());
            if let Some(s) = state {
                m["log"] = json!(log_json(&s.log));
                m["commit"] = json!(s.commit_number);
            }
        }
    }
    m
}
