#!/usr/bin/env bash
# Usage: burger-loadtest.sh <main|dev> [RPS=10] [duration=1m] [path=/v1/posts/cursor?limit=20]
# Runs on the existing load generator. Change the path to the search API once available.
set -euo pipefail
env="${1:-}"
case "$env" in main|dev) ;; *) echo "usage: $0 <main|dev> [RPS] [duration] [path]" >&2; exit 2 ;; esac
rps="${2:-10}"; duration="${3:-1m}"; path="${4:-/v1/posts/cursor?limit=20}"
[[ "$rps" =~ ^[1-9][0-9]*$ ]] || { echo 'RPS must be a positive integer' >&2; exit 2; }
[[ "$duration" =~ ^[1-9][0-9]*[smh]$ ]] || { echo 'duration must be e.g. 30s, 5m or 1h' >&2; exit 2; }
[[ "$path" = /* ]] || { echo 'path must start with /' >&2; exit 2; }
source "$(dirname "$0")/burger-common.sh"
loadgen=$(burger_value .load_generator_id)
monitor_ip=$(burger_value .monitoring_ip)
base_url=$(burger_value ".environments.$env.url")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$BURGER_TF_ROOT/monitoring/burger/loadtest.js" "$work/"
id="burger-$env-$(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg env "$env" --arg base "$base_url" --arg path "$path" --arg duration "$duration" --arg id "$id" --argjson rps "$rps" \
  '{env:$env,baseUrl:$base,path:$path,duration:$duration,testid:$id,rps:$rps,maxVUs:500}' > "$work/loadtest-config.json"
payload=$(COPYFILE_DISABLE=1 tar -C "$work" -czf - loadtest.js loadtest-config.json | base64 | tr -d '\n')
# Each run has its own files; existing Bangjjack test scenarios/results are preserved.
script="set -eu
mkdir -p /opt/loadtest/burger/$id
printf '%s' '$payload' | base64 -d | tar -xzf - -C /opt/loadtest/burger/$id
cd /opt/loadtest/burger/$id
export K6_PROMETHEUS_RW_SERVER_URL=http://$monitor_ip:9090/api/v1/write
export K6_PROMETHEUS_RW_TREND_STATS='p(95),p(99),avg'
k6 run -o experimental-prometheus-rw --summary-export summary.json loadtest.js > output.log 2>&1"
# Load tests may outlast the SSM helper's 15m budget; submit asynchronously and print the command ID.
params=$(jq -nc --arg script "$script" '{commands:[$script],executionTimeout:["86400"]}')
command_id=$(burger_aws ssm send-command --instance-ids "$loadgen" --document-name AWS-RunShellScript --parameters "$params" --query Command.CommandId --output text)
echo "testid=$id"
echo "instance=$loadgen command=$command_id"
echo "Results: /opt/loadtest/burger/$id/{summary.json,output.log} on the shared load generator"
echo "Inspect: aws --profile $BURGER_PROFILE --region $BURGER_REGION ssm get-command-invocation --command-id $command_id --instance-id $loadgen"
