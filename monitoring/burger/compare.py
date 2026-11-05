#!/usr/bin/env python3
"""Compare nominal-window k6 summaries only when workload and dataset conditions match."""
import argparse
import json
from pathlib import Path

MATCH = ['experiment','datasetSha256','workloadSha256','endpoint','rps','seconds','warmupSeconds','seed','limit','preAllocatedVUs','maxVUs','resources']

def compare(main, dev):
    a,b=main['config'],dev['config']
    mismatch=[key for key in MATCH if key not in a or key not in b or a[key]!=b[key]]
    if mismatch:raise ValueError('incomparable conditions: '+', '.join(mismatch))
    if a.get('env')!='main' or b.get('env')!='dev':raise ValueError('provide main first, dev second')
    if not main['measurement']['thresholdsPassed'] or not dev['measurement']['thresholdsPassed']:raise ValueError('failed thresholds; inspect failures before comparing latency')
    rows={}
    for label,getter in [('p95Ms',lambda v:v['latency']['p(95)']),('p99Ms',lambda v:v['latency']['p(99)']),('completedRps',lambda v:v['completedRps']),('errorRate',lambda v:v['errorRate'])]:
        x,y=getter(main['measurement']),getter(dev['measurement'])
        if x is None or y is None:raise ValueError('missing measurement '+label)
        rows[label]={'main':x,'dev':y,'changePercent':100*(y-x)/x if x else None}
    return {'conditions':{key:a[key] for key in MATCH},'mainTestId':a['testid'],'devTestId':b['testid'],'results':rows,
            'note':'negative latency change is faster; repeat and alternate main/dev order; this is not a significance test'}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('main',type=Path);p.add_argument('dev',type=Path)
    a=p.parse_args()
    try:result=compare(json.loads(a.main.read_text()),json.loads(a.dev.read_text()))
    except (ValueError,KeyError,TypeError) as e:p.error(str(e))
    print(json.dumps(result,ensure_ascii=False,indent=2))
