# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Generate observation-only source patch from the pinned Git blob. No reset."""

import ast
import difflib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(sys.argv[1]).resolve()
OUT = pathlib.Path(__file__).resolve().parents[1]
SHA = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
FILE = "nvflare/fuel/f3/streaming/download_service.py"
old = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{SHA}:{FILE}"], text=True)
s = old


def replace(a, b, count=1):
    global s
    assert s.count(a) == count, (a, s.count(a), count)
    s = s.replace(a, b)


def after(a, hook, count=1):
    indent = a.splitlines()[-1][: len(a.splitlines()[-1]) - len(a.splitlines()[-1].lstrip())]
    replace(a, a + "\n" + indent + f'_trace.point("{hook}", locals())', count)


replace("import dataclasses", "from nvflare.fuel.f3.streaming import specula_trace as _trace\n\nimport dataclasses")
# Admission and drain: probes execute under the same operation lock as mutations.
after("            self._active_ops += 1", "op_begin")
after("            self._active_ops -= 1", "op_end")
after("            self._ops_closed = True", "drain_begin")
replace(
    "                if remaining <= 0:\n                    return False",
    '                if remaining <= 0:\n                    _trace.point("drain_expired", locals())\n                    return False',
)
replace(
    "                self._ops_cond.wait(remaining)\n        return True",
    '                self._ops_cond.wait(remaining)\n            _trace.point("drain_empty", locals())\n        return True',
)
# Active timestamps: preserve separate progress/stats-lock publications.
replace(
    "    def mark_active(self):\n        self.last_active_time = time.time()",
    '    def mark_active(self):\n        with _trace.atomic():\n            self.last_active_time = time.time()\n            _trace.point("mark_active", locals())',
)
after("            self._receiver_activity[receiver] = now", "ref_active")
after("            tx._receiver_last_active[receiver] = now", "tx_receiver_active")
# Finalizer call selection, commit, callbacks and continuations.
replace(
    "        with self._progress_lock:\n            if to_receiver in self.receiver_statuses:",
    '        _trace.point("finalizer_select", locals())\n        with self._progress_lock:\n            if to_receiver in self.receiver_statuses:',
    count=2,
)
replace(
    '        nonce = uuid.uuid4().hex\n        _trace.point("finalizer_select", locals())',
    "        nonce = uuid.uuid4().hex",
)
replace(
    "            if to_receiver in self.receiver_statuses:\n                return False",
    '            if to_receiver in self.receiver_statuses:\n                _trace.point("finalizer_reject", locals())\n                return False',
)
replace(
    "                    return False\n            self._pending_confirms.pop",
    '                    _trace.point("finalizer_reject", locals())\n                    return False\n            self._pending_confirms.pop',
)
replace(
    "                self._downloaded_to_all_called = True\n\n        # Guarded",
    '                self._downloaded_to_all_called = True\n            _trace.point("finalizer_commit", locals())\n\n        # Guarded',
)
replace(
    "        if all_done:\n            # this object",
    '        _trace.point("one_returned", locals())\n        if all_done:\n            # this object',
)
replace(
    "                self.obj.downloaded_to_all,\n            )\n        return True",
    '                self.obj.downloaded_to_all,\n            )\n            _trace.point("all_returned", locals())\n        return True',
)
replace(
    "                # already finalized -- a late duplicate serve must not resurrect a provisional\n                return None",
    '                # already finalized -- a late duplicate serve must not resurrect a provisional\n                _trace.point("served_final", locals())\n                return None',
)
after("            self._pending_confirms[to_receiver] = (status, nonce)", "served")
replace(
    "        return accepted\n",
    '        _trace.point("finalizer_advance", locals())\n        return accepted\n',
    count=2,
)
replace(
    "            return dict(self.receiver_statuses)",
    '            return _trace.value("snapshot_ref", dict(self.receiver_statuses), locals())',
)
# Every source progress call, including suppression, is observed under its original lock.
replace(
    "        now = time.time()\n        with self._progress_lock:\n            event =",
    '        _trace.point("progress_request", locals())\n        now = time.time()\n        with self._progress_lock:\n            event =',
)
replace(
    "                timestamp=now,\n            )\n        if not event:",
    '                timestamp=now,\n            )\n            _trace.point("progress_made", locals())\n        if not event:',
)
replace(
    "                for receiver_id in receiver_ids\n            ]",
    '                for receiver_id in receiver_ids\n            ]\n            _trace.point("terminal_batch", locals())',
)
# Source callback guard observes arguments at entry, exceptions separately from return.
replace(
    '    try:\n        cb(*args, **kwargs)\n    except Exception as ex:\n        logger.warning(f"{what} failed: {secure_format_exception(ex)}")',
    '    _trace.point("callback_enter", locals())\n    try:\n        cb(*args, **kwargs)\n    except Exception as ex:\n        _trace.point("callback_exception", locals())\n        logger.warning(f"{what} failed: {secure_format_exception(ex)}")\n    else:\n        _trace.point("callback_return", locals())',
)
# Budget snapshots and the actual selected failures (never manufacture an expiration).
after("            tx_last_active = dict(self._receiver_last_active)", "budget_snapshot")
replace(
    "        enforced = []\n        for receiver, reason in failures:",
    '        _trace.point("budget_nonfailures", locals())\n        enforced = []\n        for receiver, reason in failures:\n            _trace.point("budget_select", locals())',
)
replace(
    "            with self.tx._stats_lock:\n                if self.tx._receiver_last_active.get(receiver)",
    '            with self.tx._stats_lock:\n                _trace.point("budget_recheck", locals())\n                if self.tx._receiver_last_active.get(receiver)',
)
replace(
    "            if not self._finalize_receiver(receiver, DownloadStatus.FAILED):\n                continue",
    '            if not self._finalize_receiver(receiver, DownloadStatus.FAILED):\n                _trace.point("budget_advance", locals())\n                continue',
)
after("            enforced.append((receiver, reason))", "budget_advance")
# Settlement local snapshots, actual verdict, source references and callback loops.
replace(
    "            progress_state = self._progress_state_for_transaction_status(status)",
    '            _trace.point("computed", locals())\n            progress_state = self._progress_state_for_transaction_status(status)',
)
replace(
    "            elapsed = time.time() - self.start_time",
    '            _trace.point("settlement_progress_returned", locals())\n            elapsed = time.time() - self.start_time',
)
replace(
    "            base_objs = [ref.obj.base_obj for ref in refs]",
    '            base_objs = [_trace.base_object(ref) for ref in refs]\n            _trace.point("objects_begin", locals())',
)
replace(
    '                _invoke_cb_safely(\n                    self.logger,\n                    f"transaction_done of',
    '                _trace.point("object_callback", locals())\n                _invoke_cb_safely(\n                    self.logger,\n                    f"transaction_done of',
)
replace(
    "                    status,\n                )\n\n            if self.transaction_done_cb:",
    '                    status,\n                )\n                _trace.point("object_returned", locals())\n\n            if self.transaction_done_cb:\n                _trace.point("tx_callback", locals())',
)
replace(
    "            if outcome is not None and self.outcome_cb:\n                _invoke",
    '            if outcome is not None and self.outcome_cb:\n                _trace.point("outcome_callback", locals())\n                _invoke',
)
replace(
    '            for ref in refs:\n                _invoke_cb_safely(self.logger, f"release',
    '            _trace.point("release_begin", locals())\n            for ref in refs:\n                _trace.point("release_callback", locals())\n                _invoke_cb_safely(self.logger, f"release',
)
replace(
    "ref.obj.release)\n\n            # PHASE: recording",
    'ref.obj.release)\n                _trace.point("release_returned", locals())\n            _trace.point("record_ready", locals())\n\n            # PHASE: recording',
)
replace(
    "            self._settlement_complete = True",
    '            if not on_outcome:\n                _trace.point("record_skipped", locals())\n            with _trace.atomic():\n                self._settlement_complete = True\n                _trace.point("settlement_complete", locals())',
)
replace(
    "        try:\n            self.progress_cb(**event)",
    '        _trace.point("progress_callback", locals())\n        try:\n            self.progress_cb(**event)',
)
replace(
    '                f"{secure_format_exception(ex)}"\n            )\n\n    @staticmethod',
    '                f"{secure_format_exception(ex)}"\n            )\n        finally:\n            _trace.point("progress_returned", locals())\n\n    @staticmethod',
)
# Capture an unsuccessful completion scan at its actual missing-ref read.
replace(
    "                if not ref._completion_reached_locked():\n                    return False",
    '                if not ref._completion_reached_locked():\n                    _trace.point("finish_scan_missing", locals())\n                    return False',
)
# Retirement and marker ownership.
replace(
    "                cls._delete_tx(tx)\n\n        if tx:",
    '                cls._delete_tx(tx)\n                _trace.point("delete", locals())\n\n        if tx:',
)
replace(
    "            if cls._tx_table.get(tx.tid) is not tx or not tx.is_finished():\n                return False",
    '            if cls._tx_table.get(tx.tid) is not tx or not tx.is_finished():\n                _trace.point("finish_missing", locals())\n                return False',
)
replace(
    "            cls._delete_tx(tx, tombstone_finished_refs=True)\n\n        cls._submit",
    '            cls._delete_tx(tx, tombstone_finished_refs=True)\n            _trace.point("finish", locals())\n\n        cls._submit',
)
after("            future = callback_thread_pool.submit(cls._settle_finished_transaction, tx)", "submit_return")
replace(
    "        except RuntimeError:\n            # The shared executor",
    '        except RuntimeError:\n            _trace.point("submit_exception", locals())\n            # The shared executor',
)
replace(
    "            cls._settle_finished_transaction(tx)\n\n    @classmethod",
    '            _trace.point("submit_fallback", locals())\n            cls._settle_finished_transaction(tx)\n\n    @classmethod',
)
replace(
    "                cls._tx_waiters.clear()\n\n        with cls._init_lock:",
    '                cls._tx_waiters.clear()\n                _trace.point("shutdown", locals())\n\n        with cls._init_lock:',
)
after("            leaked = tx._active_ops > 0", "marker_read")
replace(
    "                cls._terminating_txs.pop(tx.tid, None)\n\n    @classmethod\n    def _reap",
    '                cls._terminating_txs.pop(tx.tid, None)\n            _trace.point("marker_write", locals())\n\n    @classmethod\n    def _reap',
)
after("                cls._terminating_txs.pop(tid, None)", "marker_reap")
# Second waiter under outcome lock, all three branches.
replace(
    "                waiter._resolve(existing)\n                return waiter",
    '                waiter._resolve(existing)\n                _trace.point("late_waiter", locals())\n                return waiter',
)
replace(
    "                waiter._resolve(None)\n                return waiter",
    '                waiter._resolve(None)\n                _trace.point("late_waiter", locals())\n                return waiter',
)
after("            cls._tx_waiters.setdefault(transaction_id, []).append(waiter)", "late_waiter")
replace(
    "                # ownership consumed (prior record) or cleared (shutdown): stale, drop\n                return",
    '                # ownership consumed (prior record) or cleared (shutdown): stale, drop\n                _trace.point("record_drop", locals())\n                return',
)
replace(
    "                waiter._resolve(outcome)\n\n    @classmethod",
    '                waiter._resolve(outcome)\n            _trace.point("record", locals())\n\n    @classmethod',
)
after("                cls._tx_outcomes.pop(tid, None)", "expire")
# Producer actual returns are expression-wrapped via AST locations below.
replace(
    "                rc, data, new_state = ref.obj.produce(current_state, requester)",
    '                rc, data, new_state = ref.obj.produce(current_state, requester)\n                _trace.point("produce", locals())',
)
replace(
    "            except Exception as ex:\n                ref.emit_progress",
    '            except Exception as ex:\n                _trace.point("produce_exception", locals())\n                ref.emit_progress',
)
replace(
    "            if accepted:\n                ref.mark_active()",
    '            if accepted:\n                ref.mark_active()\n            else:\n                _trace.point("confirm_inactive", locals())',
)
after("                acquired = requester in tx._acquired_receivers", "cancel_acquired")
replace(
    "                accepted = tx_ref.obj_cancelled(requester) or accepted\n        finally:",
    '                accepted = tx_ref.obj_cancelled(requester) or accepted\n            _trace.point("cancel_loop_done", locals())\n        finally:',
)
replace(
    "        if ref is None:\n            # the transaction already terminated",
    '        if ref is None:\n            _trace.point("confirm_late", locals())\n            # the transaction already terminated',
)
replace(
    '        if ref is None:\n            cls._logger.debug(f"late cancellation',
    '        if ref is None:\n            _trace.point("cancel_late", locals())\n            cls._logger.debug(f"late cancellation',
)
# Explicit real monitor iteration, scheduling controlled by test clock sleep seam.
replace(
    "        while True:\n            now = time.time()\n\n            # Per-receiver",
    '        while True:\n            now = time.time()\n            _trace.point("monitor_begin", locals())\n\n            # Per-receiver',
)
replace(
    "                budget_txs = [tx for tx in cls._tx_table.values() if tx.has_receiver_budgets]",
    '                budget_txs = [tx for tx in cls._tx_table.values() if tx.has_receiver_budgets]\n                _trace.point("monitor_no_budgets", locals())',
)
replace(
    "                    live = cls._tx_table.get(tx.tid) is tx and tx.begin_op()",
    '                    live = cls._tx_table.get(tx.tid) is tx and tx.begin_op()\n                    if not live:\n                        _trace.point("monitor_admission_failed", locals())',
)
replace(
    "                    cls._delete_tx(tx)\n\n                for tx in finished_tx:",
    '                    cls._delete_tx(tx)\n                    _trace.point("monitor_timeout", locals())\n\n                for tx in finished_tx:',
)
replace(
    "                    cls._delete_tx(tx, tombstone_finished_refs=True)\n\n                cls._expire_finished_refs(now)",
    '                    cls._delete_tx(tx, tombstone_finished_refs=True)\n                    _trace.point("monitor_finished", locals())\n\n                _trace.point("monitor_not_retired", locals())\n                cls._expire_finished_refs(now)',
)
# Consumer probes retain actual return / error decision, nonce and payload.
replace(
    "    def _do_request(req_state):\n        req_payload",
    '    def _do_request(req_state):\n        _trace.point("request_start", locals())\n        req_payload',
)
replace(
    "        if not (confirm_enabled and producer_expects_confirm):\n            return",
    '        if not (confirm_enabled and producer_expects_confirm):\n            _trace.point("confirm_skip", locals())\n            return',
)
replace(
    '            logger.warning(f"failed to send download confirmation',
    '            _trace.point("confirm_lost", locals())\n            logger.warning(f"failed to send download confirmation',
)
replace(
    "        if status == ProduceRC.EOF:\n            elapsed",
    '        if status == ProduceRC.EOF:\n            _trace.point("consumer_eof", locals())\n            elapsed',
)
replace(
    "                consumer.download_completed(ref_id)\n            except Exception:",
    '                consumer.download_completed(ref_id)\n                _trace.point("consumer_completed", locals())\n            except Exception:\n                _trace.point("consumer_completed_exception", locals())',
)
replace(
    "        elif status == ProduceRC.ERROR:\n            _send_confirm",
    '        elif status == ProduceRC.ERROR:\n            _trace.point("consumer_producer_error", locals())\n            _send_confirm',
)
replace(
    '            _send_cancel()\n            consumer.download_failed(ref_id, f"error requesting',
    '            _trace.point("consumer_request_error", locals())\n            _send_cancel()\n            consumer.download_failed(ref_id, f"error requesting',
)
after("        state = payload.get(_PropKey.STATE)", "consumer_data")
replace(
    "            pending_future = download_request_thread_pool.submit(_do_request, request_state)",
    '            _trace.point("pipeline_submit", locals())\n            pending_future = download_request_thread_pool.submit(_do_request, request_state)',
)
replace(
    '            _send_cancel()\n            consumer.download_failed(ref_id, f"exception when consuming',
    '            _trace.point("consumer_consume_exception", locals())\n            _send_cancel()\n            consumer.download_failed(ref_id, f"exception when consuming',
)
replace(
    '        _emit_progress("active")\n',
    '        _trace.point("consumer_consume_return", locals())\n        _emit_progress("active")\n',
)
# Wrap every ordinary handler return without changing actual Message construction.
tree = ast.parse(s)
lines = s.splitlines(keepends=True)
offsets = [0]
for line in lines:
    offsets.append(offsets[-1] + len(line))
