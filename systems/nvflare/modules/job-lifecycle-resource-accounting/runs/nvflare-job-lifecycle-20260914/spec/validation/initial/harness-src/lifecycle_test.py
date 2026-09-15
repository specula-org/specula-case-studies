# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0.
"""Production POC integration fixtures adapted from POCSiteLauncher.

Real secure parents, real admin requests, job store, deployment and default
server/client subprocess launchers. No mocked scheduler, RM, event dispatcher,
job handle, waiter, transport response, or resource cleanup.
"""
import json
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest
import yaml

from nvflare.fuel.flare_api.flare_api import new_secure_session
from nvflare.fuel.utils.network_utils import get_open_ports
from nvflare.tool.poc.poc_commands import prepare_poc_provision

HARNESS = Path(__file__).resolve().parent.parent
SOURCE = Path('/home/ubuntu/nvflare-job-lifecycle-20260914/source')
SCRATCH = Path('/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/harness')


def wait_until(fn, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.25)
    raise AssertionError(f'condition did not become true in {seconds}s')


def export_job(root, name, hold):
    folder = root/name
    config = folder/'app/config'
    config.mkdir(parents=True)
    meta = {'name': name, 'resource_spec': {'site-1': {'gpu': 1}, 'site-2': {'gpu': 1}},
            'min_clients': 2 if name.startswith('delayed_start') else 1, 'mandatory_clients': ['site-1'],
            'deploy_map': {'app': ['server', 'site-1', 'site-2']}}
    (folder/'meta.json').write_text(json.dumps(meta))
    (config/'config_fed_server.json').write_text(json.dumps({'format_version': 2,
        'workflows': [{'id': 'hold', 'path': 'nvflare._lifecycle_workload.HoldController', 'args': {'seconds': hold}}],
        'components': [], 'task_data_filters': [], 'task_result_filters': []}))
    (config/'config_fed_client.json').write_text(json.dumps({'format_version': 2,
        'executors': [{'tasks': ['*'], 'executor': {'path': 'nvflare._lifecycle_workload.IdleExecutor'}}],
        'components': [], 'task_data_filters': [], 'task_result_filters': []}))
    return folder


