#!/usr/bin/env bash
# Extends existing Prometheus config/dashboard; never replaces volumes or old evidence.
set -euo pipefail
source "$(dirname "$0")/burger-common.sh"
monitor=$(burger_value .monitoring_instance_id)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$BURGER_TF_ROOT/monitoring/elasticsearch/configure.py" "$BURGER_TF_ROOT/monitoring/elasticsearch/dashboard.json" "$work/"
(cd "$BURGER_TF_ROOT" && terraform output -json burger_search) > "$work/config.json"
payload=$(COPYFILE_DISABLE=1 tar -C "$work" -czf - configure.py dashboard.json config.json | base64 | tr -d '\n')
script=$(cat <<EOF_REMOTE
set -eu
mkdir -p /opt/burger-search-monitoring
printf '%s' '$payload' | base64 -d | tar -xzf - -C /opt/burger-search-monitoring
python3 -c 'import yaml'
backup=/opt/monitoring/prometheus/prometheus.yml.before-search-\$(date +%s)
cp /opt/monitoring/prometheus/prometheus.yml "\$backup"
python3 /opt/burger-search-monitoring/configure.py
if ! docker exec prometheus promtool check config /etc/prometheus/prometheus.yml; then
  cp "\$backup" /opt/monitoring/prometheus/prometheus.yml
  exit 1
fi
curl -fsS -X POST http://127.0.0.1:9090/-/reload
install -m 644 /opt/burger-search-monitoring/dashboard.json /opt/monitoring/grafana/dashboards/burger-search.json
EOF_REMOTE
)
burger_ssm "$monitor" "$script"
echo 'Search monitoring installed: https://monitoring.pattie.cloud/d/burger-search'
