"""Extract observations from recorded post-states; does not execute model actions."""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2]

def decode(value):
    if isinstance(value, list):
        return tuple(decode(x) for x in value)
    if isinstance(value, dict):
        if value.get('__tla') == 'function':
            return {decode(e['key']):decode(e['value']) for e in value['entries']}
        if value.get('__tla') == 'set':
            return tuple(decode(x) for x in value['items'])
        return {k:decode(v) for k,v in value.items()}
    return value

def printable(value):
    if isinstance(value, dict):
        return {str(k):printable(v) for k,v in value.items()}
    if isinstance(value, (tuple, list)):
        return [printable(v) for v in value]
    return value

all_rows = []
for path in sorted((OUT / 'traces/normalized').glob('*.ndjson')):
    trace = [json.loads(line) for line in path.read_text().splitlines()]
    state = decode(trace[0]['post'])
    receipts = []
    progress_conflicts = []
    milestones = []
    for event in trace[1:]:
        state.update(decode(event['post']))
        name = event['event']
        if name == 'RecordOutcome':
            receipts.append(dict(n=event['n'], receipt=state['receipt'],
                                 sourceHeld=state['sourceHeld'], ops=state['ops'],
                                 releaseAttempts=state['releaseAttempts'],
                                 doneCalls=state['doneCalls'], outcomeCbCalls=state['outcomeCbCalls']))
        if name == 'TransactionEmitProgressEvent':
            e = decode(event['args']['e'])
            if e['state'] == 'completed' and state['status'][e['pair']] != 'success':
                progress_conflicts.append(dict(n=event['n'], event=e, receiver_status=state['status'][e['pair']]))
        if name in {'CheckedExecutorEnqueue','CheckedExecutorSubmitRuntimeError','SubmitFinishedSettlementFallback',
                    'SettleFinishedTransactionWorker','RecordOutcome','RecordOutcomeDrop',
                    'Shutdown','TransactionDoneDrainExpired','WaitForResultTransfers'}:
            milestones.append(dict(n=event['n'], event=name, args=event['args']))
    row = dict(name=path.stem, config=trace[0]['config'], receipts=receipts,
               progress_conflicts=progress_conflicts, milestones=milestones,
               final={k:state[k] for k in ['status','waiter','lateWaiter','receiptWrites','receipt',
                   'doneCalls','outcomeCbCalls','releaseAttempts','objectDoneCalls','effectsAfterReceipt',
                   'sourceHeld','caller','callbackErrors','terminating','ops','retained']})
    all_rows.append(printable(row))
    print(path.stem, 'waiter='+state['waiter'], 'status='+state['receipt']['status'],
          'quorum='+str(state['receipt']['quorum']), 'receiptWrites='+str(state['receiptWrites']),
          'doneCalls='+str(state['doneCalls']), 'progressConflicts='+str(len(progress_conflicts)))
(OUT / 'spec/output/trace-observations.json').write_text(json.dumps(all_rows, indent=2)+'\n')
