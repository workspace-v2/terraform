#!/usr/bin/env python3
"""Generate/seed reproducible data, run search experiments on the shared load generator, fetch results."""
import argparse
import base64
import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'monitoring/burger'


def aws(config, *args):
    command=['aws','--profile',os.environ.get('AWS_PROFILE_NAME','personal-project'),'--region',config['region'],*args,'--output','json']
    return json.loads(subprocess.check_output(command,text=True))


def configuration():
    return json.loads(subprocess.check_output(['terraform','output','-json','burger_deployment'],cwd=ROOT,text=True))


def read_bundle(path):
    path=Path(path)
    manifest=json.loads((path/'manifest.json').read_text())
    workload=(path/'workload.json').read_bytes()
    if manifest.get('schemaVersion')!=1 or manifest.get('generatorVersion')!=1:raise ValueError('unsupported manifest version')
    if manifest.get('profile') not in ('10k','100k','1m') or type(manifest.get('seed'))!=int:raise ValueError('invalid manifest')
    if manifest.get('commentsPerReview') not in (0,1,2) or type(manifest.get('idBase'))!=int or manifest['idBase']<1:raise ValueError('invalid generator parameters')
    for name in ['datasetSha256','workloadSha256']:
        if not re.fullmatch('[0-9a-f]{64}',manifest.get(name,'')):raise ValueError('invalid checksum')
    if hashlib.sha256(workload).hexdigest()!=manifest['workloadSha256']:raise ValueError('workload checksum mismatch')
    return manifest,workload


def package(files):
    buffer=io.BytesIO()
    with tarfile.open(fileobj=buffer,mode='w:gz') as archive:
        for name,data in files.items():
            if '/' in name:raise ValueError('archive names must be flat')
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o600
            archive.addfile(info,io.BytesIO(data))
    return base64.b64encode(buffer.getvalue()).decode()


def upload_script(directory, files):
    payload=package(files)
    return f"mkdir -p {shlex.quote(directory)}\nprintf '%s' '{payload}' | base64 -d | tar -xzf - -C {shlex.quote(directory)}\ncd {shlex.quote(directory)}\n"


def submit(config,instance,script,timeout=86400):
    if not instance:raise ValueError('instance is not configured')
    params=json.dumps({'commands':[script],'executionTimeout':[str(timeout)]})
    if len(params.encode())>24000:raise ValueError('SSM payload exceeds 24KB; reduce judgments or workload size')
    response=aws(config,'ssm','send-command','--instance-ids',instance,'--document-name','AWS-RunShellScript','--parameters',params)
    return response['Command']['CommandId']


def wait(config,instance,command,timeout=180):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try: result=aws(config,'ssm','get-command-invocation','--command-id',command,'--instance-id',instance)
        except subprocess.CalledProcessError:
            time.sleep(2);continue
        if result['Status']=='Success':return result['StandardOutputContent']
        if result['Status'] in ['Failed','Cancelled','TimedOut','Cancelling']:
            raise ValueError('remote command '+result['Status']+': '+result.get('StandardErrorContent','')[-1500:])
        time.sleep(2)
    raise ValueError('command still pending; inspect '+command)


def receipt(config,env,instance,command,run_id,kind,remote_directory=None):
    value={'schemaVersion':1,'env':env,'region':config['region'],'instance':instance,'command':command,'runId':run_id,'kind':kind,
           'remoteDirectory':remote_directory or '/opt/loadtest/burger/'+run_id}
    directory=ROOT/'loadtest-results/burger/receipts';directory.mkdir(parents=True,exist_ok=True)
    path=directory/(run_id+'.json');path.write_text(json.dumps(value,indent=2)+'\n')
    print(json.dumps(value,indent=2));print('Receipt: '+str(path))


def verify_dataset(config,env,manifest):
    instance=config['environments'][env]['database_id']
    marker='/opt/burger-benchmark/datasets/'+manifest['datasetSha256'][:16]+'/loaded.json'
    command=submit(config,instance,'set -eu\ncat '+shlex.quote(marker),60)
    loaded=json.loads(wait(config,instance,command))
    if loaded.get('datasetSha256')!=manifest['datasetSha256']:raise ValueError('deployed dataset differs from local manifest')


