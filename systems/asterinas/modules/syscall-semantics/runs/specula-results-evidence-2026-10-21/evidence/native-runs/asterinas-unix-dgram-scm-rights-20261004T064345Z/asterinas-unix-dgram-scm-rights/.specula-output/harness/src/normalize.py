#!/usr/bin/env python3
"""Decode recorded observations. No missing production events are synthesized."""
import collections
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

PIN = '0c60537098f4c2949ad2d382aaf499de72263d76'
NAMES = ['Full', 'Null', 'Zero', 'Short', 'HeaderOnly', 'NoInteger', 'One',
         'OnePadded', 'SpaceOne', 'FirstFault', 'LaterFault', 'PartialFault',
         'HeaderFault', 'HeaderPartial']
TIDS = {0: 's', 1: 'r1', 2: 'r2'}

def layout(i, rights_count=4):
    name = NAMES[i]
    return dict(name=name, null=i == 1,
                capacity={2: 0, 3: 15, 4: 16, 5: 19, 6: 20, 7: 21, 8: 24}.get(i, 16+4*rights_count),
                headerCopied={12: 0, 13: 8}.get(i, 16),
                failEntry={9: 1, 10: 3, 11: 3}.get(i, 0),
                partialBytes=2 if i == 11 else 0)

def receiver(rights_count=4):
    return dict(pc='Idle', mode='Recv', layout=layout(0, rights_count), payloadGood=True,
                selected='NoMessage', payloadResult='Pending', selectedRef=[], temp=[],
                nfit=0, index=1, fdForEntry=[-1]*rights_count, installedObjects=['NoObject']*rights_count,
                installed=[], numberComplete=[], numberFailed=[], delivered=[], dirtyBytes=[],
                cursor=0, headerResult='Unattempted', headerLen=0, controlError='',
                internalLen=0, ctrunc=False, reportedLen=0, reportedCtrunc=False,
                msghdrWritten=False, returnValue='Pending', faultRetained=False,
                generated=False, peekBefore=[], peekAfter=[], peekMessageBefore='NoMessage',
                peekMessageAfter='NoMessage', generatedObjects=[])

def extract(path):
    records = collections.defaultdict(list)
    for line in path.read_text().splitlines():
        match = re.search(r'SCM_(\w+) (\{.*\})\s*$', line)
        if match:
            records[match[1]].append(json.loads(match[2]))
    return records

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')

