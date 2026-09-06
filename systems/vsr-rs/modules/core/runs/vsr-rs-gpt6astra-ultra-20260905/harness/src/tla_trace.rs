//! Feature-gated observations of the real VSR implementation.
//!
//! This module reads private implementation fields. It does not execute any
//! protocol transition. The caller owns publication, transport and persistence
//! snapshots; `commit_op` and `send_prepare_ok` capture transient observations.

use crate::{Client, LogEntry, Message, Replica, Reply, StateMachine, Status};
use serde::{Serialize, Serializer};
use serde_json::{json, Value};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Input {
    Put(usize),
    Get,
}

impl Serialize for Input {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        input(self).serialize(serializer)
    }
}

/// An order-sensitive application: Put and Get both return the old value.
#[derive(Debug, Default)]
pub struct Register {
    pub value: usize,
}

impl StateMachine for Register {
    type Input = Input;
    type Output = usize;

    fn apply(&mut self, operation: Input) -> usize {
        let old = self.value;
        if let Input::Put(value) = operation {
            self.value = value;
        }
        old
    }

    fn trace_state(&self) -> Value {
        json!(self.value)
    }
}

#[derive(Debug)]
pub(crate) struct ApplyObservation<Op, Output> {
    pub(crate) slot: usize,
    pub(crate) entry: LogEntry<Op>,
    pub(crate) state_before: Value,
    pub(crate) result: Output,
    pub(crate) state_after: Value,
}

pub fn input(operation: &Input) -> Value {
    match operation {
        Input::Put(value) => json!({"kind": "Put", "value": value}),
        Input::Get => json!({"kind": "Get", "value": 0}),
    }
}

pub fn entry(item: &LogEntry<Input>) -> Value {
    json!({"client": item.client_id, "request": item.request_number,
        "input": input(&item.op)})
}

pub fn entries(log: &[LogEntry<Input>]) -> Vec<Value> {
    log.iter().map(entry).collect()
}

pub fn kind(message: &Message<Input>) -> &'static str {
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

fn default_wire(kind: &str) -> Value {
    json!({"kind":kind, "view":0, "opn":0, "commit":0,
        "entry":[], "log":[], "start":0, "last":0, "nonce":0,
        "hasState":false, "client":[], "request":0, "result":0})
}

/// The owner resolves nonces against the recovering destination's nonce map.
/// `normalized_nonce` is ignored for variants without a nonce on the wire.
pub fn wire(message: &Message<Input>, normalized_nonce: usize) -> Value {
    let mut w = default_wire(kind(message));
    match message {
        Message::Request {
            client_id,
            request_number,
            op,
        } => {
            w["entry"] = json!([entry(&LogEntry {
                client_id: *client_id,
                request_number: *request_number,
                op: op.clone()
            })]);
        }
        Message::Prepare {
            view_number,
            op_number,
            client_id,
            request_number,
            op,
            commit_number,
        } => {
            w["view"] = json!(view_number);
            w["opn"] = json!(op_number);
            w["commit"] = json!(commit_number);
            w["entry"] = json!([entry(&LogEntry {
                client_id: *client_id,
                request_number: *request_number,
                op: op.clone()
            })]);
        }
        Message::PrepareOk {
            view_number,
            op_number,
            ..
        }
        | Message::GetState {
            view_number,
            op_number,
            ..
        } => {
            w["view"] = json!(view_number);
            w["opn"] = json!(op_number);
        }
        Message::Commit {
            view_number,
            commit_number,
        } => {
            w["view"] = json!(view_number);
            w["commit"] = json!(commit_number);
        }
        Message::NewState {
            view_number,
            log,
            op_number_start,
            op_number_end,
            commit_number,
        } => {
            w["view"] = json!(view_number);
            w["log"] = json!(entries(log));
            w["start"] = json!(op_number_start);
            w["opn"] = json!(op_number_end);
            w["commit"] = json!(commit_number);
        }
        Message::StartViewChange { view_number, .. } => {
            w["view"] = json!(view_number);
        }
        Message::DoViewChange {
            view_number,
            last_normal_view,
            log,
            op_number,
            commit_number,
            ..
        } => {
            w["view"] = json!(view_number);
            w["last"] = json!(last_normal_view);
            w["log"] = json!(entries(log));
            w["opn"] = json!(op_number);
            w["commit"] = json!(commit_number);
        }
        Message::StartView {
            view_number,
            log,
            op_number,
            commit_number,
        } => {
            w["view"] = json!(view_number);
            w["log"] = json!(entries(log));
            w["opn"] = json!(op_number);
            w["commit"] = json!(commit_number);
        }
        Message::Recovery { view_number, .. } => {
            w["view"] = json!(view_number);
            w["nonce"] = json!(normalized_nonce);
        }
        Message::RecoveryResponse {
            view_number, state, ..
        } => {
            w["view"] = json!(view_number);
            w["nonce"] = json!(normalized_nonce);
            w["hasState"] = json!(state.is_some());
            if let Some(state) = state {
                w["log"] = json!(entries(&state.log));
                w["commit"] = json!(state.commit_number);
            }
        }
    }
    w
}