def seed(args,config):
    manifest,_=read_bundle(args.bundle)
    if manifest['catalogSourceType']!='SYNTHETIC':raise ValueError('remote seed supports synthetic catalogs only; load verified real catalogs using the generated SQL directly')
    env=config['environments'][args.env]
    dataset=manifest['datasetSha256']
    directory='/opt/burger-benchmark/datasets/'+dataset[:16]
    params=f"--profile {manifest['profile']} --seed {manifest['seed']} --id-base {manifest['idBase']} --comments-per-review {manifest['commentsPerReview']}"
    base=manifest['idBase'];upper=base+max(3000,manifest['counts']['reviews'],manifest['counts']['comments'],1000)
    sql='SELECT '+ '+'.join(f'(SELECT COUNT(*) FROM {table} WHERE {col} BETWEEN {base+1} AND {upper})' for table,col in [('brand','brand_id'),('menu','menu_id'),('users','user_id'),('post','post_id'),('comment','comment_id')])+';'
    script='set -eu\nflock -n /var/lock/burger-benchmark-seed.lock bash -s <<\'BURGER_SEED\'\nset -eu\n'
    script+=upload_script(directory,{'dataset.py':(TOOLS/'dataset.py').read_bytes()})
    script+="""mysql --protocol=socket -uroot -N burgerpedia -e 'SELECT menu_id,rating FROM post LIMIT 0' >/dev/null
"""
    script+=f"[ ! -e loaded.json ] || {{ echo 'Dataset already loaded; use the existing manifest.' >&2; exit 1; }}\n"
    script+=f"collisions=$(mysql --protocol=socket -uroot -N burgerpedia -e {shlex.quote(sql)})\n[ \"$collisions\" = 0 ] || {{ echo 'Reserved IDs already exist; no rows changed. Use a clean benchmark database/snapshot.' >&2; exit 1; }}\n"
    required_kb = max(4194304, (manifest.get('files',{}).get('dataset.sql',0)*3+1073741824)//1024)
    script += f"available=$(df -Pk . | awk 'NR==2 {{print $4}}')\n[ \"$available\" -ge {required_kb} ] || {{ echo 'Insufficient free disk for SQL and database growth.' >&2; exit 1; }}\n"
    script+=f"python3 dataset.py {params} --output bundle > generation.log\n"
    verification = 'import json; assert json.load(open("bundle/manifest.json"))["datasetSha256"] == ' + repr(dataset)
    script += "python3 -c " + shlex.quote(verification) + "\n"
    checks = [('brand','brand_id','brands'),('menu','menu_id','menus'),('users','user_id','users'),('post','post_id','reviews'),('comment','comment_id','comments')]
    count_sql = "SELECT CONCAT_WS(','," + ','.join(f'(SELECT COUNT(*) FROM {table} WHERE {col} BETWEEN {base+1} AND {upper})' for table,col,_ in checks) + ');'
    expected_counts = ','.join(str(manifest['counts'][key]) for _,_,key in checks)
    script += "mysql --protocol=socket -uroot --default-character-set=utf8mb4 burgerpedia < bundle/dataset.sql\n"
    script += f"actual=$(mysql --protocol=socket -uroot -N burgerpedia -e {shlex.quote(count_sql)})\n[ \"$actual\" = {shlex.quote(expected_counts)} ] || {{ echo 'Imported counts differ from the manifest.' >&2; exit 1; }}\n"
    script += "cp bundle/manifest.json loaded.json\ncat loaded.json\nBURGER_SEED\n"
    command=submit(config,env['database_id'],script)
    receipt(config,args.env,env['database_id'],command,'seed-'+args.env+'-'+dataset[:12]+'-'+uuid.uuid4().hex[:6],'seed',remote_directory=directory)


def deployed_metadata(config,env):
    service=config['environments'][env]['service']
    active=aws(config,'deploy','list-deployments','--application-name','burger','--deployment-group-name','burger-'+env,
               '--include-only-statuses','Created','Queued','InProgress','Ready','Baking')['deployments']
    if active:raise ValueError('deployment in progress; do not benchmark a traffic shift')
    services=aws(config,'ecs','describe-services','--cluster','burger','--services',service)
    state=services['services'][0]
    if services.get('failures') or state['desiredCount']<1 or state['runningCount']!=state['desiredCount'] or state['pendingCount']:
        raise ValueError('environment is not stable and running')
    tasks=aws(config,'ecs','list-tasks','--cluster','burger','--service-name',service)['taskArns']
    details=aws(config,'ecs','describe-tasks','--cluster','burger','--tasks',*tasks)['tasks']
    if len(details)!=state['desiredCount'] or len({t['taskDefinitionArn'] for t in details})!=1:raise ValueError('mixed task revisions')
    td=aws(config,'ecs','describe-task-definition','--task-definition',details[0]['taskDefinitionArn'])['taskDefinition']
    data=aws(config,'ec2','describe-instances','--instance-ids',config['environments'][env]['database_id'],config['environments'][env]['redis_id'])
    types={i['InstanceId']:i['InstanceType'] for r in data['Reservations'] for i in r['Instances']}
    resources={'taskCpu':td['cpu'],'taskMemory':td['memory'],'desiredTasks':state['desiredCount'],
               'databaseType':types[config['environments'][env]['database_id']],'redisType':types[config['environments'][env]['redis_id']]}
    return {'taskDefinition':td['taskDefinitionArn'],'images':[{'image':c['image'],'digest':c.get('imageDigest')} for t in details for c in t['containers']], 'resources':resources}


def load(args,config):
    manifest,workload=read_bundle(args.bundle)
    if not re.fullmatch('[A-Za-z0-9_.-]{1,64}',args.experiment):raise ValueError('invalid experiment ID')
    verify_dataset(config,args.env,manifest)
    metadata=deployed_metadata(config,args.env)
    run_id='search-'+args.env+'-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:6]
    value={'schemaVersion':1,'env':args.env,'baseUrl':config['environments'][args.env]['url'],'rps':args.rps,'seconds':args.seconds,
           'warmupSeconds':args.warmup,'preAllocatedVUs':args.vus,'maxVUs':args.max_vus,'seed':manifest['seed'],'limit':args.limit,'endpoint':args.endpoint,
           'testid':run_id,'experiment':args.experiment,'datasetSha256':manifest['datasetSha256'],'workloadSha256':manifest['workloadSha256'],
           'resources':metadata['resources'],'deployed':metadata}
    files={'search.js':(TOOLS/'search.js').read_bytes(),'search-config.json':json.dumps(value).encode(),'workload.json':workload,
           'collect-metrics.py':(TOOLS/'collect_metrics.py').read_bytes()}
    script='set -eu\nflock -n /var/lock/burger-benchmark.lock bash -s <<\'BURGER_LOAD\'\nset -eu\n'
    script+=upload_script('/opt/loadtest/burger/'+run_id,files)
    monitor=config['monitoring_ip']
    script+=f"export K6_PROMETHEUS_RW_SERVER_URL=http://{monitor}:9090/api/v1/write\nexport K6_PROMETHEUS_RW_TREND_STATS='p(95),p(99),avg'\n"
    script+="command -v k6 >/dev/null\nstarted=$(date +%s)\nset +e\nk6 run -o experimental-prometheus-rw search.js > output.log 2>&1\nresult=$?\nset -e\nfinished=$(date +%s)\n"
    script+=f"python3 collect-metrics.py --prometheus http://{monitor}:9090 --env {args.env} --start \"$started\" --end \"$finished\" --output monitoring.json --summary summary.json || echo 'Monitoring export failed; inspect monitoring.json/output.log' >&2\n"
    script+="cat summary.json\nexit \"$result\"\nBURGER_LOAD\n"
    command=submit(config,config['load_generator_id'],script)
    receipt(config,args.env,config['load_generator_id'],command,run_id,'load')


def quality(args,config):
    manifest,_=read_bundle(args.bundle)
    judgments=args.judgments.read_bytes()
    if json.loads(judgments).get('datasetSha256')!=manifest['datasetSha256']:raise ValueError('judgments belong to another dataset')
    verify_dataset(config,args.env,manifest)
    run_id='quality-'+args.env+'-'+uuid.uuid4().hex[:12]
    script='set -eu\nflock -n /var/lock/burger-benchmark.lock bash -s <<\'BURGER_QUALITY\'\nset -eu\n'
    script+=upload_script('/opt/loadtest/burger/'+run_id,{'quality.py':(TOOLS/'quality.py').read_bytes(),'judgments.json':judgments})
    script+=f"python3 quality.py --base-url {shlex.quote(config['environments'][args.env]['url'])} --judgments judgments.json --output quality.json > output.log 2>&1\nBURGER_QUALITY\n"
    command=submit(config,config['load_generator_id'],script)
    receipt(config,args.env,config['load_generator_id'],command,run_id,'quality')


def fetch(args,config):
    value=json.loads(args.receipt.read_text())
    run_id=value['runId'];instance=value['instance']
    if not re.fullmatch('[A-Za-z0-9_.-]+',run_id):raise ValueError('invalid run ID')
    if value.get('kind') not in ('load','quality'):raise ValueError('seed status is available through the SSM command output')
    result=aws(config,'ssm','get-command-invocation','--command-id',value['command'],'--instance-id',instance)
    if result['Status'] not in ['Success','Failed','TimedOut','Cancelled']:raise ValueError('experiment still running: '+result['Status'])
    remote='/opt/loadtest/burger/'+run_id
    code=r"""import base64,io,tarfile
from pathlib import Path
buffer=io.BytesIO()
with tarfile.open(fileobj=buffer,mode='w:gz') as archive:
 for name in ['summary.json','search-config.json','monitoring.json','quality.json','judgments.json','output.log']:
  p=Path(name)
  if p.exists():
   data=p.read_bytes() if name!='output.log' else '\n'.join(p.read_text(errors='replace').splitlines()[-100:]).encode()
   info=tarfile.TarInfo(name);info.size=len(data);archive.addfile(info,io.BytesIO(data))
encoded=base64.b64encode(buffer.getvalue()).decode()
Path('results.b64').write_text(encoded)
print(len(encoded))
"""
    command=submit(config,instance,'set -eu\ncd '+shlex.quote(remote)+"\npython3 - <<'PY_FETCH'\n"+code+'\nPY_FETCH\n')
    size=int(wait(config,instance,command))
    if size>10000000:raise ValueError('result export exceeds 10MB')
    pieces=[]
    for offset in range(0,size,16000):
        code=f"from pathlib import Path; print(Path('results.b64').read_text()[{offset}:{offset+16000}],end='')"
        command=submit(config,instance,'set -eu\ncd '+shlex.quote(remote)+'\npython3 -c '+shlex.quote(code))
        pieces.append(wait(config,instance,command).strip())
    args.output.mkdir(parents=True,exist_ok=True)
    allowed={'summary.json','search-config.json','monitoring.json','quality.json','judgments.json','output.log'}
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(''.join(pieces))),mode='r:gz') as archive:
        for member in archive.getmembers():
            if member.name not in allowed or not member.isfile():raise ValueError('unexpected archive member')
            target=args.output/member.name
            if target.exists():raise ValueError('refuse to overwrite '+str(target))
            target.write_bytes(archive.extractfile(member).read())
    (args.output/'receipt.json').write_text(json.dumps(value,indent=2)+'\n')
    print('Saved '+str(args.output)+'; original SSM status: '+result['Status'])