def decode_case(case, source):
    fixture = next(f for f in source['FIXTURE'] if f['case'] == case)
    rights_count = fixture['rightsCount']
    assert 1 <= rights_count <= 4
    rows = [r for r in source['RAW'] if r['case'] == case]
    maps = [m for m in source['MAP'] if m['case'] == case]
    assert len(maps) == 3 and all(not m['overflow'] for m in maps), (case, 'buffers')
    assert len({tuple(m['objects']) for m in maps}) == 1
    addresses = maps[0]['objects']
    assert addresses[0] != addresses[1] and all(addresses)
    clocks = [c for c in source['CLOCK'] if c['case'] == case]
    assert len(clocks) == 1 and clocks[0]['samples'] == 128
    assert clocks[0]['source'] == 'HPET' and clocks[0]['period_fs'] > 0
    assert len(clocks[0]['exchanges']) == 128
    assert all(a <= b <= c for a, b, c in clocks[0]['exchanges']), (case, 'clock qualification')
    cpus = clocks[0]['cpus']
    assert cpus[1] != cpus[2], (case, 'receivers were placed on one CPU')
    assert all(r['cpu'] == cpus[r['tid']] for r in rows), (case, 'CPU placement changed')
    def obj(p):
        assert p in addresses, (case, 'unknown file', p)
        return 'fileA' if p == addresses[0] else 'fileB'
    def ids(raw):
        assert not any(raw[raw.index(0):]) if 0 in raw else True
        return [obj(p) for p in raw if p]
    def balance(raw, delta):
        counts = collections.Counter(obj(p) for p in raw if p)
        return [dict(object=o, delta=counts[o]*delta) for o in ['fileA', 'fileB']]
    qids = {r['v'][0] for r in rows if r['event'] == 'MessageQueueTrySendLock'}
    assert len(qids) == 1
    qid = next(iter(qids))
    def queue(v, owner):
        assert v[0] == qid and v[1] in [0, 1], (case, 'queue identity', v)
        assert not v[1] or v[2] == 1
        rights = ids(v[3:7])
        assert bool(rights) == bool(v[1])
        return dict(msg='message1' if v[1] else 'NoMessage', rights=rights, lock=owner,
                    enqueued=bool(v[7]), consumed=v[8], disposed=v[9], disposeTemp=[], closed=False)
    result = []
    per_thread = {}
    observations = {}
    for tid in range(3):
        stream = [r for r in rows if r['tid'] == tid]
        assert all(a['end'] <= b['start'] for a, b in zip(stream, stream[1:])), (case, tid, 'time order')
        per_thread[TIDS[tid]] = stream
        send = dict(pc='Idle', temp=[], capturedObjects=[], payloadGood=True, result='Pending')
        rx = None
        op = []
        q = None
        base_address = None
        for raw_index, raw in enumerate(stream):
            name, v = raw['event'], raw['v']
            assert raw['start'] <= raw['end'] and raw['start'] > 0
            e = dict(tag='trace', event=name, tid=TIDS[tid], op=[],
                     start=raw['start'], end=raw['end'], args={}, post={})
            p = e['post']
            if name == 'SendBegin':
                send.update(pc='Capture', payloadGood=bool(v[2]))
                e['args'] = dict(good=bool(v[2]))
            elif name == 'FileMessageReadFrom':
                assert v[0] == (5 if v[2] % 2 else 6)
                assert v[2] == len(send['capturedObjects'])+1
                send['temp'].append(obj(v[1]))
                send['capturedObjects'].append(obj(v[1]))
                p['balance'] = balance([v[1]], 1)
            elif name == 'AuxiliaryDataFromControl':
                assert ids(v[:4]) == send['temp']
                send['pc'] = 'Lock'
            elif name == 'MessageQueueTrySendLock':
                q = queue(v, ['Sender', 0]); p['queue'] = q
                send['pc'] = 'Copy'
            elif name == 'MessageQueueTrySendCopy':
                send['pc'] = 'Enqueue' if v[0] else 'Unlock'
                send['result'] = 'Pending' if v[0] else 'EFAULT'
                assert bool(v[0]) == send['payloadGood']
            elif name == 'MessageQueueTrySendEnqueue':
                q = queue(v, ['Sender', 0]); p['queue'] = q
                assert q['rights'] == send['temp']
                send.update(pc='Unlock', temp=[], result='OK')
            elif name == 'MessageQueueTrySendUnlock':
                q = queue(v, ['NoOwner', 0]); p['queue'] = q
                send['pc'] = 'Drop'
            elif name == 'SendTemporaryDrop':
                assert send['temp'].pop(0) == obj(v[0])
                p['balance'] = balance([v[0]], -1)
            elif name == 'SysSendmsgComplete':
                assert not send['temp']
                send['pc'] = 'Done'
            elif name == 'RecvBegin':
                rx = receiver(rights_count); op = [TIDS[tid], v[0]]
                rx.update(pc='Lock', mode='Peek' if v[3] else 'Recv', layout=layout(v[1], rights_count),
                          payloadGood=bool(v[2]), reportedLen=layout(v[1], rights_count)['capacity'])
                e['args'] = dict(mode=rx['mode'], layout=NAMES[v[1]], good=bool(v[2]))
            elif name == 'MessageReceiverTryRecvLock':
                q = queue(v, op); p['queue'] = q; rx['pc'] = 'Select'
            elif name == 'MessageReceiverTryRecvSelect':
                q = queue(v, op); p['queue'] = q
                rx['selected'] = q['msg']
                rx['pc'] = 'Copy' if v[1] else 'Unlock'
                if not v[1]: rx['returnValue'] = 'EAGAIN'
            elif name == 'MessageReceiverTryRecvCopy':
                q = queue(v, op); p['queue'] = q
                rx['payloadResult'] = 'OK' if v[11] else 'Fault'
                assert bool(v[11]) == rx['payloadGood']
                if v[11]: rx['pc'] = 'Dequeue' if rx['mode'] == 'Recv' else 'GeneratePeek'
                else: rx.update(pc='Unlock', faultRetained=q['msg'] == rx['selected'], returnValue='EFAULT')
            elif name == 'MessageReceiverTryRecvDequeue':
                q = queue(v, op); p['queue'] = q
                assert v[15] == 1
                rx.update(pc='GenerateRecv', selectedRef=ids(v[11:15]))
            elif name in ['AuxiliaryDataGenerateControlRecv', 'AuxiliaryDataGenerateControlPeek']:
                before, after, copied = ids(v[:4]), ids(v[4:8]), ids(v[8:12])
                rx.update(pc='Unlock', temp=copied.copy(), generatedObjects=copied.copy(), generated=True)
                if name.endswith('Recv'):
                    assert before == rx['selectedRef'] and not after
                    rx['selectedRef'] = []
                else:
                    assert before == q['rights'] and copied == before
                    q['rights'] = after
                    rx.update(peekBefore=before, peekAfter=after,
                              peekMessageBefore=q['msg'], peekMessageAfter=q['msg'])
                    p['queue'] = q
                    p['balance'] = balance(v[8:12], 1)
            elif name == 'MessageReceiverTryRecvUnlock':
                q = queue(v, ['NoOwner', 0]); p['queue'] = q
                rx['pc'] = 'ReleaseBorrow' if rx['payloadResult'] == 'OK' else 'Drop'
            elif name == 'SysRecvmsgReleaseBorrow': rx['pc'] = 'Control'
            elif name == 'CUserMsgHdrWriteControl':
                assert bool(v[0]) == rx['layout']['null'] and v[1] == rx['layout']['capacity']
                if v[0]: rx.update(pc='Writeback', controlError='Null', internalLen=0, ctrunc=bool(v[2] & 8))
                else: rx['pc'] = 'Capacity'; base_address = v[2]
            elif name == 'FileMessageWriteCapacity':
                assert v[1] == rx['layout']['capacity']
                rx.update(nfit=v[0], pc='Header' if v[0] else 'Report', controlError='' if v[0] else 'Capacity')
            elif name == 'FileMessageWriteHeader':
                assert v[1] == rx['layout']['headerCopied'], (case, 'header copy coverage', v)
                rx.update(pc='Install' if v[0] else 'Report', headerResult='OK' if v[0] else 'Fault',
                          headerLen=v[3] if v[0] else 0, controlError='' if v[0] else 'Header',
                          cursor=v[2]-base_address, dirtyBytes=list(range(v[1])))
            elif name == 'FileTableInsert':
                fd, pointer, index = v[:3]
                assert index == rx['index']
                rx['fdForEntry'][index-1] = fd
                rx['installedObjects'][index-1] = obj(pointer)
                rx['installed'].append(index); rx['pc'] = 'Number'
                p['slot'] = dict(slot=['shared', fd], object=obj(pointer), origin=dict(kind='Received', entry=[op, index]))
                p['balance'] = balance([pointer], 1)
            elif name == 'VmWriterWriteFd':
                good, copied, cursor, index, fd = v[:5]
                assert index == rx['index'] and fd == rx['fdForEntry'][index-1]
                assert bool(good) == (index != rx['layout']['failEntry'])
                assert copied == (4 if good else rx['layout']['partialBytes']), (case, 'integer copy coverage', v)
                rx['dirtyBytes'] += list(range(16+4*(index-1), 16+4*(index-1)+copied))
                rx['cursor'] = cursor-base_address
                rx['numberComplete' if good else 'numberFailed'].append(index)
                if good: rx['delivered'].append(index); rx['index'] += 1
                rx['controlError'] = '' if good else 'Number'
                rx['pc'] = 'Install' if good and index < rx['nfit'] else 'Report'
            elif name == 'ControlMessageWriteAllTo':
                rx.update(pc='Writeback', internalLen=v[0], ctrunc=bool(v[1] & 8), cursor=v[2]-base_address)
            elif name == 'SysRecvmsgWriteback':
                rx.update(pc='Drop', reportedLen=v[0], reportedCtrunc=bool(v[1] & 8),
                          returnValue=v[2], msghdrWritten=True)
            elif name == 'RecvTemporaryDrop':
                assert rx['temp'].pop(0) == obj(v[0])
                p['balance'] = balance([v[0]], -1)
            elif name == 'SysRecvmsgComplete':
                assert not rx['temp'] and not rx['selectedRef']
                rx['pc'] = 'Done'
                observations[tuple(op)] = copy.deepcopy(rx)
            elif name == 'RequestCleanup': p['cleanup'] = True
            elif name == 'FileTableCloseFile':
                e['args'] = dict(slot=['shared', v[0]])
                p['slot'] = dict(slot=['shared', v[0]], object='NoObject', origin=dict(kind='Other'))
                p['pendingClose'] = dict(slot=['shared', v[0]], object=obj(v[1]))
                p['released'] = [[[TIDS[v[2]], v[3]], v[4]]] if v[4] else []
            elif name == 'ClosedFileDrop':
                e['args'] = dict(slot=['shared', v[0]])
                p['pendingClose'] = dict(slot=['shared', v[0]], object='NoObject')
                p['balance'] = balance([v[1]], -1)
            elif name == 'SenderReuse':
                p['slot'] = dict(slot=['shared', v[0]], object=obj(v[1]), origin=dict(kind='Reuse'))
                p['balance'] = balance([v[1]], 1); p['reuse'] = True
            elif name == 'MessageReceiverDropBegin':
                q = queue(v, ['Disposer', 0])
                q.update(disposeTemp=q['rights'], rights=[], msg='NoMessage', disposed=q['disposed']+v[1])
                p['queue'] = q
            elif name == 'MessageReceiverDropReference':
                assert q['disposeTemp'].pop(0) == obj(v[0])
                p['queue'] = q; p['balance'] = balance([v[0]], -1)
            elif name == 'MessageReceiverDropComplete':
                assert qid == v[0] and not q['disposeTemp']
                q.update(lock=['NoOwner', 0], closed=True); p['queue'] = q
            else: raise AssertionError((case, 'unknown event', name))
            if name in ['SendBegin', 'FileMessageReadFrom', 'AuxiliaryDataFromControl',
                        'MessageQueueTrySendLock', 'MessageQueueTrySendCopy',
                        'MessageQueueTrySendEnqueue', 'MessageQueueTrySendUnlock',
                        'SendTemporaryDrop', 'SysSendmsgComplete']:
                p['send'] = send
            if tid in [1, 2]:
                e['op'] = op; p['rx'] = rx
            # JSON snapshots cannot alias later changes in observer histories.
            result.append(copy.deepcopy(e))
    users = [u for u in source['USER'] if u['case'] == case]
    assert len(users) == len(observations)
    for u in users:
        r = observations[(TIDS[u['tid']], u['attempt'])]
        expected_ret = {'EAGAIN': (-1, 11), 'EFAULT': (-1, 14)}.get(r['returnValue'], (r['returnValue'], 0))
        assert (u['return'], u['errno']) == expected_ret, (case, 'syscall result', u, r)
        assert u['length'] == r['reportedLen'] and bool(u['flags'] & 8) == r['reportedCtrunc']
        for entry in r['numberComplete']:
            offset = 16 + 4*(entry-1)
            assert int.from_bytes(bytes(u['bytes'][offset:offset+4]), 'little', signed=True) == r['fdForEntry'][entry-1]
        if r['headerResult'] == 'OK':
            header = bytes(u['bytes'][:16])
            assert int.from_bytes(header[:8], 'little') == r['headerLen']
            assert int.from_bytes(header[8:12], 'little') == 1 and int.from_bytes(header[12:], 'little') == 1
    scans = [f for f in source['FDS'] if f['case'] == case]
    assert len(scans) == 1
    installed = {fd: r['installedObjects'][i] for r in observations.values()
                 for i, fd in enumerate(r['fdForEntry']) if fd >= 0}
    if case == 22: installed.update({5: 'fileA', 6: 'fileB'})
    if case == 1: installed[5] = 'fileB'
    assert {fd: 'file'+o for fd, o in scans[0]['fds']} == installed, (case, 'FD scan')
    return result, per_thread, observations