@pytest.mark.parametrize('scenario', ['competition', 'delayed_start', 'admission_exception', 'abort_completion'])
def test_lifecycle(scenario):
    stamp = str(time.time_ns())
    work = SCRATCH/f'{scenario}-{stamp}'
    work.mkdir(parents=True)
    raw = HARNESS/'logs'/f'{scenario}-{stamp}.raw.ndjson'
    project = yaml.safe_load((HARNESS/'src/project.yml').read_text())
    port = get_open_ports(1)[0]
    for p in project['participants']:
        if p['type'] == 'server':
            p['fed_learn_port'] = port
    project_path = work/'project-input.yml'
    project_path.write_text(yaml.safe_dump(project))
    prepare_poc_provision(clients=['site-1','site-2'], number_of_clients=2,
        workspace=str(work/'poc'), docker_image=None, project_conf_path=str(project_path),
        examples_dir=str(SOURCE/'examples'))
    prod = work/'poc/example_project/prod_00'
    for site in ['server', 'site-1', 'site-2']:
        respath = prod/site/'local/resources.json'
        default = respath.with_name('resources.json.default')
        res = json.loads((respath if respath.exists() else default).read_text())
        res['class_allow_list'] += ['nvflare._lifecycle_workload.HoldController',
                                    'nvflare._lifecycle_workload.IdleExecutor']
        for component in res['components']:
            if component['id'] == 'job_scheduler':
                component['args']['max_jobs'] = 2
            elif component['id'] == 'resource_manager':
                component['path'] = 'nvflare.app_common.resource_managers.list_resource_manager.ListResourceManager'
                component['args'] = {'resources': {'gpu': [0]}, 'expiration_period': 30}
            elif component['id'] == 'resource_consumer':
                component['path'] = 'nvflare.app_common.resource_consumers.list_resource_consumer.ListResourceConsumer'
                component['args'] = {}
        respath.write_text(json.dumps(res, indent=2))
        if scenario == 'competition' and site == 'site-2':
            res['components'].append({'id':'ordinary_launch_handler_failure',
                'path':'nvflare._lifecycle_workload.RaisingAfterLaunch'})
            respath.write_text(json.dumps(res, indent=2))
    gate=work/'bootstrap.ready'
    env = dict(os.environ, NVFLARE_LIFECYCLE_RAW=str(raw), NVFLARE_LIFECYCLE_SCENARIO=scenario,
               NVFLARE_LIFECYCLE_GATE=str(gate),
               PYTHONPATH=str(SOURCE), CUDA_VISIBLE_DEVICES='')
    processes = []
    logs = []
    session = None
    ids = []
    statuses = {}
    start_time = time.monotonic_ns()
    harness_snapshot={str(p.relative_to(HARNESS)):hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in (HARNESS/'patches/instrumentation.patch', HARNESS/'src/probe.py',
                                HARNESS/'src/workload.py', HARNESS/'src/lifecycle_test.py')}
    def launch(site):
        module = 'server.server_train' if site == 'server' else 'client.client_train'
        log = open(work/f'{site}.console.log', 'w')
        logs.append(log)
        args = [sys.executable, '-m', f'nvflare.private.fed.app.{module}', '-m', str(prod/site),
                '-s', 'fed_server.json' if site == 'server' else 'fed_client.json', '--set',
                'secure_train=true', 'org=nvidia', 'config_folder=config']
        if site != 'server':
            args.append('uid='+site)
        process = subprocess.Popen(args, env=dict(env, NVFLARE_LIFECYCLE_SITE=site), stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(process)
    try:
        launch('server')
        launch('site-1')
        launch('site-2')
        session = new_secure_session('admin@nvidia.com', str(prod/'admin@nvidia.com'),
                                     timeout=60, command_timeout=15)
        wait_until(lambda: len(session.get_system_info().client_info)==2,60)
        for index in ([1,2,3] if scenario=='abort_completion' else [1,2]):
            job = export_job(work/'jobs', f'{scenario}-{index}', 45 if scenario == 'abort_completion' else 12)
            ids.append(session.submit_job(str(job)))
        # TraceInit requires the finite submitted workload and connected sites.
        # Release only scheduling's initial call; production components/RPCs are live.
        gate.touch()
        if scenario == 'abort_completion':
            wait_until(lambda: session.get_job_meta(ids[0]).get('status') == 'RUNNING')
            def checked_in():
                if not raw.exists():return False
                records=[json.loads(x) for x in raw.read_text().splitlines()]
                return len({r['capture'].get('site') for r in records
                    if r['event']=='JobExecutorNotifyStatus' and r['capture'].get('job_id')==ids[0]
                    and r['capture'].get('job_status')==2})==2
            wait_until(checked_in,30)
            session.abort_job(ids[2])
            session.abort_job(ids[2])
            session.abort_job(ids[0])
            session.abort_job(ids[0])
        def finished():
            for jid in ids:
                statuses[jid] = session.get_job_meta(jid)
            return all(x.get('status', '').startswith('FINISHED') or x.get('status') == 'FAILED_TO_RUN'
                       for x in statuses.values())
        wait_until(finished, 210)
        # Preserve the production TTL backstop, including reservations left by admission failures.
        time.sleep(33 if scenario in ('delayed_start', 'admission_exception') else 3)
        assert raw.is_file() and raw.stat().st_size > 0
        assert not Path(str(raw)+'.errors').exists(), 'trace probe failed; evidence invalid'
        records=[json.loads(x) for x in raw.read_text().splitlines()]
        final_rm={}
        final_processes={}
        allocations=[]
        frees=[]
        for row in records:
            d=row['capture'];site=d.get('site')
            if 'rm' in d:final_rm[site]=d['rm']
            if 'client_processes' in d:final_processes[site]=d['client_processes']
            if row['event']=='StartJobProcessorAllocate':allocations.append(d['token'])
            if row['event']=='ResourceFree':frees.append(d['token'])
        for site in ('site-1','site-2'):
            assert final_rm[site]=={'free':{'gpu':[0]},'reserved':{}}, final_rm
            assert final_processes.get(site,{})=={}, final_processes
        assert sorted(allocations)==sorted(frees), (allocations,frees)
        expected=['FINISHED:ABORTED','FINISHED:COMPLETED','FINISHED:ABORTED'] if scenario=='abort_completion' else (
                 ['FINISHED:COMPLETED','FINISHED:FAILED_TO_RUN'] if scenario=='admission_exception' else
                 ['FINISHED:COMPLETED','FINISHED:COMPLETED'])
        assert [statuses[jid]['status'] for jid in ids]==expected
    finally:
        receipt = {'scenario': scenario, 'raw': str(raw), 'workspace': str(work),
                   'job_ids': ids, 'status': statuses, 'start_ns': start_time,
                   'finish_ns': time.monotonic_ns(), 'parent_pids': [p.pid for p in processes],
                   'harness_snapshot':harness_snapshot, 'python_version':sys.version,
                   'sourceRevision': '53ba7ee567468ea7971dad4faccef13c6cb35dc2'}
        (HARNESS/'logs'/f'{scenario}.receipt.json').write_text(json.dumps(receipt, indent=2))
        if session:
            session.close()
        # Test-owned parent groups only. This is fixture teardown after trace collection.
        for p in processes:
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGTERM)
        for p in processes:
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=5)
        for log in logs:
            log.close()
