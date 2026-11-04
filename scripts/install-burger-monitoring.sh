#!/usr/bin/env bash
# Adds scrape targets on the EXISTING monitoring host, without replacing it or losing metrics.
set -euo pipefail
source "$(dirname "$0")/burger-common.sh"
monitor=$(burger_value .monitoring_instance_id)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$BURGER_TF_ROOT/monitoring/burger/"*.py "$work/"
cp "$BURGER_TF_ROOT/monitoring/burger/dashboard.json" "$work/"
jq '{region,cluster,environments}' <<< "$BURGER_CONFIG" > "$work/config.json"
payload=$(COPYFILE_DISABLE=1 tar -C "$work" -czf - discover.py configure.py config.json dashboard.json | base64 | tr -d '\n')
script=$(cat <<EOF_REMOTE
set -eu
apt-get update -q
apt-get install -y python3-boto3 python3-yaml
mkdir -p /opt/burger-monitoring
printf '%s' '$payload' | base64 -d | tar -xzf - -C /opt/burger-monitoring
install -m 644 /opt/burger-monitoring/config.json /etc/burger-monitoring.json
/usr/bin/python3 /opt/burger-monitoring/discover.py
cp /opt/monitoring/prometheus/prometheus.yml /opt/monitoring/prometheus/prometheus.yml.before-burger
/usr/bin/python3 /opt/burger-monitoring/configure.py
if ! docker exec prometheus promtool check config /etc/prometheus/prometheus.yml; then
  cp /opt/monitoring/prometheus/prometheus.yml.before-burger /opt/monitoring/prometheus/prometheus.yml
  exit 1
fi
curl -fsS -X POST http://localhost:9090/-/reload
cat > /etc/systemd/system/burger-discovery.service <<'UNIT'
[Unit]
Description=Burgerpedia ECS Prometheus target discovery
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/burger-monitoring/discover.py
UNIT
cat > /etc/systemd/system/burger-discovery.timer <<'UNIT'
[Unit]
Description=Refresh Burgerpedia ECS monitoring targets
[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
[Install]
WantedBy=timers.target
UNIT
install -m 644 /opt/burger-monitoring/dashboard.json /opt/monitoring/grafana/dashboards/burger-overview.json
systemctl daemon-reload
systemctl enable --now burger-discovery.timer
EOF_REMOTE
)
burger_ssm "$monitor" "$script"
echo 'Burgerpedia monitoring installed. Grafana: filter project="burger", env="main" or "dev".'
