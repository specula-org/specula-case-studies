#!/usr/bin/env python3
"""Reproducible, pin-checked additive instrumentation. Refuses unrelated edits."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent.parent
SOURCE = Path('/home/ubuntu/nvflare-job-lifecycle-20260914/source')
PIN = '53ba7ee567468ea7971dad4faccef13c6cb35dc2'
assert subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip() == PIN
edits = {}


def edit(file, anchor, new, count=1):
    path = 'nvflare/' + file + '.py'
    edits.setdefault(path, []).append((anchor, new, count))


def before(file, anchor, event, condition=None):
    indent = anchor[:len(anchor)-len(anchor.lstrip())]
    call = f'{indent}_trace_probe({event!r}, locals())\n'
    if condition:
        call = f'{indent}if {condition}:\n    {call}'
    edit(file, anchor, call + anchor)


def after(file, anchor, event):
    indent = anchor[:len(anchor)-len(anchor.lstrip())]
    edit(file, anchor, anchor + f'\n{indent}_trace_probe({event!r}, locals())')


s = 'app_common/job_schedulers/job_scheduler'
after(s, '        job_candidates.sort(key=lambda j: j.meta.get(JobMetaKey.SUBMIT_TIME.value, 0.0))', 'DefaultJobSchedulerBeginPass')
before(s, '        self.log_debug(fl_ctx, "No job is scheduled.")', 'DefaultJobSchedulerEndPass')
before(s, '                # do not schedule again too soon', 'DefaultJobSchedulerSkipBackoff')
before(s, '            with engine.new_context() as ctx:', 'BackoffObservation')
before(s, '        online_clients = engine.get_clients()', 'DefaultJobSchedulerTryJob')
before(s, '        if num_sites_ok < job.min_sites:', 'DefaultJobSchedulerEvaluateResources')
after(s, '        job.meta[JobMetaKey.LAST_SCHEDULE_TIME.value] = time.time()', 'ScheduleMetadataUpdated')
before(s, '                    return job, sites_dispatch_info', 'DefaultJobSchedulerUpdateHistory')
after(s, '                    failed_jobs.append(job)', 'DefaultJobSchedulerUpdateHistory')
after(s, '                self._update_schedule_history(job, f"exceeded max schedule count {self.max_schedule_count}", fl_ctx)', 'DefaultJobSchedulerExhausted')
after(s, '            ready_job, dispatch_info = None, None', 'DefaultJobSchedulerAdmissionException')
edit(s, '                for job in failed_jobs:\n                    job_manager.refresh_meta(job, self._get_update_meta_keys(), fl_ctx)', '                for job in failed_jobs:\n                    job_manager.refresh_meta(job, self._get_update_meta_keys(), fl_ctx)\n                    _trace_probe("DefaultJobSchedulerPersistFailed", locals())')
after(s, '                    job_manager.set_status(job.job_id, RunStatus.FINISHED_CANT_SCHEDULE, fl_ctx)', 'DefaultJobSchedulerPersistBlocked')
before(s, '        return ready_job, dispatch_info', 'DefaultJobSchedulerReturnPass')
after(s, '                    self.scheduled_jobs.append(job_id)', 'DefaultJobSchedulerJobStarted')
edit(s, '                if job_id in self.scheduled_jobs:\n                    self.scheduled_jobs.remove(job_id)',
     '                if job_id in self.scheduled_jobs:\n                    self.scheduled_jobs.remove(job_id)\n                _trace_probe("SchedulerJobRemoved", locals())')
after(s, '        engine.cancel_client_resources(resource_check_results, resource_reqs, fl_ctx)', 'DefaultJobSchedulerCancelReturned')
edit(s, '        fl_ctx.set_prop(FLContextKey.RESOURCE_CHECK_RESULT, resource_check_results, private=True, sticky=False)',
     '        _trace_fault("after_resource_results", locals())\n        fl_ctx.set_prop(FLContextKey.RESOURCE_CHECK_RESULT, resource_check_results, private=True, sticky=False)')

s = 'app_common/resource_managers/auto_clean_resource_manager'
before(s, '                for token in tokens_to_remove:', 'AutoCleanResourceManagerTick')
after(s, '                    self._deallocate(resources=reserved_resources)', 'AutoCleanResourceManagerFinishExpiry')
before(s, '        return is_resource_enough, token', 'ResourceCheckReturned')
# Keep ownership snapshots inside the actual RM critical section.
before(s, '                self.log_debug(\n                    fl_ctx, f"reserving resources: {reserved_resources} for requirements {resource_requirement}."', 'CheckResourceProcessorReserve')
before(s, '                self.log_debug(fl_ctx, f"allocating resources: {result} for requirements: {resource_requirement}.")', 'StartJobProcessorAllocate')
before(s, '                raise RuntimeError(f"allocate_resources: No reserved resources for token {token}.")', 'StartJobProcessorRejectToken')
after(s, '            self._deallocate(resources=resources)', 'ResourceFree')
# The common cancel tail is inside _lock; both no-op and successful paths.
edit(s, '        return None', '            _trace_probe("CancelResourceProcessorCancel", locals())\n        return None')

s = 'private/fed/server/server_engine'
before(s, '            replies = self._send_admin_requests(requests, fl_ctx, 15)', 'SendCheck')
edit(s, '        if requests:\n            _ = self._send_admin_requests(requests, fl_ctx)', '        _trace_probe("SendCancel", locals())\n        if requests:\n            _ = self._send_admin_requests(requests, fl_ctx)')
before(s, '            replies = self._send_admin_requests(requests, fl_ctx, timeout_secs=20)', 'SendStart')
after(s, '        job_handle = job_launcher.launch_job(job_meta, fl_ctx)', 'ServerEngineSpawnJob')
edit(s, '            }\n\n        threading.Thread(target=self.wait_for_complete, args=[args.workspace, job.job_id, job_handle]).start()', '            }\n            _trace_probe("ServerEngineRegisterJob", locals())\n\n        threading.Thread(target=self.wait_for_complete, args=[args.workspace, job.job_id, job_handle]).start()')
after(s, '        threading.Thread(target=self.wait_for_complete, args=[args.workspace, job.job_id, job_handle]).start()', 'ServerEngineInstallWaiter')
after(s, '        process.wait()', 'ServerChildExitObserved')
after(s, '                self.run_processes.pop(job_id, None)', 'ServerEngineObserveExit')

# Observe the server cleanup worker independently from the caller's return.
s = 'private/fed/server/server_engine'
before(s, '        with self.lock:\n            self.run_processes.pop(job_id, None)\n\n    def check_app_start_readiness', 'ServerEngineTerminateObserved')
edit(s, '            self.run_processes.pop(job_id, None)\n\n    def check_app_start_readiness', '            self.run_processes.pop(job_id, None)\n            _trace_probe("ServerEngineRemoveAfterTerminate", locals())\n\n    def check_app_start_readiness')

s = 'private/fed/server/admin'
before(s, '                    result[r.client_token] = r.reply', 'AdminReplyDictProjection')
before(s, '        raise RuntimeError(f"Failed to {command} to the following clients: \\n{error_msg}")', 'JobRunnerStartReplyError')
s = 'private/fed/server/message_send'
edit(s, 'message=new_cell_message({}, req)', 'message=new_cell_message({"_specula_admin_id": req.id}, req)')
before(s, '        replies = cell.broadcast_multi_requests(target_msgs, timeout_secs, optional=optional)', 'AdminWaitBegin')
after(s, '        replies = cell.broadcast_multi_requests(target_msgs, timeout_secs, optional=optional)', 'AdminWaitEnd')
edit(s, '        return result', '        for r in result:\n            _trace_probe("AdminReply", locals())\n        return result')

s = 'private/fed/server/job_runner'
edit(s, '        if job_manager:\n            thread = threading.Thread(target=self._job_complete_process, args=[engine])',
     '        _trace_fault("bootstrap_wait", locals())\n        if job_manager:\n            thread = threading.Thread(target=self._job_complete_process, args=[engine])')
before(s, '            _ = _send_to_clients(admin_server, client_sites, engine, message, timeout=2.0, optional=True)', 'SendStop')
before(s, '            client_token_to_reply = admin_server.send_requests_and_get_reply_dict(', 'SendDeploy')
before(s, '        if abort_job:', 'JobRunnerEvaluateDeployment')
after(s, '            self._pending_client_outcomes[job_id] = set(client_sites)', 'JobRunnerSetPendingOutcomes')
before(s, '        # Set metadata once, after any timeout exclusion, so it always reflects active participants.', 'JobRunnerEvaluateStartReplies')
after(s, '            self._pending_client_outcomes[job_id].intersection_update(active_client_sites)', 'JobRunnerFilterPendingOutcomes')
after(s, '                                self.running_jobs[job_id] = ready_job', 'JobRunnerRegisterRunning')
after(s, '                            job_manager.set_status(ready_job.job_id, RunStatus.DISPATCHED, fl_ctx)', 'JobRunnerWriteDispatched')
before(s, '                            if failed_clients:', 'JobRunnerPersistDeploy')
after(s, '                            job_manager.set_status(ready_job.job_id, RunStatus.RUNNING, fl_ctx)', 'JobRunnerWriteRunning')
after(s, '        reload_job = job_manager.get_job(job_id, fl_ctx)', 'JobRunnerCheckStatus')
before(s, '                            if job_id:', 'JobRunnerStartupException')
after(s, '                                    self._pending_client_outcomes.pop(job_id, None)', 'JobRunnerFailureRemove')
after(s, '                                self._stop_run(job_id, fl_ctx)', 'JobRunnerFailureStop')
before(s, '                            self._fire_job_lifecycle_event(EventType.JOB_ABORTED, ready_job.job_id, fl_ctx)', 'JobRunnerFailureStatus')
after(s, '            self._pending_client_outcomes.get(job_id, set()).discard(client_name)', 'ServerEngineReceiveOutcome')
after(s, '            job.run_aborted = True', 'JobRunnerMarkAborted')
# Capture actual stop completion before the subsequent mark, preserving the
# observed client callbacks that may execute during this blocking operation.
edit(s, '        self._stop_run(job_id, fl_ctx)\n        return self.mark_run_aborted(job_id, fl_ctx)',
     '        self._stop_run(job_id, fl_ctx)\n        _trace_probe("JobCommandAbortRunning", locals())\n        return self.mark_run_aborted(job_id, fl_ctx)')
before(s, '                        with engine.new_context() as completion_ctx:', 'JobRunnerCompletionReady')
before(s, '                                    continue\n                                unresolved = sorted(pending)', 'JobRunnerCompletionWaiting')
after(s, '                                self._finished_job_states[job.job_id] = finished_state', 'JobRunnerClassifyCompletion')
after(s, '                                finished_state.workspace_archival_complete = True', 'JobRunnerArchiveSuccess')
after(s, '                                job_manager.set_status(job.job_id, status, completion_ctx)', 'JobRunnerPublishTerminal')
before(s, '                            if status == RunStatus.FINISHED_ABORTED:', 'JobRunnerRemoveCompleted')

s = 'private/fed/client/scheduler_cmds'
edit(s, '                resource_manager.cancel_resources(resource_requirement=resource_spec, token=token, fl_ctx=fl_ctx)',
     '                resource_manager.cancel_resources(resource_requirement=resource_spec, token=token, fl_ctx=fl_ctx)\n                _trace_fault("cancel_reply", locals())')
before(s, '                allocated_resources = resource_manager.allocate_resources(', 'StartRequestBegin')
edit(s, '                allocated_resources = resource_manager.allocate_resources(',
     '                _trace_fault("before_allocate", locals())\n                allocated_resources = resource_manager.allocate_resources(')
before(s, '        if not result:', 'StartProcessorReply')
s = 'private/fed/client/training_cmds'
edit(s, '        if err:\n            return error_reply(err)\n\n        return ok_reply(body=f"deployed {app_name} to {client_name}")', '        if err:\n            _trace_probe("ClientDeployError", locals())\n            return error_reply(err)\n\n        return ok_reply(body=f"deployed {app_name} to {client_name}")')
before(s, '        return ok_reply(body=f"deployed {app_name} to {client_name}")', 'ClientDeploySuccess')
s = 'app_common/resource_consumers/list_resource_consumer'
after(s, '        os.environ["CUDA_VISIBLE_DEVICES"] = ",".join(gpu_numbers)', 'ListResourceConsumerConsume')
s = 'private/fed/client/client_engine'
before(s, '        self.client_executor.start_app(', 'ClientEngineStartAppCheck')
before(s, '            return "Client app already stopped."', 'ClientEngineAbortApp')
edit(s, '            return "Client app has not started."\n\n        self.client_executor.abort_app', '            _trace_probe("ClientEngineAbortApp", locals())\n            return "Client app has not started."\n\n        self.client_executor.abort_app')
s = 'private/fed/client/client_executor'
after(s, '                job_handle = process.get(RunProcessKey.JOB_HANDLE) if process else None', 'ClientEngineAbortApp')
edit(s, '                            job_handle.terminate()\n                        break', '                            job_handle.terminate()\n                        _trace_probe("JobExecutorAbortStarting", locals())\n                        break')
edit(s, '        # use a deep copy of the args for operation since its content will be changed!',
     '        _trace_fault("prepare_start", locals())\n        # use a deep copy of the args for operation since its content will be changed!')
edit(s, '            }\n        try:\n            job_handle = job_launcher.launch_job(job_meta, fl_ctx)', '            }\n            _trace_probe("JobExecutorRegisterPendingHandle", locals())\n        try:\n            job_handle = job_launcher.launch_job(job_meta, fl_ctx)')
before(s, '            raise\n\n        heartbeat_cleanup = pending_handle.attach(job_handle)', 'ProcessJobLauncherSpawnException')
after(s, '        heartbeat_cleanup = pending_handle.attach(job_handle)', 'PendingJobHandleAttach')
after(s, '            self.abort_app(job_id, heartbeat_cleanup=heartbeat_cleanup)', 'JobExecutorApplyPendingAbort')
after(s, '        engine.fire_event(EventType.AFTER_JOB_LAUNCH, fl_ctx)', 'JobExecutorAfterJobLaunchEvent')
edit(s, '        thread.start()', '        thread.start()\n        _trace_probe("JobExecutorInstallCleanupWaiter", locals())')
after(s, '            run_process[RunProcessKey.STATUS] = job_status', 'JobExecutorNotifyStatus')
after(s, '            job_handle.wait()', 'ClientChildExitObserved')
before(s, '            failure_reason = REPORTABLE_JOB_FAILURES.get(return_code)', 'JobExecutorWaitChildExit')
before(s, '                reply = self.client.send_request_before_shutdown(', 'JobExecutorReportOutcome')
before(s, '                if reply is None:', 'JobExecutorOutcomeReportReturned')
before(s, '                self.logger.error(f"could not report terminal outcome of job {job_id}: {secure_format_exception(e)}")', 'JobExecutorOutcomeReportException')
edit(s, '        with self.lock:\n            self.run_processes.pop(job_id, None)', '        with self.lock:\n            self.run_processes.pop(job_id, None)\n            _trace_probe("JobExecutorRemoveProcess", locals())')
after(s, '        engine.fire_event(EventType.JOB_COMPLETED, fl_ctx)', 'JobExecutorJobCompletedEvent')
before(s, '        self.logger.info(f"run ({job_id}): child worker process terminated")', 'JobExecutorTerminateAfterGrace')
s = 'app_common/job_launcher/process_launcher'
after(s, '        new_env = os.environ.copy()', 'ProcessJobLauncherSnapshotEnvironment')
after(s, '        process_adapter = spawn_process(argv, new_env)', 'ProcessJobLauncherSpawn')

s = 'private/fed/server/job_cmds'
before(s, '                if job_status in [RunStatus.SUBMITTED.value, RunStatus.DISPATCHED.value]:', 'JobCommandAbortRead')
after(s, '                    job_manager.set_status(job.job_id, RunStatus.FINISHED_ABORTED, fl_ctx)', 'JobCommandAbortPreRunWrite')
before(s, '                    return\n                elif job_status and job_status.startswith("FINISHED:"):', 'JobCommandAbortPreRunAcknowledge')
before(s, '                    message = f"Job for {job_id} is already completed."', 'JobCommandAbortAlreadyTerminal')

s = 'fuel/f3/cellnet/core_cell'
after(s, '        self.waiters[waiter.id] = waiter', 'CoreWaiterOpened')
after(s, '                waiter.received_replies[req_destination] = message', 'CoreReplyAccepted')
before(s, '                self.log_warning(f"no waiter for req {rid} - the reply is too late", None)', 'CoreLateReplyDiscarded')


s = 'private/fed/server/fed_server'
before(s, '            self.logger.warning(f"Dropped terminal outcome for untracked job/client {job_id}/{client_name}")', 'ServerEngineIgnoreOutcome')


for saved in (HERE/'applied').rglob('*.py'):
    path=str(saved.relative_to(HERE/'applied'))
    if path not in edits:
        original=subprocess.check_output(['git','-C',str(SOURCE),'show',f'{PIN}:{path}'],text=True)
        current=(SOURCE/path).read_text()
        if current not in (saved.read_text(),original):
            raise RuntimeError(f'refusing unrelated edits in retired probe file: {path}')
        (SOURCE/path).write_text(original)
patch = []
anchors = []
for path, operations in edits.items():
    original = subprocess.check_output(['git', '-C', str(SOURCE), 'show', f'{PIN}:{path}'], text=True)
    updated = original
    tree = ast.parse(updated)
    first_import = min(n.lineno for n in tree.body if isinstance(n, (ast.Import, ast.ImportFrom)))
    lines = updated.splitlines(keepends=True)
    lines.insert(first_import-1, 'from nvflare._lifecycle_probe import probe as _trace_probe, fault as _trace_fault\n')
    updated = ''.join(lines)
    for anchor, replacement, count in operations:
        if updated.count(anchor) != count:
            raise RuntimeError(f'{path}: expected {count} anchors, got {updated.count(anchor)}: {anchor}')
        updated = updated.replace(anchor, replacement, count)
    ast.parse(updated)
    current = (SOURCE/path).read_text()
    if current not in (original, updated):
        # Accept only our previous generated version, never unrelated user changes.
        previous = HERE/'applied'/path
        if not previous.exists() or previous.read_text() != current:
            raise RuntimeError(f'refusing unrelated edits: {path}')
    (SOURCE/path).write_text(updated)
    saved = HERE/'applied'/path
    saved.parent.mkdir(parents=True, exist_ok=True)
    saved.write_text(updated)
    patch.extend(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
                                    fromfile='a/'+path, tofile='b/'+path))
    for number, line in enumerate(updated.splitlines(), 1):
        if '_trace_probe(' in line or '_trace_fault(' in line:
            anchors.append({'file': path, 'line': number, 'hook': line.strip()})
(SOURCE/'nvflare/_lifecycle_probe.py').write_text((HERE/'src/probe.py').read_text())
(SOURCE/'nvflare/_lifecycle_workload.py').write_text((HERE/'src/workload.py').read_text())
(HERE/'patches/instrumentation.patch').write_text(''.join(patch))
(HERE/'hook-locations.json').write_text(json.dumps(anchors, indent=2)+'\n')
print(f'Applied {len(anchors)} source probes in {len(edits)} files at {PIN}')