edits = []
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_handle_download":
        for n in ast.walk(node):
            if isinstance(n, ast.Return) and n.value is not None:
                v = n.value
                if isinstance(v, ast.Call) and isinstance(v.func, ast.Name) and v.func.id == "make_reply":
                    a = offsets[v.lineno - 1] + v.col_offset
                    b = offsets[v.end_lineno - 1] + v.end_col_offset
                    edits.append((a, b, '_trace.value("producer_reply", ' + s[a:b] + ", locals())"))
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in ("_send_confirm", "_send_cancel"):
        for v in ast.walk(node):
            if isinstance(v, ast.Call) and isinstance(v.func, ast.Name) and v.func.id == "new_cell_message":
                a = offsets[v.lineno - 1] + v.col_offset
                b = offsets[v.end_lineno - 1] + v.end_col_offset
                edits.append((a, b, '_trace.value("control_message", ' + s[a:b] + ", locals())"))
for a, b, new in sorted(edits, reverse=True):
    s = s[:a] + new + s[b:]
ast.parse(s)
patch = "".join(
    difflib.unified_diff(old.splitlines(True), s.splitlines(True), fromfile="a/" + FILE, tofile="b/" + FILE)
)
(OUT / "patches/instrumentation.patch").write_text(patch)
(OUT / "patches/instrumented-download_service.py.txt").write_text(s)
print("Patch generated:", len(patch.splitlines()), "lines")

CALLER = "nvflare/client/cell/api.py"
caller_old = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{SHA}:{CALLER}"], text=True)
caller_new = caller_old.replace(
    "    def _wait_for_result_transfers(self, result_waiters)",
    "    @_trace.caller_observed\n    def _wait_for_result_transfers(self, result_waiters)",
)
# Insert with existing imports, after any future imports.
caller_new = caller_new.replace(
    "import ", "from nvflare.fuel.f3.streaming import specula_trace as _trace\n\nimport ", 1
)
ast.parse(caller_new)
with (OUT / "patches/instrumentation.patch").open("a") as f:
    f.write(
        "".join(
            difflib.unified_diff(
                caller_old.splitlines(True), caller_new.splitlines(True), fromfile="a/" + CALLER, tofile="b/" + CALLER
            )
        )
    )