pub fn reply_wire(reply: &Reply<usize>) -> Value {
    let mut w = default_wire("Reply");
    w["view"] = json!(reply.view_number);
    w["client"] = json!([reply.client_id]);
    w["request"] = json!(reply.request_number);
    w["result"] = json!(reply.result);
    w
}

impl Replica<Register> {
    /// Drain to volatile owner staging, preserving emission-time ack evidence.
    /// No publication transition occurs until the owner releases one packet.
    pub fn trace_drain_messages(&mut self) -> Vec<(usize, Message<Input>, Vec<LogEntry<Input>>)> {
        let mut proofs = std::mem::take(&mut self.trace_prepare_ok_proofs);
        self.outbox
            .drain(..)
            .enumerate()
            .map(|(index, (destination, message))| {
                let proof = proofs.remove(&index).unwrap_or_default();
                if let Message::PrepareOk { op_number, .. } = &message {
                    assert_eq!(proof.len(), *op_number, "missing creation-time ack prefix");
                } else {
                    assert!(proof.is_empty());
                }
                (destination, message, proof)
            })
            .collect()
    }

    /// Ordered observations since the previous completed handler.
    pub fn trace_take_applies(&mut self) -> Vec<Value> {
        let result = self.trace_apply_history[self.trace_apply_cursor..]
            .iter()
            .map(|a| {
                json!({"slot":a.slot,"entry":entry(&a.entry),
                "stateBefore":a.state_before,"result":a.result,
                "stateAfter":a.state_after})
            })
            .collect();
        self.trace_apply_cursor = self.trace_apply_history.len();
        result
    }

    pub fn trace_raw_nonce(&self) -> u64 {
        self.recovery_nonce
    }

    /// Full private-state projection; `out`/`replies` include owner staging.
    pub fn trace_snapshot(
        &self,
        out: &[Value],
        replies: &[Value],
        normalized_nonce: usize,
    ) -> Value {
        assert!(
            self.outbox.is_empty(),
            "stage library outputs before snapshot"
        );
        assert!(
            self.replies.is_empty(),
            "stage library replies before snapshot"
        );
        let acks: Vec<_> = self
            .acks
            .iter()
            .map(|(slot, replicas)| json!({"slot":slot,"replicas":replicas}))
            .collect();
        let table: Vec<_> = self
            .client_table
            .iter()
            .map(|(client, item)| {
                json!({"client":client,"request":item.request_number,
                "hasReply":item.reply.is_some(),"reply":item.reply.unwrap_or(0)})
            })
            .collect();
        let dvc: Vec<_> = self
            .do_view_change_from
            .iter()
            .map(|(replica, item)| {
                json!({"replica":replica,"last":item.last_normal_view,
                "log":entries(&item.log),"commit":item.commit_number})
            })
            .collect();
        let responses: Vec<_> = self
            .recovery_responses
            .iter()
            .map(|(replica, item)| {
                let (log, commit) = match &item.state {
                    Some(state) => (entries(&state.log), state.commit_number),
                    None => (Vec::new(), 0),
                };
                json!({"replica":replica,"view":item.view_number,
                "hasState":item.state.is_some(),"log":log,"commit":commit})
            })
            .collect();
        let applied: Vec<_> = self
            .trace_apply_history
            .iter()
            .map(|a| entry(&a.entry))
            .collect();
        let results: Vec<_> = self.trace_apply_history.iter().map(|a| a.result).collect();
        json!({"id":self.self_id,"status":format!("{:?}",self.status),
            "view":self.view_number,"lastNormal":self.last_normal_view,
            "commit":self.commit_number,"log":entries(&self.log),"acks":acks,
            "table":table,"heard":self.heard_from_primary,
            "waiting":self.idle_periods_waiting,"attempts":self.view_change_attempts,
            "stable":self.idle_periods_stable,"svc":self.start_view_change_from,
            "dvcSent":self.do_view_change_sent,"dvc":dvc,"catching":self.catching_up,
            "nonce":normalized_nonce,"responses":responses,"out":out,"replies":replies,
            "app":self.state_machine.value,"applied":applied,"results":results})
    }