def main():
    evidence, output = map(Path, sys.argv[1:])
    raw = extract(evidence/'guest.log')
    linux = extract(evidence/'linux.log')
    assert len(raw['CASE_DONE']) == 23
    assert len(linux['CASE_DONE']) == 23
    write_json(evidence/'linux-observations.json', linux)
    write_json(evidence/'guest-observations.json', {k: v for k, v in raw.items() if k != 'RAW'})
    coverage = collections.Counter()
    summaries = []
    output.mkdir(exist_ok=True)
    raw_dir = evidence/'per-thread'
    raw_dir.mkdir(exist_ok=True)
    for f in raw['FIXTURE']:
        case = f['case']
        events, per_thread, receivers = decode_case(case, raw)
        for tid, rows in per_thread.items():
            (raw_dir/f'case-{case:02d}-{tid}.ndjson').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        windows = [w for w in raw['WINDOW'] if w['case'] == case]
        assert len(windows) <= 1
        window = windows[0] if windows else None
        if case in (17, 18) and f['rightsCount'] == 1:
            assert window is not None, (case, 'missing competition window')
        receive_window = None
        if window:
            assert case in (17, 18) and window['start'] < window['end']
            measured = [e for e in events if window['start'] <= e['start'] and e['end'] <= window['end']]
            window_pairs = [(a, b) for a in measured for b in measured if a['tid'] < b['tid']]
            window_overlaps = sum(max(a['start'], b['start']) < min(a['end'], b['end'])
                                  for a, b in window_pairs)
            window_counts = collections.Counter(e['tid'] for e in measured)
            window_bound = (window_counts['r1'] + window_counts['r2'] - 1
                            if window_counts['r1'] and window_counts['r2'] else 0)
            window_positive = collections.Counter(e['tid'] for e in measured if e['start'] < e['end'])
            window_strict_bound = (window_positive['r1'] + window_positive['r2'] - 1
                                   if window_positive['r1'] and window_positive['r2'] else 0)
            receive_window = dict(label='SCM_WINDOW analysis only, not the timebox guide criterion',
                                  start=window['start'], end=window['end'], events=len(measured),
                                  events_by_thread=dict(window_counts), cross_thread_pairs=len(window_pairs),
                                  overlaps=window_overlaps,
                                  overlap_fraction=window_overlaps/len(window_pairs) if window_pairs else 0,
                                  structural_upper_bound=window_bound,
                                  structural_fraction=window_bound/len(window_pairs) if window_pairs else 0,
                                  positive_interval_upper_bound=window_strict_bound,
                                  positive_interval_fraction=window_strict_bound/len(window_pairs) if window_pairs else 0)
        stamps = sorted({e[k] for e in events for k in ['start', 'end']})
        rank = {n: i+1 for i, n in enumerate(stamps)}
        write_json(evidence/f'case-{case:02d}-timestamps.json', stamps)
        pairs = [(a, b) for a in events for b in events if a['tid'] < b['tid']]
        overlap = [(a, b) for a, b in pairs if max(a['start'], b['start']) < min(a['end'], b['end'])]
        receive_pairs = [(a, b) for a, b in pairs if a['tid'] == 'r1' and b['tid'] == 'r2']
        receive_overlap = [(a, b) for a, b in overlap if a['tid'] == 'r1' and b['tid'] == 'r2']
        counts = collections.Counter(e['tid'] for e in events)
        upper_bound = counts['r1'] + counts['r2'] - 1 if receive_pairs else 0
        positive = collections.Counter(e['tid'] for e in events if e['start'] < e['end'])
        strict_bound = positive['r1'] + positive['r2'] - 1 if positive['r1'] and positive['r2'] else 0
        same_message = (case == 18 and len(receivers) == 2 and
                        all(r['selected'] == 'message1' and r['payloadResult'] == 'OK'
                            for r in receivers.values()))
        for e in events:
            coverage[e['event']] += 1
            e['start'], e['end'] = rank[e['start']], rank[e['end']]
        fixture = dict(tag='fixture', schema=1, source=PIN, implementation='Asterinas',
                       receivers=['r1', 'r2'], tids=['s', 'r1', 'r2'], attemptSlots=f['attemptSlots'],
                       rightsCount=f['rightsCount'], objectA='fileA', objectB='fileB', sharedTable=True,
                       setupFDCount=f['setupFDCount'], maxFD=f['maxFD'], payloadSize=f['payloadSize'],
                       headerBytes=f['headerBytes'], fdBytes=f['fdBytes'], alignment=f['alignment'])
        path = output/f'case-{case:02d}.ndjson'
        path.write_text(''.join(json.dumps(e, separators=(',', ':'))+'\n' for e in [fixture]+events))
        summaries.append(dict(case=case, events=len(events), events_by_thread=dict(counts),
                              overlap_scope='Whole trace, timebox guide criterion', receive_window=receive_window,
                              cross_thread_pairs=len(pairs), overlaps=len(overlap),
                              overlap_fraction=len(overlap)/len(pairs) if pairs else 0,
                              receive_pairs=len(receive_pairs), receive_overlaps=len(receive_overlap),
                              receive_fraction=len(receive_overlap)/len(receive_pairs) if receive_pairs else 0,
                              structural_upper_bound=upper_bound,
                              structural_fraction=upper_bound/len(pairs) if pairs else 0,
                              positive_interval_upper_bound=strict_bound,
                              positive_interval_fraction=strict_bound/len(pairs) if pairs else 0,
                              peek_and_recv_same_message=same_message,
                              clock_source=clocks_for_case(raw, case)['source'],
                              sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        print(f'{path.name}: {len(events)} whole-trace events, '
              f'{len(overlap)} overlapping cross-thread pairs')
    write_json(evidence/'coverage.json', dict(coverage))
    write_json(evidence/'traces.json', summaries)
    assert len(coverage) == 34, (len(coverage), sorted(coverage))
    assert any(s['overlaps'] for s in summaries), 'No genuine cross-thread overlap was observed'
    for s in summaries:
        if s['case'] in (17, 18):
            assert s['receive_overlaps'] > 0, (s['case'], 'No receiver overlap')
        if s['case'] == 18:
            assert s['peek_and_recv_same_message'], 'PEEK and receive did not select the same message'

def clocks_for_case(raw, case):
    return next(c for c in raw['CLOCK'] if c['case'] == case)

if __name__ == '__main__':
    main()
