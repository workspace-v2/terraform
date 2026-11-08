#!/usr/bin/env python3
"""Index the currently deployed main/dev MySQL database through temporary SSM tunnels.

Does not change data, app task definitions, GitHub variables, or deploy applications.
Requires local mysql, AWS CLI and session-manager-plugin. Uses personal-project by default.
"""
import argparse
from contextlib import contextmanager, ExitStack
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('experiment', ROOT / 'scripts/burger-experiment.py')
experiment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(experiment)


def protected_write(path, text):
    path.write_text(text)
    path.chmod(0o600)
    return path


@contextmanager
def tunnel(config, target, remote_port, directory):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    command = ['aws', '--profile', os.environ.get('AWS_PROFILE_NAME', 'personal-project'),
               '--region', config['region'], 'ssm', 'start-session', '--target', target,
               '--document-name', 'AWS-StartPortForwardingSession', '--parameters',
               json.dumps({'portNumber': [str(remote_port)], 'localPortNumber': [str(port)]})]
    log_path = directory / ('tunnel-' + str(remote_port) + '.log')
    with log_path.open('w') as log:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None:
                    raise RuntimeError('SSM tunnel exited; check instance readiness and local plugin')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('SSM tunnel readiness timeout')
                    time.sleep(1)
            yield port
        finally:
            text = log_path.read_text(errors='replace')
            sessions = re.findall(r'SessionId:\s*([A-Za-z0-9_.:@-]+)', text)
            for session in sessions:
                experiment.aws(config, 'ssm', 'terminate-session', '--session-id', session)
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            process.stdin.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('env', choices=['main', 'dev'])
    parser.add_argument('--database', required=True, help='must equal the running app datasource database')
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--quiescent-source-confirmed', action='store_true')
    args = parser.parse_args()
    if not args.quiescent_source_confirmed:
        parser.error('Stop benchmark traffic and source writes, then pass --quiescent-source-confirmed')
    if not re.fullmatch(r'[a-z0-9-]+', args.run_id) or not re.fullmatch(r'[A-Za-z0-9_]+', args.database):
        parser.error('Invalid database/run ID')
    for program in ('mysql', 'aws', 'session-manager-plugin'):
        if not shutil.which(program):
            parser.error('Required local program: ' + program)
    config = experiment.configuration()
    search = json.loads(subprocess.check_output(['terraform', 'output', '-json', 'burger_search'], cwd=ROOT, text=True))
    metadata = experiment.deployed_metadata(config, args.env)
    task = experiment.aws(config, 'ecs', 'describe-task-definition', '--task-definition', metadata['taskDefinition'])['taskDefinition']
    app = next(container for container in task['containerDefinitions'] if container['name'] == 'app')
    env = {item['name']: item['value'] for item in app.get('environment', [])}
    secrets = {item['name']: item['valueFrom'] for item in app.get('secrets', [])}
    database = urlsplit(env['SPRING_DATASOURCE_URL'].removeprefix('jdbc:')).path.lstrip('/')
    if database != args.database:
        raise RuntimeError('Requested DB differs from deployed datasource; no index changes made')
    generator = config['load_generator_id']
    state = experiment.aws(config, 'ec2', 'describe-instances', '--instance-ids', generator)
    if state['Reservations'][0]['Instances'][0]['State']['Name'] == 'running':
        command = experiment.submit(config, generator, 'if pgrep -x k6 >/dev/null; then echo "Active k6; indexing refused" >&2; exit 1; fi', 60)
        experiment.wait(config, generator, command, 90)
    receipt = ROOT / 'loadtest-results/burger/search-index' / (args.env + '-' + args.run_id + '.json')
    if receipt.exists():
        raise RuntimeError('Receipt exists; choose a new run ID')
    # Secret values never enter process arguments, SSM command payloads, Terraform output or logs.
    with tempfile.TemporaryDirectory(prefix='burger-search-') as tmp:
        directory = Path(tmp)
        with ExitStack() as stack:
            db_port = stack.enter_context(tunnel(config, config['environments'][args.env]['database_id'], 3306, directory))
            es_port = stack.enter_context(tunnel(config, search['instance_id'], 9200, directory))
            db_password = experiment.aws(config, 'ssm', 'get-parameter', '--name', secrets['DB_PASSWORD'], '--with-decryption')['Parameter']['Value']
            admin_password = experiment.aws(config, 'ssm', 'get-parameter', '--name', search['admin_parameter'], '--with-decryption')['Parameter']['Value']
            # Generated infrastructure passwords are alphanumeric; escape option-file values defensively.
            def option(value):
                return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
            defaults = protected_write(directory / 'mysql.cnf', '[client]\nprotocol=tcp\nhost=127.0.0.1\nport=' + str(db_port) + '\nuser=' + option(env.get('DB_USERNAME', 'burger')) + '\npassword=' + option(db_password) + '\n')
            password = protected_write(directory / 'admin.secret', admin_password)
            subprocess.run(['python3', str(ROOT / 'scripts/burger-search-index.py'),
                '--mysql-defaults-file', str(defaults), '--database', database,
                '--url', 'http://127.0.0.1:' + str(es_port), '--password-file', str(password),
                '--prefix', 'burger-' + args.env, '--run-id', args.run_id,
                '--receipt', str(receipt), '--quiescent-source-confirmed'], check=True)
    value = json.loads(receipt.read_text())
    value.update({'source_deployed': metadata, 'search_node': search['instance_id'], 'search_version': search['version']})
    receipt.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    print('Index verified and aliases published; app search engine was not changed.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.CalledProcessError):
        raise SystemExit('Indexing failed; inspect the receipt and aliases before retrying. No application deployment was requested.')
