#!/usr/bin/env python3
"""Render all transition deltas after the required MCP summary/state inspection."""
from pathlib import Path
import argparse
import json

ROOT = Path(__file__).resolve().parent


def delta(before, after, prefix=''):
    if isinstance(before,dict) and isinstance(after,dict) and before.keys() == after.keys():
        result = {}
        for key in after:
            if before[key] != after[key]:
                result.update(delta(before[key],after[key],prefix+'.'+key if prefix else key))
        return result
    return {prefix: {'before':before,'after':after}} if before != after else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run')
    ap.add_argument('--fields', nargs='*')
    args = ap.parse_args()
    directory = ROOT/'output'/args.run
    summary = json.loads((directory/'summary.json').read_text())
    assert json.loads(summary['content'][0]['text'])['success'], 'Run get_tlc_summary first'
    assert (directory/'inspection.json').exists(), 'Run state/diff inspection first'
    ce = json.loads((directory/'counterexample.json').read_text())['counterexample']
    timeline = []
    for before,action,after in ce['action']:
        changes = delta(before[1],after[1])
        row = {'from':before[0],'to':after[0], 'action':action['name'],'changes':changes}
        timeline.append(row)
    (directory/'all-transition-deltas.json').write_text(json.dumps(timeline,indent=2)+'\n')
    for row in timeline:
        changes = row['changes']
        if args.fields:
            changes = {k:v for k,v in changes.items() if k.split('.')[0] in args.fields}
        print(json.dumps({**row,'changes':changes},separators=(',',':')))


if __name__ == '__main__':
    main()