def status(args,config):
    value=json.loads(args.receipt.read_text())
    if args.wait:
        wait(config,value['instance'],value['command'],86400)
        print('Success: '+value['command'])
    else:
        result=aws(config,'ssm','get-command-invocation','--command-id',value['command'],'--instance-id',value['instance'])
        print(json.dumps({'status':result['Status'],'command':value['command'],'responseCode':result.get('ResponseCode')},indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    for name in ['seed','load','quality']:
        cmd=sub.add_parser(name);cmd.add_argument('env',choices=['main','dev']);cmd.add_argument('bundle',type=Path)
        if name=='load':
            cmd.add_argument('--experiment',required=True);cmd.add_argument('--rps',type=int,default=10);cmd.add_argument('--seconds',type=int,default=300)
            cmd.add_argument('--warmup',type=int,default=60);cmd.add_argument('--vus',type=int,default=50);cmd.add_argument('--max-vus',type=int,default=500)
            cmd.add_argument('--limit',type=int,default=10);cmd.add_argument('--endpoint',choices=['mixed','menus','reviews','combined'],default='mixed')
        if name=='quality':cmd.add_argument('--judgments',type=Path,required=True)
    cmd=sub.add_parser('fetch');cmd.add_argument('receipt',type=Path);cmd.add_argument('--output',type=Path,required=True)
    cmd=sub.add_parser('status');cmd.add_argument('receipt',type=Path);cmd.add_argument('--wait',action='store_true')
    args=parser.parse_args()
    if args.command=='load' and (not 1<=args.rps<=10000 or not 1<=args.seconds<=3600 or not 0<=args.warmup<=600 or not 1<=args.vus<=args.max_vus<=2000 or not 1<=args.limit<=100):
        parser.error('invalid rate/duration/VU/limit bounds')
    try:
        config=configuration()
        {'seed':seed,'load':load,'quality':quality,'fetch':fetch,'status':status}[args.command](args,config)
    except (ValueError,KeyError,subprocess.CalledProcessError) as e:parser.exit(1,str(e)+'\n')

if __name__=='__main__':main()
