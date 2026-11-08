"""Add a separate search scrape job without changing Burgerpedia baseline targets."""
import json
from pathlib import Path
import yaml

config = json.loads(Path('/opt/burger-search-monitoring/config.json').read_text())
path = Path('/opt/monitoring/prometheus/prometheus.yml')
value = yaml.safe_load(path.read_text())
jobs = value.setdefault('scrape_configs', [])
jobs[:] = [j for j in jobs if j.get('job_name') != 'burger-search']
labels = {'project': 'burger-search', 'env': 'shared', 'role': 'elasticsearch'}
jobs.append({'job_name': 'burger-search', 'scrape_interval': '15s', 'scrape_timeout': '12s',
             'static_configs': [
                 {'targets': [config['private_ip'] + ':9114'], 'labels': labels | {'component': 'elasticsearch'}},
                 {'targets': [config['private_ip'] + ':9100'], 'labels': labels | {'component': 'node'}},
             ]})
path.write_text(yaml.safe_dump(value, sort_keys=False))
