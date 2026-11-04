#!/usr/bin/env python3
"""Add one scrape job, preserving all existing jobs and the Prometheus data volume."""
from pathlib import Path
import yaml

path = Path("/opt/monitoring/prometheus/prometheus.yml")
config = yaml.safe_load(path.read_text())
jobs = config.setdefault("scrape_configs", [])
jobs[:] = [job for job in jobs if job.get("job_name") != "burger-endpoints"]
jobs.append({"job_name": "burger-endpoints", "scrape_interval": "15s",
             "file_sd_configs": [{"files": ["/etc/prometheus/burger-targets.json"], "refresh_interval": "15s"}]})
path.write_text(yaml.safe_dump(config, sort_keys=False))
