#!/usr/bin/env python3
"""Export Prometheus samples for the measured window; absent samples remain explicitly absent."""
import argparse
import json
from pathlib import Path
import urllib.parse
import urllib.request


def collect(prometheus,env,start,end,fetch=None):
    labels=f'project="burger",env="{env}"'
    queries={
        'appProcessCpuFraction':f'avg by (env) (process_cpu_usage{{{labels}}})',
        'appHeapBytes':f'sum by (env) (jvm_memory_used_bytes{{{labels},area="heap"}})',
        'databaseConnections':f'mysql_global_status_threads_connected{{{labels}}}',
        'databaseQuestionsPerSecond':f'rate(mysql_global_status_questions{{{labels}}}[1m])',
        'hostCpuFraction':f'1 - avg by (env,role) (rate(node_cpu_seconds_total{{{labels},mode="idle"}}[1m]))',
        'scrapeUp':f'up{{{labels}}}',
    }
    def get(url):
        with urllib.request.urlopen(url,timeout=20) as response:return json.load(response)
    fetch=fetch or get
    results={}
    for name,query in queries.items():
        params=urllib.parse.urlencode({'query':query,'start':start,'end':end,'step':15})
        try:
            payload=fetch(prometheus.rstrip('/')+'/api/v1/query_range?'+params)
            if payload.get('status')!='success':raise ValueError('Prometheus query failed')
            series=payload['data']['result']
            results[name]={'query':query,'status':'ok' if series else 'no-data','series':series}
        except Exception as e:results[name]={'query':query,'status':'failed','error':str(e)}
    return {'schemaVersion':1,'env':env,'window':{'start':start,'end':end,'stepSeconds':15},'metrics':results,
            'note':'process CPU is JVM process usage, not whole Fargate task CPU; rate[1m] includes lookback before the window'}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--prometheus',required=True);p.add_argument('--env',choices=['main','dev'],required=True)
    p.add_argument('--start',type=float,required=True);p.add_argument('--end',type=float,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--summary',type=Path)
    a=p.parse_args()
    if a.summary and a.summary.exists():
        summary=json.loads(a.summary.read_text())
        start=summary['measurement'].get('windowStartEpochSeconds')
        if start:a.start=start;a.end=start+summary['config']['seconds']
    if a.end<=a.start:p.error('end must follow start')
    report=collect(a.prometheus,a.env,a.start,a.end)
    a.output.write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(1 if any(v['status']!='ok' for v in report['metrics'].values()) else 0)