    /// Classification only: inspect PRE-state, then invoke real `on_message`.
    pub fn trace_message_branch(&self, message: &Message<Input>) -> &'static str {
        if self.status == Status::Recovering && !matches!(message, Message::RecoveryResponse { .. })
        {
            return "ignore-recovering";
        }
        match message {
            Message::Request {
                client_id,
                request_number,
                ..
            } => {
                if !self.is_primary() || self.status != Status::Normal {
                    "ignore-role-status"
                } else if let Some(item) = self.client_table.get(client_id) {
                    if *request_number < item.request_number {
                        "old-request"
                    } else if *request_number == item.request_number {
                        "duplicate-request"
                    } else {
                        "append-request"
                    }
                } else {
                    "append-request"
                }
            }
            Message::Prepare {
                view_number,
                op_number,
                ..
            } => self.trace_primary_message_branch(
                *view_number,
                *op_number > self.log.len() + 1,
                *op_number == self.log.len() + 1,
            ),
            Message::Commit {
                view_number,
                commit_number,
            } => self.trace_primary_message_branch(
                *view_number,
                *commit_number > self.log.len(),
                false,
            ),
            Message::NewState { view_number, .. } => {
                if *view_number != self.view_number {
                    "different-view"
                } else if self.status == Status::StateTransfer {
                    "same-view-transfer"
                } else if self.status == Status::ViewChange && self.catching_up {
                    "view-catch-up"
                } else {
                    "ignore-status"
                }
            }
            _ => kind(message),
        }
    }

    fn trace_primary_message_branch(&self, view: usize, gap: bool, append: bool) -> &'static str {
        if view < self.view_number {
            "old-view"
        } else if view > self.view_number {
            "catch-up-new-view"
        } else if self.status == Status::ViewChange {
            "catch-up-same-view"
        } else if self.status != Status::Normal || self.is_primary() {
            "ignore-role-status"
        } else if gap {
            "state-transfer"
        } else if append {
            "append-prepare"
        } else {
            "normal"
        }
    }

    pub fn trace_idle_branch(&self) -> &'static str {
        match self.status {
            Status::Normal if self.is_primary() => "primary",
            Status::Recovering => "recovering",
            Status::ViewChange => "view-change",
            _ => "backup-or-transfer",
        }
    }
}

impl Client<Input> {
    pub fn trace_snapshot(&self, out: &[Value]) -> Value {
        assert!(
            self.outbox.is_empty(),
            "stage library outputs before snapshot"
        );
        let pending: Vec<_> = self
            .pending
            .iter()
            .map(|(request, op)| {
                entry(&LogEntry {
                    client_id: self.client_id,
                    request_number: *request,
                    op: op.clone(),
                })
            })
            .collect();
        json!({"view":self.view_number,"next":self.next_request_number,
            "pending":pending,"out":out})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Config;

    #[test]
    fn creation_time_ack_prefixes_and_actual_ordered_apply_results() {
        let mut config = Config::new();
        for _ in 0..3 {
            config.add_replica();
        }
        let mut primary = Replica::new(0, config.clone(), Register::default());
        let mut backup = Replica::new(1, config, Register::default());
        for (client_id, value) in [(3, 1), (4, 2)] {
            primary.on_message(Message::Request {
                client_id,
                request_number: 0,
                op: Input::Put(value),
            });
        }
        for (destination, message, _) in primary.trace_drain_messages() {
            if destination == 1 {
                backup.on_message(message);
            }
        }
        // Both acks remain unpublished while the backup's log grows. The
        // first proof must preserve its shorter creation-time prefix.
        let acknowledgements = backup.trace_drain_messages();
        assert_eq!(acknowledgements[0].2.len(), 1);
        assert_eq!(acknowledgements[1].2.len(), 2);
        // Cumulative ack 2 applies both entries in one real handler.
        primary.on_message(acknowledgements[1].1.clone());
        let applies = primary.trace_take_applies();
        assert_eq!(applies.len(), 2);
        assert_eq!(applies[0]["slot"], 1);
        assert_eq!(applies[0]["stateBefore"], 0);
        assert_eq!(applies[0]["result"], 0);
        assert_eq!(applies[0]["stateAfter"], 1);
        assert_eq!(applies[1]["slot"], 2);
        assert_eq!(applies[1]["stateBefore"], 1);
        assert_eq!(applies[1]["result"], 1);
        assert_eq!(applies[1]["stateAfter"], 2);
        assert!(primary.trace_take_applies().is_empty());
        assert_eq!(primary.drain_replies().count(), 2);
        let snapshot = primary.trace_snapshot(&[], &[], 0);
        assert_eq!(snapshot["applied"].as_array().unwrap().len(), 2);
        assert_eq!(snapshot["results"], json!([0, 1]));
    }
}
